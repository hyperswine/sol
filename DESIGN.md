Sol is a modern, minimal, batteries-included scripting language designed for readability, quick startup, and powerful standard tooling. Inspired by the clarity of Python and the functional simplicity of Haskell, Sol provides a highly expressive scripting experience without the quirks of traditional shells.

- Statements end with a period `.`
- Function calls are prefix-based: `result = func arg`
- Minimal parentheses. only used for grouping
- Simple functions of multi variables

```sol
file = wget "https://example.com/file.txt".
place file cwd.
check = cwd get (name file).
echo check.

# simple functions
# multiplies the two args
f a b = * a b.
# myres = 2.
myres = f 1 2.
myotherfunc = map (+ 1).
m = filter (> 1).
# arrays
myarray = [1, 2, 3].
# [2, 3, 4]
res = m (myotherfunc myarray).
sum = fold +.
# 9
res' = sum res.

# dictionary and list access - IMPLEMENTED ✓
# lists are 1-indexed
d = {"x" : [1, 2]}.
# shows 1
echo d|x|1.

# Variable key access - use parentheses for variable values as keys
key_name = "x".
echo d|(key_name).  # Uses value of key_name as key

# JSON, CSV parsing - IMPLEMENTED ✓
j = jsonread "myfile.json".
echo j|x.
c = csvread "myfile.csv".
# first row, first element
echo c|1|1.
# creates another dictionary with j "x" set to 2
j2 = set j "x" 2.
c2 = set c "1|1" 1.
jsonwrite j2 "myfile2.json".
csvwrite c2 "myfile2.csv".

# progress bar - IMPLEMENTED ✓
# supports most functions, if a function is kind of trivial, then it can just go from 0 to 100 quickly like show 0 1 2 3 ... 100 in half a second.
# otherwise, if possible, break it up into chunks and when we receive each chunk increment it
progress (wget "https://example.com").
```

GOALS

- Clean, readable, indentation-tolerant syntax
- Built-in standard tools (no pip required)
- Fast startup and minimal runtime overhead
- Cross-platform, easy to embed and distribute

By default everything is imported from the stdlib.

Filesystem tools like `ls`, `mkdir`, `rm`, `find`, `read`, `write`.
Web utilities like `get`, `post`, file downloads, headers, etc.
Hashing tools: `md5`, `sha256`, etc.
Support for JSON, CSV parsing.
Printing, arguments, prompt, progress bars.
Simple regex, replace, split, trim, grep-like utilities.
System info: environment variables, current user, CPU/mem stats.
Git wrapper functions (using gitpython).
Networking utilities: ping, dns lookup, nmap, whois.
Zip/tar/gzip tools.

```sol
#!/usr/bin/env sol

file = wget "https://example.com/data.txt".
text = fs.read file.
echo text.
```

Uses nuitka to compile to a native binary.

WANT LATER

- Pipe syntax: `file |> fs.read |> text.grep "error"`
- Len or something
