{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Part of the client update function; see "Eza.Web.Update".
module Eza.Web.Update.Dedup (
    accessionLabel,
    addDedupChoices,
    dedupGroup,
    dedupHasMoreTitle,
    dedupHasMoreUrl,
    dropDedupGroup,
    handle,
    initialChoices,
) where

import Control.Monad
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Text (Text)

import Miso

import Eza.Types
import Eza.Web.Api
import Eza.Web.Error
import Eza.Web.Interpreter
import Eza.Web.Model
import Eza.Web.Update.Common (dedupFirstPage, putModel, refreshStats)

accessionLabel :: Int -> MisoString
accessionLabel bookmarkId =
    ms ("EA-" <> replicate (max 0 (5 - length raw)) '0' <> raw)
  where
    raw = show bookmarkId

-- Is a layer covering the ledger? A bare letter belongs to that layer, so
-- the palette must not open underneath a dialog.

dedupGroup :: Model -> Text -> Maybe DedupGroup
dedupGroup m key =
    case filter ((== key) . dgKey) (mDedupUrlGroups m ++ mDedupTitleGroups m) of
        (group : _) -> Just group
        [] -> Nothing

dedupHasMoreUrl :: Model -> Bool
dedupHasMoreUrl m = case mDedupCounts m of
    Nothing -> False
    Just counts -> length (mDedupUrlGroups m) < dcUrlGroups counts

dedupHasMoreTitle :: Model -> Bool
dedupHasMoreTitle m = case mDedupCounts m of
    Nothing -> False
    Just counts -> length (mDedupTitleGroups m) < dcTitleGroups counts

-- \| Seed the per-group keeper choices. An explicit choice already made for
-- a group survives a later page or refresh.

addDedupChoices :: [DedupGroup] -> M.Map Text Int -> M.Map Text Int
addDedupChoices groups choices =
    foldl
        ( \acc group -> case dgItems group of
            (firstItem : _) -> M.insertWith (\_ old -> old) (dgKey group) (bsId firstItem) acc
            [] -> acc
        )
        choices
        groups

initialChoices :: [DedupGroup] -> [DedupGroup] -> M.Map Text Int
initialChoices urlGroups titleGroups = addDedupChoices (urlGroups ++ titleGroups) M.empty

-- \| Forget a group the server has merged and drop its records from the
-- exact counts. No refetch: DedupRefresh does that when asked.

dropDedupGroup :: Text -> Model -> Model
dropDedupGroup key m =
    m
        { mDedupUrlGroups = filter ((/= key) . dgKey) (mDedupUrlGroups m)
        , mDedupTitleGroups = filter ((/= key) . dgKey) (mDedupTitleGroups m)
        , mDedupCounts = adjustedCounts
        }
  where
    inUrl = any ((== key) . dgKey) (mDedupUrlGroups m)
    inTitle = any ((== key) . dgKey) (mDedupTitleGroups m)
    size = maybe 0 (length . dgItems) (dedupGroup m key)
    adjustedCounts = case mDedupCounts m of
        Nothing -> Nothing
        Just counts
            | inUrl ->
                Just
                    counts
                        { dcUrlGroups = max 0 (dcUrlGroups counts - 1)
                        , dcUrlRecords = max 0 (dcUrlRecords counts - size)
                        }
            | inTitle ->
                Just
                    counts
                        { dcTitleGroups = max 0 (dcTitleGroups counts - 1)
                        , dcTitleRecords = max 0 (dcTitleRecords counts - size)
                        }
            | otherwise -> Just counts

handle :: Action -> Effect () () Model Action
handle = \case
    DedupLoaded report -> do
        putModel
            ( \m ->
                m
                    { mDedupCounts = Just (drCounts report)
                    , mDedupUrlGroups = drUrlGroups report
                    , mDedupTitleGroups = drTitleGroups report
                    , mDedupLoading = False
                    , mDedupMoreBusy = False
                    , mDedupError = Nothing
                    , mDedupChoice = initialChoices (drUrlGroups report) (drTitleGroups report)
                    }
            )
    DedupFailed err -> do
        putModel
            ( \m ->
                m
                    { mDedupLoading = False
                    , mDedupMoreBusy = False
                    , mDedupBusy = False
                    , mDedupError = Just (ms (aeMessage err))
                    }
            )
        handleApiError err
    DedupMoreUrl -> do
        m <- get
        when (dedupHasMoreUrl m && not (mDedupMoreBusy m) && not (mDedupLoading m)) $ do
            putModel (\x -> x{mDedupMoreBusy = True})
            fetchDedupReport
                (length (mDedupUrlGroups m))
                60
                0
                1
                (DedupMoreLoaded True)
                DedupFailed
    DedupMoreTitle -> do
        m <- get
        when (dedupHasMoreTitle m && not (mDedupMoreBusy m) && not (mDedupLoading m)) $ do
            putModel (\x -> x{mDedupMoreBusy = True})
            fetchDedupReport
                0
                1
                (length (mDedupTitleGroups m))
                40
                (DedupMoreLoaded False)
                DedupFailed
    DedupMoreLoaded moreUrls report ->
        putModel
            ( \m ->
                m
                    { mDedupCounts = Just (drCounts report)
                    , mDedupUrlGroups =
                        if moreUrls
                            then mDedupUrlGroups m ++ drUrlGroups report
                            else mDedupUrlGroups m
                    , mDedupTitleGroups =
                        if moreUrls
                            then mDedupTitleGroups m
                            else mDedupTitleGroups m ++ drTitleGroups report
                    , mDedupMoreBusy = False
                    , mDedupError = Nothing
                    , mDedupChoice =
                        addDedupChoices
                            (drUrlGroups report ++ drTitleGroups report)
                            (mDedupChoice m)
                    }
            )
    DedupKeep key bookmarkId -> putModel (\m -> m{mDedupChoice = M.insert key bookmarkId (mDedupChoice m)})
    DedupMerge key -> do
        m <- get
        case dedupGroup m key of
            Just group
                | length (dgItems group) > 1 ->
                    putModel (\x -> x{mDedupConfirm = Just key})
            _ -> notify "Nothing to merge in this group" ToastInfo
    DedupMergeCancel -> putModel (\m -> m{mDedupConfirm = Nothing})
    DedupRefresh -> do
        putModel (\m -> m{mDedupLoading = True, mDedupMoreBusy = False, mDedupError = Nothing})
        dedupFirstPage DedupLoaded DedupFailed
    DedupMergeConfirm -> do
        m <- get
        case mDedupConfirm m >>= dedupGroup m of
            Nothing -> putModel (\x -> x{mDedupConfirm = Nothing})
            Just group -> case dgItems group of
                [] -> putModel (\x -> x{mDedupConfirm = Nothing})
                (firstItem : rest) -> do
                    let kept = fromMaybe (bsId firstItem) (M.lookup (dgKey group) (mDedupChoice m))
                        mergeIds = [bsId item | item <- rest, bsId item /= kept]
                    if null mergeIds
                        then do
                            putModel (\x -> x{mDedupConfirm = Nothing})
                            notify "Nothing to merge in this group" ToastInfo
                        else do
                            putModel (\x -> x{mDedupBusy = True})
                            mergeDedup
                                kept
                                mergeIds
                                (\(merged, snapshotId) -> DedupMerged (dgKey group) merged kept (if snapshotId > 0 then Just snapshotId else Nothing))
                                DedupFailed
    DedupMerged key merged keeper snapshotId -> do
        putModel
            ( \m ->
                (dropDedupGroup key m)
                    { mDedupConfirm = Nothing
                    , mDedupBusy = False
                    , mDedupLast = Just (merged, keeper)
                    , mDedupLastSnapshot = snapshotId
                    }
            )
        notify
            ( ms
                ( "Merged "
                    <> show merged
                    <> (if merged == 1 then " duplicate record into " else " duplicate records into ")
                    <> fromMisoString (accessionLabel keeper)
                )
            )
            ToastOk
        refreshStats
    DedupMergeAllOpen -> putModel (\m -> m{mDedupMergeAllOpen = True})
    DedupMergeAllCancel -> putModel (\m -> m{mDedupMergeAllOpen = False})
    DedupMergeAllConfirm -> do
        putModel (\m -> m{mDedupBusy = True})
        mergeDedupAll DedupMergeAllDone DedupMergeAllFailed
    DedupMergeAllDone report -> do
        putModel
            ( \m ->
                m
                    { mDedupMergeAllOpen = False
                    , mDedupBusy = False
                    , mDedupMergeAllReport = Just report
                    , mDedupUrlGroups = []
                    , mDedupConfirm = Nothing
                    , mDedupCounts =
                        fmap
                            (\counts -> counts{dcUrlGroups = 0, dcUrlRecords = 0})
                            (mDedupCounts m)
                    }
            )
        notify
            ( ms
                ( "Merged "
                    <> show (dmGroups report)
                    <> " URL duplicate group"
                    <> (if dmGroups report == 1 then "" else "s")
                    <> " ("
                    <> show (dmRecords report)
                    <> " records, snapshot #"
                    <> show (dmSnapshotId report)
                    <> ")"
                )
            )
            ToastOk
        refreshStats
    DedupMergeAllFailed err -> do
        putModel (\m -> m{mDedupBusy = False})
        handleApiError err
    -- tags -----------------------------------------------------------------
    _ -> pure ()
