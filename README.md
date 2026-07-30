# Sol — Scripting Language

`sol script.sol` parses, linearity-checks, desugars, lambda-lifts, compiles to
register bytecode, and runs the script inside one file-backed STM transaction.

## What is reused vs. new

Reused verbatim from the FPRISC compiler (`src/Lang.hs` is FPRISC.hs with ~40
new lines): the megaparsec parser, the desugarer to Core, lambda lifting, and
the linearity checker. New: `>` top-level eval statements, `@/path` literals,
the bytecode compiler (`src/Bytecode.hs`), the register VM (`src/VM.hs`), and
the transaction layer (`src/Txn.hs`).

## The VM

A dumb, mechanistic register machine, per the design discussion:

- **Scalar band**: LOADI/LOADS/MOVE/ARITH2/JMP/JZ/CALL/RET. Saturated
  arithmetic and comparisons are real opcodes, not calls.
- **CALL** carries no dynamism: lambda lifting removed closures upstream, so
  every call target is a known supercombinator. Frame size (`fnSlots`) is
  computed at compile time — the `slotsNeeded` analog from Codegen.hs.
- **APPLY** is `fpr_apply`'s twin: PAP accumulation until saturation. It only
  exists for genuinely higher-order code (pipelines with partial application).
- **HCALL** is the single trap into the Haskell HAL. Every unknown global
  becomes an HCALL, exactly the `fpr_g_*` extern discipline from hal.c: the
  bytecode never grows an opcode per device, the HAL table grows instead.
- **Fuel** is decremented at every function entry (the same contract the
  FPRISC compiler + actors.c use). Structured control flow means recursion is
  the only loop, so function entry is a guaranteed safepoint. In this
  single-actor PoC, exhaustion refills and counts (`fuelPreempts`); the
  refill site is where an actor scheduler slots in.
- **No heap ops, no GC, no closure op**: values are host values; ownership
  discipline is enforced upstream by linearity.

## The transaction (why `sol script.sol` is atomic)

The whole script session is one TRec; every host file it touches is a
TVar-like slot:

- first read of a path snapshots content (or absence) into the **read set**;
- writes buffer in the **write set** — the disk is untouched mid-script, but
  the script reads its own writes;
- at exit: lock every touched file (sorted order — no deadlock), validate the
  read set against the disk, apply the write set, unlock;
- validation failure = STM retry: the whole script re-runs (bounded, with the
  conflict reported).

Locks are atomic `mkdir` locks (`<path>.sol-lock`), so two concurrent `sol`
processes exclude each other with no daemon. Run `examples/counter.sol` twice
concurrently to watch one commit, the other detect the conflict, retry, and
land the correct final value.

### Crash atomicity (kill -9 / power loss during commit)

The commit is also atomic against crashes, not just script errors and
concurrent writers:

- every committed file is written to `<path>.sol-tmp`, fsynced, and
  **renamed** over the target — a file is entirely-old or entirely-new,
  never torn;
- after validation and before any disk mutation, the effect log is
  serialized to `<script>.soljournal` (fsynced, complete-or-absent). A
  crash mid-replay leaves the journal as the redo authority: the next run
  heals first, then executes normally. File effects redo idempotently;
  each deferred `shq` command that runs is fsync-marked in
  `<journal>.done` and redo skips marked ones (the marker window makes
  shell redo **at-least-once** — stated, not hidden);
- lock dirs carry an owner file (pid + journal path). A contended lock
  whose owner is dead is **reclaimed**: one reclaimer wins an atomic
  rename of the lock dir, finishes the dead owner's journal, and removes
  it. A crashed sol no longer wedges later runs on those paths.

Every crash window is deterministically testable: `SOL_CRASH_AT=n` hard-
exits (`_exit`, no cleanup) just before applying effect index n —
`tests/compose/c11_crash_atomic.sh` walks all five windows. `SOL_NOSYNC=1`
skips the fsyncs when bulk speed matters more than power-loss durability
(writes stay rename-atomic and the journal still heals a killed process);
the 200-file benchmark is ~0.13s with it, ~0.54s without.

Known PoC caveats: `print` is not transactional, so a retried script
re-prints; and a deferred command that FAILS still stops the replay with
effects after it unapplied (reported, journal cleared — a policy stop,
not a crash).

## The auto-provided std surface

Injected before every script (see `prelude` in Main.hs):

    Path = Type (Path String).
    Handle 1 = Type (Handle Int).
    open : Path -> Handle.
    readAll : Handle -> (String, Handle).
    writeAll : Handle -> String -> Handle.
    close : Handle -> Unit.

`Handle` is linear, so the unchanged FPRISC linearity checker makes leaking a
handle or using one twice a **compile error** (`examples/bad_leak.sol`,
`examples/bad_double.sol`). Every well-typed script provably closes what it
opens. `readPath`/`writePath` are conveniences written in Sol against that
API — the prelude eats its own cooking.

`@/tmp/foo.txt` is a path literal (a trailing `.` is the statement
terminator, same rule as `dotTerm`).

## Script ergonomics

`> expr.` at top level runs in file order; non-unit results echo as `=> v`.
The body is a full block, so `> h = open @/x; ...; close h3.` is one atomic
script step. A zero-arity `main`, if present, runs after the `>` statements.

`$` is Haskell-style low-precedence application (`print $ a + b`); it
parses to the same AST as parens, so module hashes are unaffected. Clause
guards accept comma-separated components including pattern-match bindings
(`f y | Just x <- y, x < 0 = x + 1.`) with fallthrough to the next clause
on match failure; list patterns (`[]`, `[a, b]`, `(x :: r)`) work in
parameter position. See STYLE.md for the conventions.

## gen_view: MVU web apps (View.serve)

    > View.serve 8080 init update view [(1000, "tick")].

`src/Web.hs` is the gen_* behavior: it owns HTTP delivery of the companion
JS client, the WebSocket handshake (hand-rolled SHA-1 + base64, pure
Haskell) and framing, the session table, the dyn-slot diff loop, the msg
log, the Cmd interpreter, and the subscription timers. Sol owns the logic
and never sees a socket:

    init   : token -> model
    update : msg -> model -> (model, Cmd)    -- msg = (eventName, valueString)
    view   : model -> node
    subs   : [(intervalMs, eventName)]

Views are plain Sol records — {tag, cls, kids}, {text}, {dyn, node},
{ev, val, node} (clickable), {btn, inp, ph} (input box). The compiler's
shape table is threaded into the runtime, so ANY record serializes to
named-key JSON generically; the ~60-line JS client builds DOM from it, with
a minimal tailwind-flavored utility sheet (flex/grid/gap/card/tab, one
responsive breakpoint).

The protocol is the FPRLive Static/Dyn split, lite: on hello the client
gets a session token plus the full view; after that only the {dyn} slots
whose JSON changed travel, as patches. The token lives in localStorage;
reconnecting with it gets the same model back.

### Persistence: event-sourcing the Msg stream

Model fields wrapped `Persistent x` are the durable part. After every
update the runner compares the persistent projection of the model
before/after; if it moved, the MSG (not the model) is appended to
`<script>.soldata` as a JSON line {"tok","ev","val"} and flushed — verified
kill -9 safe. On startup the log replays: each session's model is rebuilt
by folding update over its msgs. Cmds are NOT re-executed during replay,
but their result msgs were logged if they mattered — which is exactly how
nondeterminism (Rng) replays deterministically: the value is in the log,
not the request. Msgs that never touched a Persistent field were never
logged, so that runtime state (blog demo: lucky number, uptime ticks,
motd) is abandoned on restart by design, while tab + comments survive.

### Cmds and subscriptions

update returns (model, Cmd); the runner interprets:

    None | Print s | ReadFile path evName | Rng lo hi evName | Batch cmds

Print writes to the server console; ReadFile and Rng feed their results
back in as ordinary (evName, value) msgs, re-entering update — the MVU
circle, depth-capped against cmd loops. Subscriptions are timers: every
interval each CONNECTED session receives the msg and its changed dyn slots
are pushed over the socket — server-initiated UI updates with no client
event (the blog's uptime badge ticks by itself).

Notes: Sol callbacks serialize through one lock (the single-hart shadow);
`View.serve` never returns, so the script's file transaction never commits.
Build needs -threaded and libghc-network-dev.

### Shared KV store + Msg cmd (what auth is built from)

Two additions make multi-user apps expressible. `Put k v` / `Get k ev` cmds
read and write a store shared across ALL sessions, persisted to
`<script>.solkv` (append log, last write per key wins on load) — per-session
models can't express accounts or store-wide totals; the KV can. `Msg ev
val` self-dispatches a synthetic msg, and it is the key to replay-safe
login: the login msg carries the password but never touches persistent
state (not logged); the Get-reply check emits `Msg "setuser" name`, and
THAT self-contained msg is what moves the Persistent user field and lands
in the log. Result: sign-in survives restarts, and passwords never appear
in the msg log — only in the KV (plaintext; a real system hashes). The
runner also dispatches ("connected","") after every ws hello, which apps
use to refresh KV-backed data — replay skips cmds, so post-restart reloads
hang off connect instead.

### Three more apps (the pattern validated)

All three share the same ~25-line auth block (register/login/logout via KV
accounts + Msg setuser) and the multi-field {form, fields, btn} widget
(password inputs auto-detected client-side):

- examples/todo.sol (8081) — per-user todo lists stored in KV under
  `todos:<user>`, so the list follows the login across browsers. Toggle by
  index, clear-done, open-count badge. Verified: wrong-password rejection,
  cross-browser login, kill -9 + restart keeps both the signed-in session
  (replayed setuser) and the todos (KV).
- examples/dash.sol (8082) — live ops dashboard: a 500ms tick sub drives an
  Rng random-walk requests/sec series pushed to the browser with zero
  client events (ASCII bar chart); total sign-ins accumulate in KV via a
  Get -> Msg -> Put read-modify-write chain; the live series is runtime
  state and resets on restart by design.
- examples/pos.sol (8083) — point of sale: static Sol catalog, click-to-add
  cart (runtime), checkout folds the cart total into KV revenue shared by
  every cashier (verified: two cashiers, 23 then 23+4=27) and Print-logs
  the sale to the server console.

- examples/terra.sol (8084) — Terra II Lite: the card game's core loop.
  Per-player Forward/Rear zones (3 lanes), active supply from rear convoys,
  attack + counter-damage combat, rear protection (rear exposed only where
  the forward lane is empty), tactics (Barrage / Field Repair / Scorch),
  and the shared ENV track: +1 per round, +1 per kill, deterministic phase
  thresholds (Stable / Stressed / UV High / Acid Rain / Snowball /
  Collapse) applying ambient damage that shields soak. Win by HQ
  destruction through an empty lane. Hot-seat, both boards visible. The
  whole game state is one `Persistent` record, so the game IS its
  event-sourced msg log: kill -9 mid-game and replay reconstructs the
  exact board. ~330 lines of Sol; scoped out (deliberately): ambush,
  overwatch, artillery charge, four draw decks, per-faction ENV asymmetry,
  dice-rolled phases.

## File modules (content-addressed, process-isolated)


Every .sol file is a module, addressed by the hash of its AST:

    mymod = use "mymod#47c0102faf5cb7cd".
    runner x = run mymod x.
    > capture = (runner "hi").
    > print capture.

### Symbol imports + the Sol library layer

`use` now works at COMPILE TIME as well as runtime. `m = use "name#hash".`
splices the module's definitions into the program, renamed under the alias
(node -> web.node); `m.f` resolves qualified, `x = m.x.` aliases values,
and `T = m.T.` aliases an imported constructor/type so it works in
PATTERNS and signatures — `f (T x) = T (x + 1)` compiles against the
imported tid, and a linear type stays linear through the alias (verified:
double-consume of an imported linear resource is a compile error). Modules
contribute definitions only — their `> effect.` statements are dropped on
import — and module-uses-module nesting expands recursively with the same
hash verification as runtime use (compile-time pin hints included). The
runtime alias binding survives, so `run m x` still works on the same name.

That enabled a library layer (lib/), extracted from what was hardcoded in
the Haskell prelude or copy-pasted across apps:

- lib/base.sol — pI/and2/max0/takeN/removeAt/... plus the string helpers
  (substr/splitFirst/splitCh), REMOVED from the Haskell prelude: the
  runtime now injects only type declarations and HAL signatures.
- lib/web.sol — the entire view vocabulary (node/text/dynS/clickable/
  inputBox/formBox) plus conveniences (row/col/card/badge/btn/title).
- lib/auth.sol — the sign-in/registration pattern (doLogin/doAuth/doReg/
  doRegchk/loginView), itself built on base + web (nested use).

examples/todo2.sol is the todo app rebuilt on the libs with PINNED hashes —
the app file is now only its own logic. Known PoC honesty: two importers of
the same module each get a renamed copy (base.pI and auth.base.pI coexist);
content-addressed dedup is the natural fix and the hashes already exist.

`use` resolves the name (relative to the importing script's directory,
`.sol` appended if missing), parses the file, hashes the AST (FNV-1a 64 for
the PoC; a registry would use SHA-256 over a canonical serialization), and
verifies against the pin. Because the hash is of the AST, reformatting and
comments don't change a module's identity — code does. Unpinned `use
"mymod"` resolves, prints the hash so you can pin it, and proceeds. A
mismatch is an error showing both hashes.

`run mod x` executes the module in a SEPARATE PROCESS (a fresh `sol` on the
resolved file), writes `str x` to its stdin — the module reads it with
`input Unit` — and captures its stdout as a String. The hash is re-verified
at run time, so a pinned module can never run drifted code. Modules are
ordinary non-linear values: run them as many times as you like.

Transactionally, the child is its own session: its file commits are atomic
and independent, landing when the child exits — a sub-transaction inside
the parent's run. The interplay is honest STM: if the parent reads a file,
then `run`s a module that commits to it, the parent's read set is
invalidated at commit and the whole parent script retries. `run` itself is
a non-transactional effect (like `print`): a retried parent re-runs it.

### Machine learning (linreg / SVM / decision tree)

Training loops forced the JIT's most useful extension yet: the PARTIAL
APPLICATION tier. `Vec.fold (grad w1 w2 b) 0 v` captures the current
weights; captured args now ride into native code as leading typed params
(i64 or f64 bits) delivered through the driver's extras array — one compilation per
fold serves every epoch and every parameter value ([jit] lines report
"+ k captured scalar(s)"). Two rules this surfaced: (1) project the
element record ONLY inside the scheme function — helpers take scalars;
(2) symbols are now uniqued per compilation unit (two schemes sharing
fix.fmul used to collide in the JITDylib).

- examples/linreg.sol — full-batch gradient descent, three JITted gradient
  folds per epoch. Learned (1.745, -0.497, 0.249) vs true (1.75, -0.5,
  0.25); held-out MSE ~0. Bit-exact vs the interpreter.
- examples/svm.sol — linear SVM, hinge-loss subgradient descent with L2:
  the margin condition is a conditional inside the JITted fold. 99% train
  / 100% test on overlapping gaussian blobs. Bit-exact.
- examples/dtree.sol — depth-2 tree: split search packs all four class
  counts (left/right x pos/neg) into ONE i64 base-1024 inside a JITted
  fold with (feature, threshold) captured; build/partition/predict are
  interpreted structure work over a recursive `Tree = Type (Leaf x | Node
  a b c d)`. Recovers the generating rule exactly; 92% test vs a ~95%
  noise ceiling. Honest footnote: on XOR data every root split has ~zero
  first-order gain and greedy induction collapses to ~52% — the classic
  pathology, faithfully reproduced. Bit-exact.

lib/rand.sol is a pure-arithmetic LCG (deterministic datasets = replayable
experiments and diffable JIT/interpreter runs). Seed hygiene matters:
gauss4 consumes four draws, so independent features need next4-separated
streams — the correlated-features bug this caused was found because the
tree degenerated, a nice case of the model debugging the data.

### Transactional filesystem + safe tool orchestration

The script-session transaction now spans the whole filesystem, not just
named-file reads/writes. The HAL surface is TWO functions — `read` and
`write` — and everything else is prelude Sol over them: `mkdirp p = write
p Dir`, `ls p = read (Ls p)`, `sh c = read (Sh c)`, `print v = write
"/dev/out" v`, `mv` composes a read, a write, and an `Rm`. Structured `Io`
values and device paths are decoded by the HAL inside the transaction; the
linear handle quartet (open/readAll/writeAll/close) remains the separate
linearity tier. Every mutation is buffered in an ORDERED effect log and
applied atomically at commit; nothing touches disk mid-script. ls/exists/
stat compose the disk state with the txn's own pending adds/removes, so
the script always sees its own effects. Directory listings join the read
set and are validated at commit alongside file contents.

The external-tool question — shelling out breaks rollback — resolves by
SPLITTING COMMANDS BY EFFECT, capability-style:
  * sh cmd   — IMMEDIATE, for read-only tools (git status, docker ps).
    Runs now, returns (exitcode, output). Reruns on retry. The read-only
    claim is the caller's assertion; it cannot be enforced or validated.
  * shq cmd  — DEFERRED, for mutating tools (git commit, docker rm).
    Queued in declaration order with the file effects; runs INSIDE the
    commit, after validation. If the txn conflicts and retries, the queue
    is discarded — the command never ran. Proven deterministically
    (SOL_FORCE_RETRY=2): across 3 attempts, an sh probe ran 3x while a shq
    command ran exactly once, on the winning commit.
Honest limit: once a deferred command is released it CANNOT be rolled
back. A failing shq stops the replay and reports which queued effects did
not run — but effects already flushed stay flushed. External world =
one-way door; sol sequences the doorway, it can't un-ring the bell.

examples/fileops.sol scaffolds a project tree, line-counts a directory,
and prunes files by suffix — all atomic. examples/prolog.sol-style tool
use: examples show a git release (writePath + shq git add/commit)
committing the file and the git commit together, sequenced correctly.
Benchmark vs bash: ~4x slower on 200-file bulk writes (0.067s vs 0.016s) —
the cost of buffering, locking, and validation buys atomicity bash has no
way to offer. One conservative wrinkle: reading a directory you also mkdir
into self-conflicts once and retries (correct, mildly pessimistic).

### A Prolog interpreter (and the linear Vec earns its keep)

lib/logic.sol + lib/plparse.sol implement a Prolog engine (~600 lines of
Sol) that parses and runs the Infera-style syntax: facts, rules, queries,
juxtaposition compounds, wildcards, and is/%/+/-/*//>/</>=/<=/!=/= with
correct precedence. examples/prolog.sol runs the 8-bit CPU simulator
(cpu/5 state, instr/2 memory, step/2 per instruction, run/3) nearly
verbatim from the reference — all three programs produce the exact
reference results, including the dec/jnz countdown loop (backtracking
through clause alternatives) and carry-flag overflow detection.

The engine is where the linear mutable Vec pays off: the WAM's state model
IS linear types. One heap of tagged cells {tag, val} (REF/CON/INT/STR/FUN,
two unboxed i64 columns), destructively bound via Vec.set through the
linear handle, threaded as one machine through the entire search; a trail
records bindings, and backtracking = unwind trail + reset the heap's soft
top (cells above are reused by later allocations — no garbage, no copies,
no persistent maps). Structure-copying resolution rather than compiled WAM
instructions; no occurs check; != decided at call time; DFS with fuel —
all declared. The three-layer stack (Haskell -> Sol -> Prolog) runs the
full CPU suite in ~0.1s.

Building it forced two module-system fixes with teeth: (1) renameTops now
renames constructors in case patterns INSIDE bodies (imported `case x of
Nope -> ...` previously kept the unqualified name); (2) imports now DEDUP
BY CONTENT HASH — the app's `use logic` and the parser library's nested
`use logic` splice once and share one set of declarations, so a PT value
built by the library unifies with the app's patterns. Before the fix they
were two distinct types with two tids and every query failed; exactly the
duplication noted as future work in the symbol-import session, now load-
bearing and closed.

### A real tool: SPICE netlist -> breadboard placer

examples/bboard.sol ports a Python+clingo circuit-placement tool to pure
Sol (~340 lines): a SPICE netlist parser (R/C/L/D/B components, V/I
sources, comments/directives), net classification (GND/PWR/signal), a
placer, a wiring planner (jumpers between a net's strips, rail wires for
power nets), self-verification, and a 30-row ASCII breadboard render.

The one non-portable piece was clingo: the ASP search became a transparent
greedy scorer over the same constraint set — reject shared holes and
cross-net strips, reward placing a pin on a strip already carrying its net
(+100), charge jumper debt for ignoring an existing strip (-40), pull
toward centre rows. At 56 candidate positions per component, greedy
recovers the same layouts the solver found (direct strip sharing where
possible, gap-straddling splits where not). Strips encode as row*2+side,
so "two rows down, same side" is key+4.

Unlike the numeric examples this runs fully interpreted — parsing,
assoc-list state threading, and string rendering are exactly what the
interpreter tier is for, and the whole pipeline is <100ms. The checks
section is computed, not asserted: one-net-per-strip and jumpers ==
strips-1 per net are verified from the final state.

## Matrices + CSV (lib/matrix.sol)

`lib/matrix.sol` is the everyday-python tier: a 2D Numeric matrix over the
linear SoA Vector, with CSV in and out.

    Matrix 1 = Type (Mat Int Int Vector)

The wrapper is linear and the Vector field is DECLARED, so the checker
tracks the payload: dropping a matrix, using one twice, or leaking the Vec
out of a destructure is a compile error (two cases in c9 prove it).
Interrogations thread — `(x, Matrix)` back, same shape as `Vec.len`.

Surface (`mx = use "../lib/matrix". M = mx.M.`): fromRows / fill / dims /
get / set / row / col / head / selectRows / selectCols / map / fold /
mapRow / mapCol / mapRows / transpose / mul / mulVec / colMeans /
fromCsv(Header) / toCsv(Header) / show / free. Elementwise `M.map` and
`M.fold` are one Vec.map/Vec.fold over the row-major cells column, so
they hit the typed JIT tier (`examples/csvmatrix.sol` shows the [jit]
lines on a 50000x3 matrix); indexed work (matmul, selection) threads the
Vec through get/set the way the Prolog engine threads its heap. Cells are
Numeric: integer CSVs stay exact, and inexactness enters only through
`Numeric.div` (colMeans) and propagates. CSV rendering goes through BStr
— the interpolation fold over a big matrix is exactly the O(n^2) trap
the byte-buffer tier exists for.

`examples/csvmatrix.sol` is the end-to-end demo: generate two random
integer CSVs (lib/rand LCG), read them back, head/select/map, gram =
a·aᵀ, matvec, column means, and write the result CSV — all inside the
one script transaction, so the outputs exist complete or not at all.
`tests/compose/c12_matrix.sol` pins every op to hand-computed values.

## Scientific computing: the Numeric datatype and the typed JIT tier

Sol has ONE number surface. `1 + 1` is exact bignum arithmetic and `/` on
two Ints is quot, exactly as before; inexactness enters through
`Numeric.div` (true division), `Numeric.sqrt`, or `Numeric.inexact`, and
then PROPAGATES — any `+ - * <` touching an inexact value promotes,
Julia-style, and a result that lands back on an integer renders as one.
No float literals, no fixed-point library, no second set of operators
(lib/fix.sol survives as a museum piece; nothing uses it).

The JIT follows the same philosophy as inference-as-optimization. A small
type lattice — JI (provably Int), JD (provably inexact), JW (widened:
could be either, stored promoted), JB (inference bottom) — types every
fold/map closure per CALLSITE: helpers specialize per argument-type
vector (linreg's epoch-1 gradient fold with int-zero weights and its
later f64-weight fold are two native variants), KNum record fields live
in unboxed f64 SoA columns next to i64 ones, captured inexact scalars
ride as f64 bits in the extras array, and Num.div/sqrt/floor/round
compile to fdiv and llvm.sqrt/floor/rint intrinsics (rint's nearest-even
IS Haskell's `round`). The ONE operation where exact and inexact
semantics diverge is division — so `/` over int-ambiguous (JW) operands
bails to the interpreter, as does any JW value escaping native code, and
everything that does compile is BIT-IDENTICAL to the interpreter
(tests/compose/c10_typed_jit.sol locks this; 40 epochs of a 50k-row
sqrt-fold: ~12s interpreted, ~0.3s native).

- examples/physics.sol — ballistics ensemble: semi-implicit Euler with
  QUADRATIC drag (a = -c|v|v), plain operators + Numeric.sqrt in the hot
  loop. The recursive integrator compiles natively over the int launch
  columns with f64 state, and the drag-free variant is asserted against
  the closed form R = 2 vx vy / g. Bit-exact vs the interpreter.
- examples/mandel.sol — Mandelbrot with plain complex-square arithmetic
  on Numeric coordinates; the per-pixel escape map compiles natively;
  pixel-exact between tiers.

Getting here surfaced and fixed three JIT-tier gaps: (1) the clause
compiler rebinds parameters (CLet p (CVar a1_k)), so the dual checker and
codegen now track LET-ALIASES of the element parameter — named functions
JIT like lambdas do; (2) `case c of True/False` desugars through CTagEq on
bools, now compiled as an integer compare; (3) the unreachable CErr tail of
an exhaustive bool match is stripped (reachable non-bool tails still
reject). And one semantic alignment: the interpreter divided with
Haskell's flooring `div` while LLVM sdiv, C, and RISC-V DIV all truncate
toward zero — the interpreter now uses `quot`, so all tiers (and the
eventual metal) agree bit-for-bit on negative operands.

Honesty notes: i64 overflow and division-by-zero inside native code are the
programmer's problem (the interpreter is bignum and panics respectively;
native fdiv-by-zero yields inf where the interpreter panics — same stance).
f64 comparisons against promoted ints are exact only within 2^53. Native
recursion has no fuel CHECK (the cell only decrements), so a
non-terminating element function hangs harder than interpreted code.
SOL_JIT_DEBUG=1 explains any silent fallback to the interpreter.

## The linear SoA Vector

A builtin `Vector`: growable (push_back with doubling realloc, amortized
O(1)), O(1) random access, and **automatically SoA** — the layout is fixed
by the first push:

- a product value (record, tuple, single-variant data) decomposes into one
  column per field: Int fields land in unboxed malloc'd i64 columns,
  inexact Numeric fields in unboxed f64 columns (both JIT-ready),
  everything else in boxed columns. `{age : Int, name : String}` stores as
  an ages column + a names column. Layouts print in [jit] lines as e.g.
  r104:ddi — two f64 columns and an i64 one.
- a plain Int gives a scalar unboxed column; anything else a scalar boxed
  column.

`Vector` is declared LINEAR in the prelude, and that is what makes the whole
design sound: single ownership licences in-place mutation (`Vec.push`/
`Vec.set` mutate the store and hand the same reference back as the "new"
vector) and licences lending raw column pointers to native code. The checker
rejects use-after-consume at compile time — it caught the first draft of
examples/vec.sol doing exactly that.

API (vector always LAST, for `|>` pipelines):

    Vec.new : Unit -> Vector.              Vec.push : a -> Vector -> Vector.
    Vec.len : Vector -> (Int, Vector).     Vec.get : Int -> Vector -> (a, Vector).
    Vec.set : Int -> a -> Vector -> Vector.
    Vec.map : (a -> b) -> Vector -> Vector.
    Vec.filter : (a -> Bool) -> Vector -> Vector.
    Vec.fold : (b -> a -> b) -> b -> Vector -> (b, Vector).
    Vec.fromList / Vec.toList / Vec.free.

`v ! i` is O(1) but consumes the vector (linearity); `Vec.get` is the
keep-the-vector form. Both RECONSTRUCT the product from the columns — the
deliberately slower escape hatch, same path explicit pattern matching takes.

**Dualization.** `Vec.map` / `Vec.filter` / `Vec.fold` are the fast path.
Over the JIT threshold, an element function like `fn s -> s.age + 1`
compiles against the SoA layout as its dual `fn cols i -> ages[i] + 1`:
every `CProj k (CVar s)` in Core becomes `load (cols[k])[i]` in IR, and the
driver runs directly on the lent column pointers — zero marshalling, boxed
columns never touched (the jittability guard proves it). `Vec.filter`
computes the predicate natively and returns kept-row INDICES; the VM gathers
full rows — including boxed name columns — from them. Below threshold or
with non-arithmetic element functions, the interpreted dual reconstructs
each row and applies the function.

Measured (examples/vecbench.sol, 200k rows {key, val}, filter+map+fold):
the interpreted scheme portion costs ~1.8s; the dualized native portion is
within measurement noise (<30ms) — the pipeline is effectively free next to
building the vector. Layout-specialized code caches per (scheme, fn,
layout) triple.

Known caveat (same as the list tier): a comparison-returning function
JIT-maps to 0/1 ints where the interpreter would store Bools.

## The JIT tier (LLVM ORC)

`src/JIT.hs` + `cbits/shim.c`. No llvm-hs is packaged for this toolchain, so
the JIT talks to the LLVM-C ORC (LLJIT) API through ~40 hand-rolled FFI
imports; the C shim is 10 lines, existing only because the native-target
init functions are `static inline` in llvm-c/Target.h.

Policy, per the design discussion: **recursion schemes only** — `map`,
`filter`, `foldl` — and only when the list clears `jitThreshold` (64).
Guards, all falling back to the interpreted loop when unmet:

- every element is an unboxed Int
- the element function is an unapplied top-level supercombinator whose call
  closure is arithmetic-only Core (ints, arith/cmp, if, let, saturated calls
  to other such functions — recursion allowed and compiled alongside)

The schemes are provably bounded (one element-function call per element), so
they need no preemption; fuel is still counted — **reified** into the native
code as a decrement-at-function-entry on a fuel cell passed by pointer, the
same contract the interpreter and the C runtime use — and the cell is
reconciled with the VM counter when the pure native call returns
(`withFuelCell`; at most one preempt is booked per native call, an honest
simplification). RC is trivially reified too: the Int-only specialization has
nothing to refcount, and the marshalled array is the builder→freeze boundary.

The IR codegen is deliberately the bytecode compiler's twin — same
slot-per-value discipline, `LLVMBuild*` where Bytecode.hs has `emit`, `CIf`
as alloca/store/br/load instead of Move/Jz, no phi nodes. Compiled
(scheme, fn) pairs cache per process and survive STM retries.

Measured on `examples/bench.sol` (sum of 100k Collatz lengths, list build
interpreted in both runs): interpreted 16.7s, JIT 0.51s — ~33× end to end.
`SOL_JIT=0` disables the tier. A user-defined `map`/`filter`/`foldl` shadows
the scheme (program bindings dispatch before HAL symbols).

## Building / running

    apt-get install ghc libghc-megaparsec-dev libghc-network-dev llvm-dev
    gcc -c cbits/shim.c -o cbits/shim.o $(llvm-config --cflags)
    ghc -O1 -threaded -isrc -o sol src/Main.hs cbits/shim.o -L$(llvm-config --libdir) -lLLVM-18

    ./sol examples/hello.sol
    ./sol --asm examples/hello.sol      # disassemble the bytecode
    echo 0 > /tmp/sol-counter.txt
    ./sol examples/counter.sol & ./sol examples/counter.sol &   # watch a retry

## Where this goes next

- the actor band (SPAWN/SEND/RECV) drops into the fuel-refill site; per-sender
  SPSC channel semantics can mirror actors.c directly
- TVars need not be files: the same TRec shape works over any content-addressed
  store, which is the FPR OS object-store commit protocol in miniature
- hot reload: CALL is already resolved by name per activation, so patching the
  function table between transactions is the natural reload point

## Creating Invokable Sol Scripts

Create an extensionless file like `myscript` somewhere, preferrably in a version controlled or private area. Add the env shebang `#!/usr/bin/env sol` to automatically resolve `sol` from PATH (works if you cabal install it). Then:

```
chmod +x path/to/myscript
ln -s /path/to/myscript ~/.local/bin/myscript
```

Create a link to it in $HOME/.local/bin. Now `myscript` usable from anywhere in the chroot without any further env or PATH modifications.

To delete it, simply just delete the link in .local bin.
