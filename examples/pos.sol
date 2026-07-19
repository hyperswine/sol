# pos.sol — point of sale with cashier sign-in. Catalog is static Sol data;
# the cart is runtime state; store-wide revenue accumulates in KV and is
# shared across every cashier and every restart.

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

catalog = [("flat white", 5), ("long black", 4), ("cheese toastie", 9), ("brownie", 6)].

priceOf t = (n, p) = t; p.
nameOf t = (n, p) = t; n.
addPrice a t = a + priceOf t.
cartTotal cart = foldl addPrice 0 cart.

init tok = {user = Persistent "", pendu = "", pendp = "", note = "", cart = [], revenue = ""}.

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
  | ("buy", v) -> ({model | cart = (catalog ! parseInt v) :: model.cart}, None)
  | ("void", v) -> ({model | cart = []}, None)
  | ("checkout", v) -> (model, case model.cart == [] of True -> None | False -> Get "revenue" "dorev")
  | ("dorev", v) ->
      ({model | cart = []},
       Batch [Put "revenue" (str (pI v + cartTotal model.cart)),
              Msg "gotrev" (str (pI v + cartTotal model.cart)),
              Print "sale: {cartTotal model.cart} by {unwrapU model}"])
  | _ -> (model, None).

node tag cls kids = {cls = cls, kids = kids, tag = tag}.
text s = {text = s}.
dynS name n = {dyn = name, node = n}.
clickable ev val n = {ev = ev, node = n, val = val}.
formBox ev fields btn = {btn = btn, fields = fields, form = ev}.

loginView model =
  node "div" "card flex flex-col gap-3" [
    node "h2" "text-xl font-bold" [text "Cashier sign in"],
    formBox "login" ["username", "password"] "Sign in",
    node "h3" "font-bold" [text "Register"],
    formBox "register" ["username", "password"] "Create account",
    node "span" "text-muted" [text model.note]
  ].

productBtn k t =
  clickable "buy" (str k) (node "div" "card flex flex-col gap-1" [
    node "div" "font-bold" [text (nameOf t)],
    node "div" "text-muted" [text "${priceOf t}"]
  ]).

productGrid k ts | ts == [] = [].
productGrid k ts = case ts of t :: r -> productBtn k t :: productGrid (k + 1) r.

cartRow t = node "div" "comment flex flex-row gap-2" [
  node "span" "flex-1" [text (nameOf t)], node "span" "" [text "${priceOf t}"]].

posView model =
  node "div" "flex flex-col gap-3" [
    node "div" "flex flex-row items-center gap-3" [
      node "span" "badge" [text "cashier: {unwrapU model}"],
      node "span" "badge" [text "revenue: ${model.revenue}"],
      clickable "logout" "" (node "span" "tab" [text "sign out"])
    ],
    node "div" "grid grid-cols-2 gap-3" (productGrid 1 catalog),
    node "div" "card flex flex-col gap-2" [
      node "h3" "font-bold" [text "cart - total ${cartTotal model.cart}"],
      node "div" "flex flex-col gap-1" (map cartRow model.cart),
      node "div" "flex flex-row gap-2" [
        clickable "checkout" "" (node "span" "btn" [text "checkout"]),
        clickable "void" "" (node "span" "tab" [text "void"])
      ]
    ]
  ].

view model =
  node "div" "container mx-auto flex flex-col gap-4 p-4" [
    node "header" "flex flex-row items-center gap-3" [node "h1" "text-2xl font-bold" [text "Sol POS"]],
    dynS "main" (case unwrapU model == "" of True -> loginView model | False -> posView model)
  ].

> View.serve 8083 init update view [].
