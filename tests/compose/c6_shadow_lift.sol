# lambda-lift stress: nested captures, shadowing, partial app through pipes
chk name got want = case got == want of True -> print "ok {name}" | False -> error "FAIL {name}: {got} vs {want}".

mk a = fn b -> fn a -> a + b.
add3 a b c = a + b + c.

> f = mk 100 5;
  chk "inner shadows outer capture" (f 7) 12.
> g = add3 1;
  h = g 2;
  chk "curried through bindings" (h 10) 13.
> r = 5 |> add3 1 2 |> fn a -> a * a;
  chk "partial app as pipe stage" r 64.
> xs = map (add3 10 20) [1, 2, 3];
  chk "partial app under map" xs [31, 32, 33].
> k = 3;
  fs = map (fn n -> fn a -> a * n + k) [1, 2];
  chk "closures over free var in list" (map (fn f -> f 10) fs) [13, 23].
