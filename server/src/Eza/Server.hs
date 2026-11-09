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
    enableWorkers,
    syncUserWorkers,
    stopAllUserWorkers,
    userWorkerIds,
    app,
    runServer,
    bootPayloadFor,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel, poll)
import Control.Concurrent.MVar
import Control.Concurrent.QSem (QSem, newQSem)
import Control.Exception (IOException, SomeException, bracket, onException, throwIO, try)
import Control.Monad (filterM, forM, forM_, void, when)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as LBS
import Data.Char (isDigit, toLower)
import Data.Int (Int64)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe, isNothing, mapMaybe)
import Data.Pool (Pool, defaultPoolConfig, destroyAllResources, newPool, withResource)
import qualified Data.Set as Set
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime, utcTimeToPOSIXSeconds)
import Data.Word (Word64)
import Database.SQLite.Simple (Connection, Only (..), query)
import qualified Database.SQLite.Simple as Sqlite
import Network.HTTP.Client (Manager)
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types
import Network.Socket (SockAddr (..))
import Network.Wai
import Network.Wai.Handler.Warp
import Network.Wai.Middleware.Gzip (GzipFiles (..), GzipSettings (..), defaultGzipSettings, gzip)
import Network.Wai.Middleware.RequestLogger (logStdout, logStdoutDev)
import Network.Wai.Middleware.RequestSizeLimit (defaultRequestSizeLimitSettings, requestSizeLimitMiddleware, setMaxLengthForRequest, setOnLengthExceeded)
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, getFileSize, getModificationTime)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath (addTrailingPathSeparator, (</>))
import System.IO (hPutStrLn, stderr)
import qualified Web.Cookie as Cookie

import qualified Eza.Admin as Admin
import Eza.AiTag (aiSuggestions, resolveAiModel)
import qualified Eza.Auth as Auth
import qualified Eza.Authz as Authz
import Eza.Bookmarks
import Eza.Boot (BootPayload (..))
import Eza.Clip (ClipError, ClipRequest (..), ClipTemplate (..), SaveClipResult (..), TemplateError, clipErrorCode, clipErrorMessage, clipErrorStatus, createTemplate, deleteTemplate, getTemplate, previewClip, saveClip, templateErrorCode, templateErrorMessage, templateErrorStatus, templatesPayload, updateTemplate)
import Eza.Config
import Eza.Control (ControlUser (..))
import qualified Eza.Control as Control
import qualified Eza.Db as Db
import Eza.DeadLinks (checkDead)
import Eza.Dedup (DedupQuery (..), dedupCandidates, mergeBookmarks, mergeUrlDuplicatesAll)
import Eza.Enrich (enqueueEnrichment, runEnrichWorkerFor, runFaviconWorkerFor)
import Eza.Export (exportBookmarks)
import Eza.Favicon (Favicon (..), getFavicon)
import Eza.Graph (LayoutCache (..), emptyLayoutCache, globalGraph, graphLayoutPayload, graphRevision, layoutPresetFromText, lookupCachedLayout, storeCachedLayout)
import Eza.Highlights (createHighlight, deleteHighlight, listHighlights, updateHighlight)
import Eza.Import (defaultImportOptions, importParsed, parseNetscape)
import Eza.Jobs (resetRunningJobs)
import Eza.JsonExport (JsonImportReport (..), exportJson, importJson)
import Eza.Pages (addPasskeyPage, loginPage, passkeyLoginPage, recoverPage, recoverySetupPage, setupPage)
import Eza.Password (validatePassword, validateUsername)
import qualified Eza.Password as Password
import Eza.Rules (Rule (..), createRule, deleteRule, listRules, matchingBookmarks, updateRule)
import Eza.SavedSearches (createSavedSearch, deleteSavedSearch, listSavedSearches)
import Eza.Shares (ShareRecord (..), ShareState (..), ShareUnavailable (..), createShare, listShares, resolveShareState, revokeShare, shareBookmarkPage, shareSearchFeed, shareSearchPage, shareUnavailablePage)
import Eza.Snapshot (captureSnapshot)
import Eza.Tags (consolidationCandidates, deleteTag, deleteTagWithLinks, mergeTags, renameTag)
import qualified Eza.TokenPrefix as TokenPrefix
import Eza.Tokens (Token (..), authenticateToken, createToken, listTokens, revokeToken)
import Eza.Types
import Eza.Undo (undoLast)
import Eza.User (UserCreateInput (..), UserCreateResult (..), UserRole (..))
import Eza.View (ViewInput (..))
import Eza.Views (ViewError, ViewPatch (..), createView, deleteView, getView, listViews, updateView, viewErrorCode, viewErrorMessage, viewErrorStatus)
import Eza.Webhook (WebhookInput (..))
import Eza.Webhooks (WebhookError, WebhookWorkerConfig (..), createWebhook, defaultWebhookWorkerConfig, deleteWebhook, getWebhook, listDeliveries, listWebhooks, runWebhookWorker, testWebhook, updateWebhook, webhookErrorCode, webhookErrorMessage, webhookErrorStatus)
import Network.Wai.Parse (File, FileInfo (..), Param, defaultParseRequestBodyOptions, lbsBackEnd, parseRequestBodyEx, setMaxRequestFileSize, setMaxRequestFilesSize, setMaxRequestNumFiles, setMaxRequestParmsSize)

runServer :: Config -> IO ()
runServer cfg = do
    state <- newAppState cfg
    logStartupWarnings cfg state
    enableWorkers state
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
    , asControl :: MVar Connection
    , asUsers :: MVar (Map.Map Int UserSlot)
    , asManager :: Manager
    , asRecoveryLimiter :: Auth.RateLimiter
    , asLoginLimiter :: Auth.RateLimiter
    , asWorkersEnabled :: MVar Bool
    , asEnrichSem :: QSem
    , asLastSessionCleanup :: MVar Int
    , asWorkerLimitWarned :: MVar [Int]
    }

{- | An opened user library. Slots are created on first use and closed at
shutdown. The map in 'asUsers' is the only place a request gets a database
path, and every path comes from the control row, never from a request.
-}
data UserSlot = UserSlot
    { usUser :: Control.ControlUser
    , usDbPath :: FilePath
    , usWrite :: MVar Connection
    , usRead :: Pool Connection
    , usLayoutCache :: MVar LayoutCache
    , usSnapshotDir :: FilePath
    , usWorkers :: MVar [Async ()]
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

-- ---------------------------------------------------------------------------
-- Application state
-- ---------------------------------------------------------------------------

{- | Open the control database, register an existing single-user installation
when the control registry is empty, and start with no user slots open. The
control database is cheap and the user databases open lazily; a request only
ever opens the database its authenticated account names.
-}
newAppState :: Config -> IO AppState
newAppState cfg = do
    control <- Control.openControlDb (cfgControlDbPath cfg)
    bootstrapControl cfg control
    manager <- newTlsManager
    recoveryLimiter <- Auth.newRateLimiter 5 900
    {- The per-host login limiter is checked before the current attempt is
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
    controlVar <- newMVar control
    usersVar <- newMVar Map.empty
    workersEnabledVar <- newMVar False
    enrichSem <- newQSem (max 1 (cfgEnrichWorkers cfg))
    lastCleanupVar <- newMVar 0
    limitWarnedVar <- newMVar []
    pure
        AppState
            { asConfig = cfg
            , asControl = controlVar
            , asUsers = usersVar
            , asManager = manager
            , asRecoveryLimiter = recoveryLimiter
            , asLoginLimiter = loginLimiter
            , asWorkersEnabled = workersEnabledVar
            , asEnrichSem = enrichSem
            , asLastSessionCleanup = lastCleanupVar
            , asWorkerLimitWarned = limitWarnedVar
            }

{- | Bootstrap and migration. The two existing shapes are:

  * @EZA_DB@ (default @data/eza.db@) is claimed, meaning it already has an
    account, and the control database is empty: register that exact file as
    user 1 with the admin role. The file is never copied or moved, so an
    operator can roll back by removing the control database.

  * Everything else: leave the legacy file alone. The first @/setup@ creates
    @users/1/eza.db@ and registers it.

A control database with any user row ignores @EZA_DB@ entirely.
-}
bootstrapControl :: Config -> Connection -> IO ()
bootstrapControl cfg control = do
    accounts <- Control.countUsers control
    when (accounts == 0) $ do
        claimed <- legacyDatabaseClaimed cfg
        when claimed $ do
            -- The legacy account's own username is authoritative. Using a
            -- placeholder here made the migrated account impossible to log
            -- into, because login resolves the control row by username.
            legacyName <- legacyUsername cfg
            let username = case fmap T.strip legacyName of
                    Just name | not (T.null name) -> name
                    _ -> "owner"
            created <- Control.createUser control username (cfgDbPath cfg) RoleAdmin Nothing
            case created of
                Left err ->
                    ioError (userError ("could not register the existing database at " <> cfgDbPath cfg <> ": " <> show err))
                Right user ->
                    hPutStrLn
                        stderr
                        ( "eza: registered the existing database "
                            <> cfgDbPath cfg
                            <> " as user "
                            <> show (cuId user)
                            <> " ("
                            <> T.unpack (cuUsername user)
                            <> ", admin); the file was left in place"
                        )
    -- Repair the placeholder name written by the first migration build, so an
    -- installation that already ran it can log in again without hand-editing
    -- the control database.
    repairLegacyAccountName cfg control

{- | The username stored in an existing user database, if it has the old or
new app_state row. Missing files, the Python layout, and unclaimed databases
return Nothing.
-}
legacyUsername :: Config -> IO (Maybe Text)
legacyUsername cfg = usernameInDatabase (cfgDbPath cfg)

usernameInDatabase :: FilePath -> IO (Maybe Text)
usernameInDatabase path = do
    exists <- doesFileExist path
    if not exists
        then pure Nothing
        else do
            result <-
                try
                    ( bracket (Sqlite.open path) Sqlite.close $ \conn -> do
                        rows <- Sqlite.query_ conn "SELECT username FROM app_state WHERE id = 1" :: IO [Only Text]
                        pure (case rows of [Only name] -> Just name; _ -> Nothing)
                    ) ::
                    IO (Either SomeException (Maybe Text))
            pure (either (const Nothing) id result)

{- | If a migration from before the username fix registered the legacy library
as the placeholder @owner@, restore the name the database actually has. Runs
on every start and is a no-op once the names agree.
-}
repairLegacyAccountName :: Config -> Connection -> IO ()
repairLegacyAccountName _cfg control = do
    users <- Control.listUsers control
    forM_ users $ \user ->
        when (T.strip (cuUsername user) == "owner") $ do
            stored <- usernameInDatabase (cuDbPath user)
            case fmap T.strip stored of
                Just name
                    | not (T.null name)
                    , name /= cuUsername user -> do
                        repaired <- Control.setUsername control (cuId user) name
                        case repaired of
                            Right () ->
                                hPutStrLn
                                    stderr
                                    ( "eza: repaired the migrated account username from "
                                        <> T.unpack name
                                        <> " in the library database"
                                    )
                            Left err ->
                                hPutStrLn
                                    stderr
                                    ( "eza: could not repair the migrated account username: "
                                        <> show err
                                    )
                _ -> pure ()

{- | True when the legacy single-user database exists and its @app_state@ says
an account was claimed. A missing table (the old Python layout) or an
unclaimed database is not migrated.
-}
legacyDatabaseClaimed :: Config -> IO Bool
legacyDatabaseClaimed cfg = do
    exists <- doesFileExist (cfgDbPath cfg)
    if not exists
        then pure False
        else do
            result <-
                try (bracket (Sqlite.open (cfgDbPath cfg)) Sqlite.close Auth.setupClaimed) ::
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
closeUserSlot slot = do
    destroyAllResources (usRead slot)
    withMVar (usWrite slot) Sqlite.close

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
    case opened of
        Left message -> pure (Left message)
        Right slot -> do
            startUserWorkers state slot
            pure (Right slot)

-- | How many user databases this process currently has open (tests use it).
userSlotCount :: AppState -> IO Int
userSlotCount state = Map.size <$> readMVar (asUsers state)

openUserSlot :: Config -> Control.ControlUser -> IO UserSlot
openUserSlot cfg user = do
    conn <- Db.openDb (cuDbPath user)
    Auth.cleanupExpired conn
    resetRunningJobs conn
    writeVar <- newMVar conn
    readPool <-
        newPool
            ( defaultPoolConfig
                (openReadConnection (cuDbPath user))
                Sqlite.close
                60
                4
            )
    layoutCache <- newMVar emptyLayoutCache
    workersVar <- newMVar []
    pure
        UserSlot
            { usUser = user
            , usDbPath = cuDbPath user
            , usWrite = writeVar
            , usRead = readPool
            , usLayoutCache = layoutCache
            , usSnapshotDir = Admin.userSnapshotDir cfg (cuId user)
            , usWorkers = workersVar
            }

withDb :: UserSlot -> (Connection -> IO a) -> IO a
withDb slot = withMVar (usWrite slot)

withReadDb :: UserSlot -> (Connection -> IO a) -> IO a
withReadDb slot = withResource (usRead slot)

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
        Left message -> respond (jsonError status503 "user_limit" message)
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

{- | The legacy fallback: an unprefixed token may only resolve while exactly one
enabled account exists, so there is never a question of whose database it
belongs to.
-}
legacyUser :: AppState -> IO (Maybe Control.ControlUser)
legacyUser state = withControl state $ \control -> do
    enabled <- Control.countEnabledUsers control
    if enabled /= 1
        then pure Nothing
        else do
            users <- Control.listUsers control
            pure $ case filter (isNothing . cuDisabledAt) users of
                [user] -> Just user
                _ -> Nothing

-- ---------------------------------------------------------------------------
-- Token prefixes
-- ---------------------------------------------------------------------------

{- | The wire format carries the owning account id, so the server can pick the
user database before it hashes and validates the token. A rewritten prefix
lands on the wrong database and fails the hash check. Unprefixed values use
the explicit single-account fallback.

Wire forms: @u<id>_<raw>@ for sessions, pending sessions, and share links,
and @eza_pat_u<id>_<raw>@ for API bearer tokens.
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

{- | Resolve a prefixed (or legacy unprefixed) token to the account and slot
that own it, plus the bare value its database stores. Left carries a limit
message the guard reports as 503; Right Nothing means the token names no
usable account.
-}
resolveOwner ::
    AppState ->
    Maybe (Int, Text) ->
    Text ->
    IO (Either Text (Maybe (Control.ControlUser, UserSlot, Text)))
resolveOwner state parsed raw =
    case parsed of
        Just (userId, bare) -> do
            muser <- enabledUserById state userId
            case muser of
                Nothing -> pure (Right Nothing)
                Just user -> slotThen user bare
        Nothing -> do
            muser <- legacyUser state
            case muser of
                Nothing -> pure (Right Nothing)
                Just user -> slotThen user raw
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
            found <- withDb slot $ \conn -> Auth.getSession conn bare
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

{- | Turn worker supervision on for this process. A plain 'newAppState' (tests,
-- tools) leaves it off so no worker touches a temporary database unexpectedly;
-- 'runServer' enables it at startup.
-}
enableWorkers :: AppState -> IO ()
enableWorkers state = modifyMVar_ (asWorkersEnabled state) (const (pure True))

-- | How many live worker loops each open account currently has (tests use it).
userWorkerIds :: AppState -> IO [(Int, Int)]
userWorkerIds state = do
    slots <- Map.elems <$> readMVar (asUsers state)
    forM slots $ \slot -> do
        workers <- readMVar (usWorkers slot)
        pure (cuId (usUser slot), length workers)

{- | Start (or restart) the enrichment and webhook loops for one open user
database. A healthy set is left alone; a set with a dead member is replaced.
The enrich semaphore is process-wide, so @EZA_ENRICH_WORKERS@ caps total
network work across every account while each database keeps its own claimer.
-}
startUserWorkers :: AppState -> UserSlot -> IO ()
startUserWorkers state slot = do
    enabled <- readMVar (asWorkersEnabled state)
    when enabled $ do
        let user = usUser slot
        when (isNothing (cuDisabledAt user)) $
            modifyMVar_ (usWorkers slot) $ \running -> do
                alive <- filterM stillRunning running
                if not (null running) && length alive == length running
                    then pure running
                    else do
                        mapM_ cancel running
                        spawnUserWorkers state slot

spawnUserWorkers :: AppState -> UserSlot -> IO [Async ()]
spawnUserWorkers state slot = do
    let cfg = asConfig state
        manager = asManager state
        databasePath = usDbPath slot
        enrichCount = cfgEnrichWorkers cfg
        webhookCfg = (defaultWebhookWorkerConfig cfg manager){wwcDatabase = databasePath}
    enrichWorkers <-
        forM [1 .. enrichCount] $ \_ ->
            async (runEnrichWorkerFor manager cfg databasePath (asEnrichSem state))
    webhookWorker <- async (runWebhookWorker webhookCfg)
    -- One favicon backfill loop per account: cached domains cost no network,
    -- and each new domain costs one fetch no matter how many links it has.
    faviconWorkers <-
        if cfgFaviconBackfill cfg && enrichCount > 0
            then (: []) <$> async (runFaviconWorkerFor manager cfg databasePath (asEnrichSem state))
            else pure []
    pure (enrichWorkers <> [webhookWorker] <> faviconWorkers)

stillRunning :: Async () -> IO Bool
stillRunning worker = isNothing <$> poll worker

-- | Stop one account's workers (disable, shutdown, or tests).
stopUserWorkers :: UserSlot -> IO ()
stopUserWorkers slot = modifyMVar_ (usWorkers slot) $ \running -> do
    mapM_ cancel running
    pure []

stopAllUserWorkers :: AppState -> IO ()
stopAllUserWorkers state = do
    slots <- readMVar (asUsers state)
    mapM_ stopUserWorkers (Map.elems slots)

{- | One reconciliation pass: workers exist only for enabled accounts, enabled
accounts get their database opened, disabled or removed accounts lose their
workers. Disabling therefore stops enrichment and webhook delivery at the next
tick (five seconds in the server) without touching the control row again.
-}
syncUserWorkers :: AppState -> IO ()
syncUserWorkers state = do
    users <- withControl state Control.listUsers
    let enabledIds = Set.fromList [cuId user | user <- users, isNothing (cuDisabledAt user)]
    slots <- readMVar (asUsers state)
    forM_ (Map.elems slots) $ \slot ->
        if cuId (usUser slot) `Set.member` enabledIds
            then startUserWorkers state slot
            else stopUserWorkers slot
    misses <-
        fmap catMaybes $
            forM users $ \user ->
                if isNothing (cuDisabledAt user) && not (Map.member (cuId user) slots)
                    then do
                        opened <- userSlotFor state user
                        pure $ case opened of
                            Left message -> Just (cuId user, message)
                            Right _ -> Nothing
                    else pure Nothing
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
    | pathInfo req == ["api", "v1", "import"] = Just (fromIntegral (cfgImportMaxBytes cfg))
    | otherwise = Just (fromIntegral (cfgMaxBodyBytes cfg))

requestTooLargeResponse :: Word64 -> Response
requestTooLargeResponse limit =
    jsonError
        status413
        "payload_too_large"
        ("request body must be at most " <> T.pack (show limit) <> " bytes")

app :: Config -> AppState -> Application
app cfg state = requestBodyLimitMiddleware cfg (dispatchApp cfg state)

-- | The routed application, behind the request-body limit.
dispatchApp :: Config -> AppState -> Application
dispatchApp cfg state req respond =
    case (requestMethod req, pathInfo req) of
        -- CORS preflight for the browser clipper. This must run before the
        -- auth guard: the preflight deliberately carries no Authorization.
        ("OPTIONS", path) | isClipPath path -> clipPreflight cfg req respond
        -- Public: health + password auth pages/ceremonies.
        ("GET", ["healthz"]) -> health state respond
        ("GET", ["login"]) -> loginHandler state req respond
        ("GET", ["setup"]) -> setupHandler state req respond
        ("GET", ["recover"]) -> respond (htmlResponse recoverPage)
        ("GET", ["s", token]) -> publicShareHandler state token respond
        ("POST", ["api", "auth", "login"]) -> passwordLoginHandler state req respond
        ("POST", ["api", "auth", "passkey", "options"]) -> passkeySecondFactorOptionsHandler state req respond
        ("POST", ["api", "auth", "passkey", "verify"]) -> passkeySecondFactorVerifyHandler state req respond
        ("POST", ["api", "auth", "options"]) -> legacyPasskeyOptionsHandler state req respond
        ("POST", ["api", "auth", "verify"]) -> legacyPasskeyVerifyHandler state req respond
        ("POST", ["api", "setup", "password"]) -> passwordSetupHandler state req respond
        -- Passkey-first setup is retired. Recovery sets a password too.
        ("POST", ["api", "setup", "options"]) -> respond passkeySetupRetired
        ("POST", ["api", "setup", "verify"]) -> respond passkeySetupRetired
        ("POST", ["api", "recovery", "redeem"]) -> recoveryRedeemHandler state req respond
        ("GET", ("assets" : rest)) -> serveAsset cfg rest req respond
        ("GET", ["favicon.svg"]) -> serveAsset cfg ["favicon.svg"] req respond
        ("GET", ["theme.js"]) -> serveAsset cfg ["theme.js"] req respond
        ("GET", ["manifest.webmanifest"]) ->
            serveStaticFile cfg "manifest.webmanifest" [("Content-Type", "application/manifest+json")] req respond
        ("GET", ["sw.js"]) -> serveServiceWorker cfg req respond
        ("GET", []) -> do
            msess <- requestSession state req
            case msess of
                Just (_, _, sess) | Auth.sessScope sess == "normal" -> indexResponse cfg req respond
                _ -> respond (redirectTo "/login")
        -- Authenticated API.
        _ -> withAuthed cfg state req respond $ \rctx conn -> authedRoute rctx req respond conn

-- ---------------------------------------------------------------------------
-- Public auth handlers
-- ---------------------------------------------------------------------------

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
                    respond (htmlResponse (if legacy then passkeyLoginPage else loginPage))

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
    case msess of
        Just (user, _, sess)
            | Auth.sessScope sess == "recovery" ->
                respond (htmlResponse (recoverySetupPage (cuUsername user)))
        Just _ -> respond (redirectTo "/")
        Nothing -> do
            accounts <- withControl state Control.countUsers
            if accounts == 0
                then respond (htmlResponse setupPage)
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
            body <- readAuthBody cfg req
            case body of
                Left AuthBodyTooLarge -> respond (payloadTooLargeResponse cfg)
                Left (AuthBodyInvalid message) -> respond (jsonError status400 "bad_request" message)
                Right value -> case parseMaybeObj value of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case (parseMaybe (.: "username") o, parseMaybe (.: "password") o) of
                        (Just username, Just password) -> do
                            let limiterKey = clientHostKey req <> "|" <> T.toLower (T.strip username)
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
                Password.dummyVerify (cfgArgon2 cfg) password
                respond invalidCredentials
            Just user -> withSlot state user respond $ \slot -> do
                result <-
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

{- | The client address without the ephemeral source port, so the login and
recovery limiters key on the host instead of on each new connection.
-}
clientHostKey :: Request -> Text
clientHostKey req = case remoteHost req of
    SockAddrInet _ address -> T.pack (show address)
    SockAddrInet6 _ _ address _ -> T.pack (show address)
    other -> T.pack (show other)

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
            body <- readAuthBody cfg req
            case body of
                Left AuthBodyTooLarge -> respond (payloadTooLargeResponse cfg)
                Left (AuthBodyInvalid message) -> respond (jsonError status400 "bad_request" message)
                Right value -> do
                    let limiterKey = clientHostKey req <> "|recovery"
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

{- | Every authenticated JSON and app-shell route. The handler keeps its
plain 'Connection' signature; the connection is the authenticated user's
database, and the context carries that user's control row and slot.
-}
authedRoute :: RequestContext -> Request -> (Response -> IO ResponseReceived) -> Connection -> IO ResponseReceived
authedRoute rctx req respond conn =
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
            payload <- bootPayloadFor (cfgPublicOrigin cfg) conn
            respond (jsonResponse status200 payload)
        ("GET", ["api", "v1", "bookmarks"]) -> do
            page <- listBookmarks conn (listQueryFrom req)
            respond (jsonResponse status200 page)
        ("POST", ["api", "v1", "bookmarks"]) -> addBookmark cfg conn req respond
        ("POST", ["api", "v1", "bookmarks", "bulk"]) -> bulkHandler cfg conn req respond
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
            quickSaveHandler cfg conn req respond
        ("GET", ["api", "v1", "bookmarks", idTxt, "highlights"]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> do
                highlights <- listHighlights conn bid
                respond (jsonResponse status200 (object ["highlights" .= highlights]))
        ("POST", ["api", "v1", "bookmarks", idTxt, "highlights"]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> highlightCreateHandler cfg conn bid req respond
        ("PATCH", ["api", "v1", "bookmarks", idTxt, "highlights", hidTxt]) ->
            case (readInt idTxt, readInt hidTxt) of
                (Just bid, Just hid) -> highlightUpdateHandler cfg conn bid hid req respond
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
        ("POST", ["api", "v1", "share-links"]) -> shareCreateHandler cfg user conn req respond
        ("DELETE", ["api", "v1", "share-links", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid share id")
            Just shareId -> do
                ok <- revokeShare conn shareId
                if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "share not found")
        ("GET", ["api", "v1", "bookmarks", idTxt, "snapshot"]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> snapshotHandler cfg slot conn bid respond
        ("GET", ["api", "v1", "tags"]) -> do
            tags <- allTags conn
            respond (jsonResponse status200 (object ["tags" .= tags]))
        ("POST", ["api", "v1", "inbox", "mark-all-above"]) -> markAbove cfg conn req respond
        ("PATCH", ["api", "v1", "bookmarks", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> patchBookmark cfg conn bid req respond
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
                            m <- captureSnapshot cfg (usSnapshotDir slot) conn bid
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
            graph <- globalGraph conn
            respond (jsonResponse status200 graph)
        ("GET", ["api", "v1", "graph", "layout"]) ->
            graphLayoutHandler slot conn req respond
        ("GET", ["api", "v1", "views"]) -> do
            views <- listViews conn
            respond (jsonResponse status200 (object ["views" .= views]))
        ("POST", ["api", "v1", "views"]) ->
            viewsCreateHandler cfg conn req respond
        ("GET", ["api", "v1", "views", viewSlug]) -> do
            found <- getView conn viewSlug
            case found of
                Nothing -> respond (jsonError status404 "not_found" "view not found")
                Just view -> respond (jsonResponse status200 view)
        ("PATCH", ["api", "v1", "views", viewSlug]) ->
            viewsUpdateHandler cfg conn viewSlug req respond
        ("DELETE", ["api", "v1", "views", viewSlug]) -> do
            result <- deleteView conn viewSlug
            case result of
                Left err -> respond (viewErrorResponse err)
                Right () -> respond (emptyResponse status204)
        ("GET", ["api", "v1", "webhooks"]) -> do
            webhooks <- listWebhooks conn
            respond (jsonResponse status200 (object ["webhooks" .= webhooks]))
        ("POST", ["api", "v1", "webhooks"]) ->
            webhookCreateHandler cfg conn req respond
        ("GET", ["api", "v1", "webhooks", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid webhook id")
            Just webhookId -> do
                found <- getWebhook conn webhookId
                case found of
                    Nothing -> respond (jsonError status404 "not_found" "webhook not found")
                    Just webhook -> respond (jsonResponse status200 webhook)
        ("PATCH", ["api", "v1", "webhooks", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid webhook id")
            Just webhookId -> webhookUpdateHandler cfg conn webhookId req respond
        ("DELETE", ["api", "v1", "webhooks", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid webhook id")
            Just webhookId -> do
                removed <- deleteWebhook conn webhookId
                if removed
                    then respond (emptyResponse status204)
                    else respond (jsonError status404 "not_found" "webhook not found")
        ("POST", ["api", "v1", "webhooks", idTxt, "test"]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid webhook id")
            Just webhookId ->
                webhookTestHandler cfg state conn webhookId respond
        ("GET", ["api", "v1", "webhooks", idTxt, "deliveries"]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid webhook id")
            Just webhookId -> do
                exists <- getWebhook conn webhookId
                case exists of
                    Nothing -> respond (jsonError status404 "not_found" "webhook not found")
                    Just _ -> do
                        let limit = fromMaybe 20 (readInt =<< param "limit" req)
                        deliveries <- listDeliveries conn webhookId limit
                        respond (jsonResponse status200 (object ["deliveries" .= deliveries]))
        ("GET", ["api", "v1", "saved-searches"]) -> do
            s <- listSavedSearches conn
            respond (jsonResponse status200 (object ["saved_searches" .= s]))
        ("POST", ["api", "v1", "saved-searches"]) -> do
            body <- jsonBody cfg req
            case body of
                Left response -> respond response
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
            body <- jsonBody cfg req
            case body of
                Left response -> respond response
                Right v -> case parseMaybeObj v of
                    Just o
                        | (parseMaybe (.: "confirm") o :: Maybe Bool) == Just True -> do
                            report <- mergeUrlDuplicatesAll conn
                            respond (jsonResponse status200 report)
                    _ -> respond (jsonError status400 "bad_request" "confirm is required")
        ("POST", ["api", "v1", "dedup", "merge"]) -> do
            body <- jsonBody cfg req
            case body of
                Left response -> respond response
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
            body <- jsonBody cfg req
            case body of
                Left response -> respond response
                Right v -> case parseMaybeObj v of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case (parseMaybe (.: "bookmark_id") o, parseMaybe (.: "tags") o) of
                        (Just bid, Just tags) -> do
                            n <- addTagsToBookmark conn bid tags
                            respond (jsonResponse status200 (object ["updated" .= n]))
                        _ -> respond (jsonError status400 "bad_request" "bookmark_id and tags are required")
        ("POST", ["api", "v1", "tags", "merge"]) -> do
            body <- jsonBody cfg req
            case body of
                Left response -> respond response
                Right v -> case parseMaybeObj v of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case (parseMaybe (.: "from") o, parseMaybe (.: "into") o) of
                        (Just froms, Just into) -> do
                            n <- mergeTags conn froms into
                            respond (jsonResponse status200 (object ["updated" .= n]))
                        _ -> respond (jsonError status400 "bad_request" "from and into are required")
        ("GET", ["api", "v1", "tags", tag, "suggestions"]) -> do
            r <- aiSuggestions (T.pack (cfgAiProvider cfg)) (T.pack (cfgAiModel cfg)) (T.pack (cfgOllamaBaseUrl cfg)) conn tag 20
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
            body <- jsonBody cfg req
            case body of
                Left response -> respond response
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
            body <- jsonBody cfg req
            case body of
                Left response -> respond response
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
            body <- jsonBody cfg req
            case body of
                Left response -> respond response
                Right v -> case parseMaybeObj v of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case parseMaybe (.: "ids") o :: Maybe [Int] of
                        Nothing -> respond (jsonError status400 "bad_request" "ids is required")
                        Just ids -> do
                            n <- pruneApply conn ids
                            respond (jsonResponse status200 (object ["pruned" .= n]))
        ("POST", ["api", "v1", "undo"]) -> do
            n <- undoLast conn
            respond (jsonResponse status200 (object ["restored" .= n]))
        ("POST", ["api", "v1", "import"]) -> importHandler cfg conn req respond
        ("POST", ["api", "v1", "import", "json"]) -> do
            body <- jsonBody cfg req
            case body of
                Left response -> respond response
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
            let provider = cfgAiProvider cfg
                model = resolveAiModel (T.pack provider) (T.pack (cfgAiModel cfg))
            key <-
                case provider of
                    "ollama" -> pure (Just "")
                    "openai" -> lookupEnv "OPENAI_API_KEY"
                    "openai-compatible" -> lookupEnv "OPENAI_API_KEY"
                    "none" -> pure Nothing
                    _ -> lookupEnv "ANTHROPIC_API_KEY"
            let configured = provider /= "none" && maybe False (not . null) key
            respond
                ( jsonResponse
                    status200
                    ( object
                        [ "provider" .= provider
                        , "model" .= model
                        , "configured" .= configured
                        ]
                    )
                )
        ("GET", ["api", "v1", "rules"]) -> do
            rules <- listRules conn
            respond (jsonResponse status200 (object ["rules" .= rules]))
        ("POST", ["api", "v1", "rules"]) -> do
            body <- jsonValue cfg req
            case body of
                Left response -> respond response
                Right rule -> do
                    created <- createRule conn (sanitizeRule rule)
                    respond (jsonResponse status201 created)
        ("POST", ["api", "v1", "rules", "test"]) -> do
            body <- jsonValue cfg req
            case body of
                Left response -> respond response
                Right rule -> do
                    ids <- matchingBookmarks conn (ruleField rule) (rulePattern rule)
                    respond (jsonResponse status200 (object ["matches" .= length ids, "bookmark_ids" .= ids]))
        ("PATCH", ["api", "v1", "rules", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid rule id")
            Just rid -> do
                body <- jsonValue cfg req
                case body of
                    Left response -> respond response
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
            body <- jsonValue cfg req
            case body of
                Left response -> respond response
                Right (TokenCreateBody name scopes) -> do
                    (_, raw, view) <- createToken conn name (fromMaybe ["read", "write"] scopes)
                    respond (jsonResponse status201 (object ["token" .= wireApiToken user raw, "token_info" .= view]))
        ("DELETE", ["api", "v1", "tokens", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid token id")
            Just tokenId -> do
                ok <- revokeToken conn tokenId
                if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "token not found")
        ("GET", ["api", "v1", "account"]) -> do
            payload <- accountPayload conn ctx (Control.cuRole user)
            respond (jsonResponse status200 payload)
        ("POST", ["api", "v1", "account", "2fa"]) -> accountTwoFactorHandler cfg conn ctx (Control.cuRole user) req respond
        ("POST", ["api", "v1", "account", "password"]) ->
            accountPasswordHandler cfg conn ctx req respond
        ("POST", ["api", "v1", "account", "username"]) ->
            accountUsernameHandler cfg state user conn req respond
        ("POST", ["api", "v1", "account", "sessions", "revoke-others"]) -> case ctx of
            CookieSession sess -> do
                revoked <- Auth.deleteOtherSessions conn sess
                respond (jsonResponse status200 (object ["revoked" .= revoked]))
            BearerToken _ -> respond (jsonError status403 "session_required" "a bearer token cannot revoke browser sessions")
        ("POST", ["api", "v1", "account", "passkeys", "options"]) -> do
            handle <- passkeyHandle state user
            r <- Auth.addPasskeyOptions conn (authConfig cfg) handle
            either (respond . authErrResponse) (respond . jsonResponse status200) r
        ("POST", ["api", "v1", "account", "passkeys", "verify"]) -> do
            body <- jsonBody cfg req
            case body of
                Left response -> respond response
                Right v -> do
                    handle <- passkeyHandle state user
                    r <- Auth.verifyAddPasskey conn (authConfig cfg) handle v
                    case r of
                        Left e -> respond (authErrResponse e)
                        Right () -> respond (jsonResponse status200 (object ["ok" .= True]))
        ("PATCH", ["api", "v1", "account", "passkeys", cidTxt]) ->
            case Auth.decodeCredentialId cidTxt of
                Nothing -> respond (jsonError status400 "bad_request" "invalid credential id")
                Just cid -> do
                    body <- jsonBody cfg req
                    case body of
                        Left response -> respond response
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
        -- Admin user management. The guard already restricts this namespace
        -- to admin browser sessions (Authz AdminClass).
        ("GET", ["api", "v1", "admin", "users"]) -> adminListUsers state respond
        ("POST", ["api", "v1", "admin", "users"]) -> adminCreateUser state req respond
        ("PATCH", ["api", "v1", "admin", "users", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid user id")
            Just userId -> adminPatchUser state user userId req respond
        ("POST", ["api", "v1", "admin", "users", idTxt, "password"]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid user id")
            Just userId -> adminResetPassword state userId req respond
        ("DELETE", ["api", "v1", "admin", "users", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid user id")
            Just userId -> adminDeleteUser state user userId req respond
        ("GET", path)
            | not ("api" `elem` path)
            , not ("assets" `elem` path) ->
                indexResponse cfg req respond
        _ -> respond (jsonError status404 "not_found" "No such route")
  where
    cfg = rcConfig rctx
    state = rcState rctx
    user = rcUser rctx
    slot = rcSlot rctx
    ctx = rcAuth rctx

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

-- ---------------------------------------------------------------------------
-- Graph layout and views
-- ---------------------------------------------------------------------------

{- | Everything one boot request reads. Exported so the server tests can check
the boot document without starting Warp.
-}
bootPayloadFor :: Text -> Connection -> IO BootPayload
bootPayloadFor origin conn = do
    page <- listBookmarks conn defaultListQuery
    tags <- allTags conn
    stats <- libraryStats conn
    searches <- listSavedSearches conn
    views <- listViews conn
    pure (BootPayload "0.1.0" origin tags searches page stats views)

{- | @GET /api/v1/graph/layout?preset=...@. The positions are built from the
same graph data the graph endpoint returns and cached per database until the
revision changes, so switching presets after the first load is a map lookup.
-}
graphLayoutHandler :: UserSlot -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
graphLayoutHandler slot conn req respond =
    case layoutPresetFromText (fromMaybe "standard" (param "preset" req)) of
        Nothing ->
            respond (jsonError status400 "bad_request" "preset must be compact, standard, or airy")
        Just preset -> do
            revision <- graphRevision conn
            cached <- withMVar (usLayoutCache slot) $ \cache -> pure (lookupCachedLayout revision preset cache)
            payload <- case cached of
                Just hit -> pure hit
                Nothing -> do
                    graph <- globalGraph conn
                    let built = graphLayoutPayload preset graph
                    modifyMVar_ (usLayoutCache slot) $ \cache ->
                        pure (storeCachedLayout (gdRevision graph) preset built cache)
                    pure built
            respond (jsonResponse status200 payload)

viewsCreateHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
viewsCreateHandler cfg conn req respond = do
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case fromJSON value :: Result ViewInput of
            Error message -> respond (jsonError status400 "bad_request" (T.pack message))
            Success input -> do
                result <- createView conn input
                case result of
                    Left err -> respond (viewErrorResponse err)
                    Right view -> respond (jsonResponse status201 view)

viewsUpdateHandler :: Config -> Connection -> Text -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
viewsUpdateHandler cfg conn viewSlug req respond = do
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case fromJSON value :: Result ViewPatch of
            Error message -> respond (jsonError status400 "bad_request" (T.pack message))
            Success patch -> do
                result <- updateView conn viewSlug patch
                case result of
                    Left err -> respond (viewErrorResponse err)
                    Right view -> respond (jsonResponse status200 view)

viewErrorResponse :: ViewError -> Response
viewErrorResponse err =
    jsonError (mkStatus (viewErrorStatus err) "") (viewErrorCode err) (viewErrorMessage err)

-- ---------------------------------------------------------------------------
-- Webhooks
-- ---------------------------------------------------------------------------

webhookCreateHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
webhookCreateHandler cfg conn req respond = do
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case fromJSON value :: Result WebhookInput of
            Error message -> respond (jsonError status400 "bad_request" (T.pack message))
            Success input -> do
                result <- createWebhook conn input
                case result of
                    Left err -> respond (webhookErrorResponse err)
                    Right (webhook, secret) ->
                        respond (jsonResponse status201 (object ["webhook" .= webhook, "secret" .= secret]))

webhookUpdateHandler :: Config -> Connection -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
webhookUpdateHandler cfg conn webhookId req respond = do
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case fromJSON value :: Result WebhookInput of
            Error message -> respond (jsonError status400 "bad_request" (T.pack message))
            Success input -> do
                result <- updateWebhook conn webhookId input
                case result of
                    Left err -> respond (webhookErrorResponse err)
                    Right webhook -> respond (jsonResponse status200 webhook)

webhookTestHandler ::
    Config ->
    AppState ->
    Connection ->
    Int ->
    (Response -> IO ResponseReceived) ->
    IO ResponseReceived
webhookTestHandler cfg state conn webhookId respond = do
    result <- testWebhook (defaultWebhookWorkerConfig cfg (asManager state)) conn webhookId
    case result of
        Left err -> respond (webhookErrorResponse err)
        Right (ok, status, message) ->
            respond
                ( jsonResponse
                    status200
                    (object ["ok" .= ok, "status" .= status, "error" .= message])
                )

webhookErrorResponse :: WebhookError -> Response
webhookErrorResponse err =
    jsonError (mkStatus (webhookErrorStatus err) "") (webhookErrorCode err) (webhookErrorMessage err)

{- | Resolve the request principal, then run the handler on the right
connection: reads use the user database's read pool, writes use its one writer.
Authentication itself runs on the writer because a session lookup records
@last_seen_at@.
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
        jsonError status403 "session_required" "this route requires a browser session"

    bearerAuth rawToken
        | klass `elem` [Authz.SessionClass, Authz.AdminClass] = pure (Left sessionRequired)
        | klass == Authz.DeniedClass = pure (Left (jsonError status404 "not_found" "No such route"))
        | otherwise = do
            resolved <- resolveApiToken state rawToken
            case resolved of
                Left message -> pure (Left (jsonError status503 "user_limit" message))
                Right Nothing -> pure (Left invalidBearerToken)
                Right (Just (user, slot, bare)) -> do
                    mtoken <- withDb slot $ \conn -> authenticateToken conn bare
                    case mtoken of
                        Nothing -> pure (Left invalidBearerToken)
                        Just token
                            | not (Authz.tokenAllows (mapMaybe Authz.scopeFromText (tokenScopes token)) method path) ->
                                pure (Left (jsonError status403 "token_scope" "this token does not allow the request"))
                            | not (requestOriginAllowed cfg req) ->
                                pure (Left (jsonError status403 "origin" "origin is not allowed"))
                            | otherwise -> pure (Right (user, slot, BearerToken token))

    cookieAuth =
        case cookieValue req Auth.sessionCookieName of
            Nothing -> pure (Left (unauthorized req))
            Just wire -> do
                resolved <- resolveSession state wire
                pure $ case resolved of
                    Left message -> Left (jsonError status503 "user_limit" message)
                    Right Nothing -> Left (unauthorized req)
                    Right (Just (user, slot, sess))
                        | not (sessionScopeAllows (cuRole user) (Auth.sessScope sess) method path) ->
                            Left (jsonError status403 "session_scope" "this session may not use this route")
                        | not (requestOriginAllowed cfg req) ->
                            Left (jsonError status403 "origin" "origin is not allowed")
                        | not (csrfOk req sess) ->
                            Left (jsonError status403 "csrf" "missing or invalid CSRF token")
                        | otherwise -> Right (user, slot, CookieSession sess)

invalidBearerToken :: Response
invalidBearerToken = jsonError status401 "unauthenticated" "invalid bearer token"

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

{- | The per-user WebAuthn handle. It is generated with the control row; a
legacy row without one gets a fresh handle stored before the ceremony, so two
accounts on one server never share a user handle.
-}
passkeyHandle :: AppState -> Control.ControlUser -> IO BS.ByteString
passkeyHandle state user = do
    ensured <- withControl state $ \control -> Control.ensureCredentialHandle control user
    pure (fromMaybe "\x01" (cuCredentialHandle ensured))

bearerToken :: Request -> Maybe Text
bearerToken req =
    case lookup hAuthorization (requestHeaders req) of
        Nothing -> Nothing
        Just raw ->
            let value = TE.decodeUtf8 raw
             in if "Bearer " `T.isPrefixOf` value then Just (T.drop 7 value) else Nothing

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

cookieValue :: Request -> Text -> Maybe Text
cookieValue req name =
    case lookup hCookie (requestHeaders req) of
        Nothing -> Nothing
        Just rawCookie -> do
            rawValue <- lookup (TE.encodeUtf8 name) (Cookie.parseCookies rawCookie)
            pure (TE.decodeUtf8 rawValue)

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

health :: AppState -> (Response -> IO ResponseReceived) -> IO ResponseReceived
health state respond = do
    result <- try (withControl state Db.ping) :: IO (Either SomeException Bool)
    case result of
        Right True -> respond (jsonResponse status200 (object ["status" .= ("ok" :: Text), "version" .= ("0.1.0" :: Text)]))
        _ -> respond (jsonError status503 "unavailable" "database is unavailable")

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

addBookmark :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
addBookmark cfg conn req respond = do
    body <- jsonValue cfg req
    case body of
        Left response -> respond response
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

highlightCreateHandler :: Config -> Connection -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
highlightCreateHandler cfg conn bid req respond = do
    body <- jsonValue cfg req
    case body of
        Left response -> respond response
        Right (HighlightCreateBody quote prefix suffix start end note color) -> do
            result <- createHighlight conn bid quote (fromMaybe "" prefix) (fromMaybe "" suffix) start end (fromMaybe "" note) (fromMaybe "yellow" color)
            case result of
                Left err -> respond (jsonError status400 "bad_request" err)
                Right highlight -> respond (jsonResponse status201 highlight)

data HighlightPatchBody = HighlightPatchBody (Maybe Text) (Maybe Text)

instance FromJSON HighlightPatchBody where
    parseJSON = withObject "HighlightPatchBody" $ \o ->
        HighlightPatchBody <$> o .:? "note" <*> o .:? "color"

highlightUpdateHandler :: Config -> Connection -> Int -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
highlightUpdateHandler cfg conn bid hid req respond = do
    body <- jsonValue cfg req
    case body of
        Left response -> respond response
        Right (HighlightPatchBody note color) -> do
            ok <- updateHighlight conn bid hid note color
            if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonError status404 "not_found" "highlight not found")

data ShareCreateBody = ShareCreateBody Text Int (Maybe Bool) (Maybe Int)

instance FromJSON ShareCreateBody where
    parseJSON = withObject "ShareCreateBody" $ \o ->
        ShareCreateBody <$> o .: "scope" <*> o .: "target_id" <*> o .:? "include_note" <*> o .:? "expires_in_days"

shareCreateHandler :: Config -> Control.ControlUser -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
shareCreateHandler cfg user conn req respond = do
    body <- jsonValue cfg req
    case body of
        Left response -> respond response
        Right (ShareCreateBody scope targetId includeNote expires) -> do
            let days = fromMaybe (cfgShareTtlDays cfg) expires
            result <- createShare conn scope targetId (fromMaybe False includeNote) days
            case result of
                Left err -> respond (jsonError status400 "bad_request" err)
                Right (shareId, raw) ->
                    respond (jsonResponse status201 (object ["id" .= shareId, "url" .= (cfgPublicOrigin cfg <> "/s/" <> wireShareToken user raw)]))

{- | A share link is public but still resolves to one account: the token prefix
names the database to read. A revoked, expired, or wrong-database token gets
the same unavailable page family as before.
-}
publicShareHandler :: AppState -> Text -> (Response -> IO ResponseReceived) -> IO ResponseReceived
publicShareHandler state token respond = do
    let isFeed = T.isSuffixOf ".xml" token
        wire = if isFeed then T.dropEnd 4 token else token
    resolved <- resolveShareOwner state wire
    case resolved of
        Left _ -> respond shareGone
        Right Nothing -> respond shareGone
        Right (Just (_, slot, bare)) -> withDb slot $ \conn -> do
            shareState <- resolveShareState conn bare
            case shareState of
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
    shareGone = shareHeaders (htmlResponseAt status404 (shareUnavailablePage ShareInvalid))

{- | Serve a locally captured snapshot. The path must be inside the account's
own snapshots directory; the old global @EZA_SNAPSHOT_DIR@ is accepted as a
second root so snapshots made before the per-user layout keep working.
-}
snapshotHandler :: Config -> UserSlot -> Connection -> Int -> (Response -> IO ResponseReceived) -> IO ResponseReceived
snapshotHandler cfg slot conn bid respond = do
    bookmark <- getBookmark conn bid
    case bookmark of
        Just detail
            | bdSnapshotKind detail /= "file" || T.null (bdSnapshotPath detail) ->
                respond (jsonError status404 "not_found" "no local snapshot for this bookmark")
            | otherwise -> do
                let rawPath = T.unpack (bdSnapshotPath detail)
                resolvedResult <- try (canonicalizePath rawPath) :: IO (Either SomeException FilePath)
                roots <- mapM canonicalRoot [usSnapshotDir slot, cfgSnapshotDir cfg]
                let resolved = either (const rawPath) id resolvedResult
                exists <- doesFileExist resolved
                if exists && any (isUnder resolved) (catMaybes roots)
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
  where
    canonicalRoot root = do
        exists <- doesDirectoryExist root
        if not exists
            then pure Nothing
            else do
                result <- try (canonicalizePath root) :: IO (Either SomeException FilePath)
                pure (either (const Nothing) Just result)
    isUnder path root = path == root || (addTrailingPathSeparator root) `isPrefixOf` path

data BulkBody = BulkBody Text [Int] (Maybe [Text]) (Maybe Bool)

instance FromJSON BulkBody where
    parseJSON = withObject "BulkBody" $ \o ->
        BulkBody <$> o .: "action" <*> o .:? "ids" .!= [] <*> o .:? "tags" <*> o .:? "confirm"

bulkHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
bulkHandler cfg conn req respond = do
    body <- jsonValue cfg req
    case body of
        Left response -> respond response
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

quickSaveHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
quickSaveHandler cfg conn req respond = do
    body <- jsonValue cfg req
    case body of
        Left response -> respond response
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

markAbove :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
markAbove cfg conn req respond = do
    body <- jsonValue cfg req
    case body of
        Left response -> respond response
        Right (MarkAboveBody aid) -> do
            n <- markAllAbove conn aid
            respond (jsonResponse status200 (object ["updated" .= n]))

data PatchBody = PatchBody (Maybe Text) (Maybe Text) (Maybe Bool) (Maybe [Text])

instance FromJSON PatchBody where
    parseJSON = withObject "PatchBody" $ \o ->
        PatchBody <$> o .:? "title" <*> o .:? "note_body" <*> o .:? "is_read" <*> o .:? "tags"

patchBookmark :: Config -> Connection -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
patchBookmark cfg conn bid req respond = do
    body <- jsonValue cfg req
    case body of
        Left response -> respond response
        Right (PatchBody mTitle mNote mRead mTags)
            | maybe False (T.null . T.strip) mTitle -> respond (jsonError status400 "bad_request" "title must not be empty")
            | all (== Nothing) [fmap (const ()) mTitle, fmap (const ()) mNote, fmap (const ()) mRead, fmap (const ()) mTags] ->
                respond (jsonError status400 "bad_request" "empty patch")
            | otherwise -> do
                ok <- updateBookmark conn bid mTitle mNote mRead mTags
                if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonError status404 "not_found" "bookmark not found")

importHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
importHandler cfg conn req respond =
    case lookup hContentType (requestHeaders req) of
        Just contentType | "application/json" `BS.isPrefixOf` contentType -> importJsonBody
        _ -> importMultipart
  where
    importLimit = fromIntegral (cfgImportMaxBytes cfg) :: Int64
    options =
        setMaxRequestNumFiles 1
            . setMaxRequestParmsSize (cfgImportMaxBytes cfg)
            . setMaxRequestFilesSize importLimit
            . setMaxRequestFileSize importLimit
            $ defaultParseRequestBodyOptions

    -- A JSON body is an eza export (the browser-clipper upload path and the
    -- documented portable backup). It answers with the Netscape report shape so
    -- the account import panel can show one result format for both sources.
    importJsonBody = do
        body <- jsonBody cfg req
        case body of
            Left response -> respond response
            Right value -> do
                result <- importJson conn value
                case result of
                    Left message -> respond (jsonError status400 "bad_request" message)
                    Right report ->
                        respond
                            ( jsonResponse
                                status200
                                ( object
                                    [ "format" .= ("eza-json" :: Text)
                                    , "json_report" .= report
                                    , "imported" .= jrBookmarks report
                                    , "inserted" .= jrBookmarks report
                                    , "found" .= jrBookmarks report
                                    , "existing" .= (0 :: Int)
                                    , "highlights" .= jrHighlights report
                                    , "captures" .= jrCaptures report
                                    , "views" .= jrViews report
                                    , "clip_templates" .= jrTemplates report
                                    , "skipped" .= jrSkipped report
                                    ]
                                )
                            )

    importMultipart = do
        parsed <- try (parseRequestBodyEx options lbsBackEnd req) :: IO (Either SomeException ([Param], [File LBS.ByteString]))
        case parsed of
            Left _ ->
                -- The wai parser throws when a file or parameter grows past the
                -- configured multipart limits; report it as the same 413 the
                -- size middleware uses rather than a 500.
                respond (requestTooLargeResponse (fromIntegral (cfgImportMaxBytes cfg)))
            Right (_, files) -> case lookup "file" files of
                Nothing -> respond (jsonError status400 "bad_request" "multipart field \"file\" is required")
                Just fileInfo -> do
                    let raw = LBS.toStrict (fileContent fileInfo)
                        -- The account panel uploads .html and .json files under
                        -- the same multipart flow; sniff the JSON format rather
                        -- than relying on the browser's content type.
                        asJson = eitherDecodeStrict' raw :: Either String Value
                    case asJson of
                        Right value | isEzaJsonExport value -> do
                            result <- importJson conn value
                            case result of
                                Left message -> respond (jsonError status400 "bad_request" message)
                                Right report ->
                                    respond
                                        ( jsonResponse
                                            status200
                                            ( object
                                                [ "format" .= ("eza-json" :: Text)
                                                , "json_report" .= report
                                                , "imported" .= jrBookmarks report
                                                , "inserted" .= jrBookmarks report
                                                , "found" .= jrBookmarks report
                                                , "existing" .= (0 :: Int)
                                                , "highlights" .= jrHighlights report
                                                , "captures" .= jrCaptures report
                                                , "views" .= jrViews report
                                                , "clip_templates" .= jrTemplates report
                                                , "skipped" .= jrSkipped report
                                                ]
                                            )
                                        )
                        _ -> do
                            let parsedBookmarks = parseNetscape defaultImportOptions raw
                            report <- importParsed conn defaultImportOptions parsedBookmarks
                            respond (jsonResponse status200 report)

-- | True when the decoded document announces the eza JSON export format.
isEzaJsonExport :: Value -> Bool
isEzaJsonExport (Object o) = case KeyMap.lookup "format" o of
    Just (String "eza-json") -> True
    _ -> False
isEzaJsonExport _ = False

{- | Read the request body under the general per-request cap. The size-limit
middleware rejects a declared or chunked oversize body before the handler, but
this is the in-handler backstop: no handler ever builds an unbounded lazy
bytestring. Returns a ready 413 in the shared JSON error shape.
-}
readBodyBounded :: Config -> Request -> IO (Either Response LBS.ByteString)
readBodyBounded cfg req = do
    body <- readBodyLimited (cfgMaxBodyBytes cfg) req
    pure $ case body of
        Left () -> Left (requestTooLargeResponse (fromIntegral (cfgMaxBodyBytes cfg)))
        Right raw -> Right raw

{- | Decode a bounded JSON body. A body over the cap is a ready-made 413; a
parse failure keeps the existing generic 400 shape.
-}
jsonBody :: Config -> Request -> IO (Either Response Value)
jsonBody cfg req = do
    body <- readBodyBounded cfg req
    pure $ case body of
        Left response -> Left response
        Right raw -> case eitherDecode raw of
            Left err -> Left (jsonError status400 "bad_request" (T.pack err))
            Right value -> Right value

-- | Decode a bounded JSON body as one typed value.
jsonValue :: (FromJSON a) => Config -> Request -> IO (Either Response a)
jsonValue cfg req = do
    body <- jsonBody cfg req
    pure $ case body of
        Left response -> Left response
        Right value -> case fromJSON value of
            Error err -> Left (jsonError status400 "bad_request" (T.pack err))
            Success parsed -> Right parsed

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
-- Admin API
-- ---------------------------------------------------------------------------

adminErrorResponse :: Admin.AdminError -> Response
adminErrorResponse err =
    jsonError (mkStatus (Admin.adminErrorStatus err) "") (Admin.adminErrorCode err) (Admin.adminErrorMessage err)

adminListUsers :: AppState -> (Response -> IO ResponseReceived) -> IO ResponseReceived
adminListUsers state respond = do
    users <- withControl state Control.listUsers
    respond (jsonResponse status200 (object ["users" .= map Admin.controlUserView users]))

adminCreateUser :: AppState -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
adminCreateUser state req respond = do
    let cfg = asConfig state
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case fromJSON value :: Result UserCreateInput of
            Error message -> respond (jsonError status400 "bad_request" (T.pack message))
            Success input -> do
                created <-
                    withControl state $ \control ->
                        Admin.createUserAccount (asConfig state) control (uciUsername input) (uciRole input) (uciPassword input)
                case created of
                    Left err -> respond (adminErrorResponse err)
                    Right (user, codes) ->
                        respond (jsonResponse status201 (UserCreateResult (Admin.controlUserView user) codes))

adminPatchUser ::
    AppState ->
    Control.ControlUser ->
    Int ->
    Request ->
    (Response -> IO ResponseReceived) ->
    IO ResponseReceived
adminPatchUser state admin targetId req respond = do
    let cfg = asConfig state
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case parseMaybeObj value of
            Nothing -> respond (jsonError status400 "bad_request" "invalid body")
            Just object' -> do
                let wantedEnabled = parseMaybe (.: "enabled") object' :: Maybe Bool
                    wantedRole = parseMaybe (.: "role") object' :: Maybe UserRole
                case (wantedEnabled, wantedRole) of
                    (Nothing, Nothing) ->
                        respond (jsonError status400 "bad_request" "enabled or role is required")
                    _
                        | wantedEnabled == Just False && targetId == cuId admin ->
                            respond (adminErrorResponse Admin.AdminSelfDisable)
                    _ -> do
                        roleResult <-
                            case wantedRole of
                                Nothing -> pure (Right Nothing)
                                Just role -> do
                                    applied <- withControl state $ \control -> Admin.setUserRole control targetId role
                                    pure (fmap Just applied)
                        case roleResult of
                            Left err -> respond (adminErrorResponse err)
                            Right _ -> do
                                enabledResult <-
                                    case wantedEnabled of
                                        Nothing -> pure (Right Nothing)
                                        Just enabled -> do
                                            applied <-
                                                withControl state $ \control ->
                                                    Admin.setUserEnabled (asConfig state) control targetId enabled
                                            pure (fmap Just applied)
                                case enabledResult of
                                    Left err -> respond (adminErrorResponse err)
                                    Right _ -> do
                                        updated <- withControl state $ \control -> Control.lookupUserById control targetId
                                        case updated of
                                            Nothing -> respond (adminErrorResponse Admin.AdminNotFound)
                                            Just user -> respond (jsonResponse status200 (Admin.controlUserView user))

adminResetPassword :: AppState -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
adminResetPassword state targetId req respond = do
    let cfg = asConfig state
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case parseMaybeObj value of
            Nothing -> respond (jsonError status400 "bad_request" "invalid body")
            Just object' -> case parseMaybe (.: "password") object' of
                Nothing -> respond (jsonError status400 "bad_request" "password is required")
                Just password -> do
                    result <-
                        withControl state $ \control ->
                            Admin.resetUserPassword (asConfig state) control targetId password
                    case result of
                        Left err -> respond (adminErrorResponse err)
                        Right () -> respond (jsonResponse status200 (object ["ok" .= True]))

{- | Delete one account. The control row always goes; the library and its
snapshots go only when @delete_db@ is true, because they are the user's
content. Refuses self-delete and the last enabled admin.
-}
adminDeleteUser :: AppState -> Control.ControlUser -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
adminDeleteUser state admin targetId req respond = do
    body <- jsonBody (asConfig state) req
    case body of
        Left response -> respond response
        Right value -> case parseMaybeObj value of
            Nothing -> respond (jsonError status400 "bad_request" "invalid body")
            Just o -> do
                let confirmed = parseMaybe (.: "confirm") o :: Maybe Bool
                    deleteDb = fromMaybe False (parseMaybe (.: "delete_db") o :: Maybe Bool)
                if confirmed /= Just True
                    then respond (jsonError status400 "bad_request" "confirm must be true")
                    else
                        if targetId == Control.cuId admin
                            then respond (adminErrorResponse Admin.AdminSelfDisable)
                            else do
                                result <-
                                    withControl state $ \control ->
                                        Admin.deleteUserAccount (asConfig state) control targetId deleteDb
                                case result of
                                    Left err -> respond (adminErrorResponse err)
                                    Right () -> respond (jsonResponse status200 (object ["ok" .= True]))

-- ---------------------------------------------------------------------------
-- Account handlers
-- ---------------------------------------------------------------------------

{- | The account document. @GET /api/v1/account@ and the two-factor toggle
return the same shape, so the account page can replace its copy after a
change without a second request.
-}
accountPayload :: Connection -> AuthContext -> Control.UserRole -> IO Value
accountPayload conn ctx role = do
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
            , "role" .= role
            , "has_password" .= Auth.accountHasPassword account
            , "require_passkey" .= Auth.acctRequirePasskey account
            , "account_configured" .= configured
            ]
        )

{- | Turn optional passkey two-factor on or off. Both directions need the
current password, and turning it on needs an already-registered passkey.
-}
accountTwoFactorHandler :: Config -> Connection -> AuthContext -> Control.UserRole -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
accountTwoFactorHandler cfg conn ctx role req respond = do
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
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
                            payload <- accountPayload conn ctx role
                            respond (jsonResponse status200 payload)

{- | Change the account password. A current password is required once one
exists; the session vouches for the first password on a legacy passkey-only
account. Other browser sessions are revoked so a stolen session does not keep
the old access.
-}
accountPasswordHandler :: Config -> Connection -> AuthContext -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
accountPasswordHandler cfg conn ctx req respond = do
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
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

{- | Rename the signed-in account. The control row is the login lookup source,
so it changes with the user database account name.
-}
accountUsernameHandler :: Config -> AppState -> Control.ControlUser -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
accountUsernameHandler cfg state user conn req respond = do
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
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
                                    renamed <- withControl state $ \control -> Control.setUsername control (cuId user) username
                                    case renamed of
                                        Left Control.ControlDuplicateUsername ->
                                            respond (jsonError status409 "username_taken" "that username is already in use")
                                        Left err -> respond (jsonError status500 "control" (T.pack (show err)))
                                        Right () -> do
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

{- | Resolve one decoded asset path against the static root. Returns the
canonical file path only when every segment is a plain name and the canonical
candidate stays inside the canonical root.

WAI splits the raw path on @/@ and percent-decodes each segment afterwards, so
@..%2f..%2fetc%2fpasswd@ arrives as a single segment whose text contains
slashes. Comparing a decoded segment with @".."@ alone is therefore not enough:
any segment containing a path separator (or @.@/@..@, empty, or NUL) is
rejected, and the surviving candidate is canonicalized and prefix-checked like
the snapshot route does. This is also what stops @%2e%2e%2f@ and a backslash
form.
-}
resolveStaticPath :: FilePath -> [Text] -> IO (Maybe FilePath)
resolveStaticPath root rest
    | invalidStaticSegments rest = pure Nothing
    | otherwise = do
        rootExists <- doesDirectoryExist root
        if not rootExists
            then pure Nothing
            else do
                rootResult <- try (canonicalizePath root) :: IO (Either SomeException FilePath)
                case rootResult of
                    Left (_ :: SomeException) -> pure Nothing
                    Right canonicalRoot -> do
                        let rel = foldr ((</>) . T.unpack) "" rest
                            candidate = canonicalRoot </> rel
                        exists <- doesFileExist candidate
                        if not exists
                            then pure Nothing
                            else do
                                resolvedResult <- try (canonicalizePath candidate) :: IO (Either SomeException FilePath)
                                pure $ case resolvedResult of
                                    Left (_ :: SomeException) -> Nothing
                                    Right resolved
                                        | resolved /= canonicalRoot
                                        , isUnder resolved canonicalRoot ->
                                            Just resolved
                                        | otherwise -> Nothing
  where
    isUnder path canonicalRoot =
        path == canonicalRoot
            || addTrailingPathSeparator canonicalRoot `isPrefixOf` path

{- | A decoded path segment is only a plain file name: no empty segment, no
@.@/@..@, no separators of either kind, and no NUL. The encoded-slash
traversal arrives here as one segment containing @/@, so it is rejected before
any filesystem call.
-}
invalidStaticSegments :: [Text] -> Bool
invalidStaticSegments = any unsafeStaticSegment
  where
    unsafeStaticSegment segment =
        T.null segment
            || segment == "."
            || segment == ".."
            || T.any (== '/') segment
            || T.any (== '\\') segment
            || T.any (== '\NUL') segment

serveAsset :: Config -> [Text] -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
serveAsset cfg rest req respond = case cfgStaticDir cfg of
    Nothing -> respond (jsonError status404 "not_found" "static assets are not configured")
    Just root -> do
        if invalidStaticSegments rest
            then respond (jsonError status400 "bad_request" "invalid asset path")
            else do
                resolved <- resolveStaticPath root rest
                case resolved of
                    Nothing -> respond (jsonError status404 "not_found" "asset not found")
                    Just path -> do
                        let rel = foldr ((</>) . T.unpack) "" rest
                        sendFile req "no-cache" [(hContentType, mimeFor rel)] path respond

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
