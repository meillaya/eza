{-# LANGUAGE OverloadedStrings #-}
module Eza.Graph
  ( graphNeighborhood
  ) where

import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple

import Eza.Types

-- | A tag-co-occurrence neighbourhood: records that share tags with the seed,
-- then records that share tags with those neighbours. Edges carry the number
-- of shared tags, which is what the catalogue draws as line weight.
graphNeighborhood :: Connection -> Int -> Int -> IO (Maybe GraphData)
graphNeighborhood conn seed depth = do
  exists <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only seed) :: IO [Only Int]
  if null exists
    then pure Nothing
    else do
      seedTags <- tagsFor conn [seed] >>= pure . Map.findWithDefault [] seed
      if null seedTags
        then do
          details <- nodeDetails conn [seed] Map.empty
          pure (Just (GraphData [fromMaybe emptyNode (Map.lookup seed details)] []))
        else do
          let hops = max 1 (min 2 depth)
          level1 <- neighboursByTags conn seedTags [seed] 200
          level2 <-
            if hops < 2
              then pure []
              else do
                level1Tags <- tagsFor conn level1
                neighboursByTags conn (concat (Map.elems level1Tags)) (seed : level1) 300
          let selected = take 500 (seed : level1 <> level2)
          tagsBy <- tagsFor conn selected
          let degreeBy = Map.fromList [(i, sharedWith seedTags (Map.findWithDefault [] i tagsBy)) | i <- selected]
              edges = graphEdges selected tagsBy
          details <- nodeDetails conn selected degreeBy
          let nodes = [fromMaybe emptyNode (Map.lookup i details) | i <- selected]
          pure (Just (GraphData nodes (take 2000 (sortOn (negate . geWeight) edges))))
  where
    emptyNode = GraphNode 0 "" "" [] False 0
    sharedWith tags mine = length (filter (`elem` mine) tags)

-- | Records sharing at least one tag, ranked by the number of shared tags.
neighboursByTags :: Connection -> [Text] -> [Int] -> Int -> IO [Int]
neighboursByTags _ [] _ _ = pure []
neighboursByTags conn tags exclude limit = do
  let tagMarks = commaMarks (length tags)
      tagParams = tags
      excludeClause = case exclude of
        [] -> ""
        _ -> " AND bt.bookmark_id NOT IN (" <> T.intercalate "," (map (T.pack . show) exclude) <> ")"
      sql =
        "SELECT bt.bookmark_id, COUNT(*) FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id WHERE t.name IN ("
          <> tagMarks
          <> ") AND bt.bookmark_id <> 0"
          <> excludeClause
          <> " GROUP BY bt.bookmark_id ORDER BY COUNT(*) DESC, bt.bookmark_id LIMIT "
          <> T.pack (show (max 1 limit))
  rows <- query conn (Query sql) tagParams :: IO [(Int, Int)]
  pure (map fst rows)

tagsFor :: Connection -> [Int] -> IO (Map.Map Int [Text])
tagsFor _ [] = pure Map.empty
tagsFor conn ids = do
  let marks = commaMarks (length ids)
  rows <-
    query
      conn
      (Query ("SELECT bt.bookmark_id,t.name FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id WHERE bt.bookmark_id IN (" <> marks <> ") ORDER BY bt.bookmark_id,t.name"))
      ids :: IO [(Int, Text)]
  pure (Map.fromListWith (flip (<>)) [(i, [t]) | (i, t) <- rows])

{- | Tag co-occurrence edges between the selected records.

The previous implementation compared every selected record with every other
one and intersected their tag lists. This groups the records by tag first: one
map walks the tag membership, counts how many tags each pair shares, and then
emits the edge list in the same order the old nested loop produced it (by the
position of the numerically smaller id in the id list, then the position of the
larger id), so the weight sort the caller applies sees an identical edge list.
-}
graphEdges :: [Int] -> Map.Map Int [Text] -> [GraphEdge]
graphEdges ids tagsBy =
  [ GraphEdge a b weight
  | ((a, b), weight) <- orderedCounts
  , a < b
  ]
  where
    posById :: Map.Map Int Int
    posById = Map.fromList (zip ids [0 :: Int ..])

    -- Each tag maps to the ids carrying it, in id-list order.
    tagMembers :: Map.Map Text [Int]
    tagMembers =
      Map.fromListWith (flip (<>))
        [ (tag, [bid])
        | bid <- ids
        , tag <- Map.findWithDefault [] bid tagsBy
        ]

    pairCounts :: Map.Map (Int, Int) Int
    pairCounts =
      Map.fromListWith (+)
        [ (orderedPair x y, 1)
        | members <- Map.elems tagMembers
        , (x, y) <- unorderedPairs members
        ]

    orderedCounts :: [((Int, Int), Int)]
    orderedCounts =
      sortOn
        (\((a, b), _) -> (position a, position b))
        (Map.toList pairCounts)

    position :: Int -> Int
    position bid = Map.findWithDefault 0 bid posById

    orderedPair :: Int -> Int -> (Int, Int)
    orderedPair x y
      | x <= y = (x, y)
      | otherwise = (y, x)

    unorderedPairs :: [a] -> [(a, a)]
    unorderedPairs [] = []
    unorderedPairs (x : xs) = [(x, y) | y <- xs] <> unorderedPairs xs

nodeDetails :: Connection -> [Int] -> Map.Map Int Int -> IO (Map.Map Int GraphNode)
nodeDetails _ [] _ = pure Map.empty
nodeDetails conn ids degreeBy = do
  let marks = commaMarks (length ids)
  rows <- query conn (Query ("SELECT id,title,url,is_read FROM bookmarks WHERE id IN (" <> marks <> ")")) ids :: IO [(Int, Text, Text, Int)]
  tagRows <- query conn (Query ("SELECT bt.bookmark_id,t.name FROM bookmark_tags bt JOIN tags t ON t.id=bt.tag_id WHERE bt.bookmark_id IN (" <> marks <> ") ORDER BY bt.bookmark_id,t.name")) ids :: IO [(Int, Text)]
  let tagsBy = Map.fromListWith (flip (<>)) [(i, [t]) | (i, t) <- tagRows]
  pure
    ( Map.fromList
        [ ( i
          , GraphNode i title url (Map.findWithDefault [] i tagsBy) (readFlag == 1) (Map.findWithDefault 0 i degreeBy)
          )
        | (i, title, url, readFlag) <- rows
        ]
    )

commaMarks :: Int -> Text
commaMarks n = intercalateComma (replicate n "?")

intercalateComma :: [Text] -> Text
intercalateComma [] = ""
intercalateComma [x] = x
intercalateComma (x : xs) = x <> "," <> intercalateComma xs
