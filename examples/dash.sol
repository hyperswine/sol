# dash.sol — a live dashboard with sign-in. Metrics tick server-side and
# push to the browser (no client events). Total sign-ins persist in KV;
# the live series is runtime state, abandoned on restart by design.

base = use "../lib/base".
ui = use "../lib/ui".

pI s = case s == "" of True -> 0 | False -> Str.parse s.
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
  | ("sample", v) -> ({model | reqs = Str.parse v, series = takeN 10 (Str.parse v :: model.series)}, None)
  | _ -> (model, None).


bar n | n == 0 = "".
bar n = "#{bar (n - 1)}".

sampleRow v = ui.el "div" [ui.Style.textsm] [ui.text "{bar (v / 8)} {v}"].

loginView model =
  ui.el "div" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap3] [
    ui.el "h2" [ui.Style.textxl, ui.Style.fontbold] [ui.text "Ops sign in"],
    ui.form "login" ["username", "password"] "Sign in",
    ui.el "h3" [ui.Style.fontbold] [ui.text "Register"],
    ui.form "register" ["username", "password"] "Create account",
    ui.el "span" [ui.Style.textmuted] [ui.text model.note]
  ].

dashView model =
  ui.el "div" [ui.Style.flex, ui.Style.flexcol, ui.Style.gap3] [
    ui.el "div" [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.gap3] [
      ui.el "span" [ui.Style.badge] [ui.text (unwrapU model)],
      ui.onClick "logout" "" (ui.el "span" [ui.Style.tab] [ui.text "sign out"])
    ],
    ui.el "div" [ui.Style.grid, ui.Style.gridcols2, ui.Style.gap3] [
      ui.el "div" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] [
        ui.el "h3" [ui.Style.fontbold] [ui.text "requests/sec"],
        ui.el "div" [ui.Style.text2xl, ui.Style.fontbold] [ui.text (str model.reqs)]
      ],
      ui.el "div" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] [
        ui.el "h3" [ui.Style.fontbold] [ui.text "total sign-ins"],
        ui.el "div" [ui.Style.text2xl, ui.Style.fontbold] [ui.text model.logins]
      ],
      ui.el "div" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] [
        ui.el "h3" [ui.Style.fontbold] [ui.text "history"],
        ui.el "div" [ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] (List.map sampleRow model.series)
      ],
      ui.el "div" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] [
        ui.el "h3" [ui.Style.fontbold] [ui.text "about"],
        ui.el "p" [ui.Style.textmuted, ui.Style.textsm] [ui.text "live series is runtime state - it resets on restart; sign-ins persist in KV"]
      ]
    ]
  ].

view model =
  ui.el "div" [ui.Style.container, ui.Style.mxauto, ui.Style.flex, ui.Style.flexcol, ui.Style.gap4, ui.Style.p4] [
    ui.el "header" [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.gap3] [ui.el "h1" [ui.Style.text2xl, ui.Style.fontbold] [ui.text "Sol Ops"]],
    ui.dyn "main" (case unwrapU model == "" of True -> loginView model | False -> dashView model)
  ].

> View.serve 8082 init update view [(500, "tick")].
