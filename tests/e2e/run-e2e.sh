#!/bin/bash
# run-e2e.sh — boots examples/pos2.sol fresh, drives the full user flow,
# then restarts against the same logs and verifies shared persistence.
# Needs: node, and `npm install ws` in this directory.
set -u
cd "$(dirname "$0")/../.."
pkill -f "sol examples/pos2" 2>/dev/null; sleep 0.5
rm -f examples/pos2.soldata examples/pos2.solkv
./sol examples/pos2.sol > /tmp/pos2.log 2>&1 < /dev/null &
SRV=$!
for i in $(seq 1 30); do curl -s -m 1 -o /dev/null http://127.0.0.1:8084/ && break; sleep 0.5; done
( cd tests/e2e && timeout 60 node drive.js ); rc1=$?
kill $SRV 2>/dev/null; sleep 0.5
./sol examples/pos2.sol >> /tmp/pos2.log 2>&1 < /dev/null &
SRV=$!
for i in $(seq 1 30); do curl -s -m 1 -o /dev/null http://127.0.0.1:8084/ && break; sleep 0.5; done
( cd tests/e2e && timeout 40 node persist.js ); rc2=$?
kill $SRV 2>/dev/null
[ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] && echo "E2E ALL GREEN" || echo "E2E FAILURES"
[ $rc1 -eq 0 ] && [ $rc2 -eq 0 ]
