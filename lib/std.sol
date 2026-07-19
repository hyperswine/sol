# lib/std.sol — the stdlib shape from the design discussion, as a module:
# sigs are named rows (N = Sig {...}), structures implement them (N = Struct ...), generic functions are
# row-generic over `(s : Sig)` params and monomorphize at the call site.

Arith = Sig { add : t -> t -> t, zero : t }.
Functor = Sig { fmap : (a -> b) -> t a -> t b }.
StreamOps = Sig { sfilter, sfold, sany }.

Num = Struct Arith {
  add = fn a b -> a + b,
  zero = 0
}.

ListS = Struct Functor StreamOps Arith {
  fmap = fn f xs -> map f xs,
  sfilter = fn p xs -> filter p xs,
  sfold = fn f z xs -> foldl f z xs,
  sany = fn p xs -> case filter p xs of Nil -> False | _ -> True,
  add = fn a b -> case a of Nil -> b | x :: rest -> x :: (ListS.add rest b),
  zero = []
}.

# generic over Arith: works for Num, ListS, or any conforming struct
total (s : Arith) xs = foldl s.add s.zero xs.

# generic over Functor + StreamOps together (two sig params)
mapKeep (f : Functor) (st : StreamOps) g p xs = st.sfilter p (f.fmap g xs).

# generic composing another generic, struct passed through
average xs = n = strlen (str 0); t = total Num xs; c = foldl (fn a x -> a + 1) 0 xs; t / c.
