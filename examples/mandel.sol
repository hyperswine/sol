# mandel.sol — Mandelbrot on the Numeric datatype. Coordinates are inexact
# Numerics born from Numeric.div; the escape iteration uses plain *, +, >
# throughout — promotion carries inexactness, escape counts stay Ints.
# (The former Q16.16 version is gone: no fix library, no manual scaling.)
#
# JIT note: the typed tier compiles the per-pixel map natively — the
# complex-square recursion specializes per callsite (int seed iteration
# widening into f64 state), with the inexact plane constants folded in as
# f64 CAFs — and the all-int escape counts take the i64 fold unchanged.

w = 96.
h = 36.
maxIter = 80.

xmin = 0 - Numeric.div 2213 1000.  # -2.213 .. 0.787
xspan = 3.
ymin = 0 - Numeric.div 12 10.      # -1.2 .. 1.2
yspan = Numeric.div 24 10.

dx = Numeric.div xspan w.
dy = Numeric.div yspan h.

imod a b = a - (a / b) * b.

mand cr ci zr zi k | k == 0 = 0.
mand cr ci zr zi k =
  r2 = zr * zr;
  i2 = zi * zi;
  case r2 + i2 > 4 of
    True -> k
  | False -> mand cr ci (r2 - i2 + cr) (2 * zr * zi + ci) (k - 1).

pix i =
  col = imod (i - 1) w;
  row = (i - 1) / w;
  mand (xmin + col * dx) (ymin + row * dy) 0 0 maxIter.

upto a b | a > b = [].
upto a b = a :: upto (a + 1) b.
plus a b = a + b.

palette = ["@", "#", "*", "+", "=", "-", ":", ".", " "].
charFor c = case c == 0 of
  True -> "@"
| False -> palette ! (case c / 10 + 1 > 9 of True -> 9 | False -> c / 10 + 1).

rowStr cs | cs == [] = "".
rowStr cs = case cs of c :: r -> "{charFor c}{rowStr r}".

dropN n xs | n == 0 = xs.
dropN n xs | xs == [] = [].
dropN n xs = case xs of x :: r -> dropN (n - 1) r.

takeN n xs | n == 0 = [].
takeN n xs | xs == [] = [].
takeN n xs = case xs of x :: r -> x :: takeN (n - 1) r.

printRows cs | cs == [] = 0.
printRows cs = u = print (rowStr (takeN w cs)); printRows (dropN w cs).

> v = Vec.fromList (upto 1 (w * h));
  counts = Vec.map pix v;
  (checksum, c2) = Vec.fold plus 0 counts;
  cl = Vec.toList c2;
  u = printRows cl;
  print "checksum: {checksum} ({w}x{h}, {maxIter} iters)".
