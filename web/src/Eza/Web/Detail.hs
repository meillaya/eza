{- | Bookmark detail: editable title, reader column, markdown notes with
wikilink autocomplete, tag editing, backlinks, and the save/dirty guard.
-}
module Eza.Web.Detail (detailPage) where

import Data.List (sortOn)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Miso
import qualified Miso.Html as H
import qualified Miso.Html.Event as HE
import qualified Miso.Html.Property as HP
import Text.Read (readMaybe)

import Eza.Types (
    Backlink (..),
    BookmarkDetail (..),
    BookmarkSummary (..),
    Highlight (..),
 )
import Eza.Web.Markdown (renderMarkdown)
import Eza.Web.Model
import Eza.Web.Types (ReaderSelection (..), ShareView (..))
import Eza.Web.Widgets

detailPage :: Model -> View () () Model Action
detailPage m = case mDetail m of
    Nothing
        | mDetailLoading m ->
            H.main_
                [HP.class_ "layout full"]
                [H.div_ [HP.class_ "content"] [spinnerRow "Loading bookmark…"]]
        | otherwise ->
            H.main_
                [HP.class_ "layout full"]
                [ H.div_
                    [HP.class_ "content"]
                    [ emptyState
                        "🔗"
                        "That bookmark could not be loaded"
                        [ H.p_ [] [text "It may have been deleted, or the server is unavailable."]
                        , btn "btn-primary" [HE.onClick (Navigate Index)] [text "Back to the library"]
                        ]
                    ]
                ]
    Just detail ->
        H.main_
            [HP.class_ "layout full"]
            [ H.div_
                [HP.class_ "content detail"]
                [ hero m detail
                , H.div_
                    [HP.class_ "detail-columns"]
                    [ readerPanel m detail
                    , notesPanel m detail
                    ]
                , backlinksPanel m
                , H.div_ [HP.class_ "row"] [btnGhost "← Back to library" (Navigate Index)]
                , highlightNoteModal m
                , highlightEditModal m
                , shareDialog m detail
                , snapshotModal m detail
                ]
            ]

hero :: Model -> BookmarkDetail -> View () () Model Action
hero m detail =
    H.section_
        [HP.class_ "detail-hero"]
        [ H.input_
            [ HP.class_ "detail-title-input"
            , HP.aria_ "label" "Bookmark title"
            , HP.value_ (mEditTitle m)
            , HP.placeholder_ "Untitled bookmark"
            , HE.onInput TitleInput
            ]
        , H.div_
            [HP.class_ "detail-url"]
            [ H.a_
                [HP.href_ (ms (bdUrl detail)), HP.target_ "_blank", HP.rel_ "noopener noreferrer"]
                [text (ms (bdUrl detail))]
            , H.a_
                [ HP.class_ "linklike"
                , HP.href_ (ms (bdUrl detail))
                , HP.target_ "_blank"
                , HP.rel_ "noopener noreferrer"
                , HP.title_ "Open in a new tab"
                ]
                [icon iExternal]
            ]
        , H.div_
            [HP.class_ "meta-row"]
            ( [ pill "" (ms ("Saved " <> (fromMisoString (formatStamp (bdCreatedAt detail)) :: String)))
              , if bdIsRead detail then pill "ok" "Read" else pill "warn" "Unread"
              ]
                ++ [pill "danger" "Dead link" | bdIsDead detail]
                ++ [pill "" (ms (T.strip (bdAuthor detail))) | not (T.null (T.strip (bdAuthor detail)))]
                ++ [pill "" (ms (T.strip (bdSitename detail))) | not (T.null (T.strip (bdSitename detail)))]
                ++ [pill "" (ms ("lang " <> T.strip (bdLanguage detail))) | not (T.null (T.strip (bdLanguage detail)))]
                ++ [pill "" (ms ("opened " <> (fromMisoString (formatStamp t) :: String))) | Just t <- [bdLastOpenedAt detail], t > 0]
                ++ [pill (enrichPillClass detail) label | Just label <- [enrichLabel detail]]
                ++ [ pill "ok" (ms (show (bdReadingTimeMinutes detail) <> " min read"))
                   | bdReadingTimeMinutes detail > 0
                   ]
            )
        , case T.strip (bdEnrichError detail) of
            "" -> H.div_ [] []
            message ->
                H.p_
                    [HP.class_ "enrich-error", HP.role_ "status"]
                    [text (ms ("Enrichment: " <> message))]
        , H.div_
            [HP.class_ "detail-actions"]
            [ H.a_
                [ HP.class_ "btn btn-primary"
                , HP.href_ (ms (bdUrl detail))
                , HP.target_ "_blank"
                , HP.rel_ "noopener noreferrer"
                ]
                [icon iExternal, text "Open"]
            , btn "" [HE.onClick ReadToggled] [text (if bdIsRead detail then "Mark unread" else "Mark read")]
            , btn "" [HE.onClick (OpenGraphAt (bdId detail))] [icon iGraph, text "Graph"]
            , btn "" [HE.onClick (RunBookmarkAction (bdId detail) "enrich")] [text "Enrich"]
            , btn
                (if mDirty m then "btn-primary" else "")
                ([HE.onClick SaveBookmark] <> disabledAttr (not (mDirty m) || mSaving m))
                ( [H.span_ [HP.class_ "dirty-dot"] [] | mDirty m]
                    ++ [text (if mSaving m then "Saving…" else "Save")]
                )
            , btn "" [HE.onClick ShareDialogOpen] [icon iShare, text "Share"]
            , btn "btn-danger" [HE.onClick (DeleteBookmark (bdId detail))] [icon iTrash, text "Delete"]
            , enrichRetryButton detail
            ]
        ]

-- | Human label for the background enrichment state, when it is worth showing.
enrichLabel :: BookmarkDetail -> Maybe MisoString
enrichLabel detail = case T.strip (bdEnrichState detail) of
    "queued" -> Just "Enrichment queued"
    "pending" -> Just "Enrichment queued"
    "running" -> Just "Enriching…"
    "failed" -> Just "Enrichment failed"
    _ -> Nothing

enrichPillClass :: BookmarkDetail -> MisoString
enrichPillClass detail = case T.strip (bdEnrichState detail) of
    "failed" -> "danger"
    "queued" -> "warn"
    "pending" -> "warn"
    "running" -> "warn"
    _ -> ""

-- | Retry enrichment for failed bookmarks; disabled while one is in flight.
enrichRetryButton :: BookmarkDetail -> View () () Model Action
enrichRetryButton detail =
    case T.strip (bdEnrichState detail) of
        "failed" ->
            btn "" [HE.onClick (RetryEnrich (bdId detail))] [icon iRefresh, text "Retry enrich"]
        "queued" ->
            btn "" ([HE.onClick (RetryEnrich (bdId detail))] ++ disabledAttr True) [icon iRefresh, text "Retry enrich"]
        "pending" ->
            btn "" ([HE.onClick (RetryEnrich (bdId detail))] ++ disabledAttr True) [icon iRefresh, text "Retry enrich"]
        "running" ->
            btn "" ([HE.onClick (RetryEnrich (bdId detail))] ++ disabledAttr True) [icon iRefresh, text "Retry enrich"]
        _ -> H.span_ [] []

readerPanel :: Model -> BookmarkDetail -> View () () Model Action
readerPanel m detail =
    panelWithHead
        "Reader"
        ( [ btnSm "Extract" (RunBookmarkAction (bdId detail) "extract")
          , btnSm "Snapshot" (RunBookmarkAction (bdId detail) "snapshot")
          ]
            ++ [ btnSm "View snapshot" SnapshotOpen
               | T.strip (bdSnapshotKind detail) == "file"
               ]
        )
        ( if T.null (T.strip (bdExtractedText detail))
            then
                [ emptyState
                    "📄"
                    "No extracted text yet"
                    [ H.p_ [] [text "Run Extract to pull the readable article text from the page."]
                    , btn "btn-primary" [HE.onClick (RunBookmarkAction (bdId detail) "extract")] [text "Extract now"]
                    ]
                ]
            else
                [ highlightToolbar m
                , H.div_
                    [ HP.id_ "reader-text"
                    , HP.class_ "reader-text"
                    , HE.onMouseUp ReaderMouseUp
                    , HP.aria_ "label" "Extracted article text (select to highlight)"
                    ]
                    (readerHighlighted (bdExtractedText detail) (mHighlights m))
                , highlightsSection m detail
                ]
        )

{- | Render the extracted text with highlight spans.  Ranges whose offsets no
longer match the stored quote (drifted text) are skipped rather than
corrupting the reader.
-}
readerHighlighted :: Text -> [Highlight] -> [View () () Model Action]
readerHighlighted body highlights = go 0 (sortedHighlights body highlights)
  where
    total = T.length body
    go cursor [] = [H.span_ [] [text (ms (T.drop cursor body))] | cursor < total]
    go cursor (highlight : rest)
        | start < cursor = go cursor rest
        | otherwise =
            [ H.span_ [] [text (ms (T.take (start - cursor) (T.drop cursor body)))]
            | start > cursor
            ]
                ++ [ H.span_
                        [ HP.class_ ("hl hl-" <> highlightColorClass (hColor highlight))
                        , HP.title_ (ms (highlightTitle highlight))
                        , HE.onClick (HighlightEditStart (hId highlight))
                        ]
                        [text (ms matched)]
                   ]
                ++ go (start + T.length matched) rest
      where
        start = hStartOffset highlight
        end = hEndOffset highlight
        matched = T.take (max 0 (end - start)) (T.drop start body)

highlightTitle :: Highlight -> String
highlightTitle highlight
    | T.null (T.strip (hNote highlight)) = "Highlight — click to edit"
    | otherwise = "Highlight: " <> T.unpack (hNote highlight)

{- | Valid + sorted highlights for a text (start offset inside bounds and the
stored quote still matching at those offsets).
-}
sortedHighlights :: Text -> [Highlight] -> [Highlight]
sortedHighlights text =
    sortOn hStartOffset . filter matches
  where
    total = T.length text
    matches highlight =
        let start = hStartOffset highlight
            end = hEndOffset highlight
            quote = hQuote highlight
         in start >= 0
                && end > start
                && end <= total
                && not (T.null (T.strip quote))
                && T.take (end - start) (T.drop start text) == quote

highlightColorClass :: Text -> MisoString
highlightColorClass color = case T.toLower (T.strip color) of
    "green" -> "green"
    "blue" -> "blue"
    "pink" -> "pink"
    "purple" -> "purple"
    _ -> "yellow"

-- | Small toolbar shown after selecting reader text.
highlightToolbar :: Model -> View () () Model Action
highlightToolbar m = case mReaderSel m of
    Nothing -> H.span_ [] []
    Just selection ->
        H.div_
            [HP.class_ "highlight-toolbar", HP.role_ "toolbar", HP.aria_ "label" "Highlight actions"]
            [ H.span_ [HP.class_ "highlight-quote"] [text (ms (truncateQuote 80 (rsQuote selection)))]
            , H.div_
                [HP.class_ "highlight-actions"]
                [ btn "btn-primary btn-sm" [HE.onClick HighlightCreateQuick] [icon iCheck, text "Highlight"]
                , btn "btn-sm" [HE.onClick HighlightNoteOpen] [text "Note"]
                , H.button_
                    [ HP.class_ "icon-btn"
                    , HP.type_ "button"
                    , HP.title_ "Cancel selection"
                    , HP.aria_ "label" "Cancel selection"
                    , HE.onClick ReaderSelectionClear
                    ]
                    [text "×"]
                ]
            ]

truncateQuote :: Int -> Text -> Text
truncateQuote limit quote
    | T.length quote <= limit = quote
    | otherwise = T.take (limit - 1) quote <> "…"

-- | The list of highlights below the reader (edit note / delete).
highlightsSection :: Model -> BookmarkDetail -> View () () Model Action
highlightsSection m _detail =
    H.div_
        [HP.class_ "highlights"]
        ( [ H.div_
                [HP.class_ "highlights-head"]
                [ H.span_ [HP.class_ "panel-title"] [text (ms ("Highlights (" <> show (length (mHighlights m)) <> ")"))]
                , H.span_ [HP.class_ "muted"] [text "Select text above to add one."]
                ]
          ]
            ++ [ H.div_ [HP.class_ "highlight-row"] (highlightRow m highlight)
               | highlight <- sortOn hStartOffset (mHighlights m)
               ]
            ++ [ H.p_ [HP.class_ "muted"] [text "No highlights yet for this bookmark."]
               | null (mHighlights m)
               ]
            ++ [spinnerRow "Loading highlights…" | mHighlightsLoading m && null (mHighlights m)]
        )

highlightRow :: Model -> Highlight -> [View () () Model Action]
highlightRow m highlight =
    [ H.span_
        [HP.class_ ("highlight-dot highlight-dot-" <> highlightColorClass (hColor highlight))]
        []
    , H.div_
        [HP.class_ "highlight-body"]
        [ H.div_ [HP.class_ "highlight-quote"] [text (ms (truncateQuote 160 (hQuote highlight)))]
        , if T.null (T.strip (hNote highlight))
            then H.span_ [] []
            else H.div_ [HP.class_ "highlight-note"] [text (ms (hNote highlight))]
        ]
    , H.div_
        [HP.class_ "row"]
        [ iconBtn iRefresh "Edit highlight" (HighlightEditStart (hId highlight))
        , iconBtnDanger iTrash "Delete highlight" (HighlightDelete (hId highlight))
        ]
    ]

-- | Modal to create a highlight with a note.
highlightNoteModal :: Model -> View () () Model Action
highlightNoteModal m =
    if not (mHighlightNoteOpen m)
        then H.span_ [] []
        else
            H.div_
                [HP.class_ "overlay", HE.onClick HighlightNoteCancel]
                [ H.div_
                    [HP.class_ "modal", HE.onClickWithOptions stopPropagation Noop]
                    [ H.div_ [HP.class_ "modal-head"] [text "Add a note to the highlight"]
                    , H.div_
                        [HP.class_ "modal-body"]
                        [ H.label_
                            [HP.class_ "field"]
                            [ H.span_ [HP.class_ "field-label"] [text "Note"]
                            , H.textarea_
                                [ HP.id_ "highlight-note"
                                , HP.class_ "textarea"
                                , HP.value_ (mHighlightNote m)
                                , HE.onInput HighlightNoteInput
                                ]
                            ]
                        ]
                    , H.div_
                        [HP.class_ "modal-foot"]
                        [ btn "btn-ghost" [HE.onClick HighlightNoteCancel] [text "Cancel"]
                        , btn "btn-primary" [HE.onClick HighlightNoteSubmit] [text "Save highlight"]
                        ]
                    ]
                ]

-- | Modal to edit a highlight's note and colour.
highlightEditModal :: Model -> View () () Model Action
highlightEditModal m = case mHighlightEdit m of
    Nothing -> H.span_ [] []
    Just _ ->
        H.div_
            [HP.class_ "overlay", HE.onClick HighlightEditCancel]
            [ H.div_
                [HP.class_ "modal", HE.onClickWithOptions stopPropagation Noop]
                [ H.div_ [HP.class_ "modal-head"] [text "Edit highlight"]
                , H.div_
                    [HP.class_ "modal-body"]
                    [ H.label_
                        [HP.class_ "field"]
                        [ H.span_ [HP.class_ "field-label"] [text "Note"]
                        , H.textarea_
                            [ HP.id_ "highlight-edit-note"
                            , HP.class_ "textarea"
                            , HP.value_ (mHighlightEditNote m)
                            , HE.onInput HighlightEditInput
                            ]
                        ]
                    , H.div_
                        [HP.class_ "field"]
                        [ H.span_ [HP.class_ "field-label"] [text "Colour"]
                        , H.div_ [HP.class_ "color-row"] (map colorSwatch highlightColors)
                        ]
                    ]
                , H.div_
                    [HP.class_ "modal-foot"]
                    [ btn "btn-ghost" [HE.onClick HighlightEditCancel] [text "Cancel"]
                    , btn "btn-primary" [HE.onClick HighlightEditSave] [text "Save changes"]
                    ]
                ]
            ]
  where
    colorSwatch color =
        H.button_
            [ HP.class_
                ( "color-swatch"
                    <> " swatch-"
                    <> ms color
                    <> (if mHighlightEditColor m == color then " active" else "")
                )
            , HP.type_ "button"
            , HP.title_ (ms ("Set " <> color <> " colour"))
            , HP.aria_ "label" (ms ("Set " <> color <> " colour"))
            , HE.onClick (HighlightEditColor color)
            ]
            []

{- | Share dialog for the current bookmark: fixed bookmark scope, include-note
toggle, expiry select, create + copy URL, and revoke existing links.
-}
shareDialog :: Model -> BookmarkDetail -> View () () Model Action
shareDialog m detail =
    if not (mShareDialogOpen m)
        then H.span_ [] []
        else
            H.div_
                [HP.class_ "overlay", HE.onClick ShareDialogClose]
                [ H.div_
                    [HP.class_ "modal", HE.onClickWithOptions stopPropagation Noop]
                    [ H.div_ [HP.class_ "modal-head"] [text "Share this bookmark"]
                    , H.div_
                        [HP.class_ "modal-body"]
                        ( [ H.p_
                                [HP.class_ "muted"]
                                [text "Anyone with the link can read a read-only copy. Links expire; you can revoke them at any time."]
                          , H.label_
                                [HP.class_ "share-option"]
                                [ H.input_
                                    [ HP.type_ "checkbox"
                                    , HP.checked_ (mShareIncludeNote m)
                                    , HE.onClick ShareIncludeNoteToggle
                                    ]
                                , text "Include my note"
                                ]
                          , H.label_
                                [HP.class_ "field"]
                                [ H.span_ [HP.class_ "field-label"] [text "Expires in"]
                                , H.select_
                                    [ HP.class_ "select"
                                    , HE.onChange
                                        (\raw -> ShareExpirySelected (fromMaybe 30 (readMaybe (fromMisoString raw))))
                                    ]
                                    (map expiryOption [1, 7, 30, 90, 365])
                                ]
                          , btn
                                "btn-primary"
                                ([HE.onClick ShareCreate] <> disabledAttr (mShareBusy m))
                                [text (if mShareBusy m then "Creating…" else "Create share link")]
                          ]
                            ++ [ H.div_
                                    [HP.class_ "share-reveal", HP.role_ "status"]
                                    [ H.div_ [HP.class_ "token-reveal-title"] [text "Public link — copy it now"]
                                    , H.pre_ [HP.class_ "token-secret"] [H.code_ [] [text (ms url)]]
                                    , H.div_
                                        [HP.class_ "row-wrap"]
                                        [ btn "btn-primary" [HE.onClick (ShareCopy url)] [text "Copy link"]
                                        , H.a_
                                            [HP.class_ "btn", HP.href_ (ms url), HP.target_ "_blank", HP.rel_ "noopener noreferrer"]
                                            [text "Open"]
                                        ]
                                    ]
                               | Just url <- [mShareUrl m]
                               ]
                        )
                    , H.div_
                        [HP.class_ "divider"]
                        []
                    , H.div_
                        [HP.class_ "modal-body"]
                        [ H.h3_ [HP.class_ "panel-title"] [text "Existing links for this bookmark"]
                        , H.div_ [HP.class_ "stack"] (map shareRow (bookmarkShares m detail))
                        , H.p_
                            [HP.class_ "muted"]
                            [ text "Revoked links stop working immediately."
                            | null (bookmarkShares m detail)
                            ]
                        ]
                    , H.div_
                        [HP.class_ "modal-foot"]
                        [ btn "btn-ghost" [HE.onClick ShareDialogClose] [text "Close"]
                        ]
                    ]
                ]
  where
    expiryOption days =
        H.option_
            [HP.value_ (ms (show days)), HP.selected_ (mShareExpiryDays m == days)]
            [text (ms (show days <> " days"))]

bookmarkShares :: Model -> BookmarkDetail -> [ShareView]
bookmarkShares m detail =
    [ share
    | share <- mShares m
    , svScope share == "bookmark"
    , svTargetId share == bdId detail
    , isJust (svRevokedAt share) == False
    ]

shareRow :: ShareView -> View () () Model Action
shareRow share =
    H.div_
        [HP.class_ "share-row"]
        [ H.span_ [HP.class_ "mono"] [text (ms (svPrefix share))]
        , H.span_
            [HP.class_ "muted"]
            [ text
                ( ms
                    ( "expires "
                        <> (fromMisoString (formatStamp (svExpiresAt share)) :: String)
                        <> (if svIncludeNote share then " · includes note" else "")
                    )
                )
            ]
        , btnSm "Revoke" (ShareRevoke (svId share))
        ]

-- | Sandboxed iframe preview of a locally captured snapshot.
snapshotModal :: Model -> BookmarkDetail -> View () () Model Action
snapshotModal m detail =
    if not (mSnapshotOpen m)
        then H.span_ [] []
        else
            H.div_
                [HP.class_ "overlay", HE.onClick SnapshotClose]
                [ H.div_
                    [HP.class_ "modal wide", HE.onClickWithOptions stopPropagation Noop]
                    [ H.div_
                        [HP.class_ "modal-head"]
                        [ text "Snapshot"
                        , H.span_ [HP.class_ "spacer"] []
                        , H.a_
                            [ HP.class_ "btn btn-sm"
                            , HP.href_ (ms ("/api/v1/bookmarks/" <> show (bdId detail) <> "/snapshot"))
                            , HP.target_ "_blank"
                            , HP.rel_ "noopener noreferrer"
                            ]
                            [text "Open in new tab"]
                        , iconBtn iPlus "Close snapshot" SnapshotClose
                        ]
                    , H.div_
                        [HP.class_ "modal-body flush"]
                        [ H.iframe_
                            [ HP.class_ "snapshot-frame"
                            , HP.src_ (ms ("/api/v1/bookmarks/" <> show (bdId detail) <> "/snapshot"))
                            , HP.title_ "Saved snapshot"
                            , HP.sandbox_ ""
                            ]
                            []
                        ]
                    ]
                ]

highlightColors :: [Text]
highlightColors = ["yellow", "green", "blue", "pink", "purple"]

notesPanel :: Model -> BookmarkDetail -> View () () Model Action
notesPanel m _detail =
    panelWithHead
        "Notes"
        [ H.div_
            [HP.class_ "seg"]
            [ segBtn (mNoteMode m == NoteWrite) "Write" (NoteModeChanged NoteWrite)
            , segBtn (mNoteMode m == NotePreview) "Preview" (NoteModeChanged NotePreview)
            ]
        ]
        [ case mNoteMode m of
            NoteWrite ->
                H.div_
                    [HP.class_ "note-editor-wrap"]
                    ( [ H.textarea_
                            [ HP.id_ "note-editor"
                            , HP.class_ "note-editor"
                            , HP.placeholder_ "Write in markdown. Type [[ to link another bookmark."
                            , HP.value_ (mEditNote m)
                            , HE.onInputWith NoteChanged
                            ]
                      ]
                        ++ [linkSuggest m | isJust' (mLinkQuery m)]
                    )
            NotePreview ->
                H.div_
                    [HP.class_ "markdown"]
                    ( if T.null (T.strip (fromMisoString (mEditNote m)))
                        then [H.p_ [HP.class_ "muted"] [text "Nothing here yet — switch to Write to add a note."]]
                        else renderMarkdown (fromMisoString (mEditNote m))
                    )
        , H.div_ [HP.class_ "divider"] []
        , H.div_
            [HP.class_ "row-wrap"]
            [ H.span_ [HP.class_ "tag-chip"] [text (ms tag)]
            | tag <- mEditTags m
            ]
        , H.div_
            [HP.class_ "row"]
            [ H.input_
                [ HP.class_ "input"
                , HP.placeholder_ "Add a tag and press Enter"
                , HP.value_ (mNewTag m)
                , HE.onInput TagDraftInput
                , HE.onKeyDown (\code -> if keyCodeToInt code == 13 then TagAdd else Noop)
                ]
            , btnSm "Add tag" TagAdd
            ]
        , H.div_ [HP.class_ "divider"] []
        , H.div_
            [HP.class_ "note-foot"]
            [ H.span_ [HP.class_ "muted"] [text "Saving also stores tags and the read state."]
            , H.span_ [HP.class_ "spacer"] []
            , H.span_ [HP.class_ "kbd"] [text "Ctrl/⌘ S"]
            , btn
                (if mDirty m then "btn-primary" else "")
                ([HE.onClick SaveBookmark] <> disabledAttr (not (mDirty m) || mSaving m))
                [text (if mSaving m then "Saving…" else "Save")]
            ]
        ]
  where
    isJust' (Just _) = True
    isJust' Nothing = False

linkSuggest :: Model -> View () () Model Action
linkSuggest m =
    H.div_
        [HP.class_ "link-suggest"]
        ( H.div_ [HP.class_ "link-suggest-head"] [text "Link a bookmark"]
            : [ H.button_
                    [ HP.class_ ("link-suggest-item" <> if index == mLinkSel m then " active" else "")
                    , HP.type_ "button"
                    , HE.onClick (LinkChoose index)
                    ]
                    [ H.span_ [] [text (ms (bsTitle bookmark))]
                    , H.span_ [HP.class_ "muted"] [text (ms (bsDomain bookmark))]
                    ]
              | (index, bookmark) <- zip [0 ..] (mLinkResults m)
              ]
        )

backlinksPanel :: Model -> View () () Model Action
backlinksPanel m =
    panelWithHead
        "Backlinks"
        [H.span_ [HP.class_ "pill"] [text (ms (show (length (mBacklinks m)) <> " references"))]]
        ( [ H.div_ [HP.class_ "backlinks"] (map backlinkView (mBacklinks m))
          ]
            ++ [emptyState "🔗" "No references yet" [H.p_ [] [text "Notes that link here with [[wikilinks]] will appear in this list."]] | null (mBacklinks m)]
        )

backlinkView :: Backlink -> View () () Model Action
backlinkView link =
    H.div_
        [HP.class_ "backlink"]
        [ H.div_
            [HP.class_ "row"]
            [ H.button_
                [HP.class_ "linklike backlink-title", HP.type_ "button", HE.onClick (Navigate (Bookmark (blSourceId link)))]
                [text (ms (blSourceTitle link))]
            , H.span_ [HP.class_ "spacer"] []
            , if blResolved link then pill "ok" "linked" else pill "" "unlinked"
            ]
        , H.div_ [HP.class_ "backlink-snippet"] [text (ms (blSnippet link))]
        , H.div_
            [HP.class_ "backlink-meta"]
            [ H.span_ [HP.class_ "muted"] [text (maybe "" (\line -> ms ("line " <> show line)) (blLine link))]
            , H.button_ [HP.class_ "linklike", HP.type_ "button", HE.onClick (Navigate (Bookmark (blSourceId link)))] [text "Open source"]
            ]
        ]

keyCodeToInt :: KeyCode -> Int
keyCodeToInt (KeyCode n) = n

_unusedDetailFields :: BookmarkSummary -> Text
_unusedDetailFields = bsTitle
