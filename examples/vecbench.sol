Row = {key : Int, val : Int}.
mkRow i = {key = i, val = i * 7 - (i / 13) * 13}.
fill v i lim | i > lim = v.
fill v i lim = fill (Vec.push (mkRow i) v) (i + 1) lim.
plus a b = a + b.
> v = fill (Vec.new Unit) 1 200000;
  hot = Vec.filter (fn r -> r.val > 500000) v;
  (n, hot2) = Vec.len hot;
  scores = Vec.map (fn r -> r.key + r.val * 2) hot2;
  (total, s2) = Vec.fold plus 0 scores;
  u = print "kept {n}, total {total}";
  Vec.free s2.
