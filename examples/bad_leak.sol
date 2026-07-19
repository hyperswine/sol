# forgets to close: handle used 0 times after writeAll
> h = open @/tmp/x.txt;
  h2 = writeAll h "data";
  print "done".
