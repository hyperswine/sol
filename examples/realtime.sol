# realtime escapes: what they do and what they cost

> u = writePath @/tmp/rt-demo.txt "transactional write\n";
  print "transactional write buffered (not on disk yet)".

> code = shNow "echo '  ...streamed from a subprocess, live'";
  print "shNow exit code {code}".

> u = appendNow @/tmp/rt-live.log "progress: step 1\n";
  u2 = appendNow @/tmp/rt-live.log "progress: step 2\n";
  s = readNow @/tmp/rt-live.log;
  print "readNow saw {String.len s} bytes already on disk".
