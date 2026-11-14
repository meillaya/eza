{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Authentication for one account database: the username/password account
row, sessions, login rate limiting, recovery codes, passkey management,
optional passkey two-factor, and the WebAuthn relying-party operations kept
for accounts that still sign in with a legacy passkey. Multi-user identity
lives in the control database ("Eza.Control"); this module is unaware of it
except for the per-user WebAuthn handle that registration callers pass in.

A password is the primary factor. Passkeys registered before schema v6 are
legacy credentials: they keep working only while no password exists. On a
password account a passkey is an optional second factor: when @require_passkey@
is on and at least one credential exists, a correct password opens a
short-lived pending session instead of a normal one, and a passkey assertion
finishes the sign-in. Recovery clears the password and the passkeys and opens
a recovery-scoped setup that sets a new password and rotates the ten recovery
codes.
-}
module Eza.Auth (
    AuthConfig (..),
    AuthError (..),
    toProblem,
    authError,
    Session (..),
    NewSession (..),
    LoginOutcome (..),
    RegistrationOutcome (..),
    Account (..),
    RateLimiter,
    newRateLimiter,
    checkRateLimit,
    resetRateLimit,
    rateLimiterKeyCount,
    countCredentials,
    setupClaimed,
    hasRecoverySession,
    setupAllowed,
    accountHasPassword,
    accountConfigured,
    legacyPasskeyLoginAllowed,
    twoFactorRequired,
    loadAccount,
    setAccountPassword,
    setAccountUsername,
    setRequirePasskey,
    setTwoFactorRequirement,
    completeSetup,
    verifyPasswordLogin,
    verifyCurrentPassword,
    registrationOptions,
    authenticationOptions,
    addPasskeyOptions,
    secondFactorOptions,
    verifyRegistration,
    verifyLogin,
    verifySecondFactor,
    verifyAddPasskey,
    completePendingLogin,
    createSession,
    validateSession,
    getSession,
    touchSession,
    sessionActivityDue,
    listSessions,
    deleteSession,
    deleteSessionHash,
    deleteOtherSessions,
    deleteAllSessions,
    scopeAllows,
    issueRecoveryCodes,
    redeemRecoveryCode,
    regenerateRecoveryCodes,
    listCredentials,
    recoveryCodesRemaining,
    renameCredential,
    deleteCredential,
    decodeCredentialId,
    cleanupExpired,
    sessionCookieName,
    csrfCookieName,
    pendingCookieName,
    pendingSessionTtlSeconds,
    pendingScope,
    hashToken,
) where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Monad (forM_, when)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64.URL as B64
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import qualified Data.Validation as V
import Database.SQLite.Simple
import Time.System (dateCurrent)

import qualified Crypto.WebAuthn as WA

import qualified Eza.Account as Account
import qualified Eza.Password as Password
import Eza.Problem (Problem (..))

data AuthConfig = AuthConfig
    { acOrigin :: Text
    , acRpId :: Text
    , acRpName :: Text
    , acSessionTtlSeconds :: Int
    , acPasswordParams :: Password.PasswordParams
    , acLoginMaxAttempts :: Int
    , acLoginLockoutSeconds :: Int
    }
    deriving (Show, Eq)

data AuthError = AuthError
    { aeStatus :: Int
    , aeCode :: Text
    , aeMessage :: Text
    , aeRetryAfter :: Maybe Int
    }
    deriving (Show, Eq)

{- | The one HTTP representation of an auth error. The retry delay is response
metadata, so callers add the @Retry-After@ header from 'aeRetryAfter'.
-}
toProblem :: AuthError -> Problem
toProblem err = Problem (aeStatus err) (aeCode err) (aeMessage err)

data Session = Session
    { sessId :: Text
    , sessCsrf :: Text
    , sessScope :: Text
    , sessExpiresAt :: Int
    , sessLastSeenAt :: Maybe Int
    }
    deriving (Show, Eq)

data NewSession = NewSession
    { nsToken :: Text
    , nsCsrf :: Text
    , nsScope :: Text
    , nsTtlSeconds :: Int
    }
    deriving (Show, Eq)

{- | What a correct password earns. When optional passkey two-factor is on,
the password alone opens only a pending session and the browser still owes a
passkey assertion before the normal session exists.
-}
data LoginOutcome
    = LoginComplete NewSession
    | LoginNeedsPasskey NewSession
    deriving (Show, Eq)

data RegistrationOutcome = RegistrationOutcome
    { roCodes :: Maybe [Text]
    , roSession :: Maybe NewSession
    }

{- | The single account row. Timestamps are POSIX seconds. The counters are
kept in the database so a restart does not unlock a rate-limited login.
-}
data Account = Account
    { acctUsername :: Text
    , acctPasswordHash :: Text
    , acctPasswordUpdatedAt :: Maybe Int
    , acctRequirePasskey :: Bool
    , acctFailedLoginCount :: Int
    , acctFailedLoginAt :: Maybe Int
    , acctLoginBlockedUntil :: Maybe Int
    , acctLastLoginAt :: Maybe Int
    }
    deriving (Show, Eq)

emptyAccount :: Account
emptyAccount = Account "" "" Nothing False 0 Nothing Nothing Nothing

{- | In-memory attempt counter for public endpoints without a database row
(recovery redemption). A restart clears it, which is fine for a one-shot
code exchange.

The key set is bounded: keys come from client addresses and client-supplied
request fields, so rotating names must not grow the map without limit. Once
the cap is reached a key is evicted before the current key is stored; the
current attempt is always counted, so a full map cannot be used to dodge the
limit for a fresh key.
-}
data RateLimiter = RateLimiter
    { rlAttempts :: MVar (Map.Map Text [Int])
    , rlMaxAttempts :: Int
    , rlWindowSeconds :: Int
    , rlMaxKeys :: Int
    }

{- | Hard cap on limiter buckets. A login burst keys one bucket per client host
and per username; a few thousand buckets is far above any real household and
still bounds the memory an attacker-chosen key stream can hold.
-}
defaultRateLimiterMaxKeys :: Int
defaultRateLimiterMaxKeys = 4096

sessionCookieName, csrfCookieName, pendingCookieName :: Text
sessionCookieName = "eza_session"
csrfCookieName = "eza_csrf"
pendingCookieName = "eza_pending"

{- | How long a browser may sit between the password and the passkey of a
two-factor sign-in. The pending session is useless on every other route.
-}
pendingSessionTtlSeconds :: Int
pendingSessionTtlSeconds = 300

-- | Session scope for a password that still owes a passkey assertion.
pendingScope :: Text
pendingScope = "pending_2fa"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

authError :: Int -> Text -> Text -> AuthError
authError status code message = AuthError status code message Nothing

authErrorRetry :: Int -> Text -> Text -> Int -> AuthError
authErrorRetry status code message retryAfter = AuthError status code message (Just (max 1 retryAfter))

epoch :: IO Int
epoch = floor <$> getPOSIXTime

randomToken :: Int -> IO Text
randomToken n = TE.decodeUtf8 . B64.encodeUnpadded <$> getRandomBytes n

hashToken :: Text -> Text
hashToken raw = T.pack (show (hash (TE.encodeUtf8 raw) :: Digest SHA256))

base64Id :: BS.ByteString -> Text
base64Id = TE.decodeUtf8 . B64.encodeUnpadded

decodeCredentialId :: Text -> Maybe BS.ByteString
decodeCredentialId t =
    case B64.decodeUnpadded (TE.encodeUtf8 t) of
        Left _ -> Nothing
        Right bs -> Just bs

-- ---------------------------------------------------------------------------
-- Setup / credential counts
-- ---------------------------------------------------------------------------

countCredentials :: Connection -> IO Int
countCredentials conn = do
    [Only n] <- query_ conn "SELECT COUNT(*) FROM passkey_credentials" :: IO [Only Int]
    pure n

setupClaimed :: Connection -> IO Bool
setupClaimed conn = do
    rows <- query_ conn "SELECT setup_claimed FROM app_state WHERE id = 1" :: IO [Only Int]
    pure (case rows of [Only n] -> n /= 0; _ -> False)

hasRecoverySession :: Connection -> IO Bool
hasRecoverySession conn = do
    now <- epoch
    rows <- query conn "SELECT 1 FROM sessions WHERE scope = 'recovery' AND expires_at > ?" (Only now) :: IO [Only Int]
    pure (not (null rows))

{- | The password setup form is available on a fresh database and during a
recovery setup. A database claimed by a passkey and a configured password
account both refuse it.
-}
setupAllowed :: Connection -> IO Bool
setupAllowed conn = do
    n <- countCredentials conn
    claimed <- setupClaimed conn
    rec <- hasRecoverySession conn
    pure (n == 0 && (not claimed || rec))

accountHasPassword :: Account -> Bool
accountHasPassword account = not (T.null (acctPasswordHash account))

-- | True when a usable username/password pair exists.
accountConfigured :: Connection -> IO Bool
accountConfigured conn = do
    account <- loadAccount conn
    pure (accountHasPassword account && not (T.null (acctUsername account)))

{- | Passkey sign-in survives only on a database that has passkeys and no
password. Once a password or a recovery session exists, password setup and
recovery own the ceremony.
-}
legacyPasskeyLoginAllowed :: Connection -> IO Bool
legacyPasskeyLoginAllowed conn = do
    n <- countCredentials conn
    configured <- accountConfigured conn
    rec <- hasRecoverySession conn
    pure (n > 0 && not configured && not rec)

{- | True when a correct password must be followed by a passkey assertion. The
flag alone is not enough: a credential has to exist, otherwise the account
would ask for a second factor it cannot satisfy. Deleting the last credential
while the flag is on is refused, so this is a safety net rather than the normal
case.
-}
twoFactorRequired :: Connection -> IO Bool
twoFactorRequired conn = do
    account <- loadAccount conn
    n <- countCredentials conn
    pure (acctRequirePasskey account && n > 0)

{- | Which routes a session scope may reach. A normal session reaches every
route the authenticated area allows. A recovery session may only re-enroll.
A pending two-factor session reaches no authenticated route at all: the two
passkey endpoints read its cookie directly, and the pending scope never opens
@/api/v1@.
-}
scopeAllows :: Text -> Text -> [Text] -> Bool
scopeAllows scope method path
    | scope == "normal" = True
    | scope == "recovery" = case (method, path) of
        ("POST", ["api", "setup", "password"]) -> True
        ("POST", ["api", "auth", "logout"]) -> True
        ("GET", ["api", "v1", "boot"]) -> True
        ("GET", ["api", "v1", "account"]) -> True
        _ -> False
    | otherwise = False

-- ---------------------------------------------------------------------------
-- Account
-- ---------------------------------------------------------------------------

loadAccount :: Connection -> IO Account
loadAccount conn = do
    rows <-
        query_
            conn
            "SELECT username,password_hash,password_updated_at,require_passkey,failed_login_count,failed_login_at,login_blocked_until,last_login_at FROM app_state WHERE id = 1" ::
            IO [(Text, Text, Maybe Int, Int, Int, Maybe Int, Maybe Int, Maybe Int)]
    pure $ case rows of
        [] -> emptyAccount
        ((username, passwordHash, updatedAt, requirePasskey, failedCount, failedAt, blockedUntil, lastLogin) : _) ->
            Account username passwordHash updatedAt (requirePasskey /= 0) failedCount failedAt blockedUntil lastLogin

{- | Store a new password without disturbing the optional two-factor flag.
Turning passkey two-factor on or off is a separate, password-confirmed step.
-}
setAccountPassword :: Connection -> Text -> Text -> IO ()
setAccountPassword conn username passwordHash = do
    now <- epoch
    withImmediateTransaction conn $
        executeNamed
            conn
            "UPDATE app_state SET username = :username, password_hash = :hash, password_updated_at = :now, setup_claimed = 1, failed_login_count = 0, failed_login_at = NULL, login_blocked_until = NULL WHERE id = 1"
            [ ":username" := username
            , ":hash" := passwordHash
            , ":now" := now
            ]

setAccountUsername :: Connection -> Text -> IO ()
setAccountUsername conn username =
    withImmediateTransaction conn $
        executeNamed
            conn
            "UPDATE app_state SET username = :username WHERE id = 1"
            [":username" := username]

setRequirePasskey :: Connection -> Bool -> IO ()
setRequirePasskey conn required =
    withImmediateTransaction conn $
        execute conn "UPDATE app_state SET require_passkey = ? WHERE id = 1" (Only (if required then 1 else 0 :: Int))

{- | Turn optional passkey two-factor on or off. Both directions need the
current password; turning it on also needs at least one registered credential
or the next sign-in could never finish. Returns the reloaded account.
-}
setTwoFactorRequirement :: Connection -> AuthConfig -> Bool -> Text -> IO (Either AuthError Account)
setTwoFactorRequirement conn ac required currentPassword = do
    account <- loadAccount conn
    if not (accountHasPassword account)
        then pure (Left (authError 409 "password_required" "set a password before turning on passkey two-factor"))
        else do
            authorized <- Password.verifyPassword (acPasswordParams ac) (acctPasswordHash account) currentPassword
            if not authorized
                then pure (Left (authError 403 "invalid_password" "the current password is incorrect"))
                else
                    if required
                        then do
                            n <- countCredentials conn
                            if n == 0
                                then pure (Left (authError 409 "passkey_required" "add a passkey before turning on passkey two-factor"))
                                else do
                                    setRequirePasskey conn True
                                    Right <$> loadAccount conn
                        else do
                            setRequirePasskey conn False
                            Right <$> loadAccount conn

{- | Finish a password setup (fresh claim or recovery): store the account,
mark the database claimed, clear any stale login counters, and replace the
recovery codes. Returns the ten new plaintext codes; only their hashes are
stored.
-}
completeSetup :: Connection -> Text -> Text -> IO [Text]
completeSetup conn username passwordHash = do
    now <- epoch
    codes <- mapM (const (randomToken 16)) [1 .. 10 :: Int]
    withImmediateTransaction conn $ do
        executeNamed
            conn
            "UPDATE app_state SET username = :username, password_hash = :hash, password_updated_at = :now, require_passkey = 0, setup_claimed = 1, failed_login_count = 0, failed_login_at = NULL, login_blocked_until = NULL, last_login_at = :now WHERE id = 1"
            [ ":username" := username
            , ":hash" := passwordHash
            , ":now" := now
            ]
        execute_ conn "DELETE FROM recovery_codes"
        forM_ codes $ \code ->
            execute
                conn
                "INSERT INTO recovery_codes (code_hash, used, created_at) VALUES (?, 0, ?)"
                (hashToken code, now)
    pure codes

updatePasswordHash :: Connection -> Text -> Int -> IO ()
updatePasswordHash conn passwordHash now =
    withImmediateTransaction conn $
        execute
            conn
            "UPDATE app_state SET password_hash = ?, password_updated_at = ? WHERE id = 1"
            (passwordHash, now)

clearLoginFailures :: Connection -> IO ()
clearLoginFailures conn =
    withImmediateTransaction conn $
        execute_ conn "UPDATE app_state SET failed_login_count = 0, failed_login_at = NULL, login_blocked_until = NULL WHERE id = 1"

{- | Check the current password for a password change. A legacy passkey-only
account has no password to check, so the session itself vouches for the first
password.
-}
verifyCurrentPassword :: Connection -> AuthConfig -> Text -> IO Bool
verifyCurrentPassword conn ac password = do
    account <- loadAccount conn
    if not (accountHasPassword account)
        then pure True
        else Password.verifyPassword (acPasswordParams ac) (acctPasswordHash account) password

{- | Authenticate a username and password. A wrong username, a wrong password,
and a missing account all return the same generic 401 (or 429 while locked),
and a missing account still pays for a dummy hash so timing does not enumerate
usernames.

A correct password earns a normal session unless optional passkey two-factor
is on and a credential exists; then it earns only a short-lived pending session
that the passkey assertion must exchange for the normal one.
-}
verifyPasswordLogin :: Connection -> AuthConfig -> Text -> Text -> IO (Either AuthError LoginOutcome)
verifyPasswordLogin conn ac suppliedUsername suppliedPassword = do
    now <- epoch
    account <- loadAccount conn
    let blockedUntil = acctLoginBlockedUntil account
        locked = maybe False (> now) blockedUntil
    if locked
        then pure (Left (authErrorRetry 429 "login_locked" "too many failed sign-in attempts; try again later" (maybe 1 (subtract now) blockedUntil)))
        else do
            -- An expired lock is cleared before the attempt is counted.
            when (isJust blockedUntil) (clearLoginFailures conn)
            let priorFailures = case blockedUntil of
                    Just _ -> 0
                    Nothing -> acctFailedLoginCount account
                knownUsername = acctUsername account
                usernameMatches =
                    not (T.null knownUsername)
                        && Password.constantTimeEq (TE.encodeUtf8 (T.strip suppliedUsername)) (TE.encodeUtf8 knownUsername)
                storedHash = acctPasswordHash account
            if T.null storedHash || not usernameMatches
                then do
                    Password.dummyVerify (acPasswordParams ac) suppliedPassword
                    Left <$> recordFailedLogin conn ac priorFailures now
                else do
                    ok <- Password.verifyPassword (acPasswordParams ac) storedHash suppliedPassword
                    if not ok
                        then Left <$> recordFailedLogin conn ac priorFailures now
                        else do
                            clearLoginFailures conn
                            withImmediateTransaction conn $
                                execute conn "UPDATE app_state SET last_login_at = ? WHERE id = 1" (Only now)
                            when (Password.needsRehash (acPasswordParams ac) storedHash) $ do
                                upgraded <- Password.hashPassword (acPasswordParams ac) suppliedPassword
                                updatePasswordHash conn upgraded now
                            -- The second factor is the passkey only while the
                            -- account asks for it and a credential exists.
                            let twoFactor = acctRequirePasskey account
                            n <- if twoFactor then countCredentials conn else pure 0
                            if twoFactor && n > 0
                                then Right . LoginNeedsPasskey <$> createSession conn pendingScope pendingSessionTtlSeconds
                                else Right . LoginComplete <$> createSession conn "normal" (acSessionTtlSeconds ac)

{- | Count one failed login and lock the account once the configured attempts
are used. Returns the error the login endpoint should send: a generic 401
until the threshold, then a locked 429 with the retry delay.
-}
recordFailedLogin :: Connection -> AuthConfig -> Int -> Int -> IO AuthError
recordFailedLogin conn ac priorFailures now = do
    let failures = priorFailures + 1
        locked = failures >= acLoginMaxAttempts ac
        blockedUntil = if locked then Just (now + acLoginLockoutSeconds ac) else Nothing
    withImmediateTransaction conn $
        executeNamed
            conn
            "UPDATE app_state SET failed_login_count = :count, failed_login_at = :now, login_blocked_until = :blocked WHERE id = 1"
            [ ":count" := failures
            , ":now" := now
            , ":blocked" := (blockedUntil :: Maybe Int)
            ]
    pure $
        if locked
            then authErrorRetry 429 "login_locked" "too many failed sign-in attempts; try again later" (acLoginLockoutSeconds ac)
            else authError 401 "invalid_credentials" "invalid username or password"

-- ---------------------------------------------------------------------------
-- Recovery-code rate limiting
-- ---------------------------------------------------------------------------

newRateLimiter :: Int -> Int -> IO RateLimiter
newRateLimiter maxAttempts windowSeconds =
    RateLimiter
        <$> newMVar Map.empty
        <*> pure (max 1 maxAttempts)
        <*> pure (max 1 windowSeconds)
        <*> pure defaultRateLimiterMaxKeys

{- | Allow one more attempt for a key, or report how many seconds to wait.
Expired attempts are pruned on every check, so a key with no recent attempt
costs nothing and an idle process empties the map. Keys are client addresses,
the constant global key, or one of those combined with a username; see
'Eza.Server' for the callers.
-}
checkRateLimit :: RateLimiter -> Text -> IO (Either Int ())
checkRateLimit limiter key = do
    now <- epoch
    modifyMVar (rlAttempts limiter) $ \attemptsMap -> do
        let window = rlWindowSeconds limiter
            pruned = Map.mapMaybe (recentAttempts now window) attemptsMap
            recent = Map.findWithDefault [] key pruned
        if length recent >= rlMaxAttempts limiter
            then do
                let oldest = minimum (now : recent)
                    retryAfter = max 1 (window - (now - oldest))
                pure (boundedKeys limiter key (Map.insert key recent pruned), Left retryAfter)
            else pure (boundedKeys limiter key (Map.insert key (now : recent) pruned), Right ())
  where
    recentAttempts now window attempts =
        case filter (> now - window) attempts of
            [] -> Nothing
            fresh -> Just fresh

-- | Read the number of live limiter buckets (used by the map-bound tests).
rateLimiterKeyCount :: RateLimiter -> IO Int
rateLimiterKeyCount limiter = Map.size <$> readMVar (rlAttempts limiter)

{- | Enforce the hard bucket cap. The current key is never the one evicted, so
a new key cannot escape being counted by being lexicographically first.
Eviction is by key order, not by recency: the cap is a memory backstop for an
attacker-chosen key stream, not the primary rate limit.
-}
boundedKeys :: RateLimiter -> Text -> Map.Map Text [Int] -> Map.Map Text [Int]
boundedKeys limiter currentKey attemptsMap
    | Map.size attemptsMap <= cap = attemptsMap
    | otherwise =
        Map.insert currentKey (Map.findWithDefault [] currentKey attemptsMap) $
            Map.deleteMin (Map.delete currentKey attemptsMap)
  where
    cap = max 1 (rlMaxKeys limiter)

resetRateLimit :: RateLimiter -> Text -> IO ()
resetRateLimit limiter key = modifyMVar_ (rlAttempts limiter) (pure . Map.delete key)

-- ---------------------------------------------------------------------------
-- Challenges
-- ---------------------------------------------------------------------------

storeChallenge :: Connection -> Text -> BS.ByteString -> IO ()
storeChallenge conn purpose challenge = do
    now <- epoch
    withImmediateTransaction conn $ do
        execute conn "DELETE FROM webauthn_challenges WHERE purpose = ?" (Only purpose)
        execute
            conn
            "INSERT INTO webauthn_challenges (challenge, purpose, created_at, expires_at) VALUES (?,?,?,?)"
            (challenge, purpose, now, now + 300)

consumeChallenge :: Connection -> Text -> IO (Maybe BS.ByteString)
consumeChallenge conn purpose = do
    now <- epoch
    rows <-
        query
            conn
            "SELECT challenge, expires_at FROM webauthn_challenges WHERE purpose = ? ORDER BY created_at DESC LIMIT 1"
            (Only purpose) ::
            IO [(BS.ByteString, Int)]
    case rows of
        [] -> pure Nothing
        ((challenge, expires) : _) -> do
            withImmediateTransaction conn $ execute conn "DELETE FROM webauthn_challenges WHERE challenge = ?" (Only challenge)
            pure (if expires > now then Just challenge else Nothing)

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

registrationOptionsFor :: AuthConfig -> BS.ByteString -> BS.ByteString -> [WA.CredentialDescriptor] -> WA.CredentialOptions 'WA.Registration
registrationOptionsFor ac handle challenge exclude =
    WA.CredentialOptionsRegistration
        { WA.corRp =
            WA.CredentialRpEntity
                { WA.creId = Just (WA.RpId (acRpId ac))
                , WA.creName = WA.RelyingPartyName (acRpName ac)
                }
        , WA.corUser =
            WA.CredentialUserEntity
                { WA.cueId = WA.UserHandle handle
                , WA.cueDisplayName = WA.UserAccountDisplayName "eza"
                , WA.cueName = WA.UserAccountName "eza"
                }
        , WA.corChallenge = WA.Challenge challenge
        , WA.corPubKeyCredParams =
            [ WA.CredentialParameters
                { WA.cpTyp = WA.CredentialTypePublicKey
                , WA.cpAlg = WA.CoseAlgorithmES256
                }
            , WA.CredentialParameters
                { WA.cpTyp = WA.CredentialTypePublicKey
                , WA.cpAlg = WA.CoseAlgorithmRS256
                }
            ]
        , WA.corTimeout = Just (WA.Timeout 60000)
        , WA.corExcludeCredentials = exclude
        , WA.corAuthenticatorSelection =
            Just
                WA.AuthenticatorSelectionCriteria
                    { WA.ascAuthenticatorAttachment = Nothing
                    , WA.ascResidentKey = WA.ResidentKeyRequirementRequired
                    , WA.ascUserVerification = WA.UserVerificationRequirementRequired
                    }
        , WA.corHints = []
        , WA.corAttestation = WA.AttestationConveyancePreferenceNone
        , WA.corExtensions = Nothing
        }

authenticationOptionsFor :: AuthConfig -> BS.ByteString -> WA.CredentialOptions 'WA.Authentication
authenticationOptionsFor ac challenge =
    WA.CredentialOptionsAuthentication
        { WA.coaRpId = Just (WA.RpId (acRpId ac))
        , WA.coaTimeout = Just (WA.Timeout 60000)
        , WA.coaChallenge = WA.Challenge challenge
        , WA.coaAllowCredentials = []
        , WA.coaUserVerification = WA.UserVerificationRequirementRequired
        , WA.coaHints = []
        , WA.coaExtensions = Nothing
        }

registrationOptions :: Connection -> AuthConfig -> BS.ByteString -> Bool -> IO (Either AuthError Value)
registrationOptions conn ac handle forSetup = do
    allowed <- if forSetup then setupAllowed conn else pure True
    if not allowed
        then pure (Left (authError 403 "setup_unavailable" "setup is not available"))
        else do
            challenge <- getRandomBytes 32
            storeChallenge conn "registration" challenge
            excludes <- if forSetup then pure [] else existingDescriptors conn
            let opts = registrationOptionsFor ac handle challenge excludes
            pure (Right (toJSON (WA.wjEncodeCredentialOptionsRegistration opts)))

existingDescriptors :: Connection -> IO [WA.CredentialDescriptor]
existingDescriptors conn = do
    rows <- query_ conn "SELECT credential_id FROM passkey_credentials" :: IO [Only BS.ByteString]
    pure
        [ WA.CredentialDescriptor
            { WA.cdTyp = WA.CredentialTypePublicKey
            , WA.cdId = WA.CredentialId cid
            , WA.cdTransports = Just []
            }
        | Only cid <- rows
        ]

credentialDescriptors :: Connection -> IO [WA.CredentialDescriptor]
credentialDescriptors conn = do
    rows <- query_ conn "SELECT credential_id FROM passkey_credentials ORDER BY created_at" :: IO [Only BS.ByteString]
    pure
        [ WA.CredentialDescriptor
            { WA.cdTyp = WA.CredentialTypePublicKey
            , WA.cdId = WA.CredentialId raw
            , WA.cdTransports = Nothing
            }
        | Only raw <- rows
        ]

{- | Assertion options for one ceremony. The challenge purpose separates the
legacy passkey sign-in from the two-factor check so one ceremony cannot consume
the other's challenge.
-}
authenticationOptionsWith :: Connection -> AuthConfig -> Text -> IO (Either AuthError Value)
authenticationOptionsWith conn ac purpose = do
    descriptors <- credentialDescriptors conn
    if null descriptors
        then pure (Left (authError 400 "no_credentials" "no passkeys are registered"))
        else do
            challenge <- getRandomBytes 32
            storeChallenge conn purpose challenge
            let opts = (authenticationOptionsFor ac challenge){WA.coaAllowCredentials = descriptors}
            pure (Right (toJSON (WA.wjEncodeCredentialOptionsAuthentication opts)))

authenticationOptions :: Connection -> AuthConfig -> IO (Either AuthError Value)
authenticationOptions conn ac = authenticationOptionsWith conn ac "authentication"

{- | The second-factor challenge. Only meaningful while the account asks for a
passkey at sign-in; the caller has already proved the password with a pending
session.
-}
secondFactorOptions :: Connection -> AuthConfig -> IO (Either AuthError Value)
secondFactorOptions conn ac = do
    required <- twoFactorRequired conn
    if required
        then authenticationOptionsWith conn ac "second_factor"
        else pure (Left (authError 403 "2fa_not_required" "this account does not ask for a passkey at sign-in"))

{- | A logged-in session can register a passkey at any time. On a password
account the credential is an optional second factor and an extra way in; on a
legacy passkey-only account it is the credential the sign-in uses.
-}
addPasskeyOptions :: Connection -> AuthConfig -> BS.ByteString -> IO (Either AuthError Value)
addPasskeyOptions conn ac handle = registrationOptions conn ac handle False

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------

rpHash :: AuthConfig -> WA.RpIdHash
rpHash ac = WA.RpIdHash (hash (TE.encodeUtf8 (acRpId ac)))

verifyRegistration :: Connection -> AuthConfig -> BS.ByteString -> Bool -> Value -> IO (Either AuthError RegistrationOutcome)
verifyRegistration conn ac handle forSetup body =
    case fromJSON body :: Result WA.WJCredentialRegistration of
        Error _ -> pure (Left (authError 400 "bad_request" "malformed registration response"))
        Success wjCredential ->
            case WA.wjDecodeCredentialRegistration wjCredential of
                Left _ -> pure (Left (authError 400 "bad_request" "malformed registration response"))
                Right cred -> do
                    mChallenge <- consumeChallenge conn "registration"
                    case mChallenge of
                        Nothing -> pure (Left (authError 400 "challenge" "challenge is unknown, expired, or already used"))
                        Just challenge -> do
                            now <- dateCurrent
                            let options = registrationOptionsFor ac handle challenge []
                                origin = WA.Origin (acOrigin ac)
                            case WA.verifyRegistrationResponse (origin :| []) (rpHash ac) mempty now options cred of
                                V.Failure _ -> pure (Left (authError 400 "verification" "registration response failed verification"))
                                V.Success result -> do
                                    storeCredential conn (WA.rrEntry result)
                                    if forSetup
                                        then do
                                            setSetupClaimed conn
                                            codes <- issueRecoveryCodes conn
                                            sess <- createSession conn "normal" (acSessionTtlSeconds ac)
                                            pure (Right (RegistrationOutcome (Just codes) (Just sess)))
                                        else pure (Right (RegistrationOutcome Nothing Nothing))

storeCredential :: Connection -> WA.CredentialEntry -> IO ()
storeCredential conn entry = do
    now <- epoch
    let cid = WA.unCredentialId (WA.ceCredentialId entry)
        pk = WA.unPublicKeyBytes (WA.cePublicKeyBytes entry)
        sign = fromIntegral (WA.unSignatureCounter (WA.ceSignCounter entry)) :: Int
        uh = WA.unUserHandle (WA.ceUserHandle entry)
    withImmediateTransaction conn $
        executeNamed
            conn
            "INSERT OR REPLACE INTO passkey_credentials (credential_id,user_handle,public_key,sign_count,transports,backup_eligible,backup_state,aaguid,nickname,created_at,last_used_at) VALUES (:cid,:uh,:pk,:sign,:transports,:be,:bs,:aaguid,:nick,:created,:used)"
            [ ":cid" := cid
            , ":uh" := uh
            , ":pk" := pk
            , ":sign" := sign
            , ":transports" := ("[]" :: Text)
            , ":be" := (0 :: Int)
            , ":bs" := (0 :: Int)
            , ":aaguid" := BS.empty
            , ":nick" := ("" :: Text)
            , ":created" := now
            , ":used" := now
            ]

setSetupClaimed :: Connection -> IO ()
setSetupClaimed conn =
    withImmediateTransaction conn $ execute_ conn "UPDATE app_state SET setup_claimed = 1 WHERE id = 1"

{- | Verify one WebAuthn assertion against the challenge of the given purpose.
Records the credential use on success. The caller decides what the assertion
earns: a legacy passkey sign-in creates a normal session directly, while a
two-factor assertion must complete the pending session.
-}
verifyAssertion :: Connection -> AuthConfig -> Text -> Value -> IO (Either AuthError ())
verifyAssertion conn ac purpose body =
    case fromJSON body :: Result WA.WJCredentialAuthentication of
        Error _ -> pure (Left (authError 400 "bad_request" "malformed authentication response"))
        Success wjCredential ->
            case WA.wjDecodeCredentialAuthentication wjCredential of
                Left _ -> pure (Left (authError 400 "bad_request" "malformed authentication response"))
                Right cred -> do
                    mChallenge <- consumeChallenge conn purpose
                    case mChallenge of
                        Nothing -> pure (Left (authError 400 "challenge" "challenge is unknown, expired, or already used"))
                        Just challenge -> do
                            mEntry <- loadEntry conn (WA.unCredentialId (WA.cIdentifier cred))
                            case mEntry of
                                Nothing -> pure (Left (authError 401 "unknown_credential" "unknown credential"))
                                Just entry -> do
                                    let options = authenticationOptionsFor ac challenge
                                        origin = WA.Origin (acOrigin ac)
                                    case WA.verifyAuthenticationResponse (origin :| []) (rpHash ac) (Just (WA.ceUserHandle entry)) entry options cred of
                                        V.Failure _ -> pure (Left (authError 401 "login_failed" "authentication failed"))
                                        V.Success (WA.AuthenticationResult counter) -> do
                                            recordCredentialUse conn (WA.unCredentialId (WA.ceCredentialId entry)) counter
                                            pure (Right ())

verifyLogin :: Connection -> AuthConfig -> Value -> IO (Either AuthError NewSession)
verifyLogin conn ac body = do
    result <- verifyAssertion conn ac "authentication" body
    case result of
        Left err -> pure (Left err)
        Right () -> Right <$> createSession conn "normal" (acSessionTtlSeconds ac)

{- | The passkey half of a two-factor sign-in. The pending session is proof that
the password was already correct.
-}
verifySecondFactor :: Connection -> AuthConfig -> Value -> IO (Either AuthError ())
verifySecondFactor conn ac body = do
    required <- twoFactorRequired conn
    if required
        then verifyAssertion conn ac "second_factor" body
        else pure (Left (authError 403 "2fa_not_required" "this account does not ask for a passkey at sign-in"))

verifyAddPasskey :: Connection -> AuthConfig -> BS.ByteString -> Value -> IO (Either AuthError ())
verifyAddPasskey conn ac handle body = do
    result <- verifyRegistration conn ac handle False body
    pure (() <$ result)

recordCredentialUse :: Connection -> BS.ByteString -> WA.SignatureCounterResult -> IO ()
recordCredentialUse conn cid counter = do
    now <- epoch
    case counter of
        WA.SignatureCounterUpdated (WA.SignatureCounter n) -> do
            withImmediateTransaction conn $ do
                execute conn "UPDATE passkey_credentials SET last_used_at = ?, sign_count = ? WHERE credential_id = ?" (now, fromIntegral n :: Int, cid)
        _ ->
            withImmediateTransaction conn $
                execute conn "UPDATE passkey_credentials SET last_used_at = ? WHERE credential_id = ?" (now, cid)

loadEntry :: Connection -> BS.ByteString -> IO (Maybe WA.CredentialEntry)
loadEntry conn cid = do
    rows <-
        query
            conn
            "SELECT credential_id,user_handle,public_key,sign_count,transports FROM passkey_credentials WHERE credential_id = ?"
            (Only cid) ::
            IO [(BS.ByteString, BS.ByteString, BS.ByteString, Int, Text)]
    case rows of
        [] -> pure Nothing
        ((cid', uh, pk, sign, _transportsText) : _) -> do
            pure
                ( Just
                    WA.CredentialEntry
                        { WA.ceCredentialId = WA.CredentialId cid'
                        , WA.ceUserHandle = WA.UserHandle uh
                        , WA.cePublicKeyBytes = WA.PublicKeyBytes pk
                        , WA.ceSignCounter = WA.SignatureCounter (fromIntegral sign)
                        , WA.ceTransports = []
                        }
                )

-- ---------------------------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------------------------

createSession :: Connection -> Text -> Int -> IO NewSession
createSession conn scope ttl = do
    token <- randomToken 32
    csrf <- randomToken 32
    now <- epoch
    let ttlSeconds = max 1 ttl
    withImmediateTransaction conn $
        execute
            conn
            "INSERT INTO sessions (id,csrf_hash,scope,created_at,expires_at,last_seen_at) VALUES (?,?,?,?,?,?)"
            (hashToken token, hashToken csrf, scope, now, now + ttlSeconds, now)
    pure (NewSession token csrf scope ttlSeconds)

{- | Exchange a pending two-factor session for the normal one after the passkey
assertion. The pending row is deleted in the same request, so a captured
pending cookie cannot be replayed once the passkey has been used.
-}
completePendingLogin :: Connection -> AuthConfig -> Session -> IO (Either AuthError NewSession)
completePendingLogin conn ac pending
    | sessScope pending /= pendingScope =
        pure (Left (authError 400 "pending_session_required" "the pending two-factor session is not valid"))
    | otherwise = do
        sess <- createSession conn "normal" (acSessionTtlSeconds ac)
        deleteSessionHash conn (sessId pending)
        pure (Right sess)

{- | Resolve a cookie token to a live session. This is a pure read: the
activity timestamp is recorded separately by 'touchSession', which the auth
guard calls on the connection's writer only when 'sessionActivityDue' says the
throttle window has passed. That keeps the common GET path free of writes.
-}
validateSession :: Connection -> Text -> IO (Maybe Session)
validateSession conn rawToken
    | T.null rawToken = pure Nothing
    | otherwise = do
        now <- epoch
        rows <-
            query
                conn
                "SELECT csrf_hash,scope,expires_at,last_seen_at FROM sessions WHERE id = ?"
                (Only (hashToken rawToken)) ::
                IO [(Text, Text, Int, Maybe Int)]
        pure $ case rows of
            ((csrfHash, scope, expires, lastSeen) : _)
                | expires > now ->
                    Just (Session (hashToken rawToken) csrfHash scope expires lastSeen)
            _ -> Nothing

{- | Kept for callers that only need the session row; identical to the
read-only 'validateSession'.
-}
getSession :: Connection -> Text -> IO (Maybe Session)
getSession = validateSession

-- | How often one session's activity timestamp is written back at most.
activityTouchSeconds :: Int
activityTouchSeconds = 60

{- | True when the stored activity timestamp is missing or older than the
throttle window, so the caller should record one activity write. This is a
read of the in-memory session value plus the clock, never a database access.
-}
sessionActivityDue :: Session -> IO Bool
sessionActivityDue sess = do
    now <- epoch
    pure (maybe True (\seen -> now - seen >= activityTouchSeconds) (sessLastSeenAt sess))

{- | Record session activity. Callers throttle this through
'sessionActivityDue' and run it on the user database writer.
-}
touchSession :: Connection -> Session -> IO ()
touchSession conn sess = do
    now <- epoch
    withImmediateTransaction conn $
        execute conn "UPDATE sessions SET last_seen_at = ? WHERE id = ?" (now, sessId sess)

deleteSession :: Connection -> Text -> IO ()
deleteSession conn rawToken =
    withImmediateTransaction conn $
        execute conn "DELETE FROM sessions WHERE id = ?" (Only (hashToken rawToken))

deleteSessionHash :: Connection -> Text -> IO ()
deleteSessionHash conn sessionHash =
    withImmediateTransaction conn $
        execute conn "DELETE FROM sessions WHERE id = ?" (Only sessionHash)

{- | Revoke every session except the one making the request. Returns how many
were revoked.
-}
deleteOtherSessions :: Connection -> Session -> IO Int
deleteOtherSessions conn current =
    withImmediateTransaction conn $ do
        execute conn "DELETE FROM sessions WHERE id != ?" (Only (sessId current))
        changes conn

-- | Revoke every session. The CLI @set-password --reset-sessions@ uses it.
deleteAllSessions :: Connection -> IO Int
deleteAllSessions conn =
    withImmediateTransaction conn $ do
        execute_ conn "DELETE FROM sessions"
        changes conn

-- ---------------------------------------------------------------------------
-- Recovery codes
-- ---------------------------------------------------------------------------

issueRecoveryCodes :: Connection -> IO [Text]
issueRecoveryCodes conn = do
    now <- epoch
    codes <- mapM (const (randomToken 16)) [1 .. 10 :: Int]
    withImmediateTransaction conn $
        forM_ codes $ \code ->
            execute
                conn
                "INSERT INTO recovery_codes (code_hash, used, created_at) VALUES (?, 0, ?)"
                (hashToken code, now)
    pure codes

regenerateRecoveryCodes :: Connection -> IO [Text]
regenerateRecoveryCodes conn = do
    withImmediateTransaction conn $ execute_ conn "DELETE FROM recovery_codes"
    issueRecoveryCodes conn

{- | Exchange one unused recovery code for a short-lived recovery session. The
redemption spends the code, removes every passkey and the password, revokes
every other session, and leaves the database in setup mode: the next setup
request sets a new password and rotates the remaining codes out.
-}
redeemRecoveryCode :: Connection -> Text -> IO (Either AuthError NewSession)
redeemRecoveryCode conn code = do
    rows <-
        query
            conn
            "SELECT 1 FROM recovery_codes WHERE code_hash = ? AND used = 0"
            (Only (hashToken code)) ::
            IO [Only Int]
    if null rows
        then pure (Left (authError 400 "bad_code" "unknown or already-used recovery code"))
        else do
            sess <- createSession conn "recovery" (10 * 60)
            now <- epoch
            withImmediateTransaction conn $ do
                execute
                    conn
                    "UPDATE recovery_codes SET used = 1, redeemed_at = ? WHERE code_hash = ?"
                    (now, hashToken code)
                execute_ conn "DELETE FROM passkey_credentials"
                execute conn "DELETE FROM sessions WHERE id != ?" (Only (hashToken (nsToken sess)))
                execute_
                    conn
                    "UPDATE app_state SET password_hash = '', password_updated_at = NULL, require_passkey = 0, failed_login_count = 0, failed_login_at = NULL, login_blocked_until = NULL WHERE id = 1"
            pure (Right sess)

-- ---------------------------------------------------------------------------
-- Account views
-- ---------------------------------------------------------------------------

{- | Every live normal or recovery session, oldest first, with the requesting
session marked. Pending two-factor sessions are invisible here: they are an
unfinished sign-in, not something the account page can list or revoke.
-}
listSessions :: Connection -> Maybe Session -> IO [Account.SessionInfo]
listSessions conn current = do
    now <- epoch
    rows <-
        query
            conn
            "SELECT id, created_at, last_seen_at, expires_at FROM sessions WHERE expires_at > ? AND scope != ? ORDER BY created_at ASC"
            (now, pendingScope) ::
            IO [(Text, Int, Maybe Int, Int)]
    pure
        [ Account.SessionInfo created lastSeen expires (Just sid == currentId)
        | (sid, created, lastSeen, expires) <- rows
        ]
  where
    currentId = sessId <$> current

listCredentials :: Connection -> IO [Account.Credential]
listCredentials conn = do
    rows <-
        query_
            conn
            "SELECT credential_id,nickname,created_at,last_used_at,backup_eligible FROM passkey_credentials ORDER BY created_at ASC" ::
            IO [(BS.ByteString, Text, Int, Maybe Int, Int)]
    pure
        [ Account.Credential (base64Id cid) nick created lastUsed (be /= 0)
        | (cid, nick, created, lastUsed, be) <- rows
        ]

recoveryCodesRemaining :: Connection -> IO Int
recoveryCodesRemaining conn = do
    [Only n] <- query_ conn "SELECT COUNT(*) FROM recovery_codes WHERE used = 0" :: IO [Only Int]
    pure n

renameCredential :: Connection -> BS.ByteString -> Text -> IO Bool
renameCredential conn cid nick = do
    n <- withImmediateTransaction conn $ do
        execute conn "UPDATE passkey_credentials SET nickname = ? WHERE credential_id = ?" (nick, cid)
        changes conn
    pure (n > 0)

{- | A legacy passkey-only account must keep one credential so it can still
sign in. A password account may drop every passkey, except while optional
passkey two-factor is on: then a credential is the second factor and removing
the last one would make the next sign-in impossible.
-}
deleteCredential :: Connection -> BS.ByteString -> IO (Either AuthError ())
deleteCredential conn cid = do
    n <- countCredentials conn
    account <- loadAccount conn
    let configured = accountHasPassword account && not (T.null (acctUsername account))
        lastOne = n <= 1
    if lastOne && not configured
        then pure (Left (authError 409 "last_credential" "cannot revoke the last passkey while no password is set; set a password or use a recovery code"))
        else
            if lastOne && acctRequirePasskey account
                then pure (Left (authError 409 "last_credential" "cannot revoke the last passkey while passkey two-factor is on; turn two-factor off first"))
                else do
                    changed <- withImmediateTransaction conn $ do
                        execute conn "DELETE FROM passkey_credentials WHERE credential_id = ?" (Only cid)
                        changes conn
                    pure (if changed > 0 then Right () else Left (authError 404 "not_found" "unknown passkey"))

-- ---------------------------------------------------------------------------
-- Housekeeping
-- ---------------------------------------------------------------------------

cleanupExpired :: Connection -> IO ()
cleanupExpired conn = do
    now <- epoch
    withImmediateTransaction conn $ do
        execute conn "DELETE FROM webauthn_challenges WHERE expires_at <= ?" (Only now)
        execute conn "DELETE FROM sessions WHERE expires_at <= ?" (Only now)
