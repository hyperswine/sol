# transaction semantics: read-your-writes, interleaved effects, sh query
chk name got want = case got == want of True -> print "ok {name}" | False -> error "FAIL {name}: {got} vs {want}".

> u = writePath @/tmp/sol-c8.txt "alpha";
  s = readPath @/tmp/sol-c8.txt;
  chk "read-your-writes in txn" s "alpha".
> u = writePath @/tmp/sol-c8.txt "beta";
  s = readPath @/tmp/sol-c8.txt;
  chk "second write visible" s "beta".
> (rc, out) = sh "echo hi";
  chk "sh exit code" rc 0.
> (rc, out) = sh "echo hi";
  chk "sh query output" out "hi".
