{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- Txn.hs — the script-session TRec.
--
-- `sol script.sol` runs the whole script inside one transaction. Every host
-- file the script touches becomes a TVar-like slot:
--
--   * first READ of a path snapshots its content (or its absence) into the
--     read set; later reads are served from the write set, then the read set
--     — the script sees a stable snapshot plus its own writes
--   * WRITES are buffered in the write set; the disk is never touched
--     mid-script
--   * at exit: lock every touched file (sorted order — no deadlock),
--     VALIDATE the read set against the disk, COMMIT the write set,
--     unlock. If validation fails, the whole script re-runs (STM retry).
--
-- Locks are atomic mkdir locks (<path>.sol-lock) so two concurrent `sol`
-- processes exclude each other portably with no daemon.
--
-- Handles: `open` registers a path and returns a handle id; the LINEARITY
-- checker (front-end, compile time) is what guarantees each handle is used
-- exactly once per operation and therefore cannot be leaked or double-closed
-- — the runtime table below just maps ids to paths.

module Txn where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Control.Monad (foldM, forM_, unless, when)
import Data.IORef
import qualified Data.IntMap.Strict as IM
import Data.List (isSuffixOf, sort)
import qualified Data.Map.Strict as M
import System.Directory
  ( createDirectory,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getFileSize,
    getModificationTime,
    listDirectory,
    removeDirectory,
    removeFile,
  )
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import System.Exit (ExitCode (..))
import System.IO (readFile')
import System.IO (hFlush, hIsEOF, hGetLine, stderr, stdin, stdout, hPutStrLn)
import System.Process (createProcess, readCreateProcessWithExitCode, shell, waitForProcess)

-- The transaction's pending effect on the world, IN DECLARATION ORDER.
-- File writes, removals, mkdirs, and QUEUED external commands interleave
-- exactly as the script issued them; commit replays the log.
data Effect
  = EWrite FilePath String
  | ERemove FilePath
  | EMkdir FilePath
  | ERmdir FilePath
  | EShell String
  deriving (Show)

data TxState = TxState
  { txReads :: M.Map FilePath (Maybe String), -- content snapshot at first read
    txDirReads :: M.Map FilePath [String], -- directory listings taken
    txEffects :: [Effect], -- REVERSED effect log
    txView :: M.Map FilePath (Maybe String), -- current in-txn file view
    txDirView :: M.Map FilePath Bool, -- dirs mkdir'd (True) / rmdir'd (False)
    txHandles :: IM.IntMap FilePath, -- open handle id -> path
    txNextH :: !Int
  }

newTx :: IO (IORef TxState)
newTx = newIORef emptyTx

emptyTx :: TxState
emptyTx = TxState M.empty M.empty [] M.empty M.empty IM.empty 1

resetTx :: IORef TxState -> IO ()
resetTx ref = writeIORef ref emptyTx

pushEffect :: IORef TxState -> Effect -> IO ()
pushEffect ref e = atomicModifyIORef' ref (\s -> (s {txEffects = e : txEffects s}, ()))

diskRead :: FilePath -> IO (Maybe String)
diskRead p = do
  r <- try (readFile' p) :: IO (Either IOException String)
  pure (either (const Nothing) Just r)

-- open: register the path, hand back a handle id. Reading is NOT done here;
-- the snapshot happens lazily at first txHRead so a write-only open doesn't
-- inflate the read set (and therefore can't cause a spurious conflict).
txOpen :: IORef TxState -> FilePath -> IO Int
txOpen ref p = atomicModifyIORef' ref $ \s ->
  let h = txNextH s
   in (s {txHandles = IM.insert h p (txHandles s), txNextH = h + 1}, h)

txPathOf :: IORef TxState -> Int -> IO FilePath
txPathOf ref h = do
  s <- readIORef ref
  case IM.lookup h (txHandles s) of
    Just p -> pure p
    Nothing -> ioError (userError ("sol: stale handle " ++ show h ++ " (should be impossible: linearity)"))

txClose :: IORef TxState -> Int -> IO ()
txClose ref h = atomicModifyIORef' ref $ \s ->
  (s {txHandles = IM.delete h (txHandles s)}, ())

-- snapshot a path into the read set (for validation) if not already there
snapshot :: IORef TxState -> FilePath -> IO (Maybe String)
snapshot ref p = do
  s <- readIORef ref
  case M.lookup p (txReads s) of
    Just snap -> pure snap
    Nothing -> do
      d <- diskRead p
      atomicModifyIORef' ref (\st -> (st {txReads = M.insert p d (txReads st)}, ()))
      pure d

-- transactional read: in-txn view > read snapshot > disk (snapshotting)
txHRead :: IORef TxState -> Int -> IO String
txHRead ref h = do
  p <- txPathOf ref h
  s <- readIORef ref
  case M.lookup p (txView s) of
    Just (Just w) -> pure w
    Just Nothing -> pure "" -- removed earlier in this txn
    Nothing -> maybe "" id <$> snapshot ref p

txHWrite :: IORef TxState -> Int -> String -> IO ()
txHWrite ref h v = do
  p <- txPathOf ref h
  pushEffect ref (EWrite p v)
  atomicModifyIORef' ref (\s -> (s {txView = M.insert p (Just v) (txView s)}, ()))

-- ---- path-level transactional ops ----------------------------------------

-- remove: snapshot current state (so a concurrent write aborts us), mark
-- deleted in the view, queue the removal
txRm :: IORef TxState -> FilePath -> IO ()
txRm ref p = do
  _ <- snapshot ref p
  pushEffect ref (ERemove p)
  atomicModifyIORef' ref (\s -> (s {txView = M.insert p Nothing (txView s)}, ()))

txMkdirp :: IORef TxState -> FilePath -> IO ()
txMkdirp ref p = do
  pushEffect ref (EMkdir p)
  atomicModifyIORef' ref (\s -> (s {txDirView = M.insert p True (txDirView s)}, ()))

txRmdir :: IORef TxState -> FilePath -> IO ()
txRmdir ref p = do
  pushEffect ref (ERmdir p)
  atomicModifyIORef' ref (\s -> (s {txDirView = M.insert p False (txDirView s)}, ()))

-- list a directory: disk listing (validated at commit) composed with this
-- txn's own additions and removals in that directory. sol-lock artifacts
-- are invisible.
txLs :: IORef TxState -> FilePath -> IO [String]
txLs ref dir = do
  s <- readIORef ref
  base <- case M.lookup dir (txDirReads s) of
    Just names -> pure names
    Nothing -> do
      r <- try (listDirectory dir) :: IO (Either IOException [String])
      let names = sort (filter (not . (".sol-lock" `isSuffixOf`)) (either (const []) id r))
      atomicModifyIORef' ref (\st -> (st {txDirReads = M.insert dir names (txDirReads st)}, ()))
      pure names
  s2 <- readIORef ref
  let inDir p = takeDir p == dir
      takeDir p = let q = reverse (dropWhile (/= '/') (reverse p)) in if null q then "." else init q
      baseName p = reverse (takeWhile (/= '/') (reverse p))
      added = [baseName p | (p, Just _) <- M.toList (txView s2), inDir p, baseName p `notElem` base]
      removed = [baseName p | (p, Nothing) <- M.toList (txView s2), inDir p]
      addedDirs = [baseName p | (p, True) <- M.toList (txDirView s2), inDir p, baseName p `notElem` base]
  pure (sort ((base ++ added ++ addedDirs) `without` removed))
  where
    without xs ys = [x | x <- xs, x `notElem` ys]

txExists :: IORef TxState -> FilePath -> IO Bool
txExists ref p = do
  s <- readIORef ref
  case M.lookup p (txView s) of
    Just (Just _) -> pure True
    Just Nothing -> pure False
    Nothing -> case M.lookup p (txDirView s) of
      Just b -> pure b
      Nothing -> do
        snap <- snapshot ref p
        case snap of
          Just _ -> pure True
          Nothing -> doesDirectoryExist p -- dirs have no content snapshot

txIsDir :: IORef TxState -> FilePath -> IO Bool
txIsDir ref p = do
  s <- readIORef ref
  case M.lookup p (txDirView s) of
    Just b -> pure b
    Nothing -> doesDirectoryExist p

-- (exists, size, mtime-seconds); content snapshotted for validation
txStat :: IORef TxState -> FilePath -> IO (Bool, Integer, Integer)
txStat ref p = do
  snap <- snapshot ref p
  case snap of
    Nothing -> pure (False, 0, 0)
    Just _ -> do
      sz <- getFileSize p
      mt <- getModificationTime p
      pure (True, sz, floor (utcTimeToPOSIXSeconds mt))

-- ---- external commands -----------------------------------------------------

-- immediate: for READ-ONLY commands (git status, docker ps). The read-only
-- claim is the caller's assertion — it cannot be enforced, and its output
-- cannot be validated at commit. Reruns on retry.
txSh :: String -> IO (Int, String)
txSh cmd = do
  (code, out, err) <- readCreateProcessWithExitCode (shell cmd) ""
  let c = case code of ExitSuccess -> 0; ExitFailure n -> n
  pure (c, out ++ err)

-- queued: for MUTATING commands (git commit, docker rm). Runs at COMMIT,
-- after validation, interleaved in declaration order with file effects.
-- On retry the queue is discarded: the world was never touched.
txShq :: IORef TxState -> String -> IO ()
txShq ref cmd = pushEffect ref (EShell cmd)

-- ---- REALTIME ESCAPES (outside the transaction) ---------------------------
--
-- Everything above this line is transactional: reads snapshot, writes buffer,
-- and a validation failure re-runs the script with the world untouched. That
-- is the default and it is what you want almost always.
--
-- These are the deliberate holes in it. They exist because three things are
-- genuinely impossible inside a transaction:
--
--   * OBSERVING CHANGE. A transactional read is idempotent by construction —
--     the second `read p` returns the first read's snapshot. A poll/watch/tail
--     loop can therefore never see a file change. rtRead re-reads the disk.
--   * STREAMING OUTPUT. `sh` captures a command's output and hands it back
--     when the command is done, so a four-minute build shows nothing until
--     it finishes. rtShell inherits stdio so the output arrives live.
--   * PROMPTING. `input` slurps all of stdin at once; a prompt loop needs a
--     line at a time, now.
--
-- What you give up, in every case: the operation happens even if the
-- transaction later rolls back, it happens AGAIN on every retry, and its
-- result is not validated at commit. The counter below exists so a run that
-- uses these says so out loud.

-- per-kind use counts, for the warning summary; survives retries
type RtCounts = IORef (M.Map String Int)

newRtCounts :: IO RtCounts
newRtCounts = newIORef M.empty

-- bump, and on FIRST use of a kind explain what was given up
noteEscape :: RtCounts -> String -> String -> IO ()
noteEscape ref kind why = do
  m <- readIORef ref
  when (not (M.member kind m)) $
    hPutStrLn stderr ("[sol] REALTIME: " ++ kind ++ " — " ++ why)
  atomicModifyIORef' ref (\mm -> (M.insertWith (+) kind 1 mm, ()))

rtTotal :: RtCounts -> IO Int
rtTotal ref = sum . M.elems <$> readIORef ref

rtReport :: RtCounts -> IO [String]
rtReport ref = do
  m <- readIORef ref
  pure [k ++ " x" ++ show n | (k, n) <- M.toList m]

-- A realtime write steps outside the transaction for that path, so the
-- transaction must stop making claims about it: drop any snapshot we took.
-- Without this, `s = readPath p; u = appendNow p line` would invalidate its
-- own read set and retry forever. Returns True if a claim was actually
-- dropped, so the caller can say so.
txForget :: IORef TxState -> FilePath -> IO Bool
txForget ref p = atomicModifyIORef' ref $ \s ->
  ( s { txReads = M.delete p (txReads s), txView = M.delete p (txView s) },
    M.member p (txReads s) || M.member p (txView s)
  )

-- read the disk NOW, with no snapshot: repeated calls can differ
rtRead :: FilePath -> IO (Maybe String)
rtRead = diskRead

rtWrite :: IORef TxState -> FilePath -> String -> IO Bool
rtWrite ref p v = do
  dropped <- txForget ref p
  writeFile p v
  pure dropped

rtAppend :: IORef TxState -> FilePath -> String -> IO Bool
rtAppend ref p v = do
  dropped <- txForget ref p
  appendFile p v
  pure dropped

-- inherit stdio so output streams to the terminal as it is produced;
-- only the exit code comes back
rtShell :: String -> IO Int
rtShell cmd = do
  hFlush stdout
  (_, _, _, ph) <- createProcess (shell cmd)
  code <- waitForProcess ph
  pure (case code of ExitSuccess -> 0; ExitFailure n -> n)

-- one line from stdin, now; "" at end of input
rtLine :: IO String
rtLine = do
  hFlush stdout
  eof <- hIsEOF stdin
  if eof then pure "" else hGetLine stdin

-- ---- commit protocol ------------------------------------------------------

lockPath :: FilePath -> FilePath
lockPath p = p ++ ".sol-lock"

acquire :: FilePath -> IO ()
acquire p = go (0 :: Int)
  where
    parent = reverse (dropWhile (/= '/') (reverse p))
    go n = do
      -- the lock lives beside the target; its parent dir may itself be a
      -- pending mkdir in this very txn, so ensure it exists before locking
      unless (null parent) (createDirectoryIfMissing True parent)
      r <- try (createDirectory (lockPath p)) :: IO (Either IOException ())
      case r of
        Right () -> pure ()
        Left _
          | n > 5000 -> ioError (userError ("sol: could not lock " ++ p ++ " (stale " ++ lockPath p ++ "?)"))
          | otherwise -> threadDelay 1000 >> go (n + 1)

release :: FilePath -> IO ()
release p = do
  _ <- try (removeDirectory (lockPath p)) :: IO (Either IOException ())
  pure ()

data CommitResult = Committed Int | Conflict [FilePath]

effectPath :: Effect -> Maybe FilePath
effectPath (EWrite p _) = Just p
effectPath (ERemove p) = Just p
effectPath (EMkdir p) = Just p
effectPath (ERmdir p) = Just p
effectPath (EShell _) = Nothing

-- lock (sorted) -> validate reads AND dir listings -> replay the effect
-- log in order -> unlock. Deferred shell commands run inside the commit,
-- after validation: if the txn retried they never happened. Once released
-- they CANNOT be rolled back — a failing deferred command stops the replay
-- and reports what did not run.
commit :: IORef TxState -> IO CommitResult
commit ref = do
  s <- readIORef ref
  let effs = reverse (txEffects s)
      touched =
        M.keys
          ( M.unions
              [ M.map (const ()) (txReads s),
                M.map (const ()) (txDirReads s),
                M.fromList [(p, ()) | e <- effs, Just p <- [effectPath e]]
              ]
          )
  forM_ touched acquire -- sorted: global lock order
  staleC <-
    foldM
      ( \acc (p, snap) -> do
          now <- diskRead p
          pure (if now == snap then acc else p : acc)
      )
      []
      (M.toList (txReads s))
  staleD <-
    foldM
      ( \acc (dir, names) -> do
          r <- try (listDirectory dir) :: IO (Either IOException [String])
          let now = sort (filter (not . (".sol-lock" `isSuffixOf`)) (either (const []) id r))
          pure (if now == names then acc else dir : acc)
      )
      []
      (M.toList (txDirReads s))
  let stale = staleC ++ staleD
  res <-
    if null stale
      then Committed <$> replay effs 0
      else pure (Conflict stale)
  forM_ (reverse touched) release
  pure res
  where
    replay [] n = pure n
    replay (e : rest) n = case e of
      EWrite p v -> writeFile p v >> replay rest (n + 1)
      ERemove p -> do
        _ <- try (removeFile p) :: IO (Either IOException ())
        replay rest (n + 1)
      EMkdir p -> createDirectoryIfMissing True p >> replay rest (n + 1)
      ERmdir p -> do
        _ <- try (removeDirectory p) :: IO (Either IOException ())
        replay rest (n + 1)
      EShell cmd -> do
        (code, out) <- txSh cmd
        unless (null out) (putStr ("[sol] $ " ++ cmd ++ "\n" ++ out))
        if code == 0
          then replay rest (n + 1)
          else do
            putStrLn ("[sol] deferred command FAILED (exit " ++ show code ++ "): " ++ cmd)
            putStrLn ("[sol] " ++ show (length rest) ++ " queued effect(s) after it did NOT run")
            pure (n + 1)
