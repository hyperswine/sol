# Session notes: realtime escapes, BStr, and one lexer bug

Three changes to Sol, plus the first Sol replacements for the FP-RISC shell
scripts. Build (LLVM 18 + utf8-string):

```sh
gcc -c cbits/shim.c -o cbits/shim.o $(llvm-config-18 --cflags)
UTF8=/usr/lib/haskell-packages/ghc/lib/x86_64-linux-ghc-9.4.7/utf8-string-1.0.2-KqazO8nUWrDMJ2shK7HoQ
ghc -O0 -threaded -isrc -o sol src/Main.hs cbits/shim.o \
    -I/usr/lib/llvm-18/include -L$(llvm-config-18 --libdir) -lLLVM-18 \
    -L$UTF8 -lHSutf8-string-1.0.2-KqazO8nUWrDMJ2shK7HoQ
LD_LIBRARY_PATH=/usr/lib/llvm-18/lib ./sol script.sol
```

(`utf8-string` was added to sol.cabal; apt package `libghc-utf8-string-dev`.)

---

## 1. Realtime escapes — I/O that leaves the transaction

The observation that shaped the design: Sol's *entire* outside-world surface is
already two builtins, `read` and `write`, where the SHAPE of the argument picks
the operation, and `/dev/out`, `/dev/in`, `/dev/sh`, `/dev/clock` are already
non-transactional escapes. So this extends that grain rather than adding a
parallel mechanism — five new `Io` intents and five prelude wrappers.

| realtime | what it is for | transactional twin |
|---|---|---|
| `readNow p` | re-reads the disk, so a poll/tail loop can observe change | `readPath` |
| `writeNow p s` | lands on disk immediately | `writePath` |
| `appendNow p s` | append now — progress logs you can tail | `writePath` |
| `shNow c` | streams a command's output live, returns exit code | `shq` |
| `readLineNow u` | one line of stdin, now, for prompts | `input` |

Those five exist because three things are genuinely impossible inside a
transaction, not merely awkward:

* **Observing change.** A transactional read is idempotent by construction —
  the second `read p` returns the first read's snapshot. A watch/tail loop can
  therefore never see a file change.
* **Streaming output.** `sh` captures a command's output and returns it when the
  command finishes, so a four-minute build shows nothing until it ends.
* **Prompting.** `input` slurps all of stdin at once.

### Warnings, at three levels

Not the default, and loud about it:

1. **Compile time** — a block naming each escape, its use count, and the
   transactional alternative:

   ```
   === REALTIME ESCAPES: 4 use(s) ===
     appendNow x2  — appends before commit and survives a rollback (transactional: writePath)
     readNow x1  — re-reads the disk, not snapshotted, not validated at commit (transactional: readPath)
     shNow x1  — streams a command live and re-runs on every retry (transactional: shq)
     this script is NOT atomic with respect to those paths/commands
   ```

2. **First use, at runtime** — one stderr line per kind naming the actual path
   or command.

3. **Exit** — `[sol] NOT atomic overall: 4 realtime escape(s) — appendNow x2,
   readNow x1, shNow x1`, so the `committed N file(s) atomically` line above it
   can't be mistaken for a claim about the whole run.

The compile-time scan is **call-graph reachable** from the `>` statements and a
zero-arity `main`. That matters because `use` splices whole modules in: a
library with one realtime helper would otherwise make every importer report an
escape it never performs, and a warning you learn to ignore is worse than none.
Verified both directions — the false positive is gone, and a true positive
still fires through a level of indirection.

### Two hazards handled rather than left as traps

* **Self-invalidation.** `s = readPath p; u = appendNow p line` would invalidate
  its own read set and retry until it gave up. A realtime write now drops the
  path from the read set and says so: *"was already read in this transaction —
  dropping it from the read set; the transaction no longer guarantees anything
  about that path."* The transaction stops making claims about a path you have
  stepped outside the transaction for.
* **Retry honesty.** Under `SOL_FORCE_RETRY=1`, `appendNow` genuinely runs
  twice, two lines land on disk, and the summary reports `appendNow x2`. The
  cost is visible rather than hidden.

Implementation: `src/Txn.hs` (`rtRead`/`rtWrite`/`rtAppend`/`rtShell`/`rtLine`,
`txForget`, `RtCounts`), `src/VM.hs` (dispatch), `src/Preamble.hs` (`Io`
constructors + wrappers), `src/Main.hs` (`scanRealtime` + the summary).

---

## 2. BStr — the byte-buffer string tier

`VStr` is a Haskell `String` = a linked list of boxed `Char`. Hence `Str.at` is
O(i), `strcat` is O(|a|), and string interpolation desugars to a left-fold of
`strcat` — so `acc = "{acc}{line}"` in a loop is **O(n²)**. That is fine for
what Sol mostly manipulates (filenames, status lines, formatted numbers) and
badly wrong for anything that scales with input size.

`BStr` is the escape: a mutable, contiguous byte buffer (`ByteString` storage,
UTF-8 encoding) with amortised O(1) append via doubling, declared **linear** in
the prelude for the same reason `Vector` is — in-place mutation is only sound
with exactly one owner, and the linearity checker proves it statically.

```sol
BStr 1 = Type (BStr Int).
BStr.new     : Unit -> BStr.
BStr.fromStr : String -> BStr.
BStr.toStr   : BStr -> String.              # consumes (terminal op)
BStr.append  : String -> BStr -> BStr.      # the hot path
BStr.cat     : a -> a -> a.
BStr.len     : BStr -> (Int, BStr).         # THREADS, like Vec.len
BStr.at      : BStr -> Int -> (Int, BStr).  # 1-based, by CODEPOINT
BStr.sub     : BStr -> Int -> Int -> (BStr, BStr).
BStr.free    : BStr -> Unit.
```

Interrogation threads the buffer rather than consuming it — the linearity
checker caught my first attempt (`BStr.len : BStr -> Int`) with *"linear
variable 'b2' used 5 time(s), expected exactly 1"*, which is the correct
complaint and the reason `Vec.len` has the shape it does.

Indexing is by **codepoint, not byte**, so Sol's 1-based `charAt` contract
survives UTF-8: `BStr.len (BStr.fromStr "héllo")` is 5, not 6, and
`BStr.at ... 2` is 233. There's a fast path for ASCII; full decode only when a
character boundary doesn't land on a 7-bit byte.

Runtime representation reuses the bridge `Handle` already uses: a `BStr` is
`VData bstrT 0 [VInt key]` at the Sol level, with a process-global
`IORef (IntMap (IORef BStrStore))` mapping keys to buffers. So the linearity
checker treats it as an opaque linear type with no special cases. `strcat`,
`String.len`, `charAt` and `==` all accept **either** variant at runtime
(`vsStr` unpacks both), so values arriving untyped from HAL calls interoperate;
typed code still needs an explicit `BStr.toStr`, which is the honest boundary.

### Measured

The append-heavy builder that motivated it, `foldl` over N lines:

| N | VStr | BStr | speedup |
|---:|---:|---:|---:|
| 1000 | 154 ms | 84 ms | 1.8× |
| 2000 | 644 ms | 105 ms | 6× |
| 4000 | 2956 ms | 261 ms | 11× |
| 8000 | 12620 ms | 366 ms | **34×** |

VStr quadruples per doubling (O(n²)); BStr grows roughly linearly (the ~60 ms
floor is process startup). The gap keeps widening — this is an asymptotic fix,
not a constant-factor one.

**When to use which:** VStr stays the default and is right for short strings
built once and read a few times. Reach for BStr when the work scales with input
size — append-heavy builders, index-heavy scanning, parsing multi-KB input.

---

## 3. A lexer bug: reserved words matched as prefixes

`cases = [1,2].` failed to parse. Cause: `caseE` used `symbol "case"`, which
happily matches the *prefix* of `cases` and leaves a stray `s` behind. Same for
`fn` (two sites), `of`, and `Type`. A correct `keyword` combinator with a
`notFollowedBy (satisfy identChar)` boundary check already existed in
`Lang.hs` — those five sites just weren't using it.

This is the same bug class I hit in the FP-RISC front-end earlier (`fnv1a`
lexing as `fn` + `v1a`), so it's worth a look wherever else `symbol` is used
for a word.

Fixed and verified: `cases`, `often`, `fnord` all parse; `hello`, `fileops`,
`structs`, `modules` unchanged.

---

## 4. The script rewrites

`tools/harness.sol` and `tools/sweep.sol` (in the FP-RISC repo, not this one).

**`tools/sweep.sol` replaces posix-sweep.sh and passes 21/21.** The bash version
was a here-doc table parsed at runtime by `IFS='|' read` inside a `while` inside
a pipeline whose subshell lost the PASS/FAIL counters. The Sol version is a list
of `Case name expects wantFail` values, a `map`, and clause patterns.

The division of labour is deliberate, and it is the actual argument for the
rewrite:

* **Decisions in Sol** — the expectation table, pass/fail logic, the report.
  That was the unmaintainable part of the bash.
* **Byte-shovelling stays a tool call.** Sol strings are linked lists; grep and
  sed are the right instruments for megabyte logs. (BStr narrows this, but for a
  one-shot scan of a large file, invoking grep is still the better answer.)
* **The report is transactional** (`writePath`) — complete or absent, even if
  the sweep is killed halfway. **The progress log is realtime** (`appendNow`) —
  because a progress log you cannot tail while the sweep runs is useless. That
  contrast in one script is the clearest justification for the escape hatch.

### Still to do

* `tools/voxel-check.sol` — not started. Shape: `shNow` for the slow build so
  it streams, `sh` for the runs, determinism by string equality, frame
  extraction via sed, report via `writePath`.
* The `harness.sol` string helpers (`findStr`, `splitCh`, `trim`) are the
  quadratic VStr versions. Now that BStr exists they should be rewritten
  against it — that was the whole point of adding it.
* `BStr.len` is O(n) because counting UTF-8 codepoints requires a walk. Caching
  the count in `BStrStore` and invalidating on append would make it O(1) for the
  common all-ASCII case.
* `bsAppendStr` rebuilds the ByteString via `<>` rather than poking into a
  pre-allocated buffer. It is amortised-correct but does more copying than
  necessary; a real `mallocForeignPtrBytes` buffer (as `Val.hs`'s `Col` already
  uses for Vector) would remove that.
