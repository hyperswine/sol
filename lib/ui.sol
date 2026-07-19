# ui.sol — the typed view DSL: an Html ADT (Elm-style) + first-class
# Style symbols, replacing ad-hoc heterogeneous node records.
#
# Views built with these helpers TYPECHECK (no # sol:notypes needed):
# Html is nominal and recursive, which structural rows can't express —
# this is the Node-ADT decision from the README's gradual-boundary note.
# Web.hs serializes the constructors to the same wire JSON the client
# already speaks, so the browser side is unchanged.
#
#   view model = ui.div [ui.Style.card] [
#     ui.h2 [ui.Style.textxl] [ui.text "hello"],
#     ui.onClick "add" "1" (ui.text "+")
#   ].
#
# A typo'd style (ui.Style.crd) or element helper is a COMPILE error.

Html = Type (
    El String String (List Html)
  | Txt String
  | EvN String String Html
  | DynN String Html
  | FormN String (List String) String
  | InpN String String String
).

# ---- styles: one symbol per served CSS class --------------------------------

Style = Struct {
  container = "container",
  mxauto = "mx-auto",
  flex = "flex",
  flexcol = "flex-col",
  flexrow = "flex-row",
  flexwrap = "flex-wrap",
  flex1 = "flex-1",
  itemscenter = "items-center",
  grid = "grid",
  gridcols2 = "grid-cols-2",
  gap1 = "gap-1",
  gap2 = "gap-2",
  gap3 = "gap-3",
  gap4 = "gap-4",
  p2 = "p-2",
  p4 = "p-4",
  px3 = "px-3",
  py1 = "py-1",
  rounded = "rounded",
  border = "border",
  shadow = "shadow",
  card = "card",
  textsm = "text-sm",
  textxl = "text-xl",
  text2xl = "text-2xl",
  fontbold = "font-bold",
  textmuted = "text-muted",
  badge = "badge",
  tab = "tab",
  tabactive = "tab-active",
  clickable = "clickable",
  comment = "comment",
  input = "input",
  btn = "btn"
}.

# ---- element helpers --------------------------------------------------------

cls ss = List.fold clsJoin "" ss.
clsJoin a s = case a == "" of True -> s | False -> "{a} {s}".

el tag ss ks = El tag (cls ss) ks.

div ss ks = el "div" ss ks.
span ss ks = el "span" ss ks.
h1 ss ks = el "h1" ss ks.
h2 ss ks = el "h2" ss ks.
h3 ss ks = el "h3" ss ks.
p ss ks = el "p" ss ks.
ul ss ks = el "ul" ss ks.
li ss ks = el "li" ss ks.

text s = Txt s.
tf s = Txt "{s}".

# clickable wrapper: sends (ev, val) on click
onClick ev val n = EvN ev val n.

# named dynamic slot: server patches this subtree by name
dyn name n = DynN name n.

# multi-field form: sends fields space-joined under the event name
form ev fields btnLabel = FormN ev fields btnLabel.

# single input + button row
inputRow ev placeholder btnLabel = InpN ev placeholder btnLabel.

# ---- conveniences (typed versions of the old web.sol layer) -----------------
# extra styles are LISTS and append with `+` — List.+ via the Arith row

row extra ks = div ([Style.flex, Style.flexrow, Style.gap2] + extra) ks.
col extra ks = div ([Style.flex, Style.flexcol, Style.gap2] + extra) ks.
card ks = div [Style.card, Style.flex, Style.flexcol, Style.gap2] ks.
badge s = span [Style.badge] [text s].
tabBtn ev val label = onClick ev val (span [Style.tab] [text label]).
btn ev val label = onClick ev val (span [Style.btn] [text label]).
title s = h1 [Style.text2xl, Style.fontbold] [text s].
subtitle s = h3 [Style.fontbold] [text s].
muted s = span [Style.textmuted] [text s].
