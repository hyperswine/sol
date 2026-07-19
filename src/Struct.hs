{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- Struct.hs — sigs, structs, and compile-time specialization.
--
-- The design (per the stdlib discussion): signatures are named rows of
-- field names; structures are records that implement them; generic
-- functions take `(s : Sig)` params. Resolution is a compile-time search:
--
--   * `struct N : S1, S2 = {...}` expands to flat globals `N.f` (the same
--     discipline module aliases already use) plus a first-class record
--     global `N = {f = N.f, ...}`, after checking N's fields cover each
--     declared sig's row.
--   * a call `g N xs` where g's first param is `(s : Sig)` and N is a
--     known struct is MONOMORPHIZED: conformance of N against Sig is
--     checked structurally (fields ⊇ row — the row IS the sig), and the
--     call is rewritten to `g#N xs`, a specialized clone in which `s.f`
--     became the direct global `N.f` and bare `s` became `N`. Clones are
--     re-scanned, so generics calling generics specialize transitively
--     (the worklist bottoms out via a seen-set).
--   * a call whose sig-arg is NOT a struct literal is left alone: the
--     annotation erases to a plain param and the struct RECORD flows in
--     at runtime, dispatched by the existing record-shape machinery —
--     first-class fallback, no types needed.
--
-- This is deliberately name-level (no inference yet): the "row check" is
-- field-name coverage. When HM + row types land, conformance tightens to
-- type-level and the specializer's search becomes type-directed; the
-- pass structure stays the same.

module Struct where

import Data.List (foldl', intercalate, (\\))
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Lang

-- ---- tables -----------------------------------------------------------------

type Sigs = M.Map Name [Name] -- sig name -> row (field names)

type Structs = M.Map Name ([Name], [Name]) -- struct -> (declared sigs, fields)

type Generics = M.Map Name [(Int, Name)] -- fn -> sig-annotated param positions

sigTable :: [STop] -> Sigs
sigTable tops = M.fromList [(n, fs) | TSigDef n fs <- tops]

structTable :: [STop] -> Structs
structTable tops = M.fromList [(n, (sigs, map fst fs)) | TStruct n sigs fs <- tops]

genericTable :: [STop] -> Generics
genericTable tops =
  M.fromList
    [ (n, anns)
      | TBind n ps _ _ <- tops,
        let anns = [(i, sg) | (i, PSig _ sg) <- zip [0 ..] ps],
        not (null anns)
    ]

-- ---- struct expansion + declared-conformance check --------------------------

-- a struct's fields must cover every declared sig's row
conformErrs :: Sigs -> Name -> [Name] -> [Name] -> [String]
conformErrs sigs sname declared fields = concatMap one declared
  where
    one sg = case M.lookup sg sigs of
      Nothing -> ["struct " ++ sname ++ ": unknown sig " ++ sg]
      Just row -> case row \\ fields of
        [] -> []
        missing ->
          [ "struct " ++ sname ++ " does not satisfy sig " ++ sg
              ++ ": missing " ++ intercalate ", " missing
          ]

-- expand `struct N : ... = {f = e, ...}` into:
--   N.f = e.          (an n-ary function if e is a lambda, else a CAF)
--   N   = {f = N.f, ...}   (the first-class record — the fallback path)
expandStructs :: [STop] -> ([String], [STop])
expandStructs tops = (errs, concatMap one tops)
  where
    sigs = sigTable tops
    errs =
      concat [conformErrs sigs n ss (map fst fs) | TStruct n ss fs <- tops]
        ++ dups
    dups =
      [ "duplicate struct/sig name: " ++ n
        | n <- M.keys (M.filter (> (1 :: Int)) counts)
      ]
    counts =
      foldl' (\m n -> M.insertWith (+) n 1 m) M.empty $
        [n | TSigDef n _ <- tops] ++ [n | TStruct n _ _ <- tops]
    one = \case
      TStruct n _ fs ->
        [fieldBind (qual n f) e | (f, e) <- fs]
          ++ [TBind n [] Nothing (SRec [(f, SVar (qual n f)) | (f, _) <- fs])]
      t -> [t]
    qual n f = n ++ "." ++ f
    -- a lambda field becomes a real n-ary global (direct CALLs, JITtable);
    -- anything else is a zero-arity CAF
    fieldBind g (SLam ps b) = TBind g (map PVar ps) Nothing b
    fieldBind g e = TBind g [] Nothing e

-- ---- specialization (compile-time search + monomorphization) ----------------

specName :: Name -> [(Int, Name)] -> Name
specName f chosen = f ++ concat ["#" ++ s | (_, s) <- chosen]

-- binder-aware substitution for one specialized clone:
--   s.f ...rest  ->  (N.f) ...rest      (direct flat global)
--   s            ->  N                  (the record, for pass-through)
substStruct :: M.Map Name Name -> SExpr -> SExpr
substStruct sub = transformE step S.empty
  where
    -- transformE rewrites BOTTOM-UP: by the time the SProj node is seen,
    -- its head `s` has already become the struct name. So: rewrite vars
    -- first (guarded by bs — seeded empty, membership means locally
    -- shadowed), then flatten projections whose head is a substituted-in
    -- struct name into the flat global (`Num.add`) — the monomorphization.
    -- Struct names are uppercase, locals lowercase: no collision.
    targets = S.fromList (M.elems sub)
    step bs e = case e of
      SProj (SVar n) (f : rest)
        | S.member n targets ->
            let base = SVar (n ++ "." ++ f)
             in if null rest then base else SProj base rest
      SVar s | Just n <- M.lookup s sub, not (S.member s bs) -> SVar n
      _ -> e

data SpecSt = SpecSt
  { spSeen :: S.Set Name, -- specialized names already generated
    spNew :: [STop], -- generated clones (worklist output)
    spErrs :: [String]
  }

specialize :: Sigs -> Structs -> [STop] -> ([String], [STop])
specialize sigs structs tops0 = go 0 tops0 (SpecSt S.empty [] [])
  where
    generics0 = genericTable tops0
    -- bodies of generic functions, for cloning
    genBodies =
      M.fromList
        [(n, (ps, g, b)) | TBind n ps g b <- tops0, M.member n generics0]

    go :: Int -> [STop] -> SpecSt -> ([String], [STop])
    go depth tops st
      | depth > 32 = (spErrs st ++ ["specialize: recursion limit (generic call cycle through structs?)"], tops)
      | otherwise =
          let (tops', st') = rewriteTops tops st
           in case spNew st' of
                [] -> (spErrs st', tops')
                new ->
                  let (errs2, tops'') = go (depth + 1) (tops' ++ new) st' {spNew = []}
                   in (errs2, tops'')

    rewriteTops :: [STop] -> SpecSt -> ([STop], SpecSt)
    rewriteTops tops st = foldr top ([], st) tops
      where
        top t (acc, s) = let (t', s') = rwTop t s in (t' : acc, s')
        rwTop t s = case t of
          TBind n ps g b ->
            let (g', s1) = maybe (Nothing, s) (\e -> let (e', sx) = rwE e s in (Just e', sx)) g
                (b', s2) = rwE b s1
             in (TBind n ps g' b', s2)
          TEval e -> let (e', s') = rwE e s in (TEval e', s')
          o -> (o, s)

    -- bottom-up rewrite; state-threading version of transformE, spine-aware
    rwE :: SExpr -> SpecSt -> (SExpr, SpecSt)
    rwE e0 st = case e0 of
      SApp {} -> rwSpine e0 st
      SVar {} -> rwSpine e0 st -- bare generic ref: 0-arg spine (no rewrite)
      SLam ps b -> let (b', s) = rwE b st in (SLam ps b', s)
      SBlock stmts fin ->
        let (stmts', s1) = foldr stmt ([], st) stmts
            (fin', s2) = rwE fin s1
         in (SBlock stmts' fin', s2)
        where
          stmt (SBind n ps x) (acc, s) = let (x', s') = rwE x s in (SBind n ps x' : acc, s')
          stmt (SBindPat p x) (acc, s) = let (x', s') = rwE x s in (SBindPat p x' : acc, s')
      SCase sc alts ->
        let (sc', s1) = rwE sc st
            (alts', s2) = foldr alt ([], s1) alts
         in (SCase sc' alts', s2)
        where
          alt (p, e) (acc, s) = let (e', s') = rwE e s in ((p, e') : acc, s')
      SBin op a b ->
        let (a', s1) = rwE a st; (b', s2) = rwE b s1 in (SBin op a' b', s2)
      SProj e path -> let (e', s) = rwE e st in (SProj e' path, s)
      SRec fs ->
        let (fs', s) = foldr fld ([], st) fs in (SRec fs', s)
        where
          fld (n, e) (acc, s) = let (e', s') = rwE e s in ((n, e') : acc, s')
      SUpd m as ->
        let (m', s1) = rwE m st
            (as', s2) = foldr fld ([], s1) as
         in (SUpd m' as', s2)
        where
          fld (p, e) (acc, s) = let (e', s') = rwE e s in ((p, e') : acc, s')
      STup es -> let (es', s) = list es st in (STup es', s)
      SList es -> let (es', s) = list es st in (SList es', s)
      SStrI segs ->
        let (segs', s) = foldr seg ([], st) segs in (SStrI segs', s)
        where
          seg (SegExpr e) (acc, s) = let (e', s') = rwE e s in (SegExpr e' : acc, s')
          seg o (acc, s) = (o : acc, s)
      other -> (other, st)
      where
        list es s0 = foldr (\e (acc, s) -> let (e', s') = rwE e s in (e' : acc, s')) ([], s0) es

    -- an application spine `f a1 .. an`: if f is generic and every
    -- sig-annotated position within reach holds a struct literal, check
    -- conformance and monomorphize
    rwSpine :: SExpr -> SpecSt -> (SExpr, SpecSt)
    rwSpine e st =
      let (h, args) = spineS e
          (args', st1) = foldr (\a (acc, s) -> let (a', s') = rwE a s in (a' : acc, s')) ([], st) args
          rebuilt = foldl' SApp h args'
       in case h of
            SVar f
              | Just anns <- M.lookup f generics0,
                all (\(i, _) -> i < length args') anns,
                Just chosen <- mapM (\(i, sg) -> (,) i . (,) sg <$> structArg (args' !! i)) anns ->
                  -- chosen :: [(Int, (SigName, StructName))]
                  let cerrs = concatMap (\(_, (sg, sn)) -> callConform f sg sn) chosen
                      picks = [(i, sn) | (i, (_, sn)) <- chosen]
                      nm = specName f picks
                      keep = [a | (i, a) <- zip [0 ..] args', i `notElem` map fst picks]
                      call = foldl' SApp (SVar nm) keep
                   in if not (null cerrs)
                        then (rebuilt, st1 {spErrs = spErrs st1 ++ cerrs})
                        else
                          if S.member nm (spSeen st1)
                            then (call, st1)
                            else case mkClone f picks nm of
                              Nothing -> (rebuilt, st1) -- no body (HAL?) — leave it
                              Just clone ->
                                ( call,
                                  st1
                                    { spSeen = S.insert nm (spSeen st1),
                                      spNew = clone : spNew st1
                                    }
                                )
            _ -> (rebuilt, st1)

    structArg (SVar n) | M.member n structs = Just n
    structArg _ = Nothing

    -- structural row check at the call site: the row IS the sig
    callConform f sg sn = case (M.lookup sg sigs, M.lookup sn structs) of
      (Nothing, _) -> ["call of " ++ f ++ ": unknown sig " ++ sg]
      (_, Nothing) -> []
      (Just row, Just (_, fields)) -> case row \\ fields of
        [] -> []
        missing ->
          [ "call of " ++ f ++ " with struct " ++ sn
              ++ ": does not satisfy " ++ sg
              ++ " (missing " ++ intercalate ", " missing ++ ")"
          ]

    -- clone f's body with sig params at `picks` positions dropped and
    -- substituted by their struct
    mkClone :: Name -> [(Int, Name)] -> Name -> Maybe STop
    mkClone f picks nm = do
      (ps, g, b) <- M.lookup f genBodies
      let pickM = M.fromList picks
          sub =
            M.fromList
              [ (v, sn)
                | (i, PSig v _) <- zip [0 ..] ps,
                  Just sn <- [M.lookup i pickM]
              ]
          ps' = [p | (i, p) <- zip [0 ..] ps, not (M.member i pickM)]
          rep = substStruct sub
      pure (TBind nm ps' (fmap rep g) (rep b))

spineS :: SExpr -> (SExpr, [SExpr])
spineS = go []
  where
    go acc (SApp a b) = go (b : acc) a
    go acc h = (h, acc)

-- after specialization, remaining sig annotations erase to plain params:
-- the first-class record flows in at runtime (shape-dispatched projection)
erasePSig :: [STop] -> [STop]
erasePSig = map top
  where
    top (TBind n ps g b) = TBind n (map ep ps) g b
    top (TSigDef _ _) = TSkip -- consumed by the tables; nothing downstream
    top t = t
    ep (PSig n _) = PVar n
    ep (PCon c ps) = PCon c (map ep ps)
    ep (PTup ps) = PTup (map ep ps)
    ep p = p

-- the whole pass: expand structs, check, specialize, erase
structPass :: [STop] -> ([String], [STop])
structPass tops =
  let sigs = sigTable tops
      (e1, tops1) = expandStructs tops
      structs = structTable tops -- from the ORIGINAL tops (pre-expansion)
      (e2, tops2) = specialize sigs structs tops1
   in (e1 ++ e2, erasePSig tops2)
