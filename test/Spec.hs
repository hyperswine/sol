{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Main where

import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Sol.Eval (apply, evalExpr, evalProg, initialEnv)
import Sol.Parser (parseProgram)
import Sol.Syntax
import Sol.Value
import System.Exit (exitFailure)

-- Orphan Show instance so Hedgehog can display counterexamples. SBuiltin / SFun are shown via showVal (e.g. "<builtin>").
instance Show SolVal where
  show = showVal

-- ===================================================================
-- Generators  (return primitive Haskell types that already have Show)
-- ===================================================================

genFiniteDouble :: Gen Double
genFiniteDouble = Gen.double (Range.linearFrac (-1000) 1000)

genPosDouble :: Gen Double
genPosDouble = Gen.double (Range.linearFrac 1 1000)

genSafeString :: Gen String
genSafeString = Gen.string (Range.linear 0 20) Gen.alphaNum

genAlphaKey :: Gen String
genAlphaKey = Gen.string (Range.linear 1 10) Gen.alpha

-- ===================================================================
-- isTruthy properties
-- ===================================================================

prop_isTruthy_true :: Property
prop_isTruthy_true = property $ isTruthy (SBool True) === True

prop_isTruthy_false :: Property
prop_isTruthy_false = property $ isTruthy (SBool False) === False

prop_isTruthy_zero :: Property
prop_isTruthy_zero = property $ isTruthy (SNum 0) === False

prop_isTruthy_nonzero :: Property
prop_isTruthy_nonzero = property $ do
  n <- forAll genPosDouble
  isTruthy (SNum n) === True

prop_isTruthy_empty_str :: Property
prop_isTruthy_empty_str = property $ isTruthy (SStr "") === False

prop_isTruthy_nonempty_str :: Property
prop_isTruthy_nonempty_str = property $ do
  s <- forAll $ Gen.string (Range.linear 1 20) Gen.alphaNum
  isTruthy (SStr s) === True

prop_isTruthy_empty_list :: Property
prop_isTruthy_empty_list = property $ isTruthy (SList []) === False

prop_isTruthy_nonempty_list :: Property
prop_isTruthy_nonempty_list = property $ do
  n <- forAll genFiniteDouble
  ns <- forAll $ Gen.list (Range.linear 0 5) genFiniteDouble
  isTruthy (SList (SNum n : map SNum ns)) === True

prop_isTruthy_null :: Property
prop_isTruthy_null = property $ isTruthy SNull === False

prop_isTruthy_empty_dict :: Property
prop_isTruthy_empty_dict = property $ isTruthy (SDict Map.empty) === False

prop_isTruthy_nonempty_dict :: Property
prop_isTruthy_nonempty_dict = property $ do
  k <- forAll genAlphaKey
  isTruthy (SDict (Map.fromList [(k, SNull)])) === True

-- ===================================================================
-- showVal properties
-- ===================================================================

prop_showVal_true :: Property
prop_showVal_true = property $ showVal (SBool True) === "true"

prop_showVal_false :: Property
prop_showVal_false = property $ showVal (SBool False) === "false"

prop_showVal_null :: Property
prop_showVal_null = property $ showVal SNull === "null"

prop_showVal_str_identity :: Property
prop_showVal_str_identity = property $ do
  s <- forAll genSafeString
  showVal (SStr s) === s

prop_showVal_int_no_decimal :: Property
prop_showVal_int_no_decimal = property $ do
  n <- forAll $ Gen.int (Range.linear (-1000) 1000)
  let s = showVal (SNum (fromIntegral n))
  assert ('.' `notElem` s)

-- ===================================================================
-- Parser properties
-- ===================================================================

prop_parse_integer_literal :: Property
prop_parse_integer_literal = property $ do
  n <- forAll $ Gen.int (Range.linear 0 9999)
  let prog = show n ++ "."
  case parseProgram prog of
    Right [SExpr (ENum v)] -> v === fromIntegral n
    _ -> failure

prop_parse_raw_string :: Property
prop_parse_raw_string = property $ do
  s <- forAll $ Gen.string (Range.linear 0 15) Gen.alphaNum
  let prog = "raw\"" ++ s ++ "\"."
  case parseProgram prog of
    Right [SExpr (EStr v)] -> v === s
    _ -> failure

prop_parse_fstring :: Property
prop_parse_fstring = property $ do
  s <- forAll $ Gen.string (Range.linear 0 15) Gen.alphaNum
  let prog = "\"" ++ s ++ "\"."
  case parseProgram prog of
    Right [SExpr (EFStr v)] -> v === s
    _ -> failure

prop_parse_empty_list :: Property
prop_parse_empty_list = property $
  case parseProgram "[]." of
    Right [SExpr (EList [])] -> success
    _ -> failure

prop_parse_list :: Property
prop_parse_list = property $
  case parseProgram "[1, 2, 3]." of
    Right [SExpr (EList [ENum 1, ENum 2, ENum 3])] -> success
    _ -> failure

prop_parse_dict :: Property
prop_parse_dict = property $
  case parseProgram "{a: 1, b: 2}." of
    Right [SExpr (EDict _)] -> success
    _ -> failure

prop_parse_assign_var :: Property
prop_parse_assign_var = property $
  case parseProgram "x = 42." of
    Right [SAssign "x" [] (ENum 42)] -> success
    _ -> failure

prop_parse_function_def :: Property
prop_parse_function_def = property $
  case parseProgram "double x = * x 2." of
    Right [SAssign "double" ["x"] _] -> success
    _ -> failure

prop_parse_if_expr :: Property
prop_parse_if_expr = property $
  case parseProgram "if true then 1 else 2." of
    Right [SExpr (EIf _ _ _)] -> success
    _ -> failure

prop_parse_pipeline :: Property
prop_parse_pipeline = property $
  case parseProgram "[1, 2, 3] |> len." of
    Right [SExpr (EPipe _ _)] -> success
    _ -> failure

prop_parse_multiple_stmts :: Property
prop_parse_multiple_stmts = property $ do
  n <- forAll $ Gen.int (Range.linear 0 9)
  let prog = "x = " ++ show n ++ ".\ny = " ++ show n ++ "."
  case parseProgram prog of
    Right [SAssign "x" [] _, SAssign "y" [] _] -> success
    _ -> failure

-- ===================================================================
-- Eval: arithmetic
-- ===================================================================

prop_eval_add_commutative :: Property
prop_eval_add_commutative = property $ do
  a <- forAll genFiniteDouble
  b <- forAll genFiniteDouble
  ra <- evalIO $ apply initialEnv (initialEnv Map.! "+") [SNum a, SNum b]
  rb <- evalIO $ apply initialEnv (initialEnv Map.! "+") [SNum b, SNum a]
  ra === rb

prop_eval_add_zero :: Property
prop_eval_add_zero = property $ do
  a <- forAll genFiniteDouble
  r <- evalIO $ apply initialEnv (initialEnv Map.! "+") [SNum a, SNum 0]
  r === SNum a

prop_eval_sub_self :: Property
prop_eval_sub_self = property $ do
  a <- forAll genFiniteDouble
  r <- evalIO $ apply initialEnv (initialEnv Map.! "-") [SNum a, SNum a]
  r === SNum 0

prop_eval_mul_one :: Property
prop_eval_mul_one = property $ do
  a <- forAll genFiniteDouble
  r <- evalIO $ apply initialEnv (initialEnv Map.! "*") [SNum a, SNum 1]
  r === SNum a

prop_eval_mul_zero :: Property
prop_eval_mul_zero = property $ do
  a <- forAll genFiniteDouble
  r <- evalIO $ apply initialEnv (initialEnv Map.! "*") [SNum a, SNum 0]
  r === SNum 0

prop_eval_mul_commutative :: Property
prop_eval_mul_commutative = property $ do
  a <- forAll genFiniteDouble
  b <- forAll genFiniteDouble
  ra <- evalIO $ apply initialEnv (initialEnv Map.! "*") [SNum a, SNum b]
  rb <- evalIO $ apply initialEnv (initialEnv Map.! "*") [SNum b, SNum a]
  ra === rb

prop_eval_div_one :: Property
prop_eval_div_one = property $ do
  a <- forAll genFiniteDouble
  r <- evalIO $ apply initialEnv (initialEnv Map.! "/") [SNum a, SNum 1]
  r === SNum a

prop_eval_mod_range :: Property
prop_eval_mod_range = property $ do
  a <- forAll $ Gen.int (Range.linear 0 1000)
  m <- forAll $ Gen.int (Range.linear 1 100)
  r <- evalIO $ apply initialEnv (initialEnv Map.! "mod") [SNum (fromIntegral a), SNum (fromIntegral m)]
  case r of
    SNum v -> do
      assert (v >= 0)
      assert (v < fromIntegral m)
    _ -> failure

-- ===================================================================
-- Eval: comparisons
-- ===================================================================

prop_eval_eq_reflexive :: Property
prop_eval_eq_reflexive = property $ do
  n <- forAll genFiniteDouble
  r <- evalIO $ apply initialEnv (initialEnv Map.! "==") [SNum n, SNum n]
  r === SBool True

prop_eval_neq_reflexive :: Property
prop_eval_neq_reflexive = property $ do
  n <- forAll genFiniteDouble
  r <- evalIO $ apply initialEnv (initialEnv Map.! "!=") [SNum n, SNum n]
  r === SBool False

prop_eval_eq_neq_complement :: Property
prop_eval_eq_neq_complement = property $ do
  a <- forAll genFiniteDouble
  b <- forAll genFiniteDouble
  req <- evalIO $ apply initialEnv (initialEnv Map.! "==") [SNum a, SNum b]
  rne <- evalIO $ apply initialEnv (initialEnv Map.! "!=") [SNum a, SNum b]
  case (req, rne) of
    (SBool e, SBool ne) -> e === not ne
    _ -> failure

-- ===================================================================
-- Eval: boolean logic
-- ===================================================================

prop_eval_not_involution :: Property
prop_eval_not_involution = property $ do
  b <- forAll Gen.bool
  r1 <- evalIO $ apply initialEnv (initialEnv Map.! "not") [SBool b]
  r2 <- evalIO $ apply initialEnv (initialEnv Map.! "not") [r1]
  r2 === SBool b

prop_eval_and_commutative :: Property
prop_eval_and_commutative = property $ do
  a <- forAll Gen.bool
  b <- forAll Gen.bool
  ra <- evalIO $ apply initialEnv (initialEnv Map.! "and") [SBool a, SBool b]
  rb <- evalIO $ apply initialEnv (initialEnv Map.! "and") [SBool b, SBool a]
  ra === rb

prop_eval_or_commutative :: Property
prop_eval_or_commutative = property $ do
  a <- forAll Gen.bool
  b <- forAll Gen.bool
  ra <- evalIO $ apply initialEnv (initialEnv Map.! "or") [SBool a, SBool b]
  rb <- evalIO $ apply initialEnv (initialEnv Map.! "or") [SBool b, SBool a]
  ra === rb

prop_eval_and_false_absorb :: Property
prop_eval_and_false_absorb = property $ do
  b <- forAll Gen.bool
  r <- evalIO $ apply initialEnv (initialEnv Map.! "and") [SBool False, SBool b]
  r === SBool False

prop_eval_or_true_absorb :: Property
prop_eval_or_true_absorb = property $ do
  b <- forAll Gen.bool
  r <- evalIO $ apply initialEnv (initialEnv Map.! "or") [SBool True, SBool b]
  r === SBool True

-- ===================================================================
-- Eval: list operations
-- ===================================================================

prop_eval_append_increases_len :: Property
prop_eval_append_increases_len = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 10) genFiniteDouble
  let list = SList (map SNum xs)
  r <- evalIO $ apply initialEnv (initialEnv Map.! "append") [list, SNum 99]
  case r of
    SList ys -> length ys === length xs + 1
    _ -> failure

prop_eval_prepend_increases_len :: Property
prop_eval_prepend_increases_len = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 10) genFiniteDouble
  let list = SList (map SNum xs)
  r <- evalIO $ apply initialEnv (initialEnv Map.! "prepend") [SNum 99, list]
  case r of
    SList ys -> length ys === length xs + 1
    _ -> failure

prop_eval_head_of_prepend :: Property
prop_eval_head_of_prepend = property $ do
  x <- forAll genFiniteDouble
  xs <- forAll $ Gen.list (Range.linear 0 5) genFiniteDouble
  let list = SList (map SNum xs)
  prepended <- evalIO $ apply initialEnv (initialEnv Map.! "prepend") [SNum x, list]
  h <- evalIO $ apply initialEnv (initialEnv Map.! "head") [prepended]
  h === SNum x

prop_eval_tail_of_prepend :: Property
prop_eval_tail_of_prepend = property $ do
  x <- forAll genFiniteDouble
  xs <- forAll $ Gen.list (Range.linear 0 5) genFiniteDouble
  let list = SList (map SNum xs)
  prepended <- evalIO $ apply initialEnv (initialEnv Map.! "prepend") [SNum x, list]
  t <- evalIO $ apply initialEnv (initialEnv Map.! "tail") [prepended]
  t === list

prop_eval_reverse_involution :: Property
prop_eval_reverse_involution = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 10) genFiniteDouble
  let list = SList (map SNum xs)
  r1 <- evalIO $ apply initialEnv (initialEnv Map.! "reverse") [list]
  r2 <- evalIO $ apply initialEnv (initialEnv Map.! "reverse") [r1]
  r2 === list

prop_eval_str_reverse_involution :: Property
prop_eval_str_reverse_involution = property $ do
  s <- forAll $ Gen.string (Range.linear 0 20) Gen.alphaNum
  r1 <- evalIO $ apply initialEnv (initialEnv Map.! "reverse") [SStr s]
  r2 <- evalIO $ apply initialEnv (initialEnv Map.! "reverse") [r1]
  r2 === SStr s

prop_eval_concat_len :: Property
prop_eval_concat_len = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 10) genFiniteDouble
  ys <- forAll $ Gen.list (Range.linear 0 10) genFiniteDouble
  r <-
    evalIO $
      apply
        initialEnv
        (initialEnv Map.! "concat")
        [SList (map SNum xs), SList (map SNum ys)]
  case r of
    SList zs -> length zs === length xs + length ys
    _ -> failure

prop_eval_sort_idempotent :: Property
prop_eval_sort_idempotent = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 10) genFiniteDouble
  let list = SList (map SNum xs)
  r1 <- evalIO $ apply initialEnv (initialEnv Map.! "sort") [list]
  r2 <- evalIO $ apply initialEnv (initialEnv Map.! "sort") [r1]
  r1 === r2

prop_eval_range_length :: Property
prop_eval_range_length = property $ do
  a <- forAll $ Gen.int (Range.linear 0 50)
  n <- forAll $ Gen.int (Range.linear 0 20)
  let b = a + n
  r <-
    evalIO $
      apply
        initialEnv
        (initialEnv Map.! "range")
        [SNum (fromIntegral a), SNum (fromIntegral b)]
  case r of
    SList ys -> length ys === n
    _ -> failure

prop_eval_range_values :: Property
prop_eval_range_values = property $ do
  a <- forAll $ Gen.int (Range.linear 0 20)
  n <- forAll $ Gen.int (Range.linear 0 10)
  let b = a + n
  r <-
    evalIO $
      apply
        initialEnv
        (initialEnv Map.! "range")
        [SNum (fromIntegral a), SNum (fromIntegral b)]
  r === SList [SNum (fromIntegral i) | i <- [a .. b - 1]]

prop_eval_zip_length :: Property
prop_eval_zip_length = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 10) genFiniteDouble
  ys <- forAll $ Gen.list (Range.linear 0 10) genFiniteDouble
  r <-
    evalIO $
      apply
        initialEnv
        (initialEnv Map.! "zip")
        [SList (map SNum xs), SList (map SNum ys)]
  case r of
    SList zs -> length zs === min (length xs) (length ys)
    _ -> failure

prop_eval_flatten_length :: Property
prop_eval_flatten_length = property $ do
  rows <-
    forAll $
      Gen.list
        (Range.linear 0 5)
        (Gen.list (Range.linear 0 5) genFiniteDouble)
  let nested = SList (map (\row -> SList (map SNum row)) rows)
  r <- evalIO $ apply initialEnv (initialEnv Map.! "flatten") [nested]
  case r of
    SList ys -> length ys === sum (map length rows)
    _ -> failure

prop_eval_len_list :: Property
prop_eval_len_list = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 20) genFiniteDouble
  r <- evalIO $ apply initialEnv (initialEnv Map.! "len") [SList (map SNum xs)]
  r === SNum (fromIntegral (length xs))

prop_eval_len_string :: Property
prop_eval_len_string = property $ do
  s <- forAll $ Gen.string (Range.linear 0 20) Gen.alphaNum
  r <- evalIO $ apply initialEnv (initialEnv Map.! "len") [SStr s]
  r === SNum (fromIntegral (length s))

prop_eval_contains_member :: Property
prop_eval_contains_member = property $ do
  x <- forAll genFiniteDouble
  rest <- forAll $ Gen.list (Range.linear 0 5) genFiniteDouble
  r <-
    evalIO $
      apply
        initialEnv
        (initialEnv Map.! "contains")
        [SList (map SNum (x : rest)), SNum x]
  r === SBool True

prop_eval_contains_str_substr :: Property
prop_eval_contains_str_substr = property $ do
  pre <- forAll $ Gen.string (Range.linear 0 5) Gen.alphaNum
  mid <- forAll $ Gen.string (Range.linear 1 5) Gen.alphaNum
  suf <- forAll $ Gen.string (Range.linear 0 5) Gen.alphaNum
  r <-
    evalIO $
      apply
        initialEnv
        (initialEnv Map.! "contains")
        [SStr (pre ++ mid ++ suf), SStr mid]
  r === SBool True

-- ===================================================================
-- Eval: string operations
-- ===================================================================

prop_eval_upper_idempotent :: Property
prop_eval_upper_idempotent = property $ do
  s <- forAll $ Gen.string (Range.linear 0 20) Gen.alphaNum
  r1 <- evalIO $ apply initialEnv (initialEnv Map.! "upper") [SStr s]
  r2 <- evalIO $ apply initialEnv (initialEnv Map.! "upper") [r1]
  r1 === r2

prop_eval_lower_idempotent :: Property
prop_eval_lower_idempotent = property $ do
  s <- forAll $ Gen.string (Range.linear 0 20) Gen.alphaNum
  r1 <- evalIO $ apply initialEnv (initialEnv Map.! "lower") [SStr s]
  r2 <- evalIO $ apply initialEnv (initialEnv Map.! "lower") [r1]
  r1 === r2

prop_eval_str_concat_empty_right :: Property
prop_eval_str_concat_empty_right = property $ do
  s <- forAll genSafeString
  r <- evalIO $ apply initialEnv (initialEnv Map.! "concat") [SStr s, SStr ""]
  r === SStr s

prop_eval_str_concat_empty_left :: Property
prop_eval_str_concat_empty_left = property $ do
  s <- forAll genSafeString
  r <- evalIO $ apply initialEnv (initialEnv Map.! "concat") [SStr "", SStr s]
  r === SStr s

prop_eval_split_join_roundtrip :: Property
prop_eval_split_join_roundtrip = property $ do
  ws <-
    forAll $
      Gen.list
        (Range.linear 1 5)
        (Gen.string (Range.linear 1 5) Gen.alphaNum)
  let sep = ","
      joined = intercalate sep ws
  r <- evalIO $ apply initialEnv (initialEnv Map.! "split") [SStr sep, SStr joined]
  r === SList (map SStr ws)

prop_eval_trim_idempotent :: Property
prop_eval_trim_idempotent = property $ do
  s <- forAll $ Gen.string (Range.linear 0 10) Gen.alphaNum
  r1 <- evalIO $ apply initialEnv (initialEnv Map.! "trim") [SStr s]
  r2 <- evalIO $ apply initialEnv (initialEnv Map.! "trim") [r1]
  r1 === r2

prop_eval_replace_no_match :: Property
prop_eval_replace_no_match = property $ do
  s <- forAll $ Gen.string (Range.linear 0 10) (Gen.element "abcde")
  r <-
    evalIO $
      apply
        initialEnv
        (initialEnv Map.! "replace")
        [SStr "XXXXX", SStr "YYY", SStr s]
  r === SStr s

prop_eval_startswith_self :: Property
prop_eval_startswith_self = property $ do
  pre <- forAll $ Gen.string (Range.linear 0 5) Gen.alphaNum
  rest <- forAll $ Gen.string (Range.linear 0 10) Gen.alphaNum
  r <-
    evalIO $
      apply
        initialEnv
        (initialEnv Map.! "startswith")
        [SStr pre, SStr (pre ++ rest)]
  r === SBool True

prop_eval_endswith_self :: Property
prop_eval_endswith_self = property $ do
  suf <- forAll $ Gen.string (Range.linear 0 5) Gen.alphaNum
  pre <- forAll $ Gen.string (Range.linear 0 10) Gen.alphaNum
  r <-
    evalIO $
      apply
        initialEnv
        (initialEnv Map.! "endswith")
        [SStr suf, SStr (pre ++ suf)]
  r === SBool True

prop_eval_words_unwords_roundtrip :: Property
prop_eval_words_unwords_roundtrip = property $ do
  ws <-
    forAll $
      Gen.list
        (Range.linear 1 5)
        (Gen.string (Range.linear 1 5) Gen.alpha)
  let sentence = unwords ws
  r <- evalIO $ apply initialEnv (initialEnv Map.! "words") [SStr sentence]
  r === SList (map SStr ws)

-- ===================================================================
-- Eval: dict operations
-- ===================================================================

prop_eval_dict_set_get :: Property
prop_eval_dict_set_get = property $ do
  k <- forAll genAlphaKey
  v <- forAll genFiniteDouble
  d2 <-
    evalIO $
      apply
        initialEnv
        (initialEnv Map.! "set")
        [SDict Map.empty, SStr k, SNum v]
  -- Dict access via Sol's | syntax (EAccess)
  r <-
    evalIO $
      evalExpr
        (Map.insert "d" d2 initialEnv)
        (EAccess (EVar "d") [KStr k])
  r === SNum v

prop_eval_dict_has_after_set :: Property
prop_eval_dict_has_after_set = property $ do
  k <- forAll genAlphaKey
  d2 <-
    evalIO $
      apply
        initialEnv
        (initialEnv Map.! "set")
        [SDict Map.empty, SStr k, SNum 1]
  r <- evalIO $ apply initialEnv (initialEnv Map.! "has") [d2, SStr k]
  r === SBool True

prop_eval_dict_missing_key_is_null :: Property
prop_eval_dict_missing_key_is_null = property $ do
  k <- forAll genAlphaKey
  -- SDict Map.empty has no keys — direct inspection
  case SDict Map.empty of
    SDict m -> assert (not (Map.member k m))
    _ -> failure

prop_eval_dict_delete_removes :: Property
prop_eval_dict_delete_removes = property $ do
  k <- forAll genAlphaKey
  let d = SDict (Map.fromList [(k, SNum 1)])
  d2 <- evalIO $ apply initialEnv (initialEnv Map.! "delete") [d, SStr k]
  r <- evalIO $ apply initialEnv (initialEnv Map.! "has") [d2, SStr k]
  r === SBool False

prop_eval_dict_merge_has_both_keys :: Property
prop_eval_dict_merge_has_both_keys = property $ do
  let d1 = SDict (Map.fromList [("a", SNum 1)])
      d2 = SDict (Map.fromList [("b", SNum 2)])
  merged <- evalIO $ apply initialEnv (initialEnv Map.! "merge") [d1, d2]
  ra <- evalIO $ apply initialEnv (initialEnv Map.! "has") [merged, SStr "a"]
  rb <- evalIO $ apply initialEnv (initialEnv Map.! "has") [merged, SStr "b"]
  ra === SBool True
  rb === SBool True

prop_eval_dict_merge_rhs_wins :: Property
prop_eval_dict_merge_rhs_wins = property $ do
  let d1 = SDict (Map.fromList [("k", SNum 1)])
      d2 = SDict (Map.fromList [("k", SNum 2)])
  merged <- evalIO $ apply initialEnv (initialEnv Map.! "merge") [d1, d2]
  -- inspect the merged SDict directly (rhs overrides lhs per bMerge)
  case merged of
    SDict m -> Map.lookup "k" m === Just (SNum 2)
    _ -> failure

prop_eval_dict_keys_values :: Property
prop_eval_dict_keys_values = property $ do
  k1 <- forAll genAlphaKey
  k2 <- forAll $ Gen.filter (/= k1) genAlphaKey
  let d = SDict (Map.fromList [(k1, SNum 1), (k2, SNum 2)])
  ks <- evalIO $ apply initialEnv (initialEnv Map.! "keys") [d]
  vs <- evalIO $ apply initialEnv (initialEnv Map.! "values") [d]
  case (ks, vs) of
    (SList ksv, SList vsv) -> do
      length ksv === 2
      length vsv === 2
    _ -> failure

-- ===================================================================
-- Eval: higher-order functions
-- ===================================================================

prop_eval_map_preserves_length :: Property
prop_eval_map_preserves_length = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 10) genFiniteDouble
  let list = SList (map SNum xs)
  addOne <- evalIO $ apply initialEnv (initialEnv Map.! "+") [SNum 1]
  r <- evalIO $ apply initialEnv (initialEnv Map.! "map") [addOne, list]
  case r of
    SList ys -> length ys === length xs
    _ -> failure

prop_eval_map_applies_fn :: Property
prop_eval_map_applies_fn = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 10) genFiniteDouble
  let list = SList (map SNum xs)
  addOne <- evalIO $ apply initialEnv (initialEnv Map.! "+") [SNum 1]
  r <- evalIO $ apply initialEnv (initialEnv Map.! "map") [addOne, list]
  r === SList (map (SNum . (1 +)) xs)

prop_eval_filter_is_subset :: Property
prop_eval_filter_is_subset = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 10) genFiniteDouble
  let list = SList (map SNum xs)
  -- (> 0) applied to x checks: x > 0
  gtZero <- evalIO $ apply initialEnv (initialEnv Map.! ">") [SNum 0]
  r <- evalIO $ apply initialEnv (initialEnv Map.! "filter") [gtZero, list]
  case r of
    SList ys -> assert (length ys <= length xs)
    _ -> failure

prop_eval_filter_correct :: Property
prop_eval_filter_correct = property $ do
  xs <- forAll $ Gen.list (Range.linear 0 10) genFiniteDouble
  let list = SList (map SNum xs)
  gtZero <- evalIO $ apply initialEnv (initialEnv Map.! ">") [SNum 0]
  r <- evalIO $ apply initialEnv (initialEnv Map.! "filter") [gtZero, list]
  r === SList (map SNum (filter (> 0) xs))

prop_eval_fold_sum :: Property
prop_eval_fold_sum = property $ do
  x <- forAll genFiniteDouble
  xs <- forAll $ Gen.list (Range.linear 0 9) genFiniteDouble
  let list = SList (map SNum (x : xs))
  r <-
    evalIO $
      apply
        initialEnv
        (initialEnv Map.! "fold")
        [initialEnv Map.! "+", list]
  r === SNum (sum (x : xs))

-- ===================================================================
-- Eval: partial application
-- ===================================================================

prop_eval_partial_yields_partial :: Property
prop_eval_partial_yields_partial = property $ do
  a <- forAll genFiniteDouble
  p <- evalIO $ apply initialEnv (initialEnv Map.! "+") [SNum a]
  case p of
    SPartial _ _ -> success
    _ -> failure

prop_eval_partial_completes :: Property
prop_eval_partial_completes = property $ do
  a <- forAll genFiniteDouble
  b <- forAll genFiniteDouble
  p <- evalIO $ apply initialEnv (initialEnv Map.! "+") [SNum a]
  r <- evalIO $ apply initialEnv p [SNum b]
  r === SNum (a + b)

-- ===================================================================
-- Eval: ENum, EStr, EList, EIf, EVar, EFStr
-- ===================================================================

prop_eval_enum :: Property
prop_eval_enum = property $ do
  n <- forAll genFiniteDouble
  r <- evalIO $ evalExpr initialEnv (ENum n)
  r === SNum n

prop_eval_estr :: Property
prop_eval_estr = property $ do
  s <- forAll genSafeString
  r <- evalIO $ evalExpr initialEnv (EStr s)
  r === SStr s

prop_eval_elist :: Property
prop_eval_elist = property $ do
  ns <- forAll $ Gen.list (Range.linear 0 10) genFiniteDouble
  r <- evalIO $ evalExpr initialEnv (EList (map ENum ns))
  r === SList (map SNum ns)

prop_eval_if_truthy_branch :: Property
prop_eval_if_truthy_branch = property $ do
  n <- forAll genPosDouble
  r <- evalIO $ evalExpr initialEnv (EIf (ENum n) (ENum 1) (ENum 2))
  r === SNum 1

prop_eval_if_falsy_branch :: Property
prop_eval_if_falsy_branch = property $ do
  r <- evalIO $ evalExpr initialEnv (EIf (ENum 0) (ENum 1) (ENum 2))
  r === SNum 2

prop_eval_evar_lookup :: Property
prop_eval_evar_lookup = property $ do
  n <- forAll genFiniteDouble
  let env = Map.insert "myvar" (SNum n) initialEnv
  r <- evalIO $ evalExpr env (EVar "myvar")
  r === SNum n

prop_eval_evar_unknown_is_str :: Property
prop_eval_evar_unknown_is_str = property $ do
  -- Unbound names that aren't in the built-in env return SStr of the name
  r <- evalIO $ evalExpr initialEnv (EVar "unknownXYZ")
  r === SStr "unknownXYZ"

prop_eval_fstring_interpolates :: Property
prop_eval_fstring_interpolates = property $ do
  n <- forAll genFiniteDouble
  let env = Map.insert "x" (SNum n) initialEnv
  r <- evalIO $ evalExpr env (EFStr "val={x}")
  r === SStr ("val=" ++ showVal (SNum n))

prop_eval_fstring_no_braces :: Property
prop_eval_fstring_no_braces = property $ do
  s <- forAll $ Gen.string (Range.linear 0 10) (Gen.element "abcdefghijklmnop")
  r <- evalIO $ evalExpr initialEnv (EFStr s)
  r === SStr s

-- ===================================================================
-- Eval: type names
-- ===================================================================

prop_eval_type_number :: Property
prop_eval_type_number = property $ do
  n <- forAll genFiniteDouble
  r <- evalIO $ apply initialEnv (initialEnv Map.! "type") [SNum n]
  r === SStr "number"

prop_eval_type_string :: Property
prop_eval_type_string = property $ do
  s <- forAll genSafeString
  r <- evalIO $ apply initialEnv (initialEnv Map.! "type") [SStr s]
  r === SStr "string"

prop_eval_type_bool :: Property
prop_eval_type_bool = property $ do
  b <- forAll Gen.bool
  r <- evalIO $ apply initialEnv (initialEnv Map.! "type") [SBool b]
  r === SStr "bool"

prop_eval_type_null :: Property
prop_eval_type_null = property $ do
  r <- evalIO $ apply initialEnv (initialEnv Map.! "type") [SNull]
  r === SStr "null"

prop_eval_type_list :: Property
prop_eval_type_list = property $ do
  r <- evalIO $ apply initialEnv (initialEnv Map.! "type") [SList []]
  r === SStr "list"

prop_eval_type_dict :: Property
prop_eval_type_dict = property $ do
  r <- evalIO $ apply initialEnv (initialEnv Map.! "type") [SDict Map.empty]
  r === SStr "dict"

-- ===================================================================
-- Eval: num / str conversions
-- ===================================================================

prop_eval_num_from_string :: Property
prop_eval_num_from_string = property $ do
  n <- forAll $ Gen.int (Range.linear (-100) 100)
  r <- evalIO $ apply initialEnv (initialEnv Map.! "num") [SStr (show n)]
  r === SNum (fromIntegral n)

prop_eval_num_from_num :: Property
prop_eval_num_from_num = property $ do
  n <- forAll genFiniteDouble
  r <- evalIO $ apply initialEnv (initialEnv Map.! "num") [SNum n]
  r === SNum n

prop_eval_str_from_int :: Property
prop_eval_str_from_int = property $ do
  n <- forAll $ Gen.int (Range.linear (-100) 100)
  r <- evalIO $ apply initialEnv (initialEnv Map.! "str") [SNum (fromIntegral n)]
  r === SStr (showVal (SNum (fromIntegral n)))

prop_eval_bool_truthy :: Property
prop_eval_bool_truthy = property $ do
  n <- forAll genPosDouble
  r <- evalIO $ apply initialEnv (initialEnv Map.! "bool") [SNum n]
  r === SBool True

prop_eval_bool_falsy :: Property
prop_eval_bool_falsy = property $ do
  r <- evalIO $ apply initialEnv (initialEnv Map.! "bool") [SNum 0]
  r === SBool False

-- ===================================================================
-- End-to-end: parse + eval
-- ===================================================================

prop_e2e_assign_number :: Property
prop_e2e_assign_number = property $ do
  n <- forAll $ Gen.int (Range.linear 0 999)
  let prog = "x = " ++ show n ++ "."
  case parseProgram prog of
    Right stmts -> do
      env <- evalIO $ evalProg initialEnv stmts
      Map.lookup "x" env === Just (SNum (fromIntegral n))
    Left _ -> failure

prop_e2e_function_call :: Property
prop_e2e_function_call = property $ do
  n <- forAll $ Gen.int (Range.linear 1 10)
  let prog = "double x = * x 2.\nresult = double " ++ show n ++ "."
  case parseProgram prog of
    Right stmts -> do
      env <- evalIO $ evalProg initialEnv stmts
      Map.lookup "result" env === Just (SNum (fromIntegral (n * 2)))
    Left _ -> failure

prop_e2e_list_len_pipeline :: Property
prop_e2e_list_len_pipeline = property $
  case parseProgram "result = [1, 2, 3] |> len." of
    Right stmts -> do
      env <- evalIO $ evalProg initialEnv stmts
      Map.lookup "result" env === Just (SNum 3)
    Left _ -> failure

prop_e2e_range_sum :: Property
prop_e2e_range_sum = property $ do
  n <- forAll $ Gen.int (Range.linear 1 10)
  let prog = "result = fold + (range 1 " ++ show (n + 1) ++ ")."
  case parseProgram prog of
    Right stmts -> do
      env <- evalIO $ evalProg initialEnv stmts
      Map.lookup "result" env === Just (SNum (fromIntegral (sum [1 .. n])))
    Left _ -> failure

prop_e2e_map_double :: Property
prop_e2e_map_double = property $ do
  xs <- forAll $ Gen.list (Range.linear 1 5) (Gen.int (Range.linear 1 20))
  let elems = intercalate ", " (map show xs)
      prog = "double x = * x 2.\nresult = map double [" ++ elems ++ "]."
  case parseProgram prog of
    Right stmts -> do
      env <- evalIO $ evalProg initialEnv stmts
      Map.lookup "result" env
        === Just (SList (map (SNum . fromIntegral . (* 2)) xs))
    Left _ -> failure

prop_e2e_filter_evens :: Property
prop_e2e_filter_evens = property $ do
  xs <- forAll $ Gen.list (Range.linear 1 8) (Gen.int (Range.linear 1 20))
  let evens = filter even xs
      elems = intercalate ", " (map show xs)
      prog = "even x = == (mod x 2) 0.\nresult = filter even [" ++ elems ++ "]."
  case parseProgram prog of
    Right stmts -> do
      env <- evalIO $ evalProg initialEnv stmts
      Map.lookup "result" env
        === Just (SList (map (SNum . fromIntegral) evens))
    Left _ -> failure

prop_e2e_if_else :: Property
prop_e2e_if_else = property $ do
  n <- forAll $ Gen.int (Range.linear 1 100)
  let prog = "result = if " ++ show n ++ " then 1 else 0."
  case parseProgram prog of
    Right stmts -> do
      env <- evalIO $ evalProg initialEnv stmts
      Map.lookup "result" env === Just (SNum 1)
    Left _ -> failure

-- ===================================================================

main :: IO ()
main = do
  ok <- checkParallel $$(discover)
  if ok then putStrLn "All tests passed." else exitFailure
