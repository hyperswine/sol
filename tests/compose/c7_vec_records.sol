# Vec of records: SoA columns + map/filter/fold over record fields,
# threading the linear vector through every stage
chk name got want = case got == want of True -> print "ok {name}" | False -> error "FAIL {name}: {got} vs {want}".

> v = Vec.fromList [{x = 1, y = 10}, {x = 2, y = 20}, {x = 3, y = 30}];
  v2 = Vec.map (fn p -> {p | y = p.y + p.x}) v;
  v3 = Vec.filter (fn p -> p.y > 15) v2;
  (s, v4) = Vec.fold (fn acc p -> acc + p.y) 0 v3;
  xs = Vec.toList v4;
  chk "SoA record pipeline sum" s 55.
> v = Vec.fromList [{x = 1, y = 10}];
  xs = Vec.toList v;
  chk "record roundtrip through vec" (map (fn p -> p.x + p.y) xs) [11].
