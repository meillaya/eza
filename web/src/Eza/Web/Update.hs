{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The MVU update function: every action's state transition and side effect.
module Eza.Web.Update (updateModel, subscriptions) where

import Control.Monad (unless, void, when)
import Data.Aeson (Result (..), Value (..), fromJSON, object, (.=))
import qualified Data.IntSet as IS
import Data.List (nub)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T

import Miso
import qualified Miso.JSON as MJ
import Miso.Router (toURI)

import Eza.Types (
    BookmarkDetail (..),
    BookmarkSummary (..),
    BootPayload (..),
    DedupCounts (..),
    DedupGroup (..),
    DedupMergeAllReport (..),
    DedupReport (..),
    Highlight (..),
    ImportReport,
    SavedSearch (..),
    SearchPage (..),
 )
import Eza.Web.Api
import Eza.Web.Model
import Eza.Web.Types (
    AccountInfo (..),
    ApiError (..),
    ReaderSelection (..),
    Rule (..),
    TokenView (..),
    fieldInt,
 )

{- | Component subscriptions: URL changes (back/forward), window scroll for
the virtualized grid, and window resize for the column count.
-}
subscriptions :: [Sub Model Action]
subscriptions =
    [ routerSub RouteChanged
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
            notify "Session expired. Sign in again to continue." ToastError
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
    Index -> "eza, the catalogue"
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
    let enteringNewDetail = case route of
            Bookmark bookmarkId -> case mRoute m of
                Bookmark currentId -> currentId /= bookmarkId
                _ -> True
            _ -> True
        enteringList = isListRoute route && not (isListRoute (mRoute m))
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
        Graph -> do
            current <- get
            case mGraphSeed current of
                Nothing -> putModel (\x -> x{mGraph = Nothing, mGraphLoading = False})
                Just seed -> fetchGraph (Just seed) (mGraphDepth current) GraphLoaded GraphFailed
        Dedup -> dedupFirstPage DedupLoaded DedupFailed
        Tags -> do
            fetchConsolidation ConsolLoaded ConsolFailed
            refreshTags
        AiTags -> do
            refreshTags
            fetchAiStatus AiStatusLoaded (\_ -> Noop)
        Maintenance -> fetchPruneCandidates PruneLoaded PruneFailed
        Account -> do
            putModel (\x -> x{mTokensLoading = True, mSharesLoading = True, mRulesLoading = True})
            fetchAccount AccountLoaded AccountFailed
            fetchTokens TokensLoaded TokensFailed
            fetchShares (\shares -> SharesLoaded epoch shares) (SharesFailed epoch)
            fetchRules RulesLoaded RulesFailed
        Accessions -> pure ()
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
    when (route == Account) $ withSink $ \sink -> do
        hash <- readAccountHash
        sink (AccountTabFromHash hash)

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
readAccountHash :: IO MisoString
readAccountHash = do
    window' <- jsg "window"
    location' <- window' ! "location"
    raw <- fromJSVal =<< getProperty location' "hash"
    pure
        ( maybe
            ""
            (ms . (fromMisoString :: MisoString -> String))
            (raw :: Maybe MisoString)
        )

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
            sink (RouteChanged (Right (routeOfUri uri)))
    RouteChanged routeResult -> do
        m <- get
        case routeResult of
            Left _ -> loadRoute NotFound
            -- The share-target landing page is a real page now: it renders the
            -- prefilled save form instead of quietly writing a bookmark.
            Right route ->
                if mDirty m && route /= mRoute m && isDetailRoute (mRoute m)
                    then put m{mGuardOpen = True, mPendingRoute = Just route}
                    else loadRoute route
    Navigate route -> do
        m <- get
        if route == mRoute m
            then pure ()
            else
                if mDirty m && isDetailRoute (mRoute m)
                    then put m{mGuardOpen = True, mPendingRoute = Just route}
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
            notify "Bookmarklet is unavailable until the app knows its origin." ToastInfo
        | otherwise -> withSink $ \sink -> do
            copiedValue <- jsgf "ezaCopy" (bookmarklet :: MisoString)
            copied <- fromMaybe False <$> (fromJSVal copiedValue :: IO (Maybe Bool))
            sink
                ( ToastAdd
                    (if copied then "Bookmarklet copied" else "Copy failed. Drag the link instead")
                    (if copied then ToastOk else ToastError)
                )
    LayoutChanged width height -> do
        putModel (\m -> m{mWidth = width, mHeight = height})
        withSink $ \sink -> do
            measured <- measureGrid
            sink (ScrollMetrics measured)
    Resized -> withSink $ \sink -> do
        width <- windowInnerWidth
        height <- windowInnerHeight
        measured <- measureGrid
        sink (LayoutChanged width height)
        sink (ScrollMetrics measured)
    Scrolled -> withSink $ \sink -> do
        measured <- measureGrid
        sink (ScrollMetrics measured)
    ScrollMetrics Nothing -> pure ()
    ScrollMetrics (Just (scrollY, height, gridTop)) -> do
        putModel (\m -> m{mScrollY = scrollY, mHeight = height, mGridTop = gridTop})
        m <- get
        let content = gridTop + ledgerContentHeight m
        when (mHasMore m && not (mLoading m) && not (mLoadingMore m) && scrollY + height + 600 >= content) $
            loadMore
    KeyPressed key -> do
        m <- get
        let withModifier = keCtrl key || keMeta key
            editable = keEditable key
            plain = not withModifier && not (keAlt key)
            ledger = isListRoute (mRoute m)
            runAction action = updateModel action
        -- event.key is upper case for a shifted letter; the shortcut names
        -- below are the unshifted ones.
        case T.toLower (keKey key) of
            -- Escape closes the top layer from any focus, including a field.
            "escape" -> closeTopLayer m
            -- The command palette is reachable from every screen: the command
            -- mods always, Shift+K outside fields, and a bare k off the ledger
            -- (so the hint on the search line is not the only way in).
            "k" | withModifier -> runAction PaletteOpen
            "k" | not editable && keShift key -> runAction PaletteOpen
            "k" | not editable && plain && ledger -> moveCursor (-1)
            "k" | not editable && plain && not (hasModalLayer m) -> runAction PaletteOpen
            "j" | not editable && plain && ledger -> moveCursor 1
            -- The search line: focus it from any screen, but never steal a
            -- slash the user is typing into a field.
            "/" | not editable -> do
                runAction PaletteClose
                liftSinkIO (focus "search-input")
            "enter" | mPaletteOpen m -> runAction PaletteSelect
            "enter" | not editable && ledger -> openCursorRecord m
            "arrowup" | mPaletteOpen m -> runAction PalettePrev
            "arrowdown" | mPaletteOpen m -> runAction PaletteNext
            "s" | withModifier && isDetailRoute (mRoute m) -> runAction SaveBookmark
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
                    , mBootReady = True
                    }
            )
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
    DrawerOpen bid -> putModel (\m -> m{mDrawer = Just bid})
    DrawerClose -> putModel (\m -> m{mDrawer = Nothing})
    AccountTabSelected tab -> do
        putModel (\m -> m{mAccountTab = tab})
        liftSinkIO (setAccountHash (accountTabSlug tab))
    AccountTabFromHash hash -> putModel (\m -> m{mAccountTab = accountTabFromSlug hash})
    -- library ---------------------------------------------------------------
    SearchInput query -> do
        putModel
            ( \m ->
                m
                    { mQ = query
                    , mSelection = IS.empty
                    , mSelectAnchor = Nothing
                    , mSelectingAll = False
                    , mConfirmMarkAll = False
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
                    , mYearHere = spYearCounts page
                    , mHasMore = spHasMore page
                    , mLoading = False
                    , mLoadingMore = False
                    , mOffset = spOffset page + length (spItems page)
                    , mError = Nothing
                    , mConfirmMarkAll = False
                    , mSelection = if append then mSelection m else IS.empty
                    , mSelectAnchor = if append then mSelectAnchor m else Nothing
                    , mSelectingAll = False
                    , mLedgerCursor =
                        case (append, mLedgerCursor m) of
                            (False, _) -> Nothing
                            (True, Just idx) | idx < length fresh -> Just idx
                            _ -> Nothing
                    }
    ListFailed _append epoch err -> do
        m <- get
        when (epoch == mListEpoch m) $ do
            putModel
                ( \x ->
                    x
                        { mLoading = False
                        , mLoadingMore = False
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
                putModel (\x -> x{mSaving = True})
                patchBookmark
                    (bdId detail)
                    ( object
                        [ "title" .= mEditTitle m
                        , "note_body" .= mEditNote m
                        , "is_read" .= bdIsRead detail
                        , "tags" .= mEditTags m
                        ]
                    )
                    SavedOk
                    SaveFailed
    SavedOk -> do
        putModel (\m -> m{mSaving = False, mDirty = False})
        notify "Saved" ToastOk
        refreshStats
    SaveFailed err -> do
        putModel (\m -> m{mSaving = False})
        handleApiError err
    -- A read toggle is its own patch: it must not clear the unsaved note and
    -- it must not claim the note was saved.
    ReadToggled -> do
        m <- get
        case currentDetail m of
            Nothing -> pure ()
            Just detail -> do
                let nextRead = not (bdIsRead detail)
                putModel (\x -> x{mDetail = Just detail{bdIsRead = nextRead}})
                patchBookmark
                    (bdId detail)
                    (object ["is_read" .= nextRead])
                    (ReadPatched nextRead)
                    (ReadPatchFailed nextRead)
    ReadPatched readFlag -> do
        m <- get
        case currentDetail m of
            Nothing -> pure ()
            Just detail -> putModel (\x -> x{mDetail = Just detail{bdIsRead = readFlag}})
        refreshStats
    ReadPatchFailed readFlag err -> do
        m <- get
        case currentDetail m of
            Just detail
                | bdIsRead detail == readFlag ->
                    putModel (\x -> x{mDetail = Just detail{bdIsRead = not readFlag}})
            _ -> pure ()
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
            (Just bookmarkId, Just detail) | bdId detail == bookmarkId -> do
                putModel (\x -> x{mDetail = Nothing, mDetailLoading = False})
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
    DirtyGuardOpen route -> putModel (\m -> m{mGuardOpen = True, mPendingRoute = Just route})
    DirtyGuardClose -> putModel (\m -> m{mGuardOpen = False, mPendingRoute = Nothing})
    DirtyGuardDiscard -> do
        m <- get
        putModel (\x -> x{mGuardOpen = False, mPendingRoute = Nothing, mDirty = False})
        case mPendingRoute m of
            Nothing -> pure ()
            Just route -> withSink $ \_ -> pushRoute route
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
    GraphLoaded graph -> putModel (\m -> m{mGraph = Just graph, mGraphLoading = False})
    GraphFailed err -> do
        putModel (\m -> m{mGraphLoading = False})
        handleApiError err
    GraphDepthSelected depth -> do
        putModel (\m -> m{mGraphDepth = max 1 (min 3 depth), mGraphLoading = True})
        m <- get
        fetchGraph (mGraphSeed m) (mGraphDepth m) GraphLoaded GraphFailed
    GraphSeed seed -> do
        putModel (\m -> m{mGraphSeed = seed, mGraphLoading = True})
        m <- get
        fetchGraph (mGraphSeed m) (mGraphDepth m) GraphLoaded GraphFailed
    GraphZoom zoomPercent -> putModel (\m -> m{mGraphZoom = max 40 (min 260 zoomPercent)})
    OpenGraphAt bookmarkId -> do
        putModel (\m -> m{mGraphSeed = Just bookmarkId, mGraphLoading = True})
        m <- get
        fetchGraph (mGraphSeed m) (mGraphDepth m) GraphLoaded GraphFailed
        updateModel (Navigate Graph)
    GraphQueryChanged query -> do
        putModel (\m -> m{mGraphQuery = query, mGraphResults = []})
        if T.null (T.strip (fromMisoString query))
            then pure ()
            else fetchAutocomplete query GraphResults (\_ -> Noop)
    GraphResults results -> putModel (\m -> m{mGraphResults = results})
    GraphPickSeed bookmarkId -> do
        putModel (\m -> m{mGraphSeed = Just bookmarkId, mGraphQuery = "", mGraphResults = [], mGraphLoading = True, mGraph = Nothing})
        m <- get
        fetchGraph (Just bookmarkId) (mGraphDepth m) GraphLoaded GraphFailed
    GraphRefresh -> do
        m <- get
        case mGraphSeed m of
            Nothing -> notify "Search for a bookmark to seed the graph first." ToastInfo
            Just _ -> do
                putModel (\x -> x{mGraphLoading = True})
                fetchGraph (mGraphSeed m) (mGraphDepth m) GraphLoaded GraphFailed
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
                                (\merged -> DedupMerged (dgKey group) merged kept)
                                DedupFailed
    DedupMerged key merged keeper -> do
        putModel
            ( \m ->
                (dropDedupGroup key m)
                    { mDedupConfirm = Nothing
                    , mDedupBusy = False
                    , mDedupLast = Just (merged, keeper)
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
                        notify "Prune is destructive (undo available). Click again to confirm." ToastInfo
                    else do
                        putModel (\x -> x{mMaintBusy = True, mConfirmPrune = False})
                        runPrune (mPruneSel m) PruneDone MaintFailed
    PruneCancel -> putModel (\m -> m{mConfirmPrune = False})
    PruneDone pruned -> do
        putModel (\m -> m{mMaintBusy = False})
        notify (ms ("Pruned " <> show pruned <> " bookmark(s). Undo is available")) ToastOk
        fetchPruneCandidates PruneLoaded PruneFailed
        refreshTags
        refreshStats
    DeadCheckRun -> do
        putModel (\m -> m{mMaintBusy = True})
        checkDead
            (\(checked, dead) -> DeadCheckDone checked dead)
            MaintFailed
    DeadCheckDone checked dead -> do
        putModel (\m -> m{mMaintBusy = False, mCheckedCount = Just checked, mDeadCount = Just dead})
        notify (ms ("Checked " <> show checked <> " links, " <> show dead <> " dead")) ToastOk
        reloadList
        refreshStats
    UndoRun -> do
        putModel (\m -> m{mMaintBusy = True})
        runUndo UndoDone MaintFailed
    UndoDone restored -> do
        putModel
            ( \m ->
                m
                    { mMaintBusy = False
                    , mDedupLast = Nothing
                    , mDedupMergeAllReport = Nothing
                    }
            )
        notify (ms ("Restored " <> show restored <> " bookmark(s)")) ToastOk
        fetchPruneCandidates PruneLoaded PruneFailed
        dedupFirstPage DedupLoaded DedupFailed
        reloadList
        refreshStats
    MaintFailed err -> do
        putModel (\m -> m{mMaintBusy = False})
        handleApiError err
    -- account --------------------------------------------------------------
    AccountLoaded info ->
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
                    }
            )
    AccountFailed err -> do
        putModel (\m -> m{mAccountLoading = False, mAccountError = Just (ms (aeMessage err))})
        handleApiError err
    RecoveryRegenerate -> regenerateRecovery RecoveryLoaded AccountFailed
    RecoveryLoaded codes -> do
        putModel (\m -> m{mRecoveryCodes = codes})
        notify "New recovery codes generated. Store them now." ToastOk
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
        if mDirty m
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
    SelectClear -> putModel (\m -> m{mSelection = IS.empty, mSelectAnchor = Nothing, mSelectingAll = False})
    SelectAllLoaded -> do
        m <- get
        putModel (\x -> x{mSelection = IS.fromList (map bsId (mItems m)), mSelectAnchor = Nothing})
    SelectAllMatchingStart -> do
        m <- get
        put
            m
                { mSelectingAll = True
                , mSelection = IS.empty
                , mSelectAnchor = Nothing
                , mSelectFetched = 0
                }
        fetchBookmarks
            ((listParams m False){lpOffset = 0, lpLimit = 200})
            (\page -> SelectPageLoaded (map bsId (spItems page)) (spHasMore page))
            SelectPageFailed
    SelectPageLoaded ids hasMore -> do
        m <- get
        let fetched = mSelectFetched m + length ids
            merged = IS.union (mSelection m) (IS.fromList ids)
            capped = if IS.size merged > 10000 then IS.fromList (take 10000 (IS.toList merged)) else merged
        put m{mSelection = capped, mSelectFetched = fetched}
        if hasMore && IS.size capped < 10000
            then
                fetchBookmarks
                    ((listParams m False){lpOffset = fetched, lpLimit = 200})
                    (\page -> SelectPageLoaded (map bsId (spItems page)) (spHasMore page))
                    SelectPageFailed
            else do
                putModel (\x -> x{mSelectingAll = False})
                if IS.size capped >= 10000
                    then notify "Selected the first 10,000 bookmarks" ToastInfo
                    else notify (ms ("Selected " <> show (IS.size capped) <> " bookmarks")) ToastOk
    SelectPageFailed err -> do
        putModel (\m -> m{mSelectingAll = False})
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
        notify "Token created. Copy it now, it is shown only once." ToastOk
    TokenCreateFailed err -> do
        putModel (\m -> m{mTokenBusy = False})
        handleApiError err
    TokenRevoke tokenId -> revokeApiToken tokenId TokenRevoked TokenCreateFailed
    TokenRevoked -> do
        notify "Token revoked" ToastOk
        fetchTokens TokensLoaded TokensFailed
    TokenRevealDismiss -> putModel (\m -> m{mTokenSecret = Nothing})
    TokenCopied raw -> withSink $ \sink -> do
        copiedValue <- jsgf "ezaCopy" (ms raw)
        copied <- fromMaybe False <$> (fromJSVal copiedValue :: IO (Maybe Bool))
        sink
            ( ToastAdd
                (if copied then "Token copied" else "Copy failed. Select the text instead")
                (if copied then ToastOk else ToastError)
            )
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
    ShareCopy url -> withSink $ \sink -> do
        copiedValue <- jsgf "ezaCopy" (ms (url :: Text))
        copied <- fromMaybe False <$> (fromJSVal copiedValue :: IO (Maybe Bool))
        sink
            ( ToastAdd
                (if copied then "Share link copied" else "Copy failed. Select the text instead")
                (if copied then ToastOk else ToastError)
            )
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
                , mEditTitle = ""
                , mEditNote = ""
                , mEditTags = []
                , mNewTag = ""
                , mDirty = False
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
            || isJust (mSavedShare m)
            || isJust (mTagPrompt m)
            || mConfirmBulkDelete m
            || isJust (mConfirmDelete m)

    closeTopLayer m
        | mConfirmLogout m = putModel (\x -> x{mConfirmLogout = False})
        | mHighlightNoteOpen m = putModel (\x -> x{mHighlightNoteOpen = False, mHighlightNote = ""})
        | isJust (mHighlightEdit m) = putModel (\x -> x{mHighlightEdit = Nothing, mHighlightEditNote = ""})
        | mShareDialogOpen m = putModel (\x -> x{mShareDialogOpen = False, mShareUrl = Nothing})
        | isJust (mSavedShare m) = putModel (\x -> x{mSavedShare = Nothing, mShareUrl = Nothing})
        | isJust (mTagDialog m) = putModel (\x -> x{mTagDialog = Nothing, mTagDialogError = Nothing})
        | isJust (mDedupConfirm m) = putModel (\x -> x{mDedupConfirm = Nothing})
        | mSnapshotOpen m = putModel (\x -> x{mSnapshotOpen = False})
        | isJust (mReaderSel m) = putModel (\x -> x{mReaderSel = Nothing})
        | mPaletteOpen m = putModel (\x -> x{mPaletteOpen = False, mPaletteQ = "", mPaletteSel = 0})
        | mAddOpen m = putModel (\x -> x{mAddOpen = False})
        | mGuardOpen m = putModel (\x -> x{mGuardOpen = False, mPendingRoute = Nothing})
        | isJust (mTagPrompt m) = putModel (\x -> x{mTagPrompt = Nothing, mTagPromptValue = ""})
        | mConfirmBulkDelete m = putModel (\x -> x{mConfirmBulkDelete = False})
        | isJust (mLinkQuery m) = putModel (\x -> x{mLinkQuery = Nothing, mLinkResults = []})
        | isJust (mDrawer m) = putModel (\x -> x{mDrawer = Nothing})
        | isJust (mConfirmDelete m) = putModel (\x -> x{mConfirmDelete = Nothing})
        | not (IS.null (mSelection m)) = putModel (\x -> x{mSelection = IS.empty, mSelectAnchor = Nothing})
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

    decodeImportReport :: Value -> Either String ImportReport
    decodeImportReport value = case fromJSON value of
        Error message -> Left message
        Success report -> Right report

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
