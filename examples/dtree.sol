# dtree.sol — decision tree (depth 2) on an axis-aligned concept:
# y = +1 iff (x1 > 0.25 AND x2 > -0.5), 5% label noise — a nested-rectangle
# rule that greedy induction recovers exactly (root split on x1, then x2).
# Honest ML footnote: we first tried XOR (y = sign(x1*x2)); every root
# split has ~zero first-order gain there, so greedy scan picks on noise and
# depth 2 collapses to ~52% — the classic greedy-tree pathology, faithfully
# reproduced. Trees need lookahead (or luck) for XOR; that is the
# algorithm, not the runtime.
#
# The hot part is split search: for each candidate (feature, threshold),
# ONE JITted fold packs all four class counts (left/right x pos/neg) into
# a single i64 base-1024, with (feat, thresh) riding as captured scalars —
# one native compilation serves every candidate at every node. Tree
# building, partitioning, and prediction are interpreted structure work
# over a recursive ADT.

fix = use "../lib/fix".
rnd = use "../lib/rand".

Tree = Type (Leaf x | Node a b c d). # Node feat thresh left right

mkRow s =
  sa = rnd.next s;
  x1 = rnd.gauss4 sa;
  sb = rnd.next4 sa;
  x2 = rnd.gauss4 sb;
  sc = rnd.next4 sb;
  flip = rnd.uniform sc 20; # 5% label noise
  ytrue = case x1 > 16384 of
    False -> 0 - 65536
  | True -> (case x2 > (0 - 32768) of True -> 65536 | False -> 0 - 65536);
  {x1 = x1, x2 = x2, y = case flip == 0 of True -> 0 - ytrue | False -> ytrue}.

fill v s k | k == 0 = v.
fill v s k = fill (Vec.push (mkRow (rnd.next (s + k * 100003))) v) s (k - 1).

imod a b = a - (a / b) * b.

# the packed counting fold: (feat, th) captured; four counts in one i64
cnt feat th acc p =
  xv = case feat == 1 of True -> p.x1 | False -> p.x2;
  pos = case p.y > 0 of True -> 1 | False -> 0;
  case xv < th of
    True -> acc + (case pos == 1 of True -> 1073741824 | False -> 1048576)
  | False -> acc + (case pos == 1 of True -> 1024 | False -> 1).

posCnt acc p = acc + (case p.y > 0 of True -> 1 | False -> 0).

imin a b = case a < b of True -> a | False -> b.

# misclassification score of a split: each side predicts its majority
scoreOf c =
  lp = c / 1073741824; ln = imod (c / 1048576) 1024;
  rp = imod (c / 1024) 1024; rn = imod c 1024;
  imin lp ln + imin rp rn.

# scan candidates, threading the linear vec; returns (feat, th, score, v)
scan cands bf bt bs v | cands == [] = (bf, bt, bs, v).
scan cands bf bt bs v = case cands of
  c :: rest -> scanStep c rest bf bt bs v.

scanStep c rest bf bt bs v =
  (feat, th) = c;
  (packed, v2) = Vec.fold (cnt feat th) 0 v;
  s = scoreOf packed;
  case s < bs of
    True -> scan rest feat th s v2
  | False -> scan rest bf bt bs v2.

grid k | k > 6 = [].
grid k = (k * 16384) :: grid (k + 1). # -1.5 .. 1.5 step 0.25

cands1 f ts | ts == [] = [].
cands1 f ts = case ts of t :: r -> (f, t) :: cands1 f r.
allCands = cands1 1 (grid (0 - 6)) `append` cands1 2 (grid (0 - 6)).

append xs ys | xs == [] = ys.
append xs ys = case xs of x :: r -> x :: append r ys.

pick feat p = case feat == 1 of True -> p.x1 | False -> p.x2.

part feat th xs ls rs | xs == [] = (ls, rs).
part feat th xs ls rs = case xs of
  p :: r -> (case pick feat p < th of
    True -> part feat th r (p :: ls) rs
  | False -> part feat th r ls (p :: rs)).

buildVec xs v | xs == [] = v.
buildVec xs v = case xs of p :: r -> buildVec r (Vec.push p v).

listLen xs = List.fold len1 0 xs.
len1 a x = a + 1.

majorityLeaf n np = Leaf (case np * 2 >= n of True -> 65536 | False -> 0 - 65536).

# recursive build: JITted scan for the split, interpreted partition
build depth v =
  (n, v0) = Vec.len v;
  (np, v1) = Vec.fold posCnt 0 v0;
  case depth == 0 of
    True -> finishLeaf n np v1
  | False -> tryNode depth n np v1.

finishLeaf n np v = u = Vec.free v; majorityLeaf n np.

tryNode depth n np v =
  case np == 0 of
    True -> finishLeaf n np v
  | False -> (case np == n of
      True -> finishLeaf n np v
    | False -> splitNode depth n v).

splitNode depth n v =
  (bf, bt, bs, v2) = scan allCands 0 0 999999 v;
  xs = Vec.toList v2;
  (ls, rs) = part bf bt xs [] [];
  l = build (depth - 1) (buildVec ls (Vec.new Unit));
  r = build (depth - 1) (buildVec rs (Vec.new Unit));
  Node bf bt l r.

predict t p = case t of
  Leaf c -> c
| Node f th l r -> (case pick f p < th of True -> predict l p | False -> predict r p).

accGo t xs k | xs == [] = k.
accGo t xs k = case xs of
  p :: r -> accGo t r (k + (case fix.fmul (predict t p) p.y > 0 of True -> 1 | False -> 0)).

showT t = case t of
  Leaf c -> "Leaf({fix.toMilli c})"
| Node f th l r -> "Node(x{f} < {fix.toMilli th}: {showT l} | {showT r})".

> n = 600;
  train_v = fill (Vec.new Unit) 13371337 n;
  tree = build 2 train_v;
  u0 = print "tree: {showT tree}";
  test_v = fill (Vec.new Unit) 55667788 300;
  xs = Vec.toList test_v;
  acc = accGo tree xs 0;
  print "test accuracy: {acc * 100 / 300}% (5% label noise ceiling ~95%)".
