# svm.sol — linear SVM by hinge-loss subgradient descent, Q16.16.
# Two gaussian-ish blobs, labels y in {-1,+1}. Per epoch, three folds
# accumulate the hinge subgradient (only margin violators contribute:
# a conditional inside the JITted element function); L2 regularization
# applied at the step. Weights ride as captured scalars.

fix = use "../lib/fix".
rnd = use "../lib/rand".

# class +1 centered (0.7, 0.5); class -1 centered (-0.6, -0.4): overlapping
mkRow s =
  s1 = rnd.next s;
  s2 = rnd.next4 s1;
  s3 = rnd.next4 s2;
  cls = rnd.uniform s3 2;
  cx = case cls == 1 of True -> 45875 | False -> 0 - 39321;
  cy = case cls == 1 of True -> 32768 | False -> 0 - 26214;
  {x1 = cx + rnd.gauss4 s1 / 2, x2 = cy + rnd.gauss4 s2 / 2,
   y = case cls == 1 of True -> 65536 | False -> 0 - 65536}.

fill v s k | k == 0 = v.
fill v s k = fill (Vec.push (mkRow (rnd.next (s + k * 100003))) v) s (k - 1).

score w1 w2 b x1 x2 = fix.fmul w1 x1 + fix.fmul w2 x2 + b.

# hinge subgradient: contributes -y*x only when y*score < 1
hW1 w1 w2 b acc p =
  acc + (case fix.fmul p.y (score w1 w2 b p.x1 p.x2) < 65536 of
    True -> 0 - fix.fmul p.y p.x1
  | False -> 0).
hW2 w1 w2 b acc p =
  acc + (case fix.fmul p.y (score w1 w2 b p.x1 p.x2) < 65536 of
    True -> 0 - fix.fmul p.y p.x2
  | False -> 0).
hB w1 w2 b acc p =
  acc + (case fix.fmul p.y (score w1 w2 b p.x1 p.x2) < 65536 of
    True -> 0 - p.y
  | False -> 0).

# accuracy: count of sign(score) == sign(y)
correct w1 w2 b acc p =
  acc + (case fix.fmul p.y (score w1 w2 b p.x1 p.x2) > 0 of True -> 1 | False -> 0).

lam = 655. # L2 lambda = 0.01

epoch n lr w1 w2 b v =
  (s1, v1) = Vec.fold (hW1 w1 w2 b) 0 v;
  (s2, v2) = Vec.fold (hW2 w1 w2 b) 0 v1;
  (s3, v3) = Vec.fold (hB w1 w2 b) 0 v2;
  w1n = w1 - fix.fmul lr (s1 / n + fix.fmul lam w1);
  w2n = w2 - fix.fmul lr (s2 / n + fix.fmul lam w2);
  (w1n, w2n, b - fix.fmul lr (s3 / n), v3).

train k n lr w1 w2 b v | k == 0 = (w1, w2, b, v).
train k n lr w1 w2 b v =
  (w1a, w2a, ba, v2) = epoch n lr w1 w2 b v;
  train (k - 1) n lr w1a w2a ba v2.

> n = 500;
  train_v = fill (Vec.new Unit) 424242 n;
  (w1, w2, b, v2) = train 200 n 39321 0 0 0 train_v;
  u0 = print "learned w = ({fix.toMilli w1}, {fix.toMilli w2}), b = {fix.toMilli b}";
  (tr, v3) = Vec.fold (correct w1 w2 b) 0 v2;
  u1 = print "train accuracy: {tr * 100 / n}%";
  u2 = Vec.free v3;
  test_v = fill (Vec.new Unit) 987651 200;
  (te, t2) = Vec.fold (correct w1 w2 b) 0 test_v;
  u3 = print "test accuracy: {te * 100 / 200}%";
  Vec.free t2.
