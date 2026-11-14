{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The single place where the client executes something outside the pure
update function: JSON requests, browser history, DOM focus and geometry,
timers, the clipboard, the theme, uploads and the event subscriptions.

The reducers in "Eza.Web.Logic.Update" are pure: they return a new
'Eza.Web.Logic.Model.Model' and a list of "Eza.Web.Logic.Effect.Effect" values.
This module interprets those values; nothing else under @src/Eza/Web@ calls a
JSFFI function or @withSink@ directly. "Eza.Web.Transport" owns the HTTP
exchange, and the pure helper bodies that remain here are browser primitives.
-}
module Eza.Web.Interpreter (
    subscriptions,
    interpretEffects,
) where

import Control.Monad (unless, void, when)
import Data.Aeson (Value (Null))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Miso hiding (Effect, Schedule)
import qualified Miso
import qualified Miso.JSON as MJ
import Miso.Router (toURI)

import Eza.Web.Logic.Api (ClientRequest (..), requestPath)
import Eza.Web.Logic.Effect (Effect (..), RequestId (..), TimerId (..))
import Eza.Web.Logic.Model
import Eza.Web.Logic.Requests (decodeResponseAt, decodeStatsAt)
import Eza.Web.Logic.Route (Route (..))
import qualified Eza.Web.Logic.Route as ClientRoute
import Eza.Web.Model ()
import Eza.Web.Transport (performRequest, uploadImport)

-- -------------------------------------------------------- effect driver ---

-- | Interpret the effects one pure update returned, in order.
interpretEffects :: [Effect] -> Miso.Effect () () Model Action
interpretEffects = mapM_ interpretEffect

-- | Interpret one effect in the browser.
interpretEffect :: Effect -> Miso.Effect () () Model Action
interpretEffect = \case
    Fetch request requestId -> fetchRequest request requestId
    Schedule delayMs timerId -> scheduleTimer delayMs timerId
    CancelTimer _ -> cancelTimer
    ApiRequest request requestBody onResult -> performRequest request requestBody onResult
    OpSubmitImport onOk onErr -> uploadImport onOk onErr
    OpNavigate route -> navigateTo route
    OpReplaceUrl route -> replaceRoute route
    OpReplaceBrowserRoute route -> replaceBrowserRoute route
    OpSetDocumentTitle title -> setDocumentTitle title
    OpFocusElement domId -> focusElement domId
    OpFocusElementDelayed domId -> focusElementDelayed domId
    OpReadNoteCursor -> readNoteCursor
    OpSetNoteCursor cursor -> setNoteCursor cursor
    OpReadReaderSelection -> readReaderSelection
    OpCopyText value successMessage failureMessage ->
        copyText value successMessage failureMessage
    OpRedirect url -> redirect url
    OpBootstrapEnvironment -> bootstrapEnvironment
    OpToggleTheme -> toggleTheme
    OpRefreshLayout -> refreshLayout
    OpMeasureLedgerScroll -> measureLedgerScroll
    OpTriggerFileInput domId -> triggerFileInput domId
    OpSelectAccountTab slug -> selectAccountTab slug
    OpScrollLedger pixels -> scrollLedger pixels
    OpScrollRowIntoView domId -> scrollRowIntoView domId
    OpMeasureGraphCanvas -> measureGraphCanvas GraphMeasured
    OpFocusGraphCanvas -> focusGraphCanvas
    OpScheduleGraphSettle -> scheduleGraphSettle
    OpScheduleGraphDetailStep epoch phase -> scheduleGraphDetailStep epoch phase
    OpGraphFilterSettle -> graphFilterSettle
    OpScheduleAction delayMs action -> scheduleAction delayMs action

{- | Start the reader a ledger effect asked for and route its answer back. The
list fetch is an append when that append is in flight; that is the flag the
response action needs to append instead of replace.
-}
fetchRequest :: ClientRequest -> RequestId -> Miso.Effect () () Model Action
fetchRequest request requestId = case request of
    ApiBookmarks _ -> do
        model <- get
        let append = mLoadingMore model
            onResult result = case result of
                Left err -> ListFailed append requestId err
                Right value -> case decodeResponseAt (requestPath request) value of
                    Left err -> ListFailed append requestId err
                    Right page -> ListLoaded append requestId page
        performRequest request Nothing onResult
    ApiStats ->
        performRequest
            request
            Nothing
            ( \result -> case result of
                Left err -> StatsFailed requestId err
                Right value -> case decodeStatsAt (requestPath request) value of
                    Left err -> StatsFailed requestId err
                    Right stats -> StatsLoaded requestId stats
            )
    _ -> pure ()

-- | Run one action after a delay (milliseconds).
scheduleAction :: Int -> Action -> Miso.Effect () () Model Action
scheduleAction delayMs action =
    withSink $ \sink -> do
        _ <- jsgf "setTimeout" (asyncCallback1 (\_ -> sink action), delayMs :: Int)
        pure ()

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

{- | Schedule one native timer. The callback carries the native id, so the
reducer decides whether the fire is still current.
-}
scheduleTimer :: Int -> TimerId -> Miso.Effect () () Model Action
scheduleTimer delayMs timerId =
    withSink $ \sink -> do
        timer <- fromJSValUnchecked =<< jsgf "setTimeout" (asyncCallback1 (\_ -> sink (TimerFired timerId)), delayMs :: Int)
        sink (TimerRegistered (timer :: Int))

{- | Clear the pending browser timeout. The reducer has already dropped the
native id; a browser that fires anyway delivers a stale id that is ignored.
-}
cancelTimer :: Miso.Effect () () Model Action
cancelTimer = do
    model <- get
    case mDebounce model of
        Nothing -> pure ()
        Just handle -> do
            put model{mDebounce = Nothing}
            withSink $ \_ -> void $ jsgf "clearTimeout" (handle :: Int)

-- --------------------------------------------------------------- helpers ---

{- | Send the whole page to another URL (sign-in, a download). Components using
this never come back, which is why the update action that triggers it is
usually the last step.
-}
redirect :: Text -> Miso.Effect () () Model Action
redirect url = withSink $ \_ -> do
    location <- jsg "window" ! "location"
    _ <- location # "assign" $ (ms url :: MisoString)
    pure ()

-- | Set the browser tab title.
setDocumentTitle :: Text -> Miso.Effect () () Model Action
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
bootstrapEnvironment :: Miso.Effect () () Model Action
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
toggleTheme :: Miso.Effect () () Model Action
toggleTheme = withSink $ \sink -> do
    holder <- jsg "EzaTheme"
    value <- holder # "toggle" $ ()
    themeM <- fromJSVal value
    sink (ThemeLoaded (maybe ThemeLight (themeOfText . fromMisoString) (themeM :: Maybe MisoString)))

{- | Re-read the viewport and the ledger's scroll metrics after a resize: the
column count and the virtualized window both depend on it.
-}
refreshLayout :: Miso.Effect () () Model Action
refreshLayout = withSink $ \sink -> do
    width <- windowInnerWidth
    height <- windowInnerHeight
    measured <- measureGrid
    sink (LayoutChanged width height)
    sink (ScrollMetrics measured)

-- | Re-read only the ledger scroll metrics (a scroll, or a layout pass).
measureLedgerScroll :: Miso.Effect () () Model Action
measureLedgerScroll = withSink $ \sink -> do
    measured <- measureGrid
    sink (ScrollMetrics measured)

-- | Focus one element by DOM id after the next render.
focusElement :: Text -> Miso.Effect () () Model Action
focusElement domId = withSink $ \_ -> focus (ms domId)

{- | Focus an input after the VDOM patch that creates the dialog has run.
Focusing in the same update runs before the element exists, which left focus
on the body behind the palette and the add dialog.
-}
focusElementDelayed :: Text -> Miso.Effect () () Model Action
focusElementDelayed domId = withSink $ \_ -> do
    _ <- jsgf "setTimeout" (asyncCallback (focus (ms domId)), 60 :: Int)
    pure ()

{- | Read the note editor's caret after the input event that changed the text.
Reading the DOM is the only way to know where the caret is; the reducer then
computes the wikilink completion query from the new text and offset.
-}
readNoteCursor :: Miso.Effect () () Model Action
readNoteCursor = withSink $ \sink -> do
    document <- jsg ("document" :: MisoString)
    element <- (document # ("getElementById" :: MisoString)) ("note-editor" :: MisoString)
    missing <- isNull element
    unless missing $ do
        selection <- fromMaybe 0 <$> (fromJSVal =<< getProperty element "selectionStart")
        sink (NoteCursorRead (round (selection :: Double)))

-- | Put the caret back after the update rewrote the note text.
setNoteCursor :: Int -> Miso.Effect () () Model Action
setNoteCursor cursor =
    withSink $ \_ -> setSelectionRange "note-editor" cursor cursor

{- | The reader's current text selection, as character offsets, after a mouse
up in the reading pane. The offsets come from the pwa.js bridge; a decode
failure means "no selection" rather than a broken page.
-}
readReaderSelection :: Miso.Effect () () Model Action
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
triggerFileInput :: Text -> Miso.Effect () () Model Action
triggerFileInput domId = withSink $ \_ -> do
    element <- getElementById (ms domId)
    click () element

{- | Copy text through the promise-based bridge. The toast reports the real
result, so a one-time secret is never announced as copied when the clipboard
write was denied.
-}
copyText :: Text -> Text -> Text -> Miso.Effect () () Model Action
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
navigateTo :: Route -> Miso.Effect () () Model Action
navigateTo route = withSink $ \_ -> pushRoute route

-- | Rewrite the current history entry instead of pushing a new one.
replaceRoute :: Route -> Miso.Effect () () Model Action
replaceRoute route = withSink $ \_ -> replaceURI (toURI route)

{- | Record the selected account tab in the URL fragment without a history
entry, so the back button still leaves the page rather than walking the tabs.
-}
selectAccountTab :: Text -> Miso.Effect () () Model Action
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
replaceBrowserRoute :: Route -> Miso.Effect () () Model Action
replaceBrowserRoute route =
    withSink $ \_ -> void (jsgf "ezaReplaceUrl" (prettyURI (toURI route) :: MisoString))

-- --------------------------------------------------------------- ledger ---

-- | Scroll the ledger container to an absolute pixel offset.
scrollLedger :: Int -> Miso.Effect () () Model Action
scrollLedger pixels = withSink $ \_ -> void $ jsgf "ezaScrollLedger" (pixels :: Int)

-- | Narrow sheets render every row, so the browser can find the row by id.
scrollRowIntoView :: Text -> Miso.Effect () () Model Action
scrollRowIntoView domId = withSink $ \_ -> do
    document <- jsg ("document" :: MisoString)
    el <- (document # ("getElementById" :: MisoString)) (ms domId)
    _ <- (el # ("scrollIntoView" :: MisoString)) ()
    pure ()

-- ----------------------------------------------------------------- graph ---

{- | Read the canvas box after a render. The element only exists once the graph
layout has painted, so a few short retries cover the first frame.
-}
measureGraphCanvas :: (Double -> Double -> Double -> Action) -> Miso.Effect () () Model Action
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
focusGraphCanvas :: Miso.Effect () () Model Action
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
scheduleGraphSettle :: Miso.Effect () () Model Action
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
scheduleGraphDetailStep :: RequestId -> Int -> Miso.Effect () () Model Action
scheduleGraphDetailStep epoch phase =
    withSink $ \sink -> do
        callback <- asyncCallback1 (\_ -> sink (GraphDetailStep epoch phase))
        _ <- jsgf "requestAnimationFrame" callback
        pure ()

{- | Debounce the graph filter input: cancel the previous browser timeout and
arm a new one; the settled action does the matching work.
-}
graphFilterSettle :: Miso.Effect () () Model Action
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
