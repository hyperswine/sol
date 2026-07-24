# a struct chosen at RUNTIME flowing into a sig-generic function
# (first-class record fallback) vs the monomorphized literal call.
# Bare `+` inside the generic dispatches through the sig param's struct.
chk name got want = case got == want of True -> print "ok {name}" | False -> error "FAIL {name}: {got} vs {want}".

Twice = Struct Add { (+) = fn a b -> a + b + a + b, zero = 0 }.
Plus = Struct Add { (+) = fn a b -> a + b, zero = 0 }.
# NOTE: pick returning structs of DIFFERENT row widths (Numeric vs Twice)
# is a type error — no width subtyping across clause returns. Same-shaped
# rows work; the runtime record fallback handles the dispatch.

total (s : Add) xs = List.fold (fn a b -> a + b) s.zero xs.

pick 1 = Plus.
pick _ = Twice.

> mono = total Plus [1, 2, 3];
  rt = total (pick 1) [1, 2, 3];
  chk "mono == runtime-picked (same struct)" mono rt.
> chk "runtime alt struct" (total (pick 2) [1, 2, 3]) 22.
> f = total Twice;
  chk "partially applied generic" (f [5]) 10.
> chk "struct + over strings" (total Str ["ab", "cd"]) "abcd".
