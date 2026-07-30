# Sol Style Guide

Conventions used across `examples/` and `lib/`. The examples directory is
the executable spec — when in doubt, write it the way the examples do.

## Naming

- `lowerCamelCase` for functions and values; `UpperCamelCase` for types,
  constructors, sigs, and structs.
- Small single-purpose helper functions over nested lambdas — everything
  lambda-lifts anyway, so a named top-level helper costs nothing and is
  easier to read, test, and reuse in `--asm` dumps.

## `$` — low-precedence application

`f $ x` is `f (x)` with the parens removed: `$` binds looser than every
other operator except nothing (it is the lowest layer), and it is
right-associative, so `f $ g $ x` is `f (g x)`.

```sol
# do this
> print $ mystring + " " + mystring'.
> print $ classify (0 - 5).

# instead of
> print (mystring + " " + mystring').
> print (classify (0 - 5)).
```

Use `$` for the *final* application of a statement — the "print the
result of everything after me" shape. Two caveats:

- `$` swallows the entire rest of the expression, **including `>>`, `|>`
  and `|>?`**, which all bind tighter than `$`. Inside a `>>` chain,
  keep parens:

  ```sol
  main =
    print (classify (0 - 5)) >>   # NOT `print $ classify (0 - 5) >> ...`
    print check.                  # ...that would sequence INSIDE the print
  ```

- `f $ x` produces the identical AST to `f (x)`, so switching between
  them never changes a module's content-address — pins survive.

## `|>` — pipelines

`x |> f |> g` is `g (f x)`: left-to-right data flow. Prefer a pipeline
whenever a value passes through two or more stages; prefer plain
application for a single stage where the nesting is shallow.

```sol
# do this
words ln = base.splitCh 32 ln |> List.filter nonEmpty.
countLines s = base.splitCh 10 s |> base.listLen.

# instead of
words ln = List.filter nonEmpty (base.splitCh 32 ln).
countLines s = base.listLen (base.splitCh 10 s).
```

Lambdas can appear directly as pipeline stages
(`x |> inc |> fn y -> y * k`), and `|>?` is the Ok/Err short-circuiting
variant. `$` and `|>` compose: `print $ xs |> map f |> sum` pipes first,
then prints.

## Multi-clause definitions, guards, and pattern params

Prefer multi-clause definitions with pattern parameters and guards over
`case` scaffolding — especially over `case cond of True -> ... | False
-> ...`, which is an if-expression wearing a trench coat. First matching
clause wins; guard failure falls through to the next clause.

```sol
# do this
myfunc (Add x _) | x < 0 = ...
myfunc (Add x y) = x + y.

# instead of
myfunc x = case x of
  Add x y -> (case x < 0 of
      True -> ...
    | False -> x + y).
```

The same applies to boolean helpers and list recursion. List patterns
(`[]`, `[a, b]`, `x :: r`) work in parameter position (parenthesize
cons: `(x :: r)`), as do literals:

```sol
# do this
member _ [] = False.
member x (y :: _) | x == y = True.
member x (_ :: r) = member x r.

pick 1 p = p.x1.
pick _ p = p.x2.

# instead of
member x xs | xs == [] = False.
member x xs = case xs of y :: r -> (case x == y of True -> True | False -> member x r).

pick feat p = case feat == 1 of True -> p.x1 | False -> p.x2.
```

Keep `case` for what it is good at: scrutinizing a *computed* value once
in the middle of a block, or when you need an expression (guards only
attach to top-level clauses, not to block bindings or case arms).

## Pattern-match bindings in guards

A guard is a comma-separated list of components. Each component is
either a boolean condition or a pattern-match binding `pat <- expr`.
The pattern's variables are in scope for the remaining components and
the clause body; if the pattern does not match, the clause falls
through to the next one.

```sol
# do this
f y | Just x <- y, x < 0 = x + 1.
f y | Just x <- y = x * 10.
f _ = 0.

describe r | Ok v <- chained r, v > 20 = "big {v}".
describe r | Ok v <- chained r = "ok {v}".
describe _ = "failed".

# instead of
f y = case y of
  Just x -> (case x < 0 of True -> x + 1 | False -> x * 10)
| Nothing -> 0.
```

Notes:

- Components run left to right; a later condition can use variables
  bound by an earlier `<-`.
- Guards may re-evaluate on fallthrough, so (as with boolean guards)
  linear variables cannot be consumed in a guard.
- Write `x < -1` with spaces: `x <-1` parses as a pattern binding
  (`x <- 1`), same disambiguation rule as Haskell.

## Blocks and state

- Thread state explicitly through folds as tuples or records.
- Every block statement binds; discard results explicitly
  (`u = writePath p s;`) or chain effects with `>>`.
- Prefer `case ... of True -> ... | False -> ...` over `and2`/`or2`
  combinators when short-circuiting matters (the combinators evaluate
  both arguments' thunks eagerly).
