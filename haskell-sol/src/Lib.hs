-- | Top-level Sol interpreter API
module Lib
  ( runFile
  , runCode
  , runRepl
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import Data.List (isPrefixOf)
import System.IO (hPutStrLn, stderr)

import System.Console.Haskeline
  ( InputT, runInputT, defaultSettings, getInputLine
  , Settings(..), historyFile, autoAddHistory
  )
import qualified System.Console.Haskeline as H

import Sol.Eval   (evalProg, evalStmt, evalExpr, initialEnv)
import Sol.Parser (parseProgram)
import Sol.Syntax (Stmt(..))
import Sol.Value  (Env, SolVal(..), showVal)

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- | Run a Sol source file
runFile :: FilePath -> IO ()
runFile path = readFile path >>= runCode

-- | Run a Sol program given as a string
runCode :: String -> IO ()
runCode src =
  case parseProgram src of
    Left  err    -> hPutStrLn stderr (show err)
    Right stmts  -> do
      result <- try (evalProg initialEnv stmts) :: IO (Either SomeException Env)
      case result of
        Left  e -> hPutStrLn stderr ("[sol error] " ++ show e)
        Right _ -> return ()

-- ---------------------------------------------------------------------------
-- REPL
-- ---------------------------------------------------------------------------

-- | Interactive REPL with readline history via Haskeline
runRepl :: IO ()
runRepl = do
  putStrLn "Sol REPL  (type 'exit.' or Ctrl-D to quit)"
  let settings = defaultSettings
        { historyFile    = Just "~/.sol_history"
        , autoAddHistory = True
        }
  runInputT settings (loop initialEnv)

loop :: Env -> InputT IO ()
loop env = do
  minput <- getInputLine "sol> "
  case minput of
    Nothing    -> return ()
    Just input ->
      let line = trimStr input
      in if null line || head line == '#'
         then loop env
         else if line `elem` ["exit", "exit.", ":quit", ":q"]
              then return ()
              else do
                env' <- replEval env (ensureDot line)
                loop env'

-- | Append '.' if the user did not type it
ensureDot :: String -> String
ensureDot s
  | null s        = s
  | last s == '.' = s
  | otherwise     = s ++ "."

-- | Evaluate one REPL line; print result if non-null; return updated env
replEval :: Env -> String -> InputT IO Env
replEval env src =
  case parseProgram src of
    Left err -> do
      liftIO $ hPutStrLn stderr ("parse error: " ++ show err)
      return env
    Right stmts -> do
      result <- liftIO $ try (stepStmts env stmts)
                  :: InputT IO (Either SomeException (Env, Maybe SolVal))
      case result of
        Left  e          -> liftIO (hPutStrLn stderr ("[error] " ++ cleanError (show e))) >> return env
        Right (env', mv) -> do
          case mv of
            Just v | v /= SNull -> liftIO (putStrLn (showVal v))
            _                   -> return ()
          return env'

-- | Evaluate a list of statements; return final env + last expression value
stepStmts :: Env -> [Stmt] -> IO (Env, Maybe SolVal)
stepStmts env [] = return (env, Nothing)
stepStmts env stmts = do
  let initStmts = init stmts
      lastStmt  = last stmts
  env1 <- evalProg env initStmts
  case lastStmt of
    -- For bare expressions, evaluate once (side effects happen here),
    -- capture the result, and leave the env unchanged.
    SExpr expr -> do
      v <- evalExpr env1 expr
      return (env1, Just v)
    -- For assignments, update env and show nothing.
    _ -> do
      env2 <- evalStmt env1 lastStmt
      return (env2, Nothing)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

trimStr :: String -> String
trimStr = reverse . dropWhile (== ' ') . reverse . dropWhile (== ' ')

cleanError :: String -> String
cleanError s
  | "user error ([sol] " `isPrefixOf` s = reverse . drop 1 . reverse . drop 18 $ s
  | "user error (" `isPrefixOf` s       = reverse . drop 1 . reverse . drop 12 $ s
  | otherwise                            = s
