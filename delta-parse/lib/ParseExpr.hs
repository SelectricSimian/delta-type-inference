module ParseExpr
  ( expr
  )
where

import ParseUtils

import qualified Syntax as Stx
import ParseIdent (ident, path)
import qualified ParseIdent (varIdent)

import Data.Bifunctor (bimap, first)

mark :: Parser Stx.Expr -> Parser Stx.Expr
mark p = Stx.Mark <$> getPosition <*> p <*> getPosition

parenthesized :: Parser Stx.Expr
parenthesized = mark $ char '(' *> spaces *> option Stx.Unit expr <* spaces <* char ')'

slot :: Parser Stx.Expr
slot =
  choice
    [ parenthesized
    , litString
    ]

callTail :: Parser (Stx.VarIdentTail, [Stx.Expr])
callTail =
  choice
    [ first <$> (Stx.TailWord <$> ident) <*> (spaces *> callTail)
    , bimap Stx.TailSlot <$> ((:) <$> slot) <*> (spaces *> callTail)
    , pure (Stx.EmptyTail, [])
    ]

callBody :: Parser (Stx.VarIdentBody, [Stx.Expr])
callBody =
  choice
    [ first <$> (Stx.BodyWord <$> ident) <*> (spaces *> callBody)
    , bimap Stx.BodySlot <$> ((:) <$> slot) <*> (spaces *> callTail)
    ]

callNonDot :: Parser Stx.Expr
callNonDot =
  mark $ assemble <$> path <*> (first <$> (Stx.VarIdent <$> ident) <*> (spaces *> callBody)) where
  assemble varPath (varIdent, args) =
    Stx.Call (Stx.Var (Stx.Path varPath varIdent)) (foldr1 Stx.Tuple args)

escapableIdent :: Parser Stx.VarIdent
escapableIdent =
  choice
    [ flip Stx.VarIdent (Stx.BodySlot Stx.EmptyTail) <$> ident
    , char '`' *> spaces *> ParseIdent.varIdent <* spaces <* char '`'
    ]

var :: Parser Stx.Expr
var = mark $ Stx.Var <$> (Stx.Path <$> path <*> escapableIdent)

litUInt :: Parser Stx.Expr
litUInt = mark $ (Stx.LitUInt . read) <$> many1 digit

hexDigitValue :: Parser Int
hexDigitValue =
  choice
    [ rangeParser "digit 0-9" '0' '9'
    , (10 +) <$> rangeParser "letter a-f" 'a' 'f'
    , (10 +) <$> rangeParser "letter A-F" 'A' 'F'
    ]

hexNumber :: Parser Int
hexNumber = foldl ((+) . (16 *)) 0 <$> many1 hexDigitValue

escapeSequence :: Parser Stx.StringComponent
escapeSequence = choice
  [ char '\\' *> pure (Stx.Char '\\')
  , char '"' *> pure (Stx.Char '"')
  , char 'n' *> pure (Stx.Char '\n')
  , char 't' *> pure (Stx.Char '\t')
  , char 'r' *> pure (Stx.Char '\r')
  , char 'u' *> char '{' *> ((Stx.Char . toEnum) <$> hexNumber) <* char '}'
  , Stx.Interpolate <$> parenthesized
  ]

stringComponent :: Parser Stx.StringComponent
stringComponent =
  choice
    [ char '\\' *> escapeSequence
    , Stx.Char <$> satisfy (/= '"')
    ]

litString :: Parser Stx.Expr
litString = mark $
  Stx.LitString <$> (char '"' *> many stringComponent <* char '"')

atomicExpr :: Parser Stx.Expr
atomicExpr = choice
  [ parenthesized
  , try callNonDot
  , var
  , litUInt
  , litString
  ]

data Suffix
  = SuffixDotCall (Stx.Path Stx.VarIdent) [Stx.Expr]
  | SuffixCall Stx.Expr

dotCall :: Parser Suffix
dotCall =
  char '.' *> spaces *>
  (uncurry SuffixDotCall <$>
    (first
      <$> ((.) <$> (Stx.Path <$> path) <*> (Stx.DotVarIdent <$> ident))
      <*> (spaces *> callTail)))

suffixCall :: Parser Suffix
suffixCall = SuffixCall <$> slot

suffix :: Parser Suffix
suffix =
  choice
    [ dotCall
    , suffixCall
    ]

markedSuffix :: Parser (Suffix, SourcePos)
markedSuffix = (,) <$> suffix <*> getPosition

applySuffix :: Stx.Expr -> Suffix -> Stx.Expr
applySuffix receiver (SuffixDotCall varIdent args) =
  Stx.Call (Stx.Var varIdent) (foldr1 Stx.Tuple (receiver : args))
applySuffix receiver (SuffixCall arg) =
  Stx.Call receiver arg

applyAndMarkSuffix :: SourcePos -> Stx.Expr -> (Suffix, SourcePos) -> Stx.Expr
applyAndMarkSuffix pos1 receiver (suff, pos2) =
  Stx.Mark pos1 (applySuffix receiver suff) pos2

suffixes :: Parser Stx.Expr
suffixes =
  {-
  Spaces must belong to the *end* of suffixes here, not the beginning, because if spaces are
  consumed at the beginning of a suffix then that suffix will be considered to have consumed input
  and will become non-negotiable.

  In other words, if spaces were considered to belong the beginning of suffixes, then if there were
  trailing spaces after the last suffix, Parsec would treat those spaces as the beginning of another
  (spurious and nonexistent) suffix, try to parse it, and fail.
  -}
  foldl
    <$> (applyAndMarkSuffix <$> getPosition)
    <*> (atomicExpr <* spaces)
    <*> many (markedSuffix <* spaces)

expr :: Parser Stx.Expr
expr = suffixes