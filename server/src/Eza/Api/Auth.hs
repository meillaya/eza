-- | Public authentication ceremonies and the auth request guards (origin, body size, rate limits).
module Eza.Api.Auth where

import Control.Concurrent.QSem (QSem, newQSem, signalQSem, waitQSem)
import Control.Exception (IOException, SomeException, bracket, bracket_, onException, throwIO, try)

import Data.Aeson

import Data.Aeson.Types (parseMaybe)

import qualified Data.ByteString.Char8 as BSC

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)

import Database.SQLite.Simple (Connection, Only (..), query)

import Network.HTTP.Types
import Network.Wai

import qualified Eza.Admin as Admin

import qualified Eza.Auth as Auth

import Eza.Config
import Eza.Control (ControlUser (..))
import qualified Eza.Control as Control

import Eza.Pages (addPasskeyPage, loginPage, passkeyLoginPage, recoverPage, recoverySetupPage, setupPage)
import Eza.Password (validatePassword, validateUsername)
import qualified Eza.Password as Password
import Eza.Routes (Route (..))

import Eza.Shell (pageAssets)

import Eza.User (UserCreateInput (..), UserCreateResult (..), UserRole (..))

import Eza.Api.Common
import Eza.Api.Context

import Eza.Api.Admin (adminErrorResponse)

loginHandler :: AppState -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
loginHandler state req respond = do
    msess <- requestSession state req
    if maybe False (\(_, _, sess) -> Auth.sessScope sess == "normal") msess
        then respond (redirectTo "/")
        else do
            accounts <- withControl state Control.countUsers
            if accounts == 0
                then respond (redirectTo "/setup")
                else do
                    legacy <- legacyPasskeyLogin state
                    let pages = pageAssets (asAssets state)
                    respond (htmlResponse (if legacy then passkeyLoginPage pages else loginPage pages))

{- | The legacy passkey page is only for a single-account database that still
has passkeys and no password. A multi-user install always shows the password
form.
-}
legacyPasskeyLogin :: AppState -> IO Bool
legacyPasskeyLogin state = do
    muser <- legacyUser state
    case muser of
        Nothing -> pure False
        Just user -> do
            result <- userSlotFor state user
            case result of
                Left _ -> pure False
                Right slot -> withDb slot (Auth.legacyPasskeyLoginAllowed)

{- | A fresh control database and a recovery session both open the password
setup; anything else goes back to sign in.
-}
setupHandler :: AppState -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
setupHandler state req respond = do
    msess <- requestSession state req
    let pages = pageAssets (asAssets state)
    case msess of
        Just (user, _, sess)
            | Auth.sessScope sess == "recovery" ->
                respond (htmlResponse (recoverySetupPage pages (cuUsername user)))
        Just _ -> respond (redirectTo "/")
        Nothing -> do
            accounts <- withControl state Control.countUsers
            if accounts == 0
                then respond (htmlResponse (setupPage pages))
                else respond (redirectTo "/login")

passkeySetupRetired :: Response
passkeySetupRetired =
    jsonError status410 "passkey_setup_retired" "passkey setup is retired; create a username and password first"

{- | Password sign-in for one named account. The username selects the control
row and therefore the database; an unknown or disabled name pays for a dummy
Argon2 hash and returns the same generic 401 as a wrong password. A per-host
and per-username limiter caps the attempts before the database is touched, and
the user database keeps its own lockout counter.
-}
passwordLoginHandler :: AppState -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
passwordLoginHandler state req respond =
    case requireOrigin cfg req of
        Left err -> respond (authErrResponse err)
        Right () -> do
            clientKey <- clientHostKey (asTrustedProxies state) req
            limited <- checkLoginLimiters state clientKey
            case limited of
                Left retryAfter -> respond (lockedResponse "login_locked" retryAfter)
                Right () -> do
                    body <- readAuthBody cfg req
                    case body of
                        Left AuthBodyTooLarge -> respond (payloadTooLargeResponse cfg)
                        Left (AuthBodyInvalid message) -> respond (jsonError status400 "bad_request" message)
                        Right value -> case parseMaybeObj value of
                            Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                            Just o -> case (parseMaybe (.: "username") o, parseMaybe (.: "password") o) of
                                (Just username, Just password) -> do
                                    let limiterKey = clientKey <> "|" <> T.toLower (T.strip username)
                                    attempt <- Auth.checkRateLimit (asLoginLimiter state) limiterKey
                                    case attempt of
                                        Left retryAfter -> respond (lockedResponse "login_locked" retryAfter)
                                        Right () -> attemptLogin username password limiterKey
                                _ -> respond (jsonError status400 "bad_request" "username and password are required")
  where
    cfg = asConfig state

    attemptLogin username password limiterKey = do
        mfound <- enabledUserByUsername state username
        case mfound of
            Nothing -> do
                -- An unknown name still pays Argon2, so the slot cap and the
                -- pre-Argon2 limiters above are what keep that work bounded.
                withArgon2Slot state (Password.dummyVerify (cfgArgon2 cfg) password)
                respond invalidCredentials
            Just user -> withSlot state user respond $ \slot -> do
                result <-
                    withArgon2Slot state $
                        withDb slot $ \conn ->
                            Auth.verifyPasswordLogin conn (authConfig cfg) username password
                case result of
                    Left err -> respond (authErrResponse err)
                    Right (Auth.LoginComplete session) -> do
                        Auth.resetRateLimit (asLoginLimiter state) limiterKey
                        withControl state $ \control -> Control.setUserLastLogin control (cuId user)
                        respond
                            ( withAuthCookies
                                cfg
                                (wireSessionToken user session)
                                (jsonResponse status200 (object ["requires_2fa" .= False, "redirect" .= ("/" :: Text)]))
                            )
                    Right (Auth.LoginNeedsPasskey pending) -> do
                        Auth.resetRateLimit (asLoginLimiter state) limiterKey
                        withControl state $ \control -> Control.setUserLastLogin control (cuId user)
                        respond
                            ( withPendingCookie
                                cfg
                                (wireSessionToken user pending)
                                (jsonResponse status200 (object ["requires_2fa" .= True]))
                            )

invalidCredentials :: Response
invalidCredentials = jsonError status401 "invalid_credentials" "invalid username or password"

lockedResponse :: Text -> Int -> Response
lockedResponse code retryAfter =
    mapResponseHeaders
        (<> [("Retry-After", BSC.pack (show retryAfter))])
        (jsonError status429 code "too many failed attempts; try again later")

{- | The client address the limiters key on. Without a trusted proxy that is
the socket peer, without the ephemeral source port. When the peer is one of the
configured @EZA_TRUSTED_PROXIES@, the right-most untrusted @X-Forwarded-For@
hop is the client; hops that are themselves trusted proxies are skipped. A
forwarded header from an untrusted peer is ignored, so a direct client cannot
pick its own bucket.

The result is an opaque stable key, not a validated address: after a trusted
proxy names the client it is used only as a map key.
-}
clientHostKey :: [TrustedProxy] -> Request -> IO Text
clientHostKey proxies req
    | not (isTrustedProxy proxies (remoteHost req)) = pure (sockAddrKey (remoteHost req))
    | otherwise = case lookup "X-Forwarded-For" (requestHeaders req) of
        Nothing -> pure (sockAddrKey (remoteHost req))
        Just raw -> pick (reverse (forwardedHops raw))
  where
    forwardedHops raw =
        filter (not . T.null) (map T.strip (T.splitOn "," (TE.decodeUtf8With lenientDecode raw)))

    pick [] = pure (sockAddrKey (remoteHost req))
    pick (hop : rest) = do
        parsed <- parseNumericAddress hop
        case parsed of
            Just address
                | isTrustedProxy proxies address -> pick rest
                | otherwise -> pure (sockAddrKey address)
            -- An unparseable hop is treated as the client rather than skipped,
            -- so a malformed header cannot be used to hide behind a trusted
            -- address further left.
            Nothing -> pure hop

{- | Count one attempt against the process-wide and per-client login budgets
before any Argon2 work. Neither key carries the username, so rotating the
username cannot create a fresh budget.
-}
checkLoginLimiters :: AppState -> Text -> IO (Either Int ())
checkLoginLimiters state clientKey = do
    global <- Auth.checkRateLimit (asLoginGlobalLimiter state) "global"
    case global of
        Left retryAfter -> pure (Left retryAfter)
        Right () -> Auth.checkRateLimit (asLoginHostLimiter state) clientKey

-- | Run one Argon2 computation under the shared concurrency slots.
withArgon2Slot :: AppState -> IO a -> IO a
withArgon2Slot state = bracket_ (waitQSem (asArgon2Sem state)) (signalQSem (asArgon2Sem state))

{- | The passkey half of a two-factor sign-in. Both handlers need the pending
cookie that the password step set; without it there is no sign-in to finish.
The cookie prefix selects the same database the password step used.
-}
passkeySecondFactorOptionsHandler :: AppState -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
passkeySecondFactorOptionsHandler state req respond =
    case requireOrigin cfg req of
        Left err -> respond (authErrResponse err)
        Right () -> do
            mpending <- pendingSession state req
            case mpending of
                Nothing -> respond pendingRequired
                Just (_, slot, _) -> withDb slot $ \conn -> do
                    result <- Auth.secondFactorOptions conn (authConfig cfg)
                    either (respond . authErrResponse) (respond . jsonResponse status200) result
  where
    cfg = asConfig state

passkeySecondFactorVerifyHandler :: AppState -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
passkeySecondFactorVerifyHandler state req respond =
    case requireOrigin cfg req of
        Left err -> respond (authErrResponse err)
        Right () -> do
            body <- readAuthBody cfg req
            case body of
                Left AuthBodyTooLarge -> respond (payloadTooLargeResponse cfg)
                Left (AuthBodyInvalid message) -> respond (jsonError status400 "bad_request" message)
                Right value -> do
                    mpending <- pendingSession state req
                    case mpending of
                        Nothing -> respond pendingRequired
                        Just (user, slot, pending) -> withDb slot $ \conn -> do
                            result <- Auth.verifySecondFactor conn (authConfig cfg) value
                            case result of
                                Left err -> respond (authErrResponse err)
                                Right () -> do
                                    completed <- Auth.completePendingLogin conn (authConfig cfg) pending
                                    case completed of
                                        Left err -> respond (authErrResponse err)
                                        Right session ->
                                            respond
                                                ( clearPendingCookie
                                                    cfg
                                                    ( withAuthCookies
                                                        cfg
                                                        (wireSessionToken user session)
                                                        (jsonResponse status200 (object ["requires_2fa" .= False, "redirect" .= ("/" :: Text)]))
                                                    )
                                                )
  where
    cfg = asConfig state

pendingRequired :: Response
pendingRequired = jsonError status401 "pending_required" "the password sign-in expired; sign in again"

{- | Legacy passkey sign-in: only while exactly one enabled account exists and
its database has passkeys but no password, and never during a recovery setup.
-}
legacyCeremonySlot :: AppState -> IO (Maybe (Control.ControlUser, UserSlot))
legacyCeremonySlot state = do
    muser <- legacyUser state
    case muser of
        Nothing -> pure Nothing
        Just user -> do
            result <- userSlotFor state user
            pure $ case result of
                Left _ -> Nothing
                Right slot -> Just (user, slot)

legacyPasskeyOptionsHandler :: AppState -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
legacyPasskeyOptionsHandler state req respond =
    case requireOrigin cfg req of
        Left err -> respond (authErrResponse err)
        Right () -> do
            target <- legacyCeremonySlot state
            case target of
                Nothing -> respond passkeysRetired
                Just (_, slot) -> withDb slot $ \conn -> do
                    allowed <- Auth.legacyPasskeyLoginAllowed conn
                    if not allowed
                        then respond passkeysRetired
                        else do
                            result <- Auth.authenticationOptions conn (authConfig cfg)
                            either (respond . authErrResponse) (respond . jsonResponse status200) result
  where
    cfg = asConfig state

legacyPasskeyVerifyHandler :: AppState -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
legacyPasskeyVerifyHandler state req respond =
    case requireOrigin cfg req of
        Left err -> respond (authErrResponse err)
        Right () -> do
            target <- legacyCeremonySlot state
            case target of
                Nothing -> respond passkeysRetired
                Just (user, slot) -> do
                    allowed <- withDb slot (Auth.legacyPasskeyLoginAllowed)
                    if not allowed
                        then respond passkeysRetired
                        else do
                            body <- readAuthBody cfg req
                            case body of
                                Left AuthBodyTooLarge -> respond (payloadTooLargeResponse cfg)
                                Left (AuthBodyInvalid message) -> respond (jsonError status400 "bad_request" message)
                                Right value -> do
                                    result <- withDb slot $ \conn -> Auth.verifyLogin conn (authConfig cfg) value
                                    case result of
                                        Left err -> respond (authErrResponse err)
                                        Right session ->
                                            respond
                                                ( withAuthCookies
                                                    cfg
                                                    (wireSessionToken user session)
                                                    (jsonResponse status200 (object ["redirect" .= ("/" :: Text)]))
                                                )
  where
    cfg = asConfig state

passkeysRetired :: Response
passkeysRetired =
    jsonError status403 "passkeys_retired" "password sign-in is active; passkeys are legacy credentials"

{- | Finish a password setup. With a recovery session the session's account is
the target; on an empty control database this claims a new user and creates
the next free @users/N/eza.db@ (never the legacy @EZA_DB@ file, which is only
adopted by the startup bootstrap when it already holds an account).
-}
passwordSetupHandler :: AppState -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
passwordSetupHandler state req respond =
    case requireOrigin cfg req of
        Left err -> respond (authErrResponse err)
        Right () -> do
            clientKey <- clientHostKey (asTrustedProxies state) req
            limited <- checkLoginLimiters state clientKey
            case limited of
                Left retryAfter -> respond (lockedResponse "login_locked" retryAfter)
                Right () -> do
                    msess <- requestSession state req
                    case msess of
                        -- A recovery session is a live cookie session, so this route
                        -- needs the same CSRF check as every other unsafe session
                        -- request. The Origin check above only covers the fresh
                        -- install, which has no session at all.
                        Just (_, _, sess)
                            | Auth.sessScope sess == "recovery"
                            , not (csrfOk req sess) ->
                                respond (jsonError status403 "csrf" "missing or invalid CSRF token")
                        _ -> do
                            body <- readAuthBody cfg req
                            case body of
                                Left AuthBodyTooLarge -> respond (payloadTooLargeResponse cfg)
                                Left (AuthBodyInvalid message) -> respond (jsonError status400 "bad_request" message)
                                Right value -> case parseSetupBody value of
                                    Left message -> respond (jsonError status400 "bad_request" message)
                                    Right (rawUsername, password) ->
                                        case msess of
                                            Just (user, slot, sess)
                                                | Auth.sessScope sess == "recovery" ->
                                                    finishRecoverySetup user slot rawUsername password
                                            Just _ ->
                                                respond (jsonError status403 "recovery_session_required" "a recovery session is required to finish recovery setup")
                                            Nothing -> startFreshSetup rawUsername password
  where
    cfg = asConfig state

    finishRecoverySetup user slot rawUsername password =
        case validateSetupCredentials rawUsername password of
            Left response -> respond response
            Right username -> do
                renamed <- withControl state $ \control -> Control.setUsername control (cuId user) username
                case renamed of
                    Left Control.ControlDuplicateUsername ->
                        respond (jsonError status409 "username_taken" "that username is already in use")
                    Left err -> respond (jsonError status500 "control" (T.pack (show err)))
                    Right () -> do
                        passwordHash <- Password.hashPassword (cfgArgon2 cfg) password
                        codes <- withDb slot $ \conn -> Auth.completeSetup conn username passwordHash
                        session <- withDb slot $ \conn -> Auth.createSession conn "normal" (cfgSessionTtlSeconds cfg)
                        withControl state $ \control -> Control.setUserLastLogin control (cuId user)
                        respond
                            ( withAuthCookies
                                cfg
                                (wireSessionToken user session)
                                (jsonResponse status200 (object ["codes" .= codes, "redirect" .= ("/" :: Text)]))
                            )

    startFreshSetup rawUsername password = do
        accounts <- withControl state Control.countUsers
        if accounts /= 0
            then respond (jsonError status403 "setup_unavailable" "setup is not available")
            else case validateSetupCredentials rawUsername password of
                Left response -> respond response
                Right username -> do
                    -- The shared account path allocates the control row first,
                    -- then creates and migrates the user database.
                    created <-
                        withControl state $ \control ->
                            Admin.createUserAccount cfg control username RoleAdmin password
                    case created of
                        Left err -> respond (adminErrorResponse err)
                        Right (user, codes) -> withSlot state user respond $ \slot -> do
                            session <- withDb slot $ \conn -> Auth.createSession conn "normal" (cfgSessionTtlSeconds cfg)
                            withControl state $ \control -> Control.setUserLastLogin control (cuId user)
                            respond
                                ( withAuthCookies
                                    cfg
                                    (wireSessionToken user session)
                                    (jsonResponse status200 (object ["codes" .= codes, "redirect" .= ("/" :: Text)]))
                                )

    validateSetupCredentials rawUsername password =
        case validateUsername rawUsername of
            Left message -> Left (jsonError status400 "invalid_username" message)
            Right username -> case validatePassword password of
                Left message -> Left (jsonError status400 "weak_password" message)
                Right () -> Right username

parseSetupBody :: Value -> Either Text (Text, Text)
parseSetupBody value = case parseMaybeObj value of
    Nothing -> Left "invalid body"
    Just o -> case (parseMaybe (.: "username") o, parseMaybe (.: "password") o, parseMaybe (.: "confirm") o) of
        (Just username, Just password, Just confirm)
            | password /= confirm -> Left "the passwords do not match"
            | otherwise -> Right (username, password)
        _ -> Left "username, password, and confirm are required"

{- | Redeem one recovery code for a named account. The username resolves the
control row first, so a multi-user install can no longer redeem a code blindly
against the one database. Unknown names and used codes share the same 400.
-}
recoveryRedeemHandler :: AppState -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
recoveryRedeemHandler state req respond =
    case requireOrigin cfg req of
        Left err -> respond (authErrResponse err)
        Right () -> do
            clientKey <- clientHostKey (asTrustedProxies state) req
            body <- readAuthBody cfg req
            case body of
                Left AuthBodyTooLarge -> respond (payloadTooLargeResponse cfg)
                Left (AuthBodyInvalid message) -> respond (jsonError status400 "bad_request" message)
                Right value -> do
                    let limiterKey = clientKey <> "|recovery"
                    attempt <- Auth.checkRateLimit (asRecoveryLimiter state) limiterKey
                    case attempt of
                        Left retryAfter -> respond (lockedResponse "recovery_locked" retryAfter)
                        Right () -> case parseMaybeObj value of
                            Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                            Just o -> case (parseMaybe (.: "username") o, parseMaybe (.: "code") o) of
                                (Just username, Just code) -> redeem username code limiterKey
                                _ -> respond (jsonError status400 "bad_request" "username and code are required")
  where
    cfg = asConfig state

    redeem username code limiterKey = do
        mfound <- enabledUserByUsername state username
        case mfound of
            Nothing -> respond badCode
            Just user -> withSlot state user respond $ \slot -> do
                result <- withDb slot $ \conn -> Auth.redeemRecoveryCode conn code
                case result of
                    Left err -> respond (authErrResponse err)
                    Right session -> do
                        Auth.resetRateLimit (asRecoveryLimiter state) limiterKey
                        withControl state $ \control -> Control.setUserLastLogin control (cuId user)
                        respond
                            ( withAuthCookies
                                cfg
                                (wireSessionToken user session)
                                (jsonResponse status200 (object ["redirect" .= ("/setup" :: Text)]))
                            )

    badCode = jsonError status400 "bad_code" "unknown or already-used recovery code"

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

-- | Dispatch the handlers this family owns from their "Eza.Routes" constructors.
dispatch :: RequestContext -> Connection -> Route -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
dispatch rctx conn route _req respond = case route of
    RouteLogout -> case ctx of
        CookieSession sess -> do
            Auth.deleteSessionHash conn (Auth.sessId sess)
            respond (clearAuthCookies cfg (emptyResponse status204))
        BearerToken _ -> respond (jsonError status403 "session_required" "a bearer token cannot end a browser session")
    _ -> respond (jsonError status500 "internal_error" "route has no handler")
  where
    cfg = rcConfig rctx
    ctx = rcAuth rctx

-- | The "Eza.Routes" constructors this family handles.
owns :: Route -> Bool
owns route = case route of
    RouteLogout -> True
    _ -> False
