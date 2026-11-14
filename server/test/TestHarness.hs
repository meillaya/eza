{-# LANGUAGE OverloadedStrings #-}

{- | A real eza server on a temporary data directory for the server test
suites.

Every test runs the actual Warp application: the control registry, per-user
library databases, the auth guard, the admin API, and the token resolution all
behave as in production. A second control connection plays the part of an
operator that creates and disables accounts.
-}
module TestHarness (
    TestServer (..),
    HttpResponse (..),
    testConfig,
    testAuthConfig,
    withTestServer,
    withTestServerConfig,
    withTestServerCustom,
    runEgressJob,
    createTestUser,
    withTwoUsers,
    userDbPath,
    httpRequest,
    shouldHaveStatus,
    expectJust,
    setCookieValue,
    headerValue,
    cookieHeaders,
    authHeaders,
    jsonHeaders,
    loginAs,
    jsonField,
    jsonBody,
    jsonIntField,
    jsonTextField,
    bootTotal,
    listTotal,
    addTestBookmark,
    containsText,
    testBundleAuthJsPath,
    testBundleBuildId,
    testBundleCssPath,
    testBundleFaviconFallbackPath,
    testBundleFaviconPath,
    testBundleFontPath,
    testBundleIcon192Path,
    testBundleIcon512Path,
    testBundleIndexJsPath,
    testBundleJsffiPath,
    testBundleManifest,
    testBundlePwaJsPath,
    testBundleServiceWorker,
    testBundleShellHtml,
    testBundleThemeJsPath,
    testBundleVendorPath,
    testBundleWasmPath,
    writeTestStaticBundle,
) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket, finally)
import Control.Monad (forM_)
import Data.Aeson (FromJSON, Value (..), decode, eitherDecode, encode, object, (.=))
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple (Connection)
import qualified Database.SQLite.Simple as Sqlite
import Network.HTTP.Client
import Network.HTTP.Types (HeaderName, statusCode)
import qualified Network.Socket as Socket
import Network.Wai.Handler.Warp (defaultSettings, openFreePort, runSettingsSocket, setBeforeMainLoop)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import qualified Eza.Auth as Auth
import Eza.Config (Config (..))
import qualified Eza.Control as Control
import qualified Eza.Db as Db
import qualified Eza.Egress as Egress
import qualified Eza.Jobs as Jobs
import qualified Eza.Password as Password
import Eza.Server (AppState, app, closeAppState, newAppState)

-- ---------------------------------------------------------------------------
-- A real server on a temporary directory
-- ---------------------------------------------------------------------------

data TestServer = TestServer
    { tsConfig :: Config
    , tsState :: AppState
    , tsControl :: Connection
    , tsManager :: Manager
    , tsPort :: Int
    }

data HttpResponse = HttpResponse
    { hrespStatus :: Int
    , hrespHeaders :: [(HeaderName, BS.ByteString)]
    , hrespBody :: LBS.ByteString
    }

withTestServer :: (TestServer -> IO a) -> IO a
withTestServer = withTestServerCustom id (\_ -> pure ())

{- | Run the server after a preparation step (for the migration test, which
needs a claimed legacy database before startup).
-}
withTestServerConfig :: (Config -> IO ()) -> (TestServer -> IO a) -> IO a
withTestServerConfig = withTestServerCustom id

{- | Run the server on a temporary directory with the config adjusted (for
example to point the snapshot capture at a fake monolith script).
-}
withTestServerCustom :: (Config -> Config) -> (Config -> IO ()) -> (TestServer -> IO a) -> IO a
withTestServerCustom adjust prepare action =
    withSystemTempDirectory "eza-isolation" $ \dir -> do
        let cfg = adjust (testConfig dir)
        prepare cfg
        state <- newAppState cfg
        control <- Control.openControlDb (cfgControlDbPath cfg)
        manager <- newManager defaultManagerSettings
        (port, listenSocket) <- openFreePort
        ready <- newEmptyMVar
        let settings = setBeforeMainLoop (putMVar ready ()) defaultSettings
        threadId <- forkIO (runSettingsSocket settings listenSocket (app cfg state) `finally` pure ())
        takeMVar ready
        let server =
                TestServer
                    { tsConfig = cfg
                    , tsState = state
                    , tsControl = control
                    , tsManager = manager
                    , tsPort = port
                    }
        action server
            `finally` do
                killThread threadId
                Socket.close listenSocket
                Sqlite.close control
                closeAppState state

testConfig :: FilePath -> Config
testConfig dir =
    Config
        { cfgDataDir = dir
        , cfgControlDbPath = dir </> "control.db"
        , cfgUsersDir = dir </> "users"
        , cfgMaxUsers = 8
        , -- The legacy bootstrap path for this test only.
          cfgDbPath = dir </> "eza.db"
        , cfgBind = "127.0.0.1:0"
        , cfgPublicOrigin = "http://localhost:8080"
        , cfgRpId = "localhost"
        , cfgRpName = "eza-test"
        , cfgAllowedOrigins = ["http://localhost:8080"]
        , cfgClipOrigins = []
        , cfgSidecarCmd = Nothing
        , cfgSessionTtlSeconds = 3600
        , cfgSecureCookies = False
        , cfgStaticDir = Nothing
        , cfgSnapshotDir = dir </> "snapshots"
        , cfgBackupDir = dir </> "backups"
        , cfgBackupKeepDays = 14
        , cfgMonolith = "monolith"
        , cfgSnapshotMaxBytes = 50 * 1024 * 1024
        , cfgLogLevel = "error"
        , cfgAllowPrivateFetch = False
        , cfgEnrichWorkers = 0
        , cfgFetchTimeoutMs = 1000
        , cfgFaviconMaxBytes = 4096
        , cfgFaviconTtlDays = 1
        , cfgFaviconBackfill = False
        , cfgShareTtlDays = 7
        , cfgAiProvider = "none"
        , cfgOllamaBaseUrl = "http://127.0.0.1:11434"
        , cfgAiModel = ""
        , -- Cheap Argon2 keeps the suite fast; the production cost is unchanged.
          cfgArgon2 = Password.PasswordParams 1024 1 1
        , cfgLoginMaxAttempts = 100
        , cfgLoginLockoutSeconds = 900
        , cfgAuthBodyLimitBytes = 8192
        , cfgMaxBodyBytes = 8 * 1024 * 1024
        , cfgImportMaxBytes = 32 * 1024 * 1024
        }

testAuthConfig :: Config -> Auth.AuthConfig
testAuthConfig cfg =
    Auth.AuthConfig
        { Auth.acOrigin = cfgPublicOrigin cfg
        , Auth.acRpId = cfgRpId cfg
        , Auth.acRpName = cfgRpName cfg
        , Auth.acSessionTtlSeconds = cfgSessionTtlSeconds cfg
        , Auth.acPasswordParams = cfgArgon2 cfg
        , Auth.acLoginMaxAttempts = cfgLoginMaxAttempts cfg
        , Auth.acLoginLockoutSeconds = cfgLoginLockoutSeconds cfg
        }

-- ---------------------------------------------------------------------------
-- A valid content-addressed static bundle for asset-serving tests
-- ---------------------------------------------------------------------------

{- | The build id every fixture manifest carries. Sixteen lowercase hex
characters is the shape 'Eza.Assets' validates.
-}
testBundleBuildId :: Text
testBundleBuildId = "0123456789abcdef"

{- | The hashed fixture URLs. They mirror the names scripts/bundle-web.sh
emits (an eight-hex content address before the extension), without requiring
a WASM build in the native test suite.
-}
testBundleCssPath :: Text
testBundleCssPath = "/assets/eza.deadbeef.css"

testBundleThemeJsPath :: Text
testBundleThemeJsPath = "/assets/theme.cafebabe.js"

testBundlePwaJsPath :: Text
testBundlePwaJsPath = "/assets/pwa.0badf00d.js"

testBundleAuthJsPath :: Text
testBundleAuthJsPath = "/assets/auth.8badf00d.js"

testBundleFaviconPath :: Text
testBundleFaviconPath = "/assets/favicon.2badf00d.svg"

testBundleFaviconFallbackPath :: Text
testBundleFaviconFallbackPath = "/assets/favicon-fallback.3badf00d.svg"

testBundleIcon192Path :: Text
testBundleIcon192Path = "/assets/icons/icon-192.4badf00d.png"

testBundleIcon512Path :: Text
testBundleIcon512Path = "/assets/icons/icon-512.5badf00d.png"

testBundleFontPath :: Text
testBundleFontPath = "/assets/fonts/newsreader-300-800.6badf00d.woff2"

testBundleWasmPath :: Text
testBundleWasmPath = "/assets/app/app.7badf00d.wasm"

testBundleJsffiPath :: Text
testBundleJsffiPath = "/assets/app/ghc_wasm_jsffi.9badf00d.js"

testBundleIndexJsPath :: Text
testBundleIndexJsPath = "/assets/app/index.abadf00d.js"

testBundleVendorPath :: Text
testBundleVendorPath = "/assets/vendor/browser_wasi_shim.cbadf00d"

{- | The precache list of the fixture worker: the shell route, the web
manifest, and every hashed asset the shell loads.
-}
testBundlePrecache :: [Text]
testBundlePrecache =
    [ "/"
    , "/manifest.webmanifest"
    , testBundleCssPath
    , testBundleThemeJsPath
    , testBundlePwaJsPath
    , testBundleIndexJsPath
    , testBundleWasmPath
    , testBundleJsffiPath
    , testBundleFaviconPath
    , testBundleFaviconFallbackPath
    , testBundleIcon192Path
    , testBundleIcon512Path
    , testBundleVendorPath <> "/index.js"
    , testBundleFontPath
    ]

-- | The generated-shell shape: every shell ref the manifest names is present.
testBundleShellHtml :: Text
testBundleShellHtml =
    T.unlines
        [ "<!doctype html>"
        , "<html lang=\"en\" data-theme=\"light\"><head>"
        , "<link rel=\"manifest\" href=\"/manifest.webmanifest\" />"
        , "<link rel=\"icon\" href=\"" <> testBundleFaviconPath <> "\" type=\"image/svg+xml\" />"
        , "<link rel=\"alternate icon\" href=\"" <> testBundleFaviconFallbackPath <> "\" type=\"image/svg+xml\" />"
        , "<link rel=\"apple-touch-icon\" href=\"" <> testBundleIcon192Path <> "\" />"
        , "<link rel=\"preload\" href=\"" <> testBundleFontPath <> "\" as=\"font\" type=\"font/woff2\" crossorigin />"
        , "<link rel=\"stylesheet\" href=\"" <> testBundleCssPath <> "\" />"
        , "<script src=\"" <> testBundleThemeJsPath <> "\"></script>"
        , "<script src=\"" <> testBundlePwaJsPath <> "\" defer></script>"
        , "<script type=\"module\" src=\"" <> testBundleIndexJsPath <> "\"></script>"
        , "</head><body><div id=\"app\"></div></body></html>"
        ]

-- | The generated-worker shape: versioned cache name plus the precache list.
testBundleServiceWorker :: Text
testBundleServiceWorker =
    T.unlines
        [ "\"use strict\";"
        , "const VERSION = \"eza-app-shell-" <> testBundleBuildId <> "\";"
        , "const SHELL_ASSETS = [" <> T.intercalate ", " (map (\path -> "\"" <> path <> "\"") testBundlePrecache) <> "];"
        ]

{- | The asset manifest 'Eza.Assets' validates, as a JSON value so tests can
corrupt one field without hand-writing JSON.
-}
testBundleManifest :: Value
testBundleManifest =
    object
        [ "schema_version" .= (1 :: Int)
        , "build_id" .= testBundleBuildId
        , "assets"
            .= object
                [ "app.ghc_wasm_jsffi.js" .= testBundleJsffiPath
                , "app.index.js" .= testBundleIndexJsPath
                , "app.wasm" .= testBundleWasmPath
                , "auth.js" .= testBundleAuthJsPath
                , "eza.css" .= testBundleCssPath
                , "favicon-fallback.svg" .= testBundleFaviconFallbackPath
                , "favicon.svg" .= testBundleFaviconPath
                , "fonts/newsreader-300-800.woff2" .= testBundleFontPath
                , "icons/icon-192.png" .= testBundleIcon192Path
                , "icons/icon-512.png" .= testBundleIcon512Path
                , "manifest.webmanifest" .= ("/manifest.webmanifest" :: Text)
                , "pwa.js" .= testBundlePwaJsPath
                , "theme.js" .= testBundleThemeJsPath
                , "vendor/browser_wasi_shim" .= testBundleVendorPath
                ]
        , "shell"
            .= object
                [ "apple_touch_icon" .= testBundleIcon192Path
                , "auth_js" .= testBundleAuthJsPath
                , "css" .= testBundleCssPath
                , "favicon" .= testBundleFaviconPath
                , "favicon_fallback" .= testBundleFaviconFallbackPath
                , "manifest" .= ("/manifest.webmanifest" :: Text)
                , "module_js" .= testBundleIndexJsPath
                , "preload_font" .= testBundleFontPath
                , "pwa_js" .= testBundlePwaJsPath
                , "theme_js" .= testBundleThemeJsPath
                ]
        , "precache" .= testBundlePrecache
        ]

{- | Write a minimal but valid content-addressed bundle under @root@. The
static-serving tests use it instead of a WASM build, so the native suite does
not depend on scripts/build-web.sh having run.
-}
writeTestStaticBundle :: FilePath -> IO ()
writeTestStaticBundle root = do
    forM_ files $ \(relative, bytes) -> do
        let path = root </> relative
        createDirectoryIfMissing True (takeDirectory path)
        BS.writeFile path bytes
    BS.writeFile (root </> "index.html") (TE.encodeUtf8 testBundleShellHtml)
    BS.writeFile (root </> "sw.js") (TE.encodeUtf8 testBundleServiceWorker)
    BS.writeFile (root </> "manifest.webmanifest") "{\"name\":\"eza\",\"icons\":[]}"
    BS.writeFile (root </> "asset-manifest.json") (LBS.toStrict (encode testBundleManifest))
  where
    files =
        [ ("eza.deadbeef.css", "/* eza test asset */")
        , ("theme.cafebabe.js", "// eza theme test asset")
        , ("pwa.0badf00d.js", "// eza pwa test asset")
        , ("auth.8badf00d.js", "// eza auth test asset")
        , ("favicon.2badf00d.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"1\" height=\"1\"/></svg>")
        , ("favicon-fallback.3badf00d.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"2\" height=\"2\"/></svg>")
        , ("icons/icon-192.4badf00d.png", "\137PNG\r\n\SUB\n")
        , ("icons/icon-512.5badf00d.png", "\137PNG\r\n\SUB\n")
        , ("fonts/newsreader-300-800.6badf00d.woff2", "\0wOF2")
        , ("app/app.7badf00d.wasm", "\0asm")
        , ("app/ghc_wasm_jsffi.9badf00d.js", "export default 1;")
        , ("app/index.abadf00d.js", "// eza loader test asset")
        , ("vendor/browser_wasi_shim.cbadf00d/index.js", "export const WASI = 1;")
        ]

-- ---------------------------------------------------------------------------
-- Accounts
-- ---------------------------------------------------------------------------

{- | Run the egress worker steps for one claimed job synchronously, as the
library worker would. Tests enqueue through the HTTP handler, then call this to
avoid waiting for the background loop.
-}
runEgressJob :: TestServer -> Text -> Int -> IO ()
runEgressJob server username jobId = do
    users <- Control.listUsers (tsControl server)
    user <- case filter ((== username) . Control.cuUsername) users of
        (found : _) -> pure found
        [] -> expectationFailure ("no such test user: " <> T.unpack username) >> error "unreachable"
    bracket (Db.openDb (userDbPath server username)) Sqlite.close $ \conn -> do
        job <- Jobs.getJob conn jobId
        case job of
            Nothing -> expectationFailure "missing queued egress job"
            Just claimed ->
                Egress.processOneJob
                    (tsManager server)
                    (tsConfig server)
                    (cfgUsersDir (tsConfig server) </> show (Control.cuId user) </> "snapshots")
                    conn
                    claimed

userDbPath :: TestServer -> Text -> FilePath
userDbPath server username = cfgUsersDir (tsConfig server) </> T.unpack username </> "eza.db"

{- | Create one account the way the admin API will in M3b: a migrated user
database with the password setup finished, then the control row.
-}
createTestUser :: TestServer -> Text -> Text -> Control.UserRole -> IO Control.ControlUser
createTestUser server username password role = do
    let path = userDbPath server username
    userConn <- Db.openDb path
    stored <- Password.hashPassword (cfgArgon2 (tsConfig server)) password
    _ <- Auth.completeSetup userConn username stored
    Sqlite.close userConn
    created <- Control.createUser (tsControl server) username path role Nothing
    case created of
        Right user -> pure user
        Left err -> expectationFailure ("could not create test user: " <> show err) >> error "unreachable"

withTwoUsers :: (TestServer -> Control.ControlUser -> Control.ControlUser -> IO a) -> IO a
withTwoUsers action = withTestServer $ \server -> do
    alice <- createTestUser server "alice" "alice password" Control.RoleAdmin
    bob <- createTestUser server "bob" "bob password" Control.RoleMember
    action server alice bob

-- ---------------------------------------------------------------------------
-- HTTP helpers
-- ---------------------------------------------------------------------------

httpRequest ::
    TestServer ->
    BS.ByteString ->
    String ->
    [(HeaderName, BS.ByteString)] ->
    Maybe LBS.ByteString ->
    IO HttpResponse
httpRequest server requestMethod path headers body = do
    initial <- parseRequest ("http://127.0.0.1:" <> show (tsPort server) <> path)
    let request =
            initial
                { method = requestMethod
                , requestHeaders = headers
                , requestBody = maybe (RequestBodyBS BS.empty) (RequestBodyBS . LBS.toStrict) body
                , -- Assert the redirect itself instead of following it.
                  redirectCount = 0
                }
    response <- httpLbs request (tsManager server)
    pure
        HttpResponse
            { hrespStatus = statusCode (responseStatus response)
            , hrespHeaders = responseHeaders response
            , hrespBody = responseBody response
            }

shouldHaveStatus :: HttpResponse -> Int -> Expectation
shouldHaveStatus response expected =
    if hrespStatus response == expected
        then pure ()
        else
            expectationFailure
                ( "status "
                    <> show (hrespStatus response)
                    <> " /= "
                    <> show expected
                    <> ": "
                    <> show (hrespBody response)
                )

expectJust :: String -> Maybe a -> IO a
expectJust label = maybe (expectationFailure ("missing " <> label) >> error "unreachable") pure

headerValue :: HttpResponse -> HeaderName -> Maybe BS.ByteString
headerValue response name = lookup name (hrespHeaders response)

setCookieValue :: HttpResponse -> Text -> Maybe Text
setCookieValue response name = listToMaybe (mapMaybe extract (hrespHeaders response))
  where
    extract (key, raw)
        | key == "Set-Cookie" =
            T.stripPrefix (name <> "=") (TE.decodeUtf8 raw) >>= \rest ->
                Just (T.takeWhile (/= ';') rest)
        | otherwise = Nothing

cookieHeaders :: Text -> Text -> [(HeaderName, BS.ByteString)]
cookieHeaders session csrf =
    [ ("Cookie", TE.encodeUtf8 ("eza_session=" <> session <> "; eza_csrf=" <> csrf))
    ]

authHeaders :: Text -> Text -> [(HeaderName, BS.ByteString)]
authHeaders session csrf =
    cookieHeaders session csrf
        <> [ ("X-CSRF-Token", TE.encodeUtf8 csrf)
           , ("Content-Type", "application/json")
           ]

jsonHeaders :: [(HeaderName, BS.ByteString)]
jsonHeaders = [("Content-Type", "application/json")]

-- | Sign in through the public endpoint and return the wire cookies.
loginAs :: TestServer -> Text -> Text -> IO (Text, Text)
loginAs server username password = do
    response <-
        httpRequest
            server
            "POST"
            "/api/auth/login"
            jsonHeaders
            (Just (encode (object ["username" .= username, "password" .= password])))
    response `shouldHaveStatus` 200
    session <- expectJust "session cookie" (setCookieValue response Auth.sessionCookieName)
    csrf <- expectJust "csrf cookie" (setCookieValue response Auth.csrfCookieName)
    pure (session, csrf)

-- | Lazy bytestring containment, used for JSON and HTML bodies.
containsText :: Text -> LBS.ByteString -> Bool
containsText needle haystack = TE.encodeUtf8 needle `BS.isInfixOf` LBS.toStrict haystack

-- | Decode a response body into a DTO.
jsonBody :: (FromJSON a) => HttpResponse -> Maybe a
jsonBody response = either (const Nothing) Just (eitherDecode (hrespBody response))

jsonField :: Text -> LBS.ByteString -> Maybe Value
jsonField key raw = case decode raw :: Maybe Value of
    Just (Object value) -> KeyMap.lookup (AesonKey.fromText key) value
    _ -> Nothing

jsonIntField :: Text -> LBS.ByteString -> Maybe Int
jsonIntField key raw = case jsonField key raw of
    Just (Number value) -> Just (round value)
    _ -> Nothing

jsonTextField :: Text -> LBS.ByteString -> Maybe Text
jsonTextField key raw = case jsonField key raw of
    Just (String value) -> Just value
    _ -> Nothing

-- | A boot payload nests the initial page under @initial@.
bootTotal :: LBS.ByteString -> Maybe Int
bootTotal raw = case jsonField "initial" raw of
    Just (Object initial) -> case KeyMap.lookup "total" initial of
        Just (Number value) -> Just (round value)
        _ -> Nothing
    _ -> Nothing

{- | Lists the bookmarks of the account owning the session and returns the
reported total.
-}
listTotal :: TestServer -> Text -> Text -> IO Int
listTotal server session csrf = do
    response <- httpRequest server "GET" "/api/v1/bookmarks" (cookieHeaders session csrf) Nothing
    response `shouldHaveStatus` 200
    expectJust "bookmarks total" (jsonIntField "total" (hrespBody response))

addTestBookmark :: TestServer -> Text -> Text -> Int -> IO ()
addTestBookmark server session csrf index = do
    response <-
        httpRequest
            server
            "POST"
            "/api/v1/bookmarks"
            (authHeaders session csrf)
            (Just (encode (object ["url" .= ("https://example.test/" <> T.pack (show index) :: Text), "title" .= ("Entry " <> T.pack (show index) :: Text)])))
    response `shouldHaveStatus` 201
