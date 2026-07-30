# matrix.sol — a 2D Numeric matrix over the linear SoA Vector, plus CSV in
# and out. Row-major cells live in ONE Vec column, so elementwise maps go
# through Vec.map and hit the typed JIT tier; indexed work (matmul,
# row/col selection) threads the Vec through get/set the same way the
# Prolog engine threads its heap.
#
#   Matrix 1 = Type (Mat Int Int Vector)
#
# The wrapper is LINEAR and the Vector field is DECLARED (not a bare type
# var), so the checker tracks the payload: dropping a matrix, using one
# twice, or leaking the Vec out of a destructure is a compile error.
# Interrogations thread — (x, Matrix) back, same shape as Vec.len.
#
#   mx = use "../lib/matrix". M = mx.M.
#
# Values are Numeric: integer CSVs stay exact bignums; inexactness enters
# only through Numeric.div (M.colMeans) and then propagates, Julia-style.
#
# Style per STYLE.md: the work lives in top-level clause functions (case
# arms are expressions, so anything needing binds is a clause with
# guards); the Struct is the thin public surface.

base = use "base".

Matrix 1 = Type (Mat Int Int Vector).

# ---- construction ----------------------------------------------------------

mFromRows rss | rss == [] = Mat 0 0 (Vec.new Unit).
mFromRows rss =
  r0 :: _ = rss;
  c = List.len r0;
  Mat (List.len rss) c (Vec.fromList (mFlatten c rss)).

# ragged input is the caller's bug: the first row's width is the contract,
# and a mismatch panics rather than silently mis-indexing every later cell
mFlatten c rss | rss == [] = [].
mFlatten c rss | (r :: _) <- rss, List.len r != c =
  error "matrix: ragged row ({List.len r} fields vs {c})".
mFlatten c rss = r :: rest = rss; List.append r (mFlatten c rest).

mRep n x | n == 0 = [].
mRep n x = x :: mRep (n - 1) x.

mIota n = mIotaFrom 1 n.
mIotaFrom i n | i > n = [].
mIotaFrom i n = i :: mIotaFrom (i + 1) n.

# ---- interrogation (threads, like Vec.len) ---------------------------------

mDims m = Mat r c v = m; (r, c, Mat r c v).

mGet i j m =
  Mat r c v = m;
  (x, v2) = Vec.get ((i - 1) * c + j) v;
  (x, Mat r c v2).

mSet i j x m =
  Mat r c v = m;
  Mat r c (Vec.set ((i - 1) * c + j) x v).

# n cells starting at k, striding s (shared by row and col)
mGather k s n v | n == 0 = ([], v).
mGather k s n v =
  (x, v2) = Vec.get k v;
  (xs, v3) = mGather (k + s) s (n - 1) v2;
  (x :: xs, v3).

mRow i m =
  Mat r c v = m;
  (xs, v2) = mGather ((i - 1) * c + 1) 1 c v;
  (xs, Mat r c v2).

mCol j m =
  Mat r c v = m;
  (xs, v2) = mGather j c r v;
  (xs, Mat r c v2).

# rows by 1-based index, in the order given, as lists
mRowsAt is m | is == [] = ([], m).
mRowsAt is m =
  i :: rest = is;
  (xs, m2) = mRow i m;
  (rss, m3) = mRowsAt rest m2;
  (xs :: rss, m3).

mAllRows m = (r, c, m2) = mDims m; mRowsAt (mIota r) m2.

# ---- selection (new matrix out, source threads back) -----------------------

mSelectRows is m = (rss, m2) = mRowsAt is m; (mFromRows rss, m2).

mHead n m =
  (r, c, m2) = mDims m;
  mSelectRows (mIota (Numeric.min n r)) m2.

mPicks js xs | js == [] = [].
mPicks js xs = j :: rest = js; xs ! j :: mPicks rest xs.

mSelectCols js m =
  (rss, m2) = mAllRows m;
  (mFromRows (map (fn xs -> mPicks js xs) rss), m2).

# ---- maps ------------------------------------------------------------------

# elementwise: ONE Vec.map over the cells column — this is the JIT path
mMap f m = Mat r c v = m; Mat r c (Vec.map f v).

mOverStride k s n f v | n == 0 = v.
mOverStride k s n f v =
  (x, v2) = Vec.get k v;
  mOverStride (k + s) s (n - 1) f (Vec.set k (f x) v2).

mMapRow i f m = Mat r c v = m; Mat r c (mOverStride ((i - 1) * c + 1) 1 c f v).
mMapCol j f m = Mat r c v = m; Mat r c (mOverStride j c r f v).

# every row-as-list to a value: [f (row 1), ..., f (row r)]
mMapRows f m = (rss, m2) = mAllRows m; (map f rss, m2).

# ---- algebra ---------------------------------------------------------------

mDot xs ys | xs == [] = 0.
mDot xs ys = x :: xr = xs; y :: yr = ys; x * y + mDot xr yr.

mSum xs | xs == [] = 0.
mSum xs = x :: r = xs; x + mSum r.

mTRows c rss | c == 0 = [].
mTRows c rss =
  map (fn xs -> xs ! 1) rss :: mTRows (c - 1) (map (fn xs -> base.removeAt 1 xs) rss).

mTranspose m =
  (r, c, m2) = mDims m;
  (rss, m3) = mAllRows m2;
  u = mFree m3;
  mFromRows (mTRows c rss).

# matvec: m (r x c) * xs (length c) -> (list of length r, m)
mMulVec m xs =
  (r, c, m2) = mDims m;
  u = mLenGuard (List.len xs) c;
  (rss, m3) = mAllRows m2;
  (map (fn row -> mDot row xs) rss, m3).

mLenGuard n c | n == c = 0.
mLenGuard n c = error "matrix: operand length {n} vs {c} cols".

# matmul: a (r x k) * b (k x c) -> (new r x c, a, b)
mMul a b =
  (ra, ka, a2) = mDims a;
  (kb, cb, b2) = mDims b;
  u = mMulGuard ra ka kb cb;
  (arows, a3) = mAllRows a2;
  (brows, b3) = mAllRows b2;
  bcols = mTRows cb brows;
  (mFromRows (map (fn ar -> map (fn bc -> mDot ar bc) bcols) arows), a3, b3).

mMulGuard ra ka kb cb | ka == kb = 0.
mMulGuard ra ka kb cb = error "matrix: mul {ra}x{ka} * {kb}x{cb} inner dims differ".

# column means: Numeric.div is where inexactness (deliberately) enters
mColMeans m =
  (r, c, m2) = mDims m;
  (rss, m3) = mAllRows m2;
  (map (fn s -> Numeric.div s r) (mColSumsOf c rss), m3).

mColSumsOf c rss | c == 0 = [].
mColSumsOf c rss | rss == [] = mRep c 0.
mColSumsOf c rss = map (fn col -> mSum col) (mTRows c rss).

mFree m = Mat r c v = m; Vec.free v.

# fold over the cells column, row-major — with map, the JIT pair
mFold f z m = Mat r c v = m; (x, v2) = Vec.fold f z v; (x, Mat r c v2).

# ---- CSV -------------------------------------------------------------------

mCsvLines s = filter (fn l -> base.not2 (l == "")) (base.splitCh 10 s).
mParseRow line = map (fn f -> base.pI f) (base.splitCh 44 line).

# integer cells; blank lines ignored
mFromCsv s = mFromRows (map (fn l -> mParseRow l) (mCsvLines s)).

# first line is a header: (headerFields, matrix)
mFromCsvHeader s | mCsvLines s == [] = ([], mFromRows []).
mFromCsvHeader s =
  h :: rest = mCsvLines s;
  (base.splitCh 44 h, mFromRows (map (fn l -> mParseRow l) rest)).

mJoinC xs | xs == [] = "".
mJoinC xs | (x :: rest) <- xs, rest == [] = "{x}".
mJoinC xs = x :: rest = xs; "{x},{mJoinC rest}".

# render through BStr: an interpolation fold over a big matrix is the
# exact O(n^2) VStr trap the BStr tier exists for
mCsvRows rss b | rss == [] = b.
mCsvRows rss b = xs :: rest = rss; mCsvRows rest (BStr.append "{mJoinC xs}{base.nl}" b).

mToCsv m =
  (rss, m2) = mAllRows m;
  (BStr.toStr (mCsvRows rss (BStr.new Unit)), m2).

mToCsvHeader hs m = (body, m2) = mToCsv m; ("{mJoinC hs}{base.nl}{body}", m2).

# ---- show (debug printing) -------------------------------------------------

mShowRows rss | rss == [] = "".
mShowRows rss = xs :: rest = rss; "  [{mJoinC xs}]{base.nl}{mShowRows rest}".

mShow m =
  (r, c, m2) = mDims m;
  (rss, m3) = mAllRows m2;
  ("{r}x{c}{base.nl}{mShowRows rss}", m3).

# ---- the public surface ----------------------------------------------------

M = Struct {
  fromRows   = fn rss -> mFromRows rss,
  fill       = fn r c x -> Mat r c (Vec.fromList (mRep (r * c) x)),
  free       = fn m -> mFree m,
  dims       = fn m -> mDims m,
  get        = fn i j m -> mGet i j m,
  set        = fn i j x m -> mSet i j x m,
  row        = fn i m -> mRow i m,
  col        = fn j m -> mCol j m,
  head       = fn n m -> mHead n m,
  selectRows = fn is m -> mSelectRows is m,
  selectCols = fn js m -> mSelectCols js m,
  map        = fn f m -> mMap f m,
  fold       = fn f z m -> mFold f z m,
  mapRow     = fn i f m -> mMapRow i f m,
  mapCol     = fn j f m -> mMapCol j f m,
  mapRows    = fn f m -> mMapRows f m,
  transpose  = fn m -> mTranspose m,
  mulVec     = fn m xs -> mMulVec m xs,
  mul        = fn a b -> mMul a b,
  colMeans   = fn m -> mColMeans m,
  fromCsv    = fn s -> mFromCsv s,
  fromCsvHeader = fn s -> mFromCsvHeader s,
  toCsv      = fn m -> mToCsv m,
  toCsvHeader = fn hs m -> mToCsvHeader hs m,
  show       = fn m -> mShow m
}.
