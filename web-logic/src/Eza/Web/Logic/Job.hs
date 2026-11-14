{-# LANGUAGE OverloadedStrings #-}

{- | The native job-polling vocabulary.

M4-D turns the four egress flows (snapshot capture, dead-link sweep, AI tag
suggestions, webhook test delivery) into durable server jobs. The client sends
the flow's enqueue request, receives a job id, and polls
@GET /api/v1/jobs/{id}@ until the job reaches a terminal state.

The state machine lives here so a native test can drive queued -> running ->
done/failed, timeouts and stale answers without a browser. Browser timers and
requests are shell effects; this module only names the values:

- 'JobPoll' is the client-side poll record, one per active job.
- 'initialPoll' schedules the first poll after a short delay.
- 'nextDelayMs' backs off to the cap; 'jobPollBudgetMs' is the client-side
  timeout after which the reducer abandons the job.
- 'parseJobState' and the strict 'FromJSON JobStatus' decode the status body;
  an unknown state word is a decode error, never a silent default.

Staleness reuses the shared request id rule: a poll stores the 'RequestId' of
its in-flight status request and ignores an answer for another id, so a late
response cannot overwrite a newer poll or resurrect an abandoned job.
-}
module Eza.Web.Logic.Job (
    JobKind (..),
    JobState (..),
    JobStatus (..),
    JobPoll (..),
    jobKindLabel,
    jobKindTarget,
    aiScopeWord,
    initialPoll,
    firstPollDelayMs,
    nextDelayMs,
    jobPollBudgetMs,
    maxPollAttempts,
    pollAnswered,
    pollTimedOut,
    parseJobState,
) where

import Data.Aeson (FromJSON (..), Value, withObject, (.:), (.:?))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Eza.Web.Logic.Ids (RequestId, TimerId)

-- | Which flow an active job belongs to, and the row it targets.
data JobKind
    = SnapshotJob Int
    | DeadCheckJob
    | {- | The tag-bucket scope: @Nothing@ means every bookmark ("all"), and the
      dedupe target the server sees is the tag word or "all".
      -}
      AiSuggestionsJob (Maybe Text)
    | WebhookTestJob Int
    deriving (Eq, Show)

-- | The terminal-or-not state the server reports.
data JobState = JobQueued | JobRunning | JobDone | JobFailed | JobCancelled
    deriving (Eq, Show)

{- | One status body from @GET /api/v1/jobs/{id}@. The client never invents a
state: an unknown word fails the decode.
-}
data JobStatus = JobStatus
    { jsId :: Int
    , jsKind :: Text
    , jsState :: JobState
    , jsAttempts :: Int
    , jsResult :: Maybe Value
    , jsError :: Maybe Text
    }
    deriving (Eq, Show)

instance FromJSON JobStatus where
    parseJSON = withObject "job status" $ \o -> do
        jobId <- o .: "id"
        kind <- o .: "kind"
        stateWord <- o .: "state"
        state <- case parseJobState stateWord of
            Just parsed -> pure parsed
            Nothing -> fail ("unknown job state " <> T.unpack stateWord)
        attempts <- o .: "attempts"
        result <- o .:? "result"
        err <- o .:? "error"
        pure
            JobStatus
                { jsId = jobId
                , jsKind = kind
                , jsState = state
                , jsAttempts = attempts
                , jsResult = result
                , jsError = err
                }

parseJobState :: Text -> Maybe JobState
parseJobState = \case
    "queued" -> Just JobQueued
    "running" -> Just JobRunning
    "done" -> Just JobDone
    "failed" -> Just JobFailed
    "cancelled" -> Just JobCancelled
    _ -> Nothing

-- | A human label for the flow, used in the busy indicators and toasts.
jobKindLabel :: JobKind -> Text
jobKindLabel = \case
    SnapshotJob _ -> "snapshot"
    DeadCheckJob -> "dead-link check"
    AiSuggestionsJob _ -> "tag suggestions"
    WebhookTestJob _ -> "webhook test"

jobKindTarget :: JobKind -> Maybe Int
jobKindTarget = \case
    SnapshotJob bookmarkId -> Just bookmarkId
    DeadCheckJob -> Nothing
    AiSuggestionsJob _ -> Nothing
    WebhookTestJob webhookId -> Just webhookId

{- | The dedupe word for an AI suggestion scope: the tag, or "all" for the
unfiltered bucket.
-}
aiScopeWord :: Maybe Text -> Text
aiScopeWord = fromMaybe "all"

{- | One active client-side poll. @jpElapsedMs@ sums the delays already spent so
the reducer can enforce 'jobPollBudgetMs' without reading a clock.
-}
data JobPoll = JobPoll
    { jpJobId :: Int
    , jpKind :: JobKind
    , jpTimer :: Maybe TimerId
    , jpRequest :: Maybe RequestId
    , jpAttempts :: Int
    , jpDelayMs :: Int
    , jpElapsedMs :: Int
    }
    deriving (Eq, Show)

{- | The first poll waits this long; the flow's enqueue request usually lands
just before the worker picks the job up.
-}
firstPollDelayMs :: Int
firstPollDelayMs = 500

-- | Backoff: 1 s, 2 s, 4 s, ... capped at 60 s.
nextDelayMs :: Int -> Int
nextDelayMs previous
    | previous <= 0 = 1000
    | otherwise = min pollDelayCapMs (previous * 2)

pollDelayCapMs :: Int
pollDelayCapMs = 60000

{- | Give up polling after this long; the UI reports a timeout and the server
job keeps running (the client can no longer show its result).
-}
jobPollBudgetMs :: Int
jobPollBudgetMs = 180000

-- | Hard cap on polls for one job, so a broken server cannot loop us forever.
maxPollAttempts :: Int
maxPollAttempts = 200

-- | A fresh poll: no timer or request in flight yet, first delay queued.
initialPoll :: JobKind -> Int -> JobPoll
initialPoll kind jobId =
    JobPoll
        { jpJobId = jobId
        , jpKind = kind
        , jpTimer = Nothing
        , jpRequest = Nothing
        , jpAttempts = 0
        , jpDelayMs = firstPollDelayMs
        , jpElapsedMs = 0
        }

-- | Record that a status answer arrived: the request is no longer in flight.
pollAnswered :: JobPoll -> JobPoll
pollAnswered poll = poll{jpRequest = Nothing}

-- | Would scheduling the next poll exceed the client-side budget?
pollTimedOut :: JobPoll -> Bool
pollTimedOut poll =
    jpElapsedMs poll + jpDelayMs poll > jobPollBudgetMs
        || jpAttempts poll >= maxPollAttempts
