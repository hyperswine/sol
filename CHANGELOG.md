# Changelog for `haskell-sol`

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to the
[Haskell Package Versioning Policy](https://pvp.haskell.org/).

## 2.0.0 - 2026-04-18

### Changed (Breaking)

- **Infix operators** — arithmetic and comparison operators are now infix: `a + b`, `x * y`, `a == b` instead of `+ a b`, `* x y`, `== a b`.
- **Index access** — dictionary and list access now uses bracket syntax: `dict["key"]`, `list[0]`, `dict[var]` instead of `dict|key`, `list|1`, `dict|(varname)`.
- **Guarded definitions** — replaced `if/then/else` expressions with Haskell-style guarded clauses:
  ```
  classify x | x > 0 = "positive".
  classify x         = "non-positive".
  ```
  Works for both functions (with params) and plain values (0-param guards).
- **Removed `if/then/else`** — the `if`, `then`, and `else` keywords no longer exist; all conditional logic uses guards.

### Added

- Operator precedence table (via `makeExprParser`): `[* / mod]` > `[+ -]` > `[>= <= > <]` > `[== !=]` > `[not]` > `[and]` > `[or]`.
- `SGuarded` runtime value: multiple guarded clauses for the same name accumulate and are tried in order; first matching guard wins.
- F-string `{var}` interpolation now properly evaluates guarded values.

## 1.0.0 - 2026-03-31

### Added

- **v1 release** — complete rewrite of Sol in Haskell, ported from the original Python implementation (`python-sol` branch).
- Parser built with **Megaparsec**: clean, composable, with good error messages.
- All core language features ported:
  - Prefix function application: `func arg1 arg2`
  - User-defined functions with multiple parameters: `f a b = * a b`
  - Partial application via `SPartial`: `(+ 1)`, `(> 5)` etc.
  - Pipeline operator: `list |> map (* 2) |> filter (> 4) |> fold +`
  - If expressions: `if cond then x else y` (usable anywhere)
  - Access chains: `dict|key`, `list|1`, `dict|(varname)`
  - Array and dict literals, 1-indexed arrays
  - F-strings with `{var}` interpolation; raw strings with `raw"..."`
- Standard library (~50 built-ins) shelling out where appropriate:
  - Filesystem: `read`, `write`, `ls`, `mkdir`, `rm`, `exists`, `cwd`
  - Shell execution: `sh` returning `{exitcode, stdout, stderr}`
  - Result helpers: `succeeded`, `failed`, `unwrap_or`, `unwrap_or_exit`
  - Higher-order: `map`, `filter`, `fold`, `each`
  - String: `split`, `join`, `trim`, `replace`, `upper`, `lower`, `grep`
  - Dict: `keys`, `values`, `set`, `get`, `has`, `merge`
  - JSON: `jsonparse`, `jsonstringify`, `jsonread`, `jsonwrite`
  - Hashing: `sha256`, `md5` (via system tools)
  - HTTP: `wget` / `get` (via `curl`)
- Interactive REPL with history via **Haskeline**.
- CLI supports `sol script.sol`, `sol -e 'code'`, `sol -` (stdin), and bare `sol` (REPL).
- Pure, functional interpreter design: immutable AST, environment threaded explicitly, `IO` only at the leaves.
