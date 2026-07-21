# pos.sol — point of sale with cashier sign-in. Catalog is static Sol data;
# the cart is runtime state; store-wide revenue accumulates in KV and is
# shared across every cashier and every restart.

base = use "../lib/base".
ui = use "../lib/ui".

isEmptyString s = case s == "" of True -> True | False -> False.

pI s = case isEmptyString s of True -> 0 | False -> Str.parse s.
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

catalog = [("flat white", 5), ("long black", 4), ("cheese toastie", 9), ("brownie", 6)].

priceOf t = (n, p) = t; p.
nameOf t = (n, p) = t; n.
addPrice a t = a + priceOf t.
cartTotal cart = List.fold addPrice 0 cart.

init tok = {user = Persistent "", pendu = "", pendp = "", note = "", cart = [], revenue = ""}.

# technically msg should be a sum type rather than a string, but this is simpler for now. Its probably fine because constant strings are interned and so the comparisons are fast. But if we had a lot of messages, it would be better to use a sum type.
update msg model =
  case msg of
    ("login", v) -> doLogin v model
  | ("auth", v) -> doAuth v model
  | ("register", v) -> doReg v model
  | ("regchk", v) -> doRegchk v model
  | ("setuser", u) -> ({model | user = Persistent u, note = ""}, Msg "refresh" "")
  | ("logout", v) -> ({model | user = Persistent "", cart = []}, None)
  | ("connected", v) -> (model, Msg "refresh" "")
  | ("refresh", v) -> (model, case unwrapU model == "" of True -> None | False -> Get "revenue" "gotrev")
  | ("gotrev", v) -> ({model | revenue = str (pI v)}, None)
  | ("buy", v) -> ({model | cart = (catalog ! Str.parse v) :: model.cart}, None)
  | ("void", v) -> ({model | cart = []}, None)
  | ("checkout", v) -> (model, case model.cart == [] of True -> None | False -> Get "revenue" "dorev")
  | ("dorev", v) ->
      ({model | cart = []},
       Batch [Put "revenue" (str (pI v + cartTotal model.cart)),
              Msg "gotrev" (str (pI v + cartTotal model.cart)),
              Print "sale: {cartTotal model.cart} by {unwrapU model}"])
  | _ -> (model, None).

# ui.el and ui.form are helpers for generating HTML elements and forms. ui.onClick is a helper for generating clickable elements that send messages to the update function.
# they could probably just be their own fuctions like div/2 or form/3, but this is a bit more convenient for now. The ui module could be expanded to include more helpers for generating HTML elements and forms.
# we are using ui.Style.* which is better than hardcoding style strings

# ui.onClick is its own element rather than some callback or something
# with it we can just directly generate the right html and js like a button with an onclick handler that sends a message to the update function

loginView model =
  ui.el "div" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap3] [
    ui.el "h2" [ui.Style.textxl, ui.Style.fontbold] [ui.text "Cashier sign in"],
    ui.form "login" ["username", "password"] "Sign in",
    ui.el "h3" [ui.Style.fontbold] [ui.text "Register"],
    ui.form "register" ["username", "password"] "Create account",
    ui.el "span" [ui.Style.textmuted] [ui.text model.note]
  ].

productBtn k t =
  ui.onClick "buy" (str k) (ui.el "div" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] [
    ui.el "div" [ui.Style.fontbold] [ui.text (nameOf t)],
    ui.el "div" [ui.Style.textmuted] [ui.text "${priceOf t}"]
  ]).

productGrid k ts | ts == [] = [].
productGrid k ts = case ts of t :: r -> productBtn k t :: productGrid (k + 1) r.

cartRow t = ui.el "div" [ui.Style.comment, ui.Style.flex, ui.Style.flexrow, ui.Style.gap2] [
  ui.el "span" [ui.Style.flex1] [ui.text (nameOf t)], ui.el "span" [] [ui.text "${priceOf t}"]].

posView model =
  ui.el "div" [ui.Style.flex, ui.Style.flexcol, ui.Style.gap3] [
    ui.el "div" [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.gap3] [
      ui.el "span" [ui.Style.badge] [ui.text "cashier: {unwrapU model}"],
      ui.el "span" [ui.Style.badge] [ui.text "revenue: ${model.revenue}"],
      ui.onClick "logout" "" (ui.el "span" [ui.Style.tab] [ui.text "sign out"])
    ],
    ui.el "div" [ui.Style.grid, ui.Style.gridcols2, ui.Style.gap3] (productGrid 1 catalog),
    ui.el "div" [ui.Style.card, ui.Style.flex, ui.Style.flexcol, ui.Style.gap2] [
      ui.el "h3" [ui.Style.fontbold] [ui.text "cart - total ${cartTotal model.cart}"],
      ui.el "div" [ui.Style.flex, ui.Style.flexcol, ui.Style.gap1] (List.map cartRow model.cart),
      ui.el "div" [ui.Style.flex, ui.Style.flexrow, ui.Style.gap2] [
        ui.onClick "checkout" "" (ui.el "span" [ui.Style.btn] [ui.text "checkout"]),
        ui.onClick "void" "" (ui.el "span" [ui.Style.tab] [ui.text "void"])
      ]
    ]
  ].

view model =
  ui.el "div" [ui.Style.container, ui.Style.mxauto, ui.Style.flex, ui.Style.flexcol, ui.Style.gap4, ui.Style.p4] [
    ui.el "header" [ui.Style.flex, ui.Style.flexrow, ui.Style.itemscenter, ui.Style.gap3] [ui.el "h1" [ui.Style.text2xl, ui.Style.fontbold] [ui.text "Sol POS"]],
    ui.dyn "main" (case unwrapU model == "" of True -> loginView model | False -> posView model)
  ].

> View.serve 8083 init update view [].
