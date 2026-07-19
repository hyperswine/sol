# structs.sol — the stdlib sigs/structs and row-dispatched operators.
#
# `+` is resolved by OPERAND TYPE at compile time: Int -> primitive opcode,
# String -> Str.+, List -> List.+, sig-carrier -> s.(+) (then monomorphized
# per struct by the specializer). No ++: one `+`, row polymorphism does it.

# ---- operator dispatch on concrete types ------------------------------------

> print (1 + 2).
> print ("con" + "cat").
> print (str ([1,2] + [3,4])).

# ---- <structure>.<symbol> utilities -----------------------------------------

> n = Str.len "hello"; print "Str.len = {n}".
> print "List.len = {List.len [10,20,30]}".
> print "List.rev = {str (List.rev [1,2,3])}".
> print "List.map = {str (List.map (fn x -> x * x) [1,2,3])}".
> print "List.find = {str (List.find (fn x -> x > 1) [1,2,3])}".
> print "groupby parity = {str (List.groupby (fn x -> x - (x / 2) * 2) [1,2,3,4,5])}".
> print "Numeric.clamp = {Numeric.clamp 0 10 42}".

# ---- generics over the sigs -------------------------------------------------

# `a + b` at the CARRIER type resolves to s.(+); one definition serves
# Numeric, Str, and List (all satisfy Add — Numeric via Arith, structurally)
total (s : Add) xs = List.fold (fn a b -> a + b) s.zero xs.

> print "total Numeric = {total Numeric [1,2,3,4]}".
> t = total Str ["so", "l", "!"]; print "total Str = {t}".
> print "total List = {str (total List [[1],[2,3],[4]])}".

# Arith generic: `k * x` at the carrier type resolves to s.(*) — the
# operator IS the row-polymorphic call, no explicit projection needed
scaleSum (s : Arith) k xs = total s (List.map (fn x -> k * x) xs).

> print "scaleSum Numeric 10 [1,2,3] = {scaleSum Numeric 10 [1,2,3]}".

# runtime struct choice: HM unifies the case arms, so the structs must
# share BOTH carrier and field set (closed rows unify by label equality
# — width subtyping applies where an OPEN row meets a closed one, i.e.
# at `total`'s sig param, not between two concrete records)
MaxN = Struct Add { (+) = fn a b -> Numeric.max a b, zero = 0 - 999999 }.
MinN = Struct Add { (+) = fn a b -> Numeric.min a b, zero = 999999 }.
pickI b = case b of True -> MinN | False -> MaxN.

> chosen = pickI False;
  print "runtime max-fold = {total chosen [3, 9, 4]}".
