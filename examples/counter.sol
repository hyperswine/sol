# counter.sol — transactional increment. The read snapshots the file into
# the read set; sleepMs holds the transaction open so a concurrent writer
# invalidates it; commit detects the conflict and the script re-runs.
> h = open @/tmp/sol-counter.txt;
  (s, h2) = readAll h;
  n = parseInt s;
  u = sleepMs 300;
  h3 = writeAll h2 "{n + 1}";
  close h3.
> print "incremented".
