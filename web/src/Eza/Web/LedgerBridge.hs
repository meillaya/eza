{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The adapter between the native ledger reducer and the Miso shell. This is
the only module that imports both worlds: it projects the shell's existing
'Model' fields into a native @LedgerState@, runs @updateLedger@, writes the new
state back into the same fields, and interprets the returned native @Effect@
values with Miso's effect monad and browser API.

The projection is deliberate: the model stays the single store (views and the
rest of the update function keep reading the same fields), and the reducer owns
the transitions. Nothing is copied into a second hidden ledger, so a shell
action that still writes a ledger field directly (boot seeding, route load)
stays visible to the next reducer step.

== Effect interpretation

- @Fetch@ becomes the matching "Eza.Web.Api" reader. The response is fed back
  as a shell 'Action' carrying the request id
  ('ListLoaded', 'ListFailed', 'StatsLoaded', 'StatsFailed').
- @Schedule@ / @CancelTimer@ become @setTimeout@ / @clearTimeout@. The
  timeout callback dispatches 'TimerFired' with the native @TimerId@; which
  maps
  that id to the reducer entry point (the ledger's @SearchDebounceElapsed@).
  The reducer drops the id when it is no longer current. This is how a timer
  resumes pure logic without the logic package knowing a Miso action.
- @Navigate@ is dispatched as the shell's own 'Navigate' action so the
  unsaved-edit guard keeps working. @ReplaceUrl@, @SetDocumentTitle@ and
  @Focus@ perform their browser operation directly.

The read table is complete for the ledger slice (list page and stats). M2-B2
moves it to a general @Eza.Web.Interpreter@ when more slices emit fetches.
-}
module Eza.Web.LedgerBridge (
    extractLedger,
    embedLedger,
    runLedgerAction,
) where

import Control.Monad (void)
import Data.Foldable (traverse_)

import Miso
import Miso.Router (toURI)

import Eza.Web.Api (fetchBookmarksQuery, fetchStats)
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
import Eza.Web.Model

-- ----------------------------------------------------------- projection ---

{- | Read the ledger-owned subset of the shell model. Fields the shell still
mutates directly (boot seeding, the route loader) are read here each time, so
the projection never goes stale.
-}
extractLedger :: Model -> LedgerState
extractLedger model =
    initialLedgerState
        { ldQuery = fromMisoString (mQ model)
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
        , ldError = fmap fromMisoString (mError model)
        , ldListRequest = RequestId (mListEpoch model)
        , ldDebounceTimer = mDebounceTimer model
        , ldTimerSeq = mTimerSeq model
        , ldStats = mStats model
        , ldStatsError = fmap fromMisoString (mStatsError model)
        , ldStatsRequest = RequestId (mStatsEpoch model)
        }

-- | Write the ledger-owned fields back into the shell model.
embedLedger :: LedgerState -> Model -> Model
embedLedger ledger model =
    model
        { mQ = ms (ldQuery ledger)
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
        , mError = fmap ms (ldError ledger)
        , mListEpoch = unRequestId (ldListRequest ledger)
        , mDebounceTimer = ldDebounceTimer ledger
        , mTimerSeq = ldTimerSeq ledger
        , mStats = ldStats ledger
        , mStatsError = fmap ms (ldStatsError ledger)
        , mStatsEpoch = unRequestId (ldStatsRequest ledger)
        }

-- --------------------------------------------------------------- driver ---

{- | Run one ledger action: project, reduce, write back, interpret. The shell
actions that wrap a ledger event also do their own selection/scroll bookkeeping
around this call; the bridge itself touches only ledger-owned fields.
-}
runLedgerAction :: LedgerAction -> Effect () () Model Action
runLedgerAction action = do
    model <- get
    let (ledger, effects) = updateLedger (extractLedger model) action
    put (embedLedger ledger model)
    traverse_ interpretEffect effects

-- | Interpret one effect in the browser.
interpretEffect :: Logic.Effect -> Effect () () Model Action
interpretEffect = \case
    Logic.Fetch request requestId -> fetchRequest request requestId
    Logic.Schedule delayMs timerId -> scheduleTimer delayMs timerId
    -- The browser handle is tracked under the model's debounce field; the
    -- timer id itself is checked by the reducer when the callback arrives.
    Logic.CancelTimer _ -> cancelTimer
    Logic.Navigate route -> withSink $ \sink -> sink (Navigate route)
    Logic.ReplaceUrl route -> withSink $ \_ -> replaceURI (toURI route)
    Logic.SetDocumentTitle title -> withSink $ \_ -> applyDocumentTitle (ms title)
    Logic.Focus domId -> withSink $ \_ -> focusAfterRender (ms domId)

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

{- | Schedule one logic timer. The callback carries the logic id, so the
reducer decides whether the fire is still current.
-}
scheduleTimer :: Int -> TimerId -> Effect () () Model Action
scheduleTimer delayMs timerId =
    withSink $ \sink -> do
        timer <- fromJSValUnchecked =<< jsgf "setTimeout" (asyncCallback1 (\_ -> sink (TimerFired timerId)), delayMs :: Int)
        sink (TimerRegistered (timer :: Int))

{- | Clear the pending browser timeout. The reducer has already dropped the
logic id; a browser that fires anyway delivers a stale id that is ignored.
-}
cancelTimer :: Effect () () Model Action
cancelTimer = do
    model <- get
    case mDebounce model of
        Nothing -> pure ()
        Just handle -> do
            put model{mDebounce = Nothing}
            withSink $ \_ -> void $ jsgf "clearTimeout" (handle :: Int)

-- | Set the browser tab title.
applyDocumentTitle :: MisoString -> IO ()
applyDocumentTitle title = do
    document <- jsg ("document" :: MisoString)
    setField document ("title" :: MisoString) title

{- | Focus an element after the render that creates it. Focusing in the same
update runs before the element exists.
-}
focusAfterRender :: MisoString -> IO ()
focusAfterRender domId = do
    _ <- jsgf "setTimeout" (asyncCallback (focus domId), 60 :: Int)
    pure ()
