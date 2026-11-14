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
            x
                { mAddOpen = False
                , mAddBusy = False
                , mAddUrl = ""
                , mAddTitle = ""
                , mAddTags = ""
                , mAddNote = ""
                , mAddError = Nothing
                }
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
        m
            { mDetail = Nothing
            , mDetailLoading = True
            , mDetailError = Nothing
            , mDetailEpoch = epoch
            , mReadRequest = nextRequestId (mReadRequest m)
            , mReadPending = False
            , mEditTitle = ""
            , mEditNote = ""
            , mEditTags = []
            , mNewTag = ""
            , mDirty = False
            , mExtractEditing = False
            , mExtractDraft = ""
            , mExtractDirty = False
            , mExtractSaving = False
            , mNoteMode = NoteWrite
            , mLinkQuery = Nothing
            , mLinkResults = []
            , mBacklinks = []
            , mHighlights = []
            , mHighlightsLoading = True
            , mReaderSel = Nothing
            , mHighlightNoteOpen = False
            , mHighlightNote = ""
            , mHighlightEdit = Nothing
            , mSnapshotOpen = False
            , mShareDialogOpen = False
            , mShareUrl = Nothing
            , mConfirmDelete = Nothing
            }
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
        putModel (\m -> m{mAddOpen = True, mAddError = Nothing})
        focusElementDelayed "add-url"
    AddClose -> putModel (\m -> m{mAddOpen = False, mAddError = Nothing})
    AddUrlInput url -> putModel (\m -> m{mAddUrl = url})
    AddTitleInput title -> putModel (\m -> m{mAddTitle = title})
    AddTagsInput tags -> putModel (\m -> m{mAddTags = tags})
    AddNoteInput note -> putModel (\m -> m{mAddNote = note})
    AddSubmit -> do
        m <- get
        if mAddBusy m
            then pure ()
            else
                if not (isHttpUrlText (mAddUrl m))
                    then putModel (\x -> x{mAddError = Just "Enter a valid http(s) URL."})
                    else do
                        putModel (\x -> x{mAddBusy = True, mAddError = Nothing})
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
        putModel (\m -> m{mAddBusy = False, mAddError = Just ((aeMessage err))})
        handleApiError err
    -- command palette -------------------------------------------------------
    DetailLoaded epoch detail -> sameEpoch epoch $ do
        m <- get
        case mRoute m of
            Bookmark bookmarkId | bookmarkId /= bdId detail -> pure ()
            Bookmark _ ->
                putModel
                    ( \x ->
                        x
                            { mDetail = Just detail
                            , mDetailLoading = False
                            , mDetailError = Nothing
                            , mEditTitle = (bdTitle detail)
                            , mEditNote = (bdNoteBody detail)
                            , mEditTags = bdTags detail
                            , mDirty = False
                            , mExtractEditing = False
                            , mExtractDraft = (bdExtractedText detail)
                            , mExtractDirty = False
                            , mExtractSaving = False
                            , mNoteMode = NoteWrite
                            , mLinkQuery = Nothing
                            , mLinkResults = []
                            }
                    )
            _ -> pure ()
    DetailFailed epoch err -> sameEpoch epoch $ do
        putModel (\m -> m{mDetailLoading = False, mDetail = Nothing, mDetailError = Just ((aeMessage err))})
        handleApiError err
    TitleInput title -> putModel (\m -> m{mEditTitle = title, mDirty = True})
    NoteChanged noteText -> do
        putModel (\m -> m{mEditNote = noteText, mDirty = True})
        readNoteCursor
    NoteCursorRead cursor -> do
        m <- get
        dispatch (NoteMeta cursor (wikilinkQueryAt (mEditNote m) cursor))
    NoteMeta cursor query -> do
        m <- get
        putModel (\x -> x{mNoteCursor = cursor, mLinkQuery = query})
        case query of
            Nothing -> putModel (\x -> x{mLinkResults = []})
            Just rawQuery ->
                if T.null rawQuery
                    then putModel (\x -> x{mLinkResults = take 6 (mItems m)})
                    else fetchAutocomplete rawQuery LinkSuggestions (\_ -> Noop)
    NoteModeChanged mode -> putModel (\m -> m{mNoteMode = mode})
    TagDraftInput draft -> putModel (\m -> m{mNewTag = draft})
    TagAdd -> do
        m <- get
        case parseTagInput (mNewTag m) of
            Nothing -> pure ()
            Just tag ->
                putModel
                    ( \x ->
                        x
                            { mEditTags = if tag `elem` mEditTags x then mEditTags x else mEditTags x ++ [tag]
                            , mNewTag = ""
                            , mDirty = True
                            }
                    )
    TagRemove tag -> putModel (\m -> m{mEditTags = filter (/= tag) (mEditTags m), mDirty = True})
    SaveBookmark -> do
        m <- get
        case currentDetail m of
            Nothing -> pure ()
            Just detail -> do
                putModel (\x -> x{mSaving = True, mExtractSaving = mExtractEditing m})
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
                x
                    { mSaving = False
                    , mExtractSaving = False
                    , mDirty = False
                    , mExtractDirty = False
                    }
            )
        case (mDetail m, mExtractEditing m) of
            (Just detail, True) ->
                putModel
                    ( \x ->
                        x
                            { mDetail = Just (textEditedDetail detail (mExtractDraft m))
                            , mExtractEditing = False
                            , mExtractDraft = mExtractDraft m
                            }
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
        putModel (\m -> m{mSaving = False, mExtractSaving = False})
        handleApiError err
    ExtractEditStart -> do
        m <- get
        case currentDetail m of
            Nothing -> pure ()
            Just detail ->
                putModel
                    ( \x ->
                        x
                            { mExtractEditing = True
                            , mExtractDraft = (bdExtractedText detail)
                            , mExtractDirty = False
                            }
                    )
                    >> focusElementDelayed "extract-text-editor"
    ExtractEditChanged draft ->
        putModel (\m -> m{mExtractDraft = draft, mExtractDirty = True})
    ExtractEditCancel -> do
        m <- get
        case currentDetail m of
            Nothing -> putModel (\x -> x{mExtractEditing = False, mExtractDirty = False})
            Just detail ->
                putModel
                    ( \x ->
                        x
                            { mExtractEditing = False
                            , mExtractDraft = (bdExtractedText detail)
                            , mExtractDirty = False
                            }
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
                m
                    { mDetail =
                        fmap (\detail -> detail{bdIsDead = False, bdManualAlive = True}) (mDetail m)
                    }
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
                m
                    { mDetail =
                        fmap (\detail -> detail{bdManualAlive = False}) (mDetail m)
                    }
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
                        x
                            { mDetail = Just detail{bdIsRead = nextRead}
                            , mReadRequest = requestId
                            , mReadPending = True
                            }
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
            putModel (\x -> x{mReadPending = False})
            case currentDetail m of
                Nothing -> pure ()
                Just detail -> putModel (\x -> x{mDetail = Just detail{bdIsRead = readFlag}})
            refreshStats
    -- On failure, read the record back from the server rather than guessing
    -- the inverse; an unsaved note keeps its edits and only the flag rolls
    -- back, because reloading the detail would replace the editor.
    ReadPatchFailed requestId readFlag err -> do
        m <- get
        when (requestIsCurrent (mReadRequest m) requestId) $ do
            putModel (\x -> x{mReadPending = False})
            case currentDetail m of
                Just detail
                    | hasUnsaved m ->
                        putModel (\x -> x{mDetail = Just detail{bdIsRead = not readFlag}})
                    | otherwise -> dispatch (DetailReload (bdId detail))
                Nothing -> pure ()
            handleApiError err
    OpenToggled -> pure ()
    BacklinksLoaded epoch links -> sameEpoch epoch $ do
        m <- get
        case mRoute m of
            Bookmark _ -> putModel (\x -> x{mBacklinks = links})
            _ -> pure ()
    BacklinksFailed epoch err -> sameEpoch epoch (handleApiError err)
    LinkPrev -> putModel (\m -> m{mLinkSel = max 0 (mLinkSel m - 1)})
    LinkNext -> do
        m <- get
        let count = length (mLinkResults m)
        putModel (\x -> x{mLinkSel = if count == 0 then 0 else min (count - 1) (mLinkSel x + 1)})
    LinkChoose index -> do
        m <- get
        case drop index (mLinkResults m) of
            [] -> pure ()
            (bookmark : _) -> do
                let (newNote, newCursor) = completeWikilink ((mEditNote m)) (mNoteCursor m) (bsTitle bookmark)
                putModel
                    ( \x ->
                        x
                            { mEditNote = newNote
                            , mNoteCursor = newCursor
                            , mLinkQuery = Nothing
                            , mLinkResults = []
                            , mDirty = True
                            }
                    )
                setNoteCursor newCursor
    LinkSuggestions suggestions -> putModel (\m -> m{mLinkResults = suggestions, mLinkSel = 0})
    RunBookmarkAction bookmarkId "snapshot" -> do
        putModel (\m -> m{mSnapshotBusy = True})
        notify "Capturing a snapshot…" ToastInfo
        createSnapshotJob
            bookmarkId
            (SnapshotJobQueued bookmarkId)
            (\err -> SnapshotJobFailed bookmarkId (Just (aeMessage err)))
    RunBookmarkAction bookmarkId verb -> bookmarkAction bookmarkId verb (ToastAdd ((T.toTitle verb <> " queued")) ToastOk) (\err -> ApiErrorRaised err)
    SnapshotJobQueued bookmarkId jobId -> do
        putModel (\m -> m{mSnapshotJob = Just jobId})
        dispatch (JobStarted (SnapshotJob bookmarkId) jobId)
    SnapshotJobDone bookmarkId result -> do
        putModel (\m -> m{mSnapshotBusy = False, mSnapshotJob = Nothing})
        case result of
            Nothing -> notify "The snapshot job returned no result." ToastError
            Just value -> case decodeSnapshotJobResult value of
                Left err -> notify (aeMessage err) ToastError
                Right _report -> do
                    notify "Snapshot captured" ToastOk
                    dispatch (DetailReload bookmarkId)
    SnapshotJobFailed _ message -> do
        putModel (\m -> m{mSnapshotBusy = False, mSnapshotJob = Nothing})
        notify (fromMaybe "The snapshot capture failed." message) ToastError
    SnapshotJobAbandoned _ ->
        putModel (\m -> m{mSnapshotBusy = False, mSnapshotJob = Nothing})
    DeleteBookmarkRequest bookmarkId -> do
        m <- get
        case currentDetail m of
            Just detail | bdId detail == bookmarkId -> putModel (\x -> x{mConfirmDelete = Just bookmarkId})
            _ -> pure ()
    DeleteBookmarkCancel -> putModel (\m -> m{mConfirmDelete = Nothing})
    DeleteBookmarkConfirm -> do
        m <- get
        putModel (\x -> x{mConfirmDelete = Nothing})
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
    DirtyGuardOpen route -> putModel (\m -> m{mGuardOpen = True, mPendingRoute = Just route, mGuardFromHistory = False})
    -- Keep editing. When the guard came from a history navigation the address
    -- has already moved to the pending route; put it back without adding a
    -- history entry so the URL matches the record still on screen.
    DirtyGuardClose -> do
        m <- get
        putModel (\x -> x{mGuardOpen = False, mPendingRoute = Nothing, mGuardFromHistory = False})
        when (mGuardFromHistory m) $ replaceBrowserRoute (mRoute m)
    DirtyGuardDiscard -> do
        m <- get
        putModel (\x -> x{mGuardOpen = False, mPendingRoute = Nothing, mGuardFromHistory = False, mDirty = False, mExtractDirty = False, mExtractEditing = False})
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
            Bookmark _ -> putModel (\x -> x{mHighlights = highlights, mHighlightsLoading = False})
            _ -> pure ()
    HighlightsFailed epoch err -> sameEpoch epoch $ do
        putModel (\m -> m{mHighlightsLoading = False})
        handleApiError err
    ReaderMouseUp -> readReaderSelection
    ReaderSelectionFound selection -> putModel (\m -> m{mReaderSel = selection})
    ReaderSelectionClear -> putModel (\m -> m{mReaderSel = Nothing})
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
    HighlightNoteOpen -> putModel (\m -> m{mHighlightNoteOpen = True, mHighlightNote = ""})
    HighlightNoteInput value -> putModel (\m -> m{mHighlightNote = value})
    HighlightNoteCancel -> putModel (\m -> m{mHighlightNoteOpen = False, mHighlightNote = ""})
    HighlightNoteSubmit -> do
        m <- get
        case (currentDetail m, mReaderSel m) of
            (Just detail, Just selection) -> do
                putModel (\x -> x{mHighlightNoteOpen = False})
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
            _ -> putModel (\x -> x{mHighlightNoteOpen = False})
    HighlightAdded highlight -> do
        putModel
            ( \m ->
                m
                    { mHighlights = insertHighlight highlight (mHighlights m)
                    , mReaderSel = Nothing
                    , mHighlightNoteOpen = False
                    , mHighlightNote = ""
                    }
            )
        notify "Highlight saved" ToastOk
        refreshStats
    HighlightEditStart highlightId -> do
        m <- get
        case [highlight | highlight <- mHighlights m, hId highlight == highlightId] of
            (highlight : _) ->
                putModel
                    ( \x ->
                        x
                            { mHighlightEdit = Just highlightId
                            , mHighlightEditNote = (hNote highlight)
                            , mHighlightEditColor = hColor highlight
                            }
                    )
            [] -> pure ()
    HighlightEditInput value -> putModel (\m -> m{mHighlightEditNote = value})
    HighlightEditColor color -> putModel (\m -> m{mHighlightEditColor = color})
    HighlightEditCancel -> putModel (\m -> m{mHighlightEdit = Nothing, mHighlightEditNote = ""})
    HighlightEditSave -> do
        m <- get
        case (currentDetail m, mHighlightEdit m) of
            (Just detail, Just highlightId) -> do
                putModel (\x -> x{mHighlightEdit = Nothing})
                patchHighlight
                    (bdId detail)
                    highlightId
                    (Just ((mHighlightEditNote m)))
                    (Just (mHighlightEditColor m))
                    HighlightPatched
                    HighlightFailed
            _ -> putModel (\x -> x{mHighlightEdit = Nothing})
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
                m
                    { mShares = shares
                    , mSharesLoading = False
                    , mSharesError = Nothing
                    }
            )
    SharesFailed epoch err -> sameEpoch epoch $ do
        putModel (\m -> m{mSharesLoading = False, mSharesError = Just ((aeMessage err))})
        handleApiError err
    ShareDialogOpen -> do
        m <- get
        case currentDetail m of
            Just _ -> do
                let epoch = mDetailEpoch m
                putModel
                    ( \x ->
                        x
                            { mShareDialogOpen = True
                            , mShareIncludeNote = False
                            , mShareExpiryDays = 30
                            , mShareUrl = Nothing
                            , mShareBusy = False
                            , mSharesLoading = True
                            , mSharesError = Nothing
                            }
                    )
                fetchShares (\shares -> SharesLoaded epoch shares) (SharesFailed epoch)
            Nothing -> pure ()
    ShareDialogClose -> putModel (\m -> m{mShareDialogOpen = False, mShareUrl = Nothing})
    ShareIncludeNoteToggle -> putModel (\m -> m{mShareIncludeNote = not (mShareIncludeNote m)})
    ShareExpirySelected days -> putModel (\m -> m{mShareExpiryDays = days})
    ShareCreate -> do
        m <- get
        case currentDetail m of
            Just detail -> do
                putModel (\x -> x{mShareBusy = True})
                createShareLink
                    "bookmark"
                    (bdId detail)
                    (mShareIncludeNote m)
                    (mShareExpiryDays m)
                    ShareCreated
                    ShareCreateFailed
            Nothing -> pure ()
    ShareCreated shareId url -> do
        putModel (\m -> m{mShareBusy = False, mShareUrl = Just url})
        notify (T.pack ("Share link created (#" <> show shareId <> ")")) ToastOk
        refreshShares
        refreshStats
    ShareCreateFailed err -> do
        putModel (\m -> m{mShareBusy = False})
        handleApiError err
    ShareCopy url -> copyText ((url :: Text)) "Share link copied" "Copy failed. Select the text instead"
    ShareRevoke shareId -> revokeShareLink shareId ShareRevoked ShareCreateFailed
    ShareRevoked -> do
        notify "Share link revoked" ToastOk
        refreshShares
        refreshStats
    -- snapshot -------------------------------------------------------------
    SnapshotOpen -> putModel (\m -> m{mSnapshotOpen = True})
    SnapshotClose -> putModel (\m -> m{mSnapshotOpen = False})
    -- ai status ------------------------------------------------------------
    _ -> pure ()
