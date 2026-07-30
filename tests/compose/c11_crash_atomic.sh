#!/bin/bash
# c11_crash_atomic.sh — the crash windows of the commit protocol, each one
# deterministically exercised via SOL_CRASH_AT (hard _exit just before
# applying effect index N — the honest kill -9 simulation) and verified
# to heal on the next run.
#
# The script under test writes three files and queues one shq command;
# its effect log is therefore, in order:
#   0: EWrite a.txt   1: EShell (echo ran >> shell.log)   2: EWrite b.txt
#   3: EWrite c.txt
set -u
cd "$(dirname "$0")/../.."
SOL=${SOL:-./sol}
D=/tmp/sol-c11
fail=0
say() { echo "$1"; }
bad() { echo "FAIL $1"; fail=1; }

mk() {
  rm -rf "$D"; mkdir -p "$D"
  cat > "$D/prog.sol" <<'EOF'
> u1 = writePath @/tmp/sol-c11/a.txt "A2";
  u2 = shq "echo ran >> /tmp/sol-c11/shell.log";
  u3 = writePath @/tmp/sol-c11/b.txt "B2";
  u4 = writePath @/tmp/sol-c11/c.txt "C2";
  print "script body done".
EOF
  echo "A1" > "$D/a.txt"; echo "B1" > "$D/b.txt"; echo "C1" > "$D/c.txt"
  : > "$D/shell.log"
}

runsol() { (cd "$D" && "$OLDPWD/$SOL" prog.sol) ; }

# ---- window 1: crash BEFORE the shell effect (after a.txt applied) --------
mk
( cd "$D" && SOL_CRASH_AT=1 "$OLDPWD/$SOL" prog.sol >/dev/null 2>&1 )
[ "$(cat "$D/a.txt")" = "A2" ] || bad "w1: a.txt should be new (applied before crash)"
[ "$(cat "$D/b.txt")" = "B1" ] || bad "w1: b.txt should be old (crash before it)"
ls "$D"/*.sol-tmp >/dev/null 2>&1 && bad "w1: torn .sol-tmp left behind"
[ -f "$D/prog.soljournal" ] || bad "w1: journal missing after crash"
[ -d "$D/a.txt.sol-lock" ] || bad "w1: crashed process should still hold locks"
say "ok w1: crash mid-replay leaves whole files + a journal + stale locks"

# heal: rerun the same script; recovery must complete the OLD commit
# (including the shell, which never ran), then the body runs and commits again
out=$(runsol 2>&1)
echo "$out" | grep -q "recovering interrupted commit" || bad "w1: no recovery message"
echo "$out" | grep -q "reclaimed stale lock" || bad "w1: stale locks not reclaimed"
[ "$(cat "$D/b.txt")" = "B2" ] || bad "w1: b.txt not healed"
[ "$(cat "$D/c.txt")" = "C2" ] || bad "w1: c.txt not healed"
[ "$(grep -c ran "$D/shell.log")" -eq 2 ] || bad "w1: shell should run once in redo + once in rerun (got $(grep -c ran "$D/shell.log"))"
[ -f "$D/prog.soljournal" ] && bad "w1: journal not cleared"
ls -d "$D"/*.sol-lock >/dev/null 2>&1 && bad "w1: locks not cleaned up"
say "ok w1: rerun heals — files complete, journal cleared, locks freed"

# ---- window 2: crash AFTER the shell effect (before b.txt) ----------------
# the done-marker must stop the redo from running the command a second time
mk
( cd "$D" && SOL_CRASH_AT=2 "$OLDPWD/$SOL" prog.sol >/dev/null 2>&1 )
[ "$(grep -c ran "$D/shell.log")" -eq 1 ] || bad "w2: shell should have run exactly once before crash"
out=$(runsol 2>&1)
echo "$out" | grep -q "skipping already-run command" || bad "w2: redo did not honor the done marker"
# 1 (before crash, marked done, skipped in redo) + 1 (the rerun's own commit)
[ "$(grep -c ran "$D/shell.log")" -eq 2 ] || bad "w2: done-marked shell re-ran in redo (got $(grep -c ran "$D/shell.log"))"
[ "$(cat "$D/b.txt")" = "B2" ] || bad "w2: b.txt not healed"
say "ok w2: shell done-marker makes redo skip the already-run command"

# ---- window 3: crash BEFORE the commit point (journal incomplete) ---------
# fake it: a journal tmp that never got renamed must be invisible, and a
# syntactically broken journal must be discarded, not half-replayed
mk
echo "SOLJ1" > "$D/prog.soljournal"   # no effects line, no COMMIT
out=$(runsol 2>&1)
echo "$out" | grep -q "discarding incomplete journal" || bad "w3: incomplete journal not discarded"
[ "$(cat "$D/a.txt")" = "A2" ] || bad "w3: script did not run normally after discard"
say "ok w3: incomplete journal is discarded, not replayed"

# ---- window 4: stale lock with no journal (crash after clearJournal) ------
# another process's dead lock must be reclaimed and the run proceed
mk
mkdir -p "$D/a.txt.sol-lock"
printf '999999999\n/nonexistent.soljournal\n' > "$D/a.txt.sol-lock/owner"
out=$(runsol 2>&1)
echo "$out" | grep -q "reclaimed stale lock" || bad "w4: dead-pid lock not reclaimed"
[ "$(cat "$D/a.txt")" = "A2" ] || bad "w4: commit did not proceed after reclaim"
say "ok w4: dead-owner lock reclaimed without manual cleanup"

# ---- window 5: a LIVE lock must still block (reclaim must not steal) ------
mk
mkdir -p "$D/a.txt.sol-lock"
printf '%s\n/nonexistent.soljournal\n' "$$" > "$D/a.txt.sol-lock/owner"   # our own live pid
out=$(runsol 2>&1)
echo "$out" | grep -q "could not lock" || bad "w5: live-owner lock was not respected"
[ "$(cat "$D/a.txt")" = "A1" ] || bad "w5: commit went through a held lock"
say "ok w5: live-owner lock still excludes (reclaim probes, does not steal)"

rm -rf "$D"
[ $fail -eq 0 ] && say "c11 crash-atomic: ALL GREEN"
exit $fail
