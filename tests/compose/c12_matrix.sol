# matrix x linear Vec x modules x csv x txn: every op checked against
# hand-computed values; panics on any mismatch (the suite greps for ok/FAIL).

mx = use "../../lib/matrix". M = mx.M.

chk name got want | got == want = print "ok {name}".
chk name got want = error "FAIL {name}: {got} vs {want}".

# 1 2 3
# 4 5 6
mkA u = M.fromRows [[1, 2, 3], [4, 5, 6]].

> a = mkA Unit;
  (r, c, a2) = M.dims a;
  u1 = chk "dims" (r, c) (2, 3);
  (x, a3) = M.get 2 2 a2;
  u2 = chk "get 2 2" x 5;
  (row2, a4) = M.row 2 a3;
  u3 = chk "row 2" row2 [4, 5, 6];
  (col3, a5) = M.col 3 a4;
  u4 = chk "col 3" col3 [3, 6];
  a6 = M.set 1 1 9 a5;
  (y, a7) = M.get 1 1 a6;
  u5 = chk "set/get" y 9;
  M.free a7.

> a = mkA Unit;
  (h, a2) = M.head 1 a;
  (hs, h2) = M.show h;
  u1 = chk "head 1" hs "1x3\n  [1,2,3]\n";
  u2 = M.free h2;
  (s, a3) = M.selectCols [3, 1] a2;
  (ss, s2) = M.show s;
  u3 = chk "selectCols [3,1]" ss "2x2\n  [3,1]\n  [6,4]\n";
  u4 = M.free s2;
  t = M.transpose a3;
  (ts, t2) = M.show t;
  u5 = chk "transpose" ts "3x2\n  [1,4]\n  [2,5]\n  [3,6]\n";
  M.free t2.

> a = mkA Unit;
  b = M.fromRows [[7, 8], [9, 10], [11, 12]];
  (p, a2, b2) = M.mul a b;
  (ps, p2) = M.show p;
  u1 = chk "mul 2x3*3x2" ps "2x2\n  [58,64]\n  [139,154]\n";
  u2 = M.free p2;
  u3 = M.free b2;
  (mv, a3) = M.mulVec a2 [1, 0, 2];
  u4 = chk "mulVec" mv [7, 16];
  (means, a4) = M.colMeans a3;
  u5 = chk "colMeans exact" (means ! 2) (Numeric.div 7 2);
  doubled = M.map (fn x -> x * 2) a4;
  (tot, d2) = M.fold (fn acc x -> acc + x) 0 doubled;
  u6 = chk "map*2 then fold" tot 42;
  tweak = M.mapCol 1 (fn x -> 0) (M.mapRow 2 (fn x -> x + 1) d2);
  (ts, t3) = M.show tweak;
  u7 = chk "mapRow/mapCol" ts "2x3\n  [0,4,6]\n  [0,11,13]\n";
  M.free t3.

# csv roundtrip through a real file, inside the transaction
> a = M.fromRows [[3, 1], [4, 1], [5, 9]];
  (txt, a2) = M.toCsvHeader ["u", "v"] a;
  u1 = writePath @/tmp/sol-c12.csv txt;
  (hs, back) = M.fromCsvHeader (readPath @/tmp/sol-c12.csv);
  u2 = chk "csv header" hs ["u", "v"];
  (s1, a3) = M.show a2;
  (s2, b2) = M.show back;
  u3 = chk "csv roundtrip" s2 s1;
  u4 = M.free a3;
  u5 = M.free b2;
  u6 = rm @/tmp/sol-c12.csv;
  print "ok c12 done".
