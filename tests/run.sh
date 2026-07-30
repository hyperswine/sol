#!/bin/bash
# tests/run.sh — the whole test story in one command:
#   1. property suite (hedgehog differential vs SEMANTICS.txt + sugar laws)
#   2. composition programs (features crossed in unexpected ways)
#   3. negative linearity tests (must be rejected)
#   4. example regression sweep
# Build the props binary first if needed:
#   ghc -O0 -threaded -isrc -itest -o props test/Props.hs cbits/shim.o \
#       -L$(llvm-config --libdir) -lLLVM-18       # (or: cabal test)
set -u
cd "$(dirname "$0")/.."
fail=0

if [ -x ./props ]; then
  echo "--- properties ---"
  ./props || fail=1
else
  echo "--- properties: SKIPPED (no ./props binary; see header) ---"
fi

echo "--- composition programs ---"
for f in tests/compose/c*.sol; do
  out=$(./sol "$f" 2>&1)
  if echo "$out" | grep -qE "FAIL|ERRORS|PANIC|error:"; then
    echo "FAIL $f"; echo "$out" | head -5; fail=1
  else
    echo "ok   $f ($(echo "$out" | grep -c '^ok ') checks)"
  fi
done

echo "--- negative tests ---"
tests/compose/c9_neg_linearity.sh || fail=1

echo "--- crash atomicity ---"
tests/compose/c11_crash_atomic.sh || fail=1

echo "--- example regression sweep ---"
echo -n "0" > /tmp/sol-counter.txt
for f in hello structs modules example fileops vec dtree svm linreg mandel counter jit prolog csvmatrix bstr realtime bboard physics vecbench; do
  if SOL_JIT=${SOL_JIT:-1} timeout 120 ./sol "examples/$f.sol" > /tmp/ex_out 2>&1; then
    echo "ok   examples/$f.sol"
  else
    echo "FAIL examples/$f.sol"; head -3 /tmp/ex_out; fail=1
  fi
done

[ $fail -eq 0 ] && echo "ALL GREEN" || echo "FAILURES ABOVE"
exit $fail
