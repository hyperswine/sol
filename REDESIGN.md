# Sol Language Redesign — TODO

## Overview of changes

Four focused changes to make the language more sequential, flat, and declarative:

1. Replace `dict|key` access syntax with `dict[key]`
2. Add guarded definitions for both values and functions
3. Remove `if`/`then`/`else` entirely
4. Switch operators from prefix to infix

---

## 1. Replace `|` access with `[]`

### Syntax

```
# Before
config|host
config|"port"
list|1
dict|(varname)

# After
config["host"]
config["port"]
list[1]
config[varname]
```

The `(varname)` indirection for variable keys becomes just a bare identifier inside
`[]` — no special wrapping needed since it's unambiguous in that position.

### Parser (`Sol/Parser.hs`)

- Remove `pAtomAcc` and the `keyAccess` subparser that consumes `'|' <* notFollowedBy '>'`
- Add `pIndex` that parses `'[' *> pKey <* ']'` after any atom
- Update `pKey` — the `KVar` form no longer needs `'(' varname ')'` wrapping since
  bare identifiers inside `[]` are unambiguous. A bare identifier becomes `KVar`,
  a quoted string becomes `KStr`, a number literal becomes `KNum`
- Update `pAtom`/`pAtomAcc` to chain zero or more `[]` accesses instead of `|key` accesses
- The `|` character is now only used for guards (new) and `|>` pipelines (unchanged)

### Eval (`Sol/Eval.hs`)

- `applyKey` and `EAccess` evaluation logic is unchanged — only the surface syntax changes
- Remove the `notFollowedBy '>'` guard that distinguished `|` access from `|>` pipeline
  (no longer needed once `|` is freed from access duty)

---

## 2. Guarded definitions

### Syntax

```
# Value guards
status | failed result         = "error".
status | result["code"] == 200 = "ok".
status                         = "unknown".

# Function guards (same form, parameters just appear before the guard)
classify x | x > 100 = "large".
classify x | x > 0   = "positive".
classify x            = "non-positive".
```

The grammar for `assign` becomes:

```
assign ::= ident ident* ('|' guard_expr)? '=' expr
```

Where `guard_expr` is a full `expr` — no new grammar needed, just an expression
that evaluates to a truthy/falsy value.

The final unguarded clause acts as the fallthrough default. A name with no unguarded
clause that exhausts all guards is a runtime error.

### Parser (`Sol/Parser.hs`)

- Extend `pAssign` to optionally parse `symbol "|" *> pExpr` between the parameter
  list and `=`
- Fold the guard into `SAssign` as `Maybe Expr`:
  `SAssign Name [Param] (Maybe GuardExpr) Body`

### Eval (`Sol/Eval.hs`)

- A pre-pass over the statement list groups consecutive clauses for the same name into
  a single `[(Maybe Expr, Expr)]` clause table before evaluation begins. Clauses for
  the same name **must be contiguous** — this is enforced as a runtime error
- When looking up a guarded name, walk its clause list top-to-bottom; evaluate each
  guard in the current env (with any parameters already bound); return the body of the
  first clause whose guard is truthy, or the first clause with no guard
- For zero-parameter guarded values, the guard is evaluated at **lookup time** in the
  calling env — consistent with Sol's existing dynamic scope

### New error

```
[sol] no matching clause for 'status'
```

Raised when all guards fail and there is no unguarded fallthrough clause.

---

## 3. Remove `if`/`then`/`else`

### Parser (`Sol/Parser.hs`)

- Remove `pIfExpr` entirely
- Remove `pStop` (the lookahead that halted argument parsing at `then`/`else`)
- Remove `if`, `then`, `else` from the `reserved` keyword list
- Update `pExpr` to no longer try `pIfExpr`

### Eval (`Sol/Eval.hs`)

- Remove the `EIf` case from `evalExpr`

### Syntax (`Sol/Syntax.hs`)

- Remove the `EIf Expr Expr Expr` constructor from `Expr`

### Migration

```
# Before
result = if > x 0 then "positive" else "non-positive".

# After
result | x > 0 = "positive".
result          = "non-positive".
```

---

## 4. Infix operators

### Syntax

Operators become standard infix with conventional precedence. Function application
still uses juxtaposition and binds tighter than any operator.

```
# Before (prefix)
result = + a b.
check  = == x 10.
big    = and (> x 0) (< x 100).

# After (infix)
result = a + b.
check  = x == 10.
big    = x > 0 and x < 100.
```

Precedence table (high to low):

| Level | Operators |
|---|---|
| 1 (tightest) | `*`  `/`  `mod` |
| 2 | `+`  `-` |
| 3 | `>`  `<`  `>=`  `<=` |
| 4 | `==`  `!=` |
| 5 | `not` (unary prefix) |
| 6 | `and` |
| 7 (loosest) | `or` |

Function application via juxtaposition binds tighter than level 1, so
`f x + g y` parses as `(f x) + (g y)`.

### Operators are no longer first-class values

`map (+ 1) list` no longer works. The prefix-operator-as-partial-application
pattern is removed. Use a named helper instead:

```
add1 x = x + 1.
result = map add1 list.
```

This is an acceptable tradeoff — the use case was obscure and the parsing
complexity it required is no longer justified.

### Parser (`Sol/Parser.hs`)

- Remove `pOp` and the `EVar <$> pOp` case from `pAtom`
- Remove the `"-" <* notFollowedBy digitChar` disambiguation from `pOp`;
  negative literals continue to be handled in `pNum` as before
- Add a precedence-climbing parser using Megaparsec's `makeExprParser`
  from `Control.Monad.Combinators.Expr`:

```haskell
import Control.Monad.Combinators.Expr

operatorTable :: [[Operator Parser Expr]]
operatorTable =
  [ [ binary "*",   binary "/",  binary "mod" ]
  , [ binary "+",   binary "-"                ]
  , [ binary ">=",  binary "<=",
      binary ">",   binary "<"                ]
  , [ binary "==",  binary "!="               ]
  , [ prefix "not"                            ]
  , [ binary "and"                            ]
  , [ binary "or"                             ]
  ]
  where
    binary name = InfixL  ((\a b -> EApp (EVar name) [a, b]) <$ symbol name)
    prefix name = Prefix  ((\e   -> EApp (EVar name) [e])    <$ keyword name)
```

- `pExpr` becomes `makeExprParser pApp operatorTable`
- Guard expressions use the same `pExpr`, so infix operators work naturally
  in guards: `| x > 0`, `| x == "ok" and not (failed result)`

### Eval (`Sol/Eval.hs`)

- No structural changes — `+`, `-`, `==` etc. remain as named builtins in
  `initialEnv`. The parser now emits `EApp (EVar "+") [a, b]` which evaluates
  identically through the existing `apply` path
- **Fix `cmpOp` argument order**: the current implementation flips arguments
  (`f b a`) to support the curried-predicate pattern (`> 3` meaning "is value > 3?").
  That pattern no longer exists. Change all `cmpOp` calls to `f a b` so that
  `x > 3` means what it says

### Syntax (`Sol/Syntax.hs`)

- No structural changes required — `EApp` already handles n-ary application and
  operators desugar into it naturally

### Migration

```
# Before
total  = + (len items) 1.
valid  = and (> score 0) (<= score 100).
result = map (* 2) numbers.

# After
total    = len items + 1.
valid    = score > 0 and score <= 100.
double x = x * 2.
result   = map double numbers.
```

---

## Summary of file changes

| File | Changes |
|---|---|
| `Sol/Syntax.hs` | Remove `EIf`; add `Maybe Expr` guard field to `SAssign` |
| `Sol/Parser.hs` | Replace `pAtomAcc`/`\|key` with `[]` index syntax; extend `pAssign` with optional guard; remove `pIfExpr`, `pStop`, `pOp`; update `reserved`; add `makeExprParser` infix table |
| `Sol/Eval.hs` | Remove `EIf` case; add clause-grouping pre-pass; add guarded lookup logic; remove `\|` access disambiguation; fix `cmpOp` argument order |
| Test suite | Update all tests: `\|` access → `[]`, `if`/`then`/`else` → guards, prefix operators → infix |
