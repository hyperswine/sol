# auth.sol — the shared sign-in/registration pattern: KV-backed accounts +
# the replay-safe `Msg setuser` handoff. Apps route four events here and
# keep pendu/pendp/note fields (runtime) and a Persistent user field.

base = use "base".
ui = use "ui".

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

loginView heading model =
  ui.card [
    node2 heading,
    ui.form "login" ["username", "password"] "Sign in",
    ui.subtitle "New here? Register",
    ui.form "register" ["username", "password"] "Create account",
    ui.muted model.note
  ].

node2 heading = ui.h2 [ui.Style.textxl, ui.Style.fontbold] [ui.text heading].
