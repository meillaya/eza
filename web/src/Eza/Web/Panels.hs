{- | Catalogue panels: graph, duplicates, tags, AI tags, maintenance, and the
account page.

Markup, classes and copy come from the Direction B design package; the CSS
lives in static/eza.css. Every figure is read from the client model, and a
hidden state says so instead of showing an invented number.
-}
module Eza.Web.Panels (
    graphPage,
    viewsPage,
    viewDialogs,
    dedupPage,
    tagsPage,
    aiTagsPage,
    maintenancePage,
    accountPage,
) where

import Data.Char (toUpper)
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T

import Eza.GraphMatch (ColorAssignment (..))
import Eza.Types (
    BookmarkSummary (..),
    DedupCounts (..),
    DedupGroup (..),
    DedupMergeAllReport (..),
    GraphRecord (..),
    ImportReport (..),
    LibraryStats (..),
    SavedSearch (..),
    TagStat (..),
 )
import Eza.User (UserRole (..), UserView (..), userRoleText)
import qualified Eza.View as EV
import Eza.Web.Api (WebhookTest (..))
import Eza.Web.Graph (
    GraphDraw (..),
    GraphLayout (..),
    GraphMatches (..),
    LayoutPreset (..),
    drawGraph,
    gvDpr,
    gvFit,
    gvHeight,
    gvScale,
    gvWidth,
    isTagKey,
    labelCount,
 )
import Eza.Web.Model
import Eza.Web.Types (
    AccountInfo (..),
    AiStatus (..),
    ConsolGroup (..),
    Credential (..),
    Rule (..),
    SessionInfo (..),
    ShareView (..),
    TagSuggestion (..),
    TokenView (..),
 )
import Eza.Webhook (DeliveryView (..), Webhook (..), allEventTypes, eventTypeText, maxWebhooks)
import Miso
import qualified Miso.CSS as C
import qualified Miso.Canvas as Canvas
import qualified Miso.Html as H
import qualified Miso.Html.Event as HE
import qualified Miso.Html.Property as HP
import Miso.JSON (withObject, (.:))

-- ================================================================ helpers ===

-- | 8,988 with thousands separators.
num :: Int -> MisoString
num n
    | n < 0 = ms ('-' : dotted (negate n))
    | otherwise = ms (dotted n)
  where
    dotted value = reverse (groupDigits (reverse (show value)))
      where
        groupDigits [] = []
        groupDigits xs =
            let (chunk, rest) = splitAt 3 xs
             in chunk ++ (if null rest then [] else ',' : groupDigits rest)

-- | EA-08987.
accno :: Int -> MisoString
accno bookmarkId = ms ("EA-" <> pad 5 (show bookmarkId))
  where
    pad width value
        | length value >= width = value
        | otherwise = replicate (width - length value) '0' ++ value

pad2 :: Int -> MisoString
pad2 value = ms (pad 2 (show value))
  where
    pad width raw
        | length raw >= width = raw
        | otherwise = replicate (width - length raw) '0' ++ raw

-- | 2025-09-24 becomes 2025.09.24.
isoStamp :: Text -> MisoString
isoStamp = ms . T.unpack . T.replace "-" "."

-- | One hostname, without the www. prefix.
showDomain :: Text -> MisoString
showDomain domain = ms (T.unpack (fromMaybe domain (T.stripPrefix "www." domain)))

attrDisabled :: Bool -> [Attribute Model Action]
attrDisabled True = [HP.disabled_]
attrDisabled False = []

attrChecked :: Bool -> [Attribute Model Action]
attrChecked value = [HP.checked_ value]

ruleLine :: View () () Model Action
ruleLine = H.div_ [HP.class_ "rule", HP.aria_ "hidden" "true"] []

-- | Stable hooks for the browser tests.
testId :: MisoString -> Attribute Model Action
testId value = HP.data_ "testid" value

figure :: MisoString -> MisoString -> View () () Model Action
figure label value = H.div_ [] [H.dt_ [] [text label], H.dd_ [] [text value]]

secHead :: MisoString -> MisoString -> View () () Model Action
secHead title meta =
    H.div_
        [HP.class_ "pnl-sec-head"]
        [ H.h2_ [HP.class_ "pnl-sec-title"] [text title]
        , H.span_ [HP.class_ "meta"] [text meta]
        ]

-- | One catalogue page inside the running app shell: page head, body, foot.
pageWith ::
    MisoString ->
    MisoString ->
    [View () () Model Action] ->
    [MisoString] ->
    [View () () Model Action] ->
    View () () Model Action
pageWith title lede figures provenance body =
    H.div_
        [HP.class_ "pnl-scroll"]
        [ H.div_
            [HP.class_ "pnl"]
            [ H.header_
                [HP.class_ "pnl-head"]
                [ H.div_
                    [HP.class_ "pnl-head-left"]
                    [ H.h1_ [HP.class_ "pnl-title"] [text title]
                    , H.p_ [HP.class_ "pnl-lede"] [text lede]
                    ]
                , H.dl_ [HP.class_ "pnl-figs"] figures
                ]
            , ruleLine
            , H.div_ [HP.class_ "pnl-body"] body
            , H.footer_
                [HP.class_ "pnl-foot"]
                ( [ H.span_ [HP.class_ "pnl-provenance meta"] [text item]
                  | item <- provenance
                  ]
                    ++ [H.span_ [HP.class_ "pnl-proof"] [text "eza"]]
                )
            ]
        ]

-- | Design a finished empty state in the catalogue voice.
emptyPanel ::
    MisoString ->
    MisoString ->
    MisoString ->
    [View () () Model Action] ->
    View () () Model Action
emptyPanel kicker title body extra =
    H.div_
        [HP.class_ "empty"]
        ( [ H.p_ [HP.class_ "empty-kicker meta"] [text kicker]
          , H.h2_ [HP.class_ "empty-title display"] [text title]
          , H.p_ [HP.class_ "empty-body"] [text body]
          ]
            ++ extra
        )

quietNote :: MisoString -> View () () Model Action
quietNote message = H.p_ [HP.class_ "pnl-quiet"] [text message]

{- | A panel read failed: say what failed and offer a retry instead of the
clean empty state, which would read as a result.
-}
panelError :: MisoString -> MisoString -> Maybe MisoString -> View () () Model Action
panelError kicker title maybeMessage =
    H.div_
        [HP.class_ "empty", HP.role_ "alert"]
        [ H.p_ [HP.class_ "empty-kicker meta"] [text kicker]
        , H.h2_ [HP.class_ "empty-title display"] [text title]
        , H.p_ [HP.class_ "empty-body"] [text (fromMaybe "The server did not answer." maybeMessage)]
        , H.p_ [HP.class_ "empty-try"] [smallAction "try again" ReloadRoute]
        ]

-- | The same for the account panels, at the smaller panel scale.
accountReadError :: MisoString -> Maybe MisoString -> View () () Model Action
accountReadError title maybeMessage =
    H.div_
        [HP.class_ "account-empty", HP.role_ "alert"]
        [ H.p_ [HP.class_ "account-empty-title display"] [text title]
        , H.p_
            [HP.class_ "account-empty-body"]
            [text (fromMaybe "The server did not answer." maybeMessage)]
        , H.div_
            [HP.class_ "account-actions"]
            [smallAction "try again" ReloadRoute]
        ]

smallAction :: MisoString -> Action -> View () () Model Action
smallAction label action =
    H.button_
        [HP.class_ "btn btn--sm", HP.type_ "button", HE.onClick action]
        [text label]

strongAction :: MisoString -> [Attribute Model Action] -> Action -> View () () Model Action
strongAction label extra action =
    H.button_
        ([HP.class_ "btn btn--sm btn--strong", HP.type_ "button", HE.onClick action] ++ extra)
        [text label]

-- | The shared head for the panel confirmation dialogs.
confirmationHead :: MisoString -> View () () Model Action
confirmationHead title =
    H.div_
        [HP.class_ "dialog__head"]
        [H.h2_ [HP.class_ "dialog__title"] [text title], H.kbd_ [] [text "esc"]]

-- | One line of an inline write error inside a confirmation dialog.
confirmationError :: Maybe MisoString -> [View () () Model Action]
confirmationError Nothing = []
confirmationError (Just message) =
    [H.p_ [HP.class_ "add-error", HP.role_ "alert"] [text message]]

-- ================================================================== graph ===

graphPage :: Model -> View () () Model Action
graphPage m =
    H.div_
        [testId "graph"]
        [ pageWith
            "The graph"
            "Every record and every tag in the library, drawn as one plate. Two records join at a resolved wikilink; a record joins a tag when it carries it. Those two relationships are the whole graph."
            (graphFigures m)
            [ "whole-library graph"
            , "links and tags only"
            , "canvas 2d"
            ]
            (graphBody m)
        ]

-- | Prefer the boot stats the masthead uses; fall back to the loaded rows.
statIntFields :: Model -> (LibraryStats -> Int) -> Int -> MisoString
statIntFields m field fallback = case mStats m of
    Nothing -> num fallback
    Just stats -> num (field stats)

countOrNotYet :: Maybe Int -> MisoString
countOrNotYet Nothing = "not yet"
countOrNotYet (Just value) = num value

graphFigures :: Model -> [View () () Model Action]
graphFigures m =
    [ figure "records" (countOrNotYet (glRecordCount <$> activeGraphLayout m))
    , figure "tags" (countOrNotYet (glTagCount <$> activeGraphLayout m))
    , figure "wikilinks" (countOrNotYet (glLinkCount <$> activeGraphLayout m))
    ]

graphBody :: Model -> [View () () Model Action]
graphBody m
    | mGraphLayout m == Nothing
    , Just message <- mGraphError m =
        [ panelError "read failed" "The graph did not load." (Just message)
        ]
    | mGraphLayout m == Nothing =
        [graphLoadingPlate m]
    | mGraphLocal m
    , activeGraphLayout m == Nothing =
        [ emptyPanel
            "no root"
            "No neighbourhood to draw."
            "Select a record on the whole graph, then switch the scope back to local. Local mode keeps the root record and everything within the chosen depth."
            []
        ]
    | Just layout <- activeGraphLayout m
    , glRecordCount layout == 0
    , glTagCount layout == 0 =
        [ emptyPanel
            "0 records"
            "The library is empty."
            "The graph draws records and tags from the whole library. Save a record and it appears here."
            []
        ]
    | Just layout <- activeGraphLayout m =
        ( [graphToolbar m]
            ++ [graphGroupEditor m | mGraphGroupEditor m]
            ++ [graphGrid m layout]
        )
    | otherwise = []

graphLoadingPlate :: Model -> View () () Model Action
graphLoadingPlate m =
    H.div_
        [ HP.class_ "g-plate g-plate--loading"
        , HP.aria_ "busy" (if mGraphLoading m then "true" else "false")
        ]
        [ H.p_ [HP.class_ "g-load-note"] [text "Building the graph."]
        ]

-- --------------------------------------------------------------- toolbar ---

graphToolbar :: Model -> View () () Model Action
graphToolbar m =
    H.div_
        [HP.class_ "g-toolbar"]
        [ H.div_
            [HP.class_ "g-control g-filter"]
            [ controlLabel "filter"
            , H.input_
                [ HP.class_ "input"
                , HP.id_ "graph-filter"
                , HP.type_ "search"
                , HP.placeholder_ "title, domain, or tag"
                , HP.value_ (mGraphFilter m)
                , HP.autocomplete_ "off"
                , HP.spellcheck_ False
                , HP.aria_ "label" "Filter the graph by title, domain, or tag"
                , HE.onInput GraphFilterChanged
                ]
            ]
        , H.div_
            [HP.class_ "g-settings", testId "graph-settings"]
            [ H.div_
                [HP.class_ "g-control g-scope"]
                ( [ controlLabel "scope"
                  , H.div_
                        [HP.class_ "g-seg", HP.role_ "group", HP.aria_ "label" "Graph scope"]
                        [ segmentButton "whole" "graph-scope-whole" (not (mGraphLocal m)) (if mGraphLocal m then GraphScopeToggled else Noop)
                        , segmentButton "local" "graph-local-toggle" (mGraphLocal m) GraphScopeToggled
                        ]
                  ]
                    ++ [ H.span_
                            [HP.class_ "g-root-name mono", testId "graph-root"]
                            [text (graphRootName m)]
                       | mGraphLocal m
                       ]
                )
            , H.div_
                [HP.class_ "g-control g-depth"]
                ( [ controlLabel "depth"
                  , H.div_
                        [HP.class_ "g-seg", testId "graph-local-depth", HP.role_ "group", HP.aria_ "label" "Local graph depth"]
                        [ segmentButton (ms (show depth)) ("graph-depth-" <> ms (show depth)) (mGraphLocalDepth m == depth) (GraphLocalDepthSelected depth)
                        | depth <- [1, 2, 3]
                        ]
                  ]
                    ++ [H.span_ [HP.class_ "g-root-hint meta"] [text "hops"] | mGraphLocal m]
                )
            , H.div_
                [HP.class_ "g-control g-preset"]
                [ controlLabel "layout"
                , H.div_
                    [HP.class_ "g-seg", testId "graph-preset", HP.role_ "group", HP.aria_ "label" "Layout preset"]
                    [ segmentButton "compact" "graph-preset-compact" (mGraphPreset m == Compact) (GraphPresetSelected Compact)
                    , segmentButton "standard" "graph-preset-standard" (mGraphPreset m == Standard) (GraphPresetSelected Standard)
                    , segmentButton "airy" "graph-preset-airy" (mGraphPreset m == Airy) (GraphPresetSelected Airy)
                    ]
                ]
            ]
        , H.div_
            [HP.class_ "g-control g-view-actions"]
            [ controlLabel "view"
            , H.div_
                [HP.class_ "g-button-row"]
                [ H.button_
                    [HP.class_ "btn btn--sm", HP.type_ "button", testId "view-save-graph", HE.onClick ViewSaveGraph]
                    [text "save"]
                , H.button_
                    [HP.class_ "btn btn--sm", HP.type_ "button", testId "view-save-as", HE.onClick (ViewSaveOpen EV.GraphKind)]
                    [text "save as…"]
                , H.button_
                    [HP.class_ "btn btn--sm", HP.type_ "button", testId "graph-group-edit", HE.onClick ViewGroupEditorToggle]
                    [text (if mGraphGroupEditor m then "close groups" else "groups")]
                ]
            ]
        , H.div_
            [HP.class_ "g-control"]
            [ controlLabel "tags"
            , H.button_
                [ HP.class_ ("g-toggle" <> if mGraphTagsShown m then " is-on" else "")
                , HP.type_ "button"
                , testId "graph-tags-toggle"
                , HP.aria_ "pressed" (if mGraphTagsShown m then "true" else "false")
                , HE.onClick GraphTagsToggled
                ]
                [text (if mGraphTagsShown m then "shown" else "hidden")]
            ]
        , H.div_
            [HP.class_ "g-control g-view"]
            [ controlLabel "zoom"
            , H.div_
                [HP.class_ "g-zoom-box"]
                [ H.button_
                    [HP.class_ "g-zbtn", HP.type_ "button", testId "graph-zoom-out", HP.aria_ "label" "Zoom out", HE.onClick GraphZoomOut]
                    [text "-"]
                , H.span_
                    [HP.class_ "g-zval mono", testId "graph-zoom-value", HP.aria_ "live" "polite"]
                    [text (ms (show (graphZoomPercent m) <> "%"))]
                , H.button_
                    [HP.class_ "g-zbtn", HP.type_ "button", testId "graph-zoom-in", HP.aria_ "label" "Zoom in", HE.onClick GraphZoomIn]
                    [text "+"]
                , H.button_
                    [HP.class_ "g-zbtn g-zreset", HP.type_ "button", testId "graph-fit", HP.aria_ "label" "Fit the graph", HE.onClick GraphFit]
                    [text "fit"]
                ]
            ]
        , H.div_
            [HP.class_ "g-control"]
            [ controlLabel "data"
            , H.button_
                [HP.class_ "btn btn--sm", HP.type_ "button", HE.onClick GraphRefresh]
                [text "refresh"]
            ]
        ]

-- | One button in a segmented control.
segmentButton :: MisoString -> MisoString -> Bool -> Action -> View () () Model Action
segmentButton label hook pressed action =
    H.button_
        [ HP.class_ ("g-seg-btn" <> if pressed then " is-on" else "")
        , HP.type_ "button"
        , testId hook
        , HP.aria_ "pressed" (if pressed then "true" else "false")
        , HE.onClick action
        ]
        [text label]

-- | The root record of the local graph, by title.
graphRootName :: Model -> MisoString
graphRootName m =
    case activeGraphLayout m of
        Just layout ->
            case mGraphLocalRoot m >>= \root -> IM.lookup root (glRecords layout) of
                Just record -> ms (grTitle record)
                Nothing -> "no root"
        Nothing -> "no root"

-- --------------------------------------------------------------- plate -----

graphGrid :: Model -> GraphLayout -> View () () Model Action
graphGrid m layout =
    H.div_
        [HP.class_ "g-grid"]
        [ H.div_
            [HP.class_ "g-main"]
            [ H.div_
                [HP.class_ "g-plate"]
                [graphCanvas m layout]
            , H.p_
                [HP.class_ "g-plate-hint meta"]
                [text (graphHint m)]
            , graphStatus m layout
            , graphResults m layout
            ]
        , graphAside m layout
        ]

graphCanvas :: Model -> GraphLayout -> View () () Model Action
graphCanvas m layout =
    Canvas.canvas
        ( [ HP.class_ ("g-canvas-el" <> if mGraphDrag m /= Nothing then " is-panning" else "")
          , HP.id_ "graph-canvas"
          , HP.tabindex_ "0"
          , HP.width_ (ms (show (round (gvWidth view * max 1 (gvDpr view)) :: Int)))
          , HP.height_ (ms (show (round (gvHeight view * max 1 (gvDpr view)) :: Int)))
          , HP.role_ "application"
          , HP.aria_ "label" "The library graph. Drag to pan, wheel to zoom, click a record to open it. Tab here for keyboard control."
          , HE.onPointerDown (\pointerEvent -> GraphPointerDown (offsetX pointerEvent) (offsetY pointerEvent))
          , HE.onPointerUp (\pointerEvent -> GraphPointerUp (offsetX pointerEvent) (offsetY pointerEvent))
          , HE.onPointerMove (\pointerEvent -> GraphPointerMove (offsetX pointerEvent) (offsetY pointerEvent))
          , HE.onPointerLeave (const GraphPointerLeave)
          , wheelAttribute
          ]
        )
        (\_ -> pure ())
        (\() -> drawGraph draw)
  where
    view = mGraphView m
    draw =
        GraphDraw
            { drLayout = layout
            , drView = view
            , drHover = mGraphHover m
            , drSelected = mGraphSelected m
            , drFocus = mGraphFocus m
            , drMatches = mGraphMatches m
            , drTagsShown = mGraphTagsShown m
            , drLabelMode = mGraphLabelMode m
            , drRecordColors = maybe IM.empty caRecordColors (mGraphColors m)
            , drTagColors = maybe M.empty caTagColors (mGraphColors m)
            , drViewKey = graphViewCacheKey m
            , drLocal = mGraphLocal m
            , drSettled = mGraphSettled m
            , drDetailPhase = mGraphDetailPhase m
            , drDetailChunks = mGraphDetailChunks m
            , drDark = mTheme m == ThemeDark
            }
    wheelAttribute =
        onWithOptions
            BUBBLE
            preventDefault
            "wheel"
            wheelDecoder
            (\value _ _ -> GraphWheel (first3 value) (second3 value) (third3 value))

wheelDecoder :: Decoder (Double, Double, Double)
wheelDecoder =
    at [] $
        withObject "wheel" $ \o ->
            (,,)
                <$> o .: "offsetX"
                <*> o .: "offsetY"
                <*> o .: "deltaY"

offsetX :: PointerEvent -> Double
offsetX = fst . offset

offsetY :: PointerEvent -> Double
offsetY = snd . offset

first3 :: (a, b, c) -> a
first3 (first, _, _) = first

second3 :: (a, b, c) -> b
second3 (_, second, _) = second

third3 :: (a, b, c) -> c
third3 (_, _, third) = third

-- -------------------------------------------------------------- status -----

graphStatus :: Model -> GraphLayout -> View () () Model Action
graphStatus m layout =
    H.p_
        [ HP.class_ "g-status meta"
        , testId "graph-status"
        , HP.aria_ "live" "polite"
        ]
        [ H.span_ [testId "graph-status-main"] [text (graphStatusText m layout)]
        , H.span_ [HP.class_ "g-status-sep", HP.aria_ "hidden" "true"] [text " · "]
        , H.span_
            [testId "graph-label-count", HP.class_ "g-label-count"]
            [text (num (graphLabelCount m layout) <> " labels")]
        ]

{- | How many labels the current view and label mode draw. The readout uses the
same pure plan as the painter, so it counts what is on screen.
-}
graphLabelCount :: Model -> GraphLayout -> Int
graphLabelCount m layout =
    labelCount layout (mGraphView m) (mGraphTagsShown m) (mGraphLabelMode m)

graphStatusText :: Model -> GraphLayout -> MisoString
graphStatusText m layout
    | gmActive matches =
        num (gmCount matches)
            <> " of "
            <> num (glRecordCount layout)
            <> " records match the filter · "
            <> graphTagCountText
            <> " · "
            <> linkCountText
            <> localInfo
            <> layoutSource
            <> tagsHidden
            <> refreshing
    | otherwise =
        num (glRecordCount layout)
            <> " records · "
            <> graphTagCountText
            <> " · "
            <> linkCountText
            <> localInfo
            <> layoutSource
            <> tagsHidden
            <> refreshing
  where
    matches = mGraphMatches m
    graphTagCountText = num (glTagCount layout) <> " tags"
    linkCountText =
        num (glLinkCount layout)
            <> if glLinkCount layout == 1 then " link" else " links"
    layoutSource
        | mGraphLayoutSource m == "server" = " · server layout"
        | otherwise = " · local layout"
    localInfo
        | not (mGraphLocal m) = ""
        | otherwise =
            " · depth "
                <> ms (show (mGraphLocalDepth m))
                <> if mGraphLocalCapped m then " · capped at 2,500 nodes" else ""
    tagsHidden = if mGraphTagsShown m then "" else " · tags hidden"
    refreshing = if mGraphLoading m then " · refreshing" else ""

graphHint :: Model -> MisoString
graphHint m
    | mGraphLocal m =
        "local graph · drag to pan · wheel to zoom · click a record to open it · click a tag to open its ledger · tab here for keys"
    | otherwise =
        "whole library · drag to pan · wheel to zoom · click a record to open it · click a tag to open its ledger · tab here for keys"

-- -------------------------------------------------------------- results ----

graphResults :: Model -> GraphLayout -> View () () Model Action
graphResults m layout
    | not (gmActive (mGraphMatches m)) = H.div_ [] []
    | null (gmTop matches) =
        H.div_
            [HP.class_ "g-results", testId "graph-results"]
            [ H.p_ [HP.class_ "g-results-empty meta"] [text "No record matches the filter."]
            ]
    | otherwise =
        H.div_
            [HP.class_ "g-results", testId "graph-results"]
            ( H.div_
                [HP.class_ "g-results-head"]
                [ controlLabel "matches"
                , H.span_ [HP.class_ "meta"] [text (num (gmCount matches) <> " records, best eight")]
                ]
                : [ graphResult layout recordKey
                  | recordKey <- gmTop matches
                  ]
            )
  where
    matches = mGraphMatches m

graphResult :: GraphLayout -> Int -> View () () Model Action
graphResult layout recordKey =
    case IM.lookup recordKey (glRecords layout) of
        Nothing -> H.span_ [] []
        Just record ->
            H.a_
                [ HP.class_ "g-result"
                , testId "graph-result"
                , HP.href_ (bookmarkPath recordKey)
                , HE.onClickPrevent (Navigate (Bookmark recordKey))
                ]
                [ H.span_ [HP.class_ "g-result-title"] [text (ms (grTitle record))]
                , H.span_ [HP.class_ "g-result-domain meta"] [text (ms (grDomain record))]
                ]

bookmarkPath :: Int -> MisoString
bookmarkPath bookmarkId = "/bookmark/" <> ms (show bookmarkId)

-- ---------------------------------------------------------------- aside ----

graphAside :: Model -> GraphLayout -> View () () Model Action
graphAside m layout =
    H.aside_
        [HP.class_ "g-aside", testId "graph-aside", HP.aria_ "label" "Graph details"]
        [ graphPreview m layout
        , graphTopTags layout
        , graphLegend m
        ]

{- | The hover preview card. It shows the hovered node while there is one and
falls back to the focused or selected node; an idle line explains the plate
when neither exists.
-}
graphPreview :: Model -> GraphLayout -> View () () Model Action
graphPreview m layout =
    H.div_
        [HP.class_ "g-preview", testId "graph-preview"]
        ( case previewKey of
            Nothing ->
                [ H.p_ [HP.class_ "g-preview-idle meta"] [text "Hover a node to preview it."]
                ]
            Just key
                | isTagKey key -> tagPreview key
                | Just record <- IM.lookup key (glRecords layout) -> recordPreview record
                | otherwise -> []
        )
  where
    previewKey = case mGraphHover m of
        Just key -> Just key
        Nothing -> case mGraphSelected m of
            Just key -> Just key
            Nothing -> mGraphFocus m
    recordPreview record =
        [ H.div_
            [HP.class_ "g-preview-head"]
            [ controlLabel (if grIsRead record then "read" else "unread")
            , H.span_ [HP.class_ "meta mono"] [text (ms (grDomain record))]
            ]
        , H.h2_
            [HP.class_ "g-preview-title"]
            [ H.a_
                [HP.href_ (bookmarkPath (grId record)), HE.onClickPrevent (Navigate (Bookmark (grId record)))]
                [text (ms (grTitle record))]
            ]
        , H.p_
            [HP.class_ "g-preview-meta meta"]
            [ text (formatFiled (grCreatedAt record))
            , text " · "
            , text (countNoun (recordLinks layout (grId record)) "wikilink" "wikilinks")
            , text " · "
            , text (countNoun (sharedRecords layout (grId record)) "tagged record" "tagged records")
            ]
        , graphPreviewTags layout (grId record)
        , H.div_
            [HP.class_ "g-preview-act"]
            [ smallAction "open the record" (Navigate (Bookmark (grId record)))
            ]
        ]
    tagPreview key =
        case IM.lookup key (glTags layout) of
            Nothing -> []
            Just (name, count) ->
                [ H.div_
                    [HP.class_ "g-preview-head"]
                    [ controlLabel "tag"
                    , H.span_ [HP.class_ "meta mono"] [text (countNoun count "record" "records")]
                    ]
                , H.h2_ [HP.class_ "g-preview-title"] [H.span_ [] [text (ms ("#" <> name))]]
                , H.div_
                    [HP.class_ "g-preview-act"]
                    [ smallAction "open the tagged ledger" (FilterByQuery ("tag:" <> name))
                    ]
                ]

-- | A number with a singular or plural noun.
countNoun :: Int -> MisoString -> MisoString -> MisoString
countNoun count singular plural =
    num count <> " " <> if count == 1 then singular else plural

graphPreviewTags :: GraphLayout -> Int -> View () () Model Action
graphPreviewTags layout recordKey =
    H.div_
        [HP.class_ "g-preview-tags"]
        [ H.span_ [HP.class_ "tagpill"] [text (ms name)]
        | tagKey <- take 12 (IM.findWithDefault [] recordKey (glRecordTags layout))
        , Just (name, _) <- [IM.lookup tagKey (glTags layout)]
        ]

recordLinks :: GraphLayout -> Int -> Int
recordLinks layout recordKey =
    length
        [ neighbour
        | neighbour <- IM.findWithDefault [] recordKey (glAdj layout)
        , not (isTagKey neighbour)
        ]

-- | Records reachable through the record's tags, excluding itself.
sharedRecords :: GraphLayout -> Int -> Int
sharedRecords layout recordKey =
    IS.size
        ( IS.delete
            recordKey
            ( IS.unions
                ( [IS.singleton recordKey]
                    ++ [ IS.fromList members
                       | tagKey <- IM.findWithDefault [] recordKey (glRecordTags layout)
                       , let members = IM.findWithDefault [] tagKey (glAdj layout)
                       ]
                )
            )
        )

graphTopTags :: GraphLayout -> View () () Model Action
graphTopTags layout =
    H.div_
        [HP.class_ "g-side-sec"]
        [ H.div_
            [HP.class_ "g-side-head"]
            [ controlLabel "top tags"
            , H.span_ [HP.class_ "meta"] [text (num (glTagCount layout) <> " in the library")]
            ]
        , H.div_
            [HP.class_ "g-tag-list"]
            (map tagButton (take 14 (glTagOrder layout)))
        ]
  where
    tagButton tagKey =
        case IM.lookup tagKey (glTags layout) of
            Nothing -> H.span_ [] []
            Just (name, count) ->
                H.button_
                    [ HP.class_ "g-tag"
                    , HP.type_ "button"
                    , testId "graph-tag"
                    , HP.title_ (ms ("Open the ledger filtered by #" <> name))
                    , HE.onClick (FilterByQuery ("tag:" <> name))
                    ]
                    [ H.span_ [HP.class_ "g-tag-name mono"] [text (ms ("#" <> name))]
                    , H.span_ [HP.class_ "g-tag-count meta mono"] [text (num count)]
                    ]

controlLabel :: MisoString -> View () () Model Action
controlLabel label =
    H.span_ [HP.class_ "g-control-label sc"] [text label]

graphZoomPercent :: Model -> Int
graphZoomPercent m =
    case activeGraphLayout m of
        Nothing -> 100
        Just _ ->
            round
                ( 100
                    * gvScale (mGraphView m)
                    / max 1e-9 (gvFit (mGraphView m))
                )

-- ------------------------------------------------------------ graph views ---

{- | The cache identity of the active graph view: id, update stamp and the
live color groups. Any group edit or saved-view change invalidates the plate.
-}
graphViewCacheKey :: Model -> MisoString
graphViewCacheKey m =
    ms
        ( show
            ( fromMaybe 0 (mGraphViewId m)
            , mGraphViewRev m
            , [ (EV.cgName group, EV.cgQuery group, EV.cgColor group, EV.cgEnabled group)
              | group <- mGraphGroupDrafts m
              ]
            )
        )

{- | The color legend: one row per group with a swatch, the matched record
count and a live enable toggle.
-}
graphLegend :: Model -> View () () Model Action
graphLegend m =
    H.div_
        [HP.class_ "g-side-sec", testId "graph-legend"]
        ( H.div_
            [HP.class_ "g-side-head"]
            [ controlLabel "color groups"
            , H.span_
                [HP.class_ "meta"]
                [text (num (length (mGraphGroupDrafts m)) <> " groups")]
            ]
            : if null (mGraphGroupDrafts m)
                then [H.p_ [HP.class_ "g-preview-idle meta"] [text "No color groups. Use groups to add one."]]
                else map legendRow (zip [0 :: Int ..] (mGraphGroupDrafts m))
        )
  where
    legendRow (index, group) =
        H.div_
            [HP.class_ ("g-legend-row" <> if EV.cgEnabled group then "" else " is-off")]
            [ H.span_ [HP.class_ "g-swatch", C.styleInline_ ("background:" <> ms (T.unpack (EV.cgColor group)))] []
            , H.span_ [HP.class_ "g-legend-name mono"] [text (ms (T.unpack (EV.cgName group)))]
            , H.span_
                [HP.class_ "g-legend-count meta mono"]
                [text (num (indexMaybe index (mGraphGroupCounts m)) <> " matched")]
            , H.button_
                [ HP.class_ "g-legend-toggle"
                , HP.type_ "button"
                , HP.aria_ "pressed" (if EV.cgEnabled group then "true" else "false")
                , HP.title_ (if EV.cgEnabled group then "Hide this group" else "Show this group")
                , HE.onClick (ViewGroupToggleEnabled index)
                ]
                [text (if EV.cgEnabled group then "on" else "off")]
            ]

indexMaybe :: Int -> [a] -> a
indexMaybe index values = case drop index values of
    (value : _) -> value
    [] -> error "indexMaybe: index out of range"

{- | The color-group settings editor: add, edit (name/query/#rrggbb), enable,
remove, with live preview against the current graph.
-}
graphGroupEditor :: Model -> View () () Model Action
graphGroupEditor m =
    H.div_
        [HP.class_ "g-group-editor", testId "graph-group-editor"]
        ( [ H.div_
                [HP.class_ "g-group-head"]
                [ controlLabel "color groups"
                , H.span_ [HP.class_ "meta"] [text (num (length drafts) <> " of " <> num EV.maxColorGroups)]
                , H.button_
                    ( [ HP.class_ "btn btn--sm"
                      , HP.type_ "button"
                      , testId "graph-group-add"
                      , HE.onClick ViewGroupAdd
                      ]
                        ++ attrDisabled (length drafts >= EV.maxColorGroups)
                    )
                    [text "add group"]
                , H.button_
                    [ HP.class_ "btn btn--sm"
                    , HP.type_ "button"
                    , testId "view-groups-save"
                    , HE.onClick ViewGroupsSave
                    ]
                    [text "save view"]
                , H.button_
                    [ HP.class_ "btn btn--sm"
                    , HP.type_ "button"
                    , testId "view-groups-cancel"
                    , HE.onClick ViewGroupsCancel
                    ]
                    [text "cancel"]
                , H.span_
                    [HP.class_ "g-group-dirty meta"]
                    [text (if mGraphGroupDirty m then "unsaved changes" else "saved")]
                ]
          ]
            ++ [ H.span_
                    [HP.class_ "add-error", testId "graph-group-limit", HP.role_ "status"]
                    [text "at most 24 color groups"]
               | length drafts >= EV.maxColorGroups
               ]
            ++ [ H.p_
                    [HP.class_ "g-group-hint meta"]
                    [text "First enabled group wins. Queries use the ledger search syntax; #rrggbb colors."]
               , H.div_ [HP.class_ "g-group-rows"] (map groupRow (zip [0 :: Int ..] drafts))
               , case vuError (mViewUi m) of
                    Just message -> H.p_ [HP.class_ "add-error", HP.role_ "alert"] [text message]
                    Nothing -> H.span_ [] []
               ]
        )
  where
    drafts = mGraphGroupDrafts m
    groupRow (index, group) =
        H.div_
            [HP.class_ "g-group-row", testId "graph-group-row"]
            [ H.input_
                [ HP.class_ "input g-group-name"
                , HP.type_ "text"
                , HP.placeholder_ "group name"
                , HP.value_ (ms (T.unpack (EV.cgName group)))
                , HE.onInput (ViewGroupField index GroupName)
                ]
            , H.input_
                [ HP.class_ "input g-group-query"
                , HP.type_ "text"
                , HP.placeholder_ "query (tag:rust perf.example)"
                , HP.value_ (ms (T.unpack (EV.cgQuery group)))
                , HE.onInput (ViewGroupField index GroupQuery)
                ]
            , H.input_
                [ HP.class_ "input g-group-color mono"
                , HP.type_ "text"
                , HP.placeholder_ "#C98A3E"
                , HP.value_ (ms (T.unpack (EV.cgColor group)))
                , HE.onInput (ViewGroupField index GroupColor)
                ]
            , H.button_
                [ HP.class_ ("g-group-on" <> if EV.cgEnabled group then " is-on" else "")
                , HP.type_ "button"
                , HP.aria_ "pressed" (if EV.cgEnabled group then "true" else "false")
                , HE.onClick (ViewGroupToggleEnabled index)
                ]
                [text (if EV.cgEnabled group then "on" else "off")]
            , H.button_
                [ HP.class_ "g-group-remove"
                , HP.type_ "button"
                , HP.aria_ "label" ("Remove color group " <> ms (T.unpack (EV.cgName group)))
                , HE.onClick (ViewGroupRemove index)
                ]
                [text "remove"]
            ]

-- ------------------------------------------------------------ views page ---

viewsPage :: Model -> View () () Model Action
viewsPage m =
    H.div_
        [testId "views-page"]
        [ pageWith
            "Views"
            "Saved graph and ledger views. A graph view stores the query, tag visibility, label mode, layout preset, local depth and color groups; a ledger view stores a query and a sort order."
            (viewFigures m)
            [ "declarative views"
            , "one default per kind"
            ]
            (viewsBody m)
        ]

viewFigures :: Model -> [View () () Model Action]
viewFigures m =
    [ figure "views" (num (length (mViews m)))
    , figure "graph" (num (length [() | view <- mViews m, EV.vKind view == EV.GraphKind]))
    , figure "ledger" (num (length [() | view <- mViews m, EV.vKind view == EV.LedgerKind]))
    ]

viewsBody :: Model -> [View () () Model Action]
viewsBody m =
    [ H.div_
        [HP.class_ "views-toolbar"]
        [ H.button_
            [HP.class_ "btn btn--sm btn--strong", HP.type_ "button", testId "view-create", HE.onClick (ViewSaveOpen EV.GraphKind)]
            [text "new view"]
        , H.button_
            [HP.class_ "btn btn--sm", HP.type_ "button", testId "view-import", HE.onClick ViewImportOpen]
            [text "import JSON"]
        , H.button_
            [HP.class_ "btn btn--sm", HP.type_ "button", HE.onClick ReloadRoute]
            [text "refresh"]
        , H.span_ [HP.class_ "meta"] [text "Open a view to apply it to the ledger or the graph."]
        ]
    , case mViewsError m of
        Just message -> H.p_ [HP.class_ "add-error", HP.role_ "alert"] [text message]
        Nothing -> H.span_ [] []
    ]
        ++ ( if null (mViews m)
                then
                    [ emptyPanel
                        "0 views"
                        "No views yet."
                        "Create a graph view from the graph settings, save the current ledger search with save as view, or import a view JSON document."
                        []
                    ]
                else map (viewRow m) (mViews m)
           )

viewRow :: Model -> EV.View -> View () () Model Action
viewRow m view =
    H.div_
        [HP.class_ "view-row", testId "view-row"]
        [ H.div_
            [HP.class_ "view-row-main"]
            [ H.h2_
                [HP.class_ "view-row-name"]
                [text (ms (T.unpack (EV.vName view)))]
            , H.p_
                [HP.class_ "view-row-meta meta"]
                ( [ H.span_ [HP.class_ "view-kind"] [text (ms (T.unpack (EV.viewKindText (EV.vKind view))))]
                  , H.span_ [HP.class_ "view-slug mono"] [text (ms (T.unpack (EV.vSlug view)))]
                  ]
                    ++ [H.span_ [HP.class_ "view-default-badge", testId "view-default-badge"] [text "default"] | EV.vIsDefault view]
                )
            , case vuRename (mViewUi m) of
                Just (slug, name)
                    | slug == EV.vSlug view ->
                        H.div_
                            [HP.class_ "view-rename"]
                            [ H.input_
                                [ HP.class_ "input"
                                , HP.type_ "text"
                                , HP.value_ name
                                , HE.onInput ViewRenameInput
                                ]
                            , H.button_ [HP.class_ "btn btn--sm", HP.type_ "button", HE.onClick ViewRenameSubmit] [text "rename"]
                            , H.button_ [HP.class_ "btn btn--sm", HP.type_ "button", HE.onClick ViewRenameCancel] [text "cancel"]
                            ]
                _ -> H.span_ [] []
            ]
        , H.div_
            [HP.class_ "view-row-actions"]
            [ H.button_
                [HP.class_ "btn btn--sm btn--strong", HP.type_ "button", testId "view-open", HE.onClick (ViewOpenView (EV.vSlug view))]
                [text "open"]
            , H.button_
                ([HP.class_ "btn btn--sm", HP.type_ "button", testId "view-default", HE.onClick (ViewDefaultView (EV.vSlug view))] ++ attrDisabled (EV.vIsDefault view))
                [text "set default"]
            , H.button_
                [HP.class_ "btn btn--sm", HP.type_ "button", testId "view-rename", HE.onClick (ViewRenameStart (EV.vSlug view))]
                [text "rename"]
            , H.button_
                [HP.class_ "btn btn--sm", HP.type_ "button", testId "view-duplicate", HE.onClick (ViewDuplicateView (EV.vSlug view))]
                [text "duplicate"]
            , H.button_
                [HP.class_ "btn btn--sm", HP.type_ "button", testId "view-export", HE.onClick (ViewExportView (EV.vSlug view))]
                [text "export"]
            , H.button_
                [HP.class_ "btn btn--sm", HP.type_ "button", testId "view-delete", HE.onClick (ViewDeleteView (EV.vSlug view))]
                [text "delete"]
            ]
        ]

-- ---------------------------------------------------------- view dialogs ---

{- | The save-as / create, import and export dialogs. Rendered by the shell so
the graph page and the ledger can both open them.
-}
viewDialogs :: Model -> [View () () Model Action]
viewDialogs m =
    [viewSaveDialog m | vuSaveOpen (mViewUi m)]
        ++ [viewImportDialog m | vuImportOpen (mViewUi m)]
        ++ [viewExportDialog m | isJust (vuExport (mViewUi m))]

viewSaveDialog :: Model -> View () () Model Action
viewSaveDialog m =
    viewOverlay
        "Save view"
        (testId "view-save-dialog")
        [ H.h2_ [HP.class_ "dialog__title"] [text (if EV.vKind (selectedKind) == EV.GraphKind then "Save graph view" else "Save ledger view")]
        , H.p_
            [HP.class_ "meta"]
            [text "The definition captures the current query, tags, label mode, layout preset, local depth and color groups."]
        , H.div_
            [HP.class_ "view-kind-pick"]
            [ H.button_
                [ HP.class_ ("g-seg-btn" <> if uiKind == EV.GraphKind then " is-on" else "")
                , HP.type_ "button"
                , HP.aria_ "pressed" (if uiKind == EV.GraphKind then "true" else "false")
                , HE.onClick (ViewSaveKindSelected EV.GraphKind)
                ]
                [text "graph"]
            , H.button_
                [ HP.class_ ("g-seg-btn" <> if uiKind == EV.LedgerKind then " is-on" else "")
                , HP.type_ "button"
                , HP.aria_ "pressed" (if uiKind == EV.LedgerKind then "true" else "false")
                , HE.onClick (ViewSaveKindSelected EV.LedgerKind)
                ]
                [text "ledger"]
            ]
        , H.input_
            [ HP.class_ "input"
            , HP.type_ "text"
            , HP.placeholder_ "view name"
            , HP.value_ (vuSaveName ui)
            , testId "view-name-input"
            , HE.onInput ViewSaveNameInput
            ]
        , case vuError ui of
            Just message -> H.p_ [HP.class_ "add-error", HP.role_ "alert"] [text message]
            Nothing -> H.span_ [] []
        , H.div_
            [HP.class_ "dialog__actions"]
            [ H.button_
                [HP.class_ "btn btn--sm btn--strong", HP.type_ "button", testId "view-save-submit", HE.onClick ViewSaveSubmit]
                [text "save view"]
            , H.button_
                [HP.class_ "btn btn--sm", HP.type_ "button", testId "view-save-cancel", HE.onClick ViewSaveCancel]
                [text "cancel"]
            ]
        ]
  where
    ui = mViewUi m
    uiKind = vuSaveKind ui
    selectedKind = case mGraphViewId m of
        Just viewId -> case [view | view <- mViews m, EV.vId view == viewId] of
            (view : _) -> view
            [] -> EV.View 0 "" "" EV.GraphKind False (EV.GraphDefinition EV.defaultGraphViewDefinition) 0 0
        Nothing -> EV.View 0 "" "" EV.GraphKind False (EV.GraphDefinition EV.defaultGraphViewDefinition) 0 0

viewImportDialog :: Model -> View () () Model Action
viewImportDialog m =
    viewOverlay
        "Import a view"
        (testId "view-import-dialog")
        [ H.h2_ [HP.class_ "dialog__title"] [text "Import a view"]
        , H.p_ [HP.class_ "meta"] [text "Paste one view JSON document (the export shape). The server validates it."]
        , H.textarea_
            [ HP.class_ "input view-import-text"
            , HP.rows_ "8"
            , HP.placeholder_ "{ \"name\": ... }"
            , HP.value_ (vuImportText ui)
            , testId "view-import-text"
            , HE.onInput ViewImportTextInput
            ]
        , case vuError ui of
            Just message -> H.p_ [HP.class_ "add-error", HP.role_ "alert"] [text message]
            Nothing -> H.span_ [] []
        , H.div_
            [HP.class_ "dialog__actions"]
            [ H.button_
                [HP.class_ "btn btn--sm btn--strong", HP.type_ "button", testId "view-import-submit", HE.onClick ViewImportSubmit]
                [text "import"]
            , H.button_
                [HP.class_ "btn btn--sm", HP.type_ "button", HE.onClick ViewImportCancel]
                [text "cancel"]
            ]
        ]
  where
    ui = mViewUi m

viewExportDialog :: Model -> View () () Model Action
viewExportDialog m =
    viewOverlay
        "Export view"
        (testId "view-export-dialog")
        [ H.h2_ [HP.class_ "dialog__title"] [text "Export view"]
        , H.p_ [HP.class_ "meta"] [text "Copy this JSON body into import on another install."]
        , H.textarea_
            [ HP.class_ "input view-export-text"
            , HP.rows_ "10"
            , HP.readonly_ True
            , HP.value_ (maybe "" ms (vuExport (mViewUi m)))
            , testId "view-export-text"
            ]
        , H.div_
            [HP.class_ "dialog__actions"]
            [ H.button_
                [HP.class_ "btn btn--sm", HP.type_ "button", testId "view-export-close", HE.onClick ViewExportClose]
                [text "close"]
            ]
        ]

{- | A modal shell for the views manager. The dialog carries the same role,
modal marker and accessible name as every other dialog in the client: the
focus trap in static/pwa.js only sees layers marked this way, and a screen
reader announces them once.
-}
viewOverlay :: MisoString -> Attribute Model Action -> [View () () Model Action] -> View () () Model Action
viewOverlay label hook children =
    H.div_
        [HP.class_ "overlay is-open"]
        [ H.div_
            [ HP.class_ "dialog"
            , HP.role_ "dialog"
            , HP.aria_ "modal" "true"
            , HP.aria_ "label" label
            , hook
            ]
            children
        ]

-- ============================================================== duplicates ===

dedupPage :: Model -> View () () Model Action
dedupPage m =
    pageWith
        "Duplicates"
        "The same page saved more than once. Same-URL groups are safe to merge in one confirmed pass; same-title matches are a review list, because different pages can share a title."
        (dedupFigures m)
        [ "exact counts, paged groups"
        , "one undo snapshot"
        ]
        ( dedupBody m
            ++ [dedupMergeDialog m | isJust (mDedupConfirm m)]
            ++ [dedupMergeAllDialog m | mDedupMergeAllOpen m]
        )

dedupFigures :: Model -> [View () () Model Action]
dedupFigures m =
    [ figure "same-URL groups" (numOrDash (dcUrlGroups <$> mDedupCounts m))
    , figure "URL records" (numOrDash (dcUrlRecords <$> mDedupCounts m))
    , figure "after merge all" (numOrDash (dedupAfterMergeAll m))
    ]
  where
    numOrDash Nothing = "–"
    numOrDash (Just value) = num value

{- | The size the library would have after every same-URL group is merged:
each group loses its absorbed copies, and the keeper stays.
-}
dedupAfterMergeAll :: Model -> Maybe Int
dedupAfterMergeAll m = do
    stats <- mStats m
    counts <- mDedupCounts m
    let surplus = max 0 (dcUrlRecords counts - dcUrlGroups counts)
    pure (max 0 (lsTotal stats - surplus))

dedupBody :: Model -> [View () () Model Action]
dedupBody m
    | mDedupLoading m && isNothing (mDedupCounts m) && null (mDedupUrlGroups m) && null (mDedupTitleGroups m) =
        [H.p_ [HP.class_ "pnl-quiet"] [text "Finding duplicate candidates."]]
    | Just message <- mDedupError m
    , isNothing (mDedupCounts m) =
        [panelError "read failed" "The duplicate test did not run." (Just message)]
    | dedupIsEmpty m =
        [ emptyPanel
            "0 groups"
            "No duplicates."
            "No record shares a canonical URL, and no two records on one source share a normalised title."
            []
        ]
    | otherwise =
        dedupAfterBanner m
            ++ [dedupUrlSection m, dedupTitleSection m]

dedupIsEmpty :: Model -> Bool
dedupIsEmpty m =
    null (mDedupUrlGroups m)
        && null (mDedupTitleGroups m)
        && case mDedupCounts m of
            Nothing -> False
            Just counts -> dcUrlGroups counts == 0 && dcTitleGroups counts == 0

{- | After a merge the panel names what changed and offers the two exits: undo
the snapshot, or read the candidates again. No silent refetch.
-}
dedupAfterBanner :: Model -> [View () () Model Action]
dedupAfterBanner m =
    case mDedupMergeAllReport m of
        Just report -> [mergeAllBanner report]
        Nothing -> case mDedupLast m of
            Just (merged, keeper) -> [singleMergeBanner merged keeper]
            Nothing -> []

mergeAllBanner :: DedupMergeAllReport -> View () () Model Action
mergeAllBanner report =
    H.div_
        [HP.class_ "dd-after", HP.role_ "status", HP.data_ "testid" "dedup-merge-all-after"]
        [ H.p_
            [HP.class_ "dd-after-text"]
            [ text
                ( ms
                    ( "Merged "
                        <> show (dmGroups report)
                        <> (if dmGroups report == 1 then " group" else " groups")
                        <> " · "
                        <> show (dmRecords report)
                        <> (if dmRecords report == 1 then " record" else " records")
                        <> ". One undo snapshot covers it."
                    )
                )
            ]
        , H.div_
            [HP.class_ "dd-actions"]
            [ H.button_
                [HP.class_ "btn btn--sm", HP.type_ "button", HP.data_ "testid" "dedup-undo", HE.onClick UndoRun]
                [text "undo the merge"]
            , H.button_
                [HP.class_ "btn btn--sm", HP.type_ "button", HP.data_ "testid" "dedup-refresh", HE.onClick DedupRefresh]
                [text "refresh the candidates"]
            ]
        ]

singleMergeBanner :: Int -> Int -> View () () Model Action
singleMergeBanner merged keeper =
    H.div_
        [HP.class_ "dd-after", HP.role_ "status", HP.data_ "testid" "dedup-after-merge"]
        [ H.p_
            [HP.class_ "dd-after-text"]
            [ text
                ( ms
                    ( "Merged "
                        <> show merged
                        <> (if merged == 1 then " duplicate into " else " duplicates into ")
                        <> fromMisoString (accno keeper)
                        <> ". Undo lives in Maintenance."
                    )
                )
            ]
        , H.div_
            [HP.class_ "dd-actions"]
            [ H.button_
                [HP.class_ "btn btn--sm", HP.type_ "button", HP.data_ "testid" "dedup-undo", HE.onClick UndoRun]
                [text "undo the merge"]
            , H.button_
                [HP.class_ "btn btn--sm", HP.type_ "button", HP.data_ "testid" "dedup-refresh", HE.onClick DedupRefresh]
                [text "refresh the candidates"]
            ]
        ]

-- ------------------------------------------------------ same-URL section ---

dedupUrlSection :: Model -> View () () Model Action
dedupUrlSection m =
    H.section_
        [HP.class_ "dd-sec", HP.data_ "testid" "dedup-url-section"]
        ( [ secHead "Same URL" countLine
          , H.p_
                [HP.class_ "dd-lede meta"]
                [text "Same page, different address. Merging keeps the oldest record, upgrades it to https when a copy has it, unions tags and notes, and writes one undo snapshot."]
          , H.div_
                [HP.class_ "dd-toolbar"]
                [ H.button_
                    ( [ HP.class_ "btn btn--strong"
                      , HP.type_ "button"
                      , HP.data_ "testid" "dedup-merge-all"
                      , HE.onClick DedupMergeAllOpen
                      ]
                        ++ attrDisabled (mergeAllBlocked m)
                    )
                    [text (mergeAllLabel m)]
                ]
          ]
            ++ ( if null (mDedupUrlGroups m)
                    then
                        [ H.p_
                            [HP.class_ "dd-note meta"]
                            [text "No same-URL duplicates left."]
                        | urlGroups > 0
                        ]
                    else
                        [ H.div_
                            [HP.class_ "dd-groups", HP.data_ "testid" "dedup-url-groups"]
                            (zipWith (dedupGroupView m) [0 :: Int ..] (mDedupUrlGroups m))
                        , showMoreButton "dedup-more-url" DedupMoreUrl (mDedupMoreBusy m) (dedupHasMoreUrl m)
                        ]
               )
        )
  where
    counts = mDedupCounts m
    urlGroups = maybe 0 dcUrlGroups counts
    urlRecords = maybe 0 dcUrlRecords counts
    countLine =
        ms
            ( show urlGroups
                <> (if urlGroups == 1 then " group · " else " groups · ")
                <> show urlRecords
                <> " records in all"
            )
    mergeAllBlocked model =
        mDedupBusy model
            || mDedupLoading model
            || urlGroups == 0
            || null (mDedupUrlGroups model)
    mergeAllLabel model
        | mDedupBusy model = "merging..."
        | otherwise =
            "merge all "
                <> num urlGroups
                <> " URL duplicate group"
                <> (if urlGroups == 1 then "" else "s")

-- ------------------------------------------------ title review section ---

dedupTitleSection :: Model -> View () () Model Action
dedupTitleSection m =
    H.section_
        [HP.class_ "dd-sec", HP.data_ "testid" "dedup-title-section"]
        ( [ secHead "Same title, review only" countLine
          , H.p_
                [HP.class_ "dd-lede meta"]
                [text "Same title on one source, possibly different pages. Review each group; nothing here is merged in bulk."]
          ]
            ++ ( if null (mDedupTitleGroups m)
                    then
                        [ H.p_
                            [HP.class_ "dd-note meta"]
                            [text "No same-title groups left."]
                        | titleGroups > 0
                        ]
                    else
                        [ H.div_
                            [HP.class_ "dd-groups", HP.data_ "testid" "dedup-title-groups"]
                            (zipWith (dedupGroupView m) [0 :: Int ..] (mDedupTitleGroups m))
                        , showMoreButton "dedup-more-title" DedupMoreTitle (mDedupMoreBusy m) (dedupHasMoreTitle m)
                        ]
               )
        )
  where
    counts = mDedupCounts m
    titleGroups = maybe 0 dcTitleGroups counts
    titleRecords = maybe 0 dcTitleRecords counts
    countLine =
        ms
            ( show titleGroups
                <> (if titleGroups == 1 then " group · " else " groups · ")
                <> show titleRecords
                <> " records in all"
            )

showMoreButton :: MisoString -> Action -> Bool -> Bool -> View () () Model Action
showMoreButton hook action busy more =
    H.div_
        [HP.class_ "dd-more"]
        [ H.button_
            ( [ HP.class_ "btn btn--sm"
              , HP.type_ "button"
              , HP.data_ "testid" hook
              , HE.onClick action
              ]
                ++ attrDisabled (busy || not more)
            )
            [text (if busy then "reading..." else "show more")]
        | more
        ]

dedupHasMoreUrl :: Model -> Bool
dedupHasMoreUrl m = case mDedupCounts m of
    Nothing -> False
    Just counts -> length (mDedupUrlGroups m) < dcUrlGroups counts

dedupHasMoreTitle :: Model -> Bool
dedupHasMoreTitle m = case mDedupCounts m of
    Nothing -> False
    Just counts -> length (mDedupTitleGroups m) < dcTitleGroups counts

dedupGroupView :: Model -> Int -> DedupGroup -> View () () Model Action
dedupGroupView m groupIndex group@(DedupGroup key _ items) =
    H.section_
        [ key_ key
        , HP.class_ "dd-group"
        , HP.data_ "testid" "dedup-group"
        ]
        [ H.div_
            [HP.class_ "dd-head"]
            [ H.span_ [HP.class_ "dd-no mono"] [text (pad2 (groupIndex + 1))]
            , H.span_ [HP.class_ "dd-reason"] [text (ms (T.unpack key))]
            , H.span_ [HP.class_ "dd-count meta"] [text (ms (show (length items) <> if length items == 1 then " record" else " records"))]
            , H.span_ [HP.class_ "dd-act"] []
            ]
        , H.div_
            [HP.class_ "dd-rows", HP.role_ "radiogroup", HP.aria_ "label" "Keep one copy"]
            (map (dedupRow m key kept) items)
        , H.div_
            [HP.class_ "dd-foot"]
            [ H.span_ [HP.class_ "dd-sum"] [text (ms (keepSummary kept items))]
            , H.span_
                [HP.class_ "dd-actions"]
                [ smallAction "open the kept record" (Navigate (Bookmark kept))
                , strongAction
                    (ms ("merge " <> show (max 0 (length items - 1)) <> " into 1"))
                    [HP.data_ "testid" "dedup-merge"]
                    (DedupMerge key)
                ]
            ]
        ]
  where
    kept = dedupKeep m group

dedupRow :: Model -> Text -> Int -> BookmarkSummary -> View () () Model Action
dedupRow _m key kept item =
    H.label_
        [HP.class_ ("dd-row" <> if kept == bsId item then " is-keep" else "")]
        [ H.input_
            ( [ key_ (bsId item)
              , HP.class_ "dd-radio"
              , HP.type_ "radio"
              , HP.name_ (ms ("keep-" <> T.unpack key))
              , HP.aria_ "label" (ms ("Keep " <> T.unpack (bsTitle item)))
              , HP.data_ "testid" "dedup-keep"
              , HE.onClick (DedupKeep key (bsId item))
              ]
                ++ attrChecked (kept == bsId item)
            )
        , H.span_ [HP.class_ "dd-mark", HP.aria_ "hidden" "true"] []
        , H.span_ [HP.class_ "dd-c-no mono"] [text (accno (bsId item))]
        , H.span_ [HP.class_ "dd-c-title"] [text (ms (bsTitle item))]
        , H.span_
            [HP.class_ "dd-c-src"]
            [ H.span_ [HP.class_ "mono-badge", HP.aria_ "hidden" "true"] [text (ms (monogram (bsDomain item)))]
            , H.span_ [HP.class_ "dom meta"] [text (showDomain (bsDomain item))]
            ]
        , H.span_ [HP.class_ "dd-c-filed meta"] [text (formatFiled (bsCreatedAt item))]
        , H.span_ [HP.class_ "dd-c-tags meta"] [text (tagLine (bsTags item))]
        ]

{- | The merge confirmation for one group: the keeper and every absorbed copy
named, and the side effects stated before the write. Nothing is merged until
the confirm button is pressed.
-}
dedupMergeDialog :: Model -> View () () Model Action
dedupMergeDialog m = case mDedupConfirm m >>= dedupFindGroup m of
    Nothing -> H.span_ [] []
    Just group ->
        let items = dgItems group
            keep = dedupKeep m group
            absorbed = filter ((/= keep) . bsId) items
            keeper =
                [ item
                | item <- items
                , bsId item == keep
                ]
         in H.div_
                [HP.class_ "overlay is-open", HP.data_ "testid" "dialog", HE.onClick DedupMergeCancel]
                [ H.div_
                    [ HP.class_ "dialog"
                    , HP.data_ "testid" "dialog-dedup-merge"
                    , HP.role_ "dialog"
                    , HP.aria_ "modal" "true"
                    , HP.aria_ "label" "Merge duplicate records"
                    , HE.onClickWithOptions stopPropagation Noop
                    ]
                    [ confirmationHead "Merge duplicates"
                    , H.div_
                        [HP.class_ "dialog__body", HP.data_ "testid" "dialog-body"]
                        [ H.p_
                            [HP.class_ "read"]
                            [ text
                                ( ms
                                    ( "Keep one copy and absorb "
                                        <> show (length absorbed)
                                        <> (if length absorbed == 1 then " record into it." else " records into it.")
                                    )
                                )
                            ]
                        , H.div_
                            [HP.class_ "dd-dialog-list"]
                            ( [dedupDialogRow "keeper" item | item <- keeper]
                                ++ [dedupDialogRow "absorbed" item | item <- absorbed]
                            )
                        , H.p_
                            [HP.class_ "dd-dialog-warn read"]
                            [text "Notes, highlights, tags and cross-references from the absorbed copies are folded onto the keeper. The merge writes an undo snapshot first, so it can be undone from Maintenance."]
                        ]
                    , H.div_
                        [HP.class_ "dialog__foot"]
                        [ H.span_ [HP.class_ "spacer"] []
                        , H.button_
                            [ HP.class_ "btn"
                            , HP.type_ "button"
                            , HP.data_ "testid" "dialog-cancel"
                            , HP.autofocus_ True
                            , HE.onClick DedupMergeCancel
                            ]
                            [text "cancel"]
                        , H.button_
                            ( [ HP.class_ "btn btn--strong"
                              , HP.type_ "button"
                              , HP.data_ "testid" "dialog-confirm"
                              , HE.onClick DedupMergeConfirm
                              ]
                                ++ attrDisabled (null absorbed || mDedupBusy m)
                            )
                            [text "merge the records"]
                        ]
                    ]
                ]

-- --------------------------------------------------- merge-all dialog ----

{- | The one-shot URL merge confirmation: exact counts, the keeper policy, the
title-match exclusion, and the single undo snapshot. Cancel is focused first;
confirm is disabled while the write is in flight.
-}
dedupMergeAllDialog :: Model -> View () () Model Action
dedupMergeAllDialog m =
    H.div_
        [HP.class_ "overlay is-open", HP.data_ "testid" "dialog", HE.onClick DedupMergeAllCancel]
        [ H.div_
            [ HP.class_ "dialog"
            , HP.data_ "testid" "dialog-dedup-merge-all"
            , HP.role_ "dialog"
            , HP.aria_ "modal" "true"
            , HP.aria_ "label" "Merge all URL duplicates"
            , HE.onClickWithOptions stopPropagation Noop
            ]
            [ confirmationHead "Merge all URL duplicates"
            , H.div_
                [HP.class_ "dialog__body", HP.data_ "testid" "dialog-body"]
                [ H.p_
                    [HP.class_ "read"]
                    [ text
                        ( ms
                            ( "Merge "
                                <> show urlGroups
                                <> (if urlGroups == 1 then " URL duplicate group (" else " URL duplicate groups (")
                                <> show urlRecords
                                <> " records) into one record each, absorbing "
                                <> show (max 0 (urlRecords - urlGroups))
                                <> " duplicate records."
                            )
                        )
                    ]
                , H.p_
                    [HP.class_ "read"]
                    [text "The oldest record in each group is kept, and its address is upgraded to https when a copy has that form. Title matches are not touched. Tags, notes, highlights and links from the absorbed copies are folded onto the keeper, and the whole pass writes one undo snapshot."]
                ]
            , H.div_
                [HP.class_ "dialog__foot"]
                [ H.span_ [HP.class_ "spacer"] []
                , H.button_
                    [ HP.class_ "btn"
                    , HP.type_ "button"
                    , HP.data_ "testid" "dialog-cancel"
                    , HP.autofocus_ True
                    , HE.onClick DedupMergeAllCancel
                    ]
                    [text "cancel"]
                , H.button_
                    ( [ HP.class_ "btn btn--strong"
                      , HP.type_ "button"
                      , HP.data_ "testid" "dialog-confirm"
                      , HE.onClick DedupMergeAllConfirm
                      ]
                        ++ attrDisabled (mDedupBusy m || urlGroups == 0)
                    )
                    [text (if mDedupBusy m then "merging..." else "merge all " <> num urlGroups <> " groups")]
                ]
            ]
        ]
  where
    counts = mDedupCounts m
    urlGroups = maybe 0 dcUrlGroups counts
    urlRecords = maybe 0 dcUrlRecords counts

dedupFindGroup :: Model -> Text -> Maybe DedupGroup
dedupFindGroup m key =
    case filter ((== key) . dgKey) (mDedupUrlGroups m ++ mDedupTitleGroups m) of
        (group : _) -> Just group
        [] -> Nothing

dedupDialogRow :: MisoString -> BookmarkSummary -> View () () Model Action
dedupDialogRow roleLabel bookmark =
    H.div_
        [HP.class_ "dd-dialog-row"]
        [ H.span_ [HP.class_ "dd-dialog-role sc"] [text roleLabel]
        , H.span_ [HP.class_ "dd-dialog-no mono"] [text (accno (bsId bookmark))]
        , H.span_ [HP.class_ "dd-dialog-title"] [text (ms (bsTitle bookmark))]
        , H.span_ [HP.class_ "dd-dialog-src meta"] [text (showDomain (bsDomain bookmark))]
        ]

{- | The keeper the client action will use: the explicit choice when there is
one, otherwise the first member of the group (matching Update's fallback).
-}
dedupKeep :: Model -> DedupGroup -> Int
dedupKeep m group = case dgItems group of
    [] -> 0
    (firstItem : _) ->
        fromMaybe (bsId firstItem) (M.lookup (dgKey group) (mDedupChoice m))

keepSummary :: Int -> [BookmarkSummary] -> String
keepSummary kept items =
    "keep "
        <> T.unpack (accnoText kept)
        <> " · absorb "
        <> show (max 0 (length items - 1))
        <> " · notes, highlights and tags union"

monogram :: Text -> String
monogram domain = case T.unpack (T.replace "www." "" domain) of
    (c : _) -> [toUpper c]
    [] -> "?"

tagLine :: [Text] -> MisoString
tagLine tags = ms (T.unpack (T.intercalate " · " (take 3 tags)))

accnoText :: Int -> Text
accnoText bookmarkId = T.pack ("EA-" <> pad 5 (show bookmarkId))
  where
    pad width value
        | length value >= width = value
        | otherwise = replicate (width - length value) '0' ++ value

-- =================================================================== tags ===

tagsPage :: Model -> View () () Model Action
tagsPage m =
    pageWith
        "Tags"
        "The working vocabulary of the library, every tag counted, and the near misses that are worth a decision."
        (tagsFigures m)
        [ "counts from bookmark_tags"
        , "rename, detach and merge write a snapshot first"
        ]
        ( [ H.div_
                [HP.class_ "tg-grid"]
                [ tagsTable m
                , H.aside_ [HP.class_ "tg-side"] (consolidationBlock m ++ tagsMethodBlock)
                ]
          ]
            ++ [tagDialogView m | isJust (mTagDialog m)]
        )

tagsFigures :: Model -> [View () () Model Action]
tagsFigures m =
    [ figure "tags" (statIntFields m lsTags (length (mTags m)))
    , figure "tag links" (statIntFields m lsTagLinks (sum (map tsCount (mTags m))))
    , figure "entries" (statIntFields m lsTotal 0)
    ]

tagCountText :: Model -> MisoString
tagCountText m =
    statIntFields m lsTags (length (mTags m))
        <> " tags, ranked by entries"

tagsTable :: Model -> View () () Model Action
tagsTable m =
    H.section_
        [HP.class_ "tg-main"]
        [ H.div_
            [HP.class_ "pnl-sec-head"]
            [ H.h2_ [HP.class_ "pnl-sec-title"] [text "All tags"]
            , H.span_ [HP.class_ "meta"] [text (tagCountText m)]
            ]
        , H.div_
            [HP.class_ "tg-table-wrap"]
            [ H.table_
                [HP.class_ "tg-table"]
                [ H.thead_
                    []
                    [ H.tr_
                        []
                        [ H.th_ [HP.class_ "tg-no r"] [text "no."]
                        , H.th_ [] [text "tag"]
                        , H.th_ [HP.class_ "r"] [text "entries"]
                        , H.th_ [HP.class_ "r"] [text "of entries"]
                        , H.th_ [HP.class_ "r"] [text "actions"]
                        ]
                    ]
                , H.tbody_ [] (map (tagRow m) (zip [1 :: Int ..] (sortOn (negate . tsCount) (mTags m))))
                ]
            ]
        ]

tagRow :: Model -> (Int, TagStat) -> View () () Model Action
tagRow m (index, tag) =
    H.tr_
        [key_ (tsName tag)]
        [ H.td_ [HP.class_ "tg-no mono"] [text (pad2 index)]
        , H.td_
            [HP.class_ "tg-name-cell"]
            [ H.button_
                [HP.class_ "tg-name", HP.type_ "button", HE.onClick (FilterByTag (tsName tag))]
                [text (ms (tsName tag))]
            ]
        , H.td_ [HP.class_ "tg-n mono"] [text (num (tsCount tag))]
        , H.td_ [HP.class_ "tg-pct mono"] [text (shareText m (tsCount tag))]
        , H.td_
            [HP.class_ "tg-actions"]
            [ H.button_
                [ HP.class_ "account-link"
                , HP.type_ "button"
                , HP.data_ "testid" "tag-rename"
                , HP.aria_ "label" ("Rename " <> ms (tsName tag))
                , HE.onClick (TagDialogOpen (TagRenameDialog (tsName tag)))
                ]
                [text "rename"]
            , H.button_
                [ HP.class_ "account-link account-link--danger"
                , HP.type_ "button"
                , HP.data_ "testid" "tag-delete"
                , HP.aria_ "label" ("Remove " <> ms (tsName tag))
                , HE.onClick (TagDialogOpen (TagDeleteDialog (tsName tag)))
                ]
                [text (if tsCount tag > 0 then "detach" else "delete")]
            ]
        ]

shareText :: Model -> Int -> MisoString
shareText m count = case lsTotal <$> mStats m of
    Nothing -> "not yet"
    Just 0 -> "0.0%"
    Just total -> ms (oneDecimal (fromIntegral count * 100 / fromIntegral total :: Double) <> "%")

-- | 97.797 becomes 97.8.
oneDecimal :: Double -> String
oneDecimal value =
    let tenths = round (value * 10) :: Int
        whole = tenths `div` 10
        rest = abs (tenths `mod` 10)
     in show whole <> "." <> show rest

{- | The consolidation candidates the server computed. Nothing here is a
fixture: the list is empty when there is nothing to consolidate.
-}
consolidationBlock :: Model -> [View () () Model Action]
consolidationBlock m =
    [ H.section_
        [HP.class_ "pnl-block"]
        [ secHead "Consolidation" (ms (show (length (mConsol m)) <> " groups"))
        , case mConsolError m of
            Just message ->
                panelError "read failed" "The consolidation scan did not run." (Just message)
            Nothing -> case mConsol m of
                _
                    | mConsolLoading m && null (mConsol m) -> quietNote "Scanning tags."
                    | otherwise -> consolRows
        , H.p_
            [HP.class_ "pnl-quiet"]
            [text "The tags table is unique by name, but SQLite's case folding covers ASCII only, so a case group here is two names that differ outside ASCII. Near misses are pairs of names worth a review."]
        ]
    ]
  where
    consolRows
        | null (mConsol m) =
            quietNote "None. No case or near-duplicate names were found."
        | otherwise = H.div_ [] (map consolRow (mConsol m))

consolRow :: ConsolGroup -> View () () Model Action
consolRow group =
    H.div_
        [HP.class_ "fz"]
        ( [ H.span_ [HP.class_ "fz-pair"] (map tagChipButton (cgTags group))
          , H.span_ [HP.class_ "fz-meta meta"] [text (ms (kindLabel (cgKind group)))]
          ]
            ++ suggestionAction
        )
  where
    kindLabel :: Text -> MisoString
    kindLabel kind = case kind of
        "junk" -> "junk · prune the name"
        "case" -> "case duplicate"
        "fuzzy" -> "near duplicate"
        _ -> ms (T.toTitle kind)
    suggestionAction
        | T.null (T.strip (cgSuggested group)) = []
        | otherwise =
            [ H.span_ [HP.class_ "fz-d mono"] [text (ms (cgSuggested group))]
            , strongAction
                (ms ("merge into " <> T.unpack (cgSuggested group)))
                [HP.data_ "testid" "tag-merge"]
                (TagDialogOpen (TagMergeDialog (map tsName (cgTags group)) (cgSuggested group)))
            ]

tagChipButton :: TagStat -> View () () Model Action
tagChipButton tag =
    H.button_
        [ HP.class_ "tagpill"
        , HP.type_ "button"
        , HP.title_ "Remove this tag"
        , HP.data_ "testid" "tag-chip-remove"
        , HE.onClick (TagDialogOpen (TagDeleteDialog (tsName tag)))
        ]
        [ text (ms (tsName tag))
        , H.span_ [HP.class_ "chip-x"] [text " ×"]
        ]

-- | The count a tag carries in the loaded table, used by the delete dialog.
tagCountFor :: Model -> Text -> Int
tagCountFor m tag = case [entry | entry <- mTags m, tsName entry == tag] of
    (entry : _) -> tsCount entry
    [] -> 0

{- | Rename, delete/detach and merge all ask for confirmation here. The dialog
opens from the tag table and the consolidation list and never runs a write
itself: the confirm button leaves through the same actions the API uses.
-}
tagDialogView :: Model -> View () () Model Action
tagDialogView m = case mTagDialog m of
    Nothing -> H.span_ [] []
    Just dialog ->
        let (hook, title) = case dialog of
                TagRenameDialog _ -> ("dialog-tag-rename" :: MisoString, "Rename tag" :: MisoString)
                TagDeleteDialog _ -> ("dialog-tag-delete", "Remove tag")
                TagMergeDialog _ _ -> ("dialog-tag-merge", "Merge tags")
            primary = case dialog of
                TagRenameDialog _ ->
                    [ H.button_
                        ( [ HP.class_ "btn btn--strong"
                          , HP.type_ "button"
                          , HP.data_ "testid" "dialog-confirm"
                          , HE.onClick TagDialogConfirm
                          ]
                            ++ attrDisabled (mTagDialogBusy m)
                        )
                        [text "rename the tag"]
                    ]
                TagDeleteDialog tag
                    | tagCountFor m tag > 0 ->
                        [ H.button_
                            ( [ HP.class_ "btn btn--danger"
                              , HP.type_ "button"
                              , HP.data_ "testid" "dialog-confirm"
                              , HP.data_ "detach" "true"
                              , HE.onClick TagDialogDetach
                              ]
                                ++ attrDisabled (mTagDialogBusy m)
                            )
                            [text "detach from the records"]
                        ]
                    | otherwise ->
                        [ H.button_
                            ( [ HP.class_ "btn btn--danger"
                              , HP.type_ "button"
                              , HP.data_ "testid" "dialog-confirm"
                              , HE.onClick TagDialogConfirm
                              ]
                                ++ attrDisabled (mTagDialogBusy m)
                            )
                            [text "delete the tag"]
                        ]
                TagMergeDialog _ _ ->
                    [ H.button_
                        ( [ HP.class_ "btn btn--strong"
                          , HP.type_ "button"
                          , HP.data_ "testid" "dialog-confirm"
                          , HE.onClick TagDialogConfirm
                          ]
                            ++ attrDisabled (mTagDialogBusy m)
                        )
                        [text "merge the tags"]
                    ]
         in H.div_
                [HP.class_ "overlay is-open", HP.data_ "testid" "dialog", HE.onClick TagDialogClose]
                [ H.div_
                    [ HP.class_ "dialog"
                    , HP.data_ "testid" hook
                    , HP.role_ "dialog"
                    , HP.aria_ "modal" "true"
                    , HP.aria_ "label" title
                    , HE.onClickWithOptions stopPropagation Noop
                    ]
                    [ confirmationHead title
                    , H.div_
                        [HP.class_ "dialog__body", HP.data_ "testid" "dialog-body"]
                        (tagDialogBody m dialog ++ confirmationError (mTagDialogError m))
                    , H.div_
                        [HP.class_ "dialog__foot"]
                        ( [ H.span_ [HP.class_ "spacer"] []
                          , H.button_
                                ( [ HP.class_ "btn"
                                  , HP.type_ "button"
                                  , HP.data_ "testid" "dialog-cancel"
                                  , HE.onClick TagDialogClose
                                  ]
                                    ++ [ HP.autofocus_ True
                                       | case dialog of
                                            TagRenameDialog _ -> False
                                            _ -> True
                                       ]
                                )
                                [text "cancel"]
                          ]
                            ++ primary
                        )
                    ]
                ]

tagDialogBody :: Model -> TagDialog -> [View () () Model Action]
tagDialogBody m dialog = case dialog of
    TagRenameDialog tag ->
        [ H.p_
            [HP.class_ "read"]
            [ text (ms (tsName' tag <> " is filed on "))
            , H.strong_ [] [text (num (tagCountFor m tag))]
            , text " records. The records keep the tag; only the name changes."
            ]
        , H.div_
            [HP.class_ "field"]
            [ H.label_
                [HP.class_ "field-label", HP.for_ "tag-rename-input"]
                [text "new name"]
            , H.input_
                [ HP.id_ "tag-rename-input"
                , HP.class_ "input"
                , HP.type_ "text"
                , HP.autofocus_ True
                , HP.autocomplete_ "off"
                , HP.value_ (mTagDialogInput m)
                , HE.onInput TagDialogInput
                , HE.onKeyDown
                    ( \code -> case code of
                        KeyCode 13 -> TagDialogConfirm
                        _ -> Noop
                    )
                ]
            ]
        ]
    TagDeleteDialog tag ->
        let count = tagCountFor m tag
         in [ H.p_
                [HP.class_ "read"]
                ( [text (ms (tsName' tag <> " is filed on ")), text (num count)]
                    ++ [ text
                            ( " records. The records stay in the library; only the tag name is removed from them." ::
                                MisoString
                            )
                       | count > 0
                       ]
                    ++ [text " records." | count == 0]
                )
            , H.p_
                [HP.class_ "read"]
                [text "Detach removes the name from every record that carries it and leaves the records in place. Delete is only offered for an empty tag. Either way a snapshot is written first."]
            ]
    TagMergeDialog from into ->
        [ H.p_
            [HP.class_ "read"]
            [text (ms ("Fold " <> listText from <> " into " <> tsName' into <> ". Every record carrying one of those names is refiled under the keeper."))]
        , H.div_
            [HP.class_ "tg-dialog-pair"]
            ( [ H.span_
                    [HP.class_ "tagpill"]
                    [ text (ms (tsName' into))
                    , H.span_ [HP.class_ "meta"] [text (ms (" · " <> show (tagCountFor m into) <> " entries"))]
                    ]
              ]
                ++ [ H.span_
                        [HP.class_ "tagpill tagpill--sug"]
                        [ text (ms (tsName' name))
                        , H.span_ [HP.class_ "meta"] [text (ms (" · " <> show (tagCountFor m name) <> " entries"))]
                        ]
                   | name <- from
                   ]
            )
        , H.p_
            [HP.class_ "read"]
            [text "Merge writes an undo snapshot first; undo lives in Maintenance."]
        ]
  where
    tsName' :: Text -> String
    tsName' = T.unpack
    listText :: [Text] -> String
    listText names = case names of
        [] -> "the tags"
        [one] -> T.unpack one
        many -> T.unpack (T.intercalate ", " (init many)) <> " and " <> T.unpack (last many)

tagsMethodBlock :: [View () () Model Action]
tagsMethodBlock =
    [ H.section_
        [HP.class_ "pnl-block"]
        [ secHead "Making changes" "undo snapshot"
        , H.p_
            [HP.class_ "pnl-quiet"]
            [text "Click a tag name to filter the library by it. Rename and delete ask for confirmation in a dialog; delete offers detaching a non-empty name, which removes the tag from its records and leaves the records in place. Merge in a consolidation group folds the other names into the suggested keeper. Every change writes an undo snapshot first."]
        ]
    ]

-- ================================================================ ai tags ===

aiTagsPage :: Model -> View () () Model Action
aiTagsPage m =
    pageWith
        "AI tags"
        "Advisory suggestions for records the vocabulary has not reached yet. A suggestion is written only when you apply it."
        (aiFigures m)
        [ "provider status read from the environment"
        , "nothing written until apply"
        ]
        ( aiBanner m
            : H.div_
                [HP.class_ "ai-picker"]
                [ H.div_
                    [HP.class_ "pnl-sec-head"]
                    [ H.h2_ [HP.class_ "pnl-sec-title"] [text "Bucket"]
                    , H.span_ [HP.class_ "meta"] [text "the tag the suggestions should serve"]
                    ]
                , H.div_
                    [HP.class_ "ai-chips", C.styleInline_ "max-height:150px;overflow-y:auto"]
                    (allBucketButton m : map (bucketButton m) (mTags m))
                ]
            : suggestionSection m
        )

aiFigures :: Model -> [View () () Model Action]
aiFigures m =
    [ figure "provider" (providerName m)
    , figure "suggestions" (ms (show (length (mSuggestions m))))
    , figure "buckets" (num (length (mTags m)))
    ]

providerName :: Model -> MisoString
providerName m = case mAiStatus m of
    Nothing -> "not loaded"
    Just status
        | T.null (asProvider status) -> "none"
        | otherwise -> ms (asProvider status)

allBucketButton :: Model -> View () () Model Action
allBucketButton m =
    H.button_
        [ HP.class_ ("ai-chip" <> if mAiTag m == Nothing then " is-on" else "")
        , HP.type_ "button"
        , HE.onClick (AiTagSelected Nothing)
        ]
        [text "all"]

bucketButton :: Model -> TagStat -> View () () Model Action
bucketButton m tag =
    H.button_
        [ HP.class_ ("ai-chip" <> if mAiTag m == Just (tsName tag) then " is-on" else "")
        , HP.type_ "button"
        , HE.onClick (AiTagSelected (Just (tsName tag)))
        ]
        [ text (ms (tsName tag))
        , H.span_ [HP.class_ "n"] [text (num (tsCount tag))]
        ]

aiBanner :: Model -> View () () Model Action
aiBanner m =
    H.div_
        [HP.class_ "ai-banner", testId "ai-banner"]
        ( case mAiStatus m of
            Nothing ->
                [ H.p_
                    [HP.class_ "ai-banner-lead read"]
                    [text "The provider status has not loaded yet. Suggestions are advisory and nothing is written until you apply one."]
                , H.div_
                    [HP.class_ "ai-tools"]
                    [ H.button_
                        [ HP.class_ "btn btn--sm"
                        , HP.type_ "button"
                        , HP.data_ "testid" "ai-status-retry"
                        , HE.onClick AiStatusReload
                        ]
                        [text "read the provider status"]
                    ]
                ]
            Just status ->
                [ H.div_
                    [HP.class_ "ai-banner-head"]
                    [ H.span_ [HP.class_ ("status " <> if asConfigured status then "status--ok" else "status--warn")] [text (if asConfigured status then "configured" else "not configured")]
                    , H.span_ [HP.class_ "ai-banner-meta mono"] [text (ms ("provider " <> T.unpack (asProvider status) <> if T.null (asModel status) then "" else " · model " <> T.unpack (asModel status)))]
                    ]
                , H.p_
                    [HP.class_ "ai-banner-lead read"]
                    ( if asConfigured status
                        then [H.strong_ [] [text "A tag provider is configured."], text " Suggestions arrive from that provider; nothing is written until you apply one."]
                        else
                            [ H.strong_ [] [text "No tag provider is configured."]
                            , text " eza reads ANTHROPIC_API_KEY or OPENAI_API_KEY at runtime, or uses a local model with EZA_AI_PROVIDER=ollama. Until one is set the suggestion list stays empty."
                            ]
                    )
                ]
                    ++ [ H.dl_
                            [HP.class_ "ai-env"]
                            [ H.div_ [] [H.dt_ [HP.class_ "mono"] [text "ANTHROPIC_API_KEY"], H.dd_ [HP.class_ "meta"] [text "read from the environment at runtime"]]
                            , H.div_ [] [H.dt_ [HP.class_ "mono"] [text "OPENAI_API_KEY"], H.dd_ [HP.class_ "meta"] [text "read from the environment at runtime"]]
                            , H.div_ [] [H.dt_ [HP.class_ "mono"] [text "EZA_AI_PROVIDER"], H.dd_ [HP.class_ "meta"] [text "set to ollama for a local model"]]
                            ]
                       | not (asConfigured status)
                       ]
        )

suggestionSection :: Model -> [View () () Model Action]
suggestionSection m =
    [ H.div_
        [HP.class_ "pnl-sec-head ai-table-head"]
        [ H.h2_ [HP.class_ "pnl-sec-title"] [text "Suggested tags"]
        , H.span_ [HP.class_ "meta"] [text (ms (show (length (mSuggestions m)) <> " sets"))]
        , H.span_ [HP.class_ "ai-fixture"] [text "advisory"]
        ]
    , suggestionBody m
    , H.div_
        [HP.class_ "ai-tools"]
        ( [ H.button_
                ( [ HP.class_ "btn btn--sm"
                  , HP.type_ "button"
                  , HP.data_ "testid" "ai-retry"
                  , HE.onClick AiSuggestRetry
                  ]
                    ++ attrDisabled (mAiTag m == Nothing)
                )
                [text "ask again"]
          ]
            ++ [ H.button_
                    [ HP.class_ "btn btn--sm btn--ghost"
                    , HP.type_ "button"
                    , HP.data_ "testid" "ai-discard"
                    , HE.onClick AiSuggestDiscard
                    ]
                    [text "discard the suggestions"]
               | not (null (mSuggestions m))
               ]
        )
    , H.p_
        [HP.class_ "ai-foot"]
        [ H.span_ [HP.class_ "meta"] [text "suggestions are advisory"]
        , H.span_ [HP.class_ "meta"] [text "apply writes the tags to the record"]
        ]
    ]

suggestionBody :: Model -> View () () Model Action
suggestionBody m
    | mSuggestionsLoading m && null (mSuggestions m) = quietNote "Asking the provider."
    | Just message <- mSuggestionError m =
        H.div_
            [HP.class_ "ai-provider-error", HP.role_ "alert"]
            [ H.p_ [HP.class_ "ai-error-title display"] [text "The provider did not answer."]
            , H.p_ [HP.class_ "ai-error-body read"] [text message]
            , H.div_
                [HP.class_ "ai-tools"]
                [ smallAction "try again" AiSuggestRetry
                ]
            ]
    | null (mSuggestions m) =
        H.div_
            []
            ( quietNote (noSuggestionsText m)
                : [ H.p_ [HP.class_ "ai-notice read"] [text notice]
                  | Just notice <- [mSuggestionNotice m]
                  ]
            )
    | otherwise =
        H.div_
            []
            ( [ H.p_ [HP.class_ "ai-notice read"] [text notice]
              | Just notice <- [mSuggestionNotice m]
              ]
                ++ [ H.div_
                        [HP.class_ "ai-table-wrap"]
                        [ H.table_
                            [HP.class_ "ai-table"]
                            [ H.thead_
                                []
                                [ H.tr_
                                    []
                                    [ H.th_ [] [text "accession"]
                                    , H.th_ [] [text "record"]
                                    , H.th_ [] [text "suggested"]
                                    , H.th_ [HP.class_ "r"] [text "action"]
                                    ]
                                ]
                            , H.tbody_ [] (map suggestionRow (mSuggestions m))
                            ]
                        ]
                   ]
            )

noSuggestionsText :: Model -> MisoString
noSuggestionsText m
    | mAiTag m == Nothing = "Choose a bucket above to ask for suggestions."
    | Just status <- mAiStatus m, not (asConfigured status) = "No suggestions for this bucket. The provider is not configured, so nothing was asked."
    | otherwise = "No suggestions for this bucket right now."

suggestionRow :: TagSuggestion -> View () () Model Action
suggestionRow suggestion =
    H.tr_
        [key_ (gid suggestion)]
        [ H.td_ [HP.class_ "ai-acc mono"] [text recordCell]
        , H.td_ [HP.class_ "ai-rec"] (titleCell ++ reasonCell)
        , H.td_ [HP.class_ "ai-sug"] (map suggestedTag (tsgTags suggestion))
        , H.td_ [HP.class_ "ai-act"] [actionCell]
        ]
  where
    gid t = case tsgBookmark t of
        Nothing -> 0
        Just bookmark -> bsId bookmark
    recordCell = case tsgBookmark suggestion of
        Nothing -> "record"
        Just bookmark -> accno (bsId bookmark)
    titleCell = case tsgBookmark suggestion of
        Nothing -> []
        Just bookmark ->
            [ H.a_
                [ HP.class_ "ai-rec-title"
                , HP.href_ (ms ("/bookmark/" <> show (bsId bookmark)))
                , HE.onClickPrevent (Navigate (Bookmark (bsId bookmark)))
                ]
                [text (ms (bsTitle bookmark))]
            , H.span_ [HP.class_ "ai-rec-src meta"] [text (showDomain (bsDomain bookmark))]
            ]
    reasonCell =
        if T.null (T.strip (tsgReason suggestion))
            then []
            else [H.span_ [HP.class_ "ai-reason meta"] [text (ms (tsgReason suggestion))]]
    suggestedTag tag = H.span_ [HP.class_ "tagpill tagpill--sug"] [text (ms tag)]
    actionCell = case tsgBookmark suggestion of
        Nothing -> H.span_ [HP.class_ "meta"] [text "no record"]
        Just bookmark ->
            strongAction "apply" [] (SuggestionApply (bsId bookmark) (tsgTags suggestion))

-- ============================================================ maintenance ===

maintenancePage :: Model -> View () () Model Action
maintenancePage m =
    pageWith
        "Maintenance"
        "The dead-link sweep, prune candidates and undo record."
        (maintenanceFigures m)
        (maintenanceProvenance m)
        [ sweepSection m
        , pruneSection m
        , undoSection m
        ]

maintenanceFigures :: Model -> [View () () Model Action]
maintenanceFigures m =
    [ figure "links checked" (maybe "never" num (mCheckedCount m))
    , figure "dead links" (maybe "-" num (mDeadCount m))
    , figure "prunable" (num (length (mPrune m)))
    ]

maintenanceProvenance :: Model -> [MisoString]
maintenanceProvenance m
    | mCheckedCount m == Nothing = ["no dead-link check has been recorded", "merge and prune write snapshots"]
    | otherwise = ["dead-link results from the last sweep", "merge and prune write snapshots"]

sweepState :: Model -> (MisoString, MisoString)
sweepState m
    | mMaintBusy m = ("running", "status--warn")
    | mCheckedCount m == Nothing = ("never run", "status--warn")
    | otherwise = ("finished", "status--ok")

sweepSection :: Model -> View () () Model Action
sweepSection m =
    H.section_
        [HP.class_ "mt-sec", HP.aria_ "label" "Dead-link sweep"]
        [ H.div_
            [HP.class_ "pnl-sec-head"]
            [ H.h2_ [HP.class_ "pnl-sec-title"] [text "Dead-link sweep"]
            , H.span_ [HP.class_ "mt-state"] [H.span_ [HP.class_ ("status " <> stateClass)] [text stateLabel]]
            ]
        , H.dl_
            [HP.class_ "mt-facts"]
            [ H.div_ [] [H.dt_ [] [text "checked"], H.dd_ [HP.class_ "mono"] [text (maybe "never" num (mCheckedCount m))]]
            , H.div_ [] [H.dt_ [] [text "dead"], H.dd_ [HP.class_ "mono"] [text (maybe "-" num (mDeadCount m))]]
            , H.div_ [] [H.dt_ [] [text "status"], H.dd_ [] [H.span_ [HP.class_ ("status " <> stateClass)] [text stateLabel]]]
            ]
        , H.p_ [HP.class_ "mt-note read"] [text sweepNote]
        , H.div_
            [HP.class_ "mt-actions"]
            [ H.button_
                ( [HP.class_ "btn btn--strong", HP.type_ "button", HE.onClick DeadCheckRun]
                    ++ attrDisabled (mMaintBusy m)
                )
                [text (if mMaintBusy m then "working" else "check dead links")]
            , H.span_ [HP.class_ "meta"] [text "HEAD/GET each saved URL, one at a time on the server"]
            ]
        ]
  where
    (stateLabel, stateClass) = sweepState m
    sweepNote
        | mMaintBusy m = "The sweep is running. Results are written to the library when it finishes."
        | mCheckedCount m == Nothing = "No dead-link check has run yet."
        | otherwise = "The last sweep checked saved links and flagged the dead ones. Dead records stay in the ledger, marked, until you prune or delete them."

pruneSection :: Model -> View () () Model Action
pruneSection m =
    H.section_
        [HP.class_ "mt-sec", HP.aria_ "label" "Prune candidates"]
        [ H.div_
            [HP.class_ "pnl-sec-head"]
            [ H.h2_ [HP.class_ "pnl-sec-title"] [text "Prune candidates"]
            , H.span_ [HP.class_ "mt-state"] [H.span_ [HP.class_ "status status--warn"] [text (ms (show (length (mPrune m)) <> " candidates"))]]
            ]
        , H.p_
            [HP.class_ "pnl-rule"]
            [text "Records never opened, added more than a year ago. Prune writes a snapshot first; undo restores the rows, their tags and read state."]
        , H.div_
            [HP.class_ "mt-actions"]
            [ H.button_
                ( [ HP.class_ "btn btn--sm"
                  , HP.type_ "button"
                  , HE.onClick PruneAll
                  ]
                    ++ attrDisabled (null (mPrune m))
                )
                [text "select all"]
            , H.span_ [HP.class_ "meta"] [text (ms (show (length (mPruneSel m)) <> " selected"))]
            , H.span_ [HP.class_ "spacer"] []
            , H.button_
                ( [ HP.class_ "btn btn--sm btn--danger"
                  , HP.type_ "button"
                  , HE.onClick PruneRun
                  ]
                    ++ attrDisabled (null (mPruneSel m) || mMaintBusy m)
                )
                [text (if mConfirmPrune m then "confirm prune" else "prune selected")]
            , H.button_
                ( [HP.class_ "btn btn--sm", HP.type_ "button", HE.onClick PruneCancel]
                    ++ attrDisabled (not (mConfirmPrune m))
                )
                [text "cancel"]
            ]
        , case mPruneError m of
            Just message ->
                panelError "read failed" "The prune candidates could not be read." (Just message)
            Nothing ->
                if null (mPrune m)
                    then quietNote "No prune candidates right now."
                    else
                        H.div_
                            [HP.class_ "mt-table-wrap"]
                            [ H.table_
                                [HP.class_ "mt-table"]
                                [ H.thead_
                                    []
                                    [ H.tr_
                                        []
                                        [ H.th_ [] [text ""]
                                        , H.th_ [] [text "accession"]
                                        , H.th_ [] [text "record"]
                                        , H.th_ [] [text "filed"]
                                        , H.th_ [HP.class_ "r"] [text "state"]
                                        ]
                                    ]
                                , H.tbody_ [] (map (pruneRow m) (mPrune m))
                                ]
                            ]
        ]

pruneRow :: Model -> BookmarkSummary -> View () () Model Action
pruneRow m bookmark =
    H.tr_
        [key_ (bsId bookmark)]
        [ H.td_
            []
            [ H.label_
                [HP.class_ "account-scope"]
                [ H.input_
                    ( [ HP.type_ "checkbox"
                      , HP.aria_ "label" (ms ("Select " <> T.unpack (bsTitle bookmark)))
                      , HE.onClick (PruneToggle (bsId bookmark))
                      ]
                        ++ attrChecked (bsId bookmark `elem` mPruneSel m)
                    )
                , H.span_ [HP.class_ "sr-only"] [text "select"]
                ]
            ]
        , H.td_ [HP.class_ "mono"] [text (accno (bsId bookmark))]
        , H.td_
            [HP.class_ "mt-rec"]
            [ H.a_
                [ HP.href_ (ms ("/bookmark/" <> show (bsId bookmark)))
                , HE.onClickPrevent (Navigate (Bookmark (bsId bookmark)))
                ]
                [text (ms (bsTitle bookmark))]
            , H.span_ [HP.class_ "meta"] [text (showDomain (bsDomain bookmark))]
            ]
        , H.td_ [HP.class_ "mono"] [text (formatFiled (bsCreatedAt bookmark))]
        , H.td_ [HP.class_ "mono r"] [text (if bsIsRead bookmark then "read" else "unread")]
        ]

undoSection :: Model -> View () () Model Action
undoSection m =
    H.section_
        [HP.class_ "mt-sec", HP.aria_ "label" "Undo record"]
        [ H.div_
            [HP.class_ "pnl-sec-head"]
            [H.h2_ [HP.class_ "pnl-sec-title"] [text "Undo record"]]
        , H.p_
            [HP.class_ "mt-note read"]
            [text "Merge and prune write an undo snapshot before they change anything. Undo restores the rows, their tags and read state."]
        , H.div_
            [HP.class_ "mt-actions"]
            [ H.button_
                ( [HP.class_ "btn", HP.type_ "button", HE.onClick UndoRun]
                    ++ attrDisabled (mMaintBusy m)
                )
                [text "undo last action"]
            , H.span_ [HP.class_ "meta"] [text "the control acts on the last snapshot, if one exists"]
            ]
        ]

-- ================================================================ account ===

accountPage :: Model -> View () () Model Action
accountPage m =
    H.div_
        [HP.class_ "pnl-scroll"]
        [ H.div_
            [HP.class_ "account"]
            [ H.header_
                [HP.class_ "account-head"]
                [ H.div_
                    [HP.class_ "account-headline"]
                    [ H.h1_ [HP.class_ "account-title display"] [text "Account"]
                    , H.p_
                        [HP.class_ "account-lede"]
                        [text "Sessions, tokens, imports and the settings that are not per record."]
                    ]
                ]
            , H.div_
                [HP.class_ "account-body"]
                [ accountIndex m
                , H.div_ [HP.class_ "account-panels"] [activeAccountPanel m]
                ]
            ]
        ]

accountIndex :: Model -> View () () Model Action
accountIndex m =
    H.aside_
        [HP.class_ "account-index", HP.aria_ "label" "Account sections"]
        [ H.h2_ [HP.class_ "account-index-title sc"] [text "Contents"]
        , H.ul_ [HP.class_ "account-nav"] (map (navItem m) tabs)
        ]
  where
    tabs =
        [ (AccountSecurity, "security", "security", Nothing)
        , (AccountPasskeys, "passkeys", "passkeys", credentialCount m)
        , (AccountRecovery, "recovery", "recovery", Nothing)
        , (AccountSessions, "sessions", "sessions", Just (length (mSessions m)))
        , (AccountTokens, "api tokens", "tokens", Just (length (mTokens m)))
        , (AccountWebhooks, "webhooks", "webhooks", Just (length (mWebhooks m)))
        , (AccountShares, "share links", "shares", Just (length (activeShares m)))
        , (AccountRules, "rules", "rules", Just (length (mRules m)))
        , (AccountImport, "import", "import", Nothing)
        , (AccountCapture, "capture", "capture", Nothing)
        , (AccountAppearance, "appearance", "appearance", Nothing)
        , (AccountAbout, "about", "about", Nothing)
        ]
            -- The admin-only item goes last: the async admin probe adds it
            -- after first paint, and appending must not shift the tabs above
            -- it under the reader's pointer.
            ++ [ (AccountUsers, "users", "users", Just (length (mAdminUsers m)))
               | userIsAdmin m
               ]

navItem :: Model -> (AccountTab, MisoString, MisoString, Maybe Int) -> View () () Model Action
navItem m (tab, label, slug, count) =
    H.li_
        []
        [ H.button_
            ( [ HP.type_ "button"
              , HE.onClick (AccountTabSelected tab)
              , testId
                    ( case tab of
                        AccountWebhooks -> "webhooks-tab"
                        AccountUsers -> "account-users-tab"
                        _ -> "account-tab-" <> slug
                    )
              , HP.aria_ "current" (if mAccountTab m == tab then "true" else "false")
              ]
            )
            ( [H.span_ [] [text label]]
                ++ [H.span_ [HP.class_ "account-nav-n"] [text (num value)] | Just value <- [count]]
            )
        ]

credentialCount :: Model -> Maybe Int
credentialCount m = length . aiCredentials <$> mAccount m

activeShares :: Model -> [ShareView]
activeShares m = filter (not . isJust . svRevokedAt) (mShares m)

activeAccountPanel :: Model -> View () () Model Action
activeAccountPanel m = case mAccountTab m of
    AccountSecurity -> securityPanel m
    AccountPasskeys -> passkeysPanel m
    AccountRecovery -> recoveryPanel m
    AccountSessions -> sessionsPanel m
    AccountTokens -> tokensPanel m
    AccountWebhooks -> webhooksPanel m
    AccountUsers -> usersPanel m
    AccountShares -> sharesPanel m
    AccountRules -> rulesPanel m
    AccountImport -> importPanel m
    AccountCapture -> capturePanel m
    AccountAppearance -> appearancePanel m
    AccountAbout -> aboutPanel m

accountPanel ::
    MisoString ->
    MisoString ->
    MisoString ->
    [View () () Model Action] ->
    View () () Model Action
accountPanel slug title note children =
    H.section_
        [HP.class_ "account-panel", testId ("account-panel-" <> slug)]
        ( H.div_
            [HP.class_ "account-panel-head"]
            [ H.h2_ [HP.class_ "account-h2 display"] [text title]
            , H.span_ [HP.class_ "account-panel-note meta"] [text note]
            ]
            : ruleLine
            : children
        )

-- -------------------------------------------------------------- security ---

{- | The sign-in panel: one username, the password, and whether a passkey is
required after it. Every write is confirmed with the current password once one
exists; the server checks it again, so this is an affordance rather than the
authority.
-}
securityPanel :: Model -> View () () Model Action
securityPanel m =
    accountPanel "security" "Sign-in" panelNote (body (mAccount m))
  where
    panelNote = case mAccount m of
        Nothing -> "not loaded"
        Just account
            | aiHasPassword account && not (null (aiCredentials account)) -> "password + passkey"
            | aiHasPassword account -> "password"
            | not (null (aiCredentials account)) -> "passkey only, no password"
            | otherwise -> "not configured"

    body Nothing
        | mAccountLoading m = [quietNote "Loading the account."]
        | isJust (mAccountError m) =
            [accountReadError "The account could not be read." (mAccountError m)]
        | otherwise = [unavailable m]
    body (Just account) =
        [ H.p_
            [HP.class_ "account-lede"]
            [text "One username and one password open the library. A passkey registered on the account can be required as a second factor after the password."]
        , H.dl_
            [HP.class_ "account-fields"]
            [ statusFact "username" (if T.null (T.strip (aiUsername account)) then "not set" else ms (aiUsername account))
            , statusFact "role" (ms (T.unpack (userRoleText (aiRole account))))
            , statusFact "password" (if aiHasPassword account then "set" else "not set")
            , statusFact "passkeys" (ms (show (length (aiCredentials account))))
            , statusFact "passkey 2FA" (if aiRequirePasskey account then "required" else "off")
            ]
        , H.p_
            [HP.class_ "account-note meta"]
            [ text
                ( if aiHasPassword account
                    then "Every change below is confirmed with the current password."
                    else "No password is set yet. Set one below; the current password is not needed for the first one."
                )
            ]
        , case aiHasPassword account of
            True ->
                H.div_
                    [HP.class_ "account-form", HP.data_ "testid" "security-current-password-block"]
                    [ H.h3_ [HP.class_ "account-h3 display"] [text "Current password"]
                    , H.div_
                        [HP.class_ "account-form-grid"]
                        [field "current password" "security-current-password" "password" "current-password" (mSecurityCurrent m) SecurityCurrentPasswordInput]
                    , H.p_
                        [HP.class_ "account-note meta"]
                        [text "Used to confirm the changes below. The field is never stored in the browser."]
                    ]
            False -> H.span_ [] []
        , H.div_
            [HP.class_ "account-form"]
            ( [ H.h3_ [HP.class_ "account-h3 display"] [text "Username"]
              , H.div_
                    [HP.class_ "account-form-grid"]
                    [field "username" "security-username" "text" "username" (mSecurityUsername m) SecurityUsernameInput]
              , H.p_
                    [HP.class_ "account-note meta"]
                    [text "The one name this catalogue knows. The password still opens it after a rename."]
              , H.div_
                    [HP.class_ "account-form-foot"]
                    [saveButton "save the username" "security-username-save" SecurityUsernameSave]
              ]
            )
        , H.div_
            [HP.class_ "account-form"]
            [ H.h3_
                [HP.class_ "account-h3 display"]
                [text (if aiHasPassword account then "Change the password" else "Set a password")]
            , H.div_
                [HP.class_ "account-form-grid"]
                [ field "new password" "security-new-password" "password" "new-password" (mSecurityNew m) SecurityNewPasswordInput
                , field "confirm new password" "security-confirm-password" "password" "new-password" (mSecurityConfirm m) SecurityConfirmPasswordInput
                ]
            , H.p_
                [HP.class_ "account-note meta"]
                [text "At least ten characters. Changing the password signs out every other browser and rotates the session for this one."]
            , H.div_
                [HP.class_ "account-form-foot"]
                [saveButton "save the new password" "security-password-save" SecurityPasswordSave]
            ]
        , H.div_
            [HP.class_ "account-form"]
            [ H.h3_ [HP.class_ "account-h3 display"] [text "Second factor"]
            , H.p_
                [HP.class_ "account-lede"]
                [text "With the requirement on, the password alone does not open the library: the browser must also present a passkey. The option needs a password and at least one registered passkey."]
            , H.label_
                [HP.class_ "toggle"]
                ( [ H.input_
                        ( [ HP.type_ "checkbox"
                          , HP.data_ "testid" "security-2fa-toggle"
                          , HP.checked_ (mSecurity2faWanted m)
                          , HE.onClick (Security2faWantedToggled (not (mSecurity2faWanted m)))
                          ]
                            ++ attrDisabled
                                ( mSecurityBusy m
                                    || not (aiHasPassword account)
                                    || (null (aiCredentials account) && not (aiRequirePasskey account))
                                )
                        )
                  , text "require a passkey after the password"
                  ]
                )
            , H.div_
                [HP.class_ "account-actions"]
                [ H.button_
                    ( [ HP.class_ "btn btn--strong"
                      , HP.type_ "button"
                      , HP.data_ "testid" "security-2fa-save"
                      , HE.onClick Security2faSave
                      ]
                        ++ attrDisabled
                            ( mSecurityBusy m
                                || not (aiHasPassword account)
                                || mSecurity2faWanted m == aiRequirePasskey account
                                || (null (aiCredentials account) && mSecurity2faWanted m)
                            )
                    )
                    [text "save the requirement"]
                , H.a_
                    [ HP.class_ "btn btn--ghost"
                    , HP.href_ "/account/add-passkey"
                    ]
                    [text "add a passkey"]
                ]
            , H.p_
                [HP.class_ "account-note meta"]
                [ text
                    ( if not (aiHasPassword account)
                        then "Set a password before requiring a passkey."
                        else
                            if null (aiCredentials account)
                                then "Add a passkey before requiring one."
                                else "The requirement is checked after the password on every sign-in."
                    )
                ]
            ]
        , case mSecurityError m of
            Just message ->
                H.p_
                    [HP.class_ "account-error", HP.role_ "alert", HP.data_ "testid" "security-error"]
                    [text message]
            Nothing -> H.span_ [] []
        ]

    statusFact :: MisoString -> MisoString -> View () () Model Action
    statusFact label value =
        H.div_
            []
            [H.dt_ [] [text label], H.dd_ [HP.class_ "mono"] [text value]]

    field ::
        MisoString ->
        MisoString ->
        MisoString ->
        MisoString ->
        MisoString ->
        (MisoString -> Action) ->
        View () () Model Action
    field labelText domId inputType autocomplete value onInput =
        H.div_
            [HP.class_ "field"]
            [ H.label_
                [HP.class_ "field-label account-label", HP.for_ domId]
                [text labelText]
            , H.input_
                [ HP.id_ domId
                , HP.class_ "input"
                , HP.type_ inputType
                , HP.autocomplete_ autocomplete
                , HP.value_ value
                , HE.onInput onInput
                ]
            ]

    saveButton :: MisoString -> MisoString -> Action -> View () () Model Action
    saveButton labelText domId action =
        H.button_
            ( [ HP.class_ "btn btn--strong"
              , HP.type_ "button"
              , HP.data_ "testid" domId
              , HE.onClick action
              ]
                ++ attrDisabled (mSecurityBusy m)
            )
            [text (if mSecurityBusy m then "saving" else labelText)]

-- -------------------------------------------------------------- passkeys ---

passkeysPanel :: Model -> View () () Model Action
passkeysPanel m =
    accountPanel "passkeys" "Passkeys" (maybe "not loaded" deviceNote (mAccount m)) (body (mAccount m))
  where
    deviceNote account =
        let count = length (aiCredentials account)
         in ms (show count <> if count == 1 then " device" else " devices")
    body Nothing
        | mAccountLoading m = [quietNote "Loading the account."]
        | isJust (mAccountError m) =
            [accountReadError "The account could not be read." (mAccountError m)]
        | otherwise = [unavailable m]
    body (Just account) =
        [ H.p_
            [HP.class_ "account-lede"]
            [text "A passkey registered on the account is an optional second factor. The private half stays in the device's keychain or security key; eza keeps only the public half."]
        ]
            ++ [ H.p_
                    [HP.class_ "account-note meta"]
                    [ text "No password is set for this library yet, so this passkey is still the only way in. "
                    , H.button_
                        [HP.class_ "account-link", HP.type_ "button", HE.onClick (AccountTabSelected AccountSecurity)]
                        [text "set a password"]
                    , text "."
                    ]
               | not (aiHasPassword account)
               ]
            ++ [ H.div_ [HP.class_ "account-list"] (map (credentialRecord m) (aiCredentials account))
               , H.p_
                    [HP.class_ "account-note meta"]
                    [ text
                        ( if aiHasPassword account
                            then "Passkeys registered before the password release are legacy credentials: they sign in only while the database has no password. With passkey two-factor on, the last passkey cannot be removed."
                            else "Passkeys registered before the password release sign in on their own. Add a password from the sign-in section and they become second factors instead."
                        )
                    ]
               , H.div_
                    [HP.class_ "account-actions"]
                    [ H.a_
                        [HP.class_ "btn btn--strong", HP.href_ "/account/add-passkey", HP.data_ "testid" "passkey-add"]
                        [text "add another device"]
                    , H.button_
                        [HP.class_ "btn", HP.type_ "button", HE.onClick (AccountTabSelected AccountRecovery)]
                        [text "see recovery codes"]
                    , H.button_
                        [HP.class_ "btn btn--ghost", HP.type_ "button", HE.onClick (AccountTabSelected AccountSecurity)]
                        [text "sign-in settings"]
                    ]
               ]

unavailable :: Model -> View () () Model Action
unavailable _m =
    H.div_
        [HP.class_ "account-empty"]
        [ H.p_ [HP.class_ "account-empty-title display"] [text "Account details are not available."]
        , H.p_
            [HP.class_ "account-empty-body"]
            [text "The account endpoint did not answer. The library itself is still readable."]
        , H.div_
            [HP.class_ "account-actions"]
            [ H.button_
                [HP.class_ "btn", HP.type_ "button", HE.onClick AccountReload]
                [text "try again"]
            ]
        ]

credentialRecord :: Model -> Credential -> View () () Model Action
credentialRecord m credential =
    H.div_
        [HP.class_ "account-record"]
        (recordMain : editing)
  where
    nicknameOf c = if T.null (T.strip (crNickname c)) then "Passkey" else crNickname c
    recordMain =
        H.div_
            [HP.class_ "account-record-main"]
            [ H.h3_ [HP.class_ "account-record-title"] [text (ms (nicknameOf credential))]
            , H.p_
                [HP.class_ "account-record-meta meta"]
                ( [ text (ms ("created " <> fromMisoString' (formatFiled (crCreatedAt credential))))
                  , metaSep
                  , text (ms ("last used " <> maybe "never" (fromMisoString' . formatFiled) (crLastUsedAt credential)))
                  ]
                    ++ [metaSep | crBackupEligible credential]
                    ++ [text "synced backup" | crBackupEligible credential]
                )
            ]
    editing = case mCredEdit m of
        Just (editingId, draft)
            | editingId == crId credential ->
                [ H.input_
                    [ HP.class_ "input"
                    , HP.value_ draft
                    , HP.placeholder_ "Passkey nickname"
                    , HP.aria_ "label" "Passkey nickname"
                    , HE.onInput CredentialNameInput
                    , HE.onKeyDown (\code -> if keyCodeIsEnter code then CredentialEditSave else Noop)
                    ]
                , H.div_
                    [HP.class_ "account-record-actions"]
                    [smallAction "save" CredentialEditSave, smallAction "cancel" CredentialEditCancel]
                ]
        _ ->
            [ H.div_
                [HP.class_ "account-record-actions"]
                [ H.button_
                    [HP.class_ "account-link", HP.type_ "button", HE.onClick (CredentialEditStart (crId credential))]
                    [text "rename"]
                , H.button_
                    [HP.class_ "account-link account-link--danger", HP.type_ "button", HE.onClick (CredentialDeleted (crId credential))]
                    [text "delete"]
                ]
            ]

metaSep :: View () () Model Action
metaSep = H.span_ [HP.class_ "account-sep", HP.aria_ "hidden" "true"] []

-- -------------------------------------------------------------- recovery ---

recoveryPanel :: Model -> View () () Model Action
recoveryPanel m =
    accountPanel "recovery" "Recovery" "single-use codes" $
        [ H.p_
            [HP.class_ "account-lede"]
            [text "Ten single-use codes were generated when the library was claimed. They are stored hashed and cannot be shown again; regenerating replaces all of them."]
        , H.div_
            [HP.class_ "account-recovery"]
            [ H.div_
                [HP.class_ "account-rec-row"]
                [ H.span_ [HP.class_ "meta"] [text "codes"]
                , H.span_ [HP.class_ "account-rec-value mono"] [text remainingText]
                ]
            ]
        , H.div_
            [HP.class_ "account-actions"]
            [ H.button_
                [HP.class_ "btn", HP.type_ "button", HE.onClick RecoveryRegenerate]
                [text "regenerate codes"]
            ]
        ]
            ++ reveal
  where
    remainingText = case mAccount m of
        Nothing -> "not loaded"
        Just account -> ms (show (aiRecoveryRemaining account) <> " unused")
    reveal =
        [ H.div_
            [HP.class_ "account-reveal"]
            [ H.p_ [HP.class_ "account-reveal-note meta"] [text "new codes, shown once"]
            , H.pre_ [HP.class_ "account-codes mono"] [text (ms (T.unpack (T.unlines (mRecoveryCodes m))))]
            , H.p_
                [HP.class_ "account-note meta"]
                [text "Store these somewhere safe. They are shown only once."]
            ]
        | not (null (mRecoveryCodes m))
        ]

-- -------------------------------------------------------------- sessions ---

sessionsPanel :: Model -> View () () Model Action
sessionsPanel m =
    accountPanel
        "sessions"
        "Sessions"
        sessionNote
        [ H.p_
            [HP.class_ "account-lede"]
            [text "A session is one signed-in browser. Sessions are stored hashed, so the catalogue can count them but cannot name them."]
        , H.div_ [HP.class_ "account-list"] (map sessionRecord (mSessions m))
        , H.div_
            [HP.class_ "account-actions"]
            [ H.button_
                ( [ HP.class_ "btn btn--danger"
                  , HP.type_ "button"
                  , HP.data_ "testid" "account-sessions-revoke-others"
                  , HE.onClick SessionsRevokeOthers
                  ]
                    ++ attrDisabled (mAccountLoading m || length (mSessions m) <= 1)
                )
                [text "revoke other sessions"]
            , H.button_
                [HP.class_ "btn", HP.type_ "button", HE.onClick LogoutRequest]
                [text "sign out"]
            ]
        , H.p_
            [HP.class_ "account-note meta"]
            [text "Revoking signs out every other browser and keeps this one. Signing out ends this browser's session too. Passkeys stay on their devices."]
        ]
  where
    sessionNote =
        let count = length (mSessions m)
         in ms (show count <> if count == 1 then " session" else " sessions")

sessionRecord :: SessionInfo -> View () () Model Action
sessionRecord session =
    H.div_
        [HP.class_ "account-record"]
        [ H.div_
            [HP.class_ "account-record-main"]
            [ H.h3_ [HP.class_ "account-record-title"] [text (if siCurrent session then "this browser" else "another browser")]
            , H.p_
                [HP.class_ "account-record-meta meta"]
                ( [ text (ms ("opened " <> fromMisoString' (formatFiled (siCreatedAt session))))
                  , metaSep
                  , text (ms ("expires " <> fromMisoString' (formatFiled (siExpiresAt session))))
                  ]
                    ++ case siLastSeenAt session of
                        Nothing -> []
                        Just seen -> [metaSep, text (ms ("last seen " <> fromMisoString' (formatFiled seen)))]
                )
            ]
        , H.div_
            [HP.class_ "account-record-actions"]
            [ if siCurrent session
                then H.span_ [HP.class_ "account-live mono"] [text "active"]
                else H.span_ [] []
            ]
        ]

-- ---------------------------------------------------------------- tokens ---

-- ------------------------------------------------------------- webhooks ---

webhooksPanel :: Model -> View () () Model Action
webhooksPanel m =
    accountPanel "webhooks" "Webhooks" panelNote $
        [ H.p_
            [HP.class_ "account-lede"]
            [text "A webhook posts a signed event to an external URL when a record is filed, changed, removed, or clipped. Each delivery carries an HMAC signature; the secret is shown once when the webhook is created."]
        ]
            ++ secretReveal
            ++ case mWebhooksError m of
                Just message -> [accountReadError "The webhooks could not be read." (Just message)]
                Nothing ->
                    [ H.div_ [HP.class_ "account-list"] webhookRows
                    , H.div_ [HP.class_ "account-list"] (deliveriesView m)
                    , if null (mWebhooks m) then webhookEmpty m else H.span_ [] []
                    , webhookForm m
                    ]
  where
    panelNote =
        let count = length (mWebhooks m)
         in ms (show count <> " of " <> show maxWebhooks <> if count == 1 then " webhook" else " webhooks")
    secretReveal = case mWebhookSecret m of
        Nothing -> []
        Just raw ->
            [ H.div_
                [HP.class_ "account-created", testId "webhook-secret"]
                [ H.p_ [HP.class_ "account-created-label meta"] [text "signing secret, shown once"]
                , H.div_
                    [HP.class_ "account-created-row"]
                    [ H.code_ [HP.class_ "account-created-token mono"] [text (ms raw)]
                    , H.button_
                        [HP.class_ "btn", HP.type_ "button", HE.onClick (WebhookSecretCopied raw)]
                        [text "copy"]
                    , H.button_
                        [HP.class_ "btn btn--ghost", HP.type_ "button", HE.onClick WebhookSecretDismiss]
                        [text "done"]
                    ]
                , H.p_
                    [HP.class_ "account-note meta"]
                    [text "Every delivery is signed with this secret. The catalogue keeps only a hash, so it cannot show it again."]
                ]
            ]
    webhookRows
        | mWebhooksLoading m && null (mWebhooks m) = [quietNote "Loading webhooks."]
        | otherwise = concatMap (\webhook -> webhookRecord webhook : webhookTestNote m (whId webhook)) (mWebhooks m)

webhookEmpty :: Model -> View () () Model Action
webhookEmpty m
    | mWebhooksLoading m = H.span_ [] []
    | otherwise =
        H.div_
            [HP.class_ "account-empty", testId "webhook-empty"]
            [ H.p_ [HP.class_ "account-empty-title display"] [text "No webhooks yet."]
            , H.p_
                [HP.class_ "account-empty-body"]
                [text "Create one to send file and clip events to another service. A disabled webhook records nothing."]
            ]

webhookRecord :: Webhook -> View () () Model Action
webhookRecord webhook =
    H.div_
        [ HP.class_ ("account-record webhook-record" <> if whEnabled webhook then "" else " is-off")
        , testId "webhook-row"
        ]
        [ H.div_
            [HP.class_ "account-record-main"]
            [ H.h3_
                [HP.class_ "account-record-title"]
                [ text (ms (T.unpack (whName webhook)))
                , H.span_ [HP.class_ "mono token-prefix"] [text (ms (" #" <> show (whId webhook)))]
                ]
            , H.p_
                [HP.class_ "account-record-meta meta webhook-url"]
                [text (ms (T.unpack (whUrl webhook)))]
            , H.div_
                [HP.class_ "account-scope-row"]
                [ H.span_ [HP.class_ "tagpill"] [text (ms (T.unpack (eventTypeText eventType)))]
                | eventType <- whEvents webhook
                ]
            , H.p_
                [HP.class_ "account-record-meta meta"]
                ( [ text (if whEnabled webhook then "enabled" else "disabled")
                  , metaSep
                  , text (ms ("last status " <> maybe "never" (T.pack . show) (whLastStatus webhook)))
                  , metaSep
                  , text (ms ("last attempt " <> maybe "never" (fromMisoString' . formatFiled) (whLastAttemptAt webhook)))
                  ]
                    ++ [metaSep | not (T.null (whLastError webhook))]
                    ++ [H.span_ [HP.class_ "status status--warn"] [text (ms (T.unpack (whLastError webhook)))] | not (T.null (whLastError webhook))]
                    ++ [metaSep | whFailStreak webhook > 0]
                    ++ [text (ms ("fail streak " <> show (whFailStreak webhook))) | whFailStreak webhook > 0]
                )
            ]
        , H.div_
            [HP.class_ "account-record-actions webhook-actions"]
            [ H.button_
                [ HP.class_ "account-link"
                , HP.type_ "button"
                , testId "webhook-toggle"
                , HE.onClick (WebhookToggle webhook)
                ]
                [text (if whEnabled webhook then "disable" else "enable")]
            , H.button_
                [ HP.class_ "account-link"
                , HP.type_ "button"
                , testId "webhook-test"
                , HE.onClick (WebhookTestRequest (whId webhook))
                ]
                [text "send test"]
            , H.button_
                [ HP.class_ "account-link"
                , HP.type_ "button"
                , testId "webhook-deliveries-open"
                , HE.onClick (WebhookDeliveriesOpen (whId webhook))
                ]
                [text "deliveries"]
            , H.button_
                [ HP.class_ "account-link account-link--danger"
                , HP.type_ "button"
                , testId "webhook-delete"
                , HE.onClick (WebhookDelete (whId webhook))
                ]
                [text "delete"]
            ]
        ]

webhookTestNote :: Model -> Int -> [View () () Model Action]
webhookTestNote m webhookId =
    case mWebhookTest m of
        Just (id_, result)
            | id_ == webhookId ->
                [ H.p_
                    [HP.class_ "account-record-meta meta webhook-test-result", HP.role_ "status"]
                    ( [text (if wtOk result then "test delivered" else "test failed")]
                        ++ [text (ms (" · HTTP " <> maybe "no response" (T.pack . show) (wtStatus result)))]
                        ++ [text (ms (" · " <> T.unpack (wtError result))) | not (T.null (wtError result))]
                    )
                ]
        _ -> []

deliveriesView :: Model -> [View () () Model Action]
deliveriesView m =
    case mWebhookDeliveries m of
        Nothing ->
            case mWebhookDeliveriesError m of
                Just message -> [accountReadError "The deliveries could not be read." (Just message)]
                Nothing -> []
        Just (webhookId, deliveries) ->
            case [webhook | webhook <- mWebhooks m, whId webhook == webhookId] of
                (webhook : _) ->
                    [ H.div_
                        [HP.class_ "webhook-deliveries", testId "webhook-deliveries"]
                        ( H.p_
                            [HP.class_ "account-record-meta meta"]
                            [text (ms ("recent deliveries · " <> T.unpack (whName webhook)))]
                            : if null deliveries
                                then [quietNote "No deliveries yet."]
                                else map deliveryRow deliveries
                        )
                    ]
                [] -> []

deliveryRow :: DeliveryView -> View () () Model Action
deliveryRow delivery =
    H.div_
        [HP.class_ "webhook-delivery", testId "webhook-delivery-row"]
        [ H.span_ [HP.class_ "mono webhook-delivery-event"] [text (ms (T.unpack (eventTypeText (dvEvent delivery))))]
        , H.span_ [HP.class_ ("status webhook-state webhook-state--" <> stateClass (dvState delivery))] [text (ms (T.unpack (dvState delivery)))]
        , H.span_ [HP.class_ "meta mono"] [text (ms ("attempts " <> show (dvAttempts delivery)))]
        , H.span_ [HP.class_ "meta mono"] [text (ms (fromMisoString' (formatFiled (dvCreatedAt delivery))))]
        ]
  where
    stateClass state = case state of
        "delivered" -> "ok"
        "failed" -> "failed"
        "delivering" -> "delivering"
        _ -> "queued"

webhookForm :: Model -> View () () Model Action
webhookForm m =
    H.form_
        [HP.class_ "account-form", testId "webhook-form"]
        [ H.h3_ [HP.class_ "account-h3 display"] [text "Create a webhook"]
        , H.div_
            [HP.class_ "account-form-grid"]
            [ H.div_
                [HP.class_ "field"]
                [ H.label_ [HP.class_ "field-label account-label", HP.for_ "webhook-name"] [text "name"]
                , H.input_
                    [ HP.id_ "webhook-name"
                    , HP.class_ "input"
                    , HP.placeholder_ "e.g. Archive bot"
                    , HP.value_ (mWebhookName m)
                    , HP.autocomplete_ "off"
                    , testId "webhook-name"
                    , HE.onInput WebhookNameInput
                    ]
                ]
            , H.div_
                [HP.class_ "field"]
                [ H.label_ [HP.class_ "field-label account-label", HP.for_ "webhook-url"] [text "url"]
                , H.input_
                    [ HP.id_ "webhook-url"
                    , HP.class_ "input"
                    , HP.type_ "url"
                    , HP.placeholder_ "https://example.com/hooks/eza"
                    , HP.value_ (mWebhookUrl m)
                    , HP.autocomplete_ "off"
                    , testId "webhook-url"
                    , HE.onInput WebhookUrlInput
                    ]
                ]
            ]
        , H.fieldset_
            [HP.class_ "webhook-events"]
            [ H.legend_ [HP.class_ "field-label account-label"] [text "events"]
            , H.div_
                [HP.class_ "webhook-event-grid"]
                [ H.label_
                    [HP.class_ "webhook-event"]
                    [ H.input_
                        [ HP.type_ "checkbox"
                        , HP.checked_ (eventType `elem` mWebhookEvents m)
                        , testId ("webhook-event-" <> ms (T.unpack (eventTypeText eventType)))
                        , HE.onChange (const (WebhookEventToggled eventType))
                        ]
                    , H.span_ [HP.class_ "mono"] [text (ms (T.unpack (eventTypeText eventType)))]
                    ]
                | eventType <- allEventTypes
                ]
            ]
        , H.label_
            [HP.class_ "webhook-enable"]
            [ H.input_
                [ HP.type_ "checkbox"
                , HP.checked_ (mWebhookEnabled m)
                , HE.onChange (const WebhookEnabledToggled)
                ]
            , H.span_ [] [text "enabled"]
            ]
        , case mWebhookFormError m of
            Just message -> H.p_ [HP.class_ "add-error", HP.role_ "alert"] [text message]
            Nothing -> H.span_ [] []
        , H.button_
            [ HP.class_ "btn btn--sm btn--strong"
            , HP.type_ "button"
            , testId "webhook-create"
            , HE.onClick WebhookCreate
            ]
            [text (if mWebhookBusy m then "creating…" else "create webhook")]
        ]

-- ---------------------------------------------------------- admin users ---

userIsAdmin :: Model -> Bool
userIsAdmin m = mAdminUsersAllowed m || maybe False ((== RoleAdmin) . aiRole) (mAccount m)

usersPanel :: Model -> View () () Model Action
usersPanel m
    | not (userIsAdmin m) =
        accountPanel
            "users"
            "Users"
            "admin only"
            [quietNote "Only an administrator can manage the accounts on this installation."]
    | otherwise = accountPanel "users" "Users" note body
  where
    note =
        let count = length (mAdminUsers m)
         in ms (show count <> if count == 1 then " user" else " users")
    body =
        [ H.p_
            [HP.class_ "account-lede"]
            [text "Each person has their own username, password and private library. Admins can add people, change a role, enable or disable an account, and set a break-glass temporary password. Recovery codes are shown once."]
        ]
            ++ recoveryReveal
            ++ resetReveal
            ++ [ H.p_ [HP.class_ "add-error", HP.role_ "alert", testId "user-action-error"] [text message]
               | Just message <- [mUserActionError m]
               ]
            ++ case mAdminUsersError m of
                Just message -> [accountReadError "The accounts could not be read." (Just message)]
                Nothing ->
                    [ H.div_
                        [HP.class_ "account-list users-table", testId "users-table"]
                        ( if mAdminUsersLoading m && null (mAdminUsers m)
                            then [quietNote "Loading accounts."]
                            else map (userRow m) (mAdminUsers m)
                        )
                    ]
            ++ [userCreateForm m]
    recoveryReveal = case mUserRecovery m of
        Nothing -> []
        Just (username, codes) ->
            [ H.div_
                [HP.class_ "account-created", testId "user-recovery-codes"]
                [ H.p_
                    [HP.class_ "account-created-label meta"]
                    [text (ms ("recovery codes for " <> T.unpack username <> ", shown once"))]
                , H.ul_
                    [HP.class_ "account-created-codes mono"]
                    [H.li_ [] [H.code_ [] [text (ms (T.unpack code))]] | code <- codes]
                , H.div_
                    [HP.class_ "account-created-row"]
                    [ H.button_
                        [HP.class_ "btn", HP.type_ "button", HE.onClick (UserRecoveryCopied (T.intercalate "\n" codes))]
                        [text "copy all"]
                    , H.button_
                        [HP.class_ "btn btn--ghost", HP.type_ "button", HE.onClick UserRecoveryDismiss]
                        [text "done"]
                    ]
                , H.p_
                    [HP.class_ "account-note meta"]
                    [text "Give these to the person now. The catalogue keeps only hashes and cannot show them again."]
                ]
            ]
    resetReveal = case mUserResetShown m of
        Nothing -> []
        Just (username, password) ->
            [ H.div_
                [HP.class_ "account-created", testId "user-reset-shown"]
                [ H.p_
                    [HP.class_ "account-created-label meta"]
                    [text (ms ("temporary password for " <> T.unpack username <> ", shown once"))]
                , H.code_ [HP.class_ "account-created-token mono"] [text (ms (T.unpack password))]
                , H.button_
                    [HP.class_ "btn btn--ghost", HP.type_ "button", HE.onClick UserResetShownDismiss]
                    [text "done"]
                , H.p_
                    [HP.class_ "account-note meta"]
                    [text "The account's second factor is off and its existing sessions are revoked. Ask the person to sign in and change it."]
                ]
            ]

userRow :: Model -> UserView -> View () () Model Action
userRow m user =
    H.div_
        [HP.class_ "account-record user-record", testId "user-row"]
        ( [ H.div_
                [HP.class_ "account-record-main"]
                [ H.h3_
                    [HP.class_ "account-record-title"]
                    [ text (ms (T.unpack (uvUsername user)))
                    , H.span_ [HP.class_ ("tagpill user-role-pill user-role--" <> roleClass (uvRole user))] [text (ms (T.unpack (userRoleText (uvRole user))))]
                    ]
                , H.p_
                    [HP.class_ "account-record-meta meta"]
                    [ text (ms ("created " <> fromMisoString' (formatFiled (uvCreatedAt user))))
                    , metaSep
                    , text (ms ("last login " <> maybe "never" (fromMisoString' . formatFiled) (uvLastLoginAt user)))
                    ]
                , case uvDisabledAt user of
                    Just _ -> H.p_ [HP.class_ "status status--warn"] [text "disabled"]
                    Nothing -> H.span_ [] []
                ]
          , H.div_
                [HP.class_ "account-record-actions user-actions"]
                [ H.button_
                    ( [ HP.class_ "account-link"
                      , HP.type_ "button"
                      , testId (if isUserEnabledLocal user then "user-disable" else "user-enable")
                      , HE.onClick (UserToggleEnabled user)
                      ]
                    )
                    [text (if isUserEnabledLocal user then "disable" else "enable")]
                , H.button_
                    [ HP.class_ "account-link"
                    , HP.type_ "button"
                    , testId "user-role-toggle"
                    , HE.onClick (UserRoleChange user)
                    ]
                    [text (if uvRole user == RoleAdmin then "make member" else "make admin")]
                , H.button_
                    [HP.class_ "account-link", HP.type_ "button", testId "user-reset-open", HE.onClick (UserResetOpen (uvId user))]
                    [text "reset password"]
                , H.button_
                    [HP.class_ "account-link account-link--danger", HP.type_ "button", testId "user-delete-open", HE.onClick (UserDeleteOpen user)]
                    [text "delete"]
                ]
          ]
            ++ [resetPasswordForm m user | mUserReset m == Just (uvId user)]
            ++ [deleteAccountForm m user | fmap uvId (mUserDelete m) == Just (uvId user)]
        )
  where
    roleClass role = case role of
        RoleAdmin -> "admin"
        RoleMember -> "member"

isUserEnabledLocal :: UserView -> Bool
isUserEnabledLocal user = isNothing (uvDisabledAt user)

resetPasswordForm :: Model -> UserView -> View () () Model Action
resetPasswordForm m user =
    H.div_
        [HP.class_ "user-reset-form"]
        [ H.p_
            [HP.class_ "account-note meta"]
            [text (ms ("Set a temporary password for " <> T.unpack (uvUsername user) <> ". Its second factor is cleared and its sessions are revoked."))]
        , H.input_
            [ HP.class_ "input"
            , HP.type_ "password"
            , HP.placeholder_ "temporary password"
            , HP.value_ (mUserResetPassword m)
            , HP.autocomplete_ "new-password"
            , testId "user-reset-password"
            , HE.onInput UserResetPasswordInput
            ]
        , H.div_
            [HP.class_ "account-created-row"]
            [ H.button_
                [HP.class_ "btn btn--sm btn--strong", HP.type_ "button", testId "user-reset-submit", HE.onClick UserResetSubmit]
                [text "set temporary password"]
            , H.button_
                [HP.class_ "btn btn--sm", HP.type_ "button", HE.onClick UserResetCancel]
                [text "cancel"]
            ]
        ]

{- | Delete confirmation. Typing the account name is the deliberate second
step; the library checkbox is off by default so an accidental delete keeps the
content recoverable from a backup.
-}
deleteAccountForm :: Model -> UserView -> View () () Model Action
deleteAccountForm m user =
    H.div_
        [HP.class_ "user-reset-form user-delete-form"]
        [ H.p_
            [HP.class_ "account-note meta"]
            [ text
                ( ms
                    ( "Delete "
                        <> T.unpack (uvUsername user)
                        <> ". This cannot be undone. The library database and its snapshots are removed only when the box below is ticked."
                    )
                )
            ]
        , H.input_
            [ HP.class_ "input"
            , HP.type_ "text"
            , HP.placeholder_ (ms (T.unpack (uvUsername user)))
            , HP.value_ (mUserDeleteName m)
            , HP.autocomplete_ "off"
            , testId "user-delete-name"
            , HE.onInput UserDeleteNameInput
            ]
        , H.label_
            [HP.class_ "account-import-check"]
            [ H.input_
                [ HP.type_ "checkbox"
                , HP.checked_ (mUserDeleteLibrary m)
                , testId "user-delete-library"
                , HE.onChange (const UserDeleteLibraryToggled)
                ]
            , text " also delete the library and snapshots"
            ]
        , case mUserActionError m of
            Just message -> H.p_ [HP.class_ "add-error", HP.role_ "alert"] [text message]
            Nothing -> H.span_ [] []
        , H.div_
            [HP.class_ "account-created-row"]
            [ H.button_
                ( [ HP.class_ "btn btn--sm btn--strong"
                  , HP.type_ "button"
                  , testId "user-delete-submit"
                  , HE.onClick UserDeleteSubmit
                  ]
                    ++ attrDisabled (mUserDeleteBusy m)
                )
                [text (if mUserDeleteBusy m then "deleting…" else "delete account")]
            , H.button_
                [HP.class_ "btn btn--sm", HP.type_ "button", testId "user-delete-cancel", HE.onClick UserDeleteCancel]
                [text "cancel"]
            ]
        ]

userCreateForm :: Model -> View () () Model Action
userCreateForm m =
    H.form_
        [HP.class_ "account-form", testId "user-create-form"]
        [ H.h3_ [HP.class_ "account-h3 display"] [text "Add a user"]
        , H.div_
            [HP.class_ "account-form-grid"]
            [ H.div_
                [HP.class_ "field"]
                [ H.label_ [HP.class_ "field-label account-label", HP.for_ "user-name"] [text "username"]
                , H.input_
                    [ HP.id_ "user-name"
                    , HP.class_ "input"
                    , HP.placeholder_ "e.g. river"
                    , HP.value_ (mUserName m)
                    , HP.autocomplete_ "off"
                    , testId "user-name"
                    , HE.onInput UserNameInput
                    ]
                ]
            , H.div_
                [HP.class_ "field"]
                [ H.label_ [HP.class_ "field-label account-label", HP.for_ "user-password"] [text "temporary password"]
                , H.input_
                    [ HP.id_ "user-password"
                    , HP.class_ "input"
                    , HP.type_ "password"
                    , HP.autocomplete_ "new-password"
                    , HP.value_ (mUserPassword m)
                    , testId "user-password"
                    , HE.onInput UserPasswordInput
                    ]
                ]
            ]
        , H.div_
            [HP.class_ "field"]
            [ H.label_ [HP.class_ "field-label account-label", HP.for_ "user-role"] [text "role"]
            , H.select_
                [ HP.id_ "user-role"
                , HP.class_ "input"
                , testId "user-role"
                , HE.onChange (\raw -> UserRoleSelected (if fromMisoString raw == ("admin" :: Text) then RoleAdmin else RoleMember))
                ]
                [ H.option_ [HP.value_ "member", HP.selected_ (mUserRole m == RoleMember)] [text "member"]
                , H.option_ [HP.value_ "admin", HP.selected_ (mUserRole m == RoleAdmin)] [text "admin"]
                ]
            ]
        , case mUserFormError m of
            Just message -> H.p_ [HP.class_ "add-error", HP.role_ "alert", testId "user-form-error"] [text message]
            Nothing -> H.span_ [] []
        , H.button_
            ( [ HP.class_ "btn btn--sm btn--strong"
              , HP.type_ "button"
              , testId "user-create"
              , HE.onClick UserCreate
              ]
                ++ attrDisabled (mUserBusy m)
            )
            [text (if mUserBusy m then "creating…" else "create user")]
        ]

tokensPanel :: Model -> View () () Model Action
tokensPanel m =
    accountPanel "tokens" "API tokens" tokenNote $
        [ H.p_
            [HP.class_ "account-lede"]
            [text "Tokens let the command line and the phone's share sheet file links without opening the library. Each one is scoped and can be revoked at any time."]
        ]
            ++ created
            ++ case mTokensError m of
                Just message -> [accountReadError "The tokens could not be read." (Just message)]
                Nothing ->
                    [ H.div_ [HP.class_ "account-list"] tokenRows
                    , if null (mTokens m) then tokenEmpty m else H.span_ [] []
                    , tokenForm m
                    ]
  where
    tokenNote =
        let count = length (mTokens m)
         in ms (show count <> if count == 1 then " token" else " tokens")
    created = case mTokenSecret m of
        Nothing -> []
        Just (raw, _) ->
            [ H.div_
                [HP.class_ "account-created", testId "token-reveal"]
                [ H.p_ [HP.class_ "account-created-label meta"] [text "new token, shown once"]
                , H.div_
                    [HP.class_ "account-created-row"]
                    [ H.code_ [HP.class_ "account-created-token mono", testId "token-secret"] [text (ms raw)]
                    , H.button_
                        [HP.class_ "btn", HP.type_ "button", HE.onClick (TokenCopied raw)]
                        [text "copy"]
                    , H.button_
                        [HP.class_ "btn btn--ghost", HP.type_ "button", HE.onClick TokenRevealDismiss]
                        [text "done"]
                    ]
                , H.p_
                    [HP.class_ "account-note meta"]
                    [text "Copy it now. The catalogue keeps only a hash and cannot show it again."]
                ]
            ]
    tokenRows
        | mTokensLoading m && null (mTokens m) = [quietNote "Loading tokens."]
        | null (mTokens m) = []
        | otherwise = map tokenRecord (mTokens m)
    tokenEmpty m'
        | mTokensLoading m' = H.span_ [] []
        | otherwise =
            H.div_
                [HP.class_ "account-empty", testId "token-empty"]
                [ H.p_ [HP.class_ "account-empty-title display"] [text "No tokens yet."]
                , H.p_
                    [HP.class_ "account-empty-body"]
                    [text "Create one for the command line, or for the share sheet on a phone. Tokens are shown once and then stored hashed."]
                ]

tokenRecord :: TokenView -> View () () Model Action
tokenRecord token =
    H.div_
        [ HP.class_ ("account-record account-token" <> if isJust (tvRevokedAt token) then " is-revoked" else "")
        , testId "token-row"
        ]
        [ H.div_
            [HP.class_ "account-record-main"]
            [ H.h3_
                [HP.class_ "account-record-title"]
                [ text (ms (tvName token))
                , H.span_ [HP.class_ "mono token-prefix"] [text (ms (" " <> tvPrefix token))]
                ]
            , H.p_
                [HP.class_ "account-record-meta meta"]
                [ text (ms ("created " <> fromMisoString' (formatFiled (tvCreatedAt token))))
                , metaSep
                , text (ms ("last used " <> maybe "never" (fromMisoString' . formatFiled) (tvLastUsedAt token)))
                ]
            , H.div_ [HP.class_ "account-scope-row"] (map scopePill (tvScopes token))
            ]
        , H.div_
            [HP.class_ "account-record-actions"]
            [ if isJust (tvRevokedAt token)
                then H.span_ [HP.class_ "status status--warn"] [text "revoked"]
                else
                    H.button_
                        [ HP.class_ "account-link account-link--danger"
                        , HP.type_ "button"
                        , testId "token-revoke"
                        , HE.onClick (TokenRevoke (tvId token))
                        ]
                        [text "revoke"]
            ]
        ]

scopePill :: Text -> View () () Model Action
scopePill scope = H.span_ [HP.class_ "tagpill"] [text (ms scope)]

tokenForm :: Model -> View () () Model Action
tokenForm m =
    H.form_
        [HP.class_ "account-form"]
        [ H.h3_ [HP.class_ "account-h3 display"] [text "Create a token"]
        , H.div_
            [HP.class_ "account-form-grid"]
            [ H.div_
                [HP.class_ "field"]
                [ H.label_ [HP.class_ "field-label account-label", HP.for_ "token-name"] [text "name"]
                , H.input_
                    [ HP.id_ "token-name"
                    , HP.class_ "input"
                    , HP.placeholder_ "e.g. Laptop command line"
                    , HP.value_ (mTokenName m)
                    , HP.autocomplete_ "off"
                    , HE.onInput TokenNameInput
                    ]
                ]
            , H.fieldset_
                [HP.class_ "account-scopes"]
                ( H.legend_ [HP.class_ "account-label meta"] [text "scopes"]
                    : [ scopeOption scope note
                      | (scope, note) <- [("read", "read the library"), ("write", "file and edit"), ("capture", "file links only")]
                      ]
                )
            ]
        , H.div_
            [HP.class_ "account-form-foot"]
            [ H.button_
                ( [ HP.class_ "btn btn--strong"
                  , HP.type_ "button"
                  , testId "token-create"
                  , HE.onClick TokenCreate
                  ]
                    ++ attrDisabled (mTokenBusy m)
                )
                [text (if mTokenBusy m then "creating" else "create the token")]
            ]
        ]
  where
    scopeOption scope note =
        H.label_
            [HP.class_ "account-scope"]
            [ H.input_
                ( [ HP.type_ "checkbox"
                  , HE.onClick (TokenScopeToggled scope)
                  , testId (ms ("token-scope-" <> scope))
                  ]
                    ++ attrChecked (scope `elem` mTokenScopes m)
                )
            , H.span_ [] [text (ms scope)]
            , H.span_ [HP.class_ "account-scope-note meta"] [text note]
            ]

-- ---------------------------------------------------------------- shares ---

sharesPanel :: Model -> View () () Model Action
sharesPanel m =
    accountPanel "shares" "Share links" shareNote $
        [ H.p_
            [HP.class_ "account-lede"]
            [text "A share link is a read-only page outside the login. Anyone with the link can read that record or saved search until it expires or is revoked."]
        ]
            ++ [savedSearchShareSection m]
            ++ case mSharesError m of
                Just message -> [accountReadError "The share links could not be read." (Just message)]
                Nothing ->
                    if null (activeShares m)
                        then [shareEmpty m]
                        else [H.div_ [HP.class_ "account-list"] (map (shareRecord m) (mShares m))]
  where
    shareNote =
        let count = length (activeShares m)
         in ms (show count <> if count == 1 then " active link" else " active links")

{- | A saved search can be shared from the ledger rail or from here. The row
opens the same slip the rail uses; both create @scope:"saved_search"@ links.
-}
savedSearchShareSection :: Model -> View () () Model Action
savedSearchShareSection m =
    H.div_
        [HP.class_ "account-form", HP.data_ "testid" "saved-search-share-section"]
        [ H.h3_ [HP.class_ "account-h3 display"] [text "Share a saved search"]
        , H.p_
            [HP.class_ "account-note meta"]
            [text "A saved-search link is a read-only page of the results, with an Atom feed at the same address. It never makes the library public."]
        , if null (mSaved m)
            then
                H.p_
                    [HP.class_ "account-note meta"]
                    [text "No saved searches yet. Save a search from the rail on the ledger first."]
            else
                H.div_ [HP.class_ "account-list"] (map savedShareRow (mSaved m))
        ]
  where
    savedShareRow saved =
        H.div_
            [HP.class_ "account-record", HP.data_ "testid" "saved-search-share-row"]
            [ H.div_
                [HP.class_ "account-record-main"]
                [ H.h3_ [HP.class_ "account-record-title"] [text (ms (ssName saved))]
                , H.p_
                    [HP.class_ "account-record-meta meta"]
                    ( [text (ms (ssQ saved)) | not (T.null (T.strip (ssQ saved)))]
                        ++ [text (ms (T.intercalate " · " (ssTags saved)))]
                    )
                ]
            , H.div_
                [HP.class_ "account-record-actions"]
                [ H.button_
                    [ HP.class_ "account-link"
                    , HP.type_ "button"
                    , HP.data_ "testid" "saved-search-share"
                    , HE.onClick (SavedSearchShareOpen saved)
                    ]
                    [text "share"]
                ]
            ]

shareEmpty :: Model -> View () () Model Action
shareEmpty m
    | mSharesLoading m =
        H.div_
            [HP.class_ "account-empty"]
            [H.p_ [HP.class_ "account-empty-body"] [text "Loading share links."]]
    | otherwise =
        H.div_
            [HP.class_ "account-empty"]
            [ H.p_ [HP.class_ "account-empty-title display"] [text "No share links."]
            , H.p_
                [HP.class_ "account-empty-body"]
                [text "Records stay inside the login unless a link is made for one. Nothing here is public by default."]
            ]

shareRecord :: Model -> ShareView -> View () () Model Action
shareRecord m share =
    H.div_
        [ HP.class_ ("account-record" <> if isJust (svRevokedAt share) then " is-revoked" else "")
        , testId "share-link-row"
        ]
        [ H.div_
            [HP.class_ "account-record-main"]
            [ H.h3_ [HP.class_ "account-record-title"] [text (shareTargetLabel m share)]
            , H.p_
                [HP.class_ "account-record-meta meta"]
                [ text (ms (T.unpack (svPrefix share)))
                , metaSep
                , text (ms ("created " <> fromMisoString' (formatFiled (svCreatedAt share))))
                , metaSep
                , text (ms ("expires " <> fromMisoString' (formatFiled (svExpiresAt share))))
                , if svIncludeNote share then metaSep else H.span_ [] []
                , if svIncludeNote share then text "includes the note" else H.span_ [] []
                ]
            ]
        , H.div_
            [HP.class_ "account-record-actions"]
            [ if isJust (svRevokedAt share)
                then H.span_ [HP.class_ "status status--warn"] [text "revoked"]
                else
                    H.button_
                        [ HP.class_ "account-link account-link--danger"
                        , HP.type_ "button"
                        , testId "share-link-revoke"
                        , HE.onClick (ShareRevoke (svId share))
                        ]
                        [text "revoke"]
            ]
        ]
  where
    shareTargetLabel model target = case svScope target of
        "bookmark" -> ms ("record " <> show (svTargetId target))
        "saved_search" -> ms ("saved query · " <> T.unpack (savedSearchName model (svTargetId target)))
        other -> ms other

-- | Resolve a saved-search share target to the name the rail shows.
savedSearchName :: Model -> Int -> Text
savedSearchName m targetId =
    case [ss | saved <- mSaved m, let ss = ssName saved, ssId saved == targetId] of
        (name : _) -> name
        [] -> "saved search " <> T.pack (show targetId)

-- ----------------------------------------------------------------- rules ---

rulesPanel :: Model -> View () () Model Action
rulesPanel m =
    accountPanel "rules" "Rules" ruleNote $
        [ H.p_
            [HP.class_ "account-lede"]
            [text "A rule files new links automatically: match on the address, the source or the title, then add tags or mark the record read."]
        ]
            ++ ( case mRulesError m of
                    Just message ->
                        [accountReadError "The rules could not be read." (Just message)]
                    Nothing ->
                        [ H.div_ [HP.class_ "account-list", testId "rules-table"] (map ruleRecord (mRules m))
                        ]
                            ++ [ruleEmpty m | null (mRules m)]
               )
            ++ [ruleDryRun m, ruleForm m]
  where
    ruleNote =
        let count = length (mRules m)
         in ms (show count <> if count == 1 then " rule" else " rules")

ruleEmpty :: Model -> View () () Model Action
ruleEmpty m
    | mRulesLoading m = quietNote "Loading rules."
    | otherwise =
        H.div_
            [HP.class_ "account-empty"]
            [ H.p_ [HP.class_ "account-empty-title display"] [text "No rules yet."]
            , H.p_
                [HP.class_ "account-empty-body"]
                [text "Every entry in this library was filed by hand or by an import. A rule would sit between the share sheet and the ledger."]
            ]

ruleRecord :: Rule -> View () () Model Action
ruleRecord rule =
    H.div_
        [ HP.class_ ("account-record" <> if ruleEnabled rule then "" else " is-revoked")
        , testId "rule-row"
        , HP.data_ "enabled" (if ruleEnabled rule then "true" else "false")
        ]
        [ H.div_
            [HP.class_ "account-record-main"]
            [ H.h3_ [HP.class_ "account-record-title"] [text (ms (ruleName rule))]
            , H.p_
                [HP.class_ "account-record-meta meta"]
                [ text (ms ("when the " <> ruleFieldLabel (ruleField rule) <> " contains "))
                , H.code_ [HP.class_ "mono"] [text (ms (rulePattern rule))]
                , text (ms (" · " <> tagsText (ruleAddTags rule)))
                , metaSep
                , text (if ruleMarkRead rule then "marks read" else "keeps the read state")
                , metaSep
                , text (if ruleEnabled rule then "enabled" else "disabled")
                ]
            ]
        , H.div_
            [HP.class_ "account-record-actions"]
            [ H.button_
                [HP.class_ "account-link", HP.type_ "button", testId "rule-toggle", HE.onClick (RuleToggleEnabled rule)]
                [text (if ruleEnabled rule then "disable" else "enable")]
            , H.button_
                [ HP.class_ "account-link account-link--danger"
                , HP.type_ "button"
                , testId "rule-delete"
                , HE.onClick (RuleDelete (ruleId rule))
                ]
                [text "delete"]
            ]
        ]
  where
    ruleFieldLabel :: Text -> String
    ruleFieldLabel field = case field of
        "domain" -> "source"
        "title" -> "title"
        _ -> "address"
    tagsText :: [Text] -> String
    tagsText [] = "no tags added"
    tagsText tags = "adds " <> T.unpack (T.intercalate ", " tags)

ruleDryRun :: Model -> View () () Model Action
ruleDryRun m =
    H.div_
        [HP.class_ "account-dryrun", testId "rule-result"]
        [ H.div_
            [HP.class_ "account-dryrun-head"]
            [ H.h4_ [HP.class_ "sc"] [text "Dry run"]
            , H.span_ [HP.class_ "meta"] [text dryRunText]
            ]
        , H.p_
            [HP.class_ "account-note meta"]
            [text "A dry run reads the loaded sample and changes nothing."]
        ]
  where
    dryRunText = case mRuleDryRun m of
        Nothing -> "no run yet"
        Just (matches, ids) ->
            ms (show matches <> if matches == 1 then " match" else " matches")
                <> maybe "" (\bookmarkId -> ms (", e.g. " <> accnoText bookmarkId)) (safeHead ids)

safeHead :: [a] -> Maybe a
safeHead [] = Nothing
safeHead (x : _) = Just x

ruleForm :: Model -> View () () Model Action
ruleForm m =
    H.form_
        [HP.class_ "account-form"]
        [ H.h3_ [HP.class_ "account-h3 display"] [text "New rule"]
        , H.div_
            [HP.class_ "account-form-grid"]
            [ H.div_
                [HP.class_ "field"]
                [ H.label_ [HP.class_ "field-label account-label", HP.for_ "rule-name"] [text "name"]
                , H.input_
                    [ HP.id_ "rule-name"
                    , HP.class_ "input"
                    , HP.value_ (mRuleName m)
                    , HP.autocomplete_ "off"
                    , HE.onInput RuleNameInput
                    ]
                ]
            , H.div_
                [HP.class_ "field"]
                [ H.label_ [HP.class_ "field-label account-label", HP.for_ "rule-field"] [text "match"]
                , H.select_
                    [ HP.id_ "rule-field"
                    , HP.class_ "select"
                    , HE.onChange (\raw -> RuleFieldSelected (fromMisoString raw))
                    ]
                    [ fieldOption "url" "address"
                    , fieldOption "domain" "source"
                    , fieldOption "title" "title"
                    ]
                ]
            , H.div_
                [HP.class_ "field"]
                [ H.label_ [HP.class_ "field-label account-label", HP.for_ "rule-pattern"] [text "contains"]
                , H.input_
                    [ HP.id_ "rule-pattern"
                    , HP.class_ "input"
                    , HP.value_ (mRulePattern m)
                    , HP.autocomplete_ "off"
                    , HE.onInput RulePatternInput
                    ]
                ]
            , H.div_
                [HP.class_ "field"]
                [ H.label_ [HP.class_ "field-label account-label", HP.for_ "rule-tags"] [text "add tags"]
                , H.input_
                    [ HP.id_ "rule-tags"
                    , HP.class_ "input"
                    , HP.value_ (mRuleTags m)
                    , HP.autocomplete_ "off"
                    , HE.onInput RuleTagsInput
                    ]
                ]
            ]
        , H.label_
            [HP.class_ "account-scope"]
            [ H.input_
                ( [ HP.type_ "checkbox"
                  , testId "rule-mark-read"
                  , HE.onClick RuleMarkReadToggled
                  ]
                    ++ attrChecked (mRuleMarkRead m)
                )
            , H.span_ [] [text "mark read"]
            ]
        , H.div_
            [HP.class_ "account-form-foot"]
            [ H.button_
                ( [ HP.class_ "btn btn--strong"
                  , HP.type_ "button"
                  , testId "rule-create"
                  , HE.onClick RuleCreate
                  ]
                    ++ attrDisabled (mRuleBusy m)
                )
                [text (if mRuleBusy m then "working" else "create the rule")]
            , H.button_
                ( [ HP.class_ "btn btn--ghost"
                  , HP.type_ "button"
                  , testId "rule-dry-run"
                  , HE.onClick RuleDryRun
                  ]
                    ++ attrDisabled (mRuleBusy m)
                )
                [text "run a dry run"]
            ]
        ]
  where
    fieldOption :: Text -> MisoString -> View () () Model Action
    fieldOption value label =
        H.option_
            [HP.value_ (ms value), HP.selected_ (mRuleField m == value)]
            [text label]

-- ---------------------------------------------------------------- import ---

importPanel :: Model -> View () () Model Action
importPanel m =
    accountPanel "import" "Import" importNote $
        [ H.p_
            [HP.class_ "account-lede"]
            [text "Bookmarks arrive as a Netscape HTML export from any browser, or as an eza JSON export from another instance. Importing keeps the original save dates and turns folders into tags."]
        ]
            ++ [importIdle m | not (mImporting m)]
            ++ progress
            ++ report
  where
    importNote
        | mImporting m = "running"
        | otherwise = "no imports recorded in this session"
    progress =
        [ H.div_
            [HP.class_ "account-import-progress"]
            [ H.div_
                [HP.class_ "account-import-file"]
                [ H.span_ [HP.class_ "account-import-name mono"] [text "bookmarks.html or eza.json"]
                , H.span_ [HP.class_ "account-import-size meta"] [text "reading anchors"]
                ]
            , H.p_
                [HP.class_ "account-import-state meta"]
                [text "The import runs on the server. The report appears when the file is done."]
            ]
        | mImporting m
        ]
    report = case mImportReport m of
        Nothing -> []
        Just value -> [importReportView value]

importIdle :: Model -> View () () Model Action
importIdle m =
    H.div_
        [HP.class_ "account-filefield"]
        [ H.p_ [HP.class_ "account-filefield-title display"] [text "Choose a bookmarks file"]
        , H.p_
            [HP.class_ "account-filefield-note meta"]
            [text ".html exported from Chrome, Firefox, Safari or Edge, or an .json exported by eza. Nothing is imported twice."]
        , H.div_
            [HP.class_ "account-actions"]
            [ H.button_
                ( [HP.class_ "btn btn--strong", HP.type_ "button", HE.onClick ImportStart]
                    ++ attrDisabled (mImporting m)
                )
                [text (if mImporting m then "importing" else "choose a bookmarks file")]
            ]
        ]

importReportView :: ImportReport -> View () () Model Action
importReportView report =
    H.div_
        [HP.class_ "account-report"]
        [ H.div_
            [HP.class_ "account-report-head"]
            [ H.h3_ [HP.class_ "account-h3 display"] [text "Import report"]
            , H.span_ [HP.class_ "meta"] [text "this run"]
            ]
        , H.dl_
            [HP.class_ "account-report-list"]
            [ reportRow "anchors found" (irFound report)
            , reportRow "http anchors" (irHttpAnchors report)
            , reportRow "unique addresses" (irUniqueUrls report)
            , reportRow "inserted" (irInserted report)
            , reportRow "already present" (irExisting report)
            , reportRow "duplicate anchors" (irDuplicateAnchors report)
            , reportRow "tags created" (irTagsCreated report)
            , reportRow "tag links added" (irTagLinksAdded report)
            , reportRow "folders skipped" (irFoldersSkipped report)
            , reportRow "left untagged" (irUntagged report)
            ]
        , H.p_
            [HP.class_ "account-note meta"]
            [text (ms ("Elapsed " <> show (irElapsedMs report) <> " milliseconds. The import runs in one transaction."))]
        ]

reportRow :: MisoString -> Int -> View () () Model Action
reportRow label value =
    H.div_
        [HP.class_ "account-report-row"]
        [ H.dt_ [] [text label]
        , H.span_ [HP.class_ "lead", HP.aria_ "hidden" "true"] []
        , H.dd_ [HP.class_ "mono"] [text (num value)]
        ]

-- --------------------------------------------------------------- capture ---

capturePanel :: Model -> View () () Model Action
capturePanel m =
    accountPanel
        "capture"
        "Capture"
        "two ways in"
        [ H.p_
            [HP.class_ "account-lede"]
            [text "The fastest way to file a link is not to open the library at all."]
        , H.div_
            [HP.class_ "account-capture-block", testId "capture-box"]
            [ H.h3_ [HP.class_ "account-h3 display"] [text "The bookmarklet"]
            , H.p_
                [HP.class_ "account-body-text"]
                [text "Drag the link below to the bookmarks bar. On any page it opens the capture window with the address already filled in."]
            , bookmarkletLink m
            , H.div_
                [HP.class_ "account-snippet"]
                [ H.code_ [HP.class_ "mono"] [text (captureBookmarklet m)]
                , H.button_
                    ( [HP.class_ "btn", HP.type_ "button", HE.onClick (CopyBookmarklet (captureBookmarklet m))]
                        ++ attrDisabled (not (hasBookmarklet m))
                    )
                    [text "copy"]
                ]
            ]
        , H.div_
            [HP.class_ "account-capture-block"]
            [ H.h3_ [HP.class_ "account-h3 display"] [text "The app"]
            , H.p_
                [HP.class_ "account-body-text"]
                [text "eza installs as a PWA. Added to the home screen it opens full screen and appears in the system share sheet, so a link can be filed from the browser's share menu."]
            , H.div_
                [HP.class_ "account-install"]
                [ installStep "01" "open eza in the phone's browser"
                , installStep "02" "share, then add to home screen"
                , installStep "03" "on a desktop browser, install from the address bar"
                ]
            , H.div_
                [HP.class_ "account-actions"]
                [ H.a_
                    [ HP.class_ "btn"
                    , HP.href_ "/save"
                    , HE.onClickPrevent (Navigate (Save Nothing Nothing Nothing))
                    ]
                    [text "open the capture page"]
                ]
            ]
        ]

installStep :: MisoString -> MisoString -> View () () Model Action
installStep number label =
    H.div_
        []
        [ H.span_ [HP.class_ "account-install-step mono"] [text number]
        , H.span_ [] [text label]
        ]

bookmarkletLink :: Model -> View () () Model Action
bookmarkletLink m
    | not (hasBookmarklet m) =
        H.p_
            [HP.class_ "account-note meta"]
            [text "The bookmarklet becomes available once the app knows its origin."]
    | otherwise =
        H.a_
            [ HP.class_ "account-bookmarklet"
            , HP.href_ (captureBookmarklet m)
            , HP.draggable_ True
            , HP.title_ "Drag this link to the bookmarks bar"
            ]
            [text "file this page"]

hasBookmarklet :: Model -> Bool
hasBookmarklet m = not (T.null (T.strip (fromMisoString (captureBookmarklet m) :: Text)))

captureBookmarklet :: Model -> MisoString
captureBookmarklet m
    | T.null (T.strip (fromMisoString rawOrigin :: Text)) = ""
    | otherwise =
        ms
            ( "javascript:(function(){var u=encodeURIComponent(location.href),t=encodeURIComponent(document.title);"
                <> "window.open('"
                <> origin
                <> "/save?url='+u+'&title='+t,'eza-save','width=560,height=700,menubar=no,toolbar=no,resizable=yes');"
                <> "})()"
            )
  where
    rawOrigin = mWindowOrigin m
    origin = fromMisoString rawOrigin :: String

-- ------------------------------------------------------------ appearance ---

appearancePanel :: Model -> View () () Model Action
appearancePanel m =
    accountPanel
        "appearance"
        "Appearance"
        "paper and night"
        [ H.p_
            [HP.class_ "account-lede"]
            [text "The catalogue is printed on paper by day and read in the dark by night. The type and the rules do not change."]
        , H.div_
            [HP.class_ "account-appearance"]
            [ H.div_
                [HP.class_ "seg account-theme-seg", HP.role_ "group", HP.aria_ "label" "Theme"]
                [ themeButton m ThemeLight "paper"
                , themeButton m ThemeDark "reading room at night"
                ]
            , H.div_
                [HP.class_ "account-swatch", HP.aria_ "hidden" "true"]
                [ H.span_ [HP.class_ "account-swatch-paper"] []
                , H.span_ [HP.class_ "account-swatch-ink"] []
                , H.span_ [HP.class_ "account-swatch-accent"] []
                , H.span_ [HP.class_ "account-swatch-card"] []
                ]
            , H.p_
                [HP.class_ "account-note meta"]
                [text "One accent: oxblood by day, amber at night."]
            ]
        ]

themeButton :: Model -> Theme -> MisoString -> View () () Model Action
themeButton m theme label =
    H.button_
        ( [ HP.type_ "button"
          , HP.aria_ "pressed" (if mTheme m == theme then "true" else "false")
          ]
            ++ ( if mTheme m == theme
                    then [HP.disabled_]
                    else [HE.onClick ThemeToggled]
               )
        )
        [text label]

-- ----------------------------------------------------------------- about ---

aboutPanel :: Model -> View () () Model Action
aboutPanel m =
    accountPanel
        "about"
        "About"
        ""
        [ H.p_
            [HP.class_ "account-lede"]
            [text "A self-hosted catalogue for one person: one Haskell process, one SQLite file, a WebAssembly client. No sync, no telemetry."]
        , H.dl_ [HP.class_ "account-about-list"] (map aboutRow (aboutFigures m))
        , H.p_ [HP.class_ "about-sub"] [text "your data"]
        , H.p_
            [HP.class_ "account-note meta"]
            [text "The browser session downloads the file; nothing leaves the server."]
        , H.ul_
            [HP.class_ "about-links"]
            [ aboutDownload "export html" "bookmarks.html" "/api/v1/export"
            , aboutDownload "export json" "eza-export.json" "/api/v1/export?format=json"
            ]
        , H.p_ [HP.class_ "about-sub"] [text "source"]
        , H.ul_ [HP.class_ "about-links"] (map aboutLink (aboutSourceLinks m))
        , H.p_ [HP.class_ "about-sub"] [text "built with"]
        , H.ul_ [HP.class_ "about-links"] (map aboutLink aboutStack)
        ]

aboutFigures :: Model -> [(MisoString, MisoString)]
aboutFigures m = case mStats m of
    Nothing ->
        [ ("entries", "not yet")
        , ("tags", "not yet")
        , ("tag links", "not yet")
        , ("filing days", "not yet")
        , ("first accession", "not yet")
        , ("last accession", "not yet")
        ]
    Just stats ->
        [ ("entries", num (lsTotal stats))
        , ("tags", num (lsTags stats))
        , ("tag links", num (lsTagLinks stats))
        , ("filing days", num (lsDays stats))
        , ("first accession", isoStamp (lsFirstDay stats))
        , ("last accession", isoStamp (lsLastDay stats))
        ]

aboutRow :: (MisoString, MisoString) -> View () () Model Action
aboutRow (label, value) =
    H.div_ [] [H.dt_ [] [text label], H.dd_ [HP.class_ "mono"] [text value]]

aboutSourceLinks :: Model -> [(MisoString, MisoString, MisoString)]
aboutSourceLinks m =
    [ ("repository", "github.com/meillaya/eza", "https://github.com/meillaya/eza")
    , ("version " <> mVersion m, "releases", "https://github.com/meillaya/eza/releases")
    , ("license", "Apache-2.0", "https://github.com/meillaya/eza/blob/main/LICENSE")
    , ("third-party notices", "dependencies, typefaces and their licenses", "https://github.com/meillaya/eza/blob/main/THIRD-PARTY-NOTICES.md")
    ]

aboutStack :: [(MisoString, MisoString, MisoString)]
aboutStack =
    [ ("Haskell / GHC", "server", "https://www.haskell.org/ghc/")
    , ("Warp / WAI", "HTTP server", "https://hackage.haskell.org/package/warp")
    , ("SQLite + FTS5", "storage and search", "https://sqlite.org/")
    , ("sqlite-simple", "database access", "https://hackage.haskell.org/package/sqlite-simple")
    , ("WebAuthn", "passkeys", "https://hackage.haskell.org/package/webauthn")
    , ("Aeson", "JSON", "https://hackage.haskell.org/package/aeson")
    , ("Miso", "client, compiled to WebAssembly", "https://haskell-miso.org/")
    , ("Fraunces, Newsreader, IBM Plex Mono", "typefaces, SIL Open Font License 1.1", "https://github.com/meillaya/eza/blob/main/THIRD-PARTY-NOTICES.md#fonts")
    ]

aboutLink :: (MisoString, MisoString, MisoString) -> View () () Model Action
aboutLink (label, host, href) =
    H.li_
        []
        [ H.a_
            [ HP.class_ "about-link"
            , HP.href_ href
            , HP.target_ "_blank"
            , HP.rel_ "noopener noreferrer"
            ]
            [text label, H.span_ [HP.class_ "about-link-host"] [text host]]
        ]

{- | A same-tab download link. The server sets
@Content-Disposition: attachment@ on the export routes, so the browser keeps
the session cookie and saves the file without leaving the page.
-}
aboutDownload :: MisoString -> MisoString -> MisoString -> View () () Model Action
aboutDownload label filename href =
    H.li_
        []
        [ H.a_
            [HP.class_ "about-link", HP.href_ href]
            [text label, H.span_ [HP.class_ "about-link-host"] [text filename]]
        ]

-- ================================================================ helpers ===

-- | Render a MisoString as a plain String for concatenation into copy.
fromMisoString' :: MisoString -> String
fromMisoString' value = T.unpack (fromMisoString value)

keyCodeIsEnter :: KeyCode -> Bool
keyCodeIsEnter (KeyCode code) = code == 13
