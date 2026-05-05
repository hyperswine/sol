#!/usr/bin/env sol
# Demonstrates Result and Option types:
#   Just / Nothing  (Option)
#   Ok   / Err      (Result)
# and combinators: andThen, mapErr, map, echo-unwrapping, fromMaybe, unwrapOr

echo "=== Result and Option Types ===".
echo "".

# ------------------------------------------------------------------
# 1. Constructors and println (shows structure)
# ------------------------------------------------------------------
echo "1. Constructors".
println (Just 42).
println Nothing.
println (Ok "deployed").
println (Err "timeout").
echo "".

# ------------------------------------------------------------------
# 2. echo unwraps Just / Ok automatically
# ------------------------------------------------------------------
echo "2. echo vs println".
result = Ok "v1.4.2".
echo   "echo:    ".
echo   result.
echo   "println: ".
println result.
echo "".

# ------------------------------------------------------------------
# 3. Predicates
# ------------------------------------------------------------------
echo "3. Predicates".
x = Just 10.
n = Nothing.
isj = isJust x.
isn = isNothing n.
iso = isOk (Ok 1).
ise = isErr (Err "oops").
echo "isJust  (Just 10) = {isj}".
echo "isNothing Nothing = {isn}".
echo "isOk  (Ok ...) = {iso}".
echo "isErr (Err ..) = {ise}".
echo "".

# ------------------------------------------------------------------
# 4. Extractors
# ------------------------------------------------------------------
echo "4. Extractors".
val = fromJust (Just 99).
echo "fromJust (Just 99)     = {val}".
fallback = fromMaybe 0 Nothing.
echo "fromMaybe 0 Nothing    = {fallback}".
kept = fromMaybe 0 (Just 7).
echo "fromMaybe 0 (Just 7)   = {kept}".
orval = unwrapOr 42 (Err "fail").
echo "unwrapOr 42 (Err fail) = {orval}".
echo "".

# ------------------------------------------------------------------
# 5. Functor: map over Just / Ok (Nothing / Err pass through)
# ------------------------------------------------------------------
echo "5. map over Option / Result".
double n = n * 2.
md_just    = str (map double (Just 5)).
md_nothing = str (map double Nothing).
md_ok      = str (map double (Ok 7)).
md_err     = str (map double (Err "x")).
echo "map double (Just 5)  = {md_just}".
echo "map double Nothing   = {md_nothing}".
echo "map double (Ok 7)    = {md_ok}".
echo "map double (Err x)   = {md_err}".
echo "".

# ------------------------------------------------------------------
# 6. andThen (flatMap / bind)
# ------------------------------------------------------------------
echo "6. andThen (monadic bind)".
safe_div x = Ok (x / 2).
chained     = andThen safe_div (Ok 20).
skipped     = andThen safe_div (Err "upstream failure").
chained_s   = str chained.
skipped_s   = str skipped.
echo "andThen safe_div (Ok 20) = {chained_s}".
echo "andThen on Err           = {skipped_s}".
echo "".

# ------------------------------------------------------------------
# 7. mapErr — transform error payloads
# ------------------------------------------------------------------
echo "7. mapErr".
prefix_err s = concat "deployment failed: " s.
e       = mapErr prefix_err (Err "timeout").
ok_pass = mapErr prefix_err (Ok "fine").
e_s       = str e.
ok_pass_s = str ok_pass.
echo "mapErr on Err = {e_s}".
echo "mapErr on Ok  = {ok_pass_s}".
echo "".

# ------------------------------------------------------------------
# 8. Guards composing with Result (real-world pattern)
# ------------------------------------------------------------------
echo "8. Guards + Result".
check_port p | p < 1024 = Err "port below 1024 requires root".
check_port p | p > 65535 = Err "port out of range".
check_port p             = Ok p.

r1 = check_port 80.
r2 = check_port 8080.
r3 = check_port 99999.
r1s = str r1.
r2s = str r2.
r3s = str r3.
echo "port 80:    {r1s}".
echo "port 8080:  {r2s}".
echo "port 99999: {r3s}".

echo "".
echo "=== Done ===".
