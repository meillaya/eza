{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The command-line surface. It lives in the library (not in @app/Main.hs@)
so the tests can run commands against a temporary installation and supply stdin
the way a deployment script would: passwords are read from stdin, never from
argv.

Commands that operate on one library resolve the account first:
@--user <name|id>@ picks one, a single-account install uses its only enabled
account, and otherwise the command fails. 0.4 opens only the control database
and @users/<id>/eza.db@; the flat @EZA_DB@ file is not adopted.
-}
module Eza.Cli (
    CliCommand (..),
    UsersCommand (..),
    ImportOpts (..),
    EnrichOpts (..),
    SetPasswordOpts (..),
    RestoreOpts (..),
    CheckDeadOpts (..),
    DedupeOpts (..),
    PasswordSource (..),
    cliParserInfo,
    parseCliArgs,
    runCli,
    runRoutesCommand,
    readHidden,
) where

import Control.Exception (IOException, SomeException, bracket, fromException, onException, try)
import Control.Monad (forM, unless, when)
import Data.Aeson (eitherDecodeStrict', encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Database.SQLite.Simple (Connection, Only (..), close, query, query_)
import Network.HTTP.Client (httpLbs, parseRequest, responseStatus)
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)
import Options.Applicative
import qualified Options.Applicative as OA
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..), exitFailure, exitSuccess)
import System.IO (hFlush, hGetEcho, hPutStr, hPutStrLn, hSetEcho, stderr, stdin)
import System.IO.Error (ioeGetErrorString)

import qualified Eza.Admin as Admin
import qualified Eza.Auth as Auth
import Eza.Backup (BackupReport (..), BackupTarget (..), RestoreOptions (..), RestoreReport (..), runBackup, runRestore)
import Eza.Bench (runBench)
import Eza.Bookmarks
import Eza.Config
import qualified Eza.Control as Control
import Eza.Db (DbError (..))
import qualified Eza.Db as Db
import Eza.DeadLinks (checkDead)
import Eza.Dedup (DedupQuery (..), dedupCandidates, defaultDedupQuery, mergeUrlDuplicatesAll)
import Eza.Enrich (enrichBookmark)
import Eza.Export (exportBookmarks)
import Eza.Import
import Eza.JsonExport (exportJson, importJson)
import Eza.Migrate (SchemaStatus (..))
import qualified Eza.Password as Password
import Eza.Problem (pMessage)
import qualified Eza.Routes as Routes
import Eza.Server (runServer)
import Eza.Types (DedupReport (..), ImportReport (..), TagStat (..))
import Eza.User (UserRole (..), userRoleText)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

data RestoreOpts = RestoreOpts
    { rstStamp :: FilePath
    , rstDryRun :: Bool
    , rstYes :: Bool
    , rstForce :: Bool
    }
    deriving (Show, Eq)

data CliCommand
    = Serve
    | Init
    | Version
    | RoutesCmd Bool
    | ImportCmd ImportOpts
    | DedupeCmd DedupeOpts
    | Stats (Maybe Text)
    | Verify (Maybe Text)
    | RepairDomains (Maybe Text)
    | Backup (Maybe Text)
    | RestoreCmd RestoreOpts
    | CheckDead CheckDeadOpts
    | Healthcheck
    | Bench Int (Maybe Text)
    | ExportCmd Bool (Maybe Text)
    | EnrichCmd EnrichOpts
    | SetPasswordCmd SetPasswordOpts
    | UsersCmd UsersCommand
    deriving (Show, Eq)

data UsersCommand
    = UsersList
    | UsersAdd
        { uaUsername :: Text
        , uaRole :: UserRole
        , uaPasswordStdin :: Bool
        }
    | UsersEnable {ueSelector :: Text}
    | UsersDisable {udSelector :: Text}
    | UsersResetPassword
        { urSelector :: Text
        , urPasswordStdin :: Bool
        }
    | UsersDelete
        { udelSelector :: Text
        , udelDeleteDb :: Bool
        }
    deriving (Show, Eq)

data EnrichOpts = EnrichOpts
    { eoId :: Maybe Int
    , eoLimit :: Int
    , eoAll :: Bool
    , eoDryRun :: Bool
    , eoUser :: Maybe Text
    }
    deriving (Show, Eq)

data SetPasswordOpts = SetPasswordOpts
    { spUsername :: Maybe String
    , spUser :: Maybe Text
    , spResetSessions :: Bool
    , spDisable2fa :: Bool
    }
    deriving (Show, Eq)

data CheckDeadOpts = CheckDeadOpts
    { cdLimit :: Int
    , cdOlderThan :: Int
    , cdIncludeDead :: Bool
    , cdUser :: Maybe Text
    }
    deriving (Show, Eq)

data ImportOpts = ImportOpts
    { optFile :: FilePath
    , optJson :: Bool
    , optMode :: TagMode
    , optKeepNoise :: Bool
    , optMarkRead :: Bool
    , optDryRun :: Bool
    , optUser :: Maybe Text
    }
    deriving (Show, Eq)

data DedupeOpts = DedupeOpts
    { doAll :: Bool
    , doUrlOnly :: Bool
    , doDryRun :: Bool
    , doYes :: Bool
    , doUser :: Maybe Text
    }
    deriving (Show, Eq)

{- | Where the interactive password reads come from. The executable passes the
real terminal/stdin; the tests pass a handle holding the same text a piped
deployment script would supply.
-}
data PasswordSource = PasswordSource
    { psReadHidden :: String -> IO Text
    , psReadStdinLine :: IO Text
    }

-- ---------------------------------------------------------------------------
-- Parser
-- ---------------------------------------------------------------------------

cliParserInfo :: ParserInfo CliCommand
cliParserInfo =
    info
        (commandParser <**> helper)
        ( fullDesc
            <> progDesc "eza bookmark manager"
            <> header "eza-bookmarks — a fast, tag-based bookmark manager"
        )

{- | Parse a command line without running it. Exposed so tests can assert that
@--help@ works on every subcommand (and for embedding the CLI): a help request
comes back as @Left (text, ExitSuccess)@.
-}
parseCliArgs :: [String] -> Either (String, ExitCode) CliCommand
parseCliArgs args = case OA.execParserPure OA.defaultPrefs cliParserInfo args of
    OA.Success parsedCommand -> Right parsedCommand
    OA.Failure failure -> Left (OA.renderFailure failure "eza-bookmarks")
    OA.CompletionInvoked _ -> Left ("", ExitSuccess)

userOption :: Parser (Maybe Text)
userOption =
    optional
        ( T.pack
            <$> strOption
                ( long "user"
                    <> metavar "NAME|ID"
                    <> help "Account username or id (default: the only enabled account)"
                )
        )

commandParser :: Parser CliCommand
commandParser =
    subparser
        ( command "serve" (info (pure Serve <**> helper) (progDesc "Run the web server"))
            <> command "init" (info (pure Init <**> helper) (progDesc "Create the control database (0.4 opens only control.db and users/<id>/eza.db)"))
            <> command "version" (info (pure Version <**> helper) (progDesc "Print the version"))
            <> command
                "routes"
                ( info
                    ( RoutesCmd
                        <$> switch
                            ( long "markdown"
                                <> help "Print the generated Markdown reference table (docs/generated/routes.md)"
                            )
                            <**> helper
                    )
                    (progDesc "Print the HTTP route table")
                )
            <> command "stats" (info (Stats <$> userOption <**> helper) (progDesc "Print database counts and top tags"))
            <> command "verify" (info (Verify <$> userOption <**> helper) (progDesc "Verify counts and FTS index consistency"))
            <> command "repair-domains" (info (RepairDomains <$> userOption <**> helper) (progDesc "Backfill empty domain fields from URLs"))
            <> command
                "backup"
                (info (Backup <$> userOption <**> helper) (progDesc "Back up the control database and every account database into one verified stamp (--user narrows the libraries; page snapshots are not included)"))
            <> command
                "restore"
                (info (RestoreCmd <$> restoreOpts <**> helper) (progDesc "Restore a backup stamp (stop the server first; library snapshots are not in a stamp)"))
            <> command "healthcheck" (info (pure Healthcheck <**> helper) (progDesc "Probe the local /healthz endpoint (container healthcheck)"))
            <> command
                "bench"
                ( info
                    ( Bench
                        <$> option auto (long "iterations" <> value 100 <> metavar "N" <> help "Iterations per query")
                        <*> userOption
                            <**> helper
                    )
                    (progDesc "Benchmark list/search queries against one library")
                )
            <> command
                "check-dead"
                ( info
                    (CheckDead <$> checkDeadOpts <**> helper)
                    (progDesc "Sweep bookmarks for dead links")
                )
            <> command
                "import"
                ( info
                    (ImportCmd <$> importOpts <**> helper)
                    (progDesc "Import a Netscape bookmarks.html export")
                )
            <> command
                "dedupe"
                ( info
                    (DedupeCmd <$> dedupeOpts <**> helper)
                    (progDesc "Merge same-URL duplicate bookmarks (title matches stay review-only)")
                )
            <> command
                "enrich"
                ( info
                    (EnrichCmd <$> enrichOpts <**> helper)
                    (progDesc "Extract text and metadata for bookmarks, one at a time")
                )
            <> command
                "export"
                ( info
                    ( ExportCmd
                        <$> switch (long "json" <> help "Write the versioned eza JSON document instead of Netscape HTML")
                        <*> userOption
                            <**> helper
                    )
                    (progDesc "Export the library to stdout")
                )
            <> command
                "set-password"
                ( info
                    (SetPasswordCmd <$> setPasswordOpts <**> helper)
                    (progDesc "Set the account password (prompts twice with echo off)")
                )
            <> command
                "users"
                ( info
                    (UsersCmd <$> usersCommandParser <**> helper)
                    (progDesc "List and manage accounts (add, enable, disable, reset-password, delete)")
                )
        )

restoreOpts :: Parser RestoreOpts
restoreOpts =
    RestoreOpts
        <$> strArgument (metavar "STAMP" <> help "Backup stamp directory (e.g. backups/20260101-031700)")
        <*> switch (long "dry-run" <> help "Validate the stamp and print the restore plan without writing anything")
        <*> switch (long "yes" <> help "Confirm the restore (required unless --dry-run)")
        <*> switch (long "force" <> help "Continue when the current installation cannot be auto-backed up")

usersCommandParser :: Parser UsersCommand
usersCommandParser =
    subparser
        ( command "list" (info (pure UsersList <**> helper) (progDesc "List accounts with role, state, and database size"))
            <> command
                "add"
                ( info
                    ( UsersAdd
                        <$> (T.pack <$> strOption (long "username" <> metavar "NAME" <> help "Username"))
                        <*> option
                            (eitherReader parseRole)
                            ( long "role"
                                <> value RoleMember
                                <> metavar "admin|member"
                                <> help "Role (default: member)"
                            )
                        <*> switch (long "password-stdin" <> help "Read the initial password from stdin (never argv)")
                            <**> helper
                    )
                    (progDesc "Create an account and print its one-time recovery codes")
                )
            <> command
                "enable"
                ( info
                    (UsersEnable . T.pack <$> strArgument (metavar "NAME|ID" <> help "Username or id") <**> helper)
                    (progDesc "Enable an account")
                )
            <> command
                "disable"
                ( info
                    (UsersDisable . T.pack <$> strArgument (metavar "NAME|ID" <> help "Username or id") <**> helper)
                    (progDesc "Disable an account and revoke its sessions")
                )
            <> command
                "reset-password"
                ( info
                    ( UsersResetPassword
                        <$> (T.pack <$> strArgument (metavar "NAME|ID" <> help "Username or id"))
                        <*> switch (long "password-stdin" <> help "Read the temporary password from stdin (never argv)")
                            <**> helper
                    )
                    (progDesc "Set a temporary password and revoke the account's sessions")
                )
            <> command
                "delete"
                ( info
                    ( UsersDelete
                        <$> (T.pack <$> strArgument (metavar "NAME|ID" <> help "Username or id"))
                        <*> switch (long "delete-db" <> help "Also delete the account's database and snapshots (cannot be undone)")
                            <**> helper
                    )
                    (progDesc "Delete an account (refuses the last enabled admin)")
                )
        )

parseRole :: String -> Either String UserRole
parseRole raw = case T.toLower (T.strip (T.pack raw)) of
    "admin" -> Right RoleAdmin
    "member" -> Right RoleMember
    _ -> Left "role must be admin or member"

-- ---------------------------------------------------------------------------
-- Running
-- ---------------------------------------------------------------------------

runCli :: Config -> PasswordSource -> CliCommand -> IO ()
runCli cfg passwords cmd = case cmd of
    Version -> putStrLn "eza 0.1.0"
    RoutesCmd withMarkdown -> runRoutesCommand withMarkdown
    Init -> runInit cfg
    Serve -> runServer cfg
    Stats userSelector ->
        withLibrary cfg userSelector $ \path conn -> do
            counts <- bookmarkStats conn
            tags <- allTags conn
            putStrLn ("db: " <> path)
            mapM_ (\(k, n) -> putStrLn (T.unpack k <> ": " <> show n)) counts
            putStrLn ("top tags: " <> T.unpack (T.intercalate ", " [tsName t <> " (" <> T.pack (show (tsCount t)) <> ")" | t <- take 12 tags]))
    Verify userSelector -> runVerifyCommand cfg userSelector
    Backup userSelector -> runBackupCommand cfg userSelector
    RestoreCmd opts -> runRestoreCommand cfg opts
    CheckDead opts ->
        withLibrary cfg (cdUser opts) $ \_ conn -> do
            (checked, dead, alive, totalDead) <- checkDead conn (cdLimit opts) (cdOlderThan opts) (cdIncludeDead opts)
            putStrLn (LBS8.unpack (encode (object ["checked" .= checked, "dead" .= dead, "alive" .= alive, "total_dead" .= totalDead])))
    Bench iterations userSelector ->
        withLibrary cfg userSelector $ \_ conn -> runBench conn iterations
    ExportCmd json userSelector ->
        withLibrary cfg userSelector $ \_ conn ->
            if json
                then do
                    document <- exportJson conn
                    LBS8.putStrLn (encode document)
                else TIO.putStrLn =<< exportBookmarks conn
    EnrichCmd opts -> runEnrichCommand cfg opts
    RepairDomains userSelector ->
        withLibrary cfg userSelector $ \_ conn -> do
            n <- backfillDomains conn
            putStrLn ("domains repaired: " <> show n)
    Healthcheck -> runHealthcheck cfg
    SetPasswordCmd opts -> runSetPassword cfg passwords opts
    ImportCmd opts -> runImportCommand cfg opts
    DedupeCmd opts -> runDedupeCommand cfg opts
    UsersCmd usersCommand -> runUsersCommand cfg passwords usersCommand

-- | Open the control database for the duration of one users command.
withControl :: Config -> (Connection -> IO a) -> IO a
withControl cfg = bracket (Control.openControlDb (cfgControlDbPath cfg)) close

{- | Run one per-library command against the account's database. The database
is migrated on open, which is also what the server does on first use.
-}
withLibrary :: Config -> Maybe Text -> (FilePath -> Connection -> IO a) -> IO a
withLibrary cfg userSelector runAction = do
    resolved <- Admin.resolveLibraryPath cfg userSelector
    case resolved of
        Left message -> die message
        Right path -> bracket (Db.openDb path) close (runAction path)

die :: Text -> IO a
die message = do
    hPutStrLn stderr ("eza: " <> T.unpack message)
    exitFailure

{- | Print the route table. @--markdown@ is the generated reference that
@docs/generated/routes.md@ is compared against; the plain form is the same
table for a terminal. The command reads only the compiled route table, never a
database.
-}
runRoutesCommand :: Bool -> IO ()
runRoutesCommand withMarkdown
    | withMarkdown = TIO.putStr Routes.routesMarkdown
    | otherwise = TIO.putStr routesPlainText

routesPlainText :: Text
routesPlainText =
    T.unlines
        ( ("METHOD\tPATH\tCLASS\tCAPABILITY" :: Text)
            : [ T.intercalate
                    "\t"
                    [method, path, Routes.routeClassText klass, Routes.capabilityText capability]
              | (method, path, klass, capability) <- Routes.routeTable
              ]
        )

runInit :: Config -> IO ()
runInit cfg = do
    withControl cfg (\_ -> pure ())
    legacyExists <- doesFileExist (cfgDbPath cfg)
    when legacyExists $
        hPutStrLn
            stderr
            ( "eza: the pre-0.4 database at "
                <> cfgDbPath cfg
                <> " was left untouched; 0.4 does not open it (back it up and import its HTML export, see docs/upgrade.md)"
            )
    putStrLn ("control database initialized: " <> cfgControlDbPath cfg)

runBackupCommand :: Config -> Maybe Text -> IO ()
runBackupCommand cfg userSelector = do
    result <- runBackup cfg userSelector
    case result of
        Left message -> die ("backup failed: " <> message)
        Right report -> do
            putStrLn ("backup: " <> brRoot report)
            mapM_ (\target -> putStrLn ("  " <> T.unpack (btLabel target) <> " -> " <> btDest target)) (brTargets report)
            putStrLn "  (library snapshots are not part of a stamp)"

runRestoreCommand :: Config -> RestoreOpts -> IO ()
runRestoreCommand cfg opts = do
    unless (rstYes opts || rstDryRun opts) $
        die "restore: pass --yes to overwrite the current installation (or --dry-run to inspect the stamp first)"
    result <-
        runRestore
            cfg
            RestoreOptions
                { roStamp = rstStamp opts
                , roDryRun = rstDryRun opts
                , roForce = rstForce opts
                }
    case result of
        Left message -> die ("restore failed: " <> message)
        Right report -> do
            let verb = if rrsDryRun report then "would restore" else "restored"
            putStrLn ((if rrsDryRun report then "restore plan: " else "restore: ") <> rrsStamp report)
            case rrsAutoBackup report of
                Nothing -> putStrLn ("  current installation backup: " <> if rrsDryRun report then "(not taken on a dry run)" else "(none)")
                Just path -> putStrLn ("  current installation backup: " <> path)
            putStrLn ("  control database target: " <> rrsControlTarget report)
            mapM_ (\(userId, username) -> putStrLn ("  " <> T.unpack verb <> " user " <> show userId <> " (" <> T.unpack username <> ")")) (rrsRestored report)
            mapM_ (\(userId, username) -> putStrLn ("  keep current library for user " <> show userId <> " (" <> T.unpack username <> "): the stamp has no copy")) (rrsPreserved report)
            mapM_ (\(userId, username) -> putStrLn ("  drop account " <> show userId <> " (" <> T.unpack username <> "): no library in the stamp or the current installation")) (rrsDropped report)
            unless (null (rrsDropped report)) $
                putStrLn "  note: dropped accounts are removed from the restored control database"
            if rrsDryRun report
                then putStrLn "restore: dry run only, nothing was written"
                else putStrLn "restore: done; start the server to use the restored installation"

runHealthcheck :: Config -> IO ()
runHealthcheck cfg = do
    outcome <- try (probeHealth cfg) :: IO (Either SomeException Bool)
    case outcome of
        Right True -> exitSuccess
        Right False -> do
            hPutStrLn stderr "eza: healthcheck: the server answered but not with HTTP 200"
            exitFailure
        Left err -> do
            hPutStrLn stderr ("eza: healthcheck failed: " <> T.unpack (firstLine (T.pack (show err))))
            exitFailure
  where
    firstLine = T.takeWhile (/= '\n')

probeHealth :: Config -> IO Bool
probeHealth cfg = do
    let port = bindPort (cfgBind cfg)
        url = "http://127.0.0.1:" <> show port <> "/healthz"
    manager <- newTlsManager
    request <- parseRequest url
    response <- httpLbs request manager
    pure (statusCode (responseStatus response) == 200)

{- | Check the control schema and the library schema of every account against
the shared migration plans, then keep the existing per-library FTS and count
checks. A database that is newer than the binary or whose migration checksums
do not match prints the actionable reason from "Eza.Migrate" (never a stack
trace) and makes the command fail.
-}
runVerifyCommand :: Config -> Maybe Text -> IO ()
runVerifyCommand cfg userSelector = do
    controlOk <- verifyControlDatabase cfg
    librariesOk <-
        if not controlOk
            then pure False
            else verifyLibraries userSelector
    if controlOk && librariesOk
        then putStrLn "verify: ok" >> exitSuccess
        else exitFailure
  where
    verifyLibraries selector = case selector of
        Just chosen -> do
            resolved <- Admin.resolveLibraryPath cfg (Just chosen)
            case resolved of
                Left message -> reportFailure message
                Right path -> verifyLibrary cfg path
        Nothing -> withControl cfg $ \control -> do
            users <- Control.listUsers control
            if null users
                then verifyResolvedLibrary cfg
                else and <$> mapM (verifyLibrary cfg . Control.cuDbPath) users

    -- Kept out of the closure above so the EmptyControl fallback still goes
    -- through the same resolution rules as the other per-library commands.
    verifyResolvedLibrary config = do
        resolved <- Admin.resolveLibraryPath config Nothing
        case resolved of
            Left message -> reportFailure message
            Right path -> verifyLibrary config path

verifyControlDatabase :: Config -> IO Bool
verifyControlDatabase cfg = do
    let path = cfgControlDbPath cfg
    opened <- try (Control.openControlDb path) :: IO (Either SomeException Connection)
    case opened of
        Left err -> reportFailure ("control database " <> T.pack path <> ": " <> firstLineText err)
        Right control -> bracket (pure control) close $ \conn -> do
            result <- Control.checkControlSchema conn
            case result of
                Left message -> reportFailure ("control database " <> T.pack path <> ": " <> message)
                Right status -> do
                    putStrLn ("control: " <> path)
                    TIO.putStrLn ("schema: " <> renderSchemaStatus status)
                    pure True

verifyLibrary :: Config -> FilePath -> IO Bool
verifyLibrary _cfg path = do
    exists <- doesFileExist path
    if not exists
        then reportFailure ("library " <> T.pack path <> ": database file does not exist")
        else do
            opened <- try (Db.openDb path) :: IO (Either SomeException Connection)
            case opened of
                Left err -> reportFailure ("library " <> T.pack path <> ": " <> firstLineText err)
                Right conn -> bracket (pure conn) close $ \library -> verifyLibraryConnection _cfg path library

verifyLibraryConnection :: Config -> FilePath -> Connection -> IO Bool
verifyLibraryConnection _cfg path conn = do
    schemaResult <- Db.checkSchema conn
    case schemaResult of
        Left message -> reportFailure ("library " <> T.pack path <> ": " <> message)
        Right status -> do
            counts <- bookmarkStats conn
            ftsCount <- Db.queryScalar conn "SELECT COUNT(*) FROM bookmarks_fts"
            putStrLn ("db: " <> path)
            TIO.putStrLn ("schema: " <> renderSchemaStatus status)
            mapM_ (\(k, n) -> putStrLn (T.unpack k <> ": " <> show n)) counts
            putStrLn ("fts_rows: " <> show ftsCount)
            integrity <- Db.ftsIntegrityCheck conn
            case integrity of
                Left message -> reportFailure ("library " <> T.pack path <> ": the FTS index is corrupt: " <> message)
                Right () -> do
                    let bookmarks = maybe 0 id (lookup "bookmarks" counts)
                    if ftsCount == bookmarks
                        then pure True
                        else reportFailure ("library " <> T.pack path <> ": FTS row count does not match bookmarks")

reportFailure :: Text -> IO Bool
reportFailure message = do
    hPutStrLn stderr ("verify: " <> T.unpack message)
    pure False

renderSchemaStatus :: SchemaStatus -> Text
renderSchemaStatus status =
    "ok (v"
        <> T.pack (show (ssVersion status))
        <> "/v"
        <> T.pack (show (ssExpectedVersion status))
        <> if ssLegacy status then ", legacy, schema_meta pending)" else ")"

{- | The actionable message carried by a database error, without a GHC show
wrapper; anything else keeps the first line of its display form.
-}
firstLineText :: SomeException -> Text
firstLineText err = case fromException err :: Maybe DbError of
    Just (DbError message) -> message
    Nothing -> case fromException err :: Maybe IOException of
        Just ioErrorValue -> T.pack (ioeGetErrorString ioErrorValue)
        Nothing -> T.takeWhile (/= '\n') (T.pack (show err))

runSetPassword :: Config -> PasswordSource -> SetPasswordOpts -> IO ()
runSetPassword cfg passwords opts = do
    resolved <- Admin.resolveLibraryTarget cfg (spUser opts)
    case resolved of
        Left message -> die message
        Right (controlUser, path) ->
            bracket (Db.openDb path) close $ \conn -> do
                first <- psReadHidden passwords "new password: "
                second <- psReadHidden passwords "repeat password: "
                if first /= second
                    then die "set-password: the passwords do not match"
                    else case Password.validatePassword first of
                        Left message -> die ("set-password: " <> message)
                        Right () -> do
                            account <- Auth.loadAccount conn
                            rawUsername <- case spUsername opts of
                                Just name | not (null name) -> pure (T.pack name)
                                _ -> case controlUser of
                                    Just user -> pure (Control.cuUsername user)
                                    Nothing ->
                                        if T.null (Auth.acctUsername account)
                                            then promptLine "username: "
                                            else pure (Auth.acctUsername account)
                            case Password.validateUsername rawUsername of
                                Left message -> die ("set-password: " <> message)
                                Right username -> do
                                    -- The control row is the login lookup key, so the
                                    -- rename happens first: a duplicate username is
                                    -- reported before the library is touched.
                                    renamed <- renameControlFirst cfg controlUser username
                                    case renamed of
                                        Left message -> die message
                                        Right () -> do
                                            passwordHash <- Password.hashPassword (cfgArgon2 cfg) first
                                            writeResult <-
                                                try (writePassword cfg opts conn first passwordHash username) ::
                                                    IO (Either SomeException ())
                                            case writeResult of
                                                Left err -> do
                                                    rollbackControlUsername cfg controlUser
                                                    die ("set-password: the password could not be stored: " <> T.pack (show err))
                                                Right () -> do
                                                    remaining <- Auth.recoveryCodesRemaining conn
                                                    putStrLn ("password updated for " <> T.unpack username)
                                                    if remaining == 0
                                                        then putStrLn "note: no unused recovery codes remain; regenerate them from the account page"
                                                        else putStrLn ("recovery codes unchanged: " <> show remaining <> " unused")

{- | Store the password and the optional follow-up changes in the library. Runs
after the control rename; a failure here needs the rename rolled back.
-}
writePassword :: Config -> SetPasswordOpts -> Connection -> Text -> Text -> Text -> IO ()
writePassword cfg opts conn _first passwordHash username = do
    Auth.setAccountPassword conn username passwordHash
    when (spResetSessions opts) $ do
        revoked <- Auth.deleteAllSessions conn
        putStrLn ("sessions revoked: " <> show revoked)
    when (spDisable2fa opts) $ do
        Auth.setRequirePasskey conn False
        putStrLn "passkey requirement cleared"
  where
    _ = cfg

{- | Rename the control row before the library is written. The set-password
command always resolves a registered account, so there is no library-only
username path left.
-}
renameControlFirst :: Config -> Maybe Control.ControlUser -> Text -> IO (Either Text ())
renameControlFirst _ Nothing _ = pure (Right ())
renameControlFirst cfg (Just user) username
    | Control.cuUsername user == username = pure (Right ())
    | otherwise = do
        result <- withControl cfg $ \control -> Control.setUsername control (Control.cuId user) username
        pure $ case result of
            Right () -> Right ()
            Left Control.ControlDuplicateUsername ->
                Left ("set-password: the username " <> username <> " is already used by another account")
            Left err -> Left ("set-password: the control username could not be changed: " <> T.pack (show err))

{- | Undo the control rename when the library write failed, so login and the
stored account name do not diverge.
-}
rollbackControlUsername :: Config -> Maybe Control.ControlUser -> IO ()
rollbackControlUsername _ Nothing = pure ()
rollbackControlUsername cfg (Just user) = do
    result <-
        try (withControl cfg $ \control -> Control.setUsername control (Control.cuId user) (Control.cuUsername user)) ::
            IO (Either SomeException (Either Control.ControlError ()))
    case result of
        Right (Right ()) -> pure ()
        _ ->
            hPutStrLn
                stderr
                ( "eza: warning: the control username could not be rolled back; it may differ from the library account name ("
                    <> T.unpack (Control.cuUsername user)
                    <> ")"
                )

runImportCommand :: Config -> ImportOpts -> IO ()
runImportCommand cfg opts = do
    raw <- BS.readFile (optFile opts)
    if optJson opts
        then
            if optDryRun opts
                then die "import: --dry-run is only available for Netscape HTML imports"
                else case eitherDecodeStrict' raw of
                    Left err -> die ("import: the file is not valid JSON: " <> T.pack err)
                    Right decodedImport -> withLibrary cfg (optUser opts) $ \_ conn -> do
                        result <- importJson conn decodedImport
                        case result of
                            Left message -> die ("import: " <> message)
                            Right report -> putStrLn (LBS8.unpack (encode report))
        else do
            let parsed = parseNetscape (ImportOptions (optMode opts) (not (optKeepNoise opts)) (optMarkRead opts)) raw
            if optDryRun opts
                then putStrLn (LBS8.unpack (encode (dryReport parsed)))
                else withLibrary cfg (optUser opts) $ \_ conn -> do
                    report <- importParsed conn (ImportOptions (optMode opts) (not (optKeepNoise opts)) (optMarkRead opts)) parsed
                    putStrLn (LBS8.unpack (encode report))

dryReport :: ParsedImport -> ImportReport
dryReport parsed =
    ImportReport
        { irFound = piFound parsed
        , irHttpAnchors = piHttp parsed
        , irUniqueUrls = length (piItems parsed)
        , irInserted = 0
        , irExisting = 0
        , irDuplicateAnchors = piDuplicates parsed
        , irSkippedNonHttp = piNonHttp parsed
        , irTagsCreated = 0
        , irTagLinksAdded = 0
        , irFoldersSkipped = piFoldersSkipped parsed
        , irUntagged = piUntagged parsed
        , irElapsedMs = 0
        }

runDedupeCommand :: Config -> DedupeOpts -> IO ()
runDedupeCommand cfg opts
    | not (doAll opts) =
        hPutStrLn stderr "dedupe: pass --all to merge every same-URL duplicate group (use --dry-run to inspect counts first)" >> exitFailure
    | not (doYes opts) && not (doDryRun opts) =
        hPutStrLn stderr "dedupe: refusing to merge without --yes (this writes one undo snapshot and can be undone from Maintenance)" >> exitFailure
    | otherwise = withLibrary cfg (doUser opts) $ \_ conn -> do
        if doDryRun opts
            then do
                report <- dedupCandidates conn defaultDedupQuery{dqUrlLimit = 1, dqTitleLimit = 1}
                putStrLn (LBS8.unpack (encode (drCounts report)))
            else do
                unless (doUrlOnly opts) $
                    hPutStrLn stderr "dedupe: merging canonical-URL groups only; same-title matches stay review-only"
                report <- mergeUrlDuplicatesAll conn
                putStrLn (LBS8.unpack (encode report))

runEnrichCommand :: Config -> EnrichOpts -> IO ()
runEnrichCommand cfg opts = withLibrary cfg (eoUser opts) $ \_ conn -> do
    ids <- enrichIds conn opts
    if eoDryRun opts
        then putStrLn (LBS8.unpack (encode (object ["candidates" .= length ids, "dry_run" .= True])))
        else do
            manager <- newTlsManager
            results <- forM ids $ \bid -> do
                result <- try (enrichBookmark manager cfg conn bid) :: IO (Either SomeException (Either Text ()))
                pure (bid, result)
            let ok = length [() | (_, Right (Right ())) <- results]
                failed = length results - ok
            putStrLn (LBS8.unpack (encode (object ["attempted" .= length results, "ok" .= ok, "failed" .= failed])))

enrichIds :: Connection -> EnrichOpts -> IO [Int]
enrichIds conn opts = case eoId opts of
    Just bid -> pure [bid]
    Nothing ->
        if eoAll opts
            then map fromOnly <$> query_ conn "SELECT id FROM bookmarks WHERE enrich_state IN ('idle','failed') ORDER BY id"
            else map fromOnly <$> query conn "SELECT id FROM bookmarks WHERE enrich_state IN ('idle','failed') ORDER BY id LIMIT ?" (Only (max 1 (eoLimit opts)))
  where
    fromOnly (Only bid) = bid

-- ---------------------------------------------------------------------------
-- users
-- ---------------------------------------------------------------------------

runUsersCommand :: Config -> PasswordSource -> UsersCommand -> IO ()
runUsersCommand cfg passwords cmd = withControl cfg $ \control -> case cmd of
    UsersList -> do
        summaries <- Admin.listUserSummaries cfg control
        if null summaries
            then putStrLn "no accounts"
            else mapM_ printSummary summaries
    UsersAdd username role passwordStdin -> do
        unless passwordStdin $
            die "users add: pass --password-stdin (the password is never read from argv)"
        password <- psReadStdinLine passwords
        created <- Admin.createUserAccount cfg control username role password
        case created of
            Left err -> die (pMessage (Admin.toProblem err))
            Right (user, codes) -> do
                putStrLn
                    ( "created user "
                        <> T.unpack (Control.cuUsername user)
                        <> " (id "
                        <> show (Control.cuId user)
                        <> ", "
                        <> T.unpack (userRoleText (Control.cuRole user))
                        <> ")"
                    )
                putStrLn "recovery codes (shown once; each works one time):"
                mapM_ TIO.putStrLn codes
    UsersEnable selector -> withSelectedUser control selector $ \user -> do
        changed <- Admin.setUserEnabled cfg control (Control.cuId user) True
        case changed of
            Left err -> die (pMessage (Admin.toProblem err))
            Right _ -> putStrLn ("enabled " <> T.unpack (Control.cuUsername user))
    UsersDisable selector -> withSelectedUser control selector $ \user -> do
        changed <- Admin.setUserEnabled cfg control (Control.cuId user) False
        case changed of
            Left err -> die (pMessage (Admin.toProblem err))
            Right _ -> putStrLn ("disabled " <> T.unpack (Control.cuUsername user) <> " and revoked its sessions")
    UsersResetPassword selector passwordStdin -> withSelectedUser control selector $ \user -> do
        unless passwordStdin $
            die "users reset-password: pass --password-stdin (the password is never read from argv)"
        password <- psReadStdinLine passwords
        result <- Admin.resetUserPassword cfg control (Control.cuId user) password
        case result of
            Left err -> die (pMessage (Admin.toProblem err))
            Right () -> putStrLn ("temporary password set for " <> T.unpack (Control.cuUsername user) <> "; sessions revoked")
    UsersDelete selector deleteDb -> withSelectedUser control selector $ \user -> do
        unless deleteDb $
            die "users delete: pass --delete-db to remove the account's database and snapshots as well"
        result <- Admin.deleteUserAccount cfg control (Control.cuId user) True
        case result of
            Left err -> die (pMessage (Admin.toProblem err))
            Right () -> putStrLn ("deleted " <> T.unpack (Control.cuUsername user) <> " and its database")

withSelectedUser :: Connection -> Text -> (Control.ControlUser -> IO ()) -> IO ()
withSelectedUser control selector runAction = do
    found <- Admin.resolveSelector control selector
    case found of
        Nothing -> die ("no account matches " <> T.strip selector)
        Just user -> runAction user

printSummary :: Admin.UserSummary -> IO ()
printSummary summary =
    putStrLn
        ( T.unpack (T.pack (show (Admin.usmId summary)))
            <> "\t"
            <> T.unpack (Admin.usmUsername summary)
            <> "\t"
            <> T.unpack (userRoleText (Admin.usmRole summary))
            <> "\t"
            <> (if Admin.usmEnabled summary then "enabled" else "disabled")
            <> "\t"
            <> show (Admin.usmDbBytes summary)
            <> " bytes\t"
            <> show (Admin.usmSnapshotCount summary)
            <> " snapshots\t"
            <> Admin.usmDbPath summary
        )

-- ---------------------------------------------------------------------------
-- Password input helpers
-- ---------------------------------------------------------------------------

{- | Read a line with the terminal echo off. When stdin is not a terminal (for
example a piped deployment script) the read still works, without the echo
suppression.
-}
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

-- ---------------------------------------------------------------------------
-- Option parsers for the per-library commands
-- ---------------------------------------------------------------------------

enrichOpts :: Parser EnrichOpts
enrichOpts =
    EnrichOpts
        <$> optional (option auto (long "id" <> metavar "ID" <> help "Only this bookmark id"))
        <*> option auto (long "limit" <> value 100 <> metavar "N" <> help "Maximum bookmarks (default: 100)")
        <*> switch (long "all" <> help "Ignore --limit and process every idle or failed bookmark")
        <*> switch (long "dry-run" <> help "Print the candidate count without fetching")
        <*> userOption

setPasswordOpts :: Parser SetPasswordOpts
setPasswordOpts =
    SetPasswordOpts
        <$> optional (strOption (long "username" <> metavar "NAME" <> help "Username to store (prompted when the account has none)"))
        <*> userOption
        <*> switch (long "reset-sessions" <> help "Revoke every browser session after the change")
        <*> switch (long "disable-2fa" <> help "Clear the passkey requirement")

importOpts :: Parser ImportOpts
importOpts =
    ImportOpts
        <$> strArgument (metavar "FILE" <> help "Bookmarks file: a Netscape bookmarks.html or an eza JSON export with --json")
        <*> switch (long "json" <> help "Read the versioned eza JSON export instead of Netscape HTML")
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
        <*> userOption

dedupeOpts :: Parser DedupeOpts
dedupeOpts =
    DedupeOpts
        <$> switch (long "all" <> help "Merge every same-URL duplicate group (required)")
        <*> switch (long "url-only" <> help "Canonical-URL duplicates only; title matches are never bulk-merged (default)")
        <*> switch (long "dry-run" <> help "Print duplicate counts without changing anything")
        <*> switch (long "yes" <> help "Confirm the merge (required unless --dry-run)")
        <*> userOption

checkDeadOpts :: Parser CheckDeadOpts
checkDeadOpts =
    CheckDeadOpts
        <$> option auto (long "limit" <> value 500 <> metavar "N" <> help "Maximum links to check")
        <*> option auto (long "older-than" <> value 0 <> metavar "SECONDS" <> help "Only re-check older than this")
        <*> switch (long "include-dead" <> help "Re-check rows already flagged dead")
        <*> userOption

parseMode :: String -> Either String TagMode
parseMode raw = case raw of
    "leaf" -> Right TagLeaf
    "deepest" -> Right TagDeepest
    "path" -> Right TagPath
    "none" -> Right TagNone
    _ -> Left "tag mode must be one of: leaf, deepest, path, none"
