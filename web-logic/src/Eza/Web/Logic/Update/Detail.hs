{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Part of the client update function; see "Eza.Web.Update".
module Eza.Web.Logic.Update.Detail (
    currentDetail,
    finalizeAdd,
    handle,
    insertHighlight,
    readerPrefix,
    readerSuffix,
    refreshShares,
    reloadDetail,
    reloadHighlights,
    sameEpoch,
    textEditedDetail,
) where

import Control.Monad
import Data.Aeson
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Eza.Web.Logic.Effect (RequestId, nextRequestId, requestIsCurrent)

import Eza.Types
import Eza.Web.Logic.Browser
import Eza.Web.Logic.Error
import Eza.Web.Logic.Job (JobKind (..))
import Eza.Web.Logic.Model
import Eza.Web.Logic.Requests
import Eza.Web.Logic.Route (Route (..))
import Eza.Web.Logic.Update.Common
import Eza.Web.Logic.Update.Monad (Update, dispatch, get, put)
import Eza.Web.Logic.Update.Route (loadRoute)

sameEpoch :: RequestId -> Update () -> Update ()
sameEpoch epoch action = do
    m <- get
    when (requestIsCurrent (mDetailEpoch m) epoch) action

{- | The detail record only counts while its route is open.  Save, delete,
read and highlight actions arriving after a navigation are dropped.
-}
currentDetail :: Model -> Maybe BookmarkDetail
currentDetail m = case mRoute m of
    Bookmark bid -> case mDetail m of
        Just detail | bdId detail == bid -> Just detail
        _ -> Nothing
    _ -> Nothing

readerPrefix :: BookmarkDetail -> ReaderSelection -> Text
readerPrefix detail selection =
    T.takeEnd 32 (T.take (max 0 (rsStart selection)) (bdExtractedText detail))

readerSuffix :: BookmarkDetail -> ReaderSelection -> Text
readerSuffix detail selection =
    T.take 32 (T.drop (max 0 (rsEnd selection)) (bdExtractedText detail))

-- | Keep highlights sorted by their start offset.
insertHighlight :: Highlight -> [Highlight] -> [Highlight]
insertHighlight highlight highlights =
    takeWhile (\item -> hStartOffset item < hStartOffset highlight) highlights
        ++ [highlight]
        ++ dropWhile (\item -> hStartOffset item < hStartOffset highlight) highlights

-- ------------------------------------------------------------- the update --

{- | Any unsaved edit owns the navigation guard: the note/title/tag editor or
the extracted-text editor. Keep the two flags separate so saving one does not
claim the other was saved.
-}
textEditedDetail :: BookmarkDetail -> Text -> BookmarkDetail
textEditedDetail detail draft =
    detail
        { bdExtractedText = draft
        , bdReadingTimeMinutes =
            let words' = length (T.words draft)
             in if words' == 0 then 0 else (words' + 219) `div` 220
        , bdEnrichState = "manual"
        , bdEnrichError = ""
        }

reloadHighlights :: Update ()
reloadHighlights = do
    m <- get
    case currentDetail m of
        Just detail -> do
            let epoch = mDetailEpoch m
            fetchHighlights (bdId detail) (HighlightsLoaded epoch) (HighlightsFailed epoch)
        Nothing -> pure ()

finalizeAdd :: Int -> Update ()
finalizeAdd bookmarkId = do
    m <- get
    putModel
        ( \x ->
            x{gAdd = (gAdd x){adAddOpen = False, adAddBusy = False, adAddUrl = "", adAddTitle = "", adAddTags = "", adAddNote = "", adAddError = Nothing}}
        )
    notify (T.pack ("Saved bookmark #" <> show bookmarkId)) ToastOk
    refreshTags
    refreshStats
    if isSaveRoute (mRoute m)
        then replaceRoute (Bookmark bookmarkId)
        else reloadList

-- \| Reload one record after an enrichment or a cancelled edit: new epoch,
-- empty editor, loading view rather than the previous record.

reloadDetail :: Int -> Update ()
reloadDetail bookmarkId = do
    m <- get
    let epoch = nextRequestId (mDetailEpoch m)
    put
        m{gDetail = (gDetail m){dtDetail = Nothing, dtDetailLoading = True, dtDetailError = Nothing, dtDetailEpoch = epoch, dtReadRequest = nextRequestId (mReadRequest m), dtReadPending = False, dtEditTitle = "", dtEditNote = "", dtEditTags = [], dtNewTag = "", dtDirty = False, dtExtractEditing = False, dtExtractDraft = "", dtExtractDirty = False, dtExtractSaving = False, dtNoteMode = NoteWrite, dtLinkQuery = Nothing, dtLinkResults = [], dtBacklinks = [], dtHighlights = [], dtReaderSel = Nothing, dtHighlightNoteOpen = False, dtHighlightNote = "", dtHighlightEdit = Nothing, dtSnapshotOpen = False}, gShares = (gShares m){srShareDialogOpen = False, srShareUrl = Nothing}, gLedger = (gLedger m){lfConfirmDelete = Nothing}}
    fetchDetail bookmarkId (DetailLoaded epoch) (DetailFailed epoch)
    fetchBacklinks bookmarkId (BacklinksLoaded epoch) (BacklinksFailed epoch)
    fetchHighlights bookmarkId (HighlightsLoaded epoch) (HighlightsFailed epoch)

-- \| Refresh the share list without starting a new route epoch.

refreshShares :: Update ()
refreshShares = do
    m <- get
    let epoch = mDetailEpoch m
    fetchShares (\shares -> SharesLoaded epoch shares) (SharesFailed epoch)

-- \| Put a validation or server message in the security panel instead of
-- a toast: the field it belongs to is on the same screen.

handle :: Action -> Update ()
handle = \case
    AddOpen -> do
        putModel (\m -> m{gAdd = (gAdd m){adAddOpen = True, adAddError = Nothing}})
        focusElementDelayed "add-url"
    AddClose -> putModel (\m -> m{gAdd = (gAdd m){adAddOpen = False, adAddError = Nothing}})
    AddUrlInput url -> putModel (\m -> m{gAdd = (gAdd m){adAddUrl = url}})
    AddTitleInput title -> putModel (\m -> m{gAdd = (gAdd m){adAddTitle = title}})
    AddTagsInput tags -> putModel (\m -> m{gAdd = (gAdd m){adAddTags = tags}})
    AddNoteInput note -> putModel (\m -> m{gAdd = (gAdd m){adAddNote = note}})
    AddSubmit -> do
        m <- get
        if mAddBusy m
            then pure ()
            else
                if not (isHttpUrlText (mAddUrl m))
                    then putModel (\x -> x{gAdd = (gAdd x){adAddError = Just "Enter a valid http(s) URL."}})
                    else do
                        putModel (\x -> x{gAdd = (gAdd x){adAddBusy = True, adAddError = Nothing}})
                        createBookmark
                            (mAddUrl m)
                            (mAddTitle m)
                            (splitTags (mAddTags m))
                            AddSucceeded
                            AddFailed
    AddSucceeded bookmarkId -> do
        m <- get
        if T.null (T.strip ((mAddNote m)))
            then finalizeAdd bookmarkId
            else
                -- The create endpoint has no note field, so a note is attached
                -- with the same PATCH the record editor uses.
                patchBookmark
                    bookmarkId
                    (object ["note_body" .= mAddNote m])
                    (AddNoteSaved bookmarkId)
                    (AddNoteFailed bookmarkId)
    AddNoteSaved bookmarkId -> finalizeAdd bookmarkId
    AddNoteFailed bookmarkId _ -> do
        notify
            "The record was filed, but the note could not be attached. Open the record to add it."
            ToastError
        finalizeAdd bookmarkId
    AddFailed err -> do
        putModel (\m -> m{gAdd = (gAdd m){adAddBusy = False, adAddError = Just ((aeMessage err))}})
        handleApiError err
    -- command palette -------------------------------------------------------
    DetailLoaded epoch detail -> sameEpoch epoch $ do
        m <- get
        case mRoute m of
            Bookmark bookmarkId | bookmarkId /= bdId detail -> pure ()
            Bookmark _ ->
                putModel
                    ( \x ->
                        x{gDetail = (gDetail x){dtDetail = Just detail, dtDetailLoading = False, dtDetailError = Nothing, dtEditTitle = (bdTitle detail), dtEditNote = (bdNoteBody detail), dtEditTags = bdTags detail, dtDirty = False, dtExtractEditing = False, dtExtractDraft = (bdExtractedText detail), dtExtractDirty = False, dtExtractSaving = False, dtNoteMode = NoteWrite, dtLinkQuery = Nothing, dtLinkResults = []}}
                    )
            _ -> pure ()
    DetailFailed epoch err -> sameEpoch epoch $ do
        putModel (\m -> m{gDetail = (gDetail m){dtDetailLoading = False, dtDetail = Nothing, dtDetailError = Just ((aeMessage err))}})
        handleApiError err
    TitleInput title -> putModel (\m -> m{gDetail = (gDetail m){dtEditTitle = title, dtDirty = True}})
    NoteChanged noteText -> do
        putModel (\m -> m{gDetail = (gDetail m){dtEditNote = noteText, dtDirty = True}})
        readNoteCursor
    NoteCursorRead cursor -> do
        m <- get
        dispatch (NoteMeta cursor (wikilinkQueryAt (mEditNote m) cursor))
    NoteMeta cursor query -> do
        m <- get
        putModel (\x -> x{gDetail = (gDetail x){dtNoteCursor = cursor, dtLinkQuery = query}})
        case query of
            Nothing -> putModel (\x -> x{gDetail = (gDetail x){dtLinkResults = []}})
            Just rawQuery ->
                if T.null rawQuery
                    then putModel (\x -> x{gDetail = (gDetail x){dtLinkResults = take 6 (mItems m)}})
                    else fetchAutocomplete rawQuery LinkSuggestions (\_ -> Noop)
    NoteModeChanged mode -> putModel (\m -> m{gDetail = (gDetail m){dtNoteMode = mode}})
    TagDraftInput draft -> putModel (\m -> m{gDetail = (gDetail m){dtNewTag = draft}})
    TagAdd -> do
        m <- get
        case parseTagInput (mNewTag m) of
            Nothing -> pure ()
            Just tag ->
                putModel
                    ( \x ->
                        x{gDetail = (gDetail x){dtEditTags = if tag `elem` mEditTags x then mEditTags x else mEditTags x ++ [tag], dtNewTag = "", dtDirty = True}}
                    )
    TagRemove tag -> putModel (\m -> m{gDetail = (gDetail m){dtEditTags = filter (/= tag) (mEditTags m), dtDirty = True}})
    SaveBookmark -> do
        m <- get
        case currentDetail m of
            Nothing -> pure ()
            Just detail -> do
                putModel (\x -> x{gDetail = (gDetail x){dtSaving = True, dtExtractSaving = mExtractEditing m}})
                let fields =
                        [ "title" .= mEditTitle m
                        , "note_body" .= mEditNote m
                        , "tags" .= mEditTags m
                        ]
                    -- A read toggle that is still in flight owns is_read: this
                    -- save must not echo a flag the server has not confirmed.
                    readField =
                        [ "is_read" .= bdIsRead detail
                        | not (mReadPending m)
                        ]
                    textField =
                        [ "extracted_text" .= mExtractDraft m
                        | mExtractEditing m
                        ]
                patchBookmarkWithResult
                    (bdId detail)
                    (object (fields ++ readField ++ textField))
                    SavedOk
                    SaveFailed
    SavedOk highlightsRemoved -> do
        m <- get
        putModel
            ( \x ->
                x{gDetail = (gDetail x){dtSaving = False, dtExtractSaving = False, dtDirty = False, dtExtractDirty = False}}
            )
        case (mDetail m, mExtractEditing m) of
            (Just detail, True) ->
                putModel
                    ( \x ->
                        x{gDetail = (gDetail x){dtDetail = Just (textEditedDetail detail (mExtractDraft m)), dtExtractEditing = False, dtExtractDraft = mExtractDraft m}}
                    )
            _ -> pure ()
        notify
            ( if highlightsRemoved > 0
                then T.pack ("Saved; " <> show highlightsRemoved <> " unmatched highlight(s) removed")
                else "Saved"
            )
            (if highlightsRemoved > 0 then ToastInfo else ToastOk)
        when (mExtractEditing m) $ do
            case mDetail m of
                Just detail -> fetchHighlights (bdId detail) (HighlightsLoaded (mDetailEpoch m)) (HighlightsFailed (mDetailEpoch m))
                Nothing -> pure ()
        refreshStats
    SaveFailed err -> do
        putModel (\m -> m{gDetail = (gDetail m){dtSaving = False, dtExtractSaving = False}})
        handleApiError err
    ExtractEditStart -> do
        m <- get
        case currentDetail m of
            Nothing -> pure ()
            Just detail ->
                putModel
                    ( \x ->
                        x{gDetail = (gDetail x){dtExtractEditing = True, dtExtractDraft = (bdExtractedText detail), dtExtractDirty = False}}
                    )
                    >> focusElementDelayed "extract-text-editor"
    ExtractEditChanged draft ->
        putModel (\m -> m{gDetail = (gDetail m){dtExtractDraft = draft, dtExtractDirty = True}})
    ExtractEditCancel -> do
        m <- get
        case currentDetail m of
            Nothing -> putModel (\x -> x{gDetail = (gDetail x){dtExtractEditing = False, dtExtractDirty = False}})
            Just detail ->
                putModel
                    ( \x ->
                        x{gDetail = (gDetail x){dtExtractEditing = False, dtExtractDraft = (bdExtractedText detail), dtExtractDirty = False}}
                    )
    ExtractSaved _ -> pure ()
    MarkLinkAlive -> do
        m <- get
        case currentDetail m of
            Nothing -> pure ()
            Just detail -> markLinkAlive (bdId detail) LinkMarkedAlive (\err -> ApiErrorRaised err)
    LinkMarkedAlive -> do
        putModel
            ( \m ->
                m{gDetail = (gDetail m){dtDetail = fmap (\detail -> detail{bdIsDead = False, bdManualAlive = True}) (mDetail m)}}
            )
        notify "Kept alive; automatic checks will skip it" ToastOk
        refreshStats
    RecheckLink -> do
        m <- get
        case currentDetail m of
            Nothing -> pure ()
            Just detail -> recheckLink (bdId detail) LinkRechecked (\err -> ApiErrorRaised err)
    LinkRechecked -> do
        putModel
            ( \m ->
                m{gDetail = (gDetail m){dtDetail = fmap (\detail -> detail{bdManualAlive = False}) (mDetail m)}}
            )
        notify "Automatic checks will run on the next sweep" ToastInfo
    -- A read toggle is its own patch: it must not clear the unsaved note and
    -- it must not claim the note was saved.
    ReadToggled -> do
        m <- get
        case currentDetail m of
            Nothing -> pure ()
            Just detail -> do
                let nextRead = not (bdIsRead detail)
                    requestId = nextRequestId (mReadRequest m)
                putModel
                    ( \x ->
                        x{gDetail = (gDetail x){dtDetail = Just detail{bdIsRead = nextRead}, dtReadRequest = requestId, dtReadPending = True}}
                    )
                patchBookmark
                    (bdId detail)
                    (object ["is_read" .= nextRead])
                    (ReadPatched requestId nextRead)
                    (ReadPatchFailed requestId nextRead)
    -- Only the newest read PATCH may paint: a slow response for an older
    -- toggle is dropped instead of repainting the previous flag.
    ReadPatched requestId readFlag -> do
        m <- get
        when (requestIsCurrent (mReadRequest m) requestId) $ do
            putModel (\x -> x{gDetail = (gDetail x){dtReadPending = False}})
            case currentDetail m of
                Nothing -> pure ()
                Just detail -> putModel (\x -> x{gDetail = (gDetail x){dtDetail = Just detail{bdIsRead = readFlag}}})
            refreshStats
    -- On failure, read the record back from the server rather than guessing
    -- the inverse; an unsaved note keeps its edits and only the flag rolls
    -- back, because reloading the detail would replace the editor.
    ReadPatchFailed requestId readFlag err -> do
        m <- get
        when (requestIsCurrent (mReadRequest m) requestId) $ do
            putModel (\x -> x{gDetail = (gDetail x){dtReadPending = False}})
            case currentDetail m of
                Just detail
                    | hasUnsaved m ->
                        putModel (\x -> x{gDetail = (gDetail x){dtDetail = Just detail{bdIsRead = not readFlag}}})
                    | otherwise -> dispatch (DetailReload (bdId detail))
                Nothing -> pure ()
            handleApiError err
    BacklinksLoaded epoch links -> sameEpoch epoch $ do
        m <- get
        case mRoute m of
            Bookmark _ -> putModel (\x -> x{gDetail = (gDetail x){dtBacklinks = links}})
            _ -> pure ()
    BacklinksFailed epoch err -> sameEpoch epoch (handleApiError err)
    LinkPrev -> putModel (\m -> m{gDetail = (gDetail m){dtLinkSel = max 0 (mLinkSel m - 1)}})
    LinkNext -> do
        m <- get
        let count = length (mLinkResults m)
        putModel (\x -> x{gDetail = (gDetail x){dtLinkSel = if count == 0 then 0 else min (count - 1) (mLinkSel x + 1)}})
    LinkChoose index -> do
        m <- get
        case drop index (mLinkResults m) of
            [] -> pure ()
            (bookmark : _) -> do
                let (newNote, newCursor) = completeWikilink ((mEditNote m)) (mNoteCursor m) (bsTitle bookmark)
                putModel
                    ( \x ->
                        x{gDetail = (gDetail x){dtEditNote = newNote, dtNoteCursor = newCursor, dtLinkQuery = Nothing, dtLinkResults = [], dtDirty = True}}
                    )
                setNoteCursor newCursor
    LinkSuggestions suggestions -> putModel (\m -> m{gDetail = (gDetail m){dtLinkResults = suggestions, dtLinkSel = 0}})
    RunBookmarkAction bookmarkId "snapshot" -> do
        putModel (\m -> m{gDetail = (gDetail m){dtSnapshotBusy = True, dtSnapshotViewerFailed = False}})
        notify "Capturing a snapshot…" ToastInfo
        createSnapshotJob
            bookmarkId
            (SnapshotJobQueued bookmarkId)
            (\err -> SnapshotJobFailed bookmarkId (Just (aeMessage err)))
    RunBookmarkAction bookmarkId verb -> bookmarkAction bookmarkId verb (ToastAdd ((T.toTitle verb <> " queued")) ToastOk) (\err -> ApiErrorRaised err)
    SnapshotJobQueued bookmarkId jobId ->
        dispatch (JobStarted (SnapshotJob bookmarkId) jobId)
    SnapshotJobDone bookmarkId result -> do
        putModel (\m -> m{gDetail = (gDetail m){dtSnapshotBusy = False, dtSnapshotViewerFailed = False}})
        case result of
            Nothing -> notify "The snapshot job returned no result." ToastError
            Just value -> case decodeSnapshotJobResult value of
                Left err -> notify (aeMessage err) ToastError
                Right _report -> do
                    notify "Snapshot captured" ToastOk
                    dispatch (DetailReload bookmarkId)
    SnapshotJobFailed _ message -> do
        putModel (\m -> m{gDetail = (gDetail m){dtSnapshotBusy = False}})
        notify (fromMaybe "The snapshot capture failed." message) ToastError
    SnapshotJobAbandoned _ ->
        putModel (\m -> m{gDetail = (gDetail m){dtSnapshotBusy = False}})
    DeleteBookmarkRequest bookmarkId -> do
        m <- get
        case currentDetail m of
            Just detail | bdId detail == bookmarkId -> putModel (\x -> x{gLedger = (gLedger x){lfConfirmDelete = Just bookmarkId}})
            _ -> pure ()
    DeleteBookmarkCancel -> putModel (\m -> m{gLedger = (gLedger m){lfConfirmDelete = Nothing}})
    DeleteBookmarkConfirm -> do
        m <- get
        putModel (\x -> x{gLedger = (gLedger x){lfConfirmDelete = Nothing}})
        case (mConfirmDelete m, currentDetail m) of
            -- The record stays painted while the write is in flight. Clearing
            -- it here used to make a failed delete look like a successful one:
            -- the page dropped to the "record unavailable" state even though
            -- the server still held the record.
            (Just bookmarkId, Just detail)
                | bdId detail == bookmarkId ->
                    deleteBookmark bookmarkId (DeletedOk bookmarkId) DeleteFailed
            _ -> pure ()
    DeleteBookmark bookmarkId -> do
        m <- get
        case currentDetail m of
            Just detail | bdId detail == bookmarkId -> deleteBookmark bookmarkId (DeletedOk bookmarkId) DeleteFailed
            _ -> pure ()
    DeletedOk bookmarkId -> do
        m <- get
        notify "Bookmark deleted" ToastOk
        refreshTags
        refreshStats
        case mRoute m of
            Bookmark currentId | currentId == bookmarkId -> navigateTo Index
            _ -> reloadList
    DeleteFailed err -> handleApiError err
    DirtyGuardOpen route -> putModel (\m -> m{gShell = (gShell m){sfGuardOpen = True, sfPendingRoute = Just route, sfGuardFromHistory = False}})
    -- Keep editing. When the guard came from a history navigation the address
    -- has already moved to the pending route; put it back without adding a
    -- history entry so the URL matches the record still on screen.
    DirtyGuardClose -> do
        m <- get
        putModel (\x -> x{gShell = (gShell x){sfGuardOpen = False, sfPendingRoute = Nothing, sfGuardFromHistory = False}})
        when (mGuardFromHistory m) $ replaceBrowserRoute (mRoute m)
    DirtyGuardDiscard -> do
        m <- get
        putModel (\x -> x{gShell = (gShell x){sfGuardOpen = False, sfPendingRoute = Nothing, sfGuardFromHistory = False}, gDetail = (gDetail x){dtDirty = False, dtExtractDirty = False, dtExtractEditing = False}})
        case mPendingRoute m of
            Nothing -> pure ()
            -- The address already points at the pending route after a history
            -- navigation, so load it directly instead of pushing a duplicate.
            Just route
                | mGuardFromHistory m -> loadRoute route
                | otherwise -> navigateTo route
    -- import / export -------------------------------------------------------
    HighlightsLoaded epoch highlights -> sameEpoch epoch $ do
        m <- get
        case mRoute m of
            Bookmark _ -> putModel (\x -> x{gDetail = (gDetail x){dtHighlights = highlights}})
            _ -> pure ()
    HighlightsFailed epoch err -> sameEpoch epoch (handleApiError err)
    ReaderMouseUp -> readReaderSelection
    ReaderSelectionFound selection -> putModel (\m -> m{gDetail = (gDetail m){dtReaderSel = selection}})
    ReaderSelectionClear -> putModel (\m -> m{gDetail = (gDetail m){dtReaderSel = Nothing}})
    HighlightCreateQuick -> do
        m <- get
        case (currentDetail m, mReaderSel m) of
            (Just detail, Just selection) ->
                createHighlight
                    (bdId detail)
                    (rsQuote selection)
                    (readerPrefix detail selection)
                    (readerSuffix detail selection)
                    (rsStart selection)
                    (rsEnd selection)
                    ""
                    "yellow"
                    HighlightAdded
                    HighlightFailed
            _ -> notify "Select some reader text first" ToastInfo
    HighlightNoteOpen -> putModel (\m -> m{gDetail = (gDetail m){dtHighlightNoteOpen = True, dtHighlightNote = ""}})
    HighlightNoteInput value -> putModel (\m -> m{gDetail = (gDetail m){dtHighlightNote = value}})
    HighlightNoteCancel -> putModel (\m -> m{gDetail = (gDetail m){dtHighlightNoteOpen = False, dtHighlightNote = ""}})
    HighlightNoteSubmit -> do
        m <- get
        case (currentDetail m, mReaderSel m) of
            (Just detail, Just selection) -> do
                putModel (\x -> x{gDetail = (gDetail x){dtHighlightNoteOpen = False}})
                createHighlight
                    (bdId detail)
                    (rsQuote selection)
                    (readerPrefix detail selection)
                    (readerSuffix detail selection)
                    (rsStart selection)
                    (rsEnd selection)
                    ((mHighlightNote m))
                    "yellow"
                    HighlightAdded
                    HighlightFailed
            _ -> putModel (\x -> x{gDetail = (gDetail x){dtHighlightNoteOpen = False}})
    HighlightAdded highlight -> do
        putModel
            ( \m ->
                m{gDetail = (gDetail m){dtHighlights = insertHighlight highlight (mHighlights m), dtReaderSel = Nothing, dtHighlightNoteOpen = False, dtHighlightNote = ""}}
            )
        notify "Highlight saved" ToastOk
        refreshStats
    HighlightEditStart highlightId -> do
        m <- get
        case [highlight | highlight <- mHighlights m, hId highlight == highlightId] of
            (highlight : _) ->
                putModel
                    ( \x ->
                        x{gDetail = (gDetail x){dtHighlightEdit = Just highlightId, dtHighlightEditNote = (hNote highlight), dtHighlightEditColor = hColor highlight}}
                    )
            [] -> pure ()
    HighlightEditInput value -> putModel (\m -> m{gDetail = (gDetail m){dtHighlightEditNote = value}})
    HighlightEditColor color -> putModel (\m -> m{gDetail = (gDetail m){dtHighlightEditColor = color}})
    HighlightEditCancel -> putModel (\m -> m{gDetail = (gDetail m){dtHighlightEdit = Nothing, dtHighlightEditNote = ""}})
    HighlightEditSave -> do
        m <- get
        case (currentDetail m, mHighlightEdit m) of
            (Just detail, Just highlightId) -> do
                putModel (\x -> x{gDetail = (gDetail x){dtHighlightEdit = Nothing}})
                patchHighlight
                    (bdId detail)
                    highlightId
                    (Just ((mHighlightEditNote m)))
                    (Just (mHighlightEditColor m))
                    HighlightPatched
                    HighlightFailed
            _ -> putModel (\x -> x{gDetail = (gDetail x){dtHighlightEdit = Nothing}})
    HighlightDelete highlightId -> do
        m <- get
        case currentDetail m of
            Just detail -> deleteHighlight (bdId detail) highlightId HighlightDeleted HighlightFailed
            Nothing -> pure ()
    HighlightPatched -> do
        notify "Highlight updated" ToastOk
        reloadHighlights
    HighlightDeleted -> do
        notify "Highlight deleted" ToastOk
        reloadHighlights
        refreshStats
    HighlightFailed err -> handleApiError err
    -- sharing --------------------------------------------------------------
    SharesLoaded epoch shares -> sameEpoch epoch $ do
        putModel
            ( \m ->
                m{gShares = (gShares m){srShares = shares, srSharesLoading = False, srSharesError = Nothing}}
            )
    SharesFailed epoch err -> sameEpoch epoch $ do
        putModel (\m -> m{gShares = (gShares m){srSharesLoading = False, srSharesError = Just ((aeMessage err))}})
        handleApiError err
    ShareDialogOpen -> do
        m <- get
        case currentDetail m of
            Just _ -> do
                let epoch = mDetailEpoch m
                putModel
                    ( \x ->
                        x{gShares = (gShares x){srShareDialogOpen = True, srShareIncludeNote = False, srShareExpiryDays = 30, srShareUrl = Nothing, srShareBusy = False, srSharesLoading = True, srSharesError = Nothing}}
                    )
                fetchShares (\shares -> SharesLoaded epoch shares) (SharesFailed epoch)
            Nothing -> pure ()
    ShareDialogClose -> putModel (\m -> m{gShares = (gShares m){srShareDialogOpen = False, srShareUrl = Nothing}})
    ShareIncludeNoteToggle -> putModel (\m -> m{gShares = (gShares m){srShareIncludeNote = not (mShareIncludeNote m)}})
    ShareExpirySelected days -> putModel (\m -> m{gShares = (gShares m){srShareExpiryDays = days}})
    ShareCreate -> do
        m <- get
        case currentDetail m of
            Just detail -> do
                putModel (\x -> x{gShares = (gShares x){srShareBusy = True}})
                createShareLink
                    "bookmark"
                    (bdId detail)
                    (mShareIncludeNote m)
                    (mShareExpiryDays m)
                    ShareCreated
                    ShareCreateFailed
            Nothing -> pure ()
    ShareCreated shareId url -> do
        putModel (\m -> m{gShares = (gShares m){srShareBusy = False, srShareUrl = Just url}})
        notify (T.pack ("Share link created (#" <> show shareId <> ")")) ToastOk
        refreshShares
        refreshStats
    ShareCreateFailed err -> do
        putModel (\m -> m{gShares = (gShares m){srShareBusy = False}})
        handleApiError err
    ShareCopy url -> copyText ((url :: Text)) "Share link copied" "Copy failed. Select the text instead"
    ShareRevoke shareId -> do
        m <- get
        if mShareBusy m
            then pure ()
            else do
                putModel (\x -> x{gShares = (gShares x){srShareBusy = True}})
                revokeShareLink shareId ShareRevoked ShareCreateFailed
    ShareRevoked -> do
        putModel (\m -> m{gShares = (gShares m){srShareBusy = False}})
        notify "Share link revoked" ToastOk
        refreshShares
        refreshStats
    -- snapshot -------------------------------------------------------------
    SnapshotOpen -> putModel (\m -> m{gDetail = (gDetail m){dtSnapshotOpen = True, dtSnapshotViewerFailed = False}})
    SnapshotClose -> putModel (\m -> m{gDetail = (gDetail m){dtSnapshotOpen = False, dtSnapshotViewerFailed = False}})
    SnapshotViewerFailed -> putModel (\m -> m{gDetail = (gDetail m){dtSnapshotViewerFailed = True}})
    SnapshotViewerRetry -> putModel (\m -> m{gDetail = (gDetail m){dtSnapshotViewerFailed = False}})
    -- ai status ------------------------------------------------------------
    _ -> pure ()
