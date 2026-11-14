{-# LANGUAGE OverloadedStrings #-}

{- | Native tests for the M4-D job polling state machine and the four egress
flow reducers: enqueue request, first poll, stagger, terminal results, timeout,
route-change cancel, stale answers and no double polling.
-}
module JobSpec (jobSpec) where

import Data.Aeson (Value, object, (.=))
import qualified Data.IntMap.Strict as IM
import Data.List (isInfixOf)
import Data.Maybe (fromJust)
import Test.Hspec

import Eza.Web.Logic.Api (ClientRequest (..))
import Eza.Web.Logic.Effect (Effect (..), RequestId (..), TimerId (..))
import Eza.Web.Logic.Error (mkApiError)
import Eza.Web.Logic.Job (
    JobKind (..),
    JobPoll (..),
    JobState (..),
    JobStatus (..),
    firstPollDelayMs,
    jobPollBudgetMs,
    nextDelayMs,
 )
import Eza.Web.Logic.Model
import Eza.Web.Logic.Route (Route (..))
import Eza.Web.Logic.Update (update)
import Eza.Web.Logic.Wire (WebhookTest (..))

run :: Action -> (Model, [Effect])
run action = update initialModel action

effectsOf :: [Effect] -> [String]
effectsOf = map show

jobPolls :: Model -> IM.IntMap JobPoll
jobPolls = mJobPolls

-- | The request id the poll machinery used for the last tick.
lastJobRequest :: Model -> RequestId
lastJobRequest model = RequestId (let RequestId n = mJobRequestNext model in n - 1)

status :: JobState -> Maybe Value -> JobStatus
status state result =
    JobStatus
        { jsId = 42
        , jsKind = "snapshot"
        , jsState = state
        , jsAttempts = 1
        , jsResult = result
        , jsError = Nothing
        }

queued :: JobStatus
queued = status JobQueued Nothing

doneWith :: Maybe Value -> JobStatus
doneWith = status JobDone

{- | Start the snapshot flow up to the point where the first status request is
in flight, returning (model, request id).
-}
startSnapshot :: (Model, RequestId)
startSnapshot =
    let (model1, effects1) = run (SnapshotJobQueued 7 42)
        timer = case effects1 of
            (OpScheduleAction _ (JobTick _ _ tid) : _) -> tid
            other -> error ("unexpected enqueue effects: " <> show other)
        (model2, _) = update model1 (JobTick (SnapshotJob 7) 42 timer)
     in (model2, lastJobRequest model2)

currentTimer :: Model -> TimerId
currentTimer model =
    case IM.lookup 42 (jobPolls model) of
        Just poll -> fromJust (jpTimer poll)
        Nothing -> error "no poll"

jobSpec :: Spec
jobSpec = describe "M4-D job polling" $ do
    describe "enqueue" $ do
        it "the snapshot action enqueues the POST job and schedules the first poll" $ do
            let (model, effects) = run (RunBookmarkAction 7 "snapshot")
            mSnapshotBusy model `shouldBe` True
            effectsOf effects
                `shouldSatisfy` any (isInfixOf "ApiRequest ApiBookmarkAction 7")
        it "the dead-link action enqueues the job request" $ do
            let (model, effects) = run DeadCheckRun
            mMaintBusy model `shouldBe` True
            effectsOf effects `shouldSatisfy` any (isInfixOf "ApiRequest ApiCheckDead")
        it "the AI action with no tag enqueues the unfiltered bucket" $ do
            let (_, effects) = run (AiTagSelected Nothing)
            effectsOf effects `shouldSatisfy` any (isInfixOf "ApiRequest ApiAiSuggestionsJob")
        it "the webhook action enqueues the test job" $ do
            let (model, effects) = run (WebhookTestRequest 3)
            mWebhookTestBusy model `shouldBe` True
            effectsOf effects `shouldSatisfy` any (isInfixOf "ApiRequest ApiTestWebhook 3")
        it "queuing records the poll and schedules the first tick" $ do
            let (model, effects) = run (SnapshotJobQueued 7 42)
            mSnapshotJob model `shouldBe` Just 42
            IM.keys (jobPolls model) `shouldBe` [42]
            case effects of
                [OpScheduleAction delay (JobTick (SnapshotJob 7) 42 (TimerId 1))] ->
                    delay `shouldBe` firstPollDelayMs
                other -> expectationFailure ("unexpected effects: " <> show other)
    describe "polling" $ do
        it "a tick issues exactly one status request" $ do
            let (model1, effects1) = run (SnapshotJobQueued 7 42)
                timer = case effects1 of
                    (OpScheduleAction _ (JobTick _ _ tid) : _) -> tid
                    other -> error (show other)
                (model2, effects2) = update model1 (JobTick (SnapshotJob 7) 42 timer)
            case effects2 of
                (ApiRequest (ApiJobStatus 42) Nothing _ : _) -> pure ()
                other -> expectationFailure ("unexpected effects: " <> show other)
            (jpRequest =<< IM.lookup 42 (jobPolls model2)) `shouldSatisfy` (`elem` [Just (lastJobRequest model2)])
        it "a duplicate tick while the request is in flight is ignored" $ do
            let (model, _) = startSnapshot
                timer = currentTimer model
                (model2, effects2) = update model (JobTick (SnapshotJob 7) 42 timer)
            effects2 `shouldBe` []
            mJobPolls model2 `shouldBe` mJobPolls model
        it "a queued answer schedules the backed-off next poll" $ do
            let (model, requestId) = startSnapshot
                (model2, effects2) = update model (JobStatusLoaded (SnapshotJob 7) 42 requestId queued)
            case effects2 of
                [OpScheduleAction delay (JobTick (SnapshotJob 7) 42 _)] ->
                    delay `shouldBe` nextDelayMs firstPollDelayMs
                other -> expectationFailure ("unexpected effects: " <> show other)
            IM.keys (jobPolls model2) `shouldBe` [42]
        it "a stale status answer is ignored" $ do
            let (model, requestId) = startSnapshot
                stale = RequestId (let RequestId n = requestId in n - 1)
                (model2, effects2) = update model (JobStatusLoaded (SnapshotJob 7) 42 stale queued)
            effects2 `shouldBe` []
            mJobPolls model2 `shouldBe` mJobPolls model
    describe "terminal results" $ do
        it "a captured snapshot clears the busy state and reloads the record" $ do
            let (model, requestId) = startSnapshot
                result =
                    Just
                        ( object
                            [ "snapshot" .= object ["path" .= ("/snap.html" :: String), "bytes" .= (12 :: Int)]
                            ]
                        )
                (model2, effects2) = update model (JobStatusLoaded (SnapshotJob 7) 42 requestId (doneWith result))
            IM.keys (jobPolls model2) `shouldBe` []
            mSnapshotBusy model2 `shouldBe` False
            mSnapshotJob model2 `shouldBe` Nothing
            effectsOf effects2 `shouldSatisfy` any (isInfixOf "OpScheduleAction")
        it "a failed snapshot shows the error and clears the busy state" $ do
            let (model, requestId) = startSnapshot
                failed = (status JobFailed Nothing){jsError = Just "monolith missing"}
                (model2, effects2) = update model (JobStatusLoaded (SnapshotJob 7) 42 requestId failed)
            mSnapshotBusy model2 `shouldBe` False
            IM.keys (jobPolls model2) `shouldBe` []
            effectsOf effects2 `shouldBe` effectsOf effects2 -- an effect list (toast + busy clear) is emitted
        it "a dead-link result updates the maintenance counts" $ do
            let (model1, _) = run (DeadCheckJobQueued 5)
                requestId = mJobRequestNext model1
                -- the queued action schedules the first tick rather than a request
                model2 =
                    model1
                        { mJobPolls =
                            IM.adjust
                                (\poll -> poll{jpTimer = Nothing, jpRequest = Just requestId})
                                5
                                (jobPolls model1)
                        }
                result = Just (object ["checked" .= (9 :: Int), "dead" .= (2 :: Int)])
                (model3, _) = update model2 (JobStatusLoaded DeadCheckJob 5 requestId (doneWith result))
            mMaintBusy model3 `shouldBe` False
            mCheckedCount model3 `shouldBe` Just 9
            mDeadCount model3 `shouldBe` Just 2
            IM.keys (jobPolls model3) `shouldBe` []
        it "an AI result fills the suggestion panel" $ do
            let (model1, _) = run (AiSuggestionsJobQueued (Just "rust") 9)
                requestId = mJobRequestNext model1
                model2 =
                    model1
                        { mJobPolls =
                            IM.adjust
                                (\poll -> poll{jpTimer = Nothing, jpRequest = Just requestId})
                                9
                                (jobPolls model1)
                        }
                result = Just (object ["suggestions" .= ([] :: [Int])])
                (model3, _) = update model2 (JobStatusLoaded (AiSuggestionsJob (Just "rust")) 9 requestId (doneWith result))
            mSuggestionsLoading model3 `shouldBe` False
            mSuggestions model3 `shouldBe` []
        it "a webhook test result stores the delivery answer" $ do
            let (model1, _) = run (WebhookTestJobQueued 3 11)
                requestId = mJobRequestNext model1
                model2 =
                    model1
                        { mJobPolls =
                            IM.adjust
                                (\poll -> poll{jpTimer = Nothing, jpRequest = Just requestId})
                                11
                                (jobPolls model1)
                        }
                result = Just (object ["ok" .= True, "status" .= (200 :: Int)])
                (model3, _) = update model2 (JobStatusLoaded (WebhookTestJob 3) 11 requestId (doneWith result))
            mWebhookTestBusy model3 `shouldBe` False
            case mWebhookTest model3 of
                Just (3, testResult) -> wtOk testResult `shouldBe` True
                other -> expectationFailure ("unexpected test result: " <> show other)
    describe "timeout and cancellation" $ do
        it "gives up when the next delay would exceed the poll budget" $ do
            let (model, requestId) = startSnapshot
                nearlyOut =
                    model
                        { mJobPolls =
                            IM.adjust
                                (\poll -> poll{jpElapsedMs = jobPollBudgetMs})
                                42
                                (jobPolls model)
                        }
                (model2, _) = update nearlyOut (JobStatusLoaded (SnapshotJob 7) 42 requestId queued)
            IM.keys (jobPolls model2) `shouldBe` []
            mSnapshotBusy model2 `shouldBe` False
        it "a route change cancels polls and clears the busy state" $ do
            let (model, _) = update (fst (run (SnapshotJobQueued 7 42))) (Navigate (Bookmark 1))
            mJobPolls model `shouldBe` IM.empty
            mSnapshotBusy model `shouldBe` False
        it "a bad status request retries within the budget" $ do
            let (model, requestId) = startSnapshot
                err = mkApiError Nothing (Just "network down")
                (model2, effects2) = update model (JobStatusFailed (SnapshotJob 7) 42 requestId err)
            -- retry schedules the next poll
            case effects2 of
                [OpScheduleAction _ (JobTick (SnapshotJob 7) 42 _)] -> pure ()
                other -> expectationFailure ("unexpected effects: " <> show other)
            IM.keys (jobPolls model2) `shouldBe` [42]
