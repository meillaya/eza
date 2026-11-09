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
--   * @year:2025@ and @day:2025-11-03@ restrict the filed date (UTC)
--   * malformed operators are dropped, never fatal
module Eza.SearchQuery
  ( SearchQuery (..)
  , parseSearchQuery
  , ftsExpression
  , sanitizeToken
  , snippetFor
  ) where

import Data.Char (isAlphaNum, isDigit, isSpace)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)

data SearchQuery = SearchQuery
  { sqFts :: Maybe Text
  , sqTerms :: [Text]
  , sqTags :: [Text]
  , sqIsUnread :: Bool
  , sqIsDead :: Bool
  , sqLinkTargets :: [Text]
  , sqYear :: Maybe Int
  , sqDay :: Maybe Text
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
    , sqYear = yearValue
    , sqDay = dayValue
    , sqNegated = [t | t <- map sanitizeToken negated, not (T.null t)]
    }
  where
    tokens = T.words input
    (tagAcc, linkAcc, plainAcc, negAcc, unreadAcc, deadAcc, yearAcc, dayAcc) =
      foldl step ([], [], [], [], False, False, Nothing, Nothing) tokens
    step (ts, ls, ps, ns, u, d, y, dy) tok
      | Just v <- T.stripPrefix "tag:" tok =
          let value = T.toLower (T.strip v)
           in if T.null value then (ts, ls, ps, ns, u, d, y, dy) else (value : ts, ls, ps, ns, u, d, y, dy)
      | Just v <- T.stripPrefix "link:" tok =
          let value = T.strip v
           in if T.null value then (ts, ls, ps, ns, u, d, y, dy) else (ts, value : ls, ps, ns, u, d, y, dy)
      | Just v <- T.stripPrefix "year:" tok =
          (ts, ls, ps, ns, u, d, maybe y Just (parseYear v), dy)
      | Just v <- T.stripPrefix "day:" tok =
          (ts, ls, ps, ns, u, d, y, maybe dy Just (parseDay v))
      | tok == "is:unread" = (ts, ls, ps, ns, True, d, y, dy)
      | tok == "is:dead" = (ts, ls, ps, ns, u, True, y, dy)
      | "is:" `T.isPrefixOf` tok = (ts, ls, ps, ns, u, d, y, dy)
      | "-" `T.isPrefixOf` tok && T.length tok > 1 =
          let value = T.strip (T.drop 1 tok)
           in if T.null value then (ts, ls, ps, ns, u, d, y, dy) else (ts, ls, ps, value : ns, u, d, y, dy)
      | otherwise = (ts, ls, tok : ps, ns, u, d, y, dy)

    -- Preserve source order (the fold builds lists reversed).
    tags = reverse tagAcc
    linkTargets = reverse linkAcc
    plain = reverse plainAcc
    negated = reverse negAcc
    isUnread = unreadAcc
    isDead = deadAcc
    yearValue = yearAcc
    dayValue = dayAcc

-- | A filed year for @year:2025@. Four digits only; anything else is dropped.
parseYear :: Text -> Maybe Int
parseYear value =
  let digits = T.strip value
   in if T.length digits == 4 && T.all isDigit digits
        then readMaybe (T.unpack digits)
        else Nothing

{- | A filed day for @day:2025-11-03@. The day must exist on the calendar and
is kept as the ISO string the database already uses.
-}
parseDay :: Text -> Maybe Text
parseDay value =
  case T.splitOn "-" (T.strip value) of
    [yearText, monthText, dayText]
      | T.length yearText == 4
      , T.length monthText == 2
      , T.length dayText == 2
      , T.all isDigit yearText
      , T.all isDigit monthText
      , T.all isDigit dayText
      , Just year <- readMaybe (T.unpack yearText)
      , Just month <- readMaybe (T.unpack monthText)
      , Just day <- readMaybe (T.unpack dayText)
      , validDate year month day ->
          Just (yearText <> "-" <> monthText <> "-" <> dayText)
    _ -> Nothing

validDate :: Int -> Int -> Int -> Bool
validDate year month day =
  month >= 1 && month <= 12 && day >= 1 && day <= daysInMonth
  where
    daysInMonth
      | month `elem` [1, 3, 5, 7, 8, 10, 12] = 31
      | month == 2 = if leap then 29 else 28
      | otherwise = 30
    leap = (year `mod` 4 == 0 && year `mod` 100 /= 0) || year `mod` 400 == 0

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
