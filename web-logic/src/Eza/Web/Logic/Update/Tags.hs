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
    TagsRefreshed stats -> putModel (\m -> m{mTags = stats})
    TagStatsLoaded stats -> putModel (\m -> m{mTags = stats})
    ConsolLoaded groups ->
        putModel (\m -> m{mConsol = groups, mConsolLoading = False, mConsolError = Nothing})
    ConsolFailed err -> do
        putModel (\m -> m{mConsolLoading = False, mConsolError = Just ((aeMessage err))})
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
                m
                    { mTagDialog = Just dialog
                    , mTagDialogInput = draft
                    , mTagDialogBusy = False
                    , mTagDialogError = Nothing
                    }
            )
        case dialog of
            TagRenameDialog _ -> focusElementDelayed "tag-rename-input"
            _ -> pure ()
    TagDialogInput value -> putModel (\m -> m{mTagDialogInput = value})
    TagDialogDetach -> do
        m <- get
        case mTagDialog m of
            Just (TagDeleteDialog tag) -> do
                putModel (\x -> x{mTagDialogBusy = True, mTagDialogError = Nothing})
                detachTag tag TagMerged TagOpFailed
            _ -> pure ()
    TagDialogConfirm -> do
        m <- get
        case mTagDialog m of
            Nothing -> pure ()
            Just (TagRenameDialog old) -> do
                let wanted = T.strip ((mTagDialogInput m))
                if T.null wanted
                    then putModel (\x -> x{mTagDialogError = Just "Enter a name for the tag."})
                    else
                        if wanted == old
                            then putModel (\x -> x{mTagDialogError = Just "That is already this tag's name."})
                            else do
                                putModel (\x -> x{mTagDialogBusy = True, mTagDialogError = Nothing})
                                dispatch (TagRenamed old wanted)
            Just (TagDeleteDialog tag) -> do
                putModel (\x -> x{mTagDialogBusy = True, mTagDialogError = Nothing})
                dispatch (TagDeleted tag)
            Just (TagMergeDialog from into) -> do
                putModel (\x -> x{mTagDialogBusy = True, mTagDialogError = Nothing})
                dispatch (TagMerge from into)
    TagDialogClose ->
        putModel
            ( \m ->
                m
                    { mTagDialog = Nothing
                    , mTagDialogInput = ""
                    , mTagDialogBusy = False
                    , mTagDialogError = Nothing
                    }
            )
    FilterByTag tag -> do
        putModel (\m -> m{mTagsFilter = [tag]})
        dispatch (Navigate Index)
    -- Open the ledger on an explicit query (a history year, day or
    -- source, or a tag from the graph). The query replaces the old one so
    -- the total matches the figure the reader clicked.
    FilterByQuery query -> do
        m <- get
        putModel
            ( \x ->
                x
                    { mQ = query
                    , mTagsFilter = []
                    , mUnreadOnly = False
                    , mSort = "created"
                    }
            )
        if mRoute m == Index
            then reloadList
            else dispatch (Navigate Index)
    TagMerged -> do
        putModel
            ( \m ->
                m
                    { mTagDialog = Nothing
                    , mTagDialogInput = ""
                    , mTagDialogBusy = False
                    , mTagDialogError = Nothing
                    }
            )
        notify "Tag vocabulary updated" ToastOk
        fetchConsolidation ConsolLoaded ConsolFailed
        refreshTags
        refreshStats
        reloadList
    TagOpFailed err -> do
        putModel (\m -> m{mTagDialogBusy = False, mTagDialogError = Just ((aeMessage err))})
        when (aeStatus err == Just 401) (handleApiError err)
    -- ai tags ---------------------------------------------------------------
    AiTagSelected tag -> do
        putModel
            ( \m ->
                m
                    { mAiTag = tag
                    , mSuggestions = []
                    , mSuggestionsLoading = True
                    , mSuggestionNotice = Nothing
                    , mSuggestionError = Nothing
                    }
            )
        createAiSuggestionsJob tag (AiSuggestionsJobQueued tag) (\err -> AiSuggestionsJobFailed (Just (aeMessage err)))
    AiSuggestionsJobQueued scope jobId -> dispatch (JobStarted (AiSuggestionsJob scope) jobId)
    AiSuggestionsJobDone _ result -> case result of
        Nothing -> putModel (\m -> m{mSuggestionsLoading = False, mSuggestionError = Just "The suggestion job returned no result."})
        Just value -> case decodeAiSuggestionsJobResult value of
            Left err -> putModel (\m -> m{mSuggestionsLoading = False, mSuggestionError = Just (aeMessage err)})
            Right report ->
                putModel
                    ( \m ->
                        m
                            { mSuggestions = asjrSuggestions report
                            , mSuggestionsLoading = False
                            , mSuggestionError = Nothing
                            , mSuggestionNotice = Nothing
                            }
                    )
    AiSuggestionsJobFailed message ->
        putModel (\m -> m{mSuggestionsLoading = False, mSuggestionError = Just (fromMaybe "The suggestion job failed." message)})
    AiSuggestionsJobAbandoned -> putModel (\m -> m{mSuggestionsLoading = False})
    AiStatusReload -> fetchAiStatus AiStatusLoaded AiStatusFailed
    AiSuggestRetry -> do
        m <- get
        putModel (\x -> x{mSuggestionsLoading = True, mSuggestionError = Nothing, mSuggestionNotice = Nothing})
        createAiSuggestionsJob (mAiTag m) (AiSuggestionsJobQueued (mAiTag m)) (\err -> AiSuggestionsJobFailed (Just (aeMessage err)))
    AiSuggestDiscard ->
        putModel
            ( \m ->
                m
                    { mSuggestions = []
                    , mSuggestionsLoading = False
                    , mSuggestionNotice = Nothing
                    , mSuggestionError = Nothing
                    }
            )
    SuggestionApply bookmarkId tags ->
        applyTagSuggestion bookmarkId tags SuggestionsApplied (\err -> SuggestionApplyFailed err)
    SuggestionApplyFailed err -> do
        putModel (\m -> m{mSuggestionError = Just (aeMessage err)})
        when (aeStatus err == Just 401) (handleApiError err)
    SuggestionsApplied -> do
        notify "Tags applied" ToastOk
        refreshTags
        refreshStats
        m <- get
        putModel (\x -> x{mSuggestionsLoading = True, mSuggestionError = Nothing, mSuggestionNotice = Nothing})
        createAiSuggestionsJob (mAiTag m) (AiSuggestionsJobQueued (mAiTag m)) (\err -> AiSuggestionsJobFailed (Just (aeMessage err)))
    -- maintenance ----------------------------------------------------------
    AiStatusLoaded status -> putModel (\m -> m{mAiStatus = Just status})
    AiStatusFailed _ -> pure ()
    -- rules ----------------------------------------------------------------
    _ -> pure ()
