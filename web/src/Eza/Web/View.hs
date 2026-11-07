{- | The application shell: top bar, scope pills, tag rail, virtualized card
grid, command palette, add modal, dirty guard, and toasts.
-}
module Eza.Web.View (viewModel) where

import Data.Text (Text)
import qualified Data.Text as T
import Miso
import qualified Miso.CSS as C
import qualified Miso.Html as H
import qualified Miso.Html.Event as HE
import qualified Miso.Html.Property as HP

import Eza.Types (
    BookmarkSummary (..),
    SavedSearch (..),
    TagStat (..),
 )
import Eza.Web.Detail (detailPage)
import Eza.Web.Model
import Eza.Web.Panels (accountPage, aiTagsPage, dedupPage, graphPage, maintenancePage, tagsPage)
import Eza.Web.Widgets

viewModel :: Model -> View () () Model Action
viewModel m =
    H.div_
        [HP.class_ "app-shell"]
        ( [topbar m, scopes m, routeBody m, toastsView m]
            ++ [offlineBanner | not (mOnline m)]
            ++ [addModal m | mAddOpen m]
            ++ [paletteView m | mPaletteOpen m]
            ++ [guardModal m | mGuardOpen m]
            ++ [importInput]
        )

routeBody :: Model -> View () () Model Action
routeBody m = case mRoute m of
    Index -> libraryPage m
    Inbox -> libraryPage m
    Bookmark _ -> detailPage m
    Graph -> fullPage (graphPage m)
    Dedup -> fullPage (dedupPage m)
    Tags -> fullPage (tagsPage m)
    AiTags -> fullPage (aiTagsPage m)
    Maintenance -> fullPage (maintenancePage m)
    Account -> fullPage (accountPage m)
    Save _ _ _ -> libraryPage m
    NotFound -> fullPage notFoundPage

fullPage :: View () () Model Action -> View () () Model Action
fullPage view_ =
    H.main_ [HP.class_ "layout full"] [H.div_ [HP.class_ "content"] [view_]]

-- ----------------------------------------------------------------- topbar --

topbar :: Model -> View () () Model Action
topbar m =
    H.header_
        [HP.class_ "topbar"]
        [ H.div_
            [HP.class_ "topbar-inner"]
            [ H.button_
                [HP.class_ "brand", HP.type_ "button", HP.title_ "eza home", HE.onClick (Navigate Index)]
                [ H.span_ [HP.class_ "brand-mark"] [text "e"]
                , H.span_ [HP.class_ "brand-label"] [text "eza"]
                ]
            , searchInput m
            , H.div_
                [HP.class_ "topbar-actions"]
                [ iconBtn (if mTheme m == ThemeDark then iSun else iMoon) "Toggle theme" ThemeToggled
                , btn "btn-primary" [HE.onClick AddOpen] [icon iPlus, H.span_ [HP.class_ "btn-label"] [text "Add"]]
                , iconBtn iUpload "Import bookmarks" ImportStart
                , iconBtn iUser "Account" (Navigate Account)
                ]
            ]
        ]

searchInput :: Model -> View () () Model Action
searchInput m =
    H.div_
        [HP.class_ "search-wrap"]
        [ H.span_ [HP.class_ "search-icon"] [icon iSearch]
        , H.input_
            [ HP.id_ "search-input"
            , HP.class_ "search-pill"
            , HP.type_ "search"
            , HP.placeholder_ "Search everything — title, notes, tags  ( / )"
            , HP.value_ (mQ m)
            , HP.autocomplete_ "off"
            , HP.spellcheck_ False
            , HE.onInput SearchInput
            , HE.onKeyDown searchKey
            ]
        , H.span_ [HP.class_ "search-kbd"] [H.span_ [HP.class_ "kbd"] [text "/"]]
        ]
  where
    searchKey code = case code of
        KeyCode 13 -> SearchCommit
        KeyCode 27 -> ClearFilters
        _ -> Noop

-- ----------------------------------------------------------------- scopes --

scopes :: Model -> View () () Model Action
scopes m =
    H.nav_
        [HP.class_ "scopes", HP.aria_ "label" "Sections"]
        [ scopePill "All" Index (mRoute m == Index || isDetail)
        , scopePill "Inbox" Inbox (mRoute m == Inbox)
        , scopePill "Graph" Graph (mRoute m == Graph)
        , scopePill "Duplicates" Dedup (mRoute m == Dedup)
        , scopePill "Tags" Tags (mRoute m == Tags)
        , scopePill "AI tags" AiTags (mRoute m == AiTags)
        , scopePill "Maintenance" Maintenance (mRoute m == Maintenance)
        , scopePill "Account" Account (mRoute m == Account)
        ]
  where
    isDetail = case mRoute m of
        Bookmark _ -> True
        _ -> False
    scopePill label route activeOverride =
        H.button_
            [ HP.class_ ("scope" <> if active then " active" else "")
            , HP.type_ "button"
            , HE.onClick (Navigate route)
            ]
            ( [text label]
                ++ if route == Index && mTotal m > 0
                    then [H.span_ [HP.class_ "scope-count"] [text (formatCount (mTotal m))]]
                    else []
            )
      where
        active = activeOverride || mRoute m == route

-- -------------------------------------------------------------- library ---

libraryPage :: Model -> View () () Model Action
libraryPage m =
    H.main_
        [HP.class_ "layout"]
        [ railView m
        , H.div_
            [HP.class_ "content"]
            ( contentHead m
                : contentBanners m
                ++ [activeFilterChips m, gridShell m]
            )
        ]

contentHead :: Model -> View () () Model Action
contentHead m =
    H.div_
        [HP.class_ "content-head"]
        [ H.div_
            []
            [ H.h2_ [HP.class_ "head-title"] [text (titleFor m)]
            , H.p_ [HP.class_ "head-sub"] [text (subtitleFor m)]
            ]
        , H.div_
            [HP.class_ "head-actions"]
            ( ( if mRoute m == Inbox
                    then [btn "btn-sm" [HE.onClick MarkAllAbove] [icon iCheck, text "Mark all above read"]]
                    else []
              )
                ++ [ H.a_
                        [ HP.class_ "btn btn-sm"
                        , HP.href_ exportUrl'
                        , HP.download_ ""
                        , HP.title_ "Export bookmarks as Netscape HTML"
                        ]
                        [icon iDownload, H.span_ [HP.class_ "btn-label"] [text "Export"]]
                   ]
            )
        ]
  where
    exportUrl' = "/api/v1/export"

titleFor m
    | not (T.null (T.strip (fromMisoString (mQ m)))) =
        ms ("Results for \"" <> (fromMisoString (mQ m) :: String) <> "\"")
    | mRoute m == Inbox = "Inbox"
    | otherwise = "Library"

subtitleFor m
    | not (null (mTagsFilter m)) = ms (show (mTotal m) <> " bookmarks with the selected tags")
    | mRoute m == Inbox = ms (show (mTotal m) <> " unread bookmarks waiting")
    | otherwise = ms (show (mTotal m) <> " bookmarks in your library")

contentBanners :: Model -> [View () () Model Action]
contentBanners m =
    [ bannerView "danger" "Your session expired. Sign in again to keep editing." [H.a_ [HP.class_ "btn btn-sm", HP.href_ "/login"] [text "Sign in"]]
    | mSignedOut m
    ]
        ++ [bannerView "info" message [] | Just message <- [mNotice m]]
        ++ [bannerView "danger" message [] | Just message <- [mError m]]

activeFilterChips :: Model -> View () () Model Action
activeFilterChips m
    | not (null (mTagsFilter m)) || not (T.null (T.strip (fromMisoString (mQ m)))) =
        H.div_
            [HP.class_ "row-wrap"]
            ( [ H.span_
                    [HP.class_ "chip"]
                    [ text (ms ("q: " <> (fromMisoString (mQ m) :: String)))
                    , H.button_ [HP.class_ "chip-x", HP.type_ "button", HE.onClick ClearFilters] [text "×"]
                    ]
              | not (T.null (T.strip (fromMisoString (mQ m))))
              ]
                ++ [ H.span_
                        []
                        [ H.button_
                            [HP.class_ "chip", HP.type_ "button", HP.title_ "Remove tag filter", HE.onClick (TagToggled tag)]
                            [text (ms tag), H.span_ [HP.class_ "chip-x"] [text "×"]]
                        ]
                   | tag <- mTagsFilter m
                   ]
                ++ [btnSm "Clear filters" ClearFilters]
            )
    | otherwise = H.div_ [] []

gridShell :: Model -> View () () Model Action
gridShell m
    | mLoading m && null (mItems m) = skeletonGrid
    | null (mItems m) =
        if hasActiveFilters m
            then
                emptyState
                    "🔎"
                    "Nothing matches those filters"
                    [ H.p_ [] [text "Try a different search term or remove a tag filter."]
                    , btn "btn-primary" [HE.onClick ClearFilters] [text "Clear filters"]
                    ]
            else
                emptyState
                    "📚"
                    "Your library is waiting"
                    [ H.p_ [] [text "Save your first link — everything stays searchable, no folders."]
                    , btn "btn-primary" [HE.onClick AddOpen] [icon iPlus, text "Add a bookmark"]
                    , btn "btn-ghost" [HE.onClick ImportStart] [icon iUpload, text "Import browser bookmarks"]
                    ]
    | otherwise =
        H.div_
            [HP.id_ "card-grid", HP.class_ "grid-shell"]
            [ H.div_
                [HP.class_ "grid-spacer", C.style_ [C.height (C.px (rows * rowHeight (mWidth m)))]]
                [ H.div_
                    [HP.class_ "grid-track", C.style_ [C.top (C.px (firstRow * rowHeight (mWidth m)))]]
                    (map (cardView m) visibleItems)
                ]
            , if mLoadingMore m
                then spinnerRow "Loading more bookmarks…"
                else
                    if mHasMore m
                        then
                            H.div_
                                [HP.class_ "loading-row"]
                                [text (ms ("Showing " <> show (length (mItems m)) <> " of " <> show (mTotal m) <> " — scroll for more"))]
                        else H.div_ [] []
            ]
  where
    cols = colCount (mWidth m)
    rows = gridRows m
    (firstRow, lastRow) = visibleRows m
    startIndex = firstRow * cols
    count = (lastRow - firstRow) * cols
    visibleItems = take count (drop startIndex (mItems m))

skeletonGrid :: View () () Model Action
skeletonGrid =
    H.div_
        [HP.class_ "skeleton-grid", HP.aria_ "busy" "true"]
        (replicate 6 (H.div_ [HP.class_ "skeleton-card"] []))

hasActiveFilters :: Model -> Bool
hasActiveFilters m =
    not (T.null (T.strip (fromMisoString (mQ m)))) || not (null (mTagsFilter m)) || mUnreadOnly m

cardView :: Model -> BookmarkSummary -> View () () Model Action
cardView m bookmark =
    H.article_
        [ HP.class_ (cardClass bookmark)
        , HP.tabindex_ "0"
        , HE.onClick (Navigate (Bookmark (bsId bookmark)))
        , HE.onKeyDownWithInfo (\info -> if keyCodeToInt (keyCode info) == 13 then Navigate (Bookmark (bsId bookmark)) else Noop)
        ]
        [ H.div_
            [HP.class_ "card-head"]
            [ H.img_
                [ HP.class_ "favicon"
                , HP.src_ (faviconFor bookmark)
                , HP.alt_ ""
                , HP.loading_ "lazy"
                ]
            , H.span_ [HP.class_ "card-domain"] [text (ms (bsDomain bookmark))]
            , if not (bsIsRead bookmark) then H.span_ [HP.class_ "unread-dot", HP.title_ "Unread"] [] else H.span_ [] []
            , if bsIsDead bookmark then H.span_ [HP.class_ "dead-badge"] [text "dead"] else H.span_ [] []
            ]
        , H.p_ [HP.class_ "card-title"] [text (ms (bsTitle bookmark))]
        , H.div_ [HP.class_ "card-tags"] (map tagChip (take 3 (bsTags bookmark)))
        , H.div_
            [HP.class_ "card-actions"]
            [ H.a_
                [ HP.class_ "icon-btn"
                , HP.href_ (ms (bsUrl bookmark))
                , HP.target_ "_blank"
                , HP.rel_ "noopener noreferrer"
                , HP.title_ "Open the original link"
                , HE.onClickWithOptions stopPropagation Noop
                ]
                [icon iExternal]
            , H.button_
                [ HP.class_ "icon-btn danger"
                , HP.type_ "button"
                , HP.title_ "Delete bookmark"
                , HP.aria_ "label" "Delete bookmark"
                , HE.onClickWithOptions stopPropagation (DeleteBookmark (bsId bookmark))
                ]
                [icon iTrash]
            ]
        ]
  where
    _ = m

cardClass :: BookmarkSummary -> MisoString
cardClass bookmark =
    "card"
        <> (if bsIsRead bookmark then " is-read" else "")
        <> (if bsIsDead bookmark then " is-dead" else "")

{- | Favicon source for a card.  The server sends either a remote https URL or
a local /api/v1/favicons/<domain> path; both are used verbatim (so the
server-side favicon cache/fallback wins) and an empty field falls back to
the bundled SVG.  Protocol-less values are promoted to https.
-}
faviconFor :: BookmarkSummary -> MisoString
faviconFor bookmark
    | T.null url = "/assets/favicon-fallback.svg"
    | "http://" `T.isPrefixOf` lowered = ms rawUrl
    | "https://" `T.isPrefixOf` lowered = ms rawUrl
    | "data:" `T.isPrefixOf` lowered = ms rawUrl
    | "/" `T.isPrefixOf` rawUrl = ms rawUrl
    | otherwise = ms ("https://" <> rawUrl)
  where
    rawUrl = T.strip (bsFaviconUrl bookmark)
    lowered = T.toLower rawUrl
    url = rawUrl

keyCodeToInt :: KeyCode -> Int
keyCodeToInt (KeyCode n) = n

-- ------------------------------------------------------------------ rail --

railView :: Model -> View () () Model Action
railView m =
    H.aside_
        [HP.class_ "rail", HP.aria_ "label" "Filters"]
        [ savedSearchSection m
        , tagRailSection m
        , filterSection m
        ]

savedSearchSection :: Model -> View () () Model Action
savedSearchSection m =
    H.section_
        [HP.class_ "rail-section"]
        [ H.h3_ [HP.class_ "rail-title"] [text "Saved searches"]
        , H.div_
            [HP.class_ "stack"]
            ( [ H.div_
                    [HP.class_ "row"]
                    [ H.button_
                        [HP.class_ "tag-item", HP.type_ "button", HP.title_ "Apply saved search", HE.onClick (SavedSearchApply saved)]
                        [H.span_ [HP.class_ "tag-name"] [text (ms (ssName saved))]]
                    , iconBtn iTrash "Delete saved search" (SavedSearchDelete (ssId saved))
                    ]
              | saved <- mSaved m
              ]
                ++ [ H.div_
                        [HP.class_ "row"]
                        [ H.input_
                            [ HP.class_ "input"
                            , HP.placeholder_ "Save current search as…"
                            , HP.value_ (mSavedName m)
                            , HE.onInput SavedSearchNameInput
                            ]
                        , iconBtn iPlus "Save current search" SavedSearchSave
                        ]
                   ]
            )
        ]

tagRailSection :: Model -> View () () Model Action
tagRailSection m =
    H.section_
        [HP.class_ "rail-section"]
        [ H.h3_ [HP.class_ "rail-title"] [text "Tags"]
        , H.div_
            [HP.class_ "rail-scroll"]
            ( [ H.button_
                    [ HP.class_ ("tag-item" <> if tsName tag `elem` mTagsFilter m then " active" else "")
                    , HP.type_ "button"
                    , HE.onClick (TagToggled (tsName tag))
                    ]
                    [ H.span_ [HP.class_ "tag-name"] [text (ms (tsName tag))]
                    , H.span_ [HP.class_ "tag-count"] [text (ms (show (tsCount tag)))]
                    ]
              | tag <- take 40 (mTags m)
              ]
                ++ [H.span_ [HP.class_ "rail-action"] [text "Tags appear as you save bookmarks"] | null (mTags m)]
            )
        ]

filterSection :: Model -> View () () Model Action
filterSection m =
    H.section_
        [HP.class_ "rail-section"]
        [ H.h3_ [HP.class_ "rail-title"] [text "Filters"]
        , H.div_
            [HP.class_ "stack"]
            [ H.button_
                [ HP.class_ ("tag-item" <> if mUnreadOnly m then " active" else "")
                , HP.type_ "button"
                , HE.onClick UnreadToggled
                ]
                [H.span_ [HP.class_ "tag-name"] [text "Unread only"]]
            , H.label_
                [HP.class_ "field"]
                [ H.span_ [HP.class_ "field-label"] [text "Sort by"]
                , H.select_ [HP.class_ "select", HE.onChange (\raw -> SortSelected (fromMisoString raw :: Text))] (sortOptions m)
                ]
            ]
        ]
  where
    sortOptions m' =
        [ H.option_ [HP.value_ "created", HP.selected_ (mSort m' == "created")] [text "Saved date"]
        , H.option_ [HP.value_ "added", HP.selected_ (mSort m' == "added")] [text "Added date"]
        , H.option_ [HP.value_ "opened", HP.selected_ (mSort m' == "opened")] [text "Last opened"]
        ]

-- ---------------------------------------------------------------- modals --

addModal :: Model -> View () () Model Action
addModal m =
    H.div_
        [HP.class_ "overlay", HE.onClick AddClose]
        [ H.form_
            [HP.class_ "modal", HE.onClickWithOptions stopPropagation Noop, HE.onSubmit AddSubmit]
            [ H.div_
                [HP.class_ "modal-head"]
                [ text "Add bookmark"
                , iconBtn iPlus "Close" AddClose
                ]
            , H.div_
                [HP.class_ "modal-body"]
                [ H.label_
                    [HP.class_ "field"]
                    [ H.span_ [HP.class_ "field-label"] [text "URL"]
                    , H.input_
                        [ HP.id_ "add-url"
                        , HP.class_ "input"
                        , HP.type_ "url"
                        , HP.placeholder_ "https://example.com/article"
                        , HP.value_ (mAddUrl m)
                        , HP.autocomplete_ "off"
                        , HE.onInput AddUrlInput
                        ]
                    ]
                , H.label_
                    [HP.class_ "field"]
                    [ H.span_ [HP.class_ "field-label"] [text "Title (optional)"]
                    , H.input_
                        [ HP.class_ "input"
                        , HP.type_ "text"
                        , HP.placeholder_ "Leave empty to use the page title"
                        , HP.value_ (mAddTitle m)
                        , HE.onInput AddTitleInput
                        ]
                    ]
                , H.label_
                    [HP.class_ "field"]
                    [ H.span_ [HP.class_ "field-label"] [text "Tags (comma separated)"]
                    , H.input_
                        [ HP.class_ "input"
                        , HP.type_ "text"
                        , HP.placeholder_ "reading, haskell, ai"
                        , HP.value_ (mAddTags m)
                        , HE.onInput AddTagsInput
                        ]
                    ]
                , case mAddError m of
                    Nothing -> H.div_ [] []
                    Just message -> H.p_ [HP.class_ "field-error"] [text message]
                ]
            , H.div_
                [HP.class_ "modal-foot"]
                [ btn "btn-ghost" [HE.onClick AddClose] [text "Cancel"]
                , btn
                    "btn-primary"
                    ([HE.onClick AddSubmit] ++ disabledAttr (mAddBusy m))
                    [text (if mAddBusy m then "Saving…" else "Add bookmark")]
                ]
            ]
        ]

paletteView :: Model -> View () () Model Action
paletteView m =
    H.div_
        [HP.class_ "overlay top", HE.onClick PaletteClose]
        [ H.div_
            [HP.class_ "palette", HE.onClickWithOptions stopPropagation Noop]
            [ H.input_
                [ HP.id_ "palette-input"
                , HP.class_ "palette-input"
                , HP.type_ "text"
                , HP.placeholder_ "Jump to a page, run a command, open a bookmark…"
                , HP.value_ (mPaletteQ m)
                , HP.autocomplete_ "off"
                , HE.onInput PaletteInput
                ]
            , H.div_
                [HP.class_ "palette-list"]
                ( [ H.div_ [HP.class_ "palette-group"] [text "Commands"]
                  ]
                    ++ map (paletteItem m) (zip [0 ..] (paletteEntries m))
                )
            , H.div_
                [HP.class_ "palette-foot"]
                [ H.span_ [HP.class_ "kbd"] [text "↑"]
                , H.span_ [HP.class_ "kbd"] [text "↓"]
                , text "navigate"
                , H.span_ [HP.class_ "kbd"] [text "↵"]
                , text "run"
                , H.span_ [HP.class_ "kbd"] [text "esc"]
                , text "close"
                ]
            ]
        ]

paletteItem :: Model -> (Int, (MisoString, MisoString, Action)) -> View () () Model Action
paletteItem m (index, (label, hint, _)) =
    H.button_
        [ HP.class_ ("palette-item" <> if index == mPaletteSel m then " active" else "")
        , HP.type_ "button"
        , HE.onClick (PaletteChoose index)
        ]
        [ H.span_ [HP.class_ "palette-label"] [text label]
        , H.span_ [HP.class_ "palette-meta"] [text hint]
        ]

guardModal :: Model -> View () () Model Action
guardModal _m =
    H.div_
        [HP.class_ "overlay"]
        [ H.div_
            [HP.class_ "modal"]
            [ H.div_ [HP.class_ "modal-head"] [text "Unsaved changes"]
            , H.div_
                [HP.class_ "modal-body"]
                [ H.p_
                    []
                    [text "Your note or title edits have not been saved yet. Leave anyway?"]
                ]
            , H.div_
                [HP.class_ "modal-foot"]
                [ btn "btn-ghost" [HE.onClick DirtyGuardClose] [text "Keep editing"]
                , btn "btn-primary" [HE.onClick DirtyGuardDiscard] [text "Discard and leave"]
                ]
            ]
        ]

toastsView :: Model -> View () () Model Action
toastsView m =
    H.div_
        [HP.class_ "toasts", HP.aria_ "live" "polite"]
        (map toastView (mToasts m))

-- | Small fixed banner shown while navigator.onLine is false.
offlineBanner :: View () () Model Action
offlineBanner =
    H.div_
        [HP.class_ "offline-banner", HP.role_ "status", HP.aria_ "live" "polite"]
        [text "Offline: showing the app shell. Connect to sync."]

toastView :: Toast -> View () () Model Action
toastView toast =
    H.div_
        [HP.class_ ("toast " <> toastKindClass (toastKind toast))]
        [ H.span_ [] [text (toastMessage toast)]
        , H.button_
            [HP.class_ "toast-x", HP.type_ "button", HP.aria_ "label" "Dismiss", HE.onClick (ToastDismiss (toastId toast))]
            [text "×"]
        ]

toastKindClass :: ToastKind -> MisoString
toastKindClass kind = case kind of
    ToastOk -> "toast-ok"
    ToastError -> "toast-error"
    ToastInfo -> ""

importInput :: View () () Model Action
importInput =
    H.input_
        [ HP.id_ "import-file"
        , HP.class_ "sr-only"
        , HP.type_ "file"
        , HP.accept_ ".html,text/html"
        , HE.onChange (\_ -> ImportFileChosen)
        ]

-- ------------------------------------------------------------- not found --

notFoundPage :: View () () Model Action
notFoundPage =
    H.div_
        [HP.class_ "notfound"]
        [ H.div_ [HP.class_ "notfound-code"] [text "404"]
        , H.h2_ [] [text "This page does not exist"]
        , H.p_ [HP.class_ "muted"] [text "The link may be stale, or the route is not part of this build yet."]
        , btn "btn-primary" [HE.onClick (Navigate Index)] [text "Back to the library"]
        ]
