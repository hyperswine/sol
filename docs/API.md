# API.md — the Sol prelude, builtins, and libraries

Every function below states its intent, shows two different uses, and
notes the misconception most likely to bite. The whole outside-world
surface of the language is two HAL symbols — `read` and `write` — plus
the linear handle quartet; everything else in the IO section is prelude
Sol over structured `Io` values. Signatures use the prelude's notation.

Conventions that apply everywhere:
- The whole script is ONE transaction: reads snapshot, writes buffer,
  commit locks/validates/replays (crash-atomically — see README).
- Every block statement must BIND (`u = print "x";`), and case arms are
  expressions — anything needing binds becomes a clause.
- Linear values (Handle, Vector, BStr, user `T 1` types) must be used
  exactly once; interrogations thread the value back in a tuple.
- There are no float literals; inexact Numerics arise only from
  `Numeric.div` / `Num.*` and propagate.

## Transactional filesystem + shell

**readPath : String -> String** — the file's content, snapshotted into
the read set (validated at commit; a change retries the script).
```
s = readPath @/etc/hostname;
n = Str.len (readPath "logs/{day}.txt");
```
Note: a second readPath of the same path returns the FIRST read's
snapshot — by construction. A transactional read cannot observe change;
that is what `readNow` is for.

**writePath : String -> String -> Unit** — buffer a full-content write;
it reaches disk only at commit, rename-atomically.
```
u = writePath @/tmp/report.txt body;
u = writePath "out/{name}.csv" (mToCsv m);
```
Note: nothing is on disk until the script ends. A crash mid-run leaves
the old file; a crash mid-COMMIT is healed by the redo journal.

**mkdirp / rm / rmdir : String -> Unit** — buffered directory create
(recursive), file remove, empty-dir remove.
```
u = mkdirp @/tmp/job/frames;
u = rm "{dir}/stale.lock";
```
Note: buffered like writePath — `mkdirp` then `writeNow` into the new
dir fails, because the realtime write needs the directory NOW; use
`sh "mkdir -p ..."` when a realtime path depends on it.

**mv : String -> String -> Unit** — read a, write b, remove a — all
inside the transaction (so it is copy+delete, atomic with the run).
```
u = mv @/tmp/draft.txt @/tmp/final.txt;
u = mv old ("archive/" + old);
```
Note: content travels through the transaction as a String; it is not
rename(2), so huge files pay the copy.

**ls : String -> List String** — directory listing, snapshotted into
the read set (a file appearing/disappearing invalidates the txn).
```
names = ls @/tmp/sol-csv;
logs = filter (fn n -> hasSuffix n ".log") (ls dir);
```
Note: commit-protocol artifacts (.sol-lock, .sol-tmp) are filtered out;
you never see them, and they never invalidate your listing.

**stat / exists / isDir : String -> ...** — size, existence, kind.
```
big = stat p > 1000000;
u = case exists cfg of True -> 0 | False -> error "no config";
```
Note: these join the read set too — an `exists` that flips between run
and commit retries the script, which is exactly the point.

**sh : String -> (Int, String)** — run a command NOW, as a query:
`(exitCode, stdout ++ stderr)`. Reads may inform the transaction.
```
(rc, out) = sh "make -s tests";
ok = rc == 0;
(_, host) = sh "hostname";
```
Note: output keeps its trailing newline and interleaves stderr after
stdout. `sh` runs immediately (query); `shq` defers (effect) — pick by
whether you need the answer or the side effect.

**shq : String -> Unit** — QUEUE a command as a commit effect: it runs
only if the transaction commits, in effect-log order.
```
u = shq "systemctl restart myapp";
u = shq "echo done >> /var/log/deploys";
```
Note: a retried script never ran its shq commands — that is the safety.
A shq that FAILS stops the replay with later effects unapplied
(reported). Under crash recovery, executed shqs are done-marked and
skipped; the marker window makes redo at-least-once.

**print : a -> Unit** / **input : Unit -> String** — write /dev/out;
slurp all of stdin.
```
u = print "rows: {n}";
u = print (Ok 3);
```
Note: print is NOT transactional — a retried script re-prints. `input`
reads stdin ONCE, whole; for a prompt loop you want `readLineNow`.

**sleepMs : Int -> Unit** — pause via /dev/clock.
```
u = sleepMs 250;
u = sleepMs (backoff * 100);
```
Note: sleeping inside a transaction widens the validation window — a
long sleep invites conflicts on busy paths.

## Realtime escapes (leave the transaction — spelled loudly on purpose)

The compiler prints a block naming each escape reachable from your
script, warns on first use, and the exit summary says "NOT atomic
overall". Prefer the transactional twins unless you need one of the
three impossible things: observing change, streaming, prompting.

**readNow : String -> String** — re-read the DISK, not the snapshot.
```
tail1 = readNow log;                       # poll loop can see growth
u = case readNow flag == "go" of True -> start Unit | False -> wait Unit;
```
Note: also DROPS the path from the read set (and says so) — otherwise
observing your own realtime write would invalidate the txn forever.

**writeNow / appendNow : String -> String -> Unit** — land on disk
immediately; survive a rollback.
```
u = writeNow  "build/build.log" "";        # truncate the live log
u = appendNow "build/build.log" "step 3 ok{nl}";
```
Note: the pairing that justifies them: a transactional REPORT
(complete-or-absent) beside a realtime PROGRESS LOG (tailable while it
runs) in the same script.

**shNow : String -> Int** — stream a command's output live; returns
only the exit code.
```
rc = shNow "cargo build 2>&1";
u = case shNow "ping -c1 host" == 0 of True -> 0 | False -> error "down";
```
Note: use for the LONG thing you want to watch; `sh` for the thing
whose output you need as a value.

**readLineNow : Unit -> String** — one line of stdin, now.
```
name = readLineNow Unit;
u = case readLineNow Unit == "y" of True -> go Unit | False -> 0;
```
Note: this is the prompt primitive; `input` cannot interleave with
output because it slurps everything.

## The linear handle quartet (the linearity tier)

**open : String -> Handle**, **readAll : Handle -> (String, Handle)**,
**writeAll : Handle -> String -> Handle**, **close : Handle -> Unit**.
```
h = open @/tmp/x; (s, h2) = readAll h; u = close h2;
h = open p; h2 = writeAll h body; close h2.
```
Note: Handle is linear — dropping one, or using `h` after `readAll h`,
is a COMPILE error (`examples/bad_leak.sol`, `bad_double.sol`). This is
the tier where the checker earns its keep; readPath/writePath are the
ergonomic non-linear route.

## Strings

Two variants share one String type at runtime: VStr (the default,
a char list — cheap for short things) and BStr (below — for work that
scales with input size).

**str : a -> String** — render any value.
```
s = str 42;  s2 = str (Ok [1, 2]);
```
Note: interpolation `"{x}"` IS `str` — `"n={n}"` desugars to strcat of
str segments.

**strcat : String -> String -> String** — concatenation. O(|a|) on
VStr.
```
s = strcat "a" "b";
line = strcat name (strcat "," (str age));
```
Note: a strcat FOLD is O(n²) — the exact trap BStr exists for. One-off
joins are fine.

**Str.len / strlen : String -> Int** — codepoint length.
```
n = Str.len "héllo";        # 5, not 6
u = case strlen s == 0 of True -> error "empty" | False -> 0;
```
Note: codepoints, not bytes — works on both VStr and BStr values.

**Str.at / charAt : String -> Int -> Int** — 1-based codepoint CODE.
```
c = Str.at "abc" 2;         # 98
isSp = charAt s i == 32;
```
Note: returns the integer code, not a 1-char string — `Str.fromCode`
goes back. Indexing is 1-based everywhere in Sol.

**Str.fromCode : Int -> String**, **chr : Int -> String** — code to
1-char string. `nl = Str.fromCode 10` is the base.sol newline.
```
nl = Str.fromCode 10;
tab = chr 9;
```
Note: two names for history's sake; same thing.

**Str.parse / parseInt : String -> Int** — parse a decimal integer;
PANICS on non-integers.
```
n = Str.parse "42";
k = parseInt (trim out);
```
Note: panics on "" and on floats — `base.pI` wraps the empty case to
0; CSV with a header needs `fromCsvHeader`, not a blind parse.

**BStr (linear byte buffer)** — `BStr.new : Unit -> BStr`,
`BStr.fromStr / toStr`, `BStr.append : String -> BStr -> BStr`,
`BStr.len : BStr -> (Int, BStr)`, `BStr.at : BStr -> Int -> (Int, BStr)`,
`BStr.sub : BStr -> Int -> Int -> (BStr, BStr)`, `BStr.free`.
```
b = BStr.append "world" (BStr.append "hello " (BStr.new Unit));
csv = BStr.toStr (rows2buf rss (BStr.new Unit));
```
Note: amortised O(1) append (doubling) — measured 34x over VStr at 8k
appended lines, and it is asymptotic, not constant-factor. Linear:
every op threads; `toStr` consumes. Indexing is by CODEPOINT, so the
1-based contract survives UTF-8. Guidance: VStr for short build-once
strings; BStr when work scales with input.

## Lists

Literals `[1, 2, 3]`, cons `x :: xs`, 1-based index `xs ! i`.

**map / filter : (a -> b) -> List a -> List b** and
**foldl : (b -> a -> b) -> b -> List a -> b** — the globals.
```
ys = map (fn x -> x * 2) xs;
tot = foldl (fn a x -> a + x) 0 (filter (fn x -> x > 0) xs);
```
Note: these are interpreted list ops; the JIT-compiled tier is Vec.map
/ Vec.fold over a Vector, not these.

**List.len : List a -> Int** and **`!` : List a -> Int -> a**.
```
n = List.len xs;
first = xs ! 1;
```
Note: `!` is 1-based and panics out of range; `xs ! 0` is always wrong.

## The linear SoA Vector

`Vector 1` — mutable in place, sound because linear. Records auto-
decompose into SoA columns; Vec.map/filter/fold over Int/Numeric
columns JIT-compile to native loops (`[jit]` lines; SOL_JIT=0 opts
out; results are bit-identical either way).

**Vec.new : Unit -> Vector** / **Vec.fromList : List a -> Vector** /
**Vec.toList** / **Vec.free : Vector -> Unit**.
```
v = Vec.fromList [1, 2, 3];
v2 = fill (Vec.new Unit) 1 500;    # push_back loop, in place
```
Note: every Vector must end in exactly one of free/toList/`!`-style
consumption — leaking one is a compile error.

**Vec.push : a -> Vector -> Vector** — append with doubling realloc.
```
v2 = Vec.push 7 v;
v2 = Vec.push {age = 20, name = "kim"} v;   # SoA: two columns
```
Note: value first, vector last — pipeline-friendly, and the vector
argument is the one consumed.

**Vec.len / Vec.get : ... -> (x, Vector)** — interrogations THREAD.
```
(n, v2) = Vec.len v;
(x, v3) = Vec.get i v2;
```
Note: the tuple-return shape is not ceremony — it is how a linear value
survives being asked a question. Using `v` after `Vec.len v` is the
double-use error.

**Vec.set : Int -> a -> Vector -> Vector** — in-place update.
```
v2 = Vec.set 3 99 v;
v2 = Vec.set i (f x) v;
```
Note: truly in place — no copy — which is exactly why the checker
insists on one owner.

**Vec.map / Vec.filter : (a -> b) -> Vector -> Vector** — dualized:
the lambda compiles against the columns (JIT tier).
```
aged = Vec.map (fn s -> s.age + 1) v;
adults = Vec.filter (fn s -> s.age >= 18) v;
```
Note: `/` on width-ambiguous operands bails to the interpreter by rule
(soundness), silently — same answers, less speed.

**Vec.fold : (b -> a -> b) -> b -> Vector -> (b, Vector)**.
```
(tot, v2) = Vec.fold (fn a x -> a + x) 0 v;
(mx, v2) = Vec.fold (fn a x -> Numeric.max a x) 0 v;
```
Note: the accumulator comes FIRST in the lambda; the vector threads
back like every interrogation.

## Numerics

One `Numeric` datatype: exact bignum ints by default; inexactness
enters ONLY via division-like ops and then propagates (Julia-style).

**Numeric.div / Num.div : Num -> Num -> Num** — true division,
inexact result.
```
half = Numeric.div 7 2;              # 3.5 — the only way to write it
means = map (fn s -> Numeric.div s n) sums;
```
Note: `/` is integer-style on exact ints; there are NO float literals —
tests compare against `Numeric.div 7 2`, never `3.5`.

**Numeric.mod / abs / max / min / clamp / neg / zero** — the usual.
```
r = Numeric.mod i 40;
x = Numeric.clamp 0 255 v;
```
Note: `mod` is `a - (a/b)*b` — sign follows that identity, not
Euclidean convention.

**Num.sqrt / Num.floor / Num.round : Num -> Num** — inexact kernels
(fdiv/llvm intrinsics under the JIT).
```
d = Num.sqrt (dx * dx + dy * dy);
k = Num.floor (Numeric.div n 10);
```
Note: `floor`/`round` return Numerics, not a separate Int type — the
type is one; exactness is a property of the value.

## Modules

**use : String -> Module** — content-addressed import.
```
mx = use "../lib/matrix". M = mx.M.
H = use "harness#934372c47bdc1257".      # pinned: exactly this code
```
Note: unpinned `use` resolves and PRINTS the hash ("pin this");
pinning freezes it. A pin is valid per compiler version — an AST-schema
change re-hashes byte-identical source, by design.

**run : Module -> a -> String** — invoke a module's entry. RESERVED
NAME: a user function called `run` shadows this and produces
"cannot unify Module with String" at every call site — name yours
`step`/`go`.

## The MVU web tier

**View.serve : port -> init -> update -> view -> flags -> Unit** — an
event-sourced Elm-style app: model rebuilt by replaying
`<script>.soldata`, `Persistent` keys in `.solkv`, dyn-diff over
WebSocket, sessions + reconnect.
```
> View.serve 8084 init update view 0.
u = View.serve 8080 (fn f -> model0) upd vw 0;
```
Note: kill -9 safe by replay. Commands (`Cmd`: Print / ReadFile / Rng /
Batch / Put / Get / Msg) are how update reaches the world — update
itself stays pure.

## Sigs (interfaces)

`Add`, `Arith`, `Functor`, `StreamOps` — structural signatures; a
Struct can declare conformance (`Numeric = Struct Arith { ... }`) and
`(s : Functor)` constrains a param by sig.
```
sumAll (s : StreamOps) xs = s.fold (fn a x -> a + x) 0 xs;
```
Note: conformance is checked (typed struct conformance), not nominal.

## Misc

**error : String -> a** — abort the script (the transaction rolls
back: no file effects, no shq ran).
```
u = case ok of True -> 0 | False -> error "bad input: {s}";
chk n got want | got == want = print "ok {n}".
chk n got want = error "FAIL {n}: {got} vs {want}".
```
Note: this rollback-on-error is the language's core promise — error is
SAFE to call mid-"mutation" because nothing has mutated yet.

**fuelPreempts : Unit -> Int** — cooperative-scheduler introspection.
```
p = fuelPreempts Unit;
u = print "preempts: {fuelPreempts Unit}";
```

## lib/base (`base = use "../lib/base".`)

pI (parse-int, "" -> 0) · and2/or2/not2 (STRICT — both sides evaluate:
`and2 (i <= n) (charAt s i == c)` panics on the bounds you meant to
guard; use case/guards for short-circuit) · max0 · boolInt · nl ·
takeN · listLen · removeAt · substr s i j (1-based inclusive) ·
findCh/findSp · splitFirst · splitCh c s (split on char CODE: 44 =
comma, 10 = newline) · imod2 · baseName.
```
fields = base.splitCh 44 line;
day = base.substr stamp 1 10;
```

## lib/rand (`Rand = rnd.Rand.`)

LCG (glibc constants) threaded explicitly: next / uniform s hi /
unit (inexact in [-1,1)) / gauss4 / next4.
```
s2 = Rand.next s;  roll = Rand.uniform s2 6;
g = Rand.gauss4 s;  s' = Rand.next4 s;    # gauss4 CONSUMES 4 draws
```
Note: seed hygiene — independent features need next4-separated streams,
or your "independent" columns correlate.

## lib/matrix (`M = mx.M.`)

`Matrix 1 = Type (Mat Int Int Vector)` — one row-major SoA cells
column; the declared Vector field makes the checker track the payload.
Surface: fromRows / fill / dims / get / set / row / col / head /
selectRows / selectCols / map / fold / mapRow / mapCol / mapRows /
transpose / mul / mulVec / colMeans / fromCsv(Header) / toCsv(Header) /
show / free.
```
(p, a2, b2) = M.mul a b;                 # operands thread back out
(hs, m) = M.fromCsvHeader (readPath f);
```
Notes: M.map/M.fold are ONE Vec op over the cells column — the JIT
path; matmul/selection are interpreted index threading. fromRows
panics on ragged rows (first row's width is the contract). Re-reading
a header CSV with plain fromCsv panics in parseInt on the header —
use fromCsvHeader.
