# linreg.sol — linear regression by full-batch gradient descent, Q16.16.
# Data: y = 1.75*x1 - 0.5*x2 + 0.25 + noise. Each epoch runs three
# JIT-compiled folds over the SoA columns; the CURRENT weights ride into
# native code as captured scalars (the partial-application tier), so one
# compilation serves every epoch.

fix = use "../lib/fix".
rnd = use "../lib/rand".

trueW1 = 114688.   #  1.75
trueW2 = 0 - 32768. # -0.5
trueB  = 16384.    #  0.25

mkRow s =
  s1 = rnd.next s; s2 = rnd.next s1; s3 = rnd.next s2;
  x1 = rnd.unitQ s1; x2 = rnd.unitQ s2;
  noise = rnd.gauss4 s3 / 20;
  {x1 = x1, x2 = x2, y = fix.fmul trueW1 x1 + fix.fmul trueW2 x2 + trueB + noise}.

fill v s k | k == 0 = v.
fill v s k = fill (Vec.push (mkRow (rnd.next (s + k * 100003))) v) s (k - 1).

# residual and per-parameter gradient contributions (weights captured).
# JIT rule of thumb: project the element ONLY in the scheme function;
# helpers take scalars (the dual can pass column loads as plain ints).
resid w1 w2 b x1 x2 y = fix.fmul w1 x1 + fix.fmul w2 x2 + b - y.
gW1 w1 w2 b acc p = acc + fix.fmul (resid w1 w2 b p.x1 p.x2 p.y) p.x1.
gW2 w1 w2 b acc p = acc + fix.fmul (resid w1 w2 b p.x1 p.x2 p.y) p.x2.
gB  w1 w2 b acc p = acc + resid w1 w2 b p.x1 p.x2 p.y.
sqErr w1 w2 b acc p = r = resid w1 w2 b p.x1 p.x2 p.y; acc + fix.fmul r r.

plus a b = a + b.

# one epoch: three gradient folds, weights step by lr * grad / n
epoch n lr w1 w2 b v =
  (s1, v1) = Vec.fold (gW1 w1 w2 b) 0 v;
  (s2, v2) = Vec.fold (gW2 w1 w2 b) 0 v1;
  (s3, v3) = Vec.fold (gB w1 w2 b) 0 v2;
  (w1 - fix.fmul lr (s1 / n), w2 - fix.fmul lr (s2 / n), b - fix.fmul lr (s3 / n), v3).

train k n lr w1 w2 b v | k == 0 = (w1, w2, b, v).
train k n lr w1 w2 b v =
  (w1a, w2a, ba, v2) = epoch n lr w1 w2 b v;
  train (k - 1) n lr w1a w2a ba v2.

> n = 600;
  train_v = fill (Vec.new Unit) 20260716 n;
  (w1, w2, b, v2) = train 150 n 52428 0 0 0 train_v;
  u1 = print "learned  w1 {fix.toMilli w1}  w2 {fix.toMilli w2}  b {fix.toMilli b}";
  u2 = print "true     w1 {fix.toMilli trueW1}  w2 {fix.toMilli trueW2}  b {fix.toMilli trueB}";

  # held-out test set from a different seed
  test_v = fill (Vec.new Unit) 777991 200;
  (sse, t2) = Vec.fold (sqErr w1 w2 b) 0 test_v;
  u3 = print "test MSE {fix.toMilli (sse / 200)} (noise var ~ 3)";
  u4 = Vec.free t2;
  Vec.free v2.
