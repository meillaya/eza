{-# LANGUAGE OverloadedStrings #-}
module Eza.Graph
  ( graphNeighborhood
  ) where

import Control.Monad (forM)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import Database.SQLite.Simple
import Database.SQLite.Simple (Query (..))

import Eza.Types

-- | BFS over the links table, both directions, bounded to 500 nodes.
graphNeighborhood :: Connection -> Int -> Int -> IO (Maybe GraphData)
graphNeighborhood conn seed depth = do
  exists <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only seed) :: IO [Only Int]
  if null exists
    then pure Nothing
    else do
      let hops = max 1 (min 2 depth)
      (nodes0, edges) <- go hops [seed] (Set.singleton seed) [seed] []
      let nodeIds = take 500 nodes0
          kept = Set.fromList nodeIds
          edges' = [(s, t) | (s, t) <- edges, Set.member s kept, Set.member t kept]
      details <- nodeDetails conn nodeIds
      let nodes = [fromMaybe (GraphNode i "" "" [] False 0) (Map.lookup i details) | i <- nodeIds]
      pure (Just (GraphData nodes [GraphEdge s t | (s, t) <- sortOn id edges']))
  where
    go 0 _ _ order edges = pure (order, edges)
    go n frontier discovered order edges = do
      let marks = commaMarks (length frontier)
      rows <-
        query
          conn
          ( Query
              ( "SELECT source_id,target_id FROM links WHERE (source_id IN (" <> marks <> ") OR target_id IN (" <> marks <> ")) AND source_id IS NOT NULL AND target_id IS NOT NULL"
              )
          )
          (frontier <> frontier) :: IO [(Int, Int)]
      let pairs = [(s, t) | (s, t) <- rows]
          next =
            [ nid
            | (s, t) <- pairs
            , nid <- [s, t]
            , not (Set.member nid discovered)
            ]
          discovered' = foldr Set.insert discovered next
          order' = order <> next
          edges' = edges <> [(s, t) | (s, t) <- pairs, Set.member s (Set.fromList order'), Set.member t (Set.fromList order')]
      go (n - 1) next discovered' order' edges'

    commaMarks n = intercalateComma (replicate n "?")

intercalateComma :: [Text] -> Text
intercalateComma [] = ""
intercalateComma [x] = x
intercalateComma (x : xs) = x <> "," <> intercalateComma xs

nodeDetails :: Connection -> [Int] -> IO (Map.Map Int GraphNode)
nodeDetails _ [] = pure Map.empty
nodeDetails conn ids = do
  let marks = intercalateComma (replicate (length ids) "?")
  rows <- query conn (Query ("SELECT id,title,url,is_read FROM bookmarks WHERE id IN (" <> marks <> ")")) ids :: IO [(Int, Text, Text, Int)]
  tagRows <- query conn (Query ("SELECT bt.bookmark_id,t.name FROM bookmark_tags bt JOIN tags t ON t.id=bt.tag_id WHERE bt.bookmark_id IN (" <> marks <> ") ORDER BY bt.bookmark_id,t.name")) ids :: IO [(Int, Text)]
  indeg <- query conn (Query ("SELECT target_id,COUNT(*) FROM links WHERE target_id IN (" <> marks <> ") GROUP BY target_id")) ids :: IO [(Int, Int)]
  let tagsBy = Map.fromListWith (flip (<>)) [(i, [t]) | (i, t) <- tagRows]
      indegBy = Map.fromList indeg
  pure
    ( Map.fromList
        [ (i, GraphNode i title url (Map.findWithDefault [] i tagsBy) (readFlag == 1) (Map.findWithDefault 0 i indegBy))
        | (i, title, url, readFlag) <- rows
        ]
    )
