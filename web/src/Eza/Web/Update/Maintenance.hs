{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Part of the client update function; see "Eza.Web.Update".
module Eza.Web.Update.Maintenance (handle) where

import qualified Data.Text as T

import Miso

import Eza.Types
import Eza.Web.Api
import Eza.Web.Error
import Eza.Web.Interpreter
import Eza.Web.Model
import Eza.Web.Update.Common (dedupFirstPage, putModel, refreshStats, refreshTags, reloadList, toggleMember)

handle :: Action -> Effect () () Model Action
handle = \case
    PruneLoaded items ->
        putModel
            ( \m ->
                m
                    { mPrune = items
                    , mPruneSel = []
                    , mConfirmPrune = False
                    , mPruneError = Nothing
                    }
            )
    PruneFailed err -> do
        putModel (\m -> m{mPruneError = Just (ms (aeMessage err))})
        handleApiError err
    PruneToggle bookmarkId -> putModel (\m -> m{mPruneSel = toggleMember bookmarkId (mPruneSel m)})
    PruneAll -> do
        m <- get
        let allIds = map bsId (mPrune m)
        putModel (\x -> x{mPruneSel = if length (mPruneSel x) == length allIds then [] else allIds})
    PruneRun -> do
        m <- get
        if null (mPruneSel m)
            then notify "Select at least one candidate to prune" ToastInfo
            else
                if not (mConfirmPrune m)
                    then do
                        putModel (\x -> x{mConfirmPrune = True})
                        notify "Prune writes an undo snapshot. Click again to confirm." ToastInfo
                    else do
                        putModel (\x -> x{mMaintBusy = True, mConfirmPrune = False})
                        runPrune (mPruneSel m) PruneDone MaintFailed
    PruneCancel -> putModel (\m -> m{mConfirmPrune = False})
    PruneDone pruned -> do
        putModel (\m -> m{mMaintBusy = False})
        notify (ms ("Pruned " <> show pruned <> " record(s). Undo is available")) ToastOk
        fetchPruneCandidates PruneLoaded PruneFailed
        refreshTags
        refreshStats
    DeadCheckRun -> do
        putModel (\m -> m{mMaintBusy = True})
        checkDead
            (\(checked, newlyDead, totalDead) -> DeadCheckDone checked newlyDead totalDead)
            MaintFailed
    DeadCheckDone checked newlyDead totalDead -> do
        putModel (\m -> m{mMaintBusy = False, mCheckedCount = Just checked, mDeadCount = Just totalDead})
        notify
            (ms ("Checked " <> show checked <> " links, " <> show newlyDead <> " newly dead, " <> show totalDead <> " marked dead"))
            ToastOk
        reloadList
        refreshStats
    UndoRefresh -> do
        putModel (\m -> m{mUndoLoading = True, mUndoError = Nothing})
        fetchUndoEntries UndoEntriesLoaded UndoEntriesFailed
    UndoEntriesLoaded entries ->
        putModel (\m -> m{mUndoEntries = entries, mUndoLoading = False, mUndoError = Nothing})
    UndoEntriesFailed err ->
        putModel (\m -> m{mUndoLoading = False, mUndoError = Just (ms (aeMessage err))})
    UndoPreviewRequest snapshotId -> do
        putModel (\m -> m{mUndoPreview = Nothing, mUndoPreviewLoading = True, mUndoPreviewError = Nothing})
        fetchUndoPreview snapshotId UndoPreviewLoaded UndoPreviewFailed
    UndoPreviewLoaded preview ->
        putModel (\m -> m{mUndoPreview = Just preview, mUndoPreviewLoading = False, mUndoPreviewError = Nothing})
    UndoPreviewFailed err ->
        putModel (\m -> m{mUndoPreviewLoading = False, mUndoPreviewError = Just (ms (aeMessage err))})
    UndoPreviewClose ->
        putModel (\m -> m{mUndoPreview = Nothing, mUndoPreviewLoading = False, mUndoPreviewError = Nothing})
    UndoConfirm snapshotId -> do
        putModel (\m -> m{mUndoBusy = True, mUndoPreviewError = Nothing})
        runUndo snapshotId UndoDone UndoFailed
    UndoDone result -> do
        putModel
            ( \m ->
                m
                    { mUndoBusy = False
                    , mUndoPreview = Nothing
                    , mDedupLast = Nothing
                    , mDedupLastSnapshot = Nothing
                    , mDedupMergeAllReport = Nothing
                    }
            )
        notify
            (ms ("Undid " <> T.unpack (urOp result) <> "; restored " <> show (urRestored result) <> " row(s)"))
            ToastOk
        fetchUndoEntries UndoEntriesLoaded UndoEntriesFailed
        fetchPruneCandidates PruneLoaded PruneFailed
        dedupFirstPage DedupLoaded DedupFailed
        reloadList
        refreshStats
    UndoFailed err -> do
        putModel (\m -> m{mUndoBusy = False, mUndoPreviewError = Just (ms (aeMessage err))})
    MaintFailed err -> do
        putModel (\m -> m{mMaintBusy = False})
        handleApiError err
    -- account --------------------------------------------------------------
    _ -> pure ()
