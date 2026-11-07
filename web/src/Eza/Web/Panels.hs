-- | Feature pages: graph, duplicates, tags, AI tags, maintenance, account.
module Eza.Web.Panels
  ( graphPage
  , dedupPage
  , tagsPage
  , aiTagsPage
  , maintenancePage
  , accountPage
  ) where

import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T

import Miso
import qualified Miso.Html as H
import qualified Miso.Html.Event as HE
import qualified Miso.Html.Property as HP
import qualified Miso.Svg as Svg
import qualified Miso.Svg.Property as SP

import Eza.Types
  ( BookmarkSummary (..)
  , GraphData (..)
  , GraphEdge (..)
  , GraphNode (..)
  , TagStat (..)
  )
import Eza.Web.Model
import Eza.Web.Types (AccountInfo (..), ConsolGroup (..), Credential (..), DedupGroup (..), TagSuggestion (..))
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
    , H.p_ [HP.class_ "muted"]
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
    , H.p_ [HP.class_ "muted"]
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
        , H.h3_ [HP.class_ "group-title"]
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
              btn "btn-primary btn-sm"
                [HE.onClick (TagMerge (map tsName (cgTags group)) (cgSuggested group))]
                [text "Merge"]
        ]
    , H.div_
        [HP.class_ "row-wrap"]
        ( [ H.span_ []
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
    , H.p_ [HP.class_ "muted"]
        [text "Advisory suggestions only — nothing is written until you press Apply."]
    , panel "Pick a tag bucket" [H.div_ [HP.class_ "tag-cloud"] (map bucket (take 60 (mTags m)))]
    , case mAiTag m of
        Nothing ->
          emptyState
            "✨"
            "Choose a tag to see suggestions"
            [ H.p_ [] [text "Suggestions are grouped by tag bucket so you can review them in batches."]]
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
        ( [ btn "btn-primary btn-sm"
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
    , panel "Dead-link sweep"
        [ H.div_
            [HP.class_ "action-row"]
            [ H.div_
                [HP.class_ "action-text"]
                [ H.div_ [HP.class_ "action-title"] [text "Check links for dead pages"]
                , H.div_ [HP.class_ "action-desc"] [text "Runs a HEAD/GET check against saved URLs and flags failures."]
                ]
            , btn "btn-primary" (disabledAttr (mMaintBusy m) ++ [HE.onClick DeadCheckRun])
                [text (if mMaintBusy m then "Working…" else "Check dead links")]
            ]
        ]
    , panel "Prune candidates"
        [ H.div_
            [HP.class_ "row-wrap"]
            ( [ btnSm "Select all" PruneAll
              , H.span_ [HP.class_ "muted"] [text (ms (show (length (mPruneSel m)) <> " selected"))]
              , H.span_ [HP.class_ "spacer"] []
              , btn "btn-danger btn-sm"
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
    , panel "Undo"
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
                    ++ [ H.p_ [HP.class_ "muted"]
                           [text "Passkeys are registered through WebAuthn; use the server page to add one, then manage it here."]
                       | null (aiCredentials account)
                       ]
                )
            , panel "Recovery codes"
                ( [ H.p_ [HP.class_ "muted"]
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

credentialRow :: Model -> Credential -> View () () Model Action
credentialRow m credential =
  H.div_
    [HP.class_ "cred"]
    ( case mCredEdit m of
        Just (editingId, draft) | editingId == crId credential ->
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


