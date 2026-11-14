{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Part of the client update function; see "Eza.Web.Update".
module Eza.Web.Logic.Update.Dedup (
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

import qualified Data.Text as T
import Eza.Types
import Eza.Web.Logic.Browser
import Eza.Web.Logic.Error
import Eza.Web.Logic.Model
import Eza.Web.Logic.Requests
import Eza.Web.Logic.Update.Common
import Eza.Web.Logic.Update.Monad (Update, get)

accessionLabel :: Int -> Text
accessionLabel bookmarkId =
    "EA-" <> T.pack (replicate (max 0 (5 - length raw)) '0' <> raw)
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
    m{gDedup = (gDedup m){ddDedupUrlGroups = filter ((/= key) . dgKey) (mDedupUrlGroups m), ddDedupTitleGroups = filter ((/= key) . dgKey) (mDedupTitleGroups m), ddDedupCounts = adjustedCounts}}
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

handle :: Action -> Update ()
handle = \case
    DedupLoaded report -> do
        putModel
            ( \m ->
                m{gDedup = (gDedup m){ddDedupCounts = Just (drCounts report), ddDedupUrlGroups = drUrlGroups report, ddDedupTitleGroups = drTitleGroups report, ddDedupLoading = False, ddDedupMoreBusy = False, ddDedupError = Nothing, ddDedupChoice = initialChoices (drUrlGroups report) (drTitleGroups report)}}
            )
    DedupFailed err -> do
        putModel
            ( \m ->
                m{gDedup = (gDedup m){ddDedupLoading = False, ddDedupMoreBusy = False, ddDedupBusy = False, ddDedupError = Just ((aeMessage err))}}
            )
        handleApiError err
    DedupMoreUrl -> do
        m <- get
        when (dedupHasMoreUrl m && not (mDedupMoreBusy m) && not (mDedupLoading m)) $ do
            putModel (\x -> x{gDedup = (gDedup x){ddDedupMoreBusy = True}})
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
            putModel (\x -> x{gDedup = (gDedup x){ddDedupMoreBusy = True}})
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
                    { gDedup =
                        (gDedup m)
                            { ddDedupCounts = Just (drCounts report)
                            , ddDedupUrlGroups =
                                if moreUrls
                                    then mDedupUrlGroups m ++ drUrlGroups report
                                    else mDedupUrlGroups m
                            , ddDedupTitleGroups =
                                if moreUrls
                                    then mDedupTitleGroups m
                                    else mDedupTitleGroups m ++ drTitleGroups report
                            , ddDedupMoreBusy = False
                            , ddDedupError = Nothing
                            , ddDedupChoice =
                                addDedupChoices
                                    (drUrlGroups report ++ drTitleGroups report)
                                    (mDedupChoice m)
                            }
                    }
            )
    DedupKeep key bookmarkId -> putModel (\m -> m{gDedup = (gDedup m){ddDedupChoice = M.insert key bookmarkId (mDedupChoice m)}})
    DedupMerge key -> do
        m <- get
        case dedupGroup m key of
            Just group
                | length (dgItems group) > 1 ->
                    putModel (\x -> x{gDedup = (gDedup x){ddDedupConfirm = Just key}})
            _ -> notify "Nothing to merge in this group" ToastInfo
    DedupMergeCancel -> putModel (\m -> m{gDedup = (gDedup m){ddDedupConfirm = Nothing}})
    DedupRefresh -> do
        putModel (\m -> m{gDedup = (gDedup m){ddDedupLoading = True, ddDedupMoreBusy = False, ddDedupError = Nothing}})
        dedupFirstPage DedupLoaded DedupFailed
    DedupMergeConfirm -> do
        m <- get
        case mDedupConfirm m >>= dedupGroup m of
            Nothing -> putModel (\x -> x{gDedup = (gDedup x){ddDedupConfirm = Nothing}})
            Just group -> case dgItems group of
                [] -> putModel (\x -> x{gDedup = (gDedup x){ddDedupConfirm = Nothing}})
                (firstItem : rest) -> do
                    let kept = fromMaybe (bsId firstItem) (M.lookup (dgKey group) (mDedupChoice m))
                        mergeIds = [bsId item | item <- rest, bsId item /= kept]
                    if null mergeIds
                        then do
                            putModel (\x -> x{gDedup = (gDedup x){ddDedupConfirm = Nothing}})
                            notify "Nothing to merge in this group" ToastInfo
                        else do
                            putModel (\x -> x{gDedup = (gDedup x){ddDedupBusy = True}})
                            mergeDedup
                                kept
                                mergeIds
                                (\(merged, snapshotId) -> DedupMerged (dgKey group) merged kept (if snapshotId > 0 then Just snapshotId else Nothing))
                                DedupFailed
    DedupMerged key merged keeper snapshotId -> do
        putModel
            ( \m ->
                (dropDedupGroup key m){gDedup = (gDedup (dropDedupGroup key m)){ddDedupConfirm = Nothing, ddDedupBusy = False, ddDedupLast = Just (merged, keeper), ddDedupLastSnapshot = snapshotId}}
            )
        notify
            ( "Merged "
                <> T.pack (show merged)
                <> (if merged == 1 then " duplicate record into " else " duplicate records into ")
                <> accessionLabel keeper
            )
            ToastOk
        refreshStats
    DedupMergeAllOpen -> putModel (\m -> m{gDedup = (gDedup m){ddDedupMergeAllOpen = True}})
    DedupMergeAllCancel -> putModel (\m -> m{gDedup = (gDedup m){ddDedupMergeAllOpen = False}})
    DedupMergeAllConfirm -> do
        putModel (\m -> m{gDedup = (gDedup m){ddDedupBusy = True}})
        mergeDedupAll DedupMergeAllDone DedupMergeAllFailed
    DedupMergeAllDone report -> do
        putModel
            ( \m ->
                m
                    { gDedup =
                        (gDedup m)
                            { ddDedupMergeAllOpen = False
                            , ddDedupBusy = False
                            , ddDedupMergeAllReport = Just report
                            , ddDedupUrlGroups = []
                            , ddDedupConfirm = Nothing
                            , ddDedupCounts =
                                fmap
                                    (\counts -> counts{dcUrlGroups = 0, dcUrlRecords = 0})
                                    (mDedupCounts m)
                            }
                    }
            )
        notify
            ( T.pack
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
        putModel (\m -> m{gDedup = (gDedup m){ddDedupBusy = False}})
        handleApiError err
    -- tags -----------------------------------------------------------------
    _ -> pure ()
