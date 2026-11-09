{- | The application shell and the ledger family, ported to Direction B.

The shell (masthead, query line, running head, offline banner, command
palette, dialogs, toasts, mobile tab bar) is rendered for every route;
'routeBody' picks the ledger, the inbox, the quick-save page, or one of the
group pages.

Every number and date in the page comes from 'formatCount', 'formatFiled'
and 'formatProseDate'; the rows and counts come from 'Eza.Web.Model'.
-}
module Eza.Web.View (viewModel) where

import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Eza.View (ViewKind (..))
import Miso
import qualified Miso.CSS as C
import qualified Miso.Html as H
import qualified Miso.Html.Event as HE
import qualified Miso.Html.Property as HP
import qualified Miso.JSON as MJ
import Text.Read (readMaybe)

import Eza.SearchQuery (SearchQuery (..), parseSearchQuery)
import Eza.Types (BookmarkSummary (..), LibraryStats (..), SavedSearch (..), TagStat (..))
import Eza.Web.Accessions (accessionsPage)
import Eza.Web.Detail (detailPage)
import Eza.Web.Model
import Eza.Web.Panels (accountPage, aiTagsPage, dedupPage, graphPage, maintenancePage, tagsPage, viewDialogs, viewsPage)
import Eza.Web.Types (ShareView (..))
import Eza.Web.Widgets (disabledAttr, formatCount)

-- ------------------------------------------------------------------ shell --

viewModel :: Model -> View () () Model Action
viewModel m =
    H.div_
        [ HP.class_ "app ledg-app app-frame"
        , HP.data_ "testid" "app-shell"
        ]
        ( [ H.a_ [HP.class_ "skip-link", HP.href_ "#main"] [text "Skip to content"]
          , mast m
          , sectionsNav m
          ]
            ++ statusBanners m
            ++ [routeBody m]
            ++ [mobileNav m, toastsView m, importInput]
            ++ savedSearchShareDialog m
            ++ [addDialog m | mAddOpen m]
            ++ [paletteView m | mPaletteOpen m]
            ++ [guardDialog m | mGuardOpen m]
            ++ [logoutDialog | mConfirmLogout m]
            ++ [tagPromptDialog m | isJust (mTagPrompt m)]
            ++ [bulkDeleteDialog m | mConfirmBulkDelete m]
            ++ viewDialogs m
        )

{- | Non-list pages: one main element holding the group page, which brings its
own page scroll container.
-}
fullPage :: View () () Model Action -> View () () Model Action
fullPage view_ =
    H.main_
        [HP.id_ "main", HP.class_ "screen"]
        [view_]

{- | One main element per list route: facet strip, grid frame, field drawer.
  The ledger itself is a plain container inside that landmark.
-}
listScreen :: [View () () Model Action] -> View () () Model Action
listScreen =
    H.main_
        [HP.id_ "main", HP.class_ "screen"]

-- --------------------------------------------------------------- masthead --

mast :: Model -> View () () Model Action
mast m =
    H.header_
        [HP.class_ "mast", HP.data_ "testid" "mast"]
        [ H.div_
            [HP.class_ "mast-line"]
            [ H.a_
                [ HP.class_ "wordmark"
                , HP.href_ "/"
                , HE.onClickPrevent (Navigate Index)
                ]
                [text "eza"]
            , provenance m
            ]
        , queryLine m
        , metaLine m
        ]

provenance :: Model -> View () () Model Action
provenance m = H.p_ [HP.class_ "prov meta"] $ case mStats m of
    Nothing -> [H.span_ [HP.class_ "prov-item"] [text "the catalogue is opening"]]
    Just s ->
        [ provItem (formatCount (lsTotal s)) " entries"
        , provRule
        , provItem (formatCount (lsSources s)) " sources"
        , provRule
        , H.span_
            [HP.class_ "prov-item"]
            [text "filed since ", H.span_ [HP.class_ "n"] [text (yearOfDay (lsFirstDay s))]]
        ]
  where
    provItem n suffix =
        H.span_ [HP.class_ "prov-item"] [H.span_ [HP.class_ "n"] [text n], text suffix]
    provRule = H.span_ [HP.class_ "prov-rule", HP.aria_ "hidden" "true"] []

yearOfDay :: Text -> MisoString
yearOfDay day = ms (T.unpack (T.take 4 day))

queryLine :: Model -> View () () Model Action
queryLine m =
    H.div_
        [HP.class_ "query"]
        ( [ H.span_ [HP.class_ "query-mark", HP.aria_ "hidden" "true"] [text "/"]
          , H.input_
                [ HP.id_ "search-input"
                , HP.class_ "query-input"
                , HP.type_ "search"
                , HP.placeholder_ "search the catalogue"
                , HP.value_ (mQ m)
                , HP.autocomplete_ "off"
                , HP.spellcheck_ False
                , HP.aria_ "label" "Search the catalogue"
                , HE.onInput SearchInput
                , HE.onKeyDown commitOnEnter
                ]
          ]
            ++ [ H.button_
                    [ HP.class_ "query-clear"
                    , HP.type_ "button"
                    , HP.aria_ "label" "Clear the query"
                    , HP.title_ "Clear the query"
                    , HE.onClick (SearchInput "")
                    ]
                    [text "×"]
               | not (T.null (T.strip (qText m)))
               ]
            ++ [ H.button_
                    [ HP.class_ "query-hint query-hint--act"
                    , HP.type_ "button"
                    , HP.data_ "testid" "palette-open"
                    , HP.aria_ "label" "Open the command palette"
                    , HP.title_ "Command palette: Shift+K, Cmd+K or Ctrl+K"
                    , HE.onClick PaletteOpen
                    ]
                    [H.kbd_ [] [text "⇧K"], H.span_ [HP.class_ "meta"] [text "commands"]]
               ]
        )
  where
    commitOnEnter (KeyCode 13) = SearchCommit
    commitOnEnter _ = Noop

{- | Left: the parsed tokens, or the sample queries when idle. Right: counts,
the sort control and the paper/night toggle.
-}
metaLine :: Model -> View () () Model Action
metaLine m =
    H.div_
        [HP.class_ "meta-line"]
        [ H.div_ [HP.class_ "meta-left"] (metaLeft m)
        , H.div_
            ( HP.class_ "meta-right"
                : [C.styleInline_ "flex-wrap:nowrap;align-items:center;gap:10px" | mWidth m < 768]
            )
            (metaRight m)
        ]

metaLeft :: Model -> [View () () Model Action]
metaLeft m
    | not (isListRoute m) = []
    | hasActiveFilters m = [H.div_ [HP.class_ "chips"] (queryChips m)]
    | mRoute m == Inbox =
        [ H.span_
            [HP.class_ "chips"]
            [H.span_ [HP.class_ "chip"] [H.span_ [HP.class_ "op"] [text "is:"], text "unread"]]
        ]
    | otherwise = []

metaRight :: Model -> [View () () Model Action]
metaRight m
    | isListRoute m =
        countGroup m
            ++ [ H.div_
                    ( HP.class_ "ledg-controls"
                        : [C.styleInline_ "flex-basis:auto;flex-wrap:nowrap;gap:10px" | mobile]
                    )
                    (sortControl m ++ [themeToggle m])
               ]
    | otherwise = [H.div_ [HP.class_ "ledg-controls"] [themeToggle m]]
  where
    mobile = mWidth m < 768

countGroup :: Model -> [View () () Model Action]
countGroup m =
    [ H.span_
        [ HP.class_ "ledg-countgroup"
        , HP.role_ "status"
        , HP.aria_ "live" "polite"
        , HP.data_ "testid" "result-count-live"
        ]
        ( if hasActiveFilters m
            then
                [ H.span_ [HP.class_ "result-count"] [text (formatCount (mTotal m))]
                , H.span_
                    [HP.class_ "result-unit meta"]
                    [text (if mTotal m == 1 then "entry" else "entries")]
                , H.span_ [HP.class_ "meta"] [text ("of " <> formatCount libraryTotal <> " in all")]
                ]
            else
                [ H.span_
                    [HP.class_ "meta"]
                    [text (formatCount (length (mItems m)) <> " / " <> formatCount libraryTotal)]
                ]
        )
    ]
  where
    libraryTotal = maybe (mTotal m) lsTotal (mStats m)

sortControl :: Model -> [View () () Model Action]
sortControl m =
    [ H.button_
        ( [ HP.class_ "ledg-sort"
          , HP.type_ "button"
          , HP.aria_ "label" "Change the sort order (newest first)"
          , HP.title_ "Sort: filed, newest first"
          , HE.onClick (SortSelected (nextSort (mSort m)))
          ]
            ++ [C.styleInline_ compactControl | mobile]
        )
        [H.span_ [HP.class_ "meta"] [text (if mobile then shortSort (mSort m) else sortText (mSort m))]]
    ]
  where
    mobile = mWidth m < 768

nextSort :: Text -> Text
nextSort "created" = "added"
nextSort "added" = "opened"
nextSort _ = "created"

compactControl :: MisoString
compactControl =
    "min-height:44px;display:inline-flex;align-items:center;border:0;"
        <> "padding:0 2px;white-space:nowrap"

shortSort :: Text -> MisoString
shortSort "added" = "added"
shortSort "opened" = "opened"
shortSort _ = "filed"

sortText :: Text -> MisoString
sortText "added" = "added"
sortText "opened" = "opened"
sortText _ = "filed"

themeToggle :: Model -> View () () Model Action
themeToggle m =
    H.button_
        ( [ HP.class_ "ledg-sort"
          , HP.type_ "button"
          , HP.data_ "testid" "theme-toggle"
          , HP.aria_ "label" "Toggle theme"
          , HP.title_ "Toggle theme"
          , HE.onClick ThemeToggled
          ]
            ++ [C.styleInline_ compactControl | mWidth m < 768]
        )
        [H.span_ [HP.class_ "meta"] [text (if mTheme m == ThemeDark then "paper" else "night")]]

-- ----------------------------------------------------------- running head --

sectionsNav :: Model -> View () () Model Action
sectionsNav m =
    H.nav_
        [ HP.class_ "sections strip-fade"
        , HP.aria_ "label" "Sections"
        , HP.data_ "testid" "sections"
        ]
        (map sectionLink sections ++ [signOutLink])
  where
    signOutLink =
        H.button_
            [ HP.class_ "sections-signout"
            , HP.type_ "button"
            , HP.data_ "testid" "section-sign-out"
            , HP.title_ "Sign out of this browser"
            , HE.onClick LogoutRequest
            ]
            [text "sign out"]
    sections =
        [ ("ledger", "section-ledger", Index)
        , ("inbox", "section-inbox", Inbox)
        , ("graph", "section-graph", Graph)
        , ("views", "section-views", Views)
        , ("duplicates", "section-dedup", Dedup)
        , ("tags", "section-tags", Tags)
        , ("ai tags", "section-ai-tags", AiTags)
        , ("maintenance", "section-maintenance", Maintenance)
        , ("accessions", "section-accessions", Accessions)
        , ("account", "section-account", Account)
        ]
    sectionLink (label, hook, route) =
        H.a_
            ( [ HP.href_ (routePath route)
              , HP.data_ "testid" hook
              , HE.onClickPrevent (Navigate route)
              ]
                ++ [HP.aria_ "current" "page" | routeActive route]
            )
            [text label]
    routeActive route
        | route == Index = case mRoute m of
            Index -> True
            Bookmark _ -> True
            Save{} -> True
            _ -> False
        | route == Graph = isGraphRoute (mRoute m)
        | otherwise = route == mRoute m

routePath :: Route -> MisoString
routePath = \case
    Index -> "/"
    Bookmark bid -> "/bookmark/" <> ms (show bid)
    Inbox -> "/inbox"
    Graph -> "/graph"
    GraphLocal rootKey depth ->
        "/graph?focus="
            <> ms (show rootKey)
            <> "&depth="
            <> ms (show depth)
            <> "&local=1"
    Views -> "/views"
    ViewOpen slug -> "/views/" <> ms (T.unpack slug)
    Dedup -> "/dedup"
    Tags -> "/tags"
    AiTags -> "/tags/ai"
    Maintenance -> "/maintenance"
    Account -> "/account"
    Accessions -> "/accessions"
    Save{} -> "/save"
    NotFound -> "/not-found"

-- --------------------------------------------------------------- banners ---

statusBanners :: Model -> [View () () Model Action]
statusBanners m =
    [ banner
        "Live updates are paused"
        "The server is unreachable. The catalogue you see was read earlier; nothing you change is saved until the connection returns."
        [H.a_ [HP.class_ "offline-banner-action", HP.href_ "/"] [text "reload"]]
    | not (mOnline m)
    ]
        ++ [ banner
                "Signed out"
                "Your session expired. Sign in again to keep editing the catalogue."
                [H.a_ [HP.class_ "offline-banner-action", HP.href_ "/login"] [text "sign in"]]
           | mSignedOut m
           ]

banner :: MisoString -> MisoString -> [View () () Model Action] -> View () () Model Action
banner title body actions =
    H.div_
        [HP.class_ "offline-banner", HP.role_ "status", HP.aria_ "live" "polite"]
        [ H.span_ [HP.class_ "offline-banner-mark", HP.aria_ "hidden" "true"] []
        , H.span_ [HP.class_ "offline-banner-text"] [text (title <> ". "), text body]
        , H.span_ [HP.class_ "offline-banner-actions"] actions
        ]

-- ---------------------------------------------------------------- routes ---

routeBody :: Model -> View () () Model Action
routeBody m = case mRoute m of
    Index -> listScreen [facetStrip m, ledgerMain m]
    Inbox -> listScreen [facetStrip m, ledgerMain m]
    Save{} -> fullPage (savePage m)
    Bookmark _ -> fullPage (detailPage m)
    Graph -> fullPage (graphPage m)
    GraphLocal _ _ -> fullPage (graphPage m)
    Views -> fullPage (viewsPage m)
    ViewOpen _ -> fullPage (viewsPage m)
    Dedup -> fullPage (dedupPage m)
    Tags -> fullPage (tagsPage m)
    AiTags -> fullPage (aiTagsPage m)
    Maintenance -> fullPage (maintenancePage m)
    Account -> fullPage (accountPage m)
    Accessions -> fullPage (accessionsPage m)
    NotFound -> fullPage notFoundPage

isListRoute :: Model -> Bool
isListRoute m = case mRoute m of
    Index -> True
    Inbox -> True
    _ -> False

isInbox :: Model -> Bool
isInbox m = mRoute m == Inbox

notFoundPage :: View () () Model Action
notFoundPage =
    H.div_
        [HP.class_ "detail-scroll"]
        [ H.div_
            [HP.class_ "detail"]
            [ H.div_
                [HP.class_ "empty"]
                [ H.div_
                    [HP.class_ "empty-note"]
                    [ H.span_ [HP.class_ "empty-kicker sc"] [text "404"]
                    , H.h2_ [HP.class_ "empty-title"] [text "That page is not in the catalogue."]
                    , H.p_
                        [HP.class_ "empty-body"]
                        [text "The address does not match a record, a year or a section. The ledger is still here, and the catalogue behind it is unchanged."]
                    , H.p_
                        [HP.class_ "empty-try"]
                        [ H.a_
                            [HP.class_ "try-link", HP.href_ "/", HE.onClickPrevent (Navigate Index)]
                            [text "back to the ledger"]
                        ]
                    ]
                , H.div_ [HP.class_ "empty-lines", HP.aria_ "hidden" "true"] (replicate 4 (H.i_ [] []))
                , H.div_
                    [HP.class_ "empty-end meta"]
                    [H.span_ [] [text "no such route"], H.span_ [] [text "eza"]]
                ]
            ]
        ]

-- ---------------------------------------------------------------- ledger ---

ledgerMain :: Model -> View () () Model Action
ledgerMain m =
    H.div_
        [ HP.class_ (if isInbox m then "main ledg-main--wide" else "main")
        , C.styleInline_ "min-height:0"
        ]
        ( [H.aside_ [HP.class_ "rail", HP.aria_ "label" "Filters"] (railView m) | not (isInbox m)]
            ++ [ H.div_
                    [HP.class_ "ledger-wrap"]
                    [ H.div_
                        [ HP.class_ "ledger"
                        , HP.data_ "bulk" (if selectedCount m > 0 then "true" else "false")
                        ]
                        (ledgerBody m)
                    , drawerView m
                    ]
               ]
        )

-- ---------------------------------------------------------- facet strip ---

{- | The rail, folded flat for tablet and phone. Sources are plain terms (the
FTS matches the domain inside the URL), tags toggle the tag filter, status
links go to the inbox or to an is:dead query.
-}
facetStrip :: Model -> View () () Model Action
facetStrip m =
    H.div_
        [HP.class_ "facet-strip strip-fade", HP.aria_ "label" "Filters"]
        [ fgroup "sources" (map stripSource (take 3 sources))
        , fgroup "tags" (map stripTag (take 4 (mTags m)))
        , fgroup
            "status"
            [ stripLink "unread" (maybe "–" (formatCount . lsUnread) (mStats m)) (Navigate Inbox)
            , stripLink
                "dead links"
                (maybe "–" (formatCount . lsDead) (mStats m))
                (SearchInput (toggleTerm m "is:dead"))
            ]
        ]
  where
    sources = maybe [] lsTopSources (mStats m)
    fgroup label items =
        H.div_
            [HP.class_ "fstrip-group"]
            (H.span_ [HP.class_ "fstrip-key sc"] [text label] : items)
    stripSource (domain, count) =
        H.a_
            ( [ HP.class_ "fstrip-item"
              , HP.href_ "/"
              , HE.onClickPrevent (SearchInput (toggleTerm m domain))
              ]
                ++ [HP.data_ "active" "true" | hasTerm m domain]
            )
            [text (msText domain), H.span_ [HP.class_ "n"] [text (formatCount count)]]
    stripTag tag =
        H.a_
            ( [ HP.class_ "fstrip-item"
              , HP.href_ "/"
              , HE.onClickPrevent (TagToggled (tsName tag))
              ]
                ++ [HP.data_ "active" "true" | tsName tag `elem` mTagsFilter m]
            )
            [text (msText (tsName tag)), H.span_ [HP.class_ "n"] [text (formatCount (tsCount tag))]]
    stripLink label value action =
        H.a_
            [ HP.class_ "fstrip-item"
            , HP.href_ "/"
            , HE.onClickPrevent action
            ]
            [text label, H.span_ [HP.class_ "n"] [text value]]

-- ------------------------------------------------------------- facet rail ---

railView :: Model -> [View () () Model Action]
railView m =
    [ railBlock
        "Sources"
        sourceCount
        ( H.ul_ [HP.class_ "facets"] (map (sourceRow m) (take 7 sources))
            : [ H.a_
                    [ HP.class_ "facet-all"
                    , HP.href_ "/accessions"
                    , HE.onClickPrevent (Navigate Accessions)
                    ]
                    [text "all sources"]
              ]
        )
    , railBlock
        "Tags"
        tagCount
        ( H.ul_ [HP.class_ "tag-grid"] (map (tagFacet m) (take 8 (mTags m)))
            : [ H.a_
                    [ HP.class_ "facet-all"
                    , HP.href_ "/tags"
                    , HE.onClickPrevent (Navigate Tags)
                    ]
                    [text ("all " <> tagCount <> " tags")]
              ]
        )
    ]
        ++ [savedSearchesBlock m | not (null (mSaved m)) || hasActiveFilters m]
        ++ [ H.div_
                [HP.class_ "rail-block"]
                [ railHead "Status" ""
                , H.ul_ [HP.class_ "status-list"] (statusRows m)
                ]
           , H.div_
                [HP.class_ "rail-block"]
                [ railHead "Filing days" ""
                , sparkline m
                , H.p_
                    [HP.class_ "spark-cap"]
                    [H.span_ [] [text (filingTotals m)]]
                ]
           ]
  where
    sources = maybe [] lsTopSources (mStats m)
    sourceCount = maybe "–" (formatCount . lsSources) (mStats m)
    tagCount = maybe "–" (formatCount . lsTags) (mStats m)
    railBlock title right body =
        H.div_
            [HP.class_ "rail-block"]
            (railHead title right : body)
    railHead title right =
        H.div_
            [HP.class_ "rail-head"]
            [H.h2_ [HP.class_ "rail-title"] [text title], H.span_ [HP.class_ "rail-n"] [text right]]

savedSearchesBlock :: Model -> View () () Model Action
savedSearchesBlock m =
    H.div_
        [HP.class_ "rail-block"]
        [ railHead "Saved searches" (formatCount (length (mSaved m)))
        , H.ul_ [HP.class_ "facet-list"] (map savedRow (mSaved m))
        , H.button_
            [ HP.class_ "facet-all"
            , HP.type_ "button"
            , HE.onClick SavedSearchSave
            ]
            [text "save this search"]
        , H.button_
            [ HP.class_ "facet-all"
            , HP.type_ "button"
            , HP.data_ "testid" "view-save-current"
            , HE.onClick (ViewSaveOpen LedgerKind)
            ]
            [text "save as view"]
        ]
  where
    railHead title right =
        H.div_
            [HP.class_ "rail-head"]
            [H.h2_ [HP.class_ "rail-title"] [text title], H.span_ [HP.class_ "rail-n"] [text right]]
    savedRow saved =
        H.li_
            [HP.class_ "facet"]
            [ H.button_
                [ HP.class_ "facet-name"
                , HP.type_ "button"
                , HP.title_ "Apply this saved search"
                , HE.onClick (SavedSearchApply saved)
                ]
                [text (ms (ssName saved))]
            , H.button_
                [ HP.class_ "facet-share"
                , HP.type_ "button"
                , HP.data_ "testid" "saved-search-share"
                , HP.title_ "Share this saved search"
                , HP.aria_ "label" ("Share saved search " <> ms (ssName saved))
                , HE.onClick (SavedSearchShareOpen saved)
                ]
                [text "↗"]
            , H.button_
                [ HP.class_ "tagpill-remove"
                , HP.type_ "button"
                , HP.data_ "testid" "saved-search-delete"
                , HP.title_ "Delete this saved search"
                , HP.aria_ "label" ("Delete saved search " <> ms (ssName saved))
                , HE.onClick (SavedSearchDelete (ssId saved))
                ]
                [text "×"]
            ]

sourceRow :: Model -> (Text, Int) -> View () () Model Action
sourceRow m (domain, count) =
    H.li_
        [HP.class_ "facet"]
        [ H.a_
            ( [ HP.class_ ""
              , HP.href_ "/"
              , HE.onClickPrevent (SearchInput (toggleTerm m domain))
              ]
                ++ [HP.data_ "active" "true" | hasTerm m domain]
            )
            [ H.span_ [HP.class_ "name"] [text (msText domain)]
            , H.span_ [HP.class_ "lead", HP.aria_ "hidden" "true"] []
            , H.span_ [HP.class_ "n"] [text (formatCount count)]
            ]
        ]

tagFacet :: Model -> TagStat -> View () () Model Action
tagFacet m tag =
    H.li_
        []
        [ H.a_
            ( [ HP.href_ "/"
              , HE.onClickPrevent (TagToggled (tsName tag))
              ]
                ++ [HP.data_ "active" "true" | tsName tag `elem` mTagsFilter m]
            )
            [ H.span_ [HP.class_ "tn"] [text (msText (tsName tag))]
            , H.span_ [HP.class_ "n"] [text (formatCount (tsCount tag))]
            ]
        ]

statusRows :: Model -> [View () () Model Action]
statusRows m =
    [ statusRow
        "unread"
        (maybe "–" (formatCount . lsUnread) (mStats m))
        (mRoute m == Inbox)
        (Navigate Inbox)
    , statusRow
        "dead links"
        (maybe "–" (formatCount . lsDead) (mStats m))
        (hasTerm m "is:dead")
        (SearchInput (toggleTerm m "is:dead"))
    , statusRow
        "queued"
        (maybe "–" (formatCount . lsQueued) (mStats m))
        False
        (Navigate Maintenance)
    ]

statusRow :: MisoString -> MisoString -> Bool -> Action -> View () () Model Action
statusRow label value active action =
    H.li_
        []
        [ H.a_
            ( [HP.href_ "/", HE.onClickPrevent action]
                ++ [HP.data_ "active" "true" | active]
            )
            [H.span_ [] [text label], H.span_ [HP.class_ "n"] [text value]]
        ]

sparkline :: Model -> View () () Model Action
sparkline m =
    H.div_
        [HP.class_ "spark", HP.aria_ "hidden" "true"]
        (map bar (weeklyFiling m))
  where
    bar value =
        H.i_
            [ C.styleInline_
                ( "height:"
                    <> C.px (2 + round (fromIntegral value / 7 * 22 :: Double))
                    <> ";opacity:"
                    <> (if value == 0 then "0.18" else "0.82")
                )
            ]
            []

-- | The archive totals behind the window: filing days since the first save.
filingTotals :: Model -> MisoString
filingTotals m = case mStats m of
    Nothing -> ""
    Just s ->
        formatCount (lsDays s)
            <> " filing days since "
            <> formatFiled (fromMaybe 0 (dayNumber (lsFirstDay s)) * 86400)

{- | Count filing days in each of the last 52 weeks, ending on the last filing
day in the library.
-}
weeklyFiling :: Model -> [Int]
weeklyFiling m = case mStats m of
    Nothing -> replicate 52 0
    Just s ->
        let end = fromMaybe 0 (dayNumber (lsLastDay s))
            start = end - 363
            days =
                [ d
                | (day, _count) <- lsFilingDays s
                , Just d <- [dayNumber day]
                , d >= start
                , d <= end
                ]
            bucket d = (d - start) `div` 7
         in [length [() | d <- days, bucket d == week] | week <- [0 .. 51]]

-- ---------------------------------------------------------------- ledger ---

ledgerBody :: Model -> [View () () Model Action]
ledgerBody m
    | mLoading m && null (mItems m) = skeletonRows
    | isJust (mError m) && null (mItems m) = [errorState m]
    | null (mItems m) && hasActiveFilters m = [columnHead m, filteredEmpty m]
    | null (mItems m) && isInbox m = [inboxEmpty m]
    | null (mItems m) = [freshEmpty]
    | otherwise =
        invalidHint m
            ++ staleError m
            ++ [selectionBar m | selectedCount m > 0]
            ++ (columnHead m : entriesView m)
            ++ [ledgerFoot m]

{- | Rows on screen but the refresh failed: keep the ledger and say the page
is stale, rather than printing the previous list as if it were current.
-}
staleError :: Model -> [View () () Model Action]
staleError m = case mError m of
    Nothing -> []
    Just message ->
        [ H.div_
            [HP.class_ "offline-banner", HP.role_ "alert"]
            [ H.span_ [HP.class_ "offline-banner-mark", HP.aria_ "hidden" "true"] []
            , H.span_
                [HP.class_ "offline-banner-text"]
                [ text "The list could not be refreshed. "
                , text message
                ]
            , H.span_
                [HP.class_ "offline-banner-actions"]
                [ H.button_
                    [HP.class_ "ledg-foot-act", HP.type_ "button", HE.onClick SearchCommit]
                    [text "retry"]
                ]
            ]
        ]

{- | Render only the rows around the visible window. The ledger can hold
thousands of rows; the DOM keeps the visible entries plus a screen of overscan,
and the two spacers preserve the scroll height, so the scrollbar and the cursor
jumps keep meaning the same thing.

Rows and year dividers are given exact heights by eza.css and 'entryHeight', so
the arithmetic below is the same measure the browser lays out. Narrow screens
keep the full sheet: the phone row is a four-line block whose height depends on
the title, and sixty rows are cheap to keep in the DOM.
-}
entriesView :: Model -> [View () () Model Action]
entriesView m
    | null picked = map entryView entries
    | otherwise = topSpacer : map pickedEntryView picked ++ [bottomSpacer]
  where
    entries = ledgerEntries m
    heights = map (entryHeight (mWidth m)) entries
    offsets = scanl (+) 0 heights
    totalHeight = last (0 : offsets)
    virtualized = mWidth m >= 768
    overscan = if virtualized then 480 else totalHeight + 5000
    viewTop = max 0 (mScrollY m - overscan)
    viewBottom = mScrollY m + max 1 (mHeight m) + overscan
    -- Filter, not takeWhile: at a deep scroll position the entries above the
    -- window come first, and takeWhile would stop immediately and fall back to
    -- rendering the whole loaded list.
    picked = filter withinWindow (zip3 entries offsets heights)
    withinWindow (_, top, height) = top < viewBottom && top + height > viewTop
    pickedEntryView (entry, _, _) = entryView entry
    entryView (LedgerYear year matched) = yearDivider m year matched
    entryView (LedgerRow _idx bookmark) = rowView m bookmark
    firstTop = case picked of
        ((_, top, _) : _) -> top
        [] -> 0
    lastEnd = case reverse picked of
        ((_, top, height) : _) -> top + height
        [] -> 0
    spacer height =
        H.div_
            [ HP.class_ "ledger-vspace"
            , HP.aria_ "hidden" "true"
            , C.styleInline_ ("height:" <> C.px height <> ";margin:0;padding:0;border:0")
            ]
            []
    topSpacer = spacer firstTop
    bottomSpacer = spacer (max 0 (totalHeight - lastEnd))

columnHead :: Model -> View () () Model Action
columnHead _ =
    H.div_
        [HP.class_ "lh meta"]
        [ H.span_ [] [text "no."]
        , H.span_ [] [text "title"]
        , H.span_ [] [text "source"]
        , H.span_ [HP.class_ "r"] [text "filed"]
        , H.span_ [] [text "tags"]
        ]

yearDivider :: Model -> Int -> Maybe Int -> View () () Model Action
yearDivider m year matched =
    H.div_
        [HP.class_ "year", HP.role_ "separator"]
        [ H.span_ [HP.class_ "year-n display"] [text (ms (show year))]
        , H.span_ [HP.class_ "year-rule", HP.aria_ "hidden" "true"] []
        , H.span_ [HP.class_ "year-meta meta"] meta
        ]
  where
    archive = mStats m >>= \s -> lookup year (lsYears s)
    meta = case archive of
        Just n -> [H.span_ [HP.class_ "n"] [text (formatCount n)], text " filed"] ++ matchedPart
        Nothing -> matchedPart
    matchedPart
        | hasActiveFilters m
        , Just here <- matched =
            [ H.span_ [HP.class_ "year-sep"] [text " / "]
            , H.span_ [HP.class_ "n"] [text (formatCount here)]
            , text " here"
            ]
        | otherwise = []

rowView :: Model -> BookmarkSummary -> View () () Model Action
rowView m bookmark =
    H.div_
        ( [ HP.class_ "ledg-rowline"
          , C.styleInline_ "position:relative;display:block"
          , HP.id_ (rowDomId (bsId bookmark))
          , HP.data_ "testid" "ledger-row"
          , HP.data_ "bookmark-id" (ms (show (bsId bookmark)))
          , HP.tabindex_ "0"
          , HP.role_ "link"
          , HP.aria_ "label" (rowLabel bookmark)
          ]
            ++ [HP.aria_ "current" "true" | mDrawer m == Just (bsId bookmark)]
        )
        [ H.div_
            ( [ HP.class_ (rowClass m bookmark)
              , HE.onClick (DrawerOpen (bsId bookmark))
              ]
                ++ [HP.aria_ "selected" "true" | isSelected m (bsId bookmark)]
            )
            [ H.span_
                cNoAttrs
                ( selectionTick m bookmark
                    ++ [ H.span_
                            ( HP.class_ "ledg-acc"
                                : [HE.onClickWithOptions stopPropagation (Navigate (Bookmark (bsId bookmark)))]
                            )
                            [text (accessionNo (bsId bookmark))]
                       ]
                )
            , H.span_
                [ HP.class_ "c-title"
                , HP.data_ "testid" "ledger-row-title"
                , HE.onClickWithOptions stopPropagation (Navigate (Bookmark (bsId bookmark)))
                ]
                [text (msText (bsTitle bookmark)), H.span_ [HP.class_ "sr-only"] [text readWord]]
            , H.span_
                [HP.class_ "c-src meta"]
                ( faviconView bookmark
                    ++ [H.span_ [HP.class_ "dom"] [text (msText (bsDomain bookmark))]]
                )
            , H.span_ [HP.class_ "c-filed meta"] [text (formatFiled (bsCreatedAt bookmark))]
            , H.span_ [HP.class_ "c-tags meta"] (tagsCell m (bsTags bookmark))
            ]
        ]
  where
    cNoAttrs =
        [ HP.class_ "c-no mono"
        , C.styleInline_ (if mWidth m < 768 then "padding-left:18px" else "")
        ]
    readWord
        | bsIsDead bookmark = "dead link"
        | bsIsRead bookmark = "read"
        | otherwise = "unread"

rowClass :: Model -> BookmarkSummary -> MisoString
rowClass _ bookmark =
    "row"
        <> (if bsIsRead bookmark then " is-read" else "")
        <> (if bsIsDead bookmark then " is-dead" else "")

rowLabel :: BookmarkSummary -> MisoString
rowLabel bookmark = accessionNo (bsId bookmark) <> ", " <> msText (bsTitle bookmark)

rowDomId :: Int -> MisoString
rowDomId bid = "ledger-row-" <> ms (show bid)

{- | The row's selection control: a real checkbox inside the accession cell,
with a 44px tap target. The CSS only shows it in bulk mode. Shift-click
extends the selection from the last anchor.
-}
selectionTick :: Model -> BookmarkSummary -> [View () () Model Action]
selectionTick m bookmark =
    [ H.label_
        [HP.class_ "ledg-tickbox"]
        [ H.input_
            [ HP.class_ "ledg-tick ledger-row-select"
            , HP.type_ "checkbox"
            , HP.data_ "testid" "ledger-row-select"
            , HP.aria_ "label" ("Select " <> msText (bsTitle bookmark))
            , HP.checked_ (isSelected m (bsId bookmark))
            , shiftSelect (bsId bookmark)
            ]
        ]
    ]

{- | A click handler that carries the shift modifier. @on@ with the shared
empty decoder would always send False, leaving range selection unreachable.
-}
shiftSelect :: Int -> Attribute Model Action
shiftSelect bookmarkId =
    onWithOptions
        BUBBLE
        stopPropagation
        "click"
        (at [] (MJ.withObject "click" (\mouseEvent -> mouseEvent MJ..: "shiftKey")))
        (\shift _ _ -> SelectToggled bookmarkId shift)

{- | Whole tags only: two on the wide sheet, three in the mobile block rows,
followed by a mono count of the rest. The budget leaves room for the +n.
-}
tagsCell :: Model -> [Text] -> [View () () Model Action]
tagsCell m tags =
    [ H.span_
        []
        ( [H.span_ [HP.class_ "sep"] [text ", "] | i > 0]
            ++ [H.span_ [HP.class_ "tag"] [text (msText tag)]]
        )
    | (i, tag) <- zip [0 :: Int ..] shown
    ]
        ++ [H.span_ [HP.class_ "more"] [text (" +" <> ms (show (length rest)))] | not (null rest)]
  where
    budget = if mWidth m < 768 then 40 else 17
    maxTags = if mWidth m < 768 then 3 else 2
    (shown, rest) = pickTags budget maxTags tags

pickTags :: Int -> Int -> [Text] -> ([Text], [Text])
pickTags budget maxTags = step 0 []
  where
    step _ acc [] = (reverse acc, [])
    step used acc allTags@(tag : moreTags)
        | length acc >= maxTags = (reverse acc, allTags)
        | fits = step (used + cost) (tag : acc) moreTags
        | otherwise = (reverse acc, allTags)
      where
        cost = T.length tag + (if null acc then 0 else 2)
        tailCost = if null moreTags then 0 else 3
        fits = used + cost + tailCost <= budget

-- ------------------------------------------------------------ selection ---

selectionBar :: Model -> View () () Model Action
selectionBar m =
    H.div_
        [ HP.class_ "ledg-selbar"
        , HP.role_ "toolbar"
        , HP.aria_ "label" "Bulk actions"
        , HP.data_ "testid" "selection-bar"
        ]
        [ H.span_
            [ HP.class_ "ledg-selcount mono"
            , HP.aria_ "live" "polite"
            , HP.data_ "testid" "selection-count"
            ]
            [text (formatCount (selectedCount m)), text " selected"]
        , H.span_ [HP.class_ "ledg-selspacer", HP.aria_ "hidden" "true"] []
        , selAct "add tag" (BulkTagPromptOpen True)
        , selAct "remove tag" (BulkTagPromptOpen False)
        , selAct "mark read" (BulkMark True)
        , selAct "mark unread" (BulkMark False)
        , selAct "delete" BulkDeleteRequest
        , H.button_
            [HP.class_ "ledg-act ledg-act--quiet", HP.type_ "button", HE.onClick SelectClear]
            [text "clear"]
        ]
  where
    selAct label action =
        H.button_ [HP.class_ "ledg-act", HP.type_ "button", HE.onClick action] [text label]

-- ---------------------------------------------------------------- drawer ---

drawerView :: Model -> View () () Model Action
drawerView m = case mDrawer m >>= findBookmark m of
    Nothing -> H.div_ [] []
    Just bookmark ->
        H.aside_
            [ HP.class_ "drawer"
            , HP.aria_ "label" "Field card"
            , HP.data_ "testid" "drawer"
            ]
            [ H.div_
                [HP.class_ "drawer-head"]
                [ H.span_ [HP.class_ "drawer-no"] [text (accessionNo (bsId bookmark))]
                , H.button_
                    [ HP.class_ "drawer-x"
                    , HP.type_ "button"
                    , HP.aria_ "label" "Close field card"
                    , HE.onClick DrawerClose
                    ]
                    [text "×"]
                ]
            , H.h2_ [HP.class_ "drawer-title"] [text (msText (bsTitle bookmark))]
            , H.p_
                [HP.class_ "drawer-url meta"]
                ( faviconView bookmark
                    ++ [ H.a_
                            [ HP.href_ (msText (bsUrl bookmark))
                            , HP.target_ "_blank"
                            , HP.rel_ "noopener noreferrer"
                            ]
                            [text (msText (breakableUrl (stripScheme (bsUrl bookmark))))]
                       ]
                )
            , H.dl_
                [HP.class_ "stamped"]
                ( [ stampedField "filed" (formatFiled (bsCreatedAt bookmark))
                  , stampedField "added" (formatFiled (bsAddedAt bookmark))
                  , stampedField "source" (msText (bsDomain bookmark))
                  , stampedField "read" (if bsIsRead bookmark then "read" else "unread")
                  ]
                    ++ [stampedField "link" "dead" | bsIsDead bookmark]
                )
            , H.div_
                [HP.class_ "drawer-tags"]
                [ H.button_
                    [ HP.class_ "tagpill"
                    , HP.type_ "button"
                    , HE.onClick (TagToggled tag)
                    ]
                    [text (msText tag)]
                | tag <- bsTags bookmark
                ]
            , H.div_
                [HP.class_ "drawer-actions"]
                [ H.a_
                    [ HP.class_ "action action--strong"
                    , HP.href_ (routePath (Bookmark (bsId bookmark)))
                    , HE.onClickPrevent (Navigate (Bookmark (bsId bookmark)))
                    ]
                    [text "open the record"]
                , H.a_
                    [ HP.class_ "action"
                    , HP.href_ (msText (bsUrl bookmark))
                    , HP.target_ "_blank"
                    , HP.rel_ "noopener noreferrer"
                    ]
                    [text "open link"]
                , H.button_
                    [HP.class_ "action", HP.type_ "button", HE.onClick DrawerClose]
                    [text "close"]
                ]
            ]

findBookmark :: Model -> Int -> Maybe BookmarkSummary
findBookmark m bid = case filter ((== bid) . bsId) (mItems m) of
    (bookmark : _) -> Just bookmark
    [] -> Nothing

stampedField :: MisoString -> MisoString -> View () () Model Action
stampedField label value =
    H.div_ [HP.class_ "field"] [H.dt_ [] [text label], H.dd_ [] [text value]]

-- --------------------------------------------------------- empty / error ---

skeletonRows :: [View () () Model Action]
skeletonRows =
    columnHeadDummy : replicate 9 skeletonRow ++ [note]
  where
    columnHeadDummy =
        H.div_
            [HP.class_ "lh meta"]
            [ H.span_ [] [text "no."]
            , H.span_ [] [text "title"]
            , H.span_ [] [text "source"]
            , H.span_ [HP.class_ "r"] [text "filed"]
            , H.span_ [] [text "tags"]
            ]
    skeletonRow =
        H.div_
            [HP.class_ "ledg-skel", HP.aria_ "hidden" "true"]
            [ H.span_ [HP.class_ "skeleton skel-no"] []
            , H.span_ [HP.class_ "skeleton skel-title"] []
            , H.span_ [HP.class_ "skeleton skel-src"] []
            , H.span_ [HP.class_ "skeleton skel-date"] []
            , H.span_ [HP.class_ "skeleton skel-tags"] []
            ]
    note =
        H.div_ [HP.class_ "ledg-skel-note meta"] [text "reading the ledger"]

freshEmpty :: View () () Model Action
freshEmpty =
    H.div_
        [HP.class_ "empty"]
        [ H.div_
            [HP.class_ "empty-note"]
            [ H.span_ [HP.class_ "empty-kicker sc"] [text "no entries"]
            , H.h2_ [HP.class_ "empty-title"] [text "The catalogue is empty."]
            , H.p_
                [HP.class_ "empty-body"]
                [text "A fresh eza instance holds no records. File the first one from the browser toolbar, or import the bookmarks file you already keep; the ledger fills as the library grows."]
            , H.p_
                [HP.class_ "empty-try"]
                [ H.button_
                    [HP.class_ "try-link", HP.type_ "button", HE.onClick AddOpen]
                    [text "file the first record"]
                , H.button_
                    [HP.class_ "try-link", HP.type_ "button", HE.onClick ImportStart]
                    [text "import a bookmarks file"]
                ]
            ]
        , H.div_ [HP.class_ "empty-lines", HP.aria_ "hidden" "true"] (replicate 6 (H.i_ [] []))
        , H.div_
            [HP.class_ "empty-end meta"]
            [H.span_ [] [text "nothing filed yet"], H.span_ [] [text "0 of 0 entries"]]
        ]

filteredEmpty :: Model -> View () () Model Action
filteredEmpty m =
    H.div_
        [HP.class_ "empty"]
        [ H.div_
            [HP.class_ "empty-note"]
            [ H.span_ [HP.class_ "empty-kicker sc"] [text "0 entries"]
            , H.h2_ [HP.class_ "empty-title"] [text "Nothing is filed under this query."]
            , H.p_
                [HP.class_ "empty-body"]
                [ text "The catalogue holds "
                , text (formatCount (maybe 0 lsTotal (mStats m)))
                , text " entries and "
                , text (formatCount (maybe 0 lsSources (mStats m)))
                , text " sources, but no record answers every part of the query. The search language is literal: "
                , H.span_ [HP.class_ "mono"] [text "tag:"]
                , text " needs an existing tag, "
                , H.span_ [HP.class_ "mono"] [text "link:"]
                , text " needs a note that links to a record, a leading "
                , H.span_ [HP.class_ "mono"] [text "−"]
                , text " excludes. The "
                , H.span_ [HP.class_ "mono"] [text "year:"]
                , text " operator takes YYYY and "
                , H.span_ [HP.class_ "mono"] [text "day:"]
                , text " takes YYYY-MM-DD."
                ]
            , H.p_
                [HP.class_ "empty-try"]
                ( H.span_ [HP.class_ "try-label meta"] [text "try"]
                    : map tryLink ["tag:books", "is:unread", "link:Determinate", "year:2025", "day:2025-11-03"]
                    ++ [ H.button_
                            [HP.class_ "try-link", HP.type_ "button", HE.onClick ClearFilters]
                            [text "clear the query"]
                       ]
                )
            ]
        , H.div_ [HP.class_ "empty-lines", HP.aria_ "hidden" "true"] (replicate 4 (H.i_ [] []))
        , H.div_
            [HP.class_ "empty-end meta"]
            [H.span_ [] [text "nothing filed under this query"], H.span_ [] [text "0 entries"]]
        ]
  where
    tryLink label =
        H.button_
            [HP.class_ "try-link", HP.type_ "button", HE.onClick (SearchInput (msText label))]
            [text (msText label)]

inboxEmpty :: Model -> View () () Model Action
inboxEmpty _ =
    H.div_
        [HP.class_ "empty"]
        [ H.div_
            [HP.class_ "empty-note"]
            [ H.span_ [HP.class_ "empty-kicker sc"] [text "inbox clear"]
            , H.h2_ [HP.class_ "empty-title"] [text "The inbox is clear."]
            , H.p_
                [HP.class_ "empty-body"]
                [text "Every record in this list has been read. New saves arrive here unread and leave it when they are marked read; nothing else changes in the catalogue."]
            , H.p_
                [HP.class_ "empty-try"]
                [ H.a_
                    [HP.class_ "try-link", HP.href_ "/", HE.onClickPrevent (Navigate Index)]
                    [text "go to the ledger"]
                , H.button_
                    [HP.class_ "try-link", HP.type_ "button", HE.onClick AddOpen]
                    [text "file a record"]
                ]
            ]
        , H.div_ [HP.class_ "empty-lines", HP.aria_ "hidden" "true"] (replicate 4 (H.i_ [] []))
        , H.div_
            [HP.class_ "empty-end meta"]
            [H.span_ [] [text "nothing unread"], H.span_ [] [text "0 unread entries"]]
        ]

errorState :: Model -> View () () Model Action
errorState m =
    H.div_
        [HP.class_ "empty ledg-error"]
        [ H.div_
            [HP.class_ "empty-note", HP.role_ "alert"]
            [ H.span_ [HP.class_ "empty-kicker sc"] [text "read failed"]
            , H.h2_ [HP.class_ "empty-title"] [text "The ledger could not be read."]
            , H.p_
                [HP.class_ "empty-body"]
                [text "The server did not answer the list request. The library in SQLite is untouched; retry, or open maintenance to see which query failed."]
            , H.p_ [HP.class_ "ledg-error-code mono"] [text (fromMaybe "" (mError m))]
            , H.p_
                [HP.class_ "ledg-error-actions"]
                [ H.button_
                    [HP.class_ "btn", HP.type_ "button", HE.onClick SearchCommit]
                    [text "retry"]
                , H.a_
                    [ HP.class_ "btn btn--ghost"
                    , HP.href_ "/maintenance"
                    , HE.onClickPrevent (Navigate Maintenance)
                    ]
                    [text "open maintenance"]
                ]
            ]
        , H.div_ [HP.class_ "empty-lines", HP.aria_ "hidden" "true"] (replicate 4 (H.i_ [] []))
        , H.div_
            [HP.class_ "empty-end meta"]
            [H.span_ [] [text "no entries loaded"], H.span_ [] [text "the catalogue is untouched"]]
        ]

{- | The parser drops an unknown is: value and a year: or day: token whose
date it cannot keep, so the page says so rather than pretending the query was
understood.
-}
invalidHint :: Model -> [View () () Model Action]
invalidHint m = case invalidFlags (qText m) of
    [] -> []
    (bad : _) ->
        let (suffix, body) = droppedCopy bad
         in [ H.div_
                [HP.class_ "srch-hint"]
                [ H.p_ [HP.class_ "srch-hint-kicker sc"] [text "dropped token"]
                , H.p_
                    [HP.class_ "srch-hint-title"]
                    [H.span_ [HP.class_ "mono"] [text (msText bad)], text suffix]
                , H.p_ [HP.class_ "srch-hint-body"] [text body]
                ]
            ]

-- | Why the first dropped token did not become a filter.
droppedCopy :: Text -> (MisoString, MisoString)
droppedCopy bad
    | isMalformedDate bad =
        ( " is not a complete date and was dropped."
        , "The parser drops a year: or day: token that is not a full date; it is not an error. Use year:YYYY or day:YYYY-MM-DD. Other flags are is:unread and is:dead."
        )
    | otherwise =
        ( " is not a search flag."
        , "The parser ignores an unknown is: value; it is not an error. The list below is what remains of the query. Known flags: is:unread, is:dead, year:YYYY and day:YYYY-MM-DD."
        )

invalidFlags :: Text -> [Text]
invalidFlags query =
    [ word
    | word <- T.words query
    , isUnknownFlag word || isMalformedDate word
    ]
  where
    isUnknownFlag word =
        "is:" `T.isPrefixOf` T.toLower word
            && T.toLower word `notElem` ["is:unread", "is:dead"]

{- | A year: or day: word whose date the parser could not keep. The parser
conditionally swallows the token and never falls back to plain text, so the
word is simply dropped.
-}
isMalformedDate :: Text -> Bool
isMalformedDate word
    | "year:" `T.isPrefixOf` word = isNothing (sqYear parsed)
    | "day:" `T.isPrefixOf` word = isNothing (sqDay parsed)
    | otherwise = False
  where
    parsed = parseSearchQuery word

-- ---------------------------------------------------------------- footer ---

ledgerFoot :: Model -> View () () Model Action
ledgerFoot m =
    H.div_
        [HP.class_ "ledger-foot meta"]
        [ H.span_ [] [text (footCount m)]
        , H.span_ [HP.class_ "ledg-foot-actions"] (footActions m)
        ]
  where
    footCount model
        | hasActiveFilters model =
            "showing "
                <> formatCount (length (mItems model))
                <> " of "
                <> formatCount (mTotal model)
        | otherwise =
            formatCount (length (mItems model))
                <> " / "
                <> formatCount (maybe (length (mItems model)) lsTotal (mStats model))
    footActions model
        | isInbox model =
            [ H.button_
                ( [ HP.class_ "ledg-foot-act"
                  , HP.type_ "button"
                  , HP.aria_ "label" (markAllLabel model)
                  , HP.title_ "Marks only the loaded unread records, after a second click to confirm."
                  , HE.onClick MarkAllAbove
                  ]
                    ++ disabledAttr (null loadedUnread || mBulkBusy model)
                )
                [text (if mConfirmMarkAll model then "click again to confirm" else "mark loaded unread read")]
            ]
        | selectedCount model > 0 = []
        | otherwise =
            [ H.button_
                [HP.class_ "ledg-foot-act", HP.type_ "button", HE.onClick SelectAllLoaded]
                [text "select page"]
            , H.button_
                [HP.class_ "ledg-foot-act", HP.type_ "button", HE.onClick SelectAllMatchingStart]
                [text "select all matching"]
            ]
    loadedUnread = [bookmark | bookmark <- mItems m, not (bsIsRead bookmark)]
    markAllLabel model =
        ms
            ( "Mark "
                <> formatCount (length [bookmark | bookmark <- mItems model, not (bsIsRead bookmark)])
                <> " loaded unread record"
                <> (if length [bookmark | bookmark <- mItems model, not (bsIsRead bookmark)] == 1 then "" else "s")
                <> " read"
            )

-- ----------------------------------------------------------- mobile nav ---

mobileNav :: Model -> View () () Model Action
mobileNav m =
    H.nav_
        [HP.class_ "m-nav", HP.aria_ "label" "Sections"]
        [ mobileLink "ledger" ledgerOn (Navigate Index)
        , mobileLink "search" searchOn (Navigate Index)
        , mobileLink "inbox" (mRoute m == Inbox) (Navigate Inbox)
        , mobileLink "account" (mRoute m == Account) (Navigate Account)
        , H.button_
            [ HP.class_ "m-nav-a m-nav-a--signout"
            , HP.type_ "button"
            , HP.data_ "testid" "m-nav-sign-out"
            , HP.aria_ "label" "Sign out"
            , HE.onClick LogoutRequest
            ]
            [text "out"]
        , H.button_
            [ HP.class_ "m-nav-a m-nav-a--plus"
            , HP.type_ "button"
            , HP.aria_ "label" "File a record"
            , HE.onClick AddOpen
            ]
            [text "+"]
        ]
  where
    searchOn = mRoute m == Index && hasActiveFilters m
    ledgerOn = isListRoute m && not searchOn

mobileLink :: MisoString -> Bool -> Action -> View () () Model Action
mobileLink label active action =
    H.button_
        [ HP.class_ ("m-nav-a" <> if active then " m-nav-a--on" else "")
        , HP.type_ "button"
        , HP.aria_ "current" (if active then "page" else "false")
        , HE.onClick action
        ]
        [text label]

-- ---------------------------------------------------------- quick save ---

{- | The share-target landing page. Update normally turns @/save@ into the add
dialog over the ledger; this page is the route's own body for the case where
it is rendered directly, and keeps the documented save ids.
-}
savePage :: Model -> View () () Model Action
savePage m =
    H.div_
        [HP.class_ "save-scroll"]
        [ H.div_
            [HP.class_ "save-spread"]
            [ H.form_
                [HP.class_ "save-sheet", HP.aria_ "label" "File a record", HE.onSubmit AddSubmit]
                [ H.div_
                    [HP.class_ "save-head"]
                    [ H.h2_ [HP.class_ "save-title"] [text "File a record"]
                    , H.p_
                        [HP.class_ "save-lede"]
                        [text "Prefilled from the page you were reading. Adjust the title, tags or note before filing; the address is kept exactly as it arrived."]
                    ]
                , H.div_
                    [HP.class_ "save-fields"]
                    ( [ saveField "address" "save-url" "url" (mAddUrl m) AddUrlInput False
                      , saveField "title" "save-title" "text" (mAddTitle m) AddTitleInput True
                      , saveField "tags" "save-tags" "text" (mAddTags m) AddTagsInput False
                      , H.p_
                            [HP.class_ "save-hint"]
                            [text "A new name creates a new tag in the catalogue."]
                      , H.div_
                            [HP.class_ "save-field"]
                            [ H.label_ [HP.class_ "save-label", HP.for_ "save-note"] [text "note"]
                            , H.textarea_
                                [ HP.id_ "save-note"
                                , HP.class_ "save-input save-input--note"
                                , HP.rows_ "3"
                                , HP.value_ (mAddNote m)
                                , HP.placeholder_ "optional"
                                , HP.aria_ "label" "Note"
                                , HE.onInput AddNoteInput
                                ]
                            ]
                      ]
                    )
                , duplicateNote m
                , saveErrorMessage m
                , H.div_
                    [HP.class_ "save-actions"]
                    [ H.a_
                        [HP.class_ "btn btn--ghost", HP.href_ "/", HE.onClickPrevent (Navigate Index)]
                        [text "cancel"]
                    , H.button_
                        ( [ HP.class_ "btn btn--strong"
                          , HP.type_ "submit"
                          , HP.data_ "testid" "save-submit"
                          ]
                            ++ disabledAttr (mAddBusy m)
                        )
                        [text (if mAddBusy m then "filing" else "file it")]
                    ]
                , H.p_
                    [HP.class_ "save-status meta"]
                    [ text
                        ( if mAddBusy m
                            then "filing: the record is written first, then the note"
                            else "the address is checked against the library when you file"
                        )
                    ]
                ]
            , saveNotes m
            ]
        ]

{- | The validation or server error behind the form.  A duplicate has its own
notice, so only unrelated failures appear here.
-}
saveErrorMessage :: Model -> View () () Model Action
saveErrorMessage m = case (duplicateId m, mAddError m) of
    (Nothing, Just message) ->
        H.p_ [HP.class_ "add-error", HP.role_ "alert"] [text message]
    _ -> H.span_ [] []

duplicateNote :: Model -> View () () Model Action
duplicateNote m = case duplicateId m of
    Nothing -> H.div_ [] []
    Just bid ->
        H.div_
            [HP.class_ "save-warning"]
            [ H.span_ [HP.class_ "save-warning-kicker sc"] [text "already filed"]
            , H.p_
                [HP.class_ "save-warning-body"]
                [ text "This address is already in the catalogue as "
                , H.a_
                    [ HP.class_ "save-warning-no"
                    , HP.href_ (routePath (Bookmark bid))
                    , HE.onClickPrevent (Navigate (Bookmark bid))
                    ]
                    [text (accessionNo bid)]
                , text ". Filing a second copy is not supported; open the record instead."
                ]
            ]

saveField :: MisoString -> MisoString -> MisoString -> MisoString -> (MisoString -> Action) -> Bool -> View () () Model Action
saveField label domId inputType value onInput wide =
    H.div_
        [HP.class_ "save-field"]
        [ H.label_ [HP.class_ "save-label", HP.for_ domId] [text label]
        , H.input_
            [ HP.id_ domId
            , HP.class_ ("save-input" <> if wide then " save-input--title" else "")
            , HP.type_ inputType
            , HP.value_ value
            , HP.autocomplete_ "off"
            , HP.spellcheck_ False
            , HE.onInput onInput
            ]
        ]

saveNotes :: Model -> View () () Model Action
saveNotes m =
    H.aside_
        [HP.class_ "save-notes", HP.aria_ "label" "What filing does"]
        [ H.h2_ [HP.class_ "save-notes-title sc"] [text "What filing does"]
        , H.dl_
            [HP.class_ "save-rules"]
            ( map
                (\(term, detail) -> H.div_ [HP.class_ "save-rule"] [H.dt_ [] [text term], H.dd_ [] [text detail]])
                [ ("accession", "one number, reserved at filing")
                , ("duplicates", "checked against normalised addresses")
                , ("tags", "literal; a new name makes a new tag")
                , ("writes", "the record first, then the note when one is supplied")
                ]
            )
        , H.p_
            [HP.class_ "save-note"]
            [text "The quick save path is the same write the bookmarklet and the installed share target use. Filing stores the address; fetching and extraction are separate jobs."]
        , H.p_ [HP.class_ "save-colophon meta"] [text (saveColophon m)]
        ]

-- | The colophon only names years the library actually reports.
saveColophon :: Model -> MisoString
saveColophon m = case mStats m of
    Just stats
        | not (T.null (T.strip (lsFirstDay stats))) ->
            "eza · " <> yearOfDay (lsFirstDay stats) <> " to " <> yearOfDay (lsLastDay stats)
    _ -> "eza"

isNothingMaybe :: Maybe a -> Bool
isNothingMaybe Nothing = True
isNothingMaybe (Just _) = False

-- -------------------------------------------------------------- overlays ---

paletteView :: Model -> View () () Model Action
paletteView m =
    H.div_
        [HP.class_ "palette", HP.data_ "testid" "palette"]
        [ H.div_
            [HP.class_ "slip-wrap", HE.onClick PaletteClose]
            [ H.div_
                [ HP.class_ "slip"
                , HP.role_ "dialog"
                , HP.aria_ "modal" "true"
                , HP.aria_ "label" "Command palette"
                , HE.onClickWithOptions stopPropagation Noop
                ]
                [ H.div_
                    [HP.class_ "slip-head"]
                    [ H.span_ [HP.class_ "query-mark", HP.aria_ "hidden" "true"] [text "/"]
                    , H.input_
                        [ HP.id_ "palette-input"
                        , HP.class_ "slip-input"
                        , HP.type_ "text"
                        , HP.placeholder_ "a command, a query, an accession"
                        , HP.aria_ "label" "Search commands and records"
                        , HP.autofocus_ True
                        , HP.value_ (mPaletteQ m)
                        , HP.autocomplete_ "off"
                        , HP.spellcheck_ False
                        , HE.onInput PaletteInput
                        ]
                    , H.kbd_ [] [text "esc"]
                    ]
                , H.div_
                    [HP.class_ "slip-body"]
                    ( H.div_ [HP.class_ "slip-sec meta"] [text "Commands and entries"]
                        : zipWith (paletteRow m) [0 ..] (paletteEntries m)
                    )
                , H.div_
                    [HP.class_ "slip-foot meta"]
                    [ H.span_ [] [H.kbd_ [] [text "↑"], text " ", H.kbd_ [] [text "↓"], text " move"]
                    , H.span_ [] [H.kbd_ [] [text "↵"], text " run"]
                    , H.span_ [] [H.kbd_ [] [text "esc"], text " close"]
                    ]
                ]
            ]
        ]

paletteRow :: Model -> Int -> (MisoString, MisoString, Action) -> View () () Model Action
paletteRow m index (label, hint, _) =
    H.button_
        [ HP.class_ ("slip-row" <> if index == mPaletteSel m then " is-sel" else "")
        , HP.type_ "button"
        , HP.data_ "testid" "palette-row"
        , HP.title_ hint
        , HE.onClick (PaletteChoose index)
        ]
        [ H.span_ [HP.class_ "sr-title"] [text label]
        ]

toastsView :: Model -> View () () Model Action
toastsView m =
    H.div_
        [HP.class_ "toast-host", HP.aria_ "live" "polite"]
        (map toastView (mToasts m))

toastView :: Toast -> View () () Model Action
toastView toast =
    H.div_
        [ HP.class_ ("toast " <> toastKindClass (toastKind toast))
        , HP.role_ "status"
        , HP.data_ "testid" "toast"
        ]
        [ H.span_ [] [text (toastMessage toast)]
        , H.button_
            [ HP.class_ "toast__close"
            , HP.type_ "button"
            , HP.aria_ "label" "Dismiss"
            , HE.onClick (ToastDismiss (toastId toast))
            ]
            [text "×"]
        ]

toastKindClass :: ToastKind -> MisoString
toastKindClass = \case
    ToastOk -> "toast--ok"
    ToastError -> "toast--err"
    ToastInfo -> "toast--info"

-- ------------------------------------------------------ saved share slip ---

{- | The share slip for a saved search. It keeps the record share look and the
same @POST /api/v1/share-links@ contract with @scope: "saved_search"@; the
public page and its Atom feed serve the saved query rather than a record.
-}
savedSearchShareDialog :: Model -> [View () () Model Action]
savedSearchShareDialog m = case mSavedShare m of
    Nothing -> []
    Just saved ->
        [ H.div_
            [HP.class_ "overlay is-open", HE.onClick SavedSearchShareClose]
            [ H.div_
                [ HP.class_ "dshare-slip"
                , HP.data_ "testid" "dialog-saved-share"
                , HP.role_ "dialog"
                , HP.aria_ "modal" "true"
                , HP.aria_ "label" "Share a saved search"
                , HE.onClickWithOptions stopPropagation Noop
                ]
                ( [ H.div_
                        [HP.class_ "dshare-head"]
                        [ H.h2_
                            [HP.class_ "dshare-title"]
                            [text "Share a saved search"]
                        , H.button_
                            [ HP.class_ "dshare-x"
                            , HP.type_ "button"
                            , HP.aria_ "label" "Close"
                            , HP.title_ "Close"
                            , HE.onClick SavedSearchShareClose
                            ]
                            [text "×"]
                        ]
                  , H.p_
                        [HP.class_ "dshare-copy"]
                        [ text
                            ( ms
                                ( "A read-only page of “"
                                    <> ssName saved
                                    <> "” and an Atom feed at the same address. The link is unguessable and can be revoked here."
                                )
                            )
                        ]
                  ]
                    ++ savedSearchShareLinkRow m
                    ++ [ savedSearchShareFields m
                       , savedSearchShareLinks m saved
                       , H.div_
                            [HP.class_ "dshare-foot"]
                            [ H.p_
                                [HP.class_ "dshare-note"]
                                [text "The recipient does not need an account, and this does not make the library public."]
                            , H.button_
                                [HP.class_ "btn", HP.type_ "button", HE.onClick SavedSearchShareClose]
                                [text "done"]
                            ]
                       ]
                )
            ]
        ]

savedSearchShareLinkRow :: Model -> [View () () Model Action]
savedSearchShareLinkRow m = case mShareUrl m of
    Just url ->
        [ H.div_
            [HP.class_ "dshare-linkrow", HP.data_ "testid" "saved-share-reveal"]
            [ H.a_
                [ HP.class_ "dshare-link"
                , HP.data_ "testid" "saved-share-url"
                , HP.href_ (ms url)
                , HP.target_ "_blank"
                , HP.rel_ "noopener noreferrer"
                ]
                [text (ms url)]
            , H.button_
                [ HP.class_ "btn"
                , HP.data_ "testid" "saved-share-copy"
                , HP.type_ "button"
                , HE.onClick (ShareCopy url)
                ]
                [text "copy link"]
            ]
        ]
    Nothing ->
        [ H.div_
            [HP.class_ "dshare-linkrow"]
            [ H.span_ [HP.class_ "dshare-link"] [text "no link created yet"]
            , H.button_
                ( [ HP.class_ "btn btn--strong"
                  , HP.data_ "testid" "saved-share-create"
                  , HP.type_ "button"
                  , HE.onClick SavedSearchShareCreate
                  ]
                    ++ disabledAttr (mShareBusy m)
                )
                [text (if mShareBusy m then "creating..." else "create the link")]
            ]
        ]

savedSearchShareFields :: Model -> View () () Model Action
savedSearchShareFields m =
    H.div_
        [HP.class_ "dshare-fields"]
        [ H.div_
            [HP.class_ "field dshare-expiry-field"]
            [ H.label_
                [HP.class_ "field-label", HP.for_ "saved-share-expiry"]
                [text "expires"]
            , H.select_
                [ HP.id_ "saved-share-expiry"
                , HP.class_ "select"
                , HP.autofocus_ True
                , HE.onChange
                    ( \raw ->
                        ShareExpirySelected
                            (fromMaybe 30 (readMaybe (fromMisoString raw :: String)))
                    )
                ]
                (map (savedShareExpiryOption (mShareExpiryDays m)) savedShareExpiryChoices)
            ]
        ]

-- | Expiry choices offered for a share link, in days.
savedShareExpiryChoices :: [Int]
savedShareExpiryChoices = [1, 7, 30, 90, 365]

savedShareExpiryOption :: Int -> Int -> View () () Model Action
savedShareExpiryOption current days =
    H.option_
        [HP.value_ (ms (show days)), HP.selected_ (current == days)]
        [text (ms (labelFor days))]
  where
    labelFor 1 = "in 1 day" :: MisoString
    labelFor value = ms ("in " <> show value <> " days")

savedSearchShareLinks :: Model -> SavedSearch -> View () () Model Action
savedSearchShareLinks m saved
    | Just message <- mSharesError m =
        H.p_ [HP.class_ "dshare-note"] [text "existing links could not be read: ", text message]
    | null activeLinks = H.span_ [] []
    | otherwise =
        H.div_
            [HP.class_ "record-sec"]
            [ H.div_
                [HP.class_ "record-sec-head"]
                [H.h3_ [HP.class_ "record-sec-title sc"] [text "Existing links"]]
            , H.div_ [HP.class_ "record-tags"] (map linkRow activeLinks)
            ]
  where
    activeLinks =
        [ share
        | share <- mShares m
        , svScope share == "saved_search"
        , svTargetId share == ssId saved
        , isNothing (svRevokedAt share)
        ]
    linkRow share =
        H.span_
            [HP.class_ "record-tags", HP.data_ "testid" "saved-share-row"]
            [ H.span_ [HP.class_ "mono"] [text (ms (svPrefix share))]
            , H.span_ [HP.class_ "status--warn"] [text "expires ", text (formatFiled (svExpiresAt share))]
            , H.button_
                [ HP.class_ "btn btn--sm"
                , HP.data_ "testid" "saved-share-revoke"
                , HP.type_ "button"
                , HE.onClick (ShareRevoke (svId share))
                ]
                [text "revoke"]
            ]

addDialog :: Model -> View () () Model Action
addDialog m =
    H.div_
        [ HP.class_ "overlay is-open"
        , HP.data_ "testid" "dialog"
        , HE.onClick AddClose
        ]
        [ H.div_
            [ HP.class_ "dialog add-dialog"
            , HP.data_ "testid" "dialog-add"
            , HP.data_ "add-state" (addState m)
            , HP.role_ "dialog"
            , HP.aria_ "modal" "true"
            , HP.aria_ "label" "File a record"
            , HE.onClickWithOptions stopPropagation Noop
            ]
            [ H.div_
                [HP.class_ "dialog__head"]
                [H.h2_ [HP.class_ "dialog__title"] [text "File a record"], H.kbd_ [] [text "esc"]]
            , H.form_
                [HP.class_ "add-form", HE.onSubmit AddSubmit]
                [ H.div_
                    [HP.class_ "dialog__body", HP.data_ "testid" "dialog-body"]
                    ( [ addField "address" "add-url" "url" (mAddUrl m) AddUrlInput ""
                      , addField "title" "add-title" "text" (mAddTitle m) AddTitleInput " add-field-title"
                      , addField "tags" "add-tags" "text" (mAddTags m) AddTagsInput " add-field-tags"
                      ]
                        ++ [ H.p_ [HP.class_ "add-error"] [text message]
                           | isNothingMaybe (duplicateId m)
                           , Just message <- [mAddError m]
                           ]
                        ++ [duplicateBlock m | isJust (duplicateId m)]
                        ++ [ H.div_
                                [HP.class_ "add-progress"]
                                [ H.div_
                                    [HP.class_ "bar"]
                                    [H.i_ [C.styleInline_ "width:60%"] []]
                                , H.p_
                                    [HP.class_ "add-progress-note meta"]
                                    [text "filing: one write, no network call"]
                                ]
                           | mAddBusy m
                           ]
                    )
                , H.div_
                    [HP.class_ "dialog__foot"]
                    [ H.span_ [HP.class_ "spacer"] []
                    , H.button_
                        [ HP.class_ "btn"
                        , HP.type_ "button"
                        , HP.data_ "testid" "dialog-cancel"
                        , HE.onClick AddClose
                        ]
                        [text "cancel"]
                    , H.button_
                        ( [ HP.class_ "btn btn--strong"
                          , HP.type_ "submit"
                          , HP.data_ "testid" "dialog-confirm"
                          , HP.data_ "add-submit" ""
                          ]
                            ++ disabledAttr (mAddBusy m)
                        )
                        [text "file it"]
                    ]
                ]
            ]
        ]
  where
    addState model
        | mAddBusy model = "saving"
        | isJust (duplicateId model) = "duplicate"
        | otherwise = "idle"

addField :: MisoString -> MisoString -> MisoString -> MisoString -> (MisoString -> Action) -> MisoString -> View () () Model Action
addField label domId inputType value onInput extraClass =
    H.div_
        [HP.class_ ("field" <> extraClass)]
        [ H.label_ [HP.class_ "field-label", HP.for_ domId] [text label]
        , H.input_
            ( [ HP.id_ domId
              , HP.class_ "input"
              , HP.type_ inputType
              , HP.value_ value
              , HP.autocomplete_ "off"
              , HP.spellcheck_ False
              , HE.onInput onInput
              ]
                ++ [HP.autofocus_ True | domId == "add-url"]
            )
        ]

duplicateBlock :: Model -> View () () Model Action
duplicateBlock m = case duplicateId m of
    Nothing -> H.div_ [] []
    Just bid ->
        H.div_
            [HP.class_ "add-dup"]
            [ H.p_ [HP.class_ "add-dup-title sc"] [text "already filed"]
            , H.p_
                [HP.class_ "add-dup-body"]
                [ text "This address is already in the catalogue as "
                , H.a_
                    [ HP.class_ "add-dup-link"
                    , HP.href_ (routePath (Bookmark bid))
                    , HE.onClickPrevent (Navigate (Bookmark bid))
                    ]
                    [text (accessionNo bid)]
                , text ". Filing a second copy is not supported; open the record instead."
                ]
            , H.div_
                [HP.class_ "add-dup-actions"]
                [ H.a_
                    [ HP.class_ "btn btn--ghost"
                    , HP.href_ (routePath (Bookmark bid))
                    , HE.onClickPrevent (Navigate (Bookmark bid))
                    ]
                    [text "open the record"]
                ]
            ]

guardDialog :: Model -> View () () Model Action
guardDialog _ =
    H.div_
        [HP.class_ "overlay is-open", HP.data_ "testid" "dialog", HE.onClick DirtyGuardClose]
        [ H.div_
            [ HP.class_ "dialog"
            , HP.data_ "testid" "dialog-guard"
            , HP.role_ "dialog"
            , HP.aria_ "modal" "true"
            , HP.aria_ "label" "Unsaved changes"
            , HE.onClickWithOptions stopPropagation Noop
            ]
            [ dialogHead "Unsaved changes"
            , H.div_
                [HP.class_ "dialog__body", HP.data_ "testid" "dialog-body"]
                [H.p_ [] [text "Your note or title edits have not been saved yet. Leave anyway?"]]
            , H.div_
                [HP.class_ "dialog__foot"]
                [ H.span_ [HP.class_ "spacer"] []
                , dialogButton "dialog-cancel" "btn" "keep editing" DirtyGuardClose
                , dialogButton "dialog-confirm" "btn btn--strong" "discard and leave" DirtyGuardDiscard
                ]
            ]
        ]

{- | The dirty-editor guard for signing out: the note on this record would not
be written, so the action asks first. It reuses the shared dialog shell and the
same test hooks as the delete guard.
-}
logoutDialog :: View () () Model Action
logoutDialog =
    H.div_
        [HP.class_ "overlay is-open", HP.data_ "testid" "dialog", HE.onClick LogoutCancel]
        [ H.div_
            [ HP.class_ "dialog"
            , HP.data_ "testid" "dialog-logout"
            , HP.role_ "dialog"
            , HP.aria_ "modal" "true"
            , HP.aria_ "label" "Sign out"
            , HE.onClickWithOptions stopPropagation Noop
            ]
            [ dialogHead "Sign out"
            , H.div_
                [HP.class_ "dialog__body", HP.data_ "testid" "dialog-body"]
                [ H.p_
                    []
                    [text "The note or title edits on this record have not been saved yet. Signing out leaves them behind."]
                ]
            , H.div_
                [HP.class_ "dialog__foot"]
                [ H.span_ [HP.class_ "spacer"] []
                , dialogButton "dialog-cancel" "btn" "keep editing" LogoutCancel
                , dialogButton "dialog-confirm" "btn btn--strong" "sign out" Logout
                ]
            ]
        ]

tagPromptDialog :: Model -> View () () Model Action
tagPromptDialog m =
    H.div_
        [HP.class_ "overlay is-open", HP.data_ "testid" "dialog-bulk-tag", HE.onClick BulkTagCancel]
        [ H.div_
            [ HP.class_ "dialog"
            , HP.data_ "testid" "dialog-tag"
            , HP.role_ "dialog"
            , HP.aria_ "modal" "true"
            , HP.aria_ "label" title
            , HE.onClickWithOptions stopPropagation Noop
            ]
            [ dialogHead title
            , H.div_
                [HP.class_ "dialog__body", HP.data_ "testid" "dialog-body"]
                [ H.div_
                    [HP.class_ "field"]
                    [ H.label_ [HP.class_ "field-label", HP.for_ "bulk-tag-input"] [text "tags"]
                    , H.input_
                        [ HP.id_ "bulk-tag-input"
                        , HP.class_ "input"
                        , HP.type_ "text"
                        , HP.value_ (mTagPromptValue m)
                        , HP.placeholder_ "comma-separated tags"
                        , HP.autocomplete_ "off"
                        , HE.onInput BulkTagInput
                        , HE.onKeyDown enterSubmits
                        ]
                    ]
                , H.p_
                    [HP.class_ "meta"]
                    ( text (formatCount (selectedCount m))
                        : [ text
                                ( " bookmark"
                                    <> (if selectedCount m == 1 then "" else "s")
                                    <> " will be updated."
                                )
                          ]
                    )
                ]
            , H.div_
                [HP.class_ "dialog__foot"]
                [ H.span_ [HP.class_ "spacer"] []
                , dialogButton "dialog-cancel" "btn" "cancel" BulkTagCancel
                , dialogButton "dialog-confirm" "btn btn--strong" "apply" BulkTagSubmit
                ]
            ]
        ]
  where
    title
        | mTagPrompt m == Just True = "Add tags to selection"
        | otherwise = "Remove tags from selection"
    enterSubmits (KeyCode 13) = BulkTagSubmit
    enterSubmits _ = Noop

bulkDeleteDialog :: Model -> View () () Model Action
bulkDeleteDialog m =
    H.div_
        [HP.class_ "overlay is-open", HP.data_ "testid" "dialog", HE.onClick BulkDeleteCancel]
        [ H.div_
            [ HP.class_ "dialog"
            , HP.data_ "testid" "dialog-bulk-delete"
            , HP.role_ "dialog"
            , HP.aria_ "modal" "true"
            , HP.aria_ "label" "Delete records"
            , HE.onClickWithOptions stopPropagation Noop
            ]
            [ dialogHead "Delete records"
            , H.div_
                [HP.class_ "dialog__body", HP.data_ "testid" "dialog-body"]
                [ H.p_
                    []
                    [ text
                        ( "Delete "
                            <> formatCount (selectedCount m)
                            <> " selected record"
                            <> (if selectedCount m == 1 then "" else "s")
                            <> "? A snapshot is kept, so this can be undone from maintenance."
                        )
                    ]
                ]
            , H.div_
                [HP.class_ "dialog__foot"]
                [ H.span_ [HP.class_ "spacer"] []
                , dialogButton "dialog-cancel" "btn" "cancel" BulkDeleteCancel
                , dialogButton "dialog-confirm" "btn btn--danger" "delete records" BulkDeleteConfirm
                ]
            ]
        ]

dialogHead :: MisoString -> View () () Model Action
dialogHead title =
    H.div_
        [HP.class_ "dialog__head"]
        [H.h2_ [HP.class_ "dialog__title"] [text title], H.kbd_ [] [text "esc"]]

dialogButton :: MisoString -> MisoString -> MisoString -> Action -> View () () Model Action
dialogButton hook extraClass label action =
    H.button_
        [HP.class_ extraClass, HP.type_ "button", HP.data_ "testid" hook, HE.onClick action]
        [text label]

importInput :: View () () Model Action
importInput =
    H.input_
        [ HP.id_ "import-file"
        , HP.class_ "sr-only"
        , HP.type_ "file"
        , HP.accept_ ".html,.json,text/html,application/json"
        , HE.onChange (const ImportFileChosen)
        ]

-- --------------------------------------------------------------- queries ---

msText :: Text -> MisoString
msText = ms . T.unpack

qText :: Model -> Text
qText m = T.pack (fromMisoString (mQ m))

hasActiveFilters :: Model -> Bool
hasActiveFilters m = not (T.null (T.strip (qText m))) || not (null (mTagsFilter m))

-- | Is this exact free term already in the query?
hasTerm :: Model -> Text -> Bool
hasTerm m term = T.toLower term `elem` map T.toLower (T.words (qText m))

-- | Append a term, or remove it when it is already there.
toggleTerm :: Model -> Text -> MisoString
toggleTerm m term =
    let query = qText m
        words' = T.words query
        needle = T.toLower term
        remaining = dropFirst (\word -> T.toLower word == needle) words'
     in if hasTerm m term
            then ms (T.unpack (T.unwords remaining))
            else ms (T.unpack (T.strip (query <> " " <> term)))

dropFirst :: (a -> Bool) -> [a] -> [a]
dropFirst _ [] = []
dropFirst predicate (x : xs)
    | predicate x = xs
    | otherwise = x : dropFirst predicate xs

{- | Query chips: tag filters from the model plus the parsed query tokens.
Clicking a chip removes it; tag filters toggle through the model action.
-}
queryChips :: Model -> [View () () Model Action]
queryChips m = map tagFilterChip (mTagsFilter m) ++ map tokenChip (tokensOf m)
  where
    tagFilterChip tag =
        H.button_
            [ HP.class_ "chip"
            , HP.type_ "button"
            , HP.title_ "Remove this tag filter"
            , HE.onClick (TagToggled tag)
            ]
            [H.span_ [HP.class_ "op"] [text "tag:"], text (msText tag)]
    tokenChip token =
        H.button_
            [ HP.class_ (chipClass token)
            , HP.type_ "button"
            , HP.title_ "Remove this token"
            , HE.onClick (SearchInput (ms (T.unpack (removeToken token (qText m)))))
            ]
            (chipBody token)

data ChipToken
    = NegTerm Text
    | FreeTerm Text
    | TagToken Text
    | IsUnread
    | IsDead
    | LinkToken Text
    | YearToken Int
    | DayToken Text
    | BadToken Text

chipBody :: ChipToken -> [View () () Model Action]
chipBody = \case
    NegTerm term -> [H.span_ [HP.class_ "minus"] [text "−"], text (msText term)]
    FreeTerm term -> [text (msText term)]
    TagToken tag -> [H.span_ [HP.class_ "op"] [text "tag:"], text (msText tag)]
    IsUnread -> [H.span_ [HP.class_ "op"] [text "is:"], text "unread"]
    IsDead -> [H.span_ [HP.class_ "op"] [text "is:"], text "dead"]
    LinkToken target -> [H.span_ [HP.class_ "op"] [text "link:"], text (msText target)]
    YearToken year -> [H.span_ [HP.class_ "op"] [text "year:"], text (ms (show year))]
    DayToken day -> [H.span_ [HP.class_ "op"] [text "day:"], text (msText day)]
    BadToken raw -> [text (msText raw)]

chipClass :: ChipToken -> MisoString
chipClass token = case token of
    NegTerm _ -> "chip chip--neg"
    FreeTerm _ -> "chip chip--free"
    BadToken _ -> "chip chip--bad"
    _ -> "chip"

tokensOf :: Model -> [ChipToken]
tokensOf m =
    map NegTerm (sqNegated parsed)
        ++ map FreeTerm (sqTerms parsed)
        ++ map TagToken (sqTags parsed)
        ++ [IsUnread | sqIsUnread parsed]
        ++ [IsDead | sqIsDead parsed]
        ++ map LinkToken (sqLinkTargets parsed)
        ++ [YearToken year | Just year <- [sqYear parsed]]
        ++ [DayToken day | Just day <- [sqDay parsed]]
        ++ map BadToken (invalidFlags (qText m))
  where
    parsed = parseSearchQuery (qText m)

-- | Remove the first query word that produced this chip.
removeToken :: ChipToken -> Text -> Text
removeToken token query = T.unwords (dropFirst matching (T.words query))
  where
    matching word = case token of
        NegTerm term -> word == "-" <> term
        FreeTerm term -> T.toLower word == T.toLower term
        TagToken tag -> T.toLower word == T.toLower ("tag:" <> tag)
        IsUnread -> T.toLower word == "is:unread"
        IsDead -> T.toLower word == "is:dead"
        LinkToken target -> T.toLower word == T.toLower ("link:" <> target)
        YearToken year -> T.toLower word == "year:" <> T.pack (show year)
        DayToken day -> T.toLower word == "day:" <> T.toLower day
        BadToken raw -> word == raw

-- ------------------------------------------------------------- utilities ---

accessionNo :: Int -> MisoString
accessionNo bid = "EA-" <> ms (padded (show bid))
  where
    padded s = replicate (max 0 (5 - length s)) '0' <> s

{- | The design row mark: a real favicon when the server has one, otherwise a
deliberate monogram. The server's question-mark fallback SVG is never shown.
-}
faviconView :: BookmarkSummary -> [View () () Model Action]
faviconView bookmark
    | hasIcon =
        [ H.img_
            [ HP.class_ "fav"
            , HP.src_ (faviconFor bookmark)
            , HP.alt_ ""
            , HP.loading_ "lazy"
            ]
        ]
    | otherwise = [H.span_ [HP.class_ "mono-badge", HP.aria_ "hidden" "true"] [text (ms (monogramOf bookmark))]]
  where
    raw = T.strip (bsFaviconUrl bookmark)
    hasIcon = not (T.null raw) && not ("favicon-fallback" `T.isInfixOf` raw)

-- | Deliberate monogram fallback for a domain the server has no icon for.
monogramOf :: BookmarkSummary -> String
monogramOf bookmark = case T.unpack (T.toUpper (T.take 1 (stripWww (bsDomain bookmark)))) of
    (c : _) -> [c]
    [] -> "?"

stripWww :: Text -> Text
stripWww domain = fromMaybe domain (T.stripPrefix "www." domain)

faviconFor :: BookmarkSummary -> MisoString
faviconFor bookmark
    | T.null rawUrl = "/assets/favicon-fallback.svg"
    | "http://" `T.isPrefixOf` lowered = ms rawUrl
    | "https://" `T.isPrefixOf` lowered = ms rawUrl
    | "data:" `T.isPrefixOf` lowered = ms rawUrl
    | "/" `T.isPrefixOf` rawUrl = ms rawUrl
    | otherwise = ms ("https://" <> rawUrl)
  where
    rawUrl = T.strip (bsFaviconUrl bookmark)
    lowered = T.toLower rawUrl

-- | Insert zero-width break opportunities so a long URL wraps in the field card.
breakableUrl :: Text -> Text
breakableUrl = T.concatMap breakChar
  where
    breakChar c
        | c `elem` ("/-?&=." :: String) = T.singleton c <> "\x200b"
        | otherwise = T.singleton c

stripScheme :: Text -> Text
stripScheme u = case T.stripPrefix "https://" u of
    Just rest -> rest
    Nothing -> fromMaybe u (T.stripPrefix "http://" u)

duplicateId :: Model -> Maybe Int
duplicateId m = do
    message <- mAddError m
    let raw = T.pack (fromMisoString message)
    rest <- T.stripPrefix "already saved as bookmark " raw
    readMaybe (T.unpack (T.strip rest))

{- | Days since the Unix epoch for a @YYYY-MM-DD@ day, matching the model's
civil-date helpers; used for the weekly filing sparkline.
-}
dayNumber :: Text -> Maybe Int
dayNumber day = case T.splitOn "-" day of
    [y, mo, d] -> do
        year <- readInt y
        month <- readInt mo
        dayOfMonth <- readInt d
        pure (daysFromCivil year month dayOfMonth)
    _ -> Nothing
  where
    readInt value = case reads (T.unpack value) of
        ((n, rest) : _) | null rest -> Just n
        _ -> Nothing

daysFromCivil :: Int -> Int -> Int -> Int
daysFromCivil year month dayOfMonth = era * 146097 + doe - 719468
  where
    y = if month <= 2 then year - 1 else year
    era = (if y >= 0 then y else y - 399) `div` 400
    yoe = y - era * 400
    mp = if month > 2 then month - 3 else month + 9
    doy = (153 * mp + 2) `div` 5 + dayOfMonth - 1
    doe = yoe * 365 + yoe `div` 4 - yoe `div` 100 + doy
