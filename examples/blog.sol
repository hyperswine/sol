# blog.sol — an MVU web app. Sol owns init/update/view; the gen_view
# behavior (Web.hs) owns HTTP, WebSockets, sessions, and dyn-slot diffing.
#
#   ./sol examples/blog.sol      then open http://localhost:8080
ui = use "../lib/ui".
#
# The server remembers your session: the tab you were on (and your
# comments) come back when you revisit — the client stores a session token,
# the model lives server-side keyed by it.

Post = {body : String, title : String}.

posts = [
  {title = "Why SoA",
   body = "Structure-of-arrays is not an optimization, it is a decomposition. A vector of records IS a record of columns; the recursion schemes just read the columns they touch. The AoS view is the reconstruction, and you pay for it only when you ask for it."},
  {title = "Fuel as a contract",
   body = "Every function entry decrements a counter. That is the whole preemption story: structured control flow means recursion is the only loop, so function entry is a safepoint even a spin loop must pass through. The JIT keeps the contract by reifying the counter into native code."},
  {title = "Content addressing",
   body = "A module is the hash of its AST, not its bytes. Reformatting does not change identity; code does. Pin the hash and the code that runs is exactly the code you reviewed - the registry is append-only because meanings never change out from under a name."}].

# ---- view vocabulary (plain records; the client JS interprets them) ----

# ---- MVU ----------------------------------------------------------------
# model: tab + comments are `Persistent` (event-sourced to blog.soldata,
# replayed on restart); lucky / ticks / motd are runtime-only and reset.

unwrap p = case p of Persistent x -> x.

init tok = {tab = Persistent 1, comments = Persistent [], lucky = 0, ticks = 0, motd = ""}.

update msg model =
  case msg of
    ("tab", v) -> ({model | tab = Persistent (Str.parse v)}, None)
  | ("comment", v) ->
      ({model | comments = Persistent ((unwrap model.tab, v) :: unwrap model.comments)},
       Print "new comment: {v}")
  | ("luck", v) -> (model, Rng 1 100 "lucky")
  | ("lucky", v) -> ({model | lucky = Str.parse v}, None)
  | ("motd", v) -> (model, ReadFile "/tmp/motd.txt" "gotmotd")
  | ("gotmotd", v) -> ({model | motd = v}, None)
  | ("tick", v) -> ({model | ticks = model.ticks + 1}, None)
  | _ -> (model, None).

tabCls cur i = case cur == i of True -> [ui.Style.tab, ui.Style.tabactive] | False -> [ui.Style.tab].

tabBtn cur i =
  p = posts ! i;
  ui.onClick "tab" (str i) (ui.el "span" (tabCls cur i) [ui.text p.title]).

tabBar cur =
  ui.el "nav" [ui.Style.flex, ui.Style.flexrow, ui.Style.flexwrap, ui.Style.gap2] (List.map (tabBtn cur) [1, 2, 3]).

postView tab =
  p = posts ! tab;
  ui.el "article" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap2] [
    ui.el "h2" [ui.Style.textxl, ui.Style.fontbold] [ui.text p.title],
    ui.el "p" [ui.Style.textmuted] [ui.text p.body]
  ].

isFor tab c = (i, t) = c; i == tab.
commentItem c = (i, t) = c; ui.el "div" [ui.Style.comment] [ui.text t].

commentsView tab comments =
  mine = List.filter (isFor tab) comments;
  ui.el "section" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap3] [
    ui.el "h3" [ui.Style.fontbold] [ui.text "Comments"],
    ui.el "div" [ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] (List.map commentItem mine),
    ui.inputRow "comment" "write a comment..." "Post"
  ].

statusBar model =
  ui.el "div" [ui.Style.flex, ui.Style.flexrow, ui.Style.flexwrap, ui.Style.itemscenter, ui.Style.gap3, ui.Style.textsm] [
    ui.el "span" [ui.Style.badge] [ui.text "up {model.ticks}s"],
    ui.onClick "luck" "" (ui.el "span" [ui.Style.tab] [ui.text "lucky: {model.lucky}"]),
    ui.onClick "motd" "" (ui.el "span" [ui.Style.tab] [ui.text "motd"]),
    ui.el "span" [ui.Style.textmuted] [ui.text model.motd]
  ].

# the static skeleton renders once; only the dyn slots ever travel again
view model =
  tab = unwrap model.tab;
  comments = unwrap model.comments;
  ui.el "div" [ui.Style.container, ui.Style.mxauto, ui.Style.flex, ui.Style.flexcol, ui.Style.gap4, ui.Style.p4] [
    ui.el "header" [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.gap3] [
      ui.el "h1" [ui.Style.text2xl, ui.Style.fontbold] [ui.text "The Sol Blog"],
      ui.el "span" [ui.Style.badge] [ui.text "MVU over WebSocket"],
      ui.dyn "status" (statusBar model)
    ],
    ui.dyn "tabs" (tabBar tab),
    ui.dyn "post" (postView tab),
    ui.dyn "comments" (commentsView tab comments)
  ].

> View.serve 8080 init update view [(1000, "tick")].
