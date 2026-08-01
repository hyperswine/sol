# svm.sol — linear SVM by subgradient descent on the hinge loss, on the
# Numeric datatype. Two gaussian blobs, margin 1; features, weights, and
# the L2 lambda are inexact Numerics and every score/update is plain
# operators — the hinge comparison `y*score < 1` needs no scaled "one".

rnd = use "../lib/rand".
Rand = rnd.Rand.

mkRow s =
  s1 = Rand.next s;
  s2 = Rand.next4 s1;
  s3 = Rand.next4 s2;
  cls = Rand.uniform s3 2;
  cx = case cls == 0 of True -> 0 - 1 | False -> 1;
  cy = case cls == 0 of True -> 0 - 1 | False -> 1;
  {x1 = cx + Rand.gauss4 s1 / 2, x2 = cy + Rand.gauss4 s2 / 2,
    y = case cls == 0 of True -> 0 - 1 | False -> 1}.

fill v s k | k == 0 = v.
fill v s k = fill (Vec.push (mkRow (Rand.next (s + k * 100003))) v) s (k - 1).

score w1 w2 b x1 x2 = w1 * x1 + w2 * x2 + b.

# hinge subgradients: contribute only where the margin is violated
hW1 w1 w2 b acc p =
  acc + (case p.y * score w1 w2 b p.x1 p.x2 < 1 of
    True -> 0 - p.y * p.x1
  | False -> Numeric.inexact 0).
hW2 w1 w2 b acc p =
  acc + (case p.y * score w1 w2 b p.x1 p.x2 < 1 of
    True -> 0 - p.y * p.x2
  | False -> Numeric.inexact 0).
hB w1 w2 b acc p =
  acc + (case p.y * score w1 w2 b p.x1 p.x2 < 1 of
    True -> 0 - p.y
  | False -> Numeric.inexact 0).

# accuracy: count of sign(score) == sign(y)
correct w1 w2 b acc p =
  acc + (case p.y * score w1 w2 b p.x1 p.x2 > 0 of True -> 1 | False -> 0).

lam = Numeric.div 1 100. # L2 lambda = 0.01

epoch n lr w1 w2 b v =
  (s1, v1) = Vec.fold (hW1 w1 w2 b) 0 v;
  (s2, v2) = Vec.fold (hW2 w1 w2 b) 0 v1;
  (s3, v3) = Vec.fold (hB w1 w2 b) 0 v2;
  w1n = w1 - lr * (s1 / n + lam * w1);
  w2n = w2 - lr * (s2 / n + lam * w2);
  (w1n, w2n, b - lr * (s3 / n), v3).

train k n lr w1 w2 b v | k == 0 = (w1, w2, b, v).
train k n lr w1 w2 b v =
  (w1a, w2a, ba, v2) = epoch n lr w1 w2 b v;
  train (k - 1) n lr w1a w2a ba v2.

chkAtLeast name got want = case got >= want of
  True -> print "ok {name} ({got} >= {want})"
| False -> error "FAIL {name}: {got} < {want}".

> n = 300;
  lr = Numeric.div 6 10;
  train_v = fill (Vec.new Unit) 424242 n;
  (w1, w2, b, v2) = train 80 n lr 0 0 0 train_v;
  u0 = print "learned w = ({w1}, {w2}), b = {b}";
  (tr, v3) = Vec.fold (correct w1 w2 b) 0 v2;
  u1 = print "train accuracy: {tr * 100 / n}%";
  c1 = chkAtLeast "train accuracy %" (tr * 100 / n) 90;
  u2 = Vec.free v3;
  test_v = fill (Vec.new Unit) 987651 150;
  (te, t2) = Vec.fold (correct w1 w2 b) 0 test_v;
  u3 = print "test accuracy: {te * 100 / 150}%";
  c2 = chkAtLeast "test accuracy %" (te * 100 / 150) 90;
  Vec.free t2.
