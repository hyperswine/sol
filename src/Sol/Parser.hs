{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use <$>" #-}

-- | Megaparsec parser for Sol.
--
-- Grammar in brief:
--   program    ::= stmt*
--   stmt       ::= (assign | expr) '.'
--   assign     ::= ident ident* ('|' guard_expr)? '=' expr
--   expr       ::= base_expr ('|>' pipe_stage)*
--   base_expr  ::= makeExprParser app operatorTable
--   pipe_stage ::= atom_idx+
--   app        ::= atom_idx+         (first atom is the function)
--   atom_idx   ::= atom_core ('[' key ']')* trailing_sc
--   atom_core  ::= '(' expr ')' | list | dict | string | number | ident
--                  (no trailing whitespace consumed at this level)
--   key        ::= '"' string '"' | digits | ident
--
-- Index access `obj[key]` requires NO whitespace before '['.
-- `f [1, 2]` is function application of f to the list [1, 2].
-- `f[1]`    is index access into f.
--
-- Key lexical rules:
--   - Statements end with '.'
--   - Comments start with '#' (full-line only)
--   - Strings: "..." = f-string, raw"..." = raw string
--   - '|' starts a guard (in assign) or pipeline '|>' (notFollowedBy '>')
--   - Keywords (cannot be identifiers): raw not and or mod

module Sol.Parser (parseProgram, SolParseError) where

import Control.Monad.Combinators.Expr
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
-- Identifiers
-- ---------------------------------------------------------------------------

reserved :: [String]
reserved = ["raw", "not", "and", "or", "mod"]

-- | Parse an identifier core (no trailing whitespace consumed)
pIdentCore :: Parser String
pIdentCore = try $ do
  c <- letterChar
  cs <- many (alphaNumChar <|> char '_' <|> char '\'')
  let name = c : cs
  if name `elem` reserved
    then fail ("'" ++ name ++ "' is a reserved keyword")
    else return name

-- | Parse a non-keyword identifier with trailing whitespace consumed
pIdent :: Parser String
pIdent = label "identifier" $ lexeme pIdentCore

-- | Consume a keyword as a whole word (must not be followed by alnum/_/')
keyword :: String -> Parser ()
keyword w =
  lexeme $
    try $
      string w *> notFollowedBy (alphaNumChar <|> char '_' <|> char '\'')

-- ---------------------------------------------------------------------------
-- Literals (core versions: no trailing whitespace consumed)
-- ---------------------------------------------------------------------------

-- | Number literal core: no trailing whitespace
pNumCore :: Parser Expr
pNumCore = label "number" $ try $ do
  neg <- optional (try (char '-' <* lookAhead digitChar))
  ds <- some digitChar
  frac <- optional (try (char '.' <* lookAhead digitChar) *> some digitChar)
  let s = maybe "" (const "-") neg ++ ds ++ maybe "" ("." ++) frac
  return (ENum (read s))

-- | String literal core: no trailing whitespace consumed after closing quote
pStringLitCore :: Parser Expr
pStringLitCore = pRaw <|> pFStr
  where
    pRaw = label "raw string" $ try $ do
      _ <- string "raw" <* notFollowedBy (alphaNumChar <|> char '_')
      EStr <$> (char '"' *> manyTill L.charLiteral (char '"'))
    pFStr =
      label "string" $
        EFStr <$> (char '"' *> manyTill L.charLiteral (char '"'))

-- | Quoted string content helper (without the EStr wrapper)
quotedStr :: Parser String
quotedStr = char '"' *> manyTill L.charLiteral (char '"')

-- ---------------------------------------------------------------------------
-- Index keys (inside '[' ']')
-- ---------------------------------------------------------------------------

-- | Parse a key inside [...]:
--   "string"  -> KStr  (literal string key)
--   123       -> KNum  (numeric index, 1-based)
--   ident     -> KVar  (look up variable value as key)
pKey :: Parser Key
pKey =
  choice
    [ KStr <$> lexeme quotedStr,               -- "string"
      KNum . read <$> lexeme (some digitChar), -- 123
      KVar <$> pIdent                          -- bare identifier -> KVar
    ]

-- ---------------------------------------------------------------------------
-- Atom core (no trailing whitespace consumed at the outer level)
-- ---------------------------------------------------------------------------

-- | List literal (trailing whitespace consumed by symbol "]" inside)
pListCore :: Parser Expr
pListCore = label "list" $ do
  _ <- char '['
  sc
  es <- pExpr `sepBy` symbol ","
  _ <- char ']'
  return (EList es)

-- | Dict literal
pDictCore :: Parser Expr
pDictCore = label "dict" $ do
  _ <- char '{'
  sc
  ps <- pair `sepBy` symbol ","
  _ <- char '}'
  return (EDict ps)
  where
    pair = do
      k <- (EStr <$> lexeme quotedStr) <|> (EStr <$> pIdent)
      _ <- symbol ":"
      v <- pExpr
      return (k, v)

-- | Parenthesised expression (no trailing whitespace after closing ')')
pParensCore :: Parser Expr
pParensCore = do
  _ <- char '('
  sc
  e <- pExpr
  _ <- char ')'
  return e

-- ---------------------------------------------------------------------------
-- Sigil parsers  ('atom  @flag  !flag)
-- ---------------------------------------------------------------------------

-- | 'word  bare atom: non-whitespace, non-dot characters after the quote
pAtom' :: Parser Expr
pAtom' = lexeme $ try $ do
  _ <- char '\''
  s <- some (alphaNumChar <|> char '-' <|> char '_' <|> char '/')
  return (EAtom s)

-- | @flag  boolean true sigil
pFlagOn :: Parser Expr
pFlagOn = lexeme $ try $ do
  _ <- char '@'
  s <- some (alphaNumChar <|> char '-' <|> char '_')
  return (EFlag s True)

-- | !flag  boolean false sigil
pFlagOff :: Parser Expr
pFlagOff = lexeme $ try $ do
  _ <- char '!'
  notFollowedBy (char '=')  -- don't steal !=
  s <- some (alphaNumChar <|> char '-' <|> char '_')
  return (EFlag s False)

-- | x.y.z  parsed as EAccess (EVar "x") [KStr "y", KStr "z"]
--   No whitespace between dots.  Falls back to plain EVar when no dots.
pDottedIdent :: Parser Expr
pDottedIdent = try $ do
  first <- pIdentCore
  rest  <- many (try (char '.' *> pIdentCore))
  return $ case rest of
    [] -> EVar first
    ks -> EAccess (EVar first) (map KStr ks)

-- | key:val  named argument in an argument list
pNamedArg :: Parser Expr
pNamedArg = lexeme $ try $ do
  k <- pIdentCore
  _ <- char ':'
  notFollowedBy (char ':')  -- don't steal :: if added later
  v <- pAtomIdx             -- RHS is a single atom (no operators, no pipeline)
  return (ENamed k v)

-- | Atomic expression without trailing whitespace
pAtomCore :: Parser Expr
pAtomCore =
  choice
    [ pParensCore,
      pListCore,
      pDictCore,
      pStringLitCore,
      pNumCore,
      pAtom',
      pFlagOn,
      pFlagOff,
      pDottedIdent
    ]

-- ---------------------------------------------------------------------------
-- Atom with index access
--
-- Index access `obj[key]` is ONLY parsed when '[' immediately follows the
-- atom with NO preceding whitespace.  This correctly distinguishes:
--   dict["key"]   →  index access  (no space before [)
--   f [1, 2, 3]   →  application   (space before [, so [ starts a list atom)
-- ---------------------------------------------------------------------------

-- | Atom core followed by zero or more immediate '[' key ']' accesses,
--   then trailing horizontal whitespace is consumed once.
pAtomIdx :: Parser Expr
pAtomIdx = do
  sc             -- consume leading whitespace before this atom
  base <- pAtomCore
  keys <- many (try immediateIndex)
  sc             -- consume trailing whitespace after atom+indices
  return $ case keys of
    [] -> base
    ks -> EAccess base ks
  where
    -- '[' must be the very next character (no whitespace allowed before it).
    -- After the key, ']' may have trailing whitespace.
    immediateIndex :: Parser Key
    immediateIndex = do
      _ <- char '['   -- no preceding sc!
      sc              -- space is OK INSIDE brackets
      k <- pKey
      _ <- char ']'
      return k

-- ---------------------------------------------------------------------------
-- Operator table (infix, with makeExprParser)
-- ---------------------------------------------------------------------------

mkBinary :: String -> Expr -> Expr -> Expr
mkBinary name a b = EApp (EVar name) [a, b]

mkUnary :: String -> Expr -> Expr
mkUnary name e = EApp (EVar name) [e]

operatorTable :: [[Operator Parser Expr]]
operatorTable =
  [ -- Level 1: tightest — multiplication / division / modulo
    [ InfixL (mkBinary "*"   <$ try (symbol "*")),
      InfixL (mkBinary "/"   <$ try (symbol "/")),
      InfixL (mkBinary "mod" <$ keyword "mod")
    ],
    -- Level 2: addition / subtraction
    [ InfixL (mkBinary "+" <$ try (symbol "+")),
      InfixL (mkBinary "-" <$ try (symbol "-"))
    ],
    -- Level 3: comparisons (longer operators first to avoid prefix clash)
    [ InfixL (mkBinary ">=" <$ try (symbol ">=")),
      InfixL (mkBinary "<=" <$ try (symbol "<=")),
      InfixL (mkBinary ">"  <$ try (symbol ">")),
      InfixL (mkBinary "<"  <$ try (symbol "<"))
    ],
    -- Level 4: equality
    [ InfixL (mkBinary "==" <$ try (symbol "==")),
      InfixL (mkBinary "!=" <$ try (symbol "!="))
    ],
    -- Level 5: logical not (unary prefix)
    [ Prefix (mkUnary "not" <$ keyword "not") ],
    -- Level 6: logical and
    [ InfixL (mkBinary "and" <$ keyword "and") ],
    -- Level 7: logical or (loosest)
    [ InfixL (mkBinary "or" <$ keyword "or") ]
  ]

-- ---------------------------------------------------------------------------
-- Application and pipeline
-- ---------------------------------------------------------------------------

-- | A greedy application: first atom is the function, rest are arguments.
--   Named args (key:val) are tried before plain atoms in both head and tail
--   positions so they can appear inside list literals too.
--   This is the base "term" for makeExprParser.
pApp :: Parser Expr
pApp = do
  h  <- try pNamedArg <|> pAtomIdx
  tl <- many (try pNamedArg <|> pAtomIdx)
  return $ toApp h tl

-- | One pipeline stage: atom_idx+ (piped value injected as last arg by eval)
pPipeStage :: Parser [Expr]
pPipeStage = do
  h <- pAtomIdx
  tl <- many pAtomIdx
  return (h : tl)

-- | Top-level expression: infix operators over applications, then optional |> stages
pExpr :: Parser Expr
pExpr = do
  base <- makeExprParser pApp operatorTable
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
      guard_ <- optional $ try $ do
        _ <- char '|'
        notFollowedBy (char '>')
        sc
        pExpr
      _ <- symbol "="
      body <- pExpr
      return (SAssign name params guard_ body)

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
