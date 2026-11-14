{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Phase A security regression tests.

Covers the four verified defects and their hardening together with the
request-surface controls that must stay intact:

  * S1 static asset path traversal (@..%2f@ / @%2e%2e%2f@ / backslash forms),
  * S2 snapshot capture public-address policy, size cap, and opaque value,
  * S3 the private-address range table (including the CGNAT range),
  * S4 request-body limits: declared oversize on JSON mutations, the larger
    import cap, and a normal multipart import,
  * S5 CSRF for a recovery-session password setup,
  * S6 identical 401/429 sequences for known and unknown usernames.

The traversal tests speak raw HTTP over a socket because an HTTP client
normalises @..@ segments before sending them; that would hide the bypass.
-}
module SecuritySpec (spec) where

import Control.Exception (bracket)
import Data.Aeson (Value (..))
import qualified Data.Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Bits (shiftL, (.|.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word32, Word8)
import Database.SQLite.Simple (Only (..))
import qualified Database.SQLite.Simple as Sqlite
import Network.HTTP.Types (HeaderName)
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as SocketBS
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (ownerExecuteMode, ownerReadMode, ownerWriteMode, setFileMode, unionFileModes)
import System.Timeout (timeout)
import Test.Hspec

import qualified Eza.Auth as Auth
import Eza.Config (Config (..))
import qualified Eza.Control as Control
import qualified Eza.Db as Db
import Eza.Fetch (FetchError (..), assertPublicHostPolicy, publicV4, publicV6)
import TestHarness

spec :: Spec
spec = describe "Phase A security fixes" $ do
    staticAssetSpec
    snapshotSpec
    privateRangeSpec
    bodyLimitSpec
    recoveryCsrfSpec
    loginEnumerationSpec

-- ---------------------------------------------------------------------------
-- S1: static asset path traversal
-- ---------------------------------------------------------------------------

{- | A server whose static root holds one real asset, with a secret file just
outside that root. The traversal must never serve the secret.
-}
withStaticServer :: (TestServer -> FilePath -> IO a) -> IO a
withStaticServer action =
    withSystemTempDirectory "eza-security-static" $ \dir -> do
        let root = dir </> "static"
            secret = dir </> "secret.txt"
        -- The server now requires a validated asset bundle at startup, so the
        -- fixture writes the same manifest/concrete-file shape the bundler
        -- emits instead of one loose eza.css.
        writeTestStaticBundle root
        BS.writeFile secret "TOP-SECRET-STATIC-PROBE"
        withTestServerCustom (\cfg -> cfg{cfgStaticDir = Just root}) (\_ -> pure ()) $ \server ->
            action server secret

staticAssetSpec :: Spec
staticAssetSpec = describe "S1 static asset path traversal" $ do
    it "serves a normal asset and rejects encoded ..%2f traversal" $
        withStaticServer $ \server secret -> do
            normal <- httpRequest server "GET" (T.unpack testBundleCssPath) [] Nothing
            normal `shouldHaveStatus` 200
            hrespBody normal `shouldSatisfy` containsText "/* eza test asset */"

            first <- rawGet server "/assets/..%2fsecret.txt"
            assertUnsafe first secret

            dotted <- rawGet server "/assets/%2e%2e%2fsecret.txt"
            assertUnsafe dotted secret

    it "rejects a percent-encoded backslash and deeper traversal" $
        withStaticServer $ \server secret -> do
            backslash <- rawGet server "/assets/..%5csecret.txt"
            assertUnsafe backslash secret

            passwd <- rawGet server "/assets/..%2f..%2f..%2f..%2fetc%2fpasswd"
            let (status, body) = unwrapRaw passwd
            status `shouldSatisfy` (\value -> value == 400 || value == 404)
            body `shouldSatisfy` (not . BSC.isInfixOf "root:")
  where
    -- The traversal answers 400 before any filesystem call; the file must
    -- never reach the response either way.
    assertUnsafe result secret = do
        let (status, body) = unwrapRaw result
        status `shouldSatisfy` (\value -> value == 400 || value == 404)
        body `shouldSatisfy` (not . BSC.isInfixOf "TOP-SECRET-STATIC-PROBE")
        secret `seq` pure ()

-- ---------------------------------------------------------------------------
-- S2: snapshot capture address policy, size cap, and opaque value
-- ---------------------------------------------------------------------------

withSnapshotServer :: BS.ByteString -> (Config -> Config) -> (TestServer -> IO a) -> IO a
withSnapshotServer payload adjust action =
    withTestServerCustom
        (\cfg -> adjust cfg{cfgMonolith = cfgDataDir cfg </> "fake-monolith.sh"})
        ( \cfg -> do
            writeFile (cfgMonolith cfg) (monolithScript payload)
            setFileMode (cfgMonolith cfg) executableMode
        )
        action
  where
    executableMode =
        ownerReadMode
            `unionFileModes` ownerWriteMode
            `unionFileModes` ownerExecuteMode

{- | A stand-in with the monolith command contract: it writes its output to the
@-o@ path and ignores the source URL (which is what the address policy is
supposed to reject before this ever runs).
-}
monolithScript :: BS.ByteString -> String
monolithScript payload =
    "#!/bin/sh\nprintf '%s' '" <> BSC.unpack payload <> "' > \"$2\"\nexit 0\n"

snapshotSpec :: Spec
snapshotSpec = describe "S2 snapshot capture (async job)" $ do
    it "refuses a loopback bookmark URL and spawns nothing" $
        withSnapshotServer "<html><body>snapshot body</body></html>" id $ \server -> do
            user <- createTestUser server "alice" "alice password" Control.RoleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            bookmarkId <- addBookmarkWith server session csrf "http://127.0.0.1:9/internal"
            jobId <- enqueueSnapshot server session csrf bookmarkId
            runEgressJob server "alice" jobId
            jobState server session csrf jobId `shouldReturn` Just "failed"
            reason <- jobError server session csrf jobId
            reason `shouldSatisfy` maybe False (T.isInfixOf "could not be captured")
            let file = snapshotDir (tsConfig server) (Control.cuId user) </> show bookmarkId <> ".html"
            exists <- doesFileExist file
            exists `shouldBe` False

    it "allows a public address, stores an absolute path, and serves the file" $
        withSnapshotServer "<html><body>snapshot body</body></html>" id $ \server -> do
            user <- createTestUser server "alice" "alice password" Control.RoleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            bookmarkId <- addBookmarkWith server session csrf "http://93.184.216.34/page"
            jobId <- enqueueSnapshot server session csrf bookmarkId
            runEgressJob server "alice" jobId
            jobState server session csrf jobId `shouldReturn` Just "done"
            path <- jobSnapshotPath server session csrf jobId
            let file = snapshotFile (tsConfig server) (Control.cuId user) bookmarkId
            path `shouldBe` Just (T.pack file)
            (T.pack file `T.isSuffixOf` fromMaybe "" path) `shouldBe` True
            bytes <- jobSnapshotBytes server session csrf jobId
            bytes `shouldSatisfy` maybe False (> 0)
            stored <- storedSnapshotPath server "alice" bookmarkId
            stored `shouldBe` Just (T.pack file)
            served <- httpRequest server "GET" ("/api/v1/bookmarks/" <> show bookmarkId <> "/snapshot") (cookieHeaders session csrf) Nothing
            served `shouldHaveStatus` 200
            hrespBody served `shouldSatisfy` containsText "snapshot body"

    it "honours EZA_ALLOW_PRIVATE_FETCH for snapshot sources" $
        withSnapshotServer "<html><body>snapshot body</body></html>" (\cfg -> cfg{cfgAllowPrivateFetch = True}) $ \server -> do
            user <- createTestUser server "alice" "alice password" Control.RoleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            bookmarkId <- addBookmarkWith server session csrf "http://127.0.0.1:9/internal"
            jobId <- enqueueSnapshot server session csrf bookmarkId
            runEgressJob server "alice" jobId
            jobState server session csrf jobId `shouldReturn` Just "done"
            let file = snapshotFile (tsConfig server) (Control.cuId user) bookmarkId
            exists <- doesFileExist file
            exists `shouldBe` True

    it "refuses a non-http(s) bookmark URL" $
        withSnapshotServer "<html><body>snapshot body</body></html>" id $ \server -> do
            user <- createTestUser server "alice" "alice password" Control.RoleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            bookmarkId <- insertRawBookmark server "alice" "javascript:alert(1)"
            jobId <- enqueueSnapshot server session csrf bookmarkId
            runEgressJob server "alice" jobId
            jobState server session csrf jobId `shouldReturn` Just "failed"
            let file = snapshotFile (tsConfig server) (Control.cuId user) bookmarkId
            exists <- doesFileExist file
            exists `shouldBe` False

    it "discards an oversized capture and keeps no snapshot"
        $ withSnapshotServer
            (BS.replicate 64 0x78)
            (\cfg -> cfg{cfgSnapshotMaxBytes = 16})
        $ \server -> do
            user <- createTestUser server "alice" "alice password" Control.RoleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            bookmarkId <- addBookmarkWith server session csrf "http://93.184.216.34/page"
            jobId <- enqueueSnapshot server session csrf bookmarkId
            runEgressJob server "alice" jobId
            jobState server session csrf jobId `shouldReturn` Just "failed"
            let file = snapshotFile (tsConfig server) (Control.cuId user) bookmarkId
            exists <- doesFileExist file
            exists `shouldBe` False
            stored <- storedSnapshotPath server "alice" bookmarkId
            stored `shouldBe` Just ""

enqueueSnapshot :: TestServer -> Text -> Text -> Int -> IO Int
enqueueSnapshot server session csrf bookmarkId = do
    captured <- captureSnapshotWith server session csrf bookmarkId
    captured `shouldHaveStatus` 202
    pure (fromMaybe 0 (jsonIntField "job_id" (hrespBody captured)))

captureSnapshotWith :: TestServer -> Text -> Text -> Int -> IO HttpResponse
captureSnapshotWith server session csrf bookmarkId =
    httpRequest
        server
        "POST"
        ("/api/v1/bookmarks/" <> show bookmarkId <> "/snapshot")
        (authHeaders session csrf)
        (Just "{}")

jobBody :: TestServer -> Text -> Text -> Int -> IO LBS.ByteString
jobBody server session csrf jobId = do
    response <- httpRequest server "GET" ("/api/v1/jobs/" <> show jobId) (cookieHeaders session csrf) Nothing
    response `shouldHaveStatus` 200
    pure (hrespBody response)

jobState :: TestServer -> Text -> Text -> Int -> IO (Maybe Text)
jobState server session csrf jobId = jsonTextField "state" <$> jobBody server session csrf jobId

jobError :: TestServer -> Text -> Text -> Int -> IO (Maybe Text)
jobError server session csrf jobId = jsonTextField "error" <$> jobBody server session csrf jobId

jobSnapshotObject :: TestServer -> Text -> Text -> Int -> IO (Maybe Value)
jobSnapshotObject server session csrf jobId = do
    body <- jobBody server session csrf jobId
    pure $ case jsonField "result" body of
        Just (Object result) -> KeyMap.lookup "snapshot" result
        _ -> Nothing

jobSnapshotPath :: TestServer -> Text -> Text -> Int -> IO (Maybe Text)
jobSnapshotPath server session csrf jobId = do
    object <- jobSnapshotObject server session csrf jobId
    pure (jsonTextField "path" (maybe "null" Data.Aeson.encode object))

jobSnapshotBytes :: TestServer -> Text -> Text -> Int -> IO (Maybe Int)
jobSnapshotBytes server session csrf jobId = do
    object <- jobSnapshotObject server session csrf jobId
    pure (jsonIntField "bytes" (maybe "null" Data.Aeson.encode object))

addBookmarkWith :: TestServer -> Text -> Text -> Text -> IO Int
addBookmarkWith server session csrf url = do
    response <-
        httpRequest
            server
            "POST"
            "/api/v1/bookmarks"
            (authHeaders session csrf)
            (Just (encodeJsonObject [("url", url), ("title", "audit")]))
    response `shouldHaveStatus` 201
    expectJust "bookmark id" (jsonIntField "id" (hrespBody response))

snapshotDir :: Config -> Int -> FilePath
snapshotDir cfg userId = cfgUsersDir cfg </> show userId </> "snapshots"

snapshotFile :: Config -> Int -> Int -> FilePath
snapshotFile cfg userId bookmarkId =
    snapshotDir cfg userId </> show bookmarkId <> ".html"

withUserDb :: TestServer -> Text -> (Sqlite.Connection -> IO a) -> IO a
withUserDb server username =
    bracket (Db.openDb (userDbPath server username)) Sqlite.close

storedSnapshotPath :: TestServer -> Text -> Int -> IO (Maybe Text)
storedSnapshotPath server username bookmarkId =
    withUserDb server username $ \conn -> do
        rows <-
            Sqlite.query
                conn
                "SELECT snapshot_path FROM bookmarks WHERE id = ?"
                (Only bookmarkId) ::
                IO [Only Text]
        pure $ case rows of
            (Only value : _) -> Just value
            [] -> Nothing

{- | A bookmark the public API would refuse: a non-http scheme, inserted
directly so the snapshot guard is what rejects it.
-}
insertRawBookmark :: TestServer -> Text -> Text -> IO Int
insertRawBookmark server username url =
    withUserDb server username $ \conn -> do
        Sqlite.execute
            conn
            "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES (?,?,?,1,1,1)"
            (url, "raw" :: Text, "raw" :: Text)
        fromIntegral <$> Sqlite.lastInsertRowId conn

-- | A tiny JSON object of string fields; the tests only send flat strings.
encodeJsonObject :: [(Text, Text)] -> LBS.ByteString
encodeJsonObject fields =
    LBS.fromStrict
        ( TE.encodeUtf8 "{"
            <> BS.intercalate
                ","
                [TE.encodeUtf8 ("\"" <> key <> "\":\"" <> value <> "\"") | (key, value) <- fields]
            <> TE.encodeUtf8 "}"
        )

-- ---------------------------------------------------------------------------
-- S3: private-address table
-- ---------------------------------------------------------------------------

privateRangeSpec :: Spec
privateRangeSpec = describe "S3 private-address ranges" $ do
    it "treats every blocked IPv4 range as private" $
        mapM_
            (\(address, label) -> shouldBeNamed (publicV4 (v4Word address)) False label)
            blockedV4
    it "keeps ordinary public addresses reachable" $
        mapM_
            (\(address, label) -> shouldBeNamed (publicV4 (v4Word address)) True label)
            allowedV4
    it "blocks the IPv4-mapped IPv6 form and the other reserved v6 ranges" $ do
        publicV6 (0, 0, 0xffff, 0x7f000001) `shouldBe` False
        publicV6 (0, 0, 0xffff, 0x0a000001) `shouldBe` False
        publicV6 (0, 0, 0, 0) `shouldBe` False
        publicV6 (0, 0, 0, 1) `shouldBe` False
        publicV6 (0xfc000000, 0, 0, 1) `shouldBe` False
        publicV6 (0xfe800000, 0, 0, 1) `shouldBe` False
        publicV6 (0xff000000, 0, 0, 1) `shouldBe` False
        publicV6 (0x20010db8, 0, 0, 1) `shouldBe` False
        publicV6 (0x26060000, 0, 0, 1) `shouldBe` True
    it "blocks loopback through the public-host policy and honours the opt-in" $ do
        blocked <- assertPublicHostPolicy False "127.0.0.1"
        case blocked of
            Left (FetchBlocked _) -> pure ()
            other -> expectationFailure ("expected a block, got " <> show other)
        allowed <- assertPublicHostPolicy True "127.0.0.1"
        allowed `shouldBe` Right ()

blockedV4 :: [((Word8, Word8, Word8, Word8), String)]
blockedV4 =
    [ ((0, 0, 0, 0), "0.0.0.0/8")
    , ((10, 1, 2, 3), "10.0.0.0/8")
    , ((100, 64, 0, 1), "100.64.0.0/10 lower bound")
    , ((100, 127, 255, 254), "100.64.0.0/10 upper bound")
    , ((127, 0, 0, 1), "127.0.0.0/8")
    , ((169, 254, 169, 254), "169.254.0.0/16")
    , ((172, 16, 0, 1), "172.16.0.0/12 lower bound")
    , ((172, 31, 255, 255), "172.16.0.0/12 upper bound")
    , ((192, 0, 0, 1), "192.0.0.0/24")
    , ((192, 0, 2, 1), "192.0.2.0/24")
    , ((192, 168, 1, 1), "192.168.0.0/16")
    , ((198, 18, 0, 1), "198.18.0.0/15")
    , ((198, 51, 100, 1), "198.51.100.0/24")
    , ((203, 0, 113, 1), "203.0.113.0/24")
    , ((224, 0, 0, 1), "224.0.0.0/4 multicast")
    , ((240, 0, 0, 1), "240.0.0.0/4 reserved")
    , ((255, 255, 255, 255), "broadcast")
    ]

allowedV4 :: [((Word8, Word8, Word8, Word8), String)]
allowedV4 =
    [ ((8, 8, 8, 8), "8.8.8.8")
    , ((11, 0, 0, 1), "just outside 10/8")
    , ((93, 184, 216, 34), "example public address")
    , ((100, 128, 0, 1), "just outside the CGNAT range")
    , ((172, 32, 0, 1), "just outside 172.16/12")
    , ((192, 169, 0, 1), "just outside 192.168/16")
    ]

v4Word :: (Word8, Word8, Word8, Word8) -> Word32
v4Word (a, b, c, d) =
    (fromIntegral a `shiftL` 24)
        .|. (fromIntegral b `shiftL` 16)
        .|. (fromIntegral c `shiftL` 8)
        .|. fromIntegral d

shouldBeNamed :: (Eq a, Show a) => a -> a -> String -> Expectation
shouldBeNamed actual expected label
    | actual == expected = pure ()
    | otherwise = expectationFailure (label <> ": " <> show actual <> " /= " <> show expected)

-- ---------------------------------------------------------------------------
-- S4: request-body limits
-- ---------------------------------------------------------------------------

withSmallBodyServer :: (TestServer -> IO a) -> IO a
withSmallBodyServer =
    withTestServerCustom
        (\cfg -> cfg{cfgMaxBodyBytes = 1024, cfgImportMaxBytes = 8192})
        (\_ -> pure ())

bodyLimitSpec :: Spec
bodyLimitSpec = describe "S4 request-body limits" $ do
    it "answers a declared oversize JSON body with the 413 JSON shape" $
        withSmallBodyServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            let payload = LBS.fromStrict (BS.replicate 4096 0x20)
            response <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/bookmarks"
                    (authHeaders session csrf)
                    (Just payload)
            response `shouldHaveStatus` 413
            hrespBody response `shouldSatisfy` containsText "payload_too_large"
            hrespBody response `shouldSatisfy` containsText "request body must be at most"

    it "keeps normal JSON mutations working under the cap" $
        withSmallBodyServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            response <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/bookmarks"
                    (authHeaders session csrf)
                    (Just (encodeJsonObject [("url", "https://example.test/ok")]))
            response `shouldHaveStatus` 201

    it "lets the import path use the larger import cap and parses a normal multipart import" $
        withSmallBodyServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            -- Larger than cfgMaxBodyBytes but below cfgImportMaxBytes: the
            -- path-aware limit must let it through to the multipart parser.
            let verbose = BS.replicate 2048 0x20
                netscape =
                    "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n<DT><A HREF=\"https://example.test/imported\">Imported</A>\n</DL><p>\n"
                boundary = "--eza-security-boundary"
                body =
                    TE.encodeUtf8 ("--" <> boundary <> "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"bookmarks.html\"\r\nContent-Type: text/html\r\n\r\n")
                        <> TE.encodeUtf8 netscape
                        <> verbose
                        <> TE.encodeUtf8 ("\r\n--" <> boundary <> "--\r\n")
                headers = multipartHeaders session csrf boundary
            response <- httpRequest server "POST" "/api/v1/import" headers (Just (LBS.fromStrict body))
            response `shouldHaveStatus` 200
            hrespBody response `shouldSatisfy` containsText "inserted"

    it "answers an oversize import body with 413" $
        withSmallBodyServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            let boundary = "--eza-security-boundary"
                body =
                    TE.encodeUtf8 ("--" <> boundary <> "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"bookmarks.html\"\r\nContent-Type: text/html\r\n\r\n")
                        <> BS.replicate 16384 0x20
                        <> TE.encodeUtf8 ("\r\n--" <> boundary <> "--\r\n")
                headers = multipartHeaders session csrf boundary
            response <- httpRequest server "POST" "/api/v1/import" headers (Just (LBS.fromStrict body))
            response `shouldHaveStatus` 413
            hrespBody response `shouldSatisfy` containsText "payload_too_large"

multipartHeaders :: Text -> Text -> Text -> [(HeaderName, BS.ByteString)]
multipartHeaders session csrf boundary =
    [ ("Content-Type", TE.encodeUtf8 ("multipart/form-data; boundary=" <> boundary))
    , ("Cookie", TE.encodeUtf8 ("eza_session=" <> session <> "; eza_csrf=" <> csrf))
    , ("X-CSRF-Token", TE.encodeUtf8 csrf)
    ]

-- ---------------------------------------------------------------------------
-- S5: CSRF for a recovery-session password setup
-- ---------------------------------------------------------------------------

recoveryCsrfSpec :: Spec
recoveryCsrfSpec = describe "S5 recovery setup CSRF" $ do
    it "requires the CSRF header once a recovery session is present" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            recovery <- withUserDb server "alice" Auth.regenerateRecoveryCodes
            code <- case recovery of
                (first : _) -> pure first
                [] -> expectationFailure "expected recovery codes" >> error "unreachable"
            redeemed <-
                httpRequest
                    server
                    "POST"
                    "/api/recovery/redeem"
                    jsonHeaders
                    (Just (encodeJsonObject [("username", "alice"), ("code", code)]))
            redeemed `shouldHaveStatus` 200
            session <- expectJust "recovery session" (setCookieValue redeemed Auth.sessionCookieName)
            csrf <- expectJust "recovery csrf" (setCookieValue redeemed Auth.csrfCookieName)
            let setup =
                    encodeJsonObject
                        [ ("username", "alice")
                        , ("password", "recovery password 1")
                        , ("confirm", "recovery password 1")
                        ]
            missing <- httpRequest server "POST" "/api/setup/password" (cookieHeaders session csrf) (Just setup)
            missing `shouldHaveStatus` 403
            hrespBody missing `shouldSatisfy` containsText "csrf"
            accepted <-
                httpRequest
                    server
                    "POST"
                    "/api/setup/password"
                    (authHeaders session csrf)
                    (Just setup)
            accepted `shouldHaveStatus` 200

-- ---------------------------------------------------------------------------
-- S6: no account-existence oracle through the login lockout
-- ---------------------------------------------------------------------------

loginEnumerationSpec :: Spec
loginEnumerationSpec = describe "S6 login lockout symmetry" $ do
    it "gives a known and an unknown username the same 401/429 sequence"
        $ withTestServerCustom
            (\cfg -> cfg{cfgLoginMaxAttempts = 5, cfgLoginLockoutSeconds = 900})
            (\_ -> pure ())
        $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            known <- loginStatuses server "alice" 6
            unknown <- loginStatuses server "nobody-at-all" 6
            known `shouldBe` [401, 401, 401, 401, 429, 429]
            unknown `shouldBe` known

loginStatuses :: TestServer -> Text -> Int -> IO [Int]
loginStatuses server username attempts =
    mapM
        ( \_ -> do
            response <-
                httpRequest
                    server
                    "POST"
                    "/api/auth/login"
                    jsonHeaders
                    (Just (encodeJsonObject [("username", username), ("password", "definitely wrong")]))
            pure (hrespStatus response)
        )
        [1 .. attempts]

-- ---------------------------------------------------------------------------
-- Raw HTTP
-- ---------------------------------------------------------------------------

{- | A raw HTTP GET so the encoded path reaches the server untouched. An HTTP
client would normalise @..@ segments before sending them.
-}
rawGet :: TestServer -> String -> IO (Either String (Int, BS.ByteString))
rawGet server rawPath = do
    -- A misbehaving server must not hang the suite.
    result <- timeout (10 * 1000000) (rawGetInner server rawPath)
    pure $ maybe (Left "raw request timed out") Right result

rawGetInner :: TestServer -> String -> IO (Int, BS.ByteString)
rawGetInner server rawPath =
    bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
        Socket.connect sock (Socket.SockAddrInet (fromIntegral (tsPort server)) (Socket.tupleToHostAddress (127, 0, 0, 1)))
        let request = BSC.pack ("GET " <> rawPath <> " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        SocketBS.sendAll sock request
        chunks <- readChunks sock
        let response = BS.concat chunks
        pure (responseStatusOf response, response)
  where
    readChunks sock = do
        chunk <- SocketBS.recv sock 65536
        if BS.null chunk then pure [] else (chunk :) <$> readChunks sock

responseStatusOf :: BS.ByteString -> Int
responseStatusOf response = case BSC.lines response of
    (statusLine : _) -> case BSC.words statusLine of
        (_ : code : _) -> read (BSC.unpack code) :: Int
        _ -> 0
    [] -> 0

unwrapRaw :: Either String (Int, BS.ByteString) -> (Int, BS.ByteString)
unwrapRaw result = case result of
    Right value -> value
    Left message -> error ("raw request failed: " <> message)
