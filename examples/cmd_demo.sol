#!/usr/bin/env sol
# Demonstrates the cmd builtin: wrapping host executables as first-class
# Sol values with automatic flag/named-arg → shell-word conversion.
#
# Run this script from the repo root.  It uses tools that are commonly
# available on macOS / Linux (git, wc, find).  No network access needed.

echo "=== cmd builtin demo ===".
echo "".

# ------------------------------------------------------------------
# 1. Wrap an executable as a Sol value
# ------------------------------------------------------------------
echo "1. Wrapping executables with cmd".
git   = cmd "git".
wc_   = cmd "wc".
find_ = cmd "find".
git_s = str git.
wc_s  = str wc_.
echo "git value:  {git_s}".
echo "wc  value:  {wc_s}".
echo "".

# ------------------------------------------------------------------
# 2. Basic invocation — returns {exitcode, stdout, stderr}
# ------------------------------------------------------------------
echo "2. Basic invocation".
res    = git "rev-parse" "--abbrev-ref" "HEAD".
branch = trim res.stdout.
exitc  = res.exitcode.
echo "Current git branch: {branch}".
echo "Exit code:          {exitc}".
echo "".

# ------------------------------------------------------------------
# 3. Boolean @flag → --flag, !flag → --no-flag
# ------------------------------------------------------------------
echo "3. Flag sigils → --flag / --no-flag conversion".
log_res = git "log" @oneline "--max-count=5".
lines_ = lines log_res.stdout.
echo "Last 5 commits (--oneline):".
each echo lines_.
echo "".

# ------------------------------------------------------------------
# 4. Named args key:val → --key val
# ------------------------------------------------------------------
echo "4. Named args → --key val conversion".
count_res = git "log" "--format=%H" "--max-count=10".
commit_count = len (lines count_res.stdout).
echo "Commits fetched (max 10): {commit_count}".
echo "".

# ------------------------------------------------------------------
# 5. Error handling with Result helpers
# ------------------------------------------------------------------
echo "5. Error handling on cmd results".
bad_res = git "bogus-command-that-doesnt-exist".
bad_ec  = bad_res.exitcode.
status | bad_ec == 0 = Ok "command succeeded".
status               = Err "command failed".
status_str  = str status.
bad_err     = trim bad_res.stderr.
echo "Result: {status_str}".
echo "stderr: {bad_err}".
echo "".

# ------------------------------------------------------------------
# 6. Positional + flag mix, then inspect stdout
# ------------------------------------------------------------------
echo "6. Inspecting stdout of wc -l".
wc_res   = wc_ "-l" "examples/sigils_demo.sol".
wc_lines = trim wc_res.stdout.
echo "Line count output: {wc_lines}".

echo "".
echo "=== Done ===".
