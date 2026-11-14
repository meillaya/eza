{-# LANGUAGE LambdaCase #-}

{- | The job-polling reducer: one native state machine for the four M4-D
egress flows (snapshot capture, dead-link sweep, AI tag suggestions, webhook
test delivery).

The enqueue request and the per-flow result handling stay in the route-group
reducer that owns the feature; this module owns the polling mechanics:

- 'startJob' records a poll and schedules the first status request.
- 'JobTick' is the only place that issues a status request; it ignores a tick
  that is not the current timer, so one poll can never have two in flight.
- 'JobStatusLoaded' accepts only the answer for the current 'RequestId', then
  either hands a terminal result to the owning group, schedules the next
  (backed-off) poll, or gives up after 'Eza.Web.Logic.Job.jobPollBudgetMs'.
- 'cancelAllJobs' drops every poll when the route changes; stale ticks and
  answers for the dropped jobs are ignored.

No clock is read: elapsed time is the sum of the delays already scheduled, so
native tests can drive the state machine deterministically.
-}
module Eza.Web.Logic.Update.Job (
    handle,
    cancelAllJobs,
) where

import Data.Aeson (Value)
import qualified Data.IntMap.Strict as IM
import Data.Maybe (fromMaybe)
import Data.Text (Text)

import Eza.Web.Logic.Browser (scheduleAction)
import Eza.Web.Logic.Effect (RequestId (..), TimerId (..), nextRequestId)
import Eza.Web.Logic.Error (ApiError (..))
import Eza.Web.Logic.Job (
    JobKind (..),
    JobPoll (..),
    JobState (..),
    JobStatus (..),
    initialPoll,
    nextDelayMs,
    pollAnswered,
    pollTimedOut,
 )
import Eza.Web.Logic.Model
import Eza.Web.Logic.Requests (fetchJobStatus)
import Eza.Web.Logic.Update.Monad (Update, dispatch, get, putModel)

handle :: Action -> Update ()
handle = \case
    JobStarted kind jobId -> startJob kind jobId
    JobTick kind jobId timerId -> tick kind jobId timerId
    JobStatusLoaded kind jobId requestId status -> statusLoaded kind jobId requestId status
    JobStatusFailed kind jobId requestId err -> statusFailed kind jobId requestId err
    JobAbandoned kind jobId -> abandon kind jobId
    JobTimedOut kind jobId -> timedOut kind jobId
    _ -> pure ()

{- | Record a job and schedule its first status poll. The owning group has
already set its busy indicator before dispatching this action.
-}
startJob :: JobKind -> Int -> Update ()
startJob kind jobId = do
    model <- get
    let timerId = nextTimer (mJobTimerNext model)
        poll =
            (initialPoll kind jobId)
                { jpTimer = Just timerId
                , jpElapsedMs = jpDelayMs (initialPoll kind jobId)
                }
    putModel
        ( \m ->
            m{gJobs = (gJobs m){jbJobPolls = IM.insert jobId poll (mJobPolls m), jbJobTimerNext = timerId}}
        )
    scheduleAction (jpDelayMs poll) (JobTick kind jobId timerId)

-- | A timer fired: issue the status request, unless this is a stale tick.
tick :: JobKind -> Int -> TimerId -> Update ()
tick kind jobId timerId = do
    model <- get
    case IM.lookup jobId (mJobPolls model) of
        Just poll
            | jpTimer poll == Just timerId && jpRequest poll == Nothing -> do
                let requestId = mJobRequestNext model
                    poll' =
                        poll
                            { jpTimer = Nothing
                            , jpRequest = Just requestId
                            , jpAttempts = jpAttempts poll + 1
                            }
                putModel
                    ( \m ->
                        m{gJobs = (gJobs m){jbJobPolls = IM.insert jobId poll' (mJobPolls m), jbJobRequestNext = nextRequestId requestId}}
                    )
                fetchJobStatus
                    jobId
                    (JobStatusLoaded kind jobId requestId)
                    (JobStatusFailed kind jobId requestId)
        _ -> pure ()

-- | A status answer arrived for the poll we sent it to.
statusLoaded :: JobKind -> Int -> RequestId -> JobStatus -> Update ()
statusLoaded kind jobId requestId status = do
    model <- get
    case IM.lookup jobId (mJobPolls model) of
        Just poll
            | jpRequest poll == Just requestId -> do
                let poll' = pollAnswered poll
                case jsState status of
                    JobDone -> do
                        removeJob jobId
                        dispatch (doneAction kind jobId (jsResult status))
                    JobFailed -> do
                        removeJob jobId
                        dispatch (failedAction kind jobId (Just (fromMaybe "The job failed." (jsError status))))
                    JobCancelled -> do
                        removeJob jobId
                        dispatch (failedAction kind jobId (Just "The job was cancelled."))
                    _ -> advance poll'
        _ -> pure ()

{- | A status request failed. A missing job is terminal; a transport error is
retried within the polling budget (the worker keeps the job, so a blip is not
worth throwing the flow away).
-}
statusFailed :: JobKind -> Int -> RequestId -> ApiError -> Update ()
statusFailed kind jobId requestId err = do
    model <- get
    case IM.lookup jobId (mJobPolls model) of
        Just poll
            | jpRequest poll == Just requestId ->
                case aeStatus err of
                    Just 404 -> do
                        removeJob jobId
                        dispatch (failedAction kind jobId (Just (aeMessage err)))
                    _ -> advance (pollAnswered poll)
        _ -> pure ()

advance :: JobPoll -> Update ()
advance poll
    | pollTimedOut poll = do
        removeJob (jpJobId poll)
        dispatch (failedAction (jpKind poll) (jpJobId poll) (Just timeoutMessage))
    | otherwise = do
        model <- get
        let delay = nextDelayMs (jpDelayMs poll)
            timerId = nextTimer (mJobTimerNext model)
            poll' =
                poll
                    { jpTimer = Just timerId
                    , jpDelayMs = delay
                    , jpElapsedMs = jpElapsedMs poll + delay
                    }
        putModel
            ( \m ->
                m{gJobs = (gJobs m){jbJobPolls = IM.insert (jpJobId poll) poll' (mJobPolls m), jbJobTimerNext = timerId}}
            )
        scheduleAction delay (JobTick (jpKind poll) (jpJobId poll) timerId)

-- | A stale timer or a route change: drop the poll; late answers are ignored.
abandon :: JobKind -> Int -> Update ()
abandon _ jobId = removeJob jobId

timedOut :: JobKind -> Int -> Update ()
timedOut kind jobId = do
    removeJob jobId
    dispatch (failedAction kind jobId (Just timeoutMessage))

{- | Drop every active poll and tell the owning groups, so no busy indicator
survives a route change. The group actions are dispatched after the polls are
gone; their stale timers/answers can no longer match.
-}
cancelAllJobs :: Update ()
cancelAllJobs = do
    model <- get
    let polls = IM.elems (mJobPolls model)
    putModel (\m -> m{gJobs = (gJobs m){jbJobPolls = IM.empty}})
    mapM_ (\poll -> dispatch (abandonedAction (jpKind poll) (jpJobId poll))) polls

removeJob :: Int -> Update ()
removeJob jobId = putModel (\m -> m{gJobs = (gJobs m){jbJobPolls = IM.delete jobId (mJobPolls m)}})

-- ------------------------------------------------------ flow-specific glue ---

doneAction :: JobKind -> Int -> Maybe Value -> Action
doneAction kind jobId result = case kind of
    SnapshotJob bookmarkId -> SnapshotJobDone bookmarkId result
    DeadCheckJob -> DeadCheckJobDone result
    AiSuggestionsJob _ -> AiSuggestionsJobDone jobId result
    WebhookTestJob webhookId -> WebhookTestJobDone webhookId result

failedAction :: JobKind -> Int -> Maybe Text -> Action
failedAction kind _ message = case kind of
    SnapshotJob bookmarkId -> SnapshotJobFailed bookmarkId message
    DeadCheckJob -> DeadCheckJobFailed message
    AiSuggestionsJob _ -> AiSuggestionsJobFailed message
    WebhookTestJob webhookId -> WebhookTestJobFailed webhookId message

abandonedAction :: JobKind -> Int -> Action
abandonedAction kind _ = case kind of
    SnapshotJob bookmarkId -> SnapshotJobAbandoned bookmarkId
    DeadCheckJob -> DeadCheckJobAbandoned
    AiSuggestionsJob _ -> AiSuggestionsJobAbandoned
    WebhookTestJob webhookId -> WebhookTestJobAbandoned webhookId

nextTimer :: TimerId -> TimerId
nextTimer (TimerId value) = TimerId (value + 1)

timeoutMessage :: Text
timeoutMessage = "The background job did not finish in time. Try again in a moment."
