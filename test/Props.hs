{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- test/Props.hs — property-based tests for Sol.
--
-- Strategy: a typed generator produces random well-typed Sol programs
-- together with an in-Haskell REFERENCE EVALUATOR written directly against
-- SEMANTICS.txt (strict, call-by-value, lexical scope, first-match-wins
-- clauses, guard fallthrough, quot division). Every generated program is
-- pushed through the REAL pipeline in-process — parse, sig/struct
-- expansion, HM inference, specialization, linearity, desugar,
-- lambda-lift, bytecode, VM — and the VM's answer is compared against the
-- reference's. Divergence means one of the two is wrong about the
-- semantics, which is exactly the conversation we want to have.
--
-- Build & run (from repo root):
--   ghc -O0 -threaded -isrc -itest -o props test/Props.hs cbits/shim.o \
--       -L$(llvm-config --libdir) -lLLVM-18
--   ./props
--
-- Uses hedgehog (integrated shrinking: counterexamples arrive minimized).

module Main where

import Bytecode (compileProg)
import Control.Exception (SomeException, try)
import Control.Monad (unless)
import Control.Monad.State.Strict (runState)
import Data.IORef (newIORef)
import Data.List (intercalate, sortOn)
import qualified Data.Map.Strict as M
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Infer (inferTops)
import Lang
import Preamble (halArities, prelude)
import Struct (erasePSig, expandStructs, sigTable, specialize, structTable)
import System.Exit (exitFailure)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import Text.Megaparsec (errorBundlePretty, parse)
import Txn (newTx)
import VM
import qualified Val

--------------------------------------------------------------------------------
-- The in-process pipeline: same stages as Main.hs, minus modules/JIT/txn loop
--------------------------------------------------------------------------------

-- Compile a source string and evaluate the zero-arg binding `ptest`,
-- returning the rendered result or a phase-tagged error.
runSol :: String -> IO (Either String String)
runSol userSrc = do
  case (,) <$> parse program "<prelude>" prelude <*> parse program "<prop>" userSrc of
    Left eb -> pure (Left ("PARSE: " ++ errorBundlePretty eb))
    Right (ptops, utops) -> do
      let sigs = sigTable (ptops ++ utops)
          structs = structTable (ptops ++ utops)
          (perrs, ptopsExp) = expandStructs sigs ptops
          (uerrs, utopsExp) = expandStructs sigs utops
      if not (null (perrs ++ uerrs))
        then pure (Left ("SIG/STRUCT: " ++ unlines (perrs ++ uerrs)))
        else do
          let (terrs, _notes, rewritten) = inferTops sigs structs (ptopsExp ++ utopsExp)
          if not (null terrs)
            then pure (Left ("TYPES: " ++ unlines terrs))
            else do
              let (serrs, topsSpec) = specialize sigs structs rewritten
                  allX = erasePSig topsSpec
              if not (null serrs)
                then pure (Left ("SIG/STRUCT2: " ++ unlines serrs))
                else do
                  let li = buildLinInfo allX
                      lerrs = lcheck li allX
                  if not (null lerrs)
                    then pure (Left ("LINEARITY: " ++ unlines lerrs))
                    else do
                      let cons = collectCons allX
                          shapes = collectShapes allX
                          (prog, _) = runState (compileTop allX >>= liftFix) (DEnv 0 cons shapes [])
                          bprog = compileProg halArities prog
                      tx <- newTx
                      preempts <- newIORef 0
                      fuel <- newIORef fuelQuantum
                      let env =
                            VMEnv
                              { vmBaseDir = ".",
                                vmDataFile = "/tmp/props.soldata",
                                vmCons = M.map (\(t, v, _) -> (t, v)) cons,
                                vmShapes = M.fromList [(tid, fs) | (fs, tid) <- M.toList shapes],
                                vmProg = bprog,
                                vmCore = prog,
                                vmJit = Nothing,
                                vmHal = mkHal cons tx preempts,
                                vmFuel = fuel,
                                vmPreempts = preempts
                              }
                      r <- try (execFn env "ptest" [])
                      pure $ case r of
                        Left (e :: SomeException) -> Left ("RUNTIME: " ++ show e)
                        Right v -> Right (Val.render v)

-- Parse only (for AST-level properties).
parseSol :: String -> Either String [STop]
parseSol s = either (Left . errorBundlePretty) Right (parse program "<prop>" s)

--------------------------------------------------------------------------------
-- Generated language: a first-order typed fragment of Sol
--------------------------------------------------------------------------------

data GTy = TI | TB | TS | TL GTy | TP GTy GTy
  deriving (Eq, Show)

data GE
  = GI Integer
  | GS String
  | GB Bool
  | GV String
  | GBin String GE GE          -- + - * / == != < <= > >= (:: and ! separate)
  | GCons GE GE
  | GIndex GE Int              -- xs ! k, k statically in range
  | GIf GE GE GE               -- case c of True -> a | False -> b
  | GCaseL GE GE (String, String) GE -- case xs of [] -> e0 | h :: t -> e1
  | GCaseP GE (String, String) GE    -- case p of (a, b) -> e
  | GLam1 String GTy GE        -- fn x -> e   (annotated for the ref)
  | GApp GE GE
  | GPipe GE GE                -- e |> f
  | GDollar GE GE              -- f $ e
  | GList [GE]
  | GPair GE GE
  | GInterp [Either String GE] -- "seg{e}seg..."
  | GCall String [GE]          -- helper or struct/HAL call by name
  deriving (Show)

-- one generated top-level helper: name, params (typed), clauses.
-- Each clause: param patterns + optional guard + body. Rendered as real
-- multi-clause Sol; the reference implements first-match-wins + guard
-- fallthrough per SEMANTICS.txt.
data GClause = GClause [GPatG] (Maybe GE) GE deriving (Show)

data GPatG = PGVar String | PGWild | PGLit Integer | PGNil | PGConsP String String
  deriving (Show)

data GDef = GDef String [GTy] GTy [GClause] deriving (Show)

--------------------------------------------------------------------------------
-- Rendering to Sol source (fully parenthesized except where sugar is the point)
--------------------------------------------------------------------------------

rE :: GE -> String
rE e0 = case e0 of
  GI n | n < 0 -> "(0 - " ++ show (abs n) ++ ")"
       | otherwise -> show n
  GS s -> show s
  GB b -> if b then "True" else "False"
  GV x -> x
  GBin op a b -> "(" ++ rE a ++ " " ++ op ++ " " ++ rE b ++ ")"
  GCons a b -> "(" ++ rE a ++ " :: " ++ rE b ++ ")"
  GIndex a k -> "(" ++ rE a ++ " ! " ++ show k ++ ")"
  GIf c a b -> "(case " ++ rE c ++ " of True -> " ++ rE a ++ " | False -> " ++ rE b ++ ")"
  GCaseL s e0' (h, t) e1 ->
    "(case " ++ rE s ++ " of [] -> " ++ rE e0' ++ " | " ++ h ++ " :: " ++ t ++ " -> " ++ rE e1 ++ ")"
  GCaseP s (a, b) e ->
    "(case " ++ rE s ++ " of (" ++ a ++ ", " ++ b ++ ") -> " ++ rE e ++ ")"
  GLam1 x _ e -> "(fn " ++ x ++ " -> " ++ rE e ++ ")"
  GApp f a -> "(" ++ rE f ++ " " ++ rE a ++ ")"
  GPipe a f -> "(" ++ rE a ++ " |> " ++ rE f ++ ")"
  GDollar f a -> "(" ++ rE f ++ " $ " ++ rE a ++ ")"
  GList xs -> "[" ++ intercalate ", " (map rE xs) ++ "]"
  GPair a b -> "(" ++ rE a ++ ", " ++ rE b ++ ")"
  GInterp segs -> "\"" ++ concatMap seg segs ++ "\""
    where
      seg (Left s) = s
      seg (Right e) = "{" ++ rE e ++ "}"
  GCall f as -> "(" ++ f ++ " " ++ unwords (map rE as) ++ ")"

rPat :: GPatG -> String
rPat (PGVar x) = x
rPat PGWild = "_"
rPat (PGLit n) = show n
rPat PGNil = "[]"
rPat (PGConsP h t) = "(" ++ h ++ " :: " ++ t ++ ")"

rDef :: GDef -> String
rDef (GDef n _ _ cls) = unlines (map one cls)
  where
    one (GClause ps mg body) =
      n ++ " " ++ unwords (map rPat ps)
        ++ maybe "" (\g -> " | " ++ rE g) mg
        ++ " = " ++ rE body ++ "."

rProgram :: [GDef] -> GE -> String
rProgram defs e = concatMap rDef defs ++ "ptest = " ++ rE e ++ ".\n"

--------------------------------------------------------------------------------
-- Reference evaluator (SEMANTICS.txt made executable)
--------------------------------------------------------------------------------

data RV
  = RI Integer
  | RS String
  | RB Bool
  | RL [RV]
  | RP RV RV
  | RF String GE REnv          -- closure: lexical scope per SEMANTICS.txt
  deriving (Show)

type REnv = [(String, RV)]

rvEq :: RV -> RV -> Bool
rvEq (RI a) (RI b) = a == b
rvEq (RS a) (RS b) = a == b
rvEq (RB a) (RB b) = a == b
rvEq (RL a) (RL b) = length a == length b && and (zipWith rvEq a b)
rvEq (RP a b) (RP c d) = rvEq a c && rvEq b d
rvEq _ _ = False

-- must agree with Val.render for first-order values
rvRender :: RV -> String
rvRender (RI n) = show n
rvRender (RS s) = s
rvRender (RB b) = if b then "True" else "False"
rvRender (RL xs) = "[" ++ intercalate ", " (map rvRender xs) ++ "]"
rvRender (RP a b) = "(" ++ rvRender a ++ ", " ++ rvRender b ++ ")"
rvRender RF {} = "<fn>"

type Defs = M.Map String GDef

refEval :: Defs -> REnv -> GE -> Either String RV
refEval ds env e0 = case e0 of
  GI n -> Right (RI n)
  GS s -> Right (RS s)
  GB b -> Right (RB b)
  GV x -> maybe (Left ("unbound " ++ x)) Right (lookup x env)
  GBin op a b -> do
    va <- go a; vb <- go b            -- CBV, left to right
    binop op va vb
  GCons a b -> do
    va <- go a
    vb <- go b
    case vb of RL xs -> Right (RL (va : xs)); _ -> Left "cons: not a list"
  GIndex a k -> do
    va <- go a
    case va of
      RL xs | k >= 1 && k <= length xs -> Right (xs !! (k - 1)) -- 1-based
      _ -> Left "index"
  GIf c a b -> go c >>= \case
    RB True -> go a
    RB False -> go b
    _ -> Left "if: not bool"
  GCaseL s e0' (h, t) e1 -> go s >>= \case
    RL [] -> go e0'
    RL (x : xs) -> refEval ds ((h, x) : (t, RL xs) : env) e1
    _ -> Left "case: not list"
  GCaseP s (a, b) e -> go s >>= \case
    RP x y -> refEval ds ((a, x) : (b, y) : env) e
    _ -> Left "case: not pair"
  GLam1 x _ b -> Right (RF x b env)  -- capture the DEFINITION env (lexical)
  GApp f a -> do
    vf <- go f; va <- go a
    applyR vf va
  GPipe a f -> do
    va <- go a; vf <- go f           -- e1 |> e2: eval e1 first
    applyR vf va
  GDollar f a -> go (GApp f a)       -- `$` is application, nothing more
  GList xs -> RL <$> mapM go xs
  GPair a b -> RP <$> go a <*> go b
  GInterp segs -> RS . concat <$> mapM seg segs
    where
      seg (Left s) = Right s
      seg (Right e) = rvRender <$> go e
  GCall f as -> do
    vs <- mapM go as
    callNamed ds f vs
  where
    go = refEval ds env
    applyR (RF x b cenv) va = refEval ds ((x, va) : cenv) b
    applyR _ _ = Left "apply: not a function"

binop :: String -> RV -> RV -> Either String RV
binop "+" (RI a) (RI b) = Right (RI (a + b))
binop "+" (RS a) (RS b) = Right (RS (a ++ b))
binop "+" (RL a) (RL b) = Right (RL (a ++ b))   -- List struct (+)
binop "-" (RI a) (RI b) = Right (RI (a - b))
binop "*" (RI a) (RI b) = Right (RI (a * b))
binop "/" (RI a) (RI b)
  | b == 0 = Left "div0"
  | otherwise = Right (RI (a `quot` b))          -- truncate toward zero
binop "<" (RI a) (RI b) = Right (RB (a < b))
binop "<=" (RI a) (RI b) = Right (RB (a <= b))
binop ">" (RI a) (RI b) = Right (RB (a > b))
binop ">=" (RI a) (RI b) = Right (RB (a >= b))
binop "==" a b = Right (RB (rvEq a b))
binop "!=" a b = Right (RB (not (rvEq a b)))
binop op _ _ = Left ("binop " ++ op)

-- generated helpers + the struct/HAL functions the generator emits
callNamed :: Defs -> String -> [RV] -> Either String RV
callNamed ds f vs = case M.lookup f ds of
  Just (GDef _ _ _ cls) -> clauses cls
  Nothing -> rprim f vs
  where
    clauses [] = Left (f ++ ": no matching clause")
    clauses (GClause ps mg body : rest)
      | length ps /= length vs = Left (f ++ ": arity")
      | otherwise = case matchAll ps vs of
          Nothing -> clauses rest                     -- pattern fallthrough
          Just bs -> case mg of
            Nothing -> refEval ds bs body
            Just g -> case refEval ds bs g of        -- guard fallthrough
              Right (RB True) -> refEval ds bs body
              Right (RB False) -> clauses rest
              Right _ -> Left "guard: not bool"
              Left e -> Left e
    matchAll ps' vs' = concat <$> sequence (zipWith m1 ps' vs')
    m1 (PGVar x) v = Just [(x, v)]
    m1 PGWild _ = Just []
    m1 (PGLit n) (RI m) = if n == m then Just [] else Nothing
    m1 (PGLit _) _ = Nothing
    m1 PGNil (RL []) = Just []
    m1 PGNil _ = Nothing
    m1 (PGConsP h t) (RL (x : xs)) = Just [(h, x), (t, RL xs)]
    m1 (PGConsP _ _) _ = Nothing

rprim :: String -> [RV] -> Either String RV
rprim "List.len" [RL xs] = Right (RI (fromIntegral (length xs)))
rprim "List.rev" [RL xs] = Right (RL (reverse xs))
rprim "List.append" [RL a, RL b] = Right (RL (a ++ b))
rprim "Numeric.max" [RI a, RI b] = Right (RI (max a b))
rprim "Numeric.min" [RI a, RI b] = Right (RI (min a b))
rprim "Numeric.abs" [RI a] = Right (RI (abs a))
rprim "Numeric.neg" [RI a] = Right (RI (negate a))
rprim "Numeric.mod" [RI a, RI b]
  | b == 0 = Left "div0"
  | otherwise = Right (RI (a - (a `quot` b) * b))    -- a - (a/b)*b, quot-based
rprim "Str.len" [RS s] = Right (RI (fromIntegral (length s)))
rprim "Str.cat" [RS a, RS b] = Right (RS (a ++ b))
rprim "Str.at" [RS s, RI i]
  | i >= 1 && i <= fromIntegral (length s) =
      Right (RI (fromIntegral (fromEnum (s !! fromIntegral (i - 1)))))
  | otherwise = Left "charAt: range"
rprim "Str.parse" [RS s] = case reads (dropWhile (== ' ') s) :: [(Integer, String)] of
  [(n, _)] -> Right (RI n)
  _ -> Left "parseInt"
rprim "strlen" [RS s] = Right (RI (fromIntegral (length s)))
rprim "strcat" [RS a, RS b] = Right (RS (a ++ b))
rprim "str" [v] = Right (RS (rvRender v))
rprim "map" [f, RL xs] = RL <$> mapM (ap1 f) xs
rprim "filter" [f, RL xs] = RL <$> filterM' (ap1 f) xs
  where
    filterM' _ [] = Right []
    filterM' p (y : ys) = p y >>= \case
      RB True -> (y :) <$> filterM' p ys
      RB False -> filterM' p ys
      _ -> Left "filter: not bool"
rprim "foldl" [f, z, RL xs] = foldlM' z xs
  where
    foldlM' acc [] = Right acc
    foldlM' acc (y : ys) = ap1 f acc >>= \g -> apV g y >>= \acc' -> foldlM' acc' ys
rprim f _ = Left ("rprim? " ++ f)

ap1 :: RV -> RV -> Either String RV
ap1 (RF x b cenv) v = refEvalClosed ((x, v) : cenv) b
ap1 _ _ = Left "apply: not fn"

apV :: RV -> RV -> Either String RV
apV = ap1

-- closures generated inside `map f xs` etc. never call helpers, so an
-- empty Defs is safe here; kept separate to make that assumption explicit
refEvalClosed :: REnv -> GE -> Either String RV
refEvalClosed = refEval M.empty

--------------------------------------------------------------------------------
-- Generators
--------------------------------------------------------------------------------

varPool :: [String]
varPool = ["a", "b", "c", "d", "m", "n"]

-- lexical scope: the FIRST binding of a name is the visible one
visibleEnv :: [(String, GTy)] -> [(String, GTy)]
visibleEnv = go []
  where
    go _ [] = []
    go seen ((x, t) : r)
      | x `elem` seen = go seen r
      | otherwise = (x, t) : go (x : seen) r

genTyFO :: Gen GTy       -- first-order result types (renderable & comparable)
genTyFO =
  Gen.recursive
    Gen.choice
    [pure TI, pure TB, pure TS]
    [TL <$> genTyFO, TP <$> genTyFO <*> genTyFO]

genLit :: GTy -> Gen GE
genLit TI = GI <$> Gen.integral (Range.linearFrom 0 (-40) 40)
genLit TB = GB <$> Gen.bool
genLit TS = GS <$> genSafeStr
genLit (TL t) = GList <$> Gen.list (Range.linear 0 4) (genLit t)
genLit (TP a b) = GPair <$> genLit a <*> genLit b

genSafeStr :: Gen String
genSafeStr = Gen.string (Range.linear 0 6) (Gen.element (['a' .. 'z'] ++ ['0' .. '9'] ++ " "))

-- (allowHelpers, helper sigs, scope) -> target type -> depth -> expr
genExpr :: Bool -> [(String, ([GTy], GTy))] -> [(String, GTy)] -> GTy -> Int -> Gen GE
genExpr ah defs env ty d
  | d <= 0 = leaf
  | otherwise = Gen.frequency ((3, leaf) : map ((,) 2) (branches ++ tyBranches))
  where
    leaf =
      case [x | (x, t) <- visibleEnv env, t == ty] of
        [] -> genLit ty
        vs -> Gen.frequency [(2, genLit ty), (3, GV <$> Gen.element vs)]
    sub t = genExpr ah defs env t (d - 1)
    -- new-scope helpers
    subWith bs t = genExpr ah defs (bs ++ env) t (d - 1)
    fresh = Gen.element varPool

    branches =
      [ -- if
        GIf <$> sub TB <*> sub ty <*> sub ty,
        -- let as ((fn x -> body) e) — SEMANTICS.txt's binding form
        do
          x <- fresh
          t' <- Gen.element [TI, TB, TS]
          e <- sub t'
          b <- subWith [(x, t')] ty
          pure (GApp (GLam1 x t' b) e),
        -- pipe into a lambda
        do
          x <- fresh
          t' <- Gen.element [TI, TS]
          e <- sub t'
          b <- subWith [(x, t')] ty
          pure (GPipe e (GLam1 x t' b)),
        -- $-apply a lambda
        do
          x <- fresh
          t' <- Gen.element [TI, TB]
          e <- sub t'
          b <- subWith [(x, t')] ty
          pure (GDollar (GLam1 x t' b) e),
        -- case over a list scrutinee
        do
          t' <- Gen.element [TI, TS]
          s <- sub (TL t')
          h <- fresh
          t <- Gen.element (filter (/= h) varPool)
          e0 <- sub ty
          e1 <- subWith [(h, t'), (t, TL t')] ty
          pure (GCaseL s e0 (h, t) e1),
        -- case over a pair
        do
          ta <- Gen.element [TI, TS]
          tb <- Gen.element [TI, TB]
          s <- sub (TP ta tb)
          a <- fresh
          b <- Gen.element (filter (/= a) varPool)
          e <- subWith [(a, ta), (b, tb)] ty
          pure (GCaseP s (a, b) e)
      ]
        ++ [ do
               -- call a generated helper of the right return type
               (f, (pts, _)) <- Gen.element hs
               GCall f <$> mapM sub pts
             | ah,
               let hs = [dh | dh@(_, (_, rt)) <- defs, rt == ty],
               not (null hs)
           ]

    tyBranches = case ty of
      TI ->
        [ GBin <$> Gen.element ["+", "-", "*"] <*> sub TI <*> sub TI,
          do a <- sub TI; k <- Gen.integral (Range.linearFrom 1 (-9) 9); pure (GBin "/" a (GI (nz k))),
          do a <- sub TI; k <- Gen.integral (Range.linearFrom 1 (-9) 9); pure (GCall "Numeric.mod" [a, GI (nz k)]),
          GCall "Numeric.max" <$> mapM sub [TI, TI],
          GCall "Numeric.min" <$> mapM sub [TI, TI],
          (\a -> GCall "Numeric.abs" [a]) <$> sub TI,
          (\a -> GCall "Numeric.neg" [a]) <$> sub TI,
          (\a -> GCall "List.len" [a]) <$> sub (TL TI),
          (\a -> GCall "Str.len" [a]) <$> sub TS,
          (\a -> GCall "Str.parse" [GCall "str" [a]]) <$> sub TI,
          do -- charAt returns the 1-based character CODE
            str' <- Gen.string (Range.linear 1 8) (Gen.element ['a' .. 'z'])
            k <- Gen.integral (Range.linear 1 (length str'))
            pure (GCall "Str.at" [GS str', GI (fromIntegral k)]),
          do -- static in-range index
            xs <- Gen.list (Range.linear 1 5) (sub TI)
            k <- Gen.integral (Range.linear 1 (length xs))
            pure (GIndex (GList xs) k),
          do -- foldl with an arithmetic lambda
            x <- fresh
            acc <- Gen.element (filter (/= x) varPool)
            op <- Gen.element ["+", "-", "*"]
            xs <- sub (TL TI)
            z <- sub TI
            pure (GCall "foldl" [GLam1 acc TI (GLam1 x TI (GBin op (GV acc) (GV x))), z, xs])
        ]
      TB ->
        [ GBin <$> Gen.element ["<", "<=", ">", ">="] <*> sub TI <*> sub TI,
          do t' <- Gen.element [TI, TB, TS, TL TI, TP TI TB, TL (TL TI), TP TS TI]
             GBin <$> Gen.element ["==", "!="] <*> sub t' <*> sub t'
        ]
      TS ->
        [ GBin "+" <$> sub TS <*> sub TS,
          GCall "Str.cat" <$> mapM sub [TS, TS],

          (\v -> GCall "str" [v]) <$> (Gen.element [TI, TB, TL TI] >>= sub),
          do -- interpolation
            t' <- Gen.element [TI, TB, TS, TL TI, TP TI TI]
            pre <- genSafeStr
            e <- sub t'
            post <- genSafeStr
            pure (GInterp [Left pre, Right e, Left post])
        ]
      TL t ->
        [ GList <$> Gen.list (Range.linear 0 3) (sub t),
          GCons <$> sub t <*> sub ty,
          GBin "+" <$> sub ty <*> sub ty,           -- List struct (+) = append
          (\a -> GCall "List.rev" [a]) <$> sub ty,
          GCall "List.append" <$> mapM sub [ty, ty],
          do -- map with a lambda (no helper calls inside closures)
            x <- fresh
            b <- genExpr False defs [(x, t)] t 1
            xs <- sub ty
            pure (GCall "map" [GLam1 x t b, xs])
        ]
          ++ [ do -- filter over int lists
                 x <- fresh
                 cmp <- Gen.element ["<", "<=", ">", ">="]
                 k <- GI <$> Gen.integral (Range.linearFrom 0 (-10) 10)
                 xs <- sub ty
                 pure (GCall "filter" [GLam1 x TI (GBin cmp (GV x) k), xs])
               | t == TI
             ]
      TP a b -> [GPair <$> sub a <*> sub b]

    nz k = if k == 0 then 1 else k

-- helpers: ints with guards / literal patterns, or structural list recursion
genDef :: String -> Gen GDef
genDef name =
  Gen.choice
    [ do -- int helper: guarded clauses, first-match-wins, no recursion
        c1 <- Gen.integral (Range.linearFrom 0 (-10) 10)
        g1 <- Gen.element ["<", "<=", ">", ">="]
        b1 <- genExpr False [] [("a", TI)] TI 2
        lit <- Gen.integral (Range.linear 0 5)   -- neg literal pats don't parse
        bl <- genExpr False [] [] TI 1
        b2 <- genExpr False [] [("a", TI)] TI 2
        pure $
          GDef name [TI] TI
            [ GClause [PGLit lit] Nothing bl,
              GClause [PGVar "a"] (Just (GBin g1 (GV "a") (GI c1))) b1,
              GClause [PGVar "a"] Nothing b2
            ],
      do -- list helper: structural recursion over the tail
        b0 <- genExpr False [] [] TI 1
        op <- Gen.element ["+", "-", "*"]
        pure $
          GDef name [TL TI] TI
            [ GClause [PGNil] Nothing b0,
              GClause [PGConsP "a" "b"] Nothing (GBin op (GV "a") (GCall name [GV "b"]))
            ]
    ]

genProgram :: Gen ([GDef], GE, GTy)
genProgram = do
  nDefs <- Gen.integral (Range.linear 0 2)
  defs <- mapM (\i -> genDef ("f" ++ show (i :: Int))) [1 .. nDefs]
  let sigs = [(n, (ps, rt)) | GDef n ps rt _ <- defs]
  ty <- genTyFO
  d <- Gen.integral (Range.linear 3 5)
  e <- genExpr True sigs [] ty d
  pure (defs, e, ty)

--------------------------------------------------------------------------------
-- Properties
--------------------------------------------------------------------------------

-- 1. The pipeline agrees with SEMANTICS.txt on the generated fragment.
prop_ref_vm_agree :: Property
prop_ref_vm_agree = withTests 400 . property $ do
  (defs, e, _) <- forAll genProgram
  let src = rProgram defs e
      dm = M.fromList [(n, d) | d@(GDef n _ _ _) <- defs]
  annotate src
  case refEval dm [] e of
    Left err -> do
      annotate ("reference failed: " ++ err)
      failure
    Right rv -> do
      out <- evalIO (runSol src)
      out === Right (rvRender rv)

-- 2. `f $ x` and `f (x)` parse to the identical AST (STYLE.md's pin-safety claim).
prop_dollar_paren_same_ast :: Property
prop_dollar_paren_same_ast = withTests 200 . property $ do
  (defs, e, _) <- forAll genProgram
  let s1 = concatMap rDef defs ++ "ptest = str $ " ++ rE e ++ ".\n"
      s2 = concatMap rDef defs ++ "ptest = str (" ++ rE e ++ ").\n"
  case (parseSol s1, parseSol s2) of
    (Right t1, Right t2) -> show t1 === show t2
    (a, b) -> do
      annotate (show (a, b))
      failure

-- 3. `e |> f` runs to the same value as `f (e)`.
prop_pipe_is_application :: Property
prop_pipe_is_application = withTests 150 . property $ do
  (defs, e, _) <- forAll genProgram
  x <- forAll (Gen.element varPool)
  b <- forAll (genExpr False [] [(x, TI)] TI 2)
  ei <- forAll (genExpr False [] [] TI 3)
  let lam = "(fn " ++ x ++ " -> " ++ rE b ++ ")"
      pre = concatMap rDef defs
      s1 = pre ++ "ptest = (" ++ rE ei ++ ") |> " ++ lam ++ ".\n"
      s2 = pre ++ "ptest = " ++ lam ++ " (" ++ rE ei ++ ").\n"
  _ <- pure (defs, e) -- defs only anchor shared shrink context
  o1 <- evalIO (runSol s1)
  o2 <- evalIO (runSol s2)
  o1 === o2

-- 4. String interpolation of e equals `str e`.
prop_interp_is_str :: Property
prop_interp_is_str = withTests 150 . property $ do
  t' <- forAll (Gen.element [TI, TB, TS, TL TI])
  e <- forAll (genExpr False [] [] t' 3)
  let s1 = "ptest = \"{" ++ rE e ++ "}\".\n"
      s2 = "ptest = (str " ++ rE e ++ ").\n"
  o1 <- evalIO (runSol s1)
  o2 <- evalIO (runSol s2)
  o1 === o2

-- 5. `$` binds looser than `|>`: `f $ e |> g` is `f (e |> g)` (STYLE.md).
prop_dollar_swallows_pipe :: Property
prop_dollar_swallows_pipe = withTests 150 . property $ do
  e <- forAll (genExpr False [] [] TI 3)
  x <- forAll (Gen.element varPool)
  b <- forAll (genExpr False [] [(x, TI)] TI 2)
  let lam = "(fn " ++ x ++ " -> " ++ rE b ++ ")"
      s1 = "ptest = str $ " ++ rE e ++ " |> " ++ lam ++ ".\n"
      s2 = "ptest = str (" ++ rE e ++ " |> " ++ lam ++ ").\n"
  case (parseSol s1, parseSol s2) of
    (Right t1, Right t2) -> show t1 === show t2
    (a, b') -> annotate (show (a, b')) >> failure

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering >> setLocaleEncoding utf8
  ok <-
    checkParallel $
      Group
        "sol-props"
        [ ("ref/vm agree (SEMANTICS.txt differential)", prop_ref_vm_agree),
          ("$ == parens (AST identity)", prop_dollar_paren_same_ast),
          ("|> is application", prop_pipe_is_application),
          ("interpolation == str", prop_interp_is_str),
          ("$ swallows |> (precedence)", prop_dollar_swallows_pipe)
        ]
  unless ok exitFailure
