{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The MVU update function: every action's state transition and side effect.
module Eza.Web.Update (updateModel, subscriptions) where

import Control.Monad (join, unless, void, when)
import Data.Aeson (Result (..), Value (..), encode, fromJSON, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.List (nub)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Miso
import qualified Miso.JSON as MJ
import Miso.Router (toURI)

import Eza.Boot (BootPayload (..))
import qualified Eza.GraphMatch as GM
import Eza.SearchQuery (parseSearchQuery)
import Eza.Types (
    BookmarkDetail (..),
    BookmarkSummary (..),
    DedupCounts (..),
    DedupGroup (..),
    DedupMergeAllReport (..),
    DedupReport (..),
    GraphData (..),
    GraphRecord (..),
    Highlight (..),
    ImportReport,
    SavedSearch (..),
    SearchPage (..),
    UndoResult (..),
 )
import Eza.User (UserCreateInput (..), UserCreateResult (..), UserRole (..), UserView (..))
import qualified Eza.View as EV
import Eza.Web.Api
import Eza.Web.Graph
import Eza.Web.Model
import Eza.Web.Types (
    AccountInfo (..),
    ApiError (..),
    ReaderSelection (..),
    Rule (..),
    TokenView (..),
    fieldInt,
 )
import Eza.Webhook (Webhook (..), WebhookInput (..))

{- | Component subscriptions: URL changes (back/forward), window scroll for
the virtualized grid, and window resize for the column count.
-}
subscriptions :: [Sub Model Action]
subscriptions =
    [ uriSub (\uri -> RouteChanged (uriFragment uri) (Right (routeOfUri uri)))
    , windowSub "scroll" emptyDecoder (\() -> Scrolled)
    , windowSub "resize" emptyDecoder (\() -> Resized)
    , -- The keyboard bridge in pwa.js normalises @event.key@ and the modifier
      -- and focus state into one @eza-key@ event. Listening here, on window,
      -- keeps shortcuts working when focus is on <body>; the bridge also
      -- suppresses the browser's own Ctrl/Cmd+K and Ctrl/Cmd+S.
      windowSub "eza-key" ezaKeyDecoder KeyPressed
    , -- Connectivity drives the offline banner.
      windowSub "online" emptyDecoder (\() -> ConnectivityChanged True)
    , windowSub "offline" emptyDecoder (\() -> ConnectivityChanged False)
    ]

{- | Decode the @detail@ object the keyboard bridge puts on the custom event.
Every field is present on the detail object; the decoder keeps the client free
of the DOM and of the deprecated @keyCode@ numbers.
-}
ezaKeyDecoder :: Decoder KeyEvent
ezaKeyDecoder =
    at ["detail"] $
        MJ.withObject "eza-key" $ \o ->
            KeyEvent
                <$> o MJ..: "key"
                <*> (o MJ..:? "shiftKey" MJ..!= False)
                <*> (o MJ..:? "ctrlKey" MJ..!= False)
                <*> (o MJ..:? "metaKey" MJ..!= False)
                <*> (o MJ..:? "altKey" MJ..!= False)
                <*> (o MJ..:? "editable" MJ..!= False)
                <*> (o MJ..:? "row")

-- ---------------------------------------------------------------- helpers --

putModel :: (Model -> Model) -> Effect () () Model Action
putModel f = get >>= put . f

liftSinkIO :: IO () -> Effect () () Model Action
liftSinkIO action = withSink $ \_ -> action

notify :: MisoString -> ToastKind -> Effect () () Model Action
notify message kind = do
    m <- get
    let tid = mToastNext m
        toast = Toast tid message kind
        keep = drop (max 0 (length (mToasts m) - 3)) (mToasts m ++ [toast])
    put m{mToasts = keep, mToastNext = tid + 1}
    withSink $ \sink -> do
        _ <- jsgf "setTimeout" (asyncCallback1 (\_ -> sink (ToastDismiss tid)), 4800 :: Int)
        pure ()

handleApiError :: ApiError -> Effect () () Model Action
handleApiError err = do
    let message = ms (aeMessage err)
    case aeStatus err of
        Just 401 -> do
            putModel (\m -> m{mSignedOut = True})
            notify "Session expired. Sign in again." ToastError
        Just 404 -> do
            putModel (\m -> m{mNotice = Just message})
            notify message ToastInfo
        _ -> notify message ToastError

redirectTo :: MisoString -> IO ()
redirectTo url = do
    location <- jsg "window" ! "location"
    _ <- location # "assign" $ (url :: MisoString)
    pure ()

{- | Focus an input after the VDOM patch that creates the dialog has run.
Focusing in the same update runs before the element exists, which left
focus on the body behind the palette and the add dialog.
-}
focusAfterRender :: MisoString -> IO ()
focusAfterRender domId = do
    _ <- jsgf "setTimeout" (asyncCallback (focus domId), 60 :: Int)
    pure ()

-- | Set the browser tab title from the route.
setDocumentTitle :: MisoString -> IO ()
setDocumentTitle title = do
    document <- jsg ("document" :: MisoString)
    setField document ("title" :: MisoString) title

documentTitle :: Route -> MisoString
documentTitle route = case route of
    Index -> "eza"
    _ -> routeTitle route <> " · eza"

{- | Read the whole library count again after a write, so the masthead and
the panels stop showing a pre-write number.
-}
refreshStats :: Effect () () Model Action
refreshStats = fetchStats StatsRefreshed (\_ -> Noop)

{- | The first page of both duplicate sections. The server's defaults are 60
same-URL groups and 40 review-only title groups; the counts in the report always
cover the whole library.
-}
dedupFirstPage :: (DedupReport -> Action) -> (ApiError -> Action) -> Effect () () Model Action
dedupFirstPage = fetchDedupReport 0 60 0 40

-- | Reload the current route: the retry path for panel read errors.
reloadRoute :: Effect () () Model Action
reloadRoute = do
    m <- get
    loadRoute (mRoute m)

{- | Accept an in-flight detail fetch only while its request epoch is
current.  Every route change starts a new epoch, so a slow response for
the record the reader left behind is dropped rather than painted.
-}
sameEpoch :: Int -> Effect () () Model Action -> Effect () () Model Action
sameEpoch epoch action = do
    m <- get
    when (mDetailEpoch m == epoch) action

{- | The detail record only counts while its route is open.  Save, delete,
read and highlight actions arriving after a navigation are dropped.
-}
currentDetail :: Model -> Maybe BookmarkDetail
currentDetail m = case mRoute m of
    Bookmark bid -> case mDetail m of
        Just detail | bdId detail == bid -> Just detail
        _ -> Nothing
    _ -> Nothing

isHttpUrlText :: MisoString -> Bool
isHttpUrlText value =
    let lowered = T.toLower (T.strip (fromMisoString value))
     in "http://" `T.isPrefixOf` lowered || "https://" `T.isPrefixOf` lowered

splitTags :: MisoString -> [Text]
splitTags raw =
    nub
        [ T.toLower tag
        | tag <- T.words (T.map replaceSep (fromMisoString raw))
        , not (T.null tag)
        ]
  where
    replaceSep c = if c == ',' || c == ';' then ' ' else c

parseTagInput :: MisoString -> Maybe Text
parseTagInput raw =
    let tag = T.toLower (T.strip (fromMisoString raw))
     in if T.null tag then Nothing else Just tag

toggleMember :: (Eq a) => a -> [a] -> [a]
toggleMember x xs
    | x `elem` xs = filter (/= x) xs
    | otherwise = xs ++ [x]

isDetailRoute :: Route -> Bool
isDetailRoute = \case
    Bookmark _ -> True
    _ -> False

isListRoute :: Route -> Bool
isListRoute = \case
    Index -> True
    Inbox -> True
    _ -> False

isSaveRoute :: Route -> Bool
isSaveRoute = \case
    Save{} -> True
    _ -> False

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
        && T.null (T.strip (fromMisoString (mQ m)))
        && null (mTagsFilter m)
        && mSort m == "created"
        && not (mUnreadOnly m)

reloadList :: Effect () () Model Action
reloadList = do
    m <- get
    let epoch = mListEpoch m + 1
    put
        m
            { mLoading = True
            , mLoadingMore = False
            , mError = Nothing
            , mListDeferred = False
            , mBootSeeded = False
            , mListEpoch = epoch
            , -- a new result set invalidates the old selection
              mSelection = IS.empty
            , mSelectAnchor = Nothing
            , mSelectingAll = False
            , mSelectFetched = 0
            , mSelectEpoch = mSelectEpoch m + 1
            , mSelectParams = Nothing
            , mConfirmMarkAll = False
            , mBulkBusy = False
            , mConfirmBulkDelete = False
            }
    fetchBookmarks (listParams m False) (ListLoaded False epoch) (ListFailed False epoch)

{- | Load the ledger for @/@. On the first paint the boot payload already
carries the same default page, so the fetch is deferred until @/boot@ answers
and only issued when the route is filtered or the boot page was consumed
elsewhere.
-}
loadIndexList :: Effect () () Model Action
loadIndexList = do
    m <- get
    if mBootSeeded m
        then putModel (\x -> x{mBootSeeded = False, mListDeferred = False, mLoading = False, mError = Nothing})
        else
            if not (mBootReady m)
                then putModel (\x -> x{mLoading = True, mListDeferred = True, mError = Nothing})
                else reloadList

loadMore :: Effect () () Model Action
loadMore = do
    m <- get
    unless (mLoading m || mLoadingMore m || not (mHasMore m)) $ do
        put m{mLoadingMore = True}
        let epoch = mListEpoch m
        fetchBookmarks (listParams m True) (ListLoaded True epoch) (ListFailed True epoch)

refreshTags :: Effect () () Model Action
refreshTags = fetchTags TagsRefreshed (\_ -> Noop)

loadRoute :: Route -> Effect () () Model Action
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
        epoch = mDetailEpoch m + 1
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
            , mSelectEpoch = mSelectEpoch m + 1
            , mSelectParams = Nothing
            , mReadRequest = mReadRequest m + 1
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
    withSink $ \_ -> setDocumentTitle (documentTitle route)
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
            let urlFromShare = case fmap (T.strip) sharedUrl of
                    Just url | isHttpUrlText (ms (T.unpack url)) -> ms (T.unpack url)
                    _ -> firstUrlIn sharedText
                titleFromShare = ms (fromMaybe "" sharedTitle)
                noteFromShare =
                    ms
                        ( fromMaybe "" $
                            case fmap T.strip sharedText of
                                Just shared
                                    | T.null shared -> Nothing
                                    | "http://" `T.isPrefixOf` shared || "https://" `T.isPrefixOf` shared -> Nothing
                                    | otherwise -> Just shared
                                Nothing -> Nothing
                        )
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
scheduleSearch :: Int -> Effect () () Model Action
scheduleSearch delayMs = do
    m <- get
    put m{mDebounce = Nothing}
    withSink $ \sink -> do
        case mDebounce m of
            Just oldTimer -> void $ jsgf "clearTimeout" (oldTimer :: Int)
            Nothing -> pure ()
        timer <- fromJSValUnchecked =<< jsgf "setTimeout" (asyncCallback1 (\_ -> sink DebouncedSearch), delayMs :: Int)
        sink (TimerRegistered (timer :: Int))

{- | The ledger owns its scroll container now, so the next page is fetched when
that element approaches its end. The window itself does not scroll.
-}
measureGrid :: IO (Maybe (Int, Int, Int))
measureGrid = do
    document <- jsg "document"
    element <- (document # ("querySelector" :: MisoString)) (".ledger" :: MisoString)
    isNothingElement <- isNull element
    if isNothingElement
        then pure Nothing
        else do
            scrollTop <- asDouble =<< getProperty element "scrollTop"
            clientHeight <- asDouble =<< getProperty element "clientHeight"
            pure (Just (round scrollTop, round clientHeight, 0))
  where
    asDouble value = fromMaybe 0 <$> (fromJSVal value :: IO (Maybe Double))

-- | Current navigator.onLine value (true when the API is unavailable).
readOnline :: IO Bool
readOnline = do
    navigator' <- jsg "navigator"
    value <- navigator' ! "onLine"
    online <- fromJSVal value
    pure (fromMaybe True (online :: Maybe Bool))

-- | The real page origin, used to build the account-page bookmarklet.
readOrigin :: IO MisoString
readOrigin = do
    window' <- jsg "window"
    location' <- window' ! "location"
    value <- location' ! "origin"
    origin <- fromJSVal value
    pure (fromMaybe "" (origin :: Maybe MisoString))

{- | The fragment of the current URL, used to make the account tabs addressable:
@/account#sessions@ opens the sessions panel directly.
-}

{- | Record the selected account tab in the fragment without a history entry,
so the back button still leaves the page rather than walking the tabs.
-}
setAccountHash :: MisoString -> IO ()
setAccountHash slug = do
    window' <- jsg "window"
    history' <- window' ! "history"
    location' <- window' ! "location"
    path <- fromJSVal =<< getProperty location' "pathname"
    let pathname :: String
        pathname = case (path :: Maybe MisoString) of
            Just value
                | not (T.null (T.strip (fromMisoString value))) ->
                    fromMisoString value
            _ -> "/account"
    stateValue <- toJSVal (Null :: Value)
    titleValue <- toJSVal ("" :: MisoString)
    urlValue <- toJSVal (ms (pathname <> "#" <> (fromMisoString slug :: String)))
    _ <- history' # ("replaceState" :: MisoString) $ (stateValue, titleValue, urlValue)
    pure ()

readTheme :: IO Theme
readTheme = do
    holder <- jsg "EzaTheme"
    value <- holder # "get" $ ()
    themeM <- fromJSVal value
    pure $ maybe ThemeLight (themeOfMiso . fromMisoStringUnsafe) (themeM :: Maybe MisoString)
  where
    fromMisoStringUnsafe = fromMisoString

-- | Detect an open @[[query@ immediately before the cursor.
wikilinkQueryAt :: Text -> Int -> Maybe Text
wikilinkQueryAt body cursor =
    let before = T.take (max 0 cursor) body
        (prefix, suffix) = T.breakOnEnd "[[" before
     in if T.null prefix
            then Nothing
            else
                if "]]" `T.isInfixOf` suffix || T.any (== '\n') suffix
                    then Nothing
                    else
                        let query = suffix
                         in if T.length query > 80 then Nothing else Just query

-- | Replace the open @[[query@ with a completed wikilink.
completeWikilink :: Text -> Int -> Text -> (Text, Int)
completeWikilink body cursor title =
    let before = T.take (max 0 cursor) body
        (prefix, _) = T.breakOnEnd "[[" before
        start = T.length prefix - 2
        (headPart, _) = T.splitAt (max 0 start) body
        inserted = headPart <> "[[" <> title <> "]] "
        remainder = T.drop cursor body
     in (inserted <> remainder, T.length inserted)

-- | Pick the first http(s) URL out of share_target "text".
firstUrlIn :: Maybe Text -> MisoString
firstUrlIn Nothing = ""
firstUrlIn (Just queryText) =
    fromMaybe "" $
        case filter (\word -> "http://" `T.isPrefixOf` word || "https://" `T.isPrefixOf` word) (T.words queryText) of
            (url : _) -> Just (ms (T.strip url))
            [] -> Nothing

{- | A few characters before/after a highlight selection, used by the server
as drift anchors.
-}
readerPrefix :: BookmarkDetail -> ReaderSelection -> Text
readerPrefix detail selection =
    T.takeEnd 32 (T.take (max 0 (rsStart selection)) (bdExtractedText detail))

readerSuffix :: BookmarkDetail -> ReaderSelection -> Text
readerSuffix detail selection =
    T.take 32 (T.drop (max 0 (rsEnd selection)) (bdExtractedText detail))

-- | Keep highlights sorted by their start offset.
insertHighlight :: Highlight -> [Highlight] -> [Highlight]
insertHighlight highlight highlights =
    takeWhile (\item -> hStartOffset item < hStartOffset highlight) highlights
        ++ [highlight]
        ++ dropWhile (\item -> hStartOffset item < hStartOffset highlight) highlights

-- ------------------------------------------------------------- the update --

{- | Any unsaved edit owns the navigation guard: the note/title/tag editor or
the extracted-text editor. Keep the two flags separate so saving one does not
claim the other was saved.
-}
hasUnsaved :: Model -> Bool
hasUnsaved m = mDirty m || mExtractDirty m

{- | Reflect a saved manual reading copy in the open record without refetching
the whole detail (which would discard a pending note edit). The server remains
the authority; this only keeps the editor and reading header consistent.
-}
textEditedDetail :: BookmarkDetail -> MisoString -> BookmarkDetail
textEditedDetail detail draft =
    detail
        { bdExtractedText = fromMisoString draft
        , bdReadingTimeMinutes =
            let words' = length (T.words (fromMisoString draft))
             in if words' == 0 then 0 else (words' + 219) `div` 220
        , bdEnrichState = "manual"
        , bdEnrichError = ""
        }

updateModel :: Action -> Effect () () Model Action
updateModel = \case
    -- lifecycle -------------------------------------------------------------
    Mounted -> do
        putModel (\m -> m{mBooted = True})
        fetchBoot BootLoaded BootFailed
        withSink $ \sink -> do
            uri <- getURI
            width <- windowInnerWidth
            height <- windowInnerHeight
            theme <- readTheme
            online <- readOnline
            origin <- readOrigin
            sink (ThemeLoaded theme)
            sink (ConnectivityChanged online)
            sink (WindowOriginKnown origin)
            sink (LayoutChanged width height)
            sink (RouteChanged (uriFragment uri) (Right (routeOfUri uri)))
    RouteChanged fragmentText routeResult -> do
        m <- get
        case routeResult of
            Left _ -> loadRoute NotFound
            -- The share-target landing page is a real page now: it renders the
            -- prefilled save form instead of quietly writing a bookmark.
            Right route -> do
                -- The fragment is applied in the same update as the route, so
                -- it cannot land after a tab click and undo it.
                when (route == Account) $
                    putModel (\x -> x{mAccountTab = accountTabFromSlug fragmentText})
                if hasUnsaved m && route /= mRoute m && isDetailRoute (mRoute m)
                    then
                        -- The browser already changed the address before the
                        -- subscription delivered this route. Remember that so
                        -- cancelling can put the address back and discarding
                        -- can avoid a duplicate history entry.
                        put m{mGuardOpen = True, mPendingRoute = Just route, mGuardFromHistory = True}
                    else do
                        -- A history navigation that lands on the rendered
                        -- route (e.g. Forward while the guard is open) closes
                        -- the guard instead of re-deriving it.
                        putModel (\x -> x{mGuardOpen = False, mPendingRoute = Nothing, mGuardFromHistory = False})
                        loadRoute route
    Navigate route -> do
        m <- get
        if route == mRoute m
            then pure ()
            else
                if hasUnsaved m && isDetailRoute (mRoute m)
                    then put m{mGuardOpen = True, mPendingRoute = Just route, mGuardFromHistory = False}
                    else withSink $ \_ -> pushRoute route
    ThemeToggled -> withSink $ \sink -> do
        holder <- jsg "EzaTheme"
        value <- holder # "toggle" $ ()
        themeM <- fromJSVal value
        sink (ThemeLoaded (maybe ThemeLight (themeOfMiso . fromMisoString) (themeM :: Maybe MisoString)))
    ThemeLoaded theme -> putModel (\m -> m{mTheme = theme})
    ConnectivityChanged online -> putModel (\m -> m{mOnline = online})
    WindowOriginKnown origin -> putModel (\m -> m{mWindowOrigin = origin})
    QuickSaved bookmarkId existing -> do
        notify
            ( if existing
                then ms ("Already in your library (#" <> show bookmarkId <> ")")
                else "Saved to eza"
            )
            ToastOk
        reloadList
        refreshTags
        refreshStats
    QuickSaveFailed err -> handleApiError err
    CopyBookmarklet bookmarklet
        | T.null (T.strip (fromMisoString bookmarklet)) ->
            notify "Bookmarklet unavailable." ToastInfo
        | otherwise -> copyText bookmarklet "Bookmarklet copied" "Copy failed. Drag the link instead"
    LayoutChanged width height -> do
        putModel (\m -> m{mWidth = width, mHeight = height})
        withSink $ \sink -> do
            measured <- measureGrid
            sink (ScrollMetrics measured)
    Resized -> do
        withSink $ \sink -> do
            width <- windowInnerWidth
            height <- windowInnerHeight
            measured <- measureGrid
            sink (LayoutChanged width height)
            sink (ScrollMetrics measured)
        m <- get
        when (isGraphRoute (mRoute m)) (measureGraphCanvas GraphMeasured)
    Scrolled -> withSink $ \sink -> do
        measured <- measureGrid
        sink (ScrollMetrics measured)
    ScrollMetrics Nothing -> pure ()
    ScrollMetrics (Just (scrollY, height, gridTop)) -> do
        -- While a return-to-position is still loading pages, the browser fires
        -- scroll events as the container remounts and clamps the saved offset.
        -- Those are not the reader scrolling, so they must not cancel the
        -- restore; only a scroll after the restore has applied may clear it.
        previous <- get
        let restoring = isJust (mScrollRestore previous)
        putModel
            ( \m ->
                m
                    { mScrollY = scrollY
                    , mHeight = height
                    , mGridTop = gridTop
                    , mScrollRestore = if restoring then mScrollRestore m else Nothing
                    }
            )
        m <- get
        let content = gridTop + ledgerContentHeight m
        when
            (mHasMore m && not (mLoading m) && not (mLoadingMore m) && scrollY + height + 600 >= content)
            loadMore
    KeyPressed key -> do
        m <- get
        let withModifier = keCtrl key || keMeta key
            editable = keEditable key
            plain = not withModifier && not (keAlt key)
            ledger = isListRoute (mRoute m)
            -- A dialog owns the keyboard: no page shortcut below runs while a
            -- modal layer is open, so Enter on a dialog button cannot also
            -- open the record behind it.
            modal = hasModalLayer m
            graphKeys = isGraphRoute (mRoute m) && not editable && plain && not modal
            runAction action = updateModel action
        -- event.key is upper case for a shifted letter; the shortcut names
        -- below are the unshifted ones.
        case T.toLower (keKey key) of
            -- Escape closes the top layer from any focus, including a field.
            -- On the graph it clears the filter line first, then the selection.
            "escape"
                | isGraphRoute (mRoute m) && not modal -> graphEscape m
                | otherwise -> closeTopLayer m
            -- The palette keeps the keys that drive its own list while it is
            -- the top layer.
            "enter" | mPaletteOpen m -> runAction PaletteSelect
            "arrowup" | mPaletteOpen m -> runAction PalettePrev
            "arrowdown" | mPaletteOpen m -> runAction PaletteNext
            -- The command palette is reachable from every screen: the command
            -- mods always, Shift+K outside fields, and a bare k off the ledger
            -- (so the hint on the search line is not the only way in).
            "k" | not modal && withModifier -> runAction PaletteOpen
            "k" | not modal && not editable && keShift key -> runAction PaletteOpen
            "k" | not modal && not editable && plain && ledger -> moveCursor (-1)
            "k" | not modal && not editable && plain -> runAction PaletteOpen
            "j" | not modal && not editable && plain && ledger -> moveCursor 1
            -- The search line: focus it from any screen, but never steal a
            -- slash the user is typing into a field.
            "/" | not modal && not editable -> do
                runAction PaletteClose
                liftSinkIO (focus "search-input")
            -- Enter opens the focused row when the keyboard bridge reports
            -- one; otherwise it falls back to the cursor row.
            "enter" | not modal && not editable && ledger ->
                case keRow key of
                    Just bookmarkId -> activateRow bookmarkId
                    Nothing -> openCursorRecord m
            -- The graph keys live on the global bridge so the canvas never
            -- scrolls the panel while panning; pwa.js cancels the browser
            -- default for arrows and zoom keys on the graph canvas.
            "arrowup" | graphKeys -> graphPan 0 (-1) (keShift key)
            "arrowdown" | graphKeys -> graphPan 0 1 (keShift key)
            "arrowleft" | graphKeys -> graphPan (-1) 0 (keShift key)
            "arrowright" | graphKeys -> graphPan 1 0 (keShift key)
            "+" | graphKeys -> runAction GraphZoomIn
            "=" | graphKeys -> runAction GraphZoomIn
            "-" | graphKeys -> runAction GraphZoomOut
            "_" | graphKeys -> runAction GraphZoomOut
            "0" | graphKeys -> runAction GraphFit
            "f" | graphKeys -> runAction GraphFit
            "enter" | graphKeys -> graphOpenSelected m
            "s" | not modal && withModifier && isDetailRoute (mRoute m) -> runAction SaveBookmark
            _ -> pure ()
    Noop -> pure ()
    -- boot ------------------------------------------------------------------
    BootLoaded payload -> do
        putModel
            ( \m ->
                m
                    { mVersion = ms (bpVersion payload)
                    , mOrigin = ms (bpOrigin payload)
                    , mTags = bpTags payload
                    , mStats = Just (bpStats payload)
                    , mSaved = bpSavedSearches payload
                    , mViews = bpViews payload
                    , mBootReady = True
                    }
            )
        -- A cold load of /graph?focus=..&local=1 must keep the URL's scope:
        -- the route already applied local mode, so the default whole-library
        -- view must not overwrite it. A plain /graph load still gets it.
        m0 <- get
        unless (isLocalGraphRoute (mRoute m0)) $
            case defaultGraphView (bpViews payload) of
                Just view -> putModel (applyGraphView view)
                Nothing -> pure ()
        m1 <- get
        -- The boot payload can apply a default graph view after the cold
        -- /graph route has already asked for the standard layout. Ask for the
        -- current preset's layout as well; otherwise the preset is selected
        -- but the plate stays on the previous layout.
        when (isGraphRoute (mRoute m1)) $
            when (fmap fst (mGraphLayoutWire m1) /= Just (mGraphPreset m1)) $
                fetchGraphLayout (mGraphPreset m1) (GraphLayoutLoaded (mGraphPreset m1)) GraphLayoutFailed
        m <- get
        let page = bpInitial payload
            deferred = mListDeferred m
            canSeed =
                bootPageMatchesLedger m
                    && (deferred || not (mRouted m))
        if canSeed
            then
                put
                    m
                        { mItems = spItems page
                        , mTotal = spTotal page
                        , mYearHere = spYearCounts page
                        , mHasMore = spHasMore page
                        , mOffset = spOffset page + length (spItems page)
                        , mLoading = False
                        , mLoadingMore = False
                        , mListDeferred = False
                        , mError = Nothing
                        , mSelection = IS.empty
                        , mSelectAnchor = Nothing
                        , mSelectingAll = False
                        , mConfirmMarkAll = False
                        , mLedgerCursor = Nothing
                        , -- A route loaded before the boot answer consumed the
                          -- seed immediately; a route still to come consumes the
                          -- flag in loadIndexList instead of refetching.
                          mBootSeeded = not deferred
                        }
            else when deferred $ do
                putModel (\x -> x{mListDeferred = False})
                when (isListRoute (mRoute m)) reloadList
    BootFailed err -> do
        m <- get
        let deferred = mListDeferred m
        putModel (\x -> x{mBootReady = True, mListDeferred = False})
        when (deferred && isListRoute (mRoute m)) reloadList
        handleApiError err
        when (aeStatus err == Just 401) $ liftSinkIO (redirectTo "/login")
    ApiUnauthorized -> putModel (\m -> m{mSignedOut = True})
    ApiErrorRaised err -> handleApiError err
    TagsRefreshed stats -> putModel (\m -> m{mTags = stats})
    StatsRefreshed maybeStats -> case maybeStats of
        Nothing -> putModel (\m -> m{mStatsError = Just "The library figures could not be read."})
        Just stats -> putModel (\m -> m{mStats = Just stats, mStatsError = Nothing})
    ReloadRoute -> reloadRoute
    LedgerCursorNext -> moveCursor 1
    LedgerCursorPrev -> moveCursor (-1)
    LedgerCursorSet idx -> setCursor idx
    DrawerOpen bid -> do
        m <- get
        let cursor = case indexOfBookmark (mItems m) bid of
                Just idx -> Just idx
                Nothing -> mLedgerCursor m
        putModel (\x -> x{mDrawer = Just bid, mLedgerCursor = cursor})
    DrawerClose -> putModel (\m -> m{mDrawer = Nothing})
    AccountTabSelected tab -> do
        putModel (\m -> m{mAccountTab = tab})
        liftSinkIO (setAccountHash (accountTabSlug tab))
        when (tab == AccountWebhooks) $ do
            m <- get
            when (null (mWebhooks m) && not (mWebhooksLoading m)) $ do
                putModel (\x -> x{mWebhooksLoading = True, mWebhooksError = Nothing})
                fetchWebhooks WebhooksLoaded WebhooksFailed
        when (tab == AccountUsers) $ do
            m <- get
            when (null (mAdminUsers m) && not (mAdminUsersLoading m)) $ do
                putModel (\x -> x{mAdminUsersLoading = True, mAdminUsersError = Nothing})
                fetchAdminUsers AdminUsersLoaded AdminUsersFailed
    -- library ---------------------------------------------------------------
    SearchInput query -> do
        putModel
            ( \m ->
                m
                    { mQ = query
                    , mSelection = IS.empty
                    , mSelectAnchor = Nothing
                    , mSelectingAll = False
                    , mSelectFetched = 0
                    , mSelectEpoch = mSelectEpoch m + 1
                    , mSelectParams = Nothing
                    , mConfirmMarkAll = False
                    , -- The input now names a query no in-flight page can
                      -- answer, so invalidate the list epoch at once: stale
                      -- ListLoaded/ListFailed responses are dropped and
                      -- loadMore cannot mix the new query with the old offset
                      -- during the debounce window.
                      mListEpoch = mListEpoch m + 1
                    , mLoading = True
                    , mLoadingMore = False
                    , mHasMore = False
                    , mError = Nothing
                    }
            )
        scheduleSearch 180
    SearchCommit -> reloadList
    DebouncedSearch -> do
        putModel (\m -> m{mDebounce = Nothing})
        reloadList
    TimerRegistered timer -> putModel (\m -> m{mDebounce = Just timer})
    TagToggled tag -> do
        putModel (\m -> m{mTagsFilter = toggleMember tag (mTagsFilter m)})
        reloadList
    ClearFilters -> do
        putModel (\m -> m{mQ = "", mTagsFilter = [], mUnreadOnly = False})
        reloadList
    SortSelected sort -> do
        putModel (\m -> m{mSort = sort})
        reloadList
    UnreadToggled -> do
        putModel (\m -> m{mUnreadOnly = not (mUnreadOnly m)})
        reloadList
    ListLoaded append epoch page -> do
        m <- get
        -- A response for an older query no longer paints: the user may have
        -- typed again, changed the sort, or left the list route entirely.
        when (epoch == mListEpoch m) $ do
            let fresh =
                    if append
                        then mItems m ++ spItems page
                        else spItems page
            put
                m
                    { mItems = fresh
                    , mTotal = spTotal page
                    , -- The server computes the per-year match counts on the
                      -- first page only; keeping them on append stops the
                      -- "/ N here" figure vanishing on the first scroll.
                      mYearHere = if append then mYearHere m else spYearCounts page
                    , mHasMore = spHasMore page
                    , mLoading = False
                    , mLoadingMore = False
                    , mOffset = spOffset page + length (spItems page)
                    , mError = Nothing
                    , mConfirmMarkAll = False
                    , mSelection = if append then mSelection m else IS.empty
                    , mSelectAnchor = if append then mSelectAnchor m else Nothing
                    , mSelectingAll = if append then mSelectingAll m else False
                    , mSelectEpoch = if append then mSelectEpoch m else mSelectEpoch m + 1
                    , mSelectParams = if append then mSelectParams m else Nothing
                    , mLedgerCursor =
                        case (append, mLedgerCursor m) of
                            (False, _) -> Nothing
                            (True, Just idx) | idx < length fresh -> Just idx
                            _ -> Nothing
                    }
            continueScrollRestore
    ListFailed _append epoch err -> do
        m <- get
        when (epoch == mListEpoch m) $ do
            putModel
                ( \x ->
                    x
                        { mLoading = False
                        , mLoadingMore = False
                        , mScrollRestore = Nothing
                        , mError = Just (ms (aeMessage err))
                        , mConfirmMarkAll = False
                        }
                )
            handleApiError err
    LoadMore -> loadMore
    -- The old call sent the first row's id to an id-cutoff endpoint and marked
    -- rows the reader could not see.  Now the client confirms and sends the
    -- explicit ids of the loaded, unread records.
    MarkAllAbove -> do
        m <- get
        let loadedUnread = [bsId bookmark | bookmark <- mItems m, not (bsIsRead bookmark)]
        case loadedUnread of
            [] -> notify "No loaded unread records to mark read." ToastInfo
            ids
                | not (mConfirmMarkAll m) -> do
                    putModel (\x -> x{mConfirmMarkAll = True})
                    notify
                        ( ms
                            ( "Mark "
                                <> show (length ids)
                                <> " loaded unread record"
                                <> (if length ids == 1 then "" else "s")
                                <> " read? Click again to confirm."
                            )
                        )
                        ToastInfo
                | otherwise -> do
                    putModel (\x -> x{mConfirmMarkAll = False, mBulkBusy = True})
                    bulkUpdate (BulkMarkRead True) ids MarkAllDone MarkAllFailed
    MarkAllDone updated -> do
        putModel (\m -> m{mBulkBusy = False, mConfirmMarkAll = False})
        notify
            ( ms
                ( "Marked "
                    <> show updated
                    <> " record"
                    <> (if updated == 1 then "" else "s")
                    <> " as read"
                )
            )
            ToastOk
        reloadList
        refreshTags
        refreshStats
    MarkAllFailed err -> do
        putModel (\m -> m{mBulkBusy = False, mConfirmMarkAll = False})
        handleApiError err
    SavedSearchApply saved -> do
        putModel
            ( \m ->
                m
                    { mQ = ms (ssQ saved)
                    , mTagsFilter = if null (ssTags saved) then mTagsFilter m else ssTags saved
                    }
            )
        reloadList
    ExportClicked -> liftSinkIO (redirectTo exportUrl)
    -- add modal -------------------------------------------------------------
    AddOpen -> do
        putModel (\m -> m{mAddOpen = True, mAddError = Nothing})
        liftSinkIO (focusAfterRender "add-url")
    AddClose -> putModel (\m -> m{mAddOpen = False, mAddError = Nothing})
    AddUrlInput url -> putModel (\m -> m{mAddUrl = url})
    AddTitleInput title -> putModel (\m -> m{mAddTitle = title})
    AddTagsInput tags -> putModel (\m -> m{mAddTags = tags})
    AddNoteInput note -> putModel (\m -> m{mAddNote = note})
    AddSubmit -> do
        m <- get
        if mAddBusy m
            then pure ()
            else
                if not (isHttpUrlText (mAddUrl m))
                    then putModel (\x -> x{mAddError = Just "Enter a valid http(s) URL."})
                    else do
                        putModel (\x -> x{mAddBusy = True, mAddError = Nothing})
                        createBookmark
                            (mAddUrl m)
                            (mAddTitle m)
                            (splitTags (mAddTags m))
                            AddSucceeded
                            AddFailed
    AddSucceeded bookmarkId -> do
        m <- get
        if T.null (T.strip (fromMisoString (mAddNote m)))
            then finalizeAdd bookmarkId
            else
                -- The create endpoint has no note field, so a note is attached
                -- with the same PATCH the record editor uses.
                patchBookmark
                    bookmarkId
                    (object ["note_body" .= mAddNote m])
                    (AddNoteSaved bookmarkId)
                    (AddNoteFailed bookmarkId)
    AddNoteSaved bookmarkId -> finalizeAdd bookmarkId
    AddNoteFailed bookmarkId _ -> do
        notify
            "The record was filed, but the note could not be attached. Open the record to add it."
            ToastError
        finalizeAdd bookmarkId
    AddFailed err -> do
        putModel (\m -> m{mAddBusy = False, mAddError = Just (ms (aeMessage err))})
        handleApiError err
    -- command palette -------------------------------------------------------
    PaletteOpen -> do
        putModel (\m -> m{mPaletteOpen = True, mPaletteQ = "", mPaletteSel = 0})
        liftSinkIO (focusAfterRender "palette-input")
    PaletteClose -> putModel (\m -> m{mPaletteOpen = False, mPaletteQ = "", mPaletteSel = 0})
    PaletteInput query -> putModel (\m -> m{mPaletteQ = query, mPaletteSel = 0})
    PalettePrev -> do
        m <- get
        let count = length (paletteEntries m)
        putModel (\x -> x{mPaletteSel = if count == 0 then 0 else max 0 (mPaletteSel x - 1)})
    PaletteNext -> do
        m <- get
        let count = length (paletteEntries m)
        putModel (\x -> x{mPaletteSel = if count == 0 then 0 else min (count - 1) (mPaletteSel x + 1)})
    PaletteSelect -> choosePalette 0
    PaletteChoose offsetFromSelection -> choosePalette offsetFromSelection
    -- detail ----------------------------------------------------------------
    DetailLoaded epoch detail -> sameEpoch epoch $ do
        m <- get
        case mRoute m of
            Bookmark bookmarkId | bookmarkId /= bdId detail -> pure ()
            Bookmark _ ->
                putModel
                    ( \x ->
                        x
                            { mDetail = Just detail
                            , mDetailLoading = False
                            , mDetailError = Nothing
                            , mEditTitle = ms (bdTitle detail)
                            , mEditNote = ms (bdNoteBody detail)
                            , mEditTags = bdTags detail
                            , mDirty = False
                            , mExtractEditing = False
                            , mExtractDraft = ms (bdExtractedText detail)
                            , mExtractDirty = False
                            , mExtractSaving = False
                            , mNoteMode = NoteWrite
                            , mLinkQuery = Nothing
                            , mLinkResults = []
                            }
                    )
            _ -> pure ()
    DetailFailed epoch err -> sameEpoch epoch $ do
        putModel (\m -> m{mDetailLoading = False, mDetail = Nothing, mDetailError = Just (ms (aeMessage err))})
        handleApiError err
    TitleInput title -> putModel (\m -> m{mEditTitle = title, mDirty = True})
    NoteChanged noteText domRef -> do
        putModel (\m -> m{mEditNote = noteText, mDirty = True})
        withSink $ \sink -> do
            selection <- fromMaybe 0 <$> (fromJSVal =<< getProperty domRef "selectionStart")
            let cursor = round (selection :: Double)
                query = wikilinkQueryAt (fromMisoString noteText) cursor
            sink (NoteMeta cursor query)
    NoteMeta cursor query -> do
        m <- get
        putModel (\x -> x{mNoteCursor = cursor, mLinkQuery = fmap ms query})
        case query of
            Nothing -> putModel (\x -> x{mLinkResults = []})
            Just rawQuery ->
                if T.null rawQuery
                    then putModel (\x -> x{mLinkResults = take 6 (mItems m)})
                    else fetchAutocomplete (ms rawQuery) LinkSuggestions (\_ -> Noop)
    NoteModeChanged mode -> putModel (\m -> m{mNoteMode = mode})
    TagDraftInput draft -> putModel (\m -> m{mNewTag = draft})
    TagAdd -> do
        m <- get
        case parseTagInput (mNewTag m) of
            Nothing -> pure ()
            Just tag ->
                putModel
                    ( \x ->
                        x
                            { mEditTags = if tag `elem` mEditTags x then mEditTags x else mEditTags x ++ [tag]
                            , mNewTag = ""
                            , mDirty = True
                            }
                    )
    TagRemove tag -> putModel (\m -> m{mEditTags = filter (/= tag) (mEditTags m), mDirty = True})
    SaveBookmark -> do
        m <- get
        case currentDetail m of
            Nothing -> pure ()
            Just detail -> do
                putModel (\x -> x{mSaving = True, mExtractSaving = mExtractEditing m})
                let fields =
                        [ "title" .= mEditTitle m
                        , "note_body" .= mEditNote m
                        , "tags" .= mEditTags m
                        ]
                    -- A read toggle that is still in flight owns is_read: this
                    -- save must not echo a flag the server has not confirmed.
                    readField =
                        [ "is_read" .= bdIsRead detail
                        | not (mReadPending m)
                        ]
                    textField =
                        [ "extracted_text" .= mExtractDraft m
                        | mExtractEditing m
                        ]
                patchBookmarkWithResult
                    (bdId detail)
                    (object (fields ++ readField ++ textField))
                    SavedOk
                    SaveFailed
    SavedOk highlightsRemoved -> do
        m <- get
        putModel
            ( \x ->
                x
                    { mSaving = False
                    , mExtractSaving = False
                    , mDirty = False
                    , mExtractDirty = False
                    }
            )
        case (mDetail m, mExtractEditing m) of
            (Just detail, True) ->
                putModel
                    ( \x ->
                        x
                            { mDetail = Just (textEditedDetail detail (mExtractDraft m))
                            , mExtractEditing = False
                            , mExtractDraft = mExtractDraft m
                            }
                    )
            _ -> pure ()
        notify
            ( if highlightsRemoved > 0
                then ms ("Saved; " <> show highlightsRemoved <> " unmatched highlight(s) removed")
                else "Saved"
            )
            (if highlightsRemoved > 0 then ToastInfo else ToastOk)
        when (mExtractEditing m) $ do
            case mDetail m of
                Just detail -> fetchHighlights (bdId detail) (HighlightsLoaded (mDetailEpoch m)) (HighlightsFailed (mDetailEpoch m))
                Nothing -> pure ()
        refreshStats
    SaveFailed err -> do
        putModel (\m -> m{mSaving = False, mExtractSaving = False})
        handleApiError err
    ExtractEditStart -> do
        m <- get
        case currentDetail m of
            Nothing -> pure ()
            Just detail ->
                putModel
                    ( \x ->
                        x
                            { mExtractEditing = True
                            , mExtractDraft = ms (bdExtractedText detail)
                            , mExtractDirty = False
                            }
                    )
                    >> liftSinkIO (focusAfterRender "extract-text-editor")
    ExtractEditChanged draft ->
        putModel (\m -> m{mExtractDraft = draft, mExtractDirty = True})
    ExtractEditCancel -> do
        m <- get
        case currentDetail m of
            Nothing -> putModel (\x -> x{mExtractEditing = False, mExtractDirty = False})
            Just detail ->
                putModel
                    ( \x ->
                        x
                            { mExtractEditing = False
                            , mExtractDraft = ms (bdExtractedText detail)
                            , mExtractDirty = False
                            }
                    )
    ExtractSaved _ -> pure ()
    MarkLinkAlive -> do
        m <- get
        case currentDetail m of
            Nothing -> pure ()
            Just detail -> markLinkAlive (bdId detail) LinkMarkedAlive (\err -> ApiErrorRaised err)
    LinkMarkedAlive -> do
        putModel
            ( \m ->
                m
                    { mDetail =
                        fmap (\detail -> detail{bdIsDead = False, bdManualAlive = True}) (mDetail m)
                    }
            )
        notify "Kept alive; automatic checks will skip it" ToastOk
        refreshStats
    RecheckLink -> do
        m <- get
        case currentDetail m of
            Nothing -> pure ()
            Just detail -> recheckLink (bdId detail) LinkRechecked (\err -> ApiErrorRaised err)
    LinkRechecked -> do
        putModel
            ( \m ->
                m
                    { mDetail =
                        fmap (\detail -> detail{bdManualAlive = False}) (mDetail m)
                    }
            )
        notify "Automatic checks will run on the next sweep" ToastInfo
    -- A read toggle is its own patch: it must not clear the unsaved note and
    -- it must not claim the note was saved.
    ReadToggled -> do
        m <- get
        case currentDetail m of
            Nothing -> pure ()
            Just detail -> do
                let nextRead = not (bdIsRead detail)
                    requestId = mReadRequest m + 1
                putModel
                    ( \x ->
                        x
                            { mDetail = Just detail{bdIsRead = nextRead}
                            , mReadRequest = requestId
                            , mReadPending = True
                            }
                    )
                patchBookmark
                    (bdId detail)
                    (object ["is_read" .= nextRead])
                    (ReadPatched requestId nextRead)
                    (ReadPatchFailed requestId nextRead)
    -- Only the newest read PATCH may paint: a slow response for an older
    -- toggle is dropped instead of repainting the previous flag.
    ReadPatched requestId readFlag -> do
        m <- get
        when (requestId == mReadRequest m) $ do
            putModel (\x -> x{mReadPending = False})
            case currentDetail m of
                Nothing -> pure ()
                Just detail -> putModel (\x -> x{mDetail = Just detail{bdIsRead = readFlag}})
            refreshStats
    -- On failure, read the record back from the server rather than guessing
    -- the inverse; an unsaved note keeps its edits and only the flag rolls
    -- back, because reloading the detail would replace the editor.
    ReadPatchFailed requestId readFlag err -> do
        m <- get
        when (requestId == mReadRequest m) $ do
            putModel (\x -> x{mReadPending = False})
            case currentDetail m of
                Just detail
                    | hasUnsaved m ->
                        putModel (\x -> x{mDetail = Just detail{bdIsRead = not readFlag}})
                    | otherwise -> updateModel (DetailReload (bdId detail))
                Nothing -> pure ()
            handleApiError err
    OpenToggled -> pure ()
    BacklinksLoaded epoch links -> sameEpoch epoch $ do
        m <- get
        case mRoute m of
            Bookmark _ -> putModel (\x -> x{mBacklinks = links})
            _ -> pure ()
    BacklinksFailed epoch err -> sameEpoch epoch (handleApiError err)
    LinkPrev -> putModel (\m -> m{mLinkSel = max 0 (mLinkSel m - 1)})
    LinkNext -> do
        m <- get
        let count = length (mLinkResults m)
        putModel (\x -> x{mLinkSel = if count == 0 then 0 else min (count - 1) (mLinkSel x + 1)})
    LinkChoose index -> do
        m <- get
        case drop index (mLinkResults m) of
            [] -> pure ()
            (bookmark : _) -> do
                let (newNote, newCursor) = completeWikilink (fromMisoString (mEditNote m)) (mNoteCursor m) (bsTitle bookmark)
                putModel
                    ( \x ->
                        x
                            { mEditNote = ms newNote
                            , mNoteCursor = newCursor
                            , mLinkQuery = Nothing
                            , mLinkResults = []
                            , mDirty = True
                            }
                    )
                liftSinkIO (setSelectionRange "note-editor" newCursor newCursor)
    LinkSuggestions suggestions -> putModel (\m -> m{mLinkResults = suggestions, mLinkSel = 0})
    RunBookmarkAction bookmarkId verb -> bookmarkAction bookmarkId verb (ToastAdd (ms (T.toTitle verb <> " queued")) ToastOk) (\err -> ApiErrorRaised err)
    DeleteBookmarkRequest bookmarkId -> do
        m <- get
        case currentDetail m of
            Just detail | bdId detail == bookmarkId -> putModel (\x -> x{mConfirmDelete = Just bookmarkId})
            _ -> pure ()
    DeleteBookmarkCancel -> putModel (\m -> m{mConfirmDelete = Nothing})
    DeleteBookmarkConfirm -> do
        m <- get
        putModel (\x -> x{mConfirmDelete = Nothing})
        case (mConfirmDelete m, currentDetail m) of
            -- The record stays painted while the write is in flight. Clearing
            -- it here used to make a failed delete look like a successful one:
            -- the page dropped to the "record unavailable" state even though
            -- the server still held the record.
            (Just bookmarkId, Just detail)
                | bdId detail == bookmarkId ->
                    deleteBookmark bookmarkId (DeletedOk bookmarkId) DeleteFailed
            _ -> pure ()
    DeleteBookmark bookmarkId -> do
        m <- get
        case currentDetail m of
            Just detail | bdId detail == bookmarkId -> deleteBookmark bookmarkId (DeletedOk bookmarkId) DeleteFailed
            _ -> pure ()
    DeletedOk bookmarkId -> do
        m <- get
        notify "Bookmark deleted" ToastOk
        refreshTags
        refreshStats
        case mRoute m of
            Bookmark currentId | currentId == bookmarkId -> withSink $ \_ -> pushRoute Index
            _ -> reloadList
    DeleteFailed err -> handleApiError err
    DirtyGuardOpen route -> putModel (\m -> m{mGuardOpen = True, mPendingRoute = Just route, mGuardFromHistory = False})
    -- Keep editing. When the guard came from a history navigation the address
    -- has already moved to the pending route; put it back without adding a
    -- history entry so the URL matches the record still on screen.
    DirtyGuardClose -> do
        m <- get
        putModel (\x -> x{mGuardOpen = False, mPendingRoute = Nothing, mGuardFromHistory = False})
        when (mGuardFromHistory m) $ liftSinkIO (replaceBrowserUrl (prettyURI (toURI (mRoute m))))
    DirtyGuardDiscard -> do
        m <- get
        putModel (\x -> x{mGuardOpen = False, mPendingRoute = Nothing, mGuardFromHistory = False, mDirty = False, mExtractDirty = False, mExtractEditing = False})
        case mPendingRoute m of
            Nothing -> pure ()
            -- The address already points at the pending route after a history
            -- navigation, so load it directly instead of pushing a duplicate.
            Just route
                | mGuardFromHistory m -> loadRoute route
                | otherwise -> withSink $ \_ -> pushRoute route
    -- import / export -------------------------------------------------------
    ImportStart -> liftSinkIO $ do
        element <- getElementById "import-file"
        click () element
    ImportFileChosen -> do
        putModel (\m -> m{mImporting = True})
        submitImport ImportDone ImportFailed
    ImportDone value -> do
        putModel (\m -> m{mImporting = False, mImportReport = either (const Nothing) Just (decodeImportReport value)})
        let inserted = fieldInt "inserted" value
            existing = fieldInt "existing" value
            found = fieldInt "found" value
        notify
            ( ms
                ( "Imported "
                    <> show inserted
                    <> " of "
                    <> show found
                    <> " links ("
                    <> show existing
                    <> " already saved)"
                )
            )
            ToastOk
        reloadList
        refreshTags
        refreshStats
    ImportFailed err -> do
        putModel (\m -> m{mImporting = False})
        handleApiError err
    -- saved searches --------------------------------------------------------
    SavedSearchSave -> do
        m <- get
        let queryText = T.strip (fromMisoString (mQ m))
            explicitName = T.strip (fromMisoString (mSavedName m))
        if T.null queryText && null (mTagsFilter m)
            then notify "Type a search or choose a tag before saving it" ToastInfo
            else do
                let name = if T.null explicitName then mQ m else mSavedName m
                saveSavedSearch name (mQ m) (mTagsFilter m) (\_ -> SavedSearchDone) SavedSearchFailed
    SavedSearchNameInput name -> putModel (\m -> m{mSavedName = name})
    SavedSearchDelete savedSearchId -> deleteSavedSearch savedSearchId SavedSearchDone SavedSearchFailed
    SavedSearchDone -> do
        notify "Saved searches updated" ToastOk
        putModel (\m -> m{mSavedName = ""})
        fetchSavedSearches SavedSearchesLoaded (\_ -> Noop)
    SavedSearchFailed err -> handleApiError err
    SavedSearchesLoaded saved -> putModel (\m -> m{mSaved = saved})
    SavedSearchShareOpen saved -> do
        m <- get
        let epoch = mDetailEpoch m
        putModel
            ( \x ->
                x
                    { mSavedShare = Just saved
                    , mShareUrl = Nothing
                    , mShareBusy = False
                    , mSharesLoading = True
                    , mSharesError = Nothing
                    }
            )
        fetchShares (\shares -> SharesLoaded epoch shares) (SharesFailed epoch)
    SavedSearchShareClose -> putModel (\m -> m{mSavedShare = Nothing, mShareUrl = Nothing})
    SavedSearchShareCreate -> do
        m <- get
        case mSavedShare m of
            Nothing -> pure ()
            Just saved -> do
                putModel (\x -> x{mShareBusy = True})
                createShareLink
                    "saved_search"
                    (ssId saved)
                    False
                    (mShareExpiryDays m)
                    ShareCreated
                    ShareCreateFailed
    -- graph ----------------------------------------------------------------
    GraphLoaded graph -> do
        m <- get
        case (Just graph == mGraph m, mGraphLayout m) of
            -- A warm return with the same payload keeps the cached bitmap, the
            -- layout and the generation: no 30k-primitive repaint.
            (True, Just _) -> do
                let scoped = applyGraphScope m
                    old = mGraphView scoped
                    view = case (mGraphFocus scoped, activeGraphLayout scoped) of
                        (Just key, Just layout) ->
                            focusView layout key (gvWidth old) (gvHeight old) (gvDpr old)
                        _ -> old
                putModel
                    ( \x ->
                        let upgraded = upgradeWithWire graph x
                            scopedNow = applyGraphScope (recomputeGraphColors (upgraded{mGraph = Just graph}))
                         in scopedNow
                                { mGraphView = view
                                , mGraphMatches = mGraphMatches scopedNow
                                , mGraphLoading = False
                                , mGraphError = Nothing
                                , mGraphHover = Nothing
                                , mGraphFocus = if mGraphViewReady x then Nothing else mGraphFocus x
                                }
                    )
                when (view /= old) (markGraphMoving >> scheduleGraphSettle)
                unless (mGraphViewReady m) (measureGraphCanvas GraphMeasured)
                focusGraphPlate m
            _ -> do
                let generation = mGraphGen m + 1
                    preset = mGraphPreset m
                    wireMismatch =
                        case mGraphLayoutWire m of
                            Just (wirePreset, wire) -> wirePreset == preset && lwRevision wire /= gdRevision graph
                            Nothing -> False
                    hydrated = do
                        (wirePreset, wire) <- mGraphLayoutWire m
                        if wirePreset == preset && lwRevision wire == gdRevision graph
                            then hydrateWire graph wire
                            else Nothing
                    whole =
                        case hydrated of
                            Just layout -> layout{glGen = generation}
                            Nothing -> buildLayoutWith (presetOptions preset) generation graph
                    seeded =
                        m
                            { mGraph = Just graph
                            , mGraphLayout = Just whole
                            , mGraphLayoutSource = if isJust hydrated then "server" else "local"
                            , mGraphGen = generation
                            , mGraphLoading = False
                            , mGraphError = Nothing
                            , mGraphHover = Nothing
                            , mGraphSettled = False
                            , mGraphSettleEpoch = mGraphSettleEpoch m + 1
                            , mGraphDetailPhase = 0
                            }
                    scoped = applyGraphScope seeded
                    old = mGraphView m
                    view =
                        case (mGraphFocus scoped, activeGraphLayout scoped) of
                            (Just key, Just layout) ->
                                focusView layout key (gvWidth old) (gvHeight old) (gvDpr old)
                            (_, Just layout)
                                | mGraphViewReady m ->
                                    resizeView layout (gvWidth old) (gvHeight old) (gvDpr old) old
                                | otherwise ->
                                    fitView layout (gvWidth old) (gvHeight old) (gvDpr old)
                            _ -> old
                putModel
                    ( \x ->
                        let seededNow =
                                x
                                    { mGraph = Just graph
                                    , mGraphLayout = Just whole
                                    , mGraphLayoutSource =
                                        if isJust hydrated then "server" else "local"
                                    , mGraphGen = generation
                                    , mGraphLoading = False
                                    , mGraphError = Nothing
                                    , mGraphHover = Nothing
                                    , mGraphSettled = False
                                    , mGraphSettleEpoch = mGraphSettleEpoch x + 1
                                    , mGraphDetailPhase = 0
                                    }
                            scopedNow = applyGraphScope (recomputeGraphColors (upgradeWithWire graph seededNow))
                         in scopedNow
                                { mGraphView = view
                                , mGraphSelected = mGraphFocus x
                                }
                    )
                scheduleGraphSettle
                when (wireMismatch || wirePresetDiffers m preset) $
                    fetchGraphLayout preset (GraphLayoutLoaded preset) GraphLayoutFailed
                unless (mGraphViewReady m) (measureGraphCanvas GraphMeasured)
                focusGraphPlate m
    GraphFailed err -> do
        putModel (\x -> x{mGraphLoading = False, mGraphError = Just (ms (aeMessage err))})
        -- The error panel is only rendered while the plate has no layout to
        -- fall back on; without this toast a failed refresh of an already
        -- painted graph looked like a successful one.
        handleApiError err
    GraphRefresh -> do
        m <- get
        -- The layout endpoint carries the library revision. Fetch it first:
        -- when the revision still matches, the graph payload and plate are
        -- already current and no repaint is needed; a changed revision makes
        -- GraphLayoutLoaded fetch the graph before hydrating.
        putModel (\x -> x{mGraphLoading = True, mGraphError = Nothing})
        fetchGraphLayout (mGraphPreset m) (GraphLayoutLoaded (mGraphPreset m)) GraphLayoutFailed
    OpenGraphAt bookmarkId -> do
        m <- get
        putModel (\x -> x{mGraphFocus = Just bookmarkId, mGraphSelected = Just bookmarkId, mGraphError = Nothing})
        case (mGraphLayout m, mGraphViewReady m) of
            (Just layout, True) -> do
                let old = mGraphView m
                    view = focusView layout bookmarkId (gvWidth old) (gvHeight old) (gvDpr old)
                putModel
                    ( \x ->
                        x
                            { mGraphView = view
                            , mGraphFocus = Nothing
                            , mGraphSettled = False
                            , mGraphSettleEpoch = mGraphSettleEpoch x + 1
                            , mGraphDetailPhase = 0
                            }
                    )
                scheduleGraphSettle
                when (not (isGraphRoute (mRoute m))) (updateModel (Navigate Graph))
            _ -> do
                putModel (\x -> x{mGraphLoading = True})
                when (not (isGraphRoute (mRoute m))) (updateModel (Navigate Graph))
    GraphMeasured width height dpr -> do
        m <- get
        case activeGraphLayout m of
            Nothing -> pure ()
            Just layout
                | width < 40 || height < 40 -> pure ()
                | not (mGraphViewReady m) -> do
                    let view = case mGraphFocus m of
                            Just key -> focusView layout key width height dpr
                            Nothing -> fitView layout width height dpr
                    putModel
                        ( \x ->
                            x
                                { mGraphView = view
                                , mGraphViewReady = True
                                , mGraphFocus = Nothing
                                , mGraphSettled = False
                                , mGraphSettleEpoch = mGraphSettleEpoch x + 1
                                , mGraphDetailPhase = 0
                                }
                        )
                    scheduleGraphSettle
                | gvWidth (mGraphView m) /= width
                    || gvHeight (mGraphView m) /= height
                    || gvDpr (mGraphView m) /= dpr -> do
                    let view = resizeView layout width height dpr (mGraphView m)
                    putModel
                        ( \x ->
                            x
                                { mGraphView = view
                                , mGraphSettled = False
                                , mGraphSettleEpoch = mGraphSettleEpoch x + 1
                                , mGraphDetailPhase = 0
                                }
                        )
                    scheduleGraphSettle
                | otherwise -> pure ()
    GraphPointerDown x y ->
        putModel (\m -> m{mGraphDrag = Just (GraphDrag (x, y) (x, y) False), mGraphHover = Nothing})
    GraphPointerMove x y -> do
        m <- get
        case mGraphDrag m of
            Just drag -> do
                let (lastX, lastY) = gdLast drag
                    view = panView (x - lastX, y - lastY) (mGraphView m)
                    moved =
                        gdMoved drag
                            || abs (x - fst (gdStart drag)) > 3
                            || abs (y - snd (gdStart drag)) > 3
                putModel
                    ( \model ->
                        model
                            { mGraphDrag = Just drag{gdLast = (x, y), gdMoved = moved}
                            , mGraphView = view
                            , mGraphHover = Nothing
                            , mGraphSettled = False
                            , mGraphSettleEpoch = mGraphSettleEpoch model + 1
                            , mGraphDetailPhase = 0
                            }
                    )
            Nothing -> case activeGraphLayout m of
                Nothing -> pure ()
                Just layout ->
                    let hovered = visibleHit m (nodeAt layout (mGraphView m) (x, y))
                     in unless (hovered == mGraphHover m) $
                            putModel (\model -> model{mGraphHover = hovered})
    GraphPointerUp x y -> do
        m <- get
        case mGraphDrag m of
            Nothing -> pure ()
            Just drag -> do
                putModel (\model -> model{mGraphDrag = Nothing})
                when (gdMoved drag) scheduleGraphSettle
                unless (gdMoved drag) (graphClick m x y)
    GraphPointerLeave -> do
        m <- get
        putModel (\x -> x{mGraphDrag = Nothing, mGraphHover = Nothing})
        when (isJust (mGraphDrag m)) scheduleGraphSettle
    GraphWheel x y delta -> do
        m <- get
        case activeGraphLayout m of
            Nothing -> pure ()
            Just layout -> do
                let factor = max 0.5 (min 2 (exp (negate delta * 0.0015)))
                    view = zoomViewAt layout (mGraphView m) (x, y) factor
                putModel
                    ( \model ->
                        model
                            { mGraphView = view
                            , mGraphHover = Nothing
                            , mGraphSettled = False
                            , mGraphSettleEpoch = mGraphSettleEpoch model + 1
                            , mGraphDetailPhase = 0
                            }
                    )
                scheduleGraphSettle
    GraphZoomIn -> graphZoom 1.25
    GraphZoomOut -> graphZoom 0.8
    GraphFit -> do
        m <- get
        case activeGraphLayout m of
            Nothing -> pure ()
            Just layout -> do
                let old = mGraphView m
                    view = fitView layout (gvWidth old) (gvHeight old) (gvDpr old)
                putModel
                    ( \model ->
                        model
                            { mGraphView = view
                            , mGraphHover = Nothing
                            , mGraphSettled = False
                            , mGraphSettleEpoch = mGraphSettleEpoch model + 1
                            , mGraphDetailPhase = 0
                            }
                    )
                scheduleGraphSettle
    GraphFilterChanged query -> do
        m <- get
        case mGraphFilterTimer m of
            Just oldTimer -> liftSinkIO (void (jsgf "clearTimeout" (oldTimer :: Int)))
            Nothing -> pure ()
        putModel (\x -> x{mGraphFilter = query, mGraphMatches = emptyMatches, mGraphFilterTimer = Nothing})
        withSink $ \sink -> do
            timer <- fromJSValUnchecked =<< jsgf "setTimeout" (asyncCallback1 (\_ -> sink GraphFilterSettled), 120 :: Int)
            sink (GraphFilterArmed (timer :: Int))
    GraphFilterArmed timer -> putModel (\x -> x{mGraphFilterTimer = Just timer})
    GraphFilterSettled -> do
        m <- get
        case activeGraphLayout m of
            Nothing -> putModel (\x -> x{mGraphFilterTimer = Nothing})
            Just layout ->
                putModel
                    ( \x ->
                        x
                            { mGraphMatches = matchGraph (T.strip (fromMisoString (mGraphFilter x))) layout
                            , mGraphFilterTimer = Nothing
                            }
                    )
    GraphSettled epoch -> do
        m <- get
        case activeGraphLayout m of
            Just layout
                | isGraphRoute (mRoute m)
                , epoch == mGraphSettleEpoch m
                , not (mGraphSettled m)
                , mGraphDetailPhase m == 0 ->
                    let view = mGraphView m
                        atFit = gvScale view <= 1.1 * gvFit view
                        chunks = detailChunkCount layout
                     in if mGraphLocal m || atFit || chunks <= 0
                            then putModel (\x -> x{mGraphSettled = True})
                            else do
                                putModel
                                    ( \x ->
                                        x
                                            { mGraphSettled = False
                                            , mGraphDetailPhase = 1
                                            , mGraphDetailChunks = chunks
                                            }
                                    )
                                scheduleGraphDetailStep epoch 1
            _ -> pure ()
    GraphDetailStep epoch expected -> do
        m <- get
        when
            ( isGraphRoute (mRoute m)
                && isJust (activeGraphLayout m)
                && not (mGraphLocal m)
                && epoch == mGraphSettleEpoch m
                && mGraphDetailPhase m == expected
            )
            ( if expected >= mGraphDetailChunks m
                then putModel (\x -> x{mGraphSettled = True, mGraphDetailPhase = 0})
                else do
                    putModel (\x -> x{mGraphDetailPhase = expected + 1})
                    scheduleGraphDetailStep epoch (expected + 1)
            )
    GraphTagsToggled -> do
        putModel
            ( \m ->
                m
                    { mGraphTagsShown = not (mGraphTagsShown m)
                    , mGraphSettled = False
                    , mGraphSettleEpoch = mGraphSettleEpoch m + 1
                    , mGraphDetailPhase = 0
                    }
            )
        scheduleGraphSettle
    GraphLayoutLoaded preset wire -> do
        putModel (\x -> x{mGraphLayoutWire = Just (preset, wire)})
        m <- get
        when (preset /= mGraphPreset m && isNothing (mGraph m)) $
            -- A default view or a preset change landed while this request was
            -- in flight. Fetch the current preset; the stale wire is kept for
            -- a later switch back.
            fetchGraphLayout (mGraphPreset m) (GraphLayoutLoaded (mGraphPreset m)) GraphLayoutFailed
        when (preset == mGraphPreset m) $
            case mGraph m of
                -- Layout first on a cold route. The graph request follows the
                -- known revision, so the first plate is hydrated rather than
                -- built locally and then thrown away.
                Nothing -> do
                    putModel (\x -> x{mGraphLoading = True})
                    fetchGraph GraphLoaded GraphFailed
                Just graph
                    | gdRevision graph /= lwRevision wire -> do
                        -- The layout is for a newer library than the graph we
                        -- hold; fetch the records before hydrating.
                        putModel (\x -> x{mGraphLoading = True})
                        fetchGraph GraphLoaded GraphFailed
                    | Just hydrated <- hydrateWire graph wire -> do
                        let same =
                                maybe
                                    False
                                    (sameGraphLayout (hydrated{glGen = 0}) . (\current -> current{glGen = 0}))
                                    (mGraphLayout m)
                            generation = if same then mGraphGen m else mGraphGen m + 1
                            layout = hydrated{glGen = generation}
                            old = mGraphView m
                            view
                                | same && mGraphViewReady m = old
                                | mGraphViewReady m = resizeView layout (gvWidth old) (gvHeight old) (gvDpr old) old
                                | otherwise = fitView layout (gvWidth old) (gvHeight old) (gvDpr old)
                        putModel
                            ( \x ->
                                let seeded =
                                        x
                                            { mGraphLayout = Just layout
                                            , mGraphGen = generation
                                            , mGraphLayoutSource = "server"
                                            , mGraphView = view
                                            , mGraphHover = if same then mGraphHover x else Nothing
                                            , mGraphSettled = if same then mGraphSettled x else False
                                            , mGraphSettleEpoch = if same then mGraphSettleEpoch x else mGraphSettleEpoch x + 1
                                            , mGraphDetailPhase = if same then mGraphDetailPhase x else 0
                                            , mGraphLoading = False
                                            }
                                 in applyGraphScope (recomputeGraphColors seeded)
                            )
                        when (not same || view /= old) scheduleGraphSettle
                Just _ -> putModel (\x -> x{mGraphLayoutSource = "local", mGraphLoading = False})
    GraphLayoutFailed err -> do
        -- A failed refresh of an already-painted graph has no error panel to
        -- show (the plate is still usable), so surface the failure as a toast.
        handleApiError err
        m <- get
        case mGraph m of
            Nothing -> do
                -- No records yet: get them, then GraphLoaded builds the local
                -- fallback because no layout wire exists.
                putModel (\x -> x{mGraphLayoutSource = "local", mGraphLayoutWire = Nothing, mGraphLoading = True})
                fetchGraph GraphLoaded GraphFailed
            Just graph -> do
                -- A refresh or preset switch failed. Build the deterministic
                -- local layout for the current preset rather than leaving a
                -- plate whose positions belong to the previous preset.
                let generation = mGraphGen m + 1
                    whole = buildLayoutWith (presetOptions (mGraphPreset m)) generation graph
                putModel
                    ( \x ->
                        let seeded =
                                x
                                    { mGraphLayout = Just whole
                                    , mGraphGen = generation
                                    , mGraphLayoutSource = "local"
                                    , mGraphLoading = False
                                    , mGraphHover = Nothing
                                    , mGraphFocus = Nothing
                                    , mGraphSettled = False
                                    , mGraphSettleEpoch = mGraphSettleEpoch x + 1
                                    , mGraphDetailPhase = 0
                                    }
                         in fitActiveView (applyGraphScope seeded)
                    )
                scheduleGraphSettle
    -- views ---------------------------------------------------------------
    ViewsLoaded views -> do
        putModel (\x -> x{mViews = views, mViewsLoading = False, mViewsError = Nothing})
        m <- get
        when (mGraphViewId m == Nothing) $
            case defaultGraphView views of
                Just view -> putModel (applyGraphView view)
                Nothing -> pure ()
        putModel recomputeGraphColors
    ViewsFailed err ->
        putModel (\x -> x{mViewsLoading = False, mViewsError = Just (ms (aeMessage err))})
    ViewSaved view -> do
        notify "View saved" ToastOk
        putModel
            ( \x ->
                let ui = mViewUi x
                    isGraph = EV.vKind view == EV.GraphKind
                    viewsAfter = upsertView view (mViews x)
                    viewsFinal
                        | EV.vIsDefault view =
                            [ if EV.vKind candidate == EV.vKind view && EV.vSlug candidate /= EV.vSlug view
                                then candidate{EV.vIsDefault = False}
                                else candidate
                            | candidate <- viewsAfter
                            ]
                        | otherwise = viewsAfter
                 in x
                        { mViews = viewsFinal
                        , mViewsLoading = False
                        , mViewsError = Nothing
                        , mViewUi =
                            ui
                                { vuSaveOpen = False
                                , vuImportOpen = False
                                , vuImportText = ""
                                , vuBusy = False
                                , vuError = Nothing
                                }
                        , mGraphViewId = if isGraph then Just (EV.vId view) else mGraphViewId x
                        , mGraphViewRev = if isGraph then EV.vUpdatedAt view else mGraphViewRev x
                        , mGraphColorGroups = if isGraph then mGraphGroupDrafts x else mGraphColorGroups x
                        , mGraphGroupDirty = if isGraph then False else mGraphGroupDirty x
                        , mGraphGroupEditor = if isGraph then False else mGraphGroupEditor x
                        }
            )
        putModel recomputeGraphColors
    ViewSaveFailed err ->
        putModel
            ( \x ->
                let ui = mViewUi x
                 in x{mViewUi = ui{vuBusy = False, vuError = Just (ms (aeMessage err))}}
            )
    ViewDeleted slug -> do
        notify "View deleted" ToastOk
        -- The server promotes another view of the same kind to default in the
        -- same transaction; refetch so the manager shows the surviving default
        -- badge instead of none. If the deleted view was the active one, drop
        -- the id so the refetched default becomes active again.
        m <- get
        let deletedId = EV.vId <$> findViewBySlug slug (mViews m)
        putModel
            ( \x ->
                x
                    { mViews = [view | view <- mViews x, EV.vSlug view /= slug]
                    , mViewsLoading = True
                    , mGraphViewId =
                        case deletedId of
                            Just viewId | mGraphViewId x == Just viewId -> Nothing
                            _ -> mGraphViewId x
                    }
            )
        fetchViews ViewsLoaded ViewsFailed
    ViewDeleteFailed err ->
        putModel (\x -> x{mViewsError = Just (ms (aeMessage err))})
    ViewOpenView slug -> openSavedView slug
    ViewFetched view -> openSavedViewNow view
    ViewFetchFailed err ->
        putModel (\x -> x{mViewsError = Just (ms (aeMessage err))})
    ViewDefaultView slug -> do
        putModel (\x -> x{mViewUi = (mViewUi x){vuBusy = True, vuError = Nothing}})
        patchView slug (ViewPatch Nothing Nothing Nothing (Just True)) ViewSaved ViewSaveFailed
    ViewDeleteView slug -> deleteView slug (ViewDeleted slug) ViewDeleteFailed
    ViewExportView slug -> do
        m <- get
        case findViewBySlug slug (mViews m) of
            Just view ->
                putModel
                    ( \x ->
                        let ui = mViewUi x
                         in x{mViewUi = ui{vuExport = Just (TE.decodeUtf8 (BL.toStrict (encode view)))}}
                    )
            Nothing -> pure ()
    ViewExportClose ->
        putModel (\x -> x{mViewUi = (mViewUi x){vuExport = Nothing}})
    ViewRenameStart slug -> do
        m <- get
        case findViewBySlug slug (mViews m) of
            Just view ->
                putModel
                    ( \x ->
                        let ui = mViewUi x
                         in x{mViewUi = ui{vuRename = Just (EV.vSlug view, ms (T.unpack (EV.vName view)))}}
                    )
            Nothing -> pure ()
    ViewRenameInput name ->
        putModel
            ( \x ->
                let ui = mViewUi x
                 in x{mViewUi = ui{vuRename = fmap (\(slug, _) -> (slug, name)) (vuRename ui)}}
            )
    ViewRenameSubmit -> do
        m <- get
        case vuRename (mViewUi m) of
            Just (slug, name)
                | not (T.null (T.strip (fromMisoString name))) -> do
                    putModel (\x -> x{mViewUi = (mViewUi x){vuBusy = True, vuError = Nothing}})
                    patchView slug (ViewPatch (Just (T.strip (fromMisoString name))) Nothing Nothing Nothing) ViewSaved ViewSaveFailed
            _ -> pure ()
    ViewDuplicateView slug -> do
        m <- get
        case findViewBySlug slug (mViews m) of
            Just view -> do
                notify "Duplicating view" ToastInfo
                createView
                    ( EV.ViewInput
                        (EV.vName view <> " copy")
                        (EV.vKind view)
                        (EV.vDefinition view)
                        Nothing
                    )
                    ViewSaved
                    ViewSaveFailed
            Nothing -> pure ()
    ViewSaveOpen kind ->
        putModel
            ( \x ->
                let ui = mViewUi x
                 in x{mViewUi = ui{vuSaveOpen = True, vuSaveKind = kind, vuSaveName = "", vuError = Nothing, vuBusy = False}}
            )
    ViewSaveNameInput name ->
        putModel (\x -> x{mViewUi = (mViewUi x){vuSaveName = name}})
    ViewSaveKindSelected kind ->
        putModel (\x -> x{mViewUi = (mViewUi x){vuSaveKind = kind, vuError = Nothing}})
    ViewRenameCancel ->
        putModel (\x -> x{mViewUi = (mViewUi x){vuRename = Nothing}})
    ViewSaveSubmit -> do
        m <- get
        let ui = mViewUi m
            name = T.strip (fromMisoString (vuSaveName ui))
            definition = case vuSaveKind ui of
                EV.GraphKind -> currentGraphDefinition m
                EV.LedgerKind -> currentLedgerDefinition m
        if T.null name
            then putModel (\x -> x{mViewUi = (mViewUi x){vuError = Just "a name is required"}})
            else do
                putModel (\x -> x{mViewUi = (mViewUi x){vuBusy = True, vuError = Nothing}})
                createView (EV.ViewInput name (vuSaveKind ui) definition Nothing) ViewSaved ViewSaveFailed
    ViewSaveCancel ->
        putModel (\x -> x{mViewUi = (mViewUi x){vuSaveOpen = False, vuBusy = False, vuError = Nothing}})
    ViewImportOpen ->
        putModel (\x -> x{mViewUi = (mViewUi x){vuImportOpen = True, vuImportText = "", vuError = Nothing}})
    ViewImportTextInput rawText ->
        putModel (\x -> x{mViewUi = (mViewUi x){vuImportText = rawText}})
    ViewImportSubmit -> do
        m <- get
        let ui = mViewUi m
            raw = TE.encodeUtf8 (T.pack (fromMisoString (vuImportText ui)))
        case Aeson.eitherDecodeStrict' raw :: Either String EV.ViewInput of
            Left message ->
                putModel (\x -> x{mViewUi = (mViewUi x){vuError = Just (ms message)}})
            Right input -> do
                putModel (\x -> x{mViewUi = (mViewUi x){vuBusy = True, vuError = Nothing}})
                createView input ViewSaved ViewSaveFailed
    ViewImportCancel ->
        putModel (\x -> x{mViewUi = (mViewUi x){vuImportOpen = False, vuError = Nothing}})
    ViewGroupEditorToggle ->
        putModel (\x -> x{mGraphGroupEditor = not (mGraphGroupEditor x)})
    ViewGroupAdd -> do
        m <- get
        when (length (mGraphGroupDrafts m) < EV.maxColorGroups) $ do
            let group = EV.ColorGroup "group" "" "#C98A3E" True
            putModel
                ( \x ->
                    x
                        { mGraphGroupDrafts = mGraphGroupDrafts x ++ [group]
                        , mGraphGroupDirty = True
                        }
                )
            putModel recomputeGraphColors
    ViewGroupRemove index -> do
        putModel (\x -> x{mGraphGroupDrafts = removeAt index (mGraphGroupDrafts x), mGraphGroupDirty = True, mGraphGroupEditor = True})
        putModel recomputeGraphColors
    ViewGroupField index field value -> do
        let fieldText = fromMisoString value
            update group = case field of
                GroupName -> group{EV.cgName = fieldText}
                GroupQuery -> group{EV.cgQuery = fieldText}
                GroupColor -> group{EV.cgColor = fieldText}
        putModel (\x -> x{mGraphGroupDrafts = setAt index update (mGraphGroupDrafts x), mGraphGroupDirty = True, mGraphGroupEditor = True})
        putModel recomputeGraphColors
    ViewGroupToggleEnabled index -> do
        putModel (\x -> x{mGraphGroupDrafts = setAt index (\group -> group{EV.cgEnabled = not (EV.cgEnabled group)}) (mGraphGroupDrafts x), mGraphGroupDirty = True, mGraphGroupEditor = True})
        putModel recomputeGraphColors
    ViewGroupsSave -> do
        m <- get
        saveCurrentGraphView m
    ViewGroupsCancel -> do
        putModel
            ( \x ->
                x
                    { mGraphGroupDrafts = mGraphColorGroups x
                    , mGraphGroupDirty = False
                    , mGraphGroupEditor = False
                    }
            )
        putModel recomputeGraphColors
    ViewSaveGraph -> do
        m <- get
        saveCurrentGraphView m
    GraphLabelModeSelected mode -> putModel (\m -> m{mGraphLabelMode = mode})
    GraphPresetSelected preset -> do
        m <- get
        putModel (\x -> x{mGraphPreset = preset, mGraphLoading = True, mGraphError = Nothing})
        case mGraph m of
            Nothing -> pure ()
            Just _ -> fetchGraphLayout preset (GraphLayoutLoaded preset) GraphLayoutFailed
    GraphScopeToggled -> do
        putModel
            ( \x ->
                x
                    { mGraphLocal = not (mGraphLocal x)
                    , mGraphHover = Nothing
                    , mGraphFocus = Nothing
                    , mGraphSettled = False
                    , mGraphSettleEpoch = mGraphSettleEpoch x + 1
                    , mGraphDetailPhase = 0
                    }
            )
        putModel (\x -> fitActiveView (applyGraphScope x))
    GraphLocalDepthSelected depth -> do
        putModel
            ( \x ->
                x
                    { mGraphLocal = True
                    , mGraphLocalDepth = max 1 (min 3 depth)
                    , mGraphHover = Nothing
                    , mGraphSettled = False
                    , mGraphSettleEpoch = mGraphSettleEpoch x + 1
                    , mGraphDetailPhase = 0
                    }
            )
        putModel (\x -> fitActiveView (applyGraphScope x))
    GraphLocalAt root depth -> do
        putModel
            ( \x ->
                x
                    { mGraphLocal = True
                    , mGraphLocalRoot = Just root
                    , mGraphLocalDepth = max 1 (min 3 depth)
                    , mGraphHover = Nothing
                    , mGraphSettled = False
                    , mGraphSettleEpoch = mGraphSettleEpoch x + 1
                    , mGraphDetailPhase = 0
                    }
            )
        putModel (\x -> fitActiveView (applyGraphScope x))
        measureGraphCanvas GraphMeasured
    GraphSelect key ->
        putModel (\m -> m{mGraphSelected = Just key, mGraphFocus = Nothing})
    GraphClearSelection ->
        putModel (\m -> m{mGraphSelected = Nothing, mGraphFocus = Nothing})
    -- dedup ----------------------------------------------------------------
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
    TagStatsLoaded stats -> putModel (\m -> m{mTags = stats})
    ConsolLoaded groups ->
        putModel (\m -> m{mConsol = groups, mConsolLoading = False, mConsolError = Nothing})
    ConsolFailed err -> do
        putModel (\m -> m{mConsolLoading = False, mConsolError = Just (ms (aeMessage err))})
        handleApiError err
    TagMerge from into -> mergeTags from into TagMerged TagOpFailed
    TagRenamed old newName -> renameTag old (fromMisoString newName) TagMerged TagOpFailed
    TagDeleted tag -> deleteTag tag TagMerged TagOpFailed
    TagDialogOpen dialog -> do
        let draft = case dialog of
                TagRenameDialog tag -> ms tag
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
            TagRenameDialog _ -> liftSinkIO (focusAfterRender "tag-rename-input")
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
                let wanted = T.strip (fromMisoString (mTagDialogInput m))
                if T.null wanted
                    then putModel (\x -> x{mTagDialogError = Just "Enter a name for the tag."})
                    else
                        if wanted == old
                            then putModel (\x -> x{mTagDialogError = Just "That is already this tag's name."})
                            else do
                                putModel (\x -> x{mTagDialogBusy = True, mTagDialogError = Nothing})
                                updateModel (TagRenamed old (ms wanted))
            Just (TagDeleteDialog tag) -> do
                putModel (\x -> x{mTagDialogBusy = True, mTagDialogError = Nothing})
                updateModel (TagDeleted tag)
            Just (TagMergeDialog from into) -> do
                putModel (\x -> x{mTagDialogBusy = True, mTagDialogError = Nothing})
                updateModel (TagMerge from into)
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
        updateModel (Navigate Index)
    -- Open the ledger on an explicit query (a history year, day or
    -- source, or a tag from the graph). The query replaces the old one so
    -- the total matches the figure the reader clicked.
    FilterByQuery query -> do
        m <- get
        putModel
            ( \x ->
                x
                    { mQ = ms (T.unpack query)
                    , mTagsFilter = []
                    , mUnreadOnly = False
                    , mSort = "created"
                    }
            )
        if mRoute m == Index
            then reloadList
            else updateModel (Navigate Index)
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
        putModel (\m -> m{mTagDialogBusy = False, mTagDialogError = Just (ms (aeMessage err))})
        when (aeStatus err == Just 401) (handleApiError err)
    -- ai tags ---------------------------------------------------------------
    AiTagSelected tag -> do
        putModel
            ( \m ->
                m
                    { mAiTag = tag
                    , mSuggestions = []
                    , mSuggestionsLoading = isJust tag
                    , mSuggestionNotice = Nothing
                    , mSuggestionError = Nothing
                    }
            )
        case tag of
            Nothing -> pure ()
            Just selected -> fetchSuggestions selected SuggestionsLoaded SuggestionsFailed
    SuggestionsLoaded _configured suggestions notice ->
        putModel
            ( \m ->
                m
                    { mSuggestions = suggestions
                    , mSuggestionsLoading = False
                    , mSuggestionError = Nothing
                    , mSuggestionNotice = fmap ms notice
                    }
            )
    SuggestionsFailed err -> do
        putModel (\m -> m{mSuggestionsLoading = False, mSuggestionError = Just (ms (aeMessage err))})
        when (aeStatus err == Just 401) (handleApiError err)
    AiStatusReload -> fetchAiStatus AiStatusLoaded AiStatusFailed
    AiSuggestRetry -> do
        m <- get
        case mAiTag m of
            Nothing -> pure ()
            Just tag -> do
                putModel (\x -> x{mSuggestionsLoading = True, mSuggestionError = Nothing, mSuggestionNotice = Nothing})
                fetchSuggestions tag SuggestionsLoaded SuggestionsFailed
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
    SuggestionApply bookmarkId tags -> applyTagSuggestion bookmarkId tags SuggestionsApplied SuggestionsFailed
    SuggestionsApplied -> do
        notify "Tags applied" ToastOk
        refreshTags
        refreshStats
        m <- get
        case mAiTag m of
            Nothing -> pure ()
            Just tag -> fetchSuggestions tag SuggestionsLoaded SuggestionsFailed
    -- maintenance ----------------------------------------------------------
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
    AccountLoaded info -> do
        putModel
            ( \m ->
                m
                    { mAccount = Just info
                    , mAccountLoading = False
                    , mAccountError = Nothing
                    , mSessions = aiSessions info
                    , mSecurityUsername =
                        if T.null (T.strip (fromMisoString (mSecurityUsername m)))
                            then ms (aiUsername info)
                            else mSecurityUsername m
                    , mSecurity2faWanted = aiRequirePasskey info
                    , mAdminUsersLoading = null (mAdminUsers m)
                    }
            )
        m0 <- get
        when (mAdminUsersLoading m0) (fetchAdminUsers AdminUsersLoaded AdminUsersFailed)
    AccountFailed err -> do
        putModel (\m -> m{mAccountLoading = False, mAccountError = Just (ms (aeMessage err))})
        handleApiError err
    RecoveryRegenerate -> regenerateRecovery RecoveryLoaded AccountFailed
    RecoveryLoaded codes -> do
        putModel (\m -> m{mRecoveryCodes = codes})
        notify "New recovery codes. Store them now." ToastOk
    CredentialRenamed credentialId nickname -> do
        renameCredential credentialId (fromMisoString nickname) (ToastAdd "Passkey renamed" ToastOk) CredentialOpFailed
    CredentialDeleted credentialId -> deleteCredential credentialId (CredentialRemoved credentialId) CredentialOpFailed
    CredentialRemoved _ -> do
        notify "Passkey deleted" ToastOk
        fetchAccount AccountLoaded AccountFailed
    CredentialOpFailed err -> handleApiError err
    CredentialEditStart credentialId -> putModel (\m -> m{mCredEdit = Just (credentialId, "")})
    CredentialNameInput nickname -> putModel (\m -> m{mCredEdit = fmap (\(cid, _) -> (cid, nickname)) (mCredEdit m)})
    CredentialEditSave -> do
        m <- get
        case mCredEdit m of
            Nothing -> pure ()
            Just (credentialId, nickname) -> do
                putModel (\x -> x{mCredEdit = Nothing})
                renameCredential credentialId (fromMisoString nickname) AccountReload CredentialOpFailed
    CredentialEditCancel -> putModel (\m -> m{mCredEdit = Nothing})
    SecurityUsernameInput value -> putModel (\m -> m{mSecurityUsername = value, mSecurityError = Nothing})
    SecurityCurrentPasswordInput value -> putModel (\m -> m{mSecurityCurrent = value, mSecurityError = Nothing})
    SecurityNewPasswordInput value -> putModel (\m -> m{mSecurityNew = value, mSecurityError = Nothing})
    SecurityConfirmPasswordInput value -> putModel (\m -> m{mSecurityConfirm = value, mSecurityError = Nothing})
    Security2faWantedToggled wanted ->
        putModel (\m -> m{mSecurity2faWanted = wanted, mSecurityError = Nothing})
    SecurityUsernameSave -> do
        m <- get
        case mAccount m of
            Nothing -> setSecurityError "The account has not loaded yet."
            Just account ->
                let wanted = T.strip (fromMisoString (mSecurityUsername m))
                    current = fromMisoString (mSecurityCurrent m)
                 in if T.null wanted
                        then setSecurityError "Enter the username."
                        else
                            if aiHasPassword account && T.null (T.strip current)
                                then setSecurityError "Enter the current password to rename the account."
                                else do
                                    putModel (\x -> x{mSecurityBusy = True, mSecurityError = Nothing})
                                    patchUsername
                                        (if aiHasPassword account then Just current else Nothing)
                                        wanted
                                        (SecuritySaved "Username saved")
                                        SecurityFailed
    SecurityPasswordSave -> do
        m <- get
        case mAccount m of
            Nothing -> setSecurityError "The account has not loaded yet."
            Just account ->
                let current = fromMisoString (mSecurityCurrent m)
                    wanted = fromMisoString (mSecurityNew m)
                    repeated = fromMisoString (mSecurityConfirm m)
                 in if T.length wanted < 10
                        then setSecurityError "The new password must be at least ten characters."
                        else
                            if wanted /= repeated
                                then setSecurityError "The two new passwords do not match."
                                else
                                    if aiHasPassword account && T.null current
                                        then setSecurityError "Enter the current password."
                                        else do
                                            putModel (\x -> x{mSecurityBusy = True, mSecurityError = Nothing})
                                            changePassword
                                                (if aiHasPassword account then Just current else Nothing)
                                                wanted
                                                repeated
                                                (SecuritySaved "Password changed")
                                                SecurityFailed
    Security2faSave -> do
        m <- get
        case mAccount m of
            Nothing -> setSecurityError "The account has not loaded yet."
            Just account
                | aiRequirePasskey account == mSecurity2faWanted m ->
                    setSecurityError "The passkey requirement is already in that state."
                | mSecurity2faWanted m && null (aiCredentials account) ->
                    setSecurityError "Add a passkey before requiring one for sign-in."
                | aiHasPassword account
                , T.null (T.strip (fromMisoString (mSecurityCurrent m))) ->
                    setSecurityError "Enter the current password."
                | otherwise -> do
                    putModel (\x -> x{mSecurityBusy = True, mSecurityError = Nothing})
                    setPasskeyRequirement
                        (mSecurity2faWanted m)
                        ( if aiHasPassword account
                            then Just (fromMisoString (mSecurityCurrent m))
                            else Nothing
                        )
                        (SecuritySaved "Sign-in requirement saved")
                        SecurityFailed
    SecuritySaved message -> do
        putModel
            ( \m ->
                m
                    { mSecurityBusy = False
                    , mSecurityCurrent = ""
                    , mSecurityNew = ""
                    , mSecurityConfirm = ""
                    , mSecurityUsername = ""
                    , mSecurityError = Nothing
                    }
            )
        notify message ToastOk
        fetchAccount AccountLoaded AccountFailed
    SecurityFailed err -> do
        putModel (\m -> m{mSecurityBusy = False, mSecurityError = Just (ms (aeMessage err))})
        when (aeStatus err == Just 401) (handleApiError err)
    SessionsRevokeOthers -> do
        putModel (\m -> m{mAccountLoading = True})
        revokeOtherSessions SessionsRevoked SessionsRevokeFailed
    SessionsRevoked revoked -> do
        putModel (\m -> m{mAccountLoading = False})
        notify
            ( ms
                ( "Revoked "
                    <> show revoked
                    <> (if revoked == 1 then " other session" else " other sessions")
                )
            )
            ToastOk
        fetchAccount AccountLoaded AccountFailed
    SessionsRevokeFailed err -> do
        putModel (\m -> m{mAccountLoading = False})
        handleApiError err
    AccountReload -> fetchAccount AccountLoaded AccountFailed
    -- Signing out is a write, but an unsaved note would be lost silently, so
    -- the dirty editor asks first; a clean screen signs out immediately.
    LogoutRequest -> do
        m <- get
        if hasUnsaved m
            then putModel (\x -> x{mConfirmLogout = True})
            else updateModel Logout
    LogoutCancel -> putModel (\m -> m{mConfirmLogout = False})
    Logout -> logout LoggedOut (\err -> ApiErrorRaised err)
    LoggedOut -> liftSinkIO (redirectTo "/login")
    -- selection / bulk -----------------------------------------------------
    SelectToggled bookmarkId shift -> do
        m <- get
        let current = mSelection m
            indexOf :: Int -> Maybe Int
            indexOf target = case [i | (i, item) <- zip [0 :: Int ..] (mItems m), bsId item == target] of
                (i : _) -> Just i
                [] -> Nothing
        case (shift, mSelectAnchor m >>= \anchor -> (,) anchor <$> indexOf anchor) of
            (True, Just (_anchor, anchorIndex)) ->
                case indexOf bookmarkId of
                    Just currentIndex -> do
                        let (from, to) = (min anchorIndex currentIndex, max anchorIndex currentIndex)
                            rangeIds = [bsId item | (i, item) <- zip [0 :: Int ..] (mItems m), i >= from, i <= to]
                        putModel (\x -> x{mSelection = IS.union current (IS.fromList rangeIds)})
                    Nothing -> pure ()
            _ ->
                let next =
                        if IS.member bookmarkId current
                            then IS.delete bookmarkId current
                            else IS.insert bookmarkId current
                 in putModel (\x -> x{mSelection = next, mSelectAnchor = Just bookmarkId})
    SelectClear -> putModel (\m -> (cancelSelectAllPaging m){mSelection = IS.empty, mSelectAnchor = Nothing})
    -- Stop the paging run but keep the ids already collected.
    SelectAllMatchingCancel -> putModel cancelSelectAllPaging
    SelectAllLoaded -> do
        m <- get
        putModel (\x -> x{mSelection = IS.fromList (map bsId (mItems m)), mSelectAnchor = Nothing})
    SelectAllMatchingStart -> do
        m <- get
        unless (mSelectingAll m) $ do
            -- Capture the query, filter, sort and list epoch once: the pages
            -- that follow belong to this result set even if the reader types
            -- again or clears the bar.
            let selectEpoch = mSelectEpoch m + 1
                params = (listParams m False){lpOffset = 0, lpLimit = 200}
            put
                m
                    { mSelectingAll = True
                    , mSelection = IS.empty
                    , mSelectAnchor = Nothing
                    , mSelectFetched = 0
                    , mSelectEpoch = selectEpoch
                    , mSelectListEpoch = mListEpoch m
                    , mSelectParams = Just params
                    }
            fetchBookmarks
                params
                (\page -> SelectPageLoaded selectEpoch (map bsId (spItems page)) (spHasMore page))
                (SelectPageFailed selectEpoch)
    -- A page may only extend the run captured by this token and only while the
    -- list still shows the result set the run started on.
    SelectPageLoaded selectEpoch ids hasMore -> do
        m <- get
        when (mSelectingAll m && selectEpoch == mSelectEpoch m && mSelectListEpoch m == mListEpoch m) $ do
            let fetched = mSelectFetched m + length ids
                merged = IS.union (mSelection m) (IS.fromList ids)
                capped = if IS.size merged > 10000 then IS.fromList (take 10000 (IS.toList merged)) else merged
            put m{mSelection = capped, mSelectFetched = fetched}
            if hasMore && IS.size capped < 10000
                then case mSelectParams m of
                    Nothing -> putModel cancelSelectAllPaging
                    Just params ->
                        fetchBookmarks
                            (params{lpOffset = fetched, lpLimit = 200})
                            (\page -> SelectPageLoaded selectEpoch (map bsId (spItems page)) (spHasMore page))
                            (SelectPageFailed selectEpoch)
                else do
                    putModel (\x -> (cancelSelectAllPaging x){mSelection = capped})
                    if IS.size capped >= 10000
                        then notify "Selected the first 10,000 bookmarks" ToastInfo
                        else notify (ms ("Selected " <> show (IS.size capped) <> " bookmarks")) ToastOk
    SelectPageFailed selectEpoch err -> do
        m <- get
        when (selectEpoch == mSelectEpoch m) $ do
            putModel cancelSelectAllPaging
            handleApiError err
    BulkTagPromptOpen adding -> do
        putModel (\m -> m{mTagPrompt = Just adding, mTagPromptValue = ""})
        liftSinkIO (focusAfterRender "bulk-tag-input")
    BulkTagInput value -> putModel (\m -> m{mTagPromptValue = value})
    BulkTagCancel -> putModel (\m -> m{mTagPrompt = Nothing, mTagPromptValue = ""})
    BulkTagSubmit -> do
        m <- get
        let ids = IS.toList (mSelection m)
            tags = splitTags (mTagPromptValue m)
            adding = mTagPrompt m == Just True
        if null ids
            then notify "Select at least one bookmark first" ToastInfo
            else
                if null tags
                    then notify "Type at least one tag" ToastInfo
                    else do
                        putModel (\x -> x{mBulkBusy = True, mTagPrompt = Nothing, mTagPromptValue = ""})
                        bulkUpdate
                            (if adding then BulkAddTags tags else BulkRemoveTags tags)
                            ids
                            BulkActionDone
                            BulkActionFailed
    BulkMark readFlag -> do
        m <- get
        let ids = IS.toList (mSelection m)
        if null ids
            then notify "Select at least one bookmark first" ToastInfo
            else do
                putModel (\x -> x{mBulkBusy = True})
                bulkUpdate (BulkMarkRead readFlag) ids BulkActionDone BulkActionFailed
    BulkDeleteRequest -> do
        m <- get
        if IS.null (mSelection m)
            then notify "Select at least one bookmark first" ToastInfo
            else putModel (\x -> x{mConfirmBulkDelete = True})
    BulkDeleteCancel -> putModel (\m -> m{mConfirmBulkDelete = False})
    BulkDeleteConfirm -> do
        m <- get
        putModel (\x -> x{mConfirmBulkDelete = False, mBulkBusy = True})
        bulkUpdate BulkDelete (IS.toList (mSelection m)) BulkActionDone BulkActionFailed
    BulkActionDone updated -> do
        putModel
            ( \m ->
                m
                    { mSelection = IS.empty
                    , mSelectAnchor = Nothing
                    , mSelectingAll = False
                    , mBulkBusy = False
                    , mTagPrompt = Nothing
                    , mTagPromptValue = ""
                    , mConfirmBulkDelete = False
                    }
            )
        notify (ms ("Updated " <> show updated <> " bookmarks")) ToastOk
        reloadList
        refreshTags
        refreshStats
    BulkActionFailed err -> do
        putModel (\m -> m{mBulkBusy = False})
        handleApiError err
    RetryEnrich bookmarkId -> do
        putModel
            ( \m ->
                m
                    { mDetail =
                        fmap (\detail -> detail{bdEnrichState = "queued", bdEnrichError = ""}) (mDetail m)
                    }
            )
        bookmarkAction bookmarkId "enrich" (DetailReload bookmarkId) (\err -> ApiErrorRaised err)
    DetailReload bookmarkId -> reloadDetail bookmarkId
    -- api tokens -----------------------------------------------------------
    TokensLoaded tokens ->
        putModel (\m -> m{mTokens = tokens, mTokensLoading = False, mTokensError = Nothing})
    TokensFailed err -> do
        putModel (\m -> m{mTokensLoading = False, mTokensError = Just (ms (aeMessage err))})
        handleApiError err
    TokenNameInput value -> putModel (\m -> m{mTokenName = value})
    TokenScopeToggled scope ->
        putModel
            ( \m ->
                m
                    { mTokenScopes =
                        if scope `elem` mTokenScopes m
                            then filter (/= scope) (mTokenScopes m)
                            else mTokenScopes m ++ [scope]
                    }
            )
    TokenCreate -> do
        m <- get
        let name = T.strip (fromMisoString (mTokenName m))
        if T.null name
            then notify "Give the token a name" ToastInfo
            else
                if null (mTokenScopes m)
                    then notify "Pick at least one scope" ToastInfo
                    else do
                        putModel (\x -> x{mTokenBusy = True})
                        createApiToken name (mTokenScopes m) TokenCreated TokenCreateFailed
    TokenCreated raw info -> do
        putModel
            ( \m ->
                m
                    { mTokens = info : filter ((/= tvId info) . tvId) (mTokens m)
                    , mTokenName = ""
                    , mTokenBusy = False
                    , mTokenSecret = Just (raw, info)
                    }
            )
        notify "Token created. Copy it now; it is shown once." ToastOk
    TokenCreateFailed err -> do
        putModel (\m -> m{mTokenBusy = False})
        handleApiError err
    TokenRevoke tokenId -> revokeApiToken tokenId TokenRevoked TokenCreateFailed
    TokenRevoked -> do
        notify "Token revoked" ToastOk
        fetchTokens TokensLoaded TokensFailed
    TokenRevealDismiss -> putModel (\m -> m{mTokenSecret = Nothing})
    TokenCopied raw -> copyText (ms raw) "Token copied" "Copy failed. Select the text instead"
    -- admin users ----------------------------------------------------------
    AdminUsersLoaded users ->
        putModel
            ( \m ->
                m
                    { mAdminUsers = users
                    , mAdminUsersAllowed = True
                    , mAdminUsersLoading = False
                    , mAdminUsersError = Nothing
                    }
            )
    AdminUsersFailed err -> do
        putModel
            ( \m ->
                m
                    { mAdminUsersLoading = False
                    , mAdminUsersAllowed = False
                    , mAdminUsersError = if mAccountTab m == AccountUsers then Just (ms (aeMessage err)) else Nothing
                    }
            )
        when (aeStatus err == Just 401) (handleApiError err)
    UserNameInput value -> putModel (\m -> m{mUserName = value, mUserFormError = Nothing})
    UserPasswordInput value -> putModel (\m -> m{mUserPassword = value, mUserFormError = Nothing})
    UserRoleSelected role -> putModel (\m -> m{mUserRole = role})
    UserCreate -> do
        m <- get
        let input =
                UserCreateInput
                    { uciUsername = T.strip (fromMisoString (mUserName m))
                    , uciPassword = fromMisoString (mUserPassword m)
                    , uciRole = mUserRole m
                    }
        putModel (\x -> x{mUserBusy = True, mUserFormError = Nothing})
        createAdminUser input UserCreated UserCreateFailed
    UserCreated result -> do
        notify "User created. Copy the recovery codes now." ToastOk
        putModel
            ( \m ->
                m
                    { mAdminUsers = upsertUser (ucrUser result) (mAdminUsers m)
                    , mAdminUsersLoading = False
                    , mAdminUsersError = Nothing
                    , mUserBusy = False
                    , mUserFormError = Nothing
                    , mUserName = ""
                    , mUserPassword = ""
                    , mUserRole = RoleMember
                    , mUserRecovery = Just (uvUsername (ucrUser result), ucrRecoveryCodes result)
                    }
            )
    UserCreateFailed err -> do
        putModel (\m -> m{mUserBusy = False, mUserFormError = Just (ms (aeMessage err))})
        when (aeStatus err == Just 401) (handleApiError err)
    UserToggleEnabled user ->
        patchAdminUser
            (uvId user)
            (Just (not (isUserEnabled user)))
            Nothing
            UserUpdated
            UserUpdateFailed
    UserRoleChange user ->
        patchAdminUser
            (uvId user)
            Nothing
            (Just (if uvRole user == RoleAdmin then RoleMember else RoleAdmin))
            UserUpdated
            UserUpdateFailed
    UserUpdated user -> do
        notify "User updated" ToastOk
        putModel
            ( \m ->
                m
                    { mAdminUsers = upsertUser user (mAdminUsers m)
                    , mUserActionError = Nothing
                    }
            )
    UserUpdateFailed err ->
        putModel (\m -> m{mUserActionError = Just (ms (aeMessage err))})
    UserResetOpen userId ->
        putModel (\m -> m{mUserReset = Just userId, mUserResetPassword = "", mUserActionError = Nothing})
    UserResetPasswordInput value -> putModel (\m -> m{mUserResetPassword = value})
    UserResetSubmit -> do
        m <- get
        case mUserReset m of
            Nothing -> pure ()
            Just userId ->
                let password = fromMisoString (mUserResetPassword m)
                 in if T.null (T.strip password)
                        then putModel (\x -> x{mUserActionError = Just "a temporary password is required"})
                        else resetAdminPassword userId password (UserResetDone userId password) UserResetFailed
    UserResetDone userId password -> do
        notify "Temporary password set. The user's sessions were revoked." ToastOk
        putModel
            ( \m ->
                let username = case [uvUsername user | user <- mAdminUsers m, uvId user == userId] of
                        (name : _) -> name
                        [] -> T.pack (show userId)
                 in m
                        { mUserReset = Nothing
                        , mUserResetPassword = ""
                        , mUserResetShown = Just (username, password)
                        , mUserActionError = Nothing
                        }
            )
    UserResetCancel -> putModel (\m -> m{mUserReset = Nothing, mUserResetPassword = "", mUserActionError = Nothing})
    UserResetFailed err ->
        putModel (\m -> m{mUserActionError = Just (ms (aeMessage err))})
    UserRecoveryCopied raw -> copyText (ms raw) "Recovery codes copied" "Copy failed. Select the text instead"
    UserRecoveryDismiss -> putModel (\m -> m{mUserRecovery = Nothing})
    UserResetShownDismiss -> putModel (\m -> m{mUserResetShown = Nothing})
    UserDeleteOpen user ->
        putModel
            ( \m ->
                m
                    { mUserDelete = Just user
                    , mUserDeleteName = ""
                    , mUserDeleteLibrary = False
                    , mUserDeleteBusy = False
                    , mUserActionError = Nothing
                    }
            )
    UserDeleteCancel ->
        putModel
            ( \m ->
                m
                    { mUserDelete = Nothing
                    , mUserDeleteName = ""
                    , mUserDeleteLibrary = False
                    , mUserDeleteBusy = False
                    }
            )
    UserDeleteNameInput value -> putModel (\m -> m{mUserDeleteName = value})
    UserDeleteLibraryToggled -> putModel (\m -> m{mUserDeleteLibrary = not (mUserDeleteLibrary m)})
    UserDeleteSubmit -> do
        m <- get
        case mUserDelete m of
            Just user
                | T.strip (fromMisoString (mUserDeleteName m)) == uvUsername user -> do
                    putModel (\x -> x{mUserDeleteBusy = True, mUserActionError = Nothing})
                    deleteAdminUser (uvId user) (mUserDeleteLibrary m) (UserDeleted (uvId user)) UserDeleteFailed
                | otherwise ->
                    putModel (\x -> x{mUserActionError = Just "type the account name to confirm"})
            Nothing -> pure ()
    UserDeleted userId -> do
        notify "Account deleted" ToastOk
        putModel
            ( \m ->
                m
                    { mUserDelete = Nothing
                    , mUserDeleteName = ""
                    , mUserDeleteLibrary = False
                    , mUserDeleteBusy = False
                    , mUserActionError = Nothing
                    , mAdminUsers = [user | user <- mAdminUsers m, uvId user /= userId]
                    }
            )
        fetchAdminUsers AdminUsersLoaded AdminUsersFailed
    UserDeleteFailed err ->
        putModel (\m -> m{mUserDeleteBusy = False, mUserActionError = Just (ms (aeMessage err))})
    -- webhooks -------------------------------------------------------------
    WebhooksLoaded webhooks ->
        putModel (\m -> m{mWebhooks = webhooks, mWebhooksLoading = False, mWebhooksError = Nothing})
    WebhooksFailed err -> do
        putModel (\m -> m{mWebhooksLoading = False, mWebhooksError = Just (ms (aeMessage err))})
        handleApiError err
    WebhookNameInput value -> putModel (\m -> m{mWebhookName = value})
    WebhookUrlInput value -> putModel (\m -> m{mWebhookUrl = value})
    WebhookEventToggled eventType ->
        putModel
            ( \m ->
                m
                    { mWebhookEvents =
                        if eventType `elem` mWebhookEvents m
                            then filter (/= eventType) (mWebhookEvents m)
                            else mWebhookEvents m ++ [eventType]
                    , mWebhookFormError = Nothing
                    }
            )
    WebhookEnabledToggled -> putModel (\m -> m{mWebhookEnabled = not (mWebhookEnabled m)})
    WebhookCreate -> do
        m <- get
        let input =
                WebhookInput
                    { wiName = T.strip (fromMisoString (mWebhookName m))
                    , wiUrl = T.strip (fromMisoString (mWebhookUrl m))
                    , wiEvents = mWebhookEvents m
                    , wiEnabled = mWebhookEnabled m
                    }
        putModel (\x -> x{mWebhookBusy = True, mWebhookFormError = Nothing})
        createWebhook input (\(webhook, secret) -> WebhookCreated webhook secret) WebhookCreateFailed
    WebhookCreated webhook secret -> do
        notify "Webhook created. Copy the signing secret now." ToastOk
        putModel
            ( \m ->
                m
                    { mWebhooks = upsertWebhook webhook (mWebhooks m)
                    , mWebhooksLoading = False
                    , mWebhooksError = Nothing
                    , mWebhookBusy = False
                    , mWebhookFormError = Nothing
                    , mWebhookSecret = Just secret
                    , mWebhookName = ""
                    , mWebhookUrl = ""
                    , mWebhookEvents = []
                    , mWebhookEnabled = True
                    }
            )
    WebhookCreateFailed err -> do
        putModel
            ( \m ->
                m
                    { mWebhookBusy = False
                    , mWebhookFormError = Just (ms (aeMessage err))
                    }
            )
        when (aeStatus err == Just 401) (handleApiError err)
    WebhookToggle webhook ->
        updateWebhook
            (whId webhook)
            ( WebhookInput
                (whName webhook)
                (whUrl webhook)
                (whEvents webhook)
                (not (whEnabled webhook))
            )
            WebhookToggled
            WebhookToggleFailed
    WebhookToggled webhook -> do
        notify "Webhook updated" ToastOk
        putModel (\m -> m{mWebhooks = upsertWebhook webhook (mWebhooks m)})
    WebhookToggleFailed err -> handleApiError err
    WebhookTestRequest webhookId -> do
        putModel (\m -> m{mWebhookTest = Nothing, mWebhookTestError = Nothing})
        testWebhook webhookId (WebhookTested webhookId) WebhookTestFailed
    WebhookTested webhookId result ->
        putModel (\m -> m{mWebhookTest = Just (webhookId, result), mWebhookTestError = Nothing})
    WebhookTestFailed err -> do
        putModel (\m -> m{mWebhookTest = Nothing, mWebhookTestError = Just (ms (aeMessage err))})
        when (aeStatus err == Just 401) (handleApiError err)
    WebhookDelete webhookId ->
        deleteWebhook webhookId (WebhookDeleted webhookId) WebhookDeleteFailed
    WebhookDeleted webhookId -> do
        notify "Webhook deleted" ToastOk
        putModel
            ( \m ->
                m
                    { mWebhooks = filter ((/= webhookId) . whId) (mWebhooks m)
                    , mWebhookDeliveries = case mWebhookDeliveries m of
                        Just (showId, _) | showId == webhookId -> Nothing
                        other -> other
                    , mWebhookTest = case mWebhookTest m of
                        Just (showId, _) | showId == webhookId -> Nothing
                        other -> other
                    }
            )
    WebhookDeleteFailed err -> handleApiError err
    WebhookSecretDismiss -> putModel (\m -> m{mWebhookSecret = Nothing})
    WebhookSecretCopied raw -> copyText (ms raw) "Webhook secret copied" "Copy failed. Select the text instead"
    WebhookDeliveriesOpen webhookId -> do
        putModel (\m -> m{mWebhookDeliveriesError = Nothing})
        fetchWebhookDeliveries webhookId (WebhookDeliveriesLoaded webhookId) (WebhookDeliveriesFailed webhookId)
    WebhookDeliveriesLoaded webhookId deliveries ->
        putModel (\m -> m{mWebhookDeliveries = Just (webhookId, deliveries), mWebhookDeliveriesError = Nothing})
    WebhookDeliveriesFailed _webhookId err ->
        putModel (\m -> m{mWebhookDeliveries = Nothing, mWebhookDeliveriesError = Just (ms (aeMessage err))})
    -- highlights -----------------------------------------------------------
    HighlightsLoaded epoch highlights -> sameEpoch epoch $ do
        m <- get
        case mRoute m of
            Bookmark _ -> putModel (\x -> x{mHighlights = highlights, mHighlightsLoading = False})
            _ -> pure ()
    HighlightsFailed epoch err -> sameEpoch epoch $ do
        putModel (\m -> m{mHighlightsLoading = False})
        handleApiError err
    ReaderMouseUp -> withSink $ \sink -> do
        raw <- jsgf "ezaSelectionOffsets" ("reader-text" :: MisoString)
        selectionJson <- fromJSVal raw
        let selection = case (selectionJson :: Maybe MisoString) of
                Nothing -> Nothing
                Just json -> case MJ.eitherDecode json of
                    Right parsed -> Just (parsed :: ReaderSelection)
                    Left _ -> Nothing
        sink (ReaderSelectionFound selection)
    ReaderSelectionFound selection -> putModel (\m -> m{mReaderSel = selection})
    ReaderSelectionClear -> putModel (\m -> m{mReaderSel = Nothing})
    HighlightCreateQuick -> do
        m <- get
        case (currentDetail m, mReaderSel m) of
            (Just detail, Just selection) ->
                createHighlight
                    (bdId detail)
                    (rsQuote selection)
                    (readerPrefix detail selection)
                    (readerSuffix detail selection)
                    (rsStart selection)
                    (rsEnd selection)
                    ""
                    "yellow"
                    HighlightAdded
                    HighlightFailed
            _ -> notify "Select some reader text first" ToastInfo
    HighlightNoteOpen -> putModel (\m -> m{mHighlightNoteOpen = True, mHighlightNote = ""})
    HighlightNoteInput value -> putModel (\m -> m{mHighlightNote = value})
    HighlightNoteCancel -> putModel (\m -> m{mHighlightNoteOpen = False, mHighlightNote = ""})
    HighlightNoteSubmit -> do
        m <- get
        case (currentDetail m, mReaderSel m) of
            (Just detail, Just selection) -> do
                putModel (\x -> x{mHighlightNoteOpen = False})
                createHighlight
                    (bdId detail)
                    (rsQuote selection)
                    (readerPrefix detail selection)
                    (readerSuffix detail selection)
                    (rsStart selection)
                    (rsEnd selection)
                    (fromMisoString (mHighlightNote m))
                    "yellow"
                    HighlightAdded
                    HighlightFailed
            _ -> putModel (\x -> x{mHighlightNoteOpen = False})
    HighlightAdded highlight -> do
        putModel
            ( \m ->
                m
                    { mHighlights = insertHighlight highlight (mHighlights m)
                    , mReaderSel = Nothing
                    , mHighlightNoteOpen = False
                    , mHighlightNote = ""
                    }
            )
        notify "Highlight saved" ToastOk
        refreshStats
    HighlightEditStart highlightId -> do
        m <- get
        case [highlight | highlight <- mHighlights m, hId highlight == highlightId] of
            (highlight : _) ->
                putModel
                    ( \x ->
                        x
                            { mHighlightEdit = Just highlightId
                            , mHighlightEditNote = ms (hNote highlight)
                            , mHighlightEditColor = hColor highlight
                            }
                    )
            [] -> pure ()
    HighlightEditInput value -> putModel (\m -> m{mHighlightEditNote = value})
    HighlightEditColor color -> putModel (\m -> m{mHighlightEditColor = color})
    HighlightEditCancel -> putModel (\m -> m{mHighlightEdit = Nothing, mHighlightEditNote = ""})
    HighlightEditSave -> do
        m <- get
        case (currentDetail m, mHighlightEdit m) of
            (Just detail, Just highlightId) -> do
                putModel (\x -> x{mHighlightEdit = Nothing})
                patchHighlight
                    (bdId detail)
                    highlightId
                    (Just (fromMisoString (mHighlightEditNote m)))
                    (Just (mHighlightEditColor m))
                    HighlightPatched
                    HighlightFailed
            _ -> putModel (\x -> x{mHighlightEdit = Nothing})
    HighlightDelete highlightId -> do
        m <- get
        case currentDetail m of
            Just detail -> deleteHighlight (bdId detail) highlightId HighlightDeleted HighlightFailed
            Nothing -> pure ()
    HighlightPatched -> do
        notify "Highlight updated" ToastOk
        reloadHighlights
    HighlightDeleted -> do
        notify "Highlight deleted" ToastOk
        reloadHighlights
        refreshStats
    HighlightFailed err -> handleApiError err
    -- sharing --------------------------------------------------------------
    SharesLoaded epoch shares -> sameEpoch epoch $ do
        putModel
            ( \m ->
                m
                    { mShares = shares
                    , mSharesLoading = False
                    , mSharesError = Nothing
                    }
            )
    SharesFailed epoch err -> sameEpoch epoch $ do
        putModel (\m -> m{mSharesLoading = False, mSharesError = Just (ms (aeMessage err))})
        handleApiError err
    ShareDialogOpen -> do
        m <- get
        case currentDetail m of
            Just _ -> do
                let epoch = mDetailEpoch m
                putModel
                    ( \x ->
                        x
                            { mShareDialogOpen = True
                            , mShareIncludeNote = False
                            , mShareExpiryDays = 30
                            , mShareUrl = Nothing
                            , mShareBusy = False
                            , mSharesLoading = True
                            , mSharesError = Nothing
                            }
                    )
                fetchShares (\shares -> SharesLoaded epoch shares) (SharesFailed epoch)
            Nothing -> pure ()
    ShareDialogClose -> putModel (\m -> m{mShareDialogOpen = False, mShareUrl = Nothing})
    ShareIncludeNoteToggle -> putModel (\m -> m{mShareIncludeNote = not (mShareIncludeNote m)})
    ShareExpirySelected days -> putModel (\m -> m{mShareExpiryDays = days})
    ShareCreate -> do
        m <- get
        case currentDetail m of
            Just detail -> do
                putModel (\x -> x{mShareBusy = True})
                createShareLink
                    "bookmark"
                    (bdId detail)
                    (mShareIncludeNote m)
                    (mShareExpiryDays m)
                    ShareCreated
                    ShareCreateFailed
            Nothing -> pure ()
    ShareCreated shareId url -> do
        putModel (\m -> m{mShareBusy = False, mShareUrl = Just url})
        notify (ms ("Share link created (#" <> show shareId <> ")")) ToastOk
        refreshShares
        refreshStats
    ShareCreateFailed err -> do
        putModel (\m -> m{mShareBusy = False})
        handleApiError err
    ShareCopy url -> copyText (ms (url :: Text)) "Share link copied" "Copy failed. Select the text instead"
    ShareRevoke shareId -> revokeShareLink shareId ShareRevoked ShareCreateFailed
    ShareRevoked -> do
        notify "Share link revoked" ToastOk
        refreshShares
        refreshStats
    -- snapshot -------------------------------------------------------------
    SnapshotOpen -> putModel (\m -> m{mSnapshotOpen = True})
    SnapshotClose -> putModel (\m -> m{mSnapshotOpen = False})
    -- ai status ------------------------------------------------------------
    AiStatusLoaded status -> putModel (\m -> m{mAiStatus = Just status})
    AiStatusFailed _ -> pure ()
    -- rules ----------------------------------------------------------------
    RulesLoaded rules ->
        putModel (\m -> m{mRules = rules, mRulesLoading = False, mRulesError = Nothing})
    RulesFailed err -> do
        putModel (\m -> m{mRulesLoading = False, mRulesError = Just (ms (aeMessage err))})
        handleApiError err
    RuleNameInput value -> putModel (\m -> m{mRuleName = value})
    RuleFieldSelected field -> putModel (\m -> m{mRuleField = field})
    RulePatternInput value -> putModel (\m -> m{mRulePattern = value})
    RuleTagsInput value -> putModel (\m -> m{mRuleTags = value})
    RuleMarkReadToggled -> putModel (\m -> m{mRuleMarkRead = not (mRuleMarkRead m)})
    RuleCreate -> do
        m <- get
        let name = T.strip (fromMisoString (mRuleName m))
            patternText = T.strip (fromMisoString (mRulePattern m))
        if T.null name || T.null patternText
            then notify "Rule name and pattern are required" ToastInfo
            else do
                putModel (\x -> x{mRuleBusy = True})
                createRule
                    name
                    True
                    (mRuleField m)
                    patternText
                    (splitTags (mRuleTags m))
                    (mRuleMarkRead m)
                    RuleCreated
                    RuleCreateFailed
    RuleCreated rule -> do
        putModel
            ( \m ->
                m
                    { mRules = mRules m ++ [rule]
                    , mRuleName = ""
                    , mRulePattern = ""
                    , mRuleTags = ""
                    , mRuleMarkRead = False
                    , mRuleBusy = False
                    , mRuleDryRun = Nothing
                    }
            )
        notify (ms ("Rule “" <> ruleName rule <> "” created")) ToastOk
    RuleCreateFailed err -> do
        putModel (\m -> m{mRuleBusy = False})
        handleApiError err
    RuleToggleEnabled rule -> patchRule (ruleId rule) rule{ruleEnabled = not (ruleEnabled rule)} (RuleToggled rule{ruleEnabled = not (ruleEnabled rule)}) RuleFailed
    RuleToggled updated ->
        putModel
            ( \m ->
                m
                    { mRules = map (\rule -> if ruleId rule == ruleId updated then updated else rule) (mRules m)
                    }
            )
    RuleDelete ruleIdToDelete -> deleteRule ruleIdToDelete (RuleDeleted ruleIdToDelete) RuleFailed
    RuleDeleted ruleIdToDelete -> do
        putModel (\m -> m{mRules = filter (\rule -> ruleId rule /= ruleIdToDelete) (mRules m)})
        notify "Rule deleted" ToastOk
    RuleFailed err -> handleApiError err
    RuleDryRun -> do
        m <- get
        let patternText = T.strip (fromMisoString (mRulePattern m))
        if T.null patternText
            then notify "Enter a pattern to dry-run" ToastInfo
            else do
                putModel (\x -> x{mRuleBusy = True, mRuleDryRun = Nothing})
                testRule (mRuleField m) patternText RuleDryRunResult RuleDryRunFailed
    RuleDryRunResult matches ids -> do
        putModel (\m -> m{mRuleBusy = False, mRuleDryRun = Just (matches, ids)})
        notify (ms (show matches <> " bookmark(s) would match")) ToastOk
    RuleDryRunFailed err -> do
        putModel (\m -> m{mRuleBusy = False})
        handleApiError err
    -- toasts ---------------------------------------------------------------
    ToastAdd message kind -> notify message kind
    ToastDismiss dismissed -> putModel (\m -> m{mToasts = filter (\toast -> toastId toast /= dismissed) (mToasts m)})
  where
    reloadHighlights = do
        m <- get
        case currentDetail m of
            Just detail -> do
                let epoch = mDetailEpoch m
                fetchHighlights (bdId detail) (HighlightsLoaded epoch) (HighlightsFailed epoch)
            Nothing -> pure ()

    finalizeAdd :: Int -> Effect () () Model Action
    finalizeAdd bookmarkId = do
        m <- get
        putModel
            ( \x ->
                x
                    { mAddOpen = False
                    , mAddBusy = False
                    , mAddUrl = ""
                    , mAddTitle = ""
                    , mAddTags = ""
                    , mAddNote = ""
                    , mAddError = Nothing
                    }
            )
        notify (ms ("Saved bookmark #" <> show bookmarkId)) ToastOk
        refreshTags
        refreshStats
        if isSaveRoute (mRoute m)
            then withSink $ \_ -> replaceURI (toURI (Bookmark bookmarkId))
            else reloadList

    -- \| Reload one record after an enrichment or a cancelled edit: new epoch,
    -- empty editor, loading view rather than the previous record.
    reloadDetail :: Int -> Effect () () Model Action
    reloadDetail bookmarkId = do
        m <- get
        let epoch = mDetailEpoch m + 1
        put
            m
                { mDetail = Nothing
                , mDetailLoading = True
                , mDetailError = Nothing
                , mDetailEpoch = epoch
                , mReadRequest = mReadRequest m + 1
                , mReadPending = False
                , mEditTitle = ""
                , mEditNote = ""
                , mEditTags = []
                , mNewTag = ""
                , mDirty = False
                , mExtractEditing = False
                , mExtractDraft = ""
                , mExtractDirty = False
                , mExtractSaving = False
                , mNoteMode = NoteWrite
                , mLinkQuery = Nothing
                , mLinkResults = []
                , mBacklinks = []
                , mHighlights = []
                , mHighlightsLoading = True
                , mReaderSel = Nothing
                , mHighlightNoteOpen = False
                , mHighlightNote = ""
                , mHighlightEdit = Nothing
                , mSnapshotOpen = False
                , mShareDialogOpen = False
                , mShareUrl = Nothing
                , mConfirmDelete = Nothing
                }
        fetchDetail bookmarkId (DetailLoaded epoch) (DetailFailed epoch)
        fetchBacklinks bookmarkId (BacklinksLoaded epoch) (BacklinksFailed epoch)
        fetchHighlights bookmarkId (HighlightsLoaded epoch) (HighlightsFailed epoch)

    -- \| Refresh the share list without starting a new route epoch.
    refreshShares :: Effect () () Model Action
    refreshShares = do
        m <- get
        let epoch = mDetailEpoch m
        fetchShares (\shares -> SharesLoaded epoch shares) (SharesFailed epoch)

    -- \| Put a validation or server message in the security panel instead of
    -- a toast: the field it belongs to is on the same screen.
    setSecurityError :: MisoString -> Effect () () Model Action
    setSecurityError message =
        putModel (\m -> m{mSecurityBusy = False, mSecurityError = Just message})

    -- \| EA-00417: the accession form used by the dedup toast and dialog.
    accessionLabel :: Int -> MisoString
    accessionLabel bookmarkId =
        ms ("EA-" <> replicate (max 0 (5 - length raw)) '0' <> raw)
      where
        raw = show bookmarkId

    -- Is a layer covering the ledger? A bare letter belongs to that layer, so
    -- the palette must not open underneath a dialog.
    hasModalLayer :: Model -> Bool
    hasModalLayer m =
        mPaletteOpen m
            || mAddOpen m
            || mGuardOpen m
            || mConfirmLogout m
            || mSnapshotOpen m
            || mShareDialogOpen m
            || isJust (mTagDialog m)
            || isJust (mDedupConfirm m)
            || mDedupMergeAllOpen m
            || isJust (mSavedShare m)
            || isJust (mTagPrompt m)
            || mConfirmBulkDelete m
            || isJust (mConfirmDelete m)
            || mHighlightNoteOpen m
            || isJust (mHighlightEdit m)
            || vuSaveOpen (mViewUi m)
            || vuImportOpen (mViewUi m)
            || isJust (vuExport (mViewUi m))
            || mUndoPreviewLoading m
            || isJust (mUndoPreview m)
            || isJust (mUndoPreviewError m)

    closeTopLayer m
        | mUndoPreviewLoading m || isJust (mUndoPreview m) || isJust (mUndoPreviewError m) = updateModel UndoPreviewClose
        | vuSaveOpen (mViewUi m) = putModel (\x -> x{mViewUi = (mViewUi x){vuSaveOpen = False, vuError = Nothing}})
        | vuImportOpen (mViewUi m) = putModel (\x -> x{mViewUi = (mViewUi x){vuImportOpen = False, vuError = Nothing}})
        | isJust (vuExport (mViewUi m)) = putModel (\x -> x{mViewUi = (mViewUi x){vuExport = Nothing}})
        | mConfirmLogout m = putModel (\x -> x{mConfirmLogout = False})
        | mHighlightNoteOpen m = putModel (\x -> x{mHighlightNoteOpen = False, mHighlightNote = ""})
        | isJust (mHighlightEdit m) = putModel (\x -> x{mHighlightEdit = Nothing, mHighlightEditNote = ""})
        | mShareDialogOpen m = putModel (\x -> x{mShareDialogOpen = False, mShareUrl = Nothing})
        | isJust (mSavedShare m) = putModel (\x -> x{mSavedShare = Nothing, mShareUrl = Nothing})
        | isJust (mTagDialog m) = putModel (\x -> x{mTagDialog = Nothing, mTagDialogError = Nothing})
        | isJust (mDedupConfirm m) = putModel (\x -> x{mDedupConfirm = Nothing})
        | mDedupMergeAllOpen m = putModel (\x -> x{mDedupMergeAllOpen = False})
        | mSnapshotOpen m = putModel (\x -> x{mSnapshotOpen = False})
        | isJust (mReaderSel m) = putModel (\x -> x{mReaderSel = Nothing})
        | mPaletteOpen m = putModel (\x -> x{mPaletteOpen = False, mPaletteQ = "", mPaletteSel = 0})
        | mAddOpen m = putModel (\x -> x{mAddOpen = False})
        | mGuardOpen m = updateModel DirtyGuardClose
        | isJust (mTagPrompt m) = putModel (\x -> x{mTagPrompt = Nothing, mTagPromptValue = ""})
        | mConfirmBulkDelete m = putModel (\x -> x{mConfirmBulkDelete = False})
        | isJust (mLinkQuery m) = putModel (\x -> x{mLinkQuery = Nothing, mLinkResults = []})
        | isJust (mDrawer m) = putModel (\x -> x{mDrawer = Nothing})
        | isJust (mConfirmDelete m) = putModel (\x -> x{mConfirmDelete = Nothing})
        | not (IS.null (mSelection m)) = putModel (\x -> (cancelSelectAllPaging x){mSelection = IS.empty, mSelectAnchor = Nothing})
        | mSelectingAll m = putModel cancelSelectAllPaging
        | otherwise = pure ()

    choosePalette :: Int -> Effect () () Model Action
    choosePalette offsetFromSelection = do
        m <- get
        let entries = paletteEntries m
            selection = max 0 (mPaletteSel m + offsetFromSelection)
        case drop selection entries of
            ((_, _, nextAction) : _) -> do
                putModel (\x -> x{mPaletteOpen = False, mPaletteQ = "", mPaletteSel = 0})
                updateModel nextAction
            [] -> pure ()

    moveCursor :: Int -> Effect () () Model Action
    moveCursor delta = do
        m <- get
        let n = length (mItems m)
        when (n > 0) $ do
            let start = fromMaybe (if delta > 0 then -1 else n) (mLedgerCursor m)
                idx = max 0 (min (n - 1) (start + delta))
            setCursor idx
            when (idx + 8 >= n && mHasMore m) loadMore

    setCursor :: Int -> Effect () () Model Action
    setCursor idx = do
        m <- get
        case itemAt (mItems m) idx of
            Nothing -> pure ()
            Just b -> do
                putModel (\x -> x{mLedgerCursor = Just idx, mDrawer = Just (bsId b)})
                if mWidth m < 768
                    then liftSinkIO (scrollRowIntoView (ms ("ledger-row-" <> show (bsId b))))
                    else do
                        let target = max 0 (ledgerScrollTarget m idx)
                        when (target /= mScrollY m) $ liftSinkIO (ezaScrollLedger target)

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

    openCursorRecord :: Model -> Effect () () Model Action
    openCursorRecord m =
        case itemAt (mItems m) (fromMaybe 0 (mLedgerCursor m)) of
            Nothing -> pure ()
            Just b -> updateModel (Navigate (Bookmark (bsId b)))

    -- \| Open the row the keyboard is on: it becomes the cursor row first, so
    -- returning from the record lands on what the reader activated.
    activateRow :: Int -> Effect () () Model Action
    activateRow bookmarkId = do
        m <- get
        case indexOfBookmark (mItems m) bookmarkId of
            Just idx -> putModel (\x -> x{mLedgerCursor = Just idx})
            Nothing -> pure ()
        updateModel (Navigate (Bookmark bookmarkId))

    -- \| The index of a bookmark in the loaded ledger.
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
            , mSelectEpoch = mSelectEpoch x + 1
            , mSelectParams = Nothing
            }

    -- \| Rewrite the current history entry (no navigation, no new entry). Used
    -- to put the address back after cancelling a history-driven dirty guard.
    replaceBrowserUrl :: MisoString -> IO ()
    replaceBrowserUrl path = void (jsgf "ezaReplaceUrl" (path :: MisoString))

    -- \| Copy text through the promise-based bridge. The toast reports the
    -- real result, so a one-time secret is never announced as copied when the
    -- clipboard write was denied.
    copyText :: MisoString -> MisoString -> MisoString -> Effect () () Model Action
    copyText value successMessage failureMessage = withSink $ \sink -> do
        _ <-
            jsgf
                "ezaCopy"
                ( value
                , asyncCallback1
                    ( \jsValue -> do
                        copied <- fromMaybe False <$> (fromJSVal jsValue :: IO (Maybe Bool))
                        sink
                            ( ToastAdd
                                (if copied then successMessage else failureMessage)
                                (if copied then ToastOk else ToastError)
                            )
                    )
                )
        pure ()

    decodeImportReport :: Value -> Either String ImportReport
    decodeImportReport value = case fromJSON value of
        Error message -> Left message
        Success report -> Right report

    -- \| Continue a return-to-position after a list page arrived. If the
    -- loaded content cannot reach the saved offset yet, fetch pages until it
    -- can (or until the list has no more rows), then set the model offset and
    -- the container together.
    continueScrollRestore :: Effect () () Model Action
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
                        liftSinkIO (ezaScrollLedger seek)
                    else loadMore

    -- \| Scroll the ledger container to an absolute pixel offset. The helper
    -- lives in pwa.js because the target row may not be in the virtual DOM.
    ezaScrollLedger :: Int -> IO ()
    ezaScrollLedger pixels = void $ jsgf "ezaScrollLedger" (pixels :: Int)

    -- \| Narrow sheets render every row, so the browser can find the row by id.
    scrollRowIntoView :: MisoString -> IO ()
    scrollRowIntoView domId = do
        document <- jsg ("document" :: MisoString)
        el <- (document # ("getElementById" :: MisoString)) domId
        _ <- (el # ("scrollIntoView" :: MisoString)) ()
        pure ()

    itemAt :: [a] -> Int -> Maybe a
    itemAt xs i
        | i < 0 = Nothing
        | otherwise = case drop i xs of
            (x : _) -> Just x
            [] -> Nothing

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

-- -------------------------------------------------------------- graph glue --

graphZoom :: Double -> Effect () () Model Action
graphZoom factor = do
    m <- get
    case activeGraphLayout m of
        Nothing -> pure ()
        Just layout -> do
            let view = zoomViewCenter layout (mGraphView m) factor
            putModel
                ( \model ->
                    model
                        { mGraphView = view
                        , mGraphSettled = False
                        , mGraphSettleEpoch = mGraphSettleEpoch model + 1
                        , mGraphDetailPhase = 0
                        }
                )
            scheduleGraphSettle

{- | A pointer that went down and up without moving is a click: a record
selects, a tag opens the ledger filtered by @tag:@, and empty plate clears.
-}
graphClick :: Model -> Double -> Double -> Effect () () Model Action
graphClick m x y =
    case activeGraphLayout m of
        Nothing -> pure ()
        Just layout -> case visibleHit m (nodeAt layout (mGraphView m) (x, y)) of
            Nothing ->
                putModel (\model -> model{mGraphSelected = Nothing, mGraphFocus = Nothing})
            Just key
                | isTagKey key -> case IM.lookup key (glTags layout) of
                    Just (name, _) -> updateModel (FilterByQuery ("tag:" <> name))
                    Nothing -> pure ()
                | otherwise ->
                    updateModel (Navigate (Bookmark key))

{- | Focus the plate once it has painted, so the keyboard shortcuts work
immediately after a visit. @preventScroll@ keeps the panel from jumping to
the canvas on a phone, where focus() would otherwise scroll the title and the
filter line out of view.

The canvas only exists after the first layout paints, and on a large library
that can arrive several animation frames after the graph payload. A single
timer used to give up when the element was not mounted yet; retry over a few
frames instead, like 'measureGraphCanvas'.
-}
focusGraphPlate :: Model -> Effect () () Model Action
focusGraphPlate m =
    when
        (isGraphRoute (mRoute m) && T.null (T.strip (fromMisoString (mGraphFilter m))))
        (liftSinkIO focusGraphCanvas)

focusGraphCanvas :: IO ()
focusGraphCanvas = attempt (0 :: Int)
  where
    attempt tries = do
        focused <- focusWithoutScroll "graph-canvas"
        unless focused (retry (tries + 1))
    retry tries =
        when (tries < 30) $ do
            callback <- asyncCallback1 (\_ -> attempt tries)
            _ <- jsgf "requestAnimationFrame" callback
            pure ()

focusWithoutScroll :: MisoString -> IO Bool
focusWithoutScroll domId = do
    document <- jsg ("document" :: MisoString)
    element <- (document # ("getElementById" :: MisoString)) domId
    missing <- isNull element
    if missing
        then pure False
        else do
            options <- create
            setField options ("preventScroll" :: MisoString) True
            _ <- (element # ("focus" :: MisoString)) [options]
            pure True

{- | A hit on a tag node only counts while the tag layer is shown; otherwise a
click could open a ledger for a node the reader cannot see.
-}
visibleHit :: Model -> Maybe Int -> Maybe Int
visibleHit _ Nothing = Nothing
visibleHit m (Just key)
    | not (mGraphTagsShown m) && isTagKey key = Nothing
    | otherwise = Just key

{- | Validate and hydrate a server layout. The revision and the two position
arrays must line up with the graph payload, otherwise the caller keeps the
local fallback.
-}
hydrateWire :: GraphData -> LayoutWire -> Maybe GraphLayout
hydrateWire graph wire
    | lwRevision wire /= gdRevision graph = Nothing
    | length (lwTags wire) /= length (gdTags graph) = Nothing
    | length (lwRecords wire) /= length (gdRecords graph) = Nothing
    | otherwise =
        Just
            ( hydrateLayout
                graph
                LayoutPositions
                    { -- Core hydrates tag positions by tag index and record
                      -- positions by bookmark id, so apply the node-key mapping
                      -- only there, never twice.
                      lpTagPositions = IM.fromList (zip [0 :: Int ..] (lwTags wire))
                    , lpRecordPositions =
                        IM.fromList
                            [ (recordKeyOf (grId record), point)
                            | (record, point) <- zip (gdRecords graph) (lwRecords wire)
                            ]
                    , lpBounds = lwBounds wire
                    }
            )

-- | Replace a local fallback with a pending server layout for the same preset.
upgradeWithWire :: GraphData -> Model -> Model
upgradeWithWire graph m =
    case (mGraphLayoutWire m, mGraphLayoutSource m) of
        (Just (preset, wire), "local")
            | preset == mGraphPreset m
            , Just hydrated <- hydrateWire graph wire ->
                let generation = mGraphGen m + 1
                 in m
                        { mGraphLayout = Just hydrated{glGen = generation}
                        , mGraphGen = generation
                        , mGraphLayoutSource = "server"
                        }
        _ -> m

-- ------------------------------------------------------------- views glue --

findViewBySlug :: Text -> [EV.View] -> Maybe EV.View
findViewBySlug slug views =
    case [view | view <- views, EV.vSlug view == slug] of
        (view : _) -> Just view
        [] -> Nothing

defaultGraphView :: [EV.View] -> Maybe EV.View
defaultGraphView views =
    case [view | view <- views, EV.vKind view == EV.GraphKind, EV.vIsDefault view] of
        (view : _) -> Just view
        [] -> case [view | view <- views, EV.vKind view == EV.GraphKind] of
            (view : _) -> Just view
            [] -> Nothing

{- | Apply a graph view definition to the graph state. Color maps are rebuilt
from the graph data by 'recomputeGraphColors'.
-}
applyGraphView :: EV.View -> Model -> Model
applyGraphView view m = case EV.vDefinition view of
    EV.GraphDefinition definition ->
        m
            { mGraphViewId = Just (EV.vId view)
            , mGraphViewRev = EV.vUpdatedAt view
            , mGraphFilter = ms (T.unpack (EV.gvdQuery definition))
            , mGraphTagsShown = EV.gvdTagsShown definition
            , mGraphLabelMode = EV.gvdLabelMode definition
            , mGraphPreset = EV.gvdLayoutPreset definition
            , mGraphLocal = isJust (EV.gvdLocalDepth definition)
            , mGraphLocalDepth = fromMaybe 1 (EV.gvdLocalDepth definition)
            , mGraphLocalRoot = Nothing
            , mGraphColorGroups = EV.gvdColorGroups definition
            , mGraphGroupDrafts = EV.gvdColorGroups definition
            , mGraphGroupDirty = False
            , mGraphGroupEditor = False
            }
    _ -> m

-- | The current graph state as a view definition, ready to PATCH or POST.
currentGraphDefinition :: Model -> EV.ViewDefinition
currentGraphDefinition m =
    EV.GraphDefinition
        EV.GraphViewDefinition
            { EV.gvdQuery = fromMisoString (mGraphFilter m)
            , EV.gvdTagsShown = mGraphTagsShown m
            , EV.gvdLabelMode = mGraphLabelMode m
            , EV.gvdLayoutPreset = mGraphPreset m
            , EV.gvdLocalDepth = if mGraphLocal m then Just (mGraphLocalDepth m) else Nothing
            , EV.gvdColorGroups = mGraphGroupDrafts m
            }

currentLedgerDefinition :: Model -> EV.ViewDefinition
currentLedgerDefinition m =
    EV.LedgerDefinition
        EV.LedgerViewDefinition
            { EV.lvdQuery = fromMisoString (mQ m)
            , EV.lvdSort = case mSort m of
                "added" -> EV.SortAdded
                "opened" -> EV.SortOpened
                _ -> EV.SortCreated
            }

-- | Build the record and tag color maps once per graph/view/groups change.
recomputeGraphColors :: Model -> Model
recomputeGraphColors m =
    case mGraph m of
        Nothing -> m{mGraphColors = Nothing, mGraphGroupCounts = []}
        Just graph ->
            let groups = mGraphGroupDrafts m
                assignment = GM.assignGroupColors groups graph
                countFor group
                    | not (EV.cgEnabled group) = 0
                    | otherwise =
                        length
                            [ ()
                            | record <- gdRecords graph
                            , GM.matchesQueryRecord (parseSearchQuery (EV.cgQuery group)) graph record
                            ]
             in m
                    { mGraphColors = Just assignment
                    , mGraphGroupCounts = map countFor groups
                    }

upsertView :: EV.View -> [EV.View] -> [EV.View]
upsertView view views =
    view : [existing | existing <- views, EV.vSlug existing /= EV.vSlug view]

{- | Open a saved view: graph views switch the graph route to the definition,
ledger views load the ledger with the saved query and sort.
-}
openSavedView :: Text -> Effect () () Model Action
openSavedView slug = do
    m <- get
    case findViewBySlug slug (mViews m) of
        Just view -> openSavedViewNow view
        Nothing -> fetchView slug ViewFetched ViewFetchFailed

openSavedViewNow :: EV.View -> Effect () () Model Action
openSavedViewNow view = case EV.vDefinition view of
    EV.GraphDefinition definition -> do
        putModel (applyGraphView view)
        m <- get
        when (isJust (mGraphLayout m)) $
            updateModel (GraphPresetSelected (EV.gvdLayoutPreset definition))
        putModel recomputeGraphColors
        updateModel (Navigate Graph)
    EV.LedgerDefinition definition -> do
        putModel
            ( \x ->
                x
                    { mQ = ms (T.unpack (EV.lvdQuery definition))
                    , mSort = EV.ledgerSortText (EV.lvdSort definition)
                    , mTagsFilter = []
                    , mUnreadOnly = False
                    }
            )
        updateModel (Navigate Index)

-- | PATCH the active (or default) graph view with the current state.
saveCurrentGraphView :: Model -> Effect () () Model Action
saveCurrentGraphView m =
    case graphTarget of
        Nothing -> updateModel (ViewSaveOpen EV.GraphKind)
        Just view -> do
            putModel (\x -> x{mViewUi = (mViewUi x){vuBusy = True, vuError = Nothing}})
            patchView
                (EV.vSlug view)
                ( ViewPatch
                    Nothing
                    Nothing
                    (Just (currentGraphDefinition m))
                    (Just (EV.vIsDefault view))
                )
                ViewSaved
                ViewSaveFailed
  where
    graphTarget = case mGraphViewId m of
        Just viewId -> case [view | view <- mViews m, EV.vId view == viewId] of
            (view : _) -> Just view
            [] -> defaultGraphView (mViews m)
        Nothing -> defaultGraphView (mViews m)

setAt :: Int -> (a -> a) -> [a] -> [a]
setAt index update list = [if position == index then update value else value | (position, value) <- zip [0 :: Int ..] list]

removeAt :: Int -> [a] -> [a]
removeAt index list = [value | (position, value) <- zip [0 :: Int ..] list, position /= index]

-- | The definition of the active saved graph view, when one is selected.
activeGraphDefinition :: Model -> Maybe EV.GraphViewDefinition
activeGraphDefinition m = do
    viewId <- mGraphViewId m
    view <- case [candidate | candidate <- mViews m, EV.vId candidate == viewId] of
        (candidate : _) -> Just candidate
        [] -> Nothing
    case EV.vDefinition view of
        EV.GraphDefinition definition -> Just definition
        _ -> Nothing

isLocalGraphRoute :: Route -> Bool
isLocalGraphRoute route = case route of
    GraphLocal{} -> True
    _ -> False

isUserEnabled :: UserView -> Bool
isUserEnabled user = isNothing (uvDisabledAt user)

upsertUser :: UserView -> [UserView] -> [UserView]
upsertUser user users =
    user : [existing | existing <- users, uvId existing /= uvId user]

upsertWebhook :: Webhook -> [Webhook] -> [Webhook]
upsertWebhook webhook webhooks =
    webhook : [existing | existing <- webhooks, whId existing /= whId webhook]

{- | Do two layouts paint the same pixels? Compare the source maps and the
derived primitives; the generation is deliberately excluded.
-}
sameGraphLayout :: GraphLayout -> GraphLayout -> Bool
wirePresetDiffers :: Model -> LayoutPreset -> Bool
wirePresetDiffers model preset =
    case mGraphLayoutWire model of
        Just (wirePreset, _) -> wirePreset /= preset
        Nothing -> False
sameGraphLayout left right =
    glPos left == glPos right
        && glRadii left == glRadii right
        && glLinks left == glLinks right
        && glMembers left == glMembers right
        && glTags left == glTags right
        && glRecords left == glRecords right

{- | Load the graph route. Whole mode keeps the cached view; local mode
rebuilds the neighbourhood and fits it before the first paint. A warm route
keeps its layout wire and only refreshes the records; a cold route asks for
the layout first so the first plate is hydrated instead of painted twice.
-}
enterGraphRoute :: Bool -> Maybe Int -> Int -> Effect () () Model Action
enterGraphRoute localMode root depth = do
    m <- get
    let viewLocalDepth = EV.gvdLocalDepth <$> activeGraphDefinition m
        viewLocal = maybe False isJust viewLocalDepth
        effectiveLocal = localMode || viewLocal
        effectiveDepth = if localMode then max 1 (min 3 depth) else fromMaybe (max 1 (min 3 depth)) (join viewLocalDepth)
    putModel
        ( \x ->
            x
                { mGraphLoading =
                    case mGraphLayoutWire x of
                        Just (wirePreset, _) | wirePreset == mGraphPreset x && isJust (mGraphLayout x) -> False
                        _ -> isNothing (mGraphLayout x)
                , mGraphError = Nothing
                , mGraphLocal = effectiveLocal
                , mGraphLocalDepth = effectiveDepth
                , mGraphLocalRoot = root
                , mGraphDetailPhase = 0
                , mGraphSettled = False
                , mGraphSettleEpoch = mGraphSettleEpoch x + 1
                , mGraphHover = Nothing
                }
        )
    putModel (\x -> if effectiveLocal then fitActiveView (applyGraphScope x) else applyGraphScope x)
    current <- get
    let preset = mGraphPreset current
        cachedWire = case mGraphLayoutWire current of
            Just (wirePreset, _) | wirePreset == preset -> True
            _ -> False
    if cachedWire
        then fetchGraph GraphLoaded GraphFailed
        else fetchGraphLayout preset (GraphLayoutLoaded preset) GraphLayoutFailed
    measureGraphCanvas GraphMeasured

{- | Resolve the row that roots local mode: the explicit root when it still
exists, else the selected record, else the focused record, else the
highest-degree record in the whole layout.
-}
resolveLocalRoot :: Model -> GraphLayout -> Maybe Int
resolveLocalRoot m whole =
    case [key | Just key <- [mGraphLocalRoot m, mGraphSelected m, mGraphFocus m], usable key] of
        (key : _) -> Just key
        []
            | (key : _) <- glRecordOrder whole
            , not (isTagKey key) ->
                Just key
            | otherwise -> Nothing
  where
    usable key = not (isTagKey key) && IM.member key (glPos whole)

{- | Rebuild the active derived layout after the scope, root or depth changed.
The whole layout is never rebuilt here, so the 2,500-node local cap is the
only work local mode adds.
-}
applyGraphScope :: Model -> Model
applyGraphScope m =
    case mGraphLayout m of
        Nothing -> m
        Just whole
            | not (mGraphLocal m) ->
                m
                    { mGraphLocalLayout = Nothing
                    , mGraphLocalCapped = False
                    , mGraphMatches = matchOn whole
                    }
            | otherwise ->
                case resolveLocalRoot m whole of
                    Just root ->
                        case localLayout whole root (mGraphLocalDepth m) of
                            Just (local, capped) ->
                                m
                                    { mGraphLocalRoot = Just root
                                    , mGraphLocalLayout = Just local
                                    , mGraphLocalCapped = capped
                                    , mGraphMatches = matchOn local
                                    }
                            Nothing -> emptyScope m
                    Nothing -> emptyScope m
  where
    matchOn layout = matchGraph (T.strip (fromMisoString (mGraphFilter m))) layout
    emptyScope model =
        model
            { mGraphLocalLayout = Nothing
            , mGraphLocalCapped = False
            , mGraphMatches = emptyMatches
            }

{- | Fit the plate to the active layout. Used when the scope, root, depth or
preset changes; not on interaction frames.
-}
fitActiveView :: Model -> Model
fitActiveView m =
    case activeGraphLayout m of
        Nothing -> m
        Just layout ->
            let old = mGraphView m
             in m
                    { mGraphView = fitView layout (gvWidth old) (gvHeight old) (gvDpr old)
                    , mGraphHover = Nothing
                    , mGraphSettled = False
                    , mGraphSettleEpoch = mGraphSettleEpoch m + 1
                    , mGraphDetailPhase = 0
                    }

{- | The view is moving: the plate keeps blitting the world bitmap, and the
screen-resolution detail plate is stale until the gesture stops.
-}
markGraphMoving :: Effect () () Model Action
markGraphMoving =
    putModel
        ( \m ->
            m
                { mGraphSettled = False
                , mGraphSettleEpoch = mGraphSettleEpoch m + 1
                , mGraphDetailPhase = 0
                }
        )

{- | Arm a settle check for the current view epoch. Timers are never cancelled:
a stale epoch is ignored, so only the timer armed for the last view can build
the detail plate. One timer per gesture event is cheap.
-}
scheduleGraphSettle :: Effect () () Model Action
scheduleGraphSettle = do
    m <- get
    let epoch = mGraphSettleEpoch m
    withSink $ \sink -> do
        _ <- jsgf "setTimeout" (asyncCallback1 (\_ -> sink (GraphSettled epoch)), 150 :: Int)
        pure ()

{- | Draw one chunk of the settle plate per animation frame. Chunking keeps
each frame short: the plate sharpens over a handful of frames instead of
blocking one long task after the gesture stops.
-}
scheduleGraphDetailStep :: Int -> Int -> Effect () () Model Action
scheduleGraphDetailStep epoch phase =
    withSink $ \sink -> do
        callback <- asyncCallback1 (\_ -> sink (GraphDetailStep epoch phase))
        _ <- jsgf "requestAnimationFrame" callback
        pure ()

{- | Escape clears an active filter first, then the selection. The filter is
the more specific state, so it goes first.
-}
graphEscape :: Model -> Effect () () Model Action
graphEscape m
    | not (T.null (T.strip (fromMisoString (mGraphFilter m)))) = do
        updateModel (GraphFilterChanged "")
        updateModel GraphFilterSettled
    | otherwise = updateModel GraphClearSelection

{- | Pan the graph from the global keyboard bridge. The canvas is a tab stop,
but the shortcuts run from any non-editable focus on the graph route, so the
panel does not need to keep DOM focus on the canvas to be keyboard driven.
-}
graphPan :: Double -> Double -> Bool -> Effect () () Model Action
graphPan deltaX deltaY accelerated = do
    m <- get
    case mGraphLayout m of
        Nothing -> pure ()
        Just _ -> do
            let step = if accelerated then 160 else 48
            putModel
                ( \model ->
                    model
                        { mGraphView = panView (deltaX * step, deltaY * step) (mGraphView model)
                        , mGraphSettled = False
                        , mGraphSettleEpoch = mGraphSettleEpoch model + 1
                        , mGraphDetailPhase = 0
                        }
                )
            scheduleGraphSettle

-- | Enter on the graph opens the selected record, matching a click.
graphOpenSelected :: Model -> Effect () () Model Action
graphOpenSelected m =
    case mGraphSelected m of
        Just key | not (isTagKey key) -> updateModel (Navigate (Bookmark key))
        _ -> pure ()

{- | Read the canvas box after a render. The element only exists once the graph
layout has painted, so a few short retries cover the first frame.
-}
measureGraphCanvas :: (Double -> Double -> Double -> Action) -> Effect () () Model Action
measureGraphCanvas onMeasured = withSink $ \sink -> measureWith sink 0
  where
    measureWith :: Sink Action -> Int -> IO ()
    measureWith sink attempt = do
        document <- jsg ("document" :: MisoString)
        element <- document # ("querySelector" :: MisoString) $ (".g-canvas-el" :: MisoString)
        missing <- isNull element
        if missing
            then retry sink attempt
            else do
                width <- (fromJSValUnchecked =<< element ! ("clientWidth" :: MisoString)) :: IO Double
                height <- (fromJSValUnchecked =<< element ! ("clientHeight" :: MisoString)) :: IO Double
                dpr <- (fromJSValUnchecked =<< jsg ("devicePixelRatio" :: MisoString)) :: IO Double
                if width < 40 || height < 40
                    then retry sink attempt
                    else sink (onMeasured width height (min 2 dpr))
    retry :: Sink Action -> Int -> IO ()
    retry sink attempt =
        when (attempt < 4) $
            void $
                jsgf "setTimeout" (asyncCallback (measureWith sink (attempt + 1)), 80 :: Int)
