{-# LANGUAGE OverloadedStrings #-}

{- | Library lifecycle and read-path authentication.

Three properties the M4 server architecture must keep:

  * authenticating a request is a read. A GET with a live session completes
    even while another connection holds the user database's write lock;
  * the activity timestamp (@sessions.last_seen_at@, @api_tokens.last_used_at@)
    is written at most once per throttle window, so the common GET path takes
    no writer at all;
  * opening and closing a library, starting and stopping its workers, and
    disabling an account repeatedly does not leak SQLite connections. The
    deltas of "Eza.Db.connectionStats" balance after the cycle.
-}
module LibrarySpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Aeson (encode, object, (.=))
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple (Connection, Only (..))
import qualified Database.SQLite.Simple as Sqlite
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import qualified Eza.Admin as Admin
import qualified Eza.Auth as Auth
import Eza.Config (Config (..))
import Eza.Control (ControlUser (..))
import qualified Eza.Control as Control
import qualified Eza.Db as Db
import qualified Eza.Library as Library
import Eza.Server (closeAppState, newAppState, syncUserWorkers, userWorkerIds)
import Eza.TokenPrefix (splitUserPrefix)
import Eza.User (UserRole (..))
import TestHarness (
    authHeaders,
    cookieHeaders,
    createTestUser,
    expectJust,
    hrespBody,
    httpRequest,
    jsonTextField,
    loginAs,
    shouldHaveStatus,
    testConfig,
    userDbPath,
    withTestServer,
 )

spec :: Spec
spec = describe "library lifecycle and read-path authentication" $ do
    it "authenticates a GET on the read pool while the writer is held" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            -- One request opens the slot and proves the session works.
            warm <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders session csrf) Nothing
            warm `shouldHaveStatus` 200
            -- Hold the user database's write lock from outside the server.
            bracket (Sqlite.open (userDbPath server "alice")) Sqlite.close $ \blocker -> do
                Sqlite.execute_ blocker "BEGIN IMMEDIATE"
                during <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders session csrf) Nothing
                Sqlite.execute_ blocker "ROLLBACK"
                during `shouldHaveStatus` 200

    it "writes session activity at most once per throttle window" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            let bareToken = maybe session snd (splitUserPrefix session)
                sessionId = Auth.hashToken bareToken
                dbPath = userDbPath server "alice"
            _ <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders session csrf) Nothing
            initial <- readSessionActivity dbPath sessionId
            -- A fresh session takes no writer: the GET does not change it.
            _ <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders session csrf) Nothing
            unchanged <- readSessionActivity dbPath sessionId
            unchanged `shouldBe` initial
            -- Once stale, the next request records exactly one activity write.
            let stale = maybe 0 (subtract 120) initial
            setSessionActivity dbPath sessionId stale
            _ <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders session csrf) Nothing
            touched <- readSessionActivity dbPath sessionId
            touched `shouldSatisfy` maybe False (> stale)

    it "writes token activity at most once per throttle window" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            created <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/tokens"
                    (authHeaders session csrf)
                    (Just (encode (object ["name" .= ("library-spec" :: Text), "scopes" .= (["read"] :: [Text])])))
            created `shouldHaveStatus` 201
            rawToken <- expectJust "token" (jsonTextField "token" (hrespBody created))
            let bearer = [("Authorization", TE.encodeUtf8 ("Bearer " <> rawToken))]
                dbPath = userDbPath server "alice"
            first <- httpRequest server "GET" "/api/v1/whoami" bearer Nothing
            first `shouldHaveStatus` 200
            firstUsedAt <- readTokenActivity dbPath
            firstUsedAt `shouldSatisfy` (/= Nothing)
            -- The second request inside the window does not write again.
            second <- httpRequest server "GET" "/api/v1/whoami" bearer Nothing
            second `shouldHaveStatus` 200
            secondUsedAt <- readTokenActivity dbPath
            secondUsedAt `shouldBe` firstUsedAt

    it "does not leak SQLite connections across library and worker cycles" $
        withSystemTempDirectory "eza-library-lifecycle" $ \dir -> do
            let cfg = (testConfig dir){cfgEnrichWorkers = 1, cfgFetchTimeoutMs = 1000}
            -- A second enabled admin keeps the member's disable legal.
            _ <- createAccount cfg "owner" RoleAdmin
            alice <- createAccount cfg "alice" RoleMember
            -- Direct open/close cycles of the library itself.
            beforeOpenClose <- Db.connectionStats
            forM_ [1 .. 3 :: Int] $ \_ ->
                bracket (Library.openLibrary (cuDbPath alice)) Library.closeLibrary (\_ -> pure ())
            afterOpenClose <- Db.connectionStats
            balanced "open/close cycles" beforeOpenClose afterOpenClose
            -- Server slot cycles: enable, start workers, disable, stop them.
            state <- newAppState cfg
            forM_ [1 .. 2 :: Int] $ \_ -> do
                setEnabled cfg (cuId alice) True
                syncUserWorkers state
                waitUntil "the workers started" (userWorkerIds state) $ \ids ->
                    maybe 0 id (lookup (cuId alice) ids) >= 2
                setEnabled cfg (cuId alice) False
                syncUserWorkers state
                waitUntil "the workers stopped" (userWorkerIds state) $ \ids ->
                    lookup (cuId alice) ids == Just 0
            closeAppState state
            finalStats <- Db.connectionStats
            balanced "worker enable/disable cycles" afterOpenClose finalStats

-- ---------------------------------------------------------------------------
-- Activity timestamps
-- ---------------------------------------------------------------------------

readSessionActivity :: FilePath -> Text -> IO (Maybe Int)
readSessionActivity dbPath sessionId =
    withReadConnection dbPath $ \conn -> do
        rows <-
            Sqlite.query
                conn
                "SELECT last_seen_at FROM sessions WHERE id = ?"
                (Only sessionId) ::
                IO [Only (Maybe Int)]
        pure (case rows of [Only value] -> value; _ -> Nothing)

setSessionActivity :: FilePath -> Text -> Int -> IO ()
setSessionActivity dbPath sessionId value =
    withReadConnection dbPath $ \conn ->
        Sqlite.execute
            conn
            "UPDATE sessions SET last_seen_at = ? WHERE id = ?"
            (value, sessionId)

readTokenActivity :: FilePath -> IO (Maybe Int)
readTokenActivity dbPath =
    withReadConnection dbPath $ \conn -> do
        rows <-
            Sqlite.query_
                conn
                "SELECT last_used_at FROM api_tokens ORDER BY id DESC LIMIT 1" ::
                IO [Only (Maybe Int)]
        pure (case rows of [Only value] -> value; _ -> Nothing)

{- | A separate connection for the test's own reads and writes. The server
keeps the user database open in WAL mode, so this is safe while requests run.
-}
withReadConnection :: FilePath -> (Connection -> IO a) -> IO a
withReadConnection dbPath action = bracket openConnection Sqlite.close $ \conn -> do
    Sqlite.execute_ conn "PRAGMA busy_timeout = 5000"
    action conn
  where
    openConnection = Sqlite.open dbPath

-- ---------------------------------------------------------------------------
-- Accounts and assertions
-- ---------------------------------------------------------------------------

createAccount :: Config -> Text -> UserRole -> IO ControlUser
createAccount cfg username role = withControl cfg $ \control -> do
    created <- Admin.createUserAccount cfg control username role (username <> " password")
    case created of
        Left err -> expectationFailure ("could not create the test account: " <> show err) >> error "unreachable"
        Right (user, _) -> pure user

setEnabled :: Config -> Int -> Bool -> IO ()
setEnabled cfg userId enabled = withControl cfg $ \control -> do
    changed <- Admin.setUserEnabled cfg control userId enabled
    case changed of
        Left err -> expectationFailure ("could not change the account state: " <> show err)
        Right _ -> pure ()

withControl :: Config -> (Connection -> IO a) -> IO a
withControl cfg = bracket (Control.openControlDb (cfgControlDbPath cfg)) Sqlite.close

balanced :: String -> Db.ConnectionStats -> Db.ConnectionStats -> Expectation
balanced label earlier later
    | openedDelta == closedDelta = pure ()
    | otherwise =
        expectationFailure
            ( label
                <> ": opened "
                <> show openedDelta
                <> " connections but closed "
                <> show closedDelta
            )
  where
    openedDelta = Db.csOpened later - Db.csOpened earlier
    closedDelta = Db.csClosed later - Db.csClosed earlier

waitUntil :: String -> IO a -> (a -> Bool) -> IO ()
waitUntil label probe predicate = go (80 :: Int)
  where
    go 0 = expectationFailure ("timed out waiting for " <> label)
    go attemptsLeft = do
        value <- probe
        if predicate value
            then pure ()
            else threadDelay (50 * 1000) >> go (attemptsLeft - 1)
