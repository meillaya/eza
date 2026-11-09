{-# LANGUAGE OverloadedStrings #-}

{- | Per-user background workers.

The tests run the worker supervisor explicitly (no Warp server): enabled
accounts get their own enrichment and webhook loops, disabling an account stops
its loops, and @EZA_ENRICH_WORKERS=0@ disables the enrichment loop while the
webhook loop stays available.
-}
module WorkerSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (when)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import Database.SQLite.Simple (Only (..), Query (..))
import qualified Database.SQLite.Simple as Sqlite
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import qualified Eza.Admin as Admin
import qualified Eza.Auth as Auth
import Eza.Bookmarks (insertBookmark)
import Eza.Config (Config (..))
import Eza.Control (ControlUser (..))
import qualified Eza.Control as Control
import qualified Eza.Db as Db
import Eza.Enrich (backfillCachedFavicons, enqueueEnrichment)
import Eza.Favicon (putFavicon)
import Eza.Server (
    closeAppState,
    enableWorkers,
    newAppState,
    stopAllUserWorkers,
    syncUserWorkers,
    userSlotCount,
    userSlotFor,
    userWorkerIds,
 )
import Eza.User (UserRole (..))
import TestHarness (testConfig)

spec :: Spec
spec = describe "per-user workers" $ do
    it "runs one worker set per enabled account and stops it on disable" $
        withWorkerConfig $ \cfg -> do
            (alice, bob) <- createAccounts cfg
            state <- newAppState cfg
            enableWorkers state
            syncUserWorkers state
            workers <- userWorkerIds state
            length workers `shouldBe` 2
            map snd workers `shouldSatisfy` all (>= 2) -- one enrich + one webhook
            aliceSlotCount <- userSlotCount state
            aliceSlotCount `shouldBe` 2
            -- The enrichment loop claims jobs only in its own account database.
            enqueueBoom cfg alice
            waitUntil "alice's enrich job was attempted" (jobAttempts cfg alice) (>= 1)
            bobAttempts <- jobAttempts cfg bob
            bobAttempts `shouldBe` 0
            -- Disabling the account stops its workers at the next tick.
            withControl cfg $ \control -> do
                disabled <- Admin.setUserEnabled cfg control (cuId bob) False
                disabled `shouldSatisfy` isRight
            syncUserWorkers state
            workersAfterDisable <- userWorkerIds state
            map fst (filter ((> 0) . snd) workersAfterDisable) `shouldBe` [cuId alice]
            lookup (cuId bob) workersAfterDisable `shouldBe` Just 0
            enqueueBoom cfg bob
            threadDelay (3 * 1000000)
            disabledAttempts <- jobAttempts cfg bob
            disabledAttempts `shouldBe` 0
            -- Re-enabling restarts them.
            withControl cfg $ \control -> do
                _ <- Admin.setUserEnabled cfg control (cuId bob) True
                pure ()
            syncUserWorkers state
            workersAfterEnable <- userWorkerIds state
            length workersAfterEnable `shouldBe` 2
            stopAllUserWorkers state
            closeAppState state

    it "honours EZA_ENRICH_WORKERS=0 and keeps the webhook loop" $
        withWorkerConfig $ \cfg0 -> do
            let cfg = cfg0{cfgEnrichWorkers = 0}
            (alice, _) <- createAccounts cfg
            state <- newAppState cfg
            enableWorkers state
            syncUserWorkers state
            workers <- userWorkerIds state
            length workers `shouldBe` 2
            map snd workers `shouldSatisfy` all (== 1) -- webhook only
            enqueueBoom cfg alice
            threadDelay (3 * 1000000)
            attempts <- jobAttempts cfg alice
            attempts `shouldBe` 0
            stopAllUserWorkers state
            closeAppState state

    it "expires stale sessions when a user database is opened" $
        withWorkerConfig $ \cfg -> do
            (alice, _) <- createAccounts cfg
            bracket (Db.openDb (cuDbPath alice)) Sqlite.close $ \conn -> do
                _ <- Auth.createSession conn "normal" 60
                Sqlite.execute_ conn "UPDATE sessions SET expires_at = 1"
                pure ()
            state <- newAppState cfg
            _ <- userSlotFor state alice
            bracket (Db.openDb (cuDbPath alice)) Sqlite.close $ \conn -> do
                sessions <- Sqlite.query_ conn "SELECT COUNT(*) FROM sessions" :: IO [Only Int]
                sessions `shouldBe` [Only 0]
            closeAppState state

    it "fills every bookmark of a cached favicon domain without network" $
        withWorkerConfig $ \cfg -> do
            (alice, _) <- createAccounts cfg
            bracket (Db.openDb (cuDbPath alice)) Sqlite.close $ \conn -> do
                _ <- insertBookmark conn "https://example.test/one" "One" []
                _ <- insertBookmark conn "https://example.test/two" "Two" []
                _ <- putFavicon conn "example.test" "https://example.test/favicon.ico" "image/png" (BS.pack [0x89, 0x50, 0x4E, 0x47])
                first <- backfillCachedFavicons conn
                first `shouldBe` True
                urls <-
                    Sqlite.query_ conn "SELECT favicon_url FROM bookmarks ORDER BY id" ::
                        IO [Only T.Text]
                map (\(Only url) -> url) urls
                    `shouldSatisfy` all ("/api/v1/favicons/example.test?v=" `T.isPrefixOf`)
                -- A second pass has no row to fill, so it does no work.
                second <- backfillCachedFavicons conn
                second `shouldBe` False

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

withWorkerConfig :: (Config -> IO a) -> IO a
withWorkerConfig action = withSystemTempDirectory "eza-workers" $ \dir -> do
    let cfg =
            (testConfig dir)
                { cfgEnrichWorkers = 1
                , cfgFetchTimeoutMs = 1000
                }
    action cfg

createAccounts :: Config -> IO (ControlUser, ControlUser)
createAccounts cfg = withControl cfg $ \control -> do
    alice <- mustCreate (Admin.createUserAccount cfg control "alice" RoleAdmin "alice password")
    bob <- mustCreate (Admin.createUserAccount cfg control "bob" RoleMember "bob password")
    pure (alice, bob)

mustCreate :: IO (Either Admin.AdminError (ControlUser, [T.Text])) -> IO ControlUser
mustCreate action = do
    result <- action
    case result of
        Right (user, _) -> pure user
        Left err -> expectationFailure ("could not create a test account: " <> show err) >> error "unreachable"

withControl :: Config -> (Sqlite.Connection -> IO a) -> IO a
withControl cfg = bracket (Control.openControlDb (cfgControlDbPath cfg)) Sqlite.close

enqueueBoom :: Config -> ControlUser -> IO ()
enqueueBoom _ user =
    bracket (Db.openDb (cuDbPath user)) Sqlite.close $ \conn -> do
        bookmarkId <- insertBookmark conn "http://127.0.0.1:9/no-such-host" "Boom" []
        case bookmarkId of
            Left err -> expectationFailure ("could not insert the test bookmark: " <> T.unpack err)
            Right bid -> enqueueEnrichment conn bid

jobAttempts :: Config -> ControlUser -> IO Int
jobAttempts _ user =
    bracket (Db.openDb (cuDbPath user)) Sqlite.close $ \conn -> do
        rows <-
            Sqlite.query
                conn
                (Query "SELECT COALESCE(MAX(attempts),0) FROM jobs")
                () ::
                IO [Only Int]
        pure (case rows of [Only value] -> value; _ -> 0)

waitUntil :: String -> IO a -> (a -> Bool) -> IO ()
waitUntil label probe predicate = go (60 :: Int)
  where
    go 0 = expectationFailure ("timed out waiting for " <> label) >> pure ()
    go attemptsLeft = do
        value <- probe
        when (predicate value) (pure ()) >> when (not (predicate value)) (threadDelay (250 * 1000) >> go (attemptsLeft - 1))
        pure ()

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _) = False
