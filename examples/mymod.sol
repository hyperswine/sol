# mymod.sol — a file module. `input Unit` is the whole stdin the parent's
# `run` passed in; anything printed here is what the parent captures.
# a new comment
greet name   = "hello {name}, from mymod".
> print (greet (input Unit)).
