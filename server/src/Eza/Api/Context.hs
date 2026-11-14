-- | The server runtime: app state, per-user slots, token/session resolution, and the worker supervisor.
module Eza.Api.Context where

import Control.Concurrent (threadDelay)

import Control.Concurrent.MVar
import Control.Concurrent.QSem (QSem, newQSem)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (forM, forM_, unless, when)

import qualified Data.ByteString as BS

import Data.Char (isDigit)

import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe, isNothing)
import qualified Data.Set as Set

import Data.Text (Text)
import qualified Data.Text as T

import Data.Time.Clock.POSIX (getPOSIXTime)

import Database.SQLite.Simple (Connection, Only (..))
import qualified Database.SQLite.Simple as Sqlite
import Network.HTTP.Client (Manager)
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types
import Network.Wai

import System.Directory (doesFileExist)

import System.IO (hPutStrLn, stderr)

import qualified Eza.Admin as Admin

import Eza.Assets (Assets, loadAssetsForStartup)
import qualified Eza.Auth as Auth

import Eza.Config
import Eza.Control (ControlUser (..))
import qualified Eza.Control as Control

import Eza.Library (LibraryWorkerConfig (..))
import qualified Eza.Library as Library

import qualified Eza.TokenPrefix as TokenPrefix
import Eza.Tokens (Token (..), tokenActivityDue, touchToken)

import Eza.Api.Common

{- | One server process, one control database, and a lazily opened slot per
user library database.

The control connection carries identity only: account lookup, login
bookkeeping, and the per-user WebAuthn handle. Library rows never travel
through it. Each 'UserSlot' owns its own writer, a small read-only pool, and
the graph layout cache for that database, so one user's import or merge cannot
stall another user's browsing.
-}
data AppState = AppState
    { asConfig :: Config
    , asAssets :: Assets
    , asControl :: MVar Connection
    , asUsers :: MVar (Map.Map Int UserSlot)
    , asManager :: Manager
    , asRecoveryLimiter :: Auth.RateLimiter
    , asLoginLimiter :: Auth.RateLimiter
    , asLoginHostLimiter :: Auth.RateLimiter
    , asLoginGlobalLimiter :: Auth.RateLimiter
    , asArgon2Sem :: QSem
    , asTrustedProxies :: [TrustedProxy]
    , asEnrichSem :: QSem
    , asLastSessionCleanup :: MVar Int
    , asWorkerLimitWarned :: MVar [Int]
    }

{- | One account's runtime slot: the control row, the snapshot directory, and
the opened "Eza.Library" that owns the database connections, the graph layout
cache, and the background workers. Slots are created on first use and closed at
shutdown; the map in 'asUsers' is the only place a request gets a database
path, and every path comes from the control row, never from a request.
-}
data UserSlot = UserSlot
    { usUser :: Control.ControlUser
    , usDbPath :: FilePath
    , usSnapshotDir :: FilePath
    , usLibrary :: Library.Library
    }

{- | What one authenticated request resolved to. Handlers keep their plain
'Connection' signature; the connection they receive is this user's database.
-}
data RequestContext = RequestContext
    { rcConfig :: Config
    , rcState :: AppState
    , rcUser :: Control.ControlUser
    , rcSlot :: UserSlot
    , rcAuth :: AuthContext
    }

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

-- ---------------------------------------------------------------------------
-- Application state
-- ---------------------------------------------------------------------------

{- | Attempts one client host may make against the public password paths per
lockout window. This caps the Argon2 work a single source can cause; a
household behind one NAT is far below it even when every member signs in.
-}
loginHostMaxAttempts :: Int
loginHostMaxAttempts = 30

{- | Attempts all clients together may make per minute, so rotating source
addresses (or spoofed forwarding headers from a trusted proxy) cannot multiply
the per-host budget into a CPU exhaustion. Sized for a small household: a
whole family signing in at once stays well under it.
-}
loginGlobalMaxAttempts :: Int
loginGlobalMaxAttempts = 120

loginGlobalWindowSeconds :: Int
loginGlobalWindowSeconds = 60

{- | Concurrent Argon2 verifications. One hash holds the configured memory for
the duration, so unbounded concurrency is a memory exhaustion even when the
request rate is capped. Two in flight keeps the peak at a couple of hashes.
-}
argon2Slots :: Int
argon2Slots = 2

{- | Open the control database, register an existing single-user installation
when the control registry is empty, and start with no user slots open. The
control database is cheap and the user databases open lazily; a request only
ever opens the database its authenticated account names.
-}
newAppState :: Config -> IO AppState
newAppState cfg = do
    -- Fail before opening databases: a server that cannot serve its client is
    -- a startup error with the bundler/release fix in the message, never a
    -- half-running process.
    assets <- loadAssetsForStartup (cfgStaticDir cfg)
    control <- Control.openControlDb (cfgControlDbPath cfg)
    warnLegacyInstallation cfg control
    manager <- newTlsManager
    proxies <- loadTrustedProxies
    recoveryLimiter <- Auth.newRateLimiter 5 900
    {- The per-username login limiter is checked before the current attempt is
    recorded, while an account's database lockout is decided after the attempt
    that reaches 'EZA_LOGIN_MAX_ATTEMPTS'. Sizing the limiter one attempt short
    makes a known username and an unknown one answer 429 on the same attempt,
    so the rate limiter cannot be used to test whether an account exists. With
    'EZA_LOGIN_MAX_ATTEMPTS=1' both paths answer 429 on the first attempt.
    -}
    loginLimiter <-
        Auth.newRateLimiter
            (max 1 (cfgLoginMaxAttempts cfg - 1))
            (max 1 (cfgLoginLockoutSeconds cfg))
    -- Host and global buckets are deliberately not keyed by a request field
    -- the attacker can rotate: one caps a single source address and one caps
    -- the whole process, so rotating usernames cannot multiply the Argon2 work.
    loginHostLimiter <- Auth.newRateLimiter loginHostMaxAttempts (max 1 (cfgLoginLockoutSeconds cfg))
    loginGlobalLimiter <- Auth.newRateLimiter loginGlobalMaxAttempts loginGlobalWindowSeconds
    argon2Sem <- newQSem argon2Slots
    controlVar <- newMVar control
    usersVar <- newMVar Map.empty
    enrichSem <- newQSem (max 1 (cfgEnrichWorkers cfg))
    lastCleanupVar <- newMVar 0
    limitWarnedVar <- newMVar []
    pure
        AppState
            { asConfig = cfg
            , asAssets = assets
            , asControl = controlVar
            , asUsers = usersVar
            , asManager = manager
            , asRecoveryLimiter = recoveryLimiter
            , asLoginLimiter = loginLimiter
            , asLoginHostLimiter = loginHostLimiter
            , asLoginGlobalLimiter = loginGlobalLimiter
            , asArgon2Sem = argon2Sem
            , asTrustedProxies = proxies
            , asEnrichSem = enrichSem
            , asLastSessionCleanup = lastCleanupVar
            , asWorkerLimitWarned = limitWarnedVar
            }

{- | Startup diagnosis for pre-0.4 installations. 0.4 opens only the control
database and @users/<id>/eza.db@; a flat @EZA_DB@ file is never adopted or
migrated automatically. When no account is registered yet and the legacy file
still exists, print the upgrade hint (this is diagnosis only, not a fallback).
-}
warnLegacyInstallation :: Config -> Connection -> IO ()
warnLegacyInstallation cfg control = do
    accounts <- Control.countUsers control
    when (accounts == 0) $ do
        exists <- doesFileExist (cfgDbPath cfg)
        when exists $ do
            pythonLayout <- looksLikePythonDatabase (cfgDbPath cfg)
            hPutStrLn
                stderr
                ( if pythonLayout
                    then
                        "eza: the old Python eza database at "
                            <> cfgDbPath cfg
                            <> " is not opened by 0.4; back it up and import its HTML export instead"
                    else
                        "eza: the pre-0.4 single-user database at "
                            <> cfgDbPath cfg
                            <> " is not opened or adopted by 0.4; back it up and import its HTML export, or finish /setup to create a fresh account (see docs/upgrade.md)"
                )

{- | The Python application shipped no @app_state@ table and no @added_at@
column. A malformed or non-SQLite file is treated as unknown, not as Python.
-}
looksLikePythonDatabase :: FilePath -> IO Bool
looksLikePythonDatabase path = do
    result <-
        try
            ( bracket (Sqlite.open path) Sqlite.close $ \conn -> do
                appState <- Sqlite.query_ conn "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'app_state'" :: IO [Only Int]
                addedAt <- Sqlite.query_ conn "SELECT 1 FROM pragma_table_info('bookmarks') WHERE name = 'added_at'" :: IO [Only Int]
                pure (null appState && null addedAt)
            ) ::
            IO (Either SomeException Bool)
    pure (either (const False) id result)

{- | Close every open user database and the control database. Warp has already
stopped routing requests when this runs.
-}
closeAppState :: AppState -> IO ()
closeAppState state = do
    -- Worker loops hold their own database connections, so stop them before
    -- the slots and the control database go away.
    stopAllUserWorkers state
    slots <- modifyMVar (asUsers state) (\current -> pure (Map.empty, Map.elems current))
    mapM_ closeUserSlot slots
    withMVar (asControl state) Sqlite.close

closeUserSlot :: UserSlot -> IO ()
closeUserSlot slot = Library.closeLibrary (usLibrary slot)

{- | The slot for one account, opening the library the first time this process
needs it. The registry cap is enforced here so a request cannot make the
server open unbounded database files.
-}
userSlotFor :: AppState -> Control.ControlUser -> IO (Either Text UserSlot)
userSlotFor state user = do
    opened <- modifyMVar (asUsers state) $ \slots ->
        case Map.lookup (cuId user) slots of
            Just slot -> pure (slots, Right slot)
            Nothing
                | Map.size slots >= cfgMaxUsers (asConfig state) ->
                    pure (slots, Left "the server has reached its configured user limit")
                | otherwise -> do
                    slot <- openUserSlot (asConfig state) user
                    pure (Map.insert (cuId user) slot slots, Right slot)
    pure opened

-- | How many user databases this process currently has open (tests use it).
userSlotCount :: AppState -> IO Int
userSlotCount state = Map.size <$> readMVar (asUsers state)

openUserSlot :: Config -> Control.ControlUser -> IO UserSlot
openUserSlot cfg user = do
    library <- Library.openLibrary (cuDbPath user)
    pure
        UserSlot
            { usUser = user
            , usDbPath = cuDbPath user
            , usSnapshotDir = Admin.userSnapshotDir cfg (cuId user)
            , usLibrary = library
            }

withDb :: UserSlot -> (Connection -> IO a) -> IO a
withDb slot = Library.withLibraryWriter (usLibrary slot)

withReadDb :: UserSlot -> (Connection -> IO a) -> IO a
withReadDb slot = Library.withLibraryReader (usLibrary slot)

withControl :: AppState -> (Connection -> IO a) -> IO a
withControl state = withMVar (asControl state)

withSlot ::
    AppState ->
    Control.ControlUser ->
    (Response -> IO ResponseReceived) ->
    (UserSlot -> IO ResponseReceived) ->
    IO ResponseReceived
withSlot state user respond action = do
    result <- userSlotFor state user
    case result of
        Left message -> respond (jsonProblem status503 "user_limit" message)
        Right slot -> action slot

enabledUserById :: AppState -> Int -> IO (Maybe Control.ControlUser)
enabledUserById state userId = withControl state $ \control -> do
    found <- Control.lookupUserById control userId
    pure (enabledOnly found)

enabledUserByUsername :: AppState -> Text -> IO (Maybe Control.ControlUser)
enabledUserByUsername state username = withControl state $ \control -> do
    found <- Control.lookupUserByUsername control (T.strip username)
    pure (enabledOnly found)

enabledOnly :: Maybe Control.ControlUser -> Maybe Control.ControlUser
enabledOnly found = case found of
    Just user | isNothing (cuDisabledAt user) -> Just user
    _ -> Nothing

-- ---------------------------------------------------------------------------
-- Token prefixes
-- ---------------------------------------------------------------------------

{- | The wire format carries the owning account id, so the server can pick the
user database before it hashes and validates the token. A rewritten prefix
lands on the wrong database and fails the hash check. Unprefixed values use
the explicit single-account fallback.

Wire forms: @u<id>_<raw>@ for sessions, pending sessions, and share links,
and @eza_pat_u<id>_<raw>@ for API bearer tokens. Unprefixed values are not
tokens in 0.4.
-}
stripSessionPrefix :: Text -> Maybe (Int, Text)
stripSessionPrefix = TokenPrefix.splitUserPrefix

{- | Split @eza_pat_u<id>_<random>@ into the account id and the bare
@eza_pat_<random>@ value whose hash the user database stores.
-}
stripApiTokenPrefix :: Text -> Maybe (Int, Text)
stripApiTokenPrefix wire = do
    userId <- TokenPrefix.parseApiTokenUserId wire
    rest <- T.stripPrefix TokenPrefix.apiTokenPrefix wire
    let (digits, afterDigits) = T.span isDigit rest
    body <- T.stripPrefix "_" afterDigits
    if T.null digits || T.null body
        then Nothing
        else Just (userId, "eza_pat_" <> body)

wireSessionToken :: Control.ControlUser -> Auth.NewSession -> Auth.NewSession
wireSessionToken user session =
    session{Auth.nsToken = TokenPrefix.withUserPrefix TokenPrefix.sessionPrefix (cuId user) (Auth.nsToken session)}

wireApiToken :: Control.ControlUser -> Text -> Text
wireApiToken user raw = case T.stripPrefix "eza_pat_" raw of
    Just body -> TokenPrefix.withUserPrefix TokenPrefix.apiTokenPrefix (cuId user) body
    Nothing -> raw

wireShareToken :: Control.ControlUser -> Text -> Text
wireShareToken user raw = TokenPrefix.withUserPrefix TokenPrefix.sharePrefix (cuId user) raw

{- | Resolve a prefixed token to the account and slot that own it, plus the
bare value its database stores. Every token must carry its account prefix; an
unprefixed value resolves to nothing (401). Left carries a limit message the
guard reports as 503; Right Nothing means the token names no usable account.
-}
resolveOwner ::
    AppState ->
    Maybe (Int, Text) ->
    Text ->
    IO (Either Text (Maybe (Control.ControlUser, UserSlot, Text)))
resolveOwner state parsed _raw =
    case parsed of
        Just (userId, bare) -> do
            muser <- enabledUserById state userId
            case muser of
                Nothing -> pure (Right Nothing)
                Just user -> slotThen user bare
        Nothing -> pure (Right Nothing)
  where
    slotThen user bare = do
        result <- userSlotFor state user
        pure $ case result of
            Left message -> Left message
            Right slot -> Right (Just (user, slot, bare))

resolveSession ::
    AppState ->
    Text ->
    IO (Either Text (Maybe (Control.ControlUser, UserSlot, Auth.Session)))
resolveSession state wire = do
    owner <- resolveOwner state (stripSessionPrefix wire) wire
    case owner of
        Left message -> pure (Left message)
        Right Nothing -> pure (Right Nothing)
        Right (Just (user, slot, bare)) -> do
            found <- withReadDb slot $ \conn -> Auth.validateSession conn bare
            pure (Right (fmap (\session -> (user, slot, session)) found))

resolveApiToken ::
    AppState ->
    Text ->
    IO (Either Text (Maybe (Control.ControlUser, UserSlot, Text)))
resolveApiToken state wire = resolveOwner state (stripApiTokenPrefix wire) wire

resolveShareOwner ::
    AppState ->
    Text ->
    IO (Either Text (Maybe (Control.ControlUser, UserSlot, Text)))
resolveShareOwner state wire = resolveOwner state (stripSessionPrefix wire) wire

-- ---------------------------------------------------------------------------
-- Per-user workers
-- ---------------------------------------------------------------------------

{- | The worker inputs for one 'AppState'. The supervisor is the only caller
that starts workers, so a library opened by a request does no background work
until the first supervisor tick.
-}
libraryWorkerConfig :: AppState -> UserSlot -> LibraryWorkerConfig
libraryWorkerConfig state slot =
    LibraryWorkerConfig
        { lwcConfig = asConfig state
        , lwcManager = asManager state
        , lwcEnrichSem = asEnrichSem state
        , lwcSnapshotDir = usSnapshotDir slot
        }

-- | How many live worker loops each open account currently has (tests use it).
userWorkerIds :: AppState -> IO [(Int, Int)]
userWorkerIds state = do
    slots <- Map.elems <$> readMVar (asUsers state)
    forM slots $ \slot -> do
        workers <- Library.libraryWorkerIds (usLibrary slot)
        pure (cuId (usUser slot), workers)

-- | Start (or restart) one open account's enrichment, favicon, and webhook loops.
startUserWorkers :: AppState -> UserSlot -> IO ()
startUserWorkers state slot =
    Library.startLibraryWorkers (libraryWorkerConfig state slot) (usLibrary slot)

-- | Stop one account's workers (disable, shutdown, or tests).
stopUserWorkers :: UserSlot -> IO ()
stopUserWorkers slot = Library.stopLibraryWorkers (usLibrary slot)

stopAllUserWorkers :: AppState -> IO ()
stopAllUserWorkers state = do
    slots <- readMVar (asUsers state)
    mapM_ stopUserWorkers (Map.elems slots)

{- | One reconciliation pass: workers exist only for enabled accounts, enabled
accounts get their library opened, and disabled or removed accounts lose their
workers. Disabling therefore stops enrichment and webhook delivery at the next
tick without touching the control row again. The supervisor is the only place
workers start, so a library opened by a request never starts them implicitly.
-}
syncUserWorkers :: AppState -> IO ()
syncUserWorkers state = do
    users <- withControl state Control.listUsers
    let enabledUsers = [user | user <- users, isNothing (cuDisabledAt user)]
        enabledIds = Set.fromList (map cuId enabledUsers)
    slots <- readMVar (asUsers state)
    forM_ (Map.elems slots) $ \slot ->
        unless (cuId (usUser slot) `Set.member` enabledIds) (stopUserWorkers slot)
    misses <-
        fmap catMaybes $
            forM enabledUsers $ \user -> do
                opened <- userSlotFor state user
                case opened of
                    Left message -> pure (Just (cuId user, message))
                    Right slot -> do
                        startUserWorkers state slot
                        pure Nothing
    warnWorkerLimit state misses

{- | Report accounts the process cannot open because of the user cap once per
change, not once per tick.
-}
warnWorkerLimit :: AppState -> [(Int, T.Text)] -> IO ()
warnWorkerLimit state misses = do
    let ids = map fst misses
    previous <- readMVar (asWorkerLimitWarned state)
    when (ids /= previous) $ do
        forM_ misses $ \(userId, message) ->
            hPutStrLn stderr ("eza: worker supervisor: user " <> show userId <> ": " <> T.unpack message)
        modifyMVar_ (asWorkerLimitWarned state) (const (pure ids))

cleanupAllSessions :: AppState -> IO ()
cleanupAllSessions state = do
    slots <- readMVar (asUsers state)
    forM_ (Map.elems slots) $ \slot -> do
        result <- try (withDb slot Auth.cleanupExpired) :: IO (Either SomeException ())
        case result of
            Left err ->
                hPutStrLn stderr ("eza: session cleanup failed for user " <> show (cuId (usUser slot)) <> ": " <> show err)
            Right () -> pure ()

{- | Warn once at startup instead of letting the first request discover the
problem: accounts over the slot cap cannot sign in, and an enabled account
whose library file vanished would otherwise be silently recreated empty when
first opened.
-}
logStartupWarnings :: Config -> AppState -> IO ()
logStartupWarnings cfg state =
    withControl state $ \control -> do
        limitMessage <- Admin.userLimitWarning cfg control
        forM_ limitMessage (hPutStrLn stderr . T.unpack)
        missing <- Admin.missingUserDatabases cfg control
        forM_ missing $ \user ->
            hPutStrLn
                stderr
                ( "eza: account "
                    <> T.unpack (cuUsername user)
                    <> " has no library database at "
                    <> cuDbPath user
                    <> "; restore it from a backup instead of signing in"
                )

{- | The server's worker supervisor: reconcile every five seconds and sweep
expired sessions once a day for every open user database.
-}
workerSupervisor :: AppState -> IO ()
workerSupervisor state = do
    result <- try (syncUserWorkers state) :: IO (Either SomeException ())
    case result of
        Left err -> hPutStrLn stderr ("eza: worker supervisor: " <> show err)
        Right () -> pure ()
    now <- floor <$> getPOSIXTime
    lastCleanup <- readMVar (asLastSessionCleanup state)
    when (now - lastCleanup >= 86400) $ do
        cleanupAllSessions state
        modifyMVar_ (asLastSessionCleanup state) (const (pure now))
    threadDelay (5 * 1000000)
    workerSupervisor state

data AuthContext
    = CookieSession Auth.Session
    | BearerToken Token

{- | Every authenticated JSON and app-shell route. The handler keeps its
plain 'Connection' signature; the connection is the authenticated user's
database, and the context carries that user's control row and slot.
-}

{- | Record a session's activity on the writer only when the throttle window
has passed. The common GET path is a read-only validation: the stored
timestamp is already fresh, so this never acquires the writer.
-}
recordSessionActivity :: UserSlot -> Auth.Session -> IO ()
recordSessionActivity slot session = do
    due <- Auth.sessionActivityDue session
    when due $ withDb slot $ \conn -> Auth.touchSession conn session

-- | The same throttled activity write for a bearer token's @last_used_at@.
recordTokenActivity :: UserSlot -> Token -> IO ()
recordTokenActivity slot token = do
    due <- tokenActivityDue token
    when due $ withDb slot $ \conn -> touchToken conn token

{- | The per-user WebAuthn handle. It is generated with the control row; a
legacy row without one gets a fresh handle stored before the ceremony, so two
accounts on one server never share a user handle.
-}
passkeyHandle :: AppState -> Control.ControlUser -> IO BS.ByteString
passkeyHandle state user = do
    ensured <- withControl state $ \control -> Control.ensureCredentialHandle control user
    pure (fromMaybe "\x01" (cuCredentialHandle ensured))

{- | The live browser session named by the session cookie. The cookie value
carries the user prefix, so this resolves the owning database first.
-}
requestSession ::
    AppState ->
    Request ->
    IO (Maybe (Control.ControlUser, UserSlot, Auth.Session))
requestSession state req =
    case cookieValue req Auth.sessionCookieName of
        Nothing -> pure Nothing
        Just wire -> do
            resolved <- resolveSession state wire
            pure (either (const Nothing) id resolved)

{- | The pending cookie that the password step set. Only a live @pending_2fa@
session resolves; the normal session cookie is not consulted here.
-}
pendingSession ::
    AppState ->
    Request ->
    IO (Maybe (Control.ControlUser, UserSlot, Auth.Session))
pendingSession state req =
    case cookieValue req Auth.pendingCookieName of
        Nothing -> pure Nothing
        Just wire -> do
            resolved <- resolveSession state wire
            pure $ case resolved of
                Right (Just (user, slot, sess))
                    | Auth.sessScope sess == Auth.pendingScope -> Just (user, slot, sess)
                _ -> Nothing
