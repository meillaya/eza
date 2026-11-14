{-# LANGUAGE OverloadedStrings #-}

{- | The durable job queue behind asynchronous egress (schema v18): the
migration, claim-by-kind isolation, dedupe, lifecycle states, retry/cancel,
crash reset, the enqueue-only HTTP handlers, own-library job status with
cross-account 404, and worker execution of a job.
-}
module JobsSpec (spec) where

import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.ByteString.Char8
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Only (..))
import qualified Database.SQLite.Simple as Sqlite
import Network.HTTP.Client (defaultManagerSettings, newManager)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Eza.Config (Config (..))
import qualified Eza.Db as Db
import qualified Eza.Egress as Egress
import Eza.Jobs
import Eza.Migrate (MigrationPlan (..), applyMigrations, planMigrations)
import Eza.User (UserRole (..))
import TestHarness

spec :: Spec
spec = do
    describe "schema v18 job queue" $ do
        it "extends jobs with target/payload/result/cancel columns and a backup" $
            withSystemTempDirectory "eza-jobs-migrate" $ \dir -> do
                let path = dir </> "v17.db"
                bracket (Sqlite.open path) Sqlite.close $ \conn -> do
                    applied <- applyMigrations conn planV17
                    case applied of
                        Left message -> expectationFailure (show message)
                        Right _ -> pure ()
                    Sqlite.execute_ conn "INSERT INTO jobs (kind, bookmark_id, state, attempts, available_at, created_at, updated_at) VALUES ('enrich', 1, 'queued', 0, 1, 1, 1)"
                migrated <- Db.openDb path
                version <- Db.schemaVersion migrated
                version `shouldBe` 18
                columns <- jobColumns migrated
                ("target" `elem` columns) `shouldBe` True
                ("payload" `elem` columns) `shouldBe` True
                ("result" `elem` columns) `shouldBe` True
                ("cancel_requested" `elem` columns) `shouldBe` True
                preserved <- Sqlite.query_ migrated "SELECT COUNT(*) FROM jobs" :: IO [Only Int]
                preserved `shouldBe` [Only 1]
                Sqlite.close migrated
                backups <- backupsIn dir
                length backups `shouldBe` 1

    describe "job lifecycle" $ do
        it "dedupes active jobs, claims by kind, completes with a result, and resets" $
            withSystemTempDirectory "eza-jobs-lifecycle" $ \dir -> do
                conn <- Db.openDb (dir </> "jobs.db")
                let payload = object ["bookmark_id" .= (1 :: Int)]
                firstId <- enqueueTrackedJob conn "snapshot" "bookmark:1" payload
                duplicate <- enqueueTrackedJob conn "snapshot" "bookmark:1" payload
                duplicate `shouldBe` firstId
                queued <- getJobView conn firstId
                (jvState <$> queued) `shouldBe` Just "queued"
                (jvResult <$> queued) `shouldBe` Just Nothing
                claimed <- claimJobKind conn "snapshot"
                (jobId <$> claimed) `shouldBe` Just firstId
                (jobTarget <$> claimed) `shouldBe` Just "bookmark:1"
                claimJobKind conn "snapshot" `shouldReturn` Nothing
                running <- getJobView conn firstId
                (jvState <$> running) `shouldBe` Just "running"
                resetRunningJobs conn
                reset <- getJobView conn firstId
                (jvState <$> reset) `shouldBe` Just "queued"
                reclaimed <- claimJobKind conn "snapshot"
                (jobId <$> reclaimed) `shouldBe` Just firstId
                completeJobResult conn firstId (object ["snapshot" .= object ["path" .= ("/tmp/x.html" :: Text), "bytes" .= (12 :: Int)]])
                done <- getJobView conn firstId
                (jvState <$> done) `shouldBe` Just "done"
                (jvResult =<< done) `shouldSatisfy` maybe False (\value -> case value of Object _ -> True; _ -> False)
                (jvError <$> done) `shouldBe` Just Nothing
                -- A finished target may be queued again.
                secondId <- enqueueTrackedJob conn "snapshot" "bookmark:1" payload
                secondId `shouldSatisfy` (> firstId)
                Sqlite.close conn

        it "isolates claim kinds" $
            withSystemTempDirectory "eza-jobs-kinds" $ \dir -> do
                conn <- Db.openDb (dir </> "kinds.db")
                snapshotId <- enqueueTrackedJob conn "snapshot" "bookmark:1" (object ["bookmark_id" .= (1 :: Int)])
                deadId <- enqueueTrackedJob conn "check_dead" "maintenance" (object [])
                claimed <- claimJobKind conn "check_dead"
                (jobId <$> claimed) `shouldBe` Just deadId
                claimJobKind conn "check_dead" `shouldReturn` Nothing
                snapshotClaim <- claimJobKind conn "snapshot"
                (jobId <$> snapshotClaim) `shouldBe` Just snapshotId
                Sqlite.close conn

        it "cancels and permanently fails jobs with a reason" $
            withSystemTempDirectory "eza-jobs-fail" $ \dir -> do
                conn <- Db.openDb (dir </> "fail.db")
                cancelId <- enqueueTrackedJob conn "check_dead" "maintenance" (object [])
                _ <- claimJobKind conn "check_dead"
                cancelled <- jobCancelRequested conn cancelId
                cancelled `shouldBe` False
                cancelJob conn cancelId
                cancelledView <- getJobView conn cancelId
                (jvState <$> cancelledView) `shouldBe` Just "cancelled"
                failId <- enqueueTrackedJob conn "webhook_test" "webhook:9" (object ["webhook_id" .= (9 :: Int)])
                _ <- claimJobKind conn "webhook_test"
                failJobPermanent conn failId "the webhook could not be reached"
                failed <- getJobView conn failId
                (jvState <$> failed) `shouldBe` Just "failed"
                (jvError <$> failed) `shouldBe` Just (Just "the webhook could not be reached")
                Sqlite.close conn

        it "retries with backoff and parks the third failure" $
            withSystemTempDirectory "eza-jobs-retry" $ \dir -> do
                conn <- Db.openDb (dir </> "retry.db")
                jobId <- enqueueTrackedJob conn "snapshot" "bookmark:1" (object [])
                failJob conn jobId "first" 0
                retried <- getJobView conn jobId
                (jvState <$> retried) `shouldBe` Just "queued"
                (jvAttempts <$> retried) `shouldBe` Just 1
                failJob conn jobId "second" 1
                failJob conn jobId "third" 2
                parked <- getJobView conn jobId
                (jvState <$> parked) `shouldBe` Just "failed"
                (jvAttempts <$> parked) `shouldBe` Just 3
                Sqlite.close conn

        it "executes a check_dead job and an AI job without a provider" $
            withSystemTempDirectory "eza-jobs-exec" $ \dir -> do
                manager <- newManager defaultManagerSettings
                let cfg = (testConfig dir){cfgAiProvider = "none"}
                conn <- Db.openDb (dir </> "exec.db")
                deadId <- enqueueTrackedJob conn "check_dead" "maintenance" (object ["limit" .= (10 :: Int)])
                _ <- claimJobKind conn "check_dead"
                deadJob <- expectJustIO "check_dead job" =<< getJob conn deadId
                Egress.processOneJob manager cfg (dir </> "snapshots") conn deadJob
                deadView <- getJobView conn deadId
                (jvState <$> deadView) `shouldBe` Just "done"
                aiId <- enqueueTrackedJob conn "ai_suggestions" "all" (object [])
                _ <- claimJobKind conn "ai_suggestions"
                aiJob <- expectJustIO "ai job" =<< getJob conn aiId
                Egress.processOneJob manager cfg (dir </> "snapshots") conn aiJob
                aiView <- getJobView conn aiId
                (jvState <$> aiView) `shouldBe` Just "failed"
                (jvError <$> aiView) `shouldSatisfy` maybe False (maybe False ((not . null) . show))
                Sqlite.close conn

    describe "no inline egress" $ do
        it "keeps network and subprocess work out of the request handlers" $ do
            forM_ handlerSources $ \path -> do
                source <- readExisting path
                forM_ ["captureSnapshot", "checkDead", "aiSuggestions", "testWebhook"] $ \symbol ->
                    (symbol `T.isInfixOf` T.pack source)
                        `shouldBe` False
    describe "HTTP enqueue and status" $ do
        it "enqueues legacy egress routes and serves own-library job status" $
            withTestServer $ \server -> do
                _ <- createTestUser server "alice" "alice password" RoleAdmin
                (session, csrf) <- loginAs server "alice" "alice password"
                addTestBookmark server session csrf 1
                checkDead <- postJson server session csrf "/api/v1/maintenance/check-dead" "{}"
                checkDead `shouldHaveStatus` 202
                let deadJobId = jobIdOf checkDead
                statusResponse <- getJobStatus server session csrf deadJobId
                statusResponse `shouldHaveStatus` 200
                jsonTextField "kind" (hrespBody statusResponse) `shouldBe` Just "check_dead"
                jsonTextField "state" (hrespBody statusResponse) `shouldBe` Just "queued"
                jsonIntField "attempts" (hrespBody statusResponse) `shouldBe` Just 0
                jsonField "result" (hrespBody statusResponse) `shouldBe` Just Null
                jsonField "error" (hrespBody statusResponse) `shouldBe` Just Null
                -- Same active target returns the same job id.
                again <- postJson server session csrf "/api/v1/maintenance/check-dead" "{}"
                jobIdOf again `shouldBe` deadJobId
                -- Snapshot and AI routes are enqueue only (no inline egress).
                snapshotResponse <- postJson server session csrf "/api/v1/bookmarks/1/snapshot" "{}"
                snapshotResponse `shouldHaveStatus` 202
                aiResponse <- postJson server session csrf "/api/v1/ai/suggestions" "{}"
                aiResponse `shouldHaveStatus` 202
                taggedAi <- postJson server session csrf "/api/v1/ai/suggestions" "{\"tag\":\"rust\"}"
                taggedAi `shouldHaveStatus` 202
                (jobIdOf aiResponse /= jobIdOf taggedAi) `shouldBe` True
                -- Unknown ids are JSON 404; another account never sees the job.
                missing <- getJobStatus server session csrf 999999
                missing `shouldHaveStatus` 404
                _ <- createTestUser server "bob" "bob password" RoleMember
                (bobSession, bobCsrf) <- loginAs server "bob" "bob password"
                otherLibrary <- getJobStatus server bobSession bobCsrf deadJobId
                otherLibrary `shouldHaveStatus` 404
                -- Missing webhook for a test job is a 404, not an inline delivery.
                missingHook <- postJson server session csrf "/api/v1/webhooks/999/test" "{}"
                missingHook `shouldHaveStatus` 404
                pure ()

-- ----------------------------------------------------------------- helpers ---

handlerSources :: [FilePath]
handlerSources =
    [ "src/Eza/Api/Bookmarks.hs"
    , "src/Eza/Api/Maintenance.hs"
    , "src/Eza/Api/Tags.hs"
    , "src/Eza/Api/Extensions.hs"
    ]

readExisting :: FilePath -> IO String
readExisting path = do
    existsHere <- doesFileExist path
    let prefixed = "server/" <> path
    existsPrefixed <- doesFileExist prefixed
    if existsHere
        then readFile path
        else
            if existsPrefixed
                then readFile prefixed
                else expectationFailure ("missing handler source: " <> path) >> pure ""

planV17 :: MigrationPlan
planV17 =
    Db.dbMigrationPlan
        { planMigrations = take 17 (planMigrations Db.dbMigrationPlan)
        }

jobColumns :: Sqlite.Connection -> IO [Text]
jobColumns conn = do
    rows <- Sqlite.query_ conn "PRAGMA table_info(jobs)" :: IO [(Int, Text, Text, Int, Maybe Text, Int)]
    pure [name | (_, name, _, _, _, _) <- rows]

backupsIn :: FilePath -> IO [FilePath]
backupsIn dir = do
    let backupDir = dir </> "backups"
    exists <- doesDirectoryExist backupDir
    if exists then listDirectory backupDir else pure []

postJson :: TestServer -> Text -> Text -> String -> String -> IO HttpResponse
postJson server session csrf path body =
    httpRequest server "POST" path (authHeaders session csrf) (Just (encodeText body))

encodeText :: String -> LBS.ByteString
encodeText = LBS.fromStrict . Data.ByteString.Char8.pack

getJobStatus :: TestServer -> Text -> Text -> Int -> IO HttpResponse
getJobStatus server session csrf jobId =
    httpRequest server "GET" ("/api/v1/jobs/" <> show jobId) (cookieHeaders session csrf) Nothing

jobIdOf :: HttpResponse -> Int
jobIdOf response = fromMaybe 0 (jsonIntField "job_id" (hrespBody response))

expectJustIO :: String -> Maybe a -> IO a
expectJustIO label = maybe (expectationFailure ("missing " <> label) >> error "unreachable") pure
