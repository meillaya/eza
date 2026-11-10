{- | Ledger page segmentation, shared by the Miso client and the native tests.

The client loads the ledger in pages. A page is a flat, sorted list of
bookmarks; the ledger paints it as one section per filed year so the year
headings describe the archive instead of repeating every time the sort field
crosses a year boundary.
-}
module Eza.Ledger (
    LedgerEntry (..),
    ledgerEntries,
) where

import Data.IntSet (IntSet)
import qualified Data.IntSet as IS
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import Eza.Time (utcYear)
import Eza.Types (BookmarkSummary (..))

-- | One line of the ledger: a year divider or a record row.
data LedgerEntry
    = LedgerYear Int (Maybe Int)
    | LedgerRow Int BookmarkSummary
    deriving stock (Show, Eq)

{- | Group the loaded records into one section per filed year, plus its rows.

The sections keep the order in which each year first appears in the result
list, so appending a page never moves an existing section: the response order
decides the ledger order, and the year dividers only label it. Rows keep the
result order inside their section and carry their index in the original list,
so the cursor and the scroll offsets stay in step with the loaded page.

A record without an original save date (@created_at = 0@) has no filed year
and is not part of any section; the ledger omits it rather than inventing a
1970 heading.

The first argument is the per-year matching count the server returns for a
filtered list (@year_counts@), so a divider can print how many of that year's
records match the query.
-}
ledgerEntries :: [(Int, Int)] -> [BookmarkSummary] -> [LedgerEntry]
ledgerEntries yearHere rows = concatMap block orderedYears
  where
    here = M.fromList yearHere
    indexed = zip [0 ..] rows

    filedYear :: BookmarkSummary -> Maybe Int
    filedYear bookmark
        | bsCreatedAt bookmark > 0 = Just (utcYear (bsCreatedAt bookmark))
        | otherwise = Nothing

    -- Built from the right so the rows of a year stay in result order.
    byYear :: M.Map Int [(Int, BookmarkSummary)]
    byYear =
        foldr
            ( \(idx, bookmark) acc ->
                case filedYear bookmark of
                    Nothing -> acc
                    Just year -> M.insertWith (++) year [(idx, bookmark)] acc
            )
            M.empty
            indexed

    orderedYears :: [Int]
    orderedYears = reverse (snd (foldl' addYear (IS.empty, []) (mapMaybe (filedYear . snd) indexed)))

    addYear :: (IntSet, [Int]) -> Int -> (IntSet, [Int])
    addYear (seen, acc) year
        | IS.member year seen = (seen, acc)
        | otherwise = (IS.insert year seen, year : acc)

    block :: Int -> [LedgerEntry]
    block year =
        LedgerYear year (M.lookup year here)
            : map (\(idx, bookmark) -> LedgerRow idx bookmark) (M.findWithDefault [] year byYear)
