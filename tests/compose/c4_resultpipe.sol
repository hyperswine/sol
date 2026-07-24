# |>? short-circuiting with the BUILTIN Ok/Err, case, interpolation
chk name got want = case got == want of True -> print "ok {name}" | False -> error "FAIL {name}: {got} vs {want}".

half n = case Numeric.mod n 2 of 0 -> Ok (n / 2) | _ -> Err "odd: {n}".
dec n | n > 0 = Ok (n - 1).
dec n = Err "hit zero".

show r = case r of Ok v -> "got {v}" | Err e -> "err {e}".

> chk "Ok chain" (show (Ok 20 |>? half |>? dec |>? dec)) "got 8".
> chk "Err at the right link" (show (Ok 20 |>? half |>? dec |>? half)) "err odd: 9".
> chk "short-circuit keeps first Err" (show (Ok 20 |>? half |>? half |>? half)) "err odd: 5".
