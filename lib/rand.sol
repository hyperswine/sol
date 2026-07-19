# rand.sol — deterministic PRNG in pure arithmetic (JITtable if needed).
# LCG (glibc constants) over 2^31 via the a-(a/b)b mod identity; values
# and helpers are Q16.16-friendly.

next s = imod (s * 1103515245 + 12345) 2147483648.
imod a b = a - (a / b) * b.

# uniform in [0, hi) as plain int
uniform s hi = imod (s / 65536) hi.

# uniform Q16.16 in [-1, 1): take 17 bits, center
unitQ s = imod (s / 1024) 131072 - 65536.

# rough gaussian: sum of 4 unit uniforms, variance ~4/3 (fine for demos)
gauss4 s =
  s1 = next s; s2 = next s1; s3 = next s2; s4 = next s3;
  (unitQ s1 + unitQ s2 + unitQ s3 + unitQ s4) / 2.

# skip past the draws gauss4 consumes: independent streams per feature
next4 s = next (next (next (next s))).
