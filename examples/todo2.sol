# todo2.sol — the todo app rebuilt on `use`d libraries: base (helpers),
# web (view vocabulary), auth (sign-in pattern). Compare with todo.sol:
# the app is now ONLY its own logic.

base = use "../lib/base#4cb470f20dc4cca4".
ui = use "../lib/ui#937f83a2a6bbb0da".
auth = use "../lib/auth#71e071e95202e053".

# aliases for the hot paths (qualified access also works everywhere)


# ---- todos: one per line as "<done> <text>" in KV --------------------------
parseItem line = (d, x) = base.splitFirst line; (base.pI d, x).
parseTodos s | s == "" = [].
parseTodos s = List.map parseItem (base.splitCh 10 s).

serItem t = (d, x) = t; "{d} {x}".
serTodos ts | ts == [] = "".
serTodos ts = case ts of
  x :: rest -> (case rest == [] of True -> serItem x | False -> "{serItem x}{base.nl}{serTodos rest}").

flipItem t = (d, x) = t; (1 - d, x).
tAt i k ts | ts == [] = [].
tAt i k ts = case ts of
  x :: rest -> (case i == k of True -> flipItem x :: rest | False -> x :: tAt i (k + 1) rest).

isOpen t = (d, x) = t; d == 0.
openCount ts = List.fold countOpen 0 ts.
countOpen a t = a + base.boolInt (isOpen t).

save ts model = ({model | todos = ts}, Put "todos:{auth.unwrapU model}" (serTodos ts)).

# ---- MVU --------------------------------------------------------------------
init tok = {user = Persistent "", pendu = "", pendp = "", note = "", todos = []}.

update msg model =
  case msg of
    ("login", v) -> auth.doLogin v model
  | ("auth", v) -> auth.doAuth v model
  | ("register", v) -> auth.doReg v model
  | ("regchk", v) -> auth.doRegchk v model
  | ("setuser", u) -> ({model | user = Persistent u, note = ""}, Msg "refresh" "")
  | ("logout", v) -> ({model | user = Persistent "", todos = []}, None)
  | ("connected", v) -> (model, Msg "refresh" "")
  | ("refresh", v) -> (model, case auth.unwrapU model == "" of True -> None | False -> Get "todos:{auth.unwrapU model}" "gottodos")
  | ("gottodos", v) -> ({model | todos = parseTodos v}, None)
  | ("add", v) -> save ((0, v) :: model.todos) model
  | ("toggle", v) -> save (tAt (Str.parse v) 1 model.todos) model
  | ("clear", v) -> save (List.filter isOpen model.todos) model
  | _ -> (model, None).

# ---- view --------------------------------------------------------------------
todoItem k t =
  (d, x) = t;
  ui.onClick "toggle" (str k)
    (ui.div (case d == 1 of True -> [ui.Style.comment, ui.Style.textmuted] | False -> [ui.Style.comment]) [
      ui.text (case d == 1 of True -> "[x] {x}" | False -> "[ ] {x}")
    ]).

todoRows k ts | ts == [] = [].
todoRows k ts = case ts of x :: rest -> todoItem k x :: todoRows (k + 1) rest.

todoView model =
  ui.col [] [
    ui.row [ui.Style.itemscenter] [
      ui.badge "{auth.unwrapU model} - {openCount model.todos} open",
      ui.tabBtn "clear" "" "clear done",
      ui.tabBtn "logout" "" "sign out"
    ],
    ui.card [
      ui.inputRow "add" "what needs doing?" "Add",
      ui.col [ui.Style.gap1] (todoRows 1 model.todos)
    ]
  ].

view model =
  ui.div [ui.Style.container, ui.Style.mxauto, ui.Style.flex, ui.Style.flexcol, ui.Style.gap4, ui.Style.p4] [
    ui.el "header" [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.gap3] [ui.title "Sol Todos"],
    ui.dyn "main" (case auth.unwrapU model == "" of
      True -> auth.loginView "Sign in" model
    | False -> todoView model)
  ].

> View.serve 8081 init update view [].
