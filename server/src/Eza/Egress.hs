{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The per-library egress worker: it claims asynchronous jobs whose payload
names network or subprocess work (page snapshots, the dead-link sweep, AI
suggestions, webhook test deliveries) and executes them outside the request
writer.

Handlers only validate and enqueue; this loop is the only place these kinds of
egress happen for the converted routes. The worker bounds its own network work
with the process-wide enrichment semaphore and checks the job's cancellation
flag before it starts.
-}
module Eza.Egress (
    runEgressWorkerFor,
    processOneJob,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.QSem (QSem, signalQSem, waitQSem)
import Control.Exception (SomeException, bracket, bracket_, try)
import Control.Monad (forM)
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
import Eza.Snapshot (captureSnapshot)
import Eza.Webhooks (defaultWebhookWorkerConfig, testWebhook)

-- | The kinds this worker owns; enrichment has its own loops.
egressKinds :: [Text]
egressKinds = ["snapshot", "check_dead", "ai_suggestions", "webhook_test"]

{- | One loop per library. It opens its own connection and closes it on
cancellation, like the other worker loops.
-}
runEgressWorkerFor :: Manager -> Config -> FilePath -> FilePath -> QSem -> IO ()
runEgressWorkerFor manager cfg dbPath snapshotDirectory sem =
    bracket (Db.openDb dbPath) Db.closeDb loop
  where
    loop conn = do
        claimed <- forM egressKinds (claimJobKind conn)
        case firstJust claimed of
            Nothing -> threadDelay (2 * 1000000) >> loop conn
            Just job -> do
                cancelled <- jobCancelRequested conn (jobId job)
                if cancelled
                    then cancelJob conn (jobId job)
                    else do
                        outcome <- try (bracket_ (waitQSem sem) (signalQSem sem) (processOneJob manager cfg snapshotDirectory conn job)) :: IO (Either SomeException ())
                        case outcome of
                            Left err -> failJobPermanent conn (jobId job) (T.take 400 (T.pack (show err)))
                            Right () -> pure ()
                loop conn

firstJust :: [Maybe a] -> Maybe a
firstJust (Just value : _) = Just value
firstJust (Nothing : rest) = firstJust rest
firstJust [] = Nothing

{- | Execute one claimed job and record its outcome: a JSON result on success, a
permanent failure on deterministic errors (refused URL, missing provider key,
missing webhook). Exposed for the job lifecycle tests.
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
                    Nothing -> failJobPermanent conn (jobId job) "the snapshot could not be captured"
                    Just (_, name) -> do
                        let path = snapshotDirectory </> T.unpack name
                        sized <- try (getFileSize path) :: IO (Either SomeException Integer)
                        case sized of
                            Left _ -> failJobPermanent conn (jobId job) "the snapshot file is missing"
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
            Left message -> failJobPermanent conn (jobId job) message
            Right suggestions ->
                completeJobResult conn (jobId job) (object ["suggestions" .= suggestions])

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
