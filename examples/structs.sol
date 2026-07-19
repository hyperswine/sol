# structs.sol — sigs, structs, and compile-time specialization.
#
# `N = Sig {...}` names a row; `N = Struct S1 S2 {...}` implements rows; `(s : Sig)` params make a
# function generic over any conforming struct. Call sites with a struct
# literal are monomorphized (s.f -> direct N.f globals); call sites where
# the struct flows in as a value fall back to first-class records.

Arith = Sig { add : t -> t -> t, zero : t }.
Functor = Sig { fmap : (a -> b) -> t a -> t b }.

# ---- structures -------------------------------------------------------------

Num = Struct Arith {
  add = fn a b -> a + b,
  zero = 0
}.

Concat = Struct Arith {
  add = fn a b -> strcat a b,
  zero = ""
}.

Listy = Struct Functor Arith {
  fmap = fn f xs -> map f xs,
  add = fn a b -> case a of
    Nil -> b
    | x :: rest -> x :: (Listy.add rest b),
  zero = []
}.

# ---- generics over a sig ----------------------------------------------------

# fold any Arith over a list of its carrier
total (s : Arith) xs = foldl s.add s.zero xs.

# use a Functor twice — a generic calling into the struct's own field
twice (s : Functor) f xs = s.fmap f (s.fmap f xs).

# a generic calling another generic with the struct passed through:
# specialization must chase this transitively
sumShifted (s : Arith) n xs = total s (map (fn x -> s.add x n) xs).

# ---- monomorphized call sites (struct literal at the call) ------------------

> print "total Num [1,2,3,4] = {total Num [1,2,3,4]}".
> print "total Concat = {total Concat ["so", "l", "!"]}".
> print "twice Listy (+3) [1,2,3] = {str (twice Listy (fn x -> x + 3) [1,2,3])}".
> print "sumShifted Num 10 [1,2,3] = {sumShifted Num 10 [1,2,3]}".
> print "Listy.add [1,2] [3,4] = {str (total Listy [[1,2],[3,4]])}".

# ---- first-class fallback (struct as a runtime value) -----------------------

# pick a struct at RUNTIME — cannot be monomorphized; the record flows in
# and s.add / s.zero dispatch through record projection
pick b = case b of True -> Num | False -> Concat.

> chosen = pick True;
  print "runtime-chosen total = {total chosen [5,6,7]}".

# the record itself is an ordinary value
> print "Num.zero = {Num.zero}; direct field call = {Num.add 40 2}".
