# guard pattern-bindings composed with recursion, records, fallthrough
chk name got want = case got == want of True -> print "ok {name}" | False -> error "FAIL {name}: {got} vs {want}".

classify r | (k, v) <- r, k == "n", v > 10 = "big {v}".
classify r | (k, v) <- r, k == "n" = "small {v}".
classify _ = "not n".

> chk "guard pat + cond" (classify ("n", 25)) "big 25".
> chk "guard pat fallthrough" (classify ("n", 3)) "small 3".
> chk "guard pat miss" (classify ("m", 3)) "not n".

# guards re-evaluate on fallthrough: pure lookups only, but the SAME
# expression feeding two clauses must stay consistent
step st | x :: _ <- st.q, x > st.hi = {st | hi = x, q = tailOf st.q}.
step st | x :: _ <- st.q = {st | q = tailOf st.q}.
step st = st.
tailOf (_ :: r) = r.
tailOf [] = [].

runq st | st.q == [] = st.hi.
runq st = runq (step st).

> chk "record + guard-pat loop (max)" (runq {q = [3, 9, 2, 7], hi = 0}) 9.
