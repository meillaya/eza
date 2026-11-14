{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Part of the client update function; see "Eza.Web.Update".
module Eza.Web.Logic.Update.Maintenance (handle) where

import Data.Maybe (fromMaybe)
import qualified Data.Text as T

import Eza.Types
import Eza.Web.Logic.Browser
import Eza.Web.Logic.Error
import Eza.Web.Logic.Job (JobKind (..))
import Eza.Web.Logic.Model
import Eza.Web.Logic.Requests
import Eza.Web.Logic.Update.Common
import Eza.Web.Logic.Update.Monad (Update, dispatch, get)

handle :: Action -> Update ()
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
        putModel (\m -> m{mPruneError = Just ((aeMessage err))})
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
        notify (T.pack ("Pruned " <> show pruned <> " record(s). Undo is available")) ToastOk
        fetchPruneCandidates PruneLoaded PruneFailed
        refreshTags
        refreshStats
    DeadCheckRun -> do
        putModel (\m -> m{mMaintBusy = True})
        createDeadCheckJob DeadCheckJobQueued MaintFailed
    DeadCheckJobQueued jobId -> dispatch (JobStarted DeadCheckJob jobId)
    DeadCheckJobDone result -> do
        putModel (\m -> m{mMaintBusy = False})
        case result of
            Nothing -> notify "The dead-link check returned no result." ToastError
            Just value -> case decodeDeadCheckJobResult value of
                Left err -> notify (aeMessage err) ToastError
                Right report -> do
                    putModel
                        ( \m ->
                            m
                                { mCheckedCount = Just (dcjrChecked report)
                                , mDeadCount = Just (dcjrDead report)
                                }
                        )
                    notify
                        ( T.pack
                            ( "Checked "
                                <> show (dcjrChecked report)
                                <> " links, "
                                <> show (dcjrDead report)
                                <> " dead"
                            )
                        )
                        ToastOk
                    reloadList
                    refreshStats
    DeadCheckJobFailed message -> do
        putModel (\m -> m{mMaintBusy = False})
        notify (fromMaybe "The dead-link check failed." message) ToastError
    DeadCheckJobAbandoned -> putModel (\m -> m{mMaintBusy = False})
    UndoRefresh -> do
        putModel (\m -> m{mUndoLoading = True, mUndoError = Nothing})
        fetchUndoEntries UndoEntriesLoaded UndoEntriesFailed
    UndoEntriesLoaded entries ->
        putModel (\m -> m{mUndoEntries = entries, mUndoLoading = False, mUndoError = Nothing})
    UndoEntriesFailed err ->
        putModel (\m -> m{mUndoLoading = False, mUndoError = Just ((aeMessage err))})
    UndoPreviewRequest snapshotId -> do
        putModel (\m -> m{mUndoPreview = Nothing, mUndoPreviewLoading = True, mUndoPreviewError = Nothing})
        fetchUndoPreview snapshotId UndoPreviewLoaded UndoPreviewFailed
    UndoPreviewLoaded preview ->
        putModel (\m -> m{mUndoPreview = Just preview, mUndoPreviewLoading = False, mUndoPreviewError = Nothing})
    UndoPreviewFailed err ->
        putModel (\m -> m{mUndoPreviewLoading = False, mUndoPreviewError = Just ((aeMessage err))})
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
            ("Undid " <> urOp result <> "; restored " <> T.pack (show (urRestored result)) <> " row(s)")
            ToastOk
        fetchUndoEntries UndoEntriesLoaded UndoEntriesFailed
        fetchPruneCandidates PruneLoaded PruneFailed
        dedupFirstPage DedupLoaded DedupFailed
        reloadList
        refreshStats
    UndoFailed err -> do
        putModel (\m -> m{mUndoBusy = False, mUndoPreviewError = Just ((aeMessage err))})
    MaintFailed err -> do
        putModel (\m -> m{mMaintBusy = False})
        handleApiError err
    -- account --------------------------------------------------------------
    _ -> pure ()
