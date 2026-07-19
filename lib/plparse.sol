# plparse.sol — parser for the Infera-style Prolog syntax subset:
#   facts        head.
#   rules        head <- goal, goal, ... .
#   queries      > goal, ... ?
#   terms        atoms, Vars, _, ints, f a (g b) juxtaposition compounds
#   operators    * / %  over  + -  over  the non-assoc  > < >= <= != = is
# Operator applications parse to compounds named plus/minus/mul/div/mod/
# gt/lt/gte/lte/neq/unify/is — which intern onto the engine's reserved
# builtin symbol ids, so the parser needs no special knowledge of them.
# Comments (# to end of line) are stripped; '.' ends a clause, '?' a query.

base = use "base".
logic = use "logic".

Opt2 = Type (Nope2 | Got2 x).

# raw terms before interning/numbering
R = Type (RA x | RV x | RI x | RC x y).

# tokens: (kind, text, num)  kind 1=int 2=atom 3=var 4=punct
tInt n = (1, "", n).
tAtom s = (2, s, 0).
tVar s = (3, s, 0).
tP s = (4, s, 0).

tkKind t = (k, s, n) = t; k.
tkStr t = (k, s, n) = t; s.
tkNum t = (k, s, n) = t; n.

isP t s2 = (k, s, n) = t; base.and2 (k == 4) (s == s2).

# ---------- tokenizer ----------
isDigit c = base.and2 (c >= 48) (c <= 57).
isLower c = base.or2 (base.and2 (c >= 97) (c <= 122)) (c == 95).
isUpper c = base.and2 (c >= 65) (c <= 90).
isIdent c = base.or2 (base.or2 (isLower c) (isUpper c)) (isDigit c).

# strip comment: cut line at first '#'
stripC ln =
  k = base.findCh 35 ln 1;
  case k == 0 of True -> ln | False -> base.substr ln 1 (k - 1).

tokLine ln = toks (stripC ln) 1.

toks ln i | i > strlen ln = [].
toks ln i =
  c = charAt ln i;
  case c == 32 of True -> toks ln (i + 1) | False ->
  case isDigit c of True -> lexInt ln i 0 | False ->
  case c == 95 of True -> lexIdent ln i i tVar | False ->
  case isLower c of True -> lexIdent ln i i tAtom | False ->
  case isUpper c of True -> lexIdent ln i i tVar | False -> lexPunct ln i c.

lexInt ln i acc =
  case base.and2 (i <= strlen ln) (isDigit (charAt ln i)) of
    True -> lexInt ln (i + 1) (acc * 10 + (charAt ln i - 48))
  | False -> tInt acc :: toks ln i.

lexIdent ln s i mk =
  case base.and2 (i <= strlen ln) (isIdent (charAt ln i)) of
    True -> lexIdent ln s (i + 1) mk
  | False -> mk (base.substr ln s (i - 1)) :: toks ln i.

# multi-char puncts: <-  >=  <=  !=
lexPunct ln i c =
  nxt = case i < strlen ln of True -> charAt ln (i + 1) | False -> 0;
  case base.and2 (c == 60) (nxt == 45) of True -> tP "<-" :: toks ln (i + 2) | False ->
  case base.and2 (c == 62) (nxt == 61) of True -> tP ">=" :: toks ln (i + 2) | False ->
  case base.and2 (c == 60) (nxt == 61) of True -> tP "<=" :: toks ln (i + 2) | False ->
  case base.and2 (c == 33) (nxt == 61) of True -> tP "!=" :: toks ln (i + 2) | False ->
  tP "{chr c}" :: toks ln (i + 1).

tokAll lns | lns == [] = [].
tokAll lns = case lns of l :: r -> base2app (tokLine l) (tokAll r).
base2app xs ys | xs == [] = ys.
base2app xs ys = case xs of x :: r -> x :: base2app r ys.

# ---------- precedence-climbing parser over the token list ----------
# every parser returns (result, remainingTokens); errors panic

expect toks s = case toks of
  t :: r -> (case isP t s of True -> r | False -> error "expected {s} near {tkStr t}").

peekP toks s = case toks of
  t :: r -> isP t s
| _ -> False.

pExpr toks = pCmp toks.

cmpName s =
  case s == ">" of True -> "gt" | False ->
  case s == "<" of True -> "lt" | False ->
  case s == ">=" of True -> "gte" | False ->
  case s == "<=" of True -> "lte" | False ->
  case s == "!=" of True -> "neq" | False ->
  case s == "=" of True -> "unify" | False -> "".

pCmp toks =
  (l, t1) = pAdd toks;
  case t1 of
    t :: r -> pCmp2 l t t1 r
  | _ -> (l, t1).
pCmp2 l t t1 r =
  case base.and2 (tkKind t == 2) (tkStr t == "is") of
    True -> pCmpRhs "is" l r
  | False -> (case base.and2 (tkKind t == 4) (cmpName (tkStr t) != "") of
      True -> pCmpRhs (cmpName (tkStr t)) l r
    | False -> (l, t1)).
pCmpRhs nm l r =
  (rhs, t2) = pAdd r;
  (RC nm [l, rhs], t2).

pAdd toks =
  (l, t1) = pMul toks;
  pAddLoop l t1.
pAddLoop l toks = case toks of
  t :: r -> (case isP t "+" of
      True -> pAddStep "plus" l r
    | False -> (case isP t "-" of True -> pAddStep2 "minus" l r toks | False -> (l, toks)))
| _ -> (l, toks).
pAddStep nm l r = (rhs, t2) = pMul r; pAddLoop (RC nm [l, rhs]) t2.
pAddStep2 nm l r toks = (rhs, t2) = pMul r; pAddLoop (RC nm [l, rhs]) t2.

pMul toks =
  (l, t1) = pPrim toks;
  pMulLoop l t1.
pMulLoop l toks = case toks of
  t :: r -> (case isP t "*" of
      True -> pMulStep "mul" l r
    | False -> (case isP t "/" of
        True -> pMulStep "div" l r
      | False -> (case isP t "%" of True -> pMulStep "mod" l r | False -> (l, toks))))
| _ -> (l, toks).
pMulStep nm l r = (rhs, t2) = pPrim r; pMulLoop (RC nm [l, rhs]) t2.

# primary: int | var | ( expr ) | atom argterm*  (compound when args follow)
pPrim toks = case toks of
  t :: r -> pPrim2 t r
| _ -> error "unexpected end of input".
pPrim2 t r =
  case tkKind t == 1 of True -> (RI (tkNum t), r) | False ->
  case tkKind t == 3 of True -> (RV (tkStr t), r) | False ->
  case isP t "(" of True -> pParen r | False ->
  case tkKind t == 2 of True -> pCompound (tkStr t) r | False ->
  error "unexpected token {tkStr t}".
pParen r =
  (e, t2) = pExpr r;
  (e, expect t2 ")").

pCompound nm toks =
  (args, t2) = pArgs toks;
  case args == [] of
    True -> (RA nm, t2)
  | False -> (RC nm args, t2).

# argterms: greedily take atoms/ints/vars/parens until a non-arg token
pArgs toks = case toks of
  t :: r -> pArgs2 t r toks
| _ -> ([], toks).
pArgs2 t r toks =
  case tkKind t == 1 of True -> pArgsCons (RI (tkNum t)) r | False ->
  case tkKind t == 3 of True -> pArgsCons (RV (tkStr t)) r | False ->
  case base.and2 (tkKind t == 2) (tkStr t != "is") of True -> pArgsCons (RA (tkStr t)) r | False ->
  case isP t "(" of True -> pArgsParen r | False -> ([], toks).
pArgsCons a r = (rest, t2) = pArgs r; (a :: rest, t2).
pArgsParen r =
  (e, t2) = pParen r;
  (rest, t3) = pArgs t2;
  (e :: rest, t3).

# goals: expr sepBy ','
pGoals toks =
  (g, t1) = pExpr toks;
  case peekP t1 "," of
    True -> pGoalsMore g t1
  | False -> ([g], t1).
pGoalsMore g t1 =
  (rest, t2) = pGoals (expect t1 ",");
  (g :: rest, t2).

# ---------- statements ----------
# Stmt = SClause head body | SQuery goals
Stmt = Type (SClause x y | SQuery x).

pStmt toks = case toks of
  t :: r -> (case isP t ">" of True -> pQuery r | False -> pClause toks).
pQuery r =
  (gs, t2) = pGoals r;
  (SQuery gs, expect t2 "?").
pClause toks =
  (hd, t1) = pExpr toks;
  case peekP t1 "." of
    True -> (SClause hd [], expect t1 ".")
  | False -> pRule hd t1.
pRule hd t1 =
  (body, t2) = pGoals (expect t1 "<-");
  (SClause hd body, expect t2 ".").

pStmts toks | toks == [] = [].
pStmts toks =
  (s, t2) = pStmt toks;
  s :: pStmts t2.

# ---------- R -> PT: intern atoms, number variables ----------
# cv = (varAssoc, nextIdx); syms threaded
conv r syms cv = case r of
  RI n -> (logic.PI n, syms, cv)
| RV nm -> convVar nm syms cv
| RA nm -> convAtom nm syms cv
| RC nm args -> convC nm args syms cv.

convVar nm syms cv =
  (vm, nx) = cv;
  case nm == "_" of
    True -> (logic.PV nx, syms, (vm, nx + 1))
  | False -> convNamed nm syms vm nx.
convNamed nm syms vm nx =
  case lookupV nm vm of
    Got2 i -> (logic.PV i, syms, (vm, nx))
  | Nope2 -> (logic.PV nx, syms, ((nm, nx) :: vm, nx + 1)).

lookupV k ps | ps == [] = Nope2.
lookupV k ps = case ps of p :: r -> lvStep k p r.
lvStep k p r = (k2, v) = p; case k2 == k of True -> Got2 v | False -> lookupV k r.

convAtom nm syms cv =
  (i, syms2) = logic.intern nm syms;
  (logic.PA i, syms2, cv).

convC nm args syms cv =
  (i, syms2) = logic.intern nm syms;
  (pargs, syms3, cv3) = convList args syms2 cv;
  (logic.PC i pargs, syms3, cv3).

convList rs syms cv | rs == [] = ([], syms, cv).
convList rs syms cv = case rs of r :: rest -> clStep r rest syms cv.
clStep r rest syms cv =
  (p, syms2, cv2) = conv r syms cv;
  (ps, syms3, cv3) = convList rest syms2 cv2;
  (p :: ps, syms3, cv3).

# a clause: number vars across head+body; db entry (functor, head, body, nv)
buildClause hd body syms =
  (hp, syms2, cv2) = conv hd syms ([], 1);
  (bp, syms3, cv3) = convList body syms2 cv2;
  (vm, nx) = cv3;
  ((logic.functorOf hp, hp, bp, nx - 1), syms3).

# a query: same, but report named vars in first-appearance order
buildQuery gs syms =
  (gp, syms2, cv2) = convList gs syms ([], 1);
  (vm, nx) = cv2;
  (gp, nx - 1, revL [] vm, syms2).

revL acc xs | xs == [] = acc.
revL acc xs = case xs of x :: r -> revL (x :: acc) r.

# ---------- top level: source lines -> (db, queries, syms) ----------
# queries: [(goalsPT, nqv, qnames)]
loadProgram lns =
  stmts = pStmts (tokAll lns);
  foldStmts stmts [] [] logic.symsInit.

foldStmts ss db qs syms | ss == [] = (revL [] db, revL [] qs, syms).
foldStmts ss db qs syms = case ss of s :: r -> fsStep s r db qs syms.
fsStep s r db qs syms = case s of
  SClause hd body -> fsClause hd body r db qs syms
| SQuery gs -> fsQuery gs r db qs syms.
fsClause hd body r db qs syms =
  (c, syms2) = buildClause hd body syms;
  foldStmts r (c :: db) qs syms2.
fsQuery gs r db qs syms =
  (gp, nqv, qnames, syms2) = buildQuery gs syms;
  foldStmts r db ((gp, nqv, qnames) :: qs) syms2.
