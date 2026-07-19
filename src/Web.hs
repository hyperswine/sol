{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}

-- IDEALLY THIS WOULD BE COMPLETELY a LIB IN PURE SOL

-- Web.hs — gen_view v2: MVU with event-sourced persistence, Cmds, and subs.
--
--   > View.serve 8080 init update view subs.
--
--   init   : token -> model
--   update : msg -> model -> (model, Cmd)    msg = (eventName, valueString)
--   view   : model -> node
--   subs   : [(intervalMs, eventName)]       timer msgs, server-pushed
--
-- PERSISTENCE is event sourcing over the Msg stream. Model fields wrapped
-- `Persistent x` are the durable part. After every update the runner
-- compares the persistent projection of the model before/after; if it
-- changed, the MSG (not the model) is appended to <script>.soldata as a
-- JSON line {"tok","ev","val"} and flushed — kill-safe. On startup the log
-- replays: each session's model is rebuilt by folding update over its
-- msgs (Cmds are NOT re-executed during replay — but their RESULT msgs
-- were logged if they mattered, which is how nondeterminism like Rng
-- replays deterministically: the value is in the log, not the request).
-- Msgs that never touched a Persistent field were never logged: that
-- runtime state is abandoned on restart, by design.
--
-- CMDS are data returned by update, interpreted by the runner:
--   None | Print s | ReadFile path evName | Rng lo hi evName | Batch cmds
-- ReadFile/Rng feed their results back in as ordinary msgs (evName, value),
-- which re-enter update — the MVU circle. Depth-capped to stop cmd loops.
--
-- SUBS are timers: every interval, each CONNECTED session receives the msg
-- and its changed dyn slots are pushed over the socket — server-initiated
-- updates with no client event.

module Web where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (IOException, SomeException, try)
import Control.Monad (forM_, forever, unless, when)
import Data.Bits (complement, rotateL, shiftL, shiftR, xor, (.&.), (.|.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Char (chr, ord)
import Data.IORef
import Data.List (foldl', isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as M
import Data.Time.Clock (getCurrentTime, utctDayTime)
import Data.Word (Word32, Word64, Word8)
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)
import System.Directory (doesFileExist)
import System.IO (BufferMode (LineBuffering), Handle, IOMode (AppendMode), hFlush, hPutStrLn, hSetBuffering, openFile, readFile', stdout)
import Val

type Shapes = M.Map Int [String]

type Cons = M.Map String (Int, Int) -- constructor name -> (tid, variant)

data Callbacks = Callbacks
  { cbInit :: Value -> IO Value,
    cbUpdate :: Value -> Value -> IO Value, -- returns (model, Cmd)
    cbView :: Value -> IO Value
  }

data Rt = Rt
  { rtShapes :: Shapes,
    rtCons :: Cons,
    rtCbs :: Callbacks,
    rtSessions :: IORef (M.Map String (Value, M.Map String String)),
    rtConns :: IORef (M.Map String (String -> IO ())), -- token -> ws sender
    rtSolLock :: MVar (), -- serialize Sol callbacks: single-hart
    rtLog :: MVar Handle, -- the .soldata append handle
    rtRng :: IORef Word64,
    rtPersistT :: Int, -- tid of the Persistent wrapper
    rtKV :: IORef (M.Map String String), -- shared cross-session store
    rtKVLog :: MVar Handle -- the .solkv append handle
  }

serveWeb :: Int -> FilePath -> Shapes -> Cons -> [(Int, String)] -> Callbacks -> IO Value
serveWeb port dataFile shapes cons subs cbs = do
  hSetBuffering stdout LineBuffering
  sessions <- newIORef M.empty
  conns <- newIORef M.empty
  solLock <- newMVar ()
  seed <- utcSeed
  rng <- newIORef seed
  let persistT = maybe (-1) fst (M.lookup "Persistent" cons)
  -- replay the msg log before opening the socket
  haveLog <- doesFileExist dataFile
  when haveLog $ do
    txt <- readFile' dataFile
    let msgs = [(tok, ev, val) | ln <- lines txt, not (null ln), let kv = parseFlat ln, Just tok <- [lookup "tok" kv], Just ev <- [lookup "ev" kv], let val = maybe "" id (lookup "val" kv)]
    forM_ msgs $ \(tok, ev, val) -> do
      known <- readIORef sessions
      model <- case M.lookup tok known of
        Just (m, _) -> pure m
        Nothing -> cbInit cbs (VStr tok)
      r <- cbUpdate cbs (mkMsg ev val) model
      let (model', _cmd) = splitUpd r -- cmds are NOT re-executed on replay
      modifyIORef' sessions (M.insert tok (model', M.empty))
    n <- M.size <$> readIORef sessions
    putStrLn ("[view] replayed " ++ show (length msgs) ++ " msg(s) -> " ++ show n ++ " session(s) from " ++ dataFile)
  logH <- openFile dataFile AppendMode >>= newMVar
  -- the shared KV store: cross-session state (user accounts, app data),
  -- persisted to its own append log, last write per key wins on load
  let kvFile = take (length dataFile - 8) dataFile ++ ".solkv"
  haveKV <- doesFileExist kvFile
  kv0 <-
    if haveKV
      then do
        txt <- readFile' kvFile
        pure (M.fromList [(k, v) | ln <- lines txt, not (null ln), let p = parseFlat ln, Just k <- [lookup "k" p], Just v <- [lookup "v" p]])
      else pure M.empty
  when haveKV (putStrLn ("[view] loaded " ++ show (M.size kv0) ++ " key(s) from " ++ kvFile))
  kvRef <- newIORef kv0
  kvH <- openFile kvFile AppendMode >>= newMVar
  let rt = Rt shapes cons cbs sessions conns solLock logH rng persistT kvRef kvH
  -- subscriptions: timers that inject msgs into every CONNECTED session
  forM_ subs $ \(ms, ev) -> forkIO $ forever $ do
    threadDelay (ms * 1000)
    toks <- M.keys <$> readIORef conns
    forM_ toks $ \tok -> processMsg rt 4 tok (ev, "")
  addr : _ <- getAddrInfo (Just defaultHints {addrFlags = [AI_PASSIVE], addrSocketType = Stream}) Nothing (Just (show port))
  sock <- socket (addrFamily addr) Stream defaultProtocol
  setSocketOption sock ReuseAddr 1
  bind sock (addrAddress addr)
  listen sock 16
  putStrLn ("[view] serving MVU app on http://localhost:" ++ show port ++ " (log: " ++ dataFile ++ (if null subs then "" else ", " ++ show (length subs) ++ " sub(s)") ++ ")")
  forever $ do
    (conn, _) <- accept sock
    _ <- forkIO $ do
      r <- try (handleConn rt conn) :: IO (Either SomeException ())
      case r of
        Left e -> putStrLn ("[view] connection error: " ++ show e)
        Right () -> pure ()
      close conn
    pure ()
  pure vUnit

mkMsg :: String -> String -> Value
mkMsg ev val = VData 4 0 [VStr ev, VStr val]

-- update's result: (model, Cmd); tolerate a bare model for forgiveness
splitUpd :: Value -> (Value, Value)
splitUpd (VData 4 0 [m, c]) = (m, c)
splitUpd m = (m, vUnit)

utcSeed :: IO Word64
utcSeed = do
  t <- getCurrentTime
  pure (fromIntegral (round (utctDayTime t * 1e6) :: Integer) .|. 1)

-- ---- the MVU pump: every msg from every source flows through here ----------

-- the persistent projection: JSON of each Persistent-wrapped subtree, in
-- deterministic walk order. Msg logging is keyed on this changing.
collectP :: Rt -> Value -> [String]
collectP rt = go
  where
    go v@(VData t 0 [inner]) | t == rtPersistT rt = jsonVC (rtShapes rt) (conIndex (rtCons rt)) inner : go inner
    go (VData _ _ fs) = concatMap go fs
    go _ = []

processMsg :: Rt -> Int -> String -> (String, String) -> IO ()
processMsg _ 0 _ _ = putStrLn "[view] cmd depth cap hit; dropping"
processMsg rt depth tok (ev, val) = do
  known <- readIORef (rtSessions rt)
  case M.lookup tok known of
    Nothing -> pure ()
    Just (model, lastDyn) -> do
      (model', cmdV, dyn') <- withMVar (rtSolLock rt) $ \_ -> do
        r <- cbUpdate (rtCbs rt) (mkMsg ev val) model
        let (m', c) = splitUpd r
        v' <- cbView (rtCbs rt) m'
        pure (m', c, collectDyn (rtShapes rt) (conIndex (rtCons rt)) v')
      -- event sourcing: log the msg iff it moved the persistent projection
      when (collectP rt model /= collectP rt model') $
        withMVar (rtLog rt) $ \h -> do
          hPutStrLn h ("{\"tok\":" ++ jstr tok ++ ",\"ev\":" ++ jstr ev ++ ",\"val\":" ++ jstr val ++ "}")
          hFlush h
      atomicModifyIORef' (rtSessions rt) (\m -> (M.insert tok (model', dyn') m, ()))
      -- push changed dyn slots if this session has a live socket
      let patch = M.toList (M.differenceWith (\new old -> if new == old then Nothing else Just new) dyn' lastDyn) ++ M.toList (M.difference dyn' lastDyn)
      unless (null patch) $ do
        cs <- readIORef (rtConns rt)
        case M.lookup tok cs of
          Just send' -> send' ("{\"patch\":{" ++ intercalateC [jstr k ++ ":" ++ vj | (k, vj) <- patch] ++ "}}")
          Nothing -> pure ()
      -- interpret the Cmd; result msgs re-enter the pump
      results <- runCmd rt cmdV
      forM_ results (processMsg rt (depth - 1) tok)

-- Cmd interpreter: None | Print s | ReadFile p ev | Rng lo hi ev | Batch cs
runCmd :: Rt -> Value -> IO [(String, String)]
runCmd rt cmdV = case cmdV of
  VData 0 0 [] -> pure [] -- unit: no cmd
  VData t v args -> case lookupCon t v of
    Just "None" -> pure []
    Just "Print" | [s] <- args -> putStrLn ("[app] " ++ render s) >> pure []
    Just "ReadFile" | [VStr p, VStr ev] <- args -> do
      r <- try (readFile' p) :: IO (Either IOException String)
      pure [(ev, either (const ("<no such file: " ++ p ++ ">")) id r)]
    Just "Rng" | [VInt lo, VInt hi, VStr ev] <- args -> do
      n <- xorshift (rtRng rt)
      let x = lo + fromIntegral (n `mod` fromIntegral (max 1 (hi - lo + 1)))
      pure [(ev, show x)]
    Just "Batch" | [xs] <- args -> concat <$> mapM (runCmd rt) (listItemsV xs)
    Just "Put" | [VStr k, VStr v'] <- args -> do
      atomicModifyIORef' (rtKV rt) (\m -> (M.insert k v' m, ()))
      withMVar (rtKVLog rt) $ \h -> do
        hPutStrLn h ("{\"k\":" ++ jstr k ++ ",\"v\":" ++ jstr v' ++ "}")
        hFlush h
      pure []
    Just "Get" | [VStr k, VStr ev] <- args -> do
      m <- readIORef (rtKV rt)
      pure [(ev, M.findWithDefault "" k m)]
    Just "Msg" | [VStr ev, VStr v'] <- args -> pure [(ev, v')] -- self-dispatch
    _ -> putStrLn ("[view] unknown Cmd: " ++ render cmdV) >> pure []
  _ -> pure []
  where
    lookupCon t v = case [n | (n, (t', v')) <- M.toList (rtCons rt), t' == t, v' == v] of
      (n : _) -> Just n
      [] -> Nothing

listItemsV :: Value -> [Value]
listItemsV (VData t 1 [x, r]) | t == listT = x : listItemsV r
listItemsV _ = []

xorshift :: IORef Word64 -> IO Word64
xorshift ref = atomicModifyIORef' ref $ \s0 ->
  let s1 = s0 `xor` (s0 `shiftL` 13)
      s2 = s1 `xor` (s1 `shiftR` 7)
      s3 = s2 `xor` (s2 `shiftL` 17)
   in (s3, s3)

-- ---- HTTP -------------------------------------------------------------------

recvUntil :: Socket -> BS.ByteString -> IO BS.ByteString
recvUntil s marker = go BS.empty
  where
    go acc
      | marker `BS.isInfixOf` acc = pure acc
      | otherwise = do
          b <- recv s 4096
          if BS.null b then pure acc else go (acc <> b)

header :: String -> [String] -> Maybe String
header name hdrs =
  case [drop (length name + 1) h | h <- hdrs, (name ++ ":") `isPrefixOf` h] of
    (v : _) -> Just (dropWhile (== ' ') v)
    [] -> Nothing

handleConn :: Rt -> Socket -> IO ()
handleConn rt conn = do
  req <- recvUntil conn (BC.pack "\r\n\r\n")
  let ls = lines (filter (/= '\r') (BC.unpack req))
      reqLine = case ls of (l : _) -> l; [] -> ""
      hdrs = drop 1 ls
      path = case words reqLine of (_ : p : _) -> p; _ -> "/"
      wantWS = maybe False (isInfixOf "websocket") (map toLowerC <$> header "Upgrade" hdrs)
      toLowerC c = if c >= 'A' && c <= 'Z' then chr (ord c + 32) else c
  if wantWS || path == "/ws"
    then case header "Sec-WebSocket-Key" hdrs of
      Nothing -> sendAll conn (BC.pack "HTTP/1.1 400 Bad Request\r\n\r\n")
      Just key -> do
        let accept' = b64encode (sha1 (map (fromIntegral . ord) (key ++ wsGUID)))
        sendAll conn $
          BC.pack
            ( "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
                ++ accept'
                ++ "\r\n\r\n"
            )
        wsSession rt conn
    else do
      let body = clientPage
      sendAll conn $
        BC.pack
          ( "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: "
              ++ show (length body)
              ++ "\r\nConnection: close\r\n\r\n"
              ++ body
          )

wsGUID :: String
wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

-- ---- the ws session ---------------------------------------------------------

wsSession :: Rt -> Socket -> IO ()
wsSession rt conn = do
  hello <- wsRecvText conn
  case hello of
    Nothing -> pure ()
    Just h -> do
      let kv = parseFlat h
          givenTok = maybe "" id (lookup "hello" kv)
      known <- readIORef (rtSessions rt)
      tok <-
        if not (null givenTok) && M.member givenTok known
          then pure givenTok
          else do
            n <- xorshift (rtRng rt)
            pure ("s" ++ take 10 (showHexW n))
      model <- case M.lookup tok known of
        Just (m, _) -> pure m
        Nothing -> withMVar (rtSolLock rt) (\_ -> cbInit (rtCbs rt) (VStr tok))
      v <- withMVar (rtSolLock rt) (\_ -> cbView (rtCbs rt) model)
      let dyns = collectDyn (rtShapes rt) (conIndex (rtCons rt)) v
      atomicModifyIORef' (rtSessions rt) (\m -> (M.insert tok (model, dyns) m, ()))
      -- register a serialized sender for pushes (subs, cmd results)
      sendLock <- newMVar ()
      let sender payload = withMVar sendLock (\_ -> wsSendText conn payload)
      atomicModifyIORef' (rtConns rt) (\m -> (M.insert tok sender m, ()))
      sender ("{\"token\":" ++ jstr tok ++ ",\"view\":" ++ jsonVC (rtShapes rt) (conIndex (rtCons rt)) v ++ "}")
      processMsg rt 6 tok ("connected", "")
      loop tok
      atomicModifyIORef' (rtConns rt) (\m -> (M.delete tok m, ()))
  where
    loop tok =
      wsRecvText conn >>= \case
        Nothing -> pure ()
        Just m -> do
          let kv = parseFlat m
          case lookup "ev" kv of
            Just ev -> processMsg rt 6 tok (ev, maybe "" id (lookup "val" kv))
            Nothing -> pure ()
          loop tok

showHexW :: Word64 -> String
showHexW 0 = "0"
showHexW n = go n ""
  where
    go 0 acc = acc
    go x acc = go (x `div` 16) (("0123456789abcdef" !! fromIntegral (x `mod` 16)) : acc)

intercalateC :: [String] -> String
intercalateC = go
  where
    go [] = ""
    go [x] = x
    go (x : xs) = x ++ "," ++ go xs

-- walk the view collecting dyn slots — both the untyped {dyn, node}
-- record form and the typed DynN constructor (lib/ui.sol) — outermost first
collectDyn :: Shapes -> M.Map (Int, Int) String -> Value -> M.Map String String
collectDyn shapes conNames = go M.empty
  where
    lastSeg n = case break (== '.') n of
      (_, '.' : rest) -> lastSeg rest
      _ -> n
    go acc (VData tid 0 fs)
      | Just names <- M.lookup tid shapes,
        names == ["dyn", "node"],
        [VStr name, node] <- fs =
          go (M.insert name (jsonVC shapes conNames node) acc) node
    go acc (VData t c fs)
      | Just nm <- M.lookup (t, c) conNames,
        lastSeg nm == "DynN",
        [VStr name, node] <- fs =
          go (M.insert name (jsonVC shapes conNames node) acc) node
      | otherwise = foldl' go acc fs
    go acc _ = acc

-- ---- Value -> JSON (field names from the compiler's shape table) ------------

conIndex :: Cons -> M.Map (Int, Int) String
conIndex cons = M.fromList [((t, v), n) | (n, (t, v)) <- M.toList cons]

jsonV :: Shapes -> Value -> String
jsonV shapes = jsonVC shapes M.empty

-- with the constructor table: the typed view DSL's Html ADT (lib/ui.sol)
-- serializes to the SAME wire JSON the untyped record nodes use, so the
-- client JS is unchanged. Constructors are matched by their name's last
-- segment (file-module splicing prefixes them: ui.El, ui.Txt, ...).
jsonVC :: Shapes -> M.Map (Int, Int) String -> Value -> String
jsonVC shapes conNames = go
  where
    obj kvs = "{" ++ intercalateC [jstr k ++ ":" ++ v | (k, v) <- kvs] ++ "}"
    lastSeg n = case break (== '.') n of
      (_, '.' : rest) -> lastSeg rest
      _ -> n
    go v@(VData t c fs)
      | Just nm <- M.lookup (t, c) conNames = case (lastSeg nm, fs) of
          ("Txt", [x]) -> obj [("text", go x)]
          ("El", [tg, cl, ks]) -> obj [("tag", go tg), ("cls", go cl), ("kids", go ks)]
          ("EvN", [ev, val, nd]) -> obj [("ev", go ev), ("val", go val), ("node", go nd)]
          ("DynN", [d, nd]) -> obj [("dyn", go d), ("node", go nd)]
          ("FormN", [f, flds, b]) -> obj [("form", go f), ("fields", go flds), ("btn", go b)]
          ("InpN", [i, ph, b]) -> obj [("inp", go i), ("ph", go ph), ("btn", go b)]
          _ -> goPlain v
    go v = goPlain v
    goPlain (VInt n) = show n
    goPlain (VStr s) = jstr s
    goPlain (VData 1 0 []) = "false"
    goPlain (VData 1 1 []) = "true"
    goPlain (VData 0 0 []) = "null"
    goPlain v@(VData t _ _) | t == listT = "[" ++ intercalateC (map go (listItemsV v)) ++ "]"
    goPlain (VData 4 0 [a, b]) = "[" ++ go a ++ "," ++ go b ++ "]"
    goPlain (VData 5 0 [a, b, c]) = "[" ++ go a ++ "," ++ go b ++ "," ++ go c ++ "]"
    goPlain (VData t 0 [VStr a]) | t == atomT = jstr (":" ++ a)
    goPlain (VData tid 0 fs)
      | Just names <- M.lookup tid shapes,
        length names == length fs =
          "{" ++ intercalateC [jstr n ++ ":" ++ go f | (n, f) <- zip names fs] ++ "}"
    goPlain other = jstr (render other)

jstr :: String -> String
jstr s = "\"" ++ concatMap esc s ++ "\""
  where
    esc '"' = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\r' = "\\r"
    esc '\t' = "\\t"
    esc c | ord c < 32 = "\\u00" ++ [hexDig (ord c `div` 16), hexDig (ord c `mod` 16)]
    esc c = [c]
    hexDig n = "0123456789abcdef" !! n

-- flat {"k":"v","k2":null} parser: enough for the client protocol + the log
parseFlat :: String -> [(String, String)]
parseFlat = go
  where
    go s = case break (== '"') s of
      (_, '"' : rest) ->
        let (k, rest1) = jstring rest
         in case dropWhile (`elem` " \t") rest1 of
              ':' : rest2 -> case dropWhile (`elem` " \t") rest2 of
                '"' : rest3 -> let (v, rest4) = jstring rest3 in (k, v) : go rest4
                r | "null" `isPrefixOf` r -> (k, "") : go (drop 4 r)
                r -> go r
              r -> go r
      _ -> []
    jstring = goS ""
      where
        goS acc ('\\' : c : rest) = case c of
          'n' -> goS ('\n' : acc) rest
          't' -> goS ('\t' : acc) rest
          'r' -> goS ('\r' : acc) rest
          'u' -> case splitAt 4 rest of
            (h', rest') -> goS (chr (hexVal h') : acc) rest'
          _ -> goS (c : acc) rest
        goS acc ('"' : rest) = (reverse acc, rest)
        goS acc (c : rest) = goS (c : acc) rest
        goS acc [] = (reverse acc, [])
        hexVal = foldl' (\a c -> a * 16 + dig c) 0
        dig c
          | c >= '0' && c <= '9' = ord c - ord '0'
          | c >= 'a' && c <= 'f' = ord c - ord 'a' + 10
          | c >= 'A' && c <= 'F' = ord c - ord 'A' + 10
          | otherwise = 0

-- ---- WebSocket framing ------------------------------------------------------

recvN :: Socket -> Int -> IO (Maybe BS.ByteString)
recvN s n = go BS.empty
  where
    go acc
      | BS.length acc >= n = pure (Just acc)
      | otherwise = do
          b <- recv s (n - BS.length acc)
          if BS.null b then pure Nothing else go (acc <> b)

wsRecvText :: Socket -> IO (Maybe String)
wsRecvText s = do
  mh <- recvN s 2
  case mh of
    Nothing -> pure Nothing
    Just h -> do
      let b0 = BS.index h 0
          b1 = BS.index h 1
          opcode = b0 .&. 0x0f
          masked = b1 .&. 0x80 /= 0
          len7 = fromIntegral (b1 .&. 0x7f) :: Int
      mlen <- case len7 of
        126 -> fmap (fmap (\b -> (fromIntegral (BS.index b 0) `shiftL` 8) .|. fromIntegral (BS.index b 1))) (recvN s 2)
        127 -> fmap (fmap (\b -> foldl' (\a i -> a * 256 + fromIntegral (BS.index b i)) 0 [0 .. 7])) (recvN s 8)
        n -> pure (Just n)
      case mlen of
        Nothing -> pure Nothing
        Just len -> do
          mmask <- if masked then recvN s 4 else pure (Just BS.empty)
          mpay <- recvN s len
          case (mmask, mpay) of
            (Just mask, Just pay) -> do
              let unmasked =
                    if masked
                      then BS.pack [BS.index pay i `xor` BS.index mask (i `mod` 4) | i <- [0 .. BS.length pay - 1]]
                      else pay
              case opcode of
                0x8 -> pure Nothing
                0x9 -> sendAll s (BS.pack [0x8A, 0]) >> wsRecvText s
                0x1 -> pure (Just (BC.unpack unmasked))
                _ -> wsRecvText s
            _ -> pure Nothing

wsSendText :: Socket -> String -> IO ()
wsSendText s payload = do
  let bytes = BC.pack payload
      n = BS.length bytes
      hdr
        | n < 126 = BS.pack [0x81, fromIntegral n]
        | n < 65536 = BS.pack [0x81, 126, fromIntegral (n `shiftR` 8), fromIntegral (n .&. 0xff)]
        | otherwise = BS.pack (0x81 : 127 : [fromIntegral ((fromIntegral n :: Word64) `shiftR` (8 * i) .&. 0xff) | i <- [7, 6 .. 0]])
  sendAll s (hdr <> bytes)

-- ---- SHA-1 + Base64 (WS handshake only) -------------------------------------

sha1 :: [Word8] -> [Word8]
sha1 msg = concatMap w32be [a, b, c, d, e]
  where
    (a, b, c, d, e) = foldl' block (0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0) chunks
    padded =
      msg
        ++ [0x80]
        ++ replicate ((55 - length msg) `mod` 64) 0
        ++ w64be (fromIntegral (length msg) * 8)
    chunks = split64 padded
    split64 [] = []
    split64 xs = take 64 xs : split64 (drop 64 xs)
    block (h0, h1, h2, h3, h4) chunk =
      let w0 = [beW32 (take 4 (drop (i * 4) chunk)) | i <- [0 .. 15]]
          arr = w0 ++ [rotateL (arr !! (i - 3) `xor` arr !! (i - 8) `xor` arr !! (i - 14) `xor` arr !! (i - 16)) 1 | i <- [16 .. 79]]
          (a', b', c', d', e') = foldl' rnd (h0, h1, h2, h3, h4) (zip [0 :: Int ..] arr)
       in (h0 + a', h1 + b', h2 + c', h3 + d', h4 + e')
    rnd (a', b', c', d', e') (i, w) =
      let (f, k)
            | i < 20 = ((b' .&. c') .|. (complement b' .&. d'), 0x5A827999)
            | i < 40 = (b' `xor` c' `xor` d', 0x6ED9EBA1)
            | i < 60 = ((b' .&. c') .|. (b' .&. d') .|. (c' .&. d'), 0x8F1BBCDC)
            | otherwise = (b' `xor` c' `xor` d', 0xCA62C1D6)
          t = rotateL a' 5 + f + e' + k + w
       in (t, a', rotateL b' 30, c', d')
    beW32 [x, y, z, u] = (fromIntegral x `shiftL` 24) .|. (fromIntegral y `shiftL` 16) .|. (fromIntegral z `shiftL` 8) .|. fromIntegral u :: Word32
    beW32 _ = 0
    w32be x = [fromIntegral (x `shiftR` s') | s' <- [24, 16, 8, 0]]
    w64be :: Word64 -> [Word8]
    w64be x = [fromIntegral (x `shiftR` (8 * i)) | i <- [7, 6 .. 0]]

b64encode :: [Word8] -> String
b64encode = go
  where
    alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    go (x : y : z : rest) =
      let n = (fromIntegral x `shiftL` 16) .|. (fromIntegral y `shiftL` 8) .|. fromIntegral z :: Int
       in [alpha !! (n `shiftR` 18), alpha !! ((n `shiftR` 12) .&. 63), alpha !! ((n `shiftR` 6) .&. 63), alpha !! (n .&. 63)] ++ go rest
    go [x, y] =
      let n = (fromIntegral x `shiftL` 16) .|. (fromIntegral y `shiftL` 8) :: Int
       in [alpha !! (n `shiftR` 18), alpha !! ((n `shiftR` 12) .&. 63), alpha !! ((n `shiftR` 6) .&. 63), '=']
    go [x] =
      let n = fromIntegral x `shiftL` 16 :: Int
       in [alpha !! (n `shiftR` 18), alpha !! ((n `shiftR` 12) .&. 63), '=', '=']
    go [] = []

-- ---- the companion client ---------------------------------------------------

clientPage :: String
clientPage =
  unlines
    [ "<!doctype html><html><head><meta charset='utf-8'>",
      "<meta name='viewport' content='width=device-width, initial-scale=1'>",
      "<title>sol view</title><style>",
      "*{box-sizing:border-box;margin:0} body{font-family:system-ui,sans-serif;background:#f6f7f9;color:#1a202c}",
      ".container{max-width:760px} .mx-auto{margin-left:auto;margin-right:auto}",
      ".flex{display:flex} .flex-col{flex-direction:column} .flex-row{flex-direction:row} .flex-wrap{flex-wrap:wrap} .flex-1{flex:1} .items-center{align-items:center}",
      ".grid{display:grid} .grid-cols-2{grid-template-columns:1fr 1fr}",
      ".gap-1{gap:.25rem} .gap-2{gap:.5rem} .gap-3{gap:.75rem} .gap-4{gap:1rem}",
      ".p-2{padding:.5rem} .p-4{padding:1rem} .px-3{padding-left:.75rem;padding-right:.75rem} .py-1{padding-top:.25rem;padding-bottom:.25rem}",
      ".rounded{border-radius:.5rem} .border{border:1px solid #e2e8f0} .shadow{box-shadow:0 1px 3px rgba(0,0,0,.08)}",
      ".card{background:#fff;border:1px solid #e2e8f0;border-radius:.5rem;padding:1rem;box-shadow:0 1px 3px rgba(0,0,0,.06)}",
      ".text-sm{font-size:.85rem} .text-xl{font-size:1.3rem} .text-2xl{font-size:1.7rem} .font-bold{font-weight:700} .text-muted{color:#5a6472;line-height:1.55}",
      ".badge{background:#e6f0ff;color:#2456c4;border-radius:999px;padding:.15rem .6rem;font-size:.75rem;font-weight:600}",
      ".tab{padding:.4rem .9rem;border-radius:.5rem;border:1px solid #e2e8f0;background:#fff;cursor:pointer;font-size:.9rem}",
      ".tab-active{background:#2456c4;color:#fff;border-color:#2456c4}",
      ".clickable{cursor:pointer;user-select:none}",
      ".comment{background:#f1f5f9;border-radius:.4rem;padding:.45rem .7rem;font-size:.92rem}",
      ".input{padding:.45rem .7rem;border:1px solid #cbd5e1;border-radius:.5rem;font-size:.92rem;min-width:0}",
      ".btn{padding:.45rem .9rem;border:0;border-radius:.5rem;background:#2456c4;color:#fff;cursor:pointer;font-size:.92rem}",
      "@media (max-width:640px){ .grid-cols-2{grid-template-columns:1fr} .flex-row{flex-wrap:wrap} .container{padding:.5rem} }",
      "</style></head><body><div id='root'></div><script>",
      "let tok = localStorage.getItem('sol-token');",
      "const ws = new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+'/ws');",
      "ws.onopen = () => ws.send(JSON.stringify({hello: tok}));",
      "ws.onmessage = (e) => { const m = JSON.parse(e.data);",
      "  if (m.token !== undefined) { tok = m.token; localStorage.setItem('sol-token', tok);",
      "    const r = document.getElementById('root'); r.replaceChildren(build(m.view)); }",
      "  if (m.patch) { for (const k of Object.keys(m.patch)) {",
      "    const el = document.querySelector('[data-dyn=\"'+k+'\"]');",
      "    if (el) el.replaceChildren(build(m.patch[k])); } } };",
      "function send(ev, val){ ws.send(JSON.stringify({ev: ev, val: String(val==null?'':val)})); }",
      "function build(n){",
      "  if (n == null) return document.createTextNode('');",
      "  if (typeof n === 'string' || typeof n === 'number') return document.createTextNode(String(n));",
      "  if (Array.isArray(n)) { const f = document.createDocumentFragment(); n.forEach(k=>f.appendChild(build(k))); return f; }",
      "  if (n.text !== undefined) return document.createTextNode(n.text);",
      "  if (n.dyn !== undefined) { const s = document.createElement('span'); s.dataset.dyn = n.dyn; s.appendChild(build(n.node)); return s; }",
      "  if (n.ev !== undefined) { const w = build(n.node);",
      "    if (w.classList) w.classList.add('clickable');",
      "    w.addEventListener('click', () => send(n.ev, n.val)); return w; }",
      "  if (n.form !== undefined) { const col = document.createElement('div'); col.className = 'flex flex-col gap-2';",
      "    const ins = (n.fields||[]).map(f => { const i = document.createElement('input'); i.className='input';",
      "      i.placeholder = f; if (f.indexOf('pass') >= 0) i.type = 'password'; col.appendChild(i); return i; });",
      "    const b = document.createElement('button'); b.className = 'btn'; b.textContent = n.btn || 'Go';",
      "    b.onclick = () => { const vs = ins.map(i => i.value.trim()); if (vs.every(v => v)) { send(n.form, vs.join(' ')); ins.forEach(i => i.value=''); } };",
      "    col.appendChild(b); return col; }",
      "  if (n.inp !== undefined) { const row = document.createElement('div'); row.className = 'flex flex-row gap-2';",
      "    const i = document.createElement('input'); i.className = 'input flex-1'; i.placeholder = n.ph || '';",
      "    const b = document.createElement('button'); b.className = 'btn'; b.textContent = n.btn || 'Send';",
      "    const go = () => { const v = i.value.trim(); if (v) { send(n.inp, v); i.value = ''; } };",
      "    b.onclick = go; i.addEventListener('keydown', e => { if (e.key === 'Enter') go(); });",
      "    row.append(i, b); return row; }",
      "  const el = document.createElement(n.tag || 'div'); if (n.cls) el.className = n.cls;",
      "  (n.kids || []).forEach(k => el.appendChild(build(k))); return el; }",
      "</script></body></html>"
    ]
