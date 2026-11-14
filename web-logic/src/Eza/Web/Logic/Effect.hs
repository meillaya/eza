{- | The effects a native client reducer may ask the shell to perform.

A reducer in this package is pure: it turns one action into a new state plus a
list of 'Effect' values. The Miso shell interprets those values (see
@Eza.Web.LedgerBridge@), which is the only place that knows how a browser
request, a history entry or a timer is actually made. Nothing in this module
names a Miso type, an action constructor of the shell or a JSFFI function.

=== Requests and staleness

A 'Fetch' carries a 'RequestId' chosen by the reducer that issued it. The
reducer remembers the id as its /current/ request for that stream and ignores
any response whose id is not current. The shell only has to echo the id back,
so out-of-order responses cannot overwrite newer state.

=== How a timer resumes logic

'Schedule' carries a delay and a 'TimerId'; when the timer fires the shell
feeds the same id back to the owning reducer. The reducer accepts the
'TimerId' only while it is still its current timer and ignores the stale ones.
The shell therefore needs no knowledge of what a timer means: the mapping from
a bare id to the reducer entry point (for the ledger: @SearchDebounceElapsed@)
lives next to the reducer it belongs to, and the bridge only knows the one web
@Action@ that carries the id back.

A timer is cancelled with 'CancelTimer'. Cancelling is advisory: the reducer
drops the id, the shell clears the browser timeout when it still can, and a
late fire is ignored by the reducer either way.
-}
module Eza.Web.Logic.Effect (
    RequestId (..),
    TimerId (..),
    Effect (..),
    nextRequestId,
    requestIsCurrent,
) where

import Data.Text (Text)

import Eza.Web.Logic.Api (ClientRequest)
import Eza.Web.Logic.Route (Route)

{- | The identity of one in-flight request. Ids are allocated by the slice
reducer and increase monotonically, so "newer" is just a comparison.
-}
newtype RequestId = RequestId
    { unRequestId :: Int
    }
    deriving (Eq, Ord, Show)

-- | The identity of one scheduled timer. Allocated by the slice reducer.
newtype TimerId = TimerId
    { unTimerId :: Int
    }
    deriving (Eq, Ord, Show)

{- | One shell action requested by a reducer.

The constructors cover what the ledger slice (and the slices M2-B2 adds) need
from the browser: a JSON read, a history navigation, a document title, focus
and a timer. Writes are not modelled here yet; they still go through the
Miso shell until M2-B2 adopts them.
-}
data Effect
    = -- | Read one JSON endpoint. The response comes back tagged with the id.
      Fetch ClientRequest RequestId
    | -- | Run an action after a delay (milliseconds), under a timer id.
      Schedule Int TimerId
    | -- | Cancel a timer that has not fired yet.
      CancelTimer TimerId
    | -- | Push a route onto the browser history stack.
      Navigate Route
    | -- | Rewrite the current history entry instead of pushing a new one.
      ReplaceUrl Route
    | -- | Set the browser tab title.
      SetDocumentTitle Text
    | -- | Focus one element by DOM id after the next render.
      Focus Text
    deriving (Eq, Show)

-- | The successor of a request id. Reducers allocate ids from their state.
nextRequestId :: RequestId -> RequestId
nextRequestId (RequestId n) = RequestId (n + 1)

{- | Does a response stamped with @stamped@ still answer the @current@ request?
The comparison lives here so every slice shares one staleness rule.
-}
requestIsCurrent :: RequestId -> RequestId -> Bool
requestIsCurrent current stamped = stamped == current
