{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- Width.hs — Numeric width analysis (the optimization tier, per the
-- README's "Numeric widths: optimization types, not semantics").
--
-- The surface type stays Int. This pass classifies each PRIMITIVE arith
-- op site (post-resolution, so any remaining SBin +-*/ IS an Int site)
-- by a conservative interval analysis:
--
--   * literals are exact; intervals combine through + - * / and ::case
--     joins; anything unknown is TOP
--   * one level of interprocedural seeding: a function whose EVERY call
--     site passes a literal (or literal-interval) argument gets that
--     join as the param's interval — enough for constant-driven code
--     (Numeric.clamp 0 10 42, fixed-point scale factors) without a full
--     fixpoint
--   * a site is i32-ELIGIBLE when its operands and result provably fit
--     [-2^31, 2^31)
--
-- Output is advisory: SOL_WIDTHS=1 prints per-function counts and the
-- fully-narrow functions — the candidates a width-aware JIT tier would
-- compile with i32 registers (and, later, the seam where f32/f64 enter).
-- Nothing downstream consumes the hints yet; the analysis is the
-- opportunity DETECTOR, deliberately separate from semantics.

module Width where

import Data.List (foldl')
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Lang

-- ---- intervals --------------------------------------------------------------

data B = NegInf | Fin Integer | PosInf deriving (Eq, Ord, Show)

data Iv = Iv B B | TopIv deriving (Eq, Show) -- TopIv = unknown / non-int

exact :: Integer -> Iv
exact n = Iv (Fin n) (Fin n)

joinIv :: Iv -> Iv -> Iv
joinIv TopIv _ = TopIv
joinIv _ TopIv = TopIv
joinIv (Iv a b) (Iv c d) = Iv (min a c) (max b d)

addB :: B -> B -> B
addB (Fin a) (Fin b) = Fin (a + b)
addB NegInf PosInf = PosInf -- unreachable in well-formed bounds use
addB PosInf _ = PosInf
addB _ PosInf = PosInf
addB NegInf _ = NegInf
addB _ NegInf = NegInf

negB :: B -> B
negB (Fin a) = Fin (negate a)
negB NegInf = PosInf
negB PosInf = NegInf

mulB :: B -> B -> B
mulB (Fin a) (Fin b) = Fin (a * b)
mulB a b -- infinity times anything: sign bookkeeping, coarse is fine here
  | a == PosInf || b == PosInf || a == NegInf || b == NegInf =
      if (isNeg a && isNeg b) || (isPos a && isPos b) then PosInf else NegInf
  | otherwise = PosInf
  where
    isNeg NegInf = True
    isNeg (Fin x) = x < 0
    isNeg PosInf = False
    isPos PosInf = True
    isPos (Fin x) = x > 0
    isPos NegInf = False

arith :: Name -> Iv -> Iv -> Iv
arith _ TopIv _ = TopIv
arith _ _ TopIv = TopIv
arith op (Iv a b) (Iv c d) = case op of
  "+" -> Iv (addB a c) (addB b d)
  "-" -> Iv (addB a (negB d)) (addB b (negB c))
  "*" ->
    let ps = [mulB x y | x <- [a, b], y <- [c, d]]
     in Iv (minimum ps) (maximum ps)
  "/" -> case (c, d) of
    -- division shrinks magnitude for divisor |d| >= 1; if the divisor
    -- range includes 0 or is unknown-signed, stay coarse but bounded by
    -- the numerator's magnitude
    _ -> Iv (minB [a, negB b]) (maxB [b, negB a])
  _ -> TopIv
  where
    minB = foldr1 min
    maxB = foldr1 max

fitsI32 :: Iv -> Bool
fitsI32 TopIv = False
fitsI32 (Iv (Fin lo) (Fin hi)) = lo >= -2147483648 && hi <= 2147483647
fitsI32 _ = False

-- ---- analysis ---------------------------------------------------------------

data WStats = WStats {wI32 :: !Int, wI64 :: !Int} deriving (Show)

instance Semigroup WStats where WStats a b <> WStats c d = WStats (a + c) (b + d)

instance Monoid WStats where mempty = WStats 0 0

type ParamSeeds = M.Map Name [Iv] -- fn -> interval per param position

-- pass 1: join literal-interval arguments across every call site of each
-- named function; a single non-literal call site tops the param
collectSeeds :: [STop] -> ParamSeeds
collectSeeds tops = M.mapWithKey trim (foldl' top M.empty tops)
  where
    arities = M.fromList [(n, length ps) | TBind n ps _ _ <- tops]
    trim n ivs = take (M.findWithDefault 0 n arities) ivs
    top acc = \case
      TBind _ _ g b -> maybe id goE g (goE b acc)
      TEval e -> goE e acc
      _ -> acc
    goE e acc0 = case spine e of
      (SVar f, args)
        | Just ar <- M.lookup f arities,
          length args == ar,
          ar > 0 ->
            let ivs = map litIv args
             in foldl' (flip goE) (M.insertWith (zipWith joinIv) f ivs acc0) args
      (h, args) -> foldl' (flip goE) (goH h acc0) args
    goH = \case
      SLam _ b -> goE b
      SBlock stmts fin -> \a -> goE fin (foldl' (\ac st -> case st of SBind _ _ x -> goE x ac; SBindPat _ x -> goE x ac) a stmts)
      SCase s as -> \a -> foldl' (\ac (_, x) -> goE x ac) (goE s a) as
      SBin _ a b -> \ac -> goE b (goE a ac)
      SProj x _ -> goE x
      SRec fs -> \a -> foldl' (\ac (_, x) -> goE x ac) a fs
      SUpd m as -> \a -> foldl' (\ac (_, x) -> goE x ac) (goE m a) as
      STup es -> \a -> foldl' (flip goE) a es
      SList es -> \a -> foldl' (flip goE) a es
      SStrI segs -> \a -> foldl' (\ac -> \case SegExpr x -> goE x ac; _ -> ac) a segs
      _ -> id
    litIv (SInt n) = exact n
    litIv (SBin "-" (SInt a) (SInt b)) = exact (a - b) -- 0 - 999999 idiom
    litIv _ = TopIv
    spine = go []
      where
        go acc (SApp a b) = go (b : acc) a
        go acc h = (h, acc)

-- pass 2: per function, interpret with seeded params; classify prim sites
analyze :: [STop] -> [(Name, WStats)]
analyze tops =
  [ (n, snd (goE env0 b) <> maybe mempty (snd . goE env0) g)
    | TBind n ps g b <- tops,
      let seeds = M.findWithDefault (repeat TopIv) n seedTbl
          env0 = M.fromList (zip (concatMap patVars ps) (seeds ++ repeat TopIv))
  ]
  where
    seedTbl = collectSeeds tops
    -- returns (interval of the expr, site stats within it)
    goE :: M.Map Name Iv -> SExpr -> (Iv, WStats)
    goE env = \case
      SInt n -> (exact n, mempty)
      SVar v -> (M.findWithDefault TopIv v env, mempty)
      SBin op a b
        | op `elem` ["+", "-", "*", "/"] ->
            let (ia, sa) = goE env a
                (ib, sb) = goE env b
                r = arith op ia ib
                site = if fitsI32 ia && fitsI32 ib && fitsI32 r then WStats 1 0 else WStats 0 1
             in (r, sa <> sb <> site)
        | otherwise ->
            let (_, sa) = goE env a; (_, sb) = goE env b in (TopIv, sa <> sb)
      SApp f x -> (TopIv, snd (goE env f) <> snd (goE env x))
      SLam ps b ->
        let env' = M.union (M.fromList [(p, TopIv) | p <- ps]) env
         in (TopIv, snd (goE env' b))
      SBlock stmts fin -> goBlock env stmts
        where
          goBlock e [] = goE e fin
          goBlock e (SBind v ps rhs : rest)
            | null ps =
                let (iv, s) = goE e rhs
                    (ir, sr) = goBlock (M.insert v iv e) rest
                 in (ir, s <> sr)
            | otherwise =
                let env' = M.union (M.fromList [(p, TopIv) | p <- ps]) e
                    (_, s) = goE env' rhs
                    (ir, sr) = goBlock (M.insert v TopIv e) rest
                 in (ir, s <> sr)
          goBlock e (SBindPat p rhs : rest) =
            let (_, s) = goE e rhs
                e' = M.union (M.fromList [(v, TopIv) | v <- patVars p]) e
                (ir, sr) = goBlock e' rest
             in (ir, s <> sr)
      SCase s as ->
        let (_, ss) = goE env s
            armR (p, x) =
              let env' = M.union (M.fromList [(v, TopIv) | v <- patVars p]) env
               in goE env' x
            rs = map armR as
         in (foldr (joinIv . fst) (Iv PosInf NegInf `orFirst` rs) (drop 1 rs), ss <> foldMap snd rs)
        where
          orFirst dflt xs = case xs of ((iv, _) : _) -> iv; [] -> dflt
      SProj e _ -> (TopIv, snd (goE env e))
      SRec fs -> (TopIv, foldMap (snd . goE env . snd) fs)
      SUpd m as -> (TopIv, snd (goE env m) <> foldMap (snd . goE env . snd) as)
      STup es -> (TopIv, foldMap (snd . goE env) es)
      SList es -> (TopIv, foldMap (snd . goE env) es)
      SStrI segs -> (TopIv, foldMap (\case SegExpr x -> snd (goE env x); _ -> mempty) segs)
      _ -> (TopIv, mempty)

-- advisory report: per-function counts, plus fully-narrow candidates
widthReport :: [STop] -> [String]
widthReport tops =
  let per = [(n, st) | (n, st) <- analyze tops, wI32 st + wI64 st > 0]
      narrow = [n | (n, WStats i o) <- per, o == 0, i > 0]
      line (n, WStats i o) = "  " ++ n ++ ": " ++ show i ++ "/" ++ show (i + o) ++ " arith sites i32-provable"
   in map line per
        ++ [ "  fully-narrow (JIT i32 candidates): " ++ unwords narrow
             | not (null narrow)
           ]
