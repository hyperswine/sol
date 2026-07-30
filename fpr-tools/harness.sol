# harness.sol — shared pieces for the Sol replacements of tools/*.sh.
#
# The division of labour here is deliberate, and it is the whole argument
# for writing a build harness in Sol rather than bash:
#
#   * DECISIONS live in Sol — the table of expectations, pass/fail logic,
#     the report text. That is the part that was unreadable in bash
#     (nested `case` inside `while read` inside a pipeline) and it is the
#     part you actually maintain.
#   * BYTE-SHOVELLING stays a tool call. Sol strings are linked lists, so
#     `Str.at`/substr are O(i) and a char loop over a megabyte log is
#     quadratic. grep and sed are the right instruments for that; Sol
#     calls them and decides what their answers mean.
#   * The REPORT is written transactionally, so a sweep either produces a
#     complete report or none at all. The PROGRESS log uses the realtime
#     escape on purpose: a progress log you cannot tail while the sweep
#     runs is useless, and that is exactly the case the escape is for.

nl = Str.fromCode 10.

# ---- strings ---------------------------------------------------------------
# Costs are O(n) per character because of the list representation; these are
# for the tens-of-lines outputs a single test prints, not for whole logs.

substr s i j = case i > j of True -> "" | False -> "{Str.fromCode (Str.at s i)}{substr s (i + 1) j}".

findCh c s i | i > Str.len s = 0.
findCh c s i = case Str.at s i == c of True -> i | False -> findCh c s (i + 1).

# 1-based index of needle in hay, or 0
findStr hay needle | needle == "" = 1.
findStr hay needle = findFrom hay needle 1 (Str.len hay - Str.len needle + 1).
findFrom hay needle i last | i > last = 0.
findFrom hay needle i last =
  case substr hay i (i + Str.len needle - 1) == needle of
    True -> i
  | False -> findFrom hay needle (i + 1) last.

contains hay needle = findStr hay needle > 0.

splitCh c s | s == "" = [].
splitCh c s =
  k = findCh c s 1;
  case k of
    0 -> [s]
  | _ -> substr s 1 (k - 1) :: splitCh c (substr s (k + 1) (Str.len s)).

lines s = splitCh 10 s.

isSpace c = or2 (c == 32) (or2 (c == 10) (or2 (c == 13) (c == 9))).
trimL s | s == "" = "".
trimL s = case isSpace (Str.at s 1) of True -> trimL (substr s 2 (Str.len s)) | False -> s.
trimR s | s == "" = "".
trimR s = case isSpace (Str.at s (Str.len s)) of True -> trimR (substr s 1 (Str.len s - 1)) | False -> s.
trim s = trimR (trimL s).

and2 a b = case a of True -> b | False -> False.
or2 a b = case a of True -> True | False -> b.
not2 a = case a of True -> False | False -> True.

# ---- expectations ----------------------------------------------------------

# the needles that are NOT in the output (empty list = all present)
missing out xs = filter (fn e -> not2 (contains out e)) xs.

# ---- shelling out ----------------------------------------------------------
# `sh` is immediate and captured: right for a quick read-only tool whose
# output we want to inspect. It re-runs if the transaction retries, which is
# harmless for a read-only command and is the caller's assertion.

shOut c = case sh c of (code, out) -> out.
shCode c = case sh c of (code, out) -> code.
shOk c = shCode c == 0.

# the working directory the harness was launched from, so these scripts
# behave like the shell scripts they replace: run them from the repo root
repoRoot u = trim (shOut "pwd").

# ---- progress -------------------------------------------------------------
# REALTIME on purpose. Everything else in these harnesses is transactional;
# this one line is not, because the point of a progress log is that it is
# visible before the run finishes. Sol prints the warning for us.

progress logp msg = appendNow logp "{msg}{nl}".
