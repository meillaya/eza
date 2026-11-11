{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | M2 extension platform: outbox events, webhook CRUD, signed delivery,
retries and the v10 to v11 migration.
-}
module WebhookSpec (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (forM_)
import Data.Aeson (Value (..), decode, eitherDecodeStrict', encode, object, (.=))
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple (Only (..))
import qualified Database.SQLite.Simple as Sqlite
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.HTTP.Types (HeaderName, mkStatus)
import Network.Socket (Socket)
import qualified Network.Socket as Socket
import Network.Wai (Application, requestHeaders, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (defaultSettings, openFreePort, runSettingsSocket, setBeforeMainLoop)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Eza.Bookmarks (BulkAction (..), bulkUpdate, deleteBookmark, insertBookmark, updateBookmark)
import Eza.Clip (ClipRequest (..), SaveClipResult (..), emptyClipMetadata, saveClip)
import Eza.Db
import Eza.Dedup (mergeBookmarks, mergeUrlDuplicatesAll)
import Eza.Events (recordEvent)
import Eza.Types (DedupMergeAllReport (..))
import Eza.Webhook
import Eza.Webhooks

spec :: Spec
spec = do
    describe "webhook signing" $ do
        it "signs timestamp dot body with lowercase hex HMAC-SHA256" $ do
            signWebhook "0123456789abcdef" "1700000000" "{\"hello\":\"world\"}"
                `shouldBe` "sha256=66997eb7c1d13335f141deda66669e544a2c7f62745300308aec8f7042fb18be"

    describe "webhook CRUD and validation" $ do
        it "creates, lists, updates and deletes subscriptions" $
            withTempDb $ \conn -> do
                (webhook, secret) <- createdHookWithSecret conn "Deploy" [BookmarkCreated] "http://127.0.0.1:9/hook"
                whName webhook `shouldBe` "Deploy"
                whUrl webhook `shouldBe` "http://127.0.0.1:9/hook"
                whEvents webhook `shouldBe` [BookmarkCreated]
                whEnabled webhook `shouldBe` True
                T.length secret `shouldBe` 64
                T.all (`elem` ("0123456789abcdef" :: String)) secret `shouldBe` True
                listed <- listWebhooks conn
                map whId listed `shouldBe` [whId webhook]
                -- The list response never carries the secret.
                TE.decodeUtf8 (LBS.toStrict (encode listed)) `shouldSatisfy` (not . T.isInfixOf secret)
                updated <-
                    updateWebhook
                        conn
                        (whId webhook)
                        (hookInput "Deploy v2" "http://127.0.0.1:9/other" [BookmarkCreated, ClipCreated] False)
                case updated of
                    Left err -> expectationFailure ("update failed: " <> show err)
                    Right value -> do
                        whName value `shouldBe` "Deploy v2"
                        whEvents value `shouldBe` [BookmarkCreated, ClipCreated]
                        whEnabled value `shouldBe` False
                deleteWebhook conn (whId webhook) `shouldReturn` True
                deleteWebhook conn (whId webhook) `shouldReturn` False
                listWebhooks conn `shouldReturn` []

        it "validates the input and caps the subscription count" $
            withTempDb $ \conn -> do
                blankName <- createWebhook conn (hookInput " " "http://example.test/h" [BookmarkCreated] True)
                blankName `shouldSatisfy` isWebhookInvalid
                badUrl <- createWebhook conn (hookInput "Name" "ftp://example.test/h" [BookmarkCreated] True)
                badUrl `shouldSatisfy` isWebhookInvalid
                noEvents <- createWebhook conn (hookInput "Name" "http://example.test/h" [] True)
                noEvents `shouldSatisfy` isWebhookInvalid
                forM_ [1 .. maxWebhooks] $ \index -> do
                    result <-
                        createWebhook conn (hookInput (T.pack ("Hook " <> show (index :: Int))) "http://example.test/h" [BookmarkCreated] True)
                    result `shouldSatisfy` isWebhookCreated
                createWebhook conn (hookInput "One too many" "http://example.test/h" [BookmarkCreated] True)
                    `shouldReturn` Left WebhookLimit

    describe "event outbox" $ do
        it "writes one event per committed bookmark write and none for no-ops" $
            withTempDb $ \conn -> do
                _ <- insertBookmark conn "https://example.test/created" "Created" ["rust"]
                eventKinds conn `shouldReturn` ["bookmark.created"]
                firstId <- singleBookmarkId conn
                payload <- eventPayloadAt conn 1
                payload `shouldSatisfy` hasField "url" "https://example.test/created"
                payload `shouldSatisfy` hasField "title" "Created"
                payload `shouldSatisfy` hasField "domain" "example.test"
                -- A patch with no supplied fields records nothing.
                _ <- updateBookmark conn firstId Nothing Nothing Nothing Nothing
                length <$> eventKinds conn `shouldReturn` 1
                -- A real patch records bookmark.updated.
                _ <- updateBookmark conn firstId (Just "Renamed") Nothing Nothing Nothing
                kindsAfterUpdate <- eventKinds conn
                length kindsAfterUpdate `shouldBe` 2
                last kindsAfterUpdate `shouldBe` "bookmark.updated"
                -- Delete records the payload before the row goes away.
                deleteBookmark conn firstId `shouldReturn` True
                kindsAfterDelete <- eventKinds conn
                length kindsAfterDelete `shouldBe` 3
                last kindsAfterDelete `shouldBe` "bookmark.deleted"
                deletedPayload <- eventPayloadAt conn 3
                deletedPayload `shouldSatisfy` hasField "url" "https://example.test/created"

        it "does not leave an event behind when the transaction rolls back" $
            withTempDb $ \conn -> do
                _ <- insertBookmark conn "https://example.test/kept" "Kept" []
                beforeCount <- length <$> eventKinds conn
                outcome <-
                    try
                        ( Sqlite.withImmediateTransaction conn $ do
                            recordEvent conn BookmarkUpdated (object ["id" .= (1 :: Int)])
                            Sqlite.execute_ conn "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES ('duplicate-url','x','x',1,1,1)"
                            Sqlite.execute_ conn "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES ('duplicate-url','x','x',1,1,1)"
                        ) ::
                        IO (Either SomeException ())
                case outcome of
                    Left _ -> pure ()
                    Right () -> expectationFailure "the duplicate insert should fail"
                length <$> eventKinds conn `shouldReturn` beforeCount

        it "records bookmark.updated for bulk tag and mark-read writes" $
            withTempDb $ \conn -> do
                first <- rawBookmark conn "https://example.test/bulk-events-a" "Bulk A"
                second <- rawBookmark conn "https://example.test/bulk-events-b" "Bulk B"
                _ <- bulkUpdate conn (BulkAddTags ["bulk-tag"]) [first]
                _ <- bulkUpdate conn (BulkMarkRead True) [second]
                updatedIds <- eventBookmarkIds conn "bookmark.updated"
                updatedIds `shouldBe` [first, second]

        it "records deleted for absorbed rows and updated for the keeper on a merge" $
            withTempDb $ \conn -> do
                keeper <- rawBookmark conn "http://dup.test/page" "Keeper"
                absorbed <- rawBookmark conn "https://dup.test/page" "Absorbed"
                merged <- mergeBookmarks conn keeper [absorbed]
                merged `shouldBe` 1
                deletedIds <- eventBookmarkIds conn "bookmark.deleted"
                updatedIds <- eventBookmarkIds conn "bookmark.updated"
                deletedIds `shouldBe` [absorbed]
                updatedIds `shouldBe` [keeper]

        it "records deleted and updated rows for merge-all" $
            withTempDb $ \conn -> do
                keeper <- rawBookmark conn "http://dup-all.test/page" "Keeper"
                absorbed <- rawBookmark conn "https://dup-all.test/page" "Absorbed"
                report <- mergeUrlDuplicatesAll conn
                dmGroups report `shouldBe` 1
                deletedIds <- eventBookmarkIds conn "bookmark.deleted"
                updatedIds <- eventBookmarkIds conn "bookmark.updated"
                deletedIds `shouldBe` [absorbed]
                updatedIds `shouldBe` [keeper]

        it "records clip.created once and not again on an idempotent replay" $
            withTempDb $ \conn -> do
                saved <- saveClip conn sampleClip
                result <- case saved of
                    Left err -> expectationFailure ("clip save failed: " <> show err) >> error "unreachable"
                    Right value -> pure value
                eventKinds conn `shouldReturn` ["clip.created"]
                payload <- eventPayloadAt conn 1
                payload `shouldSatisfy` hasField "capture_id" (T.pack (show (scrCaptureId result)))
                payload `shouldSatisfy` hasField "bookmark_id" (T.pack (show (scrBookmarkId result)))
                _ <- saveClip conn sampleClip
                length <$> eventKinds conn `shouldReturn` 1

    describe "dispatch and delivery" $ do
        it "fans out only matching enabled subscriptions and is idempotent" $
            withTempDb $ \conn -> do
                matching <- createdHook conn "Matching" [BookmarkCreated]
                other <- createdHook conn "Other" [ClipCreated]
                disabled <- disabledHook conn
                _ <- insertBookmark conn "https://example.test/a" "A" []
                dispatchNewEvents conn `shouldReturn` 1
                deliveryCount conn matching `shouldReturn` 1
                deliveryCount conn other `shouldReturn` 0
                deliveryCount conn disabled `shouldReturn` 0
                -- Re-dispatching does not duplicate queued deliveries.
                dispatchNewEvents conn `shouldReturn` 0
                deliveryCount conn matching `shouldReturn` 1
                -- A second event adds exactly one more delivery.
                _ <- insertBookmark conn "https://example.test/b" "B" []
                dispatchNewEvents conn `shouldReturn` 1
                deliveryCount conn matching `shouldReturn` 2

        it "delivers a signed event and records success" $
            withReceiver $ \receiver ->
                withTempDb $ \conn -> do
                    (webhook, secret) <- createdHookWithSecret conn "Receiver" [BookmarkCreated] (receiverUrl receiver)
                    _ <- insertBookmark conn "https://example.test/signed" "Signed" ["rust"]
                    dispatchNewEvents conn `shouldReturn` 1
                    cfg <- testConfig
                    processPendingDeliveries cfg conn `shouldReturn` 1
                    delivery <- deliveryView conn (whId webhook)
                    dvState delivery `shouldBe` "delivered"
                    dvAttempts delivery `shouldBe` 1
                    dvEvent delivery `shouldBe` BookmarkCreated
                    refreshed <- webhookOrFail conn (whId webhook)
                    whLastStatus refreshed `shouldBe` Just 200
                    whFailStreak refreshed `shouldBe` 0
                    captured <- capturedRequests receiver
                    case captured of
                        [] -> expectationFailure "expected one delivered request"
                        ((headers, body) : _) -> do
                            lookup "X-Eza-Event" headers `shouldBe` Just "bookmark.created"
                            case lookup "X-Eza-Timestamp" headers of
                                Just timestamp ->
                                    TE.decodeUtf8 timestamp `shouldSatisfy` T.all (`elem` ("0123456789" :: String))
                                Nothing -> expectationFailure "missing X-Eza-Timestamp"
                            case (lookup "X-Eza-Timestamp" headers, lookup "X-Eza-Signature" headers) of
                                (Just timestamp, Just signature) -> do
                                    let expected =
                                            signWebhook secret (TE.decodeUtf8 timestamp) (TE.decodeUtf8 (LBS.toStrict body))
                                    signature `shouldBe` TE.encodeUtf8 expected
                                _ -> expectationFailure "missing signature headers"
                            lookup "X-Eza-Delivery" headers `shouldSatisfy` maybe False (not . BS.null)
                            case decode body of
                                Just (Object objectValue) ->
                                    KeyMap.lookup "type" objectValue `shouldBe` Just (String "bookmark.created")
                                _ -> expectationFailure "the delivery body is not an event envelope"

        it "retries a failing receiver with backoff and disables after the last attempt" $
            withReceiver $ \receiver -> do
                setReceiverStatus receiver 500 99
                withTempDb $ \conn -> do
                    (webhook, _) <- createdHookWithSecret conn "Failing" [BookmarkCreated] (receiverUrl receiver)
                    _ <- insertBookmark conn "https://example.test/retry" "Retry" []
                    dispatchNewEvents conn `shouldReturn` 1
                    cfg <- testConfig
                    -- Attempt 1 fails and stays queued; the base-1 backoff makes
                    -- the next attempt not due yet.
                    processPendingDeliveries cfg conn `shouldReturn` 1
                    afterFirst <- deliveryView conn (whId webhook)
                    dvState afterFirst `shouldBe` "queued"
                    dvAttempts afterFirst `shouldBe` 1
                    afterFirstHook <- webhookOrFail conn (whId webhook)
                    whFailStreak afterFirstHook `shouldBe` 1
                    processPendingDeliveries cfg conn `shouldReturn` 0
                    -- Make it due and burn the remaining attempts.
                    makeDeliveriesDue conn
                    processPendingDeliveries cfg conn `shouldReturn` 1
                    makeDeliveriesDue conn
                    processPendingDeliveries cfg conn `shouldReturn` 1
                    failed <- deliveryView conn (whId webhook)
                    dvState failed `shouldBe` "failed"
                    dvAttempts failed `shouldBe` 3
                    disabled <- webhookOrFail conn (whId webhook)
                    whEnabled disabled `shouldBe` False
                    whLastStatus disabled `shouldBe` Just 500
                    whLastError disabled `shouldSatisfy` T.isInfixOf "500"
                    whFailStreak disabled `shouldBe` 3
                    -- A disabled subscription is no longer attempted and gets
                    -- no deliveries for new events.
                    processPendingDeliveries cfg conn `shouldReturn` 0
                    _ <- insertBookmark conn "https://example.test/retry2" "Retry2" []
                    dispatchNewEvents conn `shouldReturn` 1
                    deliveryCount conn (whId webhook) `shouldReturn` 1

        it "does not follow receiver redirects" $
            withReceiver $ \receiver -> do
                setReceiverStatus receiver 302 1
                withTempDb $ \conn -> do
                    (webhook, _) <- createdHookWithSecret conn "Redirect" [BookmarkCreated] (receiverUrl receiver)
                    _ <- insertBookmark conn "https://example.test/redirect" "Redirect" []
                    dispatchNewEvents conn `shouldReturn` 1
                    cfg <- testConfig
                    processPendingDeliveries cfg conn `shouldReturn` 1
                    delivery <- deliveryView conn (whId webhook)
                    dvLastError delivery `shouldSatisfy` T.isInfixOf "redirect"

        it "records the result of a webhook test request" $
            withReceiver $ \receiver ->
                withTempDb $ \conn -> do
                    (webhook, _) <- createdHookWithSecret conn "Test hook" [BookmarkCreated] (receiverUrl receiver)
                    cfg <- testConfig
                    testWebhook cfg conn (whId webhook) `shouldReturn` Right (True, Just 200, "")
                    captured <- capturedRequests receiver
                    case captured of
                        [] -> expectationFailure "expected the test request"
                        ((headers, body) : _) -> do
                            lookup "X-Eza-Event" headers `shouldBe` Just "bookmark.updated"
                            lookup "X-Eza-Delivery" headers `shouldBe` Just "test"
                            LBS.toStrict body `shouldSatisfy` BS.isInfixOf "\"test\":true"
                    refreshed <- webhookOrFail conn (whId webhook)
                    whLastStatus refreshed `shouldBe` Just 200

    describe "delivery listing" $ do
        it "returns the most recent deliveries for one hook with a bounded limit" $
            withReceiver $ \receiver ->
                withTempDb $ \conn -> do
                    (webhook, _) <- createdHookWithSecret conn "Listing" [BookmarkCreated] (receiverUrl receiver)
                    _ <- insertBookmark conn "https://example.test/one" "One" []
                    _ <- insertBookmark conn "https://example.test/two" "Two" []
                    dispatchNewEvents conn `shouldReturn` 2
                    cfg <- testConfig
                    processPendingDeliveries cfg conn `shouldReturn` 2
                    deliveries <- listDeliveries conn (whId webhook) 1
                    length deliveries `shouldBe` 1
                    case deliveries of
                        (delivery : _) -> dvState delivery `shouldBe` "delivered"
                        [] -> expectationFailure "expected one delivery"
                    length <$> listDeliveries conn (whId webhook) 20 `shouldReturn` 2

    describe "migration v12" $ do
        it "migrates a v11 database to v12 and preserves its rows" $
            withSystemTempDirectory "eza-webhook-migrate" $ \dir -> do
                let path = dir </> "test.db"
                bracket (Sqlite.open path) Sqlite.close $ \conn -> do
                    mapM_
                        (Sqlite.execute_ conn)
                        ( schemaV1
                            <> schemaV2
                            <> schemaV3
                            <> schemaV4
                            <> schemaV5
                            <> schemaV6
                            <> schemaV7
                            <> schemaV8
                            <> schemaV9
                            <> schemaV10
                            <> schemaV11
                        )
                    Sqlite.execute_ conn "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES ('https://example.test/v11','V11','example.test',1,1,1)"
                    Sqlite.execute_ conn "INSERT INTO views (slug,name,kind,definition_json,is_default,created_at,updated_at) VALUES ('v11','V11','graph','{}',1,1,1)"
                    Sqlite.execute_ conn "INSERT INTO captures (bookmark_id,url,captured_at,created_at) VALUES (1,'https://example.test/v11',1,1)"
                    Sqlite.execute_ conn "PRAGMA user_version = 11"
                migrated <- openDb path
                version <- schemaVersion migrated
                version `shouldBe` targetSchemaVersion
                queryScalar migrated "SELECT COUNT(*) FROM bookmarks" `shouldReturn` (1 :: Int)
                queryScalar migrated "SELECT COUNT(*) FROM views" `shouldReturn` (1 :: Int)
                queryScalar migrated "SELECT COUNT(*) FROM captures" `shouldReturn` (1 :: Int)
                tables <- tableNames migrated
                mapM_ (\name -> name `elem` tables `shouldBe` True) ["event_log", "webhooks", "webhook_deliveries", "undo_capture_rows"]
                queryScalar migrated "SELECT event_cursor FROM app_state WHERE id = 1" `shouldReturn` (0 :: Int)
                Sqlite.close migrated

    describe "delivery history retention" $ do
        it "keeps a delivery readable after its event row is purged" $
            withTempDb $ \conn -> do
                webhookId <- createdHook conn "History" [BookmarkCreated]
                _ <- insertBookmark conn "https://example.test/history" "History" []
                dispatchNewEvents conn `shouldReturn` 1
                firstDelivery <- deliveryView conn webhookId
                dvEvent firstDelivery `shouldBe` BookmarkCreated
                dvState firstDelivery `shouldBe` "queued"
                -- Age the outbox row past the 30-day window and purge it. The
                -- delivery row is kept (only terminal deliveries are pruned)
                -- and has to stay readable with the kind it was created with.
                Sqlite.execute_ conn "UPDATE event_log SET created_at = 0"
                purgeExpired conn
                eventKinds conn `shouldReturn` []
                deliveries <- listDeliveries conn webhookId 20
                length deliveries `shouldBe` 1
                case deliveries of
                    (deliveryAfterPurge : _) -> do
                        dvEvent deliveryAfterPurge `shouldBe` BookmarkCreated
                        dvState deliveryAfterPurge `shouldBe` "queued"
                    [] -> expectationFailure "expected the delivery history to survive the purge"

-- ---------------------------------------------------------------- fixtures ---

withTempDb :: (Sqlite.Connection -> IO a) -> IO a
withTempDb action = withSystemTempDirectory "eza-webhook" $ \dir -> do
    conn <- openDb (dir </> "test.db")
    bracket (pure conn) Sqlite.close action

hookInput :: Text -> Text -> [EventType] -> Bool -> WebhookInput
hookInput name url events enabled =
    WebhookInput{wiName = name, wiUrl = url, wiEvents = events, wiEnabled = enabled}

testConfig :: IO WebhookWorkerConfig
testConfig = do
    manager <- newManager defaultManagerSettings
    pure
        WebhookWorkerConfig
            { wwcDatabase = ":memory:"
            , wwcManager = manager
            , wwcTimeoutMs = 2000
            , wwcAllowPrivate = True
            , wwcPollMicros = 1000
            , wwcMaxAttempts = 3
            , wwcBackoffBaseSeconds = 1
            , wwcMaxBodyBytes = 64 * 1024
            }

createdHook :: Sqlite.Connection -> Text -> [EventType] -> IO Int
createdHook conn name events = do
    (webhook, _) <- createdHookWithSecret conn name events "http://127.0.0.1:9/hook"
    pure (whId webhook)

createdHookWithSecret :: Sqlite.Connection -> Text -> [EventType] -> Text -> IO (Webhook, Text)
createdHookWithSecret conn name events url = do
    created <- createWebhook conn (hookInput name url events True)
    case created of
        Right value -> pure value
        Left err -> expectationFailure ("create failed: " <> show err) >> error "unreachable"

disabledHook :: Sqlite.Connection -> IO Int
disabledHook conn = do
    created <- createWebhook conn (hookInput "Disabled" "http://127.0.0.1:9/hook" [BookmarkCreated] False)
    case created of
        Right (webhook, _) -> pure (whId webhook)
        Left err -> expectationFailure ("disabled create failed: " <> show err) >> error "unreachable"

deliveryCount :: Sqlite.Connection -> Int -> IO Int
deliveryCount conn webhookId = do
    rows <- Sqlite.query conn "SELECT COUNT(*) FROM webhook_deliveries WHERE webhook_id = ?" (Only webhookId) :: IO [Only Int]
    pure (case rows of [Only n] -> n; _ -> 0)

deliveryView :: Sqlite.Connection -> Int -> IO DeliveryView
deliveryView conn webhookId = do
    deliveries <- listDeliveries conn webhookId 20
    case deliveries of
        (delivery : _) -> pure delivery
        [] -> expectationFailure "expected a delivery" >> error "unreachable"

makeDeliveriesDue :: Sqlite.Connection -> IO ()
makeDeliveriesDue conn =
    Sqlite.execute_ conn "UPDATE webhook_deliveries SET available_at = 0 WHERE state = 'queued'"

rawBookmark :: Sqlite.Connection -> Text -> Text -> IO Int
rawBookmark conn url title = do
    Sqlite.execute
        conn
        "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES (?,?,?,?,?,?)"
        (url, title, ("example.test" :: Text), (1 :: Int), (1 :: Int), (1 :: Int))
    fromIntegral <$> Sqlite.lastInsertRowId conn

-- | The @data.id@ of every outbox event of one kind, in insertion order.
eventBookmarkIds :: Sqlite.Connection -> Text -> IO [Int]
eventBookmarkIds conn kind = do
    rows <-
        Sqlite.query
            conn
            "SELECT payload_json FROM event_log WHERE kind = ? ORDER BY id"
            (Only kind) ::
            IO [Only Text]
    pure (mapMaybe payloadId [raw | Only raw <- rows])
  where
    payloadId raw = do
        value <- either (const Nothing) Just (eitherDecodeStrict' (TE.encodeUtf8 raw)) :: Maybe Value
        case value of
            Object objectValue -> case KeyMap.lookup "id" objectValue of
                Just (Number number) -> Just (round number)
                _ -> Nothing
            _ -> Nothing

eventKinds :: Sqlite.Connection -> IO [Text]
eventKinds conn = do
    rows <- Sqlite.query_ conn "SELECT kind FROM event_log ORDER BY id" :: IO [Only Text]
    pure [kind | Only kind <- rows]

eventPayloadAt :: Sqlite.Connection -> Int -> IO Value
eventPayloadAt conn eventId = do
    rows <- Sqlite.query conn "SELECT payload_json FROM event_log WHERE id = ?" (Only eventId) :: IO [Only Text]
    pure $ case rows of
        [Only payload] -> fromMaybe Null (either (const Nothing) Just (eitherDecodeStrict' (TE.encodeUtf8 payload)))
        _ -> Null

singleBookmarkId :: Sqlite.Connection -> IO Int
singleBookmarkId conn = do
    rows <- Sqlite.query_ conn "SELECT MIN(id) FROM bookmarks" :: IO [Only (Maybe Int)]
    pure $ case rows of
        [Only (Just bid)] -> bid
        _ -> 0

webhookOrFail :: Sqlite.Connection -> Int -> IO Webhook
webhookOrFail conn webhookId = do
    found <- getWebhook conn webhookId
    case found of
        Just webhook -> pure webhook
        Nothing -> expectationFailure "expected the webhook" >> error "unreachable"

hasField :: Text -> Text -> Value -> Bool
hasField key expected value = case value of
    Object objectValue -> case KeyMap.lookup (AesonKey.fromText key) objectValue of
        Just (String actual) -> actual == expected
        Just fieldValue -> TE.decodeUtf8 (LBS.toStrict (encode fieldValue)) == expected
        Nothing -> False
    _ -> False

sampleClip :: ClipRequest
sampleClip =
    ClipRequest
        { clUrl = "https://example.com/webhook-clip"
        , clTitle = "Webhook clip"
        , clContentMarkdown = ""
        , clContentText = "A real body sentence for the capture."
        , clContentHtml = ""
        , clSelection = ""
        , clTags = ["webhook-test"]
        , clTemplateId = Nothing
        , clSource = "extension"
        , clClient = "e2e"
        , clCapturedAt = Nothing
        , clIdempotencyKey = Just "webhook-clip-key"
        , clMetadata = emptyClipMetadata
        }

-- --------------------------------------------------------------- receivers ---

data Receiver = Receiver
    { receiverPort :: Int
    , receiverState :: MVar (Int, Int)
    , receiverCaptured :: MVar [([(HeaderName, BS.ByteString)], LBS.ByteString)]
    }

receiverUrl :: Receiver -> Text
receiverUrl receiver = "http://127.0.0.1:" <> T.pack (show (receiverPort receiver)) <> "/hook"

startReceiver :: IO (Receiver, IO ())
startReceiver = do
    state <- newMVar (0, 200)
    captured <- newMVar []
    (port, sock) <- openFreePort
    ready <- newEmptyMVar
    let settings = setBeforeMainLoop (putMVar ready ()) defaultSettings
        app :: Application
        app request respond = do
            body <- strictRequestBody request
            modifyMVar_ captured (pure . ((requestHeaders request, body) :))
            status <- modifyMVar state $ \current@(failures, failureStatus) ->
                if failures > 0
                    then pure ((failures - 1, failureStatus), failureStatus)
                    else pure (current, 200)
            respond (responseLBS (mkStatus status "") [] "")
    threadId <- forkIO (runSettingsSocket settings sock app)
    takeMVar ready
    pure (Receiver (fromIntegral port) state captured, shutdownReceiver threadId sock)
  where
    shutdownReceiver threadId (sock :: Socket) = do
        killThread threadId
        Socket.close sock

withReceiver :: (Receiver -> IO a) -> IO a
withReceiver action =
    bracket startReceiver snd (\(receiver, _) -> action receiver)

setReceiverStatus :: Receiver -> Int -> Int -> IO ()
setReceiverStatus receiver status failures =
    modifyMVar_ (receiverState receiver) (const (pure (failures, status)))

capturedRequests :: Receiver -> IO [([(HeaderName, BS.ByteString)], LBS.ByteString)]
capturedRequests receiver = reverse <$> readMVar (receiverCaptured receiver)

tableNames :: Sqlite.Connection -> IO [Text]
tableNames conn = do
    rows <- Sqlite.query_ conn "SELECT name FROM sqlite_master WHERE type = 'table'" :: IO [Only Text]
    pure [name | Only name <- rows]

isWebhookInvalid :: Either WebhookError (Webhook, Text) -> Bool
isWebhookInvalid (Left (WebhookInvalid _)) = True
isWebhookInvalid _ = False

isWebhookCreated :: Either WebhookError (Webhook, Text) -> Bool
isWebhookCreated (Right _) = True
isWebhookCreated _ = False
