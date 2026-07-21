{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

{-# OPTIONS_GHC -Wno-missing-export-lists #-}
{-# LANGUAGE FlexibleContexts #-}

-- Infer.hs — Hindley–Milner inference with row-polymorphic records for Sol.
--
-- Algorithm W over:
--
--   τ ::= α | C | τ τ | τ -> τ | (τ, ..) | { ρ }
--   ρ ::= ρα | ∅ | (l : τ | ρ)
--
-- Records are rows (Leijen-style): projection `e.f` constrains e to
-- {f : α | ρ} with fresh ρ — structural, width-subtyped via the open
-- tail. Sigs are rows by construction, so `(s : Sig)` params type as
-- {sig fields | ρ} and struct conformance is type-level: each struct
-- field's inferred type must unify with the sig's declared field type
-- under one shared carrier (`t`) instantiation per struct/sig pair.
--
-- Type application is structural (no kinds): `t a` in a sig unifies as
-- TAp (TV t) a — first-order HKT, enough for Functor without a kind
-- system, same simplification the specializer already banks on.
--
-- Deliberate PoC simplifications, called out where they bite:
--   * no value restriction (no ML-style refs at the language level)
--   * monomorphic recursion; polymorphism via SCC-ordered generalization
--   * sig matching by unification, not subsumption (weaker but simple)
--   * a handful of HAL builtins get generous schemes (Vec.get : Int ->
--     Vector -> (a, Vector) — the untyped-storage escape hatch)

module Infer where

import Control.Monad (foldM, forM, forM_, unless, when, zipWithM, zipWithM_)
import Control.Monad.State.Strict
import Data.Graph (SCC (..), stronglyConnComp)
import qualified Data.IntMap.Strict as IM
import Data.List (foldl', intercalate, nub, stripPrefix)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import qualified Data.Set as S
import Lang
import Struct (Sigs, Structs)

-- ---- types ------------------------------------------------------------------

data Type
  = TV Int
  | TC Name
  | TAp Type Type
  | TFn Type Type
  | TRec Row
  | TTupT [Type]
  deriving (Eq, Show)

data Row
  = RV Int
  | RNil
  | RExt Name Type Row
  deriving (Eq, Show)

data Scheme = Forall [Int] [Int] Type deriving (Show) -- tvars, rowvars

tcon :: Name -> [Type] -> Type
tcon n = foldl' TAp (TC n)

tInt, tStr, tBool, tUnit, tAtom :: Type
tInt = TC "Int"
tStr = TC "String"
tBool = TC "Bool"
tUnit = TC "Unit"
tAtom = TC "Atom"

tList :: Type -> Type
tList a = TAp (TC "List") a

-- ---- inference monad --------------------------------------------------------

data IEnv = IEnv
  { iFresh :: !Int,
    iSub :: IM.IntMap Type, -- tvar solutions
    iRSub :: IM.IntMap Row, -- rowvar solutions
    iErrs :: [String],
    iNotes :: [(Name, String)], -- pretty-printed inferred schemes
    iNextSite :: !Int,
    iSites :: IM.IntMap (Name, Type), -- operator sites awaiting resolution
    iCarriers :: IM.IntMap (Name, Name) -- carrier var -> (param, sig)
  }

type I = State IEnv

freshT :: I Type
freshT = do s <- get; put s {iFresh = iFresh s + 1}; pure (TV (iFresh s))

freshR :: I Row
freshR = do s <- get; put s {iFresh = iFresh s + 1}; pure (RV (iFresh s))

report :: String -> I ()
report e = modify (\s -> s {iErrs = iErrs s ++ [e]})

-- ---- zonking (chase solutions) ----------------------------------------------

zonk :: Type -> I Type
zonk = \case
  TV v -> do
    sub <- gets iSub
    case IM.lookup v sub of
      Just t -> zonk t
      Nothing -> pure (TV v)
  TAp a b -> TAp <$> zonk a <*> zonk b
  TFn a b -> TFn <$> zonk a <*> zonk b
  TRec r -> TRec <$> zonkR r
  TTupT ts -> TTupT <$> mapM zonk ts
  t -> pure t

zonkR :: Row -> I Row
zonkR = \case
  RV v -> do
    sub <- gets iRSub
    case IM.lookup v sub of
      Just r -> zonkR r
      Nothing -> pure (RV v)
  RExt l t r -> RExt l <$> zonk t <*> zonkR r
  RNil -> pure RNil

-- ---- unification ------------------------------------------------------------

occursT :: Int -> Type -> Bool
occursT v = \case
  TV v' -> v == v'
  TAp a b -> occursT v a || occursT v b
  TFn a b -> occursT v a || occursT v b
  TRec r -> occursTR v r
  TTupT ts -> any (occursT v) ts
  _ -> False

occursTR :: Int -> Row -> Bool
occursTR v = \case
  RExt _ t r -> occursT v t || occursTR v r
  _ -> False

rowTail :: Row -> Maybe Int
rowTail = \case
  RV v -> Just v
  RNil -> Nothing
  RExt _ _ r -> rowTail r

unify :: String -> Type -> Type -> I ()
unify ctx a0 b0 = do
  a <- zonk a0
  b <- zonk b0
  case (a, b) of
    (TV v, t) -> bindT v t
    (t, TV v) -> bindT v t
    (TC x, TC y) | x == y -> pure ()
    (TAp f x, TAp g y) -> unify ctx f g >> unify ctx x y
    (TFn x r, TFn y s) -> unify ctx x y >> unify ctx r s
    (TTupT xs, TTupT ys) | length xs == length ys -> zipWithM_ (unify ctx) xs ys
    (TRec r1, TRec r2) -> unifyRow ctx r1 r2
    _ -> do
      pa <- prettyT a
      pb <- prettyT b
      report (ctx ++ ": cannot unify " ++ pa ++ " with " ++ pb)
  where
    bindT v t
      | t == TV v = pure ()
      | occursT v t = report (ctx ++ ": occurs check (infinite type)")
      | otherwise = modify (\s -> s {iSub = IM.insert v t (iSub s)})

-- Leijen-style row unification: to unify (l : τ | r1) with row2, rewrite
-- row2 to expose l (inserting through its tail var if open), then unify
-- τ with the exposed type and the remainders with each other.
unifyRow :: String -> Row -> Row -> I ()
unifyRow ctx r1z r2z = do
  r1 <- zonkR r1z
  r2 <- zonkR r2z
  case (r1, r2) of
    (RV v, r) -> bindR v r
    (r, RV v) -> bindR v r
    (RNil, RNil) -> pure ()
    (RExt l t rest, r) -> walk l t rest r id
    (RNil, RExt l _ _) -> report (ctx ++ ": closed record has no field ." ++ l)
  where
    -- find l among r's EXPLICIT labels first; only if absent and r ends
    -- in a tail var do we instantiate the tail — and only THEN does a
    -- shared tail between the two rows mean an infinite row (Leijen)
    walk l t rest r acc = case r of
      RExt l' t' r'
        | l == l' -> unify ctx t t' >> unifyRow ctx rest (acc r')
        | otherwise -> walk l t rest r' (acc . RExt l' t')
      RV v
        | rowTail rest == Just v -> report (ctx ++ ": recursive row (field " ++ l ++ ")")
        | otherwise -> do
            a <- freshT
            tl <- freshR
            modify (\s -> s {iRSub = IM.insert v (RExt l a tl) (iRSub s)})
            unify ctx t a
            unifyRow ctx rest (acc tl)
      RNil -> do
        p2 <- prettyRow (acc RNil)
        report (ctx ++ ": record lacks field ." ++ l ++ " (has " ++ p2 ++ "))")
    bindR v r
      | r == RV v = pure ()
      | occursR v r = report (ctx ++ ": occurs check (recursive row)")
      | otherwise = modify (\s -> s {iRSub = IM.insert v r (iRSub s)})
    occursR v = \case
      RV v' -> v == v'
      RExt _ _ r -> occursR v r
      RNil -> False

-- ---- schemes ----------------------------------------------------------------

instantiate :: Scheme -> I Type
instantiate (Forall tvs rvs t) = do
  tm <- IM.fromList <$> mapM (\v -> (,) v <$> freshT) tvs
  rm <- IM.fromList <$> mapM (\v -> (,) v <$> freshR) rvs
  let goT = \case
        TV v -> fromMaybe (TV v) (IM.lookup v tm)
        TAp a b -> TAp (goT a) (goT b)
        TFn a b -> TFn (goT a) (goT b)
        TRec r -> TRec (goR r)
        TTupT ts -> TTupT (map goT ts)
        o -> o
      goR = \case
        RV v -> fromMaybe (RV v) (IM.lookup v rm)
        RExt lb ty r -> RExt lb (goT ty) (goR r)
        RNil -> RNil
  pure (goT t)

ftv :: Type -> (S.Set Int, S.Set Int) -- (tvars, rowvars)
ftv = \case
  TV v -> (S.singleton v, S.empty)
  TAp a b -> ftv a <> ftv b
  TFn a b -> ftv a <> ftv b
  TTupT ts -> mconcat (map ftv ts)
  TRec r -> ftvR r
  _ -> mempty
  where
    ftvR = \case
      RV v -> (S.empty, S.singleton v)
      RExt _ t r -> ftv t <> ftvR r
      RNil -> mempty

type TEnv = M.Map Name Scheme

generalize :: TEnv -> Type -> I Scheme
generalize env t0 = do
  t <- zonk t0
  envFtv <- mconcat <$> mapM schemeFtv (M.elems env)
  let (tv, rv) = ftv t
      (etv, erv) = envFtv
  pure (Forall (S.toList (tv S.\\ etv)) (S.toList (rv S.\\ erv)) t)
  where
    schemeFtv (Forall qs rqs ty) = do
      ty' <- zonk ty
      let (tv, rv) = ftv ty'
      pure (tv S.\\ S.fromList qs, rv S.\\ S.fromList rqs)

mono :: Type -> Scheme
mono = Forall [] []

-- ---- Ty (surface annotations) -> Type ---------------------------------------

-- named surface vars (a, b, t) map through a shared table so `t` is the
-- same var across a sig's fields; unseen names allocate fresh
tyToType :: M.Map Name Type -> Ty -> I (Type, M.Map Name Type)
tyToType = tyToTypeA M.empty

-- with named record aliases (`MyRecord = {a : String, b : Int}.`): a bare
-- TCon hit in the alias table becomes its (closed) record type
type ShapeAliases = M.Map Name [(Name, Ty)]

tyToTypeA :: ShapeAliases -> M.Map Name Type -> Ty -> I (Type, M.Map Name Type)
tyToTypeA aliases tbl0 ty = runStateT (go ty) tbl0
  where
    go :: Ty -> StateT (M.Map Name Type) I Type
    go = \case
      TVarT n -> var n
      TCon n [] | Just fs <- M.lookup n aliases -> do
        tfs <- mapM (\(f, t) -> (,) f <$> go t) fs
        pure (TRec (foldr (\(f, t) r -> RExt f t r) RNil tfs))
      TCon n args -> foldl' TAp (TC (canon n)) <$> mapM go args
      TVApp n args -> do h <- var n; foldl' TAp h <$> mapM go args
      TArrT a b -> TFn <$> go a <*> go b
      TTup ts -> TTupT <$> mapM go ts
      TOther -> lift freshT
    var n = do
      tbl <- get
      case M.lookup n tbl of
        Just v -> pure v
        Nothing -> do v <- lift freshT; put (M.insert n v tbl); pure v
    canon "Str" = "String"
    canon n = n

-- ---- builtin schemes --------------------------------------------------------

sv :: Int -> Type
sv = TV

scheme :: [Int] -> Type -> Scheme
scheme vs = Forall vs []

builtinEnv :: TEnv
builtinEnv =
  M.fromList
    [ ("print", scheme [0] (TFn (sv 0) tUnit)),
      ("str", scheme [0] (TFn (sv 0) tStr)),
      ("strcat", mono (TFn tStr (TFn tStr tStr))),
      ("strlen", mono (TFn tStr tInt)),
      ("String.len", mono (TFn tStr tInt)),
      ("error", scheme [0] (TFn tStr (sv 0))),
      ("parseInt", mono (TFn tStr tInt)),
      ("charAt", mono (TFn tStr (TFn tInt tInt))), -- returns the char CODE
      ("chr", mono (TFn tInt tStr)),
      ("sleepMs", mono (TFn tInt tUnit)),
      ("fuelPreempts", mono (TFn tInt tInt)),
      ("rm", mono (TFn tStr tUnit)),
      ("rmdir", mono (TFn tStr tUnit)),
      ("mkdirp", mono (TFn tStr tUnit)),
      ("ls", mono (TFn tStr (tList tStr))),
      ("exists", mono (TFn tStr tBool)),
      ("isDir", mono (TFn tStr tBool)),
      ("stat", scheme [0] (TFn tStr (sv 0))),
      ("sh", mono (TFn tStr tStr)),
      ("shq", mono (TFn tStr tStr)),
      ("!", scheme [0, 1] (TFn (sv 0) (TFn tInt (sv 1)))), -- indexing; builtin-overloaded List/Vector — candidate for an Index sig
      ("map", scheme [0, 1] (TFn (TFn (sv 0) (sv 1)) (TFn (tList (sv 0)) (tList (sv 1))))),
      ("filter", scheme [0] (TFn (TFn (sv 0) tBool) (TFn (tList (sv 0)) (tList (sv 0))))),
      ("foldl", scheme [0, 1] (TFn (TFn (sv 1) (TFn (sv 0) (sv 1))) (TFn (sv 1) (TFn (tList (sv 0)) (sv 1)))))
    ]

builtinCons' :: TEnv
builtinCons' =
  M.fromList
    [ ("Unit", mono tUnit),
      ("True", mono tBool),
      ("False", mono tBool),
      ("Nil", scheme [0] (tList (sv 0))),
      ("Cons", scheme [0] (TFn (sv 0) (TFn (tList (sv 0)) (tList (sv 0))))),
      ("Ok", scheme [0, 1] (TFn (sv 0) (tcon "Result" [sv 0, sv 1]))),
      ("Err", scheme [0, 1] (TFn (sv 1) (tcon "Result" [sv 0, sv 1]))),
      ("Tup2", scheme [0, 1] (TFn (sv 0) (TFn (sv 1) (TTupT [sv 0, sv 1])))),
      ("Tup3", scheme [0, 1, 2] (TFn (sv 0) (TFn (sv 1) (TFn (sv 2) (TTupT [sv 0, sv 1, sv 2])))))
    ]

-- user `N a b = Type (C τ.. | D τ..).` — constructor schemes; free surface
-- vars in con args that aren't declared params quantify per-constructor
-- (the prelude's `Cmd = Type (Print x | ...)` style)
consEnv :: ShapeAliases -> [STop] -> I TEnv
consEnv aliases tops = M.fromList . concat <$> mapM one [t | t@TType {} <- tops]
  where
    one (TType n _ params cs) = forM cs $ \(c, argTys) -> do
      let ptbl0 = M.fromList (zip params (map TV [-1, -2 ..])) -- placeholder
      -- allocate real vars for params, shared across this con's args
      pvars <- mapM (const freshT) params
      let ptbl = M.fromList (zip params pvars)
      (args, tbl') <- foldM step ([], ptbl) argTys
      let res = foldl' TAp (TC n) pvars
          ty = foldr TFn res (reverse args)
          (tvs, rvs) = ftv ty
      _ <- pure ptbl0
      pure (c, Forall (S.toList tvs) (S.toList rvs) ty)
    one _ = pure []
    step (acc, tbl) ty = do
      (t, tbl') <- tyToTypeA aliases tbl ty
      pure (t : acc, tbl')

-- `n : τ1 -> .. -> τr.` prelude/user annotations become declared schemes
sigAnnEnv :: ShapeAliases -> [STop] -> I TEnv
sigAnnEnv aliases tops = M.fromList <$> mapM one [(n, ps, r) | TSig n (ps, r) <- tops]
  where
    one (n, ps, r) = do
      (t, _) <- tyToTypeA aliases M.empty (foldr TArrT r ps)
      let (tvs, rvs) = ftv t
      pure (n, Forall (S.toList tvs) (S.toList rvs) t)

-- ---- pattern inference ------------------------------------------------------

inferPat :: TEnv -> SPat -> I (Type, TEnv)
inferPat cons = \case
  PWild -> (,M.empty) <$> freshT
  PInt _ -> pure (tInt, M.empty)
  PStr _ -> pure (tStr, M.empty)
  PVar n -> do a <- freshT; pure (a, M.singleton n (mono a))
  PSig n sg -> do
    -- reaches here only if a PSig survives outside a top-level param
    a <- freshT
    _ <- pure sg
    pure (a, M.singleton n (mono a))
  PTup ps -> do
    (ts, envs) <- unzip <$> mapM (inferPat cons) ps
    pure (TTupT ts, M.unions envs)
  PRec ns -> do
    fields <- mapM (\n -> (,) n <$> freshT) ns
    tail' <- freshR
    let row = foldr (\(n, t) r -> RExt n t r) tail' fields
    pure (TRec row, M.fromList [(n, mono t) | (n, t) <- fields])
  PCon c ps -> do
    (ts, envs) <- unzip <$> mapM (inferPat cons) ps
    res <- freshT
    case M.lookup c cons of
      Nothing -> report ("pattern: unknown constructor " ++ c) >> pure (res, M.unions envs)
      Just sc -> do
        ct <- instantiate sc
        unify ("pattern " ++ c) ct (foldr TFn res ts)
        pure (res, M.unions envs)

-- ---- expression inference ---------------------------------------------------

data ICtx = ICtx
  { icEnv :: TEnv, -- values in scope
    icCons :: TEnv, -- constructor schemes (for patterns)
    icSigs :: Sigs
  }

extend :: TEnv -> ICtx -> ICtx
extend e c = c {icEnv = M.union e (icEnv c)}

-- ---- operator resolution sites ----------------------------------------------
--
-- Arith operators (+ - * /) are ROW-DISPATCHED: inference gives each site
-- a type; after solving, each site rewrites by its operand type —
--   Int         -> the primitive opcode (SBin stays)
--   String      -> Str.+            List a -> List.+
--   sig carrier -> s.(+)            (the specializer then monomorphizes)
--   unconstrained -> DEFAULTS to Int (Julia-style numeric default)
-- Inference marks each site (SBin "op#N#+") and resolveSites rewrites.

markerPrefix :: String
markerPrefix = "op#"

newSite :: Name -> Type -> I Int
newSite op t = do
  st <- get
  let n = iNextSite st
  put st {iNextSite = n + 1, iSites = IM.insert n (op, t) (iSites st)}
  pure n

-- carrier var of an in-scope `(s : Sig)` param: var id -> (param, sig)
addCarrier :: Int -> (Name, Name) -> I ()
addCarrier v sn = modify (\st -> st {iCarriers = IM.insert v sn (iCarriers st)})

-- unification may have rebound a carrier var to another var (which then
-- became the representative) — the check must be against zonked reps
carrierReps :: I (IM.IntMap (Name, Name))
carrierReps = do
  cs <- gets iCarriers
  fmap IM.fromList . forM (IM.toList cs) $ \(v, pn) ->
    zonk (TV v) >>= \case
      TV r -> pure (r, pn)
      _ -> pure (v, pn)

inferE :: ICtx -> SExpr -> I (Type, SExpr)
inferE ctx e0 = case e0 of
  SInt n -> pure (tInt, SInt n)
  SAtom a -> pure (tAtom, SAtom a)
  SPath p -> pure (tStr, SPath p) -- @paths are URL strings (STM detail)
  SStrI segs -> do
    segs' <- forM segs $ \case
      SegExpr e -> SegExpr . snd <$> inferE ctx e -- interpolation str's anything
      o -> pure o
    pure (tStr, SStrI segs')
  SVar n -> case M.lookup n (icEnv ctx) of
    Just sc -> (,SVar n) <$> instantiate sc
    Nothing -> case M.lookup n (icCons ctx) of
      Just sc -> (,SVar n) <$> instantiate sc
      Nothing -> do
        report ("unbound name: " ++ n)
        (,SVar n) <$> freshT
  SApp f x -> do
    (tf, f') <- inferE ctx f
    (tx, x') <- inferE ctx x
    r <- freshT
    unify (describe f) tf (TFn tx r)
    pure (r, SApp f' x')
  SLam ps b -> do
    pvs <- mapM (const freshT) ps
    let env' = M.fromList (zip ps (map mono pvs))
    (tb, b') <- inferE (extend env' ctx) b
    pure (foldr TFn tb pvs, SLam ps b')
  SBlock stmts fin -> do
    (stmts', fin', t) <- goBlock ctx stmts
    pure (t, SBlock stmts' fin')
    where
      goBlock c [] = do (t, fin') <- inferE c fin; pure ([], fin', t)
      goBlock c (SBind n ps rhs : rest) = do
        a <- freshT
        let cRec = extend (M.singleton n (mono a)) c
        pvs <- mapM (const freshT) ps
        let env' = M.fromList (zip ps (map mono pvs))
        (tb, rhs') <- inferE (extend env' cRec) rhs
        let t = foldr TFn tb pvs
        unify ("local " ++ n) a t
        sc <-
          if null ps && not (isLamE rhs)
            then pure (mono t)
            else generalize (icEnv c) t
        (rest', fin', tr) <- goBlock (extend (M.singleton n sc) c) rest
        pure (SBind n ps rhs' : rest', fin', tr)
      goBlock c (SBindPat p rhs : rest) = do
        (tr, rhs') <- inferE c rhs
        (tp, benv) <- inferPat (icCons c) p
        unify "let pattern" tp tr
        (rest', fin', tfin) <- goBlock (extend benv c) rest
        pure (SBindPat p rhs' : rest', fin', tfin)
      isLamE SLam {} = True
      isLamE _ = False
  SCase scrut arms -> do
    (ts, scrut') <- inferE ctx scrut
    res <- freshT
    arms' <- forM arms $ \(p, e) -> do
      (tp, benv) <- inferPat (icCons ctx) p
      unify "case scrutinee" tp ts
      (te, e') <- inferE (extend benv ctx) e
      unify "case arm" te res
      pure (p, e')
    pure (res, SCase scrut' arms')
  SBin op a b -> inferBin ctx op a b
  SProj e path -> do
    (te, e') <- inferE ctx e
    t <- foldM projOne te path
    pure (t, SProj e' path)
    where
      projOne t f = do
        a <- freshT
        rest <- freshR
        unify ("projection ." ++ f) t (TRec (RExt f a rest))
        pure a
  SRec fs -> do
    tfs <- forM fs $ \(n, e) -> do (t, e') <- inferE ctx e; pure (n, t, e')
    pure
      ( TRec (foldr (\(n, t, _) r -> RExt n t r) RNil tfs),
        SRec [(n, e') | (n, _, e') <- tfs]
      )
  SUpd m as -> do
    (tm, m') <- inferE ctx m
    as' <- forM as $ \(path, e) -> do
      (te, e') <- inferE ctx e
      constrainPath tm path te
      pure (path, e')
    pure (tm, SUpd m' as')
    where
      constrainPath t [] te = unify "record update" t te
      constrainPath t (f : rest) te = do
        a <- freshT
        tl <- freshR
        unify ("update ." ++ f) t (TRec (RExt f a tl))
        constrainPath a rest te
  STup es -> do
    tes <- mapM (inferE ctx) es
    pure (TTupT (map fst tes), STup (map snd tes))
  SList es -> do
    a <- freshT
    es' <- forM es $ \e -> do
      (t, e') <- inferE ctx e
      unify "list element" a t
      pure e'
    pure (tList a, SList es')

describe :: SExpr -> String
describe = \case
  SVar n -> "application of " ++ n
  SApp f _ -> describe f
  _ -> "application"

inferBin :: ICtx -> Name -> SExpr -> SExpr -> I (Type, SExpr)
inferBin ctx op a b = case op of
  "|>" -> do
    (ta, a') <- inferE ctx a
    (tb, b') <- inferE ctx b
    r <- freshT
    unify "(|>)" tb (TFn ta r)
    pure (r, SBin op a' b')
  ">>" -> do
    (_, a') <- inferE ctx a
    (tb, b') <- inferE ctx b
    pure (tb, SBin op a' b')
  "::" -> do
    (ta, a') <- inferE ctx a
    (tb, b') <- inferE ctx b
    unify "(::)" tb (tList ta)
    pure (tb, SBin op a' b')
  "|>?" -> do
    (ta, a') <- inferE ctx a
    (tb, b') <- inferE ctx b
    x <- freshT; y <- freshT; err <- freshT
    unify "(|>?) source" ta (tcon "Result" [x, err])
    unify "(|>?) fn" tb (TFn x (tcon "Result" [y, err]))
    pure (tcon "Result" [y, err], SBin op a' b')
  _ | op `elem` ["+", "-", "*", "/"] -> do
        (ta, a') <- inferE ctx a
        (tb, b') <- inferE ctx b
        t <- freshT
        unify ("(" ++ op ++ ")") ta t
        unify ("(" ++ op ++ ")") tb t
        site <- newSite op t
        pure (t, SBin (markerPrefix ++ show site ++ "#" ++ op) a' b')
    | op `elem` ["<", "<=", ">", ">="] -> do
        (ta, a') <- inferE ctx a
        (tb, b') <- inferE ctx b
        unify ("(" ++ op ++ ")") ta tInt
        unify ("(" ++ op ++ ")") tb tInt
        pure (tBool, SBin op a' b')
    | op `elem` ["==", "!="] -> do
        (ta, a') <- inferE ctx a
        (tb, b') <- inferE ctx b
        unify ("(" ++ op ++ ")") ta tb
        pure (tBool, SBin op a' b')
    | otherwise -> do
        -- user-defined operator: an ordinary binding applied infix
        (t, _) <- inferE ctx (SVar op)
        (ta, a') <- inferE ctx a
        (tb, b') <- inferE ctx b
        r <- freshT
        unify ("(" ++ op ++ ")") t (TFn ta (TFn tb r))
        pure (r, SBin op a' b')

-- ---- post-solve operator resolution -----------------------------------------

data OpTarget = OpPrim Name | OpGlobal Name | OpProj Name Name -- s.(+)

-- decide every site once the substitution is final
resolveSites :: Sigs -> I (IM.IntMap OpTarget)
resolveSites sigs = do
  sites <- gets iSites
  IM.traverseWithKey one sites
  where
    one _ (op, t0) = do
      t <- zonk t0
      case t of
        TC "Int" -> pure (OpPrim op)
        TC "String"
          | op == "+" -> pure (OpGlobal "Str.+")
          | otherwise -> OpPrim op <$ report ("(" ++ op ++ ") is not defined for String")
        TAp (TC "List") _
          | op == "+" -> pure (OpGlobal "List.+")
          | otherwise -> OpPrim op <$ report ("(" ++ op ++ ") is not defined for List")
        TV v -> do
          carriers <- carrierReps
          case IM.lookup v carriers of
            Just (pn, sg)
              | op `elem` maybe [] (map fst) (M.lookup sg sigs) -> pure (OpProj pn op)
              | otherwise ->
                  OpPrim op <$ report ("(" ++ op ++ ") used at carrier of sig " ++ sg ++ ", which lacks it")
            Nothing -> do
              -- unconstrained: default to Int (numeric default)
              unify "numeric default" (TV v) tInt
              pure (OpPrim op)
        other -> do
          p <- prettyT other
          OpPrim op <$ report ("(" ++ op ++ ") is not defined for " ++ p)

-- rewrite the markers by the decided targets
applySites :: IM.IntMap OpTarget -> SExpr -> SExpr
applySites tgts = go
  where
    go = \case
      SBin op a b
        | Just rest <- stripPrefix markerPrefix op,
          (num, '#' : _rawOp) <- break (== '#') rest,
          Just tgt <- IM.lookup (read num) tgts ->
            case tgt of
              OpPrim o -> SBin o (go a) (go b)
              OpGlobal g -> SApp (SApp (SVar g) (go a)) (go b)
              OpProj s o -> SApp (SApp (SProj (SVar s) [o]) (go a)) (go b)
        | otherwise -> SBin op (go a) (go b)
      SApp a b -> SApp (go a) (go b)
      SLam ps b -> SLam ps (go b)
      SBlock stmts fin -> SBlock (map goS stmts) (go fin)
      SCase s as -> SCase (go s) [(p, go e) | (p, e) <- as]
      SProj e p -> SProj (go e) p
      SRec fs -> SRec [(n, go e) | (n, e) <- fs]
      SUpd m as -> SUpd (go m) [(p, go e) | (p, e) <- as]
      STup es -> STup (map go es)
      SList es -> SList (map go es)
      SStrI segs -> SStrI [seg s | s <- segs]
      o -> o
    goS (SBind n ps e) = SBind n ps (go e)
    goS (SBindPat p e) = SBindPat p (go e)
    seg (SegExpr e) = SegExpr (go e)
    seg o = o

-- ---- top-level driver -------------------------------------------------------

-- infer all top-level bindings; returns errors (empty = well-typed)
typecheck :: Sigs -> Structs -> [STop] -> [String]
typecheck sigs structs tops = let (e, _, _) = inferTops sigs structs tops in e

inferTops :: Sigs -> Structs -> [STop] -> ([String], [(Name, String)], [STop])
inferTops sigs structs tops =
  let (tops', st) = runState run (IEnv 0 IM.empty IM.empty [] [] 0 IM.empty IM.empty)
   in (iErrs st, iNotes st, tops')
  where
    aliases = M.fromList [(n, fs) | TShape n fs <- tops]
    run :: I [STop]
    run = do
      cons <- (\u -> M.union u builtinCons') <$> consEnv aliases tops
      declared <- sigAnnEnv aliases tops
      let env0 = M.union declared builtinEnv
      -- group multi-clause binds under one name, preserving first-seen order
      let bindNames = nub [n | TBind n _ _ _ <- tops]
          clausesOf n = [(ps, g, b) | TBind n' ps g b <- tops, n' == n]
          evals = [e | TEval e <- tops]
          topSet = S.fromList bindNames
          nodes =
            [ (n, n, nub (concatMap refs (clausesOf n)))
              | n <- bindNames
            ]
          refs (ps, g, b) =
            let bound = S.fromList (concatMap patVars ps)
                bound' = S.union bound (S.fromList (concatMap patVars (guardPats g)))
             in topRefs2 topSet bound' b ++ concatMap (topRefs2 topSet bound') (guardExprs g)
          sccs = stronglyConnComp nodes
      (env, rwBinds) <-
        foldM
          (\(e, acc) ns -> do (e', rws) <- inferSCC cons e ns; pure (e', acc ++ rws))
          (env0, [])
          [ns | scc <- sccs, let ns = flat scc]
      -- `> expr.` top-level effects
      let ctx = ICtx env cons sigs
      rwEvals <- forM evals $ \e -> snd <$> inferE ctx e
      -- typed struct conformance
      checkStructConformance sigs structs env
      -- record pretty schemes for reporting (user binds, in file order)
      forM_ bindNames $ \n ->
        forM_ (M.lookup n env) $ \sc -> do
          t <- instantiate sc
          p <- prettyT t
          modify (\s -> s {iNotes = iNotes s ++ [(n, p)]})
      -- resolve operator sites against the final substitution, then
      -- rebuild the top list with markers rewritten, in original order
      tgts <- resolveSites sigs
      let rwMap = M.fromListWith (++) [(n, [(ps, g, b)]) | (n, ps, g, b) <- rwBinds]
          apE = applySites tgts
      let rebuild (evs, bnds) t = case t of
            TEval _ -> case evs of
              (e : rest) -> ((rest, bnds), TEval (apE e))
              [] -> ((evs, bnds), t)
            TBind n _ _ _ -> case M.lookup n bnds of
              Just ((ps, g, b) : more) ->
                ((evs, M.insert n more bnds), TBind n ps (map (mapGuardE apE) g) (apE b))
              _ -> ((evs, bnds), t)
            _ -> ((evs, bnds), t)
          (_, tops') = foldl' (\(st', acc) t -> let (st2, t') = rebuild st' t in (st2, acc ++ [t'])) ((rwEvals, fmap reverse rwMap), []) tops
      pure tops'
    flat (AcyclicSCC n) = [n]
    flat (CyclicSCC ns) = ns

    inferSCC :: TEnv -> TEnv -> [Name] -> I (TEnv, [(Name, [SPat], [SGuard], SExpr)])
    inferSCC cons env ns = do
      -- monomorphic recursion within the SCC
      mvs <- mapM (const freshT) ns
      let recEnv = M.union (M.fromList (zip ns (map mono mvs))) env
      rws <- forM (zip ns mvs) $ \(n, mv) ->
        forM (clauses n) $ \(ps, g, b) -> do
          -- params: PSig gets its sig's record type; others infer
          (ptys, penvs) <- unzip <$> mapM (inferParam cons) ps
          let ctx = ICtx (M.union (M.unions penvs) recEnv) cons sigs
          (ctx2, g') <-
            foldM
              ( \(cx, acc) gd -> case gd of
                  GBool ge -> do
                    (tg, ge') <- inferE cx ge
                    unify ("guard of " ++ n) tg tBool
                    pure (cx, acc ++ [GBool ge'])
                  GPat p ge -> do
                    (tg, ge') <- inferE cx ge
                    (tp, benv) <- inferPat (icCons cx) p
                    unify ("pattern guard of " ++ n) tp tg
                    pure (extend benv cx, acc ++ [GPat p ge'])
              )
              (ctx, [])
              g
          (tb, b') <- inferE ctx2 b
          declaredOrRec n mv (foldr TFn tb ptys)
          pure (n, ps, g', b')
      -- numeric defaulting BEFORE generalization: an op site still at an
      -- unbound non-carrier var here must pin to Int now — otherwise the
      -- scheme generalizes while the site compiles as the Int primitive
      do
        sites <- gets iSites
        reps <- carrierReps
        forM_ (IM.elems sites) $ \(_, t0) -> do
          t <- zonk t0
          case t of
            TV v | not (IM.member v reps) -> unify "numeric default" (TV v) tInt
            _ -> pure ()
      -- generalize against the OUTER env
      newEnv <- forM (zip ns mvs) $ \(n, mv) -> do
        sc <- case M.lookup n env of
          Just declared -> pure declared -- keep the declared scheme
          Nothing -> generalize env mv
        pure (n, sc)
      pure (M.union (M.fromList newEnv) env, concat rws)
      where
        clauses n = [(ps, g, b) | TBind n' ps g b <- tops, n' == n]
        declaredOrRec n mv t = case M.lookup n env of
          Just declared -> do
            dt <- instantiate declared
            unify ("declared type of " ++ n) dt t
          Nothing -> unify ("definition of " ++ n) mv t

    inferParam :: TEnv -> SPat -> I (Type, TEnv)
    inferParam cons p = case p of
      PSig n sg ->
        sigRecType sg >>= \case
          Nothing -> do
            report ("(" ++ n ++ " : " ++ sg ++ "): unknown sig")
            a <- freshT
            pure (a, M.singleton n (mono a))
          Just (t, mcarrier) -> do
            forM_ mcarrier $ \cv -> addCarrier cv (n, sg)
            pure (t, M.singleton n (mono t))
      _ -> inferPat cons p

    sigRecType :: Name -> I (Maybe (Type, Maybe Int))
    sigRecType sg = case M.lookup sg sigs of
      Nothing -> pure Nothing
      Just fields -> do
        (mk, tbl) <- foldM step (id, M.empty) fields
        tl <- freshR
        let carrier = case M.lookup "t" tbl of Just (TV v) -> Just v; _ -> Nothing
        pure (Just (TRec (mk tl), carrier))
      where
        step (acc, tbl) (f, mty) = case mty of
          Nothing -> do t <- freshT; pure (acc . RExt f t, tbl)
          Just ty -> do (t, tbl') <- tyToTypeA aliases tbl ty; pure (acc . RExt f t, tbl')

    -- typed conformance: for struct N implementing Sig, each declared
    -- sig field type must unify with an instantiation of N.f's inferred
    -- scheme — under ONE shared var table per struct/sig pair, so the
    -- carrier `t` is consistent across the sig's fields
    checkStructConformance :: Sigs -> Structs -> TEnv -> I ()
    checkStructConformance sgs sts env =
      forM_ (M.toList sts) $ \(sn, (declSigs, _fields)) ->
        forM_ declSigs $ \sg -> do
          _ <-
            foldM
              ( \tbl (f, mty) -> case (mty, M.lookup (sn ++ "." ++ f) env) of
                  (Just ty, Just sc) -> do
                    have <- instantiate sc
                    (want, tbl') <- tyToTypeA aliases tbl ty
                    unify ("struct " ++ sn ++ " field ." ++ f ++ " vs sig " ++ sg) have want
                    pure tbl'
                  _ -> pure tbl
              )
              M.empty
              (M.findWithDefault [] sg sgs)
          pure ()

    topRefs2 topSet bound e = [n | n <- coll bound e, S.member n topSet]
      where
        coll bs = \case
          SVar v | not (S.member v bs) -> [v]
          SApp a b -> coll bs a ++ coll bs b
          SLam ps x -> coll (bs <> S.fromList ps) x
          SBlock stmts fin -> gos bs stmts fin
          SCase s as -> coll bs s ++ concat [coll (bs <> S.fromList (patVars p)) x | (p, x) <- as]
          SBin _ a b -> coll bs a ++ coll bs b
          SProj x _ -> coll bs x
          SRec fs -> concatMap (coll bs . snd) fs
          SUpd m as -> coll bs m ++ concatMap (coll bs . snd) as
          STup es -> concatMap (coll bs) es
          SList es -> concatMap (coll bs) es
          SStrI segs -> concat [coll bs x | SegExpr x <- segs]
          _ -> []
        gos bs [] fin = coll bs fin
        gos bs (SBind n ps x : rest) fin = coll (bs <> S.fromList (n : ps)) x ++ gos (S.insert n bs) rest fin
        gos bs (SBindPat p x : rest) fin = coll bs x ++ gos (bs <> S.fromList (patVars p)) rest fin

-- ---- pretty printing --------------------------------------------------------

prettyT :: Type -> I String
prettyT t0 = do t <- zonk t0; pure (go 0 t)
  where
    go :: Int -> Type -> String
    go p = \case
      TV v -> tvName v
      TC n -> n
      TAp a b -> paren (p > 9) (go 9 a ++ " " ++ go 10 b)
      TFn a b -> paren (p > 0) (go 1 a ++ " -> " ++ go 0 b)
      TTupT ts -> "(" ++ intercalate ", " (map (go 0) ts) ++ ")"
      TRec r -> "{" ++ rowStr r ++ "}"
    rowStr = \case
      RNil -> ""
      RV v -> tvName v
      RExt l t r -> l ++ " : " ++ go 0 t ++ next r
    next = \case
      RNil -> ""
      RV v -> " | " ++ tvName v
      r@RExt {} -> ", " ++ rowStr r
    paren True s = "(" ++ s ++ ")"
    paren False s = s
    tvName v = let l = ['a' ..] !! (v `mod` 26) in l : (if v >= 26 then show (v `div` 26) else "")

prettyRow :: Row -> I String
prettyRow r = do
  s <- prettyT (TRec r)
  pure s
