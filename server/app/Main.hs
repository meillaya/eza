module Main (main) where

import Control.Exception (bracket)
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (close)
import Network.HTTP.Client
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)
import Options.Applicative
import System.Environment (lookupEnv)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)

import Eza.Backup (runBackup)
import Eza.Bench (runBench)
import Eza.Bookmarks
import Eza.Config
import Eza.DeadLinks (checkDead)
import qualified Eza.Db as Db
import Eza.Import
import Eza.Types (ImportReport (..), TagStat (..))
import Eza.Server (runServer)

data Command
  = Serve
  | Init
  | Version
  | ImportCmd ImportOpts
  | Stats
  | Verify
  | RepairDomains
  | Backup
  | CheckDead CheckDeadOpts
  | Healthcheck
  | Bench Int
  deriving (Show, Eq)

data CheckDeadOpts = CheckDeadOpts
  { cdLimit :: Int
  , cdOlderThan :: Int
  , cdIncludeDead :: Bool
  }
  deriving (Show, Eq)

data ImportOpts = ImportOpts
  { optFile :: FilePath
  , optMode :: TagMode
  , optKeepNoise :: Bool
  , optMarkRead :: Bool
  , optDryRun :: Bool
  }
  deriving (Show, Eq)

main :: IO ()
main = do
  command <- execParser opts
  cfg <- loadConfig
  case command of
    Version -> putStrLn "eza 0.1.0"
    Init -> do
      Db.initDb (cfgDbPath cfg)
      putStrLn ("database initialized: " <> cfgDbPath cfg)
    Serve ->
      bracket (Db.openDb (cfgDbPath cfg)) close $ \conn ->
        runServer cfg conn
    Stats ->
      bracket (Db.openDb (cfgDbPath cfg)) close $ \conn -> do
        counts <- bookmarkStats conn
        tags <- allTags conn
        putStrLn ("db: " <> cfgDbPath cfg)
        mapM_ (\(k, n) -> putStrLn (T.unpack k <> ": " <> show n)) counts
        putStrLn ("top tags: " <> T.unpack (T.intercalate ", " [tsName t <> " (" <> T.pack (show (tsCount t)) <> ")" | t <- take 12 tags]))
    Backup -> do
      result <- runBackup cfg
      case result of
        Left e -> hPutStrLn stderr ("backup failed: " <> T.unpack e) >> exitFailure
        Right path -> putStrLn ("backup: " <> path)
    CheckDead co ->
      bracket (Db.openDb (cfgDbPath cfg)) close $ \conn -> do
        (checked, dead, alive) <- checkDead conn (cdLimit co) (cdOlderThan co) (cdIncludeDead co)
        putStrLn (LBS8.unpack (encode (object ["checked" .= checked, "dead" .= dead, "alive" .= alive])))
    Bench iterations ->
      bracket (Db.openDb (cfgDbPath cfg)) close $ \conn -> runBench conn iterations
    Healthcheck -> do
      let port = bindPort (cfgBind cfg)
          url = "http://127.0.0.1:" <> show port <> "/healthz"
      manager <- newTlsManager
      req <- parseRequest url
      resp <- httpLbs req manager
      if statusCode (responseStatus resp) == 200
        then exitSuccess
        else exitFailure
    RepairDomains ->
      bracket (Db.openDb (cfgDbPath cfg)) close $ \conn -> do
        n <- backfillDomains conn
        putStrLn ("domains repaired: " <> show n)
    Verify ->
      bracket (Db.openDb (cfgDbPath cfg)) close $ \conn -> do
        counts <- bookmarkStats conn
        ftsCount <- Db.queryScalar conn "SELECT COUNT(*) FROM bookmarks_fts"
        putStrLn ("db: " <> cfgDbPath cfg)
        mapM_ (\(k, n) -> putStrLn (T.unpack k <> ": " <> show n)) counts
        putStrLn ("fts_rows: " <> show ftsCount)
        let bookmarks = maybe 0 id (lookup "bookmarks" counts)
        if ftsCount == bookmarks
          then putStrLn "verify: ok" >> exitSuccess
          else hPutStrLn stderr "verify: FTS row count does not match bookmarks" >> exitFailure
    ImportCmd io -> do
      raw <- BS.readFile (optFile io)
      let parsed = parseNetscape (ImportOptions (optMode io) (not (optKeepNoise io)) (optMarkRead io)) raw
      if optDryRun io
        then putStrLn (LBS8.unpack (encode (dryReport parsed)))
        else
          bracket (Db.openDb (cfgDbPath cfg)) close $ \conn -> do
            report <- importParsed conn (ImportOptions (optMode io) (not (optKeepNoise io)) (optMarkRead io)) parsed
            putStrLn (LBS8.unpack (encode report))

dryReport :: ParsedImport -> ImportReport
dryReport p =
  ImportReport
    { irFound = piFound p
    , irHttpAnchors = piHttp p
    , irUniqueUrls = length (piItems p)
    , irInserted = 0
    , irExisting = 0
    , irDuplicateAnchors = piDuplicates p
    , irSkippedNonHttp = piNonHttp p
    , irTagsCreated = 0
    , irTagLinksAdded = 0
    , irFoldersSkipped = piFoldersSkipped p
    , irUntagged = piUntagged p
    , irElapsedMs = 0
    }

opts :: ParserInfo Command
opts =
  info
    (commandParser <**> helper)
    ( fullDesc
        <> progDesc "eza bookmark manager"
        <> header "eza-bookmarks — a fast, tag-based bookmark manager"
    )

commandParser :: Parser Command
commandParser =
  subparser
    ( command "serve" (info (pure Serve) (progDesc "Run the web server"))
        <> command "init" (info (pure Init) (progDesc "Create or migrate the database"))
        <> command "version" (info (pure Version) (progDesc "Print the version"))
        <> command "stats" (info (pure Stats) (progDesc "Print database counts and top tags"))
        <> command "verify" (info (pure Verify) (progDesc "Verify counts and FTS consistency"))
        <> command "repair-domains" (info (pure RepairDomains) (progDesc "Backfill empty domain fields from URLs"))
        <> command "backup" (info (pure Backup) (progDesc "Create and verify an online SQLite backup"))
        <> command "healthcheck" (info (pure Healthcheck) (progDesc "Probe the local /healthz endpoint (container healthcheck)"))
        <> command
          "bench"
          ( info
              (Bench <$> option auto (long "iterations" <> value 100 <> metavar "N" <> help "Iterations per query"))
              (progDesc "Benchmark list/search queries against the database")
          )
        <> command
          "check-dead"
          ( info
              (CheckDead <$> checkDeadOpts)
              (progDesc "Sweep bookmarks for dead links")
          )
        <> command
          "import"
          ( info
              (ImportCmd <$> importOpts)
              (progDesc "Import a Netscape bookmarks.html export")
          )
    )

importOpts :: Parser ImportOpts
importOpts =
  ImportOpts
    <$> strArgument (metavar "FILE" <> help "Netscape bookmarks.html file")
    <*> ( option
            (eitherReader parseMode)
            ( long "tag-mode"
                <> value TagLeaf
                <> metavar "leaf|deepest|path|none"
                <> help "Folder-to-tag mapping (default: leaf)"
            )
        )
    <*> switch (long "keep-noise" <> help "Keep timestamp/New folder names as tags")
    <*> switch (long "mark-read" <> help "Mark imported bookmarks as read")
    <*> switch (long "dry-run" <> help "Parse and report without writing")

checkDeadOpts :: Parser CheckDeadOpts
checkDeadOpts =
  CheckDeadOpts
    <$> option auto (long "limit" <> value 500 <> metavar "N" <> help "Maximum links to check")
    <*> option auto (long "older-than" <> value 0 <> metavar "SECONDS" <> help "Only re-check older than this")
    <*> switch (long "include-dead" <> help "Re-check rows already flagged dead")

parseMode :: String -> Either String TagMode
parseMode raw = case raw of
  "leaf" -> Right TagLeaf
  "deepest" -> Right TagDeepest
  "path" -> Right TagPath
  "none" -> Right TagNone
  _ -> Left "tag mode must be one of: leaf, deepest, path, none"
