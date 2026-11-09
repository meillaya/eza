{-# LANGUAGE RecordWildCards #-}

{- | The deterministic whole-library graph layout.

This module is pure and builds for native and WASM. It holds the node-key
scheme, the layout record the client paints from, the deterministic builder,
and hydration from server-supplied positions.

Node identity is one 'Int'. Record keys are bookmark ids (positive); tag keys
are @negate (index + 1)@ so both fit in one 'Data.IntMap.Strict.IntMap'.

Two relationship types exist: a resolved wikilink joins two records, and tag
membership joins a record to a tag. Tag co-occurrence only decides where tag
nodes sit; it is never drawn as an edge.

'buildLayout' with 'defaultLayoutOptions' (the 'Standard' preset) reproduces
the client's historical layout exactly. 'Compact' and 'Airy' only scale the tag
force spread and the record anchor radius, so every preset is deterministic.
-}
module Eza.GraphLayout (
    -- * Node keys
    tagKeyOf,
    isTagKey,
    tagIndexOf,
    recordKeyOf,

    -- * Options and presets
    LayoutOptions (..),
    LayoutPreset (..),
    defaultLayoutOptions,
    presetOptions,

    -- * Server positions
    LayoutPositions (..),
    layoutPositions,

    -- * Layout
    GraphLayout (..),
    buildLayout,
    buildLayoutWith,
    hydrateLayout,
    layoutWorldSpan,
) where

import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)

import Eza.Types (GraphData (..), GraphLink (..), GraphRecord (..), GraphTag (..))

-- ------------------------------------------------------------------ keys ---

-- | The node key for a tag index into 'gdTags'.
tagKeyOf :: Int -> Int
tagKeyOf index = negate (index + 1)

isTagKey :: Int -> Bool
isTagKey key = key < 0

tagIndexOf :: Int -> Int
tagIndexOf key = negate key - 1

{- | The node key for a record id. Record ids are always positive, so the
identity function is the key; the name documents the intent.
-}
recordKeyOf :: Int -> Int
recordKeyOf = id

-- --------------------------------------------------------------- options ---

{- | Deterministic layout knobs. 'Standard' uses the historical constants:
a tag force spread of 1 and a record anchor radius of 1.
-}
data LayoutOptions = LayoutOptions
    { loTagSpread :: Double
    {- ^ Multiplier on the tag phyllotaxis radius, attraction target and
    repulsion range.
    -}
    , loAnchorRadius :: Double
    {- ^ Multiplier on the per-tag-combination sunflower radius and the
    untagged record grid.
    -}
    , loRelaxIterations :: Int
    -- ^ Grid relaxation passes. The current layout uses three.
    }
    deriving (Eq, Show)

{- | Named option sets. 'Standard' is the current layout; 'Compact' and 'Airy'
scale it down and up. Ordering by world span is compact < standard < airy.
-}
data LayoutPreset = Compact | Standard | Airy
    deriving (Eq, Show)

defaultLayoutOptions :: LayoutOptions
defaultLayoutOptions = LayoutOptions 1 1 3

presetOptions :: LayoutPreset -> LayoutOptions
presetOptions = \case
    Compact -> LayoutOptions 0.82 0.8 3
    Standard -> defaultLayoutOptions
    Airy -> LayoutOptions 1.3 1.35 3

-- ------------------------------------------------------- server positions ---

{- | Layout positions as the server would supply them: tag positions keyed by
index into 'gdTags', record positions keyed by bookmark id, and the world
bounds of the finished layout.
-}
data LayoutPositions = LayoutPositions
    { lpTagPositions :: IM.IntMap (Double, Double)
    , lpRecordPositions :: IM.IntMap (Double, Double)
    , lpBounds :: ((Double, Double), (Double, Double))
    }
    deriving (Eq, Show)

{- | Project a built layout back to the position payload, for hydration tests
and for shipping positions to another client.
-}
layoutPositions :: GraphLayout -> LayoutPositions
layoutPositions layout =
    LayoutPositions
        { lpTagPositions =
            IM.fromList
                [ (tagIndexOf key, point)
                | (key, point) <- IM.toList (glPos layout)
                , isTagKey key
                ]
        , lpRecordPositions =
            IM.fromList
                [ (recordKeyOf key, point)
                | (key, point) <- IM.toList (glPos layout)
                , not (isTagKey key)
                ]
        , lpBounds = (glMin layout, glMax layout)
        }

-- ---------------------------------------------------------------- layout ---

{- | Everything the painter and the panels need. 'GraphLayout' is built once per
server response and lives at the end of the client model record.
-}
data GraphLayout = GraphLayout
    { glGen :: Int
    -- ^ Data generation, part of the client bitmap cache key.
    , glPos :: IM.IntMap (Double, Double)
    -- ^ World position of every node, keyed by node key.
    , glRadii :: IM.IntMap Double
    -- ^ World radius of every node.
    , glAdj :: IM.IntMap [Int]
    -- ^ Node key to neighbouring node keys, both edge families.
    , glLinks :: [(Int, Int)]
    -- ^ Record to record wikilinks, deduplicated and sorted.
    , glMembers :: [(Int, Int)]
    -- ^ Record key to tag key membership, sorted.
    , glMemberSegments :: [(Double, Double, Double, Double)]
    -- ^ Membership endpoints in world space.
    , glLinkSegments :: [(Double, Double, Double, Double)]
    -- ^ Wikilink endpoints in world space.
    , glRecordPoints :: [(Double, Double, Double)]
    -- ^ Record x, y and radius in world space.
    , glTagPoints :: [(Double, Double, Double)]
    -- ^ Tag x, y and radius in world space.
    , glTags :: IM.IntMap (Text, Int)
    -- ^ Tag key to (name, record count), read from 'gdTags'.
    , glRecords :: IM.IntMap GraphRecord
    -- ^ Record key to the server record.
    , glRecordTags :: IM.IntMap [Int]
    -- ^ Record key to its tag keys, in server order.
    , glTagOrder :: [Int]
    -- ^ Tags by label priority (count desc, tag order).
    , glRecordOrder :: [Int]
    -- ^ Records by label priority (degree desc, then newest).
    , glMin :: (Double, Double)
    , glMax :: (Double, Double)
    , glTagCount :: Int
    , glLinkCount :: Int
    , glMemberCount :: Int
    , glRecordCount :: Int
    }
    deriving (Eq, Show)

goldenAngle :: Double
goldenAngle = 2.399963229728653

-- | Build the standard layout for one graph payload.
buildLayout :: Int -> GraphData -> GraphLayout
buildLayout = buildLayoutWith defaultLayoutOptions

-- | Build a layout with explicit options.
buildLayoutWith :: LayoutOptions -> Int -> GraphData -> GraphLayout
buildLayoutWith options generation graph =
    assembleLayout generation graph positions Nothing
  where
    tags = gdTags graph
    records = gdRecords graph
    tagData :: IM.IntMap (Text, Int)
    tagData =
        IM.fromList
            [ (tagKeyOf index, (gtName tag, gtCount tag))
            | (index, tag) <- zip [0 :: Int ..] tags
            ]
    coEdges =
        M.toList
            ( M.fromListWith
                (+)
                [ ((left, right), 1)
                | record <- records
                , let tagIndexes = take 8 (grTags record)
                , left <- tagIndexes
                , right <- tagIndexes
                , left < right
                ]
            )
    tagPositions = forceTags options (length tags) coEdges
    recordMap = IM.fromList [(recordKeyOf (grId record), record) | record <- records]
    recordTags =
        IM.fromList
            [ (recordKeyOf (grId record), map tagKeyOf (grTags record))
            | record <- records
            ]
    validTagKeys = IM.keysSet tagData
    cleanTags = IM.map (filter (`IS.member` validTagKeys)) recordTags
    wikiEdges = cleanWikiEdges recordMap (gdLinks graph)
    (tagPos, recordPos) = anchorRecords options tagPositions cleanTags recordMap wikiEdges
    positions = IM.union tagPos recordPos

{- | Hydrate a layout from server-supplied positions and bounds. The graph data
still supplies titles, tags and the two edge families; only where the nodes sit
is taken from the server.
-}
hydrateLayout :: GraphData -> LayoutPositions -> GraphLayout
hydrateLayout graph supplied =
    assembleLayout 0 graph positions (Just (lpBounds supplied))
  where
    tagPositions =
        IM.fromList
            [ (tagKeyOf index, point)
            | (index, point) <- IM.toList (lpTagPositions supplied)
            ]
    recordPositions =
        IM.fromList
            [ (recordKeyOf recordId, point)
            | (recordId, point) <- IM.toList (lpRecordPositions supplied)
            ]
    positions = IM.union tagPositions recordPositions

-- | The world span the fit scale divides by.
layoutWorldSpan :: GraphLayout -> Double
layoutWorldSpan layout =
    max 1 (max (maxX - minX) (maxY - minY))
  where
    (minX, minY) = glMin layout
    (maxX, maxY) = glMax layout

{- | Build every derived field (radii, adjacency, segments, points, label
orders and counts) from graph data plus node positions. The bounds come from
the caller when hydrating and are computed from positions and radii otherwise.
-}
assembleLayout ::
    Int ->
    GraphData ->
    IM.IntMap (Double, Double) ->
    Maybe ((Double, Double), (Double, Double)) ->
    GraphLayout
assembleLayout generation graph positions boundsOverride = GraphLayout{..}
  where
    tags = gdTags graph
    records = gdRecords graph
    tagData :: IM.IntMap (Text, Int)
    tagData =
        IM.fromList
            [ (tagKeyOf index, (gtName tag, gtCount tag))
            | (index, tag) <- zip [0 :: Int ..] tags
            ]
    recordMap = IM.fromList [(recordKeyOf (grId record), record) | record <- records]
    recordTags =
        IM.fromList
            [ (recordKeyOf (grId record), map tagKeyOf (grTags record))
            | record <- records
            ]
    validTagKeys = IM.keysSet tagData
    cleanTags = IM.map (filter (`IS.member` validTagKeys)) recordTags
    wikiEdges = cleanWikiEdges recordMap (gdLinks graph)
    -- Node size follows the computed world span: at the fit scale a tag reads
    -- about 5 to 12 screen pixels and a record about 1.5, which keeps 8,800
    -- records as points rather than a blob. Sizing by sqrt(count) would make
    -- the busiest tag a plate-sized disc.
    (spanMinX, spanMinY, spanMaxX, spanMaxY) = positionBounds positions
    worldSpan = max 1 (max (spanMaxX - spanMinX) (spanMaxY - spanMinY))
    maxTagCount = maximum (0 : [count | (_, count) <- IM.elems tagData])
    tagRatio count =
        logBase
            (1 + fromIntegral (max 1 maxTagCount))
            (1 + fromIntegral (max 0 count))
    tagRadii =
        IM.fromList
            [ (key, worldSpan * (0.010 + 0.020 * tagRatio count))
            | (key, (_, count)) <- IM.toList tagData
            ]
    membership =
        M.keys
            ( M.fromList
                [ ((recordKey, tagKey), ())
                | (recordKey, tagKeys) <- IM.toList cleanTags
                , tagKey <- tagKeys
                ]
            )
    adjacency =
        IM.fromListWith
            (++)
            ( concat
                [ [(a, [b]), (b, [a])]
                | (a, b) <- wikiEdges
                ]
                ++ concat
                    [ [(recordKey, [tagKey]), (tagKey, [recordKey])]
                    | (recordKey, tagKey) <- membership
                    ]
            )
    degree key = maybe 0 length (IM.lookup key adjacency)
    recordRadiusFactor = if length records < 200 then 0.006 else 0.0036
    recordRadii =
        IM.fromList
            [ (key, worldSpan * recordRadiusFactor)
            | key <- IM.keys recordMap
            ]
    radii = IM.unionWith const tagRadii recordRadii
    labelTags =
        map
            fst
            ( sortOn
                (\(key, (_, count)) -> (negate count, key))
                (IM.toList tagData)
            )
    labelRecords =
        map
            fst
            ( sortOn
                ( \(key, record) ->
                    (negate (degree key), negate (grCreatedAt record), key)
                )
                (IM.toList recordMap)
            )
    bounds = fromMaybe (nodeBounds positions radii) boundsOverride
    segOf (a, b) =
        case (IM.lookup a positions, IM.lookup b positions) of
            (Just (x1, y1), Just (x2, y2)) -> Just (x1, y1, x2, y2)
            _ -> Nothing
    pointsFor keys =
        [ (x, y, radius)
        | key <- keys
        , Just (x, y) <- [IM.lookup key positions]
        , Just radius <- [IM.lookup key radii]
        ]
    glMemberSegments = mapMaybe segOf membership
    glLinkSegments = mapMaybe segOf wikiEdges
    glRecordPoints = pointsFor (IM.keys recordMap)
    glTagPoints = pointsFor (IM.keys tagData)
    glTags = tagData
    glRecords = recordMap
    glRecordTags = cleanTags
    glLinks = wikiEdges
    glMembers = membership
    glAdj = adjacency
    glPos = positions
    glRadii = radii
    glTagOrder = labelTags
    glRecordOrder = labelRecords
    glMin = fst bounds
    glMax = snd bounds
    glGen = generation
    glTagCount = length tags
    glLinkCount = length wikiEdges
    glMemberCount = length membership
    glRecordCount = length records

{- | Position the tags with a deterministic force pass over co-occurrence.
Isolated tags keep their phyllotaxis seed, so the result never depends on a
random number generator.
-}
forceTags :: LayoutOptions -> Int -> [((Int, Int), Int)] -> IM.IntMap (Double, Double)
forceTags options count pairs =
    IM.fromList
        [ (tagKeyOf index, point)
        | (index, point) <- zip [0 :: Int ..] (IM.elems (settle seed))
        ]
  where
    spread = loTagSpread options
    seed =
        IM.fromList
            [ (index, phyllotaxis index)
            | index <- [0 .. count - 1]
            ]
    iterations :: Int
    iterations = 110
    settle start = foldl' (\position _ -> step position) start [1 .. iterations]
    step position =
        let attracted = foldl' attract position pairs
            repulsed = repulse attracted
         in anchor position repulsed
    anchor initial position =
        IM.intersectionWith
            (\(x, y) (x0, y0) -> (x * 0.985 + x0 * 0.015, y * 0.985 + y0 * 0.015))
            position
            initial
    attract position ((a, b), weight) =
        case (IM.lookup a position, IM.lookup b position) of
            (Just (x1, y1), Just (x2, y2)) ->
                let dx = x2 - x1
                    dy = y2 - y1
                    distance = max 0.001 (sqrt (dx * dx + dy * dy))
                    target = 55 * spread
                    pull =
                        0.03
                            * fromIntegral (min 5 weight)
                            * (distance - target)
                            / distance
                    stepX = dx / distance * pull
                    stepY = dy / distance * pull
                 in IM.insert
                        a
                        (x1 + stepX, y1 + stepY)
                        (IM.insert b (x2 - stepX, y2 - stepY) position)
            _ -> position
    repulse position =
        foldl' push position [(a, b) | a <- keys, b <- keys, a < b]
      where
        keys = IM.keys position
        limit = 120 * spread
        push current (a, b) =
            case (IM.lookup a current, IM.lookup b current) of
                (Just (x1, y1), Just (x2, y2)) ->
                    let dx = x2 - x1
                        dy = y2 - y1
                        distance = sqrt (dx * dx + dy * dy)
                     in if distance <= 0.01 || distance >= limit
                            then current
                            else
                                let push_ = 0.02 * spread * (limit - distance)
                                    stepX = dx / distance * push_
                                    stepY = dy / distance * push_
                                 in IM.insert
                                        a
                                        (x1 - stepX, y1 - stepY)
                                        (IM.insert b (x2 + stepX, y2 + stepY) current)
                _ -> current
    phyllotaxis index =
        let angle = fromIntegral index * goldenAngle
            radius = 34 * spread * sqrt (fromIntegral (index + 1))
         in (radius * cos angle, radius * sin angle)

{- | Records with the same tag combination sit on a sunflower around the mean
of their tags; untagged records fall back to a grid or, when a wikilink gives
them an anchor, the mean position of their tagged neighbours.
-}
anchorRecords ::
    LayoutOptions ->
    IM.IntMap (Double, Double) ->
    IM.IntMap [Int] ->
    IM.IntMap GraphRecord ->
    [(Int, Int)] ->
    (IM.IntMap (Double, Double), IM.IntMap (Double, Double))
anchorRecords options tagPositions recordTags recordMap wikiEdges =
    (tagPositions, relaxRecords (loRelaxIterations options) placed)
  where
    anchorRadius = loAnchorRadius options
    groups =
        [ (tagKeys, sortOn id ids)
        | (tagKeys, ids) <-
            M.toList
                ( M.fromListWith
                    (++)
                    [ (tagKeys, [recordKey])
                    | (recordKey, tagKeys) <- IM.toList recordTags
                    , not (null tagKeys)
                    ]
                )
        ]
    sunflowerPlaced = foldl' placeGroup IM.empty groups
    placeGroup acc (tagKeys, ids) =
        case meanPoint [point | tagKey <- tagKeys, Just point <- [IM.lookup tagKey tagPositions]] of
            Nothing -> acc
            Just (anchorX, anchorY) ->
                let phase = fromIntegral (abs (sum tagKeys) `mod` 360) * pi / 180
                    total = length ids
                 in foldl'
                        ( \inner (index, recordKey) ->
                            let radius =
                                    if total <= 1
                                        then 18 * anchorRadius
                                        else 26 * anchorRadius * sqrt (fromIntegral index + 0.5)
                                angle = fromIntegral index * goldenAngle + phase
                             in IM.insert
                                    recordKey
                                    (anchorX + radius * cos angle, anchorY + radius * sin angle)
                                    inner
                        )
                        acc
                        (zip [0 :: Int ..] ids)
    tagged = IM.keysSet sunflowerPlaced
    untagged =
        sortOn
            id
            [ recordKey
            | recordKey <- IM.keys recordMap
            , not (IS.member recordKey tagged)
            ]
    linkAnchors =
        IM.fromListWith
            (++)
            ( concat
                [ [(a, [b]), (b, [a])]
                | (a, b) <- wikiEdges
                ]
            )
    -- Untagged records sit in a grid below the tag cloud, close enough that a
    -- small library does not look like two unrelated plates.
    (tagMinX, tagMinY, tagMaxX, tagMaxY) = positionBounds tagPositions
    tagSpan = max (tagMaxX - tagMinX) (tagMaxY - tagMinY)
    tagCentreX = (tagMinX + tagMaxX) / 2
    gridOrigin =
        case meanPoint (IM.elems tagPositions) of
            Nothing -> (0, 0)
            Just (_, y) -> (tagCentreX, y + max (140 * anchorRadius) (tagSpan * 0.9 * anchorRadius))
    columns :: Int
    columns = max 1 (ceiling (sqrt (fromIntegral (max 1 (length untagged)) :: Double)))
    gridPlaced =
        foldl'
            ( \inner (index, recordKey) ->
                let (baseX, baseY) = gridOrigin
                    x = baseX + fromIntegral (index `mod` columns) * 74 * anchorRadius
                    y = baseY + fromIntegral (index `div` columns) * 74 * anchorRadius
                 in IM.insert recordKey (x, y) inner
            )
            sunflowerPlaced
            (zip [0 :: Int ..] untagged)
    withLinks =
        foldl'
            ( \inner recordKey ->
                let neighbours =
                        [ point
                        | neighbour <- fromMaybe [] (IM.lookup recordKey linkAnchors)
                        , Just point <- [IM.lookup neighbour sunflowerPlaced]
                        ]
                 in case meanPoint neighbours of
                        Just point | not (null neighbours) -> IM.insert recordKey point inner
                        _ -> inner
            )
            gridPlaced
            untagged
    placed = withLinks

{- | Push overlapping records apart on a coarse grid. Only records move, so the
tag clusters keep the shape the force pass gave them.
-}
relaxRecords :: Int -> IM.IntMap (Double, Double) -> IM.IntMap (Double, Double)
relaxRecords iterations start = foldl' (\position _ -> relaxStep position) start [1 .. iterations]

relaxStep :: IM.IntMap (Double, Double) -> IM.IntMap (Double, Double)
relaxStep position =
    foldl' spread position (M.toList cells)
  where
    cellSize = 34
    cells =
        IM.foldlWithKey'
            ( \acc key (x, y) ->
                M.insertWith (++) (cellOf x y) [key] acc
            )
            M.empty
            position
    cellOf x y = (floor (x / cellSize) :: Int, floor (y / cellSize) :: Int)
    spread acc ((cellX, cellY), keys) =
        case sortOn id keys of
            [] -> acc
            [_] -> acc
            ordered ->
                let centerX = (fromIntegral cellX + 0.5) * cellSize
                    centerY = (fromIntegral cellY + 0.5) * cellSize
                 in foldl'
                        ( \inner (index, key) ->
                            case IM.lookup key inner of
                                Nothing -> inner
                                Just (x, y) ->
                                    let radius = 4 * sqrt (fromIntegral index)
                                        angle = fromIntegral index * goldenAngle
                                        targetX = centerX + radius * cos angle
                                        targetY = centerY + radius * sin angle
                                     in IM.insert key (x * 0.45 + targetX * 0.55, y * 0.45 + targetY * 0.55) inner
                        )
                        acc
                        (zip [0 :: Int ..] ordered)

meanPoint :: [(Double, Double)] -> Maybe (Double, Double)
meanPoint [] = Nothing
meanPoint points =
    let total = fromIntegral (length points)
        (sumX, sumY) = foldl' (\(x, y) (px, py) -> (x + px, y + py)) (0, 0) points
     in Just (sumX / total, sumY / total)

{- | Bounds of the raw node positions, used to size nodes before the padded
bounds are known.
-}
positionBounds :: IM.IntMap (Double, Double) -> (Double, Double, Double, Double)
positionBounds positions
    | IM.null positions = (0, 0, 1, 1)
    | otherwise =
        let (minX, minY, maxX, maxY) =
                IM.foldlWithKey'
                    ( \(lowX, lowY, highX, highY) _ (x, y) ->
                        (min lowX x, min lowY y, max highX x, max highY y)
                    )
                    (1e9, 1e9, -1e9, -1e9)
                    positions
         in (minX, minY, maxX, maxY)

nodeBounds :: IM.IntMap (Double, Double) -> IM.IntMap Double -> ((Double, Double), (Double, Double))
nodeBounds positions radii
    | IM.null positions = ((0, 0), (1, 1))
    | otherwise = foldl' step ((1e9, 1e9), (-1e9, -1e9)) (IM.toList positions)
  where
    step ((minX, minY), (maxX, maxY)) (key, (x, y)) =
        let radius = fromMaybe 4 (IM.lookup key radii)
         in ( (min minX (x - radius), min minY (y - radius))
            , (max maxX (x + radius), max maxY (y + radius))
            )

cleanWikiEdges :: IM.IntMap GraphRecord -> [GraphLink] -> [(Int, Int)]
cleanWikiEdges recordMap links =
    M.keys
        ( M.fromList
            [ (ordered, ())
            | link <- links
            , let source = recordKeyOf (glSource link)
            , let target = recordKeyOf (glTarget link)
            , source /= target
            , IM.member source recordMap
            , IM.member target recordMap
            , let ordered = (min source target, max source target)
            ]
        )
