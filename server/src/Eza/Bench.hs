{-# LANGUAGE OverloadedStrings #-}

{- | Read-only query benchmarks against a live library database.

Every case is a pure read: the benchmark never writes and never migrates.
Each invocation prints one parseable line per case with the average and the
p50/p95/p99 latencies in milliseconds plus the result size, so a run can be
diffed between commits. Cases measure the queries behind one boot request,
the two ledger page shapes the UI requests most, the whole-library graph, the
deterministic client layout for that graph, and the duplicate scan.
-}
module Eza.Bench (
    runBench,
) where

import Control.Monad (forM_, replicateM)
import Data.Aeson (ToJSON, encode)
import qualified Data.ByteString.Lazy as BL
import Data.List (sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple (Connection, query_)

import Eza.Bookmarks
import Eza.Dedup (dedupCandidates, defaultDedupQuery)
import Eza.Graph (globalGraph, graphLayoutPayload)
import Eza.GraphLayout (LayoutPreset (..))
import Eza.Types (DedupGroup (..), DedupReport (..), GraphData (..), SearchPage (..))
import Eza.Url (dedupeKey)

{- | The size of one case result: rendered rows and the payload bytes a JSON
response would carry. Both are informational and may be 0 where a count is
not meaningful.
-}
data CaseResult = CaseResult
    { crRows :: Int
    , crBytes :: Int
    }

type BenchCase = (String, IO CaseResult)

runBench :: Connection -> Int -> IO ()
runBench conn iterations = do
    let n = max 1 iterations
        cases = benchCases conn
    putStrLn ("iterations: " <> show n)
    forM_ cases $ \(name, runCase) -> do
        samples <- replicateM n $ do
            start <- getPOSIXTime
            result <- runCase
            end <- getPOSIXTime
            pure (realToFrac ((end - start) * 1000) :: Double, result)
        let times = sort (map fst samples)
            result = case reverse samples of
                ((_, lastResult) : _) -> lastResult
                [] -> CaseResult 0 0
            average = sum times / fromIntegral (length times)
        putStrLn
            ( name
                <> ": total_ms="
                <> show (round2 (sum times))
                <> " avg_ms="
                <> show (round2 average)
                <> " p50_ms="
                <> show (round2 (percentile 0.50 times))
                <> " p95_ms="
                <> show (round2 (percentile 0.95 times))
                <> " p99_ms="
                <> show (round2 (percentile 0.99 times))
                <> " rows="
                <> show (crRows result)
                <> " bytes="
                <> show (crBytes result)
            )

benchCases :: Connection -> [BenchCase]
benchCases conn =
    [ ("all", listCase conn defaultListQuery)
    , ("fts-rust", listCase conn defaultListQuery{lqQ = "rust"})
    , ("fts-github", listCase conn defaultListQuery{lqQ = "github"})
    , ("tag-imported", listCase conn defaultListQuery{lqTags = ["imported"]})
    , ("tag-imported-books", listCase conn defaultListQuery{lqTags = ["imported", "books"]})
    , ("all-page2", listCase conn defaultListQuery{lqOffset = 60})
    , ("boot-components", bootComponents conn)
    , ("library-stats", statsCase conn)
    , ("graph", graphCase conn)
    , ("layout", layoutCase conn)
    , ("all-tags", tagsCase conn)
    , ("autocomplete", autocompleteCase conn)
    , ("sort-opened", listCase conn defaultListQuery{lqSort = "opened"})
    , ("unread-filter", listCase conn defaultListQuery{lqIsRead = Just False})
    , ("dedup-grouping", dedupGroupingCase conn)
    , ("dedup-candidates", dedupCandidatesCase conn)
    ]

-- | One ledger page: the list query plus the tag query the response needs.
listCase :: Connection -> ListQuery -> IO CaseResult
listCase conn listQuery = do
    page <- listBookmarks conn listQuery
    pure
        CaseResult
            { crRows = length (spItems page)
            , crBytes = payloadBytes page
            }

-- | The read-only part of one boot request.
bootComponents :: Connection -> IO CaseResult
bootComponents conn = do
    page <- listBookmarks conn defaultListQuery
    tags <- allTags conn
    stats <- libraryStats conn
    pure
        CaseResult
            { crRows = length (spItems page) + length tags
            , crBytes = payloadBytes page + payloadBytes tags + payloadBytes stats
            }

statsCase :: Connection -> IO CaseResult
statsCase conn = do
    stats <- libraryStats conn
    pure (CaseResult 0 (payloadBytes stats))

-- | The whole-library graph request: every record and every tag.
graphCase :: Connection -> IO CaseResult
graphCase conn = do
    graph <- globalGraph conn
    pure
        CaseResult
            { crRows = length (gdRecords graph) + length (gdTags graph)
            , crBytes = payloadBytes graph
            }

tagsCase :: Connection -> IO CaseResult
tagsCase conn = do
    tags <- allTags conn
    pure (CaseResult (length tags) (payloadBytes tags))

{- | The deterministic layout the layout endpoint serves: build the standard
preset from the graph payload, quantize it and encode the JSON response. This
is pure CPU work on the graph payload, so the case measures the layout endpoint
on a cache miss rather than a database read.
-}
layoutCase :: Connection -> IO CaseResult
layoutCase conn = do
    graph <- globalGraph conn
    let payload = graphLayoutPayload Standard graph
    pure
        CaseResult
            { crRows = length (gdRecords graph) + length (gdTags graph)
            , crBytes = payloadBytes payload
            }

autocompleteCase :: Connection -> IO CaseResult
autocompleteCase conn = do
    items <- autocomplete conn "rust" 10
    pure (CaseResult (length items) (payloadBytes items))

{- | The duplicate scan: read every id/url/title/domain row and group it by the
shared canonical URL key, exactly as the duplicates view does for URL groups
(domain only scopes the advisory title matches, so it is not part of the URL
key). This reimplements the grouping locally so the case still measures the raw
scan and key work.
-}
dedupGroupingCase :: Connection -> IO CaseResult
dedupGroupingCase conn = do
    rows <-
        query_
            conn
            "SELECT id,url,title,domain FROM bookmarks" ::
            IO [(Int, Text, Text, Text)]
    let groups =
            Map.fromListWith
                (<>)
                [ (dedupeKey url, [bid])
                | (bid, url, _, _) <- rows
                ]
        duplicateGroups = [members | (_, members) <- Map.toList groups, length members > 1]
    pure
        CaseResult
            { crRows = sum (map length duplicateGroups)
            , crBytes = sum [T.length url + T.length title + T.length domain | (_, url, title, domain) <- rows]
            }

-- | One paginated duplicates request with the default page sizes.
dedupCandidatesCase :: Connection -> IO CaseResult
dedupCandidatesCase conn = do
    report <- dedupCandidates conn defaultDedupQuery
    pure
        CaseResult
            { crRows = sum (map (length . dgItems) (drUrlGroups report <> drTitleGroups report))
            , crBytes = payloadBytes report
            }

payloadBytes :: (ToJSON a) => a -> Int
payloadBytes value = fromIntegral (BL.length (encode value))

percentile :: Double -> [Double] -> Double
percentile p sorted = case sorted of
    [] -> 0
    _ -> fromMaybe 0 (nthAt rank sorted)
  where
    rank = max 0 (min (length sorted - 1) (ceiling (p * fromIntegral (length sorted)) - 1))
    nthAt 0 (x : _) = Just x
    nthAt k (_ : xs) = nthAt (k - 1) xs
    nthAt _ [] = Nothing

round2 :: Double -> Double
round2 x = fromIntegral (round (x * 100) :: Int) / 100
