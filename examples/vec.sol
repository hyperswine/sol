# vec.sol — the linear SoA Vector.
# Student records decompose into columns automatically: {age, name} (sorted
# field order) stores as an unboxed i64 ages column + a boxed names column.
# Every op consumes the vector and hands one back — the linearity checker
# rejects any use-after-consume at compile time.

Student = {age : Int, name : String}.

iota k | k == 0 = [].
iota k = k :: iota (k - 1).

mkStudent i = {age = 17 + (i - (i / 40) * 40), name = "student{i}"}.
plus a b = a + b.

# build: push_back with doubling realloc, entirely in place (linear!)
fill v i lim | i > lim = v.
fill v i lim = fill (Vec.push (mkStudent i) v) (i + 1) lim.

> v = fill (Vec.new Unit) 1 500;
  (n, v2) = Vec.len v;
  u = print "students: {n}";

  # explicit access RECONSTRUCTS the product from the columns (slower path)
  (s, v3) = Vec.get 3 v2;
  u2 = print "student 3 reconstructed: age {s.age}, {s.name}";

  # DUALIZED filter: the predicate runs natively over the ages column only;
  # kept-row indices come back and ALL columns (incl. names) gather by row
  adults = Vec.filter (fn s -> s.age >= 18) v3;
  (m, adults2) = Vec.len adults;
  u3 = print "adults: {m}";
  (a1, adults3) = Vec.get 1 adults2;
  u4 = print "first adult: {a1.name} age {a1.age}";

  # DUALIZED map: fn s -> s.age + 1 becomes (cols, i) -> ages[i] + 1
  aged = Vec.map (fn s -> s.age + 1) adults3;
  (total, aged2) = Vec.fold plus 0 aged;
  u5 = print "sum of adult ages+1: {total}";
  Vec.free aged2.

# scalar int vectors: same machinery, one unboxed column
> nums = Vec.fromList (iota 1000);
  doubled = Vec.map (fn x -> x * 2) nums;
  (s, d2) = Vec.fold plus 0 doubled;
  u = print "sum doubled 1..1000: {s}";
  d2 ! 1.
