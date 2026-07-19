# physics.sol — ballistics ensemble in Q16.16 fixed point.
#
# N projectiles with varying launch velocities, each integrated by
# semi-implicit Euler with QUADRATIC drag (a = -c|v|v), until impact.
# The integrator `fly` — including fix.fmul and the 18-iteration Newton
# fix.fsqrt inside the hot loop — is an ordinary recursive Sol function;
# the JIT compiles the whole call closure alongside the dualized element
# function and runs it over the vector's unboxed columns.
#
# Verification: (1) the drag-free integrator matches the closed form
# R = 2·vx·vy/g to O(dt); (2) JIT and interpreter agree exactly (run with
# SOL_JIT=0 and diff).

fix = use "../lib/fix".

dt = 655.        # 0.01 s
g  = 642908.     # 9.81 m/s^2
cD = 131.        # drag coefficient 0.002 (quadratic)

upto a b | a > b = [].
upto a b = a :: upto (a + 1) b.

plus a b = a + b.

# integrate with drag; returns range (Q16.16 metres) at impact
fly x y vx vy | y < 0 = x.
fly x y vx vy =
  v  = fix.fsqrt (fix.fmul vx vx + fix.fmul vy vy);
  ax = 0 - fix.fmul cD (fix.fmul v vx);
  ay = 0 - g - fix.fmul cD (fix.fmul v vy);
  fly (x + fix.fmul vx dt) (y + fix.fmul vy dt) (vx + fix.fmul ax dt) (vy + fix.fmul ay dt).

# drag-free variant for the closed-form check
flyN x y vx vy | y < 0 = x.
flyN x y vx vy = flyN (x + fix.fmul vx dt) (y + fix.fmul vy dt) vx (vy - fix.fmul g dt).

rangeOf p = fly 0 0 p.vx p.vy.
rangeN p = flyN 0 0 p.vx p.vy.

# launch grid: vx 12..31 m/s, vy 8..27 m/s interleaved
mkRow i = {vx = fix.fromInt (12 + i - (i / 20) * 20), vy = fix.fromInt (8 + (i * 7 - ((i * 7) / 20) * 20))}.

fill v xs | xs == [] = v.
fill v xs = case xs of i :: r -> fill (Vec.push (mkRow i) v) r.

closedForm p = fix.fdiv (2 * fix.fmul p.vx p.vy) g.

> n = 40000;
  vec = fill (Vec.new Unit) (upto 1 n);

  # drag-free vs closed form on the first projectile
  (p1, vec2) = Vec.get 1 vec;
  u = print "closed form R = {fix.toMilli (closedForm p1)} mm-ish";
  u2 = print "integrated  R = {fix.toMilli (rangeN p1)} (drag-free, O(dt) error)";

  # the ensemble, WITH drag, on the SoA columns
  ranges = Vec.map rangeOf vec2;
  (total, r2) = Vec.fold plus 0 ranges;
  (best, r3) = Vec.fold fix.fmax 0 r2;
  u3 = print "n = {n}: mean range {fix.toMilli (total / n)} mm, best {fix.toMilli best} mm";
  Vec.free r3.
