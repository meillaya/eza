{-# LANGUAGE OverloadedStrings #-}

{- | Multi-user isolation tests for the M3a control plane: tokens, sessions,
shares, the legacy fallback, recovery, and the Authz matrix.
-}
module IsolationSpec (spec) where

import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64.URL as B64
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.SQLite.Simple as Sqlite
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Hspec

import qualified Eza.Auth as Auth
import Eza.Config (Config (..))
import qualified Eza.Control as Control
import qualified Eza.Db as Db
import qualified Eza.Password as Password
import Eza.Server (userSlotCount)
import qualified Eza.TokenPrefix as TokenPrefix
import TestHarness

-- ---------------------------------------------------------------------------
-- Token tampering helpers
-- ---------------------------------------------------------------------------

rewriteSessionPrefix :: Int -> Text -> Text
rewriteSessionPrefix userId wire = case TokenPrefix.splitUserPrefix wire of
    Just (_, bare) -> TokenPrefix.withUserPrefix TokenPrefix.sessionPrefix userId bare
    Nothing -> wire

rewriteApiPrefix :: Int -> Text -> Text
rewriteApiPrefix userId wire = case T.stripPrefix "eza_pat_" wire of
    Just rest ->
        let withoutId = T.drop 1 (T.dropWhile (/= '_') rest)
         in TokenPrefix.withUserPrefix TokenPrefix.apiTokenPrefix userId withoutId
    Nothing -> wire

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "M3a multi-user isolation" $ do
    it "keeps each account's library and session in its own database" $
        withTwoUsers $ \server alice bob -> do
            (sessionA, csrfA) <- loginAs server "alice" "alice password"
            sessionA `shouldSatisfy` T.isPrefixOf ("u" <> T.pack (show (Control.cuId alice)) <> "_")
            addTestBookmark server sessionA csrfA 1
            aliceBoot <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders sessionA csrfA) Nothing
            aliceBoot `shouldHaveStatus` 200
            bootTotal (hrespBody aliceBoot) `shouldBe` Just 1

            (sessionB, csrfB) <- loginAs server "bob" "bob password"
            sessionB `shouldSatisfy` T.isPrefixOf ("u" <> T.pack (show (Control.cuId bob)) <> "_")
            bobBoot <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders sessionB csrfB) Nothing
            bobBoot `shouldHaveStatus` 200
            bootTotal (hrespBody bobBoot) `shouldBe` Just 0
            bobTotal <- listTotal server sessionB csrfB
            bobTotal `shouldBe` 0
            aliceTotal <- listTotal server sessionA csrfA
            aliceTotal `shouldBe` 1

    it "rejects a session token whose user prefix was rewritten" $
        withTwoUsers $ \server _ bob -> do
            (sessionA, csrfA) <- loginAs server "alice" "alice password"
            _ <- listTotal server sessionA csrfA
            let toBob = rewriteSessionPrefix (Control.cuId bob) sessionA
                toNobody = rewriteSessionPrefix 9999 sessionA
            tampered <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders toBob csrfA) Nothing
            tampered `shouldHaveStatus` 401
            missing <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders toNobody csrfA) Nothing
            missing `shouldHaveStatus` 401

    it "binds an API token to its account and rejects a rewritten prefix" $
        withTwoUsers $ \server alice bob -> do
            (sessionA, csrfA) <- loginAs server "alice" "alice password"
            addTestBookmark server sessionA csrfA 1
            created <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/tokens"
                    (authHeaders sessionA csrfA)
                    (Just (encode (object ["name" .= ("cli" :: Text)])))
            created `shouldHaveStatus` 201
            token <- expectJust "token" (jsonTextField "token" (hrespBody created))
            token `shouldSatisfy` T.isPrefixOf ("eza_pat_u" <> T.pack (show (Control.cuId alice)) <> "_")
            let bearer value = ("Authorization", TE.encodeUtf8 ("Bearer " <> value))
            ok <- httpRequest server "GET" "/api/v1/bookmarks" [bearer token] Nothing
            ok `shouldHaveStatus` 200
            tokenTotal <- expectJust "token total" (jsonIntField "total" (hrespBody ok))
            tokenTotal `shouldBe` 1
            let toBob = rewriteApiPrefix (Control.cuId bob) token
            rejected <- httpRequest server "GET" "/api/v1/bookmarks" [bearer toBob] Nothing
            rejected `shouldHaveStatus` 401

    it "applies the Authz matrix to session-only and admin routes" $
        withTwoUsers $ \server _ _ -> do
            (sessionA, csrfA) <- loginAs server "alice" "alice password"
            (sessionB, csrfB) <- loginAs server "bob" "bob password"
            created <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/tokens"
                    (authHeaders sessionA csrfA)
                    (Just (encode (object ["name" .= ("cli" :: Text)])))
            created `shouldHaveStatus` 201
            token <- expectJust "token" (jsonTextField "token" (hrespBody created))
            let bearer value = ("Authorization", TE.encodeUtf8 ("Bearer " <> value))
            -- A bearer token may not use the session-only webhook routes ...
            tokenOnWebhooks <- httpRequest server "GET" "/api/v1/webhooks" [bearer token] Nothing
            tokenOnWebhooks `shouldHaveStatus` 403
            -- ... while the same request from a normal session is allowed.
            sessionOnWebhooks <- httpRequest server "GET" "/api/v1/webhooks" (cookieHeaders sessionA csrfA) Nothing
            sessionOnWebhooks `shouldHaveStatus` 200
            -- A member session may not use the admin namespace.
            memberOnAdmin <- httpRequest server "GET" "/api/v1/admin/users" (cookieHeaders sessionB csrfB) Nothing
            memberOnAdmin `shouldHaveStatus` 403
            -- An admin session passes the matrix and reaches the admin API.
            adminOnAdmin <- httpRequest server "GET" "/api/v1/admin/users" (cookieHeaders sessionA csrfA) Nothing
            adminOnAdmin `shouldHaveStatus` 200

    it "serves a share link from the owning database and rejects a rewritten prefix" $
        withTwoUsers $ \server _ bob -> do
            (sessionA, csrfA) <- loginAs server "alice" "alice password"
            createdBookmark <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/bookmarks"
                    (authHeaders sessionA csrfA)
                    (Just (encode (object ["url" .= ("https://alice.example/shared" :: Text), "title" .= ("Alice shared entry" :: Text)])))
            createdBookmark `shouldHaveStatus` 201
            bookmarkId <- expectJust "bookmark id" (jsonIntField "id" (hrespBody createdBookmark))
            createdShare <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/share-links"
                    (authHeaders sessionA csrfA)
                    (Just (encode (object ["scope" .= ("bookmark" :: Text), "target_id" .= bookmarkId])))
            createdShare `shouldHaveStatus` 201
            shareUrl <- expectJust "share url" (jsonTextField "url" (hrespBody createdShare))
            let pathOf url = "/s/" <> T.unpack (last (T.splitOn "/s/" url))
            page <- httpRequest server "GET" (pathOf shareUrl) [] Nothing
            page `shouldHaveStatus` 200
            hrespBody page `shouldSatisfy` containsText "Alice shared entry"
            let token = last (T.splitOn "/s/" shareUrl)
                tampered = rewriteSessionPrefix (Control.cuId bob) token
            rejected <- httpRequest server "GET" ("/s/" <> T.unpack tampered) [] Nothing
            rejected `shouldHaveStatus` 404

    it "accepts an unprefixed legacy token only while one enabled account exists" $
        withTestServer $ \server -> do
            alice <- createTestUser server "alice" "alice password" Control.RoleAdmin
            legacyConn <- Db.openDb (Control.cuDbPath alice)
            legacySession <- Auth.createSession legacyConn "normal" 3600
            Sqlite.close legacyConn
            let rawToken = Auth.nsToken legacySession
                getBoot =
                    httpRequest
                        server
                        "GET"
                        "/api/v1/boot"
                        [("Cookie", TE.encodeUtf8 ("eza_session=" <> rawToken))]
                        Nothing
            single <- getBoot
            single `shouldHaveStatus` 200
            _ <- createTestUser server "bob" "bob password" Control.RoleMember
            ambiguous <- getBoot
            ambiguous `shouldHaveStatus` 401

    it "rejects a session for a disabled account" $
        withTestServer $ \server -> do
            alice <- createTestUser server "alice" "alice password" Control.RoleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            beforeDisable <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders session csrf) Nothing
            beforeDisable `shouldHaveStatus` 200
            disabled <- Control.setUserDisabled (tsControl server) (Control.cuId alice) True
            disabled `shouldBe` True
            afterDisable <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders session csrf) Nothing
            afterDisable `shouldHaveStatus` 401

    it "requires a username to redeem a recovery code" $
        withTestServer $ \server -> do
            alice <- createTestUser server "alice" "alice password" Control.RoleAdmin
            recoveryConn <- Db.openDb (Control.cuDbPath alice)
            codes <- Auth.regenerateRecoveryCodes recoveryConn
            Sqlite.close recoveryConn
            code <- case codes of
                (firstCode : _) -> pure firstCode
                [] -> expectationFailure "expected recovery codes" >> error "unreachable"
            missing <- httpRequest server "POST" "/api/recovery/redeem" jsonHeaders (Just (encode (object ["code" .= code])))
            missing `shouldHaveStatus` 400
            unknown <- httpRequest server "POST" "/api/recovery/redeem" jsonHeaders (Just (encode (object ["username" .= ("nobody" :: Text), "code" .= code])))
            unknown `shouldHaveStatus` 400
            redeemed <-
                httpRequest
                    server
                    "POST"
                    "/api/recovery/redeem"
                    jsonHeaders
                    (Just (encode (object ["username" .= ("alice" :: Text), "code" .= code])))
            redeemed `shouldHaveStatus` 200
            session <- expectJust "recovery session" (setCookieValue redeemed Auth.sessionCookieName)
            csrf <- expectJust "recovery csrf" (setCookieValue redeemed Auth.csrfCookieName)
            session `shouldSatisfy` T.isPrefixOf ("u" <> T.pack (show (Control.cuId alice)) <> "_")
            setupPage <- httpRequest server "GET" "/setup" (cookieHeaders session csrf) Nothing
            setupPage `shouldHaveStatus` 200
            hrespBody setupPage `shouldSatisfy` containsText "recovery"
            finished <-
                httpRequest
                    server
                    "POST"
                    "/api/setup/password"
                    (authHeaders session csrf)
                    (Just (encode (object ["username" .= ("alice-renamed" :: Text), "password" .= ("new alice password" :: Text), "confirm" .= ("new alice password" :: Text)])))
            finished `shouldHaveStatus` 200
            -- The recovery setup may change the username; the control row is
            -- the login lookup source and has to follow it.
            renamed <- Control.lookupUserByUsername (tsControl server) "alice-renamed"
            renamed `shouldSatisfy` isJust
            stale <-
                httpRequest
                    server
                    "POST"
                    "/api/auth/login"
                    jsonHeaders
                    (Just (encode (object ["username" .= ("alice" :: Text), "password" .= ("new alice password" :: Text)])))
            stale `shouldHaveStatus` 401
            _ <- loginAs server "alice-renamed" "new alice password"
            pure ()

    it "returns the same generic error for an unknown username and a wrong password" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            unknown <-
                httpRequest
                    server
                    "POST"
                    "/api/auth/login"
                    jsonHeaders
                    (Just (encode (object ["username" .= ("nobody" :: Text), "password" .= ("some password" :: Text)])))
            wrong <-
                httpRequest
                    server
                    "POST"
                    "/api/auth/login"
                    jsonHeaders
                    (Just (encode (object ["username" .= ("alice" :: Text), "password" .= ("wrong password" :: Text)])))
            unknown `shouldHaveStatus` 401
            wrong `shouldHaveStatus` 401
            hrespBody unknown `shouldBe` hrespBody wrong

    it "claims users/1/eza.db on a fresh setup and leaves an unclaimed legacy file alone"
        $ withTestServerConfig
            (\cfg -> Db.initDb (cfgDbPath cfg))
        $ \server -> do
            unauthenticated <- httpRequest server "GET" "/" [] Nothing
            unauthenticated `shouldHaveStatus` 302
            headerValue unauthenticated "Location" `shouldBe` Just "/login"
            loginPage <- httpRequest server "GET" "/login" [] Nothing
            loginPage `shouldHaveStatus` 302
            headerValue loginPage "Location" `shouldBe` Just "/setup"
            setupPage <- httpRequest server "GET" "/setup" [] Nothing
            setupPage `shouldHaveStatus` 200
            finished <-
                httpRequest
                    server
                    "POST"
                    "/api/setup/password"
                    jsonHeaders
                    (Just (encode (object ["username" .= ("owner" :: Text), "password" .= ("fresh owner password" :: Text), "confirm" .= ("fresh owner password" :: Text)])))
            finished `shouldHaveStatus` 200
            session <- expectJust "session cookie" (setCookieValue finished Auth.sessionCookieName)
            session `shouldSatisfy` T.isPrefixOf "u1_"
            users <- Control.listUsers (tsControl server)
            length users `shouldBe` 1
            case users of
                (user : _) -> do
                    Control.cuId user `shouldBe` 1
                    Control.cuRole user `shouldBe` Control.RoleAdmin
                    Control.cuDbPath user `shouldBe` cfgUsersDir (tsConfig server) </> "1" </> "eza.db"
                [] -> expectationFailure "expected the first account"
            freshExists <- doesFileExist (cfgUsersDir (tsConfig server) </> "1" </> "eza.db")
            freshExists `shouldBe` True
            -- The legacy file still exists because it was never claimed;
            -- the fresh account uses the per-user path instead.
            legacyExists <- doesFileExist (cfgDbPath (tsConfig server))
            legacyExists `shouldBe` True
            legacyConn <- Sqlite.open (cfgDbPath (tsConfig server))
            legacyClaimed <- Auth.setupClaimed legacyConn
            Sqlite.close legacyConn
            legacyClaimed `shouldBe` False
            csrf <- expectJust "csrf cookie" (setCookieValue finished Auth.csrfCookieName)
            boot <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders session csrf) Nothing
            boot `shouldHaveStatus` 200
            bootTotal (hrespBody boot) `shouldBe` Just 0
            (loginSession, loginCsrf) <- loginAs server "owner" "fresh owner password"
            loginSession `shouldSatisfy` T.isPrefixOf "u1_"
            afterLoginPage <- httpRequest server "GET" "/login" (cookieHeaders loginSession loginCsrf) Nothing
            afterLoginPage `shouldHaveStatus` 302
            headerValue afterLoginPage "Location" `shouldBe` Just "/"

    it "gives each account a distinct WebAuthn user handle in passkey options" $
        withTwoUsers $ \server alice bob -> do
            aliceHandle <- expectJust "alice handle" (Control.cuCredentialHandle alice)
            bobHandle <- expectJust "bob handle" (Control.cuCredentialHandle bob)
            BS.length aliceHandle `shouldBe` 16
            aliceHandle `shouldNotBe` bobHandle
            let ac = testAuthConfig (tsConfig server)
            aliceConn <- Db.openDb (Control.cuDbPath alice)
            aliceOptions <- Auth.addPasskeyOptions aliceConn ac aliceHandle
            Sqlite.close aliceConn
            case aliceOptions of
                Left err -> expectationFailure ("passkey options failed: " <> show err)
                Right value -> do
                    let encoded = LBS.toStrict (encode value)
                        aliceB64 = B64.encodeUnpadded aliceHandle
                        bobB64 = B64.encodeUnpadded bobHandle
                    encoded `shouldSatisfy` BS.isInfixOf aliceB64
                    encoded `shouldSatisfy` (not . BS.isInfixOf bobB64)

    it "registers an already-claimed legacy database under its own username"
        $ withTestServerConfig
            ( \cfg -> do
                legacy <- Db.openDb (cfgDbPath cfg)
                stored <- Password.hashPassword (cfgArgon2 cfg) "legacy password"
                _ <- Auth.completeSetup legacy "legacyuser" stored
                Sqlite.close legacy
            )
        $ \server -> do
            users <- Control.listUsers (tsControl server)
            length users `shouldBe` 1
            case users of
                (user : _) -> do
                    Control.cuUsername user `shouldBe` "legacyuser"
                    Control.cuRole user `shouldBe` Control.RoleAdmin
                    Control.cuDbPath user `shouldBe` cfgDbPath (tsConfig server)
                    Control.cuCredentialHandle user `shouldSatisfy` isJust
                [] -> expectationFailure "expected one migrated account"
            exists <- doesFileExist (cfgDbPath (tsConfig server))
            exists `shouldBe` True
            freshDbExists <- doesFileExist (cfgUsersDir (tsConfig server) </> "1" </> "eza.db")
            freshDbExists `shouldBe` False
            (session, csrf) <- loginAs server "legacyuser" "legacy password"
            session `shouldSatisfy` T.isPrefixOf "u1_"
            boot <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders session csrf) Nothing
            boot `shouldHaveStatus` 200

    it "repairs the placeholder owner name from an earlier migration"
        $ withTestServerConfig
            ( \cfg -> do
                legacy <- Db.openDb (cfgDbPath cfg)
                stored <- Password.hashPassword (cfgArgon2 cfg) "legacy password"
                _ <- Auth.completeSetup legacy "meillaya" stored
                Sqlite.close legacy
                control <- Control.openControlDb (cfgControlDbPath cfg)
                _ <- Control.createUser control "owner" (cfgDbPath cfg) Control.RoleAdmin Nothing
                Sqlite.close control
            )
        $ \server -> do
            users <- Control.listUsers (tsControl server)
            map Control.cuUsername users `shouldBe` ["meillaya"]
            (session, _csrf) <- loginAs server "meillaya" "legacy password"
            session `shouldSatisfy` T.isPrefixOf "u1_"

    it "opens one slot per account and reuses it across reads and writes" $
        withTwoUsers $ \server _ _ -> do
            (sessionA, csrfA) <- loginAs server "alice" "alice password"
            (sessionB, csrfB) <- loginAs server "bob" "bob password"
            addTestBookmark server sessionA csrfA 1
            addTestBookmark server sessionB csrfB 1
            _ <- listTotal server sessionA csrfA
            _ <- listTotal server sessionB csrfB
            _ <- listTotal server sessionA csrfA
            slots <- userSlotCount (tsState server)
            slots `shouldBe` 2
            (sessionC, csrfC) <- loginAs server "alice" "alice password"
            _ <- listTotal server sessionC csrfC
            slotsAfter <- userSlotCount (tsState server)
            slotsAfter `shouldBe` 2
