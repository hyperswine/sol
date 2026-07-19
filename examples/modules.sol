# modules.sol — content-addressed file modules.
# The hash is of the AST, so reformatting mymod.sol doesn't break the pin;
# changing its code does (compile-time-of-use error, and re-checked at run).
mymod = use "mymod#47c0102faf5cb7cd".
runner x = run mymod x.
> capture = (runner "hi");
  print "captured: [{capture}]".
> print (run mymod "sol").
