{-# LANGUAGE OverloadedStrings #-}

{- | Shared pure update helpers: route predicates, tag input, ledger
selection/cursor state and the small request chains several groups share.

The ledger state machine itself is "Eza.Web.Logic.Ledger"; this module projects
the whole 'Model' into that slice and writes the slice back when a ledger
action runs, so the shell model keeps one store.
-}
module Eza.Web.Logic.Update.Common (
    bootPageMatchesLedger,
    cancelSelectAllPaging,
    completeWikilink,
    continueScrollRestore,
    dedupFirstPage,
    fireTimer,
    firstUrlIn,
    hasUnsaved,
    indexOfBookmark,
    isDetailRoute,
    isHttpUrlText,
    isListRoute,
    isSaveRoute,
    itemAt,
    ledgerScrollTarget,
    listParams,
    loadIndexList,
    loadMore,
    moveCursor,
    parseTagInput,
    projectLedger,
    putModel,
    refreshStats,
    refreshTags,
    reloadList,
    resetShellForReload,
    resetShellForSearch,
    runLedger,
    setCursor,
    settleLedgerSelection,
    splitTags,
    toggleMember,
    wikilinkQueryAt,
) where

import Control.Monad
import qualified Data.IntSet as IS
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T

import Eza.Ledger (LedgerEntry (..))
import Eza.Types

import Eza.Web.Logic.Browser (scrollLedger, scrollRowIntoView)
import Eza.Web.Logic.Effect (TimerId, nextRequestId)
import Eza.Web.Logic.Error (ApiError)
import qualified Eza.Web.Logic.Input as LogicInput
import qualified Eza.Web.Logic.Ledger as Ledger
import Eza.Web.Logic.Model
import Eza.Web.Logic.Requests
import Eza.Web.Logic.Route (Route (..))
import qualified Eza.Web.Logic.Route as ClientRoute
import Eza.Web.Logic.Update.Monad (Update, emit, get, put, putModel)

{- | Run one ledger action: project the model into the native ledger slice,
let the slice reduce, write the slice back, and emit the effects it asks for.
-}
runLedger :: Ledger.LedgerAction -> Update ()
runLedger action = do
    model <- get
    let (ledger, effects) = Ledger.updateLedger (projectLedger model) action
    put (embedLedger ledger model)
    mapM_ emit effects

projectLedger :: Model -> Ledger.LedgerState
projectLedger model =
    Ledger.initialLedgerState
        { Ledger.ldQuery = mQ model
        , Ledger.ldTagFilters = mTagsFilter model
        , Ledger.ldSort = mSort model
        , Ledger.ldUnreadOnly = mUnreadOnly model
        , Ledger.ldRouteUnread = mRoute model == Inbox
        , Ledger.ldLimit = Ledger.defaultLedgerLimit
        , Ledger.ldOffset = mOffset model
        , Ledger.ldItems = mItems model
        , Ledger.ldTotal = mTotal model
        , Ledger.ldYearCounts = mYearHere model
        , Ledger.ldHasMore = mHasMore model
        , Ledger.ldLoading = mLoading model
        , Ledger.ldLoadingMore = mLoadingMore model
        , Ledger.ldError = mError model
        , Ledger.ldListRequest = mListEpoch model
        , Ledger.ldDebounceTimer = mDebounceTimer model
        , Ledger.ldTimerSeq = mTimerSeq model
        , Ledger.ldStats = mStats model
        , Ledger.ldStatsError = mStatsError model
        , Ledger.ldStatsRequest = mStatsEpoch model
        }

embedLedger :: Ledger.LedgerState -> Model -> Model
embedLedger ledger model =
    model
        { mQ = Ledger.ldQuery ledger
        , mTagsFilter = Ledger.ldTagFilters ledger
        , mSort = Ledger.ldSort ledger
        , mUnreadOnly = Ledger.ldUnreadOnly ledger
        , mOffset = Ledger.ldOffset ledger
        , mItems = Ledger.ldItems ledger
        , mTotal = Ledger.ldTotal ledger
        , mYearHere = Ledger.ldYearCounts ledger
        , mHasMore = Ledger.ldHasMore ledger
        , mLoading = Ledger.ldLoading ledger
        , mLoadingMore = Ledger.ldLoadingMore ledger
        , mError = Ledger.ldError ledger
        , mListEpoch = Ledger.ldListRequest ledger
        , mDebounceTimer = Ledger.ldDebounceTimer ledger
        , mTimerSeq = Ledger.ldTimerSeq ledger
        , mStats = Ledger.ldStats ledger
        , mStatsError = Ledger.ldStatsError ledger
        , mStatsEpoch = Ledger.ldStatsRequest ledger
        }

{- | Read the whole library count again after a write, so the masthead and
the panels stop showing a pre-write number.
-}
refreshStats :: Update ()
refreshStats = runLedger Ledger.StatsRequested

{- | The first page of both duplicate sections. The server's defaults are 60
same-URL groups and 40 review-only title groups; the counts in the report always
cover the whole library.
-}
dedupFirstPage :: (DedupReport -> Action) -> (ApiError -> Action) -> Update ()
dedupFirstPage = fetchDedupReport 0 60 0 40

isHttpUrlText :: Text -> Bool
isHttpUrlText value =
    let lowered = T.toLower (T.strip value)
     in "http://" `T.isPrefixOf` lowered || "https://" `T.isPrefixOf` lowered

-- | The native tag-input parser, wrapped for the shell's MisoString field.
splitTags :: Text -> [Text]
splitTags = LogicInput.splitTags

-- | The native one-tag parser, wrapped for the shell's MisoString field.
parseTagInput :: Text -> Maybe Text
parseTagInput = LogicInput.parseTagInput

toggleMember :: (Eq a) => a -> [a] -> [a]
toggleMember x xs
    | x `elem` xs = filter (/= x) xs
    | otherwise = xs ++ [x]

{- | Route predicates live in the native route module; these aliases keep the
shell calling one vocabulary.
-}
isDetailRoute :: Route -> Bool
isDetailRoute = ClientRoute.isDetailRoute

isListRoute :: Route -> Bool
isListRoute = ClientRoute.isListRoute

isSaveRoute :: Route -> Bool
isSaveRoute = ClientRoute.isSaveRoute

listParams :: Model -> Bool -> ListParams
listParams m append =
    defaultListParams
        { lpQ = mQ m
        , lpTags = mTagsFilter m
        , lpSort = mSort m
        , lpUnreadOnly = mRoute m == Inbox || mUnreadOnly m
        , lpOffset = if append then length (mItems m) else 0
        }

{- | Can the default page @/boot@ returns stand in for the current ledger?
Only the unfiltered, newest-filed @/@ view matches the boot query; an inbox
or a searched ledger needs its own request.
-}
bootPageMatchesLedger :: Model -> Bool
bootPageMatchesLedger m =
    mRoute m == Index
        && T.null (T.strip (mQ m))
        && null (mTagsFilter m)
        && mSort m == "created"
        && not (mUnreadOnly m)

{- | The shell half of a ledger reload: the selection, the confirmations and
the boot seed are invalidated by a new result set. The ledger's own loading and
request-id fields are reset by the native reducer, which then emits the fetch.
-}
resetShellForReload :: Model -> Model
resetShellForReload m =
    m
        { mListDeferred = False
        , mBootSeeded = False
        , -- a new result set invalidates the old selection
          mSelection = IS.empty
        , mSelectAnchor = Nothing
        , mSelectingAll = False
        , mSelectFetched = 0
        , mSelectEpoch = nextRequestId (mSelectEpoch m)
        , mSelectParams = Nothing
        , mConfirmMarkAll = False
        , mBulkBusy = False
        , mConfirmBulkDelete = False
        }

{- | The shell half of the search box: the uncommitted query invalidates the
selection at once, but it does not consume the boot seed.
-}
resetShellForSearch :: Model -> Model
resetShellForSearch m =
    m
        { mSelection = IS.empty
        , mSelectAnchor = Nothing
        , mSelectingAll = False
        , mSelectFetched = 0
        , mSelectEpoch = nextRequestId (mSelectEpoch m)
        , mSelectParams = Nothing
        , mConfirmMarkAll = False
        }

{- | The shell half of a list response: a replace clears the selection, an
append keeps it but clamps the keyboard cursor to the rows that now exist.
-}
settleLedgerSelection :: Bool -> Model -> Model
settleLedgerSelection append m =
    m
        { mConfirmMarkAll = False
        , mSelection = if append then mSelection m else IS.empty
        , mSelectAnchor = if append then mSelectAnchor m else Nothing
        , mSelectingAll = if append then mSelectingAll m else False
        , mSelectEpoch = if append then mSelectEpoch m else nextRequestId (mSelectEpoch m)
        , mSelectParams = if append then mSelectParams m else Nothing
        , mLedgerCursor =
            case (append, mLedgerCursor m) of
                (False, _) -> Nothing
                (True, Just idx) | idx < length (mItems m) -> Just idx
                _ -> Nothing
        }

-- | Reload the first page of the current ledger query.
reloadList :: Update ()
reloadList = do
    putModel resetShellForReload
    runLedger Ledger.Reload

{- | Load the ledger for @/@. On the first paint the boot payload already
carries the same default page, so the fetch is deferred until @/boot@ answers
and only issued when the route is filtered or the boot page was consumed
elsewhere.
-}
loadIndexList :: Update ()
loadIndexList = do
    m <- get
    if mBootSeeded m
        then putModel (\x -> x{mBootSeeded = False, mListDeferred = False, mLoading = False, mError = Nothing})
        else
            if not (mBootReady m)
                then putModel (\x -> x{mLoading = True, mListDeferred = True, mError = Nothing})
                else reloadList

{- | Ask the native reducer for the next page. It owns the guards, so the
scroll callback cannot double-fetch.
-}
loadMore :: Update ()
loadMore = runLedger Ledger.LoadMore

{- | A native debounce timer fired. The reducer accepts the id only while it is
still current, so a late fire changes nothing; the shell reset around it
matches the old @DebouncedSearch@ handler.
-}
fireTimer :: TimerId -> Update ()
fireTimer timerId = do
    m <- get
    when (Ledger.debounceTimerIsCurrent (projectLedger m) timerId) $ do
        putModel (\x -> x{mDebounce = Nothing})
        putModel resetShellForReload
        runLedger (Ledger.SearchDebounceElapsed timerId)

refreshTags :: Update ()
refreshTags = fetchTags TagsRefreshed (\_ -> Noop)

-- | Detect an open @[[query@ immediately before the cursor.
wikilinkQueryAt :: Text -> Int -> Maybe Text
wikilinkQueryAt = LogicInput.wikilinkQueryAt

-- | Replace the open @[[query@ with a completed wikilink.
completeWikilink :: Text -> Int -> Text -> (Text, Int)
completeWikilink = LogicInput.completeWikilink

-- | Pick the first http(s) URL out of share_target "text".
firstUrlIn :: Maybe Text -> Text
firstUrlIn value = fromMaybe "" (value >>= LogicInput.firstUrlIn)

{- | A few characters before/after a highlight selection, used by the server
as drift anchors.
-}
hasUnsaved :: Model -> Bool
hasUnsaved m = mDirty m || mExtractDirty m

{- | Reflect a saved manual reading copy in the open record without refetching
the whole detail (which would discard a pending note edit). The server remains
the authority; this only keeps the editor and reading header consistent.
-}
moveCursor :: Int -> Update ()
moveCursor delta = do
    m <- get
    let n = length (mItems m)
    when (n > 0) $ do
        let start = fromMaybe (if delta > 0 then -1 else n) (mLedgerCursor m)
            idx = max 0 (min (n - 1) (start + delta))
        setCursor idx
        when (idx + 8 >= n && mHasMore m) loadMore

setCursor :: Int -> Update ()
setCursor idx = do
    m <- get
    case itemAt (mItems m) idx of
        Nothing -> pure ()
        Just b -> do
            putModel (\x -> x{mLedgerCursor = Just idx, mDrawer = Just (bsId b)})
            if mWidth m < 768
                then scrollRowIntoView ("ledger-row-" <> T.pack (show (bsId b)))
                else do
                    let target = max 0 (ledgerScrollTarget m idx)
                    when (target /= mScrollY m) $ scrollLedger target

-- \| The @scrollTop@ that brings a ledger row into view. The ledger only
--    renders the visible window, so the row may not exist in the DOM yet; the
--    offset comes from the same entry-height table the view uses.
--

ledgerScrollTarget :: Model -> Int -> Int
ledgerScrollTarget m idx =
    let entries = ledgerEntries m
        heights = map (entryHeight (mWidth m)) entries
        offsets = scanl (+) 0 heights
        tops =
            [ (top, height)
            | (entry, top, height) <- zip3 entries offsets heights
            , case entry of
                LedgerRow rowIndex _ -> rowIndex == idx
                LedgerYear _ _ -> False
            ]
        scroll = mScrollY m
        viewport = max 1 (mHeight m)
        visibleTop = scroll
        visibleBottom = scroll + viewport
     in case tops of
            ((top, height) : _)
                | top < visibleTop -> top
                | top + height > visibleBottom -> top + height - viewport + 24
            _ -> scroll

indexOfBookmark :: [BookmarkSummary] -> Int -> Maybe Int
indexOfBookmark items bookmarkId =
    case [i | (i, item) <- zip [0 :: Int ..] items, bsId item == bookmarkId] of
        (i : _) -> Just i
        [] -> Nothing

-- \| Stop the "select all matching" paging chain. Bumping the token makes
-- every response still in flight a no-op, so a cleared or cancelled run
-- cannot repopulate the selection.

cancelSelectAllPaging :: Model -> Model
cancelSelectAllPaging x =
    x
        { mSelectingAll = False
        , mSelectFetched = 0
        , mSelectEpoch = nextRequestId (mSelectEpoch x)
        , mSelectParams = Nothing
        }

-- \| Continue a return-to-position after a list page arrived. If the
-- loaded content cannot reach the saved offset yet, fetch pages until it
-- can (or until the list has no more rows), then set the model offset and
-- the container together.

continueScrollRestore :: Update ()
continueScrollRestore = do
    m <- get
    case mScrollRestore m of
        Nothing -> pure ()
        Just target -> do
            let content = ledgerContentHeight m
                viewport = max 1 (mHeight m)
                maxScroll = max 0 (content - viewport)
                seek = min target maxScroll
            if target <= maxScroll || not (mHasMore m)
                then do
                    putModel (\x -> x{mScrollY = seek, mScrollRestore = Nothing})
                    scrollLedger seek
                else loadMore

itemAt :: [a] -> Int -> Maybe a
itemAt xs i
    | i < 0 = Nothing
    | otherwise = case drop i xs of
        (x : _) -> Just x
        [] -> Nothing
