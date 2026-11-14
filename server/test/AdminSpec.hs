{-# LANGUAGE OverloadedStrings #-}

{- | The admin JSON API and per-user snapshot capture.

These tests run the real Warp application. They cover the AdminClass guard,
account creation with one-time recovery codes, disable/re-enable with session
revocation, the last-admin and self-disable rules, password reset, and the
per-user snapshots directory.
-}
module AdminSpec (spec) where

import Data.Aeson (Value (..), encode, object, (.=))
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath ((</>))
import System.Posix.Files (
    groupExecuteMode,
    groupReadMode,
    otherExecuteMode,
    otherReadMode,
    ownerExecuteMode,
    ownerReadMode,
    ownerWriteMode,
    setFileMode,
    unionFileModes,
 )
import Test.Hspec

import Control.Exception (finally)
import qualified Database.SQLite.Simple as Sqlite
import qualified Eza.Admin as Admin
import Eza.Config (Config (..))
import qualified Eza.Control as Control
import Eza.User (UserCreateResult (..), UserView (..))
import TestHarness

spec :: Spec
spec = describe "admin API" $ do
    it "lists accounts without exposing database paths" $
        withTwoUsers $ \server alice bob -> do
            (session, csrf) <- loginAs server "alice" "alice password"
            listed <- httpRequest server "GET" "/api/v1/admin/users" (cookieHeaders session csrf) Nothing
            listed `shouldHaveStatus` 200
            hrespBody listed `shouldSatisfy` containsText "alice"
            hrespBody listed `shouldSatisfy` containsText "bob"
            hrespBody listed `shouldSatisfy` (not . containsText "db_path")
            hrespBody listed `shouldSatisfy` (not . containsText (T.pack (Control.cuDbPath alice)))
            hrespBody listed `shouldSatisfy` (not . containsText (T.pack (Control.cuDbPath bob)))

    it "rejects a member session and a bearer token on admin routes" $
        withTwoUsers $ \server _ _ -> do
            (memberSession, memberCsrf) <- loginAs server "bob" "bob password"
            member <- httpRequest server "GET" "/api/v1/admin/users" (cookieHeaders memberSession memberCsrf) Nothing
            member `shouldHaveStatus` 403
            (adminSession, adminCsrf) <- loginAs server "alice" "alice password"
            created <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/tokens"
                    (authHeaders adminSession adminCsrf)
                    (Just (encode (object ["name" .= ("cli" :: Text)])))
            created `shouldHaveStatus` 201
            token <- expectJust "token" (jsonTextField "token" (hrespBody created))
            tokenRequest <-
                httpRequest
                    server
                    "GET"
                    "/api/v1/admin/users"
                    [("Authorization", "Bearer " <> TE.encodeUtf8 token)]
                    Nothing
            tokenRequest `shouldHaveStatus` 403

    it "creates an account with one-time recovery codes" $
        withTwoUsers $ \server _ _ -> do
            (session, csrf) <- loginAs server "alice" "alice password"
            created <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/admin/users"
                    (authHeaders session csrf)
                    (Just (encode (object ["username" .= ("carol" :: Text), "password" .= ("carol password" :: Text), "role" .= ("member" :: Text)])))
            created `shouldHaveStatus` 201
            result <- expectJust "user create result" (jsonBody created :: Maybe UserCreateResult)
            length (ucrRecoveryCodes result) `shouldBe` 10
            uvUsername (ucrUser result) `shouldBe` "carol"
            uvRole (ucrUser result) `shouldBe` Control.RoleMember
            -- The new account can sign in and has an empty library.
            (carolSession, carolCsrf) <- loginAs server "carol" "carol password"
            boot <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders carolSession carolCsrf) Nothing
            boot `shouldHaveStatus` 200
            bootTotal (hrespBody boot) `shouldBe` Just 0
            -- Duplicate usernames are refused, not partially created.
            duplicate <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/admin/users"
                    (authHeaders session csrf)
                    (Just (encode (object ["username" .= ("Carol" :: Text), "password" .= ("carol password" :: Text)])))
            duplicate `shouldHaveStatus` 409
            hrespBody duplicate `shouldSatisfy` containsText "username_taken"

    it "disables an account, revokes its sessions, and re-enables it" $
        withTwoUsers $ \server _ bob -> do
            (adminSession, adminCsrf) <- loginAs server "alice" "alice password"
            (bobSession, bobCsrf) <- loginAs server "bob" "bob password"
            let path = "/api/v1/admin/users/" <> show (Control.cuId bob)
            disabled <-
                httpRequest
                    server
                    "PATCH"
                    path
                    (authHeaders adminSession adminCsrf)
                    (Just (encode (object ["enabled" .= False])))
            disabled `shouldHaveStatus` 200
            hrespBody disabled `shouldSatisfy` containsText "disabled_at"
            revoked <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders bobSession bobCsrf) Nothing
            revoked `shouldHaveStatus` 401
            enabled <-
                httpRequest
                    server
                    "PATCH"
                    path
                    (authHeaders adminSession adminCsrf)
                    (Just (encode (object ["enabled" .= True])))
            enabled `shouldHaveStatus` 200
            _ <- loginAs server "bob" "bob password"
            pure ()

    it "refuses self-disable and removing the last enabled admin" $
        withTwoUsers $ \server alice _ -> do
            (adminSession, adminCsrf) <- loginAs server "alice" "alice password"
            let selfPath = "/api/v1/admin/users/" <> show (Control.cuId alice)
            selfDisable <-
                httpRequest
                    server
                    "PATCH"
                    selfPath
                    (authHeaders adminSession adminCsrf)
                    (Just (encode (object ["enabled" .= False])))
            selfDisable `shouldHaveStatus` 409
            hrespBody selfDisable `shouldSatisfy` containsText "self_disable"
            lastAdmin <-
                httpRequest
                    server
                    "PATCH"
                    selfPath
                    (authHeaders adminSession adminCsrf)
                    (Just (encode (object ["role" .= ("member" :: Text)])))
            lastAdmin `shouldHaveStatus` 409
            hrespBody lastAdmin `shouldSatisfy` containsText "last_admin"
            -- A second admin makes the demotion legal.
            created <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/admin/users"
                    (authHeaders adminSession adminCsrf)
                    (Just (encode (object ["username" .= ("dave" :: Text), "password" .= ("dave password" :: Text), "role" .= ("admin" :: Text)])))
            created `shouldHaveStatus` 201
            demoted <-
                httpRequest
                    server
                    "PATCH"
                    selfPath
                    (authHeaders adminSession adminCsrf)
                    (Just (encode (object ["role" .= ("member" :: Text)])))
            demoted `shouldHaveStatus` 200
            -- Dave is now the only admin; demoting himself is refused.
            daveId <- case jsonBody created :: Maybe UserCreateResult of
                Just result -> pure (uvId (ucrUser result))
                Nothing -> expectationFailure "expected a created user" >> error "unreachable"
            (daveSession, daveCsrf) <- loginAs server "dave" "dave password"
            daveDemote <-
                httpRequest
                    server
                    "PATCH"
                    ("/api/v1/admin/users/" <> show daveId)
                    (authHeaders daveSession daveCsrf)
                    (Just (encode (object ["role" .= ("member" :: Text)])))
            daveDemote `shouldHaveStatus` 409
            hrespBody daveDemote `shouldSatisfy` containsText "last_admin"

    it "resets a password and revokes the old sessions" $
        withTwoUsers $ \server _ _ -> do
            (adminSession, adminCsrf) <- loginAs server "alice" "alice password"
            created <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/admin/users"
                    (authHeaders adminSession adminCsrf)
                    (Just (encode (object ["username" .= ("carol" :: Text), "password" .= ("carol password" :: Text)])))
            created `shouldHaveStatus` 201
            carolId <- case jsonBody created :: Maybe UserCreateResult of
                Just result -> pure (uvId (ucrUser result))
                Nothing -> expectationFailure "expected a created user" >> error "unreachable"
            (carolSession, carolCsrf) <- loginAs server "carol" "carol password"
            reset <-
                httpRequest
                    server
                    "POST"
                    ("/api/v1/admin/users/" <> show carolId <> "/password")
                    (authHeaders adminSession adminCsrf)
                    (Just (encode (object ["password" .= ("temporary carol password" :: Text)])))
            reset `shouldHaveStatus` 200
            stale <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders carolSession carolCsrf) Nothing
            stale `shouldHaveStatus` 401
            oldPassword <- loginResponse server "carol" "carol password"
            oldPassword `shouldHaveStatus` 401
            _ <- loginAs server "carol" "temporary carol password"
            pure ()

    it "refuses an unknown account and an invalid patch body" $
        withTwoUsers $ \server _ _ -> do
            (session, csrf) <- loginAs server "alice" "alice password"
            missing <-
                httpRequest
                    server
                    "PATCH"
                    "/api/v1/admin/users/9999"
                    (authHeaders session csrf)
                    (Just (encode (object ["enabled" .= False])))
            missing `shouldHaveStatus` 404
            emptyPatch <-
                httpRequest
                    server
                    "PATCH"
                    "/api/v1/admin/users/1"
                    (authHeaders session csrf)
                    (Just (encode (object [])))
            emptyPatch `shouldHaveStatus` 400
            resetMissing <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/admin/users/9999/password"
                    (authHeaders session csrf)
                    (Just (encode (object ["password" .= ("some password" :: Text)])))
            resetMissing `shouldHaveStatus` 404

    it "removes the partial row when account creation fails" $
        withTwoUsers $ \server _ _ -> do
            (session, csrf) <- loginAs server "alice" "alice password"
            -- A directory where the new account's database would go makes the
            -- create fail after the control row was allocated.
            let blocked = cfgUsersDir (tsConfig server) </> "3" </> "eza.db"
            createDirectoryIfMissing True blocked
            failed <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/admin/users"
                    (authHeaders session csrf)
                    (Just (encode (object ["username" .= ("carol" :: Text), "password" .= ("carol password" :: Text)])))
            failed `shouldHaveStatus` 500
            listed <- httpRequest server "GET" "/api/v1/admin/users" (cookieHeaders session csrf) Nothing
            listed `shouldHaveStatus` 200
            hrespBody listed `shouldSatisfy` (not . containsText "carol")
            users <- withControlUsers (tsConfig server) Control.listUsers
            length users `shouldBe` 2

    it "captures snapshots into each account's own snapshots directory" $
        withSnapshotServer $ \server -> do
            alice <- createTestUser server "alice" "alice password" Control.RoleAdmin
            bob <- createTestUser server "bob" "bob password" Control.RoleMember
            (sessionA, csrfA) <- loginAs server "alice" "alice password"
            (sessionB, csrfB) <- loginAs server "bob" "bob password"
            addTestBookmark server sessionA csrfA 1
            addTestBookmark server sessionB csrfB 1
            aliceJob <- snapshot server sessionA csrfA 1
            bobJob <- snapshot server sessionB csrfB 1
            runEgressJob server "alice" aliceJob
            runEgressJob server "bob" bobJob
            alicePath <- snapshotPathOf server sessionA csrfA aliceJob
            bobPath <- snapshotPathOf server sessionB csrfB bobJob
            let aliceDir = cfgUsersDir (tsConfig server) </> show (Control.cuId alice) </> "snapshots"
                bobDir = cfgUsersDir (tsConfig server) </> show (Control.cuId bob) </> "snapshots"
            alicePath `shouldBe` aliceDir </> "1.html"
            bobPath `shouldBe` bobDir </> "1.html"
            alicePath `shouldNotBe` bobPath
            aliceFile <- doesFileExist alicePath
            aliceFile `shouldBe` True
            bobFile <- doesFileExist bobPath
            bobFile `shouldBe` True
            served <- httpRequest server "GET" "/api/v1/bookmarks/1/snapshot" (cookieHeaders sessionA csrfA) Nothing
            served `shouldHaveStatus` 200
            hrespBody served `shouldSatisfy` containsText "snapshot"

    it "caps account creation at EZA_MAX_USERS" $
        withTestServerCustom (\cfg -> cfg{cfgMaxUsers = 1}) (\_ -> pure ()) $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            created <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/admin/users"
                    (authHeaders session csrf)
                    (Just (encode (object ["username" .= ("carol" :: Text), "password" .= ("carol password" :: Text)])))
            created `shouldHaveStatus` 409
            hrespBody created `shouldSatisfy` containsText "user_limit"
            users <- withControlUsers (tsConfig server) Control.listUsers
            length users `shouldBe` 1

    it "exposes startup warnings for missing libraries and the over-limit case" $
        withTestServerCustom (\cfg -> cfg{cfgMaxUsers = 1}) (\_ -> pure ()) $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            bob <- createTestUser server "bob" "bob password" Control.RoleMember
            let cfg = tsConfig server
                control = tsControl server
            missingBefore <- Admin.missingUserDatabases cfg control
            missingBefore `shouldBe` []
            removeFile (Control.cuDbPath bob)
            missing <- Admin.missingUserDatabases cfg control
            map Control.cuId missing `shouldBe` [Control.cuId bob]
            overLimit <- Admin.userLimitWarning cfg control
            case overLimit of
                Just message -> message `shouldSatisfy` T.isInfixOf "EZA_MAX_USERS"
                Nothing -> expectationFailure "two enabled accounts over a limit of one must warn"

    it "deletes an account and its library only when delete_db is true" $
        withTwoUsers $ \server alice _bob -> do
            (session, csrf) <- loginAs server "alice" "alice password"
            carol <- createTestUser server "carol" "carol password" Control.RoleMember
            let carolPath = "/api/v1/admin/users/" <> show (Control.cuId carol)
            noConfirm <-
                httpRequest
                    server
                    "DELETE"
                    carolPath
                    (authHeaders session csrf)
                    (Just (encode (object ["delete_db" .= True])))
            noConfirm `shouldHaveStatus` 400
            kept <-
                httpRequest
                    server
                    "DELETE"
                    carolPath
                    (authHeaders session csrf)
                    (Just (encode (object ["confirm" .= True, "delete_db" .= False])))
            kept `shouldHaveStatus` 200
            doesFileExist (Control.cuDbPath carol) `shouldReturn` True
            -- A second account can be removed together with its library.
            dave <- createTestUser server "dave" "dave password" Control.RoleMember
            removed <-
                httpRequest
                    server
                    "DELETE"
                    ("/api/v1/admin/users/" <> show (Control.cuId dave))
                    (authHeaders session csrf)
                    (Just (encode (object ["confirm" .= True, "delete_db" .= True])))
            removed `shouldHaveStatus` 200
            doesFileExist (Control.cuDbPath dave) `shouldReturn` False
            users <- withControlUsers (tsConfig server) Control.listUsers
            map Control.cuUsername users `shouldBe` ["alice", "bob"]
            -- Self-delete is refused before any files change.
            selfDelete <-
                httpRequest
                    server
                    "DELETE"
                    ("/api/v1/admin/users/" <> show (Control.cuId alice))
                    (authHeaders session csrf)
                    (Just (encode (object ["confirm" .= True])))
            selfDelete `shouldHaveStatus` 409
            hrespBody selfDelete `shouldSatisfy` containsText "self_disable"

    it "imports an eza JSON document through both the JSON and multipart routes" $
        withTwoUsers $ \server _alice _bob -> do
            (session, csrf) <- loginAs server "alice" "alice password"
            let document =
                    "{\"format\":\"eza-json\",\"version\":2,"
                        <> "\"bookmarks\":[{\"url\":\"https://example.test/json-import\",\"title\":\"JSON import\",\"tags\":[\"json\"]}]}"
            direct <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/import/json"
                    (("Content-Type", "application/json") : authHeaders session csrf)
                    (Just (LBS.fromStrict (TE.encodeUtf8 document)))
            direct `shouldHaveStatus` 200
            multipart <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/import"
                    (("Content-Type", "multipart/form-data; boundary=EzaTest") : authHeaders session csrf)
                    ( Just
                        ( LBS.fromStrict
                            ( TE.encodeUtf8
                                ( "--EzaTest\r\nContent-Disposition: form-data; name=\"file\"; filename=\"eza.json\"\r\nContent-Type: application/json\r\n\r\n"
                                    <> document
                                    <> "\r\n--EzaTest--\r\n"
                                )
                            )
                        )
                    )
            multipart `shouldHaveStatus` 200
            hrespBody multipart `shouldSatisfy` containsText "json_report"
            listed <- httpRequest server "GET" "/api/v1/bookmarks?limit=10" (cookieHeaders session csrf) Nothing
            listed `shouldHaveStatus` 200
            hrespBody listed `shouldSatisfy` containsText "JSON import"

-- | Enqueue a snapshot job and return its id (the response is now 202).
snapshot :: TestServer -> T.Text -> T.Text -> Int -> IO Int
snapshot server session csrf bookmarkId = do
    response <-
        httpRequest
            server
            "POST"
            ("/api/v1/bookmarks/" <> show bookmarkId <> "/snapshot")
            (authHeaders session csrf)
            Nothing
    response `shouldHaveStatus` 202
    pure (fromMaybe 0 (jsonIntField "job_id" (hrespBody response)))

snapshotPathOf :: TestServer -> T.Text -> T.Text -> Int -> IO FilePath
snapshotPathOf server session csrf jobId = do
    response <- httpRequest server "GET" ("/api/v1/jobs/" <> show jobId) (cookieHeaders session csrf) Nothing
    response `shouldHaveStatus` 200
    case jsonField "result" (hrespBody response) of
        Just (Object result) -> case KeyMap.lookup "snapshot" result of
            Just (Object snapshotObject) ->
                case KeyMap.lookup "path" snapshotObject of
                    Just (String path) -> pure (T.unpack path)
                    _ -> expectationFailure "job result has no snapshot path" >> error "unreachable"
            _ -> expectationFailure "job result has no snapshot" >> error "unreachable"
        _ -> expectationFailure "job result is missing" >> error "unreachable"

loginResponse :: TestServer -> T.Text -> T.Text -> IO HttpResponse
loginResponse server username password =
    httpRequest
        server
        "POST"
        "/api/auth/login"
        jsonHeaders
        (Just (encode (object ["username" .= username, "password" .= password])))

withControlUsers :: Config -> (Sqlite.Connection -> IO a) -> IO a
withControlUsers cfg action =
    Control.openControlDb (cfgControlDbPath cfg) >>= \conn -> action conn `finally` Sqlite.close conn

{- | A server whose monolith is a tiny shell script that writes a snapshot
file, so the capture path can be exercised without network access.
-}
withSnapshotServer :: (TestServer -> IO a) -> IO a
withSnapshotServer =
    withTestServerCustom
        (\cfg -> cfg{cfgMonolith = cfgDataDir cfg </> "fake-monolith.sh", cfgAllowPrivateFetch = True})
        ( \cfg -> do
            let script = cfgMonolith cfg
            writeFile
                script
                "#!/bin/sh\nprintf '<html><body>snapshot</body></html>' > \"$2\"\nexit 0\n"
            setFileMode script (executableMode)
        )
  where
    executableMode =
        ownerReadMode
            `unionFileModes` ownerWriteMode
            `unionFileModes` ownerExecuteMode
            `unionFileModes` groupReadMode
            `unionFileModes` groupExecuteMode
            `unionFileModes` otherReadMode
            `unionFileModes` otherExecuteMode
