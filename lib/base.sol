# base.sol — the base library, written against the stdlib structures
# (Str.*, List.*, Numeric.*) rather than bare HAL globals. Everything
# here was previously either hardcoded in the Haskell prelude string or
# copy-pasted across apps.

pI s = case s == "" of True -> 0 | False -> Str.parse s.
and2 a b = case a of True -> b | False -> False.
or2 a b = case a of True -> True | False -> b.
not2 a = case a of True -> False | False -> True.
max0 n = Numeric.max 0 n.
boolInt b = case b of True -> 1 | False -> 0.
nl = Str.fromCode 10.

takeN n xs | n == 0 = [].
takeN n xs | xs == [] = [].
takeN n xs = case xs of x :: r -> x :: takeN (n - 1) r.

listLen xs = List.len xs.

removeAt k xs | xs == [] = [].
removeAt k xs = case xs of
  x :: r -> (case k == 1 of True -> r | False -> x :: removeAt (k - 1) r).

# string helpers (moved out of the Haskell-injected prelude)
substr s i j = case i > j of True -> "" | False -> "{Str.fromCode (Str.at s i)}{substr s (i + 1) j}".
findCh c s i = case i > Str.len s of True -> 0 | False -> (case Str.at s i == c of True -> i | False -> findCh c s (i + 1)).
findSp s i = findCh 32 s i.
splitFirst s = k = findSp s 1; case k of 0 -> (s, "") | _ -> (substr s 1 (k - 1), substr s (k + 1) (Str.len s)).
splitCh c s | s == "" = [].
splitCh c s =
  k = findCh c s 1;
  case k of
    0 -> [s]
  | _ -> substr s 1 (k - 1) :: splitCh c (substr s (k + 1) (Str.len s)).

imod2 a b = Numeric.mod a b.

# last path segment
baseName p =
  k = lastSlash p 1 0;
  case k == 0 of True -> p | False -> substr p (k + 1) (Str.len p).
lastSlash p i best | i > Str.len p = best.
lastSlash p i best = case Str.at p i == 47 of True -> lastSlash p (i + 1) i | False -> lastSlash p (i + 1) best.
