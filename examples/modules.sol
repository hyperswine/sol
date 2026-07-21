# modules.sol — content-addressed file modules.
# The hash is of the AST, so reformatting mymod.sol doesn't break the pin;
# changing its code does (compile-time-of-use error, and re-checked at run).
mymod = use "mymod#3f2e7b4929116f16".
runner x = run mymod x.
> capture = (runner "hi");
  print "captured: [{capture}]".
> print $ run mymod "sol".
