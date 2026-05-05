#!/usr/bin/env sol
# Demonstrates sigil argument syntax: 'atom  @flag  !flag  key:val
# and the dotted command/subcommand calling convention: x.y args*

echo "=== Sigil Argument Syntax ===".
echo "".

# ------------------------------------------------------------------
# 1. Bare atom  'word  → just a string, no quoting needed
# ------------------------------------------------------------------
echo "1. Bare atoms ('word)".
ext  = 'sol.
lang = 'haskell.
echo "Extension:  {ext}".
echo "Language:   {lang}".
echo "".

# ------------------------------------------------------------------
# 2. Boolean flags  @flag → ("flag", true)  !flag → ("flag", false)
# ------------------------------------------------------------------
echo "2. Boolean flags (@flag / !flag)".
println @amend.
println !verify.
println @dry-run.
echo "".

# ------------------------------------------------------------------
# 3. Named arguments  key:val → ("key", val)
# ------------------------------------------------------------------
echo "3. Named arguments (key:val)".
println replicas:3.
println msg:"fix everything".
println tag:"v2.0.1".
echo "".

# ------------------------------------------------------------------
# 4. has_flag / flag_val / pos_args helpers
# ------------------------------------------------------------------
echo "4. Inspecting a mixed args list".
args = [@verbose, !dry-run, 'main, replicas:3, "output.txt"].

has_verbose = has_flag "verbose"  args.
has_dryrun  = has_flag "dry-run"  args.
rep_value   = flag_val "replicas" args.
positional  = pos_args args.
pos_str     = str positional.

echo "has verbose flag:   {has_verbose}".
echo "has dry-run flag:   {has_dryrun}".
echo "replicas value:     {rep_value}".
echo "positional args:    {pos_str}".
echo "".

# ------------------------------------------------------------------
# 5. Dotted field access  x.y  →  x["y"]
# ------------------------------------------------------------------
echo "5. Dotted field access (x.y)".
repo  = {name: "sol", meta: {owner: "jasenqin", stars: 42}}.
rname = repo.name.
owner = repo.meta.owner.
stars = repo.meta.stars.
echo "repo name:          {rname}".
echo "owner:              {owner}".
echo "stars:              {stars}".
echo "".

echo "=== Done ===".
