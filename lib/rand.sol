# rand.sol — deterministic PRNG, packaged as a Struct so consumers can
# `rnd = use "../lib/rand". Rand = rnd.Rand.` and call Rand.next etc.
# LCG (glibc constants) over 2^31 via the a-(a/b)b mod identity.
#
# Rand.unit yields an inexact Numeric in [-1, 1) — no Q16.16 anywhere;
# downstream arithmetic promotes automatically. Seed hygiene still
# matters: gauss4 consumes four draws, so independent features need
# next4-separated streams.

Rand = Struct {
  imod = fn a b -> a - (a / b) * b,
  next = fn s -> Rand.imod (s * 1103515245 + 12345) 2147483648,

  # uniform int in [0, hi)
  uniform = fn s hi -> Rand.imod (s / 65536) hi,

  # inexact uniform in [-1, 1): take 17 bits, center, scale
  unit = fn s -> Numeric.div (Rand.imod (s / 1024) 131072 - 65536) 65536,

  # rough gaussian: sum of 4 unit uniforms over the chained states
  # s1 = next s, s2 = next s1, s3 = next s2, s4 = next s3 (= next4 s)
  gauss4 = fn s -> (Rand.unit (Rand.next s)
                  + Rand.unit (Rand.next (Rand.next s))
                  + Rand.unit (Rand.next (Rand.next (Rand.next s)))
                  + Rand.unit (Rand.next4 s)) / 2,

  # skip past the draws gauss4 consumes: independent streams per feature
  next4 = fn s -> Rand.next (Rand.next (Rand.next (Rand.next s)))
}.
