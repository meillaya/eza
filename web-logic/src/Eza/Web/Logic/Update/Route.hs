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
        m{gShell = (gShell m){sfRoute = route, sfRouted = True, sfScrollY = if enteringList then 0 else mScrollY m, sfScrollRestore = restoreTarget, sfGuardFromHistory = False}, gLedger = (gLedger m){lfListDeferred = isListRoute route && mListDeferred m, lfLoading = isListRoute route, lfLoadingMore = False, lfError = Nothing, lfNotice = Nothing, lfStatsError = Nothing, lfConfirmDelete = Nothing, lfConfirmMarkAll = False, lfSavedShare = Nothing, lfSelection = IS.empty, lfSelectAnchor = Nothing, lfSelectingAll = False, lfSelectFetched = 0, lfSelectEpoch = nextRequestId (mSelectEpoch m), lfSelectParams = Nothing, lfBulkBusy = False, lfTagPrompt = Nothing, lfTagPromptValue = "", lfConfirmBulkDelete = False}, gDetail = (gDetail m){dtDetailEpoch = epoch, dtDetail = if keepDetail then mDetail m else Nothing, dtDetailError = if keepDetail then mDetailError m else Nothing, dtDetailLoading = isDetailRoute route, dtEditTitle = if keepDetail then mEditTitle m else "", dtEditNote = if keepDetail then mEditNote m else "", dtEditTags = if keepDetail then mEditTags m else [], dtNewTag = "", dtNoteMode = NoteWrite, dtNoteCursor = 0, dtLinkQuery = Nothing, dtLinkResults = [], dtLinkSel = 0, dtBacklinks = if keepDetail then mBacklinks m else [], dtHighlights = if keepDetail then mHighlights m else [], dtHighlightsLoading = isDetailRoute route, dtReaderSel = Nothing, dtHighlightNoteOpen = False, dtHighlightNote = "", dtHighlightEdit = Nothing, dtHighlightEditNote = "", dtHighlightEditColor = "yellow", dtSnapshotOpen = False, dtSaving = False, dtDirty = if keepDetail then mDirty m else False, dtExtractEditing = if keepDetail then mExtractEditing m else False, dtExtractDraft = if keepDetail then mExtractDraft m else "", dtExtractDirty = if keepDetail then mExtractDirty m else False, dtExtractSaving = False, dtReadRequest = nextRequestId (mReadRequest m), dtReadPending = False}, gShares = (gShares m){srShares = if keepDetail then mShares m else [], srSharesLoading = False, srSharesError = Nothing, srShareDialogOpen = False, srShareIncludeNote = False, srShareExpiryDays = 30, srShareBusy = False, srShareUrl = Nothing}, gMaint = (gMaint m){mnUndoPreview = Nothing, mnUndoPreviewLoading = False, mnUndoPreviewError = Nothing, mnUndoBusy = False, mnPruneError = Nothing}, gGraph = (gGraph m){grGraphLoading = route == Graph}, gDedup = (gDedup m){ddDedupLoading = route == Dedup, ddDedupError = Nothing, ddDedupConfirm = Nothing, ddDedupLast = Nothing, ddDedupLastSnapshot = Nothing, ddDedupMoreBusy = False, ddDedupBusy = False, ddDedupMergeAllOpen = False, ddDedupMergeAllReport = Nothing}, gTags = (gTags m){tgConsolLoading = route == Tags, tgConsolError = Nothing, tgTagDialog = Nothing, tgTagDialogInput = "", tgTagDialogBusy = False, tgTagDialogError = Nothing, tgSuggestionNotice = Nothing, tgSuggestionError = Nothing, tgAiTag = if route == AiTags then mAiTag m else Nothing, tgSuggestions = if route == AiTags then mSuggestions m else []}, gAccount = (gAccount m){acAccountLoading = route == Account, acAccountError = Nothing, acSecurityUsername = "", acSecurityCurrent = "", acSecurityNew = "", acSecurityConfirm = "", acSecurity2faWanted = False, acSecurityBusy = False, acSecurityError = Nothing, acTokensError = Nothing}, gRules = (gRules m){ruRulesError = Nothing}, gAdd = (gAdd m){adAddOpen = False, adAddBusy = False, adAddError = Nothing, adAddUrl = if isSaveRoute route then mAddUrl m else "", adAddTitle = if isSaveRoute route then mAddTitle m else "", adAddTags = if isSaveRoute route then mAddTags m else "", adAddNote = if isSaveRoute route then mAddNote m else ""}}
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
            putModel (\x -> x{gViews = (gViews x){vwViewsLoading = True, vwViewsError = Nothing}})
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
            putModel (\x -> x{gMaint = (gMaint x){mnUndoLoading = True, mnUndoError = Nothing}})
            fetchPruneCandidates PruneLoaded PruneFailed
            fetchUndoEntries UndoEntriesLoaded UndoEntriesFailed
        Account -> do
            putModel (\x -> x{gAccount = (gAccount x){acTokensLoading = True}, gShares = (gShares x){srSharesLoading = True}, gRules = (gRules x){ruRulesLoading = True}, gWebhooks = (gWebhooks x){wkWebhooksLoading = True}})
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
                    x{gAdd = (gAdd x){adAddUrl = urlFromShare, adAddTitle = titleFromShare, adAddTags = "", adAddNote = noteFromShare, adAddError = Nothing}}
                )
        NotFound -> pure ()

{- | The ledger owns its scroll container now, so the next page is fetched when
that element approaches its end. The window itself does not scroll.
-}
