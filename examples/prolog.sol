# prolog.sol — the 8-bit CPU simulator, in actual Prolog syntax, parsed and
# executed by the Sol logic engine (lib/logic.sol + lib/plparse.sol).
#
# The Prolog source below is the Infera example nearly verbatim: cpu state
# cpu(PC, A, B, ZF, CF), an instr/2 program memory, one step/2 clause per
# instruction, and run/3 driving N cycles. Three programs exercise it:
#   A: 45 + 200 = 245 (no carry)         run (cpu 0 0 0 0 0) 3 R
#   B: countdown 5..0 via dec/jnz loop   run (cpu 0 0 0 0 0) 11 R
#   C: 200 + 100 overflows: A=44, CF=1   run (cpu 0 0 0 0 0) 3 R

logic = use "../lib/logic".
pl = use "../lib/plparse".

cpuRules = [
  "# flag helpers",
  "zflag 0 1.",
  "zflag V 0 <- V != 0.",
  "cflag S C <- C is S / 256.",
  "",
  "# instruction stepping",
  "step (cpu PC _ B _ _) (cpu NPC NA B NZ 0) <-",
  "  instr PC (lda Imm), NA is Imm % 256, NPC is PC + 1, zflag NA NZ.",
  "step (cpu PC A _ _ CF) (cpu NPC A NB _ CF) <-",
  "  instr PC (ldb Imm), NB is Imm % 256, NPC is PC + 1.",
  "step (cpu PC A B _ _) (cpu NPC NA B NZ NC) <-",
  "  instr PC add, Sum is A + B, NA is Sum % 256, NPC is PC + 1,",
  "  zflag NA NZ, cflag Sum NC.",
  "step (cpu PC A B _ _) (cpu NPC NA B NZ 0) <-",
  "  instr PC sub, NA is (A - B + 256) % 256, NPC is PC + 1, zflag NA NZ.",
  "step (cpu PC A B _ _) (cpu NPC NA B NZ NC) <-",
  "  instr PC inc, Sum is A + 1, NA is Sum % 256, NPC is PC + 1,",
  "  zflag NA NZ, cflag Sum NC.",
  "step (cpu PC A B _ _) (cpu NPC NA B NZ 0) <-",
  "  instr PC dec, NA is (A - 1 + 256) % 256, NPC is PC + 1, zflag NA NZ.",
  "step (cpu PC _ B _ _) (cpu NPC B B NZ 0) <-",
  "  instr PC mova, NPC is PC + 1, zflag B NZ.",
  "step (cpu PC A _ _ CF) (cpu NPC A A _ CF) <-",
  "  instr PC movb, NPC is PC + 1.",
  "step (cpu PC A B ZF CF) (cpu Addr A B ZF CF) <- instr PC (jmp Addr).",
  "step (cpu PC A B 1 CF) (cpu Addr A B 1 CF) <- instr PC (jz Addr).",
  "step (cpu PC A B 0 CF) (cpu NPC A B 0 CF) <- instr PC (jz _), NPC is PC + 1.",
  "step (cpu PC A B 0 CF) (cpu Addr A B 0 CF) <- instr PC (jnz Addr).",
  "step (cpu PC A B 1 CF) (cpu NPC A B 1 CF) <- instr PC (jnz _), NPC is PC + 1.",
  "step (cpu PC A B ZF CF) (cpu NPC A B ZF CF) <- instr PC nop, NPC is PC + 1.",
  "step (cpu PC A B ZF CF) (cpu PC A B ZF CF) <- instr PC hlt.",
  "",
  "# execution engine",
  "run S 0 S.",
  "run S N SF <- N > 0, step S S1, N1 is N - 1, run S1 N1 SF."
].

progA = [
  "instr 0 (lda 45).",
  "instr 1 (ldb 200).",
  "instr 2 add.",
  "instr 3 hlt.",
  "> run (cpu 0 0 0 0 0) 3 R?"
].

progB = [
  "instr 0 (lda 5).",
  "instr 1 dec.",
  "instr 2 (jnz 1).",
  "instr 3 hlt.",
  "> run (cpu 0 0 0 0 0) 11 R?"
].

progC = [
  "instr 0 (lda 200).",
  "instr 1 (ldb 100).",
  "instr 2 add.",
  "instr 3 hlt.",
  "> run (cpu 0 0 0 0 0) 3 R?"
].

showSols sols | sols == [] = 0.
showSols sols = case sols of s :: r -> ssStep s r.
ssStep s r = u = print "  {s}"; showSols r.

runQ db syms q =
  (gp, nqv, qpairs, s2) = q;
  (sols, fl) = logic.runQuery db s2 gp nqv qpairs 200000;
  case sols == [] of
    True -> print "  false."
  | False -> showSols sols.

runQs db syms qs | qs == [] = 0.
runQs db syms qs = case qs of q :: r -> rqsStep db syms q r.
rqsStep db syms q r = u = runQ db syms (withSyms q syms); runQs db syms r.
withSyms q syms = (gp, nqv, qp) = q; (gp, nqv, qp, syms).

runProgram title extra =
  u0 = print "";
  u1 = print "=== {title} ===";
  (db, qs, syms) = pl.loadProgram (appendL cpuRules extra);
  u2 = print "({lenL db} clauses loaded)";
  runQs db syms qs.

appendL xs ys | xs == [] = ys.
appendL xs ys = case xs of x :: r -> x :: appendL r ys.
lenL xs = foldl l1 0 xs.
l1 a x = a + 1.

> runProgram "program A: 45 + 200 = 245" progA.
> runProgram "program B: countdown 5 -> 0 (dec/jnz loop)" progB.
> runProgram "program C: 200 + 100 overflows (CF = 1)" progC.
