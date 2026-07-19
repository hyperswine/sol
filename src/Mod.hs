{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- Mod.hs — the file module system.
--
-- Every .sol file IS a module, addressed by content:
--
--     mymod = use "mymod#4f2a...".
--
-- The hash is the hash of the AST the file parses to — whitespace and
-- comments don't change a module's identity, code does. This is the
-- content-addressed `name#hash` module discipline in miniature: a pinned
-- hash can never silently resolve to different code. `use "mymod"`
-- (unpinned) resolves, prints the hash so you can pin it, and proceeds.
--
-- `run mod x` executes the module in a SEPARATE PROCESS (a fresh `sol`
-- invocation on the resolved file), writes `str x` to its stdin, and
-- captures its stdout as a String. The child is its own transaction: its
-- file commits are atomic and independent — a sub-transaction that commits
-- on child exit, before the parent's own commit. The hash is re-verified
-- at run time, so the code that runs is exactly the code that was pinned.

module Mod where

import Data.Bits (xor)
import Data.Char (ord)
import Data.List (foldl', isSuffixOf)
import Data.Word (Word64)
import Lang (STop, program)
import Numeric (showHex)
import System.Directory (doesFileExist)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readCreateProcessWithExitCode, proc)
import Text.Megaparsec (errorBundlePretty, parse)

-- FNV-1a 64 over the printed AST: deterministic, dependency-free.
-- (A real registry would use SHA-256 over a canonical serialization.)
hashAST :: [STop] -> String
hashAST tops = pad (showHex h "")
  where
    h = foldl' step 0xcbf29ce484222325 (show tops) :: Word64
    step acc c = (acc `xor` fromIntegral (ord c)) * 0x100000001b3
    pad s = replicate (16 - length s) '0' ++ s

parseModuleFile :: FilePath -> IO (Either String (FilePath, String))
parseModuleFile path = do
  ok <- doesFileExist path
  if not ok
    then pure (Left ("use: no such module file: " ++ path))
    else do
      src <- readFile path
      case parse program path src of
        Left e -> pure (Left ("use: module " ++ path ++ " does not parse:\n" ++ errorBundlePretty e))
        Right tops -> pure (Right (path, hashAST tops))

-- "name", "name#hash", "dir/name#hash", "name.sol#hash" — resolved
-- relative to the importing script's directory
resolveModule :: FilePath -> String -> IO (Either String (FilePath, String, Bool))
resolveModule baseDir spec = do
  let (name, hashPart) = break (== '#') spec
      wantHash = drop 1 hashPart
      pinned = not (null wantHash)
      file = if ".sol" `isSuffixOf` name then name else name ++ ".sol"
      path = if take 1 file == "/" then file else baseDir </> file
  r <- parseModuleFile path
  pure $ case r of
    Left e -> Left e
    Right (p, h)
      | pinned && h /= wantHash ->
          Left
            ( "use: hash mismatch for " ++ name
                ++ ":\n  pinned  #" ++ wantHash
                ++ "\n  on disk #" ++ h
                ++ "\n(the module's AST changed since it was pinned)"
            )
      | otherwise -> Right (p, h, pinned)

-- spawn `sol <path>` with `str x` on stdin; capture stdout. Hash
-- re-verified so a pinned module can never run drifted code.
runModule :: FilePath -> String -> String -> IO (Either String String)
runModule path wantHash stdinStr = do
  r <- parseModuleFile path
  case r of
    Left e -> pure (Left e)
    Right (_, h)
      | h /= wantHash ->
          pure (Left ("run: module " ++ path ++ " changed since `use` (was #" ++ wantHash ++ ", now #" ++ h ++ ")"))
      | otherwise -> do
          self <- getExecutablePath
          (code, out, err) <- readCreateProcessWithExitCode (proc self [path]) stdinStr
          pure $ case code of
            ExitSuccess -> Right out
            ExitFailure n ->
              Left ("run: module " ++ path ++ " exited with code " ++ show n ++ (if null err then "" else ":\n" ++ err) ++ (if null out then "" else "\npartial stdout:\n" ++ out))
