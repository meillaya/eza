module Main (main) where

import Control.Exception (IOException, SomeException, bracket, onException, try)
import Control.Monad (forM)
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Database.SQLite.Simple (Connection, Only (..), close, query, query_)
import Network.HTTP.Client
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)
import Options.Applicative
import System.Exit (exitFailure, exitSuccess)
import System.IO (hFlush, hGetEcho, hPutStr, hPutStrLn, hSetEcho, stdin, stderr)

import qualified Eza.Auth as Auth
import Eza.Backup (runBackup)
import Eza.Bench (runBench)
import Eza.Bookmarks
import Eza.Config
import Eza.DeadLinks (checkDead)
import Eza.Enrich (enrichBookmark)
import qualified Eza.Db as Db
import Eza.Export (exportBookmarks)
import Eza.Import
import Eza.JsonExport (exportJson)
import qualified Eza.Password as Password
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
  | ExportCmd Bool
  | EnrichCmd EnrichOpts
  | SetPasswordCmd SetPasswordOpts
  deriving (Show, Eq)

data EnrichOpts = EnrichOpts
  { eoId :: Maybe Int
  , eoLimit :: Int
  , eoAll :: Bool
  , eoDryRun :: Bool
  }
  deriving (Show, Eq)

data SetPasswordOpts = SetPasswordOpts
  { spUsername :: Maybe String
  , spResetSessions :: Bool
  , spDisable2fa :: Bool
  }
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
  cmd <- execParser opts
  cfg <- loadConfig
  case cmd of
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
    ExportCmd json ->
      bracket (Db.openDb (cfgDbPath cfg)) close $ \conn ->
        if json
          then do
            document <- exportJson conn
            LBS8.putStrLn (encode document)
          else TIO.putStrLn =<< exportBookmarks conn
    EnrichCmd eo ->
      bracket (Db.openDb (cfgDbPath cfg)) close $ \conn -> do
        ids <- enrichIds conn eo
        if eoDryRun eo
          then putStrLn (LBS8.unpack (encode (object ["candidates" .= length ids, "dry_run" .= True])))
          else do
            manager <- newTlsManager
            results <- forM ids $ \bid -> do
              result <- try (enrichBookmark manager cfg conn bid) :: IO (Either SomeException (Either Text ()))
              pure (bid, result)
            let ok = length [() | (_, Right (Right ())) <- results]
                failed = length results - ok
            putStrLn (LBS8.unpack (encode (object ["attempted" .= length results, "ok" .= ok, "failed" .= failed])))
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
    SetPasswordCmd sp -> setPassword cfg sp
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
        <> command
          "enrich"
          ( info
              (EnrichCmd <$> enrichOpts)
              (progDesc "Extract text and metadata for bookmarks, one at a time")
          )
        <> command
          "export"
          ( info
              (ExportCmd <$> switch (long "json" <> help "Write the versioned eza JSON document instead of Netscape HTML"))
              (progDesc "Export the library to stdout")
          )
        <> command
          "set-password"
          ( info
              (SetPasswordCmd <$> setPasswordOpts)
              (progDesc "Set the account password (prompts twice with echo off)")
          )
    )

enrichOpts :: Parser EnrichOpts
enrichOpts =
  EnrichOpts
    <$> optional (option auto (long "id" <> metavar "ID" <> help "Only this bookmark id"))
    <*> option auto (long "limit" <> value 100 <> metavar "N" <> help "Maximum bookmarks (default: 100)")
    <*> switch (long "all" <> help "Ignore --limit and process every idle or failed bookmark")
    <*> switch (long "dry-run" <> help "Print the candidate count without fetching")

enrichIds :: Connection -> EnrichOpts -> IO [Int]
enrichIds conn eo = case eoId eo of
  Just bid -> pure [bid]
  Nothing ->
    if eoAll eo
      then map fromOnly <$> query_ conn "SELECT id FROM bookmarks WHERE enrich_state IN ('idle','failed') ORDER BY id"
      else map fromOnly <$> query conn "SELECT id FROM bookmarks WHERE enrich_state IN ('idle','failed') ORDER BY id LIMIT ?" (Only (max 1 (eoLimit eo)))
  where
    fromOnly (Only bid) = bid

setPasswordOpts :: Parser SetPasswordOpts
setPasswordOpts =
  SetPasswordOpts
    <$> optional (strOption (long "username" <> metavar "NAME" <> help "Username to store (prompted when the account has none)"))
    <*> switch (long "reset-sessions" <> help "Revoke every browser session after the change")
    <*> switch (long "disable-2fa" <> help "Clear the passkey requirement (already off in this release)")

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

{- | Operator escape hatch: set or reset the account password from the host.
The password is read from the terminal with echo off and never accepted as an
argument, so it cannot leak through the process table or a shell history.
-}
setPassword :: Config -> SetPasswordOpts -> IO ()
setPassword cfg sp = do
    bracket (Db.openDb (cfgDbPath cfg)) close $ \conn -> do
        first <- readHidden "new password: "
        second <- readHidden "repeat password: "
        if first /= second
            then hPutStrLn stderr "set-password: the passwords do not match" >> exitFailure
            else case Password.validatePassword first of
                Left message -> hPutStrLn stderr ("set-password: " <> T.unpack message) >> exitFailure
                Right () -> do
                    account <- Auth.loadAccount conn
                    rawUsername <- case spUsername sp of
                        Just name | not (null name) -> pure (T.pack name)
                        _ ->
                            if T.null (Auth.acctUsername account)
                                then promptLine "username: "
                                else pure (Auth.acctUsername account)
                    case Password.validateUsername rawUsername of
                        Left message -> hPutStrLn stderr ("set-password: " <> T.unpack message) >> exitFailure
                        Right username -> do
                            passwordHash <- Password.hashPassword (cfgArgon2 cfg) first
                            Auth.setAccountPassword conn username passwordHash
                            if spResetSessions sp
                                then do
                                    revoked <- Auth.deleteAllSessions conn
                                    putStrLn ("sessions revoked: " <> show revoked)
                                else pure ()
                            if spDisable2fa sp
                                then do
                                    Auth.setRequirePasskey conn False
                                    putStrLn "passkey requirement cleared"
                                else pure ()
                            remaining <- Auth.recoveryCodesRemaining conn
                            putStrLn ("password updated for " <> T.unpack username)
                            if remaining == 0
                                then putStrLn "note: no unused recovery codes remain; regenerate them from the account page"
                                else putStrLn ("recovery codes unchanged: " <> show remaining <> " unused")

-- | Read a line with the terminal echo off. When stdin is not a terminal
-- (for example a piped deployment script) the read still works, without the
-- echo suppression.
readHidden :: String -> IO Text
readHidden label = do
    hPutStr stderr label
    hFlush stderr
    echoed <- try (hGetEcho stdin) :: IO (Either IOException Bool)
    case echoed of
        Left _ -> TIO.getLine
        Right original -> do
            hSetEcho stdin False
            line <- TIO.getLine `onException` hSetEcho stdin original
            hSetEcho stdin original
            hPutStrLn stderr ""
            pure line

promptLine :: String -> IO Text
promptLine label = do
    hPutStr stderr label
    hFlush stderr
    T.strip <$> TIO.getLine
