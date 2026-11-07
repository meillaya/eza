{-# LANGUAGE OverloadedStrings #-}

-- | Environment-driven configuration, read once at startup.
module Eza.Config
  ( Config (..)
  , loadConfig
  , originHost
  , bindHost
  , bindPort
  ) where

import Data.Char (toLower)
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeDirectory)
import Text.Read (readMaybe)

data Config = Config
  { cfgDataDir :: FilePath
  , cfgDbPath :: FilePath
  , cfgBind :: String
  , cfgPublicOrigin :: Text
  , cfgRpId :: Text
  , cfgRpName :: Text
  , cfgAllowedOrigins :: [Text]
  , cfgSessionTtlSeconds :: Int
  , cfgSecureCookies :: Bool
  , cfgStaticDir :: Maybe FilePath
  , cfgSnapshotDir :: FilePath
  , cfgBackupDir :: FilePath
  , cfgMonolith :: String
  , cfgLogLevel :: String
  , cfgAllowPrivateFetch :: Bool
  }
  deriving (Show)

loadConfig :: IO Config
loadConfig = do
  dataDir <- fromMaybe "./data" <$> lookupEnv "EZA_DATA_DIR"
  createDirectoryIfMissing True dataDir
  dbPath <- fromMaybe (dataDir </> "eza.db") <$> lookupEnv "EZA_DB"
  createDirectoryIfMissing True (takeDirectory dbPath)
  bind <- fromMaybe "127.0.0.1:8080" <$> lookupEnv "EZA_BIND"
  originRaw <- fromMaybe "http://localhost:8080" <$> lookupEnv "PUBLIC_ORIGIN"
  let origin = T.pack (dropTrailingSlash originRaw)
      host = originHost origin
      rpIdDefault = maybe host id (T.stripPrefix "www." host)
  rpId <- maybe rpIdDefault T.pack <$> lookupEnv "EZA_RP_ID"
  rpName <- maybe "eza" T.pack <$> lookupEnv "EZA_RP_NAME"
  allowedRaw <- lookupEnv "EZA_ALLOWED_ORIGINS"
  let allowed = case allowedRaw of
        Nothing -> [origin]
        Just raw -> map T.pack (filter (not . null) (splitOn ',' raw))
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
  monolith <- fromMaybe "monolith" <$> lookupEnv "EZA_MONOLITH"
  logLevel <- fromMaybe "info" <$> lookupEnv "EZA_LOG_LEVEL"
  allowPrivate <- maybe False (== "1") <$> lookupEnv "EZA_ALLOW_PRIVATE_FETCH"
  pure
    Config
      { cfgDataDir = dataDir
      , cfgDbPath = dbPath
      , cfgBind = bind
      , cfgPublicOrigin = origin
      , cfgRpId = rpId
      , cfgRpName = rpName
      , cfgAllowedOrigins = allowed
      , cfgSessionTtlSeconds = ttl
      , cfgSecureCookies = secure
      , cfgStaticDir = staticDir
      , cfgSnapshotDir = snapshotDir
      , cfgBackupDir = backupDir
      , cfgMonolith = monolith
      , cfgLogLevel = logLevel
      , cfgAllowPrivateFetch = allowPrivate
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
  (_, ':':p) -> fromMaybe 8080 (readMaybe p)
  _ -> 8080

readIntEnv :: String -> Int -> IO Int
readIntEnv name fallback = do
  raw <- lookupEnv name
  pure $ case raw >>= readMaybe of
    Just n -> n
    Nothing -> fallback

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
