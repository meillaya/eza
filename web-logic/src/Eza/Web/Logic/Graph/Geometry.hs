{- | The pure graph geometry the reducers need: viewport fitting and zoom,
hit-testing, neighbourhood subsets and matching.

The painter in @Eza.Web.Graph@ re-exports these; keeping them native means a
reducer can decide what the graph should show without importing the shell's
canvas layer.
-}
module Eza.Web.Logic.Graph.Geometry (
    fitView,
    focusView,
    resizeView,
    zoomViewAt,
    zoomViewCenter,
    panView,
    worldToScreen,
    screenToWorld,
    nodeAt,
    nodeRadius,
    nodeLabel,
    neighbourhood,
    matchGraph,
    localLayout,
    detailChunkCount,
) where

import Control.Monad (unless, when)
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.List (foldl', sortOn)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Eza.GraphLayout
import Eza.Types (GraphRecord (..))
import Eza.View (LabelMode (..))

import Eza.Web.Logic.Graph (GraphMatches (..), GraphView (..), emptyMatches)

fitView :: GraphLayout -> Double -> Double -> Double -> GraphView
fitView layout width height dpr =
    GraphView width height dpr scale pan scale
  where
    (minX, minY) = glMin layout
    (maxX, maxY) = glMax layout
    worldWidth = max 1 (maxX - minX)
    worldHeight = max 1 (maxY - minY)
    scale = max 0.002 (min ((width - 96) / worldWidth) ((height - 96) / worldHeight))
    pan = (width / 2 - (minX + worldWidth / 2) * scale, height / 2 - (minY + worldHeight / 2) * scale)

-- | Centre one node at a closer zoom, used by @OpenGraphAt@.
focusView :: GraphLayout -> Int -> Double -> Double -> Double -> GraphView
focusView layout key width height dpr =
    case IM.lookup key (glPos layout) of
        Nothing -> fitView layout width height dpr
        Just (x, y) ->
            let base = fitView layout width height dpr
                scale = gvFit base * 2.6
             in base
                    { gvScale = scale
                    , gvPan = (width / 2 - x * scale, height / 2 - y * scale)
                    }

-- | Keep the world point under the plate centre when the plate resizes.
resizeView :: GraphLayout -> Double -> Double -> Double -> GraphView -> GraphView
resizeView layout width height dpr old =
    GraphView width height dpr scale pan fit
  where
    (centerX, centerY) = screenToWorld old (gvWidth old / 2, gvHeight old / 2)
    fitted = fitView layout width height dpr
    fit = gvFit fitted
    scale = clamp (fit * 0.25) (fit * 16) (gvScale old)
    pan = (width / 2 - centerX * scale, height / 2 - centerY * scale)

clamp :: Double -> Double -> Double -> Double
clamp low high value = max low (min high value)

{- | Zoom around a point in plate coordinates, keeping the world point under the
pointer fixed.
-}
zoomViewAt :: GraphLayout -> GraphView -> (Double, Double) -> Double -> GraphView
zoomViewAt _ view (cursorX, cursorY) factor =
    view{gvScale = scale, gvPan = pan}
  where
    fit = gvFit view
    scale = clamp (fit * 0.25) (fit * 18) (gvScale view * factor)
    (worldX, worldY) = screenToWorld view (cursorX, cursorY)
    pan = (cursorX - worldX * scale, cursorY - worldY * scale)

zoomViewCenter :: GraphLayout -> GraphView -> Double -> GraphView
zoomViewCenter layout view =
    zoomViewAt layout view (gvWidth view / 2, gvHeight view / 2)

panView :: (Double, Double) -> GraphView -> GraphView
panView (deltaX, deltaY) view =
    view{gvPan = (fst (gvPan view) + deltaX, snd (gvPan view) + deltaY)}

worldToScreen :: GraphView -> (Double, Double) -> (Double, Double)
worldToScreen view (x, y) =
    (fst (gvPan view) + x * gvScale view, snd (gvPan view) + y * gvScale view)

screenToWorld :: GraphView -> (Double, Double) -> (Double, Double)
screenToWorld view (x, y) =
    ( (x - fst (gvPan view)) / max 1e-9 (gvScale view)
    , (y - snd (gvPan view)) / max 1e-9 (gvScale view)
    )

{- | The node under a plate coordinate, if any. Records and tags both count;
the nearest node within its screen-space hit radius wins.
-}
nodeAt :: GraphLayout -> GraphView -> (Double, Double) -> Maybe Int
nodeAt layout view (screenX, screenY) =
    snd
        ( IM.foldlWithKey'
            pick
            (1e18, Nothing)
            (glPos layout)
        )
  where
    (worldX, worldY) = screenToWorld view (screenX, screenY)
    viewScale = max 1e-9 (gvScale view)
    pick current@(bestDistance, _) key (x, y) =
        let radius = nodeRadius layout key + 7 / viewScale
            dx = x - worldX
            dy = y - worldY
            distance = dx * dx + dy * dy
         in if distance <= radius * radius && distance < bestDistance
                then (distance, Just key)
                else current

nodeRadius :: GraphLayout -> Int -> Double
nodeRadius layout key = fromMaybe 4 (IM.lookup key (glRadii layout))

nodeLabel :: GraphLayout -> Int -> Maybe Text
nodeLabel layout key
    | isTagKey key = fst <$> IM.lookup key (glTags layout)
    | otherwise = grTitle <$> IM.lookup key (glRecords layout)

-- | The wider neighbourhood of one node, for the preview card.
neighbourhood :: GraphLayout -> Int -> IM.IntMap ()
neighbourhood layout key = IM.fromList [(neighbour, ()) | neighbour <- neighbours]
  where
    neighbours = fromMaybe [] (IM.lookup key (glAdj layout))

-- --------------------------------------------------------------- matching ---

{- | The filter result. The record set, tag set and top ids are filled by one
scan over the records; nothing is sorted per frame.
-}

{- | Match records by title, domain, or tag name. Tokens are ANDed and lowered
once. The top list keeps the eight best records for the results panel.
-}
matchGraph :: Text -> GraphLayout -> GraphMatches
matchGraph rawQuery layout
    | null tokens = emptyMatches
    | otherwise = GraphMatches True recordIds topIds count tagIds
  where
    tokens = T.words (T.toLower (T.strip rawQuery))
    tagNames = IM.map fst (glTags layout)
    scored =
        [ (recordKey, score)
        | (recordKey, record) <- IM.toList (glRecords layout)
        , Just score <- [recordScore recordKey record]
        ]
    recordIds = IS.fromList (map fst scored)
    count = length scored
    tagIds =
        IS.fromList
            [ tagKey
            | (tagKey, name) <- IM.toList tagNames
            , all (\token -> T.isInfixOf token (T.toLower name)) tokens
            ]
    recordScore recordKey record =
        let title = T.toLower (grTitle record)
            domain = T.toLower (grDomain record)
            tagWords =
                [ T.toLower name
                | tagKey <- fromMaybe [] (IM.lookup recordKey (glRecordTags layout))
                , Just name <- [IM.lookup tagKey tagNames]
                ]
            titleHits = length [() | token <- tokens, T.isInfixOf token title]
            tagHits = length [() | token <- tokens, any (T.isInfixOf token) tagWords]
            domainHits = length [() | token <- tokens, T.isInfixOf token domain]
            matched =
                all
                    (\token -> T.isInfixOf token title || T.isInfixOf token domain || any (T.isInfixOf token) tagWords)
                    tokens
         in if matched then Just (titleHits * 3 + tagHits * 2 + domainHits) else Nothing
    topIds = map fst (take 8 (foldl' insertTop [] scored))
    insertTop :: [(Int, Int)] -> (Int, Int) -> [(Int, Int)]
    insertTop [] item = [item]
    insertTop (existing : rest) item
        | rank item < rank existing = item : existing : rest
        | otherwise = existing : insertTop rest item
    rank (recordKey, score) = (negate score, recordKey)

-- ---------------------------------------------------------------- drawing ---

{- | One line of drag state. 'gdStart' is where the pointer went down, 'gdLast'
the last move; the flag tells a click from a pan.
-}

{- | How many animation frames one settle plate takes. The visible primitives
are split into ranges, so no single frame runs a long task.
-}
detailChunkCount :: GraphLayout -> Int
detailChunkCount layout =
    let total =
            glLinkCount layout
                + glMemberCount layout
                + glRecordCount layout
                + glTagCount layout
        size = 1000
     in max 1 ((total + size - 1) `div` size)

{- | The local neighbourhood of one record: the induced subgraph within @depth@
hops over both relationship families. The node set is capped at 2,500, taking
the highest-degree nodes first in each BFS layer, and the second component of
the result reports whether the cap truncated the graph.
-}
localLayout :: GraphLayout -> Int -> Int -> Maybe (GraphLayout, Bool)
localLayout layout root depth
    | depth < 1 = Nothing
    | isTagKey root = Nothing
    | not (IM.member root (glPos layout)) = Nothing
    | otherwise = Just (subset, capped)
  where
    maxNodes = 2500
    hops = max 1 (min 3 depth)
    adjacency = glAdj layout
    neighbours key = fromMaybe [] (IM.lookup key adjacency)
    degree key = length (neighbours key)
    priority key = (negate (degree key), key)
    (nodes, capped) = walk (IS.singleton root) [root] hops False
    walk visited frontier remaining truncated
        | remaining <= 0 || null frontier = (visited, truncated)
        | otherwise =
            let candidates =
                    [ neighbour
                    | key <- frontier
                    , neighbour <- neighbours key
                    , not (IS.member neighbour visited)
                    ]
                space = max 0 (maxNodes - IS.size visited)
                ordered = sortOn priority candidates
                taken = take space ordered
                over = length ordered > space
                visited' = foldl' (\acc key -> IS.insert key acc) visited taken
             in walk visited' taken (remaining - 1) (truncated || over)
    positions = IM.restrictKeys (glPos layout) nodes
    radii = IM.restrictKeys (glRadii layout) nodes
    inNodes key = IS.member key nodes
    links = filter (\(a, b) -> inNodes a && inNodes b) (glLinks layout)
    membership = filter (\(a, b) -> inNodes a && inNodes b) (glMembers layout)
    segmentOf (a, b) =
        case (IM.lookup a positions, IM.lookup b positions) of
            (Just (x1, y1), Just (x2, y2)) -> Just (x1, y1, x2, y2)
            _ -> Nothing
    pointsOf keys =
        [ (x, y, radius)
        | key <- keys
        , Just (x, y) <- [IM.lookup key positions]
        , Just radius <- [IM.lookup key radii]
        ]
    recordKeys = [key | key <- IM.keys positions, not (isTagKey key)]
    tagKeys = [key | key <- IM.keys positions, isTagKey key]
    (minX, minY, maxX, maxY) = foldl' bounds ((1e9, 1e9, -1e9, -1e9)) (IM.toList positions)
    bounds ((lowX, lowY, highX, highY)) (key, (x, y)) =
        let radius = fromMaybe 4 (IM.lookup key radii)
         in ( min lowX (x - radius)
            , min lowY (y - radius)
            , max highX (x + radius)
            , max highY (y + radius)
            )
    bounded
        | IM.null positions = ((0, 0), (1, 1))
        | otherwise = ((minX, minY), (maxX, maxY))
    subset =
        layout
            { glPos = positions
            , glRadii = radii
            , glAdj = IM.map (filter inNodes) (IM.restrictKeys (glAdj layout) nodes)
            , glLinks = links
            , glMembers = membership
            , glMemberSegments = mapMaybe segmentOf membership
            , glLinkSegments = mapMaybe segmentOf links
            , glRecordPoints = pointsOf recordKeys
            , glTagPoints = pointsOf tagKeys
            , glTagOrder = filter inNodes (glTagOrder layout)
            , glRecordOrder = filter inNodes (glRecordOrder layout)
            , glMin = fst bounded
            , glMax = snd bounded
            , glTagCount = length tagKeys
            , glLinkCount = length links
            , glMemberCount = length membership
            , glRecordCount = length recordKeys
            }
