{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Part of the client update function; see "Eza.Web.Update".
module Eza.Web.Update.Ledger (handle) where

import Control.Monad
import qualified Data.IntSet as IS
import qualified Data.Text as T
import Eza.Web.Logic.Effect (nextRequestId, requestIsCurrent)

import Miso

import Eza.Types
import Eza.Web.Api
import Eza.Web.Error
import Eza.Web.Interpreter
import qualified Eza.Web.Logic.Ledger as Ledger
import Eza.Web.Logic.Model
import Eza.Web.Update.Common (cancelSelectAllPaging, continueScrollRestore, fireTimer, listParams, putModel, refreshStats, refreshTags, reloadList, resetShellForReload, resetShellForSearch, settleLedgerSelection, splitTags)
import Eza.Web.Update.Detail (reloadDetail)

handle :: Action -> Effect () () Model Action
handle = \case
    StatsLoaded requestId stats -> runLedgerAction (Ledger.StatsLoaded requestId stats)
    StatsFailed requestId err -> runLedgerAction (Ledger.StatsFailed requestId (aeMessage err))
    SearchInput query -> do
        putModel resetShellForSearch
        runLedgerAction (Ledger.SearchInput query)
    SearchCommit -> reloadList
    TimerRegistered timer -> putModel (\m -> m{mDebounce = Just timer})
    TimerFired timerId -> fireTimer timerId
    TagToggled tag -> do
        putModel resetShellForReload
        runLedgerAction (Ledger.TagToggled tag)
    ClearFilters -> do
        putModel resetShellForReload
        runLedgerAction Ledger.ClearFilters
    SortSelected sort -> do
        putModel resetShellForReload
        runLedgerAction (Ledger.SortSelected sort)
    UnreadToggled -> do
        putModel resetShellForReload
        runLedgerAction Ledger.UnreadToggled
    ListLoaded append requestId page -> do
        m <- get
        -- A response for an older query no longer paints: the user may have
        -- typed again, changed the sort, or left the list route entirely.
        when (Ledger.listRequestIsCurrent (extractLedger m) requestId) $ do
            runLedgerAction (Ledger.ListLoaded append requestId page)
            putModel (settleLedgerSelection append)
            continueScrollRestore
    ListFailed _append requestId err -> do
        m <- get
        when (Ledger.listRequestIsCurrent (extractLedger m) requestId) $ do
            runLedgerAction (Ledger.ListFailed requestId (aeMessage err))
            putModel (\x -> x{mScrollRestore = Nothing, mConfirmMarkAll = False})
            handleApiError err
    -- The old call sent the first row's id to an id-cutoff endpoint and marked
    -- rows the reader could not see.  Now the client confirms and sends the
    -- explicit ids of the loaded, unread records.
    MarkAllAbove -> do
        m <- get
        let loadedUnread = [bsId bookmark | bookmark <- mItems m, not (bsIsRead bookmark)]
        case loadedUnread of
            [] -> notify "No loaded unread records to mark read." ToastInfo
            ids
                | not (mConfirmMarkAll m) -> do
                    putModel (\x -> x{mConfirmMarkAll = True})
                    notify
                        ( T.pack
                            ( "Mark "
                                <> show (length ids)
                                <> " loaded unread record"
                                <> (if length ids == 1 then "" else "s")
                                <> " read? Click again to confirm."
                            )
                        )
                        ToastInfo
                | otherwise -> do
                    putModel (\x -> x{mConfirmMarkAll = False, mBulkBusy = True})
                    bulkUpdate (BulkMarkRead True) ids MarkAllDone MarkAllFailed
    MarkAllDone updated -> do
        putModel (\m -> m{mBulkBusy = False, mConfirmMarkAll = False})
        notify
            ( T.pack
                ( "Marked "
                    <> show updated
                    <> " record"
                    <> (if updated == 1 then "" else "s")
                    <> " as read"
                )
            )
            ToastOk
        reloadList
        refreshTags
        refreshStats
    MarkAllFailed err -> do
        putModel (\m -> m{mBulkBusy = False, mConfirmMarkAll = False})
        handleApiError err
    SavedSearchApply saved -> do
        putModel
            ( \m ->
                m
                    { mQ = (ssQ saved)
                    , mTagsFilter = if null (ssTags saved) then mTagsFilter m else ssTags saved
                    }
            )
        reloadList
    ExportClicked -> redirect exportUrl
    -- add modal -------------------------------------------------------------
    SavedSearchSave -> do
        m <- get
        let queryText = T.strip ((mQ m))
            explicitName = T.strip ((mSavedName m))
        if T.null queryText && null (mTagsFilter m)
            then notify "Type a search or choose a tag before saving it" ToastInfo
            else do
                let name = if T.null explicitName then mQ m else mSavedName m
                saveSavedSearch name (mQ m) (mTagsFilter m) (\_ -> SavedSearchDone) SavedSearchFailed
    SavedSearchNameInput name -> putModel (\m -> m{mSavedName = name})
    SavedSearchDelete savedSearchId -> deleteSavedSearch savedSearchId SavedSearchDone SavedSearchFailed
    SavedSearchDone -> do
        notify "Saved searches updated" ToastOk
        putModel (\m -> m{mSavedName = ""})
        fetchSavedSearches SavedSearchesLoaded (\_ -> Noop)
    SavedSearchFailed err -> handleApiError err
    SavedSearchesLoaded saved -> putModel (\m -> m{mSaved = saved})
    SavedSearchShareOpen saved -> do
        m <- get
        let epoch = mDetailEpoch m
        putModel
            ( \x ->
                x
                    { mSavedShare = Just saved
                    , mShareUrl = Nothing
                    , mShareBusy = False
                    , mSharesLoading = True
                    , mSharesError = Nothing
                    }
            )
        fetchShares (\shares -> SharesLoaded epoch shares) (SharesFailed epoch)
    SavedSearchShareClose -> putModel (\m -> m{mSavedShare = Nothing, mShareUrl = Nothing})
    SavedSearchShareCreate -> do
        m <- get
        case mSavedShare m of
            Nothing -> pure ()
            Just saved -> do
                putModel (\x -> x{mShareBusy = True})
                createShareLink
                    "saved_search"
                    (ssId saved)
                    False
                    (mShareExpiryDays m)
                    ShareCreated
                    ShareCreateFailed
    -- graph ----------------------------------------------------------------
    SelectToggled bookmarkId shift -> do
        m <- get
        let current = mSelection m
            indexOf :: Int -> Maybe Int
            indexOf target = case [i | (i, item) <- zip [0 :: Int ..] (mItems m), bsId item == target] of
                (i : _) -> Just i
                [] -> Nothing
        case (shift, mSelectAnchor m >>= \anchor -> (,) anchor <$> indexOf anchor) of
            (True, Just (_anchor, anchorIndex)) ->
                case indexOf bookmarkId of
                    Just currentIndex -> do
                        let (from, to) = (min anchorIndex currentIndex, max anchorIndex currentIndex)
                            rangeIds = [bsId item | (i, item) <- zip [0 :: Int ..] (mItems m), i >= from, i <= to]
                        putModel (\x -> x{mSelection = IS.union current (IS.fromList rangeIds)})
                    Nothing -> pure ()
            _ ->
                let next =
                        if IS.member bookmarkId current
                            then IS.delete bookmarkId current
                            else IS.insert bookmarkId current
                 in putModel (\x -> x{mSelection = next, mSelectAnchor = Just bookmarkId})
    SelectClear -> putModel (\m -> (cancelSelectAllPaging m){mSelection = IS.empty, mSelectAnchor = Nothing})
    -- Stop the paging run but keep the ids already collected.
    SelectAllMatchingCancel -> putModel cancelSelectAllPaging
    SelectAllLoaded -> do
        m <- get
        putModel (\x -> x{mSelection = IS.fromList (map bsId (mItems m)), mSelectAnchor = Nothing})
    SelectAllMatchingStart -> do
        m <- get
        unless (mSelectingAll m) $ do
            -- Capture the query, filter, sort and list epoch once: the pages
            -- that follow belong to this result set even if the reader types
            -- again or clears the bar.
            let selectEpoch = nextRequestId (mSelectEpoch m)
                params = (listParams m False){lpOffset = 0, lpLimit = 200}
            put
                m
                    { mSelectingAll = True
                    , mSelection = IS.empty
                    , mSelectAnchor = Nothing
                    , mSelectFetched = 0
                    , mSelectEpoch = selectEpoch
                    , mSelectListEpoch = mListEpoch m
                    , mSelectParams = Just params
                    }
            fetchBookmarks
                params
                (\page -> SelectPageLoaded selectEpoch (map bsId (spItems page)) (spHasMore page))
                (SelectPageFailed selectEpoch)
    -- A page may only extend the run captured by this token and only while the
    -- list still shows the result set the run started on.
    SelectPageLoaded selectEpoch ids hasMore -> do
        m <- get
        when (mSelectingAll m && requestIsCurrent (mSelectEpoch m) selectEpoch && requestIsCurrent (mListEpoch m) (mSelectListEpoch m)) $ do
            let fetched = mSelectFetched m + length ids
                merged = IS.union (mSelection m) (IS.fromList ids)
                capped = if IS.size merged > 10000 then IS.fromList (take 10000 (IS.toList merged)) else merged
            put m{mSelection = capped, mSelectFetched = fetched}
            if hasMore && IS.size capped < 10000
                then case mSelectParams m of
                    Nothing -> putModel cancelSelectAllPaging
                    Just params ->
                        fetchBookmarks
                            (params{lpOffset = fetched, lpLimit = 200})
                            (\page -> SelectPageLoaded selectEpoch (map bsId (spItems page)) (spHasMore page))
                            (SelectPageFailed selectEpoch)
                else do
                    putModel (\x -> (cancelSelectAllPaging x){mSelection = capped})
                    if IS.size capped >= 10000
                        then notify "Selected the first 10,000 bookmarks" ToastInfo
                        else notify (T.pack ("Selected " <> show (IS.size capped) <> " bookmarks")) ToastOk
    SelectPageFailed selectEpoch err -> do
        m <- get
        when (requestIsCurrent (mSelectEpoch m) selectEpoch) $ do
            putModel cancelSelectAllPaging
            handleApiError err
    BulkTagPromptOpen adding -> do
        putModel (\m -> m{mTagPrompt = Just adding, mTagPromptValue = ""})
        focusElementDelayed "bulk-tag-input"
    BulkTagInput value -> putModel (\m -> m{mTagPromptValue = value})
    BulkTagCancel -> putModel (\m -> m{mTagPrompt = Nothing, mTagPromptValue = ""})
    BulkTagSubmit -> do
        m <- get
        let ids = IS.toList (mSelection m)
            tags = splitTags (mTagPromptValue m)
            adding = mTagPrompt m == Just True
        if null ids
            then notify "Select at least one bookmark first" ToastInfo
            else
                if null tags
                    then notify "Type at least one tag" ToastInfo
                    else do
                        putModel (\x -> x{mBulkBusy = True, mTagPrompt = Nothing, mTagPromptValue = ""})
                        bulkUpdate
                            (if adding then BulkAddTags tags else BulkRemoveTags tags)
                            ids
                            BulkActionDone
                            BulkActionFailed
    BulkMark readFlag -> do
        m <- get
        let ids = IS.toList (mSelection m)
        if null ids
            then notify "Select at least one bookmark first" ToastInfo
            else do
                putModel (\x -> x{mBulkBusy = True})
                bulkUpdate (BulkMarkRead readFlag) ids BulkActionDone BulkActionFailed
    BulkDeleteRequest -> do
        m <- get
        if IS.null (mSelection m)
            then notify "Select at least one bookmark first" ToastInfo
            else putModel (\x -> x{mConfirmBulkDelete = True})
    BulkDeleteCancel -> putModel (\m -> m{mConfirmBulkDelete = False})
    BulkDeleteConfirm -> do
        m <- get
        putModel (\x -> x{mConfirmBulkDelete = False, mBulkBusy = True})
        bulkUpdate BulkDelete (IS.toList (mSelection m)) BulkActionDone BulkActionFailed
    BulkActionDone updated -> do
        putModel
            ( \m ->
                m
                    { mSelection = IS.empty
                    , mSelectAnchor = Nothing
                    , mSelectingAll = False
                    , mBulkBusy = False
                    , mTagPrompt = Nothing
                    , mTagPromptValue = ""
                    , mConfirmBulkDelete = False
                    }
            )
        notify (T.pack ("Updated " <> show updated <> " bookmarks")) ToastOk
        reloadList
        refreshTags
        refreshStats
    BulkActionFailed err -> do
        putModel (\m -> m{mBulkBusy = False})
        handleApiError err
    RetryEnrich bookmarkId -> do
        putModel
            ( \m ->
                m
                    { mDetail =
                        fmap (\detail -> detail{bdEnrichState = "queued", bdEnrichError = ""}) (mDetail m)
                    }
            )
        bookmarkAction bookmarkId "enrich" (DetailReload bookmarkId) (\err -> ApiErrorRaised err)
    DetailReload bookmarkId -> reloadDetail bookmarkId
    -- api tokens -----------------------------------------------------------
    _ -> pure ()
