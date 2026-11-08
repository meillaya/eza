{- | Catalogue panels: graph, duplicates, tags, AI tags, maintenance, and the
account page.

Markup, classes and copy come from the Direction B design package; the CSS
lives in static/eza.css. Every figure is read from the client model, and a
hidden state says so instead of showing an invented number.
-}
module Eza.Web.Panels (
    graphPage,
    dedupPage,
    tagsPage,
    aiTagsPage,
    maintenancePage,
    accountPage,
) where

import Data.Char (toUpper)
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T

import Miso
import qualified Miso.CSS as C
import qualified Miso.Html as H
import qualified Miso.Html.Event as HE
import qualified Miso.Html.Property as HP
import qualified Miso.Svg as Svg
import qualified Miso.Svg.Property as SP

import Eza.Types (
    BookmarkSummary (..),
    GraphData (..),
    GraphEdge (..),
    GraphNode (..),
    ImportReport (..),
    LibraryStats (..),
    TagStat (..),
 )
import Eza.Web.Model
import Eza.Web.Types (
    AccountInfo (..),
    AiStatus (..),
    ConsolGroup (..),
    Credential (..),
    DedupGroup (..),
    Rule (..),
    SessionInfo (..),
    ShareView (..),
    TagSuggestion (..),
    TokenView (..),
 )

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
    MisoString ->
    MisoString ->
    View () () Model Action
emptyPanel kicker title body extra endLeft endRight =
    H.div_
        [HP.class_ "empty"]
        ( [ H.p_ [HP.class_ "empty-kicker meta"] [text kicker]
          , H.h2_ [HP.class_ "empty-title display"] [text title]
          , H.p_ [HP.class_ "empty-body"] [text body]
          ]
            ++ extra
            ++ [ H.div_ [HP.class_ "empty-lines", HP.aria_ "hidden" "true"] (replicate 4 (H.i_ [] []))
               , H.p_
                    [HP.class_ "empty-end meta"]
                    [H.span_ [] [text endLeft], H.span_ [] [text endRight]]
               ]
        )

quietNote :: MisoString -> View () () Model Action
quietNote message = H.p_ [HP.class_ "pnl-quiet"] [text message]

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

-- ================================================================== graph ===

graphPage :: Model -> View () () Model Action
graphPage m =
    pageWith
        "The graph"
        "A record and the records around it. Lines are cross-references between records: a note that points at another, or a record that points back. The seed sits at the centre."
        (graphFigures m)
        [ "links from the record's cross-references"
        , "depth 1 or 2 hops"
        , "seed chosen by hand"
        ]
        [graphToolbar m, graphContent m]

graphFigures :: Model -> [View () () Model Action]
graphFigures m =
    [ figure "records" (countOrNotYet (length . gdNodes <$> mGraph m))
    , figure "links" (countOrNotYet (length . gdEdges <$> mGraph m))
    , figure "depth" (ms (show (mGraphDepth m)))
    ]

countOrNotYet :: Maybe Int -> MisoString
countOrNotYet Nothing = "not yet"
countOrNotYet (Just value) = num value

-- | Prefer the boot stats the masthead uses; fall back to the loaded rows.
statIntFields :: Model -> (LibraryStats -> Int) -> Int -> MisoString
statIntFields m field fallback = case mStats m of
    Nothing -> num fallback
    Just stats -> num (field stats)

graphToolbar :: Model -> View () () Model Action
graphToolbar m =
    H.div_
        [HP.class_ "g-toolbar"]
        ( [ H.div_
                [HP.class_ "g-control g-seed"]
                [ H.span_ [HP.class_ "g-control-label sc"] [text "seed"]
                , H.input_
                    [ HP.class_ "input"
                    , HP.type_ "search"
                    , HP.placeholder_ "search a record"
                    , HP.value_ (mGraphQuery m)
                    , HP.autocomplete_ "off"
                    , HP.aria_ "label" "Search a record to seed the graph"
                    , HE.onInput GraphQueryChanged
                    ]
                ]
          ]
            ++ seedResultRow m
            ++ [ H.div_
                    [HP.class_ "g-control"]
                    [ H.span_ [HP.class_ "g-control-label sc"] [text "depth"]
                    , H.div_
                        [HP.class_ "seg", HP.role_ "group", HP.aria_ "label" "Depth"]
                        (map depthButton [1, 2])
                    ]
               , H.div_
                    [HP.class_ "g-control g-view"]
                    [ H.span_ [HP.class_ "g-control-label sc"] [text "view"]
                    , H.div_
                        [HP.class_ "g-zoom-box"]
                        [ H.button_
                            [HP.class_ "g-zbtn", HP.type_ "button", HP.aria_ "label" "Zoom out", HE.onClick (GraphZoom (mGraphZoom m - 20))]
                            [text "-"]
                        , H.span_ [HP.class_ "g-zval mono"] [text (ms (show (mGraphZoom m) <> "%"))]
                        , H.button_
                            [HP.class_ "g-zbtn", HP.type_ "button", HP.aria_ "label" "Zoom in", HE.onClick (GraphZoom (mGraphZoom m + 20))]
                            [text "+"]
                        , H.button_
                            [HP.class_ "g-zbtn g-zreset", HP.type_ "button", HP.aria_ "label" "Reset the view", HE.onClick (GraphZoom 100)]
                            [text "fit"]
                        ]
                    ]
               ]
            ++ [ H.div_
                    [HP.class_ "g-control"]
                    [ H.button_
                        [HP.class_ "btn btn--sm", HP.type_ "button", HE.onClick GraphRefresh]
                        [text "refresh"]
                    ]
               ]
        )
  where
    depthButton depth =
        H.button_
            ( [ HP.type_ "button"
              , HE.onClick (GraphDepthSelected depth)
              , HP.aria_ "pressed" (if mGraphDepth m == depth then "true" else "false")
              ]
            )
            [text (ms (show depth <> if depth == 1 then " hop" else " hops"))]

-- | Search results shown directly under the seed field while typing.
seedResultRow :: Model -> [View () () Model Action]
seedResultRow m
    | null (mGraphResults m) = []
    | otherwise =
        [ H.div_
            [HP.class_ "g-seed-results"]
            (map seedButton (take 8 (mGraphResults m)))
        ]
  where
    seedButton bookmark =
        H.button_
            [ HP.class_ "tagpill"
            , HP.type_ "button"
            , HE.onClick (GraphPickSeed (bsId bookmark))
            , HP.title_ (ms (bsTitle bookmark))
            ]
            [ text (ms (shorten 46 (bsTitle bookmark)))
            , H.span_ [HP.class_ "meta"] [text (" " <> showDomain (bsDomain bookmark))]
            ]

shorten :: Int -> Text -> String
shorten limit title
    | T.length title <= limit = T.unpack title
    | otherwise = T.unpack (T.take (limit - 1) title) <> "…"

graphContent :: Model -> View () () Model Action
graphContent m
    | mGraphLoading m && mGraph m == Nothing = graphLoading
    | mGraphSeed m == Nothing =
        emptyPanel
            "no seed"
            "Seed the graph with a record."
            "Search above and pick a record, or open a record and use its graph action. The neighbourhood is drawn from the cross-references between records."
            []
            "no seed"
            "the graph waits for one"
    | mGraph m == Nothing =
        emptyPanel
            "no data"
            "No graph data yet."
            "The seed is set but the neighbourhood has not loaded. Refresh to ask the server again."
            [H.p_ [HP.class_ "empty-try"] [smallAction "load the graph" GraphRefresh]]
            "no data"
            "the server has not answered"
    | Just graph <- mGraph m
    , null (gdNodes graph) =
        emptyPanel
            "0 neighbours"
            "This neighbourhood is empty."
            "No record references this seed, or is referenced by it, at the current depth. A larger depth may find one."
            []
            "0 neighbours"
            "try another seed"
    | Just graph <- mGraph m =
        H.div_
            [HP.class_ "g-grid"]
            [ H.div_
                [HP.class_ "g-main"]
                [ graphCanvas m graph
                , graphKeyHead graph
                , graphKey m graph
                ]
            , graphStrip m graph
            ]
    | otherwise = H.span_ [] []

graphLoading :: View () () Model Action
graphLoading =
    H.div_
        [HP.class_ "g-canvas g-canvas--loading"]
        [ Svg.svg_
            [ SP.viewBox_ "0 0 1000 400"
            , HP.class_ "g-svg"
            , HP.role_ "img"
            , HP.aria_ "label" "Loading the neighbourhood"
            ]
            [ Svg.g_
                [HP.class_ "g-skel"]
                ( [ Svg.line_ [SP.x1_ "500", SP.y1_ "200", SP.x2_ "270", SP.y2_ "70"]
                  , Svg.line_ [SP.x1_ "500", SP.y1_ "200", SP.x2_ "730", SP.y2_ "70"]
                  , Svg.line_ [SP.x1_ "500", SP.y1_ "200", SP.x2_ "270", SP.y2_ "330"]
                  , Svg.line_ [SP.x1_ "500", SP.y1_ "200", SP.x2_ "730", SP.y2_ "330"]
                  ]
                    ++ [ Svg.circle_ [SP.cx_ (coord x), SP.cy_ (coord y), SP.r_ (coord radius)]
                       | (x, y, radius) <- [(500, 200, 18), (270, 70, 10), (730, 70, 10), (270, 330, 10), (730, 330, 10)]
                       ]
                )
            ]
        , H.p_ [HP.class_ "g-load-note"] [text "Building the neighbourhood."]
        ]

-- ------------------------------------------------------------ graph plate ---

{- | Hop distance from the seed. Unreachable records fall outside the rings at
hop 3, so they are still drawn and named in the key.
-}
graphHops :: GraphData -> Maybe Int -> M.Map Int Int
graphHops graph seedId = case seedId of
    Nothing -> M.empty
    Just seed -> walk (M.singleton seed 0) [seed]
  where
    adjacency =
        M.fromListWith
            (++)
            ( concat
                [ [(geSource edge, [geTarget edge]), (geTarget edge, [geSource edge])]
                | edge <- gdEdges graph
                ]
            )
    walk visited [] = visited
    walk visited (current : rest) =
        let depth = M.findWithDefault 0 current visited + 1
            neighbours = [n | n <- M.findWithDefault [] current adjacency, not (M.member n visited)]
            visited' = foldr (\n acc -> M.insert n depth acc) visited neighbours
         in walk visited' (rest ++ neighbours)

-- | Every node with its figure number: seed first, then nearer rings first.
graphOrdered :: Model -> GraphData -> [(Int, GraphNode)]
graphOrdered m graph =
    zip [1 ..] (sortOn rank (gdNodes graph))
  where
    hops = graphHops graph (mGraphSeed m)
    rank entry = (M.findWithDefault 3 (gnId entry) hops, negate (gnIndegree entry), gnId entry)

graphPositions :: Model -> GraphData -> M.Map Int (Double, Double)
graphPositions m graph =
    M.fromList
        [ (gnId entry, point hop index (length ring))
        | (hop, ring) <- M.toAscList rings
        , (index, entry) <- zip [0 :: Int ..] ring
        ]
  where
    hops = graphHops graph (mGraphSeed m)
    rings = M.fromListWith (++) [(M.findWithDefault 3 (gnId entry) hops, [entry]) | entry <- gdNodes graph]
    scale = fromIntegral (max 40 (min 260 (mGraphZoom m))) / 100
    point hop index total
        | hop == 0 = (500, 200)
        | otherwise =
            let radiusX = min 460 (180 * fromIntegral hop) * scale
                radiusY = min 168 (92 * fromIntegral hop) * scale
                angle = 2 * pi * fromIntegral index / fromIntegral (max 1 total) - pi / 2
             in (500 + radiusX * cos angle, 200 + radiusY * sin angle)

graphCanvas :: Model -> GraphData -> View () () Model Action
graphCanvas m graph =
    H.div_
        [HP.class_ "g-canvas"]
        [ Svg.svg_
            [ SP.viewBox_ "0 0 1000 400"
            , HP.class_ "g-svg"
            , HP.role_ "img"
            , HP.aria_ "label" "Record neighbourhood"
            ]
            (map edgeView (gdEdges graph) ++ map nodeView (graphOrdered m graph))
        ]
  where
    positions = graphPositions m graph
    hops = graphHops graph (mGraphSeed m)
    edgeView edge =
        case (M.lookup (geSource edge) positions, M.lookup (geTarget edge) positions) of
            (Just (x1, y1), Just (x2, y2)) ->
                Svg.line_
                    [ key_ (ms ("edge-" <> show (geSource edge) <> "-" <> show (geTarget edge)))
                    , SP.x1_ (coord x1)
                    , SP.y1_ (coord y1)
                    , SP.x2_ (coord x2)
                    , SP.y2_ (coord y2)
                    , HP.class_ (edgeClass edge)
                    ]
            _ -> Svg.g_ [] []

    edgeClass edge
        | max (hopOf (geSource edge)) (hopOf (geTarget edge)) >= 2 = "g-edge g-edge--2"
        | otherwise = "g-edge"
    hopOf nodeId = M.findWithDefault 3 nodeId hops

    nodeView (index, entry) =
        case M.lookup (gnId entry) positions of
            Nothing -> Svg.g_ [] []
            Just (x, y) ->
                Svg.g_
                    [ key_ (gnId entry)
                    , HP.class_ (nodeClass entry)
                    , HP.role_ "button"
                    , HP.aria_ "label" (ms (gnTitle entry <> T.pack (", " <> show (gnIndegree entry) <> " incoming links")))
                    , HP.title_ (ms (gnTitle entry))
                    , HE.onClick (Navigate (Bookmark (gnId entry)))
                    ]
                    [ Svg.circle_ [HP.class_ "g-hit", SP.cx_ (coord x), SP.cy_ (coord y), SP.r_ "24"]
                    , Svg.circle_ [SP.cx_ (coord x), SP.cy_ (coord y), SP.r_ (coord (nodeRadius entry))]
                    , Svg.text_
                        [ HP.class_ "g-num"
                        , SP.x_ (coord x)
                        , SP.y_ (coord (y + 4))
                        , SP.textAnchor_ "middle"
                        ]
                        [text (ms (show index))]
                    ]

    nodeClass entry =
        "g-node"
            <> (if mGraphSeed m == Just (gnId entry) then " is-seed" else "")
            <> (if hopLevel (gnId entry) >= 2 then " is-hop2" else "")
    hopLevel nodeId = M.findWithDefault 3 nodeId hops
    nodeRadius entry =
        6 + fromIntegral (min 8 (gnIndegree entry)) + (if mGraphSeed m == Just (gnId entry) then 5 else 0)

graphKeyHead :: GraphData -> View () () Model Action
graphKeyHead graph =
    H.div_
        [HP.class_ "g-key-head"]
        [ H.span_ [HP.class_ "sc"] [text "key"]
        , H.span_
            [HP.class_ "meta"]
            [text (ms (show (length (gdNodes graph)) <> if length (gdNodes graph) == 1 then " record drawn, incoming links on the right" else " records drawn, incoming links on the right"))]
        ]

graphKey :: Model -> GraphData -> View () () Model Action
graphKey m graph =
    H.ol_ [HP.class_ "g-key"] (map keyRow (graphOrdered m graph))
  where
    hops = graphHops graph (mGraphSeed m)
    keyRow (index, entry) =
        H.li_
            []
            [ H.button_
                [ key_ (gnId entry)
                , HP.class_ "g-key-row"
                , HP.type_ "button"
                , HE.onClick (Navigate (Bookmark (gnId entry)))
                ]
                [ H.span_ [HP.class_ "g-key-no mono"] [text (ms (show index))]
                , H.span_ [HP.class_ "g-key-name"] [text (ms (gnTitle entry))]
                , H.span_ [HP.class_ "lead", HP.aria_ "hidden" "true"] []
                , H.span_ [HP.class_ "g-key-n mono"] [text (num (gnIndegree entry))]
                , H.span_ [HP.class_ "g-key-w mono"] [text (hopLabel (M.findWithDefault 3 (gnId entry) hops))]
                ]
            ]
    hopLabel hop
        | hop == 0 = "seed"
        | hop == 1 = "1 hop"
        | otherwise = ms (show hop <> " hops")

graphStrip :: Model -> GraphData -> View () () Model Action
graphStrip m graph =
    case (mGraphSeed m, seedNode) of
        (Just seedId, Just seedEntry) ->
            H.aside_
                [HP.class_ "g-strip", HP.aria_ "label" "Seed record"]
                [ H.div_
                    [HP.class_ "g-strip-head"]
                    [ H.span_ [HP.class_ "sc"] [text "seed record"]
                    , H.span_ [HP.class_ "meta"] [text (ms ("depth " <> show (mGraphDepth m)))]
                    ]
                , H.h2_ [HP.class_ "g-strip-name"] [text (ms (gnTitle seedEntry))]
                , H.p_
                    [HP.class_ "g-strip-count"]
                    [H.span_ [HP.class_ "mono"] [text (num (gnIndegree seedEntry))], H.span_ [HP.class_ "meta"] [text "incoming links"]]
                , H.div_
                    [HP.class_ "g-strip-sec"]
                    [ H.h3_ [] [text "tags"]
                    , H.div_ [HP.class_ "g-strip-tags"] (map tagPill (gnTags seedEntry))
                    ]
                , H.div_
                    [HP.class_ "g-strip-sec"]
                    [ H.h3_ [] [text "address"]
                    , H.p_ [HP.class_ "pnl-quiet"] [text (ms (gnUrl seedEntry))]
                    ]
                , H.div_
                    [HP.class_ "g-strip-act"]
                    [ smallActionStrong "open the record" (Navigate (Bookmark seedId))
                    , smallAction "clear the seed" (GraphSeed Nothing)
                    ]
                ]
        _ ->
            H.aside_
                [HP.class_ "g-strip", HP.aria_ "label" "Seed record"]
                [ H.div_
                    [HP.class_ "g-strip-head"]
                    [ H.span_ [HP.class_ "sc"] [text "seed record"]
                    , H.span_ [HP.class_ "meta"] [text "none"]
                    ]
                , H.p_ [HP.class_ "pnl-quiet"] [text "Pick a record above. Its tags decide which records join the plate."]
                ]
  where
    seedNode = do
        seedId <- mGraphSeed m
        case [entry | entry <- gdNodes graph, gnId entry == seedId] of
            (entry : _) -> Just entry
            [] -> Nothing

tagPill :: Text -> View () () Model Action
tagPill tag =
    H.span_ [HP.class_ "tagpill"] [text (ms tag)]

smallActionStrong :: MisoString -> Action -> View () () Model Action
smallActionStrong label action =
    H.button_
        [HP.class_ "btn btn--sm btn--strong", HP.type_ "button", HE.onClick action]
        [text label]

coord :: Double -> MisoString
coord value = ms (show (round value :: Int))

-- ============================================================== duplicates ===

dedupPage :: Model -> View () () Model Action
dedupPage m =
    pageWith
        "Duplicates"
        "The same page, saved more than once. The test is the normalised URL: the protocol, a leading www. and trailing slashes do not make a different source."
        (dedupFigures m)
        [ "normalised URLs"
        , "merges write an undo snapshot"
        ]
        (dedupBody m)

dedupFigures :: Model -> [View () () Model Action]
dedupFigures m =
    [ figure "groups" (countOrNotYet (loadingGuard (length (mDedup m))))
    , figure "records" (countOrNotYet (loadingGuard (sum (map (length . dgItems) (mDedup m)))))
    , figure "after merge" (countOrNotYet (loadingGuard (length (mDedup m))))
    ]
  where
    loadingGuard value
        | mDedupLoading m && null (mDedup m) = Nothing
        | otherwise = Just value

dedupBody :: Model -> [View () () Model Action]
dedupBody m
    | mDedupLoading m && null (mDedup m) = [H.p_ [HP.class_ "pnl-quiet"] [text "Finding duplicate candidates."]]
    | null (mDedup m) =
        [ emptyPanel
            "0 groups"
            "No duplicates."
            "Every saved URL is unique after normalisation. The test runs over the whole library: strip the protocol, a leading www. and trailing slashes, then compare."
            []
            "0 groups"
            "0 records to merge"
        ]
    | otherwise =
        [ H.div_
            [HP.class_ "dd-note"]
            [ secHead "The test" (ms (show (length (mDedup m)) <> " groups in the library"))
            ]
        , H.div_ [HP.class_ "dd-groups"] (map (uncurry (dedupGroupView m)) (zip [0 ..] (mDedup m)))
        , H.p_
            [HP.class_ "dd-note-foot"]
            [ H.span_ [HP.class_ "meta"] [text (ms (show (length (mDedup m)) <> " groups remain"))]
            , H.span_ [HP.class_ "meta"] [text "each merge writes an undo snapshot"]
            ]
        ]

dedupGroupView :: Model -> Int -> DedupGroup -> View () () Model Action
dedupGroupView m groupIndex (DedupGroup key items) =
    H.section_
        [key_ groupIndex, HP.class_ "dd-group"]
        [ H.div_
            [HP.class_ "dd-head"]
            [ H.span_ [HP.class_ "dd-no mono"] [text (pad2 (groupIndex + 1))]
            , H.span_ [HP.class_ "dd-reason"] [text (ms key)]
            , H.span_ [HP.class_ "dd-count meta"] [text (ms (show (length items) <> if length items == 1 then " record" else " records"))]
            , H.span_ [HP.class_ "dd-act"] []
            ]
        , H.div_
            [HP.class_ "dd-rows", HP.role_ "radiogroup", HP.aria_ "label" "Keep one copy"]
            (map (dedupRow m groupIndex kept) (zip [0 :: Int ..] items))
        , H.div_
            [HP.class_ "dd-foot"]
            [ H.span_ [HP.class_ "dd-sum"] [text (ms (keepSummary items))]
            , H.span_
                [HP.class_ "dd-actions"]
                [ smallAction "open the kept record" (Navigate (Bookmark kept))
                , strongAction (ms ("merge " <> show (max 0 (length items - 1)) <> " into 1")) [] (DedupMerge groupIndex)
                ]
            ]
        ]
  where
    kept = dedupKeep m groupIndex items

dedupRow :: Model -> Int -> Int -> (Int, BookmarkSummary) -> View () () Model Action
dedupRow _ groupIndex kept (_itemIndex, item) =
    H.label_
        [HP.class_ ("dd-row" <> if kept == bsId item then " is-keep" else "")]
        [ H.input_
            ( [ key_ (bsId item)
              , HP.class_ "dd-radio"
              , HP.type_ "radio"
              , HP.name_ (ms ("keep-" <> show groupIndex))
              , HP.aria_ "label" (ms ("Keep " <> T.unpack (bsTitle item)))
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

{- | The keeper the client action will use: the explicit choice when there is
one, otherwise the first member of the group (matching Update's fallback).
-}
dedupKeep :: Model -> Int -> [BookmarkSummary] -> Int
dedupKeep _ _ [] = 0
dedupKeep m groupIndex (first : _) =
    fromMaybe (bsId first) (M.lookup groupIndex (mDedupChoice m))

keepSummary :: [BookmarkSummary] -> String
keepSummary items =
    "keep "
        <> T.unpack (accnoText (maybe 0 bsId (safeHead items)))
        <> " · absorb "
        <> show (max 0 (length items - 1))
        <> " · tags union"

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
        , "merge and rename write a snapshot first"
        ]
        [ H.div_
            [HP.class_ "tg-grid"]
            [ tagsTable m
            , H.aside_ [HP.class_ "tg-side"] (consolidationBlock m ++ tagsMethodBlock)
            ]
        ]

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
        , case mConsol m of
            _
                | mConsolLoading m && null (mConsol m) -> quietNote "Scanning tags."
                | otherwise -> consolRows
        , H.p_
            [HP.class_ "pnl-quiet"]
            [text "Case duplicates cannot exist: the tags table is unique by name, case-insensitive. Near misses are pairs of names worth a review."]
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
        "junk" -> "junk · delete a name with its cross"
        "case" -> "case duplicate"
        "fuzzy" -> "near duplicate"
        _ -> ms (T.toTitle kind)
    suggestionAction
        | T.null (T.strip (cgSuggested group)) = []
        | otherwise =
            [ H.span_ [HP.class_ "fz-d mono"] [text (ms (cgSuggested group))]
            , strongAction
                (ms ("merge into " <> T.unpack (cgSuggested group)))
                []
                (TagMerge (map tsName (cgTags group)) (cgSuggested group))
            ]

tagChipButton :: TagStat -> View () () Model Action
tagChipButton tag =
    H.button_
        [ HP.class_ "tagpill"
        , HP.type_ "button"
        , HP.title_ "Delete this tag"
        , HE.onClick (TagDeleted (tsName tag))
        ]
        [ text (ms (tsName tag))
        , H.span_ [HP.class_ "chip-x"] [text " ×"]
        ]

tagsMethodBlock :: [View () () Model Action]
tagsMethodBlock =
    [ H.section_
        [HP.class_ "pnl-block"]
        [ secHead "Making changes" "undo snapshot"
        , H.p_
            [HP.class_ "pnl-quiet"]
            [text "Click a tag to filter the library by it. The cross beside a tag in a consolidation group deletes that name; merge folds a group into the suggested name. Every change writes an undo snapshot first."]
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
    , H.p_
        [HP.class_ "ai-foot"]
        [ H.span_ [HP.class_ "meta"] [text "suggestions are advisory"]
        , H.span_ [HP.class_ "meta"] [text "apply writes the tags to the record"]
        ]
    ]

suggestionBody :: Model -> View () () Model Action
suggestionBody m
    | mSuggestionsLoading m && null (mSuggestions m) = quietNote "Asking the provider."
    | null (mSuggestions m) = quietNote (noSuggestionsText m)
    | otherwise =
        H.div_
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
        "The condition of the archive: the dead-link sweep, the prune candidates and the undo record. Nothing changes without a snapshot written first."
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
        | mCheckedCount m == Nothing = "No dead-link check has ever been recorded for this library. This is the never-run state, not a clean bill of health: the zero is the absence of a result."
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
        , if null (mPrune m)
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
            [ H.h2_ [HP.class_ "pnl-sec-title"] [text "Undo record"]
            , H.span_ [HP.class_ "mt-state"] [H.span_ [HP.class_ "meta"] [text "none recorded"]]
            ]
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
                [ H.h1_ [HP.class_ "account-title display"] [text "Account"]
                , H.p_
                    [HP.class_ "account-lede"]
                    [text "Who may enter the catalogue, and what leaves it. Everything here is stored in the same SQLite file as the entries."]
                ]
            , ruleLine
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
        , H.p_
            [HP.class_ "account-index-note meta"]
            [text "Sections marked with a figure hold one or more records."]
        ]
  where
    tabs =
        [ (AccountPasskeys, "passkeys", "passkeys", credentialCount m)
        , (AccountRecovery, "recovery", "recovery", Nothing)
        , (AccountSessions, "sessions", "sessions", Just (length (mSessions m)))
        , (AccountTokens, "api tokens", "tokens", Just (length (mTokens m)))
        , (AccountShares, "share links", "shares", Just (length (activeShares m)))
        , (AccountRules, "rules", "rules", Just (length (mRules m)))
        , (AccountImport, "import", "import", Nothing)
        , (AccountCapture, "capture", "capture", Nothing)
        , (AccountAppearance, "appearance", "appearance", Nothing)
        , (AccountAbout, "about", "about", Nothing)
        ]

navItem :: Model -> (AccountTab, MisoString, MisoString, Maybe Int) -> View () () Model Action
navItem m (tab, label, slug, count) =
    H.li_
        []
        [ H.button_
            ( [ HP.type_ "button"
              , HE.onClick (AccountTabSelected tab)
              , testId ("account-tab-" <> slug)
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
    AccountPasskeys -> passkeysPanel m
    AccountRecovery -> recoveryPanel m
    AccountSessions -> sessionsPanel m
    AccountTokens -> tokensPanel m
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
        | otherwise = [unavailable m]
    body (Just account) =
        [ H.p_
            [HP.class_ "account-lede"]
            [text "The library opens with a passkey. The private half stays in the device's keychain or security key; eza keeps only the public half."]
        , H.div_ [HP.class_ "account-list"] (map (credentialRecord m) (aiCredentials account))
        , H.div_
            [HP.class_ "account-actions"]
            [ H.a_
                [HP.class_ "btn btn--strong", HP.href_ "/account/add-passkey"]
                [text "add another device"]
            , H.button_
                [HP.class_ "btn", HP.type_ "button", HE.onClick (AccountTabSelected AccountRecovery)]
                [text "see recovery codes"]
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
                  , text (ms ("last used " <> maybe "never" fromMisoString' (formatFiled <$> crLastUsedAt credential)))
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
                [HP.class_ "btn btn--danger", HP.type_ "button", HE.onClick Logout]
                [text "sign out"]
            ]
        , H.p_
            [HP.class_ "account-note meta"]
            [text "Signing out ends this browser's session. The passkey stays on the device."]
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

tokensPanel :: Model -> View () () Model Action
tokensPanel m =
    accountPanel "tokens" "API tokens" tokenNote $
        [ H.p_
            [HP.class_ "account-lede"]
            [text "Tokens let the command line and the phone's share sheet file links without a passkey. Each one is scoped and can be revoked at any time."]
        ]
            ++ created
            ++ [ H.div_ [HP.class_ "account-list"] tokenRows
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
            ++ ( if null (activeShares m)
                    then [shareEmpty m]
                    else [H.div_ [HP.class_ "account-list"] (map shareRecord (mShares m))]
               )
  where
    shareNote =
        let count = length (activeShares m)
         in ms (show count <> if count == 1 then " active link" else " active links")

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

shareRecord :: ShareView -> View () () Model Action
shareRecord share =
    H.div_
        [ HP.class_ ("account-record" <> if isJust (svRevokedAt share) then " is-revoked" else "")
        , testId "share-link-row"
        ]
        [ H.div_
            [HP.class_ "account-record-main"]
            [ H.h3_ [HP.class_ "account-record-title"] [text (ms (shareTargetLabel share))]
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
    shareTargetLabel target = case svScope target of
        "bookmark" -> ms ("record " <> show (svTargetId target))
        "saved_search" -> ms ("saved search " <> show (svTargetId target))
        other -> ms other

-- ----------------------------------------------------------------- rules ---

rulesPanel :: Model -> View () () Model Action
rulesPanel m =
    accountPanel "rules" "Rules" ruleNote $
        [ H.p_
            [HP.class_ "account-lede"]
            [text "A rule files new links automatically: match on the address, the source or the title, then add tags or mark the record read."]
        ]
            ++ [ H.div_ [HP.class_ "account-list", testId "rules-table"] (map ruleRecord (mRules m))
               ]
            ++ [ruleEmpty m | null (mRules m)]
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
            [text "Bookmarks arrive as a Netscape HTML export from any browser. Importing keeps the original save dates and turns folders into tags."]
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
                [ H.span_ [HP.class_ "account-import-name mono"] [text "bookmarks.html"]
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
            [text ".html exported from Chrome, Firefox, Safari or Edge. Nothing is imported twice."]
        , H.div_
            [HP.class_ "account-actions"]
            [ H.button_
                ( [HP.class_ "btn btn--strong", HP.type_ "button", HE.onClick ImportStart]
                    ++ attrDisabled (mImporting m)
                )
                [text (if mImporting m then "importing" else "choose bookmarks.html")]
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
        "this library"
        [ H.p_
            [HP.class_ "account-lede"]
            [text "eza is a self-hosted bookmark library for one person, written in Haskell and served from a single SQLite file. No account with us, no sync, no telemetry."]
        , H.dl_ [HP.class_ "account-about-list"] (map aboutRow (aboutFigures m))
        , H.p_
            [HP.class_ "account-note meta"]
            ( case mStats m of
                Nothing -> [text "The figures are not loaded yet."]
                Just _ -> [text "The figures above are read from the library's own database at load."]
            )
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
        , ("license", "Apache 2.0")
        ]
    Just stats ->
        [ ("entries", num (lsTotal stats))
        , ("tags", num (lsTags stats))
        , ("tag links", num (lsTagLinks stats))
        , ("filing days", num (lsDays stats))
        , ("first accession", isoStamp (lsFirstDay stats))
        , ("last accession", isoStamp (lsLastDay stats))
        , ("license", "Apache 2.0")
        ]

aboutRow :: (MisoString, MisoString) -> View () () Model Action
aboutRow (label, value) =
    H.div_ [] [H.dt_ [] [text label], H.dd_ [HP.class_ "mono"] [text value]]

-- ================================================================ helpers ===

-- | Render a MisoString as a plain String for concatenation into copy.
fromMisoString' :: MisoString -> String
fromMisoString' value = T.unpack (fromMisoString value)

keyCodeIsEnter :: KeyCode -> Bool
keyCodeIsEnter (KeyCode code) = code == 13
