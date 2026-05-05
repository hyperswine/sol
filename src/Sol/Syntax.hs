-- | Sol AST – immutable, simple algebraic types
module Sol.Syntax where

-- | Access key used in @obj[key]@ expressions
data Key
  = KStr String -- quoted string used as dict key: obj["key"]
  | KNum Double -- numeric index (1-based in Sol): list[1]
  | KVar String -- bare identifier: look up its value as key: obj[varname]
  deriving (Show, Eq)

-- | Abstract syntax tree for Sol expressions
data Expr
  = ENum Double -- number literal: 42, -3, 1.5
  | EStr String -- raw string (no interpolation): raw"foo"
  | EFStr String -- f-string with {var} interpolation: "hello {name}"
  | EList [Expr] -- array literal: [e1, e2, ...]
  | EDict [(Expr, Expr)] -- dict literal: {k: v, ...}
  | EVar String -- variable reference: x
  | EAccess Expr [Key] -- index access chain: obj[key][idx]
  | EApp Expr [Expr] -- juxtaposition application: func arg1 arg2
  | EPipe Expr [[Expr]] -- pipeline: val |> [func,args] |> [func,args]
  | EAtom String -- 'word  bare atom/symbol
  | EFlag String Bool -- @flag (True) or !flag (False)
  | ENamed String Expr -- key:val  named argument pair
  deriving (Show, Eq)

-- | Top-level Sol statements (each ends with a '.')
data Stmt
  = SAssign String [String] (Maybe Expr) Expr -- name [params] (guard?) = body
  | SExpr Expr -- bare expression (e.g. echo "hi")
  deriving (Show, Eq)
