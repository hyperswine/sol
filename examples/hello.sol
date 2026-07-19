# hello.sol — script ergonomics + the auto-provided linear file API

inc x = x + 1.

> print "hello from sol".
> 1 + 2 * 3.
> [10, 20, 30] |> fn xs -> xs ! 2.

# explicit linear-handle discipline: every operation rebinds the handle,
# close consumes it. Forgetting any step is a compile error.
> h = open @/tmp/sol-demo.txt;
  h2 = writeAll h "written transactionally\n";
  close h2.

# or use the prelude conveniences (themselves written in Sol)
> readPath @/tmp/sol-demo.txt.
> print "buffered write above is only on disk after commit".
