{-# LANGUAGE OverloadedStrings #-}

{- | The whole-library graph payload plus the server-computed layout.

Five read-only statements cover the response: one aggregate revision
fingerprint, the tags with their record counts, every record, the
bookmark/tag membership, and the resolved wikilinks. Records point at tags by
index into 'gdTags', so a tag name is sent once instead of once per member
record. Links whose source or target is not a live record are dropped, so the
client can trust every endpoint.

The same payload feeds 'graphLayoutPayload', which runs the deterministic
"Eza.GraphLayout" builder and ships quantized node positions for one preset.
The positions are cached per database and keyed by revision and preset.
-}
module Eza.Graph
  ( globalGraph
  , graphRevision
  , GraphLayoutPayload (..)
  , graphLayoutPayload
  , LayoutCache (..)
  , emptyLayoutCache
  , lookupCachedLayout
  , storeCachedLayout
  , layoutPresetText
  , layoutPresetFromText
  ) where

import Data.Aeson (ToJSON (..), object, (.=))
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IntSet
import Data.List (sort)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple

import Eza.GraphLayout
import Eza.Types

{- | A cheap fingerprint of everything the graph payload shows. Two equal
revisions mean the same records, tags, memberships and resolved links, not
necessarily byte-identical titles, so clients only compare it.
-}
graphRevision :: Connection -> IO Text
graphRevision conn = do
  rows <-
    query_
      conn
      "SELECT (SELECT COUNT(*) FROM bookmarks), \
      \(SELECT COALESCE(MAX(updated_at), 0) FROM bookmarks), \
      \(SELECT COUNT(*) FROM tags), \
      \(SELECT COUNT(*) FROM bookmark_tags), \
      \(SELECT COUNT(*) FROM links WHERE source_id IS NOT NULL AND target_id IS NOT NULL)" ::
      IO [(Int, Int, Int, Int, Int)]
  pure $ case rows of
    [(records, updated, tags, memberships, links)] ->
      T.intercalate
        ":"
        (map (T.pack . show) [records, updated, tags, memberships, links])
    _ -> "0:0:0:0:0"

{- | The whole library as one graph: all tags with their record counts (busiest
first, then by name), all records in id order with their tags as indexes into
the tag list, the distinct resolved wikilinks between records, and the revision
fingerprint.
-}
globalGraph :: Connection -> IO GraphData
globalGraph conn = do
  revision <- graphRevision conn
  tagRows <-
    query_
      conn
      "SELECT t.id, t.name, COUNT(bt.bookmark_id) \
      \FROM tags t LEFT JOIN bookmark_tags bt ON bt.tag_id = t.id \
      \GROUP BY t.id \
      \ORDER BY COUNT(bt.bookmark_id) DESC, t.name ASC" ::
      IO [(Int, Text, Int)]
  recordRows <-
    query_
      conn
      "SELECT id, title, domain, created_at, is_read, is_dead FROM bookmarks ORDER BY id" ::
      IO [(Int, Text, Text, Int, Int, Int)]
  memberRows <-
    query_
      conn
      "SELECT bookmark_id, tag_id FROM bookmark_tags" ::
      IO [(Int, Int)]
  linkRows <-
    query_
      conn
      "SELECT DISTINCT source_id, target_id FROM links \
      \WHERE source_id IS NOT NULL AND target_id IS NOT NULL \
      \ORDER BY source_id, target_id" ::
      IO [(Int, Int)]
  let tagIndexById :: Map.Map Int Int
      tagIndexById = Map.fromList [(tagId, index) | (index, (tagId, _, _)) <- zip [0 ..] tagRows]
      indexLists :: Map.Map Int [Int]
      indexLists =
        Map.map
          sort
          ( Map.fromListWith
              (<>)
              [ (bookmarkId, [index])
              | (bookmarkId, tagId) <- memberRows
              , Just index <- [Map.lookup tagId tagIndexById]
              ]
          )
      recordIds = IntSet.fromList [bid | (bid, _, _, _, _, _) <- recordRows]
      tags = [GraphTag name count | (_, name, count) <- tagRows]
      records =
        [ GraphRecord
            bid
            (if T.null title then domain else title)
            domain
            createdAt
            (readFlag /= 0)
            (deadFlag /= 0)
            (Map.findWithDefault [] bid indexLists)
        | (bid, title, domain, createdAt, readFlag, deadFlag) <- recordRows
        ]
      links =
        [ GraphLink source target
        | (source, target) <- linkRows
        , source `IntSet.member` recordIds
        , target `IntSet.member` recordIds
        ]
  pure (GraphData tags records links revision)

-- ------------------------------------------------------------------ layout ---

{- | The layout endpoint payload: one preset's node positions, quantized to
1/100 world unit, plus the revision they were built from.
-}
data GraphLayoutPayload = GraphLayoutPayload
  { glpSchema :: Int
  , glpRevision :: Text
  , glpPreset :: LayoutPreset
  , glpTags :: [(Double, Double)]
  , glpRecords :: [(Double, Double)]
  , glpBounds :: (Double, Double, Double, Double)
  }
  deriving (Eq, Show)

instance ToJSON GraphLayoutPayload where
  toJSON payload =
    object
      [ "schema" .= glpSchema payload
      , "revision" .= glpRevision payload
      , "preset" .= layoutPresetText (glpPreset payload)
      , "tags" .= glpTags payload
      , "records" .= glpRecords payload
      , "bounds" .= [minX, minY, maxX, maxY]
      ]
    where
      (minX, minY, maxX, maxY) = glpBounds payload

-- | Build the layout payload for one preset from an already-read graph.
graphLayoutPayload :: LayoutPreset -> GraphData -> GraphLayoutPayload
graphLayoutPayload preset graph =
  GraphLayoutPayload
    { glpSchema = 1
    , glpRevision = gdRevision graph
    , glpPreset = preset
    , glpTags =
        [ (quantize x, quantize y)
        | (_, (x, y)) <- IM.toList (lpTagPositions positions)
        ]
    , glpRecords =
        [ (quantize x, quantize y)
        | (_, (x, y)) <- IM.toList (lpRecordPositions positions)
        ]
    , glpBounds = (quantize minX, quantize minY, quantize maxX, quantize maxY)
    }
  where
    positions = layoutPositions (buildLayoutWith (presetOptions preset) 0 graph)
    ((minX, minY), (maxX, maxY)) = lpBounds positions

-- | Round to 1/100 world unit. The client renders at integer screen pixels,
-- so hundredths are well below anything visible and keep the payload small.
quantize :: Double -> Double
quantize value = fromIntegral (round (value * 100) :: Int) / 100

layoutPresetText :: LayoutPreset -> Text
layoutPresetText preset = case preset of
  Compact -> "compact"
  Standard -> "standard"
  Airy -> "airy"

-- | Parse the @preset@ query parameter. Unknown values are a 400, not a
-- silent fallback.
layoutPresetFromText :: Text -> Maybe LayoutPreset
layoutPresetFromText raw = case T.toLower (T.strip raw) of
  "compact" -> Just Compact
  "standard" -> Just Standard
  "airy" -> Just Airy
  _ -> Nothing

{- | One database's layout cache. A change of revision throws the old preset
entries away; the list at most holds the three presets of one revision.
-}
data LayoutCache = LayoutCache
  { lcRevision :: Text
  , lcPresets :: [(LayoutPreset, GraphLayoutPayload)]
  }
  deriving (Eq, Show)

emptyLayoutCache :: LayoutCache
emptyLayoutCache = LayoutCache "" []

lookupCachedLayout :: Text -> LayoutPreset -> LayoutCache -> Maybe GraphLayoutPayload
lookupCachedLayout revision preset cache
  | revision == lcRevision cache = lookup preset (lcPresets cache)
  | otherwise = Nothing

storeCachedLayout :: Text -> LayoutPreset -> GraphLayoutPayload -> LayoutCache -> LayoutCache
storeCachedLayout revision preset payload cache
  | revision == lcRevision cache =
      LayoutCache revision (insertPreset preset payload (lcPresets cache))
  | otherwise = LayoutCache revision [(preset, payload)]

insertPreset :: LayoutPreset -> GraphLayoutPayload -> [(LayoutPreset, GraphLayoutPayload)] -> [(LayoutPreset, GraphLayoutPayload)]
insertPreset preset payload entries =
  (preset, payload) : filter ((/= preset) . fst) entries
