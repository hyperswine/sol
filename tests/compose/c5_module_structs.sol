# module composition: a struct + generic defined in a module, used here,
# plus run-in-subprocess isolation of another module
chk name got want = case got == want of True -> print "ok {name}" | False -> error "FAIL {name}: {got} vs {want}".

std = use "../../lib/std".
T = std.ListS.

> chk "module struct via generic" (std.total std.Num [1, 2, 3, 4]) 10.
> chk "module generic + module struct on lists" (std.total std.ListS [[1], [2, 3]]) [1, 2, 3].
> chk "module average" (std.average [2, 4, 6]) 4.
