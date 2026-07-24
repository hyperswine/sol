# pos2.sol — point of sale, second edition: modern login screen + a
# three-tab dashboard (Register / Receipts / Inventory). Auth is reused
# from lib/auth (pinned); the view rides the theme layer classes plus the
# typed ui DSL. Written to STYLE.md throughout: head-clause tuple
# patterns for update, `|` guards over case-of-Bool, and |> pipelines.
#
# KV layout (store-wide, shared by every cashier, survives restarts):
#   revenue            running total (int string)
#   stock              space-joined counts aligned with `catalog`
#   receipts           newline-joined "n|cashier|total|item, item, ..."

base = use "../lib/base".
ui = use "../lib/ui".
auth = use "../lib/auth".

# ---- catalog ---------------------------------------------------------------

catalog = [("flat white", 5), ("long black", 4), ("cheese toastie", 9),
           ("brownie", 6), ("carrot cake", 7), ("sparkling water", 3)].

nameOf (n, _) = n.
priceOf (_, p) = p.
priceAt k = catalog ! (k + 1) |> priceOf.   # `!` is 1-based
nameAt k = catalog ! (k + 1) |> nameOf.

cartTotal cart = cart |> List.map (fn k -> priceAt k) |> List.fold (fn a b -> a + b) 0.

# ---- stock: a list of ints aligned with the catalog ------------------------

initialStock = catalog |> List.map (fn t -> 12).

encStock ns = ns |> List.map str |> joinWith " ".
decStock "" = initialStock.
decStock s = base.splitCh 32 s |> List.map base.pI.

joinWith sep [] = "".
joinWith sep [x] = x.
joinWith sep (x :: r) = "{x}{sep}{joinWith sep r}".

stockAt k ns = ns ! (k + 1).
inStock k ns = stockAt k ns > 0.

# take one of each cart item out of stock; restock adds a crate of 10
adjust f k ns = mapIdx (fn i n -> case i == k of True -> f n | False -> n) 0 ns.
mapIdx f i [] = [].
mapIdx f i (x :: r) = f i x :: mapIdx f (i + 1) r.

sellCart cart ns = cart |> List.fold (fn acc k -> adjust (fn n -> n - 1) k acc) ns.
restock k ns = adjust (fn n -> n + 10) k ns.

# ---- receipts: newline log, newest rendered first --------------------------

itemNames cart = cart |> List.rev |> List.map (fn k -> nameAt k) |> joinWith ", ".   # ring-up order
receiptLine n who cart = "{n}|{who}|{cartTotal cart}|{itemNames cart}".
appendReceipt old line | old == "" = line.
appendReceipt old line = "{old}{base.nl}{line}".
receiptCount "" = 0.
receiptCount s = base.splitCh 10 s |> List.len.
parseReceipts "" = [].
parseReceipts s = base.splitCh 10 s |> List.rev |> List.map (fn ln -> base.splitCh 124 ln).

# ---- model -----------------------------------------------------------------

init tok = {user = Persistent "", pendu = "", pendp = "", note = "",
            tab = "register", cart = [], revenue = "0",
            stock = initialStock, receipts = ""}.

refreshCmds = Batch [Get "revenue" "gotrev", Get "stock" "gotstk", Get "receipts" "gotrcp"].

# ---- update: one head-clause per message ----------------------------------

update ("login", v) m = auth.doLogin v m.
update ("auth", v) m = auth.doAuth v m.
update ("register", v) m = auth.doReg v m.
update ("regchk", v) m = auth.doRegchk v m.
update ("setuser", u) m = ({m | user = Persistent u, note = ""}, Msg "refresh" "").
update ("logout", _) m = ({m | user = Persistent "", cart = [], tab = "register"}, None).
update ("connected", _) m = (m, Msg "refresh" "").
update ("refresh", _) m | auth.unwrapU m == "" = (m, None).
update ("refresh", _) m = (m, refreshCmds).
update ("gotrev", v) m = ({m | revenue = str (base.pI v)}, None).
update ("gotstk", v) m = ({m | stock = decStock v}, None).
update ("gotrcp", v) m = ({m | receipts = v}, None).
update ("tab", v) m = ({m | tab = v}, None).
update ("buy", v) m | inStock (base.pI v) m.stock = ({m | cart = base.pI v :: m.cart}, None).
update ("buy", _) m = ({m | note = "out of stock"}, None).
update ("void", _) m = ({m | cart = []}, None).
update ("restock", v) m = restocked (restock (base.pI v) m.stock) m.
update ("checkout", _) m | m.cart == [] = (m, None).
update ("checkout", _) m = (m, Get "revenue" "dorev").
update ("dorev", v) m = settle (base.pI v + cartTotal m.cart) m.
update ("dorcp", v) m = record v m.
update _ m = (m, None).

restocked ns m = ({m | stock = ns}, Batch [Put "stock" (encStock ns), Msg "gotstk" (encStock ns)]).

# checkout, step 1: revenue arrived — bank it, take stock, fetch the log
settle rev m =
  ns = sellCart m.cart m.stock;
  ({m | revenue = str rev, stock = ns},
   Batch [Put "revenue" (str rev), Put "stock" (encStock ns), Get "receipts" "dorcp"]).

# checkout, step 2: receipts log arrived — append this sale, clear the cart
record old m =
  line = receiptLine (receiptCount old + 1) (auth.unwrapU m) m.cart;
  log = appendReceipt old line;
  ({m | cart = [], receipts = log},
   Batch [Put "receipts" log, Print "sale: {line}"]).

# ---- view: login hero ------------------------------------------------------

loginView m =
  ui.el "div" ["hero"] [
    ui.el "div" ["hero-card", "flex", "flex-col", "gap-3"] [
      ui.el "div" ["text-3xl", "font-bold", "brand-grad"] [ui.text "Sol POS"],
      ui.el "div" ["text-muted", "mb-2"] [ui.text "Sign in to open the register"],
      ui.form "login" ["username", "password"] "Sign in",
      ui.el "div" ["divider", "mt-2", "mb-2"] [],
      ui.el "div" ["font-semi", "text-sm"] [ui.text "New here?"],
      ui.form "register" ["username", "password"] "Create account",
      noteLine m.note
    ]
  ].

noteLine "" = ui.text "".
noteLine s = ui.el "span" ["badge-red"] [ui.text s].

# ---- view: chrome ----------------------------------------------------------

navTab cur id label | cur == id = ui.onClick "tab" id (ui.el "span" ["navtab", "navtab-active"] [ui.text label]).
navTab cur id label = ui.onClick "tab" id (ui.el "span" ["navtab"] [ui.text label]).

nav m =
  ui.el "div" ["nav"] [
    ui.el "span" ["font-bold", "tracking"] [ui.text "Sol POS"],
    navTab m.tab "register" "Register",
    navTab m.tab "receipts" "Receipts",
    navTab m.tab "inventory" "Inventory",
    ui.el "span" ["flex-1"] [],
    ui.el "span" ["badge-green"] [ui.text "revenue ${m.revenue}"],
    ui.el "span" ["badge"] [ui.text (auth.unwrapU m)],
    ui.onClick "logout" "" (ui.el "span" ["navtab"] [ui.text "sign out"])
  ].

# ---- view: register tab ----------------------------------------------------

stockBadge n | n == 0 = ui.el "span" ["badge-red"] [ui.text "sold out"].
stockBadge n | n <= 3 = ui.el "span" ["badge-amber"] [ui.text "{n} left"].
stockBadge n = ui.el "span" ["badge-green"] [ui.text "{n} in stock"].

productCard ns k t | inStock k ns = productBody ns k t ["card-lg", "hover-lift", "flex", "flex-col", "gap-1"].
productCard ns k t = productBody ns k t ["card-lg", "stock-out", "flex", "flex-col", "gap-1"].
productBody ns k t cs =
  ui.onClick "buy" (str k) (ui.el "div" cs [
    ui.el "div" ["font-semi"] [ui.text (nameOf t)],
    ui.el "div" ["flex", "flex-row", "items-center", "justify-between"] [
      ui.el "span" ["price"] [ui.text "${priceOf t}"],
      stockBadge (stockAt k ns)
    ]
  ]).

productGrid m = ui.el "div" ["grid", "grid-cols-3", "gap-3"] (mapIdx (productCard m.stock) 0 catalog).

# cart lines grouped: (name, qty, subtotal), via the prelude's groupby
cartLines cart =
  cart |> List.groupby (fn k -> k)
       |> List.map (fn g -> lineOf g).
lineOf (k, ks) = (nameAt k, List.len ks, priceAt k * List.len ks).

cartRow (n, q, sub) =
  ui.el "div" ["flex", "flex-row", "gap-2", "comment"] [
    ui.el "span" ["flex-1"] [ui.text n],
    ui.el "span" ["text-muted"] [ui.text "x{q}"],
    ui.el "span" ["price"] [ui.text "${sub}"]
  ].

cartBody [] = [ui.el "div" ["empty"] [ui.text "Cart is empty — tap a product"]].
cartBody cart = cartLines cart |> List.map cartRow.

cartCard m =
  ui.el "div" ["card-lg", "flex", "flex-col", "gap-2"] [
    ui.el "div" ["flex", "flex-row", "items-center", "justify-between"] [
      ui.el "h3" ["font-bold"] [ui.text "Current sale"],
      ui.el "span" ["price", "text-xl"] [ui.text "${cartTotal m.cart}"]
    ],
    ui.el "div" ["flex", "flex-col", "gap-1"] (cartBody m.cart),
    ui.el "div" ["flex", "flex-row", "gap-2", "mt-2"] [
      ui.onClick "checkout" "" (ui.el "span" ["btn"] [ui.text "Charge ${cartTotal m.cart}"]),
      ui.onClick "void" "" (ui.el "span" ["btn-ghost"] [ui.text "Void"])
    ]
  ].

registerTab m = ui.el "div" ["flex", "flex-col", "gap-3"] [productGrid m, cartCard m].

# ---- view: receipts tab ----------------------------------------------------

rcpCell cs s = ui.el "td" cs [ui.text s].
rcpRow [n, who, total, items] =
  ui.el "tr" [] [rcpCell ["font-semi"] "#{n}", rcpCell [] who,
                 rcpCell [] items, rcpCell ["price", "text-right"] "${total}"].
rcpRow _ = ui.el "tr" [] [].

receiptsTable m =
  ui.el "table" ["tbl"] (
    ui.el "tr" [] [ui.el "th" [] [ui.text "receipt"], ui.el "th" [] [ui.text "cashier"],
                   ui.el "th" [] [ui.text "items"], ui.el "th" ["text-right"] [ui.text "total"]]
    :: (parseReceipts m.receipts |> List.map rcpRow)).

receiptsBody m | m.receipts == "" = ui.el "div" ["empty"] [ui.text "No sales yet"].
receiptsBody m = receiptsTable m.

receiptsTab m =
  ui.el "div" ["card-lg", "flex", "flex-col", "gap-2"] [
    ui.el "h3" ["font-bold"] [ui.text "Receipts"],
    ui.el "div" ["text-muted", "text-sm"] [ui.text "{receiptCount m.receipts} sales, ${m.revenue} all-time"],
    receiptsBody m
  ].

# ---- view: inventory tab ---------------------------------------------------

invRow ns k t =
  ui.el "tr" [] [
    ui.el "td" ["font-semi"] [ui.text (nameOf t)],
    ui.el "td" ["price"] [ui.text "${priceOf t}"],
    ui.el "td" [] [stockBadge (stockAt k ns)],
    ui.el "td" ["text-right"] [ui.onClick "restock" (str k) (ui.el "span" ["btn-ghost"] [ui.text "+10"])]
  ].

inventoryTab m =
  ui.el "div" ["card-lg", "flex", "flex-col", "gap-2"] [
    ui.el "h3" ["font-bold"] [ui.text "Inventory"],
    ui.el "table" ["tbl"] (
      ui.el "tr" [] [ui.el "th" [] [ui.text "product"], ui.el "th" [] [ui.text "price"],
                     ui.el "th" [] [ui.text "stock"], ui.el "th" ["text-right"] [ui.text "restock"]]
      :: mapIdx (invRow m.stock) 0 catalog)
  ].

# ---- view: shell -----------------------------------------------------------

tabView m | m.tab == "receipts" = receiptsTab m.
tabView m | m.tab == "inventory" = inventoryTab m.
tabView m = registerTab m.

dashboard m =
  ui.el "div" [] [
    nav m,
    ui.el "div" ["container", "mx-auto", "p-4", "flex", "flex-col", "gap-4"] [tabView m]
  ].

body m | auth.unwrapU m == "" = loginView m.
body m = dashboard m.

view m = ui.el "div" ["app-bg"] [ui.dyn "main" (body m)].

> View.serve 8084 init update view [].
