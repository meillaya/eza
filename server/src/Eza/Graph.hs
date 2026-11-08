{-# LANGUAGE OverloadedStrings #-}
module Eza.Graph
  ( graphNeighborhood
  ) where

import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import Database.SQLite.Simple (Query (..))

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

graphEdges :: [Int] -> Map.Map Int [Text] -> [GraphEdge]
graphEdges ids tagsBy =
  [ GraphEdge a b (length (filter (`elem` tagsA) tagsB))
  | (a, tagsA) <- pairs
  , (b, tagsB) <- pairs
  , a < b
  , not (null (filter (`elem` tagsA) tagsB))
  ]
  where
    pairs = [(i, Map.findWithDefault [] i tagsBy) | i <- ids]

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
