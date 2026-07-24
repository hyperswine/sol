# linears threaded through pipes, case branches consuming equally,
# tuple-threading through recursion (case arms are exprs: helpers do binding)
chk name got want = case got == want of True -> print "ok {name}" | False -> error "FAIL {name}: {got} vs {want}".

sumVec v n acc | n == 0 = u = Vec.free v; acc.
sumVec v n acc =
  (x, v2) = Vec.get n v;
  sumVec v2 (n - 1) (acc + x).

> v = Vec.fromList [10, 20, 30] |> Vec.push 40 |> Vec.map (fn x -> x + 1);
  (len, v2) = Vec.len v;
  s = sumVec v2 len 0;
  chk "pipe-threaded vector" s 104.

# both case branches must consume the same linear set
lenFree v = (n, v2) = Vec.len v; u = Vec.free v2; n.
listLen2 v = xs = Vec.toList v; List.len xs.
splitConsume v flag = case flag of True -> lenFree v | False -> listLen2 v.

> a = splitConsume (Vec.fromList [1, 2, 3]) True;
  b = splitConsume (Vec.fromList [4, 5]) False;
  chk "case branches consume equally" (a + b) 5.
