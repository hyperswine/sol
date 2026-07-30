# sweep.sol — the posix regression sweep, replacing posix-sweep.sh.
#
# Run from the repo root:   sol tools/sweep.sol
#
# What the bash version was: a here-doc table of `name|expect;expect`
# strings, parsed at runtime by `IFS='|' read` inside a `while` inside a
# pipeline, with `grep -qF` per expectation and a subshell that lost the
# PASS/FAIL counters. What it is here: a list of values, a fold, and one
# transactional report.
#
# The transaction earns its keep at the end: the report file either exists
# complete or does not exist at all, even if the sweep is killed halfway.
# The progress log is the one deliberate realtime escape, because a sweep
# that takes four minutes needs to be tailable while it runs.

h = use "harness#934372c47bdc1257".

# ---- the table -------------------------------------------------------------
# One case per test: the program under tests/, the substrings its output must
# contain, and whether the test is expected to FAIL (the `!name` rows in the
# bash version -- those assert that a panic happens).

Case = Type (Case name expects wantFail).

cases =
  [ Case "actors" ["actor demo done"] False,
    Case "ring" ["arc live after 100k promote/drop cycles: 4"] False,
    Case "smp" ["smp smoke done"] False,
    Case "smpstress" ["20000 cross-hart blocking round trips survived"] False,
    Case "smpdead" ["deadlock"] True,
    Case "psort" ["psort OK"] False,
    Case "vectest" ["vec generic tier OK"] False,
    Case "vecbench" ["vecbench done"] False,
    Case "vectime" ["vectime done"] False,
    Case "vsimd"
      [ "axpb/sar: [2, 3, 5, 6, 8, 9]",
        "gather:   [40, 10, 20, 0]",
        "zipEq:    [0, 0, 1, 0, 0]",
        "absv:     [2, 1, 0, 1, 2]",
        "blit:     [7, 7, 50, 7, 52, 7, 7, 7]",
        "vsimd done" ] False,
    Case "slab" ["slab churn total = 300  arcLive after = 0"] False,
    Case "modtest" ["dispatch by hash + name", "Mod.has V2    = True"] False,
    Case "tuitest" ["glyphRow: 47", "glyphRows: 5", "clockrows: 24", "tuitest done"] False,
    Case "modurl"
      [ "good url : hit, f 21 = 42",
        "bad fn   : miss (as data)",
        "bad hash : miss (as data)",
        "modurl done" ] False,
    Case "orig1" ["main => 1341"] False,
    Case "orig2" ["shadowed (+): 2 + 3    = 7", "typeid plus strings    = 5"] False,
    Case "orig3" ["main => 585"] False,
    Case "orig4" ["main => 60"] False,
    Case "typed"
      [ "ops: 42 fprisc",
        "generic: total Int=10 total Str=abc",
        "sstring: len=2 at1=104 str=hi",
        "vlist: fold=60" ] False,
    Case "precond" ["amount: 80 100 75 75 0 7", "avg: 30 0  precond done"] False,
    Case "precondviol"
      ["precondition violated: double requires (n > 0), got n=-3 (in poke)"] True ].

# ---- one case --------------------------------------------------------------

Res = Type (Res name ok reason).

# build, run, judge. Clause patterns rather than nested `case` blocks: the
# bash version's control flow was the unreadable part, and this is where the
# rewrite pays for itself.
runCase repo (Case name expects wantFail) =
  bc = h.shCode "cd {repo} && timeout 120 make -s posix.bin PROG=tests/{name}.fpr > /dev/null 2>&1";
  afterBuild repo name expects wantFail bc.

afterBuild repo name expects wantFail bc | bc != 0 = Res name False "build failed".
afterBuild repo name expects wantFail bc =
  judge name expects wantFail (sh "cd {repo} && timeout 120 ./posix.bin < /dev/null 2>&1").

# a test's own output is small, so the expectation search stays in Sol where
# it is legible; `missing` names exactly which needles were absent
judge name expects wantFail (rc, out) =
  panicked = h.contains out "FPRISC PANIC";
  miss = h.missing out expects;
  exitOk = case wantFail of True -> rc != 0 | False -> h.and2 (rc == 0) (h.not2 panicked);
  verdict name (h.and2 exitOk (miss == [])) rc wantFail panicked miss.

verdict name True rc wantFail panicked miss = Res name True "".
verdict name False rc wantFail panicked miss =
  Res name False (why rc wantFail panicked miss).

why rc wantFail panicked miss | h.not2 (miss == []) = "missing {miss}".
why rc wantFail panicked miss | panicked = "unexpected panic".
why rc wantFail panicked miss | wantFail = "expected failure, exited 0".
why rc wantFail panicked miss = "exit {rc}".

# ---- the sweep -------------------------------------------------------------

logp = "/tmp/sol-sweep-progress.log".

sweep repo cs = map (fn c -> emit (runCase repo c)) cs.

# each verdict lands the moment it is known: `print` is already immediate,
# and the progress file is appended in realtime so another terminal can tail
# the sweep while it runs
emit (Res name ok reason) =
  line = verdictLine name ok reason;
  u = print line;
  u2 = h.progress logp line;
  Res name ok reason.

verdictLine name True reason = "PASS {name}".
verdictLine name False reason = "FAIL {name} ({reason})".

okOf (Res name ok reason) = ok.
nameOf (Res name ok reason) = name.
reasonOf (Res name ok reason) = reason.

passes rs = filter (fn r -> okOf r) rs.
fails rs = filter (fn r -> h.not2 (okOf r)) rs.

report rs =
  p = List.len (passes rs);
  f = List.len (fails rs);
  "sweep: {p} pass, {f} fail{h.nl}{failLines (fails rs)}".

failLines rs | rs == [] = "".
failLines rs =
  case rs of
    r :: rest -> "  FAIL {nameOf r}: {reasonOf r}{h.nl}{failLines rest}".

# ---- go --------------------------------------------------------------------

> repo = h.repoRoot Unit;
  u = print "sweep: {List.len cases} cases under {repo}/tests (progress: {logp})";
  u2 = writeNow logp "";
  rs = sweep repo cases;
  rep = report rs;
  u3 = print rep;
  # the report lands atomically: complete, or not there at all
  u4 = writePath "{repo}/sweep-report.txt" rep;
  print "report -> {repo}/sweep-report.txt".
