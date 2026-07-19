# double use: reads the same handle twice
> h = open @/tmp/x.txt;
  (a, h2) = readAll h;
  (b, h3) = readAll h;
  u = close h2; u2 = close h3;
  print "{a}{b}".
