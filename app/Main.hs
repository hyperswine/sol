module Main (main) where

import System.Environment (getArgs)
import System.IO (hPutStrLn, stderr)

import Lib (runFile, runRepl, runCode)

main :: IO ()
main = do
  args <- getArgs
  case args of
    []          -> runRepl
    ["-"]       -> getContents >>= runCode
    [path]      -> runFile path
    ("-e":code) -> runCode (unwords code)
    _           -> hPutStrLn stderr usage
  where
    usage = "Usage: sol [script.sol | - | -e 'code']"
