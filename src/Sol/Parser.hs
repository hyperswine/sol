{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use <$>" #-}
-- | Megaparsec parser for Sol.
--
-- Grammar in brief:
--   program  ::= stmt*
--   stmt     ::= (assign | expr) '.'
--   assign   ::= ident ident* '=' expr
--   expr     ::= (if_expr | app) ('|>' pipe_stage)*
--   pipe_stage ::= atom_acc+
--   app      ::= atom_acc+         (first atom is the function)
--   atom_acc ::= atom ('|' key)*
--   atom     ::= '(' expr ')' | list | dict | string | number | op | ident
--   if_expr  ::= 'if' cond 'then' branch 'else' branch
--
-- Key lexical rules:
--   - Statements end with '.'
--   - Comments start with '#' (full-line only)
--   - Strings: "..." = f-string, raw"..." = raw string
--   - Access '|' is distinct from pipeline '|>' (checked with notFollowedBy)
--   - Keywords: if | then | else | raw  (cannot be identifiers)
module Sol.Parser (parseProgram, SolParseError) where

import Data.Functor (void)
import Data.Void
import Sol.Syntax
import Text.Megaparsec
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

type Parser = Parsec Void String

type SolParseError = ParseErrorBundle String Void

-- ---------------------------------------------------------------------------
-- Whitespace / comments
-- ---------------------------------------------------------------------------

-- | Horizontal whitespace only (within a statement line)
sc :: Parser ()
sc = L.space hspace1 empty empty

-- | Multiline whitespace + line comments (between statements)
scnl :: Parser ()
scnl = L.space space1 (L.skipLineComment "#") empty

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

symbol :: String -> Parser String
symbol = L.symbol sc

-- ---------------------------------------------------------------------------
-- Identifiers and operators
-- ---------------------------------------------------------------------------

reserved :: [String]
reserved = ["if", "then", "else", "raw"]

-- | Parse a non-keyword identifier (letters, digits, _, ')
pIdent :: Parser String
pIdent = label "identifier" $ lexeme $ try $ do
  c <- letterChar
  cs <- many (alphaNumChar <|> char '_' <|> char '\'')
  let name = c : cs
  if name `elem` reserved
    then fail ("'" ++ name ++ "' is a reserved keyword")
    else return name

-- | Parse an operator symbol (prefix-style in Sol: + a b)
pOp :: Parser String
pOp =
  label "operator" $
    lexeme $
      try $
        choice
          [ string "==",
            string "!=",
            string "<=",
            string ">=",
            string "+",
            try (string "-" <* notFollowedBy digitChar), -- distinguish from negative number
            string "*",
            string "/",
            string ">",
            string "<"
          ]

-- | Consume a keyword as a whole word
keyword :: String -> Parser ()
keyword w =
  lexeme $
    try $
      string w *> notFollowedBy (alphaNumChar <|> char '_' <|> char '\'')

-- ---------------------------------------------------------------------------
-- Literals
-- ---------------------------------------------------------------------------

-- | Number literal: optional leading '-' immediately before digits
pNum :: Parser Expr
pNum = label "number" $ lexeme $ try $ do
  neg <- optional (try (char '-' <* lookAhead digitChar))
  ds <- some digitChar
  frac <- optional (try (char '.' <* lookAhead digitChar) *> some digitChar)
  let s = maybe "" (const "-") neg ++ ds ++ maybe "" ("." ++) frac
  return (ENum (read s))

-- | String literal: raw"…" (EStr) or "…" (EFStr with {var} interpolation)
pStringLit :: Parser Expr
pStringLit = pRaw <|> pFStr
  where
    pRaw = label "raw string" $ lexeme $ try $ do
      _ <- string "raw" <* notFollowedBy (alphaNumChar <|> char '_')
      EStr <$> (char '"' *> manyTill L.charLiteral (char '"'))
    pFStr =
      label "string" $
        lexeme $
          EFStr <$> (char '"' *> manyTill L.charLiteral (char '"'))

-- | Quoted string content helper (without the EStr wrapper)
quotedStr :: Parser String
quotedStr = char '"' *> manyTill L.charLiteral (char '"')

-- ---------------------------------------------------------------------------
-- Access keys (after '|')
-- ---------------------------------------------------------------------------

pKey :: Parser Key
pKey =
  choice
    [ KVar <$> (char '(' *> pIdent <* char ')'), -- (varname)
      KStr <$> lexeme quotedStr, -- "string"
      KNum . read <$> lexeme (some digitChar), -- 123
      KStr <$> pIdent -- bare identifier
    ]

-- ---------------------------------------------------------------------------
-- Composite expressions
-- ---------------------------------------------------------------------------

-- | List literal
pList :: Parser Expr
pList =
  label "list" $
    EList <$> (symbol "[" *> pExpr `sepBy` symbol "," <* symbol "]")

-- | Dict literal
pDict :: Parser Expr
pDict =
  label "dict" $
    EDict <$> (symbol "{" *> pair `sepBy` symbol "," <* symbol "}")
  where
    pair = do
      k <- (EStr <$> lexeme quotedStr) <|> (EStr <$> pIdent)
      _ <- symbol ":"
      v <- pExpr
      return (k, v)

-- | Parenthesised expression
pParens :: Parser Expr
pParens = symbol "(" *> pExpr <* symbol ")"

-- | Atomic expression (cannot consume further arguments by itself)
pAtom :: Parser Expr
pAtom =
  choice
    [ pParens,
      pList,
      pDict,
      pStringLit,
      pNum,
      EVar <$> pOp, -- operators can appear as values (e.g. map (+ 1))
      EVar <$> pIdent
    ]

-- | Atom optionally extended by one or more '|key' accesses.
--   The '|' must not be followed by '>' (that is pipeline).
pAtomAcc :: Parser Expr
pAtomAcc = do
  base <- pAtom
  keys <- many (try keyAccess)
  return $ case keys of
    [] -> base
    ks -> EAccess base ks
  where
    keyAccess = char '|' <* notFollowedBy (char '>') *> sc *> pKey

-- ---------------------------------------------------------------------------
-- If expression
-- ---------------------------------------------------------------------------

-- | Keywords that terminate an argument list or condition
pStop :: Parser ()
pStop = keyword "then" <|> keyword "else" <|> keyword "if"

pIfExpr :: Parser Expr
pIfExpr = label "if expression" $ do
  keyword "if"
  cond <- pCond
  keyword "then"
  t <- pBranch (keyword "else")
  keyword "else"
  f <- pBranch (void (lookAhead (char '.')) <|> void (lookAhead (string "|>")))
  return (EIf cond t f)
  where
    -- Condition: a sequence of atoms stopped by 'then'
    pCond = do
      h <- pAtomAcc
      tl <- many (notFollowedBy pStop *> pAtomAcc)
      return $ toApp h tl

    -- Branch: sequence of atoms stopped by a halt condition
    pBranch halt = do
      h <- pIfExpr <|> pAtomAcc
      tl <- many (notFollowedBy halt *> notFollowedBy pStop *> pAtomAcc)
      return $ toApp h tl

-- ---------------------------------------------------------------------------
-- Application and pipeline
-- ---------------------------------------------------------------------------

-- | A greedy application: first atom is the function, rest are arguments
pApp :: Parser Expr
pApp = do
  h <- pAtomAcc
  tl <- many pAtomAcc
  return $ toApp h tl

-- | One pipeline stage: atom_acc+ (value is injected as first arg by eval)
pPipeStage :: Parser [Expr]
pPipeStage = do
  h <- pAtomAcc
  tl <- many pAtomAcc
  return (h : tl)

-- | Top-level expression: if | app, then optionally extended with '|>' stages
pExpr :: Parser Expr
pExpr = do
  base <- pIfExpr <|> pApp
  stages <- many (try (symbol "|>") *> pPipeStage)
  return $ case stages of
    [] -> base
    ps -> EPipe base ps

-- ---------------------------------------------------------------------------
-- Statements
-- ---------------------------------------------------------------------------

-- | A single statement, terminated by '.'
pStmt :: Parser Stmt
pStmt = do
  s <- try pAssign <|> (SExpr <$> pExpr)
  _ <- lexeme (char '.')
  scnl
  return s
  where
    pAssign = do
      name <- pIdent
      params <- many pIdent
      _ <- symbol "="
      body <- pExpr
      return (SAssign name params body)

-- | Parse a complete Sol program
parseProgram :: String -> Either SolParseError [Stmt]
parseProgram = parse (scnl *> many pStmt <* eof) "<program>"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Collapse a head + tail list into an application node (or just the head)
toApp :: Expr -> [Expr] -> Expr
toApp h [] = h
toApp h tl = EApp h tl
