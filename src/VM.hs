{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- VM.hs — the Sol VM: dumb, mechanistic register interpreter.
--
--   * one frame of slots per activation (size known at compile time)
--   * fuel decremented at EVERY function entry — the same contract the
--     FPRISC compiler + actors.c use (function entry is the guaranteed
--     safepoint; structured control flow means recursion is the only loop).
--     No scheduler in this single-actor PoC: exhaustion refills and counts,
--     which is where a scheduler hook (or actor switch) slots in later.
--   * APPLY is fpr_apply's twin: PAP accumulation until saturation
--   * HCALL is the single trap into the Haskell HAL: prims, IO, and the
--     transactional file ops from Txn.hs
--   * no heap, no GC, no ARC at VM level: values are host values; the
--     real runtime's ARC discipline is enforced upstream by linearity

module VM (module VM, module Val) where

import Bytecode
import Mod
import Val
import Web
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import JIT
import Lang (Name)
import qualified Lang
import Control.Concurrent (threadDelay)
import Data.Int (Int64)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek, poke)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import Data.IORef
import Data.List (intercalate)
import qualified Data.Map.Strict as M
import Control.Monad (unless)
import System.IO (hFlush, hGetContents', stdin, stdout)
import Txn

data VMEnv = VMEnv
  { vmBaseDir :: FilePath, -- the script's directory: module resolution root
    vmDataFile :: FilePath, -- <script>.soldata: the persistent msg log
    vmCons :: M.Map String (Int, Int), -- constructor name -> (tid, variant)
    vmShapes :: M.Map Int [String], -- record tid -> sorted field names (for JSON)
    vmProg :: BProg,
    vmCore :: Lang.Prog, -- Core, for the JIT front-end
    vmJit :: Maybe JitCtx, -- Nothing = JIT disabled, always interpret
    vmHal :: M.Map Name (Int, [Value] -> IO Value),
    vmFuel :: IORef Int,
    vmPreempts :: IORef Int
  }

fuelQuantum :: Int
fuelQuantum = 2000

-- fuel check at function entry: the compiler-inserted decrement's twin.
-- In the full runtime this is where the scheduler switches actors.
fuelTick :: VMEnv -> IO ()
fuelTick env = do
  f <- readIORef (vmFuel env)
  if f <= 1
    then do
      modifyIORef' (vmPreempts env) (+ 1)
      writeIORef (vmFuel env) fuelQuantum -- scheduler hook goes here
    else writeIORef (vmFuel env) (f - 1)

execFn :: VMEnv -> Name -> [Value] -> IO Value
execFn env name args = do
  fuelTick env
  case M.lookup name (vmProg env) of
    Nothing -> vmPanic ("no such function: " ++ name)
    Just (Fn ar slots code) -> do
      if length args /= ar
        then vmPanic ("call " ++ name ++ ": arity mismatch")
        else do
          frame <- newIORef (M.fromList (zip [0 ..] args) :: M.Map Reg Value)
          let codeArr = code
          runLoop env frame codeArr 0

vmPanic :: String -> IO a
vmPanic m = ioError (userError ("*** SOL PANIC: " ++ m ++ " ***"))

runLoop :: VMEnv -> IORef (M.Map Reg Value) -> [Instr] -> Int -> IO Value
runLoop env frame code = go
  where
    fetch pc = case drop pc code of
      (i : _) -> i
      [] -> error "pc out of range"
    rd r = do
      m <- readIORef frame
      case M.lookup r m of
        Just v -> pure v
        Nothing -> vmPanic ("read of unwritten slot r" ++ show r)
    wr r v = modifyIORef' frame (M.insert r v)

    go pc = case fetch pc of
      LoadI r i -> wr r (VInt i) >> go (pc + 1)
      LoadS r s -> wr r (VStr s) >> go (pc + 1)
      Move d s -> rd s >>= wr d >> go (pc + 1)
      Arith2 op d a b -> do
        va <- rd a
        vb <- rd b
        wr d =<< arith op va vb
        go (pc + 1)
      Jmp l -> go l
      Jz r l ->
        rd r >>= \case
          VData t v _ | t == boolT -> if v == 0 then go l else go (pc + 1)
          other -> vmPanic ("JZ: non-bool " ++ show other)
      LabelI {} -> go (pc + 1)
      Call d g as -> do
        vs <- mapM rd as
        wr d =<< execFn env g vs
        go (pc + 1)
      HCall d g as -> do
        vs <- mapM rd as
        wr d =<< halCall env g vs
        go (pc + 1)
      MkPap d g -> do
        ar <- arityOf env g
        wr d (VPap g [] ar)
        go (pc + 1)
      Apply d f a -> do
        vf <- rd f
        va <- rd a
        wr d =<< apply env vf va
        go (pc + 1)
      Mk d t v fs -> do
        vs <- mapM rd fs
        wr d (VData t v vs)
        go (pc + 1)
      TagEq d t v s ->
        rd s >>= \case
          VData t' v' _ -> wr d (vBool (t == t' && v == v')) >> go (pc + 1)
          _ -> wr d vFalse >> go (pc + 1)
      Proj d i s ->
        rd s >>= \case
          VData _ _ fs | i < length fs -> wr d (fs !! i) >> go (pc + 1)
          other -> vmPanic ("PROJ: bad value " ++ show other)
      Ret r -> rd r
      ErrI m -> vmPanic m

arityOf :: VMEnv -> Name -> IO Int
arityOf env g = case M.lookup g (vmProg env) of
  Just fn -> pure (fnArity fn)
  Nothing -> case M.lookup g builtinArities of
    Just ar -> pure ar
    Nothing -> case M.lookup g (vmHal env) of
      Just (ar, _) -> pure ar
      Nothing
        | M.member g arithOps -> pure 2
        | otherwise -> vmPanic ("unknown symbol: " ++ g)

-- fpr_apply's twin: accumulate into a PAP; call at saturation
apply :: VMEnv -> Value -> Value -> IO Value
apply env (VPap g as 1) a = callSym env g (reverse (a : as))
apply _ (VPap g as n) a = pure (VPap g (a : as) (n - 1))
apply _ v _ = vmPanic ("APPLY: not a function: " ++ show v)

callSym :: VMEnv -> Name -> [Value] -> IO Value
callSym env g args
  | M.member g (vmProg env) = execFn env g args
  | M.member g builtinArities = builtinCall env g args
  | Just op <- M.lookup g arithOps, [a, b] <- args = arith op a b
  | Just (_, f) <- M.lookup g (vmHal env) = f args
  | otherwise = vmPanic ("call to unknown symbol: " ++ g)

arith :: ArithOp -> Value -> Value -> IO Value
arith op (VInt a) (VInt b) = case op of
  OAdd -> pure (VInt (a + b))
  OSub -> pure (VInt (a - b))
  OMul -> pure (VInt (a * b))
  -- `quot` (truncate toward zero): matches LLVM sdiv, C, and RISC-V DIV —
  -- the interpreter follows the hardware, not Haskell's flooring div
  ODiv -> if b == 0 then vmPanic "division by zero" else pure (VInt (a `quot` b))
  OLt -> pure (vBool (a < b))
  OLe -> pure (vBool (a <= b))
  OGt -> pure (vBool (a > b))
  OGe -> pure (vBool (a >= b))
  OEq -> pure (vBool (a == b))
  ONe -> pure (vBool (a /= b))
arith OEq a b = pure (vBool (veq a b))
arith ONe a b = pure (vBool (not (veq a b)))
-- Numeric contagion: an inexact operand lifts the whole operation. Int/Int
-- stays quot (above); any VNum in the pair means true real arithmetic.
arith op (VNum a) (VNum b) = arithN op a b
arith op (VNum a) (VInt b) = arithN op a (fromIntegral b)
arith op (VInt a) (VNum b) = arithN op (fromIntegral a) b
arith op a b = vmPanic ("arith " ++ show op ++ ": bad operands " ++ show (a, b))

arithN :: ArithOp -> Double -> Double -> IO Value
arithN op a b = case op of
  OAdd -> pure (VNum (a + b))
  OSub -> pure (VNum (a - b))
  OMul -> pure (VNum (a * b))
  ODiv -> if b == 0 then vmPanic "division by zero" else pure (VNum (a / b))
  OLt -> pure (vBool (a < b))
  OLe -> pure (vBool (a <= b))
  OGt -> pure (vBool (a > b))
  OGe -> pure (vBool (a >= b))
  OEq -> pure (vBool (a == b))
  ONe -> pure (vBool (a /= b))

halCall :: VMEnv -> Name -> [Value] -> IO Value
halCall env g args
  | M.member g builtinArities = builtinCall env g args
  | otherwise = case M.lookup g (vmHal env) of
      Just (ar, f)
        | length args == ar -> f args
        | otherwise -> vmPanic ("HCALL " ++ g ++ ": arity mismatch")
      Nothing -> vmPanic ("HCALL: unknown HAL symbol " ++ g)

builtinArities :: M.Map Name Int
builtinArities =
  M.union schemeArities $
    M.fromList
      [ ("use", 1), ("run", 2), ("View.serve", 5),
        ("Vec.new", 1), ("Vec.push", 2), ("Vec.len", 1), ("Vec.get", 2),
        ("Vec.set", 3), ("Vec.map", 2), ("Vec.filter", 2), ("Vec.fold", 3),
        ("Vec.toList", 1), ("Vec.fromList", 1), ("Vec.free", 1)
      ]

builtinCall :: VMEnv -> Name -> [Value] -> IO Value
builtinCall env g args
  | M.member g schemeArities = schemeCall env g args
  | g == "use" || g == "run" = modCall env g args
  | g == "View.serve" = viewServe env args
  | otherwise = vecCall env g args

-- ---- gen_view: the MVU web behavior (Web.hs owns the transport) -------------
viewServe :: VMEnv -> [Value] -> IO Value
viewServe env [VInt port, fi, fu, fv, subsV] =
  serveWeb
    (fromIntegral port)
    (vmDataFile env)
    (vmShapes env)
    (vmCons env)
    [(fromIntegral ms, ev) | VData 4 0 [VInt ms, VStr ev] <- listItemsV subsV]
    Callbacks
      { cbInit = apply env fi,
        cbUpdate = \msg mdl -> apply env fu msg >>= \p -> apply env p mdl,
        cbView = apply env fv
      }
viewServe _ _ = vmPanic "View.serve: expected port init update view subs"

-- ---- content-addressed file modules (Mod.hs does the work) -----------------
modCall :: VMEnv -> Name -> [Value] -> IO Value
modCall env "use" [VStr spec] = do
  r <- resolveModule (vmBaseDir env) spec
  case r of
    Left e -> vmPanic e
    Right (p, h, pinned) -> do
      unless pinned $
        putStrLn ("[sol] use: " ++ spec ++ " resolves to " ++ spec ++ "#" ++ h ++ " (pin this)")
      pure (VMod p h)
modCall _ "use" [v] = vmPanic ("use: expected a module spec string, got " ++ render v)
modCall _ "run" [VMod p h, x] = do
  r <- runModule p h (render x)
  either vmPanic (pure . VStr) r
modCall _ "run" [v, _] = vmPanic ("run: not a module: " ++ render v)
modCall _ g _ = vmPanic (g ++ ": bad arguments")

-- ---- recursion schemes: the JIT tier ---------------------------------------
--
-- map / filter / foldl are the only calls the JIT ever sees, and only when:
--   * the list is all unboxed ints and longer than jitThreshold
--   * the element function is an unapplied top-level supercombinator whose
--     call closure is arithmetic-only Core (checked in JIT.jittable)
-- Everything else falls back to the interpreted loop below. The schemes are
-- bounded by construction (one call per element), so they need no
-- preemption; fuel is still counted — reified into the native code — and
-- the cell is reconciled with the VM's counter around the pure native call.


-- ---- typed marshalling for the JIT boundary --------------------------------

d2b :: Double -> Int64
d2b = fromIntegral . castDoubleToWord64

b2d :: Int64 -> Double
b2d = castWord64ToDouble . fromIntegral

-- classify a list for the typed tier: all-VInt rides as i64s (JI); any
-- VNum promotes every element to f64 bits — all-VNum is JD, a mixture is
-- JW (each element COULD have been an Int the interpreter would keep exact)
toTyped :: Value -> Maybe (JTy, [Int64])
toTyped v0 = do
  xs <- nums v0
  let ety
        | all isI xs = JI
        | all (not . isI) xs = JD
        | otherwise = JW
  pure (ety, map (enc ety) xs)
  where
    nums (VData t 1 [x, r]) | t == listT = (x :) <$> nums r
    nums (VData t 0 []) | t == listT = Just []
    nums _ = Nothing
    isI VInt {} = True
    isI _ = False
    enc JI (VInt i) = fromIntegral i
    enc _ (VInt i) = d2b (fromIntegral i)
    enc _ (VNum d) = d2b d
    enc _ _ = 0

valBits :: JTy -> Value -> Int64
valBits JI (VInt a) = fromIntegral a
valBits _ (VInt a) = d2b (fromIntegral a)
valBits _ (VNum d) = d2b d
valBits _ _ = 0

bitsVal :: JTy -> Int64 -> Value
bitsVal JI r = VInt (fromIntegral r)
bitsVal _ r = VNum (b2d r)

accTyOf :: Maybe Value -> Maybe JTy
accTyOf Nothing = Just JI
accTyOf (Just (VInt _)) = Just JI
accTyOf (Just (VNum _)) = Just JD
accTyOf _ = Nothing

kindTy :: ColKind -> JTy
kindTy KInt = JI
kindTy KNum = JD
kindTy KBox = JW -- marker: unloadable; jitOKVec rejects any touch

schemeArities :: M.Map Name Int
schemeArities = M.fromList [("map", 2), ("filter", 2), ("foldl", 3)]

jitThreshold :: Int
jitThreshold = 64

schemeCall :: VMEnv -> Name -> [Value] -> IO Value
schemeCall env name args = case (name, args) of
  ("map", [f, xs]) -> viaJit "map" f xs Nothing (interpMap f xs)
  ("filter", [f, xs]) -> viaJit "filter" f xs Nothing (interpFilter f xs)
  ("foldl", [f, z, xs]) -> viaJit "foldl" f xs (Just z) (interpFold f z xs)
  _ -> vmPanic (name ++ ": bad arguments")
  where
    viaJit scheme f xs macc fallback =
      case (vmJit env, unappliedFn f, toTyped xs) of
        (Just jc, Just g, Just (ety, bits))
          | length bits >= jitThreshold,
            Just aty0 <- accTyOf macc,
            -- map/filter over MIXED lists bail: the promoted elements lose
            -- which ones the interpreter would keep as exact VInts
            not (ety == JW && scheme /= "foldl") ->
              compileScheme jc (vmCore env) scheme g ety aty0 >>= \case
                Nothing -> fallback -- not jittable: interpreter's job
                Just (addr, accTy, retTy) -> withFuelCell env $ \pfuel ->
                  if scheme == "foldl"
                    then do
                      let Just a0 = macc
                      bitsVal retTy <$> runFold addr pfuel (valBits accTy a0) bits
                    else do
                      (_, out) <- runMapFilter addr pfuel bits
                      let outTy = if scheme == "map" then retTy else ety
                      pure (foldr (\x acc -> VData listT 1 [bitsVal outTy x, acc]) (VData listT 0 []) out)
        _ -> fallback

    unappliedFn (VPap g [] _) | M.member g (vmProg env) = Just g
    unappliedFn _ = Nothing

    interpMap f = go
      where
        go (VData t 1 [x, r]) | t == listT = do
          y <- apply env f x
          rest <- go r
          pure (VData listT 1 [y, rest])
        go (VData t 0 []) | t == listT = pure (VData listT 0 [])
        go v = vmPanic ("map: not a list: " ++ render v)
    interpFilter f = go
      where
        go (VData t 1 [x, r]) | t == listT = do
          keep <- apply env f x
          rest <- go r
          case keep of
            VData bt 1 [] | bt == boolT -> pure (VData listT 1 [x, rest])
            VData bt 0 [] | bt == boolT -> pure rest
            VInt n -> pure (if n /= 0 then VData listT 1 [x, rest] else rest)
            v -> vmPanic ("filter: predicate returned non-bool: " ++ render v)
        go (VData t 0 []) | t == listT = pure (VData listT 0 [])
        go v = vmPanic ("filter: not a list: " ++ render v)
    interpFold f = go
      where
        go acc (VData t 1 [x, r]) | t == listT = do
          acc' <- apply env f acc >>= \pf -> apply env pf x
          go acc' r
        go acc (VData t 0 []) | t == listT = pure acc
        go _ v = vmPanic ("foldl: not a list: " ++ render v)


-- a scheme function is JIT-callable if it's a top-level supercombinator
-- with the right number of args REMAINING and every already-captured arg
-- is an unboxed int (delivered as the dual's extras)
jitCallable :: VMEnv -> String -> Value -> Maybe (Name, [(Int64, JTy)])
jitCallable env scheme f = case f of
  VPap g revArgs remaining
    | M.member g (vmCore env),
      remaining == (if scheme == "vecfold" then 2 else 1),
      Just is <- mapM toTV (reverse revArgs) ->
        Just (g, is)
  _ -> Nothing
  where
    -- captured scalars carry their own definite type: a VNum weight rides
    -- as f64 bits, a VInt as a plain i64 (typed inside the driver)
    toTV (VInt i) = Just (fromIntegral i, JI)
    toTV (VNum d) = Just (d2b d, JD)
    toTV _ = Nothing

-- marshal Sol Int lists <-> unboxed arrays: the builder->freeze boundary
toInts :: Value -> Maybe [Int64]
toInts (VData t 1 [VInt x, r]) | t == listT = (fromIntegral x :) <$> toInts r
toInts (VData t 0 []) | t == listT = Just []
toInts _ = Nothing

fromInts :: [Int64] -> Value
fromInts = foldr (\x acc -> VData listT 1 [VInt (fromIntegral x), acc]) (VData listT 0 [])

-- hand the native code a fuel cell; reconcile with the VM counter after.
-- Native code only decrements (accounting, per the function-entry contract);
-- exhaustion mid-scheme is impossible to act on there — which is fine,
-- because the schemes are bounded — so the refill/preempt bookkeeping
-- happens here, once, on return.
withFuelCell :: VMEnv -> (Ptr Int64 -> IO a) -> IO a
withFuelCell env body = alloca $ \p -> do
  f0 <- readIORef (vmFuel env)
  poke p (fromIntegral f0)
  r <- body p
  f1 <- peek p
  if f1 <= 0
    then do
      modifyIORef' (vmPreempts env) (+ 1)
      writeIORef (vmFuel env) fuelQuantum
    else writeIORef (vmFuel env) (fromIntegral f1)
  pure r

-- ---- the HAL: prims + transactional file IO -------------------------------
--
-- Every entry here is what an fpr_g_* symbol is on the metal: the ONLY
-- surface generated code can reach the outside world through. Path/Handle
-- tids are passed in because the front-end assigns user-type ids in
-- declaration order (prelude declares them first).

mkHal :: M.Map Name (Int, Int, Int) -> IORef TxState -> IORef Int -> M.Map Name (Int, [Value] -> IO Value)
mkHal cons tx preempts =
  M.fromList
    [ ("str", (1, \[v] -> pure (VStr (render v)))),
      ("strcat", (2, \[VStr a, VStr b] -> pure (VStr (a ++ b)))),
      ("String.len", (1, \[VStr s] -> pure (VInt (fromIntegral (length s))))),
      ("strlen", (1, \[VStr s] -> pure (VInt (fromIntegral (length s))))),
      ("charAt", (2, charAtH)),
      ("chr", (1, \[VInt c] -> pure (VStr [toEnum (fromIntegral c)]))),
      ("error", (1, \[v] -> vmPanic (render v))),
      ("parseInt", (1, parseIntH)),
      -- Numeric prims: the doors into inexact arithmetic. Num.div is TRUE
      -- division (always inexact); ordinary +,-,*,/ then propagate
      -- inexactness by promotion in `arith`. floor/round land back on Int.
      ("Num.div", (2, \[a, b] -> numDivH a b)),
      ("Num.sqrt", (1, \[a] -> numSqrtH a)),
      ("Num.floor", (1, \[a] -> pure (VInt (floor (toD a))))),
      ("Num.round", (1, \[a] -> pure (VInt (round (toD a))))),
      ("!", (2, indexH)),
      -- the transactional file surface: linear Handle discipline is enforced
      -- at COMPILE TIME by the linearity checker; these just do the TRec ops
      ("open", (1, openH)),
      ("readAll", (1, readH)),
      ("writeAll", (2, writeH)),
      ("close", (1, closeH)),
      -- read/write: the ONLY other doors out. `read x` is a coeffect —
      -- x is a path (file contents / a device) or an Io query carrying its
      -- own path or command. `write p v` is an effect — v's shape (string
      -- contents vs Io intent) or p's device prefix picks the operation.
      -- Everything the prelude calls fs ops (mkdirp, rm, ls, stat, mv, sh,
      -- print, input, ...) is Sol code decoded HERE, transactionally.
      ("read", (1, \[v] -> readIoH v)),
      ("write", (2, \[pv, v] -> writeIoH pv v))
    ]
  where
    (pathT, handleT) = (tidOf "Path", tidOf "Handle")
    tidOf n = maybe (-1) (\(t, _, _) -> t) (M.lookup n cons)
    conTV n = maybe (-1, -1) (\(t, v, _) -> (t, v)) (M.lookup n cons)
    isCon n t g = conTV n == (t, g)

    readIoH v
      | Just p <- unPath v = case p of
          "/dev/in" -> VStr <$> hGetContents' stdin
          "/dev/fuel" -> VInt . fromIntegral <$> readIORef preempts
          _ -> VStr <$> txReadWhole p
    readIoH (VData t g [q])
      | isCon "Ls" t g = withP q (\p -> strList <$> txLs tx p)
      | isCon "Exists" t g = withP q (\p -> vBool <$> txExists tx p)
      | isCon "IsDir" t g = withP q (\p -> vBool <$> txIsDir tx p)
      | isCon "Stat" t g = withP q (\p -> do
          (e, sz, mt) <- txStat tx p
          pure (VData 5 0 [vBool e, VInt (fromIntegral sz), VInt (fromIntegral mt)]))
      | isCon "Sh" t g = withS q (\c -> do
          (code, out) <- txSh c
          pure (VData 4 0 [VInt (fromIntegral code), VStr out]))
    readIoH v = vmPanic ("read: cannot decode " ++ render v)

    writeIoH pv v = case unPath pv of
      Just "/dev/out" -> putStrLn (render v) >> hFlush stdout >> pure vUnit
      Just "/dev/sh" -> withS v (\c -> txShq tx c >> pure vUnit)
      Just "/dev/clock" -> case v of
        VInt ms -> threadDelay (fromIntegral ms * 1000) >> pure vUnit
        bad -> vmPanic ("write /dev/clock: expected ms Int, got " ++ render bad)
      Just p -> case v of
        VStr s -> txWriteWhole p s
        VData t g []
          | isCon "Dir" t g -> txMkdirp tx p >> pure vUnit
          | isCon "Rm" t g -> txRm tx p >> pure vUnit
          | isCon "RmDir" t g -> txRmdir tx p >> pure vUnit
        bad -> vmPanic ("write " ++ p ++ ": cannot decode " ++ render bad)
      Nothing -> vmPanic ("write: expected a path or string, got " ++ render pv)


    toD (VInt i) = fromIntegral i
    toD (VNum d) = d
    toD v = unsafePerformIO (vmPanic ("Numeric op: not a number: " ++ render v))

    numDivH a b =
      let (x, y) = (toD a, toD b)
       in if y == 0 then vmPanic "Num.div: division by zero" else pure (VNum (x / y))
    numSqrtH a =
      let x = toD a
       in if x < 0 then vmPanic "Num.sqrt: negative" else pure (VNum (sqrt x))

    -- whole-file read/write = the handle quartet composed on the caller's
    -- behalf; identical txn semantics to open/readAll|writeAll/close
    txReadWhole p = do
      h <- txOpen tx p
      s <- txHRead tx h
      txClose tx h
      pure s
    txWriteWhole p s = do
      h <- txOpen tx p
      txHWrite tx h s
      txClose tx h
      pure vUnit
    unPath (VData t 0 [VStr p]) | t == pathT = Just p
    unPath (VStr p) = Just p
    unPath _ = Nothing

    withP (VData t 0 [VStr p]) k | t == pathT = k p
    withP (VStr p) k = k p
    withP bad _ = vmPanic ("expected a path or string, got " ++ render bad)

    withS (VStr c) k = k c
    withS bad _ = vmPanic ("expected a command string, got " ++ render bad)

    vBool b = VData 1 (if b then 1 else 0) []

    strList = foldr (\x acc -> VData listT 1 [VStr x, acc]) (VData listT 0 [])
    unHandle (VData t 0 [VInt h]) | t == handleT = Just (fromIntegral h)
    unHandle _ = Nothing
    mkHandle h = VData handleT 0 [VInt (fromIntegral h)]

    openH [v] = case unPath v of
      Just p -> mkHandle <$> txOpen tx p
      Nothing -> vmPanic ("open: not a Path: " ++ render v)
    openH _ = vmPanic "open: arity"

    readH [v] = case unHandle v of
      Just h -> do
        s <- txHRead tx h
        pure (VData 4 0 [VStr s, v]) -- (contents, handle) — hand the handle back
      Nothing -> vmPanic ("readAll: not a Handle: " ++ render v)
    readH _ = vmPanic "readAll: arity"

    writeH [v, VStr s] = case unHandle v of
      Just h -> txHWrite tx h s >> pure v -- returns the (rebound) handle
      Nothing -> vmPanic ("writeAll: not a Handle: " ++ render v)
    writeH _ = vmPanic "writeAll: bad args"

    closeH [v] = case unHandle v of
      Just h -> txClose tx h >> pure vUnit
      Nothing -> vmPanic ("close: not a Handle: " ++ render v)
    closeH _ = vmPanic "close: arity"

    parseIntH [VStr s] = case reads (dropWhile (== ' ') s) :: [(Integer, String)] of
      [(n, rest)] | all (`elem` " \n\t") rest -> pure (VInt n)
      _ -> vmPanic ("parseInt: not an integer: " ++ show s)
    parseIntH [v] = vmPanic ("parseInt: not a string: " ++ render v)
    parseIntH _ = vmPanic "parseInt: arity"

    charAtH [VStr s, VInt i]
      | i >= 1 && fromIntegral i <= length s = pure (VInt (fromIntegral (fromEnum (s !! (fromIntegral i - 1)))))
      | otherwise = vmPanic "charAt: index out of range"
    charAtH _ = vmPanic "charAt: bad args"
    indexH [xs, VInt i] = idx xs i
      where
        idx (VVec r) k = getVec r (fromIntegral k - 1) -- O(1); consumes the vector (linearity) — Vec.get keeps it
        idx (VData t 1 [x, _]) 1 | t == listT = pure x
        idx (VData t 1 [_, r]) k | t == listT = idx r (k - 1)
        idx _ _ = vmPanic "!: index out of range"
    indexH _ = vmPanic "!: bad args"


getEnvDebug :: Bool
getEnvDebug = unsafePerformIO (fmap (== Just "1") (lookupEnv "SOL_JIT_DEBUG"))
{-# NOINLINE getEnvDebug #-}

-- ---- the Vector builtins ----------------------------------------------------
--
-- Vector is LINEAR (prelude declares `Vector 1`), so in-place mutation is
-- sound: push/set mutate the store and hand the same reference back as the
-- "new" vector; the old binding is statically dead. All arg orders put the
-- vector LAST for |> pipelines: `v |> Vec.push 3 |> Vec.map inc`.
--
-- Vec.map / Vec.filter / Vec.fold are the DUAL schemes: over the JIT
-- threshold with an arithmetic element function they compile against the
-- SoA layout (element access becomes column loads — see JIT.compileVecScheme)
-- and run on the lent column pointers with zero marshalling. Otherwise they
-- RECONSTRUCT each element from the columns and apply the function in the
-- interpreter — the documented slower path, same one explicit pattern
-- matching and `!`/Vec.get take.

vecCall :: VMEnv -> Name -> [Value] -> IO Value
vecCall env name args = case (name, args) of
  ("Vec.new", [_]) -> newVec
  ("Vec.push", [x, VVec r]) -> pushVec r x >> pure (VVec r)
  ("Vec.len", [VVec r]) -> do n <- lenVec r; pure (VData 4 0 [VInt (fromIntegral n), VVec r])
  ("Vec.get", [VInt i, VVec r]) -> do
    x <- getVec r (fromIntegral i - 1) -- 1-indexed like list !
    pure (VData 4 0 [x, VVec r])
  ("Vec.set", [VInt i, x, VVec r]) -> setVec r (fromIntegral i - 1) x >> pure (VVec r)
  ("Vec.free", [VVec _]) -> pure vUnit -- ForeignPtr finalizers reclaim
  ("Vec.toList", [VVec r]) -> do
    xs <- toListVec r
    pure (foldr (\x acc -> VData listT 1 [x, acc]) (VData listT 0 []) xs)
  ("Vec.fromList", [xs]) -> do
    v <- newVec
    let VVec r = v
        go (VData t 1 [x, rest]) | t == listT = pushVec r x >> go rest
        go (VData t 0 []) | t == listT = pure ()
        go bad = vmPanic ("Vec.fromList: not a list: " ++ render bad)
    go xs
    pure v
  ("Vec.map", [f, VVec r]) -> vecScheme env "vecmap" f Nothing r
  ("Vec.filter", [f, VVec r]) -> vecScheme env "vecfilter" f Nothing r
  ("Vec.fold", [f, z, VVec r]) -> vecScheme env "vecfold" f (Just z) r
  _ -> vmPanic (name ++ ": bad arguments (is the vector argument last?)")

vecScheme :: VMEnv -> String -> Value -> Maybe Value -> IORef VecStore -> IO Value
vecScheme env scheme f macc r = do
  st <- readIORef r
  n <- lenVec r
  case (vmJit env, jitCallable env scheme f) of
    (Just _, Just (g, ex)) | getEnvDebug -> putStrLn ("[jit-debug] " ++ scheme ++ " f=" ++ g ++ " extras=" ++ show (length ex) ++ " n=" ++ show n ++ " layout=" ++ maybe "?" (\(_, _, sg) -> sg) (layoutInfo st))
    (Just _, Nothing) | getEnvDebug -> putStrLn ("[jit-debug] " ++ scheme ++ " fn not JIT-callable: " ++ render f)
    _ -> pure ()
  jitted <- case (vmJit env, jitCallable env scheme f, layoutInfo st, accTyOf macc) of
    (Just jc, Just (g, extras), Just (scalar, ks, sig), Just aty0)
      | n >= jitThreshold ->
          compileVecScheme jc (vmCore env) scheme g scalar (map kindTy ks) sig (map snd extras) aty0 >>= \case
            Nothing -> pure Nothing
            Just (addr, accTy, retTy) -> fmap Just $ withColPtrs st $ \cols -> withFuelCell env $ \pfuel ->
              case scheme of
                "vecfold" -> do
                  let Just a0 = macc
                  bitsVal retTy <$> runVecFold addr pfuel (map fst extras) cols n (valBits accTy a0)
                "vecmap" -> do
                  (_, out) <- runVecMapFilter addr pfuel (map fst extras) cols n
                  if retTy == JI then vecFromInts out else vecFromNums (map b2d out)
                _ -> do
                  (_, idxs) <- runVecMapFilter addr pfuel (map fst extras) cols n
                  gatherRows r (map fromIntegral idxs)
    _ -> pure Nothing
  case jitted of
    Just v -> finish v
    Nothing -> interp n >>= finish
  where

    finish v = case scheme of
      "vecfold" -> pure (VData 4 0 [v, VVec r]) -- (acc, vector)
      _ -> pure v
    -- interpreted duals: reconstruct each row from the columns, apply f
    interp n = case scheme of
      "vecmap" -> do
        out <- newVec
        let VVec r' = out
        mapM_ (\i -> getVec r i >>= apply env f >>= pushVec r') [0 .. n - 1]
        pure out
      "vecfilter" -> do
        keep <- filterIdx 0 n []
        gatherRows r (reverse keep)
      "vecfold" -> do
        let Just z = macc
        foldGo z 0 n
      _ -> vmPanic ("unknown vec scheme " ++ scheme)
      where
        filterIdx i lim acc
          | i >= lim = pure acc
          | otherwise = do
              x <- getVec r i
              kv <- apply env f x
              let kept = case kv of
                    VData bt 1 [] | bt == boolT -> True
                    VData bt 0 [] | bt == boolT -> False
                    VInt k -> k /= 0
                    _ -> False
              filterIdx (i + 1) lim (if kept then i : acc else acc)
        foldGo acc i lim
          | i >= lim = pure acc
          | otherwise = do
              x <- getVec r i
              pf <- apply env f acc
              acc' <- apply env pf x
              foldGo acc' (i + 1) lim
