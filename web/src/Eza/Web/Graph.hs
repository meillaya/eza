{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- | The whole-library graph: deterministic layout, viewport geometry, and the
canvas painter.

The graph holds two kinds of node. A record node carries a bookmark; a tag node
carries a tag. The two relationship types are the only ones drawn: a resolved
wikilink joins two records, and tag membership joins a record to a tag. Tag
co-occurrence only decides where tag nodes sit; it is never drawn as an edge.

Node identity is one 'Int'. Record keys are bookmark ids (positive); tag keys
are @negate (index + 1)@ so both fit in one 'Data.IntMap.Strict.IntMap'.

The base picture (both edge families, every node, the label layer) is painted
once into an offscreen canvas cached on @window.__ezaGraphCache@. Pan and zoom
only blit that bitmap. A filter paints the bitmap and then an accent overlay,
so typing never repaints the base. At three times the fit scale the painter
switches to a vector subset for crisp lines and text.
-}
module Eza.Web.Graph (
    -- * Layout from eza-core
    module Eza.GraphLayout,

    -- * Viewport
    GraphView (..),
    initialGraphView,
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

    -- * Local graph
    localLayout,

    -- * Labels
    LabelPolicy (..),
    labelPolicy,
    labelCount,

    -- * Matching
    GraphMatches (..),
    emptyMatches,
    matchGraph,

    -- * Dragging
    GraphDrag (..),

    -- * Painting
    GraphDraw (..),
    drawGraph,
    detailChunkCount,
) where

import Control.Monad (foldM, foldM_, forM_, unless, when)
import Control.Monad.Reader (runReaderT)
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as LBS
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Miso
import Miso.CSS.Color (Color, hex, renderColor, rgba)
import Miso.Canvas (Canvas)
import qualified Miso.Canvas as Canvas

import Eza.GraphLayout
import Eza.Types (GraphRecord (..))
import Eza.View (LabelMode (..))

-- --------------------------------------------------------------- viewport ---

{- | The visible transform: CSS pixels per world unit, plus the pan offset.
'gvFit' is the scale at which the whole graph fits the plate; the zoom
readout and the vector threshold are relative to it.
-}
data GraphView = GraphView
    { gvWidth :: Double
    , gvHeight :: Double
    , gvDpr :: Double
    , gvScale :: Double
    , gvPan :: (Double, Double)
    , gvFit :: Double
    }
    deriving (Eq, Show)

initialGraphView :: GraphView
initialGraphView = GraphView 920 480 1 1 (0, 0) 1

-- | The starting view for a layout inside a measured plate.
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
data GraphMatches = GraphMatches
    { gmActive :: Bool
    , gmIds :: IS.IntSet
    , gmTop :: [Int]
    , gmCount :: Int
    , gmTags :: IS.IntSet
    }
    deriving (Eq, Show)

emptyMatches :: GraphMatches
emptyMatches = GraphMatches False IS.empty [] 0 IS.empty

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
data GraphDrag = GraphDrag
    { gdStart :: (Double, Double)
    , gdLast :: (Double, Double)
    , gdMoved :: Bool
    }
    deriving (Eq, Show)

-- | Everything the painter needs for one frame.
data GraphDraw = GraphDraw
    { drLayout :: GraphLayout
    , drView :: GraphView
    , drHover :: Maybe Int
    , drSelected :: Maybe Int
    , drFocus :: Maybe Int
    , drMatches :: GraphMatches
    , drTagsShown :: Bool
    , drLabelMode :: LabelMode
    , drRecordColors :: IM.IntMap Text
    , drTagColors :: M.Map Text Text
    , drViewKey :: MisoString
    , drLocal :: Bool
    , drSettled :: Bool
    , drDetailPhase :: Int
    , drDetailChunks :: Int
    , drDark :: Bool
    }

data Palette = Palette
    { pPaper :: Color
    , pCard :: Color
    , pInk :: Color
    , pMuted :: Color
    , pAccent :: Color
    , pRule :: Color
    , pVeil :: Color
    , pCacheKey :: MisoString
    }

paletteFor :: Bool -> Palette
paletteFor dark
    | dark =
        Palette
            { pPaper = hex "10141F"
            , pCard = hex "161B28"
            , pInk = hex "E9E3D6"
            , pMuted = hex "A9A08F"
            , pAccent = hex "C98A3E"
            , pRule = hex "232A3A"
            , pVeil = rgba 16 20 31 0.70
            , pCacheKey = "dark"
            }
    | otherwise =
        Palette
            { pPaper = hex "F2EDE3"
            , pCard = hex "FBF8F1"
            , pInk = hex "1A2340"
            , pMuted = hex "6E675C"
            , pAccent = hex "8A2B20"
            , pRule = hex "D5CBB8"
            , pVeil = rgba 242 237 227 0.70
            , pCacheKey = "light"
            }

-- | World to bitmap mapping used while painting the cached base picture.
data XForm = XForm
    { xfX0 :: Double
    , xfY0 :: Double
    , xfScale :: Double
    }

xformPoint :: XForm -> Double -> Double -> (Double, Double)
xformPoint XForm{..} x y = ((x - xfX0) * xfScale, (y - xfY0) * xfScale)

-- | The cached offscreen canvas and the mapping it was painted with.
data BaseCache = BaseCache
    { bcCanvas :: JSVal
    , bcKey :: MisoString
    , bcScale :: Double
    , bcX0 :: Double
    , bcY0 :: Double
    , bcWidth :: Int
    , bcHeight :: Int
    }

cacheGlobal :: MisoString
cacheGlobal = "__ezaGraphCache"

cacheKeyFor :: GraphLayout -> Palette -> Bool -> MisoString -> MisoString
cacheKeyFor layout palette tagsShown viewKey =
    ms (show (glGen layout))
        <> ":"
        <> pCacheKey palette
        <> (if tagsShown then ":tags" else ":records")
        <> ":"
        <> viewKey

-- ----------------------------------------------------------- batch bridge ---

{- | Ask the static JS helper whether it can batch a layer. The helper lives in
pwa.js, which the page loads before the Miso module, so this is normally true;
an old cached shell or a browser without Path2D falls back to the original
per-primitive painter.
-}
graphBatchAvailable :: IO Bool
graphBatchAvailable = do
    window' <- jsg ("window" :: MisoString)
    graph <- window' ! ("EzaGraph" :: MisoString)
    missing <- (||) <$> isUndefined graph <*> isNull graph
    if missing
        then pure False
        else do
            value <- graph # ("available" :: MisoString) $ (() :: ())
            fromMaybe False <$> (fromJSValUnchecked value :: IO (Maybe Bool))

{- | Emit a mark only while the perf harness has opted in. Production frames
never pay for an extra performance entry.
-}
graphPerfMark :: MisoString -> IO ()
graphPerfMark name = do
    window' <- jsg ("window" :: MisoString)
    enabled <- (fromJSValUnchecked =<< window' ! ("__ezaGraphPerf" :: MisoString)) :: IO (Maybe Bool)
    when (fromMaybe False enabled) $ do
        perf <- jsg ("performance" :: MisoString)
        _ <- perf # ("mark" :: MisoString) $ ("eza:graph:" <> name)
        pure ()

paintLayer :: MisoString -> MisoString -> MisoString -> Double -> Double -> Canvas Bool
paintLayer mode packed color alpha lineWidth = do
    ctx <- ask
    result <-
        liftIO $ do
            window' <- jsg ("window" :: MisoString)
            graph <- window' ! ("EzaGraph" :: MisoString)
            value <-
                graph # ("paintLayer" :: MisoString) $
                    (ctx, mode, packed, color, alpha, lineWidth)
            (fromJSValUnchecked value :: IO (Maybe Bool))
    pure (fromMaybe False result)

{- | Pack one layer as little-endian Float32 bytes and hex-encode them. A
human-readable decimal list cost ~1.15 s in the WASM build for the 9k-record
plate because every coordinate went through `showFFloat`; the byte builder is
only a few thousand machine operations and JS decodes the hex once per layer.
-}
packBuilder :: BB.Builder -> MisoString
packBuilder builder =
    ms
        ( "hex:"
            <> TE.decodeUtf8
                ( LBS.toStrict
                    (BB.toLazyByteString (BB.byteStringHex raw))
                )
        )
  where
    raw = LBS.toStrict (BB.toLazyByteString builder)

coordB :: Double -> BB.Builder
coordB value = BB.floatLE (realToFrac value)

-- | One world-space segment in the cached bitmap's own pixel space.
baseSegmentB :: XForm -> GraphLayout -> (Int, Int) -> BB.Builder
baseSegmentB xform layout (source, target) =
    case (IM.lookup source (glPos layout), IM.lookup target (glPos layout)) of
        (Just (x1, y1), Just (x2, y2)) ->
            let (px1, py1) = xformPoint xform x1 y1
                (px2, py2) = xformPoint xform x2 y2
             in coordB px1 <> coordB py1 <> coordB px2 <> coordB py2
        _ -> mempty

-- | One world-space circle in the cached bitmap's own pixel space.
baseCircleB :: XForm -> GraphLayout -> Int -> BB.Builder
baseCircleB xform layout key =
    case IM.lookup key (glPos layout) of
        Just (x, y) ->
            let (px, py) = xformPoint xform x y
                radius = max 0.4 (nodeRadius layout key * xfScale xform)
             in coordB px <> coordB py <> coordB radius
        Nothing -> mempty

{- | One visible world-space segment in screen space, used by the detail plate
and the filter overlay.
-}
detailSegmentB :: GraphView -> (Double, Double, Double, Double) -> BB.Builder
detailSegmentB view (x1, y1, x2, y2) =
    let (px1, py1) = worldToScreen view (x1, y1)
        (px2, py2) = worldToScreen view (x2, y2)
     in coordB px1 <> coordB py1 <> coordB px2 <> coordB py2

detailCircleB :: GraphView -> Double -> Double -> Double -> BB.Builder
detailCircleB view x y worldRadius =
    let (px, py) = worldToScreen view (x, y)
        radius = max 0.4 (worldRadius * gvScale view)
     in coordB px <> coordB py <> coordB radius

{- | A malformed/empty packed layer is a no-op in JS; an empty builder simply
produces an empty string. The helper accepts that.
-}

{- | Paint one frame. Two caches keep motion cheap and still crisp at rest:
the world bitmap is blitted while the view moves, and after a pause a
screen-resolution detail plate is rastered once and drawn 1:1.
-}
drawGraph :: GraphDraw -> Canvas ()
drawGraph GraphDraw{..} = do
    let palette = paletteFor drDark
        view = drView
        width = gvWidth view
        height = gvHeight view
        dpr = max 1 (gvDpr view)
        zoomRatio = gvScale view / max 1e-9 (gvFit view)
    Canvas.setTransform (dpr, 0, 0, dpr, 0, 0)
    Canvas.clearRect (0, 0, width, height)
    Canvas.fillStyle (Canvas.color (pPaper palette))
    Canvas.fillRect (0, 0, width, height)
    if drLocal
        then do
            fast <- liftIO graphBatchAvailable
            ok <-
                if fast
                    then drawDetailFast palette drLayout view drTagsShown drRecordColors drTagColors
                    else drawDetailChunk palette drLayout view drTagsShown drRecordColors drTagColors 1 1 >> pure True
            unless ok (drawDetailChunk palette drLayout view drTagsShown drRecordColors drTagColors 1 1)
        else
            if drDetailPhase > 0 && drDetailChunks > 0
                then do
                    drawWorldBase palette drLayout view drTagsShown drViewKey drRecordColors drTagColors
                    liftIO
                        ( paintDetailChunk
                            palette
                            drLayout
                            view
                            drTagsShown
                            drViewKey
                            drRecordColors
                            drTagColors
                            drDetailPhase
                            drDetailChunks
                        )
                else
                    if drSettled && zoomRatio > 1.1
                        then do
                            let wanted = detailKeyFor drLayout palette drTagsShown drViewKey view
                            cached <- liftIO (loadDetailCache wanted)
                            detail <- case cached of
                                Just value -> pure (Just value)
                                Nothing -> liftIO (buildDetailCache palette drLayout view drTagsShown drViewKey drRecordColors drTagColors)
                            case detail of
                                Just value -> blitDetail view value
                                Nothing -> drawWorldBase palette drLayout view drTagsShown drViewKey drRecordColors drTagColors
                        else drawWorldBase palette drLayout view drTagsShown drViewKey drRecordColors drTagColors
    when (gmActive drMatches) $
        drawFilterOverlay palette drLayout view drMatches drTagsShown
    unless (gmActive drMatches) (drawLabels palette drLayout view drTagsShown drLabelMode)
    drawEmphasis palette drLayout view drHover drSelected drFocus

{- | Blit the cached whole-library bitmap, building it on first use. This is
the only path that runs while the reader drags or zooms.
-}
drawWorldBase :: Palette -> GraphLayout -> GraphView -> Bool -> MisoString -> IM.IntMap Text -> M.Map Text Text -> Canvas ()
drawWorldBase palette layout view tagsShown viewKey recordColors tagColors = do
    cached <- liftIO (loadBaseCache (cacheKeyFor layout palette tagsShown viewKey))
    base <- case cached of
        Just value -> pure (Just value)
        Nothing -> liftIO (buildBaseCache palette layout tagsShown viewKey recordColors tagColors)
    forM_ base (blitBase view)

-- ------------------------------------------------------------ detail cache ---

data DetailCache = DetailCache
    { dcCanvas :: JSVal
    , dcKey :: MisoString
    , dcWidth :: Int
    , dcHeight :: Int
    }

detailGlobal :: MisoString
detailGlobal = "__ezaGraphDetail"

{- | A settled view is keyed by everything that changes its pixels. Rounding
lets sub-pixel jitter reuse a plate; a real pan or zoom always misses.
-}
detailKeyFor :: GraphLayout -> Palette -> Bool -> MisoString -> GraphView -> MisoString
detailKeyFor layout palette tagsShown viewKey view =
    ms (show (glGen layout))
        <> ":"
        <> pCacheKey palette
        <> (if tagsShown then ":tags" else ":records")
        <> ":"
        <> viewKey
        <> ":"
        <> ms (show (round (gvWidth view) :: Int))
        <> "x"
        <> ms (show (round (gvHeight view) :: Int))
        <> "@"
        <> ms (show (round (gvDpr view * 100) :: Int))
        <> ":"
        <> ms (show (round (gvScale view * 1000) :: Int))
        <> ","
        <> ms (show (round (fst (gvPan view)) :: Int))
        <> ","
        <> ms (show (round (snd (gvPan view)) :: Int))

loadDetailCache :: MisoString -> IO (Maybe DetailCache)
loadDetailCache wanted = do
    window' <- jsg ("window" :: MisoString)
    raw <- window' ! detailGlobal
    maybeObject <- (fromJSValUnchecked raw :: IO (Maybe JSVal))
    case maybeObject of
        Nothing -> pure Nothing
        Just cached -> do
            key <- fromJSValUnchecked =<< cached ! ("key" :: MisoString)
            if (key :: MisoString) /= wanted
                then pure Nothing
                else do
                    canvas <- cached ! ("canvas" :: MisoString)
                    width <- fromJSValUnchecked =<< cached ! ("width" :: MisoString)
                    height <- fromJSValUnchecked =<< cached ! ("height" :: MisoString)
                    pure (Just (DetailCache canvas key width height))

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

-- | One frame's slice of the settle plate.
data DetailChunk = DetailChunk
    { chLinks :: (Int, Int)
    , chMembers :: (Int, Int)
    , chRecords :: (Int, Int)
    , chTags :: (Int, Int)
    }

detailChunkPlan :: GraphLayout -> Int -> Int -> DetailChunk
detailChunkPlan layout chunks phase = DetailChunk linkRange memberRange recordRange tagRange
  where
    linkN = glLinkCount layout
    memberN = glMemberCount layout
    recordN = glRecordCount layout
    tagN = glTagCount layout
    total = linkN + memberN + recordN + tagN
    per = max 1 ((total + chunks - 1) `div` chunks)
    start = max 0 ((phase - 1) * per)
    end = min total (start + per)
    slice offset count =
        let from = max 0 (start - offset)
            to = max 0 (min count (end - offset))
         in (min from to, max from to)
    linkRange = slice 0 linkN
    memberRange = slice linkN memberN
    recordRange = slice (linkN + memberN) recordN
    tagRange = slice (linkN + memberN + recordN) tagN

{- | Raster the visible graph at the plate's own resolution. The synchronous
fallback uses every chunk in one go; the settle path draws one per frame.
-}
buildDetailCache :: Palette -> GraphLayout -> GraphView -> Bool -> MisoString -> IM.IntMap Text -> M.Map Text Text -> IO (Maybe DetailCache)
buildDetailCache palette layout view tagsShown viewKey recordColors tagColors = do
    graphPerfMark "detail-start"
    cached <- ensureDetailCanvas (detailKeyFor layout palette tagsShown viewKey view) view
    case cached of
        Nothing -> pure Nothing
        Just (canvas, ctx2d, dpr, _) -> do
            fast <- graphBatchAvailable
            if fast
                then do
                    painted <-
                        runReaderT
                            ( do
                                Canvas.setTransform (dpr, 0, 0, dpr, 0, 0)
                                drawDetailFast palette layout view tagsShown recordColors tagColors
                            )
                            ctx2d
                    unless painted $ do
                        let chunks = detailChunkCount layout
                        runReaderT
                            ( do
                                Canvas.setTransform (dpr, 0, 0, dpr, 0, 0)
                                forM_ [1 .. chunks] $
                                    drawDetailChunk palette layout view tagsShown recordColors tagColors chunks
                            )
                            ctx2d
                else do
                    let chunks = detailChunkCount layout
                    runReaderT
                        ( do
                            Canvas.setTransform (dpr, 0, 0, dpr, 0, 0)
                            forM_ [1 .. chunks] $
                                drawDetailChunk palette layout view tagsShown recordColors tagColors chunks
                        )
                        ctx2d
            graphPerfMark "detail-end"
            pure
                ( Just
                    (DetailCache canvas (detailKeyFor layout palette tagsShown viewKey view) (round (gvWidth view)) (round (gvHeight view)))
                )

-- | Draw one chunk of the settle plate into the offscreen canvas.
paintDetailChunk :: Palette -> GraphLayout -> GraphView -> Bool -> MisoString -> IM.IntMap Text -> M.Map Text Text -> Int -> Int -> IO ()
paintDetailChunk palette layout view tagsShown viewKey recordColors tagColors phase chunks = do
    cached <- ensureDetailCanvas (detailKeyFor layout palette tagsShown viewKey view) view
    case cached of
        Nothing -> pure ()
        Just (_, ctx2d, dpr, fresh) -> do
            fast <- graphBatchAvailable
            if fast
                then when fresh $ do
                    painted <-
                        runReaderT
                            ( do
                                Canvas.setTransform (dpr, 0, 0, dpr, 0, 0)
                                drawDetailFast palette layout view tagsShown recordColors tagColors
                            )
                            ctx2d
                    unless painted $
                        runReaderT
                            ( do
                                Canvas.setTransform (dpr, 0, 0, dpr, 0, 0)
                                drawDetailChunk palette layout view tagsShown recordColors tagColors chunks phase
                            )
                            ctx2d
                else
                    runReaderT
                        ( do
                            Canvas.setTransform (dpr, 0, 0, dpr, 0, 0)
                            if fresh
                                then
                                    forM_ [1 .. phase] $
                                        drawDetailChunk palette layout view tagsShown recordColors tagColors chunks
                                else drawDetailChunk palette layout view tagsShown recordColors tagColors chunks phase
                        )
                        ctx2d

{- | The detail canvas for a key, creating and registering it on first use.
The context is fetched each chunk, which is one FFI call per frame.
-}
ensureDetailCanvas :: MisoString -> GraphView -> IO (Maybe (JSVal, JSVal, Double, Bool))
ensureDetailCanvas wanted view = do
    cached <- loadDetailCache wanted
    case cached of
        Just DetailCache{..} -> do
            ctx2d <- dcCanvas # ("getContext" :: MisoString) $ (["2d"] :: [MisoString])
            pure (Just (dcCanvas, ctx2d, max 1 (min 2 (gvDpr view)), False))
        Nothing -> do
            let dpr = max 1 (min 2 (gvDpr view))
                width = max 1 (round (gvWidth view * dpr) :: Int)
                height = max 1 (round (gvHeight view * dpr) :: Int)
            document <- jsg ("document" :: MisoString)
            canvas <- document # ("createElement" :: MisoString) $ (["canvas"] :: [MisoString])
            setField canvas ("width" :: MisoString) width
            setField canvas ("height" :: MisoString) height
            ctx2d <- canvas # ("getContext" :: MisoString) $ ["2d" :: MisoString]
            window' <- jsg ("window" :: MisoString)
            holder <- create
            setField holder ("key" :: MisoString) wanted
            setField holder ("canvas" :: MisoString) canvas
            setField holder ("width" :: MisoString) width
            setField holder ("height" :: MisoString) height
            setField window' detailGlobal holder
            pure (Just (canvas, ctx2d, dpr, True))

{- | The detail canvas stores device pixels; draw it into CSS pixels. The
context is already scaled by dpr, so the destination is the plate size.
-}
blitDetail :: GraphView -> DetailCache -> Canvas ()
blitDetail view DetailCache{..} =
    Canvas.drawImage'
        (Image dcCanvas, 0, 0, gvWidth view, gvHeight view)

{- | One slice of the settle plate: visible nodes and edges only, at screen
resolution, with no labels or interaction emphasis. The first chunk clears
the canvas; the rest append.
-}
drawDetailChunk :: Palette -> GraphLayout -> GraphView -> Bool -> IM.IntMap Text -> M.Map Text Text -> Int -> Int -> Canvas ()
drawDetailChunk palette layout view tagsShown recordColors tagColors chunks phase = do
    when (phase <= 1) $ do
        Canvas.globalAlpha 1
        Canvas.fillStyle (Canvas.color (pPaper palette))
        Canvas.fillRect (0, 0, gvWidth view, gvHeight view)
    let (minX, minY, maxX, maxY) = visibleWorld view
        segmentVisible (x1, y1, x2, y2) =
            max x1 x2 >= minX
                && min x1 x2 <= maxX
                && max y1 y2 >= minY
                && min y1 y2 <= maxY
        plan = detailChunkPlan layout chunks phase
        range (from, to) entries = take (to - from) (drop from entries)
        (linkFrom, linkTo) = chLinks plan
        (memberFrom, memberTo) = chMembers plan
        (recordFrom, recordTo) = chRecords plan
        (tagFrom, tagTo) = chTags plan
    when (linkTo > linkFrom) $ do
        Canvas.globalAlpha 0.72
        Canvas.strokeStyle (Canvas.color (pRule palette))
        Canvas.lineWidth 1
        Canvas.beginPath ()
        forM_ (range (linkFrom, linkTo) (glLinkSegments layout)) $ \(x1, y1, x2, y2) ->
            when (segmentVisible (x1, y1, x2, y2)) $
                lineBetween view (x1, y1) (x2, y2)
        Canvas.stroke ()
    when (tagsShown && memberTo > memberFrom) $ do
        Canvas.globalAlpha 0.32
        Canvas.strokeStyle (Canvas.color (pMuted palette))
        Canvas.beginPath ()
        forM_ (range (memberFrom, memberTo) (glMemberSegments layout)) $ \(x1, y1, x2, y2) ->
            when (segmentVisible (x1, y1, x2, y2)) $
                lineBetween view (x1, y1) (x2, y2)
        Canvas.stroke ()
    let recordKeys = pointKeys layout False
        tagKeys = pointKeys layout True
        tagColorsByKey = tagColorKeys layout tagColors
    when (recordTo > recordFrom) $ do
        let zipped =
                zip
                    (take (recordTo - recordFrom) (drop recordFrom recordKeys))
                    (take (recordTo - recordFrom) (drop recordFrom (glRecordPoints layout)))
            colored = M.fromListWith (flip (++)) [(color, [point]) | (key, point) <- zipped, Just color <- [IM.lookup key recordColors]]
            plain = [point | (key, point) <- zipped, IM.notMember key recordColors]
        Canvas.globalAlpha 0.82
        Canvas.fillStyle (Canvas.color (pInk palette))
        Canvas.beginPath ()
        forM_ plain $ \(x, y, radius) ->
            when (pointWithin (minX - radius) (minY - radius) (maxX + radius) (maxY + radius) (x, y)) $
                addScreenCircle view x y radius
        Canvas.fill ()
        forM_ (M.toAscList colored) $ \(color, points) -> do
            Canvas.fillStyle (Canvas.color (colorOfHex color))
            Canvas.globalAlpha 0.95
            Canvas.beginPath ()
            forM_ points $ \(x, y, radius) ->
                when (pointWithin (minX - radius) (minY - radius) (maxX + radius) (maxY + radius) (x, y)) $
                    addScreenCircle view x y radius
            Canvas.fill ()
    when (tagsShown && tagTo > tagFrom) $ do
        let zipped =
                zip
                    (take (tagTo - tagFrom) (drop tagFrom tagKeys))
                    (take (tagTo - tagFrom) (drop tagFrom (glTagPoints layout)))
            colored = M.fromListWith (flip (++)) [(color, [point]) | (key, point) <- zipped, Just color <- [IM.lookup key tagColorsByKey]]
            plain = [point | (key, point) <- zipped, IM.notMember key tagColorsByKey]
        Canvas.globalAlpha 0.92
        Canvas.fillStyle (Canvas.color (pAccent palette))
        Canvas.beginPath ()
        forM_ plain $ \(x, y, radius) ->
            when (pointWithin (minX - radius) (minY - radius) (maxX + radius) (maxY + radius) (x, y)) $
                addScreenCircle view x y radius
        Canvas.fill ()
        forM_ (M.toAscList colored) $ \(color, points) -> do
            Canvas.fillStyle (Canvas.color (colorOfHex color))
            Canvas.globalAlpha 0.95
            Canvas.beginPath ()
            forM_ points $ \(x, y, radius) ->
                when (pointWithin (minX - radius) (minY - radius) (maxX + radius) (maxY + radius) (x, y)) $
                    addScreenCircle view x y radius
            Canvas.fill ()
    Canvas.globalAlpha 1

addScreenCircle :: GraphView -> Double -> Double -> Double -> Canvas ()
addScreenCircle view x y radius = do
    let (px, py) = worldToScreen view (x, y)
        pxRadius = max 0.4 (radius * gvScale view)
    Canvas.moveTo (px + pxRadius, py)
    Canvas.arc (px, py, pxRadius, 0, 2 * pi)

-- | Blit the cached base picture with the current pan and zoom.
blitBase :: GraphView -> BaseCache -> Canvas ()
blitBase view BaseCache{..} = do
    let scaleRatio = gvScale view / bcScale
        (destinationX, destinationY) = worldToScreen view (bcX0, bcY0)
    Canvas.drawImage'
        ( Image bcCanvas
        , destinationX
        , destinationY
        , fromIntegral bcWidth * scaleRatio
        , fromIntegral bcHeight * scaleRatio
        )

-- ------------------------------------------------------------- base cache ---

loadBaseCache :: MisoString -> IO (Maybe BaseCache)
loadBaseCache wanted = do
    window' <- jsg ("window" :: MisoString)
    raw <- window' ! cacheGlobal
    maybeObject <- (fromJSValUnchecked raw :: IO (Maybe JSVal))
    case maybeObject of
        Nothing -> pure Nothing
        Just cached -> do
            key <- fromJSValUnchecked =<< cached ! ("key" :: MisoString)
            if (key :: MisoString) /= wanted
                then pure Nothing
                else do
                    canvas <- cached ! ("canvas" :: MisoString)
                    scale <- fromJSValUnchecked =<< cached ! ("scale" :: MisoString)
                    x0 <- fromJSValUnchecked =<< cached ! ("x0" :: MisoString)
                    y0 <- fromJSValUnchecked =<< cached ! ("y0" :: MisoString)
                    width <- fromJSValUnchecked =<< cached ! ("width" :: MisoString)
                    height <- fromJSValUnchecked =<< cached ! ("height" :: MisoString)
                    pure
                        ( Just
                            BaseCache
                                { bcCanvas = canvas
                                , bcKey = key
                                , bcScale = scale
                                , bcX0 = x0
                                , bcY0 = y0
                                , bcWidth = width
                                , bcHeight = height
                                }
                        )

{- | Paint the whole static picture once. The long side is capped at 1536
device pixels so the cache stays around 16 MB.
-}
buildBaseCache :: Palette -> GraphLayout -> Bool -> MisoString -> IM.IntMap Text -> M.Map Text Text -> IO (Maybe BaseCache)
buildBaseCache palette layout tagsShown viewKey recordColors tagColors = do
    graphPerfMark "base-start"
    document <- jsg ("document" :: MisoString)
    canvas <- document # ("createElement" :: MisoString) $ (["canvas"] :: [MisoString])
    let (minX, minY) = glMin layout
        (maxX, maxY) = glMax layout
        padding = 64
        x0 = minX - padding
        y0 = minY - padding
        worldWidth = max 1 (maxX - minX + 2 * padding)
        worldHeight = max 1 (maxY - minY + 2 * padding)
        scale = 1536 / max worldWidth worldHeight
        width = max 1 (ceiling (worldWidth * scale) :: Int)
        height = max 1 (ceiling (worldHeight * scale) :: Int)
    setField canvas ("width" :: MisoString) width
    setField canvas ("height" :: MisoString) height
    offscreen <- canvas # ("getContext" :: MisoString) $ (["2d"] :: [MisoString])
    let xform = XForm x0 y0 scale
    fast <- graphBatchAvailable
    if fast
        then do
            painted <- runReaderT (drawBaseFast palette layout tagsShown xform recordColors tagColors) offscreen
            unless painted $ do
                graphPerfMark "base-fallback"
                runReaderT
                    ( do
                        Canvas.clearRect (0, 0, fromIntegral width, fromIntegral height)
                        drawBase palette layout tagsShown xform recordColors tagColors
                    )
                    offscreen
        else do
            graphPerfMark "base-no-helper"
            runReaderT (drawBase palette layout tagsShown xform recordColors tagColors) offscreen
    let cached =
            BaseCache
                { bcCanvas = canvas
                , bcKey = cacheKeyFor layout palette tagsShown viewKey
                , bcScale = scale
                , bcX0 = x0
                , bcY0 = y0
                , bcWidth = width
                , bcHeight = height
                }
    window' <- jsg ("window" :: MisoString)
    holder <- create
    setField holder ("key" :: MisoString) (bcKey cached)
    setField holder ("canvas" :: MisoString) (bcCanvas cached)
    setField holder ("scale" :: MisoString) (bcScale cached)
    setField holder ("x0" :: MisoString) (bcX0 cached)
    setField holder ("y0" :: MisoString) (bcY0 cached)
    setField holder ("width" :: MisoString) (bcWidth cached)
    setField holder ("height" :: MisoString) (bcHeight cached)
    setField window' cacheGlobal holder
    graphPerfMark "base-end"
    pure (Just cached)

-- ------------------------------------------------------------ base paint ---

drawBase :: Palette -> GraphLayout -> Bool -> XForm -> IM.IntMap Text -> M.Map Text Text -> Canvas ()
drawBase palette layout tagsShown xform recordColors tagColors = do
    Canvas.globalAlpha 1
    drawBaseLinks palette layout tagsShown xform
    drawBaseRecords palette layout xform recordColors
    when tagsShown (drawBaseTags palette layout xform tagColors)

drawBaseLinks :: Palette -> GraphLayout -> Bool -> XForm -> Canvas ()
drawBaseLinks palette layout tagsShown xform = do
    Canvas.globalAlpha 0.72
    Canvas.strokeStyle (Canvas.color (pRule palette))
    Canvas.lineWidth 1
    Canvas.beginPath ()
    forM_ (glLinks layout) $ \(source, target) ->
        case (IM.lookup source (glPos layout), IM.lookup target (glPos layout)) of
            (Just (x1, y1), Just (x2, y2)) -> do
                let (px1, py1) = xformPoint xform x1 y1
                    (px2, py2) = xformPoint xform x2 y2
                Canvas.moveTo (px1, py1)
                Canvas.lineTo (px2, py2)
            _ -> pure ()
    Canvas.stroke ()
    when tagsShown $ do
        Canvas.globalAlpha 0.32
        Canvas.strokeStyle (Canvas.color (pMuted palette))
        Canvas.beginPath ()
        forM_ (glMembers layout) $ \(record, tagKey) ->
            case (IM.lookup record (glPos layout), IM.lookup tagKey (glPos layout)) of
                (Just (x1, y1), Just (x2, y2)) -> do
                    let (px1, py1) = xformPoint xform x1 y1
                        (px2, py2) = xformPoint xform x2 y2
                    Canvas.moveTo (px1, py1)
                    Canvas.lineTo (px2, py2)
                _ -> pure ()
        Canvas.stroke ()
    Canvas.globalAlpha 1

drawBaseRecords :: Palette -> GraphLayout -> XForm -> IM.IntMap Text -> Canvas ()
drawBaseRecords palette layout xform recordColors = do
    -- A filled ink dot reads after the bitmap is minified; an ink hairline
    -- around a card fill disappears at overview scale.
    Canvas.fillStyle (Canvas.color (pInk palette))
    Canvas.globalAlpha 0.82
    Canvas.beginPath ()
    forM_ (IM.toList (glPos layout)) $ \(key, (x, y)) ->
        when (not (isTagKey key) && IM.notMember key recordColors) $
            addCircle xform x y (nodeRadius layout key)
    Canvas.fill ()
    forM_ (M.toAscList (groupColorsByKey (glPos layout) recordColors)) $ \(color, keys) -> do
        Canvas.fillStyle (Canvas.color (colorOfHex color))
        Canvas.globalAlpha 0.92
        Canvas.beginPath ()
        forM_ keys $ \key ->
            case IM.lookup key (glPos layout) of
                Just (x, y) -> addCircle xform x y (nodeRadius layout key)
                Nothing -> pure ()
        Canvas.fill ()
    Canvas.globalAlpha 1

drawBaseTags :: Palette -> GraphLayout -> XForm -> M.Map Text Text -> Canvas ()
drawBaseTags palette layout xform tagColors = do
    let colored = tagColorKeys layout tagColors
    Canvas.fillStyle (Canvas.color (pAccent palette))
    Canvas.globalAlpha 0.92
    Canvas.beginPath ()
    forM_ (IM.toList (glPos layout)) $ \(key, (x, y)) ->
        when (isTagKey key && IM.notMember key colored) $
            addCircle xform x y (nodeRadius layout key)
    Canvas.fill ()
    forM_ (M.toAscList (groupColorsByKey (glPos layout) colored)) $ \(color, keys) -> do
        Canvas.fillStyle (Canvas.color (colorOfHex color))
        Canvas.globalAlpha 0.95
        Canvas.beginPath ()
        forM_ keys $ \key ->
            case IM.lookup key (glPos layout) of
                Just (x, y) -> addCircle xform x y (nodeRadius layout key)
                Nothing -> pure ()
        Canvas.fill ()
    Canvas.globalAlpha 1

-- | A stored @#rrggbb@ palette entry as a canvas color.
colorOfHex :: Text -> Color
colorOfHex raw = hex (ms (T.unpack (T.dropWhile (== '#') raw)))

{- | Group colored node keys by their color, skipping nodes the layout does not
draw. Built once per base/detail paint, never per interaction frame.
-}
groupColorsByKey :: IM.IntMap (Double, Double) -> IM.IntMap Text -> M.Map Text [Int]
groupColorsByKey positions colorMap =
    IM.foldlWithKey' step M.empty colorMap
  where
    step acc key color
        | IM.member key positions = M.insertWith (flip (++)) color [key] acc
        | otherwise = acc

-- | Tag names are stored by key, so resolve the tag color map first.
tagColorKeys :: GraphLayout -> M.Map Text Text -> IM.IntMap Text
tagColorKeys layout colorByName =
    IM.foldlWithKey' step IM.empty (glPos layout)
  where
    step acc key _
        | not (isTagKey key) = acc
        | otherwise = case IM.lookup key (glTags layout) of
            Just (name, _) -> case M.lookup name colorByName of
                Just color -> IM.insert key color acc
                Nothing -> acc
            Nothing -> acc

{- | Node keys in the same order as 'glRecordPoints' / 'glTagPoints' (ascending
node key, subset-filtered).
-}
pointKeys :: GraphLayout -> Bool -> [Int]
pointKeys layout wantTags =
    [ key
    | key <- IM.keys (glPos layout)
    , isTagKey key == wantTags
    ]

addCircle :: XForm -> Double -> Double -> Double -> Canvas ()
addCircle xform x y radius = do
    let (px, py) = xformPoint xform x y
        pxRadius = radius * xfScale xform
    Canvas.moveTo (px + pxRadius, py)
    Canvas.arc (px, py, max 0.4 pxRadius, 0, 2 * pi)

-- --------------------------------------------------------- fast painters ---

paintAll :: [Canvas Bool] -> Canvas Bool
paintAll = foldM (\ok action -> if ok then action else pure False) True

strokeLayer :: MisoString -> MisoString -> Double -> Double -> Canvas Bool
strokeLayer packed color alpha width =
    paintLayer "stroke" packed color alpha width

fillLayer :: MisoString -> MisoString -> Double -> Canvas Bool
fillLayer packed color alpha =
    paintLayer "fill" packed color alpha 1

{- | The batched cache painter. It keeps the old draw order (links, members,
plain records, colour-group records, plain tags, colour-group tags) so the
bitmap is pixel-compatible with the fallback path.
-}
drawBaseFast :: Palette -> GraphLayout -> Bool -> XForm -> IM.IntMap Text -> M.Map Text Text -> Canvas Bool
drawBaseFast palette layout tagsShown xform recordColors tagColors =
    paintAll $
        [ strokeLayer
            (packBuilder (foldMap (baseSegmentB xform layout) (glLinks layout)))
            (renderColor (pRule palette))
            0.72
            1
        ]
            ++ [ strokeLayer
                    (packBuilder (foldMap (baseSegmentB xform layout) (glMembers layout)))
                    (renderColor (pMuted palette))
                    0.32
                    1
               | tagsShown
               ]
            ++ [ fillLayer
                    (packBuilder (foldMap (baseCircleB xform layout) plainRecordKeys))
                    (renderColor (pInk palette))
                    0.82
               ]
            ++ [ fillLayer
                    (packBuilder (foldMap (baseCircleB xform layout) keys))
                    (renderColor (colorOfHex color))
                    0.92
               | (color, keys) <- M.toAscList (groupColorsByKey (glPos layout) recordColors)
               ]
            ++ [ fillLayer
                    (packBuilder (foldMap (baseCircleB xform layout) plainTagKeys))
                    (renderColor (pAccent palette))
                    0.92
               | tagsShown
               ]
            ++ [ fillLayer
                    (packBuilder (foldMap (baseCircleB xform layout) keys))
                    (renderColor (colorOfHex color))
                    0.95
               | tagsShown
               , (color, keys) <- M.toAscList (groupColorsByKey (glPos layout) tagColorKeysByKey)
               ]
  where
    tagColorKeysByKey = tagColorKeys layout tagColors
    recordKeys = [key | key <- IM.keys (glPos layout), not (isTagKey key)]
    plainRecordKeys = [key | key <- recordKeys, IM.notMember key recordColors]
    tagKeys = [key | key <- IM.keys (glPos layout), isTagKey key]
    plainTagKeys = [key | key <- tagKeys, IM.notMember key tagColorKeysByKey]

{- | The batched detail/local painter. It draws every visible primitive in one
pass; the old chunk plan remains the fallback.
-}
drawDetailFast :: Palette -> GraphLayout -> GraphView -> Bool -> IM.IntMap Text -> M.Map Text Text -> Canvas Bool
drawDetailFast palette layout view tagsShown recordColors tagColors = do
    Canvas.globalAlpha 1
    Canvas.fillStyle (Canvas.color (pPaper palette))
    Canvas.fillRect (0, 0, gvWidth view, gvHeight view)
    paintAll $
        [ strokeLayer
            (packBuilder (foldMap (detailSegmentB view) visibleLinks))
            (renderColor (pRule palette))
            0.72
            1
        ]
            ++ [ strokeLayer
                    (packBuilder (foldMap (detailSegmentB view) visibleMembers))
                    (renderColor (pMuted palette))
                    0.32
                    1
               | tagsShown
               ]
            ++ [ fillLayer
                    (packBuilder (foldMap (detailCircleKeyB view layout) plainRecordKeys))
                    (renderColor (pInk palette))
                    0.82
               ]
            ++ [ fillLayer
                    (packBuilder (foldMap (detailCircleKeyB view layout) (visibleKeys keys)))
                    (renderColor (colorOfHex color))
                    0.95
               | (color, keys) <- M.toAscList (groupColorsByKey (glPos layout) recordColors)
               ]
            ++ [ fillLayer
                    (packBuilder (foldMap (detailCircleKeyB view layout) plainTagKeys))
                    (renderColor (pAccent palette))
                    0.92
               | tagsShown
               ]
            ++ [ fillLayer
                    (packBuilder (foldMap (detailCircleKeyB view layout) (visibleKeys keys)))
                    (renderColor (colorOfHex color))
                    0.95
               | tagsShown
               , (color, keys) <- M.toAscList (groupColorsByKey (glPos layout) tagColorKeysByKey)
               ]
  where
    (minX, minY, maxX, maxY) = visibleWorld view
    segmentVisible (x1, y1, x2, y2) =
        max x1 x2 >= minX
            && min x1 x2 <= maxX
            && max y1 y2 >= minY
            && min y1 y2 <= maxY
    pointVisible key =
        case IM.lookup key (glPos layout) of
            Just (x, y) ->
                let radius = nodeRadius layout key
                 in pointWithin (minX - radius) (minY - radius) (maxX + radius) (maxY + radius) (x, y)
            Nothing -> False
    visibleKeys keys = [key | key <- keys, pointVisible key]
    visibleLinks = filter segmentVisible (glLinkSegments layout)
    visibleMembers = filter segmentVisible (glMemberSegments layout)
    tagColorKeysByKey = tagColorKeys layout tagColors
    recordKeys = [key | key <- pointKeys layout False, pointVisible key]
    tagKeys = [key | key <- pointKeys layout True, pointVisible key]
    plainRecordKeys = [key | key <- recordKeys, IM.notMember key recordColors]
    plainTagKeys = [key | key <- tagKeys, IM.notMember key tagColorKeysByKey]

detailCircleKeyB :: GraphView -> GraphLayout -> Int -> BB.Builder
detailCircleKeyB view layout key =
    case IM.lookup key (glPos layout) of
        Just (x, y) -> detailCircleB view x y (nodeRadius layout key)
        Nothing -> mempty

{- | Filter overlay in one stroke + one fill. Labels still use the old
screen-space pass, which is capped at 60.
-}
drawFilterOverlayFast :: Palette -> GraphLayout -> GraphView -> GraphMatches -> Bool -> Canvas ()
drawFilterOverlayFast palette layout view matches tagsShown = do
    drawVeil palette view
    let matchIds = gmIds matches
        tagIds = gmTags matches
        (minX, minY, maxX, maxY) = visibleWorld view
        inView (x, y) = pointWithin minX minY maxX maxY (x, y)
        scale = gvScale view
        matchedLinks =
            [ (x1, y1, x2, y2)
            | (source, target) <- glLinks layout
            , IS.member source matchIds
            , IS.member target matchIds
            , Just a <- [IM.lookup source (glPos layout)]
            , let (x1, y1) = a
            , Just b <- [IM.lookup target (glPos layout)]
            , let (x2, y2) = b
            ]
        recordKeys =
            take
                2000
                [ key
                | key <- IS.toList matchIds
                , Just (x, y) <- [IM.lookup key (glPos layout)]
                , inView (x, y)
                ]
        tagKeys =
            [ key
            | key <- IS.toList tagIds
            , Just (x, y) <- [IM.lookup key (glPos layout)]
            , inView (x, y)
            ]
        recordCircle key =
            case IM.lookup key (glPos layout) of
                Just (x, y) ->
                    let radius = max 2.4 (nodeRadius layout key * scale)
                     in detailCircleB view x y (radius / max 1e-9 scale)
                Nothing -> mempty
        tagCircle key =
            case IM.lookup key (glPos layout) of
                Just (x, y) ->
                    let radius = max 2 (nodeRadius layout key * scale)
                     in detailCircleB view x y (radius / max 1e-9 scale)
                Nothing -> mempty
    _ <- strokeLayer (packBuilder (foldMap (detailSegmentB view) matchedLinks)) (renderColor (pAccent palette)) 0.45 1
    _ <- fillLayer (packBuilder (foldMap recordCircle recordKeys)) (renderColor (pAccent palette)) 1
    _ <-
        if tagsShown
            then fillLayer (packBuilder (foldMap tagCircle tagKeys)) (renderColor (pAccent palette)) 0.9
            else pure True
    drawMatchLabels palette layout view matchIds

{- | A rough rectangle used for label collision. Text width is estimated from
the monospace glyph count; measuring every label would cost an FFI roundtrip
per frame.
-}
data LabelBox = LabelBox Double Double Double Double

collides :: LabelBox -> [LabelBox] -> Bool
collides (LabelBox left top right bottom) =
    any
        ( \(LabelBox otherLeft otherTop otherRight otherBottom) ->
            left < otherRight
                && right > otherLeft
                && top < otherBottom
                && bottom > otherTop
        )

labelFont :: Double -> MisoString
labelFont size = ms ("500 " <> show (round (max 6 size) :: Int) <> "px 'IBM Plex Mono', ui-monospace, monospace")

labelText :: Text -> MisoString
labelText = ms . T.unpack

{- | Label budgets for one zoom level. Tags are drawn first; the record budget
takes whatever remains of the total cap.
-}
data LabelPolicy = LabelPolicy
    { lpTagLimit :: Int
    , lpRecordLimit :: Int
    , lpAlpha :: Double
    }
    deriving (Eq, Show)

-- | The hard cap across both label layers.
labelTotalCap :: Int
labelTotalCap = 240

{- | Level of detail for the label layer. The budgets follow the zoom ratio
against the fit scale: 40/60 at the overview, then 60/80, 60/120 and finally
80/160 tags/records. The extra labels fade in between 1.1x and 1.5x fit.
'LabelTags' keeps tag labels only; 'LabelNone' hides the layer.
-}
labelPolicy :: LabelMode -> Double -> LabelPolicy
labelPolicy mode zoomRatio = case mode of
    LabelNone -> LabelPolicy 0 0 1
    LabelTags -> LabelPolicy 80 0 1
    LabelAuto
        | zoomRatio < 1.5 -> LabelPolicy 40 60 (fade 0.92)
        | zoomRatio < 2.2 -> LabelPolicy 60 80 1
        | zoomRatio < 3.0 -> LabelPolicy 60 120 1
        | otherwise -> LabelPolicy 80 160 1
  where
    fade base
        | zoomRatio <= 1.1 = base
        | zoomRatio >= 1.5 = 1
        | otherwise = base + (1 - base) * ((zoomRatio - 1.1) / 0.4)

data LabelItem = LabelItem
    { liLabel :: Text
    , liIsTag :: Bool
    , liX :: Double
    , liBaseline :: Double
    , liSize :: Double
    }

{- | The pure label plan: candidates in priority order, visible in the plate,
with rectangle collision against the labels already placed. The painter and
the status readout both use this plan, so the readout counts what is drawn.
-}
labelItems :: GraphLayout -> GraphView -> Bool -> LabelMode -> [LabelItem]
labelItems layout view tagsShown mode = take labelTotalCap (tagItems ++ recordItems)
  where
    ratio = gvScale view / max 1e-9 (gvFit view)
    policy = labelPolicy mode ratio
    (minX, minY, maxX, maxY) = visibleWorld view
    visible (x, y) = pointWithin minX minY maxX maxY (x, y)
    (tagBoxes, tagItemsRev) =
        if tagsShown
            then layer True 12 (lpTagLimit policy) (glTagOrder layout) []
            else ([], [])
    (_, recordItemsRev) = layer False 11 (lpRecordLimit policy) (glRecordOrder layout) tagBoxes
    tagItems = reverse tagItemsRev
    recordItems = reverse recordItemsRev
    layer isTag size limit order placed =
        foldl' step (placed, []) (take limit order)
      where
        step (boxes, items) key =
            case (IM.lookup key (glPos layout), nodeLabel layout key) of
                (Just point, Just label)
                    | not (T.null label) && visible point ->
                        let (px, py) = worldToScreen view point
                            radius = nodeRadius layout key * gvScale view
                            labelValue = T.take 26 label
                            textWidth = fromIntegral (T.length labelValue) * size * 0.62
                            baseline = py + radius + size * 1.15
                            box =
                                LabelBox
                                    (px - textWidth / 2)
                                    (baseline - size)
                                    (px + textWidth / 2)
                                    (baseline + size * 0.45)
                            item = LabelItem labelValue isTag px baseline size
                         in if collides box boxes
                                then (boxes, items)
                                else (box : boxes, item : items)
                _ -> (boxes, items)

-- | How many labels the current view and mode draw.
labelCount :: GraphLayout -> GraphView -> Bool -> LabelMode -> Int
labelCount layout view tagsShown mode = length (labelItems layout view tagsShown mode)

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

{- | The label layer: a screen-space pass on every frame so labels stay at the
same readable size whether the graph is at overview or zoomed.
-}
drawLabels :: Palette -> GraphLayout -> GraphView -> Bool -> LabelMode -> Canvas ()
drawLabels palette layout view tagsShown mode = do
    let ratio = gvScale view / max 1e-9 (gvFit view)
        alpha = lpAlpha (labelPolicy mode ratio)
        items = labelItems layout view tagsShown mode
    Canvas.textAlign Canvas.TextAlignCenter
    Canvas.textBaseline Canvas.TextBaselineMiddle
    Canvas.globalAlpha alpha
    Canvas.strokeStyle (Canvas.color (pPaper palette))
    Canvas.lineWidth 3
    foldM_ drawOne (Nothing, Nothing) items
    Canvas.globalAlpha 1
  where
    drawOne (lastSize, lastTag) item = do
        let size = round (liSize item) :: Int
            isTag = liIsTag item
            value = labelText (liLabel item)
        when (lastSize /= Just size) $
            Canvas.font (labelFont (fromIntegral size))
        when (lastTag /= Just isTag) $
            Canvas.fillStyle (Canvas.color (if isTag then pMuted palette else pInk palette))
        Canvas.strokeText (value, liX item, liBaseline item)
        Canvas.fillText (value, liX item, liBaseline item)
        pure (Just size, Just isTag)

drawScreenLabels ::
    Palette ->
    GraphLayout ->
    GraphView ->
    ((Double, Double) -> Bool) ->
    Bool ->
    Double ->
    Int ->
    [Int] ->
    [LabelBox] ->
    Canvas [LabelBox]
drawScreenLabels palette layout view visible isTag size limit order placed =
    foldM step placed (take limit order)
  where
    step boxes key =
        case (IM.lookup key (glPos layout), nodeLabel layout key) of
            (Just point, Just label) | not (T.null label) && visible point -> do
                let (px, py) = worldToScreen view point
                    radius = nodeRadius layout key * gvScale view
                    textWidth = fromIntegral (T.length (T.take 26 label)) * size * 0.62
                    baseline = py + radius + size * 1.15
                    box = LabelBox (px - textWidth / 2) (baseline - size) (px + textWidth / 2) (baseline + size * 0.45)
                if collides box boxes
                    then pure boxes
                    else do
                        Canvas.strokeStyle (Canvas.color (pPaper palette))
                        Canvas.lineWidth 3
                        Canvas.strokeText (labelText (T.take 26 label), px, baseline)
                        Canvas.fillStyle (Canvas.color (if isTag then pMuted palette else pInk palette))
                        Canvas.fillText (labelText (T.take 26 label), px, baseline)
                        pure (box : boxes)
            _ -> pure boxes

lineBetween :: GraphView -> (Double, Double) -> (Double, Double) -> Canvas ()
lineBetween view a b = do
    let (x1, y1) = worldToScreen view a
        (x2, y2) = worldToScreen view b
    Canvas.moveTo (x1, y1)
    Canvas.lineTo (x2, y2)

visibleWorld :: GraphView -> (Double, Double, Double, Double)
visibleWorld view = (minX, minY, maxX, maxY)
  where
    (minX, minY) = screenToWorld view (0, 0)
    (maxX, maxY) = screenToWorld view (gvWidth view, gvHeight view)

pointWithin :: Double -> Double -> Double -> Double -> (Double, Double) -> Bool
pointWithin minX minY maxX maxY (x, y) =
    x >= minX && x <= maxX && y >= minY && y <= maxY

-- -------------------------------------------------------------- overlays ---

drawVeil :: Palette -> GraphView -> Canvas ()
drawVeil palette view = do
    Canvas.fillStyle (Canvas.color (pVeil palette))
    Canvas.fillRect (0, 0, gvWidth view, gvHeight view)

{- | The filter accent overlay: matching records (and matching tags) are drawn
over the veil. The base bitmap is untouched, so the cost is proportional to the
match set, not the library.
-}
drawFilterOverlay :: Palette -> GraphLayout -> GraphView -> GraphMatches -> Bool -> Canvas ()
drawFilterOverlay palette layout view matches tagsShown = do
    fast <- liftIO graphBatchAvailable
    if fast
        then drawFilterOverlayFast palette layout view matches tagsShown
        else drawFilterOverlaySlow palette layout view matches tagsShown

drawFilterOverlaySlow :: Palette -> GraphLayout -> GraphView -> GraphMatches -> Bool -> Canvas ()
drawFilterOverlaySlow palette layout view matches tagsShown = do
    drawVeil palette view
    let matchIds = gmIds matches
        tagIds = gmTags matches
        (minX, minY, maxX, maxY) = visibleWorld view
        inView (x, y) = pointWithin minX minY maxX maxY (x, y)
        scale = gvScale view
    Canvas.globalAlpha 0.45
    Canvas.strokeStyle (Canvas.color (pAccent palette))
    Canvas.lineWidth 1
    Canvas.beginPath ()
    forM_ (glLinks layout) $ \(source, target) ->
        when (IS.member source matchIds && IS.member target matchIds) $
            case (IM.lookup source (glPos layout), IM.lookup target (glPos layout)) of
                (Just a, Just b) -> lineBetween view a b
                _ -> pure ()
    Canvas.stroke ()
    Canvas.globalAlpha 1
    Canvas.fillStyle (Canvas.color (pAccent palette))
    Canvas.beginPath ()
    forM_ (take 2000 (IS.toList matchIds)) $ \recordKey ->
        case IM.lookup recordKey (glPos layout) of
            Just (x, y) | inView (x, y) -> do
                let (px, py) = worldToScreen view (x, y)
                    radius = max 2.4 (nodeRadius layout recordKey * scale)
                Canvas.moveTo (px + radius, py)
                Canvas.arc (px, py, radius, 0, 2 * pi)
            _ -> pure ()
    Canvas.fill ()
    when tagsShown $ do
        Canvas.globalAlpha 0.9
        Canvas.beginPath ()
        forM_ (IS.toList tagIds) $ \tagKey ->
            case IM.lookup tagKey (glPos layout) of
                Just (x, y) | inView (x, y) -> do
                    let (px, py) = worldToScreen view (x, y)
                        radius = max 2 (nodeRadius layout tagKey * scale)
                    Canvas.moveTo (px + radius, py)
                    Canvas.arc (px, py, radius, 0, 2 * pi)
                _ -> pure ()
        Canvas.fill ()
        Canvas.globalAlpha 1
    drawMatchLabels palette layout view matchIds

drawMatchLabels :: Palette -> GraphLayout -> GraphView -> IS.IntSet -> Canvas ()
drawMatchLabels palette layout view matchIds = do
    let (minX, minY, maxX, maxY) = visibleWorld view
        visible (x, y) = pointWithin minX minY maxX maxY (x, y)
        candidates =
            take
                60
                [ recordKey
                | recordKey <- glRecordOrder layout
                , IS.member recordKey matchIds
                ]
    Canvas.font (labelFont 11)
    Canvas.textAlign Canvas.TextAlignCenter
    Canvas.textBaseline Canvas.TextBaselineMiddle
    _ <- drawScreenLabels palette layout view visible False 11 60 candidates []
    pure ()

{- | Hover, selection and focus rings. They are cheap screen-space strokes and
never enter the base bitmap.
-}
drawEmphasis :: Palette -> GraphLayout -> GraphView -> Maybe Int -> Maybe Int -> Maybe Int -> Canvas ()
drawEmphasis palette layout view hover selected focusKey = do
    forM_ hover (ring (pMuted palette) 4)
    forM_ focusKey (ring (pAccent palette) 5)
    forM_ selected (ring (pAccent palette) 6)
    forM_ selected drawPinnedLabel
    forM_ hover drawPinnedLabel
  where
    ring colour extra key =
        case IM.lookup key (glPos layout) of
            Nothing -> pure ()
            Just (x, y) -> do
                let (px, py) = worldToScreen view (x, y)
                    radius = max 6 (nodeRadius layout key * gvScale view + extra)
                Canvas.strokeStyle (Canvas.color colour)
                Canvas.lineWidth 1.6
                Canvas.beginPath ()
                Canvas.moveTo (px + radius, py)
                Canvas.arc (px, py, radius, 0, 2 * pi)
                Canvas.stroke ()
    drawPinnedLabel key =
        case (IM.lookup key (glPos layout), nodeLabel layout key) of
            (Just (x, y), Just label) | not (T.null label) -> do
                let (px, py) = worldToScreen view (x, y)
                    radius = nodeRadius layout key * gvScale view
                Canvas.font (labelFont 12)
                Canvas.textAlign Canvas.TextAlignCenter
                Canvas.textBaseline Canvas.TextBaselineMiddle
                Canvas.strokeStyle (Canvas.color (pPaper palette))
                Canvas.lineWidth 3
                let value = labelText (T.take 32 label)
                Canvas.strokeText (value, px, py + radius + 14)
                Canvas.fillStyle (Canvas.color (pAccent palette))
                Canvas.fillText (value, px, py + radius + 14)
            _ -> pure ()
