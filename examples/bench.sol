iota k | k == 0 = [].
iota k = k :: iota (k - 1).
collatzLen n | n == 1 = 0.
collatzLen n | (n / 2) * 2 == n = 1 + collatzLen (n / 2).
collatzLen n = 1 + collatzLen (3 * n + 1).
plus a b = a + b.
> List.fold plus 0 (List.map collatzLen (iota 100000)).
> fuelPreempts 0.
