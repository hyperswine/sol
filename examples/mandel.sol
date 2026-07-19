# mandel.sol — Mandelbrot in Q16.16 fixed point. Per-pixel escape iteration
# is embarrassingly parallel: Vec.map over pixel indices, the complex-square
# recursion JIT-compiled with fix.fmul in its closure, running on the
# unboxed column. Rendering is interpreted string work, kept separate.

fix = use "../lib/fix".

w = 110.
h = 40.
maxIter = 96.

xmin = 0 - 145000.   # -2.213 .. 0.787
xspan = 196608.      # 3.0
ymin = 0 - 78643.    # -1.2 .. 1.2
yspan = 157286.      # 2.4

dx = fix.fdiv xspan (fix.fromInt w).
dy = fix.fdiv yspan (fix.fromInt h).

imod a b = a - (a / b) * b.

mand cr ci zr zi k | k == 0 = 0.
mand cr ci zr zi k =
  r2 = fix.fmul zr zr;
  i2 = fix.fmul zi zi;
  case r2 + i2 > 262144 of
    True -> k
  | False -> mand cr ci (r2 - i2 + cr) (2 * fix.fmul zr zi + ci) (k - 1).

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
| False -> palette ! (case c / 12 + 1 > 9 of True -> 9 | False -> c / 12 + 1).

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
