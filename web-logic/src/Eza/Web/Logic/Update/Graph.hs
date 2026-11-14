{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Part of the client update function; see "Eza.Web.Update".
module Eza.Web.Logic.Update.Graph (
    applyGraphScope,
    enterGraphRoute,
    fitActiveView,
    focusGraphPlate,
    graphClick,
    graphEscape,
    graphOpenSelected,
    graphPan,
    graphZoom,
    handle,
    hydrateWire,
    layoutMissingMessage,
    markGraphMoving,
    resolveLocalRoot,
    sameGraphLayout,
    visibleHit,
    wirePresetDiffers,
) where

import Control.Monad
import qualified Data.IntMap.Strict as IM
import Data.Maybe
import qualified Data.Text as T
import Eza.Web.Logic.Effect (nextRequestId, requestIsCurrent)

import Data.Text (Text)
import Eza.GraphLayout
import Eza.Types
import qualified Eza.View as EV
import Eza.Web.Logic.Browser
import Eza.Web.Logic.Error
import Eza.Web.Logic.Graph (GraphDrag (..), GraphView (..), emptyMatches)
import Eza.Web.Logic.Graph.Geometry
import Eza.Web.Logic.Model
import Eza.Web.Logic.Requests
import Eza.Web.Logic.Route (Route (..), isGraphRoute)
import Eza.Web.Logic.Update.Common
import Eza.Web.Logic.Update.Monad (Update, dispatch, get)
import Eza.Web.Logic.Update.ViewDefs (activeGraphDefinition, recomputeGraphColors)

graphZoom :: Double -> Update ()
graphZoom factor = do
    m <- get
    case activeGraphLayout m of
        Nothing -> pure ()
        Just layout -> do
            let view = zoomViewCenter layout (mGraphView m) factor
            putModel
                ( \model ->
                    model{gGraph = (gGraph model){grGraphView = view, grGraphSettled = False, grGraphSettleEpoch = nextRequestId (mGraphSettleEpoch model), grGraphDetailPhase = 0}}
                )
            scheduleGraphSettle

{- | A pointer that went down and up without moving is a click: a record
selects, a tag opens the ledger filtered by @tag:@, and empty plate clears.
-}
graphClick :: Model -> Double -> Double -> Update ()
graphClick m x y =
    case activeGraphLayout m of
        Nothing -> pure ()
        Just layout -> case visibleHit m (nodeAt layout (mGraphView m) (x, y)) of
            Nothing ->
                putModel (\model -> model{gGraph = (gGraph model){grGraphSelected = Nothing, grGraphFocus = Nothing}})
            Just key
                | isTagKey key -> case IM.lookup key (glTags layout) of
                    Just (name, _) -> dispatch (FilterByQuery ("tag:" <> name))
                    Nothing -> pure ()
                | otherwise ->
                    dispatch (Navigate (Bookmark key))

{- | Focus the plate once it has painted, so the keyboard shortcuts work
immediately after a visit. @preventScroll@ keeps the panel from jumping to
the canvas on a phone, where focus() would otherwise scroll the title and the
filter line out of view.

The canvas only exists after the first layout paints, and on a large library
that can arrive several animation frames after the graph payload. A single
timer used to give up when the element was not mounted yet; retry over a few
frames instead, like 'measureGraphCanvas'.
-}
focusGraphPlate :: Model -> Update ()
focusGraphPlate m =
    when
        (isGraphRoute (mRoute m) && T.null (T.strip ((mGraphFilter m))))
        focusGraphCanvas

visibleHit :: Model -> Maybe Int -> Maybe Int
visibleHit _ Nothing = Nothing
visibleHit m (Just key)
    | not (mGraphTagsShown m) && isTagKey key = Nothing
    | otherwise = Just key

{- | Shown when the graph payload has no matching server layout. The client
never computes a layout itself: the server is the only layout producer.
-}
layoutMissingMessage :: Text
layoutMissingMessage =
    "The server sent no layout for this library. Reload the page to ask for one."

{- | Validate and hydrate a server layout. The revision and the two position
arrays must line up with the graph payload, otherwise the caller shows a
visible error instead of painting a client-computed layout.
-}
hydrateWire :: GraphData -> GraphLayoutWire -> Maybe GraphLayout
hydrateWire graph wire
    | glwRevision wire /= gdRevision graph = Nothing
    | length (glwTags wire) /= length (gdTags graph) = Nothing
    | length (glwRecords wire) /= length (gdRecords graph) = Nothing
    | otherwise =
        Just
            ( hydrateLayout
                graph
                LayoutPositions
                    { -- Core hydrates tag positions by tag index and record
                      -- positions by bookmark id, so apply the node-key mapping
                      -- only there, never twice.
                      lpTagPositions = IM.fromList (zip [0 :: Int ..] (glwTags wire))
                    , lpRecordPositions =
                        IM.fromList
                            [ (recordKeyOf (grId record), point)
                            | (record, point) <- zip (gdRecords graph) (glwRecords wire)
                            ]
                    , lpBounds =
                        let (minX, minY, maxX, maxY) = glwBounds wire
                         in ((minX, minY), (maxX, maxY))
                    }
            )

-- ------------------------------------------------------------- views glue --

sameGraphLayout :: GraphLayout -> GraphLayout -> Bool
wirePresetDiffers :: Model -> LayoutPreset -> Bool
wirePresetDiffers model preset =
    case mGraphLayoutWire model of
        Just (wirePreset, _) -> wirePreset /= preset
        Nothing -> False
sameGraphLayout left right =
    glPos left == glPos right
        && glRadii left == glRadii right
        && glLinks left == glLinks right
        && glMembers left == glMembers right
        && glTags left == glTags right
        && glRecords left == glRecords right

{- | Load the graph route. Whole mode keeps the cached view; local mode
rebuilds the neighbourhood and fits it before the first paint. A warm route
keeps its layout wire and only refreshes the records; a cold route asks for
the layout first so the first plate is hydrated instead of painted twice.
-}
enterGraphRoute :: Bool -> Maybe Int -> Int -> Update ()
enterGraphRoute localMode root depth = do
    m <- get
    let viewLocalDepth = EV.gvdLocalDepth <$> activeGraphDefinition m
        viewLocal = maybe False isJust viewLocalDepth
        effectiveLocal = localMode || viewLocal
        effectiveDepth = if localMode then max 1 (min 3 depth) else fromMaybe (max 1 (min 3 depth)) (join viewLocalDepth)
    putModel
        ( \x ->
            x
                { gGraph =
                    (gGraph x)
                        { grGraphLoading = case mGraphLayoutWire x of
                            Just (wirePreset, _) | wirePreset == mGraphPreset x && isJust (mGraphLayout x) -> False
                            _ -> isNothing (mGraphLayout x)
                        , grGraphError = Nothing
                        , grGraphLocal = effectiveLocal
                        , grGraphLocalDepth = effectiveDepth
                        , grGraphLocalRoot = root
                        , grGraphDetailPhase = 0
                        , grGraphSettled = False
                        , grGraphSettleEpoch = nextRequestId (mGraphSettleEpoch x)
                        , grGraphHover = Nothing
                        }
                }
        )
    putModel (\x -> if effectiveLocal then fitActiveView (applyGraphScope x) else applyGraphScope x)
    current <- get
    let preset = mGraphPreset current
        cachedWire = case mGraphLayoutWire current of
            Just (wirePreset, _) | wirePreset == preset -> True
            _ -> False
    if cachedWire
        then fetchGraph GraphLoaded GraphFailed
        else fetchGraphLayout preset (GraphLayoutLoaded preset) GraphLayoutFailed
    measureGraphCanvas

{- | Resolve the row that roots local mode: the explicit root when it still
exists, else the selected record, else the focused record, else the
highest-degree record in the whole layout.
-}
resolveLocalRoot :: Model -> GraphLayout -> Maybe Int
resolveLocalRoot m whole =
    case [key | Just key <- [mGraphLocalRoot m, mGraphSelected m, mGraphFocus m], usable key] of
        (key : _) -> Just key
        []
            | (key : _) <- glRecordOrder whole
            , not (isTagKey key) ->
                Just key
            | otherwise -> Nothing
  where
    usable key = not (isTagKey key) && IM.member key (glPos whole)

{- | Rebuild the active derived layout after the scope, root or depth changed.
The whole layout is never rebuilt here, so the 2,500-node local cap is the
only work local mode adds.
-}
applyGraphScope :: Model -> Model
applyGraphScope m =
    case mGraphLayout m of
        Nothing -> m
        Just whole
            | not (mGraphLocal m) ->
                m{gGraph = (gGraph m){grGraphLocalLayout = Nothing, grGraphLocalCapped = False, grGraphMatches = matchOn whole}}
            | otherwise ->
                case resolveLocalRoot m whole of
                    Just root ->
                        case localLayout whole root (mGraphLocalDepth m) of
                            Just (local, capped) ->
                                m{gGraph = (gGraph m){grGraphLocalRoot = Just root, grGraphLocalLayout = Just local, grGraphLocalCapped = capped, grGraphMatches = matchOn local}}
                            Nothing -> emptyScope m
                    Nothing -> emptyScope m
  where
    matchOn layout = matchGraph (T.strip ((mGraphFilter m))) layout
    emptyScope model =
        model{gGraph = (gGraph model){grGraphLocalLayout = Nothing, grGraphLocalCapped = False, grGraphMatches = emptyMatches}}

{- | Fit the plate to the active layout. Used when the scope, root, depth or
preset changes; not on interaction frames.
-}
fitActiveView :: Model -> Model
fitActiveView m =
    case activeGraphLayout m of
        Nothing -> m
        Just layout ->
            let old = mGraphView m
             in m{gGraph = (gGraph m){grGraphView = fitView layout (gvWidth old) (gvHeight old) (gvDpr old), grGraphHover = Nothing, grGraphSettled = False, grGraphSettleEpoch = nextRequestId (mGraphSettleEpoch m), grGraphDetailPhase = 0}}

{- | The view is moving: the plate keeps blitting the world bitmap, and the
screen-resolution detail plate is stale until the gesture stops.
-}
markGraphMoving :: Update ()
markGraphMoving =
    putModel
        ( \m ->
            m{gGraph = (gGraph m){grGraphSettled = False, grGraphSettleEpoch = nextRequestId (mGraphSettleEpoch m), grGraphDetailPhase = 0}}
        )

{- | Arm a settle check for the current view epoch. Timers are never cancelled:
a stale epoch is ignored, so only the timer armed for the last view can build
the detail plate. One timer per gesture event is cheap.
-}
graphEscape :: Model -> Update ()
graphEscape m
    | not (T.null (T.strip ((mGraphFilter m)))) = do
        dispatch (GraphFilterChanged "")
        dispatch GraphFilterSettled
    | otherwise = dispatch GraphClearSelection

{- | Pan the graph from the global keyboard bridge. The canvas is a tab stop,
but the shortcuts run from any non-editable focus on the graph route, so the
panel does not need to keep DOM focus on the canvas to be keyboard driven.
-}
graphPan :: Double -> Double -> Bool -> Update ()
graphPan deltaX deltaY accelerated = do
    m <- get
    case mGraphLayout m of
        Nothing -> pure ()
        Just _ -> do
            let step = if accelerated then 160 else 48
            putModel
                ( \model ->
                    model{gGraph = (gGraph model){grGraphView = panView (deltaX * step, deltaY * step) (mGraphView model), grGraphSettled = False, grGraphSettleEpoch = nextRequestId (mGraphSettleEpoch model), grGraphDetailPhase = 0}}
                )
            scheduleGraphSettle

-- | Enter on the graph opens the selected record, matching a click.
graphOpenSelected :: Model -> Update ()
graphOpenSelected m =
    case mGraphSelected m of
        Just key | not (isTagKey key) -> dispatch (Navigate (Bookmark key))
        _ -> pure ()

{- | Read the canvas box after a render. The element only exists once the graph
layout has painted, so a few short retries cover the first frame.
-}
handle :: Action -> Update ()
handle = \case
    GraphLoaded graph -> do
        m <- get
        case (Just graph == mGraph m, mGraphLayout m) of
            -- A warm return with the same payload keeps the cached bitmap, the
            -- layout and the generation: no 30k-primitive repaint.
            (True, Just _) -> do
                let scoped = applyGraphScope m
                    old = mGraphView scoped
                    view = case (mGraphFocus scoped, activeGraphLayout scoped) of
                        (Just key, Just layout) ->
                            focusView layout key (gvWidth old) (gvHeight old) (gvDpr old)
                        _ -> old
                putModel
                    ( \x ->
                        let scopedNow = applyGraphScope (recomputeGraphColors x{gGraph = (gGraph x){grGraph = Just graph}})
                         in scopedNow{gGraph = (gGraph scopedNow){grGraphView = view, grGraphMatches = mGraphMatches scopedNow, grGraphLoading = False, grGraphError = Nothing, grGraphHover = Nothing, grGraphFocus = if mGraphViewReady x then Nothing else mGraphFocus x}}
                    )
                when (view /= old) (markGraphMoving >> scheduleGraphSettle)
                unless (mGraphViewReady m) (measureGraphCanvas)
                focusGraphPlate m
            _ ->
                let generation = mGraphGen m + 1
                    preset = mGraphPreset m
                    wireMismatch =
                        case mGraphLayoutWire m of
                            Just (wirePreset, wire) -> wirePreset == preset && glwRevision wire /= gdRevision graph
                            Nothing -> False
                    hydrated = do
                        (wirePreset, wire) <- mGraphLayoutWire m
                        if wirePreset == preset && glwRevision wire == gdRevision graph
                            then hydrateWire graph wire
                            else Nothing
                 in case hydrated of
                        -- The server is the only layout producer. A graph payload
                        -- with no matching layout is an error state, never a
                        -- client-side layout build.
                        Nothing ->
                            putModel
                                ( \x ->
                                    x{gGraph = (gGraph x){grGraph = Just graph, grGraphLayout = Nothing, grGraphLoading = False, grGraphError = Just layoutMissingMessage}}
                                )
                        Just hydratedLayout -> do
                            let whole = hydratedLayout{glGen = generation}
                                seeded =
                                    m{gGraph = (gGraph m){grGraph = Just graph, grGraphLayout = Just whole, grGraphLayoutSource = "server", grGraphGen = generation, grGraphLoading = False, grGraphError = Nothing, grGraphHover = Nothing, grGraphSettled = False, grGraphSettleEpoch = nextRequestId (mGraphSettleEpoch m), grGraphDetailPhase = 0}}
                                scoped = applyGraphScope seeded
                                old = mGraphView m
                                view =
                                    case (mGraphFocus scoped, activeGraphLayout scoped) of
                                        (Just key, Just layout) ->
                                            focusView layout key (gvWidth old) (gvHeight old) (gvDpr old)
                                        (_, Just layout)
                                            | mGraphViewReady m ->
                                                resizeView layout (gvWidth old) (gvHeight old) (gvDpr old) old
                                            | otherwise ->
                                                fitView layout (gvWidth old) (gvHeight old) (gvDpr old)
                                        _ -> old
                            putModel
                                ( \x ->
                                    let seededNow =
                                            x{gGraph = (gGraph x){grGraph = Just graph, grGraphLayout = Just whole, grGraphLayoutSource = "server", grGraphGen = generation, grGraphLoading = False, grGraphError = Nothing, grGraphHover = Nothing, grGraphSettled = False, grGraphSettleEpoch = nextRequestId (mGraphSettleEpoch x), grGraphDetailPhase = 0}}
                                        scopedNow = applyGraphScope (recomputeGraphColors seededNow)
                                     in scopedNow{gGraph = (gGraph scopedNow){grGraphView = view, grGraphSelected = mGraphFocus x}}
                                )
                            scheduleGraphSettle
                            when (wireMismatch || wirePresetDiffers m preset) $
                                fetchGraphLayout preset (GraphLayoutLoaded preset) GraphLayoutFailed
                            unless (mGraphViewReady m) (measureGraphCanvas)
                            focusGraphPlate m
    GraphFailed err -> do
        putModel (\x -> x{gGraph = (gGraph x){grGraphLoading = False, grGraphError = Just ((aeMessage err))}})
        -- The error panel is only rendered while the plate has no layout to
        -- fall back on; without this toast a failed refresh of an already
        -- painted graph looked like a successful one.
        handleApiError err
    GraphRefresh -> do
        m <- get
        -- The layout endpoint carries the library revision. Fetch it first:
        -- when the revision still matches, the graph payload and plate are
        -- already current and no repaint is needed; a changed revision makes
        -- GraphLayoutLoaded fetch the graph before hydrating.
        putModel (\x -> x{gGraph = (gGraph x){grGraphLoading = True, grGraphError = Nothing}})
        fetchGraphLayout (mGraphPreset m) (GraphLayoutLoaded (mGraphPreset m)) GraphLayoutFailed
    OpenGraphAt bookmarkId -> do
        m <- get
        putModel (\x -> x{gGraph = (gGraph x){grGraphFocus = Just bookmarkId, grGraphSelected = Just bookmarkId, grGraphError = Nothing}})
        case (mGraphLayout m, mGraphViewReady m) of
            (Just layout, True) -> do
                let old = mGraphView m
                    view = focusView layout bookmarkId (gvWidth old) (gvHeight old) (gvDpr old)
                putModel
                    ( \x ->
                        x{gGraph = (gGraph x){grGraphView = view, grGraphFocus = Nothing, grGraphSettled = False, grGraphSettleEpoch = nextRequestId (mGraphSettleEpoch x), grGraphDetailPhase = 0}}
                    )
                scheduleGraphSettle
                when (not (isGraphRoute (mRoute m))) (dispatch (Navigate Graph))
            _ -> do
                putModel (\x -> x{gGraph = (gGraph x){grGraphLoading = True}})
                when (not (isGraphRoute (mRoute m))) (dispatch (Navigate Graph))
    GraphMeasured width height dpr -> do
        m <- get
        case activeGraphLayout m of
            Nothing -> pure ()
            Just layout
                | width < 40 || height < 40 -> pure ()
                | not (mGraphViewReady m) -> do
                    let view = case mGraphFocus m of
                            Just key -> focusView layout key width height dpr
                            Nothing -> fitView layout width height dpr
                    putModel
                        ( \x ->
                            x{gGraph = (gGraph x){grGraphView = view, grGraphViewReady = True, grGraphFocus = Nothing, grGraphSettled = False, grGraphSettleEpoch = nextRequestId (mGraphSettleEpoch x), grGraphDetailPhase = 0}}
                        )
                    scheduleGraphSettle
                | gvWidth (mGraphView m) /= width
                    || gvHeight (mGraphView m) /= height
                    || gvDpr (mGraphView m) /= dpr -> do
                    let view = resizeView layout width height dpr (mGraphView m)
                    putModel
                        ( \x ->
                            x{gGraph = (gGraph x){grGraphView = view, grGraphSettled = False, grGraphSettleEpoch = nextRequestId (mGraphSettleEpoch x), grGraphDetailPhase = 0}}
                        )
                    scheduleGraphSettle
                | otherwise -> pure ()
    GraphPointerDown x y ->
        putModel (\m -> m{gGraph = (gGraph m){grGraphDrag = Just (GraphDrag (x, y) (x, y) False), grGraphHover = Nothing}})
    GraphPointerMove x y -> do
        m <- get
        case mGraphDrag m of
            Just drag -> do
                let (lastX, lastY) = gdLast drag
                    view = panView (x - lastX, y - lastY) (mGraphView m)
                    moved =
                        gdMoved drag
                            || abs (x - fst (gdStart drag)) > 3
                            || abs (y - snd (gdStart drag)) > 3
                putModel
                    ( \model ->
                        model{gGraph = (gGraph model){grGraphDrag = Just drag{gdLast = (x, y), gdMoved = moved}, grGraphView = view, grGraphHover = Nothing, grGraphSettled = False, grGraphSettleEpoch = nextRequestId (mGraphSettleEpoch model), grGraphDetailPhase = 0}}
                    )
            Nothing -> case activeGraphLayout m of
                Nothing -> pure ()
                Just layout ->
                    let hovered = visibleHit m (nodeAt layout (mGraphView m) (x, y))
                     in unless (hovered == mGraphHover m) $
                            putModel (\model -> model{gGraph = (gGraph model){grGraphHover = hovered}})
    GraphPointerUp x y -> do
        m <- get
        case mGraphDrag m of
            Nothing -> pure ()
            Just drag -> do
                putModel (\model -> model{gGraph = (gGraph model){grGraphDrag = Nothing}})
                when (gdMoved drag) scheduleGraphSettle
                unless (gdMoved drag) (graphClick m x y)
    GraphPointerLeave -> do
        m <- get
        putModel (\x -> x{gGraph = (gGraph x){grGraphDrag = Nothing, grGraphHover = Nothing}})
        when (isJust (mGraphDrag m)) scheduleGraphSettle
    GraphWheel x y delta -> do
        m <- get
        case activeGraphLayout m of
            Nothing -> pure ()
            Just layout -> do
                let factor = max 0.5 (min 2 (exp (negate delta * 0.0015)))
                    view = zoomViewAt layout (mGraphView m) (x, y) factor
                putModel
                    ( \model ->
                        model{gGraph = (gGraph model){grGraphView = view, grGraphHover = Nothing, grGraphSettled = False, grGraphSettleEpoch = nextRequestId (mGraphSettleEpoch model), grGraphDetailPhase = 0}}
                    )
                scheduleGraphSettle
    GraphZoomIn -> graphZoom 1.25
    GraphZoomOut -> graphZoom 0.8
    GraphFit -> do
        m <- get
        case activeGraphLayout m of
            Nothing -> pure ()
            Just layout -> do
                let old = mGraphView m
                    view = fitView layout (gvWidth old) (gvHeight old) (gvDpr old)
                putModel
                    ( \model ->
                        model{gGraph = (gGraph model){grGraphView = view, grGraphHover = Nothing, grGraphSettled = False, grGraphSettleEpoch = nextRequestId (mGraphSettleEpoch model), grGraphDetailPhase = 0}}
                    )
                scheduleGraphSettle
    GraphFilterChanged query -> do
        graphFilterSettle
        putModel (\x -> x{gGraph = (gGraph x){grGraphFilter = query, grGraphMatches = emptyMatches, grGraphFilterTimer = Nothing}})
    GraphFilterArmed timer -> putModel (\x -> x{gGraph = (gGraph x){grGraphFilterTimer = Just timer}})
    GraphFilterSettled -> do
        m <- get
        case activeGraphLayout m of
            Nothing -> putModel (\x -> x{gGraph = (gGraph x){grGraphFilterTimer = Nothing}})
            Just layout ->
                putModel
                    ( \x ->
                        x{gGraph = (gGraph x){grGraphMatches = matchGraph (T.strip ((mGraphFilter x))) layout, grGraphFilterTimer = Nothing}}
                    )
    GraphSettled epoch -> do
        m <- get
        case activeGraphLayout m of
            Just layout
                | isGraphRoute (mRoute m)
                , requestIsCurrent (mGraphSettleEpoch m) epoch
                , not (mGraphSettled m)
                , mGraphDetailPhase m == 0 ->
                    let view = mGraphView m
                        atFit = gvScale view <= 1.1 * gvFit view
                        chunks = detailChunkCount layout
                     in if mGraphLocal m || atFit || chunks <= 0
                            then putModel (\x -> x{gGraph = (gGraph x){grGraphSettled = True}})
                            else do
                                putModel
                                    ( \x ->
                                        x{gGraph = (gGraph x){grGraphSettled = False, grGraphDetailPhase = 1, grGraphDetailChunks = chunks}}
                                    )
                                scheduleGraphDetailStep epoch 1
            _ -> pure ()
    GraphDetailStep epoch expected -> do
        m <- get
        when
            ( isGraphRoute (mRoute m)
                && isJust (activeGraphLayout m)
                && not (mGraphLocal m)
                && requestIsCurrent (mGraphSettleEpoch m) epoch
                && mGraphDetailPhase m == expected
            )
            ( if expected >= mGraphDetailChunks m
                then putModel (\x -> x{gGraph = (gGraph x){grGraphSettled = True, grGraphDetailPhase = 0}})
                else do
                    putModel (\x -> x{gGraph = (gGraph x){grGraphDetailPhase = expected + 1}})
                    scheduleGraphDetailStep epoch (expected + 1)
            )
    GraphTagsToggled -> do
        putModel
            ( \m ->
                m{gGraph = (gGraph m){grGraphTagsShown = not (mGraphTagsShown m), grGraphSettled = False, grGraphSettleEpoch = nextRequestId (mGraphSettleEpoch m), grGraphDetailPhase = 0}}
            )
        scheduleGraphSettle
    GraphLayoutLoaded preset wire -> do
        putModel (\x -> x{gGraph = (gGraph x){grGraphLayoutWire = Just (preset, wire)}})
        m <- get
        when (preset /= mGraphPreset m && isNothing (mGraph m)) $
            -- A default view or a preset change landed while this request was
            -- in flight. Fetch the current preset; the stale wire is kept for
            -- a later switch back.
            fetchGraphLayout (mGraphPreset m) (GraphLayoutLoaded (mGraphPreset m)) GraphLayoutFailed
        when (preset == mGraphPreset m) $
            case mGraph m of
                -- Layout first on a cold route. The graph request follows the
                -- known revision, so the first plate is hydrated rather than
                -- built locally and then thrown away.
                Nothing -> do
                    putModel (\x -> x{gGraph = (gGraph x){grGraphLoading = True}})
                    fetchGraph GraphLoaded GraphFailed
                Just graph
                    | gdRevision graph /= glwRevision wire -> do
                        -- The layout is for a newer library than the graph we
                        -- hold; fetch the records before hydrating.
                        putModel (\x -> x{gGraph = (gGraph x){grGraphLoading = True}})
                        fetchGraph GraphLoaded GraphFailed
                    | Just hydrated <- hydrateWire graph wire -> do
                        let same =
                                maybe
                                    False
                                    (sameGraphLayout (hydrated{glGen = 0}) . (\current -> current{glGen = 0}))
                                    (mGraphLayout m)
                            generation = if same then mGraphGen m else mGraphGen m + 1
                            layout = hydrated{glGen = generation}
                            old = mGraphView m
                            view
                                | same && mGraphViewReady m = old
                                | mGraphViewReady m = resizeView layout (gvWidth old) (gvHeight old) (gvDpr old) old
                                | otherwise = fitView layout (gvWidth old) (gvHeight old) (gvDpr old)
                        putModel
                            ( \x ->
                                let seeded =
                                        x{gGraph = (gGraph x){grGraphLayout = Just layout, grGraphGen = generation, grGraphLayoutSource = "server", grGraphView = view, grGraphHover = if same then mGraphHover x else Nothing, grGraphSettled = if same then mGraphSettled x else False, grGraphSettleEpoch = if same then mGraphSettleEpoch x else nextRequestId (mGraphSettleEpoch x), grGraphDetailPhase = if same then mGraphDetailPhase x else 0, grGraphLoading = False}}
                                 in applyGraphScope (recomputeGraphColors seeded)
                            )
                        when (not same || view /= old) scheduleGraphSettle
                -- The graph payload and the layout disagree on the payload
                -- size (tags or records): there is no client-side layout
                -- fallback, so say so instead of painting a partial plate.
                Just _ ->
                    putModel
                        ( \x ->
                            x{gGraph = (gGraph x){grGraphLayout = Nothing, grGraphLayoutSource = "", grGraphLoading = False, grGraphError = Just layoutMissingMessage}}
                        )
    GraphLayoutFailed err -> do
        -- A failed refresh of an already-painted graph keeps the current plate
        -- and reports the failure as a toast; a graph with no server layout at
        -- all shows a visible error panel. There is no client-side fallback:
        -- the server is the only layout producer.
        handleApiError err
        m <- get
        putModel
            ( \x ->
                x
                    { gGraph =
                        (gGraph x)
                            { grGraphLoading = False
                            , grGraphError = case mGraphLayout x of
                                Just _ -> mGraphError x
                                Nothing -> Just ((aeMessage err))
                            }
                    }
            )
        when (isNothing (mGraph m)) (fetchGraph GraphLoaded GraphFailed)
    -- views ---------------------------------------------------------------
    _ -> pure ()
