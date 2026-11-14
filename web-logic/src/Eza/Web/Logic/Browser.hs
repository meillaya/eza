{- | The browser operations a reducer may request, as 'Update' actions.

Each function here only tags an 'Effect'; the shell "Eza.Web.Interpreter" owns
the FFI. The pure interface helpers (toasts, error policy, document title) also
live here because moving them into the reducers is what keeps the group modules
free of browser code.
-}
module Eza.Web.Logic.Browser (
    -- * Pure interface policy
    notify,
    handleApiError,
    documentTitle,

    -- * Navigation and history
    navigateTo,
    replaceRoute,
    replaceBrowserRoute,
    selectAccountTab,
    redirect,
    setDocumentTitle,

    -- * Focus, DOM reads and clipboard
    focusElement,
    focusElementDelayed,
    readNoteCursor,
    setNoteCursor,
    readReaderSelection,
    triggerFileInput,
    copyText,

    -- * Layout and scrolling
    bootstrapEnvironment,
    toggleTheme,
    refreshLayout,
    measureLedgerScroll,
    scrollLedger,
    scrollRowIntoView,

    -- * Graph browser work
    measureGraphCanvas,
    focusGraphCanvas,
    scheduleGraphSettle,
    scheduleGraphDetailStep,
    graphFilterSettle,

    -- * Timers
    scheduleAction,

    -- * Epoch guard
    whenCurrent,
) where

import Data.Text (Text)

import Eza.Web.Logic.Effect (Effect (..), RequestId, requestIsCurrent)
import Eza.Web.Logic.Error (ApiError (..))
import Eza.Web.Logic.Model (Action (..), Model (..), Toast (..), ToastKind (..))
import Eza.Web.Logic.Route (Route (..), routeTitle)
import Eza.Web.Logic.Update.Monad (Update, emit, get, putModel)

-- ------------------------------------------------------------ interface ---

{- | Show a toast. The dismissal timer is a shell effect; the reducer only
decides what to show and when it should go away.
-}
notify :: Text -> ToastKind -> Update ()
notify message kind = do
    model <- get
    let toastId = mToastNext model
        toast = Toast toastId message kind
        keep = drop (max 0 (length (mToasts model) - 3)) (mToasts model <> [toast])
    putModel (\m -> m{mToasts = keep, mToastNext = toastId + 1})
    emit (OpScheduleAction 4800 (ToastDismiss toastId))

{- | The one error-to-interface policy: an expired session blocks the page and
sends the reader to sign in; a planned-but-missing endpoint is an inline
notice; anything else is a toast.
-}
handleApiError :: ApiError -> Update ()
handleApiError err = case aeStatus err of
    Just 401 -> do
        putModel (\m -> m{mSignedOut = True})
        notify "Session expired. Sign in again." ToastError
    Just 404 -> do
        putModel (\m -> m{mNotice = Just (aeMessage err)})
        notify (aeMessage err) ToastInfo
    _ -> notify (aeMessage err) ToastError

-- | The browser tab title for a route.
documentTitle :: Route -> Text
documentTitle route = case route of
    Index -> "eza"
    _ -> routeTitle route <> " · eza"

-- ----------------------------------------------------- navigation/history ---

-- | Push a route onto the history stack.
navigateTo :: Route -> Update ()
navigateTo = emit . OpNavigate

-- | Rewrite the current history entry instead of pushing a new one.
replaceRoute :: Route -> Update ()
replaceRoute = emit . OpReplaceUrl

-- | Put the address back after cancelling a history-driven dirty guard.
replaceBrowserRoute :: Route -> Update ()
replaceBrowserRoute = emit . OpReplaceBrowserRoute

{- | Record the selected account tab in the URL fragment, without a history
entry.
-}
selectAccountTab :: Text -> Update ()
selectAccountTab = emit . OpSelectAccountTab

-- | Send the whole page to another URL (sign-in, a download).
redirect :: Text -> Update ()
redirect = emit . OpRedirect

-- | Set the browser tab title.
setDocumentTitle :: Text -> Update ()
setDocumentTitle = emit . OpSetDocumentTitle

-- ---------------------------------------------------- focus/DOM/clipboard ---

-- | Focus one element by DOM id after the next render.
focusElement :: Text -> Update ()
focusElement = emit . OpFocusElement

-- | Focus an input after the VDOM patch that creates it has run.
focusElementDelayed :: Text -> Update ()
focusElementDelayed = emit . OpFocusElementDelayed

-- | Read the note editor's caret after an input event.
readNoteCursor :: Update ()
readNoteCursor = emit OpReadNoteCursor

-- | Put the caret back after the update rewrote the note text.
setNoteCursor :: Int -> Update ()
setNoteCursor = emit . OpSetNoteCursor

-- | Read the reader pane's current selection offsets.
readReaderSelection :: Update ()
readReaderSelection = emit OpReadReaderSelection

-- | Open the native file picker of the import panel.
triggerFileInput :: Text -> Update ()
triggerFileInput = emit . OpTriggerFileInput

-- | Copy text; the toasts report the real clipboard result.
copyText :: Text -> Text -> Text -> Update ()
copyText value successMessage failureMessage =
    emit (OpCopyText value successMessage failureMessage)

-- ----------------------------------------------------- layout and scroll ---

-- | Read the browser environment once at mount.
bootstrapEnvironment :: Update ()
bootstrapEnvironment = emit OpBootstrapEnvironment

-- | Flip light/dark through the theme holder the shell bootstrapped.
toggleTheme :: Update ()
toggleTheme = emit OpToggleTheme

-- | Re-read the viewport and the ledger's scroll metrics after a resize.
refreshLayout :: Update ()
refreshLayout = emit OpRefreshLayout

-- | Re-read only the ledger scroll metrics.
measureLedgerScroll :: Update ()
measureLedgerScroll = emit OpMeasureLedgerScroll

-- | Scroll the ledger container to an absolute pixel offset.
scrollLedger :: Int -> Update ()
scrollLedger = emit . OpScrollLedger

-- | Narrow sheets render every row, so the browser can find the row by id.
scrollRowIntoView :: Text -> Update ()
scrollRowIntoView = emit . OpScrollRowIntoView

-- ---------------------------------------------------------------- graph ---

-- | Read the canvas box after a render.
measureGraphCanvas :: Update ()
measureGraphCanvas = emit OpMeasureGraphCanvas

-- | Focus the plate once it has painted.
focusGraphCanvas :: Update ()
focusGraphCanvas = emit OpFocusGraphCanvas

-- | Arm a settle check for the current view epoch.
scheduleGraphSettle :: Update ()
scheduleGraphSettle = emit OpScheduleGraphSettle

-- | Draw one chunk of the settle plate per animation frame.
scheduleGraphDetailStep :: RequestId -> Int -> Update ()
scheduleGraphDetailStep epoch phase = emit (OpScheduleGraphDetailStep epoch phase)

-- | Debounce the graph filter input.
graphFilterSettle :: Update ()
graphFilterSettle = emit OpGraphFilterSettle

-- --------------------------------------------------------------- timers ---

-- | Run one action after a delay (milliseconds).
scheduleAction :: Int -> Action -> Update ()
scheduleAction delay action = emit (OpScheduleAction delay action)

-- ------------------------------------------------------------ epoch guard ---

-- | Run an update only when a response still answers the current request.
whenCurrent :: RequestId -> (Model -> RequestId) -> Update () -> Update ()
whenCurrent stamped currentOf action = do
    model <- get
    if requestIsCurrent (currentOf model) stamped
        then action
        else pure ()
