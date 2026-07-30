# csvmatrix.sol — Sol as the everyday-python replacement, exercised:
# generate two random CSVs, read them back into the linear Matrix
# (lib/matrix.sol — a 2D SoA Vector), then head / select / map / matmul /
# matvec / column means, and write the result CSV — all inside the one
# script transaction, so the output files exist complete or not at all.
#
#   sol examples/csvmatrix.sol
#
# Everything numeric is Numeric: the generated CSVs are exact ints, and
# decimals only appear where Numeric.div introduced them (the means row).

mx  = use "../lib/matrix".  M    = mx.M.
rnd = use "../lib/rand".    Rand = rnd.Rand.
base = use "../lib/base".

dir = "/tmp/sol-csv".

# ---- 1. generate two random integer CSVs ----------------------------------

# a row of n uniform ints in [0, 100), threading the LCG state
randRow s n | n == 0 = (s, []).
randRow s n =
  s2 = Rand.next s;
  (s3, xs) = randRow s2 (n - 1);
  (s3, Rand.uniform s2 100 :: xs).

randRows s r c | r == 0 = [].
randRows s r c =
  (s2, xs) = randRow s c;
  xs :: randRows s2 (r - 1) c.

genCsv path seed r c hs =
  m = M.fromRows (randRows seed r c);
  (txt, m2) = M.toCsvHeader hs m;
  u = writePath path txt;
  u2 = M.free m2;
  print "wrote {path} ({r}x{c})".

# ---- 2. read back + poke around -------------------------------------------

showHead label n m =
  (h, m2) = M.head n m;
  (s, h2) = M.show h;
  u = M.free h2;
  u2 = print "{label} — first {n} rows: {s}";
  m2.

> u0 = mkdirp @/tmp/sol-csv;
  u1 = genCsv "{dir}/a.csv" 42 6 4 ["p", "q", "r", "s"];
  u2 = genCsv "{dir}/b.csv" 1337 4 3 ["x", "y", "z"];

  (ha, a) = M.fromCsvHeader (readPath "{dir}/a.csv");
  (hb, b) = M.fromCsvHeader (readPath "{dir}/b.csv");
  u3 = print "a header: {ha}   b header: {hb}";

  a2 = showHead "a" 3 a;

  # select: rows [1,3,5] and cols [p, r] (= 1, 3) of a
  (sel, a3) = M.selectRows [1, 3, 5] a2;
  (sel2, sel3) = M.selectCols [1, 3] sel;
  u4 = M.free sel3;
  (selS, sel4) = M.show sel2;
  u5 = print "a rows [1,3,5] x cols [p,r]: {selS}";
  u6 = M.free sel4;

  # elementwise map — one Vec.map over the cells column (the JIT path)
  centered = M.map (fn x -> x - 50) a3;

  # row/col maps: double row 2, zero col 4
  tweaked = M.mapCol 4 (fn x -> 0) (M.mapRow 2 (fn x -> x * 2) centered);
  t2 = showHead "centered/tweaked a" 3 tweaked;

  # matmul: a (6x4) * a^T (4x6) -> gram (6x6); operands thread back out
  at = M.transpose t2;
  (gram, t3, at2) = M.mul t2 at;
  u7 = M.free at2;
  g2 = showHead "gram = a * a^T" 2 gram;

  # matvec
  (mv, t4) = M.mulVec t3 [1, 0, 0 - 1, 2];
  u8 = print "a * [1,0,-1,2] = {mv}";

  # column means: Numeric.div makes these inexact, and it PROPAGATES
  (means, t5) = M.colMeans t4;
  u9 = print "col means of tweaked a: {means}";
  u10 = M.free t5;
  u11 = M.free b;

  # ---- 3. write the result CSV (transactionally) --------------------------
  (out, g3) = M.toCsvHeader ["g1", "g2", "g3", "g4", "g5", "g6"] g2;
  u12 = writePath "{dir}/gram.csv" out;
  u13 = M.free g3;
  print "wrote {dir}/gram.csv".

# ---- 4. big-matrix path: prove the cells column hits the JIT -------------
sq a b = a + b * b.

> big = M.fromRows (randRows 7 50000 3);
  bsq = M.map (fn x -> x * x) big;
  (ss, b2) = M.fold (fn acc x -> acc + x) 0 bsq;
  u = print "sum of squares over 50000x3: {ss}";
  M.free b2.

> (gh, g) = M.fromCsvHeader (readPath "{dir}/gram.csv");
  g2 = showHead "gram re-read (header {gh})" 2 g;
  u = M.free g2;
  print "csvmatrix done".
