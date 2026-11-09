{-# LANGUAGE OverloadedStrings #-}

-- | Environment-driven configuration, read once at startup.
module Eza.Config (
    Config (..),
    loadConfig,
    originHost,
    bindHost,
    bindPort,
) where

import Data.Char (toLower)
import Data.List (isInfixOf, nub)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word32)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))
import Text.Read (readMaybe)

import Eza.Password (PasswordParams (..), defaultPasswordParams)

data Config = Config
    { cfgDataDir :: FilePath
    -- ^ Root data directory.
    , cfgControlDbPath :: FilePath
    -- ^ Control database: accounts and their library database paths.
    , cfgUsersDir :: FilePath
    -- ^ Per-user library directories (@users/<id>/eza.db@).
    , cfgMaxUsers :: Int
    -- ^ Upper bound on user database paths this process will open.
    , cfgDbPath :: FilePath
    {- ^ Legacy bootstrap database. Only read at startup to register an existing
    single-user install; request paths never come from here.
    -}
    , cfgBind :: String
    , cfgPublicOrigin :: Text
    , cfgRpId :: Text
    , cfgRpName :: Text
    , cfgAllowedOrigins :: [Text]
    , cfgClipOrigins :: [Text]
    , cfgSidecarCmd :: Maybe String
    , cfgSessionTtlSeconds :: Int
    , cfgSecureCookies :: Bool
    , cfgStaticDir :: Maybe FilePath
    , cfgSnapshotDir :: FilePath
    , cfgBackupDir :: FilePath
    , cfgBackupKeepDays :: Int
    , cfgMonolith :: String
    , cfgSnapshotMaxBytes :: Int
    , cfgLogLevel :: String
    , cfgAllowPrivateFetch :: Bool
    , cfgEnrichWorkers :: Int
    , cfgFetchTimeoutMs :: Int
    , cfgFaviconMaxBytes :: Int
    , cfgFaviconTtlDays :: Int
    , cfgFaviconBackfill :: Bool
    , cfgShareTtlDays :: Int
    , cfgAiProvider :: String
    , cfgOllamaBaseUrl :: String
    , cfgAiModel :: String
    , cfgArgon2 :: PasswordParams
    , cfgLoginMaxAttempts :: Int
    , cfgLoginLockoutSeconds :: Int
    , cfgAuthBodyLimitBytes :: Int
    , cfgMaxBodyBytes :: Int
    , cfgImportMaxBytes :: Int
    }
    deriving (Show)

loadConfig :: IO Config
loadConfig = do
    dataDir <- fromMaybe "./data" <$> lookupEnv "EZA_DATA_DIR"
    createDirectoryIfMissing True dataDir
    dbPath <- fromMaybe (dataDir </> "eza.db") <$> lookupEnv "EZA_DB"
    createDirectoryIfMissing True (takeDirectory dbPath)
    controlDb <- fromMaybe (dataDir </> "control.db") <$> lookupEnv "EZA_CONTROL_DB"
    createDirectoryIfMissing True (takeDirectory controlDb)
    usersDir <- fromMaybe (dataDir </> "users") <$> lookupEnv "EZA_USERS_DIR"
    createDirectoryIfMissing True usersDir
    maxUsers <- readIntEnv "EZA_MAX_USERS" 32
    bind <- fromMaybe "127.0.0.1:8080" <$> lookupEnv "EZA_BIND"
    originRaw <- fromMaybe "http://localhost:8080" <$> lookupEnv "PUBLIC_ORIGIN"
    let origin = T.pack (dropTrailingSlash originRaw)
        host = originHost origin
        rpIdDefault = maybe host id (T.stripPrefix "www." host)
    rpId <- maybe rpIdDefault T.pack <$> lookupEnv "EZA_RP_ID"
    rpName <- maybe "eza" T.pack <$> lookupEnv "EZA_RP_NAME"
    allowedRaw <- lookupEnv "EZA_ALLOWED_ORIGINS"
    let extras = case allowedRaw of
            Nothing -> []
            Just raw -> map T.pack (filter (not . null) (splitOn ',' raw))
        -- The public origin is always allowed; the environment can add origins
        -- (for a reverse proxy on another host) but never replace it.
        allowed = nub (origin : extras)
    clipRaw <- lookupEnv "EZA_CLIP_ORIGINS"
    let clipOrigins = case clipRaw of
            Nothing -> []
            Just raw -> map T.pack (filter (not . null) (splitOn ',' raw))
    sidecarCmd <- lookupEnv "EZA_DEFUDDLE_CMD"
    ttl <- readIntEnv "EZA_SESSION_TTL_SECONDS" (30 * 24 * 3600)
    secureRaw <- lookupEnv "EZA_SECURE_COOKIES"
    let secure = case secureRaw of
            Just "1" -> True
            Just "true" -> True
            Just "0" -> False
            Just "false" -> False
            _ -> "https://" `T.isPrefixOf` T.toLower origin
    staticDir <- lookupEnv "EZA_STATIC_DIR"
    snapshotDir <- fromMaybe (dataDir </> "snapshots") <$> lookupEnv "EZA_SNAPSHOT_DIR"
    createDirectoryIfMissing True snapshotDir
    backupDir <- fromMaybe (dataDir </> "backups") <$> lookupEnv "EZA_BACKUP_DIR"
    backupKeepDays <- readIntEnv "EZA_BACKUP_KEEP_DAYS" 14
    monolith <- fromMaybe "monolith" <$> lookupEnv "EZA_MONOLITH"
    snapshotMax <- readIntEnv "EZA_SNAPSHOT_MAX_BYTES" (50 * 1024 * 1024)
    logLevel <- fromMaybe "info" <$> lookupEnv "EZA_LOG_LEVEL"
    allowPrivate <- readBoolEnv "EZA_ALLOW_PRIVATE_FETCH" False
    enrichWorkers <- readIntEnv "EZA_ENRICH_WORKERS" 2
    fetchTimeout <- readIntEnv "EZA_FETCH_TIMEOUT_MS" 8000
    faviconMax <- readIntEnv "EZA_FAVICON_MAX_BYTES" 65536
    faviconTtl <- readIntEnv "EZA_FAVICON_TTL_DAYS" 90
    faviconBackfill <- readBoolEnv "EZA_FAVICON_BACKFILL" True
    shareTtl <- readIntEnv "EZA_SHARE_TTL_DAYS" 7
    aiProvider <- fromMaybe "none" <$> lookupEnv "EZA_AI_PROVIDER"
    ollamaUrl <- fromMaybe "http://127.0.0.1:11434" <$> lookupEnv "EZA_OLLAMA_BASE_URL"
    aiModel <- fromMaybe "" <$> lookupEnv "EZA_AI_MODEL"
    argonMemory <- readIntEnv "EZA_ARGON2_MEMORY_KIB" (fromIntegral (ppMemoryKiB defaultPasswordParams))
    argonIterations <- readIntEnv "EZA_ARGON2_ITERATIONS" (fromIntegral (ppIterations defaultPasswordParams))
    argonParallelism <- readIntEnv "EZA_ARGON2_PARALLELISM" (fromIntegral (ppParallelism defaultPasswordParams))
    let argon2Params =
            let par = clampWord32 1 16 argonParallelism
                -- Argon2 requires memory >= 8 * parallelism.
                mem = max (8 * par) (clampWord32 8 maxBound argonMemory)
             in PasswordParams mem (clampWord32 1 maxBound argonIterations) par
    loginMaxAttempts <- readIntEnv "EZA_LOGIN_MAX_ATTEMPTS" 5
    loginLockout <- readIntEnv "EZA_LOGIN_LOCKOUT_SECONDS" 900
    authBodyLimit <- readIntEnv "EZA_AUTH_BODY_LIMIT_BYTES" 8192
    maxBody <- readIntEnv "EZA_MAX_BODY_BYTES" (8 * 1024 * 1024)
    importMax <- readIntEnv "EZA_IMPORT_MAX_BYTES" (32 * 1024 * 1024)
    pure
        Config
            { cfgDataDir = dataDir
            , cfgDbPath = dbPath
            , cfgControlDbPath = controlDb
            , cfgUsersDir = usersDir
            , cfgMaxUsers = max 1 maxUsers
            , cfgBind = bind
            , cfgPublicOrigin = origin
            , cfgRpId = rpId
            , cfgRpName = rpName
            , cfgAllowedOrigins = allowed
            , cfgClipOrigins = clipOrigins
            , cfgSidecarCmd = sidecarCmd >>= nonEmpty
            , cfgSessionTtlSeconds = ttl
            , cfgSecureCookies = secure
            , cfgStaticDir = staticDir
            , cfgSnapshotDir = snapshotDir
            , cfgBackupDir = backupDir
            , cfgBackupKeepDays = max 1 backupKeepDays
            , cfgMonolith = monolith
            , cfgSnapshotMaxBytes = max 4096 snapshotMax
            , cfgLogLevel = logLevel
            , cfgAllowPrivateFetch = allowPrivate
            , cfgEnrichWorkers = max 0 enrichWorkers
            , cfgFetchTimeoutMs = max 1000 fetchTimeout
            , cfgFaviconMaxBytes = max 4096 faviconMax
            , cfgFaviconTtlDays = max 1 faviconTtl
            , cfgFaviconBackfill = faviconBackfill
            , cfgShareTtlDays = max 1 shareTtl
            , cfgAiProvider = aiProvider
            , cfgOllamaBaseUrl = ollamaUrl
            , cfgAiModel = aiModel
            , cfgArgon2 = argon2Params
            , cfgLoginMaxAttempts = max 1 loginMaxAttempts
            , cfgLoginLockoutSeconds = max 1 loginLockout
            , cfgAuthBodyLimitBytes = max 1024 authBodyLimit
            , cfgMaxBodyBytes = max 1024 maxBody
            , cfgImportMaxBytes = max 1024 importMax
            }

originHost :: Text -> Text
originHost origin =
    let afterScheme = case T.breakOn "://" origin of
            (_, rest) | T.null rest -> origin
            (_, rest) -> T.drop 3 rest
        authority = T.takeWhile (\c -> c /= '/' && c /= '?' && c /= '#') afterScheme
        noUser = case T.breakOnEnd "@" authority of
            ("", _) -> authority
            (_, h) -> h
        host = T.takeWhile (\c -> c /= ':') noUser
     in T.toLower (T.dropWhileEnd (== '.') host)

bindHost :: String -> String
bindHost b = case break (== ':') b of
    (h, _) -> if null h then "127.0.0.1" else h

bindPort :: String -> Int
bindPort b = case break (== ':') b of
    (_, ':' : p) -> fromMaybe 8080 (readMaybe p)
    _ -> 8080

readIntEnv :: String -> Int -> IO Int
readIntEnv name fallback = do
    raw <- lookupEnv name
    pure $ case raw >>= readMaybe of
        Just n -> n
        Nothing -> fallback

{- | Clamp an environment integer into a Word32 range without wrapping on
negative input.
-}
clampWord32 :: Word32 -> Word32 -> Int -> Word32
clampWord32 low high raw = max low (min high (fromIntegral (max 1 raw)))

readBoolEnv :: String -> Bool -> IO Bool
readBoolEnv name fallback = do
    raw <- lookupEnv name
    pure $ case fmap (map toLower) raw of
        Just "1" -> True
        Just "true" -> True
        Just "yes" -> True
        Just "0" -> False
        Just "false" -> False
        Just "no" -> False
        _ -> fallback

splitOn :: Char -> String -> [String]
splitOn sep s = case break (== sep) s of
    (a, []) -> [a]
    (a, _ : rest) -> a : splitOn sep rest

dropTrailingSlash :: String -> String
dropTrailingSlash s
    | not (null s) && last s == '/' = init s
    | otherwise = s

_unused :: [String] -> Bool
_unused xs = any (isInfixOf ",,") xs || null (mapMaybe (\x -> if null x then Nothing else Just x) xs)

_lower :: Char -> Char
_lower = toLower

nonEmpty :: String -> Maybe String
nonEmpty value = if null value then Nothing else Just value
