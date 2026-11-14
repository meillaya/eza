{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The single place where the client executes something outside the pure
update function: JSON requests, browser history, DOM focus and geometry,
timers, the clipboard, the theme and the event subscriptions.

The update modules in "Eza.Web.Update" are declarative: they read and write the
'Model' and describe side effects as `Effect` values, calling the wrappers in
this module. Nothing else under @src/Eza/Web@ calls a JSFFI function or
@withSink@ directly. (The transport in "Eza.Web.Api" is the one exception: it
is the HTTP implementation these wrappers hand requests to.)

The module also keeps the ledger bridge from M2-B1: 'extractLedger' and
'embedLedger' project the shell model to and from the native
'Eza.Web.Logic.Ledger.LedgerState', and 'runLedgerAction' interprets the
`Eza.Web.Logic.Effect.Effect` values a native reducer returns:

- @Fetch@ becomes the matching "Eza.Web.Api" reader, and its answer is fed back
  as a shell 'Action' carrying the request id.
- @Schedule@ / @CancelTimer@ become @setTimeout@ / @clearTimeout@. The timeout
  callback dispatches 'TimerFired' with the native 'TimerId'; the reducer drops
  the id when it is no longer current.
- @Navigate@ is dispatched as the shell's own 'Navigate' action so the
  unsaved-edit guard keeps working. @ReplaceUrl@, @SetDocumentTitle@ and
  @Focus@ perform their browser operation directly.

M2-B2 phase 2 moves the Model type into @eza-web-logic@; the browser-side
wrappers here stay in the shell because they are the only WASM/FFI boundary.
-}
module Eza.Web.Interpreter (
    -- * Native ledger bridge
    extractLedger,
    embedLedger,
    runLedgerAction,

    -- * Shared update helpers
    notify,
    handleApiError,
    redirect,
    documentTitle,
    setDocumentTitle,

    -- * Lifecycle and viewport
    bootstrapEnvironment,
    toggleTheme,
    refreshLayout,
    measureLedgerScroll,
    focusElement,
    focusElementDelayed,
    readNoteCursor,
    setNoteCursor,
    readReaderSelection,
    triggerFileInput,
    copyText,

    -- * History and ledger navigation
    navigateTo,
    replaceRoute,
    replaceBrowserRoute,
    selectAccountTab,
    scrollLedger,
    scrollRowIntoView,

    -- * Graph browser work
    measureGraphCanvas,
    focusGraphCanvas,
    scheduleGraphSettle,
    scheduleGraphDetailStep,
    graphFilterSettle,

    -- * Subscriptions
    subscriptions,
) where

import Control.Monad (unless, void, when)
import Data.Aeson (Value (Null))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Miso
import qualified Miso.JSON as MJ
import Miso.Router (toURI)

import Eza.Web.Api (fetchBookmarksQuery, fetchStats)

-- the orphan Router Route instance for history FFI
import Eza.Web.Error (ApiError (..))
import Eza.Web.Logic.Api (ClientRequest (..))
import Eza.Web.Logic.Effect (RequestId (..), TimerId)
import qualified Eza.Web.Logic.Effect as Logic (
    Effect (..),
 )
import Eza.Web.Logic.Ledger (
    LedgerAction,
    LedgerState (..),
    defaultLedgerLimit,
    initialLedgerState,
    updateLedger,
 )
import Eza.Web.Logic.Model
import Eza.Web.Logic.Route (Route (..), routeTitle)
import qualified Eza.Web.Logic.Route as ClientRoute
import Eza.Web.Model ()

-- ----------------------------------------------------------- subscriptions ---

{- | Component subscriptions: URL changes (back/forward), window scroll for
the virtualized grid, and window resize for the column count.
-}
subscriptions :: [Sub Model Action]
subscriptions =
    [ uriSub (\uri -> RouteChanged (fromMisoString (uriFragment uri)) (routeOfUriUri uri))
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

-- --------------------------------------------------------------- ledger ---

{- | Read the ledger-owned subset of the shell model. Fields the shell still
mutates directly (boot seeding, the route loader) are read here each time, so
the projection never goes stale.
-}
extractLedger :: Model -> LedgerState
extractLedger model =
    initialLedgerState
        { ldQuery = mQ model
        , ldTagFilters = mTagsFilter model
        , ldSort = mSort model
        , ldUnreadOnly = mUnreadOnly model
        , ldRouteUnread = mRoute model == Inbox
        , ldLimit = defaultLedgerLimit
        , ldOffset = mOffset model
        , ldItems = mItems model
        , ldTotal = mTotal model
        , ldYearCounts = mYearHere model
        , ldHasMore = mHasMore model
        , ldLoading = mLoading model
        , ldLoadingMore = mLoadingMore model
        , ldError = mError model
        , ldListRequest = mListEpoch model
        , ldDebounceTimer = mDebounceTimer model
        , ldTimerSeq = mTimerSeq model
        , ldStats = mStats model
        , ldStatsError = mStatsError model
        , ldStatsRequest = mStatsEpoch model
        }

-- | Write the ledger-owned fields back into the shell model.
embedLedger :: LedgerState -> Model -> Model
embedLedger ledger model =
    model
        { mQ = ldQuery ledger
        , mTagsFilter = ldTagFilters ledger
        , mSort = ldSort ledger
        , mUnreadOnly = ldUnreadOnly ledger
        , mOffset = ldOffset ledger
        , mItems = ldItems ledger
        , mTotal = ldTotal ledger
        , mYearHere = ldYearCounts ledger
        , mHasMore = ldHasMore ledger
        , mLoading = ldLoading ledger
        , mLoadingMore = ldLoadingMore ledger
        , mError = ldError ledger
        , mListEpoch = ldListRequest ledger
        , mDebounceTimer = ldDebounceTimer ledger
        , mTimerSeq = ldTimerSeq ledger
        , mStats = ldStats ledger
        , mStatsError = ldStatsError ledger
        , mStatsEpoch = ldStatsRequest ledger
        }

{- | Run one ledger action: project, reduce, write back, interpret. The shell
actions that wrap a ledger event also do their own selection/scroll bookkeeping
around this call; the interpreter itself touches only ledger-owned fields.
-}
runLedgerAction :: LedgerAction -> Effect () () Model Action
runLedgerAction action = do
    model <- get
    let (ledger, effects) = updateLedger (extractLedger model) action
    put (embedLedger ledger model)
    mapM_ interpretEffect effects

-- | Interpret one effect in the browser.
interpretEffect :: Logic.Effect -> Effect () () Model Action
interpretEffect = \case
    Logic.Fetch request requestId -> fetchRequest request requestId
    Logic.Schedule delayMs timerId -> scheduleTimer delayMs timerId
    -- The browser handle is tracked under the model's debounce field; the
    -- timer id itself is checked by the reducer when the callback arrives.
    Logic.CancelTimer _ -> cancelTimer
    Logic.Navigate route -> withSink $ \sink -> sink (Navigate route)
    Logic.ReplaceUrl route -> replaceRoute route
    Logic.SetDocumentTitle title -> setDocumentTitle title
    Logic.Focus domId -> focusElement domId

{- | Start the reader for a fetched request and route its answer back. A fetch
for the list is an append when the reducer has an append in flight; that is
the flag the shell action needs to append instead of replace.
-}
fetchRequest :: ClientRequest -> RequestId -> Effect () () Model Action
fetchRequest request requestId = case request of
    ApiBookmarks query -> do
        model <- get
        let append = mLoadingMore model
        fetchBookmarksQuery
            query
            (ListLoaded append requestId)
            (ListFailed append requestId)
    ApiStats -> fetchStats (StatsLoaded requestId) (StatsFailed requestId)
    -- The ledger slice issues no other read; a later slice extends the table.
    _ -> pure ()

{- | Schedule one native timer. The callback carries the native id, so the
reducer decides whether the fire is still current.
-}
scheduleTimer :: Int -> TimerId -> Effect () () Model Action
scheduleTimer delayMs timerId =
    withSink $ \sink -> do
        timer <- fromJSValUnchecked =<< jsgf "setTimeout" (asyncCallback1 (\_ -> sink (TimerFired timerId)), delayMs :: Int)
        sink (TimerRegistered (timer :: Int))

{- | Clear the pending browser timeout. The reducer has already dropped the
native id; a browser that fires anyway delivers a stale id that is ignored.
-}
cancelTimer :: Effect () () Model Action
cancelTimer = do
    model <- get
    case mDebounce model of
        Nothing -> pure ()
        Just handle -> do
            put model{mDebounce = Nothing}
            withSink $ \_ -> void $ jsgf "clearTimeout" (handle :: Int)

-- --------------------------------------------------------------- helpers ---

putModel :: (Model -> Model) -> Effect () () Model Action
putModel f = get >>= put . f

{- | Show a toast. The dismissal timer lives here because it is a browser
timer; the update modules only say what to show.
-}
notify :: Text -> ToastKind -> Effect () () Model Action
notify message kind = do
    m <- get
    let tid = mToastNext m
        toast = Toast tid message kind
        keep = drop (max 0 (length (mToasts m) - 3)) (mToasts m ++ [toast])
    put m{mToasts = keep, mToastNext = tid + 1}
    withSink $ \sink -> do
        _ <- jsgf "setTimeout" (asyncCallback1 (\_ -> sink (ToastDismiss tid)), 4800 :: Int)
        pure ()

{- | The one error-to-interface policy: an expired session blocks the page and
sends the reader to sign in; a planned-but-missing endpoint is an inline
notice; anything else is a toast.
-}
handleApiError :: ApiError -> Effect () () Model Action
handleApiError err = do
    let message = aeMessage err
    case aeStatus err of
        Just 401 -> do
            putModel (\m -> m{mSignedOut = True})
            notify "Session expired. Sign in again." ToastError
        Just 404 -> do
            putModel (\m -> m{mNotice = Just message})
            notify message ToastInfo
        _ -> notify message ToastError

{- | Send the whole page to another URL (sign-in, a download). Components using
this never come back, which is why the update action that triggers it is
usually the last step.
-}
redirect :: Text -> Effect () () Model Action
redirect url = withSink $ \_ -> do
    location <- jsg "window" ! "location"
    _ <- location # "assign" $ (ms url :: MisoString)
    pure ()

-- | The browser tab title for a route.
documentTitle :: Route -> Text
documentTitle route = case route of
    Index -> "eza"
    _ -> routeTitle route <> " · eza"

-- | Set the browser tab title.
setDocumentTitle :: Text -> Effect () () Model Action
setDocumentTitle title = withSink $ \_ -> do
    document <- jsg ("document" :: MisoString)
    setField document ("title" :: MisoString) (ms title)

-- ----------------------------------------------------- lifecycle/viewport ---

-- | Classify the current URL; the native parser takes the path text.
routeOfUriUri :: URI -> Route
routeOfUriUri uri = ClientRoute.routeOfUri (fromMisoString (prettyURI uri))

{- | Read the browser environment once at mount: URI (for the first route),
viewport, theme, connectivity and origin. Every probe answers with an action
so the update function stays pure. The order matters: the reader sees the
route only after the theme and layout are known.
-}
bootstrapEnvironment :: Effect () () Model Action
bootstrapEnvironment = withSink $ \sink -> do
    uri <- getURI
    width <- windowInnerWidth
    height <- windowInnerHeight
    theme <- readTheme
    online <- readOnline
    origin <- readOrigin
    sink (ThemeLoaded theme)
    sink (ConnectivityChanged online)
    sink (WindowOriginKnown (fromMisoString origin))
    sink (LayoutChanged width height)
    sink (RouteChanged (fromMisoString (uriFragment uri)) (routeOfUriUri uri))

-- | Flip light/dark through the theme holder the shell bootstrapped.
toggleTheme :: Effect () () Model Action
toggleTheme = withSink $ \sink -> do
    holder <- jsg "EzaTheme"
    value <- holder # "toggle" $ ()
    themeM <- fromJSVal value
    sink (ThemeLoaded (maybe ThemeLight (themeOfText . fromMisoString) (themeM :: Maybe MisoString)))

{- | Re-read the viewport and the ledger's scroll metrics after a resize: the
column count and the virtualized window both depend on it.
-}
refreshLayout :: Effect () () Model Action
refreshLayout = withSink $ \sink -> do
    width <- windowInnerWidth
    height <- windowInnerHeight
    measured <- measureGrid
    sink (LayoutChanged width height)
    sink (ScrollMetrics measured)

-- | Re-read only the ledger scroll metrics (a scroll, or a layout pass).
measureLedgerScroll :: Effect () () Model Action
measureLedgerScroll = withSink $ \sink -> do
    measured <- measureGrid
    sink (ScrollMetrics measured)

-- | Focus one element by DOM id after the next render.
focusElement :: Text -> Effect () () Model Action
focusElement domId = withSink $ \_ -> focus (ms domId)

{- | Focus an input after the VDOM patch that creates the dialog has run.
Focusing in the same update runs before the element exists, which left focus
on the body behind the palette and the add dialog.
-}
focusElementDelayed :: Text -> Effect () () Model Action
focusElementDelayed domId = withSink $ \_ -> do
    _ <- jsgf "setTimeout" (asyncCallback (focus (ms domId)), 60 :: Int)
    pure ()

{- | Read the note editor's caret after the input event that changed the text.
Reading the DOM is the only way to know where the caret is; the reducer then
computes the wikilink completion query from the new text and offset.
-}
readNoteCursor :: Effect () () Model Action
readNoteCursor = withSink $ \sink -> do
    document <- jsg ("document" :: MisoString)
    element <- (document # ("getElementById" :: MisoString)) ("note-editor" :: MisoString)
    missing <- isNull element
    unless missing $ do
        selection <- fromMaybe 0 <$> (fromJSVal =<< getProperty element "selectionStart")
        sink (NoteCursorRead (round (selection :: Double)))

-- | Put the caret back after the update rewrote the note text.
setNoteCursor :: Int -> Effect () () Model Action
setNoteCursor cursor =
    withSink $ \_ -> setSelectionRange "note-editor" cursor cursor

{- | The reader's current text selection, as character offsets, after a mouse
up in the reading pane. The offsets come from the pwa.js bridge; a decode
failure means "no selection" rather than a broken page.
-}
readReaderSelection :: Effect () () Model Action
readReaderSelection = withSink $ \sink -> do
    raw <- jsgf "ezaSelectionOffsets" ("reader-text" :: MisoString)
    selectionJson <- fromJSVal raw
    let selection = case (selectionJson :: Maybe MisoString) of
            Nothing -> Nothing
            Just json -> case MJ.eitherDecode json of
                Right parsed -> Just (parsed :: ReaderSelection)
                Left _ -> Nothing
    sink (ReaderSelectionFound selection)

-- | Open the native file picker of the import panel.
triggerFileInput :: Text -> Effect () () Model Action
triggerFileInput domId = withSink $ \_ -> do
    element <- getElementById (ms domId)
    click () element

{- | Copy text through the promise-based bridge. The toast reports the real
result, so a one-time secret is never announced as copied when the clipboard
write was denied.
-}
copyText :: Text -> Text -> Text -> Effect () () Model Action
copyText value successMessage failureMessage = withSink $ \sink -> do
    _ <-
        jsgf
            "ezaCopy"
            ( ms value
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

-- -------------------------------------------------------------- history ---

{- | Push a route onto the history stack (and let the URI subscription deliver
it, so route loading has one entry point).
-}
navigateTo :: Route -> Effect () () Model Action
navigateTo route = withSink $ \_ -> pushRoute route

-- | Rewrite the current history entry instead of pushing a new one.
replaceRoute :: Route -> Effect () () Model Action
replaceRoute route = withSink $ \_ -> replaceURI (toURI route)

{- | Record the selected account tab in the URL fragment without a history
entry, so the back button still leaves the page rather than walking the tabs.
-}
selectAccountTab :: Text -> Effect () () Model Action
selectAccountTab slug = withSink $ \_ -> do
    window <- jsg ("window" :: MisoString)
    history <- window ! "history"
    location <- window ! "location"
    path <- fromJSVal =<< getProperty location "pathname"
    let pathname :: String
        pathname = case (path :: Maybe MisoString) of
            Just value
                | not (T.null (T.strip (fromMisoString value))) ->
                    fromMisoString value
            _ -> "/account"
    stateValue <- toJSVal (Null :: Value)
    titleValue <- toJSVal ("" :: MisoString)
    urlValue <- toJSVal (ms (pathname <> "#" <> (T.unpack slug)))
    _ <- history # ("replaceState" :: MisoString) $ (stateValue, titleValue, urlValue)
    pure ()

-- | Put the address back after cancelling a history-driven dirty guard.
replaceBrowserRoute :: Route -> Effect () () Model Action
replaceBrowserRoute route =
    withSink $ \_ -> void (jsgf "ezaReplaceUrl" (prettyURI (toURI route) :: MisoString))

-- --------------------------------------------------------------- ledger ---

-- | Scroll the ledger container to an absolute pixel offset.
scrollLedger :: Int -> Effect () () Model Action
scrollLedger pixels = withSink $ \_ -> void $ jsgf "ezaScrollLedger" (pixels :: Int)

-- | Narrow sheets render every row, so the browser can find the row by id.
scrollRowIntoView :: Text -> Effect () () Model Action
scrollRowIntoView domId = withSink $ \_ -> do
    document <- jsg ("document" :: MisoString)
    el <- (document # ("getElementById" :: MisoString)) (ms domId)
    _ <- (el # ("scrollIntoView" :: MisoString)) ()
    pure ()

-- ----------------------------------------------------------------- graph ---

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

{- | Focus the plate once it has painted, so the keyboard shortcuts work
immediately after a visit. @preventScroll@ keeps the panel from jumping to the
canvas on a phone. The canvas only exists after the first layout paints, and on
a large library that can arrive several animation frames later, so retry over a
few frames.
-}
focusGraphCanvas :: Effect () () Model Action
focusGraphCanvas = withSink $ \_ -> attempt (0 :: Int)
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
scheduleGraphDetailStep :: RequestId -> Int -> Effect () () Model Action
scheduleGraphDetailStep epoch phase =
    withSink $ \sink -> do
        callback <- asyncCallback1 (\_ -> sink (GraphDetailStep epoch phase))
        _ <- jsgf "requestAnimationFrame" callback
        pure ()

{- | Debounce the graph filter input: cancel the previous browser timeout and
arm a new one; the settled action does the matching work.
-}
graphFilterSettle :: Effect () () Model Action
graphFilterSettle = do
    m <- get
    case mGraphFilterTimer m of
        Just oldTimer -> withSink $ \_ -> void (jsgf "clearTimeout" (oldTimer :: Int))
        Nothing -> pure ()
    withSink $ \sink -> do
        timer <- fromJSValUnchecked =<< jsgf "setTimeout" (asyncCallback1 (\_ -> sink GraphFilterSettled), 120 :: Int)
        sink (GraphFilterArmed (timer :: Int))

-- ------------------------------------------------------ browser primitives ---

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

readOnline :: IO Bool
readOnline = do
    navigator <- jsg "navigator"
    value <- navigator ! "onLine"
    online <- fromJSVal value
    pure (fromMaybe True (online :: Maybe Bool))

readOrigin :: IO MisoString
readOrigin = do
    window <- jsg "window"
    location <- window ! "location"
    value <- location ! "origin"
    origin <- fromJSVal value
    pure (fromMaybe "" (origin :: Maybe MisoString))

readTheme :: IO Theme
readTheme = do
    holder <- jsg "EzaTheme"
    value <- holder # "get" $ ()
    themeM <- fromJSVal value
    pure $ maybe ThemeLight (themeOfText . fromMisoString) (themeM :: Maybe MisoString)
