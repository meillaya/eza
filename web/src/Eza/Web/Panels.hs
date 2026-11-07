-- | Feature pages: graph, duplicates, tags, AI tags, maintenance, account.
module Eza.Web.Panels (
    graphPage,
    dedupPage,
    tagsPage,
    aiTagsPage,
    maintenancePage,
    accountPage,
) where

import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T

import Miso
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
    TagStat (..),
 )
import Eza.Web.Model
import Eza.Web.Types (AccountInfo (..), AiStatus (..), ConsolGroup (..), Credential (..), DedupGroup (..), Rule (..), ShareView (..), TagSuggestion (..), TokenView (..))
import Eza.Web.Widgets

pageHeader :: MisoString -> [View () () Model Action] -> View () () Model Action
pageHeader title actions =
    H.div_
        [HP.class_ "content-head"]
        [ H.div_ [] [H.h2_ [HP.class_ "head-title"] [text title]]
        , H.div_ [HP.class_ "head-actions"] actions
        ]

-- ----------------------------------------------------------------- graph ---

graphPage :: Model -> View () () Model Action
graphPage m =
    H.div_
        [HP.class_ "stack"]
        [ pageHeader "Graph" [btnSm "Refresh" GraphRefresh]
        , H.p_
            [HP.class_ "muted"]
            [text "Pick a bookmark to seed the neighbourhood, then explore links up to three hops away."]
        , H.div_
            [HP.class_ "group-card"]
            [ H.input_
                [ HP.class_ "input"
                , HP.placeholder_ "Search a bookmark to seed the graph…"
                , HP.value_ (mGraphQuery m)
                , HP.autocomplete_ "off"
                , HE.onInput GraphQueryChanged
                ]
            , if null (mGraphResults m)
                then H.div_ [] []
                else H.div_ [HP.class_ "row-wrap"] (map seedResult (take 8 (mGraphResults m)))
            ]
        , H.div_
            [HP.class_ "graph-toolbar"]
            [ H.span_ [HP.class_ "muted"] [text "Depth"]
            , H.div_
                [HP.class_ "seg"]
                [ segBtn (mGraphDepth m == 1) "1 hop" (GraphDepthSelected 1)
                , segBtn (mGraphDepth m == 2) "2 hops" (GraphDepthSelected 2)
                , segBtn (mGraphDepth m == 3) "3 hops" (GraphDepthSelected 3)
                ]
            , iconBtn iBack "Zoom out" (GraphZoom (mGraphZoom m - 20))
            , H.span_ [HP.class_ "muted"] [text (ms (show (mGraphZoom m) <> "%"))]
            , iconBtn iPlus "Zoom in" (GraphZoom (mGraphZoom m + 20))
            , case mGraphSeed m of
                Nothing -> H.span_ [] []
                Just _ -> btnSm "Clear seed" (GraphSeed Nothing)
            ]
        , content
        , if mGraph m == Nothing
            then H.div_ [] []
            else
                H.div_
                    [HP.class_ "graph-legend"]
                    [ H.span_ [] [H.span_ [HP.class_ "legend-dot seed"] [], text "seed"]
                    , H.span_ [] [H.span_ [HP.class_ "legend-dot"] [], text "unread"]
                    , H.span_ [] [H.span_ [HP.class_ "legend-dot read"] [], text "read"]
                    ]
        ]
  where
    seedResult bookmark =
        H.button_
            [ HP.class_ "tag-pill"
            , HP.type_ "button"
            , HE.onClick (GraphPickSeed (bsId bookmark))
            ]
            [ text (ms (bsTitle bookmark))
            , H.span_ [HP.class_ "n"] [text (ms (bsDomain bookmark))]
            ]
    content
        | mGraphSeed m == Nothing =
            emptyState
                "🕸"
                "Seed the graph with a bookmark"
                [ H.p_ [] [text "Search above and pick a bookmark, or open any bookmark and use its Graph action."]
                ]
        | mGraphLoading m && mGraph m == Nothing = spinnerRow "Building the neighbourhood…"
        | otherwise = case mGraph m of
            Nothing ->
                emptyState
                    "🕸"
                    "No graph data yet"
                    [ H.p_ [] [text "Refresh to load the neighbourhood for the selected bookmark."]
                    , btn "btn-primary" [HE.onClick GraphRefresh] [text "Load graph"]
                    ]
            Just graph
                | null (gdNodes graph) ->
                    emptyState "🕸" "This neighbourhood is empty" [H.p_ [] [text "Try a different bookmark or depth."]]
                | otherwise -> graphSvg m graph

graphSvg :: Model -> GraphData -> View () () Model Action
graphSvg m graph =
    H.div_
        [HP.class_ "graph-canvas"]
        [ Svg.svg_
            [SP.viewBox_ "0 0 720 480", HP.class_ "graph-svg", HP.role_ "img", HP.aria_ "label" "Bookmark link graph"]
            (concatMap edgeView (gdEdges graph) ++ map nodeView (gdNodes graph))
        ]
  where
    positions = nodePositions m (gdNodes graph)
    seedId = mGraphSeed m

    posOf nodeId = M.lookup nodeId positions

    edgeView edge = case (posOf (geSource edge), posOf (geTarget edge)) of
        (Just (x1, y1), Just (x2, y2)) ->
            [ Svg.line_
                [ SP.x1_ (num x1)
                , SP.y1_ (num y1)
                , SP.x2_ (num x2)
                , SP.y2_ (num y2)
                , HP.class_ "graph-edge"
                ]
            ]
        _ -> []

    nodeView node =
        case posOf (gnId node) of
            Nothing -> H.span_ [] []
            Just (x, y) ->
                Svg.g_
                    [ HP.class_ (nodeClass node)
                    , HE.onClick (Navigate (Bookmark (gnId node)))
                    ]
                    [ Svg.circle_ [SP.cx_ (num x), SP.cy_ (num y), SP.r_ "9"]
                    , Svg.text_
                        [SP.x_ (num x), SP.y_ (num (y + 24)), SP.textAnchor_ "middle"]
                        [text (ms (shorten (gnTitle node)))]
                    ]

    nodeClass node =
        "graph-node"
            <> (if gnIsRead node then " is-read" else "")
            <> (if seedId == Just (gnId node) then " is-seed" else "")

nodePositions :: Model -> [GraphNode] -> M.Map Int (Double, Double)
nodePositions m nodes =
    M.fromList
        [ (gnId node, point index count)
        | (index, node) <- zip [0 ..] nodes
        , let count = max 1 (length nodes)
        ]
  where
    scale = fromIntegral (max 40 (mGraphZoom m)) / 100.0
    radius = (150.0 * scale) :: Double
    point index count =
        let angle = 2 * pi * fromIntegral index / fromIntegral count
         in (360.0 + radius * cos angle, 240.0 + radius * sin angle)

shorten :: Text -> Text
shorten title
    | T.length title <= 18 = title
    | otherwise = T.take 17 title <> "…"

num :: Double -> MisoString
num value = ms (show (round value :: Int))

-- ----------------------------------------------------------------- dedup ---

dedupPage :: Model -> View () () Model Action
dedupPage m =
    H.div_
        [HP.class_ "stack"]
        [ pageHeader "Duplicates" [btnSm "Refresh" (Navigate Dedup)]
        , H.p_
            [HP.class_ "muted"]
            [text "Pick the copy to keep, then merge the rest. Merges are reversible from Maintenance."]
        , if mDedupLoading m && null (mDedup m)
            then spinnerRow "Finding duplicate candidates…"
            else
                if null (mDedup m)
                    then
                        emptyState
                            "🧬"
                            "No duplicates found"
                            [H.p_ [] [text "Every saved URL looks unique right now."]]
                    else H.div_ [] (map (dedupGroup m) (zip [0 ..] (mDedup m)))
        ]

dedupGroup :: Model -> (Int, DedupGroup) -> View () () Model Action
dedupGroup m (groupIndex, DedupGroup _ items) =
    H.div_
        [HP.class_ "group-card"]
        [ H.div_
            [HP.class_ "group-head"]
            [ H.h3_ [HP.class_ "group-title"] [text (ms (show (length items) <> " near-identical saves"))]
            , H.span_ [HP.class_ "spacer"] []
            , btn "btn-primary btn-sm" [HE.onClick (DedupMerge groupIndex)] [text "Merge group"]
            ]
        , H.div_ [HP.class_ "group-items"] (map candidateView items)
        ]
  where
    choice = M.lookup groupIndex (mDedupChoice m)
    candidateView item =
        H.div_
            [HP.class_ "candidate"]
            [ H.input_
                ( [ HP.class_ "radio"
                  , HP.type_ "radio"
                  , HP.name_ (ms ("keep-" <> show groupIndex))
                  ]
                    ++ checkedAttr (choice == Just (bsId item))
                    ++ [HE.onClick (DedupKeep groupIndex (bsId item))]
                )
            , H.button_
                [HP.class_ "linklike cand-title", HP.type_ "button", HE.onClick (Navigate (Bookmark (bsId item)))]
                [text (ms (bsTitle item))]
            , H.span_ [HP.class_ "cand-domain"] [text (ms (bsDomain item))]
            , H.a_
                [HP.class_ "icon-btn", HP.href_ (ms (bsUrl item)), HP.target_ "_blank", HP.rel_ "noopener noreferrer", HP.title_ "Open"]
                [icon iExternal]
            ]

-- ------------------------------------------------------------------ tags ---

tagsPage :: Model -> View () () Model Action
tagsPage m =
    H.div_
        [HP.class_ "stack"]
        [ pageHeader "Tags" [btnSm "Refresh" (Navigate Tags)]
        , H.div_
            [HP.class_ "stat-grid"]
            [ statBox (formatCount (length (mTags m))) "Tags"
            , statBox (formatCount (sum (map tsCount (mTags m)))) "Tag links"
            , statBox (formatCount (length (mConsol m))) "Cleanup groups"
            ]
        , panel "All tags" [tagCloud]
        , maybe (panel "Consolidation" [H.p_ [HP.class_ "muted"] [text "Nothing to consolidate right now."]]) id consolPanel
        ]
  where
    sortedTags = take 80 (sortOn (Down . tsCount) (mTags m))
    tagCloud =
        H.div_
            [HP.class_ "tag-cloud"]
            [ H.button_
                [ HP.class_ "tag-pill"
                , HP.type_ "button"
                , HP.title_ ("Filter the library by " <> ms (tsName tag))
                , HE.onClick (FilterByTag (tsName tag))
                ]
                [text (ms (tsName tag)), H.span_ [HP.class_ "n"] [text (ms (show (tsCount tag)))]]
            | tag <- sortedTags
            ]
    consolPanel
        | mConsolLoading m = Just (H.div_ [] [spinnerRow "Scanning tags…"])
        | null (mConsol m) = Nothing
        | otherwise = Just (panel "Consolidation" (map consolGroupView (mConsol m)))

consolGroupView :: ConsolGroup -> View () () Model Action
consolGroupView group =
    H.div_
        [HP.class_ "group-card"]
        [ H.div_
            [HP.class_ "group-head"]
            [ pill (kindClass (cgKind group)) (ms (cgKind group))
            , H.h3_
                [HP.class_ "group-title"]
                [ text
                    ( if T.null (T.strip (cgSuggested group))
                        then "Junk tags — delete the ones you do not want"
                        else ms ("Suggest keeping “" <> cgSuggested group <> "”")
                    )
                ]
            , H.span_ [HP.class_ "spacer"] []
            , if T.null (T.strip (cgSuggested group))
                then pill "warn" "delete individually"
                else
                    btn
                        "btn-primary btn-sm"
                        [HE.onClick (TagMerge (map tsName (cgTags group)) (cgSuggested group))]
                        [text "Merge"]
            ]
        , H.div_
            [HP.class_ "row-wrap"]
            ( [ H.span_
                    []
                    [ H.button_
                        [HP.class_ "chip plain", HP.type_ "button", HP.title_ "Delete this tag", HE.onClick (TagDeleted (tsName tag))]
                        [text (ms (tsName tag)), H.span_ [HP.class_ "chip-x"] [text "×"]]
                    ]
              | tag <- cgTags group
              ]
            )
        ]
  where
    kindClass kind = case kind of
        "junk" -> "danger"
        "fuzzy" -> "warn"
        _ -> ""

-- -------------------------------------------------------------- ai tags ---

aiTagsPage :: Model -> View () () Model Action
aiTagsPage m =
    H.div_
        [HP.class_ "stack"]
        [ pageHeader "AI tags" [btnSm "Refresh" (Navigate AiTags)]
        , aiStatusBanner m
        , H.p_
            [HP.class_ "muted"]
            [text "Advisory suggestions only — nothing is written until you press Apply."]
        , panel "Pick a tag bucket" [H.div_ [HP.class_ "tag-cloud"] (map bucket (take 60 (mTags m)))]
        , case mAiTag m of
            Nothing ->
                emptyState
                    "✨"
                    "Choose a tag to see suggestions"
                    [H.p_ [] [text "Suggestions are grouped by tag bucket so you can review them in batches."]]
            Just selected -> suggestionsPanel m selected
        ]
  where
    bucket tag =
        H.button_
            [ HP.class_ ("tag-pill" <> if mAiTag m == Just (tsName tag) then " active" else "")
            , HP.type_ "button"
            , HE.onClick (AiTagSelected (Just (tsName tag)))
            ]
            [text (ms (tsName tag)), H.span_ [HP.class_ "n"] [text (ms (show (tsCount tag)))]]

suggestionsPanel :: Model -> Text -> View () () Model Action
suggestionsPanel m selected =
    panelWithHead
        (ms ("Suggestions for “" <> selected <> "”"))
        [btnSm "Clear" (AiTagSelected Nothing)]
        [content]
  where
    content
        | mSuggestionsLoading m && null (mSuggestions m) = spinnerRow "Asking for suggestions…"
        | null (mSuggestions m) =
            H.p_ [HP.class_ "muted"] [text "No suggestions for this bucket right now."]
        | otherwise = H.div_ [] (map (suggestionView selected) (mSuggestions m))

suggestionView :: Text -> TagSuggestion -> View () () Model Action
suggestionView _suggestionTag suggestion =
    H.div_
        [HP.class_ "suggestion"]
        [ H.div_
            [HP.class_ "suggestion-main"]
            ( [ H.button_
                    [HP.class_ "linklike suggestion-title", HP.type_ "button", HE.onClick (Navigate (Bookmark (bsId bookmark)))]
                    [text (ms (bsTitle bookmark))]
              | Just bookmark <- [tsgBookmark suggestion]
              ]
                ++ [ H.div_ [HP.class_ "suggestion-reason"] [text (ms (tsgReason suggestion))]
                   ]
                ++ [ H.div_
                        [HP.class_ "suggestion-tags"]
                        [H.span_ [HP.class_ "tag-chip"] [text (ms tag)] | tag <- tsgTags suggestion]
                   ]
            )
        , H.div_
            [HP.class_ "row"]
            ( [ btn
                    "btn-primary btn-sm"
                    [HE.onClick (SuggestionApply (bsId bookmark) (tsgTags suggestion))]
                    [text "Apply"]
              | Just bookmark <- [tsgBookmark suggestion]
              ]
                ++ [btnSm "Dismiss" Noop]
            )
        ]

-- ---------------------------------------------------------- maintenance ---

maintenancePage :: Model -> View () () Model Action
maintenancePage m =
    H.div_
        [HP.class_ "stack"]
        [ pageHeader "Maintenance" []
        , H.div_
            [HP.class_ "stat-grid"]
            [ statBox (maybe "—" (formatCount) (mCheckedCount m)) "Links checked"
            , statBox (maybe "—" (formatCount) (mDeadCount m)) "Dead links"
            , statBox (formatCount (length (mPrune m))) "Prune candidates"
            ]
        , panel
            "Dead-link sweep"
            [ H.div_
                [HP.class_ "action-row"]
                [ H.div_
                    [HP.class_ "action-text"]
                    [ H.div_ [HP.class_ "action-title"] [text "Check links for dead pages"]
                    , H.div_ [HP.class_ "action-desc"] [text "Runs a HEAD/GET check against saved URLs and flags failures."]
                    ]
                , btn
                    "btn-primary"
                    (disabledAttr (mMaintBusy m) ++ [HE.onClick DeadCheckRun])
                    [text (if mMaintBusy m then "Working…" else "Check dead links")]
                ]
            ]
        , panel
            "Prune candidates"
            [ H.div_
                [HP.class_ "row-wrap"]
                ( [ btnSm "Select all" PruneAll
                  , H.span_ [HP.class_ "muted"] [text (ms (show (length (mPruneSel m)) <> " selected"))]
                  , H.span_ [HP.class_ "spacer"] []
                  , btn
                        "btn-danger btn-sm"
                        ( disabledAttr (null (mPruneSel m) || mMaintBusy m)
                            ++ [HE.onClick PruneRun]
                        )
                        [text (if mConfirmPrune m then "Confirm prune" else "Prune selected")]
                  ]
                    ++ [btnSm "Cancel" PruneCancel | mConfirmPrune m]
                )
            , H.div_
                [HP.class_ "group-items"]
                ( [ pruneRow m item | item <- mPrune m
                  ]
                    ++ [H.p_ [HP.class_ "muted"] [text "No prune candidates right now."] | null (mPrune m)]
                )
            ]
        , panel
            "Undo"
            [ H.div_
                [HP.class_ "action-row"]
                [ H.div_
                    [HP.class_ "action-text"]
                    [ H.div_ [HP.class_ "action-title"] [text "Restore the last destructive action"]
                    , H.div_ [HP.class_ "action-desc"] [text "Merges and prunes are snapshotted; undo restores them."]
                    ]
                , btn "" (disabledAttr (mMaintBusy m) ++ [HE.onClick UndoRun]) [text "Undo last action"]
                ]
            ]
        ]

pruneRow :: Model -> BookmarkSummary -> View () () Model Action
pruneRow m item =
    H.div_
        [HP.class_ "candidate"]
        [ H.input_
            ( [ HP.class_ "radio"
              , HP.type_ "checkbox"
              , HE.onClick (PruneToggle (bsId item))
              ]
                ++ checkedAttr (bsId item `elem` mPruneSel m)
            )
        , H.button_
            [HP.class_ "linklike cand-title", HP.type_ "button", HE.onClick (Navigate (Bookmark (bsId item)))]
            [text (ms (bsTitle item))]
        , H.span_ [HP.class_ "cand-domain"] [text (ms (bsDomain item))]
        ]

-- -------------------------------------------------------------- account ---

accountPage :: Model -> View () () Model Action
accountPage m =
    H.div_
        [HP.class_ "stack"]
        [ pageHeader "Account" [btn "btn-danger btn-sm" [HE.onClick Logout] [text "Sign out"]]
        , capturePanel m
        , tokensPanel m
        , sharesPanel m
        , rulesPanel m
        , case mAccount m of
            Nothing
                | mAccountLoading m -> spinnerRow "Loading account…"
                | otherwise ->
                    emptyState
                        "🔐"
                        "Account details unavailable"
                        [H.p_ [] [text "The account endpoint is not reachable yet."]]
            Just account ->
                H.div_
                    [HP.class_ "stack"]
                    [ panelWithHead
                        "Passkeys"
                        [ H.a_
                            [HP.class_ "btn btn-sm", HP.href_ "/account/add-passkey", HP.title_ "Register another passkey"]
                            [icon iUser, text "Add passkey"]
                        ]
                        ( [credentialRow m credential | credential <- aiCredentials account]
                            ++ [ H.p_
                                    [HP.class_ "muted"]
                                    [text "Passkeys are registered through WebAuthn; use the server page to add one, then manage it here."]
                               | null (aiCredentials account)
                               ]
                        )
                    , panel
                        "Recovery codes"
                        ( [ H.p_
                                [HP.class_ "muted"]
                                [text (ms (show (aiRecoveryRemaining account) <> " unused recovery codes remain."))]
                          , H.div_
                                [HP.class_ "row-wrap"]
                                [ btn "btn-primary" [HE.onClick RecoveryRegenerate] [text "Regenerate recovery codes"]
                                , H.span_ [HP.class_ "muted"] [text "Regenerating invalidates all old codes."]
                                ]
                          ]
                            ++ [ H.div_
                                    [HP.class_ "stack"]
                                    [ H.div_
                                        [HP.class_ "recovery-grid"]
                                        [H.div_ [HP.class_ "recovery-code"] [text (ms code)] | code <- mRecoveryCodes m]
                                    , H.p_ [HP.class_ "muted"] [text "Store these somewhere safe — they are shown only once."]
                                    ]
                               | not (null (mRecoveryCodes m))
                               ]
                        )
                    ]
        ]

-- | Bookmarklet + install guidance for the PWA capture story.
capturePanel :: Model -> View () () Model Action
capturePanel m =
    panelWithHead
        "Capture"
        []
        [ H.p_
            [HP.class_ "muted"]
            [text "Save the page you are reading without leaving it: drag the button below to your bookmarks bar, or share a link to the installed app."]
        , H.div_
            [HP.class_ "capture-box"]
            [ bookmarkletLink m
            , H.pre_ [HP.class_ "capture-code"] [H.code_ [] [bookmarkletCode m]]
            , H.div_
                [HP.class_ "capture-actions"]
                [ btn
                    "btn-primary"
                    ([HE.onClick (CopyBookmarklet (captureBookmarklet m))] <> disabledAttr (not (hasBookmarklet m)))
                    [text "Copy bookmarklet"]
                ]
            ]
        , H.div_ [HP.class_ "divider"] []
        , H.p_
            [HP.class_ "capture-note muted"]
            [text "Install eza as an app from the browser install prompt (or menu → Install eza) for a standalone window and a system share target. The install button only appears after the browser fires beforeinstallprompt."]
        ]

hasBookmarklet :: Model -> Bool
hasBookmarklet m = not (T.null (T.strip (fromMisoString (captureBookmarklet m) :: Text)))

bookmarkletLink :: Model -> View () () Model Action
bookmarkletLink m
    | not (hasBookmarklet m) =
        H.span_ [HP.class_ "muted"] [text "Bookmarklet becomes available once the app knows its origin."]
    | otherwise =
        H.a_
            [ HP.class_ "btn capture-bookmarklet"
            , HP.href_ (captureBookmarklet m)
            , HP.title_ "Drag this link to the bookmarks bar"
            ]
            [icon iPlus, text "Save to eza"]

bookmarkletCode :: Model -> View () () Model Action
bookmarkletCode m =
    H.code_ [] [text (if hasBookmarklet m then captureBookmarklet m else "javascript:(loading origin…)")]

{- | Bookmarklet built from the live window origin, opening /save with the
current page title and URL (the manifest share_target contract).
-}
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

{- | Bearer API tokens: list, create (scope checkboxes), one-time reveal,
revoke.  Session-only on the server side.
-}
tokensPanel :: Model -> View () () Model Action
tokensPanel m =
    panelWithHead
        "API tokens"
        ([H.span_ [HP.class_ "muted"] [text (ms (show (length (mTokens m)) <> " token(s)"))] | not (null (mTokens m))])
        [ H.p_
            [HP.class_ "muted"]
            [text "Bearer tokens let browser extensions and shortcuts read and write eza. Create them here; bearer tokens cannot manage other tokens."]
        , H.div_
            [HP.class_ "token-form"]
            [ H.input_
                [ HP.id_ "token-name"
                , HP.class_ "input"
                , HP.placeholder_ "Token name (e.g. iOS shortcut)"
                , HP.value_ (mTokenName m)
                , HP.autocomplete_ "off"
                , HE.onInput TokenNameInput
                ]
            , H.div_
                [HP.class_ "row-wrap"]
                (map scopeOption ["read", "write", "capture"])
            , btn
                "btn-primary"
                ([HE.onClick TokenCreate] ++ disabledAttr (mTokenBusy m))
                [text (if mTokenBusy m then "Creating…" else "Create token")]
            ]
        , case mTokenSecret m of
            Nothing -> H.div_ [] []
            Just (raw, _) ->
                H.div_
                    [HP.class_ "token-reveal", HP.role_ "alert"]
                    [ H.div_ [HP.class_ "token-reveal-title"] [text "Copy this token now — it is shown only once"]
                    , H.pre_ [HP.class_ "token-secret"] [H.code_ [] [text (ms raw)]]
                    , H.div_
                        [HP.class_ "row-wrap"]
                        [ btn "btn-primary" [HE.onClick (TokenCopied raw)] [text "Copy token"]
                        , btn "btn-ghost" [HE.onClick TokenRevealDismiss] [text "Done"]
                        ]
                    ]
        , if mTokensLoading m && null (mTokens m)
            then spinnerRow "Loading tokens…"
            else
                H.div_
                    [HP.class_ "stack"]
                    ( [tokenRow token | token <- mTokens m]
                        ++ [ H.p_ [HP.class_ "muted"] [text "No API tokens yet."]
                           | null (mTokens m)
                           ]
                    )
        ]
  where
    scopeOption scope =
        H.label_
            [HP.class_ "scope-option"]
            [ H.input_
                [ HP.type_ "checkbox"
                , HP.class_ "scope-option-box"
                , HP.checked_ (scope `elem` mTokenScopes m)
                , HE.onClick (TokenScopeToggled scope)
                ]
            , text (ms scope)
            ]
    tokenRow token =
        H.div_
            [HP.class_ ("cred" <> if isJust (tvRevokedAt token) then " is-revoked" else "")]
            [ H.div_
                [HP.class_ "cred-main"]
                [ H.div_
                    [HP.class_ "cred-title"]
                    [ text (ms (tvName token))
                    , H.span_ [HP.class_ "token-prefix mono"] [text (ms (tvPrefix token))]
                    ]
                , H.div_
                    [HP.class_ "cred-meta"]
                    [ text (ms ("Created " <> (fromMisoString (formatStamp (tvCreatedAt token)) :: String)))
                    , text (ms (maybe "" (\used -> " · last used " <> (fromMisoString (formatStamp used) :: String)) (tvLastUsedAt token)))
                    , if isJust (tvRevokedAt token) then text " · revoked" else text ""
                    ]
                , H.div_
                    [HP.class_ "row-wrap"]
                    [ H.span_ [HP.class_ "tag-chip"] [text (ms scope)]
                    | scope <- tvScopes token
                    ]
                ]
            , if isJust (tvRevokedAt token)
                then pill "warn" "revoked"
                else iconBtnDanger iTrash "Revoke token" (TokenRevoke (tvId token))
            ]

-- | Provider / configured banner for the AI-tags page.
aiStatusBanner :: Model -> View () () Model Action
aiStatusBanner m = case mAiStatus m of
    Nothing -> H.span_ [] []
    Just status ->
        H.div_
            [ HP.class_
                ("banner " <> if asConfigured status then "info" else "")
            , HP.role_ "status"
            ]
            [ H.span_
                []
                [ text
                    ( ms
                        ( "AI provider: "
                            <> asProvider status
                            <> (if T.null (asModel status) then "" else " · " <> asModel status)
                            <> if asConfigured status then " · configured" else " · not configured (set ANTHROPIC_API_KEY/OPENAI_API_KEY or EZA_AI_PROVIDER=ollama)"
                        )
                    )
                ]
            ]

-- | Account-level list of public share links (scope, target, expiry, revoke).
sharesPanel :: Model -> View () () Model Action
sharesPanel m =
    panelWithHead
        "Shares"
        [ H.span_ [HP.class_ "muted"] [text (ms (show (length activeShares) <> " active")) | not (null activeShares)]
        ]
        ( [ H.p_
                [HP.class_ "muted"]
                [text "Public share links render a read-only page (and an Atom feed for saved searches). Revoking a link stops it immediately."]
          , if mSharesLoading m && null (mShares m)
                then spinnerRow "Loading share links…"
                else
                    H.div_
                        [HP.class_ "stack"]
                        ( [shareAccountRow share | share <- mShares m]
                            ++ [ H.p_ [HP.class_ "muted"] [text "No share links yet. Create one from a bookmark's Share dialog."]
                               | null (mShares m)
                               ]
                        )
          ]
        )
  where
    activeShares = [share | share <- mShares m, isJust (svRevokedAt share) == False]
    shareAccountRow share =
        H.div_
            [HP.class_ ("cred" <> if isJust (svRevokedAt share) then " is-revoked" else "")]
            [ H.div_
                [HP.class_ "cred-main"]
                [ H.div_
                    [HP.class_ "cred-title"]
                    [ text (ms (shareTargetLabel share))
                    , H.span_ [HP.class_ "token-prefix mono"] [text (ms (svPrefix share))]
                    ]
                , H.div_
                    [HP.class_ "cred-meta"]
                    [ text (ms ("Created " <> (fromMisoString (formatStamp (svCreatedAt share)) :: String)))
                    , text (ms (" · expires " <> (fromMisoString (formatStamp (svExpiresAt share)) :: String)))
                    , text (ms (if svIncludeNote share then " · includes note" else "" :: String))
                    , text (ms (maybe "" (\accessed -> " · last opened " <> (fromMisoString (formatStamp accessed) :: String)) (svLastAccessedAt share)))
                    , text (ms (if isJust (svRevokedAt share) then " · revoked" else "" :: String))
                    ]
                ]
            , if isJust (svRevokedAt share)
                then pill "warn" "revoked"
                else btnSm "Revoke" (ShareRevoke (svId share))
            ]
    shareTargetLabel share =
        case svScope share of
            "bookmark" -> "Bookmark #" <> T.pack (show (svTargetId share))
            "saved_search" -> "Saved search #" <> T.pack (show (svTargetId share))
            other -> other

{- | Deterministic save rules: list + enable/disable + delete + create form
with a dry run against the existing library.
-}
rulesPanel :: Model -> View () () Model Action
rulesPanel m =
    panelWithHead
        "Rules"
        [ H.span_
            [HP.class_ "muted"]
            [text (ms (show (length (mRules m)) <> " rule(s)")) | not (null (mRules m))]
        ]
        [ H.p_
            [HP.class_ "muted"]
            [text "Rules run when a new bookmark is saved: a case-insensitive substring match on the URL, domain, or title adds tags and can mark the bookmark read."]
        , H.div_
            [HP.class_ "rule-form"]
            [ H.input_
                [ HP.id_ "rule-name"
                , HP.class_ "input"
                , HP.placeholder_ "Rule name"
                , HP.value_ (mRuleName m)
                , HP.autocomplete_ "off"
                , HE.onInput RuleNameInput
                ]
            , H.select_
                [ HP.class_ "select"
                , HE.onChange (\raw -> RuleFieldSelected (fromMisoString raw))
                ]
                [ fieldOption "url" "URL"
                , fieldOption "domain" "Domain"
                , fieldOption "title" "Title"
                ]
            , H.input_
                [ HP.id_ "rule-pattern"
                , HP.class_ "input"
                , HP.placeholder_ "Pattern (case-insensitive substring)"
                , HP.value_ (mRulePattern m)
                , HP.autocomplete_ "off"
                , HE.onInput RulePatternInput
                ]
            , H.input_
                [ HP.id_ "rule-tags"
                , HP.class_ "input"
                , HP.placeholder_ "Tags, comma separated"
                , HP.value_ (mRuleTags m)
                , HP.autocomplete_ "off"
                , HE.onInput RuleTagsInput
                ]
            , H.label_
                [HP.class_ "share-option rule-read"]
                [ H.input_
                    [ HP.type_ "checkbox"
                    , HP.checked_ (mRuleMarkRead m)
                    , HE.onClick RuleMarkReadToggled
                    ]
                , text "Mark read"
                ]
            , H.div_
                [HP.class_ "row-wrap"]
                [ btn
                    "btn-primary"
                    ([HE.onClick RuleCreate] <> disabledAttr (mRuleBusy m))
                    [text (if mRuleBusy m then "Working…" else "Create rule")]
                , btn
                    "btn-sm"
                    ([HE.onClick RuleDryRun] <> disabledAttr (mRuleBusy m))
                    [text "Dry run"]
                ]
            , case mRuleDryRun m of
                Nothing -> H.span_ [] []
                Just (matches, ids) ->
                    H.span_
                        [HP.class_ "rule-result", HP.role_ "status"]
                        [ text
                            ( ms
                                ( "Dry run: "
                                    <> show matches
                                    <> " matching bookmark(s)"
                                    <> if null ids then "" else " — e.g. #" <> show (head ids)
                                )
                            )
                        ]
            ]
        , if mRulesLoading m && null (mRules m)
            then spinnerRow "Loading rules…"
            else
                if null (mRules m)
                    then H.p_ [HP.class_ "muted"] [text "No rules yet."]
                    else
                        H.table_
                            [HP.class_ "table rules-table"]
                            [ H.thead_
                                []
                                [ H.tr_
                                    []
                                    [ H.th_ [] [text "Name"]
                                    , H.th_ [] [text "Match"]
                                    , H.th_ [] [text "Tags"]
                                    , H.th_ [] [text "Read"]
                                    , H.th_ [] [text "State"]
                                    , H.th_ [] [text ""]
                                    ]
                                ]
                            , H.tbody_ [] (map ruleRow (mRules m))
                            ]
        ]
  where
    fieldOption value label =
        H.option_
            [HP.value_ (ms (value :: Text)), HP.selected_ (mRuleField m == value)]
            [text label]
    ruleRow rule =
        H.tr_
            [HP.class_ (if ruleEnabled rule then "" else "is-disabled")]
            [ H.td_ [] [H.span_ [HP.class_ "rule-name"] [text (ms (ruleName rule))]]
            , H.td_
                []
                [ H.span_ [HP.class_ "rule-field"] [text (ms (T.toUpper (ruleField rule)))]
                , H.code_ [HP.class_ "rule-pattern"] [text (ms (rulePattern rule))]
                ]
            , H.td_
                []
                ( if null (ruleAddTags rule)
                    then [H.span_ [HP.class_ "muted"] [text "—"]]
                    else [H.span_ [HP.class_ "tag-chip"] [text (ms tag)] | tag <- ruleAddTags rule]
                )
            , H.td_ [] [if ruleMarkRead rule then pill "ok" "read" else H.span_ [HP.class_ "muted"] [text "—"]]
            , H.td_
                []
                [ btnSm
                    (if ruleEnabled rule then "Disable" else "Enable")
                    (RuleToggleEnabled rule)
                ]
            , H.td_
                []
                [ iconBtnDanger iTrash "Delete rule" (RuleDelete (ruleId rule))
                ]
            ]

credentialRow :: Model -> Credential -> View () () Model Action
credentialRow m credential =
    H.div_
        [HP.class_ "cred"]
        ( case mCredEdit m of
            Just (editingId, draft)
                | editingId == crId credential ->
                    [ H.input_
                        [ HP.class_ "input"
                        , HP.value_ draft
                        , HP.placeholder_ "Passkey nickname"
                        , HE.onInput CredentialNameInput
                        , HE.onKeyDown (\code -> if keyCodeToInt code == 13 then CredentialEditSave else Noop)
                        ]
                    , iconBtn iCheck "Save nickname" CredentialEditSave
                    , btnSm "Cancel" CredentialEditCancel
                    ]
            _ ->
                [ H.div_
                    [HP.class_ "cred-main"]
                    [ H.div_ [HP.class_ "cred-title"] [text (ms (nicknameOf credential))]
                    , H.div_
                        [HP.class_ "cred-meta"]
                        [ text (ms ("Created " <> (fromMisoString (formatStamp (crCreatedAt credential)) :: String)))
                        , text (ms (maybe "" (\t -> " · Last used " <> (fromMisoString (formatStamp t) :: String)) (crLastUsedAt credential)))
                        , if crBackupEligible credential then text " · synced backup" else text ""
                        ]
                    ]
                , iconBtn iRefresh "Rename passkey" (CredentialEditStart (crId credential))
                , iconBtnDanger iTrash "Delete passkey" (CredentialDeleted (crId credential))
                ]
        )
  where
    nicknameOf c = if T.null (T.strip (crNickname c)) then "Passkey" else crNickname c

keyCodeToInt :: KeyCode -> Int
keyCodeToInt (KeyCode n) = n
