{- | Bookmark record: the reading spread, the catalogue record card, the note
editor, the share slip, the highlight dialogs and the snapshot viewer.
The markup follows the Direction B design package.
-}
module Eza.Web.Detail (detailPage) where

import Data.List (find, sortOn)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Eza.Web.Render.Event as HE
import Miso
import qualified Miso.CSS as C
import qualified Miso.Html as H
import qualified Miso.Html.Property as HP
import Text.Read (readMaybe)

import Eza.Share (ShareView (..))
import Eza.Types (
    Backlink (..),
    BookmarkDetail (..),
    BookmarkSummary (..),
    Highlight (..),
 )
import Eza.Web.Logic.Model
import Eza.Web.Logic.Requests (bookmarkSnapshotUrl)
import Eza.Web.Logic.Route (Route (..))
import Eza.Web.Markdown (renderMarkdown)
import Eza.Web.Render (txt)
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
        ]

failedView :: Model -> View () () Model Action
failedView m =
    H.div_
        [HP.class_ "empty"]
        [ H.span_ [HP.class_ "empty-kicker sc"] [text "record unavailable"]
        , H.h1_ [HP.class_ "empty-title"] [text "This record could not be opened."]
        , H.p_
            [HP.class_ "ledg-error-code mono"]
            [txt (fromMaybe "the record request failed" (mDetailError m))]
        , H.p_
            [HP.class_ "empty-try"]
            ( H.button_
                [HP.class_ "btn btn--strong", HE.onClick (Navigate Index)]
                [text "back to the ledger"]
                : retryButton m
            )
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
            ++ [manualAliveNote | bdManualAlive detail]
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
        [HP.class_ "detail-top"]
        [ H.button_
            [HP.class_ "detail-back", HE.onClick (Navigate Index)]
            [ H.span_
                [HP.class_ "detail-back-arr", HP.aria_ "hidden" "true"]
                [text "←"]
            , text "ledger"
            ]
        , H.span_
            [HP.class_ "detail-acc"]
            [text (accession (bdId detail))]
        ]

recordHead :: Model -> BookmarkDetail -> View () () Model Action
recordHead m detail =
    H.header_
        [HP.class_ "detail-head"]
        [ H.h1_
            [HP.class_ "detail-title"]
            [text (displayTitle m detail)]
        , metaLine detail
        , tagRow m
        , actionsLine detail
        ]

displayTitle :: Model -> BookmarkDetail -> MisoString
displayTitle m detail
    | T.null (T.strip (mEditTitle m)) = ms (bdTitle detail)
    | otherwise = ms (mEditTitle m)

metaLine :: BookmarkDetail -> View () () Model Action
metaLine detail =
    H.p_
        [HP.class_ "detail-meta"]
        (interleaveSep (map spanText items ++ readSpans))
  where
    items :: [MisoString]
    items =
        filter (not . T.null . T.strip . prose) $
            [ ms author
            , ms (bdDomain detail)
            ]
                ++ [ ms ("published " <> prose (ms (formatProseDate stamp)))
                   | Just stamp <- [bdPublishedAt detail]
                   , stamp > 0
                   ]
    author
        | T.null (T.strip (bdAuthor detail)) = ""
        | "://" `T.isInfixOf` T.strip (bdAuthor detail) = ""
        | otherwise = bdAuthor detail
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
            ++ extractAction detail
            ++ [ H.button_
                    [HP.class_ "btn", HE.onClick ShareDialogOpen]
                    [text "share"]
               , H.button_
                    [ HP.class_ "btn btn--danger"
                    , HE.onClick (DeleteBookmarkRequest (bdId detail))
                    ]
                    [text "delete"]
               ]
        )

extractAction :: BookmarkDetail -> [View () () Model Action]
extractAction detail
    | stringEq (bdEnrichState detail) "queued" =
        [ H.button_
            [ HP.class_ "btn"
            , HP.aria_ "disabled" "true"
            , HP.title_ "extraction is queued"
            ]
            [text "queued"]
        ]
    | hasText detail = []
    | stringEq (bdEnrichState detail) "failed" =
        [ H.button_
            [HP.class_ "btn", HE.onClick (RetryEnrich (bdId detail))]
            [text "extract again"]
        ]
    | otherwise =
        [ H.button_
            [HP.class_ "btn", HE.onClick (RetryEnrich (bdId detail))]
            [text "extract text"]
        ]

-- --------------------------------------------------------------- banners --

deadBanner :: View () () Model Action
deadBanner =
    H.div_
        [HP.class_ "detail-dead", C.styleInline_ "display:flex", HP.data_ "testid" "dead-banner"]
        [ H.span_
            [HP.class_ "detail-dead-mark", HP.aria_ "hidden" "true"]
            [text "!"]
        , H.p_
            [HP.class_ "detail-dead-copy"]
            [ H.strong_ [] [text "This link is marked dead."]
            , text " A check did not reach the page, or the page answered as removed."
            ]
        , H.button_
            [ HP.class_ "btn btn--sm"
            , HP.type_ "button"
            , HP.data_ "testid" "mark-not-dead"
            , HE.onClick MarkLinkAlive
            ]
            [text "mark not dead"]
        ]

manualAliveNote :: View () () Model Action
manualAliveNote =
    H.div_
        [HP.class_ "detail-manual", HP.role_ "status", HP.data_ "testid" "manual-alive"]
        [ H.p_
            [HP.class_ "detail-manual-copy"]
            [ H.strong_ [] [text "Kept alive manually."]
            , text " Automatic checks skip this record."
            ]
        , H.button_
            [ HP.class_ "btn btn--sm"
            , HP.type_ "button"
            , HP.data_ "testid" "recheck-link"
            , HE.onClick RecheckLink
            ]
            [text "use automatic checks"]
        ]

-- --------------------------------------------------------------- reading --

{- | The extracted text lives in a bounded, rounded window: the record stays
composed while the copy scrolls inside the card.
-}
readingColumn :: Model -> BookmarkDetail -> [View () () Model Action]
readingColumn m detail =
    snapshotCard detail
        ++ [ H.section_
                [HP.class_ "read-window"]
                ( [ H.header_
                        [HP.class_ "read-window-head"]
                        ( [ H.span_ [HP.class_ "sc"] [text "Extracted text"]
                          , H.span_ [HP.class_ "read-count"] [text (readCount m detail)]
                          ]
                            ++ [ H.button_
                                    [ HP.class_ "read-edit"
                                    , HP.type_ "button"
                                    , HP.data_ "testid" "extract-edit"
                                    , HP.aria_ "label" "Edit extracted text"
                                    , HE.onClick ExtractEditStart
                                    ]
                                    [text "edit"]
                               | not (mExtractEditing m)
                               ]
                        )
                  ]
                    ++ [ if mExtractEditing m
                            then extractEditor m detail
                            else readingCardBody m detail
                       ]
                )
           ]
        ++ selectionBar m
        ++ marksList detail numbered
  where
    numbered = numberedHighlights (bdExtractedText detail) (mHighlights m)

extractEditor :: Model -> BookmarkDetail -> View () () Model Action
extractEditor m _detail =
    H.div_
        [HP.class_ "read-editor", HP.data_ "testid" "extract-editor"]
        [ H.textarea_
            [ HP.id_ "extract-text-editor"
            , HP.class_ "read-editor-input"
            , HP.value_ (ms (mExtractDraft m))
            , HP.placeholder_ "Paste or correct the extracted text"
            , HP.aria_ "label" "Extracted text editor"
            , HP.spellcheck_ False
            , HE.onInput ExtractEditChanged
            ]
        , if null (mHighlights m)
            then H.span_ [] []
            else
                H.p_
                    [HP.class_ "read-editor-warn"]
                    [text "Saving re-anchors this record's highlights. A quote that no longer appears is removed."]
        , H.div_
            [HP.class_ "read-editor-actions"]
            [ H.button_
                ( [ HP.class_ "btn btn--sm btn--strong"
                  , HP.type_ "button"
                  , HP.data_ "testid" "extract-save"
                  , HE.onClick SaveBookmark
                  ]
                    ++ disabledAttr (mSaving m)
                )
                [text (if mSaving m then "saving..." else "save text")]
            , H.button_
                [ HP.class_ "btn btn--sm"
                , HP.type_ "button"
                , HP.data_ "testid" "extract-cancel"
                , HE.onClick ExtractEditCancel
                ]
                [text "cancel"]
            ]
        ]

readCount :: Model -> BookmarkDetail -> MisoString
readCount m detail
    | mExtractEditing m = ms ("editing" :: MisoString)
    | hasText detail =
        ms
            ( paragraphCount (length (visibleParagraphs (bdExtractedText detail)))
                <> " · "
                <> T.pack (show (bdReadingTimeMinutes detail))
                <> " min"
                <> (if stringEq (bdEnrichState detail) "manual" then " · edited" else "")
            )
    | stringEq (bdEnrichState detail) "queued" = ms ("queued" :: MisoString)
    | stringEq (bdEnrichState detail) "failed" = ms ("failed" :: MisoString)
    | stringEq (bdEnrichState detail) "manual" = ms ("manual" :: MisoString)
    | otherwise = ms ("none" :: MisoString)

readingCardBody :: Model -> BookmarkDetail -> View () () Model Action
readingCardBody m detail
    | hasText detail =
        H.article_
            [ HP.id_ "reader-text"
            , HP.class_ "read-paras reading"
            , HE.onMouseUp ReaderMouseUp
            ]
            (paragraphsView (bdExtractedText detail) numbered)
    | stringEq (bdEnrichState detail) "queued" =
        readNote "Extraction is queued."
    | stringEq (bdEnrichState detail) "failed" =
        readNote (ms ("Extraction failed" <> errorSuffix (bdEnrichError detail) <> "."))
    | otherwise =
        readNote "No text extracted yet."
  where
    numbered = numberedHighlights (bdExtractedText detail) (mHighlights m)

errorSuffix :: Text -> String
errorSuffix raw =
    let line = T.strip (T.take 180 (T.replace "\n" " " raw))
     in if T.null line then "" else ": " <> T.unpack line

readNote :: MisoString -> View () () Model Action
readNote message =
    H.p_ [HP.class_ "read-note"] [text message]

paragraphsView :: Text -> [(Int, Highlight)] -> [View () () Model Action]
paragraphsView body numbered =
    step 0 (paragraphsOf body)
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
        [ H.section_
            [HP.class_ "marks"]
            ( [ H.header_
                    [HP.class_ "marks-head"]
                    [ H.span_ [HP.class_ "sc"] [text "Marks"]
                    , H.span_ [HP.class_ "read-count"] [text (ms (show (length numbered)))]
                    ]
              ]
                ++ [ H.ol_
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
            )
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

-- ------------------------------------------------------------- note editor --

noteEditor :: Model -> BookmarkDetail -> View () () Model Action
noteEditor m detail =
    H.section_
        [HP.class_ "note-editor", HP.aria_ "label" "Note"]
        ( [ H.div_
                [HP.class_ "note-head"]
                ( [H.span_ [HP.class_ "sc"] [text "Note"]]
                    ++ [ H.div_
                            [HP.class_ "noteed-modes"]
                            ( [ modeButton NoteWrite "write"
                              , modeButton NotePreview "preview"
                              ]
                                ++ [ H.span_
                                        [ HP.class_ "noteed-dirty"
                                        , C.styleInline_ "display:inline-flex"
                                        ]
                                        [H.span_ [HP.class_ "noteed-dirty-dot"] [], text " unsaved"]
                                   | mDirty m
                                   ]
                            )
                       ]
                )
          ]
            ++ [bodyViews]
            ++ suggestions m
            ++ [foot | mDirty m || mSaving m]
        )
  where
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
                    , HP.value_ (ms (mEditNote m))
                    , HE.onInput NoteChanged
                    ]
                ]
    previewViews model
        | T.null (T.strip (prose (ms (mEditNote model)))) =
            [ H.p_ [HP.class_ "record-empty"] [text "No note yet."]
            ]
        | otherwise = renderMarkdown (prose (ms (mEditNote model)))
    foot =
        H.div_
            [HP.class_ "noteed-foot"]
            [ H.p_
                [HP.class_ "noteed-hint"]
                [ H.kbd_ [] [text "⌘S"]
                , text " saves · "
                , H.span_ [HP.class_ "mono"] [text "[[title]]"]
                , text " links a record"
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
                    [text (if mSaving m then "saving…" else "save changes")]
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
                    , HP.value_ (ms (mNewTag m))
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
                [H.span_ [HP.class_ "sc"] [text "Catalogue record"]]
          ]
            ++ [ H.span_
                    [ HP.class_ "record-deadmark"
                    , C.styleInline_ "display:block;width:max-content;margin:0 0 12px"
                    ]
                    [text "dead"]
               | bdIsDead detail
               ]
            ++ [ filedStamp detail
               , lastOpened detail
               , titleField m
               ]
            ++ seeSection m detail
            ++ [recordLinks detail]
        )
    ]

filedStamp :: BookmarkDetail -> View () () Model Action
filedStamp detail =
    H.div_
        [HP.class_ "record-stamp"]
        [ H.span_ [HP.class_ "record-stamp-k sc"] [text "filed"]
        , H.span_
            [HP.class_ "record-stamp-d"]
            [txt (formatFiled (bdCreatedAt detail))]
        ]

lastOpened :: BookmarkDetail -> View () () Model Action
lastOpened detail =
    H.p_
        [HP.class_ "record-last"]
        [ H.span_ [HP.class_ "record-label"] [text "opened"]
        , text (openedText detail)
        ]

titleField :: Model -> View () () Model Action
titleField m =
    H.div_
        [HP.class_ "record-sec"]
        [ H.div_
            [HP.class_ "record-sec-head"]
            [ H.label_
                [HP.class_ "record-sec-title sc", HP.for_ "record-title"]
                [text "Title"]
            ]
        , H.input_
            [ HP.id_ "record-title"
            , HP.class_ "input input--serif"
            , HP.aria_ "label" "Bookmark title"
            , HP.value_ (ms (mEditTitle m))
            , HP.placeholder_ "Untitled bookmark"
            , HE.onInput TitleInput
            ]
        ]

openedText :: BookmarkDetail -> MisoString
openedText detail = case bdLastOpenedAt detail of
    Just stamp | stamp > 0 -> ms (formatFiled stamp)
    _ -> ms ("never" :: MisoString)

seeSection :: Model -> BookmarkDetail -> [View () () Model Action]
seeSection m detail
    | null rows = []
    | otherwise =
        [ H.section_
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
            )
        ]
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

recordLinks :: BookmarkDetail -> View () () Model Action
recordLinks detail =
    H.div_
        [HP.class_ "record-links"]
        ( H.button_
            [ HP.class_ "action"
            , HP.type_ "button"
            , HP.data_ "testid" "open-graph"
            , HE.onClick (OpenGraphAt (bdId detail))
            ]
            [text "the graph"]
            : extractAgain detail
            ++ snapshotAction detail
        )

extractAgain :: BookmarkDetail -> [View () () Model Action]
extractAgain detail
    | hasText detail =
        [ H.button_
            [ HP.class_ "action"
            , HP.type_ "button"
            , HE.onClick (RetryEnrich (bdId detail))
            ]
            [text "extract again"]
        ]
    | otherwise = []

snapshotAction :: BookmarkDetail -> [View () () Model Action]
snapshotAction detail
    | hasSnapshot detail = []
    | stringEq (bdSnapshotKind detail) "wayback"
    , not (T.null (T.strip (bdSnapshotPath detail))) =
        [ H.a_
            [ HP.class_ "action"
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
            , HE.onClick (RunBookmarkAction (bdId detail) "snapshot")
            ]
            [text "capture a snapshot"]
        ]

snapshotCard :: BookmarkDetail -> [View () () Model Action]
snapshotCard detail
    | not (hasSnapshot detail) = []
    | otherwise =
        [ H.section_
            [ HP.class_ "snapcard"
            , HP.aria_ "label" "Snapshot"
            ]
            [ H.span_ [HP.class_ "sc"] [text "Snapshot"]
            , H.span_ [HP.class_ "snap-state"] [text (snapshotKindLabel detail)]
            , H.button_
                [ HP.class_ "btn snap-open"
                , HP.data_ "testid" "snapshot-open"
                , HP.type_ "button"
                , HE.onClick SnapshotOpen
                ]
                [text "open"]
            ]
        ]

hasSnapshot :: BookmarkDetail -> Bool
hasSnapshot detail =
    stringEq (bdSnapshotKind detail) "file"
        && not (T.null (T.strip (bdSnapshotPath detail)))

{- | The card names the stored snapshot kind only; the DTO carries no capture
timestamp or file size, so the card does not invent one.
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
        "A read-only page. Anyone with the link can read "
            <> prose (accession (bdId detail))
            <> "."

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
            [ H.span_ [HP.class_ "dshare-link"] [text "no link yet"]
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
                            (fromMaybe 30 (readMaybe (T.unpack raw)))
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
        H.p_ [HP.class_ "dshare-note"] [txt ("existing links could not be read: " <> message)]
    | null activeLinks = H.span_ [] []
    | otherwise =
        H.div_
            [HP.class_ "dshare-links-sec"]
            [ H.h3_ [HP.class_ "dshare-links-title sc"] [text "Existing links"]
            , H.div_ [HP.class_ "dshare-links"] (map linkRow activeLinks)
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
        H.div_
            [HP.class_ "dshare-link-row", HP.data_ "testid" "share-row"]
            [ H.span_
                [HP.class_ "dshare-link-prefix mono"]
                [text (ms (svPrefix share))]
            , H.span_
                [HP.class_ "dshare-link-expiry meta"]
                [text (ms ("expires " <> prose (ms (formatFiled (svExpiresAt share)))))]
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
        [ HP.class_ "dshare-foot"
        , C.styleInline_ "justify-content:flex-end"
        ]
        [ H.button_
            [ HP.class_ "btn btn--strong"
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
                        [ text "Delete "
                        , H.strong_ [] [text (accession (bdId detail))]
                        , text " · "
                        , H.strong_ [] [text (ms (bdTitle detail))]
                        , text " with its note, highlights and links. This cannot be undone."
                        ]
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
            "note on the selection"
            HighlightNoteCancel
            [ H.div_
                [HP.class_ "field"]
                [ H.label_
                    [HP.class_ "field-label", HP.for_ "highlight-note"]
                    [text "note"]
                , H.textarea_
                    [ HP.id_ "highlight-note"
                    , HP.class_ "textarea"
                    , HP.value_ (ms (mHighlightNote m))
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
            "edit highlight"
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
                , HP.value_ (ms (mHighlightEditNote m))
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
snapshotUrl detail = ms (bookmarkSnapshotUrl (bdId detail))

-- --------------------------------------------------------------- helpers --

prose :: MisoString -> Text
prose = fromMisoString

accession :: Int -> MisoString
accession bid =
    ms ("EA-" <> T.justifyRight 5 '0' (T.pack (show bid)))

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
