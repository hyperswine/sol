{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

-- | Sol evaluator and built-in functions.
--
-- Design:
--   * 'evalExpr' is pure-functional except for IO effects.
--   * The environment is threaded explicitly (dynamic scope – no closures).
--   * 'apply' handles partial application: if fewer args than arity are
--     supplied the result is a 'SPartial' value.
--   * Built-in functions receive the current Env so higher-order ones
--     (map, filter, fold) can call back into the interpreter.
--   * Shell-heavy features (sha256, wget, etc.) delegate to the system shell.
module Sol.Eval (evalExpr, evalStmt, evalProg, apply, initialEnv) where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (foldM, forM_)
import Data.Char (isAlphaNum, isLetter)
import Data.List (intercalate, isPrefixOf, isSuffixOf, sort, sortBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import Sol.Syntax
import Sol.Value
import System.Directory (copyFile, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, findExecutable, getCurrentDirectory, getFileSize, listDirectory, removeDirectoryRecursive, removeFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeDirectory, takeExtension, takeFileName, (</>))
import System.IO (hGetContents, hPutStrLn, hSetBuffering, stderr, BufferMode(..))
import System.Process (readProcessWithExitCode, createProcess, proc, std_err, std_out, StdStream(..), waitForProcess)

-- ============================================================
-- Evaluator
-- ============================================================

-- | Evaluate an expression in the given environment
evalExpr :: Env -> Expr -> IO SolVal
evalExpr _ (ENum n) = return (SNum n)
evalExpr _ (EStr s) = return (SStr s)
evalExpr env (EFStr t) = SStr <$> interpolate env t
evalExpr env (EList es) = SList <$> mapM (evalExpr env) es
evalExpr env (EDict pairs) = do
  kvs <- mapM evalPair pairs
  return (SDict (Map.fromList kvs))
  where
    evalPair (k, v) = do
      ek <- evalExpr env k
      ev <- evalExpr env v
      return (showVal ek, ev)

-- Variable lookup:
--   0-arity builtins are auto-called
--   0-param SGuarded values are evaluated immediately
--   unknown names fall back to SStr
evalExpr env (EVar name) = case Map.lookup name env of
  Just (SBuiltin _ 0 impl) -> impl env []
  Just (SGuarded clauses) | all (\(ps, _, _) -> null ps) clauses -> do
    mval <- tryAllClauses env clauses []
    case mval of
      Just v  -> return v
      Nothing -> solError ("no matching clause for '" ++ name ++ "'")
  Just v -> return v
  Nothing -> return (SStr name)
evalExpr env (EAccess base keys) = do
  bval <- evalExpr env base
  foldM (applyKey env) bval keys
evalExpr env (EApp func args) = do
  fval <- evalExpr env func
  avals <- mapM (evalExpr env) args
  apply env fval avals

-- Pipeline: val |> [f, extraArgs] |> ...
-- Each stage inserts the accumulated value as the LAST argument to f.
evalExpr env (EPipe base stages) = do
  initVal <- evalExpr env base
  foldM applyStage initVal stages
  where
    applyStage val (fExpr : argExprs) = do
      fval <- evalExpr env fExpr
      avals <- mapM (evalExpr env) argExprs
      apply env fval (avals ++ [val])
    applyStage val [] = return val

-- ============================================================
-- Function application with partial application
-- ============================================================

apply :: Env -> SolVal -> [SolVal] -> IO SolVal
-- No arguments: return the function as-is (used internally)
apply _ fn [] = return fn
-- Peel off accumulated args from a partial application
apply env (SPartial fn args0) args1 = apply env fn (args0 ++ args1)
-- User-defined function (dynamic scope: merge params into calling env)
apply env (SFun params body) args
  | have < need = return (SPartial (SFun params body) args)
  | otherwise = do
      let callEnv = Map.fromList (zip params args) `Map.union` env
      evalExpr callEnv body
  where
    have = length args
    need = length params

-- Guarded function: try clauses top-to-bottom
apply env (SGuarded clauses) args
  | have < need && have > 0 = return (SPartial (SGuarded clauses) args)
  | otherwise = do
      mval <- tryAllClauses env clauses args
      case mval of
        Just v  -> return v
        Nothing -> solError "no matching clause for guarded function"
  where
    have = length args
    need = case clauses of ((ps, _, _) : _) -> length ps; [] -> 0

-- Built-in function
apply env (SBuiltin n arity impl) args
  | arity >= 0 && length args < arity = return (SPartial (SBuiltin n arity impl) args)
  | otherwise = impl env args
apply _ fn args = solError ("cannot apply " ++ showVal fn ++ " to " ++ show (length args) ++ " arguments")

-- ============================================================
-- Access key application
-- ============================================================

applyKey :: Env -> SolVal -> Key -> IO SolVal
applyKey _ (SDict m) (KStr k) = case Map.lookup k m of
  Just v -> return v
  Nothing -> solError ("key not found: " ++ show k ++ " in {" ++ intercalate ", " (map show (Map.keys m)) ++ "}")
applyKey env (SDict m) (KVar n) = do
  kv <- evalExpr env (EVar n)
  applyKey env (SDict m) (KStr (showVal kv))
applyKey _ (SList xs) (KNum i) =
  let idx = round i - 1 -- Sol is 1-based
   in if idx >= 0 && idx < length xs
        then return (xs !! idx)
        else solError ("index " ++ show (round i :: Int) ++ " out of range (length " ++ show (length xs) ++ ")")
applyKey env (SList xs) (KVar n) = do
  kv <- evalExpr env (EVar n)
  case kv of
    SNum i -> applyKey env (SList xs) (KNum i)
    _ -> solError ("list index must be a number, got " ++ showVal kv)
applyKey _ obj key =
  solError ("cannot access key " ++ showKey key ++ " on " ++ showVal obj)

showKey :: Key -> String
showKey (KStr s) = show s
showKey (KNum n) = show (round n :: Int)
showKey (KVar v) = "(" ++ v ++ ")"

-- ============================================================
-- Statement evaluation (returns updated env)
-- ============================================================

evalStmt :: Env -> Stmt -> IO Env
evalStmt env (SAssign name params (Just guard_) body) = do
  -- Guarded clause: accumulate onto any existing SGuarded for this name
  let newClause = (params, Just guard_, body)
  let updated = case Map.lookup name env of
        Just (SGuarded cs) -> SGuarded (cs ++ [newClause])
        _                  -> SGuarded [newClause]
  return (Map.insert name updated env)
evalStmt env (SAssign name params Nothing body) = do
  -- Unguarded clause
  case Map.lookup name env of
    Just (SGuarded existingClauses) -> do
      -- Final fallthrough for an existing guarded definition
      let newClause = (params, Nothing, body)
      return (Map.insert name (SGuarded (existingClauses ++ [newClause])) env)
    _ ->
      -- Simple unguarded definition (same as before)
      if null params
        then do
          val <- evalExpr env body
          return (Map.insert name val env)
        else return (Map.insert name (SFun params body) env)
evalStmt env (SExpr expr) = do
  _ <- evalExpr env expr
  return env

-- | Evaluate a list of statements, threading the environment through
evalProg :: Env -> [Stmt] -> IO Env
evalProg = foldM evalStmt

-- | Walk a clause list top-to-bottom, returning the body of the first match.
tryAllClauses :: Env -> [([String], Maybe Expr, Expr)] -> [SolVal] -> IO (Maybe SolVal)
tryAllClauses _ [] _ = return Nothing
tryAllClauses env ((params, mguard, body) : rest) args = do
  let callEnv = Map.fromList (zip params args) `Map.union` env
  matches <- case mguard of
    Nothing -> return True
    Just g  -> isTruthy <$> evalExpr callEnv g
  if matches
    then Just <$> evalExpr callEnv body
    else tryAllClauses env rest args

-- ============================================================
-- F-string interpolation
-- ============================================================

interpolate :: Env -> String -> IO String
interpolate env tmpl = go tmpl
  where
    go [] = return []
    go ('{' : rest) =
      let (name, after) = span (\c -> isAlphaNum c || c == '_') rest
       in case after of
            ('}' : rest') -> do
              val <- evalVar name
              rest'' <- go rest'
              return (showVal val ++ rest'')
            _ -> ('{' :) <$> go rest -- malformed interpolation → keep as-is
    go (c : rest) = (c :) <$> go rest
    evalVar name = case Map.lookup name env of
      Just (SBuiltin _ 0 impl) -> impl env []
      Just (SGuarded clauses) | all (\(ps, _, _) -> null ps) clauses -> do
        mval <- tryAllClauses env clauses []
        case mval of
          Just v  -> return v
          Nothing -> return (SStr ("{" ++ name ++ "}"))
      Just v  -> return v
      Nothing -> return (SStr ("{" ++ name ++ "}"))

-- ============================================================
-- Error helper
-- ============================================================

solError :: String -> IO a
solError msg = ioError (userError ("[sol] " ++ msg))

-- ============================================================
-- Built-in functions
-- ============================================================

-- | Smart constructor for a fixed-arity builtin
builtin :: String -> Int -> (Env -> [SolVal] -> IO SolVal) -> (String, SolVal)
builtin name arity impl = (name, SBuiltin name arity impl)

-- | All built-ins; loaded into the initial environment
initialEnv :: Env
initialEnv =
  Map.fromList
    -- I/O
    [ builtin "echo" 1 bEcho,
      builtin "print" 1 bEcho,
      builtin "str" 1 (\_ [v] -> return (SStr (showVal v))),
      builtin "num" 1 bNum,
      builtin "bool" 1 (\_ [v] -> return (SBool (isTruthy v))),
      builtin "exit" 0 bExit,
      builtin "exit" 1 bExitCode, -- overridden below; both arities handled

      -- Arithmetic (arity 2, support partial application)
      builtin "+" 2 (\_ [a, b] -> numOp2 (+) a b),
      builtin "-" 2 (\_ [a, b] -> numOp2 (-) a b),
      builtin "*" 2 (\_ [a, b] -> numOp2 (*) a b),
      builtin "/" 2 (\_ [a, b] -> numOp2 (/) a b),
      builtin "mod" 2 (\_ [a, b] -> numOp2 (\x y -> fromIntegral (floor x `mod` floor y :: Integer)) a b),
      -- Comparisons (curried: (> threshold) returns a predicate)
      builtin ">" 2 (\_ [a, b] -> cmpOp (>) a b),
      builtin "<" 2 (\_ [a, b] -> cmpOp (<) a b),
      builtin ">=" 2 (\_ [a, b] -> cmpOp (>=) a b),
      builtin "<=" 2 (\_ [a, b] -> cmpOp (<=) a b),
      builtin "==" 2 (\_ [a, b] -> return (SBool (eqVal a b))),
      builtin "!=" 2 (\_ [a, b] -> return (SBool (not (eqVal a b)))),
      builtin "not" 1 (\_ [v] -> return (SBool (not (isTruthy v)))),
      builtin "and" 2 (\_ [a, b] -> return (SBool (isTruthy a && isTruthy b))),
      builtin "or" 2 (\_ [a, b] -> return (SBool (isTruthy a || isTruthy b))),
      -- Higher-order functions
      builtin "map" 2 bMap,
      builtin "filter" 2 bFilter,
      builtin "fold" (-1) bFold,
      builtin "each" 2 bEach,
      -- List / string operations
      builtin "len" 1 (\_ [v] -> return (SNum (fromIntegral (lenOf v)))),
      builtin "head" 1 (\_ [v] -> bHead v),
      builtin "tail" 1 (\_ [v] -> bTail v),
      builtin "append" 2 (\_ [l, x] -> bAppend l x),
      builtin "prepend" 2 (\_ [x, l] -> bPrepend x l),
      builtin "concat" 2 (\_ [a, b] -> bConcat a b),
      builtin "reverse" 1 (\_ [v] -> bReverse v),
      builtin "sort" 1 (\_ [v] -> bSort v),
      builtin "range" 2 (\_ [a, b] -> bRange a b),
      builtin "zip" 2 (\_ [a, b] -> bZip a b),
      builtin "flatten" 1 (\_ [v] -> bFlatten v),
      builtin "contains" 2 (\_ [a, b] -> bContains a b),
      builtin "lines" 1 (\_ [v] -> return (SList (map SStr (splitLines (asStr v))))),
      builtin "unlines" 1 (\_ [v] -> bJoinWith "\n" v),
      builtin "words" 1 (\_ [v] -> return (SList (map SStr (words (asStr v))))),
      builtin "unwords" 1 (\_ [v] -> bJoinWith " " v),
      -- String operations
      builtin "trim" 1 (\_ [v] -> return (SStr (trim (asStr v)))),
      builtin "split" 2 (\_ [sep, s] -> return (SList (map SStr (splitOn (asStr sep) (asStr s))))),
      builtin "join" 2 (\_ [sep, v] -> bJoinWith (asStr sep) v),
      builtin "replace" 3 (\_ [old, new_, s] -> return (SStr (replaceAll (asStr old) (asStr new_) (asStr s)))),
      builtin "upper" 1 (\_ [v] -> return (SStr (map toUpperChar (asStr v)))),
      builtin "lower" 1 (\_ [v] -> return (SStr (map toLowerChar (asStr v)))),
      builtin "startswith" 2 (\_ [pre, s] -> return (SBool (asStr pre `isPrefixOf` asStr s))),
      builtin "endswith" 2 (\_ [suf, s] -> return (SBool (asStr suf `isSuffixOf` asStr s))),
      builtin "grep" 2 (\_ [pat, s] -> bGrep pat s),
      -- Dict operations
      builtin "keys" 1 (\_ [v] -> bKeys v),
      builtin "values" 1 (\_ [v] -> bValues v),
      builtin "set" 3 (\_ [d, k, val] -> bSet d k val),
      builtin "get" 2 (\_ [d, k] -> bGet d k),
      builtin "has" 2 (\_ [d, k] -> bHas d k),
      builtin "delete" 2 (\_ [d, k] -> bDelete d k),
      builtin "merge" 2 (\_ [a, b] -> bMerge a b),
      -- Filesystem
      builtin "read" 1 bReadFile,
      builtin "write" 2 bWriteFile,
      builtin "cp" 2 bCp,
      builtin "ls" (-1) bLs,
      builtin "mkdir" 1 bMkdir,
      builtin "rm" 1 bRm,
      builtin "exists" 1 bExists,
      builtin "name" 1 (\_ [v] -> return (SStr (takeFileName (asStr v)))),
      builtin "ext" 1 (\_ [v] -> return (SStr (takeExtension (asStr v)))),
      builtin "dir" 1 (\_ [v] -> return (SStr (takeDirectory (asStr v)))),
      builtin "path" 2 (\_ [a, b] -> return (SStr (asStr a </> asStr b))),
      builtin "cwd" 0 (\_ [] -> SStr <$> getCurrentDirectory),
      builtin "pwd" 0 (\_ [] -> SStr <$> getCurrentDirectory),
      -- System / process
      builtin "sh" 1 bSh,
      builtin "getenv" 1 (\_ [v] -> bGetenv v),
      builtin "setenv" 2 bSetenv,
      builtin "args" 0 (\_ [] -> return (SList [])), -- stub

      -- Result helpers (sh returns a dict with exitcode / stdout / stderr)
      builtin "failed" 1 (\_ [v] -> return (SBool (isFailed v))),
      builtin "succeeded" 1 (\_ [v] -> return (SBool (not (isFailed v)))),
      builtin "unwrap_or" 2 bUnwrapOr,
      builtin "unwrap_or_exit" 2 bUnwrapOrExit,
      builtin "stdout" 1 (\_ [v] -> resultField "stdout" v),
      builtin "stderr_str" 1 (\_ [v] -> resultField "stderr" v),
      -- Hashing (shells out to system tools)
      builtin "sha256" 1 bSha256,
      builtin "md5" 1 bMd5,
      -- JSON
      builtin "jsonparse" 1 bJsonParse,
      builtin "jsonstringify" 1 bJsonStringify,
      builtin "jsonread" 1 bJsonRead,
      builtin "jsonwrite" 2 bJsonWrite,
      -- CSV (simple implementation)
      builtin "csvread" 1 bCsvRead,
      builtin "csvwrite" 2 bCsvWrite,
      -- HTTP (via curl)
      builtin "wget" (-1) bWget,
      builtin "get" (-1) bWget,
      builtin "progress" (-1) bProgress,
      -- Miscellaneous
      builtin "type" 1 (\_ [v] -> return (SStr (typeName v))),
      builtin "place" 2 bPlace
    ]
  where
    -- exit has two forms: exit (code 0) and exit n
    -- Override the 0-arity with the correct implementation
    applyBuiltin env_ (SBuiltin _ 0 impl) = impl env_ []
    applyBuiltin _ v = return v

-- ============================================================
-- Operator helpers
-- ============================================================

numOp2 :: (Double -> Double -> Double) -> SolVal -> SolVal -> IO SolVal
numOp2 f (SNum a) (SNum b) = return (SNum (f a b))
numOp2 f (SStr a) (SStr b) = return (SStr (show (f (read a) (read b))))
numOp2 _ a b = solError ("arithmetic requires numbers, got " ++ typeName a ++ " and " ++ typeName b)

-- | Comparison: standard infix order — a `op` b (left to right)
cmpOp :: (Double -> Double -> Bool) -> SolVal -> SolVal -> IO SolVal
cmpOp f (SNum a) (SNum b) = return (SBool (f a b))
cmpOp f (SStr a) (SStr b) = return (SBool (f (fromIntegral (fromEnum (head a))) (fromIntegral (fromEnum (head b)))))
cmpOp f a b = return (SBool (f (toDouble a) (toDouble b)))
  where
    toDouble (SNum n) = n
    toDouble _ = 0

eqVal :: SolVal -> SolVal -> Bool
eqVal (SNum a) (SNum b) = a == b
eqVal (SStr a) (SStr b) = a == b
eqVal (SBool a) (SBool b) = a == b
eqVal SNull SNull = True
eqVal (SList a) (SList b) = length a == length b && and (zipWith eqVal a b)
eqVal (SDict a) (SDict b) =
  Map.keys a == Map.keys b
    && all (\k -> maybe False id (eqVal <$> Map.lookup k a <*> Map.lookup k b)) (Map.keys a)
eqVal _ _ = False

instance Eq SolVal where
  (==) = eqVal

-- ============================================================
-- Built-in implementations
-- ============================================================

bEcho :: Env -> [SolVal] -> IO SolVal
bEcho _ [v] = putStrLn (showVal v) >> return SNull
bEcho _ vs = mapM_ (putStrLn . showVal) vs >> return SNull

bNum :: Env -> [SolVal] -> IO SolVal
bNum _ [SNum n] = return (SNum n)
bNum _ [SStr s] = case reads s of
  [(n, "")] -> return (SNum n)
  _ -> solError ("cannot convert to number: " ++ show s)
bNum _ [SBool b] = return (SNum (if b then 1 else 0))
bNum _ [v] = solError ("cannot convert to number: " ++ typeName v)
bNum _ _ = solError "num: wrong number of arguments"

bExit :: Env -> [SolVal] -> IO SolVal
bExit _ [] = exitWith ExitSuccess >> return SNull
bExit _ _ = exitWith ExitSuccess >> return SNull

bExitCode :: Env -> [SolVal] -> IO SolVal
bExitCode _ [SNum n]
  | n == 0 = exitWith ExitSuccess >> return SNull
  | otherwise = exitWith (ExitFailure (round n)) >> return SNull
bExitCode _ _ = exitWith ExitSuccess >> return SNull

-- Higher-order

bMap :: Env -> [SolVal] -> IO SolVal
bMap env [f, SList xs] = SList <$> mapM (\x -> apply env f [x]) xs
bMap env [f, SStr s]   = SList <$> mapM (\c -> apply env f [SStr [c]]) s
bMap _ [_, v] = solError ("map: expected a list or string, got " ++ typeName v)
bMap _ _ = solError "map: expected function and list"

bFilter :: Env -> [SolVal] -> IO SolVal
bFilter env [f, SList xs] = do
  results <- mapM (\x -> apply env f [x]) xs
  return (SList [x | (x, r) <- zip xs results, isTruthy r])
bFilter env [f, SStr s] = do
  results <- mapM (\c -> apply env f [SStr [c]]) s
  return (SStr [c | (c, r) <- zip s results, isTruthy r])
bFilter _ [_, v] = solError ("filter: expected a list or string, got " ++ typeName v)
bFilter _ _ = solError "filter: expected function and list"

bFold :: Env -> [SolVal] -> IO SolVal
-- 2-arg form: fold fn list  (first element is initial accumulator)
bFold env [f, SList (x : xs)] = foldM (\acc el -> apply env f [acc, el]) x xs
bFold _   [_, SList []]       = solError "fold: empty list"
bFold env [f, SStr (c : cs)]  = foldM (\acc ch -> apply env f [acc, SStr [ch]]) (SStr [c]) cs
bFold _   [_, SStr ""]        = solError "fold: empty string"
-- 3-arg form: fold fn init list  (explicit initial accumulator)
bFold env [f, ini, SList xs]  = foldM (\acc el -> apply env f [acc, el]) ini xs
bFold env [f, ini, SStr s]    = foldM (\acc c  -> apply env f [acc, SStr [c]]) ini s
bFold _   [_, _, v]           = solError ("fold: third argument must be a list or string, got " ++ typeName v)
bFold _   [_, v]              = solError ("fold: second argument must be a list or string, got " ++ typeName v)
bFold _   _                   = solError "fold: usage: fold fn list  OR  fold fn init list"

bEach :: Env -> [SolVal] -> IO SolVal
bEach env [f, SList xs] = mapM_ (\x -> apply env f [x]) xs >> return SNull
bEach env [f, SStr s]   = mapM_ (\c -> apply env f [SStr [c]]) s >> return SNull
bEach _ _ = solError "each: expected function and list"

-- List operations

bHead :: SolVal -> IO SolVal
bHead (SList (x : _)) = return x
bHead (SList []) = solError "head: empty list"
bHead (SStr (c : _)) = return (SStr [c])
bHead v = solError ("head: expected a list, got " ++ typeName v)

bTail :: SolVal -> IO SolVal
bTail (SList (_ : xs)) = return (SList xs)
bTail (SList []) = solError "tail: empty list"
bTail (SStr (_ : cs)) = return (SStr cs)
bTail v = solError ("tail: expected a list, got " ++ typeName v)

bAppend :: SolVal -> SolVal -> IO SolVal
bAppend (SList xs) x = return (SList (xs ++ [x]))
bAppend v _ = solError ("append: expected a list, got " ++ typeName v)

bPrepend :: SolVal -> SolVal -> IO SolVal
bPrepend x (SList xs) = return (SList (x : xs))
bPrepend _ v = solError ("prepend: expected a list, got " ++ typeName v)

bConcat :: SolVal -> SolVal -> IO SolVal
bConcat (SList a) (SList b) = return (SList (a ++ b))
bConcat (SStr a) (SStr b) = return (SStr (a ++ b))
bConcat a b = solError ("concat: incompatible types " ++ typeName a ++ " and " ++ typeName b)

bReverse :: SolVal -> IO SolVal
bReverse (SList xs) = return (SList (reverse xs))
bReverse (SStr s) = return (SStr (reverse s))
bReverse v = solError ("reverse: expected list or string, got " ++ typeName v)

bSort :: SolVal -> IO SolVal
bSort (SList xs) = return (SList (map snd (sortBy (comparing fst) (map (\v -> (sortKey v, v)) xs))))
bSort v = solError ("sort: expected list, got " ++ typeName v)

bRange :: SolVal -> SolVal -> IO SolVal
bRange (SNum a) (SNum b) =
  return (SList [SNum (fromIntegral i) | i <- [round a .. round b - 1 :: Integer]])
bRange a b = solError ("range: expected numbers, got " ++ typeName a ++ " and " ++ typeName b)

bZip :: SolVal -> SolVal -> IO SolVal
bZip (SList a) (SList b) = return (SList (zipWith (\x y -> SList [x, y]) a b))
bZip a b = solError ("zip: expected two lists, got " ++ typeName a ++ " and " ++ typeName b)

bFlatten :: SolVal -> IO SolVal
bFlatten (SList xs) = return (SList (concatMap flatten1 xs))
  where
    flatten1 (SList ys) = ys
    flatten1 y = [y]
bFlatten v = solError ("flatten: expected list, got " ++ typeName v)

bContains :: SolVal -> SolVal -> IO SolVal
bContains (SList xs) x = return (SBool (x `elem` xs))
bContains (SStr s) (SStr sub) = return (SBool (sub `isInfixOf` s))
  where
    isInfixOf needle haystack = any (needle `isPrefixOf`) (tails haystack)
    tails [] = [[]]
    tails l@(_ : t) = l : tails t
bContains (SDict m) (SStr k) = return (SBool (Map.member k m))
bContains a b = solError ("contains: incompatible types " ++ typeName a ++ " and " ++ typeName b)

lenOf :: SolVal -> Int
lenOf (SList xs) = length xs
lenOf (SStr s) = length s
lenOf (SDict m) = Map.size m
lenOf _ = 0

bJoinWith :: String -> SolVal -> IO SolVal
bJoinWith sep (SList xs) = return (SStr (intercalate sep (map showVal xs)))
bJoinWith _ v = solError ("join: expected list, got " ++ typeName v)

bGrep :: SolVal -> SolVal -> IO SolVal
bGrep (SStr pat) (SStr text) =
  return (SList (map SStr (filter (pat `isInfixOf`) (splitLines text))))
  where
    isInfixOf needle haystack = any (needle `isPrefixOf`) (tails haystack)
    tails [] = [[]]
    tails l@(_ : t) = l : tails t
bGrep pat text = solError ("grep: expected strings, got " ++ typeName pat ++ " and " ++ typeName text)

-- String helpers
trim :: String -> String
trim = reverse . dropWhile (== ' ') . reverse . dropWhile (== ' ')

splitOn :: String -> String -> [String]
splitOn _ "" = [""]
splitOn sep s = go s
  where
    go "" = [""]
    go str
      | sep `isPrefixOf` str = "" : go (drop (length sep) str)
      | otherwise =
          let (w : ws) = go (tail str)
           in (head str : w) : ws

replaceAll :: String -> String -> String -> String
replaceAll _ _ "" = ""
replaceAll old new_ s
  | old `isPrefixOf` s = new_ ++ replaceAll old new_ (drop (length old) s)
  | otherwise = head s : replaceAll old new_ (tail s)

toUpperChar :: Char -> Char
toUpperChar c
  | c >= 'a' && c <= 'z' = toEnum (fromEnum c - 32)
  | otherwise = c

toLowerChar :: Char -> Char
toLowerChar c
  | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
  | otherwise = c

splitLines :: String -> [String]
splitLines "" = [""]
splitLines s = lines s

-- Dict operations

bKeys :: SolVal -> IO SolVal
bKeys (SDict m) = return (SList (map SStr (Map.keys m)))
bKeys v = solError ("keys: expected dict, got " ++ typeName v)

bValues :: SolVal -> IO SolVal
bValues (SDict m) = return (SList (Map.elems m))
bValues v = solError ("values: expected dict, got " ++ typeName v)

bSet :: SolVal -> SolVal -> SolVal -> IO SolVal
bSet (SDict m) (SStr k) val = return (SDict (Map.insert k val m))
bSet (SList xs) (SNum i) val =
  let idx = round i - 1
   in if idx >= 0 && idx < length xs
        then return (SList (take idx xs ++ [val] ++ drop (idx + 1) xs))
        else solError ("set: index " ++ show (round i :: Int) ++ " out of range")
bSet d k _ = solError ("set: expected dict/list, got " ++ typeName d ++ " with key " ++ showVal k)

bGet :: SolVal -> SolVal -> IO SolVal
bGet (SDict m) (SStr k) = case Map.lookup k m of
  Just v -> return v
  Nothing -> return SNull
bGet d k = solError ("get: expected dict, got " ++ typeName d ++ " with key " ++ showVal k)

bHas :: SolVal -> SolVal -> IO SolVal
bHas (SDict m) (SStr k) = return (SBool (Map.member k m))
bHas _ _ = return (SBool False)

bDelete :: SolVal -> SolVal -> IO SolVal
bDelete (SDict m) (SStr k) = return (SDict (Map.delete k m))
bDelete d k = solError ("delete: expected dict, got " ++ typeName d)

bMerge :: SolVal -> SolVal -> IO SolVal
bMerge (SDict a) (SDict b) = return (SDict (Map.union b a)) -- b overrides a
bMerge a b = solError ("merge: expected dicts, got " ++ typeName a ++ " and " ++ typeName b)

-- Filesystem

bReadFile :: Env -> [SolVal] -> IO SolVal
bReadFile _ [SStr path] = do
  ok <- doesFileExist path
  if ok
    then SStr <$> readFile path
    else solError ("read: file not found: " ++ path)
bReadFile _ [v] = solError ("read: expected a path string, got " ++ typeName v)
bReadFile _ _ = solError "read: expected exactly one argument"

bWriteFile :: Env -> [SolVal] -> IO SolVal
bWriteFile _ [SStr path, v] = writeFile path (showVal v) >> return SNull
bWriteFile _ [v, _] = solError ("write: expected path string, got " ++ typeName v)
bWriteFile _ _ = solError "write: expected path and content"

bCp :: Env -> [SolVal] -> IO SolVal
bCp _ [SStr src, SStr dst] = copyFile src dst >> return SNull
bCp _ [v, _] = solError ("cp: expected source path string, got " ++ typeName v)
bCp _ [_, v] = solError ("cp: expected destination path string, got " ++ typeName v)
bCp _ _ = solError "cp: expected source and destination paths"

bLs :: Env -> [SolVal] -> IO SolVal
bLs _ [] = SList . map SStr <$> listDirectory "."
bLs _ [SStr path] = do
  ok <- doesDirectoryExist path
  if ok
    then SList . map SStr <$> listDirectory path
    else solError ("ls: directory not found: " ++ path)
bLs _ _ = solError "ls: expected an optional path string"

bMkdir :: Env -> [SolVal] -> IO SolVal
bMkdir _ [SStr path] = createDirectoryIfMissing True path >> return SNull
bMkdir _ _ = solError "mkdir: expected a path string"

bRm :: Env -> [SolVal] -> IO SolVal
bRm _ [SStr path] = do
  isFile <- doesFileExist path
  isDir <- doesDirectoryExist path
  if isFile
    then removeFile path
    else
      if isDir
        then removeDirectoryRecursive path
        else solError ("rm: not found: " ++ path)
  return SNull
bRm _ _ = solError "rm: expected a path string"

bExists :: Env -> [SolVal] -> IO SolVal
bExists _ [SStr path] = do
  f <- doesFileExist path
  d <- doesDirectoryExist path
  return (SBool (f || d))
bExists _ _ = solError "exists: expected a path string"

bPlace :: Env -> [SolVal] -> IO SolVal
bPlace _ [SStr src, SStr dest] = do
  let destPath = dest </> takeFileName src
  content <- readFile src
  writeFile destPath content
  return (SStr destPath)
bPlace _ _ = solError "place: expected source and destination paths"

-- Shell

bSh :: Env -> [SolVal] -> IO SolVal
bSh _ [SStr cmd] = do
  (exitCode, out, err) <- readProcessWithExitCode "sh" ["-c", cmd] ""
  let ec = case exitCode of ExitSuccess -> 0; ExitFailure n -> n
  return $
    SDict $
      Map.fromList
        [ ("exitcode", SNum (fromIntegral ec)),
          ("stdout", SStr out),
          ("stderr", SStr err)
        ]
bSh _ [v] = solError ("sh: expected a command string, got " ++ typeName v)
bSh _ _ = solError "sh: expected a command string"

bGetenv :: SolVal -> IO SolVal
bGetenv (SStr k) = maybe SNull SStr <$> lookupEnv k
bGetenv v = solError ("getenv: expected string, got " ++ typeName v)

bSetenv :: Env -> [SolVal] -> IO SolVal
bSetenv _ [SStr k, v] = do
  -- We can't set env vars for the parent process; just return null
  hPutStrLn stderr ("[sol] warning: setenv has no effect on parent environment")
  return SNull
bSetenv _ _ = solError "setenv: expected key and value"

-- Result helpers

isFailed :: SolVal -> Bool
isFailed (SDict m) = case Map.lookup "exitcode" m of
  Just (SNum n) -> n /= 0
  _ -> False
isFailed _ = False

resultField :: String -> SolVal -> IO SolVal
resultField key (SDict m) = return (fromMaybe SNull (Map.lookup key m))
resultField key v = solError (key ++ ": expected a result dict, got " ++ typeName v)

bUnwrapOr :: Env -> [SolVal] -> IO SolVal
bUnwrapOr _ [def, v]
  | isFailed v = return def
  | v == SNull = return def
  | otherwise = return v
bUnwrapOr _ _ = solError "unwrap_or: expected default and value"

bUnwrapOrExit :: Env -> [SolVal] -> IO SolVal
bUnwrapOrExit _ [msg, v]
  | isFailed v || v == SNull = do
      hPutStrLn stderr (showVal msg)
      exitWith (ExitFailure 1)
      return SNull
  | otherwise = return v
bUnwrapOrExit _ _ = solError "unwrap_or_exit: expected message and value"

-- Hashing (delegate to system tools)

bSha256 :: Env -> [SolVal] -> IO SolVal
bSha256 _ [SStr s] = do
  (ec, out, _) <-
    readProcessWithExitCode
      "sh"
      ["-c", "printf '%s' " ++ show s ++ " | shasum -a 256"]
      ""
  case ec of
    ExitSuccess -> return (SStr (takeWhile (/= ' ') (trim out)))
    _ -> do
      (ec2, out2, _) <-
        readProcessWithExitCode
          "sh"
          ["-c", "printf '%s' " ++ show s ++ " | sha256sum"]
          ""
      return (SStr (takeWhile (/= ' ') (trim out2)))
bSha256 _ [v] = solError ("sha256: expected string, got " ++ typeName v)
bSha256 _ _ = solError "sha256: expected one argument"

bMd5 :: Env -> [SolVal] -> IO SolVal
bMd5 _ [SStr s] = do
  (_, out, _) <-
    readProcessWithExitCode
      "sh"
      ["-c", "printf '%s' " ++ show s ++ " | md5"]
      ""
  return (SStr (trim out))
bMd5 _ [v] = solError ("md5: expected string, got " ++ typeName v)
bMd5 _ _ = solError "md5: expected one argument"

-- JSON (simple recursive encoder/decoder, no external lib dependency)

bJsonParse :: Env -> [SolVal] -> IO SolVal
bJsonParse _ [SStr s] = case parseJson s of
  Right v -> return v
  Left e -> solError ("jsonparse: " ++ e)
bJsonParse _ [v] = solError ("jsonparse: expected string, got " ++ typeName v)
bJsonParse _ _ = solError "jsonparse: expected one argument"

bJsonStringify :: Env -> [SolVal] -> IO SolVal
bJsonStringify _ [v] = return (SStr (jsonStringify v))
bJsonStringify _ _ = solError "jsonstringify: expected one argument"

bJsonRead :: Env -> [SolVal] -> IO SolVal
bJsonRead _ [SStr path] = do
  content <- readFile path
  case parseJson content of
    Right v -> return v
    Left e -> solError ("jsonread: " ++ e)
bJsonRead _ [v] = solError ("jsonread: expected path string, got " ++ typeName v)
bJsonRead _ _ = solError "jsonread: expected one argument"

bJsonWrite :: Env -> [SolVal] -> IO SolVal
bJsonWrite _ [v, SStr path] = writeFile path (jsonStringify v) >> return SNull
bJsonWrite _ _ = solError "jsonwrite: expected value and path"

-- CSV (simple comma-separated)

bCsvRead :: Env -> [SolVal] -> IO SolVal
bCsvRead _ [SStr path] = do
  content <- readFile path
  let rows = map (SList . map SStr . splitOn ",") (splitLines content)
  return (SList rows)
bCsvRead _ [v] = solError ("csvread: expected path string, got " ++ typeName v)
bCsvRead _ _ = solError "csvread: expected one argument"

bCsvWrite :: Env -> [SolVal] -> IO SolVal
bCsvWrite _ [SList rows, SStr path] = do
  let stringify (SList cols) = intercalate "," (map showVal cols)
      stringify v = showVal v
  writeFile path (unlines (map stringify rows))
  return SNull
bCsvWrite _ _ = solError "csvwrite: expected list and path"

-- HTTP via curl

bWget :: Env -> [SolVal] -> IO SolVal
bWget _ [SStr url] = do
  (ec, out, err) <- readProcessWithExitCode "curl" ["-s", "-L", url] ""
  case ec of
    ExitSuccess -> return (SStr out)
    _ -> solError ("wget: curl failed: " ++ trim err)
bWget _ [SStr url, progress] = do
  let showBar = isTruthy progress
  if showBar
    then do
      -- Inherit stderr so curl's progress bar renders on the terminal
      (_, Just hOut, _, ph) <- createProcess
        (proc "curl" ["-L", "--progress-bar", url])
          { std_out = CreatePipe, std_err = Inherit }
      out <- hGetContents hOut
      _ <- length out `seq` waitForProcess ph
      return (SStr out)
    else do
      (ec, out, err) <- readProcessWithExitCode "curl" ["-s", "-L", url] ""
      case ec of
        ExitSuccess -> return (SStr out)
        _ -> solError ("wget: curl failed: " ++ trim err)
bWget _ [v] = solError ("wget: expected URL string, got " ++ typeName v)
bWget _ _ = solError "wget: expected url [progress]"

-- Progress wrapper

isCallable :: SolVal -> Bool
isCallable (SBuiltin _ _ _) = True
isCallable (SFun _ _)       = True
isCallable (SPartial _ _)   = True
isCallable _                = False

bProgress :: Env -> [SolVal] -> IO SolVal
-- wget: enable curl --progress-bar (progress goes to stderr, result is stdout)
bProgress env (SBuiltin "wget" _ impl : args) =
  impl env (args ++ [SBool True])
-- cp: use pv for known-size progress, fallback to copyFile with a warning
bProgress env (SBuiltin "cp" _ impl : [SStr src, SStr dst]) = do
  hasPv <- findExecutable "pv"
  case hasPv of
    Just _ -> do
      fsize <- getFileSize src
      -- Inherit stderr so pv's progress bar renders on the terminal
      (_, _, _, ph) <- createProcess
        (proc "pv" ["-s", show fsize, "-o", dst, src])
          { std_err = Inherit }
      ec <- waitForProcess ph
      case ec of
        ExitSuccess -> return SNull
        _ -> do
          hPutStrLn stderr "[sol] pv failed, falling back to plain copy"
          copyFile src dst >> return SNull
    Nothing -> do
      hPutStrLn stderr "Might take a while..."
      impl env [SStr src, SStr dst]
-- Generic callable with args: warn then call
bProgress env (f : args) | isCallable f = do
  hPutStrLn stderr "Might take a while..."
  apply env f args
-- Already-evaluated single value (e.g. progress (cp "a" "b") with parens): passthrough
bProgress _ [v] = return v
-- Non-callable with extra args (user error)
bProgress _ (v : _) = solError ("progress: expected a function, got " ++ typeName v)
bProgress _ [] = solError "progress: expected at least one argument"

-- ============================================================
-- Minimal JSON parser (no external dependency)
-- ============================================================

parseJson :: String -> Either String SolVal
parseJson s = case runJsonParser (dropWhile isWS s) of
  Just (v, rest) | all isWS rest -> Right v
  Just (_, rest) -> Left ("unexpected trailing input: " ++ take 20 rest)
  Nothing -> Left ("invalid JSON")
  where
    isWS c = c `elem` " \t\n\r"

type JsonParser = String -> Maybe (SolVal, String)

runJsonParser :: JsonParser
runJsonParser s = case s of
  ('"' : _) -> parseJsonStr s
  ('[' : _) -> parseJsonArr s
  ('{' : _) -> parseJsonObj s
  ('t' : _) -> if "true" `isPrefixOf` s then Just (SBool True, drop 4 s) else Nothing
  ('f' : _) -> if "false" `isPrefixOf` s then Just (SBool False, drop 5 s) else Nothing
  ('n' : _) -> if "null" `isPrefixOf` s then Just (SNull, drop 4 s) else Nothing
  _ -> parseJsonNum s

parseJsonStr :: JsonParser
parseJsonStr ('"' : rest) = go rest ""
  where
    go [] _ = Nothing
    go ('"' : rs) acc = Just (SStr (reverse acc), rs)
    go ('\\' : c : rs) acc = go rs (unescape c : acc)
    go (c : rs) acc = go rs (c : acc)
    unescape 'n' = '\n'
    unescape 't' = '\t'
    unescape 'r' = '\r'
    unescape c = c
parseJsonStr _ = Nothing

parseJsonNum :: JsonParser
parseJsonNum s =
  let (numStr, rest) = span (\c -> c `elem` "-0123456789.eE+") s
   in if null numStr
        then Nothing
        else case reads numStr :: [(Double, String)] of
          [(n, "")] -> Just (SNum n, rest)
          _ -> Nothing

parseJsonArr :: JsonParser
parseJsonArr ('[' : rest) = go (dropWhile isWS rest) []
  where
    isWS c = c `elem` " \t\n\r"
    go (']' : rs) acc = Just (SList (reverse acc), rs)
    go s acc = do
      (v, s') <- runJsonParser s
      let s'' = dropWhile isWS s'
      case s'' of
        (',' : s''') -> go (dropWhile isWS s''') (v : acc)
        (']' : s''') -> Just (SList (reverse (v : acc)), s''')
        _ -> Nothing
parseJsonArr _ = Nothing

parseJsonObj :: JsonParser
parseJsonObj ('{' : rest) = go (dropWhile isWS rest) []
  where
    isWS c = c `elem` " \t\n\r"
    go ('}' : rs) acc = Just (SDict (Map.fromList (reverse acc)), rs)
    go s acc = do
      (SStr k, s') <- parseJsonStr s
      let s'' = dropWhile isWS s'
      case s'' of
        (':' : s''') -> do
          (v, s4) <- runJsonParser (dropWhile isWS s''')
          let s5 = dropWhile isWS s4
          case s5 of
            (',' : s6) -> go (dropWhile isWS s6) ((k, v) : acc)
            ('}' : s6) -> Just (SDict (Map.fromList (reverse ((k, v) : acc))), s6)
            _ -> Nothing
        _ -> Nothing
    go _ _ = Nothing
parseJsonObj _ = Nothing

jsonStringify :: SolVal -> String
jsonStringify (SNum n) = showVal (SNum n)
jsonStringify (SStr s) = show s -- uses Haskell's built-in show for proper escaping
jsonStringify (SBool b) = if b then "true" else "false"
jsonStringify SNull = "null"
jsonStringify (SList xs) = "[" ++ intercalate "," (map jsonStringify xs) ++ "]"
jsonStringify (SDict m) = "{" ++ intercalate "," (map pair (Map.toList m)) ++ "}" where pair (k, v) = show k ++ ":" ++ jsonStringify v
jsonStringify v = show (showVal v)

-- ============================================================
-- Utility
-- ============================================================

asStr :: SolVal -> String
asStr (SStr s) = s
asStr (SNum n) = showVal (SNum n)
asStr (SBool b) = if b then "true" else "false"
asStr SNull = ""
asStr v = showVal v

typeName :: SolVal -> String
typeName (SNum _) = "number"
typeName (SStr _) = "string"
typeName (SBool _) = "bool"
typeName SNull = "null"
typeName (SList _) = "list"
typeName (SDict _) = "dict"
typeName (SFun _ _) = "function"
typeName (SBuiltin _ _ _) = "function"
typeName (SPartial _ _) = "function"
typeName (SGuarded _) = "function"

-- Needed for bSort (Key ordering)
sortKey :: SolVal -> Either Double String
sortKey (SNum n) = Left n
sortKey (SStr s) = Right s
sortKey v = Right (showVal v)
