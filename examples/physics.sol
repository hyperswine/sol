# physics.sol — ballistics ensemble on the Numeric datatype.
#
# N projectiles with varying launch velocities, each integrated by
# semi-implicit Euler with QUADRATIC drag (a = -c|v|v), until impact.
# dt, g, cD and every state variable are inexact Numerics; the integrator
# uses plain operators plus Numeric.sqrt — exactly the "conventional math
# on the default number type" this example always wanted to be.
#
# Verification: the drag-free integrator matches the closed form
# R = 2*vx*vy/g to O(dt), asserted below with a tolerance chk.
#
# JIT note: the ensemble map compiles natively — the recursive `fly`
# integrator, Numeric.sqrt intrinsic included, specializes over the int
# launch columns with f64 state (per-callsite typed variants). SOL_JIT=0
# agrees bit-for-bit.

dt = Numeric.div 1 100.     # 0.01 s
g  = Numeric.div 981 100.   # 9.81 m/s^2
cD = Numeric.div 2 1000.    # drag coefficient 0.002 (quadratic)

upto a b | a > b = [].
upto a b = a :: upto (a + 1) b.

plus a b = a + b.

# integrate with drag; returns range (metres) at impact
fly x y vx vy | y < 0 = x.
fly x y vx vy =
  v  = Numeric.sqrt (vx * vx + vy * vy);
  ax = 0 - cD * (v * vx);
  ay = 0 - g - cD * (v * vy);
  fly (x + vx * dt) (y + vy * dt) (vx + ax * dt) (vy + ay * dt).

# drag-free variant for the closed-form check
flyN x y vx vy | y < 0 = x.
flyN x y vx vy = flyN (x + vx * dt) (y + vy * dt) vx (vy - g * dt).

rangeOf p = fly (Numeric.inexact 0) (Numeric.inexact 0) p.vx p.vy.
rangeN p = flyN (Numeric.inexact 0) (Numeric.inexact 0) p.vx p.vy.

# launch grid: vx 12..31 m/s, vy 8..27 m/s interleaved (ints promote on use)
mkRow i = {vx = 12 + i - (i / 20) * 20, vy = 8 + (i * 7 - ((i * 7) / 20) * 20)}.

fill v xs | xs == [] = v.
fill v xs = case xs of i :: r -> fill (Vec.push (mkRow i) v) r.

closedForm p = 2 * p.vx * p.vy / g.

fmax a b = case a > b of True -> a | False -> b.

chkClose name got want tol = case Numeric.abs (got - want) < tol of
  True -> print "ok {name} ({got} ~ {want})"
| False -> error "FAIL {name}: {got} vs {want}".

> n = 300;
  vec = fill (Vec.new Unit) (upto 1 n);
  (p1, vec2) = Vec.get 1 vec;
  u = print "closed form R = {closedForm p1} m";
  u2 = print "integrated  R = {rangeN p1} m (drag-free, O(dt) error)";
  c1 = chkClose "drag-free vs closed form" (rangeN p1) (closedForm p1) 1;
  ranges = Vec.map rangeOf vec2;
  (total, r2) = Vec.fold plus 0 ranges;
  (best, r3) = Vec.fold fmax (Numeric.inexact 0) r2;
  u3 = print "n = {n}: mean range {total / n} m, best {best} m";
  Vec.free r3.
