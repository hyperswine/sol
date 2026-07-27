-- Preamble.hs — the auto-provided std surface (prelude source) and the
-- HAL symbol/arity table. Extracted from Main so tooling (property tests,
-- future REPL) can drive the exact same pipeline in-process.

module Preamble (prelude, halArities) where

import qualified Data.Map.Strict as M
import Lang (Name)

-- ---- the auto-provided std surface -----------------------------------------
-- Injected before every script: Path + linear Handle types, and the file API
-- signatures the linearity checker enforces. readPath/writePath are ordinary
-- Sol code written against the linear API — the prelude eats its own cooking.
prelude :: String
prelude =
  unlines
    [ "Path = Type (Path String).",
      "Handle 1 = Type (Handle Int).",
      -- Io: the structured intents `write`/`read` decode. Effects (Dir, Rm,
      -- RmDir) are written TO a path; queries (Ls, Stat, Exists, IsDir, Sh)
      -- carry their path/command and are read FROM. Everything below the
      -- handle quartet is ordinary Sol code over read/write — the HAL's
      -- whole outside-world surface is those two symbols plus the handles.
      "Io = Type (Dir | Rm | RmDir | Ls x | Stat x | Exists x | IsDir x | Sh x).",
      "open : String -> Handle.",
      "readAll : Handle -> (String, Handle).",
      "writeAll : Handle -> String -> Handle.",
      "close : Handle -> Unit.",
      "readPath p = read p.",
      "writePath p s = write p s.",
      "mkdirp p = write p Dir.",
      "rm p = write p Rm.",
      "rmdir p = write p RmDir.",
      "mv a b = s = read a; u = write b s; write a Rm.",
      "ls p = read (Ls p).",
      "stat p = read (Stat p).",
      "exists p = read (Exists p).",
      "isDir p = read (IsDir p).",
      "sh c = read (Sh c).",
      "shq c = write \"/dev/sh\" c.",
      "print v = write \"/dev/out\" v.",
      "input u = read \"/dev/in\".",
      "sleepMs n = write \"/dev/clock\" n.",
      "fuelPreempts u = read \"/dev/fuel\".",
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
      -- the inexact tier: div is TRUE division (1 `div` 2 = 0.5); sqrt,
      -- floor, round complete the surface. Plain +,-,*,< work on the
      -- results directly — inexactness propagates by promotion, and a
      -- computation landing back on an integer renders as one.
      "  div = fn a b -> Num.div a b,",
      "  sqrt = fn a -> Num.sqrt a,",
      "  floor = fn a -> Num.floor a,",
      "  round = fn a -> Num.round a,",
      "  inexact = fn a -> Num.div a 1,",
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
    [ ("str", 1), ("strcat", 2), ("String.len", 1), ("strlen", 1),
      ("error", 1), ("parseInt", 1), ("charAt", 2), ("chr", 1), ("!", 2),
      ("open", 1), ("readAll", 1), ("writeAll", 2), ("close", 1),
      ("read", 1), ("write", 2),
      ("Num.div", 2), ("Num.sqrt", 1), ("Num.floor", 1), ("Num.round", 1),
      ("map", 2), ("filter", 2), ("foldl", 3),
      ("Vec.new", 1), ("Vec.push", 2), ("Vec.len", 1), ("Vec.get", 2),
      ("Vec.set", 3), ("Vec.map", 2), ("Vec.filter", 2), ("Vec.fold", 3),
      ("Vec.toList", 1), ("Vec.fromList", 1), ("Vec.free", 1),
      ("use", 1), ("run", 2), ("View.serve", 5)
    ]
