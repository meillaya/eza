{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Part of the client update function; see "Eza.Web.Update".
module Eza.Web.Logic.Update.Tags (handle) where

import Control.Monad
import Data.Maybe (fromMaybe)
import qualified Data.Text as T

import Eza.Web.Logic.Browser
import Eza.Web.Logic.Error
import Eza.Web.Logic.Job (JobKind (..))
import Eza.Web.Logic.Model
import Eza.Web.Logic.Requests
import Eza.Web.Logic.Route (Route (..))
import Eza.Web.Logic.Update.Common
import Eza.Web.Logic.Update.Monad (Update, dispatch, get)

handle :: Action -> Update ()
handle = \case
    TagsRefreshed stats -> putModel (\m -> m{gLedger = (gLedger m){lfTags = stats}})
    TagStatsLoaded stats -> putModel (\m -> m{gLedger = (gLedger m){lfTags = stats}})
    ConsolLoaded groups ->
        putModel (\m -> m{gTags = (gTags m){tgConsol = groups, tgConsolLoading = False, tgConsolError = Nothing}})
    ConsolFailed err -> do
        putModel (\m -> m{gTags = (gTags m){tgConsolLoading = False, tgConsolError = Just ((aeMessage err))}})
        handleApiError err
    TagMerge from into -> mergeTags from into TagMerged TagOpFailed
    TagRenamed old newName -> renameTag old newName TagMerged TagOpFailed
    TagDeleted tag -> deleteTag tag TagMerged TagOpFailed
    TagDialogOpen dialog -> do
        let draft = case dialog of
                TagRenameDialog tag -> tag
                _ -> ""
        putModel
            ( \m ->
                m{gTags = (gTags m){tgTagDialog = Just dialog, tgTagDialogInput = draft, tgTagDialogBusy = False, tgTagDialogError = Nothing}}
            )
        case dialog of
            TagRenameDialog _ -> focusElementDelayed "tag-rename-input"
            _ -> pure ()
    TagDialogInput value -> putModel (\m -> m{gTags = (gTags m){tgTagDialogInput = value}})
    TagDialogDetach -> do
        m <- get
        case mTagDialog m of
            Just (TagDeleteDialog tag) -> do
                putModel (\x -> x{gTags = (gTags x){tgTagDialogBusy = True, tgTagDialogError = Nothing}})
                detachTag tag TagMerged TagOpFailed
            _ -> pure ()
    TagDialogConfirm -> do
        m <- get
        case mTagDialog m of
            Nothing -> pure ()
            Just (TagRenameDialog old) -> do
                let wanted = T.strip ((mTagDialogInput m))
                if T.null wanted
                    then putModel (\x -> x{gTags = (gTags x){tgTagDialogError = Just "Enter a name for the tag."}})
                    else
                        if wanted == old
                            then putModel (\x -> x{gTags = (gTags x){tgTagDialogError = Just "That is already this tag's name."}})
                            else do
                                putModel (\x -> x{gTags = (gTags x){tgTagDialogBusy = True, tgTagDialogError = Nothing}})
                                dispatch (TagRenamed old wanted)
            Just (TagDeleteDialog tag) -> do
                putModel (\x -> x{gTags = (gTags x){tgTagDialogBusy = True, tgTagDialogError = Nothing}})
                dispatch (TagDeleted tag)
            Just (TagMergeDialog from into) -> do
                putModel (\x -> x{gTags = (gTags x){tgTagDialogBusy = True, tgTagDialogError = Nothing}})
                dispatch (TagMerge from into)
    TagDialogClose ->
        putModel
            ( \m ->
                m{gTags = (gTags m){tgTagDialog = Nothing, tgTagDialogInput = "", tgTagDialogBusy = False, tgTagDialogError = Nothing}}
            )
    FilterByTag tag -> do
        putModel (\m -> m{gLedger = (gLedger m){lfTagsFilter = [tag]}})
        dispatch (Navigate Index)
    -- Open the ledger on an explicit query (a history year, day or
    -- source, or a tag from the graph). The query replaces the old one so
    -- the total matches the figure the reader clicked.
    FilterByQuery query -> do
        m <- get
        putModel
            ( \x ->
                x{gLedger = (gLedger x){lfQ = query, lfTagsFilter = [], lfUnreadOnly = False, lfSort = "created"}}
            )
        if mRoute m == Index
            then reloadList
            else dispatch (Navigate Index)
    TagMerged -> do
        putModel
            ( \m ->
                m{gTags = (gTags m){tgTagDialog = Nothing, tgTagDialogInput = "", tgTagDialogBusy = False, tgTagDialogError = Nothing}}
            )
        notify "Tag vocabulary updated" ToastOk
        fetchConsolidation ConsolLoaded ConsolFailed
        refreshTags
        refreshStats
        reloadList
    TagOpFailed err -> do
        putModel (\m -> m{gTags = (gTags m){tgTagDialogBusy = False, tgTagDialogError = Just ((aeMessage err))}})
        when (aeStatus err == Just 401) (handleApiError err)
    -- ai tags ---------------------------------------------------------------
    AiTagSelected tag -> do
        putModel
            ( \m ->
                m{gTags = (gTags m){tgAiTag = tag, tgSuggestions = [], tgSuggestionsLoading = True, tgSuggestionNotice = Nothing, tgSuggestionError = Nothing}}
            )
        createAiSuggestionsJob tag (AiSuggestionsJobQueued tag) (\err -> AiSuggestionsJobFailed (Just (aeMessage err)))
    AiSuggestionsJobQueued scope jobId -> dispatch (JobStarted (AiSuggestionsJob scope) jobId)
    AiSuggestionsJobDone _ result -> case result of
        Nothing -> putModel (\m -> m{gTags = (gTags m){tgSuggestionsLoading = False, tgSuggestionError = Just "The suggestion job returned no result."}})
        Just value -> case decodeAiSuggestionsJobResult value of
            Left err -> putModel (\m -> m{gTags = (gTags m){tgSuggestionsLoading = False, tgSuggestionError = Just (aeMessage err)}})
            Right report ->
                putModel
                    ( \m ->
                        m{gTags = (gTags m){tgSuggestions = asjrSuggestions report, tgSuggestionsLoading = False, tgSuggestionError = Nothing, tgSuggestionNotice = Nothing}}
                    )
    AiSuggestionsJobFailed message ->
        putModel (\m -> m{gTags = (gTags m){tgSuggestionsLoading = False, tgSuggestionError = Just (fromMaybe "The suggestion job failed." message)}})
    AiSuggestionsJobAbandoned -> putModel (\m -> m{gTags = (gTags m){tgSuggestionsLoading = False}})
    AiStatusReload -> fetchAiStatus AiStatusLoaded AiStatusFailed
    AiSuggestRetry -> do
        m <- get
        putModel (\x -> x{gTags = (gTags x){tgSuggestionsLoading = True, tgSuggestionError = Nothing, tgSuggestionNotice = Nothing}})
        createAiSuggestionsJob (mAiTag m) (AiSuggestionsJobQueued (mAiTag m)) (\err -> AiSuggestionsJobFailed (Just (aeMessage err)))
    AiSuggestDiscard ->
        putModel
            ( \m ->
                m{gTags = (gTags m){tgSuggestions = [], tgSuggestionsLoading = False, tgSuggestionNotice = Nothing, tgSuggestionError = Nothing}}
            )
    SuggestionApply bookmarkId tags ->
        applyTagSuggestion bookmarkId tags SuggestionsApplied (\err -> SuggestionApplyFailed err)
    SuggestionApplyFailed err -> do
        putModel (\m -> m{gTags = (gTags m){tgSuggestionError = Just (aeMessage err)}})
        when (aeStatus err == Just 401) (handleApiError err)
    SuggestionsApplied -> do
        notify "Tags applied" ToastOk
        refreshTags
        refreshStats
        m <- get
        putModel (\x -> x{gTags = (gTags x){tgSuggestionsLoading = True, tgSuggestionError = Nothing, tgSuggestionNotice = Nothing}})
        createAiSuggestionsJob (mAiTag m) (AiSuggestionsJobQueued (mAiTag m)) (\err -> AiSuggestionsJobFailed (Just (aeMessage err)))
    -- maintenance ----------------------------------------------------------
    AiStatusLoaded status -> putModel (\m -> m{gTags = (gTags m){tgAiStatus = Just status}})
    AiStatusFailed _ -> pure ()
    -- rules ----------------------------------------------------------------
    _ -> pure ()
