# Testing

One command runs everything: `tests/run.sh` (properties + composition
programs + negative tests + example sweep).

## Property suite — `test/Props.hs` (hedgehog)

Build: `ghc -O0 -threaded -isrc -itest -o props test/Props.hs cbits/shim.o
-L$(llvm-config --libdir) -lLLVM-18` — or `cabal test` (a `test-suite props`
stanza exists; `-f llvm22` works as for the executable). Run `./props`.

The suite drives the REAL pipeline in-process (parse → sig/struct →
inference → specialize → linearity → desugar/lift → bytecode → VM, JIT
off) via `runSol`, enabled by extracting `prelude`/`halArities` from Main
into `src/Preamble.hs`.

Properties:

1. **ref/vm agree** — the differential. A typed generator produces random
   well-typed programs (arithmetic, comparisons, structural equality,
   lists/cons/`!`, tuples, case over list/pair/bool, lambdas, shadowing,
   `|>`, `$`, nested interpolation, `str`, map/filter/foldl,
   `Numeric.*`/`Str.*`/`List.*`, multi-clause helpers with guards, literal
   patterns, structural recursion). Each is also evaluated by a reference
   evaluator in the test file written directly against SEMANTICS.txt
   (strict CBV left-to-right, lexical scope, first-match-wins, guard
   fallthrough, `quot` division, 1-based indexing). Outputs must match.
   Divergence means the implementation and SEMANTICS.txt disagree.
2. **`f $ x` ≡ `f (x)`** — identical ASTs (STYLE.md's pin-safety claim).
3. **`e |> f` ≡ `f (e)`** — same value through the full pipeline.
4. **`"{e}"` ≡ `str e`**.
5. **`f $ e |> g` ≡ `f (e |> g)`** — `$` binds looser than `|>`.

All pass, including a 2000-test soak of (1). When extending the language,
extend the generator (`genExpr`/`genDef`) and the reference together —
the property is only as strong as the fragment generated.

## Composition programs — `tests/compose/`

Self-checking programs that cross feature boundaries on purpose; each
prints `ok <name>` per check or panics. c1 linears × pipes × case;
c2 runtime-chosen structs vs monomorphized calls (and struct `+` over
strings); c3 guard pattern-bindings × records × recursion; c4 `|>?` with
builtin Ok/Err; c5 structs/generics across module boundaries; c6
lambda-lift/shadowing/partial-application stress; c7 Vec-of-records SoA
pipelines; c8 transaction read-your-writes + `sh`. c9 is negative:
programs that MUST be rejected (leak, double-use, guard consumption,
branch-unequal consumption), run via `c9_neg_linearity.sh`.

## Findings from building this (2026-07-24)

Fixed:

* **`sh`/`shq` types in Infer disagreed with the VM** — Infer had both as
  `String -> String`; the VM returns `(exitCode, output)` for `sh` and
  Unit for `shq`. The checker rejected correct destructuring and accepted
  code that would misbehave at runtime. Fixed in Infer.hs (caught by c8).
  No call sites in examples/lib were relying on the wrong types.

Documented, not changed:

* **Gradual linearity at function boundaries.** An unannotated
  `f v = 42.` receiving a Vector is accepted — the param's linearity is
  unknown without a `f : Vector -> ...` sig, so leak/guard checks only
  fire for annotated functions (then they fire correctly, with good
  messages). Inference runs before the linearity pass, so inferred types
  could close this gap if wanted.
* **Struct width subtyping.** A function whose clauses return structs of
  different row widths (e.g. `Numeric` vs an Add-only struct) is a type
  error; same-shaped rows work and dispatch correctly at runtime. The
  error message also renders operator fields poorly ("lacks field `.-`"
  and the `(+)` field is missing from the printed row).
* **Operator sig fields are reached via bare operators.** Inside a
  `(s : Add)`-generic body, `a + b` dispatches through the struct's `(+)`
  at specialization; `s.(+)` projection is not syntax. (Verified:
  a doubling `(+)` gives `total Twice [1,2,3] = 22`; `Str` gives concat.)
* **Negative integer literal patterns are inexpressible** — no prefix
  minus, and patterns aren't expressions; use a guard. SEMANTICS.txt
  should say so when it grows a patterns section.
* **`charAt`/`Str.at` returns the character CODE** (Int; `Str.fromCode`
  is the inverse). Consistent everywhere but worth a docs line — it reads
  like it returns a one-char string.
* **No unit literal** — `()` doesn't parse in expression position; unit
  only arises from unit-returning calls.
* **Commit count is per write-effect, not per path** — writing one path
  twice reports "committed 2 file(s)". Cosmetic (`replay` in Txn.hs
  counts every `EWrite`); count distinct effect paths if it bothers you.
* **Case arms are expressions** — no bindings in arms; factor a helper
  (this matches STYLE.md's advice but bites when porting code).

## pos2.sol session findings (2026-07-24, later)

Building `examples/pos2.sol` (login hero + Register/Receipts/Inventory
dashboard, written in full STYLE.md idiom) plus a Node WebSocket driver
(`tests/e2e/`) surfaced and fixed two significant bugs:

* **Exponential multi-clause compilation — FIXED in Lang.hs.**
  `compileGroup` spliced the fallthrough continuation (the Core of ALL
  remaining clauses) verbatim into every failure point of a clause's
  pattern/guard match. Tuple + literal head patterns have >= 2 failure
  points, so the tree doubled per clause: 14 clauses 1.3s, 18 clauses
  26s, the 22-clause idiomatic `update` was OOM-killed. Fixed with a
  join point: the continuation is bound once per clause as a lambda
  (lambda lifting turns it into an ordinary supercombinator; failure
  sites become calls). After: 18 clauses 49ms, 60 clauses 83ms. The
  property differential (whose generated helpers exercise clause and
  guard fallthrough) plus the full battery validated the change.
  Notable because the style guide's own recommendation (prefer
  multi-clause) was previously a compiler DoS.

* **WebSocket UTF-8 corruption — FIXED in Web.hs.** `BC.pack`/`BC.unpack`
  are Char8 (Latin-1 truncation): any codepoint > 0xFF corrupted the
  frame — an em-dash (U+2014) went out as control byte 0x14 and broke
  the browser's `JSON.parse`. Fixed with dependency-free UTF-8
  encode/decode at the WS frame boundary (`utf8Enc`/`utf8Dec`).

Also observed: operator-named struct fields cannot be referenced as
values at all (`Numeric.(+)` is a parse error) — bare-operator dispatch
inside sig-generic bodies is the only route; and 1-based `!` claimed its
predicted victim (a 0-based `catalog ! k` in the first draft).

The E2E harness (`tests/e2e/`): `drive.js` runs a 16-check flow
(register, buys, qty grouping, checkout, receipts row, stock decrement,
restock, logout, wrong password, re-login with persisted revenue);
`persist.js` restarts the server against the same logs and verifies a
second cashier sees shared revenue/receipts/stock. `run-e2e.sh` runs
both. Requires node + `npm install ws` in tests/e2e.

The pos2 theme layer in Web.hs (`hero`, `nav`, `card-lg`, `hover-lift`,
badge variants, `tbl`, `price`, ...) is purely additive — pinned apps
are unaffected.

## Style pass (same session)

`lib/plparse.sol` and `lib/logic.sol` rewritten to STYLE.md idioms:
`Str.len`/`Str.at`/`Str.fromCode`/`List.append`/`List.rev`/`List.len`
instead of raw HAL calls and private re-implementations (`base2app`,
`revL`, `symsLen`'s fold); literal-pattern clause dispatch in the
tokenizer (`tok1`, `lexP2`) and `cmpName`; comma guards instead of
`base.and2` chains; `[]`/cons parameter patterns instead of `== []`
guards. `lib/std.sol` similarly touched. `lib/base.sol`, `lib/ui.sol`,
`lib/auth.sol` deliberately untouched: todo2.sol pins their content
hashes. Verified byte-identical behavior on examples/prolog.sol and the
full example sweep.
