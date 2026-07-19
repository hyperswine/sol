# logic.sol — a Prolog engine on Sol's linear mutable Vec.
#
# The WAM's state model maps directly onto linear types: ONE heap of tagged
# cells, destructively bound, threaded linearly through the whole search;
# a trail records bindings so backtracking = unwind trail + reset heap top.
# No copies, no persistent maps — the machine mutates in place and undoes.
#
# Heap cell {tag, val} (SoA, two unboxed i64 columns):
#   tag 0 REF  val = addr        (val == own addr  =>  unbound variable)
#   tag 1 CON  val = symbol id
#   tag 2 INT  val = integer
#   tag 3 STR  val = addr of FUN cell
#   tag 4 FUN  val = symId * 1024 + arity   (args in the next arity cells)
#
# Machine m = (hp, ht, hl, tr, tt, tl):
#   heap vec, heap top (next free addr), heap physical len,
#   trail vec, trail top, trail physical len.  Soft tops let backtracking
#   "truncate" by moving a counter; cells above are reused by later allocs.
#
# Declared simplifications vs a real WAM / full Prolog:
#   structure copying, not compiled instructions; no argument registers or
#   first-arg indexing; no occurs check (standard); `!=` decided at call
#   time (no constraint store); `is` on unbound = fail, not error; depth-
#   first with global fuel; no cut/not/floats/strings.

base = use "base".

# ---------- interned symbols: builtins get FIXED ids ----------
# 1 is  2 plus  3 minus  4 mul  5 div  6 mod  7 gt  8 lt  9 gte  10 lte
# 11 unify  12 neq  13 true  14 fail  15 write  16 nl
builtinSyms = ["is", "plus", "minus", "mul", "div", "mod", "gt", "lt",
               "gte", "lte", "unify", "neq", "true", "fail", "write", "nl"].

symsInit = mkSyms 1 builtinSyms.
mkSyms k ns | ns == [] = [].
mkSyms k ns = case ns of n :: r -> (n, k) :: mkSyms (k + 1) r.

Opt = Type (Nope | Got x).

lookupS k ps | ps == [] = Nope.
lookupS k ps = case ps of p :: r -> lsStep k p r.
lsStep k p r = (k2, v) = p; case k2 == k of True -> Got v | False -> lookupS k r.

symsLen ps = foldl s1 0 ps.
s1 a x = a + 1.

# intern name -> (id, syms')
intern nm syms = case lookupS nm syms of
  Got i -> (i, syms)
| Nope -> internNew nm syms.
internNew nm syms = i = symsLen syms + 1; (i, (nm, i) :: syms).

symName i syms | syms == [] = "?sym{i}".
symName i syms = case syms of p :: r -> snStep i p r.
snStep i p r = (nm, k) = p; case k == i of True -> nm | False -> symName i r.

# ---------- clause-store terms (pure data; copied to heap per try) ----------
# PT: PA symid | PV varIdx (1..nv) | PI int | PC symid [PT]
PT = Type (PA x | PV x | PI x | PC x y).

functorOf t = case t of
  PA s -> s
| PC s args -> s
| PV i -> 0
| PI n -> 0.

# ---------- machine primitives ----------
cellRec t v = {tag = t, val = v}.

# allocate a cell at the soft top (reuse or push); returns (m, addr)
halloc t v m =
  (hp, ht, hl, tr, tt, tl) = m;
  case ht <= hl of
    True -> hallocSet t v hp ht hl tr tt tl
  | False -> hallocPush t v hp ht hl tr tt tl.
hallocSet t v hp ht hl tr tt tl =
  hp2 = Vec.set ht (cellRec t v) hp;
  ((hp2, ht + 1, hl, tr, tt, tl), ht).
hallocPush t v hp ht hl tr tt tl =
  hp2 = Vec.push (cellRec t v) hp;
  ((hp2, ht + 1, hl + 1, tr, tt, tl), ht).

freshVar m = (hp, ht, hl, tr, tt, tl) = m; halloc 0 ht m.

cellAt a m =
  (hp, ht, hl, tr, tt, tl) = m;
  (c, hp2) = Vec.get a hp;
  ((hp2, ht, hl, tr, tt, tl), c.tag, c.val).

setCell a t v m =
  (hp, ht, hl, tr, tt, tl) = m;
  hp2 = Vec.set a (cellRec t v) hp;
  (hp2, ht, hl, tr, tt, tl).

# record a binding on the trail (soft top, reuse or push)
trailPush a m =
  (hp, ht, hl, tr, tt, tl) = m;
  case tt <= tl of
    True -> trSet a hp ht hl tr tt tl
  | False -> trPush a hp ht hl tr tt tl.
trSet a hp ht hl tr tt tl = tr2 = Vec.set tt a tr; (hp, ht, hl, tr2, tt + 1, tl).
trPush a hp ht hl tr tt tl = tr2 = Vec.push a tr; (hp, ht, hl, tr2, tt + 1, tl + 1).

bind a t v m = trailPush a (setCell a t v m).

marks m = (hp, ht, hl, tr, tt, tl) = m; (ht, tt).

# backtrack: unbind everything trailed since tmark, reset heap top
undoTo hmark tmark m =
  (hp, ht, hl, tr, tt, tl) = m;
  m2 = unwind tmark (hp, ht, hl, tr, tt, tl);
  resetTops hmark tmark m2.
unwind tmark m =
  (hp, ht, hl, tr, tt, tl) = m;
  case tt <= tmark of
    True -> m
  | False -> unwind1 tmark hp ht hl tr tt tl.
unwind1 tmark hp ht hl tr tt tl =
  (a, tr2) = Vec.get (tt - 1) tr;
  hp2 = Vec.set a (cellRec 0 a) hp;
  unwind tmark (hp2, ht, hl, tr2, tt - 1, tl).
resetTops hmark tmark m =
  (hp, ht, hl, tr, tt, tl) = m;
  (hp, hmark, hl, tr, tmark, tl).

# ---------- deref ----------
deref a m =
  (m2, t, v) = cellAt a m;
  case base.and2 (t == 0) (base.not2 (v == a)) of
    True -> deref v m2
  | False -> (m2, a, t, v).

# ---------- unification ----------
unify a b m =
  (m1, a2, ta, va) = deref a m;
  (m2, b2, tb, vb) = deref b m1;
  case a2 == b2 of
    True -> (m2, True)
  | False -> unify2 a2 ta va b2 tb vb m2.

unify2 a ta va b tb vb m =
  case ta == 0 of
    True -> (bind a 0 b m, True)
  | False -> (case tb == 0 of
      True -> (bind b 0 a m, True)
    | False -> unifyNV a ta va b tb vb m).

unifyNV a ta va b tb vb m =
  case base.and2 (ta == tb) (base.or2 (ta == 1) (ta == 2)) of
    True -> (m, va == vb)
  | False -> (case base.and2 (ta == 3) (tb == 3) of
      True -> unifyStr va vb m
    | False -> (m, False)).

unifyStr fa fb m =
  (m1, tfa, va) = cellAt fa m;
  (m2, tfb, vb) = cellAt fb m1;
  case va == vb of
    False -> (m2, False)
  | True -> unifyArgs 1 (base.imod2 va 1024) fa fb m2.

unifyArgs k n fa fb m | k > n = (m, True).
unifyArgs k n fa fb m =
  (m2, ok) = unify (fa + k) (fb + k) m;
  case ok of
    False -> (m2, False)
  | True -> unifyArgs (k + 1) n fa fb m2.

# ---------- instantiate a clause term onto the heap ----------
# vars pre-allocated at vbase: PV i -> vbase + i - 1
inst t vbase m = case t of
  PV i -> (m, vbase + i - 1)
| PI n -> halloc 2 n m
| PA s -> halloc 1 s m
| PC s args -> instC s args vbase m.

instC s args vbase m =
  n = base.listLen args;
  (m1, addrs) = instArgs args vbase m;
  (m2, f) = halloc 4 (s * 1024 + n) m1;
  m3 = pushRefs addrs m2;
  halloc 3 f m3.

instArgs ts vbase m | ts == [] = (m, []).
instArgs ts vbase m = case ts of t :: r -> iaStep t r vbase m.
iaStep t r vbase m =
  (m1, a) = inst t vbase m;
  (m2, rest) = instArgs r vbase m1;
  (m2, a :: rest).

pushRefs addrs m | addrs == [] = m.
pushRefs addrs m = case addrs of a :: r -> prStep a r m.
prStep a r m = (m1, u) = halloc 0 a m; pushRefs r m1.

allocVars n m | n == 0 = m.
allocVars n m = (m1, u) = freshVar m; allocVars (n - 1) m1.

# ---------- arithmetic over heap terms ----------
evalA a m =
  (m1, a2, t, v) = deref a m;
  case t == 2 of
    True -> (m1, Got v)
  | False -> (case t == 3 of True -> evalStr v m1 | False -> (m1, Nope)).

evalStr f m =
  (m1, tf, fv) = cellAt f m;
  s = fv / 1024;
  ar = base.imod2 fv 1024;
  case base.and2 (base.and2 (s >= 2) (s <= 6)) (ar == 2) of
    False -> (m1, Nope)
  | True -> evalBin s f m1.

evalBin s f m =
  (m1, ra) = evalA (f + 1) m;
  (m2, rb) = evalA (f + 2) m1;
  case ra of
    Nope -> (m2, Nope)
  | Got x -> (case rb of Nope -> (m2, Nope) | Got y -> (m2, applyOp s x y)).

applyOp s x y =
  case s == 2 of True -> Got (x + y) | False ->
  case s == 3 of True -> Got (x - y) | False ->
  case s == 4 of True -> Got (x * y) | False ->
  case s == 5 of True -> (case y == 0 of True -> Nope | False -> Got (x / y)) | False ->
  (case y == 0 of True -> Nope | False -> Got (base.imod2 x y)).

# ---------- rendering heap terms ----------
rend a syms m =
  (m1, a2, t, v) = deref a m;
  case t == 0 of True -> (m1, "_G{a2}") | False ->
  case t == 1 of True -> (m1, symName v syms) | False ->
  case t == 2 of True -> (m1, "{v}") | False -> rendStr v syms m1.

rendStr f syms m =
  (m1, tf, fv) = cellAt f m;
  s = fv / 1024;
  ar = base.imod2 fv 1024;
  (m2, argsS) = rendArgs 1 ar f syms m1;
  (m2, "({symName s syms}{argsS})").

rendArgs k n f syms m | k > n = (m, "").
rendArgs k n f syms m =
  (m1, s) = rend (f + k) syms m;
  (m2, rest) = rendArgs (k + 1) n f syms m1;
  (m2, " {s}{rest}").

# ---------- the solver ----------
# db     : [(functorSym, headPT, [bodyPT], nvars)]
# goals  : [heap addr]
# qvars  : [(name, addr)] query variables to report
# returns (m, fuelLeft, [solutionString])  — solutions in reverse order
solveG db syms m goals fuel qvars sols | fuel <= 0 = (m, 0, sols).
solveG db syms m goals fuel qvars sols =
  case goals == [] of
    True -> emitSol syms m fuel qvars sols
  | False -> (case goals of g :: gs -> solveGoal db syms m g gs fuel qvars sols).

emitSol syms m fuel qvars sols =
  (m2, s) = rendQVars qvars syms m;
  (m2, fuel, s :: sols).

rendQVars qs syms m | qs == [] = (m, "true").
rendQVars qs syms m = case qs of q :: r -> rqStep q r syms m.
rqStep q r syms m =
  (nm, a) = q;
  (m1, s) = rend a syms m;
  (m2, rest) = rendQVars r syms m1;
  (m2, (case rest == "true" of True -> "{nm} = {s}" | False -> "{nm} = {s}, {rest}")).

solveGoal db syms m g gs fuel qvars sols =
  (m1, g2, t, v) = deref g m;
  case t == 1 of
    True -> dispatch db syms m1 v 0 g2 gs fuel qvars sols
  | False -> (case t == 3 of
      True -> dispatchStr db syms m1 v g2 gs fuel qvars sols
    | False -> (m1, fuel, sols)).

dispatchStr db syms m f g gs fuel qvars sols =
  (m1, tf, fv) = cellAt f m;
  dispatch db syms m1 (fv / 1024) f g gs fuel qvars sols.

# f = FUN cell addr (args at f+1..) or 0 for atoms; s = functor symbol
dispatch db syms m s f g gs fuel qvars sols =
  case s == 13 of True -> solveG db syms m gs fuel qvars sols | False ->  # true
  case s == 14 of True -> (m, fuel, sols) | False ->                      # fail
  case s == 1 of True -> doIs db syms m f gs fuel qvars sols | False ->   # is
  case base.and2 (s >= 7) (s <= 10) of
    True -> doCmp db syms m s f gs fuel qvars sols | False ->             # > < >= <=
  case s == 11 of True -> doUnify db syms m f gs fuel qvars sols | False ->
  case s == 12 of True -> doNeq db syms m f gs fuel qvars sols | False ->
  case s == 15 of True -> doWrite db syms m f gs fuel qvars sols | False ->
  case s == 16 of True -> doNl db syms m gs fuel qvars sols | False ->
  tryClauses db syms m (clausesFor s db) g gs fuel qvars sols.

doIs db syms m f gs fuel qvars sols =
  (m1, r) = evalA (f + 2) m;
  case r of
    Nope -> (m1, fuel, sols)
  | Got n -> doIs2 db syms m1 f n gs fuel qvars sols.
doIs2 db syms m f n gs fuel qvars sols =
  (m1, na) = halloc 2 n m;
  (m2, ok) = unify (f + 1) na m1;
  case ok of
    True -> solveG db syms m2 gs fuel qvars sols
  | False -> (m2, fuel, sols).

doCmp db syms m s f gs fuel qvars sols =
  (m1, ra) = evalA (f + 1) m;
  (m2, rb) = evalA (f + 2) m1;
  case ra of
    Nope -> (m2, fuel, sols)
  | Got x -> (case rb of
      Nope -> (m2, fuel, sols)
    | Got y -> (case cmpOp s x y of
        True -> solveG db syms m2 gs fuel qvars sols
      | False -> (m2, fuel, sols))).

cmpOp s x y =
  case s == 7 of True -> x > y | False ->
  case s == 8 of True -> x < y | False ->
  case s == 9 of True -> x >= y | False -> x <= y.

doUnify db syms m f gs fuel qvars sols =
  (hm, tm) = marks m;
  (m1, ok) = unify (f + 1) (f + 2) m;
  case ok of
    True -> solveG db syms m1 gs fuel qvars sols
  | False -> (undoTo hm tm m1, fuel, sols).

# != at call time: succeed iff NOT unifiable right now (bindings undone)
doNeq db syms m f gs fuel qvars sols =
  (hm, tm) = marks m;
  (m1, ok) = unify (f + 1) (f + 2) m;
  m2 = undoTo hm tm m1;
  case ok of
    True -> (m2, fuel, sols)
  | False -> solveG db syms m2 gs fuel qvars sols.

doWrite db syms m f gs fuel qvars sols =
  (m1, s) = rend (f + 1) syms m;
  u = print s;
  solveG db syms m1 gs fuel qvars sols.

doNl db syms m gs fuel qvars sols =
  u = print "";
  solveG db syms m gs fuel qvars sols.

clausesFor s db | db == [] = [].
clausesFor s db = case db of c :: r -> cfStep s c r.
cfStep s c r =
  (fs, hd, body, nv) = c;
  case fs == s of
    True -> (hd, body, nv) :: clausesFor s r
  | False -> clausesFor s r.

tryClauses db syms m cs g gs fuel qvars sols | cs == [] = (m, fuel, sols).
tryClauses db syms m cs g gs fuel qvars sols =
  case cs of c :: rest -> tcStep db syms m c rest g gs fuel qvars sols.

tcStep db syms m c rest g gs fuel qvars sols =
  (hd, body, nv) = c;
  (hm, tm) = marks m;
  (hp0, vbase0, hl0, tr0, tt0, tl0) = m;
  m1 = allocVars nv m;
  (m2, haddr) = inst hd vbase0 m1;
  (m3, ok) = unify haddr g m2;
  (m4, fuel2, sols2) = tcBody db syms m3 ok body vbase0 gs (fuel - 1) qvars sols;
  m5 = undoTo hm tm m4;
  tryClauses db syms m5 rest g gs fuel2 qvars sols2.

tcBody db syms m ok body vbase gs fuel qvars sols =
  case ok of
    False -> (m, fuel, sols)
  | True -> tcBody2 db syms m body vbase gs fuel qvars sols.
tcBody2 db syms m body vbase gs fuel qvars sols =
  (m1, baddrs) = instArgs body vbase m;
  solveG db syms m1 (base2append baddrs gs) fuel qvars sols.

base2append xs ys | xs == [] = ys.
base2append xs ys = case xs of x :: r -> x :: base2append r ys.

# ---------- top-level query ----------
# qpairs = [(name, varIdx)] — with vbase 1 the heap addr IS the index
# returns (solutions in order, fuelLeft)
runQuery db syms goalsPT nqv qpairs fuel =
  hp = Vec.new Unit;
  tr = Vec.new Unit;
  m0 = (hp, 1, 0, tr, 1, 0);
  m1 = allocVars nqv m0;
  (m2, gaddrs) = instArgs goalsPT 1 m1;
  (m3, fuelLeft, sols) = solveG db syms m2 gaddrs fuel qpairs [];
  (hp2, ht, hl, tr2, tt, tl) = m3;
  u1 = Vec.free hp2;
  u2 = Vec.free tr2;
  (rev [] sols, fuelLeft).

rev acc xs | xs == [] = acc.
rev acc xs = case xs of x :: r -> rev (x :: acc) r.
