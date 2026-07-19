# blog.sol — an MVU web app. Sol owns init/update/view; the gen_view
# behavior (Web.hs) owns HTTP, WebSockets, sessions, and dyn-slot diffing.
#
#   ./sol examples/blog.sol      then open http://localhost:8080
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
node tag cls kids = {cls = cls, kids = kids, tag = tag}.
text s = {text = s}.
dynS name n = {dyn = name, node = n}.
clickable ev val n = {ev = ev, node = n, val = val}.
inputBox name ph btn = {btn = btn, inp = name, ph = ph}.

# ---- MVU ----------------------------------------------------------------
# model: tab + comments are `Persistent` (event-sourced to blog.soldata,
# replayed on restart); lucky / ticks / motd are runtime-only and reset.

unwrap p = case p of Persistent x -> x.

init tok = {tab = Persistent 1, comments = Persistent [], lucky = 0, ticks = 0, motd = ""}.

update msg model =
  case msg of
    ("tab", v) -> ({model | tab = Persistent (parseInt v)}, None)
  | ("comment", v) ->
      ({model | comments = Persistent ((unwrap model.tab, v) :: unwrap model.comments)},
       Print "new comment: {v}")
  | ("luck", v) -> (model, Rng 1 100 "lucky")
  | ("lucky", v) -> ({model | lucky = parseInt v}, None)
  | ("motd", v) -> (model, ReadFile "/tmp/motd.txt" "gotmotd")
  | ("gotmotd", v) -> ({model | motd = v}, None)
  | ("tick", v) -> ({model | ticks = model.ticks + 1}, None)
  | _ -> (model, None).

tabCls cur i = case cur == i of True -> "tab tab-active" | False -> "tab".

tabBtn cur i =
  p = posts ! i;
  clickable "tab" (str i) (node "span" (tabCls cur i) [text p.title]).

tabBar cur =
  node "nav" "flex flex-row flex-wrap gap-2" (map (tabBtn cur) [1, 2, 3]).

postView tab =
  p = posts ! tab;
  node "article" "card flex flex-col gap-2" [
    node "h2" "text-xl font-bold" [text p.title],
    node "p" "text-muted" [text p.body]
  ].

isFor tab c = (i, t) = c; i == tab.
commentItem c = (i, t) = c; node "div" "comment" [text t].

commentsView tab comments =
  mine = filter (isFor tab) comments;
  node "section" "card flex flex-col gap-3" [
    node "h3" "font-bold" [text "Comments"],
    node "div" "flex flex-col gap-1" (map commentItem mine),
    inputBox "comment" "write a comment..." "Post"
  ].

statusBar model =
  node "div" "flex flex-row flex-wrap items-center gap-3 text-sm" [
    node "span" "badge" [text "up {model.ticks}s"],
    clickable "luck" "" (node "span" "tab" [text "lucky: {model.lucky}"]),
    clickable "motd" "" (node "span" "tab" [text "motd"]),
    node "span" "text-muted" [text model.motd]
  ].

# the static skeleton renders once; only the dyn slots ever travel again
view model =
  tab = unwrap model.tab;
  comments = unwrap model.comments;
  node "div" "container mx-auto flex flex-col gap-4 p-4" [
    node "header" "flex flex-row items-center gap-3" [
      node "h1" "text-2xl font-bold" [text "The Sol Blog"],
      node "span" "badge" [text "MVU over WebSocket"],
      dynS "status" (statusBar model)
    ],
    dynS "tabs" (tabBar tab),
    dynS "post" (postView tab),
    dynS "comments" (commentsView tab comments)
  ].

> View.serve 8080 init update view [(1000, "tick")].
