# bboard.sol — SPICE netlist -> 400-tie breadboard placement, in pure Sol.
#
# Port of the Python+clingo tool with declared simplifications:
#   * clingo's ASP search -> a transparent greedy scorer over the SAME
#     constraints (no shared holes, one net per strip, reward strip reuse,
#     prefer centre rows). At 56 candidate positions per component this is
#     near-optimal and fully deterministic.
#   * ASCII-only render (no ANSI/unicode), values kept verbatim,
#     2-pin components (R C L D B; V/I are sources, not placed).
#   * netlists are lists of line strings (no argv in Sol yet).
#
# Board model (identical to the Python):
#   30 rows x 2 sides x 5 cols; a strip = (row, side) is one node.
#   Components place vertically: pin_a at row R, pin_b at row R+2, same
#   side+col. GND net -> left neg rail, PWR nets -> left pos rail.
#   Strips are encoded as ints: key = row*2 + side (side: 0=left 1=right),
#   so "two rows down, same side" is just key+4.

base = use "../lib/base".

Opt = Type (Nope | Got x).

# ---------- generic helpers ----------
append xs ys | xs == [] = ys.
append xs ys = case xs of x :: r -> x :: append r ys.

member x xs | xs == [] = False.
member x xs = case xs of y :: r -> (case x == y of True -> True | False -> member x r).

lookupA k ps | ps == [] = Nope.
lookupA k ps = case ps of p :: r -> lookStep k p r.
lookStep k p r = (k2, v) = p; case k2 == k of True -> Got v | False -> lookupA k r.

rev2 acc xs | xs == [] = acc.
rev2 acc xs = case xs of x :: r -> rev2 (x :: acc) r.
reverse xs = rev2 [] xs.

pad3 s = case strlen s >= 3 of True -> s | False -> pad3 " {s}".
pad4 s = case strlen s >= 4 of True -> s | False -> pad4 " {s}".

iabs n = case n < 0 of True -> 0 - n | False -> n.

# ---------- tokenizing ----------
nonEmpty s = s != "".
words ln = filter nonEmpty (base.splitCh 32 ln).
upC c = case base.and2 (c >= 97) (c <= 122) of True -> c - 32 | False -> c.

# ---------- parsing ----------
# component: {kind (char code), na, nb, nm, val}
parseLine ln =
  ws = words ln;
  case ws == [] of True -> [] | False -> parseWs ws.

parseWs ws =
  nm = ws ! 1;
  k = upC (charAt nm 1);
  case base.or2 (k == 42) (k == 46) of  # '*' comment, '.' directive
    True -> []
  | False -> parseKind k nm ws (base.listLen ws).

placeableKinds = [82, 67, 76, 68, 66].  # R C L D B

parseKind k nm ws n =
  case base.and2 (member k placeableKinds) (n >= 3) of
    True -> [{kind = k, na = ws ! 2, nb = ws ! 3, nm = nm,
              val = (case n >= 4 of True -> ws ! 4 | False -> "")}]
  | False -> (case base.and2 (member k [86, 73]) (n >= 3) of  # V I sources
      True -> [{kind = k, na = ws ! 2, nb = ws ! 3, nm = nm, val = "src"}]
    | False -> []).

parseNetlist ls | ls == [] = [].
parseNetlist ls = case ls of l :: r -> append (parseLine l) (parseNetlist r).

isSource c = base.or2 (c.kind == 86) (c.kind == 73).
notSource c = base.not2 (isSource c).

# ---------- net classification ----------
pwrNetsOf comps | comps == [] = [].
pwrNetsOf comps = case comps of c :: r -> pwStep2 c r.
pwStep2 c r = case base.and2 (isSource c) (c.nb == "0") of
  True -> c.na :: pwrNetsOf r
| False -> pwrNetsOf r.

netsOf comps | comps == [] = [].
netsOf comps = case comps of c :: r -> addNet c.na (addNet c.nb (netsOf r)).
addNet n ns = case member n ns of True -> ns | False -> n :: ns.

netTag net pwrs =
  case net == "0" of
    True -> " [GND]"
  | False -> (case member net pwrs of True -> " [PWR]" | False -> "").

# ---------- strip encoding ----------
sKey row side = row * 2 + side.
sRow k = k / 2.
sSide k = k - (k / 2) * 2.

holeLetter side col = chr (97 + side * 5 + col - 1).
holeLabel k col = "{holeLetter (sSide k) col}{sRow k}".

# ---------- placement state ----------
# st = {holes  : [(stripKey, col)]        occupied holes
#       owners : [(stripKey, net)]        the one net a strip carries
#       netstr : [(net, [stripKey])]      strips per net, in placement order
#       places : [(nm, kind, sA, cA, cB)] placements (pinB strip = sA + 4)}
st0 = {holes = [], owners = [], netstr = [], places = []}.

usedCols k holes | holes == [] = [].
usedCols k holes = case holes of h :: r -> usedStep k h r.
usedStep k h r = (k2, c) = h; case k2 == k of True -> c :: usedCols k r | False -> usedCols k r.

freeCol k holes = firstNot 1 (usedCols k holes).
firstNot c used | c > 5 = 0.
firstNot c used = case member c used of True -> firstNot (c + 1) used | False -> c.

stripOK k net owners =
  case lookupA k owners of Nope -> True | Got n -> n == net.

netStrips net netstr = case lookupA net netstr of Nope -> [] | Got ss -> ss.

# ---------- candidate scoring ----------
# reward reusing a strip that already carries this net (direct connection);
# penalise a placement that IGNORES an existing strip of the net (jumper
# debt); small pull toward row 15.
scoreCand na nb sA st =
  sB = sA + 4;
  ownA = lookupA sA st.owners;
  ownB = lookupA sB st.owners;
  okA = stripOK sA na st.owners;
  okB = stripOK sB nb st.owners;
  fA = freeCol sA st.holes;
  fB = freeCol sB st.holes;
  case base.and2 (base.and2 okA okB) (base.and2 (fA > 0) (fB > 0)) of
    False -> 0 - 1000000
  | True ->
      100 * base.boolInt (ownA == Got na)
      + 100 * base.boolInt (ownB == Got nb)
      - 40 * base.boolInt (base.and2 (netStrips na st.netstr != []) (base.not2 (ownA == Got na)))
      - 40 * base.boolInt (base.and2 (netStrips nb st.netstr != []) (base.not2 (ownB == Got nb)))
      - iabs (sRow sA - 14).

allKeys r | r > 28 = [].
allKeys r = sKey r 0 :: sKey r 1 :: allKeys (r + 1).

bestCand na nb ks bk bs st | ks == [] = bk.
bestCand na nb ks bk bs st = case ks of
  k :: r -> bestStep na nb k r bk bs st.
bestStep na nb k r bk bs st =
  s = scoreCand na nb k st;
  case s > bs of
    True -> bestCand na nb r k s st
  | False -> bestCand na nb r bk bs st.

# ---------- committing a placement ----------
own k net owners = case lookupA k owners of
  Nope -> (k, net) :: owners
| Got n -> owners.

track net k netstr =
  ss = netStrips net netstr;
  case member k ss of
    True -> netstr
  | False -> (net, append ss [k]) :: dropKey net netstr.

dropKey k ps | ps == [] = [].
dropKey k ps = case ps of p :: r -> dropStep k p r.
dropStep k p r = (k2, v) = p; case k2 == k of True -> dropKey k r | False -> p :: dropKey k r.

placeOne c st =
  sA = bestCand c.na c.nb (allKeys 1) 0 (0 - 999999) st;
  case sA == 0 of
    True -> placeFail c st
  | False -> commit c sA st.

placeFail c st =
  u = print "!! no legal position for {c.nm}";
  st.

commit c sA st =
  sB = sA + 4;
  cA = freeCol sA st.holes;
  cB = freeCol sB st.holes;
  {st | holes = (sA, cA) :: (sB, cB) :: st.holes,
        owners = own sB c.nb (own sA c.na st.owners),
        netstr = track c.nb sB (track c.na sA st.netstr),
        places = append st.places [(c.nm, c.kind, sA, cA, cB)]}.

placeAll cs st | cs == [] = st.
placeAll cs st = case cs of c :: r -> placeAll r (placeOne c st).

# ---------- wiring ----------
# ws = {holes, labels : [((strip,col), lbl)], rails : [(railName, (row, lbl))],
#       wires : [(net, from, to, kind)], k : counter}
mkWs holes = {holes = holes, labels = [], rails = [], wires = [], k = 0}.

allocLbl k lbl ws =
  c = freeCol k ws.holes;
  case c == 0 of
    True -> ("(full)", ws)
  | False -> (holeLabel k c,
      {ws | holes = (k, c) :: ws.holes, labels = ((k, c), lbl) :: ws.labels}).

# jumpers between consecutive strips of one net
jumpNet net ss ws | ss == [] = ws.
jumpNet net ss ws = case ss of
  s1 :: rest -> (case rest == [] of True -> ws | False -> jumpStep net s1 rest ws).
jumpStep net s1 rest ws = case rest of
  s2 :: more -> jumpDo net s1 s2 more ws.
jumpDo net s1 s2 more ws =
  wsA = {ws | k = ws.k + 1};
  (la, ws2) = allocLbl s1 "W{wsA.k}a" wsA;
  (lb, ws3) = allocLbl s2 "W{wsA.k}b" ws2;
  jumpNet net (s2 :: more) {ws3 | wires = append ws3.wires [(net, la, lb, "JUMPER")]}.

# rail wire: from the net's first strip to the given rail
railWire net rail ss ws =
  case ss of s1 :: rest -> railDo net rail s1 ws.
railDo net rail s1 ws =
  wsA = {ws | k = ws.k + 1};
  (la, ws2) = allocLbl s1 "W{wsA.k}a" wsA;
  {ws2 | rails = (rail, (sRow s1, "W{wsA.k}b")) :: ws2.rails,
         wires = append ws2.wires [(net, la, rail, "RAIL")]}.

wireNets nets pwrs netstr ws | nets == [] = ws.
wireNets nets pwrs netstr ws = case nets of
  n :: r -> wireNets r pwrs netstr (wireOne n pwrs netstr ws).

wireOne n pwrs netstr ws =
  ss = netStrips n netstr;
  ws2 = jumpNet n ss ws;
  case n == "0" of
    True -> railWire n "L-" ss ws2
  | False -> (case member n pwrs of
      True -> railWire n "L+" ss ws2
    | False -> ws2).

# ---------- self-check ----------
# every strip carries exactly one net; every multi-strip net has strips-1
# jumpers (fully connected by construction) — verified, not assumed.
checkOwners owners seen | owners == [] = "no shorts: OK".
checkOwners owners seen = case owners of o :: r -> ownStep o r seen.
ownStep o r seen =
  (k, n) = o;
  case member k seen of
    True -> "SHORT at strip {k}!"
  | False -> checkOwners r (k :: seen).

countWires net wires | wires == [] = 0.
countWires net wires = case wires of w :: r -> cwStep net w r.
cwStep net w r =
  (n2, f, t, kd) = w;
  countWires net r + base.boolInt (base.and2 (n2 == net) (kd == "JUMPER")).

checkNets nets netstr wires | nets == [] = "connectivity: OK".
checkNets nets netstr wires = case nets of n :: r -> cnStep n r netstr wires.
cnStep n r netstr wires =
  ss = netStrips n netstr;
  need = base.listLen ss - 1;
  got = countWires n wires;
  case base.and2 (need > 0) (base.not2 (got == need)) of
    True -> "net {n}: {got}/{need} jumpers MISSING"
  | False -> checkNets r netstr wires.

# ---------- rendering ----------
pinName kind idx =
  case kind == 68 of
    True -> (case idx == 0 of True -> "A" | False -> "K")   # diode A/K
  | False -> (case idx == 0 of True -> "a" | False -> "b").

cellMapOf places | places == [] = [].
cellMapOf places = case places of p :: r -> cmStep p r.
cmStep p r =
  (nm, kd, sA, cA, cB) = p;
  ((sA, cA), "{nm}{pinName kd 0}") :: ((sA + 4, cB), "{nm}{pinName kd 1}") :: cellMapOf r.

cellAt cm k c = case lookupA (k, c) cm of Nope -> "   ." | Got l -> pad4 l.

cells cm k c | c > 5 = "".
cells cm k c = "{cellAt cm k c}{cells cm k (c + 1)}".

railCell rails name row =
  case lookupA name rails of
    Nope -> "  |"
  | Got rl -> railHit rl row.
railHit rl row = (r2, lbl) = rl; case r2 == row of True -> pad3 lbl | False -> "  |".

renderRow cm rails r =
  "{pad3 (str r)} {railCell rails "L-" r} {railCell rails "L+" r}  {cells cm (sKey r 0) 1}  ||  {cells cm (sKey r 1) 1}".

renderRows cm rails r | r > 30 = 0.
renderRows cm rails r =
  u = print (renderRow cm rails r);
  renderRows cm rails (r + 1).

header = "     L-  L+     a   b   c   d   e  ||     f   g   h   i   j".

# ---------- summaries ----------
printComps ps | ps == [] = 0.
printComps ps = case ps of p :: r -> pcStep p r.
pcStep p r =
  (nm, kd, sA, cA, cB) = p;
  u = print "  {nm}  {holeLabel sA cA} -> {holeLabel (sA + 4) cB}";
  printComps r.

stripsStr ss | ss == [] = "".
stripsStr ss = case ss of
  s :: r -> (case r == [] of
    True -> "row {sRow s} {sideName s}"
  | False -> "row {sRow s} {sideName s}, {stripsStr r}").
sideName k = case sSide k == 0 of True -> "L" | False -> "R".

printNets nets pwrs netstr | nets == [] = 0.
printNets nets pwrs netstr = case nets of n :: r -> pnStep n r pwrs netstr.
pnStep n r pwrs netstr =
  u = print "  {n}{netTag n pwrs}: {stripsStr (netStrips n netstr)}";
  printNets r pwrs netstr.

printWires wl | wl == [] = 0.
printWires wl = case wl of w :: r -> pwStep w r.
pwStep w r =
  (n, f, t, kd) = w;
  u = print "  [{kd}] net {n}: {f} -> {t}";
  printWires r.

# ---------- driver ----------
runBoard title ls =
  u0 = print "";
  u1 = print "=== {title} ===";
  comps = parseNetlist ls;
  placeable = filter notSource comps;
  pwrs = pwrNetsOf comps;
  nets = reverse (netsOf placeable);
  st = placeAll placeable st0;
  ws = wireNets nets pwrs st.netstr (mkWs st.holes);
  u2 = print "-- components --";
  u3 = printComps st.places;
  u4 = print "-- nets --";
  u5 = printNets nets pwrs st.netstr;
  u6 = print "-- wires --";
  u7 = printWires ws.wires;
  u8 = print "-- checks --";
  u9 = print "  {checkOwners st.owners []}";
  ua = print "  {checkNets nets st.netstr ws.wires}";
  ub = print "";
  uc = print header;
  cm = append (cellMapOf st.places) ws.labels;
  renderRows cm ws.rails 1.

ex1 = [
  "* RC low-pass filter",
  "V1 vcc 0 DC 5",
  "R1 vcc mid 1k",
  "C1 mid 0 100n",
  ".end"
].

ex2 = [
  "* Voltage divider + filter",
  "V1 vcc 0 DC 9",
  "R1 vcc mid1 10k",
  "R2 mid1 0 10k",
  "C1 mid1 mid2 100n",
  "R3 mid2 0 4k7",
  ".end"
].

ex3 = [
  "* Debounced push-button LED",
  "V1 vcc 0 DC 5",
  "B1 vcc sw_out",
  "R1 sw_out 0 10k",
  "C1 sw_out 0 100n",
  "R2 sw_out led_a 330",
  "D1 led_a 0",
  ".end"
].

> runBoard "RC low-pass filter" ex1.
> runBoard "Voltage divider + filter" ex2.
> runBoard "Debounced push-button LED" ex3.
