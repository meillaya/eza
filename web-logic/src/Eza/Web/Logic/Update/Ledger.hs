{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Part of the client update function; see "Eza.Web.Update".
module Eza.Web.Logic.Update.Ledger (handle) where

import Control.Monad
import qualified Data.IntSet as IS
import qualified Data.Text as T
import Eza.Web.Logic.Effect (nextRequestId, requestIsCurrent)

import Eza.Types
import Eza.Web.Logic.Browser
import Eza.Web.Logic.Error
import qualified Eza.Web.Logic.Ledger as Ledger
import Eza.Web.Logic.Model
import Eza.Web.Logic.Requests
import Eza.Web.Logic.Update.Common
import Eza.Web.Logic.Update.Detail (reloadDetail)
import Eza.Web.Logic.Update.Monad (Update, get, put)

handle :: Action -> Update ()
handle = \case
    StatsLoaded requestId stats -> runLedger (Ledger.StatsLoaded requestId stats)
    StatsFailed requestId err -> runLedger (Ledger.StatsFailed requestId (aeMessage err))
    SearchInput query -> do
        putModel resetShellForSearch
        runLedger (Ledger.SearchInput query)
    SearchCommit -> reloadList
    TimerRegistered timer -> putModel (\m -> m{gLedger = (gLedger m){lfDebounce = Just timer}})
    TimerFired timerId -> fireTimer timerId
    TagToggled tag -> do
        putModel resetShellForReload
        runLedger (Ledger.TagToggled tag)
    ClearFilters -> do
        putModel resetShellForReload
        runLedger Ledger.ClearFilters
    SortSelected sort -> do
        putModel resetShellForReload
        runLedger (Ledger.SortSelected sort)
    UnreadToggled -> do
        putModel resetShellForReload
        runLedger Ledger.UnreadToggled
    ListLoaded append requestId page -> do
        m <- get
        -- A response for an older query no longer paints: the user may have
        -- typed again, changed the sort, or left the list route entirely.
        when (Ledger.listRequestIsCurrent (projectLedger m) requestId) $ do
            runLedger (Ledger.ListLoaded append requestId page)
            putModel (settleLedgerSelection append)
            continueScrollRestore
    ListFailed _append requestId err -> do
        m <- get
        when (Ledger.listRequestIsCurrent (projectLedger m) requestId) $ do
            runLedger (Ledger.ListFailed requestId (aeMessage err))
            putModel (\x -> x{gShell = (gShell x){sfScrollRestore = Nothing}, gLedger = (gLedger x){lfConfirmMarkAll = False}})
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
                    putModel (\x -> x{gLedger = (gLedger x){lfConfirmMarkAll = True}})
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
                    putModel (\x -> x{gLedger = (gLedger x){lfConfirmMarkAll = False, lfBulkBusy = True}})
                    bulkUpdate (BulkMarkRead True) ids MarkAllDone MarkAllFailed
    MarkAllDone updated -> do
        putModel (\m -> m{gLedger = (gLedger m){lfBulkBusy = False, lfConfirmMarkAll = False}})
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
        putModel (\m -> m{gLedger = (gLedger m){lfBulkBusy = False, lfConfirmMarkAll = False}})
        handleApiError err
    SavedSearchApply saved -> do
        putModel
            ( \m ->
                m{gLedger = (gLedger m){lfQ = (ssQ saved), lfTagsFilter = if null (ssTags saved) then mTagsFilter m else ssTags saved}}
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
    SavedSearchNameInput name -> putModel (\m -> m{gLedger = (gLedger m){lfSavedName = name}})
    SavedSearchDelete savedSearchId -> deleteSavedSearch savedSearchId SavedSearchDone SavedSearchFailed
    SavedSearchDone -> do
        notify "Saved searches updated" ToastOk
        putModel (\m -> m{gLedger = (gLedger m){lfSavedName = ""}})
        fetchSavedSearches SavedSearchesLoaded (\_ -> Noop)
    SavedSearchFailed err -> handleApiError err
    SavedSearchesLoaded saved -> putModel (\m -> m{gLedger = (gLedger m){lfSaved = saved}})
    SavedSearchShareOpen saved -> do
        m <- get
        let epoch = mDetailEpoch m
        putModel
            ( \x ->
                x{gLedger = (gLedger x){lfSavedShare = Just saved}, gShares = (gShares x){srShareUrl = Nothing, srShareBusy = False, srSharesLoading = True, srSharesError = Nothing}}
            )
        fetchShares (\shares -> SharesLoaded epoch shares) (SharesFailed epoch)
    SavedSearchShareClose -> putModel (\m -> m{gLedger = (gLedger m){lfSavedShare = Nothing}, gShares = (gShares m){srShareUrl = Nothing}})
    SavedSearchShareCreate -> do
        m <- get
        case mSavedShare m of
            Nothing -> pure ()
            Just saved -> do
                putModel (\x -> x{gShares = (gShares x){srShareBusy = True}})
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
                        putModel (\x -> x{gLedger = (gLedger x){lfSelection = IS.union current (IS.fromList rangeIds)}})
                    Nothing -> pure ()
            _ ->
                let next =
                        if IS.member bookmarkId current
                            then IS.delete bookmarkId current
                            else IS.insert bookmarkId current
                 in putModel (\x -> x{gLedger = (gLedger x){lfSelection = next, lfSelectAnchor = Just bookmarkId}})
    SelectClear -> putModel (\m -> (cancelSelectAllPaging m){gLedger = (gLedger (cancelSelectAllPaging m)){lfSelection = IS.empty, lfSelectAnchor = Nothing}})
    -- Stop the paging run but keep the ids already collected.
    SelectAllMatchingCancel -> putModel cancelSelectAllPaging
    SelectAllLoaded -> do
        m <- get
        putModel (\x -> x{gLedger = (gLedger x){lfSelection = IS.fromList (map bsId (mItems m)), lfSelectAnchor = Nothing}})
    SelectAllMatchingStart -> do
        m <- get
        unless (mSelectingAll m) $ do
            -- Capture the query, filter, sort and list epoch once: the pages
            -- that follow belong to this result set even if the reader types
            -- again or clears the bar.
            let selectEpoch = nextRequestId (mSelectEpoch m)
                params = (listParams m False){lpOffset = 0, lpLimit = 200}
            put
                m{gLedger = (gLedger m){lfSelectingAll = True, lfSelection = IS.empty, lfSelectAnchor = Nothing, lfSelectFetched = 0, lfSelectEpoch = selectEpoch, lfSelectListEpoch = mListEpoch m, lfSelectParams = Just params}}
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
            put m{gLedger = (gLedger m){lfSelection = capped, lfSelectFetched = fetched}}
            if hasMore && IS.size capped < 10000
                then case mSelectParams m of
                    Nothing -> putModel cancelSelectAllPaging
                    Just params ->
                        fetchBookmarks
                            (params{lpOffset = fetched, lpLimit = 200})
                            (\page -> SelectPageLoaded selectEpoch (map bsId (spItems page)) (spHasMore page))
                            (SelectPageFailed selectEpoch)
                else do
                    putModel (\x -> (cancelSelectAllPaging x){gLedger = (gLedger (cancelSelectAllPaging x)){lfSelection = capped}})
                    if IS.size capped >= 10000
                        then notify "Selected the first 10,000 bookmarks" ToastInfo
                        else notify (T.pack ("Selected " <> show (IS.size capped) <> " bookmarks")) ToastOk
    SelectPageFailed selectEpoch err -> do
        m <- get
        when (requestIsCurrent (mSelectEpoch m) selectEpoch) $ do
            putModel cancelSelectAllPaging
            handleApiError err
    BulkTagPromptOpen adding -> do
        putModel (\m -> m{gLedger = (gLedger m){lfTagPrompt = Just adding, lfTagPromptValue = ""}})
        focusElementDelayed "bulk-tag-input"
    BulkTagInput value -> putModel (\m -> m{gLedger = (gLedger m){lfTagPromptValue = value}})
    BulkTagCancel -> putModel (\m -> m{gLedger = (gLedger m){lfTagPrompt = Nothing, lfTagPromptValue = ""}})
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
                        putModel (\x -> x{gLedger = (gLedger x){lfBulkBusy = True, lfTagPrompt = Nothing, lfTagPromptValue = ""}})
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
                putModel (\x -> x{gLedger = (gLedger x){lfBulkBusy = True}})
                bulkUpdate (BulkMarkRead readFlag) ids BulkActionDone BulkActionFailed
    BulkDeleteRequest -> do
        m <- get
        if IS.null (mSelection m)
            then notify "Select at least one bookmark first" ToastInfo
            else putModel (\x -> x{gLedger = (gLedger x){lfConfirmBulkDelete = True}})
    BulkDeleteCancel -> putModel (\m -> m{gLedger = (gLedger m){lfConfirmBulkDelete = False}})
    BulkDeleteConfirm -> do
        m <- get
        putModel (\x -> x{gLedger = (gLedger x){lfConfirmBulkDelete = False, lfBulkBusy = True}})
        bulkUpdate BulkDelete (IS.toList (mSelection m)) BulkActionDone BulkActionFailed
    BulkActionDone updated -> do
        putModel
            ( \m ->
                m{gLedger = (gLedger m){lfSelection = IS.empty, lfSelectAnchor = Nothing, lfSelectingAll = False, lfBulkBusy = False, lfTagPrompt = Nothing, lfTagPromptValue = "", lfConfirmBulkDelete = False}}
            )
        notify (T.pack ("Updated " <> show updated <> " bookmarks")) ToastOk
        reloadList
        refreshTags
        refreshStats
    BulkActionFailed err -> do
        putModel (\m -> m{gLedger = (gLedger m){lfBulkBusy = False}})
        handleApiError err
    RetryEnrich bookmarkId -> do
        putModel
            ( \m ->
                m{gDetail = (gDetail m){dtDetail = fmap (\detail -> detail{bdEnrichState = "queued", bdEnrichError = ""}) (mDetail m)}}
            )
        bookmarkAction bookmarkId "enrich" (DetailReload bookmarkId) (\err -> ApiErrorRaised err)
    DetailReload bookmarkId -> reloadDetail bookmarkId
    -- api tokens -----------------------------------------------------------
    _ -> pure ()
