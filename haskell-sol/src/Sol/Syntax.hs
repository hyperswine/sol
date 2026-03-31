-- | Sol AST – immutable, simple algebraic types
module Sol.Syntax where

-- | Access key used in @obj|key@ expressions
data Key
  = KStr String   -- bare identifier or quoted string used as dict key
  | KNum Double   -- numeric index (1-based in Sol)
  | KVar String   -- @(varname)@ – use value of variable as key
  deriving (Show, Eq)

-- | Abstract syntax tree for Sol expressions
data Expr
  = ENum  Double          -- number literal: 42, -3, 1.5
  | EStr  String          -- raw string (no interpolation): raw"foo"
  | EFStr String          -- f-string with {var} interpolation: "hello {name}"
  | EList [Expr]          -- array literal: [e1, e2, ...]
  | EDict [(Expr, Expr)]  -- dict literal: {k: v, ...}
  | EVar  String          -- variable or operator reference: x, +, ==
  | EAccess Expr [Key]    -- access chain: obj|key|idx
  | EApp   Expr [Expr]    -- prefix application: func arg1 arg2
  | EPipe  Expr [[Expr]]  -- pipeline: val |> [func,args] |> [func,args]
  | EIf   Expr Expr Expr  -- if cond then t else f
  deriving (Show, Eq)

-- | Top-level Sol statements (each ends with a '.')
data Stmt
  = SAssign String [String] Expr  -- var [params] = body
  | SExpr   Expr                  -- bare expression (e.g. echo "hi")
  deriving (Show, Eq)
