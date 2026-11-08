{-# LANGUAGE OverloadedStrings #-}

{- | Warp application: public auth pages/ceremonies, deny-by-default API,
CSRF/session guard, and the bookmark/tag JSON surface.
-}
module Eza.Server (
    runServer,
) where

import Control.Concurrent.Async (async)
import Control.Concurrent.MVar
import Control.Exception (IOException, throwIO, try)
import Control.Monad (forM_, void)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as LBS
import Data.Char (toLower)
import Data.List (isInfixOf, isPrefixOf)
import Data.Maybe (fromMaybe)
import Data.Pool (Pool, defaultPoolConfig, newPool, withResource)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Database.SQLite.Simple (Connection, Only (..), query)
import qualified Database.SQLite.Simple as Sqlite
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Handler.Warp
import Network.Wai.Middleware.Gzip (GzipFiles (..), GzipSettings (..), defaultGzipSettings, gzip)
import System.Directory (canonicalizePath, doesFileExist, getFileSize, getModificationTime)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import qualified Web.Cookie as Cookie

import Eza.AiTag (aiSuggestions)
import qualified Eza.Auth as Auth
import Eza.Bookmarks
import Eza.Clip (ClipError, ClipRequest (..), ClipTemplate (..), SaveClipResult (..), TemplateError, clipErrorCode, clipErrorMessage, clipErrorStatus, createTemplate, deleteTemplate, getTemplate, previewClip, saveClip, templateErrorCode, templateErrorMessage, templateErrorStatus, templatesPayload, updateTemplate)
import Eza.Config
import qualified Eza.Db as Db
import Eza.DeadLinks (checkDead)
import Eza.Dedup (DedupQuery (..), dedupCandidates, mergeBookmarks, mergeUrlDuplicatesAll)
import Eza.Enrich (enqueueEnrichment, runEnrichWorker)
import Eza.Export (exportBookmarks)
import Eza.Favicon (Favicon (..), getFavicon)
import Eza.Graph (graphNeighborhood)
import Eza.Highlights (createHighlight, deleteHighlight, listHighlights, updateHighlight)
import Eza.Import (defaultImportOptions, importParsed, parseNetscape)
import Eza.Jobs (resetRunningJobs)
import Eza.JsonExport (exportJson, importJson)
import Eza.Pages (addPasskeyPage, loginPage, passkeyLoginPage, recoverPage, recoverySetupPage, setupPage)
import Eza.Password (validatePassword, validateUsername)
import qualified Eza.Password as Password
import Eza.Rules (Rule (..), createRule, deleteRule, listRules, matchingBookmarks, updateRule)
import Eza.SavedSearches (createSavedSearch, deleteSavedSearch, listSavedSearches)
import Eza.Shares (ShareRecord (..), ShareState (..), ShareUnavailable (..), createShare, listShares, resolveShareState, revokeShare, shareBookmarkPage, shareSearchFeed, shareSearchPage, shareUnavailablePage)
import Eza.Snapshot (captureSnapshot)
import Eza.Tags (consolidationCandidates, deleteTag, deleteTagWithLinks, mergeTags, renameTag)
import Eza.Tokens (Token (..), authenticateToken, createToken, listTokens, revokeToken, tokenAllows)
import Eza.Types
import Eza.Undo (undoLast)
import Network.Wai.Parse (FileInfo (..), defaultParseRequestBodyOptions, lbsBackEnd, parseRequestBodyEx)

runServer :: Config -> Connection -> IO ()
runServer cfg conn = do
    Auth.cleanupExpired conn
    resetRunningJobs conn
    recoveryLimiter <- Auth.newRateLimiter 5 900
    manager <- newTlsManager
    forM_ [1 .. cfgEnrichWorkers cfg] $ \_ -> void (async (runEnrichWorker manager cfg))
    writeVar <- newMVar conn
    readPool <-
        newPool
            ( defaultPoolConfig
                (openReadConnection (cfgDbPath cfg))
                Sqlite.close
                60
                4
            )
    let db = ServerDb writeVar readPool
    let settings =
            setHost (fromString (bindHost (cfgBind cfg)))
                . setPort (bindPort (cfgBind cfg))
                . setServerName "eza"
                . setBeforeMainLoop (hPutStrLn stderr ("eza listening on " <> cfgBind cfg))
                $ defaultSettings
    outcome <- try (runSettings settings (gzip gzipSettings (securityMiddleware cfg (app cfg db recoveryLimiter)))) :: IO (Either IOException ())
    case outcome of
        Right () -> pure ()
        Left err
            | "Address already in use" `isInfixOf` show err -> do
                hPutStrLn stderr ("eza could not listen on " <> cfgBind cfg <> ": the port is already in use.")
                hPutStrLn stderr "Another eza process is probably already running there."
                hPutStrLn stderr ("Open " <> T.unpack (cfgPublicOrigin cfg) <> " to use it, or stop the other process and start again.")
                exitFailure
            | otherwise -> throwIO err

{- | Compress dynamic text responses (JSON, HTML) above 512 bytes. Static files
are served from precompressed sidecars by 'sendFile'; @GzipIgnore@ keeps the
middleware off the responseFile path so that work is not repeated.
-}
gzipSettings :: GzipSettings
gzipSettings = defaultGzipSettings{gzipFiles = GzipIgnore, gzipSizeThreshold = 512}

-- | Security headers applied to every response (API, HTML, assets).
securityMiddleware :: Config -> Middleware
securityMiddleware cfg app' req respond =
    app' req (respond . mapResponseHeaders (<> headersFor req))
  where
    headersFor r =
        [ ("X-Content-Type-Options", "nosniff")
        , ("Referrer-Policy", "no-referrer")
        , ("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        ]
            <> frameHeaders r
            <> [("Strict-Transport-Security", "max-age=31536000; includeSubDomains") | cfgSecureCookies cfg]

    -- The record page embeds the local snapshot viewer in an iframe, so that one
    -- response may be framed by this origin. Every other response stays deny.
    frameHeaders r
        | isSnapshotRequest r =
            [("Content-Security-Policy", "frame-ancestors 'self'")]
        | otherwise =
            [ ("X-Frame-Options", "DENY")
            ,
                ( "Content-Security-Policy"
                , "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
                )
            ]

isSnapshotRequest :: Request -> Bool
isSnapshotRequest r = case pathInfo r of
    ["api", "v1", "bookmarks", _, "snapshot"] -> requestMethod r == "GET"
    _ -> False

{- | The single writer plus a small pool of query-only readers. Reads (GET and
HEAD) run on the pool so a large merge, import or export does not stall
browsing; every mutation still goes through the one writer connection.
-}
data ServerDb = ServerDb
    { sdbWrite :: MVar Connection
    , sdbRead :: Pool Connection
    }

{- | A pooled read-only connection. WAL lets these run alongside the writer;
@query_only@ turns an accidental write from a GET route into a loud error
instead of a lock.
-}
openReadConnection :: FilePath -> IO Connection
openReadConnection path = do
    conn <- Sqlite.open path
    mapM_
        (Sqlite.execute_ conn)
        [ "PRAGMA busy_timeout = 5000"
        , "PRAGMA temp_store = MEMORY"
        , "PRAGMA mmap_size = 268435456"
        , "PRAGMA cache_size = -65536"
        , "PRAGMA query_only = ON"
        ]
    pure conn

authConfig :: Config -> Auth.AuthConfig
authConfig cfg =
    Auth.AuthConfig
        { Auth.acOrigin = cfgPublicOrigin cfg
        , Auth.acRpId = cfgRpId cfg
        , Auth.acRpName = cfgRpName cfg
        , Auth.acSessionTtlSeconds = cfgSessionTtlSeconds cfg
        , Auth.acPasswordParams = cfgArgon2 cfg
        , Auth.acLoginMaxAttempts = cfgLoginMaxAttempts cfg
        , Auth.acLoginLockoutSeconds = cfgLoginLockoutSeconds cfg
        }

app :: Config -> ServerDb -> Auth.RateLimiter -> Application
app cfg db recoveryLimiter req respond = do
    case (requestMethod req, pathInfo req) of
        -- CORS preflight for the browser clipper. This must run before the
        -- auth guard: the preflight deliberately carries no Authorization.
        ("OPTIONS", path) | isClipPath path -> clipPreflight cfg req respond
        -- Public: health + password auth pages/ceremonies.
        ("GET", ["healthz"]) -> health db respond
        ("GET", ["login"]) -> withDb db $ \conn -> loginHandler conn req respond
        ("GET", ["setup"]) -> withDb db $ \conn -> setupHandler conn req respond
        ("GET", ["recover"]) -> respond (htmlResponse recoverPage)
        ("GET", ["s", token]) -> withDb db $ \conn -> publicShareHandler conn token respond
        ("POST", ["api", "auth", "login"]) -> withDb db $ \conn -> passwordLoginHandler cfg conn req respond
        ("POST", ["api", "auth", "passkey", "options"]) -> withDb db $ \conn -> passkeySecondFactorOptionsHandler cfg conn req respond
        ("POST", ["api", "auth", "passkey", "verify"]) -> withDb db $ \conn -> passkeySecondFactorVerifyHandler cfg conn req respond
        ("POST", ["api", "auth", "options"]) -> withDb db $ \conn -> legacyPasskeyOptionsHandler cfg conn req respond
        ("POST", ["api", "auth", "verify"]) -> withDb db $ \conn -> legacyPasskeyVerifyHandler cfg conn req respond
        ("POST", ["api", "setup", "password"]) -> withDb db $ \conn -> passwordSetupHandler cfg conn req respond
        -- Passkey-first setup is retired. Recovery sets a password too.
        ("POST", ["api", "setup", "options"]) -> respond passkeySetupRetired
        ("POST", ["api", "setup", "verify"]) -> respond passkeySetupRetired
        ("POST", ["api", "recovery", "redeem"]) -> withDb db $ \conn -> recoveryRedeemHandler cfg recoveryLimiter conn req respond
        ("GET", ("assets" : rest)) -> serveAsset cfg rest req respond
        ("GET", ["favicon.svg"]) -> serveAsset cfg ["favicon.svg"] req respond
        ("GET", ["theme.js"]) -> serveAsset cfg ["theme.js"] req respond
        ("GET", ["manifest.webmanifest"]) ->
            serveStaticFile cfg "manifest.webmanifest" [("Content-Type", "application/manifest+json")] req respond
        ("GET", ["sw.js"]) -> serveServiceWorker cfg req respond
        ("GET", []) -> withDb db $ \conn -> do
            msess <- sessionFromReq conn req
            case msess of
                Just sess | Auth.sessScope sess == "normal" -> indexResponse cfg req respond
                _ -> respond (redirectTo "/login")
        -- Authenticated API.
        _ -> withAuthed cfg db req respond $ \ctx conn -> authedRoute cfg db req respond ctx conn

-- ---------------------------------------------------------------------------
-- Public auth handlers
-- ---------------------------------------------------------------------------

loginHandler :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
loginHandler conn req respond = do
    msess <- sessionFromReq conn req
    if maybe False (\sess -> Auth.sessScope sess == "normal") msess
        then respond (redirectTo "/")
        else do
            configured <- Auth.accountConfigured conn
            allowed <- Auth.setupAllowed conn
            legacy <- Auth.legacyPasskeyLoginAllowed conn
            if allowed
                then respond (redirectTo "/setup")
                else
                    if configured
                        then respond (htmlResponse loginPage)
                        else
                            if legacy
                                then respond (htmlResponse passkeyLoginPage)
                                else respond (htmlResponse loginPage)

{- | A fresh database and a recovery session both open the password setup;
anything else goes back to sign in.
-}
setupHandler :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
setupHandler conn req respond = do
    msess <- sessionFromReq conn req
    case msess of
        Just sess
            | Auth.sessScope sess == "recovery" -> do
                account <- Auth.loadAccount conn
                respond (htmlResponse (recoverySetupPage (Auth.acctUsername account)))
        Just _ -> respond (redirectTo "/")
        Nothing -> do
            allowed <- Auth.setupAllowed conn
            if allowed then respond (htmlResponse setupPage) else respond (redirectTo "/login")

passkeySetupRetired :: Response
passkeySetupRetired =
    jsonError status410 "passkey_setup_retired" "passkey setup is retired; create a username and password first"

passwordLoginHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
passwordLoginHandler cfg conn req respond =
    case requireOrigin cfg req of
        Left err -> respond (authErrResponse err)
        Right () -> do
            body <- readAuthBody cfg req
            case body of
                Left AuthBodyTooLarge -> respond (payloadTooLargeResponse cfg)
                Left (AuthBodyInvalid message) -> respond (jsonError status400 "bad_request" message)
                Right value -> case parseMaybeObj value of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case (parseMaybe (.: "username") o, parseMaybe (.: "password") o) of
                        (Just username, Just password) -> do
                            result <- Auth.verifyPasswordLogin conn (authConfig cfg) username password
                            case result of
                                Left err -> respond (authErrResponse err)
                                Right (Auth.LoginComplete sess) ->
                                    respond
                                        ( withAuthCookies
                                            cfg
                                            sess
                                            (jsonResponse status200 (object ["requires_2fa" .= False, "redirect" .= ("/" :: Text)]))
                                        )
                                Right (Auth.LoginNeedsPasskey pending) ->
                                    respond
                                        ( withPendingCookie
                                            cfg
                                            pending
                                            (jsonResponse status200 (object ["requires_2fa" .= True]))
                                        )
                        _ -> respond (jsonError status400 "bad_request" "username and password are required")

{- | The passkey half of a two-factor sign-in. Both handlers need the pending
cookie that the password step set; without it there is no sign-in to finish.
-}
passkeySecondFactorOptionsHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
passkeySecondFactorOptionsHandler cfg conn req respond =
    case requireOrigin cfg req of
        Left err -> respond (authErrResponse err)
        Right () -> do
            mpending <- pendingSessionFromReq conn req
            case mpending of
                Nothing -> respond pendingRequired
                Just _ -> do
                    result <- Auth.secondFactorOptions conn (authConfig cfg)
                    either (respond . authErrResponse) (respond . jsonResponse status200) result

passkeySecondFactorVerifyHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
passkeySecondFactorVerifyHandler cfg conn req respond =
    case requireOrigin cfg req of
        Left err -> respond (authErrResponse err)
        Right () -> do
            mpending <- pendingSessionFromReq conn req
            case mpending of
                Nothing -> respond pendingRequired
                Just pending -> do
                    body <- readAuthBody cfg req
                    case body of
                        Left AuthBodyTooLarge -> respond (payloadTooLargeResponse cfg)
                        Left (AuthBodyInvalid message) -> respond (jsonError status400 "bad_request" message)
                        Right value -> do
                            result <- Auth.verifySecondFactor conn (authConfig cfg) value
                            case result of
                                Left err -> respond (authErrResponse err)
                                Right () -> do
                                    completed <- Auth.completePendingLogin conn (authConfig cfg) pending
                                    case completed of
                                        Left err -> respond (authErrResponse err)
                                        Right sess ->
                                            respond
                                                ( clearPendingCookie
                                                    cfg
                                                    ( withAuthCookies
                                                        cfg
                                                        sess
                                                        (jsonResponse status200 (object ["requires_2fa" .= False, "redirect" .= ("/" :: Text)]))
                                                    )
                                                )

pendingRequired :: Response
pendingRequired = jsonError status401 "pending_required" "the password sign-in expired; sign in again"

{- | Legacy passkey sign-in: only while the database has passkeys and no
password, and never during a recovery setup.
-}
legacyPasskeyOptionsHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
legacyPasskeyOptionsHandler cfg conn req respond =
    case requireOrigin cfg req of
        Left err -> respond (authErrResponse err)
        Right () -> do
            allowed <- legacyCeremonyAllowed conn
            if not allowed
                then respond passkeysRetired
                else do
                    result <- Auth.authenticationOptions conn (authConfig cfg)
                    either (respond . authErrResponse) (respond . jsonResponse status200) result

legacyPasskeyVerifyHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
legacyPasskeyVerifyHandler cfg conn req respond =
    case requireOrigin cfg req of
        Left err -> respond (authErrResponse err)
        Right () -> do
            allowed <- legacyCeremonyAllowed conn
            if not allowed
                then respond passkeysRetired
                else do
                    body <- readAuthBody cfg req
                    case body of
                        Left AuthBodyTooLarge -> respond (payloadTooLargeResponse cfg)
                        Left (AuthBodyInvalid message) -> respond (jsonError status400 "bad_request" message)
                        Right value -> do
                            result <- Auth.verifyLogin conn (authConfig cfg) value
                            case result of
                                Left err -> respond (authErrResponse err)
                                Right sess -> respond (withAuthCookies cfg sess (jsonResponse status200 (object ["redirect" .= ("/" :: Text)])))

legacyCeremonyAllowed :: Connection -> IO Bool
legacyCeremonyAllowed conn = do
    rec <- Auth.hasRecoverySession conn
    configured <- Auth.accountConfigured conn
    pure (not configured && not rec)

passkeysRetired :: Response
passkeysRetired =
    jsonError status403 "passkeys_retired" "password sign-in is active; passkeys are legacy credentials"

{- | Create the account on a fresh database or finish a recovery setup: store
the Argon2id hash, claim the database, replace the recovery codes, and sign
the browser in.
-}
passwordSetupHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
passwordSetupHandler cfg conn req respond =
    case requireOrigin cfg req of
        Left err -> respond (authErrResponse err)
        Right () -> do
            body <- readAuthBody cfg req
            case body of
                Left AuthBodyTooLarge -> respond (payloadTooLargeResponse cfg)
                Left (AuthBodyInvalid message) -> respond (jsonError status400 "bad_request" message)
                Right value -> case parseSetupBody value of
                    Left message -> respond (jsonError status400 "bad_request" message)
                    Right (rawUsername, password) -> do
                        allowed <- Auth.setupAllowed conn
                        claimed <- Auth.setupClaimed conn
                        msess <- sessionFromReq conn req
                        let recoverySession = maybe False (\sess -> Auth.sessScope sess == "recovery") msess
                        if not allowed
                            then respond (jsonError status403 "setup_unavailable" "setup is not available")
                            else
                                if claimed && not recoverySession
                                    then respond (jsonError status403 "recovery_session_required" "a recovery session is required to finish recovery setup")
                                    else case validateUsername rawUsername of
                                        Left message -> respond (jsonError status400 "invalid_username" message)
                                        Right username -> case validatePassword password of
                                            Left message -> respond (jsonError status400 "weak_password" message)
                                            Right () -> do
                                                passwordHash <- Password.hashPassword (cfgArgon2 cfg) password
                                                codes <- Auth.completeSetup conn username passwordHash
                                                sess <- Auth.createSession conn "normal" (cfgSessionTtlSeconds cfg)
                                                respond
                                                    ( withAuthCookies
                                                        cfg
                                                        sess
                                                        (jsonResponse status200 (object ["codes" .= codes, "redirect" .= ("/" :: Text)]))
                                                    )

parseSetupBody :: Value -> Either Text (Text, Text)
parseSetupBody value = case parseMaybeObj value of
    Nothing -> Left "invalid body"
    Just o -> case (parseMaybe (.: "username") o, parseMaybe (.: "password") o, parseMaybe (.: "confirm") o) of
        (Just username, Just password, Just confirm)
            | password /= confirm -> Left "the passwords do not match"
            | otherwise -> Right (username, password)
        _ -> Left "username, password, and confirm are required"

recoveryRedeemHandler :: Config -> Auth.RateLimiter -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
recoveryRedeemHandler cfg limiter conn req respond =
    case requireOrigin cfg req of
        Left err -> respond (authErrResponse err)
        Right () -> do
            body <- readAuthBody cfg req
            case body of
                Left AuthBodyTooLarge -> respond (payloadTooLargeResponse cfg)
                Left (AuthBodyInvalid message) -> respond (jsonError status400 "bad_request" message)
                Right value -> do
                    let clientKey = T.pack (show (remoteHost req))
                    attempt <- Auth.checkRateLimit limiter clientKey
                    case attempt of
                        Left retryAfter ->
                            respond
                                ( mapResponseHeaders
                                    (<> [("Retry-After", BSC.pack (show retryAfter))])
                                    (jsonError status429 "recovery_locked" "too many recovery attempts; try again later")
                                )
                        Right () -> case parseMaybeObj value of
                            Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                            Just o -> case parseMaybe (.: "code") o of
                                Nothing -> respond (jsonError status400 "bad_request" "code is required")
                                Just code -> do
                                    result <- Auth.redeemRecoveryCode conn code
                                    case result of
                                        Left err -> respond (authErrResponse err)
                                        Right sess -> do
                                            Auth.resetRateLimit limiter clientKey
                                            respond (withAuthCookies cfg sess (jsonResponse status200 (object ["redirect" .= ("/setup" :: Text)])))

-- ---------------------------------------------------------------------------
-- Auth body size and origin checks
-- ---------------------------------------------------------------------------

data AuthBodyError
    = AuthBodyTooLarge
    | AuthBodyInvalid Text

{- | Read a public auth JSON body with a hard size cap. The declared length is
checked first, then the streamed body is cut off at the limit so a chunked
request cannot grow without bound.
-}
readAuthBody :: Config -> Request -> IO (Either AuthBodyError Value)
readAuthBody cfg req = do
    let limit = cfgAuthBodyLimitBytes cfg
    case declaredContentLength req of
        Just declared | declared > limit -> pure (Left AuthBodyTooLarge)
        _ -> do
            raw <- readBodyLimited limit req
            pure $ case raw of
                Left () -> Left AuthBodyTooLarge
                Right body -> case eitherDecode body :: Either String Value of
                    Left err -> Left (AuthBodyInvalid (T.pack err))
                    Right value -> Right value

declaredContentLength :: Request -> Maybe Int
declaredContentLength req = do
    header <- lookup hContentLength (requestHeaders req)
    readInt (TE.decodeUtf8 header)

readBodyLimited :: Int -> Request -> IO (Either () LBS.ByteString)
readBodyLimited limit req = go [] 0
  where
    go chunks total = do
        chunk <- getRequestBodyChunk req
        if BS.null chunk
            then pure (Right (LBS.fromChunks (reverse chunks)))
            else
                let total' = total + BS.length chunk
                 in if total' > limit then pure (Left ()) else go (chunk : chunks) total'

payloadTooLargeResponse :: Config -> Response
payloadTooLargeResponse cfg =
    jsonError status413 "payload_too_large" ("request body must be at most " <> T.pack (show (cfgAuthBodyLimitBytes cfg)) <> " bytes")

{- | Public auth POSTs need a real origin check. A browser request must carry
an Origin header that matches the public origin or one of the extras; a
missing Origin is allowed only for non-browser clients, and any @Sec-Fetch-Site@
value marks the caller as a browser.
-}
requireOrigin :: Config -> Request -> Either Auth.AuthError ()
requireOrigin cfg req =
    case lookup "Origin" (requestHeaders req) of
        Just raw ->
            let origin = T.dropWhileEnd (== '/') (TE.decodeUtf8 raw)
                allowed = map (T.dropWhileEnd (== '/')) (cfgAllowedOrigins cfg)
             in if origin `elem` allowed
                    then Right ()
                    else Left (Auth.authError 403 "origin" "request origin is not allowed")
        Nothing ->
            case fmap (T.toLower . TE.decodeUtf8) (lookup "Sec-Fetch-Site" (requestHeaders req)) of
                Just "cross-site" -> Left (Auth.authError 403 "origin" "cross-site request rejected")
                Just _ -> Left (Auth.authError 403 "origin" "a browser request must carry an Origin header")
                Nothing -> Right ()

data AuthContext
    = CookieSession Auth.Session
    | BearerToken Token

authedRoute :: Config -> ServerDb -> Request -> (Response -> IO ResponseReceived) -> AuthContext -> Connection -> IO ResponseReceived
authedRoute cfg _db req respond ctx conn =
    case (requestMethod req, pathInfo req) of
        ("GET", ["api", "v1", "whoami"]) -> whoAmI cfg conn req ctx respond
        ("POST", ["api", "v1", "clip"]) -> clipSaveHandler cfg conn req respond
        ("POST", ["api", "v1", "clip", "preview"]) -> clipPreviewHandler cfg conn req respond
        ("GET", ["api", "v1", "clip-templates"]) -> do
            payload <- templatesPayload conn
            respond (withCors cfg req (jsonResponse status200 payload))
        ("GET", ["api", "v1", "clip-templates", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid template id")
            Just tid -> do
                found <- getTemplate conn tid
                case found of
                    Nothing -> respond (withCors cfg req (jsonError status404 "template_not_found" "template not found"))
                    Just template -> respond (withCors cfg req (jsonResponse status200 template))
        ("POST", ["api", "v1", "clip-templates"]) -> templateWriteSession respond ctx (templateCreateHandler conn req respond)
        ("PATCH", ["api", "v1", "clip-templates", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid template id")
            Just tid -> templateWriteSession respond ctx (templateUpdateHandler conn tid req respond)
        ("DELETE", ["api", "v1", "clip-templates", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid template id")
            Just tid -> templateWriteSession respond ctx (templateDeleteHandler conn tid respond)
        ("GET", ["save"]) -> indexResponse cfg req respond
        ("GET", ["api", "v1", "boot"]) -> do
            page <- listBookmarks conn defaultListQuery
            tags <- allTags conn
            stats <- libraryStats conn
            searches <- listSavedSearches conn
            respond (jsonResponse status200 (BootPayload "0.1.0" (cfgPublicOrigin cfg) tags searches page stats))
        ("GET", ["api", "v1", "bookmarks"]) -> do
            page <- listBookmarks conn (listQueryFrom req)
            respond (jsonResponse status200 page)
        ("POST", ["api", "v1", "bookmarks"]) -> addBookmark conn req respond
        ("POST", ["api", "v1", "bookmarks", "bulk"]) -> bulkHandler conn req respond
        ("GET", ["api", "v1", "bookmarks", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> do
                m <- getBookmark conn bid
                case m of
                    Nothing -> respond (jsonError status404 "not_found" "bookmark not found")
                    Just b -> respond (jsonResponse status200 b)
        ("DELETE", ["api", "v1", "bookmarks", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> do
                ok <- deleteBookmark conn bid
                if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "bookmark not found")
        ("GET", ["api", "v1", "favicons", domain]) ->
            faviconHandler conn req domain respond
        ("POST", ["api", "v1", "quick-save"]) ->
            quickSaveHandler conn req respond
        ("GET", ["api", "v1", "bookmarks", idTxt, "highlights"]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> do
                highlights <- listHighlights conn bid
                respond (jsonResponse status200 (object ["highlights" .= highlights]))
        ("POST", ["api", "v1", "bookmarks", idTxt, "highlights"]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> highlightCreateHandler conn bid req respond
        ("PATCH", ["api", "v1", "bookmarks", idTxt, "highlights", hidTxt]) ->
            case (readInt idTxt, readInt hidTxt) of
                (Just bid, Just hid) -> highlightUpdateHandler conn bid hid req respond
                _ -> respond (jsonError status400 "bad_request" "invalid highlight id")
        ("DELETE", ["api", "v1", "bookmarks", idTxt, "highlights", hidTxt]) ->
            case (readInt idTxt, readInt hidTxt) of
                (Just bid, Just hid) -> do
                    ok <- deleteHighlight conn bid hid
                    if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "highlight not found")
                _ -> respond (jsonError status400 "bad_request" "invalid highlight id")
        ("GET", ["api", "v1", "share-links"]) -> do
            shares <- listShares conn
            respond (jsonResponse status200 (object ["shares" .= shares]))
        ("POST", ["api", "v1", "share-links"]) -> shareCreateHandler cfg conn req respond
        ("DELETE", ["api", "v1", "share-links", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid share id")
            Just shareId -> do
                ok <- revokeShare conn shareId
                if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "share not found")
        ("GET", ["api", "v1", "bookmarks", idTxt, "snapshot"]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> snapshotHandler cfg conn bid respond
        ("GET", ["api", "v1", "tags"]) -> do
            tags <- allTags conn
            respond (jsonResponse status200 (object ["tags" .= tags]))
        ("POST", ["api", "v1", "inbox", "mark-all-above"]) -> markAbove conn req respond
        ("PATCH", ["api", "v1", "bookmarks", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> patchBookmark conn bid req respond
        ("POST", ["api", "v1", "bookmarks", idTxt, action]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> do
                exists <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only bid) :: IO [Only Int]
                if null exists
                    then respond (jsonError status404 "not_found" "bookmark not found")
                    else case action of
                        "open" -> recordOpen conn bid >> respond (jsonResponse status200 (object ["ok" .= True]))
                        "enrich" -> do
                            enqueueEnrichment conn bid
                            respond (jsonResponse status200 (object ["ok" .= True, "queued" .= True]))
                        "extract" -> do
                            enqueueEnrichment conn bid
                            respond (jsonResponse status200 (object ["ok" .= True, "queued" .= True]))
                        "snapshot" -> do
                            m <- captureSnapshot cfg conn bid
                            case m of
                                Nothing -> respond (jsonError status502 "snapshot_failed" "the snapshot could not be captured")
                                Just (kind, value) ->
                                    respond (jsonResponse status200 (object ["ok" .= True, "kind" .= kind, "value" .= value]))
                        _ -> respond (jsonError status404 "not_found" "No such action")
        ("GET", ["api", "v1", "bookmarks", idTxt, "backlinks"]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> do
                bl <- getBacklinks conn bid
                respond (jsonResponse status200 bl)
        ("GET", ["api", "v1", "autocomplete"]) -> do
            let q = fromMaybe "" (param "q" req)
            items <- autocomplete conn q 10
            respond (jsonResponse status200 (object ["items" .= items]))
        ("GET", ["api", "v1", "graph"]) -> do
            case (readInt =<< param "seed" req) of
                Nothing -> respond (jsonError status400 "bad_request" "seed is required")
                Just seed -> do
                    let depth = fromMaybe 1 (readInt =<< param "depth" req)
                    m <- graphNeighborhood conn seed depth
                    case m of
                        Nothing -> respond (jsonError status404 "not_found" "bookmark not found")
                        Just g -> respond (jsonResponse status200 g)
        ("GET", ["api", "v1", "saved-searches"]) -> do
            s <- listSavedSearches conn
            respond (jsonResponse status200 (object ["saved_searches" .= s]))
        ("POST", ["api", "v1", "saved-searches"]) -> do
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> case parseMaybeObj v of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case (parseMaybe (.: "name") o, parseMaybe (.: "q") o, parseMaybe (.: "tags") o) of
                        (Just name, q, tags) -> do
                            sid <- createSavedSearch conn name (fromMaybe "" q) (fromMaybe [] tags)
                            respond (jsonResponse status201 (object ["id" .= sid]))
                        _ -> respond (jsonError status400 "bad_request" "name is required")
        ("DELETE", ["api", "v1", "saved-searches", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid id")
            Just sid -> do
                ok <- deleteSavedSearch conn sid
                if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "saved search not found")
        ("GET", ["api", "v1", "dedup", "candidates"]) -> do
            report <- dedupCandidates conn (dedupQueryFrom req)
            respond (jsonResponse status200 report)
        ("POST", ["api", "v1", "dedup", "merge-all"]) -> do
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> case parseMaybeObj v of
                    Just o
                        | (parseMaybe (.: "confirm") o :: Maybe Bool) == Just True -> do
                            report <- mergeUrlDuplicatesAll conn
                            respond (jsonResponse status200 report)
                    _ -> respond (jsonError status400 "bad_request" "confirm is required")
        ("POST", ["api", "v1", "dedup", "merge"]) -> do
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> case parseMaybeObj v of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case (parseMaybe (.: "keep_id") o, parseMaybe (.: "merge_ids") o) of
                        (Just keep, Just ms) -> do
                            n <- mergeBookmarks conn keep ms
                            respond (jsonResponse status200 (object ["merged" .= n]))
                        _ -> respond (jsonError status400 "bad_request" "keep_id and merge_ids are required")
        ("GET", ["api", "v1", "tags", "consolidation-candidates"]) -> do
            report <- consolidationCandidates conn
            respond (jsonResponse status200 report)
        ("POST", ["api", "v1", "tags", "apply"]) -> do
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> case parseMaybeObj v of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case (parseMaybe (.: "bookmark_id") o, parseMaybe (.: "tags") o) of
                        (Just bid, Just tags) -> do
                            n <- addTagsToBookmark conn bid tags
                            respond (jsonResponse status200 (object ["updated" .= n]))
                        _ -> respond (jsonError status400 "bad_request" "bookmark_id and tags are required")
        ("POST", ["api", "v1", "tags", "merge"]) -> do
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> case parseMaybeObj v of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case (parseMaybe (.: "from") o, parseMaybe (.: "into") o) of
                        (Just froms, Just into) -> do
                            n <- mergeTags conn froms into
                            respond (jsonResponse status200 (object ["updated" .= n]))
                        _ -> respond (jsonError status400 "bad_request" "from and into are required")
        ("GET", ["api", "v1", "tags", tag, "suggestions"]) -> do
            r <- aiSuggestions conn tag 20
            case r of
                Left notice ->
                    respond
                        ( jsonResponse
                            status200
                            (object ["suggestions" .= ([] :: [Value]), "configured" .= False, "notice" .= notice])
                        )
                Right suggestions -> respond (jsonResponse status200 (object ["suggestions" .= suggestions]))
        ("POST", ("api" : "v1" : "tags" : rest)) -> do
            let tagName = T.intercalate "/" rest
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> case parseMaybeObj v of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case parseMaybe (.: "name") o of
                        Nothing -> respond (jsonError status400 "bad_request" "name is required")
                        Just newName -> do
                            ok <- renameTag conn tagName newName
                            if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonError status409 "conflict" "tag rename failed")
        ("DELETE", ("api" : "v1" : "tags" : rest)) -> do
            let tagName = T.intercalate "/" rest
                detach = parseBool =<< param "detach" req
            ok <- if detach == Just True then deleteTagWithLinks conn tagName else deleteTag conn tagName
            if ok then respond (emptyResponse status204) else respond (jsonError status409 "conflict" "tag is not empty or does not exist")
        ("POST", ["api", "v1", "maintenance", "check-dead"]) -> do
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> do
                    let o = fromMaybe mempty (parseMaybeObj v) :: Object
                        limit = fromMaybe 500 (parseMaybe (.: "limit") o :: Maybe Int)
                        older = fromMaybe 0 (parseMaybe (.: "older_than") o :: Maybe Int)
                        includeDead = fromMaybe False (parseMaybe (.: "include_dead") o :: Maybe Bool)
                    (checked, dead, alive) <- checkDead conn limit older includeDead
                    respond (jsonResponse status200 (object ["checked" .= checked, "dead" .= dead, "alive" .= alive]))
        ("GET", ["api", "v1", "maintenance", "prune-candidates"]) -> do
            items <- pruneCandidates conn 365
            respond (jsonResponse status200 (object ["items" .= items]))
        ("POST", ["api", "v1", "maintenance", "prune"]) -> do
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> case parseMaybeObj v of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case parseMaybe (.: "ids") o :: Maybe [Int] of
                        Nothing -> respond (jsonError status400 "bad_request" "ids is required")
                        Just ids -> do
                            n <- pruneApply conn ids
                            respond (jsonResponse status200 (object ["pruned" .= n, "restored" .= (0 :: Int)]))
        ("POST", ["api", "v1", "undo"]) -> do
            n <- undoLast conn
            respond (jsonResponse status200 (object ["restored" .= n]))
        ("POST", ["api", "v1", "import"]) -> importHandler conn req respond
        ("POST", ["api", "v1", "import", "json"]) -> do
            body <- strictRequestBody req
            case eitherDecode body of
                Left err -> respond (jsonError status400 "bad_request" (T.pack err))
                Right value -> do
                    result <- importJson conn value
                    case result of
                        Left err -> respond (jsonError status400 "bad_request" err)
                        Right report -> respond (jsonResponse status200 report)
        ("GET", ["api", "v1", "export"]) ->
            if param "format" req == Just "json"
                then do
                    value <- exportJson conn
                    respond
                        ( responseLBS
                            status200
                            [ (hContentType, "application/json; charset=utf-8")
                            , (hContentDisposition, "attachment; filename=\"eza-export.json\"")
                            ]
                            (encode value)
                        )
                else do
                    content <- exportBookmarks conn
                    respond
                        ( responseLBS
                            status200
                            [ (hContentType, "text/html; charset=utf-8")
                            , (hContentDisposition, "attachment; filename=\"bookmarks.html\"")
                            ]
                            (LBS.fromStrict (TE.encodeUtf8 content))
                        )
        ("GET", ["api", "v1", "export", "notes"]) ->
            respond (jsonError status501 "not_implemented" "Markdown note export is coming in a later milestone")
        ("GET", ["account", "add-passkey"]) -> respond (htmlResponse addPasskeyPage)
        ("GET", ["api", "v1", "stats"]) -> do
            stats <- libraryStats conn
            links <- Db.queryScalar conn "SELECT COUNT(*) FROM links"
            respond
                ( jsonResponse
                    status200
                    ( object
                        [ "bookmarks" .= lsTotal stats
                        , "tags" .= lsTags stats
                        , "bookmark_tags" .= lsTagLinks stats
                        , "links" .= links
                        , "sources" .= lsSources stats
                        , "top_sources" .= lsTopSources stats
                        , "sources_once" .= lsSourcesOnce stats
                        , "first_day" .= lsFirstDay stats
                        , "last_day" .= lsLastDay stats
                        , "days" .= lsDays stats
                        , "years" .= lsYears stats
                        , "filing_days" .= lsFilingDays stats
                        , "unread" .= lsUnread stats
                        , "dead" .= lsDead stats
                        , "highlights" .= lsHighlights stats
                        , "shares" .= lsShares stats
                        , "jobs_pending" .= lsQueued stats
                        , "favicon_bytes" .= lsFaviconBytes stats
                        ]
                    )
                )
        ("GET", ["api", "v1", "ai", "status"]) -> do
            provider <- fromMaybe (cfgAiProvider cfg) <$> lookupEnv "EZA_AI_PROVIDER"
            key <-
                case provider of
                    "ollama" -> pure (Just "")
                    "openai" -> lookupEnv "OPENAI_API_KEY"
                    "openai-compatible" -> lookupEnv "OPENAI_API_KEY"
                    "none" -> pure Nothing
                    _ -> lookupEnv "ANTHROPIC_API_KEY"
            let configured = maybe False (not . null) key
            respond
                ( jsonResponse
                    status200
                    ( object
                        [ "provider" .= provider
                        , "model" .= (if provider == "ollama" then T.pack (cfgAiModel cfg) else ("default" :: Text))
                        , "configured" .= configured
                        ]
                    )
                )
        ("GET", ["api", "v1", "rules"]) -> do
            rules <- listRules conn
            respond (jsonResponse status200 (object ["rules" .= rules]))
        ("POST", ["api", "v1", "rules"]) -> do
            body <- strictRequestBody req
            case eitherDecode body of
                Left err -> respond (jsonError status400 "bad_request" (T.pack err))
                Right rule -> do
                    created <- createRule conn (sanitizeRule rule)
                    respond (jsonResponse status201 created)
        ("POST", ["api", "v1", "rules", "test"]) -> do
            body <- strictRequestBody req
            case eitherDecode body of
                Left err -> respond (jsonError status400 "bad_request" (T.pack err))
                Right rule -> do
                    ids <- matchingBookmarks conn (ruleField rule) (rulePattern rule)
                    respond (jsonResponse status200 (object ["matches" .= length ids, "bookmark_ids" .= ids]))
        ("PATCH", ["api", "v1", "rules", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid rule id")
            Just rid -> do
                body <- strictRequestBody req
                case eitherDecode body of
                    Left err -> respond (jsonError status400 "bad_request" (T.pack err))
                    Right rule -> do
                        ok <- updateRule conn (sanitizeRule rule){ruleId = rid}
                        if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonError status404 "not_found" "rule not found")
        ("DELETE", ["api", "v1", "rules", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid rule id")
            Just rid -> do
                ok <- deleteRule conn rid
                if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "rule not found")
        ("GET", ["api", "v1", "tokens"]) -> do
            tokens <- listTokens conn
            respond (jsonResponse status200 (object ["tokens" .= tokens]))
        ("POST", ["api", "v1", "tokens"]) -> do
            body <- strictRequestBody req
            case eitherDecode body of
                Left err -> respond (jsonError status400 "bad_request" (T.pack err))
                Right (TokenCreateBody name scopes) -> do
                    (_, raw, view) <- createToken conn name (fromMaybe ["read", "write"] scopes)
                    respond (jsonResponse status201 (object ["token" .= raw, "token_info" .= view]))
        ("DELETE", ["api", "v1", "tokens", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid token id")
            Just tokenId -> do
                ok <- revokeToken conn tokenId
                if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "token not found")
        ("GET", ["api", "v1", "account"]) -> do
            payload <- accountPayload conn ctx
            respond (jsonResponse status200 payload)
        ("POST", ["api", "v1", "account", "2fa"]) -> accountTwoFactorHandler cfg conn ctx req respond
        ("POST", ["api", "v1", "account", "password"]) ->
            accountPasswordHandler cfg conn ctx req respond
        ("POST", ["api", "v1", "account", "username"]) ->
            accountUsernameHandler cfg conn req respond
        ("POST", ["api", "v1", "account", "sessions", "revoke-others"]) -> case ctx of
            CookieSession sess -> do
                revoked <- Auth.deleteOtherSessions conn sess
                respond (jsonResponse status200 (object ["revoked" .= revoked]))
            BearerToken _ -> respond (jsonError status403 "session_required" "a bearer token cannot revoke browser sessions")
        ("POST", ["api", "v1", "account", "passkeys", "options"]) -> do
            r <- Auth.addPasskeyOptions conn (authConfig cfg)
            either (respond . authErrResponse) (respond . jsonResponse status200) r
        ("POST", ["api", "v1", "account", "passkeys", "verify"]) -> do
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> do
                    r <- Auth.verifyAddPasskey conn (authConfig cfg) v
                    case r of
                        Left e -> respond (authErrResponse e)
                        Right () -> respond (jsonResponse status200 (object ["ok" .= True]))
        ("PATCH", ["api", "v1", "account", "passkeys", cidTxt]) ->
            case Auth.decodeCredentialId cidTxt of
                Nothing -> respond (jsonError status400 "bad_request" "invalid credential id")
                Just cid -> do
                    body <- jsonBody req
                    case body of
                        Left e -> respond (jsonError status400 "bad_request" e)
                        Right v -> case parseMaybeObj v of
                            Nothing -> respond (jsonError status400 "bad_request" "nickname is required")
                            Just o -> case parseMaybe (.: "nickname") o of
                                Nothing -> respond (jsonError status400 "bad_request" "nickname is required")
                                Just nick -> do
                                    ok <- Auth.renameCredential conn cid nick
                                    if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonError status404 "not_found" "passkey not found")
        ("DELETE", ["api", "v1", "account", "passkeys", cidTxt]) ->
            case Auth.decodeCredentialId cidTxt of
                Nothing -> respond (jsonError status400 "bad_request" "invalid credential id")
                Just cid -> do
                    r <- Auth.deleteCredential conn cid
                    either (respond . authErrResponse) (const (respond (emptyResponse status204))) r
        ("POST", ["api", "v1", "account", "recovery", "regenerate"]) -> do
            codes <- Auth.regenerateRecoveryCodes conn
            respond (jsonResponse status200 (object ["codes" .= codes]))
        ("POST", ["api", "auth", "logout"]) -> case ctx of
            CookieSession sess -> do
                Auth.deleteSessionHash conn (Auth.sessId sess)
                respond (clearAuthCookies cfg (emptyResponse status204))
            BearerToken _ -> respond (jsonError status403 "session_required" "a bearer token cannot end a browser session")
        ("GET", path)
            | not ("api" `elem` path)
            , not ("assets" `elem` path) ->
                indexResponse cfg req respond
        _ -> respond (jsonError status404 "not_found" "No such route")

-- ---------------------------------------------------------------------------
-- Auth guard
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Browser clipper
-- ---------------------------------------------------------------------------

isClipPath :: [Text] -> Bool
isClipPath path = case path of
    ("api" : "v1" : "clip" : _) -> True
    ("api" : "v1" : "clip-templates" : _) -> True
    ["api", "v1", "whoami"] -> True
    _ -> False

isExtensionOrigin :: Text -> Bool
isExtensionOrigin origin =
    any
        (`T.isPrefixOf` T.toLower origin)
        [ "chrome-extension://"
        , "moz-extension://"
        , "safari-web-extension://"
        ]

clipOriginAllowed :: Config -> Request -> Bool
clipOriginAllowed cfg req =
    case lookup "Origin" (requestHeaders req) of
        Nothing -> True
        Just raw ->
            let origin = TE.decodeUtf8 raw
             in origin `elem` cfgClipOrigins cfg
                    || origin `elem` cfgAllowedOrigins cfg
                    || isExtensionOrigin origin

requestOriginAllowed :: Config -> Request -> Bool
requestOriginAllowed cfg req
    | isClipPath (pathInfo req) = clipOriginAllowed cfg req
    | otherwise = originAllowed cfg req

corsHeaders :: Config -> Request -> ResponseHeaders
corsHeaders cfg req =
    case lookup "Origin" (requestHeaders req) of
        Just raw
            | clipOriginAllowed cfg req ->
                [ ("Access-Control-Allow-Origin", raw)
                , ("Vary", "Origin")
                , ("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
                , ("Access-Control-Allow-Headers", "Authorization, Content-Type, Idempotency-Key, X-Eza-Client")
                , ("Access-Control-Max-Age", "600")
                ]
        _ -> []

withCors :: Config -> Request -> Response -> Response
withCors cfg req = mapResponseHeaders (<> corsHeaders cfg req)

clipPreflight :: Config -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
clipPreflight cfg req respond
    | clipOriginAllowed cfg req =
        respond
            ( mapResponseHeaders
                (<> corsHeaders cfg req)
                (responseLBS status204 [] "")
            )
    | otherwise = respond (jsonError status403 "origin" "origin is not allowed")

clipErrorResponse :: Config -> Request -> ClipError -> Response
clipErrorResponse cfg req err =
    withCors cfg req (jsonError (mkStatus (clipErrorStatus err) "") (clipErrorCode err) (clipErrorMessage err))

clipSaveHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
clipSaveHandler cfg conn req respond = do
    body <- readBodyLimited (8 * 1024 * 1024) req
    case body of
        Left () -> respond (jsonError status413 "payload_too_large" "clip body must be at most 8 MiB")
        Right raw -> case eitherDecode raw of
            Left err -> respond (withCors cfg req (jsonError status400 "bad_request" (T.pack err)))
            Right request -> do
                let headerKey = fmap TE.decodeUtf8 (lookup "Idempotency-Key" (requestHeaders req))
                    request' = request{clIdempotencyKey = headerKey `orElse` clIdempotencyKey request}
                result <- saveClip conn request'
                case result of
                    Left err -> respond (clipErrorResponse cfg req err)
                    Right saved -> do
                        if scrNeedsEnrichment saved
                            then enqueueEnrichment conn (scrBookmarkId saved)
                            else pure ()
                        let status = if scrBookmarkCreated saved && not (scrReplayed saved) then status201 else status200
                        respond (withCors cfg req (jsonResponse status saved))
  where
    orElse (Just value) _ = Just value
    orElse Nothing fallback = fallback

clipPreviewHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
clipPreviewHandler cfg conn req respond = do
    body <- readBodyLimited (8 * 1024 * 1024) req
    case body of
        Left () -> respond (payloadTooLargeResponse cfg)
        Right raw -> case eitherDecode raw of
            Left err -> respond (jsonError status400 "bad_request" (T.pack err))
            Right request -> do
                result <- previewClip conn request
                case result of
                    Left err -> respond (clipErrorResponse cfg req err)
                    Right preview -> respond (jsonResponse status200 preview)

whoAmI :: Config -> Connection -> Request -> AuthContext -> (Response -> IO ResponseReceived) -> IO ResponseReceived
whoAmI cfg conn req ctx respond =
    case ctx of
        BearerToken token -> do
            account <- Auth.loadAccount conn
            respond
                ( withCors
                    cfg
                    req
                    ( jsonResponse
                        status200
                        ( object
                            [ "username" .= Auth.acctUsername account
                            , "token_name" .= tokenName token
                            , "scopes" .= tokenScopes token
                            ]
                        )
                    )
                )
        CookieSession _ -> do
            account <- Auth.loadAccount conn
            respond
                ( withCors
                    cfg
                    req
                    ( jsonResponse
                        status200
                        ( object
                            [ "username" .= Auth.acctUsername account
                            , "token_name" .= ("" :: Text)
                            , "scopes" .= (["session"] :: [Text])
                            ]
                        )
                    )
                )

templateWriteSession :: (Response -> IO ResponseReceived) -> AuthContext -> IO ResponseReceived -> IO ResponseReceived
templateWriteSession respond ctx action =
    case ctx of
        CookieSession _ -> action
        BearerToken _ -> respond (jsonError status403 "session_required" "template writes require a browser session")

templateCreateHandler :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
templateCreateHandler conn req respond = do
    body <- readBodyLimited (2 * 1024 * 1024) req
    case body of
        Left () -> respond (jsonError status413 "payload_too_large" "template is too large")
        Right raw -> case eitherDecode raw of
            Left err -> respond (jsonError status400 "bad_request" (T.pack err))
            Right template -> do
                result <- createTemplate conn template
                case result of
                    Left err -> respond (templateErrorResponse err)
                    Right created -> respond (jsonResponse status201 created)

templateUpdateHandler :: Connection -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
templateUpdateHandler conn templateId req respond = do
    body <- readBodyLimited (2 * 1024 * 1024) req
    case body of
        Left () -> respond (jsonError status413 "payload_too_large" "template is too large")
        Right raw -> case eitherDecode raw of
            Left err -> respond (jsonError status400 "bad_request" (T.pack err))
            Right template -> do
                result <- updateTemplate conn template{ctId = templateId}
                case result of
                    Left err -> respond (templateErrorResponse err)
                    Right updated -> respond (jsonResponse status200 updated)

templateDeleteHandler :: Connection -> Int -> (Response -> IO ResponseReceived) -> IO ResponseReceived
templateDeleteHandler conn templateId respond = do
    result <- deleteTemplate conn templateId
    case result of
        Left err -> respond (templateErrorResponse err)
        Right () -> respond (emptyResponse status204)

templateErrorResponse :: TemplateError -> Response
templateErrorResponse err =
    jsonError (mkStatus (templateErrorStatus err) "") (templateErrorCode err) (templateErrorMessage err)

withAuthed :: Config -> ServerDb -> Request -> (Response -> IO ResponseReceived) -> (AuthContext -> Connection -> IO ResponseReceived) -> IO ResponseReceived
withAuthed cfg db req respond action = do
    authResult <- withMVar (sdbWrite db) $ \conn -> authenticateRequest cfg conn req
    case authResult of
        Left response -> respond response
        Right ctx
            | requestMethod req `elem` ["GET", "HEAD"] -> withReadDb db (action ctx)
            | otherwise -> withDb db (action ctx)

{- | Resolve the bearer token or session and apply the scope/CSRF/origin
checks. Runs on the writer connection because session lookup may touch
@last_seen_at@; the handler itself runs on the read pool for GET/HEAD.
-}
authenticateRequest :: Config -> Connection -> Request -> IO (Either Response AuthContext)
authenticateRequest cfg conn req =
    case bearerToken req of
        Just raw -> do
            mtoken <- authenticateToken conn raw
            pure $ case mtoken of
                Nothing -> Left (jsonError status401 "unauthenticated" "invalid bearer token")
                Just token
                    | requiresSession (pathInfo req) ->
                        Left (jsonError status403 "session_required" "this route requires a browser session")
                    | not (tokenAllows token (TE.decodeUtf8 (requestMethod req)) (pathInfo req)) ->
                        Left (jsonError status403 "token_scope" "this token does not allow the request")
                    | not (requestOriginAllowed cfg req) ->
                        Left (jsonError status403 "origin" "origin is not allowed")
                    | otherwise -> Right (BearerToken token)
        Nothing -> do
            msess <- sessionFromReq conn req
            pure $ case msess of
                Nothing -> Left (unauthorized req)
                Just sess
                    | not (Auth.scopeAllows (Auth.sessScope sess) (TE.decodeUtf8 (requestMethod req)) (pathInfo req)) ->
                        Left (jsonError status403 "session_scope" "this session may not use this route")
                    | not (requestOriginAllowed cfg req) ->
                        Left (jsonError status403 "origin" "origin is not allowed")
                    | not (csrfOk req sess) ->
                        Left (jsonError status403 "csrf" "missing or invalid CSRF token")
                    | otherwise -> Right (CookieSession sess)

bearerToken :: Request -> Maybe Text
bearerToken req =
    case lookup hAuthorization (requestHeaders req) of
        Nothing -> Nothing
        Just raw ->
            let value = TE.decodeUtf8 raw
             in if "Bearer " `T.isPrefixOf` value then Just (T.drop 7 value) else Nothing

requiresSession :: [Text] -> Bool
requiresSession path = case path of
    ("account" : _) -> True
    ("api" : "v1" : "account" : _) -> True
    ("api" : "v1" : "tokens" : _) -> True
    ("api" : "v1" : "rules" : _) -> True
    ["save"] -> True
    _ -> False

csrfOk :: Request -> Auth.Session -> Bool
csrfOk req sess
    | requestMethod req `notElem` ["POST", "PUT", "PATCH", "DELETE"] = True
    | otherwise =
        case lookup "X-CSRF-Token" (requestHeaders req) of
            Nothing -> False
            Just raw -> Auth.hashToken (TE.decodeUtf8 raw) == Auth.sessCsrf sess

originAllowed :: Config -> Request -> Bool
originAllowed cfg req =
    case lookup "Origin" (requestHeaders req) of
        Nothing -> True
        Just raw -> TE.decodeUtf8 raw `elem` cfgAllowedOrigins cfg

sessionCookieFrom :: Connection -> Text -> Request -> IO (Maybe Auth.Session)
sessionCookieFrom conn cookieName req =
    case lookup hCookie (requestHeaders req) of
        Nothing -> pure Nothing
        Just rawCookie -> do
            let cookies = Cookie.parseCookies rawCookie
                rawToken = lookup (TE.encodeUtf8 cookieName) cookies
            case rawToken of
                Nothing -> pure Nothing
                Just token -> Auth.getSession conn (TE.decodeUtf8 token)

sessionFromReq :: Connection -> Request -> IO (Maybe Auth.Session)
sessionFromReq conn = sessionCookieFrom conn Auth.sessionCookieName

{- | The pending cookie that the password step set. Only a live @pending_2fa@
session resolves; the normal session cookie is not consulted here.
-}
pendingSessionFromReq :: Connection -> Request -> IO (Maybe Auth.Session)
pendingSessionFromReq conn req = do
    msess <- sessionCookieFrom conn Auth.pendingCookieName req
    pure $ case msess of
        Just sess | Auth.sessScope sess == Auth.pendingScope -> Just sess
        _ -> Nothing

unauthorized :: Request -> Response
unauthorized req
    | "api" `elem` pathInfo req = jsonError status401 "unauthenticated" "sign in required"
    | otherwise = redirectTo "/login"

redirectTo :: Text -> Response
redirectTo target =
    responseLBS status302 [(hLocation, TE.encodeUtf8 target)] ""

-- ---------------------------------------------------------------------------
-- Cookies
-- ---------------------------------------------------------------------------

withAuthCookies :: Config -> Auth.NewSession -> Response -> Response
withAuthCookies cfg sess =
    mapResponseHeaders (\hs -> hs <> [sessionCookie, csrfCookie])
  where
    securePart = if cfgSecureCookies cfg then "; Secure" else ""
    maxAge = T.pack (show (Auth.nsTtlSeconds sess))
    sessionCookie =
        ( hSetCookie
        , BSC.pack
            ( T.unpack
                ( Auth.sessionCookieName
                    <> "="
                    <> Auth.nsToken sess
                    <> "; Path=/; HttpOnly; SameSite=Lax; Max-Age="
                    <> maxAge
                    <> securePart
                )
            )
        )
    csrfCookie =
        ( hSetCookie
        , BSC.pack
            ( T.unpack
                ( Auth.csrfCookieName
                    <> "="
                    <> Auth.nsCsrf sess
                    <> "; Path=/; SameSite=Lax; Max-Age="
                    <> maxAge
                    <> securePart
                )
            )
        )

{- | The short-lived cookie of a two-factor sign-in. It is HttpOnly, carries no
CSRF token, and can only finish the passkey step; it never opens a route on its
own.
-}
withPendingCookie :: Config -> Auth.NewSession -> Response -> Response
withPendingCookie cfg sess =
    mapResponseHeaders (\hs -> hs <> [pendingCookie (Auth.nsToken sess) (Auth.nsTtlSeconds sess)])
  where
    pendingCookie token ttl =
        ( hSetCookie
        , BSC.pack
            ( T.unpack
                ( Auth.pendingCookieName
                    <> "="
                    <> token
                    <> "; Path=/; HttpOnly; SameSite=Lax; Max-Age="
                    <> T.pack (show ttl)
                    <> securePart
                )
            )
        )
    securePart = if cfgSecureCookies cfg then "; Secure" else ""

clearPendingCookie :: Config -> Response -> Response
clearPendingCookie cfg =
    mapResponseHeaders
        ( \hs ->
            hs
                <> [(hSetCookie, BSC.pack (T.unpack (Auth.pendingCookieName <> "=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" <> securePart)))]
        )
  where
    securePart = if cfgSecureCookies cfg then "; Secure" else ""

clearAuthCookies :: Config -> Response -> Response
clearAuthCookies cfg =
    mapResponseHeaders
        ( \hs ->
            hs
                <> [ (hSetCookie, BSC.pack (T.unpack (Auth.sessionCookieName <> "=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" <> securePart)))
                   , (hSetCookie, BSC.pack (T.unpack (Auth.csrfCookieName <> "=; Path=/; SameSite=Lax; Max-Age=0" <> securePart)))
                   , (hSetCookie, BSC.pack (T.unpack (Auth.pendingCookieName <> "=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" <> securePart)))
                   ]
        )
  where
    securePart = if cfgSecureCookies cfg then "; Secure" else ""

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

health :: ServerDb -> (Response -> IO ResponseReceived) -> IO ResponseReceived
health db respond = do
    ok <- withResource (sdbRead db) Db.ping
    if ok
        then respond (jsonResponse status200 (object ["status" .= ("ok" :: Text), "version" .= ("0.1.0" :: Text)]))
        else respond (jsonError status503 "unavailable" "database is unavailable")

faviconHandler :: Connection -> Request -> Text -> (Response -> IO ResponseReceived) -> IO ResponseReceived
faviconHandler conn req domain respond = do
    cached <- getFavicon conn domain
    case cached of
        Nothing -> respond (redirectTo "/assets/favicon-fallback.svg")
        Just favicon -> do
            let etag = TE.encodeUtf8 (fvEtag favicon)
            case lookup hIfNoneMatch (requestHeaders req) of
                Just raw
                    | raw == etag ->
                        respond
                            ( responseLBS
                                status304
                                [ (hContentType, TE.encodeUtf8 (fvMime favicon))
                                , (hETag, etag)
                                , (hCacheControl, "private, max-age=604800, immutable")
                                , ("Vary", "Cookie")
                                ]
                                ""
                            )
                _ ->
                    respond
                        ( responseLBS
                            status200
                            [ (hContentType, TE.encodeUtf8 (fvMime favicon))
                            , (hETag, etag)
                            , (hCacheControl, "private, max-age=604800, immutable")
                            , ("Vary", "Cookie")
                            ]
                            (LBS.fromStrict (fvBytes favicon))
                        )

data AddBody = AddBody Text (Maybe Text) (Maybe [Text])

instance FromJSON AddBody where
    parseJSON = withObject "AddBody" $ \o ->
        AddBody <$> o .: "url" <*> o .:? "title" <*> o .:? "tags"

addBookmark :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
addBookmark conn req respond = do
    body <- strictRequestBody req
    case eitherDecode body of
        Left err -> respond (jsonError status400 "bad_request" (T.pack err))
        Right (AddBody url title tags) ->
            if not (isHttpUrl url)
                then respond (jsonError status400 "bad_request" "url must be http(s)")
                else do
                    result <- insertBookmark conn url (fromMaybe "" title) (fromMaybe [] tags)
                    case result of
                        Left msg -> respond (jsonError status409 "conflict" msg)
                        Right bid -> do
                            enqueueEnrichment conn bid
                            respond (jsonResponse status201 (object ["id" .= bid]))

sanitizeRule :: Rule -> Rule
sanitizeRule rule =
    rule
        { ruleName = T.strip (ruleName rule)
        , ruleField = if T.toLower (ruleField rule) `elem` ["url", "domain", "title"] then T.toLower (ruleField rule) else "url"
        , rulePattern = T.strip (rulePattern rule)
        , ruleAddTags = [T.toLower (T.strip tag) | tag <- ruleAddTags rule, not (T.null (T.strip tag))]
        }

data HighlightCreateBody = HighlightCreateBody Text (Maybe Text) (Maybe Text) Int Int (Maybe Text) (Maybe Text)

instance FromJSON HighlightCreateBody where
    parseJSON = withObject "HighlightCreateBody" $ \o ->
        HighlightCreateBody
            <$> o .: "quote"
            <*> o .:? "prefix"
            <*> o .:? "suffix"
            <*> o .: "start_offset"
            <*> o .: "end_offset"
            <*> o .:? "note"
            <*> o .:? "color"

highlightCreateHandler :: Connection -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
highlightCreateHandler conn bid req respond = do
    body <- strictRequestBody req
    case eitherDecode body of
        Left err -> respond (jsonError status400 "bad_request" (T.pack err))
        Right (HighlightCreateBody quote prefix suffix start end note color) -> do
            result <- createHighlight conn bid quote (fromMaybe "" prefix) (fromMaybe "" suffix) start end (fromMaybe "" note) (fromMaybe "yellow" color)
            case result of
                Left err -> respond (jsonError status400 "bad_request" err)
                Right highlight -> respond (jsonResponse status201 highlight)

data HighlightPatchBody = HighlightPatchBody (Maybe Text) (Maybe Text)

instance FromJSON HighlightPatchBody where
    parseJSON = withObject "HighlightPatchBody" $ \o ->
        HighlightPatchBody <$> o .:? "note" <*> o .:? "color"

highlightUpdateHandler :: Connection -> Int -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
highlightUpdateHandler conn bid hid req respond = do
    body <- strictRequestBody req
    case eitherDecode body of
        Left err -> respond (jsonError status400 "bad_request" (T.pack err))
        Right (HighlightPatchBody note color) -> do
            ok <- updateHighlight conn bid hid note color
            if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonError status404 "not_found" "highlight not found")

data ShareCreateBody = ShareCreateBody Text Int (Maybe Bool) (Maybe Int)

instance FromJSON ShareCreateBody where
    parseJSON = withObject "ShareCreateBody" $ \o ->
        ShareCreateBody <$> o .: "scope" <*> o .: "target_id" <*> o .:? "include_note" <*> o .:? "expires_in_days"

shareCreateHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
shareCreateHandler cfg conn req respond = do
    body <- strictRequestBody req
    case eitherDecode body of
        Left err -> respond (jsonError status400 "bad_request" (T.pack err))
        Right (ShareCreateBody scope targetId includeNote expires) -> do
            let days = fromMaybe (cfgShareTtlDays cfg) expires
            result <- createShare conn scope targetId (fromMaybe False includeNote) days
            case result of
                Left err -> respond (jsonError status400 "bad_request" err)
                Right (shareId, raw) ->
                    respond (jsonResponse status201 (object ["id" .= shareId, "url" .= (cfgPublicOrigin cfg <> "/s/" <> raw)]))

publicShareHandler :: Connection -> Text -> (Response -> IO ResponseReceived) -> IO ResponseReceived
publicShareHandler conn token respond = do
    let isFeed = T.isSuffixOf ".xml" token
        raw = if isFeed then T.dropEnd 4 token else token
    state <- resolveShareState conn raw
    case state of
        ShareGone reason ->
            if isFeed
                then respond (shareHeaders (jsonError (unavailableStatus reason) "not_found" "share link is not readable"))
                else respond (shareHeaders (htmlResponseAt (unavailableStatus reason) (shareUnavailablePage reason)))
        ShareReadable record
            | srScope record == "bookmark" -> do
                bookmark <- getBookmark conn (srTargetId record)
                case bookmark of
                    Nothing -> respond (shareHeaders (htmlResponseAt status404 (shareUnavailablePage ShareInvalid)))
                    Just detail
                        | isFeed -> respond (shareHeaders (jsonError status404 "not_found" "feeds are only available for saved searches"))
                        | otherwise -> respond (shareHeaders (htmlResponseAt status200 (shareBookmarkPage record detail)))
            | srScope record == "saved_search" -> do
                searches <- listSavedSearches conn
                case [saved | saved <- searches, ssId saved == srTargetId record] of
                    [] -> respond (shareHeaders (htmlResponseAt status404 (shareUnavailablePage ShareInvalid)))
                    (saved : _) -> do
                        page <- listBookmarks conn (defaultListQuery{lqQ = ssQ saved, lqTags = ssTags saved, lqLimit = 100})
                        if isFeed
                            then respond (shareHeaders (responseLBS status200 [(hContentType, "application/atom+xml; charset=utf-8")] (LBS.fromStrict (TE.encodeUtf8 (shareSearchFeed saved page)))))
                            else respond (shareHeaders (htmlResponseAt status200 (shareSearchPage record saved page)))
            | otherwise -> respond (shareHeaders (htmlResponseAt status404 (shareUnavailablePage ShareInvalid)))
  where
    shareHeaders = mapResponseHeaders (<> [("X-Robots-Tag", "noindex")])
    unavailableStatus ShareInvalid = status404
    unavailableStatus _ = status410

snapshotHandler :: Config -> Connection -> Int -> (Response -> IO ResponseReceived) -> IO ResponseReceived
snapshotHandler cfg conn bid respond = do
    bookmark <- getBookmark conn bid
    case bookmark of
        Just detail
            | bdSnapshotKind detail /= "file" || T.null (bdSnapshotPath detail) ->
                respond (jsonError status404 "not_found" "no local snapshot for this bookmark")
            | otherwise -> do
                let rawPath = T.unpack (bdSnapshotPath detail)
                    root = cfgSnapshotDir cfg
                resolved <- canonicalizePath rawPath
                rootResolved <- canonicalizePath root
                exists <- doesFileExist resolved
                if exists && isPrefixOf rootResolved resolved
                    then
                        respond
                            ( responseFile
                                status200
                                [ (hContentType, "text/html; charset=utf-8")
                                , ("Content-Security-Policy", "sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data: https:")
                                , ("X-Content-Type-Options", "nosniff")
                                ]
                                resolved
                                Nothing
                            )
                    else respond (jsonError status404 "not_found" "snapshot file not found")
        Nothing -> respond (jsonError status404 "not_found" "bookmark not found")

data BulkBody = BulkBody Text [Int] (Maybe [Text]) (Maybe Bool)

instance FromJSON BulkBody where
    parseJSON = withObject "BulkBody" $ \o ->
        BulkBody <$> o .: "action" <*> o .:? "ids" .!= [] <*> o .:? "tags" <*> o .:? "confirm"

bulkHandler :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
bulkHandler conn req respond = do
    body <- strictRequestBody req
    case eitherDecode body of
        Left err -> respond (jsonError status400 "bad_request" (T.pack err))
        Right (BulkBody action ids tags confirm) -> do
            let parsed = case action of
                    "add_tags" -> Right (BulkAddTags (fromMaybe [] tags))
                    "remove_tags" -> Right (BulkRemoveTags (fromMaybe [] tags))
                    "mark_read" -> Right (BulkMarkRead True)
                    "mark_unread" -> Right (BulkMarkRead False)
                    "delete" | confirm == Just True -> Right BulkDelete
                    "delete" -> Left "delete requires confirm: true"
                    _ -> Left "unknown bulk action"
            case parsed of
                Left err -> respond (jsonError status400 "bad_request" err)
                Right bulkAction -> do
                    result <- bulkUpdate conn bulkAction ids
                    case result of
                        Left err -> respond (jsonError status400 "bad_request" err)
                        Right (updated, snapshotId) ->
                            respond (jsonResponse status200 (object ["updated" .= updated, "snapshot_id" .= snapshotId]))

data TokenCreateBody = TokenCreateBody Text (Maybe [Text])

instance FromJSON TokenCreateBody where
    parseJSON = withObject "TokenCreateBody" $ \o ->
        TokenCreateBody <$> o .: "name" <*> o .:? "scopes"

data QuickBody = QuickBody Text (Maybe Text) (Maybe [Text])

instance FromJSON QuickBody where
    parseJSON = withObject "QuickBody" $ \o ->
        QuickBody <$> o .: "url" <*> o .:? "title" <*> o .:? "tags"

quickSaveHandler :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
quickSaveHandler conn req respond = do
    body <- strictRequestBody req
    case eitherDecode body of
        Left err -> respond (jsonError status400 "bad_request" (T.pack err))
        Right (QuickBody url title tags)
            | not (isHttpUrl url) -> respond (jsonError status400 "bad_request" "url must be http(s)")
            | otherwise -> do
                result <- quickSave conn url (fromMaybe "" title) (fromMaybe [] tags)
                case result of
                    Left message -> respond (jsonError status409 "conflict" message)
                    Right (bid, existing) -> do
                        if existing
                            then pure ()
                            else enqueueEnrichment conn bid
                        respond (jsonResponse (if existing then status200 else status201) (object ["id" .= bid, "existing" .= existing]))

data MarkAboveBody = MarkAboveBody (Maybe Int)

instance FromJSON MarkAboveBody where
    parseJSON = withObject "MarkAboveBody" $ \o -> MarkAboveBody <$> o .:? "above_id"

markAbove :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
markAbove conn req respond = do
    body <- strictRequestBody req
    case eitherDecode body of
        Left err -> respond (jsonError status400 "bad_request" (T.pack err))
        Right (MarkAboveBody aid) -> do
            n <- markAllAbove conn aid
            respond (jsonResponse status200 (object ["updated" .= n]))

data PatchBody = PatchBody (Maybe Text) (Maybe Text) (Maybe Bool) (Maybe [Text])

instance FromJSON PatchBody where
    parseJSON = withObject "PatchBody" $ \o ->
        PatchBody <$> o .:? "title" <*> o .:? "note_body" <*> o .:? "is_read" <*> o .:? "tags"

patchBookmark :: Connection -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
patchBookmark conn bid req respond = do
    body <- strictRequestBody req
    case eitherDecode body of
        Left err -> respond (jsonError status400 "bad_request" (T.pack err))
        Right (PatchBody mTitle mNote mRead mTags)
            | maybe False (T.null . T.strip) mTitle -> respond (jsonError status400 "bad_request" "title must not be empty")
            | all (== Nothing) [fmap (const ()) mTitle, fmap (const ()) mNote, fmap (const ()) mRead, fmap (const ()) mTags] ->
                respond (jsonError status400 "bad_request" "empty patch")
            | otherwise -> do
                ok <- updateBookmark conn bid mTitle mNote mRead mTags
                if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonError status404 "not_found" "bookmark not found")

importHandler :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
importHandler conn req respond = do
    (_, files) <- parseRequestBodyEx defaultParseRequestBodyOptions lbsBackEnd req
    case lookup "file" files of
        Nothing -> respond (jsonError status400 "bad_request" "multipart field \"file\" is required")
        Just fileInfo -> do
            let raw = LBS.toStrict (fileContent fileInfo)
                parsed = parseNetscape defaultImportOptions raw
            report <- importParsed conn defaultImportOptions parsed
            respond (jsonResponse status200 report)

jsonBody :: Request -> IO (Either Text Value)
jsonBody req = do
    body <- strictRequestBody req
    pure (case eitherDecode body :: Either String Value of Left e -> Left (T.pack e); Right v -> Right v)

parseMaybeObj :: Value -> Maybe Object
parseMaybeObj (Object o) = Just o
parseMaybeObj _ = Nothing

authErrResponse :: Auth.AuthError -> Response
authErrResponse e =
    let base = jsonError (mkStatus (Auth.aeStatus e) "") (Auth.aeCode e) (Auth.aeMessage e)
     in case Auth.aeRetryAfter e of
            Nothing -> base
            Just seconds -> mapResponseHeaders (<> [("Retry-After", BSC.pack (show seconds))]) base

-- ---------------------------------------------------------------------------
-- Account handlers
-- ---------------------------------------------------------------------------

{- | The account document. @GET /api/v1/account@ and the two-factor toggle
return the same shape, so the account page can replace its copy after a
change without a second request.
-}
accountPayload :: Connection -> AuthContext -> IO Value
accountPayload conn ctx = do
    creds <- Auth.listCredentials conn
    remaining <- Auth.recoveryCodesRemaining conn
    sessions <- Auth.listSessions conn (case ctx of CookieSession sess -> Just sess; BearerToken _ -> Nothing)
    account <- Auth.loadAccount conn
    configured <- Auth.accountConfigured conn
    pure
        ( object
            [ "credentials" .= creds
            , "recovery_codes_remaining" .= remaining
            , "sessions" .= sessions
            , "username" .= Auth.acctUsername account
            , "has_password" .= Auth.accountHasPassword account
            , "require_passkey" .= Auth.acctRequirePasskey account
            , "account_configured" .= configured
            ]
        )

{- | Turn optional passkey two-factor on or off. Both directions need the
current password, and turning it on needs an already-registered passkey.
-}
accountTwoFactorHandler :: Config -> Connection -> AuthContext -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
accountTwoFactorHandler cfg conn ctx req respond = do
    body <- jsonBody req
    case body of
        Left e -> respond (jsonError status400 "bad_request" e)
        Right value -> case parseMaybeObj value of
            Nothing -> respond (jsonError status400 "bad_request" "invalid body")
            Just o -> case parseMaybe (.: "required") o :: Maybe Bool of
                Nothing -> respond (jsonError status400 "bad_request" "required is required")
                Just required -> do
                    let current = fromMaybe "" (parseMaybe (.: "current_password") o :: Maybe Text)
                    result <- Auth.setTwoFactorRequirement conn (authConfig cfg) required current
                    case result of
                        Left err -> respond (authErrResponse err)
                        Right _ -> do
                            payload <- accountPayload conn ctx
                            respond (jsonResponse status200 payload)

{- | Change the account password. A current password is required once one
exists; the session vouches for the first password on a legacy passkey-only
account. Other browser sessions are revoked so a stolen session does not keep
the old access.
-}
accountPasswordHandler :: Config -> Connection -> AuthContext -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
accountPasswordHandler cfg conn ctx req respond = do
    body <- jsonBody req
    case body of
        Left e -> respond (jsonError status400 "bad_request" e)
        Right value -> case parseMaybeObj value of
            Nothing -> respond (jsonError status400 "bad_request" "invalid body")
            Just o -> do
                let current = parseMaybe (.: "current_password") o :: Maybe Text
                    newPassword = parseMaybe (.: "new_password") o :: Maybe Text
                    confirm = parseMaybe (.: "confirm") o :: Maybe Text
                case (newPassword, confirm) of
                    (Just wanted, Just repeated)
                        | wanted /= repeated ->
                            respond (jsonError status400 "password_mismatch" "the new passwords do not match")
                        | otherwise -> case validatePassword wanted of
                            Left message -> respond (jsonError status400 "weak_password" message)
                            Right () -> do
                                account <- Auth.loadAccount conn
                                authorized <- case current of
                                    Just currentPassword -> Auth.verifyCurrentPassword conn (authConfig cfg) currentPassword
                                    Nothing -> pure (not (Auth.accountHasPassword account))
                                if not authorized
                                    then respond (jsonError status403 "invalid_password" "the current password is incorrect")
                                    else
                                        if T.null (Auth.acctUsername account)
                                            then respond (jsonError status409 "username_required" "set a username before setting a password")
                                            else do
                                                passwordHash <- Password.hashPassword (cfgArgon2 cfg) wanted
                                                Auth.setAccountPassword conn (Auth.acctUsername account) passwordHash
                                                case ctx of
                                                    CookieSession sess -> void (Auth.deleteOtherSessions conn sess)
                                                    BearerToken _ -> pure ()
                                                respond (jsonResponse status200 (object ["ok" .= True]))
                    _ -> respond (jsonError status400 "bad_request" "new_password and confirm are required")

-- | Rename the single account. A password, when set, must be confirmed.
accountUsernameHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
accountUsernameHandler cfg conn req respond = do
    body <- jsonBody req
    case body of
        Left e -> respond (jsonError status400 "bad_request" e)
        Right value -> case parseMaybeObj value of
            Nothing -> respond (jsonError status400 "bad_request" "invalid body")
            Just o -> do
                let current = parseMaybe (.: "current_password") o :: Maybe Text
                    wanted = parseMaybe (.: "username") o :: Maybe Text
                case wanted of
                    Nothing -> respond (jsonError status400 "bad_request" "username is required")
                    Just rawUsername -> do
                        account <- Auth.loadAccount conn
                        authorized <- case current of
                            Just currentPassword -> Auth.verifyCurrentPassword conn (authConfig cfg) currentPassword
                            Nothing -> pure (not (Auth.accountHasPassword account))
                        if not authorized
                            then respond (jsonError status403 "invalid_password" "the current password is incorrect")
                            else case validateUsername rawUsername of
                                Left message -> respond (jsonError status400 "invalid_username" message)
                                Right username -> do
                                    Auth.setAccountUsername conn username
                                    respond (jsonResponse status200 (object ["ok" .= True]))

-- ---------------------------------------------------------------------------
-- Query parsing
-- ---------------------------------------------------------------------------

listQueryFrom :: Request -> ListQuery
listQueryFrom req =
    let q = fromMaybe "" (param "q" req)
        tags = concatMap splitTags (allParams "tags" req)
        isRead = parseBool =<< param "is_read" req
        isDead = parseBool =<< param "is_dead" req
        sort = fromMaybe "created" (param "sort" req)
        offset = max 0 (fromMaybe 0 (readInt =<< param "offset" req))
        limit = min 200 (max 1 (fromMaybe 60 (readInt =<< param "limit" req)))
     in ListQuery q tags isRead isDead sort offset limit
  where
    splitTags = filter (not . T.null) . map (T.toLower . T.strip) . T.splitOn ","

dedupQueryFrom :: Request -> DedupQuery
dedupQueryFrom req =
    DedupQuery
        { dqUrlOffset = max 0 (fromMaybe 0 (readInt =<< param "url_offset" req))
        , dqUrlLimit = min 200 (max 1 (fromMaybe 60 (readInt =<< param "url_limit" req)))
        , dqTitleOffset = max 0 (fromMaybe 0 (readInt =<< param "title_offset" req))
        , dqTitleLimit = min 200 (max 1 (fromMaybe 40 (readInt =<< param "title_limit" req)))
        }

param :: BS.ByteString -> Request -> Maybe Text
param key req =
    case [v | (k, Just v) <- queryString req, k == key] of
        (v : _) -> Just (TE.decodeUtf8 v)
        [] -> Nothing

allParams :: BS.ByteString -> Request -> [Text]
allParams key req = [TE.decodeUtf8 v | (k, Just v) <- queryString req, k == key]

parseBool :: Text -> Maybe Bool
parseBool t = case T.toLower t of
    "1" -> Just True
    "true" -> Just True
    "0" -> Just False
    "false" -> Just False
    _ -> Nothing

readInt :: Text -> Maybe Int
readInt t = case reads (T.unpack t) of
    [(n, "")] -> Just n
    _ -> Nothing

isHttpUrl :: Text -> Bool
isHttpUrl t =
    let l = T.toLower (T.strip t)
     in "http://" `T.isPrefixOf` l || "https://" `T.isPrefixOf` l

-- ---------------------------------------------------------------------------
-- Static
-- ---------------------------------------------------------------------------

{- | A static file with an ETag and a cache policy. Asset URLs do not carry
build hashes, so the browser must revalidate instead of replaying a stale
copy after a rebuild. @no-store@ is reserved for the client shell.
-}
sendFile :: Request -> BS.ByteString -> [(HeaderName, BS.ByteString)] -> FilePath -> (Response -> IO ResponseReceived) -> IO ResponseReceived
sendFile req cachePolicy headers path respond = do
    sourceModified <- getModificationTime path
    gzipExists <- doesFileExist (path <> ".gz")
    gzipModified <- if gzipExists then Just <$> getModificationTime (path <> ".gz") else pure Nothing
    let
        -- A sidecar older than the source would serve stale bytes (the usual
        -- case while editing an asset without running the web build). Treat it
        -- as absent instead of trusting the extension.
        gzipFresh = case gzipModified of
            Just modified -> modified >= sourceModified
            Nothing -> False
        useGzip = gzipFresh && acceptsGzip req
        servedPath = if useGzip then path <> ".gz" else path
        compressionHeaders =
            [ (hVary, "Accept-Encoding")
            | gzipFresh
            ]
                <> [ (hContentEncoding, "gzip")
                   | useGzip
                   ]
    size <- getFileSize servedPath
    modified <- getModificationTime servedPath
    let tag = BSC.pack ("\"" <> show size <> "-" <> show (round (utcTimeToPOSIXSeconds modified) :: Integer) <> "\"")
        cacheable = cachePolicy /= "no-store"
        fresh = cacheable && lookup hIfNoneMatch (requestHeaders req) == Just tag
        allHeaders = headers <> compressionHeaders <> [(hCacheControl, cachePolicy)] <> [(hETag, tag) | cacheable]
    if fresh
        then respond (responseLBS status304 allHeaders "")
        else respond (responseFile status200 allHeaders servedPath Nothing)

{- | Whether the request's @Accept-Encoding@ allows gzip. Header values are
tokens; browsers send lowercase, so a lowercase-insensitive containment
check is enough here.
-}
acceptsGzip :: Request -> Bool
acceptsGzip req =
    case lookup hAcceptEncoding (requestHeaders req) of
        Nothing -> False
        Just value -> BSC.isInfixOf "gzip" (BSC.map toLower value)

serveStaticFile :: Config -> FilePath -> [(HeaderName, BS.ByteString)] -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
serveStaticFile cfg relative headers req respond = case cfgStaticDir cfg of
    Nothing -> respond (jsonError status404 "not_found" "static assets are not configured")
    Just root -> do
        let path = root </> relative
        exists <- doesFileExist path
        if exists
            then sendFile req "no-cache" headers path respond
            else respond (jsonError status404 "not_found" "asset not found")

serveAsset :: Config -> [Text] -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
serveAsset cfg rest req respond = case cfgStaticDir cfg of
    Nothing -> respond (jsonError status404 "not_found" "static assets are not configured")
    Just root -> do
        if any (== "..") rest
            then respond (jsonError status400 "bad_request" "invalid asset path")
            else do
                let rel = foldr (</>) "" (map T.unpack rest)
                    path = root </> rel
                exists <- doesFileExist path
                if exists
                    then sendFile req "no-cache" [(hContentType, mimeFor rel)] path respond
                    else respond (jsonError status404 "not_found" "asset not found")

-- | The shell HTML is never stored: a rebuild must reach the next navigation.
indexResponse :: Config -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
indexResponse cfg req respond = case cfgStaticDir cfg of
    Just root -> do
        buildId <- readBuildId cfg
        let buildHeader = [("X-Eza-Build", TE.encodeUtf8 buildId) | not (T.null buildId)]
        sendFile req "no-store" ([(hContentType, "text/html; charset=utf-8")] <> buildHeader) (root </> "index.html") respond
    Nothing -> respond (htmlResponse (placeholderPage cfg))

{- | The service worker version follows the web build id, so every rebuild is a
new worker and clients update on the next load without a manual unregister.
-}
serveServiceWorker :: Config -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
serveServiceWorker cfg req respond = case cfgStaticDir cfg of
    Nothing -> respond (jsonError status404 "not_found" "static assets are not configured")
    Just root -> do
        template <- BS.readFile (root </> "sw.js")
        buildId <- readBuildId cfg
        let generated =
                if T.null buildId
                    then template
                    else TE.encodeUtf8 (T.replace "eza-app-shell-v4-dev" ("eza-app-shell-" <> buildId) (TE.decodeUtf8 template))
            tag = BSC.pack ("\"" <> (if T.null buildId then BSC.unpack (BSC.pack (show (BS.length generated))) else T.unpack buildId) <> "\"")
            fresh = lookup hIfNoneMatch (requestHeaders req) == Just tag
            headers =
                [ (hContentType, "text/javascript; charset=utf-8")
                , ("Service-Worker-Allowed", "/")
                , (hCacheControl, "no-cache")
                , (hETag, tag)
                ]
                    <> [("X-Eza-Build", TE.encodeUtf8 buildId) | not (T.null buildId)]
        if fresh
            then respond (responseLBS status304 headers "")
            else respond (responseLBS status200 headers (LBS.fromStrict generated))

{- | The build id written by scripts/build-web.sh. Deployments that copy the
built static tree without that script fall back to the WASM file's size and
modification time, which still changes when the client is rebuilt.
-}
readBuildId :: Config -> IO Text
readBuildId cfg = case cfgStaticDir cfg of
    Nothing -> pure ""
    Just root -> do
        let path = root </> "app" </> "build-id"
        exists <- doesFileExist path
        if exists
            then T.strip . TE.decodeUtf8 <$> BS.readFile path
            else do
                let wasm = root </> "app" </> "app.wasm"
                wasmExists <- doesFileExist wasm
                if wasmExists
                    then do
                        size <- getFileSize wasm
                        modified <- getModificationTime wasm
                        pure ("wasm" <> T.pack (show size) <> "-" <> T.pack (show (round (utcTimeToPOSIXSeconds modified) :: Integer)))
                    else pure ""

mimeFor :: FilePath -> BS.ByteString
mimeFor p
    | ".css" `endOf` p = BSC.pack "text/css; charset=utf-8"
    | ".js" `endOf` p = BSC.pack "text/javascript; charset=utf-8"
    | ".mjs" `endOf` p = BSC.pack "text/javascript; charset=utf-8"
    | ".wasm" `endOf` p = BSC.pack "application/wasm"
    | ".html" `endOf` p = BSC.pack "text/html; charset=utf-8"
    | ".svg" `endOf` p = BSC.pack "image/svg+xml"
    | ".json" `endOf` p = BSC.pack "application/json"
    | ".png" `endOf` p = BSC.pack "image/png"
    | ".woff2" `endOf` p = BSC.pack "font/woff2"
    | ".webmanifest" `endOf` p = BSC.pack "application/manifest+json"
    | otherwise = BSC.pack "application/octet-stream"
  where
    endOf suffix s =
        let n = length suffix
         in length s >= n && drop (length s - n) s == suffix

-- ---------------------------------------------------------------------------
-- Responses
-- ---------------------------------------------------------------------------

jsonResponse :: (ToJSON a) => Status -> a -> Response
jsonResponse status value =
    responseLBS status [(hContentType, "application/json; charset=utf-8"), (hCacheControl, "no-store")] (encode value)

jsonError :: Status -> Text -> Text -> Response
jsonError status code message =
    jsonResponse status (object ["error" .= object ["code" .= code, "message" .= message]])

emptyResponse :: Status -> Response
emptyResponse status = responseLBS status [(hContentType, "application/json; charset=utf-8"), (hCacheControl, "no-store")] "{}"

htmlResponse :: Text -> Response
htmlResponse = htmlResponseAt status200

htmlResponseAt :: Status -> Text -> Response
htmlResponseAt status body =
    responseLBS status [(hContentType, "text/html; charset=utf-8"), (hCacheControl, "no-store")] (LBS.fromStrict (TE.encodeUtf8 body))

{- | The page a server with no static directory serves. It is not the app;
it says what is missing and follows the catalogue paper stock.
-}
placeholderPage :: Config -> Text
placeholderPage cfg =
    T.unlines
        [ "<!doctype html>"
        , "<html lang=\"en\"><head><meta charset=\"utf-8\">"
        , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        , "<meta name=\"color-scheme\" content=\"light dark\">"
        , "<title>eza | bare server</title>"
        , "<style>"
        , ":root{--paper:#F2EDE3;--card:#FBF8F1;--ink:#1A2340;--muted:#6E675C;--rule:#D5CBB8;--accent:#8A2B20}"
        , "@media (prefers-color-scheme: dark){:root{--paper:#10141F;--card:#161B28;--ink:#E9E3D6;--muted:#A9A08F;--rule:#232A3A;--accent:#C98A3E}}"
        , "body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:48px 36px;background:var(--paper);color:var(--ink);font-family:'Newsreader',Georgia,'Times New Roman',serif;font-size:17px;line-height:28px}"
        , "main{width:min(560px,100%);background:var(--card);border:1px solid var(--ink);border-radius:2px;padding:32px 34px 28px}"
        , ".kicker{margin:0 0 10px;font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:11px;line-height:16px;letter-spacing:.14em;text-transform:uppercase;color:var(--accent)}"
        , ".wordmark{margin:0;font-family:'Fraunces',Georgia,'Times New Roman',serif;font-size:36px;line-height:38px;font-weight:600;letter-spacing:-.02em}"
        , ".rule{height:1px;background:var(--ink);margin:14px 0 26px}"
        , "p{margin:0 0 14px}"
        , "dl{margin:20px 0 0;border-top:1px solid var(--rule)}"
        , "dl div{display:flex;justify-content:space-between;gap:20px;padding:7px 0;border-bottom:1px solid var(--rule)}"
        , "dt{font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:11px;line-height:16px;letter-spacing:.12em;text-transform:uppercase;color:var(--muted)}"
        , "dd{margin:0;font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;line-height:18px;color:var(--ink);overflow-wrap:anywhere}"
        , ".foot{margin:18px 0 0;font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:11px;line-height:16px;letter-spacing:.12em;text-transform:uppercase;color:var(--muted)}"
        , "</style>"
        , "</head><body><main>"
        , "<p class=\"kicker\">the catalogue</p>"
        , "<p class=\"wordmark\">eza</p>"
        , "<div class=\"rule\" aria-hidden=\"true\"></div>"
        , "<p>The server is running. The client bundle is not on disk, so there is nothing to load yet.</p>"
        , "<p>Point <code>EZA_STATIC_DIR</code> at the built <code>static</code> directory and reload this page.</p>"
        , "<dl><div><dt>static dir</dt><dd>" <> escapeHtml (T.pack (fromMaybe "(unset)" (cfgStaticDir cfg))) <> "</dd></div>"
        , "<div><dt>origin</dt><dd>" <> escapeHtml (cfgPublicOrigin cfg) <> "</dd></div></dl>"
        , "<p class=\"foot\">server only <span aria-hidden=\"true\">/</span> built assets required</p>"
        , "</main></body></html>"
        ]

escapeHtml :: Text -> Text
escapeHtml value =
    T.replace "\"" "&quot;" (T.replace ">" "&gt;" (T.replace "<" "&lt;" (T.replace "&" "&amp;" value)))

withDb :: ServerDb -> (Connection -> IO ResponseReceived) -> IO ResponseReceived
withDb db = withMVar (sdbWrite db)

withReadDb :: ServerDb -> (Connection -> IO ResponseReceived) -> IO ResponseReceived
withReadDb db = withResource (sdbRead db)
