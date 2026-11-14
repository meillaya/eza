{- | The effects a native client reducer may ask the shell to perform.

A reducer in this package is pure: it turns one action into a new state plus a
list of 'Effect' values. The Miso shell interprets those values in
"Eza.Web.Interpreter", which is the only place that knows how a browser
request, a history entry, a timer or a canvas geometry read is actually made.
Nothing in this module names a Miso type or a JSFFI function; the shell actions
a browser operation answers with are plain 'Action' values, which is why the
model (and therefore the action vocabulary) can live here.

=== Requests and staleness

An 'ApiRequest' carries the request, an optional JSON body, and a continuation
that receives the already-decoded-from-JSON 'Value' (or the transport
'Eza.Web.Logic.Error.ApiError'). The reducers that care about ordering compare
the 'RequestId' a response action carries against the current one; the shell
only has to echo the action back, so out-of-order responses cannot overwrite
newer state.

=== How a timer resumes logic

'Schedule' carries a delay and a 'TimerId'; when the timer fires the shell
feeds the same id back to the owning reducer through the timer action it
records when scheduling. 'OpScheduleAction' is the general form for timers
whose continuation is a plain action (a toast dismissal, a settle check).
A timer is cancelled with 'CancelTimer'; cancelling is advisory and a late fire
is ignored by the reducer either way.
-}
module Eza.Web.Logic.Effect (
    module Eza.Web.Logic.Ids,
    Effect (..),
) where

import Data.Aeson (Value)
import Data.Text (Text)

import Eza.Web.Logic.Api (ClientRequest)
import Eza.Web.Logic.Error (ApiError)
import Eza.Web.Logic.Ids
import Eza.Web.Logic.Model (Action)
import Eza.Web.Logic.Route (Route)
import Eza.Web.Logic.Wire (ImportResponse)

{- | One shell action requested by a reducer.

The constructors fall into three groups: JSON requests ('ApiRequest', and the
transitional 'Fetch' the M2-B1 ledger slice still emits), timers
('Schedule', 'CancelTimer', 'OpScheduleAction'), and browser operations whose
result the reducer needs ('OpReadNoteCursor', 'OpBootstrapEnvironment', the
graph measurements) or whose effect is fire-and-forget (focus, scroll,
navigation, clipboard, theme).
-}
data Effect
    = {- | Read one JSON endpoint for the ledger slice. The response comes back
      tagged with the request id. Transitional: new reducers use 'ApiRequest'.
      -}
      Fetch ClientRequest RequestId
    | -- | Run an action after a delay (milliseconds), under a timer id.
      Schedule Int TimerId
    | -- | Cancel a timer that has not fired yet.
      CancelTimer TimerId
    | -- | Decode one JSON response through the reducer's continuation.
      ApiRequest ClientRequest (Maybe Value) (Either ApiError Value -> Action)
    | -- | Upload the chosen import file and answer with the import summary.
      OpSubmitImport (ImportResponse -> Action) (ApiError -> Action)
    | -- | Push a route onto the browser history stack.
      OpNavigate Route
    | -- | Rewrite the current history entry instead of pushing a new one.
      OpReplaceUrl Route
    | -- | Put the address back after cancelling a history-driven dirty guard.
      OpReplaceBrowserRoute Route
    | -- | Set the browser tab title.
      OpSetDocumentTitle Text
    | -- | The browser tab title for a route.
      OpFocusElement Text
    | -- | Focus an input after the VDOM patch that creates it has run.
      OpFocusElementDelayed Text
    | -- | Read the note editor's caret offset after an input event.
      OpReadNoteCursor
    | -- | Put the caret back after the update rewrote the note text.
      OpSetNoteCursor Int
    | -- | Read the reader pane's current selection offsets.
      OpReadReaderSelection
    | -- | Copy text; the toasts report the real clipboard result.
      OpCopyText Text Text Text
    | -- | Send the whole page to another URL.
      OpRedirect Text
    | -- | Read the browser environment once at mount.
      OpBootstrapEnvironment
    | -- | Flip light/dark through the theme holder the shell bootstrapped.
      OpToggleTheme
    | -- | Re-read the viewport and the ledger scroll metrics.
      OpRefreshLayout
    | -- | Re-read only the ledger scroll metrics.
      OpMeasureLedgerScroll
    | -- | Open the native file picker of the import panel.
      OpTriggerFileInput Text
    | -- | Record the account tab in the URL fragment without a history entry.
      OpSelectAccountTab Text
    | -- | Scroll the ledger container to an absolute pixel offset.
      OpScrollLedger Int
    | -- | Scroll one row into view by DOM id.
      OpScrollRowIntoView Text
    | -- | Read the graph canvas box after a render.
      OpMeasureGraphCanvas
    | -- | Focus the graph plate once it has painted.
      OpFocusGraphCanvas
    | -- | Arm a settle check for the current graph view epoch.
      OpScheduleGraphSettle
    | -- | Draw one chunk of the settle plate per animation frame.
      OpScheduleGraphDetailStep RequestId Int
    | -- | Debounce the graph filter input.
      OpGraphFilterSettle
    | -- | Run an action after a delay (milliseconds).
      OpScheduleAction Int Action

-- Functions (request/timer continuations) have no Eq/Show instance.
-- Native tests inspect effects by pattern matching on constructors.
-- no deriving clause

{- Note [Comparing effects]
Effects carry continuations (functions) and actions, which have no 'Show' and
(or) no stable 'Eq' in the model. Native tests still want to assert the
sequence a reducer produced, so the instances below compare the data that
matters for ordering (request, body, delay, id) and deliberately ignore the
function fields; action payloads compare by constructor-independent delay only
where a continuation action is involved.
-}
instance Eq Effect where
    Fetch a b == Fetch c d = (a, b) == (c, d)
    Schedule a b == Schedule c d = (a, b) == (c, d)
    CancelTimer a == CancelTimer b = a == b
    ApiRequest a b _ == ApiRequest c d _ = (a, b) == (c, d)
    OpSubmitImport{} == OpSubmitImport{} = True
    OpNavigate a == OpNavigate b = a == b
    OpReplaceUrl a == OpReplaceUrl b = a == b
    OpReplaceBrowserRoute a == OpReplaceBrowserRoute b = a == b
    OpSetDocumentTitle a == OpSetDocumentTitle b = a == b
    OpFocusElement a == OpFocusElement b = a == b
    OpFocusElementDelayed a == OpFocusElementDelayed b = a == b
    OpReadNoteCursor == OpReadNoteCursor = True
    OpSetNoteCursor a == OpSetNoteCursor b = a == b
    OpReadReaderSelection == OpReadReaderSelection = True
    OpCopyText a b c == OpCopyText d e f = (a, b, c) == (d, e, f)
    OpRedirect a == OpRedirect b = a == b
    OpBootstrapEnvironment == OpBootstrapEnvironment = True
    OpToggleTheme == OpToggleTheme = True
    OpRefreshLayout == OpRefreshLayout = True
    OpMeasureLedgerScroll == OpMeasureLedgerScroll = True
    OpTriggerFileInput a == OpTriggerFileInput b = a == b
    OpSelectAccountTab a == OpSelectAccountTab b = a == b
    OpScrollLedger a == OpScrollLedger b = a == b
    OpScrollRowIntoView a == OpScrollRowIntoView b = a == b
    OpMeasureGraphCanvas == OpMeasureGraphCanvas = True
    OpFocusGraphCanvas == OpFocusGraphCanvas = True
    OpScheduleGraphSettle == OpScheduleGraphSettle = True
    OpScheduleGraphDetailStep a b == OpScheduleGraphDetailStep c d = (a, b) == (c, d)
    OpGraphFilterSettle == OpGraphFilterSettle = True
    OpScheduleAction a _ == OpScheduleAction b _ = a == b
    _ == _ = False

instance Show Effect where
    show effect = case effect of
        Fetch request requestId -> "Fetch " <> show request <> " " <> show requestId
        Schedule delay timerId -> "Schedule " <> show delay <> " " <> show timerId
        CancelTimer timerId -> "CancelTimer " <> show timerId
        ApiRequest request body _ -> "ApiRequest " <> show request <> " " <> show body
        OpSubmitImport{} -> "OpSubmitImport"
        OpNavigate route -> "OpNavigate " <> show route
        OpReplaceUrl route -> "OpReplaceUrl " <> show route
        OpReplaceBrowserRoute route -> "OpReplaceBrowserRoute " <> show route
        OpSetDocumentTitle title -> "OpSetDocumentTitle " <> show title
        OpFocusElement domId -> "OpFocusElement " <> show domId
        OpFocusElementDelayed domId -> "OpFocusElementDelayed " <> show domId
        OpReadNoteCursor -> "OpReadNoteCursor"
        OpSetNoteCursor cursor -> "OpSetNoteCursor " <> show cursor
        OpReadReaderSelection -> "OpReadReaderSelection"
        OpCopyText value ok err -> "OpCopyText " <> show value <> " " <> show ok <> " " <> show err
        OpRedirect url -> "OpRedirect " <> show url
        OpBootstrapEnvironment -> "OpBootstrapEnvironment"
        OpToggleTheme -> "OpToggleTheme"
        OpRefreshLayout -> "OpRefreshLayout"
        OpMeasureLedgerScroll -> "OpMeasureLedgerScroll"
        OpTriggerFileInput domId -> "OpTriggerFileInput " <> show domId
        OpSelectAccountTab slug -> "OpSelectAccountTab " <> show slug
        OpScrollLedger pixels -> "OpScrollLedger " <> show pixels
        OpScrollRowIntoView domId -> "OpScrollRowIntoView " <> show domId
        OpMeasureGraphCanvas -> "OpMeasureGraphCanvas"
        OpFocusGraphCanvas -> "OpFocusGraphCanvas"
        OpScheduleGraphSettle -> "OpScheduleGraphSettle"
        OpScheduleGraphDetailStep epoch phase -> "OpScheduleGraphDetailStep " <> show epoch <> " " <> show phase
        OpGraphFilterSettle -> "OpGraphFilterSettle"
        OpScheduleAction delay _ -> "OpScheduleAction " <> show delay
