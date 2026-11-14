{-# LANGUAGE OverloadedStrings #-}

-- | Part of the client update function; see "Eza.Web.Update".
module Eza.Web.Logic.Update.Route (
    loadRoute,
    reloadRoute,
) where

import qualified Data.IntSet as IS
import Data.Maybe
import qualified Data.Text as T
import Eza.Web.Logic.Effect (nextRequestId)

import Eza.Web.Logic.Browser
import Eza.Web.Logic.Model
import Eza.Web.Logic.Requests
import Eza.Web.Logic.Route (Route (..))
import Eza.Web.Logic.Update.Common
import Eza.Web.Logic.Update.Graph (enterGraphRoute)
import Eza.Web.Logic.Update.Monad (Update, get, put)
import Eza.Web.Logic.Update.Views (openSavedView)

-- | Reload the current route: the retry path for panel read errors.
reloadRoute :: Update ()
reloadRoute = do
    m <- get
    loadRoute (mRoute m)

{- | Accept an in-flight detail fetch only while its request epoch is
current.  Every route change starts a new epoch, so a slow response for
the record the reader left behind is dropped rather than painted.
-}
loadRoute :: Route -> Update ()
loadRoute route = do
    m <- get
    let previousRoute = mRoute m
        enteringNewDetail = case route of
            Bookmark bookmarkId -> case previousRoute of
                Bookmark currentId -> currentId /= bookmarkId
                _ -> True
            _ -> True
        enteringList = isListRoute route && not (isListRoute previousRoute)
        -- Returning from a record page restores the ledger position once
        -- enough rows exist again. The first paint starts at the top so the
        -- ledger is never blank while the pages reload.
        restoreTarget
            | enteringList
            , isDetailRoute previousRoute
            , mScrollY m > 0 =
                Just (mScrollY m)
            | otherwise = Nothing
        keepDetail = isDetailRoute route && not enteringNewDetail
        epoch = nextRequestId (mDetailEpoch m)
    put
        m
            { mRoute = route
            , mRouted = True
            , mListDeferred = isListRoute route && mListDeferred m
            , mDetailEpoch = epoch
            , mLoading = isListRoute route
            , mLoadingMore = False
            , mScrollY = if enteringList then 0 else mScrollY m
            , mScrollRestore = restoreTarget
            , mError = Nothing
            , mNotice = Nothing
            , mStatsError = Nothing
            , mDetail = if keepDetail then mDetail m else Nothing
            , mDetailError = if keepDetail then mDetailError m else Nothing
            , mDetailLoading = isDetailRoute route
            , mEditTitle = if keepDetail then mEditTitle m else ""
            , mEditNote = if keepDetail then mEditNote m else ""
            , mEditTags = if keepDetail then mEditTags m else []
            , mNewTag = ""
            , mNoteMode = NoteWrite
            , mNoteCursor = 0
            , mLinkQuery = Nothing
            , mLinkResults = []
            , mLinkSel = 0
            , mBacklinks = if keepDetail then mBacklinks m else []
            , mHighlights = if keepDetail then mHighlights m else []
            , mHighlightsLoading = isDetailRoute route
            , mReaderSel = Nothing
            , mHighlightNoteOpen = False
            , mHighlightNote = ""
            , mHighlightEdit = Nothing
            , mHighlightEditNote = ""
            , mHighlightEditColor = "yellow"
            , mSnapshotOpen = False
            , mShares = if keepDetail then mShares m else []
            , mSharesLoading = False
            , mSharesError = Nothing
            , mShareDialogOpen = False
            , mShareIncludeNote = False
            , mShareExpiryDays = 30
            , mShareBusy = False
            , mShareUrl = Nothing
            , mSaving = False
            , mDirty = if keepDetail then mDirty m else False
            , mExtractEditing = if keepDetail then mExtractEditing m else False
            , mExtractDraft = if keepDetail then mExtractDraft m else ""
            , mExtractDirty = if keepDetail then mExtractDirty m else False
            , mExtractSaving = False
            , mUndoPreview = Nothing
            , mUndoPreviewLoading = False
            , mUndoPreviewError = Nothing
            , mUndoBusy = False
            , mConfirmDelete = Nothing
            , mConfirmMarkAll = False
            , mGraphLoading = route == Graph
            , mDedupLoading = route == Dedup
            , mDedupError = Nothing
            , mConsolLoading = route == Tags
            , mConsolError = Nothing
            , mAccountLoading = route == Account
            , mAccountError = Nothing
            , mSecurityUsername = ""
            , mSecurityCurrent = ""
            , mSecurityNew = ""
            , mSecurityConfirm = ""
            , mSecurity2faWanted = False
            , mSecurityBusy = False
            , mSecurityError = Nothing
            , mSavedShare = Nothing
            , mTagDialog = Nothing
            , mTagDialogInput = ""
            , mTagDialogBusy = False
            , mTagDialogError = Nothing
            , mDedupConfirm = Nothing
            , mDedupLast = Nothing
            , mDedupLastSnapshot = Nothing
            , mDedupMoreBusy = False
            , mDedupBusy = False
            , mDedupMergeAllOpen = False
            , mDedupMergeAllReport = Nothing
            , mSuggestionNotice = Nothing
            , mSuggestionError = Nothing
            , mPruneError = Nothing
            , mTokensError = Nothing
            , mRulesError = Nothing
            , mAiTag = if route == AiTags then mAiTag m else Nothing
            , mSuggestions = if route == AiTags then mSuggestions m else []
            , mSelection = IS.empty
            , mSelectAnchor = Nothing
            , mSelectingAll = False
            , mSelectFetched = 0
            , mSelectEpoch = nextRequestId (mSelectEpoch m)
            , mSelectParams = Nothing
            , mReadRequest = nextRequestId (mReadRequest m)
            , mReadPending = False
            , mGuardFromHistory = False
            , mBulkBusy = False
            , mTagPrompt = Nothing
            , mTagPromptValue = ""
            , mConfirmBulkDelete = False
            , mAddOpen = False
            , mAddBusy = False
            , mAddError = Nothing
            , mAddUrl = if isSaveRoute route then mAddUrl m else ""
            , mAddTitle = if isSaveRoute route then mAddTitle m else ""
            , mAddTags = if isSaveRoute route then mAddTags m else ""
            , mAddNote = if isSaveRoute route then mAddNote m else ""
            }
    setDocumentTitle (documentTitle route)
    case route of
        Index -> loadIndexList
        Inbox -> reloadList
        Bookmark bookmarkId -> do
            fetchDetail bookmarkId (DetailLoaded epoch) (DetailFailed epoch)
            fetchBacklinks bookmarkId (BacklinksLoaded epoch) (BacklinksFailed epoch)
            fetchHighlights bookmarkId (HighlightsLoaded epoch) (HighlightsFailed epoch)
            fetchShares (\shares -> SharesLoaded epoch shares) (SharesFailed epoch)
        Graph -> enterGraphRoute False Nothing 1
        GraphLocal rootKey depth -> enterGraphRoute True (Just rootKey) depth
        Views -> do
            putModel (\x -> x{mViewsLoading = True, mViewsError = Nothing})
            fetchViews ViewsLoaded ViewsFailed
        ViewOpen slug -> openSavedView slug
        Dedup -> dedupFirstPage DedupLoaded DedupFailed
        Tags -> do
            fetchConsolidation ConsolLoaded ConsolFailed
            refreshTags
        AiTags -> do
            refreshTags
            fetchAiStatus AiStatusLoaded (\_ -> Noop)
        Maintenance -> do
            putModel (\x -> x{mUndoLoading = True, mUndoError = Nothing})
            fetchPruneCandidates PruneLoaded PruneFailed
            fetchUndoEntries UndoEntriesLoaded UndoEntriesFailed
        Account -> do
            putModel (\x -> x{mTokensLoading = True, mSharesLoading = True, mRulesLoading = True, mWebhooksLoading = True})
            fetchAccount AccountLoaded AccountFailed
            fetchTokens TokensLoaded TokensFailed
            fetchWebhooks WebhooksLoaded WebhooksFailed
            fetchShares (\shares -> SharesLoaded epoch shares) (SharesFailed epoch)
            fetchRules RulesLoaded RulesFailed
        History -> pure ()
        Save sharedTitle sharedText sharedUrl -> do
            let urlFromShare = case fmap T.strip sharedUrl of
                    Just url | isHttpUrlText url -> url
                    _ -> firstUrlIn sharedText
                titleFromShare = fromMaybe "" sharedTitle
                noteFromShare =
                    fromMaybe "" $
                        case fmap T.strip sharedText of
                            Just shared
                                | T.null shared -> Nothing
                                | "http://" `T.isPrefixOf` shared || "https://" `T.isPrefixOf` shared -> Nothing
                                | otherwise -> Just shared
                            Nothing -> Nothing
            putModel
                ( \x ->
                    x
                        { mAddUrl = urlFromShare
                        , mAddTitle = titleFromShare
                        , mAddTags = ""
                        , mAddNote = noteFromShare
                        , mAddError = Nothing
                        }
                )
        NotFound -> pure ()

{- | The ledger owns its scroll container now, so the next page is fetched when
that element approaches its end. The window itself does not scroll.
-}
