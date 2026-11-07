{-# LANGUAGE OverloadedStrings #-}

-- | Parsing of the user-facing search string into FTS terms and filters.
--
-- This is a direct port of the semantics of the Python implementation:
--
--   * plain tokens become prefix FTS matches, ANDed together
--   * @-term@ becomes a negated FTS match
--   * @tag:name@ becomes an exact tag filter (AND across tags)
--   * @is:unread@ / @is:dead@ become flags; other @is:*@ values are dropped
--   * @link:target@ restricts to notes linking to the named bookmark
--   * malformed operators are dropped, never fatal
module Eza.SearchQuery
  ( SearchQuery (..)
  , parseSearchQuery
  , ftsExpression
  , sanitizeToken
  , snippetFor
  ) where

import Data.Char (isAlphaNum, isSpace)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T

data SearchQuery = SearchQuery
  { sqFts :: Maybe Text
  , sqTerms :: [Text]
  , sqTags :: [Text]
  , sqIsUnread :: Bool
  , sqIsDead :: Bool
  , sqLinkTargets :: [Text]
  , sqNegated :: [Text]
  }
  deriving (Show, Eq)

parseSearchQuery :: Text -> SearchQuery
parseSearchQuery input =
  SearchQuery
    { sqFts = ftsExpression plain
    , sqTerms = [t | t <- map sanitizeToken plain, not (T.null t)]
    , sqTags = tags
    , sqIsUnread = isUnread
    , sqIsDead = isDead
    , sqLinkTargets = linkTargets
    , sqNegated = [t | t <- map sanitizeToken negated, not (T.null t)]
    }
  where
    tokens = T.words input
    (tagAcc, linkAcc, plainAcc, negAcc, unreadAcc, deadAcc) = foldl step ([], [], [], [], False, False) tokens
    step (ts, ls, ps, ns, u, d) tok
      | Just v <- T.stripPrefix "tag:" tok =
          let value = T.toLower (T.strip v)
           in if T.null value then (ts, ls, ps, ns, u, d) else (value : ts, ls, ps, ns, u, d)
      | Just v <- T.stripPrefix "link:" tok =
          let value = T.strip v
           in if T.null value then (ts, ls, ps, ns, u, d) else (ts, value : ls, ps, ns, u, d)
      | tok == "is:unread" = (ts, ls, ps, ns, True, d)
      | tok == "is:dead" = (ts, ls, ps, ns, u, True)
      | "is:" `T.isPrefixOf` tok = (ts, ls, ps, ns, u, d)
      | "-" `T.isPrefixOf` tok && T.length tok > 1 =
          let value = T.strip (T.drop 1 tok)
           in if T.null value then (ts, ls, ps, ns, u, d) else (ts, ls, ps, value : ns, u, d)
      | otherwise = (ts, ls, tok : ps, ns, u, d)

    -- Preserve source order (the fold builds lists reversed).
    tags = reverse tagAcc
    linkTargets = reverse linkAcc
    plain = reverse plainAcc
    negated = reverse negAcc
    isUnread = unreadAcc
    isDead = deadAcc

-- | Build the FTS5 MATCH expression for the plain terms.
ftsExpression :: [Text] -> Maybe Text
ftsExpression plain =
  case [t | t <- map sanitizeToken plain, not (T.null t)] of
    [] -> Nothing
    tokens -> Just (T.intercalate " AND " (map (\t -> "\"" <> t <> "\"*") tokens))

-- | Drop every character that is not a word character or a hyphen.
sanitizeToken :: Text -> Text
sanitizeToken = T.strip . T.map keep
  where
    keep c
      | isAlphaNum c || c == '_' || c == '-' = c
      | isSpace c = ' '
      | otherwise = ' '

-- | A short excerpt around the earliest literal term occurrence.  Mirrors the
-- Python snippet behaviour: scan the candidate fields in order, keep the one
-- whose earliest match comes first, and cut a window around it.
snippetFor :: [Text] -> [Text] -> Text
snippetFor terms fields =
  case [ (idx, txt)
       | txt <- mapMaybe nonEmpty fields
       , Just idx <- [earliestMatch terms txt]
       ] of
    [] -> ""
    hits ->
      let (bestIdx, bestText) = minimumByIndex hits
          start = max 0 (bestIdx - 40)
          end = min (T.length bestText) (start + 120)
          prefix = if start > 0 then "..." else ""
          suffix = if end < T.length bestText then "..." else ""
       in prefix <> T.take (end - start) (T.drop start bestText) <> suffix
  where
    nonEmpty t = if T.null (T.strip t) then Nothing else Just (T.unwords (T.words t))

    minimumByIndex = foldl1 (\a@(i, _) b@(j, _) -> if j < i then b else a)

earliestMatch :: [Text] -> Text -> Maybe Int
earliestMatch terms text =
  case [ i
       | term <- terms
       , let needle = T.toLower term
       , not (T.null needle)
       , let i = indexOf needle (T.toLower text)
       , i >= 0
       ] of
    [] -> Nothing
    is -> Just (minimum is)

indexOf :: Text -> Text -> Int
indexOf needle haystack =
  case T.breakOn needle haystack of
    (_, rest) | T.null rest -> -1
    (before, _) -> T.length before
