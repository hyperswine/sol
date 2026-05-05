-- | Sol runtime values and environment
module Sol.Value (SolVal (..), Env, showVal, showRepr, isTruthy, emptyEnv) where

import Data.List (intercalate)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Sol.Syntax (Expr, Stmt)

-- | The variable environment maps names to runtime values
type Env = Map String SolVal

-- | Runtime values produced by evaluating Sol expressions
data SolVal
  = SNum Double
  | SStr String
  | SBool Bool
  | SNull
  | SList [SolVal]
  | SDict (Map String SolVal)
  | -- | User-defined function (dynamic scope – params, body)
    SFun [String] Expr
  | -- | Built-in function with fixed arity (-1 = variadic) and IO implementation.
    --   The Env argument lets higher-order builtins (map, filter, fold) call
    --   back into the interpreter via 'apply'.
    SBuiltin String Int (Env -> [SolVal] -> IO SolVal)
  | -- | Partially applied function: base fn + accumulated args so far
    SPartial SolVal [SolVal]
  | -- | Guarded definition: list of (params, optional guard, body) clauses.
    --   Clauses are tried top-to-bottom; first whose guard is truthy wins.
    SGuarded [([String], Maybe Expr, Expr)]
  | -- | Executable handle: resolved on PATH at call time
    SCmd String
  | -- | Named pair / flag tuple: ("key", value)
    SPair (SolVal, SolVal)
  | -- | Loaded-but-unevaluated script module
    SModule FilePath [Stmt]

emptyEnv :: Env
emptyEnv = Map.empty

-- | Display a value for end-user output (no extra quoting)
showVal :: SolVal -> String
showVal (SNum n)
  | not (isNaN n) && not (isInfinite n) && n == fromIntegral (floor n :: Integer) =
      show (floor n :: Integer)
  | otherwise = show n
showVal (SStr s) = s
showVal (SBool True) = "true"
showVal (SBool False) = "false"
showVal SNull = "null"
showVal (SList xs) = "[" ++ intercalate ", " (map showRepr xs) ++ "]"
showVal (SDict m) = "{" ++ intercalate ", " (map pair (Map.toList m)) ++ "}"
  where
    pair (k, v) = show k ++ ": " ++ showRepr v
showVal (SFun ps _) = "<function(" ++ intercalate ", " ps ++ ")>"
showVal (SBuiltin n _ _) = "<builtin:" ++ n ++ ">"
showVal (SPartial f _) = "<partial " ++ showVal f ++ ">"
showVal (SGuarded cs) = "<guarded(" ++ show (length cs) ++ " clauses)>"
showVal (SCmd s) = "<cmd:" ++ s ++ ">"
showVal (SPair (k, v)) = "(" ++ showRepr k ++ ", " ++ showRepr v ++ ")"
showVal (SModule path _) = "<module:" ++ path ++ ">"

-- | Show with quotes for strings (used inside containers)
showRepr :: SolVal -> String
showRepr (SStr s) = show s
showRepr v = showVal v

-- | Sol truthiness: mirrors Python-style semantics
isTruthy :: SolVal -> Bool
isTruthy (SBool False) = False
isTruthy SNull = False
isTruthy (SNum 0) = False
isTruthy (SStr "") = False
isTruthy (SList []) = False
isTruthy (SDict m) = not (Map.null m)
isTruthy _ = True
