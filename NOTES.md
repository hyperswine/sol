To run, do cabal run sol -- <args> or whatever if using linux (can just install ghc and libs and stuff from apt)
Segfault on LLVM 22 if using JIT compile, need the workaround. On 18 its fine.

The difference between the total run time (0.04s + 0.06s = 0.1s) and the total elapsed time (0.388s) indicates the program spent the remaining time waiting for I/O operations (like disk or network access) or waiting to be scheduled by the operating system.

0.06 in kernelspace code
0.04 in userspace code

25% usage of CPU (0.1/0.388)
If its doing fileops then mostly waiting - for disk, no network here
For writing to temps, locking, reading-validating, commiting

LLVM bring-up + first JIT compiles
   initJIT calls sol_llvm_init (the native target + asm printer inits).
   Then the first Vec.filter/Vec.map/Vec.fold over the threshold trigger compileVecScheme, which does:
•  LLVMContextCreate
•  module + builder creation
•  IR building via dozens of FFI calls
•  LLVMOrcLLJITAddLLVMIRModule + lookup
   These cross into a lot of LLVM code that wasn't hot yet.

SOL_JIT=0 && time cabal run sol -- examples/vec.sol
cabal run sol -- examples/vec.sol  0.04s user 0.02s system 72% cpu 0.084 total

•  Second cabal run (immediately after): build is known to be fresh, all pages are resident in the page cache / dyld caches. Almost no waiting → the small amount of actual work dominates and you see ~83% CPU and 0.078s.

-----

Synchronous Actor block groups could also be supported like they are in FP-RISC and QOS. With Par.create and Par.start and Par.finish
Par.start' would do all of them.
