# Sol Language Guide

Sol is a minimal scripting language with a clean, readable syntax inspired by Python and Haskell. Every statement ends with a `.`.

## Running Sol

```sh
sol script.sol          # run a file
sol -e 'echo "hi".'    # run inline code
sol -                  # read from stdin
sol                    # start the REPL
```

---

## Basics

### Output

```sol
echo "Hello, World!".
```

### Variables

```sol
name = "Sol".
version = 1.
pi = 3.14159.
```

### Comments

```sol
# This is a comment
x = 42.  # inline comment
```

---

## Strings

Double-quoted strings support `{variable}` interpolation (f-strings):

```sol
name = "world".
echo "Hello, {name}!".
```

Use `raw"..."` to suppress interpolation:

```sol
echo raw"No {interpolation} here".
```

> **Note:** Only simple variable names work inside `{}`. For access chains like `user|name`, assign to a local variable first.

---

## Numbers

```sol
x = 10.
y = 3.14.
negative = -5.
```

---

## Arrays

Arrays are **1-indexed**.

```sol
nums = [1, 2, 3, 4, 5].
echo nums|3.        # → 3 (pipe access)
echo nums[3].       # → 3 (bracket access)
```

---

## Dictionaries

```sol
person = {"name": "Alice", "age": 30}.
echo person|name.        # → Alice  (pipe access)
echo person["name"].     # → Alice  (bracket access)
echo person|age.         # → 30
```

Use a variable as a key:

```sol
key = "name".
echo person|(key).   # → Alice  (dynamic pipe access)
echo person[key].    # → Alice  (dynamic bracket access)
```

---

## Data Access

Sol has two syntaxes for accessing fields and indices — both are equivalent:

| Style             | Example              | Notes                        |
|-------------------|----------------------|------------------------------|
| Pipe `\|`         | `obj\|key`           | No space before or after key |
| Bracket `[]`      | `obj["key"]`         | No space before `[`          |
| Numeric (pipe)    | `list\|1`            | 1-based                      |
| Numeric (bracket) | `list[1]`            | 1-based                      |
| Dynamic (pipe)    | `obj\|(varname)`     | Looks up variable as key     |
| Dynamic (bracket) | `obj[varname]`       | Bare identifier = variable   |

Chains work with both styles:

```sol
company = {name: "Acme", employees: [{name: "Alice"}, {name: "Bob"}]}.
echo company|employees|1|name.              # → Alice
echo company["employees"][1]["name"].       # → Alice
```

---

## Functions

Functions are defined with `name params = body`:

```sol
double x = x * 2.
add a b = a + b.

echo (double 5).    # → 10
echo (add 3 4).     # → 7
```

---

## Operators

Sol supports both **infix** and **prefix** style for arithmetic and comparisons.

### Infix style (natural)

```sol
x = 10 + 5.         # → 15
y = 10 * 3 - 2.     # → 28
ok = x > 10.        # → true
```

### Prefix style (useful for partial application)

```sol
add5 = + 5.         # partial: add5 n = 5 + n
double = * 2.       # partial: double n = 2 * n
```

### Operator table

| Operator | Meaning         | Infix example   | Prefix example        |
|----------|-----------------|-----------------|-----------------------|
| `+`      | add             | `x + 1`         | `+ x 1`               |
| `-`      | subtract        | `x - 1`         | `- x 1`               |
| `*`      | multiply        | `x * 2`         | `* x 2`               |
| `/`      | divide          | `x / 4`         | `/ x 4`               |
| `mod`    | modulo          | `x mod 3`       | `mod x 3`             |
| `==`     | equals          | `x == 5`        | `== x 5`              |
| `!=`     | not equals      | `x != 5`        | `!= x 5`              |
| `>`      | greater than    | `x > 3`         | `> 3 x` *(curried)*   |
| `<`      | less than       | `x < 3`         | `< 3 x` *(curried)*   |
| `>=`     | ≥               | `x >= 5`        | `>= 5 x`              |
| `<=`     | ≤               | `x <= 5`        | `<= 5 x`              |
| `not`    | boolean not     | —               | `not false`           |
| `and`    | boolean and     | `a and b`       | `and a b`             |
| `or`     | boolean or      | `a or b`        | `or a b`              |

> **Curried prefix comparisons:** `> threshold value` asks "is `value > threshold`?". This lets comparisons work as predicates — e.g. `filter (> 5)` keeps elements greater than 5.

---

## Guards

Guards are a concise alternative to chains of `if/else`. Clauses are tried top-to-bottom; the first whose condition is truthy wins.

### Guarded variable

```sol
x = 42.
category | x > 100 = "large".
category | x > 10  = "medium".
category            = "small".
echo category.    # → medium
```

### Guarded function

```sol
classify n | n > 100 = "large".
classify n | n > 0   = "positive".
classify n            = "non-positive".

echo (classify 150).    # → large
echo (classify 42).     # → positive
echo (classify -5).     # → non-positive
```

```sol
score = 85.
grade | score > 90 = "A".
grade | score > 80 = "B".
grade | score > 70 = "C".
grade              = "D".
echo grade.    # → B
```

> Guards replace most `if/then/else` chains. The final unguarded clause acts as the `else` branch.

---

## Partial Application

Any function called with fewer arguments than it expects returns a partial:

```sol
add5 = + 5.
echo (add5 10).     # → 15

double = * 2.
echo (double 7).    # → 14

is_big = > 100.     # prefix: > threshold value
echo (is_big 200).  # → true
```

---

## If Expressions

`if` is an expression — it can appear anywhere. Guards are often cleaner for multiple branches.

```sol
x = 7.
label = if x > 10 then "big" else if x > 5 then "medium" else "small".
echo label.   # → medium
```

```sol
if x == 5 then echo "five" else echo "other".
```

---

## Pipelines

The `|>` operator passes the left-hand value as the **last** argument to the right-hand function:

```sol
result = [1, 2, 3, 4, 5] |> filter (> 2) |> map (* 3) |> fold +.
echo result.   # → 36
```

This lets you chain higher-order functions naturally.

---

## Higher-Order Functions

```sol
nums = [1, 2, 3, 4, 5].

doubled  = map (* 2) nums.          # [2, 4, 6, 8, 10]
big      = filter (> 4) doubled.    # [6, 8, 10]
total    = fold + big.              # 24

each echo nums.                     # prints each element
```

---

## Recursion

```sol
fib n = if n == 0 then 0 else if n == 1 then 1 else (fib (n - 1)) + (fib (n - 2)).
echo (fib 10).    # → 55

fact n = if n == 0 then 1 else n * (fact (n - 1)).
echo (fact 5).    # → 120
```

---

## Shell Commands

`sh` runs a shell command and returns a result dict with `exitcode`, `stdout`, and `stderr`:

```sol
result = sh "ls -la".
echo result|stdout.
echo result|exitcode.

ok = succeeded result.
echo "Succeeded: {ok}".
```

Handle failures with `unwrap_or` or `unwrap_or_exit` (both work in pipelines):

```sol
version = sh "git describe --tags" |> unwrap_or "unknown".
sh "make build" |> unwrap_or_exit "Build failed!".
```

Extract fields directly:

```sol
out = sh "date" |> stdout.
err = sh "bad cmd" |> stderr_str.
```

---

## Environment Variables

```sol
home = getenv "HOME".
path = getenv "PATH" |> unwrap_or "/usr/bin".
echo "Home: {home}".
```

---

## Filesystem

```sol
content = read "file.txt".
write "output.txt" content.
cp "src.txt" "dst.txt".      # copy a file

files = ls ".".
echo files.

mkdir "newdir".
rm "oldfile.txt".

exists "file.txt".   # → true / false
echo cwd.            # current working directory
echo pwd.            # alias for cwd
```

Path helpers:

```sol
echo (name "/home/user/file.txt").    # → file.txt
echo (ext "archive.tar.gz").          # → .gz
echo (dir "/home/user/file.txt").     # → /home/user
echo (path "/home/user" "docs").      # → /home/user/docs
place "README.md" "dist".             # copy into dist/, returns dest path
```

---

## JSON

```sol
data = jsonread "config.json".
echo data|version.

updated = set data "version" "2.0".
jsonwrite updated "config.json".

# Parse/stringify inline
j = jsonparse "{\"x\": 1}".
echo j|x.
echo (jsonstringify {"key": "value", "num": 42}).
```

---

## CSV

```sol
rows = csvread "data.csv".
echo rows|1.         # first row (list of strings)
echo rows|1|1.       # first row, first column

csvwrite rows "output.csv".
```

---

## HTTP

```sol
html = wget "https://example.com".
echo html.

content = get "https://api.example.com/data".  # alias for wget
```

---

## Hashing

```sol
hash = sha256 "hello world".
echo hash.

digest = md5 "hello".
echo digest.
```

---

## Progress

`progress` wraps slow operations and shows a progress indicator where available:

```sol
# wget: shows curl's download progress bar
content = progress (wget "https://example.com/large.tar.gz").

# cp: uses pv if installed, otherwise shows a notice
progress (cp "big.iso" "/backup/big.iso").
```

---

## String Built-ins

```sol
echo (len "hello").                        # 5
echo (upper "hello").                      # HELLO
echo (lower "HELLO").                      # hello
echo (trim "  hello  ").                   # hello
echo (split "," "a,b,c").                 # ["a", "b", "c"]
echo (join "-" ["a", "b", "c"]).          # a-b-c
echo (replace "o" "0" "hello world").     # hell0 w0rld
echo (startswith "he" "hello").           # true
echo (endswith "lo" "hello").             # true
echo (contains "ell" "hello").            # true
echo (grep "error" "line1\nerror here").  # ["error here"]
echo (lines "a\nb\nc").                   # ["a", "b", "c"]
echo (unlines ["a", "b", "c"]).           # a\nb\nc
echo (words "hello world").               # ["hello", "world"]
echo (unwords ["hello", "world"]).        # hello world
```

---

## List Built-ins

```sol
xs = [3, 1, 4, 1, 5].

echo (len xs).               # 5
echo (head xs).              # 3
echo (tail xs).              # [1, 4, 1, 5]
echo (reverse xs).           # [5, 1, 4, 1, 3]
echo (sort xs).              # [1, 1, 3, 4, 5]
echo (append xs 9).          # [3, 1, 4, 1, 5, 9]
echo (prepend 0 xs).         # [0, 3, 1, 4, 1, 5]
echo (concat xs [6, 7]).     # [3, 1, 4, 1, 5, 6, 7]
echo (contains 4 xs).        # true
echo (range 0 5).            # [0, 1, 2, 3, 4]
echo (zip [1,2,3] [4,5,6]).  # [[1,4],[2,5],[3,6]]
echo (flatten [[1,2],[3,4]]).# [1, 2, 3, 4]
```

`fold` supports an optional explicit initial accumulator (3-arg form):

```sol
echo (fold + [1, 2, 3, 4]).        # 10  (first element is init)
echo (fold + 0 [1, 2, 3, 4]).      # 10  (explicit init = 0)
echo (fold + 100 [1, 2, 3]).       # 106 (explicit init = 100)
```

---

## Dict Built-ins

```sol
d = {"a": 1, "b": 2}.

echo (keys d).           # ["a", "b"]
echo (values d).         # [1, 2]
echo (has d "a").        # true
echo (get d "a").        # 1
d2 = set d "c" 3.        # {"a":1,"b":2,"c":3}
d3 = delete d "b".       # {"a":1}
echo (merge d {"c": 3}). # {"a":1,"b":2,"c":3}
```

`set` also works on lists (1-based index):

```sol
xs = [10, 20, 30].
xs2 = set xs 2 99.    # [10, 99, 30]
```

---

## Type Conversion

```sol
echo (str 42).       # "42"
echo (num "3.14").   # 3.14
echo (bool 0).       # false
echo (bool "hi").    # true
echo (type 42).      # number
echo (type "hi").    # string
echo (type []).      # list
echo (type {}).      # dict
```

**Truthiness rules:** `false`, `null`, `0`, `""`, `[]`, `{}` are falsy. Everything else is truthy.

---

## Utilities

```sol
exit.          # exit with code 0
exit 1.        # exit with code 1
```

---

## Quick Reference

### All Built-in Functions

**I/O:** `echo`, `print`

**Arithmetic:** `+`, `-`, `*`, `/`, `mod`

**Comparison:** `>`, `<`, `>=`, `<=`, `==`, `!=`, `not`, `and`, `or`

**Higher-order:** `map`, `filter`, `fold`, `each`, `progress`

**Lists:** `len`, `head`, `tail`, `append`, `prepend`, `concat`, `reverse`, `sort`, `range`, `zip`, `flatten`, `contains`

**Strings:** `len`, `trim`, `split`, `join`, `replace`, `upper`, `lower`, `startswith`, `endswith`, `grep`, `lines`, `unlines`, `words`, `unwords`, `contains`

**Dicts:** `keys`, `values`, `set`, `get`, `has`, `delete`, `merge`

**Type:** `str`, `num`, `bool`, `type`

**Filesystem:** `read`, `write`, `cp`, `ls`, `mkdir`, `rm`, `exists`, `name`, `ext`, `dir`, `path`, `place`, `cwd`, `pwd`

**Shell:** `sh`, `getenv`, `setenv`

**Results:** `failed`, `succeeded`, `unwrap_or`, `unwrap_or_exit`, `stdout`, `stderr_str`

**Data:** `jsonread`, `jsonwrite`, `jsonparse`, `jsonstringify`, `csvread`, `csvwrite`

**Network:** `wget`, `get`

**Hashing:** `sha256`, `md5`

**Process:** `exit`
