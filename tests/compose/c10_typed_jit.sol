# c10_typed_jit.sol — the typed (f64) JIT tier. Every fold here is long
# enough to clear the JIT threshold; expected values are exact IEEE
# doubles (spelled as Numeric fractions — Sol has no float literals), so
# this test FAILS if native and interpreted arithmetic ever drift. Run
# with SOL_JIT=0 to cross-check: outputs must be identical.

chk name got want = case got == want of
  True -> print "ok {name}"
| False -> error "FAIL {name}: {got} vs {want}".

upto a b | a > b = [].
upto a b = a :: upto (a + 1) b.

mkRow i = {d = Numeric.div i 8, n = i}.
fill v xs | xs == [] = v.
fill v xs = case xs of i :: r -> fill (Vec.push (mkRow i) v) r.

# 1) inexact fold over a d column, int acc seed (the widened-acc case)
sumd acc p = acc + p.d.

# 2) int-column arithmetic must stay QUOT inside native code (7/2 = 3)
sumq acc p = acc + p.n / 2.

# 3) Num intrinsics in native code: floor(sqrt(n)) summed
sfl acc p = acc + Numeric.floor (Numeric.sqrt p.n).

# 4) captured inexact scalar (f64 extras) + promoted comparison
above t acc p = acc + (case p.d > t of True -> 1 | False -> 0).

# 5) list tier with all-double elements
half x = Numeric.div x 1 / 2.
plus a b = a + b.

> v = fill (Vec.new Unit) (upto 1 100);
  (s1, v1) = Vec.fold sumd 0 v;
  c1 = chk "typed fold widened acc" s1 (Numeric.div 2525 4);
  (s2, v2) = Vec.fold sumq 0 v1;
  c2 = chk "quot preserved in native" s2 2500;
  (s3, v3) = Vec.fold sfl 0 v2;
  c3 = chk "sqrt/floor intrinsics" s3 625;
  (s4, v4) = Vec.fold (above (Numeric.div 25 2)) 0 v3;
  c4 = chk "captured f64 scalar (none above)" s4 0;
  (s4b, v5) = Vec.fold (above (Numeric.div 25 4)) 0 v4;
  c4b = chk "captured f64 scalar (half above)" s4b 50;
  u = Vec.free v5;
  ds = List.map half (upto 1 100);
  s5 = List.fold plus 0 ds;
  c5 = chk "list tier doubles" s5 2525;
  print "typed jit ok".
