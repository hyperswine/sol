#!/bin/bash
# Negative tests: these MUST be rejected at compile time. Exit 0 iff all are.
# NOTE the design boundary these encode: linearity is ANNOTATION-DRIVEN at
# function boundaries. An unannotated `f v = 42.` receiving a Vector is NOT
# an error today (the param's linearity is unknown) — see TESTING.md.
cd "$(dirname "$0")/../.."
fail=0
t() {
  printf '%s' "$3" > /tmp/neg.sol
  out=$(./sol /tmp/neg.sol 2>&1)
  if echo "$out" | grep -q "$2"; then echo "ok $1"; else echo "FAIL $1 — got: $(echo "$out" | head -2)"; fail=1; fi
}
t "double-use of linear" "LINEARITY" '
f v = (n, v2) = Vec.len v; (m, v3) = Vec.len v; n + m.
> print (f (Vec.fromList [1])).
'
t "leaked linear (annotated param)" "LINEARITY" '
f : Vector -> Int.
f v = 42.
> print (f (Vec.fromList [1])).
'
t "linear consumed in guard (annotated)" "guard uses linear" '
f : Vector -> Int.
f v | Vec.toList v == [] = 0.
f v = List.len (Vec.toList v).
> print (f (Vec.fromList [1])).
'
t "case branches consume unequally" "LINEARITY" '
f : Vector -> Int.
lenFree v = (n, v2) = Vec.len v; u = Vec.free v2; n.
f v = case 1 == 1 of True -> lenFree v | False -> 0.
> print (f (Vec.fromList [1])).
'
t "matrix leak through constructor" "LINEARITY" '
Matrix 1 = Type (Mat Int Int Vector).
f m = Mat r c v = m; r.
> print (f (Mat 1 1 (Vec.fromList [1]))).
'
t "matrix payload double-use" "LINEARITY" '
Matrix 1 = Type (Mat Int Int Vector).
f m = Mat r c v = m; (a, v2) = Vec.len v; (b, v3) = Vec.len v; a + b.
> print (f (Mat 1 1 (Vec.fromList [1]))).
'
t "handle leak (examples/bad_leak)" "LINEARITY" "$(cat examples/bad_leak.sol)"
t "handle double-use (examples/bad_double)" "LINEARITY" "$(cat examples/bad_double.sol)"
exit $fail
