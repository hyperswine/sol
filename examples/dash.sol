# dash.sol — a live dashboard with sign-in. Metrics tick server-side and
# push to the browser (no client events). Total sign-ins persist in KV;
# the live series is runtime state, abandoned on restart by design.

base = use "../lib/base".

pI s = case s == "" of True -> 0 | False -> parseInt s.
unwrapU model = case model.user of Persistent u -> u.

doLogin v model = (u, p) = base.splitFirst v; ({model | pendu = u, pendp = p}, Get "user:{u}" "auth").
doAuth stored model =
  case stored == "" of
    True -> ({model | note = "no such user"}, None)
  | False -> case stored == model.pendp of
      True -> (model, Msg "setuser" model.pendu)
    | False -> ({model | note = "wrong password"}, None).
doReg v model = (u, p) = base.splitFirst v; ({model | pendu = u, pendp = p}, Get "user:{u}" "regchk").
doRegchk stored model =
  case stored == "" of
    True -> (model, Batch [Put "user:{model.pendu}" model.pendp, Msg "setuser" model.pendu])
  | False -> ({model | note = "user already exists"}, None).

takeN n xs | n == 0 = [].
takeN n xs | xs == [] = [].
takeN n xs = case xs of x :: r -> x :: takeN (n - 1) r.

init tok = {user = Persistent "", pendu = "", pendp = "", note = "", series = [], reqs = 0, logins = ""}.

update msg model =
  case msg of
    ("login", v) -> doLogin v model
  | ("auth", v) -> doAuth v model
  | ("register", v) -> doReg v model
  | ("regchk", v) -> doRegchk v model
  | ("setuser", u) -> ({model | user = Persistent u, note = ""}, Batch [Msg "refresh" "", Get "logins" "bump"])
  | ("bump", v) -> (model, Batch [Put "logins" (str (pI v + 1)), Msg "gotlogins" (str (pI v + 1))])
  | ("logout", v) -> ({model | user = Persistent ""}, None)
  | ("connected", v) -> (model, Msg "refresh" "")
  | ("refresh", v) -> (model, case unwrapU model == "" of True -> None | False -> Get "logins" "gotlogins")
  | ("gotlogins", v) -> ({model | logins = v}, None)
  | ("tick", v) -> (model, case unwrapU model == "" of True -> None | False -> Rng 20 95 "sample")
  | ("sample", v) -> ({model | reqs = parseInt v, series = takeN 10 (parseInt v :: model.series)}, None)
  | _ -> (model, None).

node tag cls kids = {cls = cls, kids = kids, tag = tag}.
text s = {text = s}.
dynS name n = {dyn = name, node = n}.
clickable ev val n = {ev = ev, node = n, val = val}.
formBox ev fields btn = {btn = btn, fields = fields, form = ev}.

bar n | n == 0 = "".
bar n = "#{bar (n - 1)}".

sampleRow v = node "div" "text-sm" [text "{bar (v / 8)} {v}"].

loginView model =
  node "div" "card flex flex-col gap-3" [
    node "h2" "text-xl font-bold" [text "Ops sign in"],
    formBox "login" ["username", "password"] "Sign in",
    node "h3" "font-bold" [text "Register"],
    formBox "register" ["username", "password"] "Create account",
    node "span" "text-muted" [text model.note]
  ].

dashView model =
  node "div" "flex flex-col gap-3" [
    node "div" "flex flex-row items-center gap-3" [
      node "span" "badge" [text (unwrapU model)],
      clickable "logout" "" (node "span" "tab" [text "sign out"])
    ],
    node "div" "grid grid-cols-2 gap-3" [
      node "div" "card flex flex-col gap-1" [
        node "h3" "font-bold" [text "requests/sec"],
        node "div" "text-2xl font-bold" [text (str model.reqs)]
      ],
      node "div" "card flex flex-col gap-1" [
        node "h3" "font-bold" [text "total sign-ins"],
        node "div" "text-2xl font-bold" [text model.logins]
      ],
      node "div" "card flex flex-col gap-1" [
        node "h3" "font-bold" [text "history"],
        node "div" "flex flex-col gap-1" (map sampleRow model.series)
      ],
      node "div" "card flex flex-col gap-1" [
        node "h3" "font-bold" [text "about"],
        node "p" "text-muted text-sm" [text "live series is runtime state - it resets on restart; sign-ins persist in KV"]
      ]
    ]
  ].

view model =
  node "div" "container mx-auto flex flex-col gap-4 p-4" [
    node "header" "flex flex-row items-center gap-3" [node "h1" "text-2xl font-bold" [text "Sol Ops"]],
    dynS "main" (case unwrapU model == "" of True -> loginView model | False -> dashView model)
  ].

> View.serve 8082 init update view [(500, "tick")].
