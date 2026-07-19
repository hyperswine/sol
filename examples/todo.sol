# todo.sol — todos with sign-in. Accounts + todo lists live in the shared
# KV store (todo.solkv), so your list follows your login across browsers.
# The view uses the TYPED DSL (lib/ui.sol): Html ADT + Style symbols —
# this file typechecks, no # sol:notypes pragma needed.
# The signed-in user is `Persistent` (event-sourced, survives restarts);
# the in-model todo list is runtime state, refreshed from KV on connect.

base = use "../lib/base".
ui = use "../lib/ui".

nl = Str.fromCode 10.
pI s = case s == "" of True -> 0 | False -> Str.parse s.

# ---- auth (the shared pattern: KV accounts + replay-safe Msg setuser) ----
unwrapU model = case model.user of Persistent u -> u.

doLogin v model =
  (u, p) = base.splitFirst v;
  ({model | pendu = u, pendp = p}, Get "user:{u}" "auth").

doAuth stored model =
  case stored == "" of
    True -> ({model | note = "no such user"}, None)
  | False -> case stored == model.pendp of
      True -> (model, Msg "setuser" model.pendu)
    | False -> ({model | note = "wrong password"}, None).

doReg v model =
  (u, p) = base.splitFirst v;
  ({model | pendu = u, pendp = p}, Get "user:{u}" "regchk").

doRegchk stored model =
  case stored == "" of
    True -> (model, Batch [Put "user:{model.pendu}" model.pendp, Msg "setuser" model.pendu])
  | False -> ({model | note = "user already exists"}, None).

# ---- todos: serialized one per line as "<done> <text>" in KV -------------
findNl s i = case i > Str.len s of True -> 0 | False -> (case Str.at s i == 10 of True -> i | False -> findNl s (i + 1)).

parseItem line = (d, x) = base.splitFirst line; (pI d, x).

parseTodos s | s == "" = [].
parseTodos s =
  k = findNl s 1;
  case k of
    0 -> [parseItem s]
  | _ -> parseItem (base.substr s 1 (k - 1)) :: parseTodos (base.substr s (k + 1) (Str.len s)).

serItem t = (d, x) = t; "{d} {x}".

serTodos ts | ts == [] = "".
serTodos ts = case ts of
  x :: rest -> (case rest == [] of True -> serItem x | False -> "{serItem x}{nl}{serTodos rest}").

flipItem t = (d, x) = t; (1 - d, x).

tAt i k ts | ts == [] = [].
tAt i k ts = case ts of
  x :: rest -> (case i == k of True -> flipItem x :: rest | False -> x :: tAt i (k + 1) rest).

isOpen t = (d, x) = t; d == 0.
openCount ts = List.fold (fn a t -> a + (case isOpen t of True -> 1 | False -> 0)) 0 ts.

save ts model = ({model | todos = ts}, Put "todos:{unwrapU model}" (serTodos ts)).

# ---- MVU ------------------------------------------------------------------
init tok = {user = Persistent "", pendu = "", pendp = "", note = "", todos = []}.

update msg model =
  case msg of
    ("login", v) -> doLogin v model
  | ("auth", v) -> doAuth v model
  | ("register", v) -> doReg v model
  | ("regchk", v) -> doRegchk v model
  | ("setuser", u) -> ({model | user = Persistent u, note = ""}, Msg "refresh" "")
  | ("logout", v) -> ({model | user = Persistent "", todos = []}, None)
  | ("connected", v) -> (model, Msg "refresh" "")
  | ("refresh", v) -> (model, case unwrapU model == "" of True -> None | False -> Get "todos:{unwrapU model}" "gottodos")
  | ("gottodos", v) -> ({model | todos = parseTodos v}, None)
  | ("add", v) -> save ((0, v) :: model.todos) model
  | ("toggle", v) -> save (tAt (Str.parse v) 1 model.todos) model
  | ("clear", v) -> save (List.filter isOpen model.todos) model
  | _ -> (model, None).

# ---- view (typed DSL: ui.Html + ui.Style symbols) ---------------------------

loginView model =
  ui.div [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap3] [
    ui.h2 [ui.Style.textxl, ui.Style.fontbold] [ui.text "Sign in"],
    ui.form "login" ["username", "password"] "Sign in",
    ui.h3 [ui.Style.fontbold] [ui.text "New here? Register"],
    ui.form "register" ["username", "password"] "Create account",
    ui.span [ui.Style.textmuted] [ui.text model.note]
  ].

todoItem k t =
  (d, x) = t;
  ui.onClick "toggle" (str k)
    (ui.div (case d == 1 of True -> [ui.Style.comment, ui.Style.textmuted] | False -> [ui.Style.comment]) [
      ui.text (case d == 1 of True -> "[x] {x}" | False -> "[ ] {x}")
    ]).

todoRows k ts | ts == [] = [].
todoRows k ts = case ts of x :: rest -> todoItem k x :: todoRows (k + 1) rest.

todoView model =
  ui.div [ui.Style.flex, ui.Style.flexcol, ui.Style.gap3] [
    ui.div [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.gap3] [
      ui.span [ui.Style.badge] [ui.text "{unwrapU model} - {openCount model.todos} open"],
      ui.onClick "clear" "" (ui.span [ui.Style.tab] [ui.text "clear done"]),
      ui.onClick "logout" "" (ui.span [ui.Style.tab] [ui.text "sign out"])
    ],
    ui.div [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap2] [
      ui.inputRow "add" "what needs doing?" "Add",
      ui.div [ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] (todoRows 1 model.todos)
    ]
  ].

view model =
  ui.div [ui.Style.container, ui.Style.mxauto, ui.Style.flex, ui.Style.flexcol, ui.Style.gap4, ui.Style.p4] [
    ui.el "header" [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.gap3] [
      ui.h1 [ui.Style.text2xl, ui.Style.fontbold] [ui.text "Sol Todos"]
    ],
    ui.dyn "main" (case unwrapU model == "" of True -> loginView model | False -> todoView model)
  ].

> View.serve 8081 init update view [].
