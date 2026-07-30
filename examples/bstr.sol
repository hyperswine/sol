# BStr — the byte-buffer string tier. Linear: every op threads the buffer.

> b0 = BStr.new Unit;
  b1 = BStr.append "hello, " b0;
  b2 = BStr.append "world" b1;
  (n, b3) = BStr.len b2;
  u = print "len:      {n}   (want 12)";
  (c1, b4) = BStr.at b3 1;
  u2 = print "at 1:     {c1}  (want 104 h)";
  (c8, b5) = BStr.at b4 8;
  u3 = print "at 8:     {c8}  (want 119 w)";
  (sl, b6) = BStr.sub b5 1 5;
  u4 = print "sub 1..5: {BStr.toStr sl}   (want hello)";
  print "toStr:    {BStr.toStr b6}   (want hello, world)".

# UTF-8: indexing is by CODEPOINT, not byte
> b = BStr.fromStr "héllo";
  (n, b1) = BStr.len b;
  u = print "utf8 len: {n}   (want 5 codepoints)";
  print "utf8 ok:  {BStr.toStr b1}".

# the builder: O(total bytes), not O(n^2)
join sep xs b = foldl (fn acc x -> BStr.append "{x}{sep}" acc) b xs.
> out = join "," [1, 2, 3, 4, 5] (BStr.new Unit);
  print "join:     {BStr.toStr out}   (want 1,2,3,4,5,)".
