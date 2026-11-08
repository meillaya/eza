{- | Bookmark record: the reading spread, the catalogue record card, the note
editor, the share slip, the highlight dialogs and the snapshot viewer.
The markup follows the Direction B design package.
-}
module Eza.Web.Detail (detailPage) where

import Data.List (find, sortOn)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Miso
import qualified Miso.CSS as C
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
import Eza.Web.Widgets (disabledAttr)

-- ------------------------------------------------------------------ page --

detailPage :: Model -> View () () Model Action
detailPage m =
    H.div_
        [HP.class_ "detail-scroll"]
        [H.div_ [HP.class_ "detail"] (pageBody m)]

pageBody :: Model -> [View () () Model Action]
pageBody m = case mDetail m of
    Nothing
        | mDetailLoading m -> [loadingView]
        | otherwise -> [failedView m]
    Just detail -> recordPage m detail

loadingView :: View () () Model Action
loadingView =
    H.div_
        [HP.class_ "empty"]
        [ H.span_ [HP.class_ "empty-kicker sc"] [text "reading"]
        , H.h1_ [HP.class_ "empty-title"] [text "Opening the record."]
        , H.p_
            [HP.class_ "empty-body"]
            [text "The record is being read from the server."]
        , H.div_
            [HP.class_ "empty-lines", HP.aria_ "hidden" "true"]
            (replicate 4 (H.i_ [] []))
        ]

failedView :: Model -> View () () Model Action
failedView m =
    H.div_
        [HP.class_ "empty"]
        [ H.span_ [HP.class_ "empty-kicker sc"] [text "record unavailable"]
        , H.h1_ [HP.class_ "empty-title"] [text "This record could not be opened."]
        , H.p_
            [HP.class_ "empty-body"]
            [ text
                "It may have been deleted, or the server did not answer. The rest of the ledger is still here."
            ]
        , H.p_
            [HP.class_ "ledg-error-code mono"]
            [text (fromMaybe "the record request failed" (mDetailError m))]
        , H.p_
            [HP.class_ "empty-try"]
            ( H.button_
                [HP.class_ "btn btn--strong", HE.onClick (Navigate Index)]
                [text "back to the library"]
                : retryButton m
            )
        , H.div_
            [HP.class_ "empty-lines", HP.aria_ "hidden" "true"]
            (replicate 3 (H.i_ [] []))
        ]

retryButton :: Model -> [View () () Model Action]
retryButton m = case mRoute m of
    Bookmark bid ->
        [H.button_ [HP.class_ "btn", HE.onClick (DetailReload bid)] [text "try again"]]
    _ -> []

recordPage :: Model -> BookmarkDetail -> [View () () Model Action]
recordPage m detail =
    [ H.div_
        [ HP.classList_
            [ ("detail-record", True)
            , ("is-read", bdIsRead detail)
            ]
        , HP.data_ "testid" "record"
        , HP.data_ "bookmark-id" (ms (show (bdId detail)))
        ]
        ( [recordTop detail, recordHead m detail]
            ++ [deadBanner | bdIsDead detail]
            ++ [ H.div_
                    [HP.class_ "detail-grid"]
                    [ H.div_
                        [HP.class_ "detail-main"]
                        (readingColumn m detail ++ [noteEditor m detail])
                    , H.div_
                        [HP.class_ "detail-aside"]
                        (recordCard m detail)
                    ]
               ]
        )
    ]
        ++ shareSlip m detail
        ++ highlightNoteDialog m
        ++ highlightEditDialog m
        ++ [snapshotDialog m detail]
        ++ [deleteDialog m detail]

-- ------------------------------------------------------------------ head --

recordTop :: BookmarkDetail -> View () () Model Action
recordTop detail =
    H.div_
        []
        [ H.div_
            [HP.class_ "detail-top"]
            [ H.button_
                [HP.class_ "detail-back", HE.onClick (Navigate Index)]
                [ H.span_
                    [HP.class_ "detail-back-arr", HP.aria_ "hidden" "true"]
                    [text "←"]
                , text "the ledger"
                ]
            , H.span_
                [HP.class_ "detail-acc"]
                [text (accession (bdId detail))]
            ]
        , H.div_ [HP.class_ "detail-toprule", HP.aria_ "hidden" "true"] []
        ]

recordHead :: Model -> BookmarkDetail -> View () () Model Action
recordHead m detail =
    H.header_
        [HP.class_ "detail-head"]
        [ H.h1_
            [HP.class_ "detail-title"]
            [text (displayTitle m detail)]
        , metaLine detail
        , tagsRow m
        , actionsLine detail
        ]

displayTitle :: Model -> BookmarkDetail -> MisoString
displayTitle m detail
    | T.null (T.strip (prose (mEditTitle m))) = ms (bdTitle detail)
    | otherwise = mEditTitle m

metaLine :: BookmarkDetail -> View () () Model Action
metaLine detail =
    H.p_
        [HP.class_ "detail-meta"]
        (interleaveSep (map spanText items ++ readSpans))
  where
    items :: [MisoString]
    items =
        filter (not . T.null . T.strip . prose) $
            [ ms (bdAuthor detail)
            , ms (bdDomain detail)
            , ms ("filed " <> prose (formatFiled (bdCreatedAt detail)))
            ]
                ++ [ ms (show (bdReadingTimeMinutes detail) <> " min")
                   | bdReadingTimeMinutes detail > 0
                   ]
    readSpans =
        [ H.span_
            []
            [ H.span_ [HP.class_ "detail-readmark read-word-yes"] [text "read"]
            , H.span_ [HP.class_ "detail-readmark read-word-no"] [text "unread"]
            ]
        ]

interleaveSep :: [View () () Model Action] -> [View () () Model Action]
interleaveSep [] = []
interleaveSep [one] = [one]
interleaveSep (one : rest) = one : sepSpan : interleaveSep rest

sepSpan :: View () () Model Action
sepSpan = H.span_ [HP.class_ "detail-sep", HP.aria_ "hidden" "true"] []

spanText :: MisoString -> View () () Model Action
spanText value = H.span_ [] [text value]

tagsRow :: Model -> View () () Model Action
tagsRow m =
    H.ul_
        [HP.class_ "detail-tags", HP.aria_ "label" "Tags"]
        [ H.li_
            []
            [ H.button_
                [ HP.class_ "detail-tag"
                , HP.type_ "button"
                , HP.title_ "Filter the library by this tag"
                , HE.onClick (FilterByTag tag)
                ]
                [text (ms tag)]
            ]
        | tag <- mEditTags m
        ]

actionsLine :: BookmarkDetail -> View () () Model Action
actionsLine detail =
    H.div_
        [HP.class_ "detail-actions"]
        ( [ H.a_
                [ HP.class_ "btn btn--strong"
                , HP.href_ (ms (bdUrl detail))
                , HP.target_ "_blank"
                , HP.rel_ "noopener noreferrer"
                ]
                [text "open the page"]
          , H.button_
                [HP.class_ "btn detail-act-read", HE.onClick ReadToggled]
                [text "mark read"]
          , H.button_
                [HP.class_ "btn detail-act-unread", HE.onClick ReadToggled]
                [text "mark unread"]
          ]
            ++ enrichAction detail
            ++ [ H.button_
                    [HP.class_ "btn", HE.onClick ShareDialogOpen]
                    [text "share"]
               , H.button_
                    [ HP.class_ "btn btn--danger"
                    , HE.onClick (DeleteBookmarkRequest (bdId detail))
                    ]
                    [text "delete"]
               , H.span_ [HP.class_ "detail-status"] [text (statusText detail)]
               ]
        )

enrichAction :: BookmarkDetail -> [View () () Model Action]
enrichAction detail
    | stringEq (bdEnrichState detail) "queued" =
        [ H.button_
            [ HP.class_ "btn"
            , HP.aria_ "disabled" "true"
            , HP.title_ "extraction is queued"
            ]
            [text "queued"]
        ]
    | stringEq (bdEnrichState detail) "failed" =
        [ H.button_
            [HP.class_ "btn", HE.onClick (RetryEnrich (bdId detail))]
            [text "extract again"]
        ]
    | hasText detail =
        [ H.button_
            [ HP.class_ "btn"
            , HE.onClick (RunBookmarkAction (bdId detail) "extract")
            ]
            [text "extract again"]
        ]
    | otherwise =
        [ H.button_
            [ HP.class_ "btn"
            , HE.onClick (RunBookmarkAction (bdId detail) "extract")
            ]
            [text "extract text"]
        ]

statusText :: BookmarkDetail -> MisoString
statusText detail
    | hasText detail =
        ms
            ( "text extracted · "
                <> paragraphCount (length (visibleParagraphs (bdExtractedText detail)))
            )
    | stringEq (bdEnrichState detail) "queued" = ms ("queued for extraction" :: MisoString)
    | stringEq (bdEnrichState detail) "failed" = ms ("extraction failed" :: MisoString)
    | otherwise = ms ("nothing lifted yet" :: MisoString)

-- --------------------------------------------------------------- banners --

deadBanner :: View () () Model Action
deadBanner =
    H.div_
        [HP.class_ "detail-dead", C.styleInline_ "display:flex"]
        [ H.span_
            [HP.class_ "detail-dead-mark", HP.aria_ "hidden" "true"]
            [text "!"]
        , H.p_
            [HP.class_ "detail-dead-copy"]
            [ H.strong_ [] [text "This link is marked dead."]
            , text
                " The page no longer answers. The record, its tags, its note and the extracted text are kept; only the link state changed."
            ]
        ]

-- --------------------------------------------------------------- reading --

readingColumn :: Model -> BookmarkDetail -> [View () () Model Action]
readingColumn m detail =
    snapshotCard detail
        ++ [H.article_ [HP.class_ "read-text"] (readHead : readingBody m detail)]
  where
    readHead =
        H.div_
            [HP.class_ "read-head"]
            [ H.span_ [HP.class_ "sc"] [text "Extracted text"]
            , H.span_ [HP.class_ "read-count"] [text (readCount detail)]
            ]

readCount :: BookmarkDetail -> MisoString
readCount detail
    | hasText detail =
        ms
            ( paragraphCount (length (visibleParagraphs (bdExtractedText detail)))
                <> " · "
                <> T.pack (show (bdReadingTimeMinutes detail))
                <> " min"
            )
    | stringEq (bdEnrichState detail) "queued" = ms ("queued" :: MisoString)
    | stringEq (bdEnrichState detail) "failed" = ms ("failed" :: MisoString)
    | otherwise = ms ("nothing lifted" :: MisoString)

readingBody :: Model -> BookmarkDetail -> [View () () Model Action]
readingBody m detail
    | hasText detail =
        paragraphsView (bdExtractedText detail) numbered
            ++ selectionBar m
            ++ marksList detail numbered
            ++ [readingFoot detail]
    | stringEq (bdEnrichState detail) "queued" = queuedBody
    | stringEq (bdEnrichState detail) "failed" = failedBody detail
    | otherwise = noExtractionBody detail
  where
    numbered = numberedHighlights (bdExtractedText detail) (mHighlights m)

paragraphsView :: Text -> [(Int, Highlight)] -> [View () () Model Action]
paragraphsView body numbered =
    [ H.div_
        [ HP.id_ "reader-text"
        , HP.class_ "read-paras reading"
        , HE.onMouseUp ReaderMouseUp
        ]
        (step 0 (paragraphsOf body))
    ]
  where
    dropcapIndex =
        fst
            <$> find
                (\(index, para) -> not (T.null para) && index >= (0 :: Int))
                (zip [0 ..] (map snd (paragraphsOf body)))
    step _ [] = []
    step index ((start, para) : rest) =
        [ H.p_
            (if Just index == dropcapIndex then [HP.class_ "dropcap"] else [])
            (paragraphSegments numbered start para)
        | not (T.null para)
        ]
            ++ [text (ms ("\n\n" :: Text)) | not (null rest)]
            ++ step (index + 1) rest

paragraphSegments ::
    [(Int, Highlight)] ->
    Int ->
    Text ->
    [View () () Model Action]
paragraphSegments numbered start para = step 0 inside
  where
    end = start + T.length para
    inside =
        [ (num, hl)
        | (num, hl) <- numbered
        , hStartOffset hl >= start
        , hStartOffset hl < end
        , hEndOffset hl <= end
        ]
    step cursor hls = case dropWhile (\(_, hl) -> hStartOffset hl - start < cursor) hls of
        [] -> plain (T.drop cursor para)
        ((num, hl) : _) ->
            let markStart = hStartOffset hl - start
                markEnd = hEndOffset hl - start
                before = T.take (markStart - cursor) (T.drop cursor para)
                quoted = T.take (markEnd - markStart) (T.drop markStart para)
             in plain before
                    ++ [ H.mark_
                            [ HP.class_ "read-mark"
                            , HP.data_ "testid" "reader-mark"
                            , HP.data_ "n" (ms (show num))
                            , C.styleInline_ (markCss (hColor hl))
                            , HP.title_ "Edit this highlight"
                            ]
                            [text (ms quoted)]
                       , H.span_
                            [HP.class_ "read-mark-pin", HP.aria_ "hidden" "true"]
                            [text (ms (show num))]
                       ]
                    ++ step markEnd hls
    plain value
        | T.null value = []
        | otherwise = [text (ms value)]

marksList :: BookmarkDetail -> [(Int, Highlight)] -> [View () () Model Action]
marksList detail numbered
    | null numbered = []
    | otherwise =
        [ H.ol_
            [HP.class_ "read-marks", HP.aria_ "label" "Marks in this record"]
            [ H.li_
                [ HP.class_ "read-mark-row"
                , HP.data_ "testid" "highlight-row"
                ]
                [ H.span_ [HP.class_ "read-mark-n"] [text (ms (show num))]
                , H.span_
                    [HP.class_ "read-mark-main"]
                    [ H.span_ [HP.class_ "read-mark-q"] [text (ms (hQuote hl))]
                    , H.button_
                        [ HP.class_ "action"
                        , HP.data_ "testid" "highlight-edit"
                        , HP.type_ "button"
                        , C.styleInline_ "margin-left:12px"
                        , HP.title_ "Edit this highlight"
                        , HE.onClick (HighlightEditStart (hId hl))
                        ]
                        [text "edit"]
                    , H.button_
                        [ HP.class_ "action"
                        , HP.data_ "testid" "highlight-delete"
                        , HP.type_ "button"
                        , C.styleInline_ "margin-left:8px"
                        , HP.title_ "Delete this highlight"
                        , HE.onClick (HighlightDelete (hId hl))
                        ]
                        [text "delete"]
                    ]
                , H.span_
                    [HP.class_ "read-mark-where"]
                    [text (ms ("¶ " <> show (paragraphNumber detail hl)))]
                ]
            | (num, hl) <- numbered
            ]
        ]

paragraphNumber :: BookmarkDetail -> Highlight -> Int
paragraphNumber detail hl =
    length
        [ ()
        | (start, paragraph) <- paragraphsOf (bdExtractedText detail)
        , T.length paragraph > 0
        , start <= hStartOffset hl
        ]

selectionBar :: Model -> [View () () Model Action]
selectionBar m = case mReaderSel m of
    Nothing -> []
    Just selection ->
        [ H.div_
            [ HP.class_ "offline-banner"
            , HP.data_ "testid" "highlight-toolbar"
            ]
            [ H.span_
                [HP.class_ "offline-banner-mark", HP.aria_ "hidden" "true"]
                []
            , H.span_
                [HP.class_ "offline-banner-text"]
                [text (ms ("selected: " <> rsQuote selection))]
            , H.div_
                [HP.class_ "offline-banner-actions"]
                [ H.button_
                    [HP.class_ "btn btn--sm btn--strong", HE.onClick HighlightCreateQuick]
                    [text "highlight"]
                , H.button_
                    [HP.class_ "btn btn--sm", HE.onClick HighlightNoteOpen]
                    [text "note"]
                , H.button_
                    [HP.class_ "btn btn--sm btn--ghost", HE.onClick ReaderSelectionClear]
                    [text "cancel"]
                ]
            ]
        ]

readingFoot :: BookmarkDetail -> View () () Model Action
readingFoot detail =
    H.footer_
        [HP.class_ "read-foot"]
        [ H.p_
            [HP.class_ "read-foot-src"]
            [text "Text lifted from the saved page by the extractor, as stored."]
        , H.p_ [HP.class_ "read-byline"] (bylineViews detail)
        ]

bylineViews :: BookmarkDetail -> [View () () Model Action]
bylineViews detail =
    interleaveDot (map spanText items)
  where
    items :: [MisoString]
    items =
        filter (not . T.null . T.strip . prose) $
            [primary]
                ++ [ ms ("published " <> prose (formatProseDate stamp))
                   | Just stamp <- [bdPublishedAt detail]
                   , stamp > 0
                   ]
    primary
        | T.null (T.strip (bdAuthor detail)) = ms (bdDomain detail)
        | otherwise = ms (bdAuthor detail)

interleaveDot :: [View () () Model Action] -> [View () () Model Action]
interleaveDot [] = []
interleaveDot [one] = [one]
interleaveDot (one : rest) =
    one
        : H.span_ [HP.aria_ "hidden" "true"] [text " · "]
        : interleaveDot rest

noExtractionBody :: BookmarkDetail -> [View () () Model Action]
noExtractionBody detail =
    [ H.div_
        [HP.class_ "noextract"]
        [ H.p_
            [HP.class_ "noextract-lead"]
            [text "No text has been lifted from this page."]
        , H.p_
            [HP.class_ "noextract-body"]
            [ text
                "This is the ordinary case: the record was filed, the page was saved, and the reader is still empty. The title, the source, the date and the tags are enough to find it again."
            ]
        , H.p_
            [HP.class_ "noextract-body"]
            [text "When extraction runs, the text lands here, in the same column as every other reading copy."]
        , H.div_
            [HP.class_ "noextract-lines", HP.aria_ "hidden" "true"]
            (replicate 4 (H.i_ [] []))
        , H.p_
            [HP.class_ "noextract-foot"]
            [ text "reader empty"
            , H.span_ [HP.aria_ "hidden" "true"] [text " / "]
            , text "no snapshot captured"
            ]
        , H.div_
            [HP.class_ "detail-actions"]
            [ H.button_
                [ HP.class_ "btn btn--strong"
                , HE.onClick (RunBookmarkAction (bdId detail) "extract")
                ]
                [text "extract the text"]
            ]
        ]
    ]

queuedBody :: [View () () Model Action]
queuedBody =
    [ H.div_
        [HP.class_ "enrich"]
        [ H.p_ [HP.class_ "enrich-kicker"] [text "Queued for extraction"]
        , H.p_
            [HP.class_ "enrich-title"]
            [text "The page will be fetched and its text lifted."]
        , H.p_
            [HP.class_ "enrich-copy"]
            [ text
                "Extraction runs in the background on the server. Nothing is lost or overwritten while it waits: the record keeps its link, tags and note, and the text lands in this column when the run finishes."
            ]
        , H.div_
            [HP.class_ "enrich-lines", HP.aria_ "hidden" "true"]
            (replicate 3 (H.i_ [] []))
        , H.p_
            [HP.class_ "enrich-foot"]
            [ text "in the queue"
            , H.span_ [HP.aria_ "hidden" "true"] [text " / "]
            , text "not yet running"
            ]
        ]
    ]

failedBody :: BookmarkDetail -> [View () () Model Action]
failedBody detail =
    [ H.div_
        [HP.class_ "enrich"]
        [ H.p_ [HP.class_ "enrich-kicker"] [text "Extraction failed"]
        , H.p_
            [HP.class_ "enrich-title"]
            [text "The extractor could not reach the page."]
        , H.p_
            [HP.class_ "enrich-copy"]
            [ text
                "Nothing was changed. The record, its tags and its note are intact. The text column stays empty until extraction succeeds."
            ]
        , H.p_
            [HP.class_ "enrich-foot"]
            [ text "no text lifted"
            , H.span_ [HP.aria_ "hidden" "true"] [text " / "]
            , text "the record is intact"
            ]
        , H.div_
            [HP.class_ "detail-actions"]
            [ H.button_
                [HP.class_ "btn", HE.onClick (RetryEnrich (bdId detail))]
                [text "extract again"]
            ]
        ]
    ]

-- ------------------------------------------------------------- note editor --

noteEditor :: Model -> BookmarkDetail -> View () () Model Action
noteEditor m detail =
    H.section_
        [HP.class_ "note-editor", HP.aria_ "label" "Note"]
        ( [noteHead]
            ++ [modesRow]
            ++ [bodyViews]
            ++ suggestions m
            ++ [foot]
        )
  where
    noteHead =
        H.div_
            [HP.class_ "read-head"]
            [ H.span_ [HP.class_ "sc"] [text "Note"]
            , H.span_
                [HP.class_ "read-count"]
                [ text
                    ( ms
                        ( prose (accession (bdId detail))
                            <> " · "
                            <> wikilinkText (prose (mEditNote m))
                        )
                    )
                ]
            ]
    modesRow =
        H.div_
            [HP.class_ "noteed-modes"]
            ( [ modeButton NoteWrite "write"
              , modeButton NotePreview "preview"
              ]
                ++ [ H.span_
                        [ HP.class_ "noteed-dirty"
                        , C.styleInline_ "display:inline-flex"
                        ]
                        [H.span_ [HP.class_ "noteed-dirty-dot"] [], text " unsaved changes"]
                   | mDirty m
                   ]
            )
    modeButton mode label =
        H.button_
            [ HP.class_
                ( if mNoteMode m == mode
                    then "noteed-mode is-on"
                    else "noteed-mode"
                )
            , HP.type_ "button"
            , HP.aria_
                "pressed"
                (if mNoteMode m == mode then "true" else "false")
            , HE.onClick (NoteModeChanged mode)
            ]
            [text label]
    bodyViews
        | mNoteMode m == NotePreview =
            H.div_
                [HP.class_ "noteed-wrap is-note-preview"]
                [ H.div_
                    [HP.class_ "noteed-preview"]
                    [ H.div_
                        [ HP.class_ "record noteed-preview-text markdown"
                        , C.styleInline_ "border:0;background:transparent;padding:0;margin:0"
                        ]
                        (previewViews m)
                    ]
                ]
        | otherwise =
            H.div_
                [HP.class_ "noteed-wrap"]
                [ H.textarea_
                    [ HP.id_ "note-editor"
                    , HP.class_ "noteed-area"
                    , HP.aria_ "label" "Note text"
                    , HP.placeholder_ "Write in markdown. Type [[ to link another record."
                    , HP.spellcheck_ False
                    , HP.value_ (mEditNote m)
                    , HE.onInputWith NoteChanged
                    ]
                ]
    previewViews model
        | T.null (T.strip (prose (mEditNote model))) =
            [ H.p_
                [HP.class_ "record-empty"]
                [text "Nothing here yet. Switch to write to add a note."]
            ]
        | otherwise = renderMarkdown (prose (mEditNote model))
    foot =
        H.div_
            [HP.class_ "noteed-foot"]
            [ H.p_
                [HP.class_ "noteed-hint"]
                [ H.kbd_ [] [text "⌘S"]
                , text " saves · "
                , H.kbd_ [] [text "esc"]
                , text " closes · "
                , H.span_ [HP.class_ "mono"] [text "[[title]]"]
                , text " links another record"
                ]
            , H.div_
                [HP.class_ "noteed-buttons"]
                [ H.button_
                    [ HP.class_ "btn"
                    , HP.type_ "button"
                    , HE.onClick (DetailReload (bdId detail))
                    ]
                    [text "cancel"]
                , H.button_
                    ( [ HP.class_ "btn btn--strong"
                      , HP.type_ "button"
                      , HE.onClick SaveBookmark
                      ]
                        ++ disabledAttr (not (mDirty m) || mSaving m)
                    )
                    [text (if mSaving m then "saving..." else "save the note")]
                ]
            ]

suggestions :: Model -> [View () () Model Action]
suggestions m
    | not (isJust (mLinkQuery m)) = []
    | null (mLinkResults m) = []
    | otherwise =
        [ H.div_
            [HP.class_ "record-tags"]
            ( H.span_ [HP.class_ "field-label"] [text "link to"]
                : [ H.button_
                        [ HP.class_
                            ( if index == mLinkSel m
                                then "btn btn--sm btn--strong"
                                else "btn btn--sm"
                            )
                        , HP.type_ "button"
                        , HE.onClick (LinkChoose index)
                        ]
                        [text (ms (bsTitle result))]
                  | (index, result) <- zip [0 ..] (mLinkResults m)
                  ]
            )
        ]

tagRow :: Model -> View () () Model Action
tagRow m =
    H.div_
        [HP.class_ "record-tags", HP.aria_ "label" "Tags"]
        ( [ H.span_
                [HP.class_ "tagpill"]
                [ H.button_
                    [ HP.class_ "tagpill-name"
                    , HP.type_ "button"
                    , HP.title_ "Filter the library by this tag"
                    , HE.onClick (FilterByTag tag)
                    ]
                    [text (ms tag)]
                , H.button_
                    [ HP.class_ "tagpill-remove"
                    , HP.type_ "button"
                    , C.styleInline_ "margin-left:4px;color:var(--muted)"
                    , HP.aria_ "label" ("Remove the tag " <> ms tag)
                    , HP.title_ "Remove this tag"
                    , HE.onClick (TagRemove tag)
                    ]
                    [text "×"]
                ]
          | tag <- mEditTags m
          ]
            ++ [ H.input_
                    [ HP.id_ "new-tag"
                    , HP.class_ "record-tagadd"
                    , C.styleInline_ "width:78px;background:transparent"
                    , HP.value_ (mNewTag m)
                    , HP.placeholder_ "+ tag"
                    , HP.aria_ "label" "Add a tag"
                    , HP.autocomplete_ "off"
                    , HP.spellcheck_ False
                    , HE.onInput TagDraftInput
                    , HE.onKeyDown
                        (\code -> if keyCodeToInt code == 13 then TagAdd else Noop)
                    ]
               ]
        )

-- ------------------------------------------------------------ record card --

recordCard :: Model -> BookmarkDetail -> [View () () Model Action]
recordCard m detail =
    [ H.aside_
        [HP.class_ "record", HP.aria_ "label" "Catalogue record"]
        ( [ H.div_
                [HP.class_ "record-head"]
                [ H.span_ [HP.class_ "sc"] [text "Catalogue record"]
                , H.span_ [HP.class_ "record-no"] [text (accession (bdId detail))]
                ]
          ]
            ++ [ H.span_
                    [ HP.class_ "record-deadmark"
                    , C.styleInline_ "display:block;width:max-content;margin:0 0 12px"
                    ]
                    [text "dead"]
               | bdIsDead detail
               ]
            ++ [ filedStamp detail
               , titleField m detail
               , stampedFields detail
               , tagRow m
               , noteSection m
               , seeSection m detail
               , recordExtras detail
               ]
        )
    ]

filedStamp :: BookmarkDetail -> View () () Model Action
filedStamp detail =
    H.div_
        [HP.class_ "record-stamp"]
        [ H.span_ [HP.class_ "record-stamp-k sc"] [text "filed"]
        , H.span_
            [HP.class_ "record-stamp-d"]
            [text (formatFiled (bdCreatedAt detail))]
        ]

titleField :: Model -> BookmarkDetail -> View () () Model Action
titleField m detail =
    H.div_
        [HP.class_ "record-sec"]
        [ H.div_
            [HP.class_ "record-sec-head"]
            [ H.h3_ [HP.class_ "record-sec-title sc"] [text "Title"]
            , H.span_
                [HP.class_ "record-sec-n"]
                [text (if mDirty m then "unsaved" else "editable")]
            ]
        , H.input_
            [ HP.class_ "input input--serif"
            , HP.aria_ "label" "Bookmark title"
            , HP.value_ (mEditTitle m)
            , HP.placeholder_ "Untitled bookmark"
            , HE.onInput TitleInput
            ]
        ]
  where
    _ = detail

stampedFields :: BookmarkDetail -> View () () Model Action
stampedFields detail =
    H.dl_
        [HP.class_ "stamped"]
        [ field "source" [text (ms (bdDomain detail))]
        , field
            "url"
            [ H.a_
                [ HP.class_ "record-url"
                , HP.href_ (ms (bdUrl detail))
                , HP.target_ "_blank"
                , HP.rel_ "noopener noreferrer"
                ]
                (urlSegments (bdUrl detail))
            ]
        , field
            "read"
            [ H.span_ [HP.class_ "record-read-yes"] [text "read"]
            , H.span_ [HP.class_ "record-read-no"] [text "unread"]
            ]
        , field "opened" [text (openedText detail)]
        , field "text" [text (textField detail)]
        ]
  where
    field name body =
        H.div_
            [HP.class_ "field"]
            [H.dt_ [] [text name], H.dd_ [] body]

openedText :: BookmarkDetail -> MisoString
openedText detail = case bdLastOpenedAt detail of
    Just stamp | stamp > 0 -> formatFiled stamp
    _ -> ms ("never" :: MisoString)

textField :: BookmarkDetail -> MisoString
textField detail
    | hasText detail =
        ms (paragraphCount (length (visibleParagraphs (bdExtractedText detail))))
    | otherwise = ms ("none" :: MisoString)

noteSection :: Model -> View () () Model Action
noteSection m =
    H.section_
        [HP.class_ "record-sec"]
        ( [ H.div_
                [HP.class_ "record-sec-head"]
                [ H.h3_ [HP.class_ "record-sec-title sc"] [text "Note"]
                , H.span_
                    [HP.class_ "record-sec-n"]
                    [text (ms (wikilinkText (prose (mEditNote m))))]
                ]
          ]
            ++ noteBody
        )
  where
    noteBody
        | T.null (T.strip (prose (mEditNote m))) =
            [ H.p_
                [HP.class_ "record-empty"]
                [text "No note on this record."]
            ]
        | otherwise =
            [ H.div_
                [HP.class_ "record-note markdown"]
                (renderMarkdown (prose (mEditNote m)))
            , H.p_
                [HP.class_ "record-prov"]
                [text "the note filed with this record"]
            ]

seeSection :: Model -> BookmarkDetail -> View () () Model Action
seeSection m detail =
    H.section_
        [HP.class_ "record-sec"]
        ( [ H.div_
                [HP.class_ "record-sec-head"]
                [ H.h3_ [HP.class_ "record-sec-title sc"] [text "See also"]
                , H.span_
                    [HP.class_ "record-sec-n"]
                    [text (ms (show (length rows)))]
                ]
          , H.ul_ [HP.class_ "record-see"] (map seeRow rows)
          ]
            ++ [ H.p_
                    [HP.class_ "record-empty"]
                    [text "No cross-references yet."]
               | null rows
               ]
        )
  where
    rows = seeRows m detail

seeRows :: Model -> BookmarkDetail -> [(MisoString, MisoString, Maybe Int)]
seeRows m detail =
    [ (ms (blSourceTitle link), ms ("links to" :: MisoString), resolvedTarget link)
    | link <- bdLinks detail
    ]
        ++ [ (ms (blSourceTitle link), ms ("cited by" :: MisoString), Just (blSourceId link))
           | link <- mBacklinks m
           , blResolved link
           ]
        ++ [ (ms (blSourceTitle link), ms ("mentions" :: MisoString), Just (blSourceId link))
           | link <- mBacklinks m
           , not (blResolved link)
           ]
  where
    resolvedTarget link
        | blSourceId link > 0 = Just (blSourceId link)
        | otherwise = Nothing

seeRow :: (MisoString, MisoString, Maybe Int) -> View () () Model Action
seeRow (name, direction, target) =
    H.li_ [] (rowView)
  where
    rowView = case target of
        Just bookmarkId ->
            [ H.button_
                [ HP.class_ "see-row"
                , HP.type_ "button"
                , HE.onClick (Navigate (Bookmark bookmarkId))
                ]
                [H.span_ [HP.class_ "see-title"] [text name], tailView (accession bookmarkId)]
            ]
        Nothing ->
            [ H.div_
                [HP.class_ "see-row"]
                [H.span_ [HP.class_ "see-title"] [text name], tailView (ms ("not filed" :: MisoString))]
            ]
    tailView tailText =
        H.span_
            [HP.class_ "see-tail"]
            [ H.span_ [HP.class_ "lead"] []
            , H.span_ [HP.class_ "see-dir"] [text direction]
            , H.span_ [HP.class_ "see-no"] [text tailText]
            ]

recordExtras :: BookmarkDetail -> View () () Model Action
recordExtras detail =
    H.div_
        [HP.class_ "record-sec"]
        [ H.div_
            [HP.class_ "record-sec-head"]
            [ H.h3_ [HP.class_ "record-sec-title sc"] [text "Record"]
            ]
        , H.div_
            [HP.class_ "record-tags"]
            ( H.button_
                [ HP.class_ "action"
                , HP.type_ "button"
                , HE.onClick (OpenGraphAt (bdId detail))
                ]
                [text "the graph"]
                : snapshotAction detail
            )
        ]

snapshotAction :: BookmarkDetail -> [View () () Model Action]
snapshotAction detail
    | hasSnapshot detail = []
    | stringEq (bdSnapshotKind detail) "wayback"
    , not (T.null (T.strip (bdSnapshotPath detail))) =
        [ H.a_
            [ HP.class_ "action"
            , C.styleInline_ "margin-left:16px"
            , HP.href_ (ms (bdSnapshotPath detail))
            , HP.target_ "_blank"
            , HP.rel_ "noopener noreferrer"
            ]
            [text "the wayback copy"]
        ]
    | otherwise =
        [ H.button_
            [ HP.class_ "action"
            , HP.type_ "button"
            , C.styleInline_ "margin-left:16px"
            , HE.onClick (RunBookmarkAction (bdId detail) "snapshot")
            ]
            [text "capture a snapshot"]
        ]

snapshotCard :: BookmarkDetail -> [View () () Model Action]
snapshotCard detail
    | not (hasSnapshot detail) = []
    | otherwise =
        [ H.section_
            [ HP.class_ "record"
            , C.styleInline_ "padding:12px 16px 13px;margin:0 0 24px"
            , HP.aria_ "label" "Snapshot"
            ]
            [ H.div_
                [HP.class_ "snap-head"]
                [ H.span_ [HP.class_ "sc"] [text "Snapshot"]
                , H.span_ [HP.class_ "snap-state"] [text "held on this server"]
                ]
            , H.div_
                [HP.class_ "snap-row"]
                [ H.div_
                    [HP.class_ "snap-facts"]
                    [ snapFact "kind" (snapshotKindLabel detail)
                    ]
                , H.button_
                    [ HP.class_ "btn snap-open"
                    , HP.data_ "testid" "snapshot-open"
                    , HP.type_ "button"
                    , HE.onClick SnapshotOpen
                    ]
                    [text "open the snapshot"]
                ]
            , H.p_
                [HP.class_ "snap-copy"]
                [ text
                    "The page as it was when the text was lifted. It opens without the network and is kept with the record."
                ]
            ]
        ]
  where
    snapFact name value =
        H.span_
            [HP.class_ "snap-fact"]
            [ H.span_ [HP.class_ "snap-k"] [text name]
            , text " "
            , H.span_ [HP.class_ "snap-v"] [text value]
            ]

hasSnapshot :: BookmarkDetail -> Bool
hasSnapshot detail =
    stringEq (bdSnapshotKind detail) "file"
        && not (T.null (T.strip (bdSnapshotPath detail)))

{- | The record card reports the stored snapshot kind only; the DTO carries no
capture timestamp or file size, so the card does not invent one.
-}
snapshotKindLabel :: BookmarkDetail -> MisoString
snapshotKindLabel detail
    | stringEq (bdSnapshotKind detail) "file" = ms ("single file" :: MisoString)
    | stringEq (bdSnapshotKind detail) "wayback" = ms ("wayback copy" :: MisoString)
    | T.null (T.strip (bdSnapshotKind detail)) = ms ("not recorded" :: MisoString)
    | otherwise = ms (T.strip (bdSnapshotKind detail))

-- ---------------------------------------------------------------- share --

shareSlip :: Model -> BookmarkDetail -> [View () () Model Action]
shareSlip m detail
    | not (mShareDialogOpen m) = []
    | otherwise =
        [ H.div_
            [HP.class_ "overlay is-open", HE.onClick ShareDialogClose]
            [ H.div_
                [ HP.class_ "dshare-slip"
                , HP.data_ "testid" "dialog-share"
                , HP.role_ "dialog"
                , HP.aria_ "modal" "true"
                , HP.aria_ "label" "Share this record"
                , HE.onClickWithOptions stopPropagation Noop
                ]
                ( [ H.div_
                        [HP.class_ "dshare-head"]
                        [ H.h2_
                            [HP.class_ "dshare-title"]
                            [text "Share this record"]
                        , H.button_
                            [ HP.class_ "dshare-x"
                            , HP.type_ "button"
                            , HP.aria_ "label" "Close"
                            , HP.title_ "Close"
                            , HE.onClick ShareDialogClose
                            ]
                            [text "×"]
                        ]
                  , H.p_ [HP.class_ "dshare-copy"] [text (ms shareCopy)]
                  ]
                    ++ shareLinkRow m
                    ++ [shareFields m, shareLinksSection m detail, shareFoot]
                )
            ]
        ]
  where
    shareCopy :: Text
    shareCopy =
        "A read-only page of "
            <> prose (accession (bdId detail))
            <> ". The link is unguessable, and you can revoke it from this record."

shareLinkRow :: Model -> [View () () Model Action]
shareLinkRow m = case mShareUrl m of
    Just url ->
        [ H.div_
            [HP.class_ "dshare-linkrow", HP.data_ "testid" "share-reveal"]
            [ H.a_
                [ HP.class_ "dshare-link"
                , HP.data_ "testid" "share-url"
                , HP.href_ (ms url)
                , HP.target_ "_blank"
                , HP.rel_ "noopener noreferrer"
                ]
                [text (ms url)]
            , H.button_
                [ HP.class_ "btn"
                , HP.data_ "testid" "share-copy"
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
                  , HP.data_ "testid" "share-create"
                  , HP.type_ "button"
                  , HE.onClick ShareCreate
                  ]
                    ++ disabledAttr (mShareBusy m)
                )
                [text (if mShareBusy m then "creating..." else "create the link")]
            ]
        ]

shareFields :: Model -> View () () Model Action
shareFields m =
    H.div_
        [HP.class_ "dshare-fields"]
        [ H.div_
            [HP.class_ "field dshare-expiry-field"]
            [ H.label_
                [HP.class_ "field-label", HP.for_ "share-expiry"]
                [text "expires"]
            , H.select_
                [ HP.id_ "share-expiry"
                , HP.class_ "select"
                , HE.onChange
                    ( \raw ->
                        ShareExpirySelected
                            (fromMaybe 30 (readMaybe (fromMisoString raw :: String)))
                    )
                ]
                (map (expiryOption (mShareExpiryDays m)) expiryDayChoices)
            ]
        , H.label_
            [HP.class_ "toggle dshare-toggle"]
            [ H.input_
                [ HP.type_ "checkbox"
                , HP.data_ "testid" "share-include-note"
                , HP.checked_ (mShareIncludeNote m)
                , HE.onClick ShareIncludeNoteToggle
                ]
            , text "include the note"
            ]
        ]

expiryDayChoices :: [Int]
expiryDayChoices = [1, 7, 30, 90, 365]

expiryOption :: Int -> Int -> View () () Model Action
expiryOption current days =
    H.option_
        [HP.value_ (ms (show days)), HP.selected_ (current == days)]
        [text (ms (labelFor days))]
  where
    labelFor 1 = "in 1 day"
    labelFor value = "in " <> show value <> " days"

shareLinksSection :: Model -> BookmarkDetail -> View () () Model Action
shareLinksSection m detail
    | Just message <- mSharesError m =
        H.p_ [HP.class_ "dshare-note"] [text ("existing links could not be read: " <> message)]
    | null activeLinks = H.span_ [] []
    | otherwise =
        H.div_
            [HP.class_ "record-sec"]
            [ H.div_
                [HP.class_ "record-sec-head"]
                [ H.h3_ [HP.class_ "record-sec-title sc"] [text "Existing links"]
                ]
            , H.div_ [HP.class_ "record-tags"] (map linkRow activeLinks)
            ]
  where
    activeLinks =
        [ share
        | share <- mShares m
        , svScope share == "bookmark"
        , svTargetId share == bdId detail
        , not (isJust (svRevokedAt share))
        ]
    linkRow share =
        H.span_
            [HP.class_ "record-tags", HP.data_ "testid" "share-row"]
            [ H.span_ [HP.class_ "mono"] [text (ms (svPrefix share))]
            , H.span_
                [HP.class_ "status--warn"]
                [text (ms ("expires " <> prose (formatFiled (svExpiresAt share))))]
            , H.button_
                [ HP.class_ "btn btn--sm"
                , HP.data_ "testid" "share-revoke"
                , HP.type_ "button"
                , HE.onClick (ShareRevoke (svId share))
                ]
                [text "revoke"]
            ]

shareFoot :: View () () Model Action
shareFoot =
    H.div_
        [HP.class_ "dshare-foot"]
        [ H.p_
            [HP.class_ "dshare-note"]
            [ text
                "The recipient does not need an account, and this does not make the record public."
            ]
        , H.button_
            [ HP.class_ "btn"
            , HP.type_ "button"
            , HE.onClick ShareDialogClose
            ]
            [text "done"]
        ]

-- ---------------------------------------------------------------- delete --

deleteDialog :: Model -> BookmarkDetail -> View () () Model Action
deleteDialog m detail
    | mConfirmDelete m /= Just (bdId detail) = H.span_ [] []
    | otherwise =
        H.div_
            [HP.class_ "overlay is-open", HE.onClick DeleteBookmarkCancel]
            [ H.div_
                [ HP.class_ "dialog detail-ov"
                , HP.data_ "testid" "dialog-delete"
                , HP.role_ "dialog"
                , HP.aria_ "modal" "true"
                , HP.aria_ "label" "Delete this record"
                , HE.onClickWithOptions stopPropagation Noop
                ]
                [ H.div_
                    [HP.class_ "dialog__head"]
                    [ H.h2_
                        [HP.class_ "dialog__title"]
                        [text "delete this record"]
                    , H.kbd_ [] [text "esc"]
                    ]
                , H.div_
                    [ HP.class_ "dialog__body"
                    , HP.data_ "testid" "dialog-body"
                    ]
                    [ H.p_
                        []
                        [ text "This removes "
                        , H.strong_ [] [text (accession (bdId detail))]
                        , text " · "
                        , H.strong_ [] [text (ms (bdTitle detail))]
                        , text " from the ledger, together with its note, highlights and links."
                        ]
                    , H.p_ [] [text "The write cannot be undone."]
                    ]
                , H.div_
                    [HP.class_ "dialog__foot"]
                    [ H.button_
                        [ HP.class_ "btn"
                        , HP.data_ "testid" "dialog-cancel"
                        , HE.onClick DeleteBookmarkCancel
                        ]
                        [text "cancel"]
                    , H.span_ [HP.class_ "spacer"] []
                    , H.button_
                        [ HP.class_ "btn btn--danger"
                        , HP.data_ "testid" "dialog-confirm"
                        , HE.onClick DeleteBookmarkConfirm
                        ]
                        [text "delete the record"]
                    ]
                ]
            ]

-- -------------------------------------------------------------- highlight --

highlightNoteDialog :: Model -> [View () () Model Action]
highlightNoteDialog m
    | not (mHighlightNoteOpen m) = []
    | otherwise =
        [ dialogShell
            "Add a note to the selection"
            HighlightNoteCancel
            [ H.div_
                [HP.class_ "field"]
                [ H.label_
                    [HP.class_ "field-label", HP.for_ "highlight-note"]
                    [text "note"]
                , H.textarea_
                    [ HP.id_ "highlight-note"
                    , HP.class_ "textarea"
                    , HP.value_ (mHighlightNote m)
                    , HP.placeholder_ "Why this passage matters"
                    , HE.onInput HighlightNoteInput
                    ]
                ]
            ]
            [ H.button_
                [ HP.class_ "btn"
                , HP.data_ "testid" "dialog-cancel"
                , HE.onClick HighlightNoteCancel
                ]
                [text "cancel"]
            , H.span_ [HP.class_ "spacer"] []
            , H.button_
                [ HP.class_ "btn btn--strong"
                , HP.data_ "testid" "dialog-confirm"
                , HE.onClick HighlightNoteSubmit
                ]
                [text "save highlight"]
            ]
        ]

highlightEditDialog :: Model -> [View () () Model Action]
highlightEditDialog m
    | not (isJust (mHighlightEdit m)) = []
    | otherwise =
        [ dialogShell
            "Edit highlight"
            HighlightEditCancel
            (quoteBlock : [noteField, markField])
            [ H.button_
                [ HP.class_ "btn"
                , HP.data_ "testid" "dialog-cancel"
                , HE.onClick HighlightEditCancel
                ]
                [text "cancel"]
            , H.button_
                [HP.class_ "btn btn--danger", HE.onClick (HighlightDelete editId)]
                [text "delete"]
            , H.span_ [HP.class_ "spacer"] []
            , H.button_
                [ HP.class_ "btn btn--strong"
                , HP.data_ "testid" "dialog-confirm"
                , HE.onClick HighlightEditSave
                ]
                [text "save changes"]
            ]
        ]
  where
    editId = fromMaybe 0 (mHighlightEdit m)
    current = find (\hl -> hId hl == editId) (mHighlights m)
    quoteBlock = case current of
        Just hl -> H.p_ [HP.class_ "record-note"] [text (ms (hQuote hl))]
        Nothing -> H.span_ [] []
    noteField =
        H.div_
            [HP.class_ "field"]
            [ H.label_
                [HP.class_ "field-label", HP.for_ "highlight-edit-note"]
                [text "note"]
            , H.textarea_
                [ HP.id_ "highlight-edit-note"
                , HP.class_ "textarea"
                , HP.value_ (mHighlightEditNote m)
                , HP.placeholder_ "Why this passage matters"
                , HE.onInput HighlightEditInput
                ]
            ]
    markField =
        H.div_
            [HP.class_ "field"]
            [ H.span_ [HP.class_ "field-label"] [text "mark"]
            , H.div_
                [HP.class_ "detail-actions"]
                (map markButton markChoices)
            ]
    markButton (label, colour) =
        H.button_
            [ HP.class_
                ( if markStyleOf (mHighlightEditColor m) == markStyleOf colour
                    then "btn btn--sm btn--strong"
                    else "btn btn--sm"
                )
            , HP.type_ "button"
            , HP.data_ "testid" (ms ("highlight-style-" <> prose label))
            , HE.onClick (HighlightEditColor colour)
            ]
            [text label]

markChoices :: [(MisoString, Text)]
markChoices =
    [ ("solid", "yellow")
    , ("dashed", "green")
    , ("double", "blue")
    ]

dialogShell ::
    MisoString ->
    Action ->
    [View () () Model Action] ->
    [View () () Model Action] ->
    View () () Model Action
dialogShell title closeAction bodyViews footViews =
    H.div_
        [HP.class_ "overlay is-open", HE.onClick closeAction]
        [ H.div_
            [ HP.class_ "dialog detail-ov"
            , HP.data_ "testid" "dialog"
            , HP.role_ "dialog"
            , HP.aria_ "modal" "true"
            , HP.aria_ "label" title
            , HE.onClickWithOptions stopPropagation Noop
            ]
            [ H.div_
                [HP.class_ "dialog__head"]
                [H.h2_ [HP.class_ "dialog__title"] [text title], H.kbd_ [] [text "esc"]]
            , H.div_
                [ HP.class_ "dialog__body"
                , HP.data_ "testid" "dialog-body"
                ]
                bodyViews
            , H.div_ [HP.class_ "dialog__foot"] footViews
            ]
        ]

-- ------------------------------------------------------------- snapshot --

snapshotDialog :: Model -> BookmarkDetail -> View () () Model Action
snapshotDialog m detail
    | not (mSnapshotOpen m) = H.span_ [] []
    | otherwise =
        H.div_
            [HP.class_ "overlay is-open", HE.onClick SnapshotClose]
            [ H.div_
                [ HP.class_ "dialog"
                , C.styleInline_ "width:min(1040px,100%)"
                , HP.role_ "dialog"
                , HP.aria_ "modal" "true"
                , HP.aria_ "label" "Snapshot"
                , HE.onClickWithOptions stopPropagation Noop
                ]
                [ H.div_
                    [HP.class_ "dialog__head"]
                    [ H.h2_ [HP.class_ "dialog__title"] [text "Snapshot"]
                    , H.button_
                        [ HP.class_ "dshare-x"
                        , HP.data_ "testid" "snapshot-close"
                        , HP.type_ "button"
                        , HP.aria_ "label" "Close"
                        , HP.title_ "Close"
                        , HE.onClick SnapshotClose
                        ]
                        [text "×"]
                    ]
                , H.div_
                    [HP.class_ "dialog__body"]
                    [ H.iframe_
                        [ HP.class_ "snapshot-frame"
                        , HP.data_ "testid" "snapshot-frame"
                        , HP.src_ (snapshotUrl detail)
                        , HP.title_ "Saved snapshot"
                        , HP.sandbox_ ""
                        ]
                        []
                    ]
                , H.div_
                    [HP.class_ "dialog__foot"]
                    [ H.a_
                        [ HP.class_ "btn"
                        , HP.href_ (snapshotUrl detail)
                        , HP.target_ "_blank"
                        , HP.rel_ "noopener noreferrer"
                        ]
                        [text "open in a new tab"]
                    , H.span_ [HP.class_ "spacer"] []
                    , H.button_
                        [HP.class_ "btn btn--strong", HE.onClick SnapshotClose]
                        [text "done"]
                    ]
                ]
            ]

snapshotUrl :: BookmarkDetail -> MisoString
snapshotUrl detail =
    ms ("/api/v1/bookmarks/" <> show (bdId detail) <> "/snapshot")

-- --------------------------------------------------------------- helpers --

prose :: MisoString -> Text
prose = fromMisoString

accession :: Int -> MisoString
accession bid =
    ms ("EA-" <> T.justifyRight 5 '0' (T.pack (show bid)))

urlText :: Text -> Text
urlText = T.replace "https://" "" . T.replace "http://" ""

urlSegments :: Text -> [View () () Model Action]
urlSegments raw =
    case T.breakOn "/" (urlText raw) of
        (host, rest)
            | T.null rest -> [H.span_ [] [text (ms host)]]
            | otherwise ->
                H.span_ [] [text (ms host)]
                    : concat
                        [ [H.wbr_ [], H.span_ [] [text (ms ("/" <> segment))]]
                        | segment <- filter (not . T.null) (T.splitOn "/" (T.drop 1 rest))
                        ]

stringEq :: Text -> Text -> Bool
stringEq left right =
    T.toLower (T.strip left) == T.toLower (T.strip right)

hasText :: BookmarkDetail -> Bool
hasText = not . T.null . T.strip . bdExtractedText

paragraphsOf :: Text -> [(Int, Text)]
paragraphsOf body = step (0 :: Int) (T.splitOn "\n\n" body)
  where
    step _ [] = []
    step offset (para : rest) =
        (offset, para) : step (offset + T.length para + 2) rest

visibleParagraphs :: Text -> [Text]
visibleParagraphs = filter (not . T.null . T.strip) . map snd . paragraphsOf

numberedHighlights :: Text -> [Highlight] -> [(Int, Highlight)]
numberedHighlights body highlights =
    zip [1 ..] (sortOn hStartOffset (filter valid highlights))
  where
    len = T.length body
    valid hl =
        hEndOffset hl > hStartOffset hl
            && hStartOffset hl >= 0
            && hEndOffset hl <= len
            && not (T.null (T.strip (hQuote hl)))

paragraphCount :: Int -> Text
paragraphCount 1 = "1 paragraph"
paragraphCount count = T.pack (show count) <> " paragraphs"

wikilinkText :: Text -> Text
wikilinkText note = case T.count "[[" note of
    0 -> "no wikilinks"
    1 -> "one wikilink"
    n -> T.pack (show n) <> " wikilinks"

markStyleOf :: Text -> Text
markStyleOf colour = case T.toLower (T.strip colour) of
    "green" -> "dashed"
    "blue" -> "double"
    "purple" -> "double"
    _ -> "solid"

markWeight :: Text -> Int
markWeight colour = case T.toLower (T.strip colour) of
    "blue" -> 3
    "pink" -> 1
    "purple" -> 1
    _ -> 2

markCss :: Text -> MisoString
markCss colour =
    ms
        ( "border-bottom:"
            <> T.pack (show (markWeight colour))
            <> "px "
            <> markStyleOf colour
            <> " var(--accent)"
        )

keyCodeToInt :: KeyCode -> Int
keyCodeToInt (KeyCode value) = value
