{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The per-library egress worker: it claims asynchronous jobs whose payload
names network or subprocess work (page snapshots, the dead-link sweep, AI
suggestions, webhook test deliveries) and executes them outside the request
writer.

Handlers only validate and enqueue; this loop is the only place these kinds of
egress happen for the converted routes. The worker bounds its own network work
with the process-wide enrichment semaphore and checks the job's cancellation
flag before it starts. A job-level exception is retried with the bounded backoff
from "Eza.Jobs" instead of failing on one attempt; on its idle tick the loop
requeues jobs abandoned @running@ by a dead worker and prunes old terminal jobs.
-}
module Eza.Egress (
    claimNextEgressJob,
    runEgressWorkerFor,
    processOneJob,
    runClaimedJob,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (AsyncCancelled)
import Control.Concurrent.QSem (QSem, signalQSem, waitQSem)
import Control.Exception (AsyncException, SomeException, bracket, bracket_, fromException, tryJust)
import Control.Monad (void, when)
import Data.Aeson (Key, Object, Value (..), decode, object, (.=))
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple (Connection)
import Network.HTTP.Client (Manager)
import System.Directory (getFileSize)
import System.FilePath ((</>))

import Eza.AiTag (aiSuggestionsForScope)
import Eza.Config (Config (..))
import qualified Eza.Db as Db
import Eza.DeadLinks (checkDead)
import Eza.Jobs
import Eza.Snapshot (SnapshotOutcome (..), captureSnapshot)
import Eza.Webhooks (defaultWebhookWorkerConfig, testWebhook)

-- | The kinds this worker owns; enrichment has its own loops.
egressKinds :: [Text]
egressKinds = ["snapshot", "check_dead", "ai_suggestions", "webhook_test"]

{- | A @running@ row untouched for this long belongs to a worker that died
mid-flight (all legitimate jobs are bounded by the fetch/process timeouts).
-}
staleJobSeconds :: Int
staleJobSeconds = 15 * 60

-- | Idle egress ticks between stale-job sweeps (2 s per tick, so once a minute).
staleSweepTicks :: Int
staleSweepTicks = 30

{- | Claim at most one ready egress job. Kinds are tried in priority order and
the first successful claim wins: one loop iteration executes exactly one job, so
the other kinds are never flipped to @running@ and abandoned (which used to
strand them, and their dedupe keys, until the next process restart). Exported for
the job-queue regression test.
-}
claimNextEgressJob :: Connection -> IO (Maybe Job)
claimNextEgressJob conn = go egressKinds
  where
    go [] = pure Nothing
    go (kind : rest) = do
        claimed <- claimJobKind conn kind
        case claimed of
            Just _ -> pure claimed
            Nothing -> go rest

{- | One loop per library. It opens its own connection and closes it on
cancellation, like the other worker loops.
-}
runEgressWorkerFor :: Manager -> Config -> FilePath -> FilePath -> QSem -> IO ()
runEgressWorkerFor manager cfg dbPath snapshotDirectory sem =
    bracket (Db.openDb dbPath) Db.closeDb (\conn -> loop conn 0)
  where
    loop conn tick = do
        claimed <- claimNextEgressJob conn
        case claimed of
            Nothing -> do
                when (tick `mod` staleSweepTicks == 0) $
                    void (requeueStaleJobs conn staleJobSeconds)
                threadDelay (2 * 1000000)
                loop conn (tick + 1)
            Just job -> do
                cancelled <- jobCancelRequested conn (jobId job)
                if cancelled
                    then cancelJob conn (jobId job)
                    else runClaimedJob manager cfg snapshotDirectory conn sem job
                cleanupJobs conn
                loop conn (tick + 1)

{- | Execute one already-claimed job. An escaping exception is not a
deterministic handler verdict (those are returned by 'processOneJob'), so it is
recorded through the bounded retry/backoff path instead of failing the job on
its first attempt. Exported for the retry regression test.
-}
runClaimedJob :: Manager -> Config -> FilePath -> Connection -> QSem -> Job -> IO ()
runClaimedJob manager cfg snapshotDirectory conn sem job = do
    outcome <- tryNonAsync (bracket_ (waitQSem sem) (signalQSem sem) (processOneJob manager cfg snapshotDirectory conn job)) :: IO (Either SomeException ())
    case outcome of
        Left err -> retryJob conn job (T.take 400 (T.pack (show err)))
        Right () -> pure ()

-- | Record a failed attempt through the bounded retry/backoff path.
retryJob :: Connection -> Job -> Text -> IO ()
retryJob conn job message = failJob conn (jobId job) message (jobAttempts job)

{- | Run an action and catch synchronous failures only: asynchronous exceptions
(worker cancellation) are rethrown, so a cancel stops the loop instead of being
swallowed and recorded as a permanent job failure. @AsyncCancelled@ is not an
@AsyncException@ subtype, so both are checked.
-}
tryNonAsync :: IO a -> IO (Either SomeException a)
tryNonAsync action = tryJust isSyncFailure action
  where
    isSyncFailure err
        | isAsync err = Nothing
        | otherwise = Just err
    isAsync err = case fromException err :: Maybe AsyncException of
        Just _ -> True
        Nothing -> case fromException err :: Maybe AsyncCancelled of
            Just _ -> True
            Nothing -> False

{- | Execute one claimed job and record its outcome: a JSON result on success, a
permanent failure on deterministic errors (refused URL, missing provider key,
missing webhook), and a bounded retry when the failure may clear up on a later
attempt. Exposed for the job lifecycle tests.
-}
processOneJob :: Manager -> Config -> FilePath -> Connection -> Job -> IO ()
processOneJob manager cfg snapshotDirectory conn job = case jobKind job of
    "snapshot" -> snapshotJob
    "check_dead" -> checkDeadJob
    "ai_suggestions" -> aiJob
    "webhook_test" -> webhookJob
    _ -> failJobPermanent conn (jobId job) ("unknown egress job kind: " <> jobKind job)
  where
    payload = decodePayload (jobPayload job)

    snapshotJob = do
        let bookmarkId = fromMaybe 0 (intField "bookmark_id" payload)
        if bookmarkId <= 0
            then failJobPermanent conn (jobId job) "snapshot job has no bookmark_id"
            else do
                captured <- captureSnapshot cfg snapshotDirectory conn bookmarkId
                case captured of
                    -- Deterministic refusals (unknown bookmark, policy, size cap)
                    -- are terminal; transient tool failures use the bounded retry.
                    SnapshotRefused message ->
                        failJobPermanent conn (jobId job) ("the snapshot could not be captured: " <> message)
                    SnapshotUnavailable message ->
                        retryJob conn job ("the snapshot could not be captured: " <> message)
                    SnapshotCaptured _ name -> do
                        let path = snapshotDirectory </> T.unpack name
                        sized <- tryNonAsync (getFileSize path) :: IO (Either SomeException Integer)
                        case sized of
                            Left _ -> retryJob conn job "the snapshot file is missing"
                            Right bytes ->
                                completeJobResult
                                    conn
                                    (jobId job)
                                    (object ["snapshot" .= object ["path" .= T.pack path, "bytes" .= bytes]])

    checkDeadJob = do
        cancelled <- jobCancelRequested conn (jobId job)
        if cancelled
            then cancelJob conn (jobId job)
            else do
                let limit = fromMaybe 500 (intField "limit" payload)
                    older = fromMaybe 0 (intField "older_than" payload)
                    includeDead = boolField "include_dead" payload
                (checked, dead, _, _) <- checkDead conn limit older includeDead
                completeJobResult conn (jobId job) (object ["checked" .= checked, "dead" .= dead])

    aiJob = do
        let scope = textField "tag" payload
        result <-
            aiSuggestionsForScope
                (T.pack (cfgAiProvider cfg))
                (T.pack (cfgAiModel cfg))
                (T.pack (cfgOllamaBaseUrl cfg))
                conn
                scope
                20
        case result of
            Left message
                -- Provider/config errors are deterministic; a provider or
                -- protocol failure may be transient and is retried.
                | deterministicAiFailure message -> failJobPermanent conn (jobId job) message
                | otherwise -> retryJob conn job message
            Right suggestions ->
                completeJobResult conn (jobId job) (object ["suggestions" .= suggestions])

    deterministicAiFailure message =
        "AI tagging is disabled" `T.isPrefixOf` message
            || "AI key is not configured" `T.isPrefixOf` message
            || message == "no bookmarks with that tag"
            || message == "no bookmarks to suggest from"

    webhookJob = do
        let webhookId = fromMaybe 0 (intField "webhook_id" payload)
        if webhookId <= 0
            then failJobPermanent conn (jobId job) "webhook test job has no webhook_id"
            else do
                result <- testWebhook (defaultWebhookWorkerConfig cfg manager) conn webhookId
                case result of
                    Left err -> failJobPermanent conn (jobId job) (T.pack (show err))
                    Right (ok, status, message) ->
                        completeJobResult
                            conn
                            (jobId job)
                            ( object
                                [ "ok" .= ok
                                , "status" .= maybe (0 :: Int) id status
                                , "error" .= if T.null message then Null else String message
                                ]
                            )

decodePayload :: Text -> Object
decodePayload raw = case decode (LBS.fromStrict (TE.encodeUtf8 raw)) of
    Just (Object value) -> value
    _ -> mempty

intField :: Key -> Object -> Maybe Int
intField key value = case KeyMap.lookup key value of
    Just (Number number) -> Just (truncate number)
    _ -> Nothing

textField :: Key -> Object -> Maybe Text
textField key value = case KeyMap.lookup key value of
    Just (String text) -> Just text
    _ -> Nothing

boolField :: Key -> Object -> Bool
boolField key value = case KeyMap.lookup key value of
    Just (Bool flag) -> flag
    _ -> False
