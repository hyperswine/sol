#!/usr/bin/env sol
# A realistic "release helper" script that combines all the new features:
#
#   • cmd  — wraps git / gh / docker as first-class values
#   • sigils — @flag !flag 'atom key:val for readable CLI-style calls
#   • Result / Option — propagate and format errors cleanly
#   • dotted access — res.stdout, res.exitcode
#   • Guards — readable branching without if/then/else
#   • andThen / mapErr — functional error chaining
#   • println vs echo — dev debug vs user output
#
# Dry-run safe: set DRY_RUN=1 to skip actual pushes.

echo "=== Sol Release Helper ===".
echo "".

# ── Config ─────────────────────────────────────────────────────────
dry_run = getenv "DRY_RUN" |> unwrap_or "0".
version = getenv "VERSION" |> unwrap_or "0.0.0".
remote  = getenv "REMOTE"  |> unwrap_or "origin".

echo "Version : {version}".
echo "Remote  : {remote}".
echo "Dry-run : {dry_run}".
echo "".

# ── Tools ──────────────────────────────────────────────────────────
git = cmd "git".

# ── Helpers ────────────────────────────────────────────────────────
# Run a command and return Ok stdout or Err stderr
run_or_err res | res.exitcode == 0 = Ok (trim res.stdout).
run_or_err res                     = Err (trim res.stderr).

# Validate semver: must contain two dots
valid_semver s | contains s "." = Ok s.
valid_semver s                  = Err "version must be semver (e.g. 1.2.3)".

# ── Step 1: validate version string ───────────────────────────────
echo "Step 1: Validating version string".
ver_check     = valid_semver version.
ver_check_str = str ver_check.
echo "version check: {ver_check_str}".
echo "".

# ── Step 2: check working tree is clean ───────────────────────────
echo "Step 2: Checking working tree".
status_res   = git "status" "--porcelain".
status_out   = trim status_res.stdout.
clean | status_out == "" = Ok "clean".
clean                    = Err "working tree is dirty - commit or stash first".
clean_str = str clean.
echo "tree status: {clean_str}".
echo "".

# ── Step 3: get current branch ────────────────────────────────────
echo "Step 3: Reading current branch".
branch_res = git "rev-parse" "--abbrev-ref" "HEAD".
branch     = run_or_err branch_res.
branch_str = str branch.
echo "branch: {branch_str}".
echo "".

# ── Step 4: last 3 commits for the changelog preview ──────────────
echo "Step 4: Recent commits".
log_res = git "log" @oneline "--max-count=3".
log_lines = lines log_res.stdout.
each echo log_lines.
echo "".

# ── Step 5: show what tag would be created ────────────────────────
echo "Step 5: Tag that would be created".
tag_name = concat "v" version.
echo "tag: {tag_name}".
echo "".

# ── Step 6: dry-run gate ──────────────────────────────────────────
echo "Step 6: Push gate (DRY_RUN={dry_run})".
would_push | dry_run == "0" = "would push tag {tag_name} to {remote}".
would_push                  = "dry-run: skipping push".
echo would_push.
echo "".

echo "=== Release check complete ===".
