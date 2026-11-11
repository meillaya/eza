{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Webhook subscriptions and the signed delivery worker.

One subscription is a URL and a set of event kinds. The worker is per database:
'runWebhookWorker' opens the database it is given, fans committed outbox rows
out into deliveries (idempotently, via the UNIQUE(webhook_id, event_id) guard
and the persistent @app_state.event_cursor@), then posts each due delivery with
an HMAC-SHA256 signature and exponential backoff. A terminal failure disables
the subscription so a dead receiver cannot be retried forever.

The worker takes an explicit database path and HTTP manager, so M3 can start
one worker per user database without touching this module.
-}
module Eza.Webhooks (
    WebhookError (..),
    webhookErrorStatus,
    webhookErrorCode,
    webhookErrorMessage,
    listWebhooks,
    getWebhook,
    createWebhook,
    updateWebhook,
    deleteWebhook,
    listDeliveries,
    testWebhook,
    WebhookWorkerConfig (..),
    defaultWebhookWorkerConfig,
    runWebhookWorker,
    dispatchNewEvents,
    processPendingDeliveries,
    resetDeliveringDeliveries,
    purgeExpired,
    signWebhook,
) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, void, when)
import Crypto.Hash (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac, hmacGetDigest)
import Crypto.Random (getRandomBytes)
import Data.Aeson (Value, eitherDecodeStrict', encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.List (nub)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import Network.HTTP.Client (Manager)

import Eza.Config (Config (..))
import qualified Eza.Db as Db
import Eza.Fetch
import Eza.Webhook

-- ------------------------------------------------------------------ errors ---

data WebhookError
    = WebhookInvalid [Text]
    | WebhookNotFound
    | WebhookLimit
    deriving (Show, Eq)

webhookErrorStatus :: WebhookError -> Int
webhookErrorStatus err = case err of
    WebhookInvalid _ -> 400
    WebhookNotFound -> 404
    WebhookLimit -> 409

webhookErrorCode :: WebhookError -> Text
webhookErrorCode err = case err of
    WebhookInvalid _ -> "bad_request"
    WebhookNotFound -> "not_found"
    WebhookLimit -> "webhook_limit"

webhookErrorMessage :: WebhookError -> Text
webhookErrorMessage err = case err of
    WebhookInvalid messages -> T.intercalate "; " messages
    WebhookNotFound -> "webhook not found"
    WebhookLimit -> "at most " <> T.pack (show maxWebhooks) <> " webhooks are allowed"

-- -------------------------------------------------------------------- rows ---

data WebhookRow = WebhookRow
    { wrId :: Int
    , wrName :: Text
    , wrUrl :: Text
    , wrSecret :: Text
    , wrEventsJson :: Text
    , wrEnabled :: Int
    , wrCreatedAt :: Int
    , wrLastStatus :: Maybe Int
    , wrLastAttemptAt :: Maybe Int
    , wrLastError :: Text
    , wrFailStreak :: Int
    }

instance FromRow WebhookRow where
    fromRow =
        WebhookRow
            <$> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field

webhookColumns :: Text
webhookColumns =
    "id, name, url, secret, events_json, enabled, created_at, last_status, last_attempt_at, last_error, fail_streak"

webhookFromRow :: WebhookRow -> Maybe Webhook
webhookFromRow row = do
    events <- either (const Nothing) Just (eitherDecodeStrict' (TE.encodeUtf8 (wrEventsJson row))) :: Maybe [Text]
    parsed <- traverse parseEventType events
    pure
        Webhook
            { whId = wrId row
            , whName = wrName row
            , whUrl = wrUrl row
            , whEvents = parsed
            , whEnabled = wrEnabled row /= 0
            , whCreatedAt = wrCreatedAt row
            , whLastStatus = wrLastStatus row
            , whLastAttemptAt = wrLastAttemptAt row
            , whLastError = wrLastError row
            , whFailStreak = wrFailStreak row
            }

nowEpoch :: IO Int
nowEpoch = floor <$> getPOSIXTime

-- --------------------------------------------------------------- reading ---

listWebhooks :: Connection -> IO [Webhook]
listWebhooks conn = do
    rows <-
        query_
            conn
            (Query ("SELECT " <> webhookColumns <> " FROM webhooks ORDER BY id ASC")) ::
            IO [WebhookRow]
    pure (mapMaybe webhookFromRow rows)

getWebhook :: Connection -> Int -> IO (Maybe Webhook)
getWebhook conn webhookId = do
    row <- getWebhookRow conn webhookId
    pure (row >>= webhookFromRow)

getWebhookRow :: Connection -> Int -> IO (Maybe WebhookRow)
getWebhookRow conn webhookId = do
    rows <-
        query
            conn
            (Query ("SELECT " <> webhookColumns <> " FROM webhooks WHERE id = ?"))
            (Only webhookId) ::
            IO [WebhookRow]
    pure (firstRow rows)
  where
    firstRow (row : _) = Just row
    firstRow [] = Nothing

{- | The recent deliveries of one subscription. The delivery row keeps the
event kind it was fanned out for (schema v14), so a LEFT JOIN is enough: the
event row may have been purged after its 30-day window while the delivery
history is kept, and the row still names the event it carried.
-}
listDeliveries :: Connection -> Int -> Int -> IO [DeliveryView]
listDeliveries conn webhookId limit = do
    let bounded = max 1 (min 100 limit)
    rows <-
        query
            conn
            "SELECT d.id, COALESCE(e.kind, d.event_kind), d.state, d.attempts, d.last_error, d.created_at \
            \FROM webhook_deliveries d LEFT JOIN event_log e ON e.id = d.event_id \
            \WHERE d.webhook_id = ? ORDER BY d.id DESC LIMIT ?"
            (webhookId, bounded) ::
            IO [(Int, Text, Text, Int, Text, Int)]
    -- A delivery written before v14 whose event was already purged has no kind
    -- anywhere; it cannot be rendered as an EventType and is skipped.
    pure (mapMaybe deliveryOfRow rows)
  where
    deliveryOfRow (deliveryId, kindText, state, attempts, lastError, createdAt) = do
        eventType <- parseEventType kindText
        pure
            DeliveryView
                { dvId = deliveryId
                , dvEvent = eventType
                , dvState = state
                , dvAttempts = attempts
                , dvLastError = lastError
                , dvCreatedAt = createdAt
                }

-- -------------------------------------------------------------- mutations ---

createWebhook :: Connection -> WebhookInput -> IO (Either WebhookError (Webhook, Text))
createWebhook conn input =
    case validateWebhookInput input of
        Left messages -> pure (Left (WebhookInvalid messages))
        Right () -> do
            count <- countWebhooks conn
            if count >= maxWebhooks
                then pure (Left WebhookLimit)
                else do
                    secret <- randomSecret
                    now <- nowEpoch
                    execute
                        conn
                        "INSERT INTO webhooks (name, url, secret, events_json, enabled, created_at) VALUES (?,?,?,?,?,?)"
                        ( T.strip (wiName input)
                        , T.strip (wiUrl input)
                        , secret
                        , encodeEventsJson (wiEvents input)
                        , wiEnabled input
                        , now
                        )
                    webhookId <- fromIntegral <$> lastInsertRowId conn
                    created <- getWebhook conn webhookId
                    pure $ case created of
                        Just webhook -> Right (webhook, secret)
                        Nothing -> Left WebhookNotFound

countWebhooks :: Connection -> IO Int
countWebhooks conn = do
    rows <- query_ conn "SELECT COUNT(*) FROM webhooks" :: IO [Only Int]
    pure (case rows of [Only n] -> n; _ -> 0)

updateWebhook :: Connection -> Int -> WebhookInput -> IO (Either WebhookError Webhook)
updateWebhook conn webhookId input =
    case validateWebhookInput input of
        Left messages -> pure (Left (WebhookInvalid messages))
        Right () -> do
            existing <- getWebhook conn webhookId
            case existing of
                Nothing -> pure (Left WebhookNotFound)
                Just _ -> do
                    execute
                        conn
                        "UPDATE webhooks SET name = ?, url = ?, events_json = ?, enabled = ? WHERE id = ?"
                        ( T.strip (wiName input)
                        , T.strip (wiUrl input)
                        , encodeEventsJson (wiEvents input)
                        , wiEnabled input
                        , webhookId
                        )
                    updated <- getWebhook conn webhookId
                    pure $ case updated of
                        Just webhook -> Right webhook
                        Nothing -> Left WebhookNotFound

deleteWebhook :: Connection -> Int -> IO Bool
deleteWebhook conn webhookId = do
    existing <- getWebhookRow conn webhookId
    case existing of
        Nothing -> pure False
        Just _ -> do
            execute conn "DELETE FROM webhooks WHERE id = ?" (Only webhookId)
            pure True

encodeEventsJson :: [EventType] -> Text
encodeEventsJson events = TE.decodeUtf8 (LBS.toStrict (encode (map eventTypeText (nub events))))

{- | @POST /api/v1/webhooks/<id>/test@: post one synthetic bookmark.updated
envelope to the subscription and record the result like a real delivery.
-}
testWebhook :: WebhookWorkerConfig -> Connection -> Int -> IO (Either WebhookError (Bool, Maybe Int, Text))
testWebhook cfg conn webhookId = do
    row <- getWebhookRow conn webhookId
    case row of
        Nothing -> pure (Left WebhookNotFound)
        Just webhook -> do
            now <- nowEpoch
            let envelope =
                    EventEnvelope
                        { eeId = "evt-test"
                        , eeType = BookmarkUpdated
                        , eeOccurredAt = now
                        , eeData = object ["test" .= True]
                        }
                body = LBS.toStrict (encode envelope)
                timestamp = T.pack (show now)
                headers =
                    [ ("X-Eza-Event", TE.encodeUtf8 (eventBodyType envelope))
                    , ("X-Eza-Delivery", "test")
                    , ("X-Eza-Timestamp", TE.encodeUtf8 timestamp)
                    , ("X-Eza-Signature", TE.encodeUtf8 (signWebhook (wrSecret webhook) timestamp (TE.decodeUtf8 body)))
                    ]
            outcome <-
                postJson
                    (webhookFetchOptions cfg)
                    (wrUrl webhook)
                    headers
                    body
            case outcome of
                Right status -> do
                    recordWebhookSuccess conn webhookId status now
                    pure (Right (True, Just status, ""))
                Left err -> do
                    let message = fetchErrorText err
                        status = httpStatusOf err
                    recordWebhookFailure conn webhookId status now message (wrFailStreak webhook + 1)
                    pure (Right (False, status, message))
  where
    eventBodyType envelope = eventTypeText (eeType envelope)

-- --------------------------------------------------------------- delivery ---

{- | One database's delivery worker settings. The database path is explicit so
M3 can start a worker per user database. Tests build this directly with a short
timeout, the private-network guard off, and a zero backoff.
-}
data WebhookWorkerConfig = WebhookWorkerConfig
    { wwcDatabase :: FilePath
    , wwcManager :: Manager
    , wwcTimeoutMs :: Int
    , wwcAllowPrivate :: Bool
    , wwcPollMicros :: Int
    , wwcMaxAttempts :: Int
    , wwcBackoffBaseSeconds :: Int
    , wwcMaxBodyBytes :: Int
    }

defaultWebhookWorkerConfig :: Config -> Manager -> WebhookWorkerConfig
defaultWebhookWorkerConfig cfg manager =
    WebhookWorkerConfig
        { wwcDatabase = cfgDbPath cfg
        , wwcManager = manager
        , wwcTimeoutMs = cfgFetchTimeoutMs cfg
        , wwcAllowPrivate = cfgAllowPrivateFetch cfg
        , wwcPollMicros = 1000000
        , wwcMaxAttempts = deliveryMaxAttempts
        , wwcBackoffBaseSeconds = deliveryBackoffBaseSeconds
        , wwcMaxBodyBytes = deliveryBodyBytes
        }

deliveryMaxAttempts :: Int
deliveryMaxAttempts = 5

deliveryBackoffBaseSeconds :: Int
deliveryBackoffBaseSeconds = 30

deliveryBodyBytes :: Int
deliveryBodyBytes = 64 * 1024

purgeAfterSeconds :: Int
purgeAfterSeconds = 30 * 86400

runWebhookWorker :: WebhookWorkerConfig -> IO ()
runWebhookWorker cfg = do
    conn <- Db.openDb (wwcDatabase cfg)
    resetDeliveringDeliveries conn
    loop conn (0 :: Int)
  where
    loop conn tick = do
        dispatchAll conn
        void (processPendingDeliveries cfg conn)
        when (tick `mod` 60 == 0) (purgeExpired conn)
        threadDelay (wwcPollMicros cfg)
        loop conn (tick + 1)
    dispatchAll conn = do
        dispatched <- dispatchNewEvents conn
        when (dispatched > 0) (dispatchAll conn)

-- | Recover deliveries that were mid-flight when the process stopped.
resetDeliveringDeliveries :: Connection -> IO ()
resetDeliveringDeliveries conn =
    execute_ conn "UPDATE webhook_deliveries SET state = 'queued' WHERE state = 'delivering'"

{- | Fan out every committed outbox row past the cursor into queued deliveries.
Idempotent: the UNIQUE guard ignores duplicates and the cursor advances in the
same transaction as the fan-out.
-}
dispatchNewEvents :: Connection -> IO Int
dispatchNewEvents conn =
    withImmediateTransaction conn $ do
        cursorRows <- query_ conn "SELECT event_cursor FROM app_state WHERE id = 1" :: IO [Only Int]
        let cursor = case cursorRows of [Only value] -> value; _ -> 0
        events <-
            query
                conn
                "SELECT id, kind FROM event_log WHERE id > ? ORDER BY id ASC LIMIT 200"
                (Only cursor) ::
                IO [(Int, Text)]
        case events of
            [] -> pure 0
            _ -> do
                hooks <-
                    query_
                        conn
                        "SELECT id, events_json FROM webhooks WHERE enabled = 1" ::
                        IO [(Int, Text)]
                now <- nowEpoch
                forM_ events $ \(eventId, kindText) ->
                    forM_ hooks $ \(webhookId, eventsJson) ->
                        when (eventMatches kindText eventsJson) $
                            execute
                                conn
                                "INSERT OR IGNORE INTO webhook_deliveries (webhook_id, event_id, event_kind, state, attempts, available_at, created_at) VALUES (?,?,?,'queued',0,?,?)"
                                (webhookId, eventId, kindText, now, now)
                let lastId = maximum (map fst events)
                execute conn "UPDATE app_state SET event_cursor = ? WHERE id = 1" (Only lastId)
                pure (length events)
  where
    eventMatches kindText eventsJson =
        case either (const Nothing) Just (eitherDecodeStrict' (TE.encodeUtf8 eventsJson)) :: Maybe [Text] of
            Nothing -> False
            Just events -> kindText `elem` events

{- | Attempt every delivery that is due, up to a bounded batch. Returns the
number of attempts made. Tests call this directly; the worker calls it once
per poll.
-}
processPendingDeliveries :: WebhookWorkerConfig -> Connection -> IO Int
processPendingDeliveries cfg conn = go 0
  where
    go attempts
        | attempts >= 25 = pure attempts
        | otherwise = do
            now <- nowEpoch
            claimed <- claimDelivery conn now
            case claimed of
                Nothing -> pure attempts
                Just delivery -> do
                    deliverClaimed cfg conn now delivery
                    go (attempts + 1)

claimDelivery :: Connection -> Int -> IO (Maybe (Int, Int, Int, Int))
claimDelivery conn now =
    withImmediateTransaction conn $ do
        rows <-
            query
                conn
                "SELECT id, webhook_id, event_id, attempts FROM webhook_deliveries \
                \WHERE state = 'queued' AND available_at <= ? ORDER BY available_at ASC, id ASC LIMIT 1"
                (Only now) ::
                IO [(Int, Int, Int, Int)]
        case rows of
            [] -> pure Nothing
            ((deliveryId, webhookId, eventId, attempts) : _) -> do
                execute
                    conn
                    "UPDATE webhook_deliveries SET state = 'delivering', attempts = attempts + 1 WHERE id = ?"
                    (Only deliveryId)
                pure (Just (deliveryId, webhookId, eventId, attempts + 1))

deliverClaimed :: WebhookWorkerConfig -> Connection -> Int -> (Int, Int, Int, Int) -> IO ()
deliverClaimed cfg conn now (deliveryId, webhookId, eventId, attempts) = do
    webhook <- getWebhookRow conn webhookId
    eventRow <- eventFor conn eventId
    case (webhook, eventRow) of
        (Just row, Just (kindText, payloadJson, occurredAt))
            | wrEnabled row /= 0 -> do
                let eventType = fromMaybe BookmarkUpdated (parseEventType kindText)
                    payload =
                        fromMaybe
                            (object [])
                            (either (const Nothing) Just (eitherDecodeStrict' (TE.encodeUtf8 payloadJson)) :: Maybe Value)
                    envelope =
                        EventEnvelope
                            { eeId = "evt-" <> T.pack (show eventId)
                            , eeType = eventType
                            , eeOccurredAt = occurredAt
                            , eeData = payload
                            }
                    body = LBS.toStrict (encode envelope)
                    bodyText = TE.decodeUtf8 body
                    timestamp = T.pack (show now)
                    headers =
                        [ ("X-Eza-Event", TE.encodeUtf8 (eventTypeText eventType))
                        , ("X-Eza-Delivery", TE.encodeUtf8 (T.pack (show deliveryId)))
                        , ("X-Eza-Timestamp", TE.encodeUtf8 timestamp)
                        , ("X-Eza-Signature", TE.encodeUtf8 (signWebhook (wrSecret row) timestamp bodyText))
                        ]
                outcome <-
                    postJson
                        (webhookFetchOptions cfg)
                        (wrUrl row)
                        headers
                        body
                case outcome of
                    Right status -> do
                        recordDeliveryDelivered conn deliveryId
                        recordWebhookSuccess conn webhookId status now
                    Left err -> do
                        let message = fetchErrorText err
                            status = httpStatusOf err
                        if attempts >= wwcMaxAttempts cfg
                            then do
                                recordDeliveryFailed conn deliveryId message
                                recordWebhookFailure conn webhookId status now message (wrFailStreak row + 1)
                                disableWebhook conn webhookId
                            else do
                                recordDeliveryRetry conn deliveryId (now + backoffSeconds cfg attempts) message
                                recordWebhookFailure conn webhookId status now message (wrFailStreak row + 1)
        (Just row, _) -> do
            let reason = if wrEnabled row == 0 then "subscription disabled" else "event missing"
            recordDeliveryFailed conn deliveryId reason
        (Nothing, _) -> recordDeliveryFailed conn deliveryId "subscription missing"

eventFor :: Connection -> Int -> IO (Maybe (Text, Text, Int))
eventFor conn eventId = do
    rows <-
        query
            conn
            "SELECT kind, payload_json, created_at FROM event_log WHERE id = ?"
            (Only eventId) ::
            IO [(Text, Text, Int)]
    pure $ case rows of
        ((kind, payload, createdAt) : _) -> Just (kind, payload, createdAt)
        [] -> Nothing

backoffSeconds :: WebhookWorkerConfig -> Int -> Int
backoffSeconds cfg attempts =
    let base = max 0 (wwcBackoffBaseSeconds cfg)
        factor = 2 ^ max 0 (min 20 (attempts - 1))
     in min 3600 (base * factor)

recordWebhookSuccess :: Connection -> Int -> Int -> Int -> IO ()
recordWebhookSuccess conn webhookId status now =
    execute
        conn
        "UPDATE webhooks SET last_status = ?, last_attempt_at = ?, last_error = '', fail_streak = 0 WHERE id = ?"
        (status, now, webhookId)

recordWebhookFailure :: Connection -> Int -> Maybe Int -> Int -> Text -> Int -> IO ()
recordWebhookFailure conn webhookId status now message failStreak =
    execute
        conn
        "UPDATE webhooks SET last_status = ?, last_attempt_at = ?, last_error = ?, fail_streak = ? WHERE id = ?"
        (status, now, truncateError message, failStreak, webhookId)

disableWebhook :: Connection -> Int -> IO ()
disableWebhook conn webhookId =
    execute conn "UPDATE webhooks SET enabled = 0 WHERE id = ?" (Only webhookId)

recordDeliveryDelivered :: Connection -> Int -> IO ()
recordDeliveryDelivered conn deliveryId =
    execute
        conn
        "UPDATE webhook_deliveries SET state = 'delivered', last_error = '' WHERE id = ?"
        (Only deliveryId)

recordDeliveryFailed :: Connection -> Int -> Text -> IO ()
recordDeliveryFailed conn deliveryId message =
    execute
        conn
        "UPDATE webhook_deliveries SET state = 'failed', last_error = ? WHERE id = ?"
        (truncateError message, deliveryId)

recordDeliveryRetry :: Connection -> Int -> Int -> Text -> IO ()
recordDeliveryRetry conn deliveryId availableAt message =
    execute
        conn
        "UPDATE webhook_deliveries SET state = 'queued', available_at = ?, last_error = ? WHERE id = ?"
        (availableAt, truncateError message, deliveryId)

{- | Delete deliveries and events older than the 30 day retention window. The
delivery history survives the event rows (event_id has no foreign key), and the
delivery row stores the event kind (schema v14) so a purged event does not hide
it from 'listDeliveries'.
-}
purgeExpired :: Connection -> IO ()
purgeExpired conn = do
    now <- nowEpoch
    let cutoff = now - purgeAfterSeconds
    execute conn "DELETE FROM webhook_deliveries WHERE created_at < ? AND state IN ('delivered','failed')" (Only cutoff)
    execute
        conn
        "DELETE FROM event_log WHERE created_at < ? AND id <= (SELECT event_cursor FROM app_state WHERE id = 1)"
        (Only cutoff)

-- --------------------------------------------------------------- signing ---

-- | @sha256=@ plus the lowercase hex HMAC-SHA256 of @timestamp <> "." <> body@.
signWebhook :: Text -> Text -> Text -> Text
signWebhook secret timestamp body =
    "sha256=" <> T.pack (show (hmacGetDigest mac))
  where
    mac :: HMAC SHA256
    mac = hmac (TE.encodeUtf8 secret) (TE.encodeUtf8 (timestamp <> "." <> body))

-- ---------------------------------------------------------------- helpers ---

webhookFetchOptions :: WebhookWorkerConfig -> FetchOptions
webhookFetchOptions cfg =
    anyOptions (wwcManager cfg) (wwcTimeoutMs cfg) (wwcMaxBodyBytes cfg) (wwcAllowPrivate cfg)

fetchErrorText :: FetchError -> Text
fetchErrorText err = case err of
    FetchInvalidUrl url -> "invalid URL: " <> url
    FetchBlocked message -> message
    FetchTooLarge -> "payload too large"
    FetchRedirect -> "redirect not followed"
    FetchHttp code -> "HTTP " <> T.pack (show code)
    FetchNetwork message -> "network error: " <> message
    FetchUnsupported contentType -> "unsupported content type: " <> contentType
    FetchEmpty -> "empty response"

httpStatusOf :: FetchError -> Maybe Int
httpStatusOf err = case err of
    FetchHttp code -> Just code
    _ -> Nothing

truncateError :: Text -> Text
truncateError = T.take 500

randomSecret :: IO Text
randomSecret = do
    bytes <- getRandomBytes 32 :: IO BS.ByteString
    pure (T.pack (concatMap hexByte (BS.unpack bytes)))
  where
    hexByte byte =
        let (high, low) = (byte `div` 16, byte `mod` 16)
         in [hexDigit high, hexDigit low]
    hexDigit value
        | value < 10 = toEnum (fromEnum '0' + fromIntegral value :: Int)
        | otherwise = toEnum (fromEnum 'a' + fromIntegral (value - 10) :: Int)
