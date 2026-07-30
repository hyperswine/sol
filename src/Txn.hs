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
import Data.Maybe (mapMaybe)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import Text.Read (readMaybe)
import qualified Data.IntMap.Strict as IM
import Data.List (isInfixOf, isSuffixOf, nub, sort)
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
    removePathForcibly,
    renamePath,
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
  deriving (Show, Read)

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
      let names = sort (filter (not . lockArtifact) (either (const []) id r))
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
--
-- CRASH-ATOMIC edition. The previous protocol was atomic against script
-- errors and concurrent sol processes, but a crash (kill -9, OOM, power
-- loss) DURING commit could tear it three ways: a half-written file, a
-- half-applied effect log, and stranded .sol-lock dirs that hard-fail
-- every later run. Three mechanisms close those, in order:
--
--   1. writeAtomic: every committed file lands under a temp name, is
--      fsynced, and is renamed over the target. rename(2) is atomic on
--      POSIX, so an individual file is always entirely-old or
--      entirely-new — never torn.
--   2. the REDO JOURNAL: after validation and before any disk mutation,
--      the whole effect log is serialized to <script>.soljournal and
--      fsynced (itself via writeAtomic, so the journal is complete or
--      absent). A crash mid-replay leaves the journal as the authority:
--      the next run (of this script, or any sol that reclaims one of the
--      dead process's locks) REDOES it. File effects are idempotent
--      (absolute content, rename-applied), so redo is safe to repeat.
--      Deferred shell commands are not idempotent; each one that runs is
--      marked in <journal>.done (append + fsync) and redo skips marked
--      ones. The crash window between a command finishing and its marker
--      landing means shell redo is AT-LEAST-ONCE — stated here rather
--      than hidden, and narrower than the every-crash re-run it replaces.
--   3. PID-stamped locks: a lock dir carries an owner file (pid +
--      journal path). acquire probes a contended lock's owner with
--      kill(pid, 0); a dead owner's lock is reclaimed by atomically
--      RENAMING the lock dir (one reclaimer wins the rename, losers keep
--      spinning), finishing the dead owner's journal first if one exists.
--      No daemon, no manual cleanup, and a crashed sol no longer wedges
--      every future run on those paths.
--
-- Honest limits, so nobody reads more than is there: fsync is
-- best-effort (some filesystems lie; we do not detect that); concurrent
-- reclaimers can both redo the same journal (file effects idempotent,
-- shell effects at-least-once as above); and a redo that races a live
-- writer on an UNLOCKED path is possible only if that writer ignores
-- locks — sol processes never do.

foreign import ccall unsafe "sol_fsync_path" c_fsyncPath :: CString -> IO CInt
foreign import ccall unsafe "sol_pid_alive" c_pidAlive :: CInt -> IO CInt
foreign import ccall unsafe "sol_getpid" c_getpid :: IO CInt
foreign import ccall unsafe "sol_hard_exit" c_hardExit :: CInt -> IO ()

-- SOL_NOSYNC=1 skips every fsync: writes stay rename-atomic (no torn
-- files, and the journal still heals a killed process), but a POWER LOSS
-- can lose "committed" data. For bulk jobs on a filesystem you trust,
-- the fsync tax (~2 syncs per committed file) is the dominant cost.
{-# NOINLINE noSync #-}
noSync :: Bool
noSync = unsafePerformIO (maybe False (/= "0") <$> lookupEnv "SOL_NOSYNC")

fsyncPath :: FilePath -> IO ()
fsyncPath p = unless noSync (withCString p (fmap (const ()) . c_fsyncPath))

parentOf :: FilePath -> FilePath
parentOf p = case reverse (dropWhile (/= '/') (reverse p)) of
  "" -> "."
  q -> q

-- entirely-old or entirely-new, never torn; durable once we return
writeAtomic :: FilePath -> String -> IO ()
writeAtomic p v = do
  let tmp = p ++ ".sol-tmp"
  writeFile tmp v
  fsyncPath tmp
  renamePath tmp p
  fsyncPath (parentOf p)

-- ---- locks ----------------------------------------------------------------

lockPath :: FilePath -> FilePath
lockPath p = p ++ ".sol-lock"

ownerPath :: FilePath -> FilePath
ownerPath p = lockPath p ++ "/owner"

-- jpath: this process's journal path, recorded in the owner file so a
-- reclaimer can finish our commit if we die holding the lock.
acquire :: FilePath -> FilePath -> IO ()
acquire = acquireGo True

-- the recovery path uses acquireGo False: it must not recurse into
-- journal recovery while already performing it
acquireGo :: Bool -> FilePath -> FilePath -> IO ()
acquireGo recover jpath p = go (0 :: Int)
  where
    parent = parentOf p
    go n = do
      -- the lock lives beside the target; its parent dir may itself be a
      -- pending mkdir in this very txn, so ensure it exists before locking
      unless (parent == ".") (createDirectoryIfMissing True parent)
      r <- try (createDirectory (lockPath p)) :: IO (Either IOException ())
      case r of
        Right () -> do
          me <- c_getpid
          writeFile (ownerPath p) (show (fromIntegral me :: Int) ++ "\n" ++ jpath ++ "\n")
        Left _
          | n > 5000 -> ioError (userError ("sol: could not lock " ++ p ++ " (live " ++ lockPath p ++ ")"))
          | otherwise -> do
              when (n `mod` 250 == 249) (tryReclaim recover p)
              threadDelay 1000 >> go (n + 1)

-- a contended lock whose recorded owner is dead is stale. Exactly one
-- reclaimer wins the atomic rename of the lock dir; it finishes the dead
-- owner's journal (if any) and removes the claimed dir. Losers, and any
-- lock with a live/unreadable owner, keep waiting.
tryReclaim :: Bool -> FilePath -> IO ()
tryReclaim recover p = do
  own <- try (readFile' (ownerPath p)) :: IO (Either IOException String)
  case own of
    Left _ -> pure () -- no owner file (mid-create, or pre-upgrade lock): wait
    Right txt -> case lines txt of
      (pidL : jL : _) | Just pid <- readMaybe pidL -> do
        alive <- c_pidAlive (fromIntegral (pid :: Int))
        when (alive == 0) $ do
          me <- c_getpid
          let claim = lockPath p ++ ".reclaim." ++ show (fromIntegral me :: Int)
          won <- try (renamePath (lockPath p) claim) :: IO (Either IOException ())
          case won of
            Left _ -> pure () -- someone else got it
            Right () -> do
              hPutStrLn stderr ("[sol] reclaimed stale lock on " ++ p ++ " (owner pid " ++ show pid ++ " is dead)")
              when recover (recoverJournal False jL)
              removePathForcibly claim
      _ -> pure ()

release :: FilePath -> IO ()
release p = do
  _ <- try (removePathForcibly (lockPath p)) :: IO (Either IOException ())
  pure ()

-- ---- the redo journal -----------------------------------------------------

donePath :: FilePath -> FilePath
donePath j = j ++ ".done"

-- complete-or-absent by construction: writeAtomic, plus a trailing COMMIT
-- line so a torn pre-rename tmp can never be mistaken for a journal
writeJournal :: FilePath -> [Effect] -> IO ()
writeJournal j effs = writeAtomic j (unlines ["SOLJ1", show effs, "COMMIT"])

parseJournal :: String -> Maybe [Effect]
parseJournal txt = case lines txt of
  ("SOLJ1" : effsL : "COMMIT" : _) -> case reads effsL of
    [(es, rest)] | all (`elem` " \t") rest -> Just es
    _ -> Nothing
  _ -> Nothing

readDone :: FilePath -> IO [Int]
readDone j = do
  r <- try (readFile' (donePath j)) :: IO (Either IOException String)
  pure (either (const []) (mapMaybe readMaybe . lines) r)

markDone :: FilePath -> Int -> IO ()
markDone j i = do
  appendFile (donePath j) (show i ++ "\n")
  fsyncPath (donePath j)

clearJournal :: FilePath -> IO ()
clearJournal j = do
  removePathForcibly j
  removePathForcibly (donePath j)
  fsyncPath (parentOf j)

-- redo an interrupted commit. takeLocks=True is the startup path (locks
-- must be taken around the redo); False is the reclaim path (the dead
-- owner's remaining lock dirs still fence other sol processes off the
-- touched paths, and we are already inside lock acquisition).
recoverJournal :: Bool -> FilePath -> IO ()
recoverJournal takeLocks j = do
  ex <- doesFileExist j
  when ex $ do
    txt <- readFile' j
    case parseJournal txt of
      Nothing -> do
        hPutStrLn stderr ("[sol] discarding incomplete journal " ++ j ++ " (crash before the commit point; the transaction never took effect)")
        clearJournal j
      Just effs -> do
        let touched = sort (nub [p | e <- effs, Just p <- [effectPath e]])
        when takeLocks (forM_ touched (acquireGo False j))
        stillThere <- doesFileExist j -- a concurrent reclaimer may have finished it
        when stillThere $ do
          done <- readDone j
          hPutStrLn stderr ("[sol] recovering interrupted commit from " ++ j ++ " (" ++ show (length effs) ++ " effect(s), " ++ show (length done) ++ " shell(s) already done)")
          _ <- replayEffs j True done Nothing (zip [0 ..] effs)
          clearJournal j
        when takeLocks (forM_ (reverse touched) release)

-- ---- commit ---------------------------------------------------------------

data CommitResult = Committed Int | Conflict [FilePath]

effectPath :: Effect -> Maybe FilePath
effectPath (EWrite p _) = Just p
effectPath (ERemove p) = Just p
effectPath (EMkdir p) = Just p
effectPath (ERmdir p) = Just p
effectPath (EShell _) = Nothing

-- lock (sorted) -> validate reads AND dir listings -> journal the effect
-- log (fsynced; the commit point) -> replay it in order -> clear the
-- journal -> unlock. Deferred shell commands run inside the commit, after
-- validation: if the txn retried they never happened. Once released they
-- CANNOT be rolled back — a failing deferred command stops the replay and
-- reports what did not run.
commit :: IORef TxState -> FilePath -> IO CommitResult
commit ref jpath = do
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
  forM_ touched (acquire jpath) -- sorted: global lock order
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
          let now = sort (filter (not . lockArtifact) (either (const []) id r))
          pure (if now == names then acc else dir : acc)
      )
      []
      (M.toList (txDirReads s))
  let stale = staleC ++ staleD
  res <-
    if null stale
      then do
        crashAt <- (>>= readMaybe) <$> lookupEnv "SOL_CRASH_AT"
        when (not (null effs)) (writeJournal jpath effs)
        n <- replayEffs jpath False [] crashAt (zip [0 ..] effs)
        clearJournal jpath
        pure (Committed n)
      else pure (Conflict stale)
  forM_ (reverse touched) release
  pure res

-- .sol-lock dirs, reclaim renames, and .sol-tmp staging files are
-- commit-protocol artifacts: invisible to validation and to txLs
lockArtifact :: FilePath -> Bool
lockArtifact n =
  ".sol-lock" `isSuffixOf` n
    || ".sol-tmp" `isSuffixOf` n
    || ".sol-lock.reclaim." `isInfixOf` n

-- replay the (indexed) effect log. recovery=True is the redo path: file
-- effects re-apply idempotently, shell effects in `done` are skipped and
-- the rest re-run (loudly — this is the at-least-once window). crashAt
-- is the SOL_CRASH_AT hook: die like kill -9 just before applying that
-- effect index, so the crash windows are deterministically testable.
replayEffs :: FilePath -> Bool -> [Int] -> Maybe Int -> [(Int, Effect)] -> IO Int
replayEffs _ _ _ _ [] = pure 0
replayEffs j recovery done crashAt ((i, e) : rest) = do
  case crashAt of
    Just k | k == i -> do
      hPutStrLn stderr ("[sol] SOL_CRASH_AT=" ++ show k ++ ": hard exit before effect " ++ show k)
      hFlush stderr
      c_hardExit 137
    _ -> pure ()
  case e of
    EWrite p v -> writeAtomic p v >> rec'
    ERemove p -> do
      _ <- try (removeFile p) :: IO (Either IOException ())
      rec'
    EMkdir p -> createDirectoryIfMissing True p >> rec'
    ERmdir p -> do
      _ <- try (removeDirectory p) :: IO (Either IOException ())
      rec'
    EShell cmd
      | recovery && i `elem` done -> do
          hPutStrLn stderr ("[sol] redo: skipping already-run command: " ++ cmd)
          rec'
      | otherwise -> do
          when recovery $ hPutStrLn stderr ("[sol] redo: re-running deferred command (at-least-once): " ++ cmd)
          (code, out) <- txSh cmd
          markDone j i
          unless (null out) (putStr ("[sol] $ " ++ cmd ++ "\n" ++ out))
          if code == 0
            then rec'
            else do
              putStrLn ("[sol] deferred command FAILED (exit " ++ show code ++ "): " ++ cmd)
              putStrLn ("[sol] " ++ show (length rest) ++ " queued effect(s) after it did NOT run")
              pure 1
  where
    rec' = (1 +) <$> replayEffs j recovery done crashAt rest
