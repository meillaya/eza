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
                m{gMaint = (gMaint m){mnPrune = items, mnPruneSel = [], mnConfirmPrune = False, mnPruneError = Nothing}}
            )
    PruneFailed err -> do
        putModel (\m -> m{gMaint = (gMaint m){mnPruneError = Just ((aeMessage err))}})
        handleApiError err
    PruneToggle bookmarkId -> putModel (\m -> m{gMaint = (gMaint m){mnPruneSel = toggleMember bookmarkId (mPruneSel m)}})
    PruneAll -> do
        m <- get
        let allIds = map bsId (mPrune m)
        putModel (\x -> x{gMaint = (gMaint x){mnPruneSel = if length (mPruneSel x) == length allIds then [] else allIds}})
    PruneRun -> do
        m <- get
        if null (mPruneSel m)
            then notify "Select at least one candidate to prune" ToastInfo
            else
                if not (mConfirmPrune m)
                    then do
                        putModel (\x -> x{gMaint = (gMaint x){mnConfirmPrune = True}})
                        notify "Prune writes an undo snapshot. Click again to confirm." ToastInfo
                    else do
                        putModel (\x -> x{gMaint = (gMaint x){mnMaintBusy = True, mnConfirmPrune = False}})
                        runPrune (mPruneSel m) PruneDone MaintFailed
    PruneCancel -> putModel (\m -> m{gMaint = (gMaint m){mnConfirmPrune = False}})
    PruneDone pruned -> do
        putModel (\m -> m{gMaint = (gMaint m){mnMaintBusy = False}})
        notify (T.pack ("Pruned " <> show pruned <> " record(s). Undo is available")) ToastOk
        fetchPruneCandidates PruneLoaded PruneFailed
        refreshTags
        refreshStats
    DeadCheckRun -> do
        putModel (\m -> m{gMaint = (gMaint m){mnMaintBusy = True}})
        createDeadCheckJob DeadCheckJobQueued MaintFailed
    DeadCheckJobQueued jobId -> dispatch (JobStarted DeadCheckJob jobId)
    DeadCheckJobDone result -> do
        putModel (\m -> m{gMaint = (gMaint m){mnMaintBusy = False}})
        case result of
            Nothing -> notify "The dead-link check returned no result." ToastError
            Just value -> case decodeDeadCheckJobResult value of
                Left err -> notify (aeMessage err) ToastError
                Right report -> do
                    putModel
                        ( \m ->
                            m{gMaint = (gMaint m){mnCheckedCount = Just (dcjrChecked report), mnDeadCount = Just (dcjrDead report)}}
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
        putModel (\m -> m{gMaint = (gMaint m){mnMaintBusy = False}})
        notify (fromMaybe "The dead-link check failed." message) ToastError
    DeadCheckJobAbandoned -> putModel (\m -> m{gMaint = (gMaint m){mnMaintBusy = False}})
    UndoRefresh -> do
        putModel (\m -> m{gMaint = (gMaint m){mnUndoLoading = True, mnUndoError = Nothing}})
        fetchUndoEntries UndoEntriesLoaded UndoEntriesFailed
    UndoEntriesLoaded entries ->
        putModel (\m -> m{gMaint = (gMaint m){mnUndoEntries = entries, mnUndoLoading = False, mnUndoError = Nothing}})
    UndoEntriesFailed err ->
        putModel (\m -> m{gMaint = (gMaint m){mnUndoLoading = False, mnUndoError = Just ((aeMessage err))}})
    UndoPreviewRequest snapshotId -> do
        putModel (\m -> m{gMaint = (gMaint m){mnUndoPreview = Nothing, mnUndoPreviewLoading = True, mnUndoPreviewError = Nothing}})
        fetchUndoPreview snapshotId UndoPreviewLoaded UndoPreviewFailed
    UndoPreviewLoaded preview ->
        putModel (\m -> m{gMaint = (gMaint m){mnUndoPreview = Just preview, mnUndoPreviewLoading = False, mnUndoPreviewError = Nothing}})
    UndoPreviewFailed err ->
        putModel (\m -> m{gMaint = (gMaint m){mnUndoPreviewLoading = False, mnUndoPreviewError = Just ((aeMessage err))}})
    UndoPreviewClose ->
        putModel (\m -> m{gMaint = (gMaint m){mnUndoPreview = Nothing, mnUndoPreviewLoading = False, mnUndoPreviewError = Nothing}})
    UndoConfirm snapshotId -> do
        putModel (\m -> m{gMaint = (gMaint m){mnUndoBusy = True, mnUndoPreviewError = Nothing}})
        runUndo snapshotId UndoDone UndoFailed
    UndoDone result -> do
        putModel
            ( \m ->
                m{gMaint = (gMaint m){mnUndoBusy = False, mnUndoPreview = Nothing}, gDedup = (gDedup m){ddDedupLast = Nothing, ddDedupLastSnapshot = Nothing, ddDedupMergeAllReport = Nothing}}
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
        putModel (\m -> m{gMaint = (gMaint m){mnUndoBusy = False, mnUndoPreviewError = Just ((aeMessage err))}})
    MaintFailed err -> do
        putModel (\m -> m{gMaint = (gMaint m){mnMaintBusy = False}})
        handleApiError err
    -- account --------------------------------------------------------------
    _ -> pure ()
