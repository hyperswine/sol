# todo.sol — todos with sign-in. Accounts + todo lists live in the shared
# KV store (todo.solkv), so your list follows your login across browsers.
# The signed-in user is `Persistent` (event-sourced, survives restarts);
# the in-model todo list is runtime state, refreshed from KV on connect.

base = use "../lib/base".

nl = chr 10.
pI s = case s == "" of True -> 0 | False -> parseInt s.

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
findNl s i = case i > strlen s of True -> 0 | False -> (case charAt s i == 10 of True -> i | False -> findNl s (i + 1)).

parseItem line = (d, x) = base.splitFirst line; (pI d, x).

parseTodos s | s == "" = [].
parseTodos s =
  k = findNl s 1;
  case k of
    0 -> [parseItem s]
  | _ -> parseItem (substr s 1 (k - 1)) :: parseTodos (substr s (k + 1) (strlen s)).

serItem t = (d, x) = t; "{d} {x}".

serTodos ts | ts == [] = "".
serTodos ts = case ts of
  x :: rest -> (case rest == [] of True -> serItem x | False -> "{serItem x}{nl}{serTodos rest}").

flipItem t = (d, x) = t; (1 - d, x).

tAt i k ts | ts == [] = [].
tAt i k ts = case ts of
  x :: rest -> (case i == k of True -> flipItem x :: rest | False -> x :: tAt i (k + 1) rest).

isOpen t = (d, x) = t; d == 0.
openCount ts = foldl (fn a t -> a + (case isOpen t of True -> 1 | False -> 0)) 0 ts.

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
  | ("toggle", v) -> save (tAt (parseInt v) 1 model.todos) model
  | ("clear", v) -> save (filter isOpen model.todos) model
  | _ -> (model, None).

# ---- view -------------------------------------------------------------------
node tag cls kids = {cls = cls, kids = kids, tag = tag}.
text s = {text = s}.
dynS name n = {dyn = name, node = n}.
clickable ev val n = {ev = ev, node = n, val = val}.
inputBox name ph btn = {btn = btn, inp = name, ph = ph}.
formBox ev fields btn = {btn = btn, fields = fields, form = ev}.

loginView model =
  node "div" "card flex flex-col gap-3" [
    node "h2" "text-xl font-bold" [text "Sign in"],
    formBox "login" ["username", "password"] "Sign in",
    node "h3" "font-bold" [text "New here? Register"],
    formBox "register" ["username", "password"] "Create account",
    node "span" "text-muted" [text model.note]
  ].

todoItem k t =
  (d, x) = t;
  clickable "toggle" (str k)
    (node "div" (case d == 1 of True -> "comment text-muted" | False -> "comment") [
      text (case d == 1 of True -> "[x] {x}" | False -> "[ ] {x}")
    ]).

todoRows k ts | ts == [] = [].
todoRows k ts = case ts of x :: rest -> todoItem k x :: todoRows (k + 1) rest.

todoView model =
  node "div" "flex flex-col gap-3" [
    node "div" "flex flex-row items-center gap-3" [
      node "span" "badge" [text "{unwrapU model} - {openCount model.todos} open"],
      clickable "clear" "" (node "span" "tab" [text "clear done"]),
      clickable "logout" "" (node "span" "tab" [text "sign out"])
    ],
    node "div" "card flex flex-col gap-2" [
      inputBox "add" "what needs doing?" "Add",
      node "div" "flex flex-col gap-1" (todoRows 1 model.todos)
    ]
  ].

view model =
  node "div" "container mx-auto flex flex-col gap-4 p-4" [
    node "header" "flex flex-row items-center gap-3" [
      node "h1" "text-2xl font-bold" [text "Sol Todos"]
    ],
    dynS "main" (case unwrapU model == "" of True -> loginView model | False -> todoView model)
  ].

> View.serve 8081 init update view [].
