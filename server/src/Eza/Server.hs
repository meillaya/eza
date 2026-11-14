{-# LANGUAGE OverloadedStrings #-}

{- | Warp application: public auth pages/ceremonies, deny-by-default API,
CSRF/session guard, and the bookmark/tag JSON surface.

Since M3a one process serves many accounts. The control database holds
identity; a request's session, pending, bearer, or share token names its
account in the token prefix, the guard resolves that account to a lazily
opened 'UserSlot', and every handler receives that user's library connection.
Tokens without a prefix fall back to the single-account behaviour only while
exactly one enabled account exists.
-}
module Eza.Server (
    AppState (..),
    UserSlot (..),
    newAppState,
    closeAppState,
    userSlotFor,
    userSlotCount,
    syncUserWorkers,
    stopAllUserWorkers,
    userWorkerIds,
    app,
    runServer,
    bootPayloadFor,
    clientHostKey,
) where

import Control.Concurrent.Async (async, cancel)

import Control.Exception (IOException, onException, throwIO, try)

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC

import Data.Char (toLower)

import Data.List (isInfixOf, nub)

import Data.Maybe (mapMaybe)

import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Data.Word (Word64)
import Database.SQLite.Simple (Connection)

import Network.HTTP.Types
import Network.Wai
import Network.Wai.Handler.Warp
import Network.Wai.Middleware.Gzip (GzipFiles (..), GzipSettings (..), defaultGzipSettings, gzip)
import Network.Wai.Middleware.RequestLogger (logStdout, logStdoutDev)
import Network.Wai.Middleware.RequestSizeLimit (defaultRequestSizeLimitSettings, requestSizeLimitMiddleware, setMaxLengthForRequest, setOnLengthExceeded)

import System.Exit (exitFailure)

import System.IO (hPutStrLn, stderr)

import qualified Eza.Auth as Auth
import qualified Eza.Authz as Authz

import Eza.Config
import Eza.Control (ControlUser (..))
import qualified Eza.Control as Control

import Eza.Pages (recoverPage)

import Eza.Routes (Route (..))
import qualified Eza.Routes as Routes

import Eza.Shell (pageAssets)

import Eza.Tokens (Token (..), validateToken)

import Eza.User (UserRole (..))

import Eza.Api.Auth (clientHostKey, loginHandler, passkeySecondFactorOptionsHandler, passkeySecondFactorVerifyHandler, passkeySetupRetired, passwordLoginHandler, passwordSetupHandler, recoveryRedeemHandler, setupHandler)
import Eza.Api.Bookmarks (bootPayloadFor)
import Eza.Api.Common
import Eza.Api.Context (AppState (..), AuthContext (..), RequestContext (..), UserSlot (..), closeAppState, logStartupWarnings, newAppState, recordSessionActivity, recordTokenActivity, requestSession, resolveApiToken, resolveSession, stopAllUserWorkers, syncUserWorkers, userSlotCount, userSlotFor, userWorkerIds, withDb, withReadDb, workerSupervisor)

import qualified Eza.Api.Auth as Auth
import qualified Eza.Api.Public as Public

import qualified Eza.Api.Account as Account
import qualified Eza.Api.Admin as Admin
import qualified Eza.Api.Bookmarks as Bookmarks
import qualified Eza.Api.Extensions as Extensions
import qualified Eza.Api.Graph as Graph
import qualified Eza.Api.Jobs as Jobs
import qualified Eza.Api.Maintenance as Maintenance
import qualified Eza.Api.Tags as Tags

import Eza.Api.Extensions (clipPreflight, isClipPath, requestOriginAllowed)
import Eza.Api.Public (health, publicShareHandler)
import Eza.Api.Static (indexResponse, serveAsset, serveNamedAsset, serveServiceWorker, serveStaticFile)

runServer :: Config -> IO ()
runServer cfg = do
    state <- newAppState cfg
    logStartupWarnings cfg state
    supervisor <- async (workerSupervisor state) `onException` closeAppState state
    let settings =
            setHost (fromString (bindHost (cfgBind cfg)))
                . setPort (bindPort (cfgBind cfg))
                . setServerName "eza"
                . setBeforeMainLoop (hPutStrLn stderr ("eza listening on " <> cfgBind cfg))
                $ defaultSettings
    outcome <- try (runSettings settings (gzip gzipSettings (securityMiddleware cfg (accessLogger cfg (app cfg state))))) :: IO (Either IOException ())
    cancel supervisor
    stopAllUserWorkers state
    closeAppState state
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

{- | Access logging follows @EZA_LOG_LEVEL@: @debug@ logs the full request
development line, @info@ logs one access line per request, and @warn@/@error@
(the default is @info@) leave access logging off while the explicit error
messages keep going to stderr.
-}
accessLogger :: Config -> Middleware
accessLogger cfg = case map toLower (cfgLogLevel cfg) of
    "debug" -> logStdoutDev
    "info" -> logStdout
    _ -> id

{- | Request-body limits in front of the routes. The limit is per path: the
multipart import keeps its larger import cap, every other unsafe method uses
the general JSON cap, and GET/HEAD carry no body. A declared or chunked body
over the cap is answered with the same JSON 413 shape as the public auth
ceremonies. The handlers still read through 'jsonBody', so the cap is also
enforced if a body arrives without a declared length.
-}
requestBodyLimitMiddleware :: Config -> Middleware
requestBodyLimitMiddleware cfg =
    requestSizeLimitMiddleware
        ( setOnLengthExceeded
            (\limit _app _req sendResponse -> sendResponse (requestTooLargeResponse limit))
            (setMaxLengthForRequest (pure . bodyLimitFor cfg) defaultRequestSizeLimitSettings)
        )

bodyLimitFor :: Config -> Request -> Maybe Word64
bodyLimitFor cfg req
    | requestMethod req `elem` ["GET", "HEAD"] = Nothing
    | pathInfo req `elem` [["api", "v1", "import"], ["api", "v1", "import", "json"]] =
        Just (fromIntegral (cfgImportMaxBytes cfg))
    | otherwise = Just (fromIntegral (cfgMaxBodyBytes cfg))

app :: Config -> AppState -> Application
app cfg state =
    catchAllMiddleware (requestBodyLimitMiddleware cfg (dispatchApp cfg state))

{- | The routed application, behind the request-body limit.

The request is parsed once: "Eza.Routes.matchRoute" yields the route the
server implements and "Eza.Routes.routeClass" says who may reach it. The
public surface runs before the guard; everything else goes through
'withAuthed'. Unknown API paths answer a JSON 404 and a known path with an
unsupported method answers a JSON 405 that names the methods it does allow.
-}
dispatchApp :: Config -> AppState -> Application
dispatchApp cfg state req respond =
    case requestMethod req of
        "OPTIONS" -> optionsDispatch
        _ -> case effectiveRoute of
            Just route -> dispatchMatched route
            Nothing -> dispatchUnmatched
  where
    method = TE.decodeUtf8 (requestMethod req)
    path = pathInfo req

    -- HEAD is the GET headers without a body. A public GET route is served
    -- for HEAD exactly as before; token reads are matched as HEAD by
    -- "Eza.Routes" itself.
    effectiveRoute = case Routes.matchRoute method path of
        Just route -> Just route
        Nothing
            | method == "HEAD" -> Routes.matchRoute "GET" path
            | otherwise -> Nothing

    authed route =
        withAuthed cfg state req respond $ \rctx conn ->
            authedRoute rctx conn route req respond

    dispatchMatched route = case Routes.routeClass route of
        Routes.PublicClass -> publicRoute route
        Routes.ShareClass -> publicRoute route
        Routes.SessionClass -> authed route
        Routes.TokenClass -> authed route
        Routes.AdminClass -> authed route
        Routes.DeniedClass -> respond (jsonProblem status404 "not_found" "No such route")

    dispatchUnmatched
        | isApiPath path = case knownMethods path of
            [] -> respond (jsonProblem status404 "not_found" "No such route")
            allowed -> respond (methodNotAllowed allowed)
        | otherwise = authedSpa
      where
        -- A non-API path that matched no route is still not an API request:
        -- keep the old authenticated fallthrough (which the guard denies).
        authedSpa = case Routes.matchRoute "GET" path of
            Just route -> authed route
            Nothing -> respond (jsonProblem status404 "not_found" "No such route")

    optionsDispatch
        | isClipPreflightPath path = clipPreflight cfg req respond
        | otherwise = case publicAllow (pathInfo req) of
            Just allow -> respond (responseLBS status204 [(hAllow, allow)] "")
            Nothing -> case effectiveRoute of
                Just route -> authed route
                Nothing -> respond (jsonProblem status404 "not_found" "No such route")

    publicRoute route = case route of
        RouteHealth -> health state respond
        RouteLoginPage -> loginHandler state req respond
        RouteSetupPage -> setupHandler state req respond
        RouteRecoverPage -> respond (htmlResponse (recoverPage (pageAssets (asAssets state))))
        RouteRootPage -> do
            msess <- requestSession state req
            case msess of
                Just (_, _, sess) | Auth.sessScope sess == "normal" -> indexResponse state req respond
                _ -> respond (redirectTo "/login")
        RouteStaticAsset segments -> serveAsset cfg (asAssets state) segments req respond
        RouteFavicon -> serveNamedAsset cfg (asAssets state) "favicon.svg" req respond
        RouteThemeJs -> serveNamedAsset cfg (asAssets state) "theme.js" req respond
        RouteManifest ->
            serveStaticFile cfg "manifest.webmanifest" [("Content-Type", "application/manifest+json")] req respond
        RouteServiceWorker -> serveServiceWorker (asAssets state) req respond
        RouteSharePage token -> publicShareHandler state token respond
        RouteShareFeed token -> publicShareHandler state (token <> ".xml") respond
        RoutePasswordLogin -> passwordLoginHandler state req respond
        RoutePasskeyLoginOptions -> passkeySecondFactorOptionsHandler state req respond
        RoutePasskeyLoginVerify -> passkeySecondFactorVerifyHandler state req respond
        RoutePasswordSetup -> passwordSetupHandler state req respond
        RoutePasskeySetupOptionsRetired -> respond passkeySetupRetired
        RoutePasskeySetupVerifyRetired -> respond passkeySetupRetired
        RouteRecoveryRedeem -> recoveryRedeemHandler state req respond
        -- These match before the guard; an authenticated method is a bug.
        _ -> respond (jsonProblem status405 "method_not_allowed" "method not allowed for this route")

{- | The methods the public surface answers for a path, for an OPTIONS
answer. A HEAD response always comes from the GET route, so it is added
explicitly. Nothing outside the public surface is advertised.
-}
publicAllow :: [Text] -> Maybe BS.ByteString
publicAllow path = case matched of
    [] -> Nothing
    _
        | any ((/= Routes.PublicClass) . Routes.routeClass) routes -> Nothing
        | otherwise ->
            Just
                ( BSC.pack
                    ( T.unpack
                        (T.intercalate ", " (ordered <> ["OPTIONS"]))
                    )
                )
  where
    methods = ["GET", "POST"]
    matched = [(m, route) | m <- methods, Just route <- [Routes.matchRoute m path]]
    routes = map snd matched
    ordered =
        concatMap
            (\(m, _) -> if m == "GET" then ["GET", "HEAD"] else [m])
            matched

-- | Methods that reach a known API path with a different method, used for 405.
knownMethods :: [Text] -> [Text]
knownMethods path =
    nub
        ( concatMap
            (\m -> if m == "GET" then ["GET", "HEAD"] else [m])
            [m | m <- ["GET", "HEAD", "POST", "PATCH", "DELETE"], Just _ <- [Routes.matchRoute m path]]
        )

-- | A JSON 405 with the methods this path does answer.
methodNotAllowed :: [Text] -> Response
methodNotAllowed allowed =
    mapResponseHeaders
        (<> [(hAllow, BSC.pack (T.unpack (T.intercalate ", " (allowed <> ["OPTIONS"]))))])
        (jsonProblem status405 "method_not_allowed" "method not allowed for this path")

isApiPath :: [Text] -> Bool
isApiPath path = case path of
    ("api" : _) -> True
    _ -> False

{- | Clip CORS preflights run before the guard and answer for the clipper's
routes, including the quick-save path that "Eza.Routes" classifies public.
-}
isClipPreflightPath :: [Text] -> Bool
isClipPreflightPath path = isClipPath path || path == ["api", "v1", "quick-save"]

-- Public auth handlers
-- ---------------------------------------------------------------------------

{- | Dispatch one authenticated request on its parsed "Eza.Routes" route. The
guard already resolved the principal, the scope, and the CSRF/origin checks; the
family modules own the handler bodies.
-}
authedRoute :: RequestContext -> Connection -> Route -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
authedRoute rctx conn route req respond
    | Jobs.owns route = Jobs.dispatch rctx conn route req respond
    | Extensions.owns route = Extensions.dispatch rctx conn route req respond
    | Bookmarks.owns route = Bookmarks.dispatch rctx conn route req respond
    | Tags.owns route = Tags.dispatch rctx conn route req respond
    | Graph.owns route = Graph.dispatch rctx conn route req respond
    | Maintenance.owns route = Maintenance.dispatch rctx conn route req respond
    | Account.owns route = Account.dispatch rctx conn route req respond
    | Admin.owns route = Admin.dispatch rctx conn route req respond
    | Auth.owns route = Auth.dispatch rctx conn route req respond
    | Public.owns route = Public.dispatch rctx conn route req respond
    | otherwise = respond (jsonProblem status500 "internal_error" "no route handler")

{- | Resolve the request principal, then run the handler on the right
connection: reads use the user database's read pool, writes use its one writer.
Authentication is a read-only validation on the read pool; only the throttled
activity timestamp write (at most once a minute per session or token) takes the
writer.
-}
withAuthed ::
    Config ->
    AppState ->
    Request ->
    (Response -> IO ResponseReceived) ->
    (RequestContext -> Connection -> IO ResponseReceived) ->
    IO ResponseReceived
withAuthed cfg state req respond action = do
    authResult <- authenticateRequest state req
    case authResult of
        Left response -> respond response
        Right (user, slot, ctx) -> do
            let rctx = RequestContext cfg state user slot ctx
            if requestMethod req `elem` ["GET", "HEAD"]
                then withReadDb slot (action rctx)
                else withDb slot (action rctx)

{- | The single guard. "Eza.Authz" decides what class of principal a route
takes and whether the presented scope or role may use it; this function
resolves the token prefix to the owning user database and applies the origin
and CSRF checks. The query strings in "Eza.Authz" are the only route-scope
source; the duplicate local classifiers are gone.
-}
authenticateRequest ::
    AppState ->
    Request ->
    IO (Either Response (Control.ControlUser, UserSlot, AuthContext))
authenticateRequest state req =
    case bearerToken req of
        Just rawToken -> bearerAuth rawToken
        Nothing -> cookieAuth
  where
    cfg = asConfig state
    method = TE.decodeUtf8 (requestMethod req)
    path = pathInfo req
    klass = Authz.routeClass method path
    sessionRequired =
        jsonProblem status403 "session_required" "this route requires a browser session"

    bearerAuth rawToken
        | klass `elem` [Authz.SessionClass, Authz.AdminClass] = pure (Left sessionRequired)
        | klass == Authz.DeniedClass = pure (Left (jsonProblem status404 "not_found" "No such route"))
        | otherwise = do
            resolved <- resolveApiToken state rawToken
            case resolved of
                Left message -> pure (Left (jsonProblem status503 "user_limit" message))
                Right Nothing -> pure (Left invalidBearerToken)
                Right (Just (user, slot, bare)) -> do
                    mtoken <- withReadDb slot $ \conn -> validateToken conn bare
                    case mtoken of
                        Nothing -> pure (Left invalidBearerToken)
                        Just token
                            | not (Authz.tokenAllows (mapMaybe Authz.scopeFromText (tokenScopes token)) method path) ->
                                pure (Left (jsonProblem status403 "token_scope" "this token does not allow the request"))
                            | not (requestOriginAllowed cfg req) ->
                                pure (Left (jsonProblem status403 "origin" "origin is not allowed"))
                            | otherwise -> do
                                recordTokenActivity slot token
                                pure (Right (user, slot, BearerToken token))

    cookieAuth =
        case cookieValue req Auth.sessionCookieName of
            Nothing -> pure (Left (unauthorized req))
            Just wire -> do
                resolved <- resolveSession state wire
                case resolved of
                    Left message -> pure (Left (jsonProblem status503 "user_limit" message))
                    Right Nothing -> pure (Left (unauthorized req))
                    Right (Just (user, slot, sess))
                        | not (sessionScopeAllows (cuRole user) (Auth.sessScope sess) method path) ->
                            pure (Left (jsonProblem status403 "session_scope" "this session may not use this route"))
                        | not (requestOriginAllowed cfg req) ->
                            pure (Left (jsonProblem status403 "origin" "origin is not allowed"))
                        | not (csrfOk req sess) ->
                            pure (Left (jsonProblem status403 "csrf" "missing or invalid CSRF token"))
                        | otherwise -> do
                            recordSessionActivity slot sess
                            pure (Right (user, slot, CookieSession sess))

invalidBearerToken :: Response
invalidBearerToken = jsonProblem status401 "unauthenticated" "invalid bearer token"

{- | A normal session follows the role matrix; a recovery session may only
finish its own setup; a pending two-factor session may not use the guard at all
(the passkey endpoints read its cookie directly).
-}
sessionScopeAllows :: UserRole -> Text -> Text -> [Text] -> Bool
sessionScopeAllows role scope method path = case scope of
    "normal" -> Authz.sessionRoleAllows (authzRole role) method path
    "recovery" -> Authz.recoverySessionAllows method path
    _ -> False

authzRole :: UserRole -> Authz.Role
authzRole role = case role of
    RoleAdmin -> Authz.RoleAdmin
    RoleMember -> Authz.RoleMember

bearerToken :: Request -> Maybe Text
bearerToken req =
    case lookup hAuthorization (requestHeaders req) of
        Nothing -> Nothing
        Just raw ->
            let value = TE.decodeUtf8 raw
             in if "Bearer " `T.isPrefixOf` value then Just (T.drop 7 value) else Nothing
