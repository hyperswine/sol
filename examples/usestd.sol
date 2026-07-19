# usestd.sol — the stdlib module consumed through content-addressed `use`
std = use "../lib/std".

> print "std.total std.Num = {std.total std.Num [10,20,30]}".
> print "std.total std.ListS = {str (std.total std.ListS [[1],[2,3]])}".
> print "mapKeep = {str (std.mapKeep std.ListS std.ListS (fn x -> x * x) (fn x -> x > 5) [1,2,3,4])}".
> print "average = {std.average [10,20,30,40]}".
