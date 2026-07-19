{-# LANGUAGE LambdaCase #-}

-- Main.hs — `sol script.sol`
--
-- Pipeline (front half reused verbatim from the FPRISC compiler):
--   prelude + script --> parse --> linearity check --> desugar --> lambda
--   lift --> BYTECODE (instead of RISC-V asm) --> Sol VM
--
-- The whole run is one transaction: reads snapshot host files, writes are
-- buffered, and at exit we lock / validate / commit / unlock. A validation
-- failure re-runs the script (STM retry) — see Txn.hs.

module Main where

import Bytecode
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.State.Strict (runState)
import Data.IORef
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Lang
import Mod (resolveModule)
import Struct (erasePSig, expandStructs, sigTable, specialize, structTable)
import Infer (inferTops)
import Width (widthReport)
import JIT (JitCtx, initJIT)
import System.Environment (getArgs, lookupEnv)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.Exit (exitFailure)
import System.FilePath (dropExtension, takeDirectory)
import Text.Megaparsec (errorBundlePretty, parse)
import Txn
import VM hiding ()
import qualified VM

-- ---- the auto-provided std surface -----------------------------------------
-- Injected before every script: Path + linear Handle types, and the file API
-- signatures the linearity checker enforces. readPath/writePath are ordinary
-- Sol code written against the linear API — the prelude eats its own cooking.
prelude :: String
prelude =
  unlines
    [ "Path = Type (Path String).",
      "Handle 1 = Type (Handle Int).",
      "open : String -> Handle.",
      "readAll : Handle -> (String, Handle).",
      "writeAll : Handle -> String -> Handle.",
      "close : Handle -> Unit.",
      "readPath p = (s, h) = readAll (open p); u = close h; s.",
      "writePath p s = close (writeAll (open p) s).",
      "Vector 1 = Type (Vector Int).",
      "Vec.new : Unit -> Vector.",
      "Vec.push : a -> Vector -> Vector.",
      "Vec.len : Vector -> (Int, Vector).",
      "Vec.get : Int -> Vector -> (a, Vector).",
      "Vec.set : Int -> a -> Vector -> Vector.",
      "Vec.map : (a -> b) -> Vector -> Vector.",
      "Vec.filter : (a -> Bool) -> Vector -> Vector.",
      "Vec.fold : (b -> a -> b) -> b -> Vector -> (b, Vector).",
      "Vec.toList : Vector -> List a.",
      "Vec.fromList : List a -> Vector.",
      "Vec.free : Vector -> Unit.",
      "Module = Type (Module Int).",
      "use : String -> Module.",
      "run : Module -> a -> String.",
      "input : Unit -> String.",
      "View.serve : Int -> (a -> b) -> (c -> b -> e) -> (b -> d) -> f -> Unit.",
      "Persistent = Type (Persistent x).",
      "Cmd = Type (None | Print x | ReadFile x y | Rng x y z | Batch x | Put x y | Get x y | Msg x y).",
      -- ---- stdlib: sigs are rows, structures implement them ----
      -- Add is the monoid-ish slice (Numeric, Str, List); Arith is the
      -- full numeric row. Structural rows mean Numeric : Arith ALSO
      -- satisfies Add at call sites without declaring it.
      "Add = Sig { (+) : t -> t -> t, zero : t }.",
      "Arith = Sig { (+) : t -> t -> t, (-) : t -> t -> t, (*) : t -> t -> t, (/) : t -> t -> t, zero : t }.",
      "Functor = Sig { map : (a -> b) -> t a -> t b }.",
      "StreamOps = Sig { filter : (a -> Bool) -> t a -> t a, fold : (b -> a -> b) -> b -> t a -> b, find : (a -> Bool) -> t a -> t a, any : (a -> Bool) -> t a -> Bool, all : (a -> Bool) -> t a -> Bool }.",
      "Numeric = Struct Arith {",
      "  (+) = fn a b -> a + b,",
      "  (-) = fn a b -> a - b,",
      "  (*) = fn a b -> a * b,",
      "  (/) = fn a b -> a / b,",
      "  zero = 0,",
      "  abs = fn a -> case a < 0 of True -> 0 - a | False -> a,",
      "  max = fn a b -> case a > b of True -> a | False -> b,",
      "  min = fn a b -> case a < b of True -> a | False -> b,",
      "  clamp = fn lo hi a -> Numeric.min hi (Numeric.max lo a),",
      "  mod = fn a b -> a - (a / b) * b,",
      "  neg = fn a -> 0 - a",
      "}.",
      "Str = Struct Add {",
      "  (+) = fn a b -> strcat a b,",
      "  zero = \"\",",
      "  len = fn s -> strlen s,",
      "  cat = fn a b -> strcat a b,",
      "  at = fn s i -> charAt s i,",
      "  fromCode = fn c -> chr c,",
      "  parse = fn s -> parseInt s",
      "}.",
      "List = Struct Add Functor StreamOps {",
      "  (+) = fn a b -> List.append a b,",
      "  zero = [],",
      "  append = fn a b -> case a of Nil -> b | x :: rest -> x :: (List.append rest b),",
      "  map = fn f xs -> map f xs,",
      "  filter = fn p xs -> filter p xs,",
      "  fold = fn f z xs -> foldl f z xs,",
      "  find = fn p xs -> case filter p xs of Nil -> [] | x :: rest -> [x],",
      "  any = fn p xs -> case filter p xs of Nil -> False | _ -> True,",
      "  all = fn p xs -> case filter (fn x -> case p x of True -> False | False -> True) xs of Nil -> True | _ -> False,",
      "  len = fn xs -> foldl (fn n x -> n + 1) 0 xs,",
      "  rev = fn xs -> foldl (fn acc x -> x :: acc) [] xs,",
      "  groupby = fn f xs -> foldl (fn acc x -> List.gbIns (f x) x acc) [] xs,",
      "  gbIns = fn k x g -> case g of Nil -> [(k, [x])] | p :: rest -> (case p of (kk, vs) -> (case kk == k of True -> (kk, List.append vs [x]) :: rest | False -> p :: (List.gbIns k x rest)))",
      "}."
    ]

-- HAL symbols + arities the bytecode compiler may emit saturated HCALLs for
halArities :: M.Map Name Int
halArities =
  M.fromList
    [ ("print", 1), ("str", 1), ("strcat", 2), ("String.len", 1), ("strlen", 1),
      ("error", 1), ("parseInt", 1), ("charAt", 2), ("chr", 1), ("!", 2), ("sleepMs", 1), ("fuelPreempts", 1),
      ("open", 1), ("readAll", 1), ("writeAll", 2), ("close", 1),
      ("rm", 1), ("rmdir", 1), ("mkdirp", 1), ("ls", 1), ("exists", 1),
      ("isDir", 1), ("stat", 1), ("sh", 1), ("shq", 1),
      ("map", 2), ("filter", 2), ("foldl", 3),
      ("Vec.new", 1), ("Vec.push", 2), ("Vec.len", 1), ("Vec.get", 2),
      ("Vec.set", 3), ("Vec.map", 2), ("Vec.filter", 2), ("Vec.fold", 3),
      ("Vec.toList", 1), ("Vec.fromList", 1), ("Vec.free", 1),
      ("use", 1), ("run", 2), ("input", 1), ("View.serve", 5)
    ]

maxRetries :: Int
maxRetries = 12

main :: IO ()
main = do
  setLocaleEncoding utf8
  as <- getArgs
  (dumpAsm, path) <- case as of
    ["--asm", p] -> pure (True, p)
    [p] -> pure (False, p)
    _ -> putStrLn "usage: sol [--asm] <script.sol>" >> exitFailure >> pure (False, "")
  src <- readFile path
  ptops <- parseOrDie "<prelude>" prelude
  utops <- parseOrDie path src

  -- compile-time FILE-module expansion: `m = use "spec".` splices the module's
  -- definitions in, renamed under the alias; `m.f` references and
  -- `T = m.T.` constructor aliases then resolve against the merged program
  seenRef <- newIORef M.empty
  utopsX0 <- expandUses 8 "" seenRef (takeDirectory path) utops

  -- sigs / structs / (s : Sig) params — now including the PRELUDE stdlib
  -- structs (Numeric/Str/List): conformance-check, expand structs to flat
  -- globals + first-class records, TYPECHECK (HM + rows) which also
  -- resolves arith operators by operand type, then monomorphize
  let sigs = sigTable (ptops ++ utopsX0)
      structs = structTable (ptops ++ utopsX0)
      (perrs, ptopsExp) = expandStructs sigs ptops
      (structErrs1, topsExp) = expandStructs sigs utopsX0
  unless (null (perrs ++ structErrs1)) $ do
    putStrLn "=== SIG/STRUCT: ERRORS ==="
    mapM_ (putStrLn . ("  * " ++)) (perrs ++ structErrs1)
    exitFailure

  -- gradual boundary: `# sol:notypes` in a file header opts the run out
  -- of the checker (the MVU view DSL's heterogeneous node records need a
  -- Node ADT to type — a gen_view design decision, tracked in README)
  envNoTypes <- (== Just "1") <$> lookupEnv "SOL_NOTYPES"
  let pragmaNoTypes = any ("sol:notypes" `isPrefixOf`) (map (dropWhile (`elem` "# \t")) (take 20 (lines src)))
      noTypes = envNoTypes || pragmaNoTypes
  when pragmaNoTypes $ putStrLn "[sol] types: skipped (# sol:notypes pragma)"
  showTypes <- (== Just "1") <$> lookupEnv "SOL_TYPES"
  combined <-
    if noTypes
      then pure (ptopsExp ++ topsExp) -- ops stay Int prims; debugging only
      else do
        let (terrs, notes, rewritten) = inferTops sigs structs (ptopsExp ++ topsExp)
            userNames = S.fromList [n | TBind n _ _ _ <- topsExp]
        unless (null terrs) $ do
          putStrLn "=== TYPE ERRORS ==="
          mapM_ (putStrLn . ("  * " ++)) terrs
          exitFailure
        when showTypes $ do
          putStrLn "=== INFERRED TYPES ==="
          forM_ [nt | nt@(n, _) <- notes, S.member n userNames] $ \(n, t) ->
            putStrLn ("  " ++ n ++ " : " ++ t)
        pure rewritten

  let (structErrs2, topsSpec) = specialize sigs structs combined
      allX = erasePSig topsSpec
  showWidths <- (== Just "1") <$> lookupEnv "SOL_WIDTHS"
  when showWidths $ do
    putStrLn "=== NUMERIC WIDTHS (advisory) ==="
    mapM_ putStrLn (widthReport allX)
  unless (null structErrs2) $ do
    putStrLn "=== SIG/STRUCT: ERRORS ==="
    mapM_ (putStrLn . ("  * " ++)) structErrs2
    exitFailure

  -- `> expr.` becomes an anonymous zero-arg binding, run in file order
  -- (prelude has no evals, so numbering over the combined list is identical)
  let (tops, evalNames) = numberEvals allX

  -- linearity: unchanged from the FPRISC front-end — this is what makes
  -- leaked / double-used handles a COMPILE error, not a runtime one
  let li = buildLinInfo tops
      lerrs = lcheck li tops
  unless (null lerrs) $ do
    putStrLn "=== LINEARITY: ERRORS ==="
    mapM_ (putStrLn . ("  * " ++)) lerrs
    exitFailure

  let cons = collectCons tops
      shapes = collectShapes tops
      (prog, _) = runState (compileTop tops >>= liftFix) (DEnv 0 cons shapes [])
      bprog = compileProg halArities prog
      Just (pathT, _, _) = M.lookup "Path" cons
      Just (handleT, _, _) = M.lookup "Handle" cons

  when dumpAsm $ do
    forM_ (M.toList bprog) $ \(n, fn) -> putStrLn (disasm n fn)

  -- `>` statements run in file order; a zero-arity `main`, if defined,
  -- runs after them (so plain FPRISC-style files still do something)
  let runList =
        evalNames ++ case M.lookup "main" bprog of
          Just fn | fnArity fn == 0 -> ["main"]
          _ -> []
  when (null runList && not dumpAsm) $
    putStrLn "[sol] note: no `> expr.` statements and no main; nothing to run"

  -- JIT: one LLJIT per process; the compile cache survives STM retries.
  -- SOL_JIT=0 disables the tier (interpreter handles everything).
  jitFlag <- lookupEnv "SOL_JIT"
  jc <-
    if jitFlag == Just "0"
      then pure Nothing
      else initJIT

  let shapeNames = M.fromList [(tid, fields) | (fields, tid) <- M.toList shapes]
      consTV = M.map (\(t, v, _) -> (t, v)) cons
      dataFile = dropExtension path ++ ".soldata"
  unless dumpAsm $ runTxLoop (takeDirectory path) dataFile consTV shapeNames bprog prog jc pathT handleT runList 0

-- run every `>` statement in order inside one transaction, then commit;
-- on read-set conflict, reset and re-run the whole script
runTxLoop :: FilePath -> FilePath -> M.Map Name (Int, Int) -> M.Map Int [Name] -> BProg -> Prog -> Maybe JitCtx -> Int -> Int -> [Name] -> Int -> IO ()
runTxLoop base dataFile consTV shapeNames bprog core jc pathT handleT topNames attempt = do
  tx <- newTx
  fuel <- newIORef fuelQuantum
  preempts <- newIORef 0
  let env = VMEnv base dataFile consTV shapeNames bprog core jc (mkHal pathT handleT tx preempts) fuel preempts
  forM_ topNames $ \n -> do
    v <- execFn env n []
    unless (isUnit v) $ putStrLn ("=> " ++ VM.render v)
  forceN <- lookupEnv "SOL_FORCE_RETRY"
  let force = maybe 0 read forceN :: Int
  res <-
    if attempt < force
      then pure (Conflict ["<forced>"]) -- discard this attempt's effects
      else commit tx
  case res of
    Committed n
      | n > 0 -> putStrLn ("[sol] committed " ++ show n ++ " file(s) atomically")
      | otherwise -> pure ()
    Conflict stale
      | attempt + 1 >= maxRetries -> do
          putStrLn ("[sol] giving up after " ++ show maxRetries ++ " attempts (conflicts on " ++ show stale ++ ")")
          exitFailure
      | otherwise -> do
          putStrLn ("[sol] conflict on " ++ show stale ++ " — retrying (attempt " ++ show (attempt + 2) ++ ")")
          runTxLoop base dataFile consTV shapeNames bprog core jc pathT handleT topNames (attempt + 1)

numberEvals :: [STop] -> ([STop], [Name])
numberEvals tops = (map fst numbered, [n | (_, Just n) <- numbered])
  where
    numbered = go (0 :: Int) tops
    go _ [] = []
    go i (TEval e : rest) =
      let n = "top__" ++ show i
       in (TBind n [] Nothing e, Just n) : go (i + 1) rest
    go i (t : rest) = (t, Nothing) : go i rest

parseOrDie :: String -> String -> IO [STop]
parseOrDie name src = case parse program name src of
  Left e -> putStrLn (errorBundlePretty e) >> exitFailure >> pure []
  Right t -> pure t

-- ---- compile-time module import ---------------------------------------------
-- Recognize `m = use "name#hash".` at top level: resolve + hash-verify the
-- module, recursively expand ITS uses, rename every top-level definition
-- under the alias, and splice the result in front of the user tops.
--
-- DEDUP BY CONTENT HASH: two imports of the same module (directly, or
-- nested at any depth) splice ONCE. `seen` maps module hash -> the FINAL
-- fully-prefixed name of the canonical splice; later aliases just rewrite
-- their qualified references onto it. This is what keeps one type ONE type:
-- a PT built by a library's internal logic import unifies with the app's
-- own logic import because they are literally the same declarations.
expandUses :: Int -> String -> IORef (M.Map String String) -> FilePath -> [STop] -> IO [STop]
expandUses 0 _ _ _ _ = putStrLn "[sol] use: module nesting too deep" >> exitFailure >> pure []
expandUses depth prefix seenRef baseDir tops = do
  let aliases = [(mn, spec) | TBind mn [] Nothing (SApp (SVar "use") (SStrI [SegStr spec])) <- tops]
  pairs <- forM aliases $ \(mn, spec) -> do
    r <- resolveModule baseDir spec
    case r of
      Left e -> putStrLn e >> exitFailure >> pure ([], (mn, mn))
      Right (mpath, h, pinned) -> do
        unless pinned $
          putStrLn ("[sol] use (compile): " ++ spec ++ " resolves to " ++ spec ++ "#" ++ h ++ " (pin this)")
        seen <- readIORef seenRef
        case M.lookup h seen of
          Just finalName -> do
            -- already spliced somewhere: alias onto the canonical copy
            let localName =
                  if prefix `isPrefixOf` finalName
                    then drop (length prefix) finalName
                    else finalName
            pure ([], (mn, localName))
          Nothing -> do
            modifyIORef' seenRef (M.insert h (prefix ++ mn))
            msrc <- readFile mpath
            mtops0 <- parseOrDie mpath msrc
            mtops1 <- expandUses (depth - 1) (prefix ++ mn ++ ".") seenRef (takeDirectory mpath) mtops0
            let defs = [t | t <- mtops1, notEval t]
                rn = M.fromList [(n, mn ++ "." ++ n) | n <- topNames defs]
            pure (renameTops rn defs, (mn, mn))
  let aliasMap = M.fromList (map snd pairs)
  pure (concatMap fst pairs ++ qualifyUses aliasMap tops)
  where
    notEval TEval {} = False
    notEval _ = True
