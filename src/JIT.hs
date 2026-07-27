{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}
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

-- the f64 tier: double type/ops/casts for the typed dual
foreign import ccall "LLVMDoubleTypeInContext" c_f64 :: LRef -> IO LRef

foreign import ccall "LLVMConstReal" c_constReal :: LRef -> Double -> IO LRef

foreign import ccall "LLVMBuildFAdd" c_bFAdd :: LRef -> LRef -> LRef -> CString -> IO LRef

foreign import ccall "LLVMBuildFSub" c_bFSub :: LRef -> LRef -> LRef -> CString -> IO LRef

foreign import ccall "LLVMBuildFMul" c_bFMul :: LRef -> LRef -> LRef -> CString -> IO LRef

foreign import ccall "LLVMBuildFDiv" c_bFDiv :: LRef -> LRef -> LRef -> CString -> IO LRef

foreign import ccall "LLVMBuildFCmp" c_bFCmp :: LRef -> Int -> LRef -> LRef -> CString -> IO LRef

foreign import ccall "LLVMBuildSIToFP" c_bSIToFP :: LRef -> LRef -> LRef -> CString -> IO LRef

foreign import ccall "LLVMBuildFPToSI" c_bFPToSI :: LRef -> LRef -> LRef -> CString -> IO LRef

foreign import ccall "LLVMBuildBitCast" c_bBitCast :: LRef -> LRef -> LRef -> CString -> IO LRef

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

-- LLVMRealPredicate (ordered)
rOEQ, rOGT, rOGE, rOLT, rOLE, rONE :: Int
rOEQ = 1
rOGT = 2
rOGE = 3
rOLT = 4
rOLE = 5
rONE = 6

-- ---- the type lattice of the typed tier -------------------------------------
--
-- Julia-style specialization needs to know, statically, which slots hold
-- exact Ints and which hold inexact Numerics — because ONE operation
-- differs between them: `/` is quot on two Ints and true division when a
-- Numeric touches it. Three points:
--
--   JI — provably always VInt at runtime            (i64 slot, sdiv)
--   JD — provably always VNum at runtime            (f64 slot, fdiv)
--   JW — widened: could be either at a given moment (f64 slot, holding
--        the PROMOTED value where the interpreter may still hold a VInt)
--
-- JW is sound for +,-,*, comparisons, and the Num.* prims — the
-- interpreter promotes on contact and lands on the same doubles — but a
-- `/` whose operands are int-ambiguous (JW with no JD partner) cannot be
-- compiled faithfully, and a JW value escaping to the interpreter would
-- have the wrong TYPE there. Both cases bail to the interpreter.

-- JB is the inference-only bottom: the type of an in-flight recursive
-- return before the fixpoint converges (and of code that never returns).
-- It is the identity for joins and promotions, so optimistic iteration
-- reaches the LEAST fixed point -- without it, a recursive call would
-- poison `join` into JW and stick there.
data JTy = JB | JI | JD | JW deriving (Eq, Show, Ord)

joinT :: JTy -> JTy -> JTy
joinT a b | a == b = a
joinT JB t = t
joinT t JB = t
joinT _ _ = JW

tyChar :: JTy -> Char
tyChar JB = '_'
tyChar JI = 'i'
tyChar JD = 'd'
tyChar JW = 'w'

isF :: JTy -> Bool
isF t = t == JD || t == JW

-- the Numeric HAL prims the typed tier compiles as LLVM intrinsics:
-- (name, arity, arg promotion target, result type)
numPrims :: M.Map Name (Int, JTy)
numPrims =
  M.fromList
    [ ("Num.div", (2, JD)), -- fdiv, always inexact
      ("Num.sqrt", (1, JD)), -- llvm.sqrt.f64
      ("Num.floor", (1, JI)), -- llvm.floor.f64 + fptosi
      ("Num.round", (1, JI)) -- llvm.rint.f64 (nearest-even = Haskell round) + fptosi
    ]

data JitCtx = JitCtx
  { jcJit :: LRef,
    jcCache :: IORef (M.Map (String, Name) (Int64, JTy, JTy)), -- (typed key, fn) -> (address, accTy, retTy)
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
                | g `notElem` locals, Just (npAr, _) <- M.lookup g numPrims, npAr == length args -> all (ok locals) args
                | g `notElem` locals, Just ar <- M.lookup g fnAr, ar == length args -> all (ok locals) args
              _ -> False
      _ -> False -- strings, data construction, lambdas, errors: interpreter's job

-- clause compilation introduces JOIN POINTS: `CLet j (f a1 .. ak) body`
-- binds a PARTIAL application that later saturates as `j extra..` — the
-- guard-fallback shape. The JIT has no closures, but when every use of j
-- saturates f, the binding inlines away into direct saturated calls.
-- Compiler-generated argument names are unique, so substitution is
-- capture-safe here.
satJoins :: M.Map Name Int -> Core -> Core
satJoins fnAr = go S.empty
  where
    go bs e = case e of
      CLet x a b
        | (CVar g, as) <- B.spine a,
          not (S.member g bs),
          Just ar <- M.lookup g fnAr,
          ar > length as,
          let miss = ar - length as,
          satOnly x miss b ->
            go bs (inline x (foldl CApp (CVar g) (map (go bs) as)) miss b)
      CLet x a b -> CLet x (go bs a) (go (S.insert x bs) b)
      ap@CApp {} ->
        let (h, as) = B.spine ap
         in foldl CApp (go bs h) (map (go bs) as)
      CIf c t el -> CIf (go bs c) (go bs t) (go bs el)
      CMk t v fs -> CMk t v (map (go bs) fs)
      CTagEq t v s -> CTagEq t v (go bs s)
      CProj i s -> CProj i (go bs s)
      CLam ps b -> CLam ps (go (foldr S.insert bs ps) b)
      other -> other
    -- every occurrence of x is the head of a spine with exactly `miss` args
    satOnly x miss = chk
      where
        chk = \case
          CVar v -> v /= x
          ap@CApp {} ->
            let (h, as) = B.spine ap
             in (case h of CVar v | v == x -> length as == miss; _ -> chk h) && all chk as
          CLet y a b -> chk a && (y == x || chk b)
          CIf c t el -> chk c && chk t && chk el
          CMk _ _ fs -> all chk fs
          CTagEq _ _ s -> chk s
          CProj _ s -> chk s
          CLam ps b -> x `elem` ps || chk b
          _ -> True
    inline x a miss = rw
      where
        rw = \case
          ap@CApp {} ->
            let (h, as) = B.spine ap
             in case h of
                  CVar v | v == x, length as == miss -> foldl CApp a (map rw as)
                  _ -> foldl CApp (rw h) (map rw as)
          CLet y r b -> CLet y (rw r) (if y == x then b else rw b)
          CIf c t el -> CIf (rw c) (rw t) (rw el)
          CMk t v fs -> CMk t v (map rw fs)
          CTagEq t v s -> CTagEq t v (rw s)
          CProj i s -> CProj i (rw s)
          CLam ps b -> CLam ps (if x `elem` ps then b else rw b)
          other -> other

-- simplify + saturate the whole closure (arities come from the closure itself)
prepClosure :: M.Map Name ([Name], Core) -> M.Map Name ([Name], Core)
prepClosure cl =
  let ars = M.map (length . fst) cl
   in M.map (fmap (satJoins ars . simpCore)) cl

checkAll :: M.Map Name ([Name], Core) -> Maybe (M.Map Name ([Name], Core))
checkAll cl =
  let ars = M.map (length . fst) cl
   in if all (uncurry (jitOK ars)) (M.elems cl) then Just cl else Nothing

-- ---- type inference (the "Julia-style" pass) --------------------------------
--
-- Per-CALLSITE specialization: a helper called with (JD, JI) and with
-- (JI, JI) becomes two LLVM functions. Variants are keyed by argument
-- types; return types live in a table iterated to a fixpoint (missing
-- entries read as JI — the optimistic bottom — and the recomputation is
-- capped, bailing on the pathological case). Inference returns Nothing
-- when a construct can't be compiled faithfully: `/` over int-ambiguous
-- (JW) operands, or a non-JI value in a boolean position.

type VKey = (Name, [JTy])

-- arithmetic result type: JD is contagious and definite; JW is contagious
-- and ambiguous; JI only survives a pure-int pair. NOT joinT: JD+JI is
-- definitely inexact (JD), while joinT would say "either" (JW).
promoT :: JTy -> JTy -> JTy
promoT JB t = t
promoT t JB = t
promoT a b
  | a == JD || b == JD = JD
  | a == JW || b == JW = JW
  | otherwise = JI

-- type one Core body; collects demanded callee variants
tyExpr :: M.Map VKey JTy -> M.Map Name ([Name], Core) -> M.Map Name JTy -> Core -> Maybe (JTy, [VKey])
tyExpr sigs cl = goT
  where
    goT env e = case e of
      CInt _ -> Just (JI, [])
      CVar v -> case M.lookup v env of
        Just t -> Just (t, [])
        Nothing
          | M.member v cl -> Just (M.findWithDefault JB (v, []) sigs, [(v, [])])
          | otherwise -> Nothing
      CLet x a b -> do
        (ta, d1) <- goT env a
        (tb, d2) <- goT (M.insert x ta env) b
        pure (tb, d1 ++ d2)
      CIf c t e2 -> do
        (tc, d0) <- goT env c
        if isF tc
          then Nothing -- a non-int in boolean position: interpreter's job
          else do
            (tt, d1) <- goT env t
            (te, d2) <- goT env e2
            pure (joinT tt te, d0 ++ d1 ++ d2)
      CTagEq 1 _ s -> do
        (ts, d) <- goT env s
        if isF ts then Nothing else pure (JI, d)
      ap@CApp {} ->
        let (h, args) = B.spine ap
         in case h of
              CVar g
                | Just op <- M.lookup g B.arithOps,
                  [x, y] <- args,
                  not (M.member g env) -> do
                    (tx, d1) <- goT env x
                    (ty, d2) <- goT env y
                    rt <- arithTy op tx ty
                    pure (rt, d1 ++ d2)
                | Just (_, ret) <- M.lookup g numPrims,
                  not (M.member g env) -> do
                    ds <- mapM (goT env) args
                    pure (ret, concatMap snd ds)
                | not (M.member g env),
                  M.member g cl -> do
                    ds <- mapM (goT env) args
                    let ats = map fst ds
                        k = (g, ats)
                    pure (M.findWithDefault JB k sigs, k : concatMap snd ds)
              _ -> Nothing
      _ -> Nothing

    arithTy op tx ty = case op of
      B.ODiv -> case promoT tx ty of
        JW -> Nothing -- quot or true division? undecidable: bail
        t -> Just t
      B.OAdd -> Just (promoT tx ty)
      B.OSub -> Just (promoT tx ty)
      B.OMul -> Just (promoT tx ty)
      _ -> Just JI -- comparisons reify as i64 bools

-- like tyExpr, but the root of a vec dual: the element param (and its
-- let-aliases) types by COLUMN KIND — CProj k -> colTys !! k
tyExprV :: M.Map VKey JTy -> M.Map Name ([Name], Core) -> Bool -> [JTy] -> S.Set Name -> M.Map Name JTy -> Core -> Maybe (JTy, [VKey])
tyExprV sigs cl scalar colTys es0 env0 e0 = goV es0 env0 e0
  where
    goV es env e = case e of
      CVar v | S.member v es -> if scalar then Just (head colTys, []) else Nothing
      CProj k (CVar v) | S.member v es -> Just (colTys !! k, [])
      CLet x (CVar v) b | S.member v es -> goV (S.insert x es) env b
      CLet x a b -> do
        (ta, d1) <- goV es env a
        (tb, d2) <- goV (S.delete x es) (M.insert x ta env) b
        pure (tb, d1 ++ d2)
      CIf c t e2 -> do
        (tc, d0) <- goV es env c
        if isF tc
          then Nothing
          else do
            (tt, d1) <- goV es env t
            (te, d2) <- goV es env e2
            pure (joinT tt te, d0 ++ d1 ++ d2)
      CTagEq 1 _ s -> do
        (ts, d) <- goV es env s
        if isF ts then Nothing else pure (JI, d)
      ap@CApp {} ->
        let (h, args) = B.spine ap
         in case h of
              CVar g
                | Just op <- M.lookup g B.arithOps,
                  [x, y] <- args,
                  not (M.member g env),
                  not (S.member g es) -> do
                    (tx, d1) <- goV es env x
                    (ty, d2) <- goV es env y
                    rt <- arithTyV op tx ty
                    pure (rt, d1 ++ d2)
                | Just (_, ret) <- M.lookup g numPrims,
                  not (M.member g env),
                  not (S.member g es) -> do
                    ds <- mapM (goV es env) args
                    pure (ret, concatMap snd ds)
                | not (M.member g env),
                  not (S.member g es),
                  M.member g cl -> do
                    ds <- mapM (goV es env) args
                    let ats = map fst ds
                        k = (g, ats)
                    pure (M.findWithDefault JB k sigs, k : concatMap snd ds)
              _ -> Nothing
      -- delegate the shared leaves
      _ -> tyExpr sigs cl env e
    arithTyV op tx ty = case op of
      B.ODiv -> case promoT tx ty of JW -> Nothing; t -> Just t
      B.OAdd -> Just (promoT tx ty)
      B.OSub -> Just (promoT tx ty)
      B.OMul -> Just (promoT tx ty)
      _ -> Just JI

-- fixpoint over all demanded HELPER variants, seeded by the root body's
-- demands. rootTy types the root itself (list roots use tyExpr; vec roots
-- use tyExprV via the closure passed in).
inferSigs :: M.Map Name ([Name], Core) -> (M.Map VKey JTy -> Maybe (JTy, [VKey])) -> Maybe (M.Map VKey JTy, JTy)
inferSigs cl rootTy = go 0 M.empty
  where
    go :: Int -> M.Map VKey JTy -> Maybe (M.Map VKey JTy, JTy)
    go round sigs
      | round > 32 = Nothing -- non-converging (shouldn't happen); bail
      | otherwise = do
          (rt, rdemands) <- rootTy sigs
          -- EVERY known variant re-settles each round: a depth>=2 variant
          -- whose callees refined must recompute (and may demand NEW
          -- variants as its argument types sharpen)
          (sigs', changed) <- settle sigs (nub (rdemands ++ M.keys sigs)) False
          if changed then go (round + 1) sigs' else pure (sigs', rt)
    -- process a worklist of variants: (re)type each, recording changes and
    -- newly demanded variants
    settle sigs [] changed = Just (sigs, changed)
    settle sigs (k@(n, ats) : rest) changed = do
      (ps, body) <- M.lookup n cl
      if length ps /= length ats
        then Nothing
        else do
          (rt, ds) <- tyExpr sigs cl (M.fromList (zip ps ats)) body
          let old = M.findWithDefault JB k sigs
              sigs' = M.insert k rt sigs
              newKs = [d | d <- nub ds, not (M.member d sigs')]
          settle (M.insert k rt sigs') (rest ++ newKs) (changed || rt /= old || not (M.member k sigs))

-- ---- codegen ---------------------------------------------------------------

data CG = CG
  { cgB :: LRef,
    cgCtx :: LRef,
    cgI64 :: LRef,
    cgF64 :: LRef,
    cgFns :: M.Map VKey (LRef, LRef, JTy), -- variant -> (fn, fnty, ret)
    cgSigs :: M.Map VKey JTy,
    cgCl :: M.Map Name ([Name], Core),
    cgIntr :: M.Map String (LRef, LRef) -- llvm.* intrinsics
  }

nm :: String -> (CString -> IO a) -> IO a
nm = withCString

repr :: CG -> JTy -> LRef
repr cg t = if isF t then cgF64 cg else cgI64 cg

zero64, one64 :: CG -> IO LRef
zero64 cg = c_constInt (cgI64 cg) 0 0
one64 cg = c_constInt (cgI64 cg) 1 0

-- promote-only coercion between slot types. JD and JW share the f64 repr;
-- JI -> f64 is sitofp, exactly the interpreter's fromIntegral-on-contact.
coerce :: CG -> (LRef, JTy) -> JTy -> IO LRef
coerce cg (v, from) to
  | isF from == isF to = pure v
  | not (isF from) = nm "pro" $ c_bSIToFP (cgB cg) v (cgF64 cg)
  | otherwise = error ("jit coerce: demotion " ++ show from ++ " -> " ++ show to ++ " (inference bug)")

-- every Sol variant becomes: <ret> f(ptr fuel, <t1> a1, ..., <tn> an) with a
-- reified fuel decrement at entry. Symbols carry the type signature so two
-- specializations of one helper coexist in the JITDylib.
declareFnT :: CG -> LRef -> LRef -> String -> VKey -> JTy -> IO (LRef, LRef, JTy)
declareFnT cg md ptrTy pre (n, ats) ret = do
  let argTys = ptrTy : map (repr cg) ats
  fty <- withArrayLen argTys $ \len p -> c_fnTy (repr cg ret) p len 0
  f <- nm (pre ++ mangle n ++ "_" ++ map tyChar ats) $ \s -> c_addFn md s fty
  pure (f, fty, ret)

mangle :: Name -> String
mangle = map (\c -> if c `elem` ['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'] then c else '_')

fuelTickIR :: CG -> LRef -> IO ()
fuelTickIR cg fuel = do
  f <- nm "f" $ c_bLoad (cgB cg) (cgI64 cg) fuel
  o <- one64 cg
  f' <- nm "f1" $ c_bSub (cgB cg) f o
  _ <- c_bStore (cgB cg) f' fuel
  pure ()

defineFnT :: CG -> VKey -> LRef -> JTy -> IO ()
defineFnT cg (n, ats) f ret = do
  let Just (ps, body) = M.lookup n (cgCl cg)
  bb <- nm "entry" $ c_appendBB (cgCtx cg) f
  c_positionAtEnd (cgB cg) bb
  fuel <- c_param f 0
  fuelTickIR cg fuel
  env0 <- forM (zip3 ps ats [1 ..]) $ \(p, t, i) -> do
    v <- c_param f i
    pure (p, (v, t))
  r <- cgExprT cg fuel Nothing (M.fromList env0) body
  rv <- coerce cg r ret
  _ <- c_bRet (cgB cg) rv
  pure ()

-- the vec dual hook: the element param (and aliases) resolves to typed
-- column loads
data VecAccess = VecAccess
  { vaParam :: Name,
    vaScalar :: Bool,
    vaColTys :: [JTy], -- per-column slot types (KBox columns never load)
    vaCols :: LRef, -- i64**/f64** cols (opaque ptrs)
    vaIdx :: LRef,
    vaPtrTy :: LRef
  }

loadColAt :: CG -> VecAccess -> Int -> IO (LRef, JTy)
loadColAt cg va k = do
  let b = cgB cg
      i64 = cgI64 cg
      t = vaColTys va !! k
      ety = repr cg t
  ki <- c_constInt i64 (fromIntegral k) 0
  pk <- withArrayLen [ki] $ \len p -> nm "pk" $ c_bGEP b (vaPtrTy va) (vaCols va) p len
  base <- nm "colbase" $ c_bLoad b (vaPtrTy va) pk
  pe <- withArrayLen [vaIdx va] $ \len p -> nm "pe" $ c_bGEP b ety base p len
  v <- nm "colv" $ c_bLoad b ety pe
  pure (v, t)

-- ONE typed expression compiler for both tiers; mva enables the dual hook.
-- Types recomputed alongside emission — deterministic, same rules as tyExpr.
cgExprT :: CG -> LRef -> Maybe VecAccess -> M.Map Name (LRef, JTy) -> Core -> IO (LRef, JTy)
cgExprT cg fuel mva env0 e0 = go (maybe S.empty (S.singleton . vaParam) mva) env0 e0
  where
    b = cgB cg
    i64 = cgI64 cg
    go es env = \case
      CInt i -> (,JI) <$> c_constInt i64 (fromIntegral i) 0
      CVar x
        | Just va <- mva, S.member x es -> loadColAt cg va 0
        | otherwise -> case M.lookup x env of
            Just vt -> pure vt
            Nothing -> case M.lookup (x, []) (cgFns cg) of
              Just (f, fty, ret) -> (,ret) <$> callFn f fty []
              Nothing -> error ("jit cgExprT: unbound " ++ x)
      CProj k (CVar x)
        | Just va <- mva, S.member x es -> loadColAt cg va k
      CLet x (CVar v) e | S.member v es -> go (S.insert x es) env e -- alias
      CLet x a e -> do
        va <- go es env a
        go (S.delete x es) (M.insert x va env) e
      CIf c t e -> do
        (vc, _) <- go es env c
        z <- zero64 cg
        cond <- nm "cond" $ c_bICmp b pNE vc z
        fn <- c_insertBlock b >>= c_bbParent
        bbT <- nm "then" $ c_appendBB (cgCtx cg) fn
        bbE <- nm "else" $ c_appendBB (cgCtx cg) fn
        bbM <- nm "merge" $ c_appendBB (cgCtx cg) fn
        -- both branch types are needed before the alloca; type (not emit)
        -- the branches first via the pure pass
        let tyOf ex = case mva of
              Just va -> tyExprV (cgSigs cg) (cgCl cg) (vaScalar va) (vaColTys va) es (M.map snd env) ex
              Nothing -> tyExpr (cgSigs cg) (cgCl cg) (M.map snd env) ex
            Just (tt0, _) = tyOf t
            Just (te0, _) = tyOf e
            tj = joinT tt0 te0
        res <- nm "ifres" $ c_bAlloca b (repr cg tj)
        _ <- c_bCondBr b cond bbT bbE
        c_positionAtEnd b bbT
        vt <- go es env t >>= \r -> coerce cg r tj
        _ <- c_bStore b vt res
        _ <- c_bBr b bbM
        c_positionAtEnd b bbE
        ve <- go es env e >>= \r -> coerce cg r tj
        _ <- c_bStore b ve res
        _ <- c_bBr b bbM
        c_positionAtEnd b bbM
        (,tj) <$> nm "ifv" (c_bLoad b (repr cg tj) res)
      CTagEq 1 v e -> do
        (ve, _) <- go es env e
        z <- zero64 cg
        c <- nm "bt" $ c_bICmp b (if v == 1 then pNE else pEQ) ve z
        (,JI) <$> nm "btz" (c_bZExt b c i64)
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
            | Just (_, _) <- M.lookup g numPrims,
              not (M.member g env),
              not (S.member g es) -> do
                vs <- mapM (go es env) args
                cgNumPrim cg g vs
            | not (M.member g env),
              not (S.member g es) -> do
                vts <- mapM (go es env) args
                let key = (g, map snd vts)
                case M.lookup key (cgFns cg) of
                  Just (f, fty, ret) -> (,ret) <$> callFn f fty (map fst vts)
                  Nothing -> error ("jit cgExprT: missing variant " ++ g ++ "/" ++ map (tyChar . snd) vts)
          _ -> error "jit cgExprT: non-jittable application survived the guard"
      other -> error ("jit cgExprT: non-jittable node survived the guard: " ++ show other)
    callFn f fty vs = withArrayLen (fuel : vs) $ \len p -> nm "call" $ c_bCall b fty f p len

cgArith :: CG -> B.ArithOp -> (LRef, JTy) -> (LRef, JTy) -> IO (LRef, JTy)
cgArith cg op xt@(_, tx) yt@(_, ty) = case op of
  B.OAdd -> num c_bAdd c_bFAdd "add"
  B.OSub -> num c_bSub c_bFSub "sub"
  B.OMul -> num c_bMul c_bFMul "mul"
  B.ODiv -> case rt of
    JD -> fdo c_bFDiv "fdiv" JD
    JW -> error "jit cgArith: ODiv on JW operands (inference bug)"
    _ -> do r <- nm "div" $ c_bSDiv b (fst xt) (fst yt); pure (r, JI)
  B.OLt -> cmp pSLT rOLT
  B.OLe -> cmp pSLE rOLE
  B.OGt -> cmp pSGT rOGT
  B.OGe -> cmp pSGE rOGE
  B.OEq -> cmp pEQ rOEQ
  B.ONe -> cmp pNE rONE
  where
    b = cgB cg
    rt = promoT tx ty
    num iop fop s
      | not (isF rt) = do r <- nm s $ iop b (fst xt) (fst yt); pure (r, rt)
      | otherwise = fdo fop ('f' : s) rt
    fdo fop s t = do
      x' <- coerce cg xt JD
      y' <- coerce cg yt JD
      r <- nm s $ fop b x' y'
      pure (r, t)
    cmp ip rp
      | not (isF tx) && not (isF ty) = do
          c <- nm "cmp" $ c_bICmp b ip (fst xt) (fst yt)
          (,JI) <$> nm "cmpz" (c_bZExt b c (cgI64 cg))
      | otherwise = do
          x' <- coerce cg xt JD
          y' <- coerce cg yt JD
          c <- nm "fcmp" $ c_bFCmp b rp x' y'
          (,JI) <$> nm "cmpz" (c_bZExt b c (cgI64 cg))

-- the Numeric prims as intrinsics: Num.div = fdiv; Num.sqrt/floor/round =
-- llvm.sqrt/floor/rint.f64 (rint's default nearest-even IS Haskell round)
cgNumPrim :: CG -> Name -> [(LRef, JTy)] -> IO (LRef, JTy)
cgNumPrim cg g vs = case (g, vs) of
  ("Num.div", [x, y]) -> do
    x' <- coerce cg x JD
    y' <- coerce cg y JD
    r <- nm "ndiv" $ c_bFDiv (cgB cg) x' y'
    pure (r, JD)
  ("Num.sqrt", [x]) -> intr "llvm.sqrt.f64" x >>= \r -> pure (r, JD)
  ("Num.floor", [x]) -> intr "llvm.floor.f64" x >>= toInt
  ("Num.round", [x]) -> intr "llvm.rint.f64" x >>= toInt
  _ -> error ("jit cgNumPrim: " ++ g)
  where
    intr name x = do
      x' <- coerce cg x JD
      let Just (f, fty) = M.lookup name (cgIntr cg)
      withArrayLen [x'] $ \len p -> nm "intr" $ c_bCall (cgB cg) fty f p len
    toInt v = (,JI) <$> nm "fpsi" (c_bFPToSI (cgB cg) v (cgI64 cg))

declareIntrinsics :: LRef -> LRef -> LRef -> IO (M.Map String (LRef, LRef))
declareIntrinsics md _i64 f64 = do
  fty <- withArrayLen [f64] $ \len p -> c_fnTy f64 p len 0
  fmap M.fromList $ forM ["llvm.sqrt.f64", "llvm.floor.f64", "llvm.rint.f64"] $ \n -> do
    f <- nm n $ \s -> c_addFn md s fty
    pure (n, (f, fty))

-- ---- compile a (scheme, element fn) pair: list tier -------------------------
--
-- elemTy comes from the marshalled list (all-VInt = JI, all-VNum = JD,
-- mixed = JW); accTy0 from the fold seed. The acc slot type is stabilized
-- against the body's return (the interpreter's acc changes type after the
-- first inexact iteration; JW covers the ambiguity), and the RESULT type
-- must come out definite (JI or JD) — a JW result would hand the
-- interpreter a value of unknowable Sol type, so those bail.

compileScheme :: JitCtx -> Prog -> String -> Name -> JTy -> JTy -> IO (Maybe (Int64, JTy, JTy))
compileScheme jc prog scheme root elemTy accTy0 = do
  let ckey = (scheme ++ "|" ++ [tyChar elemTy] ++ "|" ++ [tyChar accTy0], root)
  cache <- readIORef (jcCache jc)
  case M.lookup ckey cache of
    Just (addr, accTy, retTy) -> pure (Just (addr, accTy, retTy))
    Nothing -> case fmap prepClosure (gatherFns prog root) >>= checkAll of
      Nothing -> pure Nothing
      Just closure -> do
        let Just (rootPs, _) = M.lookup root closure
            isFold = scheme == "foldl"
            -- stabilize the fold acc type against the body's return
            stab acc n
              | n <= (0 :: Int) = Nothing
              | otherwise = do
                  let rootArgs = if isFold then [acc, elemTy] else [elemTy]
                      rootTy sigs = do
                        (ps, body) <- M.lookup root closure
                        tyExpr sigs closure (M.fromList (zip ps rootArgs)) body
                  (sigs, rt) <- inferSigs closure rootTy
                  if isFold && rt /= acc && joinT acc rt /= acc
                    then stab (joinT acc rt) (n - 1)
                    else Just (sigs, if isFold then acc else rt, rt)
        case (length rootPs == (if isFold then 2 else 1), stab accTy0 3) of
          (False, _) -> pure Nothing
          (_, Nothing) -> jitDebug ("[jit-debug] " ++ root ++ ": untypeable (JW div / bool / non-convergence)") >> pure Nothing
          (True, Just (sigs, accTy, retTy))
            -- filter needs a definite bool; map/fold results must be definite
            | scheme == "filter" && retTy /= JI -> pure Nothing
            | retTy == JW -> jitDebug ("[jit-debug] " ++ root ++ ": JW result escapes; interpreter's job") >> pure Nothing
            | otherwise -> do
                let rootKey = (root, if isFold then [accTy, elemTy] else [elemTy])
                    allKeys = nub (rootKey : M.keys sigs)
                    sigs' = M.insert rootKey retTy sigs
                emit jc closure sigs' allKeys rootKey $ \cg md ptrTy sym -> do
                  buildDriverT cg md ptrTy scheme sym (cgFns cg M.! rootKey) elemTy accTy retTy
                  pure
                    ( \addr -> do
                        putStrLn ("[jit] compiled " ++ scheme ++ "<" ++ root ++ "> elem=" ++ [tyChar elemTy] ++ (if isFold then " acc=" ++ [tyChar accTy] else "") ++ " (typed, fuel reified)")
                        atomicModifyIORef' (jcCache jc) (\m -> (M.insert ckey (addr, accTy, retTy) m, ()))
                        pure (addr, accTy, retTy)
                    )

-- shared LLVM module scaffolding: declare + define every demanded variant,
-- run the driver builder, hand the module to the JIT, look the symbol up
emit ::
  JitCtx ->
  M.Map Name ([Name], Core) ->
  M.Map VKey JTy ->
  [VKey] ->
  VKey ->
  (CG -> LRef -> LRef -> String -> IO (Int64 -> IO a)) ->
  IO (Maybe a)
emit jc closure sigs allKeys _rootKey buildAnd = do
  k <- atomicModifyIORef' (jcCount jc) (\c -> (c + 1, c))
  let sym = "sol_t" ++ show k
  (ctx, mkTsc) <- newModuleCtx
  md <- nm sym $ \s -> c_modCreate s ctx
  b <- c_builderCreate ctx
  i64 <- c_i64 ctx
  f64 <- c_f64 ctx
  ptrTy <- c_ptrTy ctx 0
  intr <- declareIntrinsics md i64 f64
  let cg0 = CG b ctx i64 f64 M.empty sigs closure intr
  decls <-
    M.fromList
      <$> forM allKeys (\vk -> (,) vk <$> declareFnT cg0 md ptrTy (sym ++ "_") vk (M.findWithDefault JI vk sigs))
  let cg = cg0 {cgFns = decls}
  forM_ (M.toList decls) $ \(vk, (f, _, ret)) -> defineFnT cg vk f ret
  finish <- buildAnd cg md ptrTy sym
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
      if addr == 0 then pure Nothing else Just <$> finish addr

-- typed list driver: same loop skeleton; element loads, out stores, and
-- the acc slot use the inferred repr. The FFI boundary stays all-i64 —
-- f64 acc/result travel as bit patterns (bitcast at entry/exit).
buildDriverT :: CG -> LRef -> LRef -> String -> String -> (LRef, LRef, JTy) -> JTy -> JTy -> JTy -> IO ()
buildDriverT cg md ptrTy scheme sym (ef, efTy, _) elemTy accTy retTy = do
  let i64 = cgI64 cg
      f64 = cgF64 cg
      b = cgB cg
      isFold = scheme == "foldl"
      eltTy = repr cg elemTy
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
  accA <- nm "acc" $ c_bAlloca b (repr cg accTy)
  _ <- c_bStore b z iA
  when isFold $ do
    a0 <- if not (isF accTy) then pure p3 else nm "accf" (c_bBitCast b p3 f64)
    () <$ c_bStore b a0 accA
  unless isFold (() <$ c_bStore b z accA)
  _ <- c_bBr b bbCond
  c_positionAtEnd b bbCond
  iv <- nm "iv" $ c_bLoad b i64 iA
  more <- nm "more" $ c_bICmp b pSLT iv n
  _ <- c_bCondBr b more bbBody bbExit
  c_positionAtEnd b bbBody
  px <- withArrayLen [iv] $ \len p -> nm "px" $ c_bGEP b eltTy pin p len
  x <- nm "x" $ c_bLoad b eltTy px
  let callE vs = withArrayLen (fuel : vs) $ \len p -> nm "fx" $ c_bCall b efTy ef p len
      bump = do
        i' <- nm "i1" $ c_bAdd b iv o
        _ <- c_bStore b i' iA
        _ <- c_bBr b bbCond
        pure ()
  case scheme of
    "map" -> do
      r <- callE [x]
      po <- withArrayLen [iv] $ \len p -> nm "po" $ c_bGEP b (repr cg retTy) p3 p len
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
      po <- withArrayLen [k] $ \len p -> nm "po" $ c_bGEP b eltTy p3 p len
      _ <- c_bStore b x po
      k' <- nm "k1" $ c_bAdd b k o
      _ <- c_bStore b k' accA
      _ <- c_bBr b bbCont
      c_positionAtEnd b bbCont
      bump
    "foldl" -> do
      acc <- nm "accv" $ c_bLoad b (repr cg accTy) accA
      r <- callE [acc, x]
      -- ret ty may be JD where the acc slot is widened: same repr, store
      -- direct; an exact-int ret into a widened slot promotes
      rv <-
        if not (isF accTy)
          then pure r
          else if not (isF retTy) then nm "pro" (c_bSIToFP b r f64) else pure r
      _ <- c_bStore b rv accA
      bump
    _ -> error ("unknown scheme " ++ scheme)
  c_positionAtEnd b bbExit
  out <- case scheme of
    "map" -> pure n
    "filter" -> nm "res" $ c_bLoad b i64 accA
    _ -> do
      a <- nm "res" $ c_bLoad b (repr cg accTy) accA
      if not (isF accTy) then pure a else nm "bits" (c_bBitCast b a i64)
  _ <- c_bRet b out
  pure ()

-- ---- native invocation (fuel cell reconciled by the caller/VM) -------------

runMapFilter :: Int64 -> Ptr Int64 -> [Int64] -> IO (Int64, [Int64])
runMapFilter addr pfuel xs = do
  let f = mkDrv4 (castPtrToFunPtr (intPtrToPtr (fromIntegral addr)))
  withArrayLen xs $ \n pin ->
    allocaArray n $ \pout -> do
      k <- f pfuel pin (fromIntegral n) pout
      out <- mapM (peekElemOff pout) [0 .. fromIntegral k - 1]
      pure (k, out)

runFold :: Int64 -> Ptr Int64 -> Int64 -> [Int64] -> IO Int64
runFold addr pfuel acc0 xs = do
  let f = mkDrvF (castPtrToFunPtr (intPtrToPtr (fromIntegral addr)))
  withArrayLen xs $ \n pin -> f pfuel pin (fromIntegral n) acc0

-- ---- Vector (SoA) tier ------------------------------------------------------
--
-- The dual, typed: `fn p -> p.x * w` over a layout with a KNum column
-- compiles to a load of f64 from cols[k][i] and fmul. Column types come
-- from the layout (i -> JI, d -> JD, b -> unloadable); KNum columns read
-- back as VNum in the interpreter too, so 'd' columns are honestly JD,
-- never JW. Captured scalars carry their own types (a VNum weight rides
-- as f64 bits in the extras array).

-- can this body run as a dual over the given layout? The elem param — or any
-- let-alias of it (the clause compiler rebinds params: CLet p (CVar a1_k)) —
-- may ONLY appear as CProj onto an UNBOXED column (i64/f64 SoA) or bare
-- (scalar unboxed).
jitOKVec :: M.Map Name Int -> Bool -> [Bool] -> Name -> [Name] -> Core -> Bool
jitOKVec fnAr scalar loadable elemP0 locals0 = ok (S.singleton elemP0) locals0
  where
    ok es locals = \case
      CInt _ -> True
      CVar v | S.member v es -> scalar && loadable == [True]
      CVar v -> v `elem` locals || M.lookup v fnAr == Just 0
      CProj k (CVar v) | S.member v es -> not scalar && k < length loadable && loadable !! k
      CLet x (CVar v) b | S.member v es -> ok (S.insert x es) locals b -- alias
      CLet x a b -> ok es locals a && ok (S.delete x es) (x : locals) b
      CIf c t e -> ok es locals c && ok es locals t && ok es locals e
      CTagEq 1 v e | v <= 1 -> ok es locals e -- bool test as int compare
      e@CApp {} ->
        let (h, args) = B.spine e
         in case h of
              CVar g
                | not (S.member g es), g `notElem` locals, M.member g B.arithOps, length args == 2 -> all (ok es locals) args
                | not (S.member g es), g `notElem` locals, Just (npAr, _) <- M.lookup g numPrims, npAr == length args -> all (ok es locals) args
                | not (S.member g es), g `notElem` locals, Just ar <- M.lookup g fnAr, ar == length args -> all (ok es locals) args
              _ -> False
      _ -> False

compileVecScheme :: JitCtx -> Prog -> String -> Name -> Bool -> [JTy] -> String -> [JTy] -> JTy -> IO (Maybe (Int64, JTy, JTy))
compileVecScheme jc prog scheme root scalar colTys laySig exTys accTy0 = do
  let ckey = (scheme ++ "|" ++ laySig ++ "|" ++ map tyChar exTys ++ "|" ++ [tyChar accTy0], root)
  cache <- readIORef (jcCache jc)
  case M.lookup ckey cache of
    Just (addr, accTy, retTy) -> pure (Just (addr, accTy, retTy))
    Nothing -> case fmap prepClosure (gatherFns prog root) of
      Nothing -> jitDebug ("[jit-debug] " ++ root ++ ": gather failed (call outside prog?)") >> pure Nothing
      Just closure -> do
        let ars = M.map (length . fst) closure
            Just (rootPs, rootBody) = M.lookup root closure
            helpers = M.delete root closure
            nEx = length exTys
            isFold = scheme == "vecfold"
            needed = nEx + (if isFold then 2 else 1)
            exPs = take nEx rootPs
            (accP, elemP) = case (scheme, drop nEx rootPs) of
              ("vecfold", [a, x]) -> (Just a, x)
              (_, [x]) -> (Nothing, x)
              _ -> (Nothing, "?")
            loadable = map (/= JW) colTys -- JW marks a KBox column below
            helpersOK = all (uncurry (jitOK ars)) (M.elems helpers)
            rootOK =
              length rootPs == needed
                && jitOKVec ars scalar loadable elemP (exPs ++ maybe [] pure accP) rootBody
            stab acc n
              | n <= (0 :: Int) = Nothing
              | otherwise = do
                  let env0 = M.fromList (zip exPs exTys ++ maybe [] (\a -> [(a, acc)]) accP)
                      rootTy sigs = tyExprV sigs closure scalar colTys (S.singleton elemP) env0 rootBody
                  (sigs, rt) <- inferSigs closure rootTy
                  if isFold && rt /= acc && joinT acc rt /= acc
                    then stab (joinT acc rt) (n - 1)
                    else Just (sigs, if isFold then acc else rt, rt)
        if not (helpersOK && rootOK)
          then do
            jitDebug ("[jit-debug] " ++ root ++ ": helpersOK=" ++ show helpersOK ++ " rootOK=" ++ show rootOK ++ " closure=" ++ show (M.keys closure))
            jitDebug ("[jit-debug] failing helpers: " ++ show [n | (n, (ps, b)) <- M.toList helpers, not (jitOK ars ps b)])
            pure Nothing
          else case stab accTy0 3 of
            Nothing -> jitDebug ("[jit-debug] " ++ root ++ ": untypeable (JW div / bool / non-convergence)") >> pure Nothing
            Just (sigs, accTy, retTy)
              | scheme == "vecfilter" && retTy /= JI -> pure Nothing
              | retTy == JW -> jitDebug ("[jit-debug] " ++ root ++ ": JW result escapes; interpreter's job") >> pure Nothing
              | otherwise -> do
                  let allKeys = nub (M.keys sigs) -- helpers only; the dual is separate
                  r <- emit jc helpers sigs allKeys ("", []) $ \cg md ptrTy sym -> do
                    -- the typed DUAL: <ret> f(fuel*, extras..., [acc,] cols**, idx)
                    let dualArgTys = [ptrTy] ++ map (repr cg) exTys ++ [repr cg accTy | isFold] ++ [ptrTy, cgI64 cg]
                    dualTy <- withArrayLen dualArgTys $ \len p -> c_fnTy (repr cg retTy) p len 0
                    dual <- nm (sym ++ "_f") $ \s -> c_addFn md s dualTy
                    bb <- nm "entry" $ c_appendBB (cgCtx cg) dual
                    c_positionAtEnd (cgB cg) bb
                    fuel <- c_param dual 0
                    fuelTickIR cg fuel
                    exVals <- mapM (\i -> c_param dual (1 + i)) [0 .. nEx - 1]
                    (env0, colsP, idxP) <-
                      if isFold
                        then do
                          acc <- c_param dual (1 + nEx)
                          cs <- c_param dual (2 + nEx)
                          ix <- c_param dual (3 + nEx)
                          pure (M.fromList (zip exPs (zip exVals exTys) ++ [(head (drop nEx rootPs), (acc, accTy))]), cs, ix)
                        else do
                          cs <- c_param dual (1 + nEx)
                          ix <- c_param dual (2 + nEx)
                          pure (M.fromList (zip exPs (zip exVals exTys)), cs, ix)
                    let va = VecAccess elemP scalar colTys colsP idxP ptrTy
                    rres <- cgExprT cg fuel (Just va) env0 rootBody
                    rv <- coerce cg rres retTy
                    _ <- c_bRet (cgB cg) rv
                    buildVecDriverT cg md ptrTy scheme sym (dual, dualTy) exTys accTy retTy
                    pure
                      ( \addr -> do
                          putStrLn ("[jit] compiled " ++ scheme ++ "<" ++ root ++ "> over SoA layout " ++ laySig ++ (if nEx > 0 then " + " ++ show nEx ++ " captured scalar(s)" else "") ++ " (typed dual, fuel reified)")
                          atomicModifyIORef' (jcCache jc) (\m -> (M.insert ckey (addr, accTy, retTy) m, ()))
                          pure (addr, accTy, retTy)
                      )
                  pure r

-- typed vec driver: extras load as i64 bits and bitcast per their type;
-- acc slot typed; vecfilter still emits kept row INDICES (i64)
buildVecDriverT :: CG -> LRef -> LRef -> String -> String -> (LRef, LRef) -> [JTy] -> JTy -> JTy -> IO ()
buildVecDriverT cg md ptrTy scheme sym (ef, efTy) exTys accTy retTy = do
  let i64 = cgI64 cg
      f64 = cgF64 cg
      b = cgB cg
      isFold = scheme == "vecfold"
      nEx = length exTys
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
  eVals <-
    mapM
      ( \(i, t) -> do
          ki <- c_constInt i64 (fromIntegral i) 0
          pe <- withArrayLen [ki] $ \len p -> nm "pex" $ c_bGEP b i64 extras p len
          raw <- nm "ex" $ c_bLoad b i64 pe
          if not (isF t) then pure raw else nm "exf" (c_bBitCast b raw f64)
      )
      (zip [0 :: Int ..] exTys)
  iA <- nm "i" $ c_bAlloca b i64
  accA <- nm "acc" $ c_bAlloca b (repr cg accTy)
  _ <- c_bStore b z iA
  when isFold $ do
    a0 <- if not (isF accTy) then pure p4 else nm "accf" (c_bBitCast b p4 f64)
    () <$ c_bStore b a0 accA
  unless isFold (() <$ c_bStore b z accA)
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
      po <- withArrayLen [iv] $ \len p -> nm "po" $ c_bGEP b (repr cg retTy) p4 p len
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
      acc <- nm "accv" $ c_bLoad b (repr cg accTy) accA
      r <- callE [eVals `seq` acc, cols, iv] -- eVals delivered inside callE
      rv <-
        if not (isF accTy)
          then pure r
          else if not (isF retTy) then nm "pro" (c_bSIToFP b r f64) else pure r
      _ <- c_bStore b rv accA
      bump
    _ -> error ("unknown vec scheme " ++ scheme)
  c_positionAtEnd b bbExit
  out <- case scheme of
    "vecmap" -> pure n
    "vecfilter" -> nm "res" $ c_bLoad b i64 accA
    _ -> do
      a <- nm "res" $ c_bLoad b (repr cg accTy) accA
      if not (isF accTy) then pure a else nm "bits" (c_bBitCast b a i64)
  _ <- c_bRet b out
  pure ()

-- invoke a vec driver: cols is the lent column-pointer array; extras carry
-- captured scalars as i64 bit patterns (typed inside the driver)
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
