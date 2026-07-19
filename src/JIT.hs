{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Eta reduce" #-}

-- JIT.hs — LLVM ORC (LLJIT) tier for the Sol VM, via hand-rolled FFI to
-- the LLVM-C API (no llvm-hs available; one 10-line C shim for the
-- static-inline target init, everything else is plain foreign imports).
--
-- What gets JITted, per the design discussion: RECURSION SCHEMES ONLY
-- (map / filter / foldl), and only when the input list clears a length
-- threshold. The schemes are provably bounded by the list length, so they
-- need no preemption; fuel accounting is REIFIED anyway — the compiled
-- code decrements a fuel cell (passed by pointer) at every function entry,
-- the same contract the interpreter and the C runtime use, and the VM
-- reconciles the cell when the pure native call returns.
--
-- The element function is compiled from CORE (not bytecode), and the
-- codegen below is deliberately the bytecode compiler's twin: same
-- slot-per-value discipline, with LLVMBuild* where Bytecode.hs has emit.
-- CIf becomes alloca+store/br/load instead of Move/Jz — no phi nodes, so
-- the shape stays mechanistic.
--
-- Guards (fall back to the interpreter when any fails):
--   * every list element is an unboxed Int
--   * the element function is a saturated top-level supercombinator whose
--     call closure is arithmetic-only Core (ints, arith/cmp prims, if,
--     let, saturated calls to other such functions — recursion allowed,
--     fuel-counted)
--   * no partial applications, strings, or data construction inside
--
-- RC note: the specialized path is Int-only, so there is nothing to
-- refcount — the marshalled array is the builder->freeze boundary and the
-- result list is freshly built. A heap-value tier would reify incref/
-- decref the same way fuel is reified here.

module JIT where

import qualified Bytecode as B
import Control.Monad (foldM, forM, forM_, unless, when)
import Data.IORef
import Data.Int (Int64)
import Data.List (nub)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Foreign.C.String
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (allocaArray, withArrayLen)
import Foreign.Ptr
import Foreign.Storable
import Lang (Core (..), Name, Prog)
import System.Environment (lookupEnv)

-- ---- raw LLVM-C bindings ----------------------------------------------------

type LRef = Ptr () -- contexts, modules, builders, types, values, blocks, ...

foreign import ccall "sol_llvm_init" c_llvm_init :: IO Int

-- LLVM version seam (select with the `llvm22` cabal flag; default is 18):
--   18: a ThreadSafeContext owns its LLVMContext
--       (Create + ThreadSafeContextGetContext)
--   22: ThreadSafeContextGetContext was removed — create a plain
--       LLVMContext per module and wrap it at JIT-handoff time
--       (LLVMOrcCreateNewThreadSafeContextFromLLVMContext)
-- newModuleCtx returns the LLVMContext plus a deferred action producing
-- the ThreadSafeContext to hand the finished module to the JIT with.
#ifdef LLVM22
foreign import ccall "LLVMContextCreate" c_ctxCreate :: IO LRef

foreign import ccall "LLVMOrcCreateNewThreadSafeContextFromLLVMContext" c_tscFromCtx :: LRef -> IO LRef

newModuleCtx :: IO (LRef, IO LRef)
newModuleCtx = do
  ctx <- c_ctxCreate
  pure (ctx, c_tscFromCtx ctx)
#else
foreign import ccall "LLVMOrcCreateNewThreadSafeContext" c_tscCreate :: IO LRef

foreign import ccall "LLVMOrcThreadSafeContextGetContext" c_tscCtx :: LRef -> IO LRef

newModuleCtx :: IO (LRef, IO LRef)
newModuleCtx = do
  tsc <- c_tscCreate
  ctx <- c_tscCtx tsc
  pure (ctx, pure tsc)
#endif

foreign import ccall "LLVMOrcCreateNewThreadSafeModule" c_tsmCreate :: LRef -> LRef -> IO LRef

foreign import ccall "LLVMOrcCreateLLJIT" c_lljitCreate :: Ptr LRef -> LRef -> IO LRef

foreign import ccall "LLVMOrcLLJITGetMainJITDylib" c_lljitDylib :: LRef -> IO LRef

foreign import ccall "LLVMOrcLLJITAddLLVMIRModule" c_lljitAddModule :: LRef -> LRef -> LRef -> IO LRef

foreign import ccall "LLVMOrcLLJITLookup" c_lljitLookup :: LRef -> Ptr Int64 -> CString -> IO LRef

foreign import ccall "LLVMGetErrorMessage" c_errMsg :: LRef -> IO CString

foreign import ccall "LLVMModuleCreateWithNameInContext" c_modCreate :: CString -> LRef -> IO LRef

foreign import ccall "LLVMCreateBuilderInContext" c_builderCreate :: LRef -> IO LRef

foreign import ccall "LLVMDisposeBuilder" c_builderDispose :: LRef -> IO ()

foreign import ccall "LLVMInt64TypeInContext" c_i64 :: LRef -> IO LRef

foreign import ccall "LLVMPointerTypeInContext" c_ptrTy :: LRef -> Int -> IO LRef

foreign import ccall "LLVMFunctionType" c_fnTy :: LRef -> Ptr LRef -> Int -> Int -> IO LRef

foreign import ccall "LLVMAddFunction" c_addFn :: LRef -> CString -> LRef -> IO LRef

foreign import ccall "LLVMGetParam" c_param :: LRef -> Int -> IO LRef

foreign import ccall "LLVMAppendBasicBlockInContext" c_appendBB :: LRef -> LRef -> CString -> IO LRef

foreign import ccall "LLVMPositionBuilderAtEnd" c_positionAtEnd :: LRef -> LRef -> IO ()

foreign import ccall "LLVMGetInsertBlock" c_insertBlock :: LRef -> IO LRef

foreign import ccall "LLVMGetBasicBlockParent" c_bbParent :: LRef -> IO LRef

foreign import ccall "LLVMConstInt" c_constInt :: LRef -> Int64 -> Int -> IO LRef

foreign import ccall "LLVMBuildAdd" c_bAdd :: LRef -> LRef -> LRef -> CString -> IO LRef

foreign import ccall "LLVMBuildSub" c_bSub :: LRef -> LRef -> LRef -> CString -> IO LRef

foreign import ccall "LLVMBuildMul" c_bMul :: LRef -> LRef -> LRef -> CString -> IO LRef

foreign import ccall "LLVMBuildSDiv" c_bSDiv :: LRef -> LRef -> LRef -> CString -> IO LRef

foreign import ccall "LLVMBuildICmp" c_bICmp :: LRef -> Int -> LRef -> LRef -> CString -> IO LRef

foreign import ccall "LLVMBuildZExt" c_bZExt :: LRef -> LRef -> LRef -> CString -> IO LRef

foreign import ccall "LLVMBuildBr" c_bBr :: LRef -> LRef -> IO LRef

foreign import ccall "LLVMBuildCondBr" c_bCondBr :: LRef -> LRef -> LRef -> LRef -> IO LRef

foreign import ccall "LLVMBuildRet" c_bRet :: LRef -> LRef -> IO LRef

foreign import ccall "LLVMBuildAlloca" c_bAlloca :: LRef -> LRef -> CString -> IO LRef

foreign import ccall "LLVMBuildLoad2" c_bLoad :: LRef -> LRef -> LRef -> CString -> IO LRef

foreign import ccall "LLVMBuildStore" c_bStore :: LRef -> LRef -> LRef -> IO LRef

foreign import ccall "LLVMBuildGEP2" c_bGEP :: LRef -> LRef -> LRef -> Ptr LRef -> Int -> CString -> IO LRef

foreign import ccall "LLVMBuildCall2" c_bCall :: LRef -> LRef -> LRef -> Ptr LRef -> Int -> CString -> IO LRef

-- native drivers: map/filter shape and fold shape
type Drv4 = Ptr Int64 -> Ptr Int64 -> Int64 -> Ptr Int64 -> IO Int64

type DrvF = Ptr Int64 -> Ptr Int64 -> Int64 -> Int64 -> IO Int64

foreign import ccall "dynamic" mkDrv4 :: FunPtr Drv4 -> Drv4

foreign import ccall "dynamic" mkDrvF :: FunPtr DrvF -> DrvF

-- vec drivers with captured-scalar extras (partial application tier):
--   map/filter: i64 drv(fuel*, extras*, cols**, n, out*)
--   fold:       i64 drv(fuel*, extras*, cols**, n, acc0)
type Drv5 = Ptr Int64 -> Ptr Int64 -> Ptr Int64 -> Int64 -> Ptr Int64 -> IO Int64

type DrvF5 = Ptr Int64 -> Ptr Int64 -> Ptr Int64 -> Int64 -> Int64 -> IO Int64

foreign import ccall "dynamic" mkDrv5 :: FunPtr Drv5 -> Drv5

foreign import ccall "dynamic" mkDrvF5 :: FunPtr DrvF5 -> DrvF5

-- LLVMIntPredicate
pEQ, pNE, pSGT, pSGE, pSLT, pSLE :: Int
pEQ = 32
pNE = 33
pSGT = 38
pSGE = 39
pSLT = 40
pSLE = 41

data JitCtx = JitCtx
  { jcJit :: LRef,
    jcCache :: IORef (M.Map (String, Name) Int64), -- (scheme, fn) -> address
    jcCount :: IORef Int
  }

jitDebug :: String -> IO ()
jitDebug msg = do
  d <- lookupEnv "SOL_JIT_DEBUG"
  when (d == Just "1") (putStrLn msg)

checkErr :: String -> LRef -> IO Bool
checkErr what e
  | e == nullPtr = pure False
  | otherwise = do
      m <- c_errMsg e >>= peekCString
      putStrLn ("[jit] " ++ what ++ ": " ++ m)
      pure True

initJIT :: IO (Maybe JitCtx)
initJIT = do
  r <- c_llvm_init
  if r /= 0
    then putStrLn "[jit] native target init failed; JIT disabled" >> pure Nothing
    else do
      jitp <- alloca $ \p -> do
        e <- c_lljitCreate p nullPtr
        bad <- checkErr "LLJIT create" e
        if bad then pure nullPtr else peek p
      if jitp == nullPtr
        then pure Nothing
        else do
          cache <- newIORef M.empty
          cnt <- newIORef 0
          pure (Just (JitCtx jitp cache cnt))

-- ---- JITtability: arithmetic-only Core, closed over other such fns --------

-- Exhaustive bool matches desugar as
--   CIf (CTagEq bool True s) a (CIf (CTagEq bool False s) b (CErr "no match"))
-- The CErr tail is unreachable: when the inner CIf runs, the outer test already failed, so the complementary test must hold. Strip it, so `case c of True -> a | False -> b` is JITtable. Non-bool case tails (reachable) keep their CErr and stay interpreter-only.
simpCore :: Core -> Core
simpCore = go
  where
    go = \case
      CIf (CTagEq 1 v s) t (CErr _) -> go t `seq` goIf v s t
      CIf c t e -> CIf (go c) (go t) (go e)
      CApp a b -> CApp (go a) (go b)
      CLet x a b -> CLet x (go a) (go b)
      CMk t v fs -> CMk t v (map go fs)
      CTagEq t v e -> CTagEq t v (go e)
      CProj i e -> CProj i (go e)
      CLam ps e -> CLam ps (go e)
      other -> other
    goIf _ _ t = go t

-- transitive closure of top-level functions called from `root`
gatherFns :: Prog -> Name -> Maybe (M.Map Name ([Name], Core))
gatherFns prog root = go M.empty [root]
  where
    go acc [] = Just acc
    go acc (n : rest)
      | M.member n acc = go acc rest
      | otherwise = case M.lookup n prog of
          Nothing -> Nothing
          Just (ps, b) -> go (M.insert n (ps, b) acc) (rest ++ calledFns ps b)
    calledFns ps b = nub [g | g <- callsIn b, g `notElem` ps, M.member g prog]
    callsIn = \case
      CVar v -> [v]
      CApp a b -> callsIn a ++ callsIn b
      CLet x a b -> callsIn a ++ filter (/= x) (callsIn b)
      CIf c t e -> callsIn c ++ callsIn t ++ callsIn e
      CMk _ _ fs -> concatMap callsIn fs
      CTagEq _ _ e -> callsIn e
      CProj _ e -> callsIn e
      CLam ps e -> filter (`notElem` ps) (callsIn e)
      _ -> []

-- can this Core body run as pure i64 arithmetic?
jitOK :: M.Map Name Int -> [Name] -> Core -> Bool
jitOK fnAr = ok
  where
    ok locals = \case
      CInt _ -> True
      CVar v -> v `elem` locals || M.lookup v fnAr == Just 0
      CLet x a b -> ok locals a && ok (x : locals) b
      CIf c t e -> ok locals c && ok locals t && ok locals e
      CTagEq 1 v e | v <= 1 -> ok locals e -- bool test: (e != 0) / (e == 0)
      e@CApp {} ->
        let (h, args) = B.spine e
         in case h of
              CVar g
                | g `notElem` locals, M.member g B.arithOps, length args == 2 -> all (ok locals) args
                | g `notElem` locals, Just ar <- M.lookup g fnAr, ar == length args -> all (ok locals) args
              _ -> False
      _ -> False -- strings, data construction, lambdas, errors: interpreter's job

checkAll :: M.Map Name ([Name], Core) -> Maybe (M.Map Name ([Name], Core))
checkAll cl =
  let ars = M.map (length . fst) cl
   in if all (uncurry (jitOK ars)) (M.elems cl) then Just cl else Nothing

-- ---- codegen ---------------------------------------------------------------

-- Need to deal with LLVM IR

data CG = CG {cgB :: LRef, cgCtx :: LRef, cgI64 :: LRef, cgFns :: M.Map Name (LRef, LRef)}

nm :: String -> (CString -> IO a) -> IO a
nm = withCString

zero64, one64 :: CG -> IO LRef
zero64 cg = c_constInt (cgI64 cg) 0 0
one64 cg = c_constInt (cgI64 cg) 1 0

-- every Sol function becomes: i64 f(ptr fuel, i64 a1, ..., i64 an) with a reified fuel decrement at entry — the compiler-inserted safepoint, carried into native code. symbols are prefixed per compilation unit: two schemes sharing helpers (e.g. every gradient fold pulling in fix.fmul) must not collide in the JITDylib; internal calls go through handles, so only symbols need this
declareFn :: CG -> LRef -> LRef -> String -> Name -> Int -> IO (LRef, LRef)
declareFn cg md ptrTy pre n ar = do
  let argTys = ptrTy : replicate ar (cgI64 cg)
  fty <- withArrayLen argTys $ \len p -> c_fnTy (cgI64 cg) p len 0
  f <- nm (pre ++ mangle n) $ \s -> c_addFn md s fty
  pure (f, fty)

mangle :: Name -> String
mangle = map (\c -> if c `elem` ['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'] then c else '_')

fuelTickIR :: CG -> LRef -> IO ()
fuelTickIR cg fuel = do
  f <- nm "f" $ c_bLoad (cgB cg) (cgI64 cg) fuel
  o <- one64 cg
  f' <- nm "f1" $ c_bSub (cgB cg) f o
  _ <- c_bStore (cgB cg) f' fuel
  pure ()

defineFn :: CG -> ([Name], Core) -> LRef -> IO ()
defineFn cg (ps, body) f = do
  bb <- nm "entry" $ c_appendBB (cgCtx cg) f
  c_positionAtEnd (cgB cg) bb
  fuel <- c_param f 0
  fuelTickIR cg fuel
  env0 <- forM (zip ps [1 ..]) $ \(p, i) -> (,) p <$> c_param f i
  r <- cgExpr cg fuel (M.fromList env0) body
  _ <- c_bRet (cgB cg) r
  pure ()

cgExpr :: CG -> LRef -> M.Map Name LRef -> Core -> IO LRef
cgExpr cg fuel = go
  where
    b = cgB cg
    i64 = cgI64 cg
    go env = \case
      CInt i -> c_constInt i64 (fromIntegral i) 0
      CVar x -> case M.lookup x env of
        Just v -> pure v
        Nothing -> case M.lookup x (cgFns cg) of
          Just (f, fty) -> callFn f fty [] -- 0-arity global
          Nothing -> error ("jit cgExpr: unbound " ++ x)
      CLet x a e -> do
        va <- go env a
        go (M.insert x va env) e
      CIf c t e -> do
        -- the bytecode compiler's Move/Jz pattern, spelled alloca/store/br
        res <- nm "ifres" $ c_bAlloca b i64
        vc <- go env c
        z <- zero64 cg
        cond <- nm "cond" $ c_bICmp b pNE vc z
        fn <- c_insertBlock b >>= c_bbParent
        bbT <- nm "then" $ c_appendBB (cgCtx cg) fn
        bbE <- nm "else" $ c_appendBB (cgCtx cg) fn
        bbM <- nm "merge" $ c_appendBB (cgCtx cg) fn
        _ <- c_bCondBr b cond bbT bbE
        c_positionAtEnd b bbT
        vt <- go env t
        _ <- c_bStore b vt res
        _ <- c_bBr b bbM
        c_positionAtEnd b bbE
        ve <- go env e
        _ <- c_bStore b ve res
        _ <- c_bBr b bbM
        c_positionAtEnd b bbM
        nm "ifv" $ c_bLoad b i64 res
      CTagEq 1 v e -> do
        ve <- go env e
        z <- zero64 cg
        c <- nm "bt" $ c_bICmp b (if v == 1 then pNE else pEQ) ve z
        nm "btz" $ c_bZExt b c i64
      e@CApp {} -> do
        let (h, args) = B.spine e
        case h of
          CVar g
            | Just op <- M.lookup g B.arithOps,
              [x, y] <- args,
              not (M.member g env) -> do
                vx <- go env x
                vy <- go env y
                arith op vx vy
            | not (M.member g env),
              Just (f, fty) <- M.lookup g (cgFns cg) -> do
                vs <- mapM (go env) args
                callFn f fty vs
          _ -> error "jit cgExpr: non-jittable application survived the guard"
      other -> error ("jit cgExpr: non-jittable node survived the guard: " ++ show other)

    callFn f fty vs = do
      let allArgs = fuel : vs
      withArrayLen allArgs $ \len p -> nm "call" $ c_bCall b fty f p len

    arith op x y = case op of
      B.OAdd -> nm "add" $ c_bAdd b x y
      B.OSub -> nm "sub" $ c_bSub b x y
      B.OMul -> nm "mul" $ c_bMul b x y
      B.ODiv -> nm "div" $ c_bSDiv b x y
      B.OLt -> cmp pSLT
      B.OLe -> cmp pSLE
      B.OGt -> cmp pSGT
      B.OGe -> cmp pSGE
      B.OEq -> cmp pEQ
      B.ONe -> cmp pNE
      where
        cmp p = do
          c <- nm "cmp" $ c_bICmp b p x y
          nm "cmpz" $ c_bZExt b c (cgI64 cg) -- bool reified as i64 0/1

-- ---- compile a (scheme, element fn) pair and hand back its address ---------

compileScheme :: JitCtx -> Prog -> String -> Name -> IO (Maybe Int64)
compileScheme jc prog scheme root = do
  cache <- readIORef (jcCache jc)
  case M.lookup (scheme, root) cache of
    Just addr -> pure (Just addr)
    Nothing -> case fmap (M.map (fmap simpCore)) (gatherFns prog root) >>= checkAll of
      Nothing -> pure Nothing
      Just closure -> do
        k <- atomicModifyIORef' (jcCount jc) (\c -> (c + 1, c))
        let sym = "sol_" ++ scheme ++ "_" ++ mangle root ++ "_" ++ show k
        -- each compiled module gets its own context; the deferred action
        -- wraps it into a ThreadSafeContext at JIT-handoff (see the CPP
        -- seam at the foreign imports for the 18-vs-22 difference)
        (ctx, mkTsc) <- newModuleCtx
        md <- nm sym $ \s -> c_modCreate s ctx
        b <- c_builderCreate ctx
        i64 <- c_i64 ctx
        ptrTy <- c_ptrTy ctx 0
        let cg0 = CG b ctx i64 M.empty
        -- declare all closure fns first (mutual recursion), then define
        decls <- M.fromList <$> forM (M.toList closure) (\(n, (ps, _)) -> (,) n <$> declareFn cg0 md ptrTy (sym ++ "_") n (length ps))
        let cg = cg0 {cgFns = decls}
        forM_ (M.toList closure) $ \(n, def) -> defineFn cg def (fst (decls M.! n))
        let Just (ps, _) = M.lookup root closure
        buildDriver2 cg md ptrTy scheme sym (decls M.! root) (length ps)
        c_builderDispose b
        tsc <- mkTsc
        tsm <- c_tsmCreate md tsc
        dylib <- c_lljitDylib (jcJit jc)
        e <- c_lljitAddModule (jcJit jc) dylib tsm
        bad <- checkErr "add module" e
        if bad
          then pure Nothing
          else do
            addr <- alloca $ \p -> do
              e2 <- nm sym $ c_lljitLookup (jcJit jc) p
              bad2 <- checkErr "lookup" e2
              if bad2 then pure 0 else peek p
            if addr == 0
              then pure Nothing
              else do
                putStrLn ("[jit] compiled " ++ scheme ++ "<" ++ root ++ "> (+" ++ show (M.size closure) ++ " fn(s), fuel reified)")
                atomicModifyIORef' (jcCache jc) (\m -> (M.insert (scheme, root) addr m, ()))
                pure (Just addr)

-- buildDriver rewritten with fuel threaded properly (see callE note above)
buildDriver2 :: CG -> LRef -> LRef -> String -> String -> (LRef, LRef) -> Int -> IO ()
buildDriver2 cg md ptrTy scheme sym (ef, efTy) fAr = do
  let i64 = cgI64 cg
      b = cgB cg
      isFold = scheme == "foldl"
      argTys = if isFold then [ptrTy, ptrTy, i64, i64] else [ptrTy, ptrTy, i64, ptrTy]
  dty <- withArrayLen argTys $ \len p -> c_fnTy i64 p len 0
  drv <- nm sym $ \s -> c_addFn md s dty
  entry <- nm "entry" $ c_appendBB (cgCtx cg) drv
  bbCond <- nm "cond" $ c_appendBB (cgCtx cg) drv
  bbBody <- nm "body" $ c_appendBB (cgCtx cg) drv
  bbExit <- nm "exit" $ c_appendBB (cgCtx cg) drv
  fuel <- c_param drv 0
  pin <- c_param drv 1
  n <- c_param drv 2
  p3 <- c_param drv 3
  c_positionAtEnd b entry
  z <- c_constInt i64 0 0
  o <- c_constInt i64 1 0
  iA <- nm "i" $ c_bAlloca b i64
  accA <- nm "acc" $ c_bAlloca b i64
  _ <- c_bStore b z iA
  _ <- c_bStore b (if isFold then p3 else z) accA
  _ <- c_bBr b bbCond
  c_positionAtEnd b bbCond
  iv <- nm "iv" $ c_bLoad b i64 iA
  more <- nm "more" $ c_bICmp b pSLT iv n
  _ <- c_bCondBr b more bbBody bbExit
  c_positionAtEnd b bbBody
  px <- withArrayLen [iv] $ \len p -> nm "px" $ c_bGEP b i64 pin p len
  x <- nm "x" $ c_bLoad b i64 px
  let callE vs = withArrayLen (fuel : vs) $ \len p -> nm "fx" $ c_bCall b efTy ef p len
      bump = do
        i' <- nm "i1" $ c_bAdd b iv o
        _ <- c_bStore b i' iA
        _ <- c_bBr b bbCond
        pure ()
  case scheme of
    "map" -> do
      r <- callE [x]
      po <- withArrayLen [iv] $ \len p -> nm "po" $ c_bGEP b i64 p3 p len
      _ <- c_bStore b r po
      bump
    "filter" -> do
      r <- callE [x]
      keep <- nm "keep" $ c_bICmp b pNE r z
      bbKeep <- nm "keepbb" $ c_appendBB (cgCtx cg) drv
      bbCont <- nm "cont" $ c_appendBB (cgCtx cg) drv
      _ <- c_bCondBr b keep bbKeep bbCont
      c_positionAtEnd b bbKeep
      k <- nm "k" $ c_bLoad b i64 accA
      po <- withArrayLen [k] $ \len p -> nm "po" $ c_bGEP b i64 p3 p len
      _ <- c_bStore b x po
      k' <- nm "k1" $ c_bAdd b k o
      _ <- c_bStore b k' accA
      _ <- c_bBr b bbCont
      c_positionAtEnd b bbCont
      bump
    "foldl" -> do
      acc <- nm "accv" $ c_bLoad b i64 accA
      r <- callE [acc, x]
      _ <- c_bStore b r accA
      bump
    _ -> error ("unknown scheme " ++ scheme)
  c_positionAtEnd b bbExit
  out <- if scheme == "map" then pure n else nm "res" $ c_bLoad b i64 accA
  _ <- c_bRet b out
  pure ()

-- ---- native invocation (fuel cell reconciled by the caller/VM) -------------

runMapFilter :: Int64 -> Ptr Int64 -> [Int64] -> IO (Int64, [Int64])
runMapFilter addr pfuel xs = do
  let f = mkDrv4 (castPtrToFunPtr (intPtrToPtr (fromIntegral addr)))
  withArrayLen xs $ \n pin ->
    allocaArr n $ \pout -> do
      k <- f pfuel pin (fromIntegral n) pout
      out <- mapM (peekElemOff pout) [0 .. fromIntegral k - 1]
      pure (k, out)
  where
    allocaArr = allocaArray

runFold :: Int64 -> Ptr Int64 -> Int64 -> [Int64] -> IO Int64
runFold addr pfuel acc0 xs = do
  let f = mkDrvF (castPtrToFunPtr (intPtrToPtr (fromIntegral addr)))
  withArrayLen xs $ \n pin -> f pfuel pin (fromIntegral n) acc0

-- ---- Vector (SoA) tier ------------------------------------------------------
--
-- The DUALIZATION from the design discussion: an element function like
--   fn student -> student.age + 1
-- compiles to (conceptually)
--   fn students i -> students.ages ! i + 1
-- concretely: i64 f(ptr fuel, ptr cols, i64 i) where cols is an array of
-- raw column base pointers lent by the linear vector, and every
-- CProj k (CVar student) becomes  load (cols[k])[i].
--
-- All drivers take the same (fuel, cols, n, out/acc) shape as the list
-- drivers, so the dynamic FFI wrappers are reused unchanged. The filter
-- driver emits KEPT ROW INDICES; the VM gathers full rows (including boxed
-- columns) from them — natively computed predicate, Haskell-side row move.

-- can this body run as a dual over the given layout? The elem param — or any let-alias of it (the clause compiler rebinds params: CLet p (CVar a1_k)) — may ONLY appear as CProj onto an int column (SoA) or bare (scalar int).
jitOKVec :: M.Map Name Int -> Bool -> [Bool] -> Name -> [Name] -> Core -> Bool
jitOKVec fnAr scalar intCols elemP0 locals0 = ok (S.singleton elemP0) locals0
  where
    ok es locals = \case
      CInt _ -> True
      CVar v | S.member v es -> scalar && intCols == [True]
      CVar v -> v `elem` locals || M.lookup v fnAr == Just 0
      CProj k (CVar v) | S.member v es -> not scalar && k < length intCols && intCols !! k
      CLet x (CVar v) b | S.member v es -> ok (S.insert x es) locals b -- alias
      CLet x a b -> ok es locals a && ok (S.delete x es) (x : locals) b
      CIf c t e -> ok es locals c && ok es locals t && ok es locals e
      CTagEq 1 v e | v <= 1 -> ok es locals e -- bool test as int compare
      e@CApp {} ->
        let (h, args) = B.spine e
         in case h of
              CVar g
                | not (S.member g es), g `notElem` locals, M.member g B.arithOps, length args == 2 -> all (ok es locals) args
                | not (S.member g es), g `notElem` locals, Just ar <- M.lookup g fnAr, ar == length args -> all (ok es locals) args
              _ -> False
      _ -> False

data VecAccess = VecAccess
  { vaParam :: Name, -- the Sol-level element parameter (aliases tracked in cgExprV)
    vaScalar :: Bool,
    vaCols :: LRef, -- i64** cols
    vaIdx :: LRef, -- current row index
    vaPtrTy :: LRef
  }

-- load (cols[k])[idx]
loadColAt :: CG -> VecAccess -> Int -> IO LRef
loadColAt cg va k = do
  let b = cgB cg
      i64 = cgI64 cg
  ki <- c_constInt i64 (fromIntegral k) 0
  pk <- withArrayLen [ki] $ \len p -> nm "pk" $ c_bGEP b (vaPtrTy va) (vaCols va) p len
  base <- nm "colbase" $ c_bLoad b (vaPtrTy va) pk
  pe <- withArrayLen [vaIdx va] $ \len p -> nm "pe" $ c_bGEP b i64 base p len
  nm "colv" $ c_bLoad b i64 pe

-- cgExpr with the dual hook: the element param (and its let-aliases) resolves to column loads
cgExprV :: CG -> LRef -> Maybe VecAccess -> M.Map Name LRef -> Core -> IO LRef
cgExprV cg fuel mva env0 e0 = go (maybe S.empty (S.singleton . vaParam) mva) env0 e0
  where
    b = cgB cg
    i64 = cgI64 cg
    go es env = \case
      CInt i -> c_constInt i64 (fromIntegral i) 0
      CVar x
        | Just va <- mva, S.member x es -> loadColAt cg va 0 -- scalar layout
        | otherwise -> case M.lookup x env of
            Just v -> pure v
            Nothing -> case M.lookup x (cgFns cg) of
              Just (f, fty) -> callFn f fty []
              Nothing -> error ("jit cgExprV: unbound " ++ x)
      CProj k (CVar x)
        | Just va <- mva, S.member x es -> loadColAt cg va k
      CLet x (CVar v) e | S.member v es -> go (S.insert x es) env e -- alias
      CLet x a e -> do
        va <- go es env a
        go (S.delete x es) (M.insert x va env) e
      CIf c t e -> do
        res <- nm "ifres" $ c_bAlloca b i64
        vc <- go es env c
        z <- c_constInt i64 0 0
        cond <- nm "cond" $ c_bICmp b pNE vc z
        fn <- c_insertBlock b >>= c_bbParent
        bbT <- nm "then" $ c_appendBB (cgCtx cg) fn
        bbE <- nm "else" $ c_appendBB (cgCtx cg) fn
        bbM <- nm "merge" $ c_appendBB (cgCtx cg) fn
        _ <- c_bCondBr b cond bbT bbE
        c_positionAtEnd b bbT
        vt <- go es env t
        _ <- c_bStore b vt res
        _ <- c_bBr b bbM
        c_positionAtEnd b bbE
        ve <- go es env e
        _ <- c_bStore b ve res
        _ <- c_bBr b bbM
        c_positionAtEnd b bbM
        nm "ifv" $ c_bLoad b i64 res
      CTagEq 1 v e -> do
        ve <- go es env e
        z <- c_constInt i64 0 0
        c <- nm "bt" $ c_bICmp b (if v == 1 then pNE else pEQ) ve z
        nm "btz" $ c_bZExt b c i64
      e@CApp {} -> do
        let (h, args) = B.spine e
        case h of
          CVar g
            | Just op <- M.lookup g B.arithOps,
              [x, y] <- args,
              not (M.member g env),
              not (S.member g es) -> do
                vx <- go es env x
                vy <- go es env y
                cgArith cg op vx vy
            | not (M.member g env),
              Just (f, fty) <- M.lookup g (cgFns cg) -> do
                vs <- mapM (go es env) args
                callFn f fty vs
          _ -> error "jit cgExprV: non-jittable application survived the guard"
      other -> error ("jit cgExprV: non-jittable node survived the guard: " ++ show other)
    callFn f fty vs = withArrayLen (fuel : vs) $ \len p -> nm "call" $ c_bCall b fty f p len

cgArith :: CG -> B.ArithOp -> LRef -> LRef -> IO LRef
cgArith cg op x y = case op of
  B.OAdd -> nm "add" $ c_bAdd b x y
  B.OSub -> nm "sub" $ c_bSub b x y
  B.OMul -> nm "mul" $ c_bMul b x y
  B.ODiv -> nm "div" $ c_bSDiv b x y
  B.OLt -> cmp pSLT
  B.OLe -> cmp pSLE
  B.OGt -> cmp pSGT
  B.OGe -> cmp pSGE
  B.OEq -> cmp pEQ
  B.ONe -> cmp pNE
  where
    b = cgB cg
    cmp p = do
      c <- nm "cmp" $ c_bICmp b p x y
      nm "cmpz" $ c_bZExt b c (cgI64 cg)

-- compile a (vec scheme, element fn, layout, #captured-ints) tuple. Partial application: `Vec.fold (grad w1 w2 b) 0 v` captures w1 w2 b as leading i64 params of the dual, delivered through the driver's extras array at CALL time — one compilation serves every parameter value, which is what makes JITted gradient-descent epochs possible.
compileVecScheme :: JitCtx -> Prog -> String -> Name -> Bool -> [Bool] -> String -> Int -> IO (Maybe Int64)
compileVecScheme jc prog scheme root scalar intCols laySig nEx = do
  let key = (scheme ++ "|" ++ laySig ++ "|" ++ show nEx, root)
  cache <- readIORef (jcCache jc)
  case M.lookup key cache of
    Just addr -> pure (Just addr)
    Nothing -> case fmap (M.map (fmap simpCore)) (gatherFns prog root) of
      Nothing -> jitDebug ("[jit-debug] " ++ root ++ ": gather failed (call outside prog?)") >> pure Nothing
      Just closure -> do
        let ars = M.map (length . fst) closure
            Just (rootPs, rootBody) = M.lookup root closure
            helpers = M.delete root closure
            needed = nEx + (if scheme == "vecfold" then 2 else 1)
            exPs = take nEx rootPs
            (accP, elemP) = case (scheme, drop nEx rootPs) of
              ("vecfold", [a, x]) -> (Just a, x)
              (_, [x]) -> (Nothing, x)
              _ -> (Nothing, "?")
            helpersOK = all (uncurry (jitOK ars)) (M.elems helpers)
            rootOK =
              length rootPs == needed
                && jitOKVec ars scalar intCols elemP (exPs ++ maybe [] pure accP) rootBody
        if not (helpersOK && rootOK)
          then do
            jitDebug ("[jit-debug] " ++ root ++ ": helpersOK=" ++ show helpersOK ++ " rootOK=" ++ show rootOK ++ " closure=" ++ show (M.keys closure))
            pure Nothing
          else do
            k <- atomicModifyIORef' (jcCount jc) (\c -> (c + 1, c))
            let sym = "sol_" ++ scheme ++ "_" ++ mangle root ++ "_" ++ show k
            -- LLVM 22+: fresh context per module (see compileScheme)
            (ctx, mkTsc) <- newModuleCtx
            md <- nm sym $ \s -> c_modCreate s ctx
            b <- c_builderCreate ctx
            i64 <- c_i64 ctx
            ptrTy <- c_ptrTy ctx 0
            let cg0 = CG b ctx i64 M.empty
            -- helpers keep the normal (fuel, i64 args) shape
            hdecls <- M.fromList <$> forM (M.toList helpers) (\(n, (ps, _)) -> (,) n <$> declareFn cg0 md ptrTy (sym ++ "_") n (length ps))
            -- the DUAL root: i64 f(fuel*, extras..., [acc,] cols**, idx)
            let dualArgTys = [ptrTy] ++ replicate nEx i64 ++ [i64 | scheme == "vecfold"] ++ [ptrTy, i64]
            dualTy <- withArrayLen dualArgTys $ \len p -> c_fnTy i64 p len 0
            dual <- nm (sym ++ "_f") $ \s -> c_addFn md s dualTy
            let cg = cg0 {cgFns = hdecls}
            forM_ (M.toList helpers) $ \(n, def) -> defineFn cg def (fst (hdecls M.! n))
            -- define the dual body
            bb <- nm "entry" $ c_appendBB ctx dual
            c_positionAtEnd b bb
            fuel <- c_param dual 0
            fuelTickIR cg fuel
            exVals <- mapM (\i -> c_param dual (1 + i)) [0 .. nEx - 1]
            (env0, colsP, idxP) <-
              if scheme == "vecfold"
                then do
                  acc <- c_param dual (1 + nEx)
                  cs <- c_param dual (2 + nEx)
                  ix <- c_param dual (3 + nEx)
                  pure (M.fromList (zip exPs exVals ++ [(head (drop nEx rootPs), acc)]), cs, ix)
                else do
                  cs <- c_param dual (1 + nEx)
                  ix <- c_param dual (2 + nEx)
                  pure (M.fromList (zip exPs exVals), cs, ix)
            let va = VecAccess elemP scalar colsP idxP ptrTy
            r <- cgExprV cg fuel (Just va) env0 rootBody
            _ <- c_bRet b r
            buildVecDriver cg md ptrTy scheme sym (dual, dualTy) nEx
            c_builderDispose b
            tsc <- mkTsc
            tsm <- c_tsmCreate md tsc
            dylib <- c_lljitDylib (jcJit jc)
            e <- c_lljitAddModule (jcJit jc) dylib tsm
            bad <- checkErr "add module" e
            if bad
              then pure Nothing
              else do
                addr <- alloca $ \p -> do
                  e2 <- nm sym $ c_lljitLookup (jcJit jc) p
                  bad2 <- checkErr "lookup" e2
                  if bad2 then pure 0 else peek p
                if addr == 0
                  then pure Nothing
                  else do
                    putStrLn ("[jit] compiled " ++ scheme ++ "<" ++ root ++ "> over SoA layout " ++ laySig ++ (if nEx > 0 then " + " ++ show nEx ++ " captured scalar(s)" else "") ++ " (dualized, fuel reified)")
                    atomicModifyIORef' (jcCache jc) (\m -> (M.insert key addr m, ()))
                    pure (Just addr)

-- same loop skeletons as the list drivers, cols instead of a data pointer. vecfilter writes KEPT INDICES to out (the VM gathers rows from them).
buildVecDriver :: CG -> LRef -> LRef -> String -> String -> (LRef, LRef) -> Int -> IO ()
buildVecDriver cg md ptrTy scheme sym (ef, efTy) nEx = do
  let i64 = cgI64 cg
      b = cgB cg
      isFold = scheme == "vecfold"
      -- fuel*, extras*, cols**, n, out*/acc0
      argTys = if isFold then [ptrTy, ptrTy, ptrTy, i64, i64] else [ptrTy, ptrTy, ptrTy, i64, ptrTy]
  dty <- withArrayLen argTys $ \len p -> c_fnTy i64 p len 0
  drv <- nm sym $ \s -> c_addFn md s dty
  entry <- nm "entry" $ c_appendBB (cgCtx cg) drv
  bbCond <- nm "cond" $ c_appendBB (cgCtx cg) drv
  bbBody <- nm "body" $ c_appendBB (cgCtx cg) drv
  bbExit <- nm "exit" $ c_appendBB (cgCtx cg) drv
  fuel <- c_param drv 0
  extras <- c_param drv 1
  cols <- c_param drv 2
  n <- c_param drv 3
  p4 <- c_param drv 4
  c_positionAtEnd b entry
  z <- c_constInt i64 0 0
  o <- c_constInt i64 1 0
  -- captured scalars: loaded once, passed to every dual call
  eVals <-
    mapM
      ( \i -> do
          ki <- c_constInt i64 (fromIntegral i) 0
          pe <- withArrayLen [ki] $ \len p -> nm "pex" $ c_bGEP b i64 extras p len
          nm "ex" $ c_bLoad b i64 pe
      )
      [0 .. nEx - 1]
  iA <- nm "i" $ c_bAlloca b i64
  accA <- nm "acc" $ c_bAlloca b i64
  _ <- c_bStore b z iA
  _ <- c_bStore b (if isFold then p4 else z) accA
  _ <- c_bBr b bbCond
  c_positionAtEnd b bbCond
  iv <- nm "iv" $ c_bLoad b i64 iA
  more <- nm "more" $ c_bICmp b pSLT iv n
  _ <- c_bCondBr b more bbBody bbExit
  c_positionAtEnd b bbBody
  let callE vs = withArrayLen (fuel : eVals ++ vs) $ \len p -> nm "fx" $ c_bCall b efTy ef p len
      bump = do
        i' <- nm "i1" $ c_bAdd b iv o
        _ <- c_bStore b i' iA
        _ <- c_bBr b bbCond
        pure ()
  case scheme of
    "vecmap" -> do
      r <- callE [cols, iv]
      po <- withArrayLen [iv] $ \len p -> nm "po" $ c_bGEP b i64 p4 p len
      _ <- c_bStore b r po
      bump
    "vecfilter" -> do
      r <- callE [cols, iv]
      keep <- nm "keep" $ c_bICmp b pNE r z
      bbKeep <- nm "keepbb" $ c_appendBB (cgCtx cg) drv
      bbCont <- nm "cont" $ c_appendBB (cgCtx cg) drv
      _ <- c_bCondBr b keep bbKeep bbCont
      c_positionAtEnd b bbKeep
      k <- nm "k" $ c_bLoad b i64 accA
      po <- withArrayLen [k] $ \len p -> nm "po" $ c_bGEP b i64 p4 p len
      _ <- c_bStore b iv po -- the row INDEX, not the value
      k' <- nm "k1" $ c_bAdd b k o
      _ <- c_bStore b k' accA
      _ <- c_bBr b bbCont
      c_positionAtEnd b bbCont
      bump
    "vecfold" -> do
      acc <- nm "accv" $ c_bLoad b i64 accA
      r <- callE [acc, cols, iv]
      _ <- c_bStore b r accA
      bump
    _ -> error ("unknown vec scheme " ++ scheme)
  c_positionAtEnd b bbExit
  out <- if scheme == "vecmap" then pure n else nm "res" $ c_bLoad b i64 accA
  _ <- c_bRet b out
  pure ()

-- invoke a vec driver: cols is the lent column-pointer array; extras are the captured scalars of a partially-applied element function
runVecMapFilter :: Int64 -> Ptr Int64 -> [Int64] -> Ptr (Ptr Int64) -> Int -> IO (Int64, [Int64])
runVecMapFilter addr pfuel extras cols n = do
  let f = mkDrv5 (castPtrToFunPtr (intPtrToPtr (fromIntegral addr)))
  withArrayLen (extras ++ [0]) $ \_ pex ->
    allocaArray n $ \pout -> do
      k <- f pfuel pex (castPtr cols) (fromIntegral n) pout
      out <- mapM (peekElemOff pout) [0 .. fromIntegral k - 1]
      pure (k, out)

runVecFold :: Int64 -> Ptr Int64 -> [Int64] -> Ptr (Ptr Int64) -> Int -> Int64 -> IO Int64
runVecFold addr pfuel extras cols n acc0 = do
  let f = mkDrvF5 (castPtrToFunPtr (intPtrToPtr (fromIntegral addr)))
  withArrayLen (extras ++ [0]) $ \_ pex -> f pfuel pex (castPtr cols) (fromIntegral n) acc0
