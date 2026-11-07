-- | Bookmark detail: editable title, reader column, markdown notes with
-- wikilink autocomplete, tag editing, backlinks, and the save/dirty guard.
module Eza.Web.Detail (detailPage) where

import Data.Text (Text)
import qualified Data.Text as T
import Miso
import qualified Miso.Html as H
import qualified Miso.Html.Event as HE
import qualified Miso.Html.Property as HP

import Eza.Types
  ( Backlink (..)
  , BookmarkDetail (..)
  , BookmarkSummary (..)
  )
import Eza.Web.Markdown (renderMarkdown)
import Eza.Web.Model
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
        )
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
        , btn (if mDirty m then "btn-primary" else "") ([HE.onClick SaveBookmark] <> disabledAttr (not (mDirty m) || mSaving m))
            ( [ H.span_ [HP.class_ "dirty-dot"] [] | mDirty m ]
                ++ [text (if mSaving m then "Saving…" else "Save")]
            )
        , btn "btn-danger" [HE.onClick (DeleteBookmark (bdId detail))] [icon iTrash, text "Delete"]
        ]
    ]

readerPanel :: Model -> BookmarkDetail -> View () () Model Action
readerPanel _m detail =
  panelWithHead
    "Reader"
    [ btnSm "Extract" (RunBookmarkAction (bdId detail) "extract")
    , btnSm "Snapshot" (RunBookmarkAction (bdId detail) "snapshot")
    ]
    ( [H.div_ [HP.class_ "reader-text"] [text (ms (bdExtractedText detail))] | not (T.null (T.strip (bdExtractedText detail)))]
        ++ [ emptyState
               "📄"
               "No extracted text yet"
               [ H.p_ [] [text "Run Extract to pull the readable article text from the page."]
               , btn "btn-primary" [HE.onClick (RunBookmarkAction (bdId detail) "extract")] [text "Extract now"]
               ]
           | T.null (T.strip (bdExtractedText detail))
           ]
    )

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
        , btn (if mDirty m then "btn-primary" else "") ([HE.onClick SaveBookmark] <> disabledAttr (not (mDirty m) || mSaving m))
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
    [ H.span_ [HP.class_ "pill"] [text (ms (show (length (mBacklinks m)) <> " references"))] ]
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
