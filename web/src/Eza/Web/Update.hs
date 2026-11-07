{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The MVU update function: every action's state transition and side effect.
module Eza.Web.Update (updateModel, subscriptions) where

import Control.Monad (forM_, unless, void, when)
import Data.Aeson (Value, object, (.=))
import qualified Data.IntSet as IS
import Data.List (nub)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Miso
import qualified Miso.JSON as MJ

import Eza.Types (
    Backlinks (..),
    BookmarkDetail (..),
    BookmarkSummary (..),
    BootPayload (..),
    Highlight (..),
    ImportReport,
    SavedSearch (..),
    SearchPage (..),
    TagStat (..),
 )
import Eza.Web.Api
import Eza.Web.Model
import Eza.Web.Types (
    AiStatus (..),
    ApiError (..),
    ConsolGroup (..),
    DedupGroup (..),
    ReaderSelection (..),
    Rule (..),
    ShareView (..),
    TagSuggestion (..),
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
    , -- Global keydown lives on window (not the VDOM root) so shortcuts work even
      -- when focus is on <body> or outside the mounted tree.
      windowSub "keydown" keyInfoDecoder GlobalKey
    , -- Connectivity drives the offline banner.
      windowSub "online" emptyDecoder (\() -> ConnectivityChanged True)
    , windowSub "offline" emptyDecoder (\() -> ConnectivityChanged False)
    ]

-- ---------------------------------------------------------------- helpers --

putModel :: (Model -> Model) -> Effect () () Model Action
putModel f = get >>= put . f

liftSinkIO :: IO () -> Effect () () Model Action
liftSinkIO io = withSink $ \_ -> io

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
            notify "Session expired — sign in again to continue." ToastError
        Just 404 -> do
            putModel (\m -> m{mNotice = Just message})
            notify message ToastInfo
        _ -> notify message ToastError

redirectTo :: MisoString -> IO ()
redirectTo url = do
    location <- jsg "window" ! "location"
    _ <- location # "assign" $ (url :: MisoString)
    pure ()

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

listParams :: Model -> Bool -> ListParams
listParams m append =
    defaultListParams
        { lpQ = mQ m
        , lpTags = mTagsFilter m
        , lpSort = mSort m
        , lpUnreadOnly = mRoute m == Inbox || mUnreadOnly m
        , lpOffset = if append then length (mItems m) else 0
        }

reloadList :: Effect () () Model Action
reloadList = do
    m <- get
    put m{mLoading = True, mLoadingMore = False, mError = Nothing}
    fetchBookmarks (listParams m False) (ListLoaded False) (ListFailed False)

loadMore :: Effect () () Model Action
loadMore = do
    m <- get
    unless (mLoading m || mLoadingMore m || not (mHasMore m)) $ do
        put m{mLoadingMore = True}
        fetchBookmarks (listParams m True) (ListLoaded True) (ListFailed True)

refreshTags :: Effect () () Model Action
refreshTags = fetchTags TagsRefreshed (\_ -> Noop)

loadRoute :: Route -> Effect () () Model Action
loadRoute route = do
    m <- get
    put
        m
            { mRoute = route
            , mLoading = isListRoute route
            , mLoadingMore = False
            , mError = Nothing
            , mNotice = Nothing
            , mDetail = if isDetailRoute route then mDetail m else Nothing
            , mDetailLoading = isDetailRoute route
            , mDirty = if isDetailRoute route then mDirty m else False
            , mGraphLoading = route == Graph
            , mDedupLoading = route == Dedup
            , mConsolLoading = route == Tags
            , mAccountLoading = route == Account
            , mAiTag = if route == AiTags then mAiTag m else Nothing
            , mSuggestions = if route == AiTags then mSuggestions m else []
            , mSelection = IS.empty
            , mSelectAnchor = Nothing
            , mSelectingAll = False
            , mBulkBusy = False
            , mTagPrompt = Nothing
            , mTagPromptValue = ""
            , mConfirmBulkDelete = False
            , mHighlights = if isDetailRoute route then mHighlights m else []
            , mHighlightsLoading = isDetailRoute route
            , mReaderSel = Nothing
            , mHighlightNoteOpen = False
            , mHighlightEdit = Nothing
            , mShareDialogOpen = False
            , mShareUrl = Nothing
            , mSnapshotOpen = False
            }
    case route of
        Index -> reloadList
        Inbox -> reloadList
        Bookmark bid -> do
            fetchDetail bid DetailLoaded DetailFailed
            fetchBacklinks bid BacklinksLoaded BacklinksFailed
            fetchHighlights bid HighlightsLoaded HighlightsFailed
            fetchShares SharesLoaded SharesFailed
        Graph -> do
            current <- get
            case mGraphSeed current of
                Nothing -> putModel (\x -> x{mGraph = Nothing, mGraphLoading = False})
                Just seed -> fetchGraph (Just seed) (mGraphDepth current) GraphLoaded GraphFailed
        Dedup -> fetchDedup DedupLoaded DedupFailed
        Tags -> do
            fetchConsolidation ConsolLoaded ConsolFailed
            refreshTags
        AiTags -> do
            refreshTags
            fetchAiStatus AiStatusLoaded (\_ -> Noop)
        Maintenance -> fetchPruneCandidates PruneLoaded PruneFailed
        Account -> do
            fetchAccount AccountLoaded AccountFailed
            putModel (\x -> x{mTokensLoading = True, mSharesLoading = True, mRulesLoading = True})
            fetchTokens TokensLoaded TokensFailed
            fetchShares SharesLoaded SharesFailed
            fetchRules RulesLoaded RulesFailed
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

measureGrid :: IO (Maybe (Int, Int, Int))
measureGrid = do
    document <- jsg "document"
    win <- jsg "window"
    scrollY <- asDouble =<< (getProperty win "scrollY")
    innerHeight <- windowInnerHeight
    element <- getElementById "card-grid"
    isNothingElement <- isNull element
    if isNothingElement
        then pure Nothing
        else do
            rect <- element # "getBoundingClientRect" $ ([] :: [JSVal])
            top <- asDouble =<< getProperty rect "top"
            pure (Just (round scrollY, innerHeight, round (top + scrollY)))
  where
    asDouble value = fromMaybe 0 <$> (fromJSVal value :: IO (Maybe Double))

isEditableFocused :: IO Bool
isEditableFocused = do
    document <- jsg "document"
    active <- document ! "activeElement"
    tagM <- fromJSVal =<< getProperty active "tagName"
    pure $ case (tagM :: Maybe MisoString) of
        Nothing -> False
        Just tag -> fromMisoString tag `elem` (["INPUT", "TEXTAREA", "SELECT"] :: [String])

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
firstUrlIn (Just text) =
    fromMaybe "" $
        case filter (\word -> "http://" `T.isPrefixOf` word || "https://" `T.isPrefixOf` word) (T.words text) of
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
            -- PWA share_target landing page.  A share normally carries a URL, so
            -- capture it through the idempotent quick-save endpoint; when there is
            -- no URL, fall back to the pre-filled Add modal.
            Right (Save title text url) -> do
                let sharedUrl = maybe (firstUrlIn text) (ms . T.strip) url
                    sharedTitle = ms (fromMaybe "" title)
                putModel (\x -> x{mRoute = Index, mAddOpen = False})
                withSink $ \_ -> pushRoute Index
                if T.null (T.strip (fromMisoString sharedUrl))
                    then
                        putModel
                            ( \x ->
                                x
                                    { mAddOpen = True
                                    , mAddUrl = ""
                                    , mAddTitle = sharedTitle
                                    , mAddTags = ""
                                    , mAddError = Nothing
                                    }
                            )
                    else quickSave sharedUrl sharedTitle QuickSaved QuickSaveFailed
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
    QuickSaveFailed err -> handleApiError err
    CopyBookmarklet bookmarklet
        | T.null (T.strip (fromMisoString bookmarklet)) ->
            notify "Bookmarklet is unavailable until the app knows its origin." ToastInfo
        | otherwise -> withSink $ \sink -> do
            copiedValue <- jsgf "ezaCopy" (bookmarklet :: MisoString)
            copied <- fromMaybe False <$> (fromJSVal copiedValue :: IO (Maybe Bool))
            sink
                ( ToastAdd
                    (if copied then "Bookmarklet copied" else "Copy failed — drag the link instead")
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
        let (_, lastRow) = visibleRows m
        when (mHasMore m && not (mLoading m) && not (mLoadingMore m) && lastRow + 5 >= gridRows m) $
            loadMore
    GlobalKey info -> withSink $ \sink -> do
        editable <- isEditableFocused
        sink (KeyHandled info editable)
    KeyHandled info editable -> do
        m <- get
        let code = case keyCode info of KeyCode n -> n
            withModifier = ctrlKey info || metaKey info
            go action = updateModel action
        case code of
            27 -> closeTopLayer m
            83 | withModifier && isDetailRoute (mRoute m) -> go SaveBookmark
            75 | not editable && not withModifier -> go PaletteOpen
            191 | not editable -> do
                go PaletteClose
                liftSinkIO (focus "search-input")
            13 | mPaletteOpen m -> go PaletteSelect
            38 | mPaletteOpen m -> go PalettePrev
            40 | mPaletteOpen m -> go PaletteNext
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
                    , mSaved = bpSavedSearches payload
                    }
            )
    BootFailed err -> do
        handleApiError err
        when (aeStatus err == Just 401) $ liftSinkIO (redirectTo "/login")
    ApiUnauthorized -> putModel (\m -> m{mSignedOut = True})
    ApiErrorRaised err -> handleApiError err
    TagsRefreshed stats -> putModel (\m -> m{mTags = stats})
    -- library ---------------------------------------------------------------
    SearchInput query -> do
        putModel (\m -> m{mQ = query})
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
    ListLoaded append page -> do
        m <- get
        let fresh =
                if append
                    then mItems m ++ spItems page
                    else spItems page
        put
            m
                { mItems = fresh
                , mTotal = spTotal page
                , mHasMore = spHasMore page
                , mLoading = False
                , mLoadingMore = False
                , mOffset = spOffset page + length (spItems page)
                , mError = Nothing
                }
    ListFailed _ err -> do
        putModel (\m -> m{mLoading = False, mLoadingMore = False})
        handleApiError err
    LoadMore -> loadMore
    MarkAllAbove -> do
        m <- get
        let above = case mItems m of
                (firstItem : _) -> Just (bsId firstItem)
                [] -> Nothing
        markAllAbove above (\updated -> ToastAdd (ms ("Marked " <> show updated <> " as read")) ToastOk) (\err -> ToastAdd ("Could not mark as read: " <> ms (aeMessage err)) ToastError)
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
        liftSinkIO (focus "add-url")
    AddClose -> putModel (\m -> m{mAddOpen = False, mAddError = Nothing})
    AddUrlInput url -> putModel (\m -> m{mAddUrl = url})
    AddTitleInput title -> putModel (\m -> m{mAddTitle = title})
    AddTagsInput tags -> putModel (\m -> m{mAddTags = tags})
    AddSubmit -> do
        m <- get
        if not (isHttpUrlText (mAddUrl m))
            then putModel (\x -> x{mAddError = Just "Enter a valid http(s) URL."})
            else do
                putModel (\x -> x{mAddBusy = True, mAddError = Nothing})
                createBookmark (mAddUrl m) (mAddTitle m) (splitTags (mAddTags m)) AddSucceeded AddFailed
    AddSucceeded bookmarkId -> do
        putModel (\m -> m{mAddOpen = False, mAddBusy = False, mAddUrl = "", mAddTitle = "", mAddTags = "", mAddError = Nothing})
        notify (ms ("Saved bookmark #" <> show bookmarkId)) ToastOk
        reloadList
        refreshTags
    AddFailed err -> do
        putModel (\m -> m{mAddBusy = False, mAddError = Just (ms (aeMessage err))})
        handleApiError err
    -- command palette -------------------------------------------------------
    PaletteOpen -> do
        putModel (\m -> m{mPaletteOpen = True, mPaletteQ = "", mPaletteSel = 0})
        liftSinkIO (focus "palette-input")
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
    PaletteSelect -> do
        m <- get
        let entries = paletteEntries m
            selection = max 0 (mPaletteSel m)
        case drop selection entries of
            ((_, _, nextAction) : _) -> do
                putModel (\x -> x{mPaletteOpen = False, mPaletteQ = "", mPaletteSel = 0})
                updateModel nextAction
            [] -> pure ()
    -- detail ----------------------------------------------------------------
    DetailLoaded detail -> do
        putModel
            ( \m ->
                m
                    { mDetail = Just detail
                    , mDetailLoading = False
                    , mEditTitle = ms (bdTitle detail)
                    , mEditNote = ms (bdNoteBody detail)
                    , mEditTags = bdTags detail
                    , mDirty = False
                    , mNoteMode = NoteWrite
                    , mLinkQuery = Nothing
                    , mLinkResults = []
                    }
            )
    DetailFailed err -> do
        putModel (\m -> m{mDetailLoading = False})
        handleApiError err
    TitleInput title -> putModel (\m -> m{mEditTitle = title, mDirty = True})
    NoteChanged text domRef -> do
        putModel (\m -> m{mEditNote = text, mDirty = True})
        withSink $ \sink -> do
            selection <- fromMaybe 0 <$> (fromJSVal =<< getProperty domRef "selectionStart")
            let cursor = round (selection :: Double)
                query = wikilinkQueryAt (fromMisoString text) cursor
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
        case mDetail m of
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
    SaveFailed err -> do
        putModel (\m -> m{mSaving = False})
        handleApiError err
    ReadToggled -> do
        m <- get
        case mDetail m of
            Nothing -> pure ()
            Just detail -> do
                let nextRead = not (bdIsRead detail)
                putModel (\x -> x{mDetail = Just detail{bdIsRead = nextRead}})
                patchBookmark (bdId detail) (object ["is_read" .= nextRead]) SavedOk SaveFailed
    OpenToggled -> pure ()
    BacklinksLoaded links -> putModel (\m -> m{mBacklinks = links})
    BacklinksFailed _ -> pure ()
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
    DeleteBookmark bookmarkId -> deleteBookmark bookmarkId (DeletedOk bookmarkId) DeleteFailed
    DeletedOk bookmarkId -> do
        m <- get
        notify "Bookmark deleted" ToastOk
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
        putModel (\m -> m{mImporting = False})
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
    ImportFailed err -> do
        putModel (\m -> m{mImporting = False})
        handleApiError err
    -- saved searches --------------------------------------------------------
    SavedSearchSave -> do
        m <- get
        let name = if T.null (T.strip (fromMisoString (mSavedName m))) then mQ m else mSavedName m
        saveSavedSearch name (mQ m) (mTagsFilter m) (\_ -> SavedSearchDone) SavedSearchFailed
    SavedSearchNameInput name -> putModel (\m -> m{mSavedName = name})
    SavedSearchDelete savedSearchId -> deleteSavedSearch savedSearchId SavedSearchDone SavedSearchFailed
    SavedSearchDone -> do
        notify "Saved searches updated" ToastOk
        putModel (\m -> m{mSavedName = ""})
        fetchSavedSearches SavedSearchesLoaded (\_ -> Noop)
    SavedSearchFailed err -> handleApiError err
    SavedSearchesLoaded saved -> putModel (\m -> m{mSaved = saved})
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
    DedupLoaded groups -> putModel (\m -> m{mDedup = groups, mDedupLoading = False, mDedupChoice = initialChoices groups})
    DedupFailed err -> do
        putModel (\m -> m{mDedupLoading = False})
        handleApiError err
    DedupKeep groupIndex bookmarkId -> putModel (\m -> m{mDedupChoice = M.insert groupIndex bookmarkId (mDedupChoice m)})
    DedupMerge groupIndex -> do
        m <- get
        case drop groupIndex (mDedup m) of
            (group : _) -> case dgItems group of
                [] -> pure ()
                (firstItem : rest) -> do
                    let keep = fromMaybe (bsId firstItem) (M.lookup groupIndex (mDedupChoice m))
                        mergeIds = [bsId item | item <- rest, bsId item /= keep]
                    if null mergeIds
                        then notify "Nothing to merge in this group" ToastInfo
                        else mergeDedup keep mergeIds (\merged -> DedupMerged merged) DedupFailed
            [] -> pure ()
    DedupMerged merged -> do
        notify (ms ("Merged " <> show merged <> " duplicate(s)")) ToastOk
        fetchDedup DedupLoaded DedupFailed
    -- tags -----------------------------------------------------------------
    TagStatsLoaded stats -> putModel (\m -> m{mTags = stats})
    ConsolLoaded groups -> putModel (\m -> m{mConsol = groups, mConsolLoading = False})
    ConsolFailed err -> do
        putModel (\m -> m{mConsolLoading = False})
        handleApiError err
    TagMerge from into -> mergeTags from into TagMerged TagOpFailed
    TagRenamed old newName -> renameTag old (fromMisoString newName) TagMerged TagOpFailed
    TagDeleted tag -> deleteTag tag TagMerged TagOpFailed
    FilterByTag tag -> do
        putModel (\m -> m{mTagsFilter = [tag]})
        updateModel (Navigate Index)
    TagMerged -> do
        notify "Tag vocabulary updated" ToastOk
        fetchConsolidation ConsolLoaded ConsolFailed
        refreshTags
        reloadList
    TagOpFailed err -> handleApiError err
    -- ai tags ---------------------------------------------------------------
    AiTagSelected tag -> do
        putModel (\m -> m{mAiTag = tag, mSuggestions = [], mSuggestionsLoading = isJust tag})
        case tag of
            Nothing -> pure ()
            Just selected -> fetchSuggestions selected SuggestionsLoaded SuggestionsFailed
    SuggestionsLoaded suggestions -> putModel (\m -> m{mSuggestions = suggestions, mSuggestionsLoading = False})
    SuggestionsFailed err -> do
        putModel (\m -> m{mSuggestionsLoading = False})
        handleApiError err
    SuggestionApply bookmarkId tags -> applyTagSuggestion bookmarkId tags SuggestionsApplied SuggestionsFailed
    SuggestionsApplied -> do
        notify "Tags applied" ToastOk
        m <- get
        case mAiTag m of
            Nothing -> pure ()
            Just tag -> fetchSuggestions tag SuggestionsLoaded SuggestionsFailed
    -- maintenance ----------------------------------------------------------
    PruneLoaded items -> putModel (\m -> m{mPrune = items, mPruneSel = [], mConfirmPrune = False})
    PruneFailed err -> handleApiError err
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
        notify (ms ("Pruned " <> show pruned <> " bookmark(s) — undo available")) ToastOk
        fetchPruneCandidates PruneLoaded PruneFailed
        refreshTags
    DeadCheckRun -> do
        putModel (\m -> m{mMaintBusy = True})
        checkDead
            (\(checked, dead) -> DeadCheckDone checked dead)
            MaintFailed
    DeadCheckDone checked dead -> do
        putModel (\m -> m{mMaintBusy = False, mCheckedCount = Just checked, mDeadCount = Just dead})
        notify (ms ("Checked " <> show checked <> " links, " <> show dead <> " dead")) ToastOk
        reloadList
    UndoRun -> do
        putModel (\m -> m{mMaintBusy = True})
        runUndo UndoDone MaintFailed
    UndoDone restored -> do
        putModel (\m -> m{mMaintBusy = False})
        notify (ms ("Restored " <> show restored <> " bookmark(s)")) ToastOk
        fetchPruneCandidates PruneLoaded PruneFailed
        reloadList
    MaintFailed err -> do
        putModel (\m -> m{mMaintBusy = False})
        handleApiError err
    -- account --------------------------------------------------------------
    AccountLoaded info -> putModel (\m -> m{mAccount = Just info, mAccountLoading = False})
    AccountFailed err -> do
        putModel (\m -> m{mAccountLoading = False})
        handleApiError err
    RecoveryRegenerate -> regenerateRecovery RecoveryLoaded AccountFailed
    RecoveryLoaded codes -> do
        putModel (\m -> m{mRecoveryCodes = codes})
        notify "New recovery codes generated — store them now" ToastOk
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
    AccountReload -> fetchAccount AccountLoaded AccountFailed
    Logout -> logout LoggedOut (\err -> ApiErrorRaised err)
    LoggedOut -> liftSinkIO (redirectTo "/login")
    -- selection / bulk -----------------------------------------------------
    SelectToggled bookmarkId shift -> do
        m <- get
        let current = mSelection m
            ids = map bsId (mItems m)
            indexOf target = case [i | (i, item) <- zip [0 ..] (mItems m), bsId item == target] of
                (i : _) -> Just i
                [] -> Nothing
        case (shift, mSelectAnchor m >>= \anchor -> (,) anchor <$> indexOf anchor) of
            (True, Just (anchor, anchorIndex)) ->
                case indexOf bookmarkId of
                    Just currentIndex -> do
                        let (from, to) = (min anchorIndex currentIndex, max anchorIndex currentIndex)
                            rangeIds = [bsId item | (i, item) <- zip [0 ..] (mItems m), i >= from, i <= to]
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
    BulkTagPromptOpen adding -> putModel (\m -> m{mTagPrompt = Just adding, mTagPromptValue = ""})
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
        bookmarkAction bookmarkId "enrich" (DetailReload bookmarkId) DetailFailed
    DetailReload bookmarkId -> fetchDetail bookmarkId DetailLoaded DetailFailed
    -- api tokens -----------------------------------------------------------
    TokensLoaded tokens -> putModel (\m -> m{mTokens = tokens, mTokensLoading = False})
    TokensFailed err -> do
        putModel (\m -> m{mTokensLoading = False})
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
        notify "Token created — copy it now, it is shown only once" ToastOk
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
                (if copied then "Token copied" else "Copy failed — select the text instead")
                (if copied then ToastOk else ToastError)
            )
    -- highlights -----------------------------------------------------------
    HighlightsLoaded highlights -> putModel (\m -> m{mHighlights = highlights, mHighlightsLoading = False})
    HighlightsFailed err -> do
        putModel (\m -> m{mHighlightsLoading = False})
        handleApiError err
    ReaderMouseUp -> withSink $ \sink -> do
        raw <- jsgf "ezaSelectionOffsets" ("reader-text" :: MisoString)
        text <- fromJSVal raw
        let selection = case (text :: Maybe MisoString) of
                Nothing -> Nothing
                Just json -> case MJ.eitherDecode json of
                    Right parsed -> Just (parsed :: ReaderSelection)
                    Left _ -> Nothing
        sink (ReaderSelectionFound selection)
    ReaderSelectionFound selection -> putModel (\m -> m{mReaderSel = selection})
    ReaderSelectionClear -> putModel (\m -> m{mReaderSel = Nothing})
    HighlightCreateQuick -> do
        m <- get
        case (mDetail m, mReaderSel m) of
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
        case (mDetail m, mReaderSel m) of
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
        case (mDetail m, mHighlightEdit m) of
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
        case mDetail m of
            Just detail -> deleteHighlight (bdId detail) highlightId HighlightDeleted HighlightFailed
            Nothing -> pure ()
    HighlightPatched -> do
        notify "Highlight updated" ToastOk
        reloadHighlights
    HighlightDeleted -> do
        notify "Highlight deleted" ToastOk
        reloadHighlights
    HighlightFailed err -> handleApiError err
    -- sharing --------------------------------------------------------------
    SharesLoaded shares -> putModel (\m -> m{mShares = shares, mSharesLoading = False})
    SharesFailed err -> do
        putModel (\m -> m{mSharesLoading = False})
        handleApiError err
    ShareDialogOpen -> do
        m <- get
        case mDetail m of
            Just detail -> do
                putModel
                    ( \x ->
                        x
                            { mShareDialogOpen = True
                            , mShareIncludeNote = False
                            , mShareExpiryDays = 30
                            , mShareUrl = Nothing
                            , mShareBusy = False
                            }
                    )
                fetchShares SharesLoaded SharesFailed
            Nothing -> pure ()
    ShareDialogClose -> putModel (\m -> m{mShareDialogOpen = False, mShareUrl = Nothing})
    ShareIncludeNoteToggle -> putModel (\m -> m{mShareIncludeNote = not (mShareIncludeNote m)})
    ShareExpirySelected days -> putModel (\m -> m{mShareExpiryDays = days})
    ShareCreate -> do
        m <- get
        case mDetail m of
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
        fetchShares SharesLoaded SharesFailed
    ShareCreateFailed err -> do
        putModel (\m -> m{mShareBusy = False})
        handleApiError err
    ShareCopy url -> withSink $ \sink -> do
        copiedValue <- jsgf "ezaCopy" (ms (url :: Text))
        copied <- fromMaybe False <$> (fromJSVal copiedValue :: IO (Maybe Bool))
        sink
            ( ToastAdd
                (if copied then "Share link copied" else "Copy failed — select the text instead")
                (if copied then ToastOk else ToastError)
            )
    ShareRevoke shareId -> revokeShareLink shareId ShareRevoked ShareCreateFailed
    ShareRevoked -> do
        notify "Share link revoked" ToastOk
        fetchShares SharesLoaded SharesFailed
    -- snapshot -------------------------------------------------------------
    SnapshotOpen -> putModel (\m -> m{mSnapshotOpen = True})
    SnapshotClose -> putModel (\m -> m{mSnapshotOpen = False})
    -- ai status ------------------------------------------------------------
    AiStatusLoaded status -> putModel (\m -> m{mAiStatus = Just status})
    AiStatusFailed _ -> pure ()
    -- rules ----------------------------------------------------------------
    RulesLoaded rules -> putModel (\m -> m{mRules = rules, mRulesLoading = False})
    RulesFailed err -> do
        putModel (\m -> m{mRulesLoading = False})
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
        case mDetail m of
            Just detail -> fetchHighlights (bdId detail) HighlightsLoaded HighlightsFailed
            Nothing -> pure ()
    closeTopLayer m
        | mHighlightNoteOpen m = putModel (\x -> x{mHighlightNoteOpen = False, mHighlightNote = ""})
        | isJust (mHighlightEdit m) = putModel (\x -> x{mHighlightEdit = Nothing, mHighlightEditNote = ""})
        | mShareDialogOpen m = putModel (\x -> x{mShareDialogOpen = False, mShareUrl = Nothing})
        | mSnapshotOpen m = putModel (\x -> x{mSnapshotOpen = False})
        | isJust (mReaderSel m) = putModel (\x -> x{mReaderSel = Nothing})
        | mPaletteOpen m = putModel (\x -> x{mPaletteOpen = False, mPaletteQ = "", mPaletteSel = 0})
        | mAddOpen m = putModel (\x -> x{mAddOpen = False})
        | mGuardOpen m = putModel (\x -> x{mGuardOpen = False, mPendingRoute = Nothing})
        | isJust (mTagPrompt m) = putModel (\x -> x{mTagPrompt = Nothing, mTagPromptValue = ""})
        | mConfirmBulkDelete m = putModel (\x -> x{mConfirmBulkDelete = False})
        | isJust (mLinkQuery m) = putModel (\x -> x{mLinkQuery = Nothing, mLinkResults = []})
        | not (IS.null (mSelection m)) = putModel (\x -> x{mSelection = IS.empty, mSelectAnchor = Nothing})
        | otherwise = pure ()

    initialChoices groups =
        M.fromList
            [ (index, bsId firstItem)
            | (index, group) <- zip [0 ..] groups
            , (firstItem : _) <- [dgItems group]
            ]
