{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The command-line surface. It lives in the library (not in @app/Main.hs@)
so the tests can run commands against a temporary installation and supply stdin
the way a deployment script would: passwords are read from stdin, never from
argv.

Commands that operate on one library resolve the account first:
@--user <name|id>@ picks one, a single-account install uses its only enabled
account, and a control database with no rows falls back to the legacy
@EZA_DB@ path so pre-M3b workflows keep working.
-}
module Eza.Cli (
    CliCommand (..),
    UsersCommand (..),
    ImportOpts (..),
    EnrichOpts (..),
    SetPasswordOpts (..),
    CheckDeadOpts (..),
    DedupeOpts (..),
    PasswordSource (..),
    cliParserInfo,
    runCli,
    readHidden,
) where

import Control.Exception (IOException, SomeException, bracket, onException, try)
import Control.Monad (forM, unless)
import Data.Aeson (encode, object, (.=))
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
import System.Exit (exitFailure, exitSuccess)
import System.IO (hFlush, hGetEcho, hPutStr, hPutStrLn, hSetEcho, stderr, stdin)

import qualified Eza.Admin as Admin
import qualified Eza.Auth as Auth
import Eza.Backup (BackupReport (..), BackupTarget (..), runBackup)
import Eza.Bench (runBench)
import Eza.Bookmarks
import Eza.Config
import qualified Eza.Control as Control
import qualified Eza.Db as Db
import Eza.DeadLinks (checkDead)
import Eza.Dedup (DedupQuery (..), dedupCandidates, defaultDedupQuery, mergeUrlDuplicatesAll)
import Eza.Enrich (enrichBookmark)
import Eza.Export (exportBookmarks)
import Eza.Import
import Eza.JsonExport (exportJson)
import qualified Eza.Password as Password
import Eza.Server (runServer)
import Eza.Types (DedupReport (..), ImportReport (..), TagStat (..))
import Eza.User (UserRole (..), userRoleText)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

data CliCommand
    = Serve
    | Init
    | Version
    | ImportCmd ImportOpts
    | DedupeCmd DedupeOpts
    | Stats (Maybe Text)
    | Verify (Maybe Text)
    | RepairDomains (Maybe Text)
    | Backup (Maybe Text)
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
        ( command "serve" (info (pure Serve) (progDesc "Run the web server"))
            <> command "init" (info (pure Init) (progDesc "Create or migrate the control database and the legacy database file"))
            <> command "version" (info (pure Version) (progDesc "Print the version"))
            <> command "stats" (info (Stats <$> userOption) (progDesc "Print database counts and top tags"))
            <> command "verify" (info (Verify <$> userOption) (progDesc "Verify counts and FTS consistency"))
            <> command "repair-domains" (info (RepairDomains <$> userOption) (progDesc "Backfill empty domain fields from URLs"))
            <> command "backup" (info (Backup <$> userOption) (progDesc "Back up the control database and every enabled user database (--user narrows it)"))
            <> command "healthcheck" (info (pure Healthcheck) (progDesc "Probe the local /healthz endpoint (container healthcheck)"))
            <> command
                "bench"
                ( info
                    ( Bench
                        <$> option auto (long "iterations" <> value 100 <> metavar "N" <> help "Iterations per query")
                        <*> userOption
                    )
                    (progDesc "Benchmark list/search queries against one library")
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
                "dedupe"
                ( info
                    (DedupeCmd <$> dedupeOpts)
                    (progDesc "Merge same-URL duplicate bookmarks (title matches stay review-only)")
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
                    ( ExportCmd
                        <$> switch (long "json" <> help "Write the versioned eza JSON document instead of Netscape HTML")
                        <*> userOption
                    )
                    (progDesc "Export the library to stdout")
                )
            <> command
                "set-password"
                ( info
                    (SetPasswordCmd <$> setPasswordOpts)
                    (progDesc "Set the account password (prompts twice with echo off)")
                )
            <> command
                "users"
                ( info
                    (UsersCmd <$> usersCommandParser)
                    (progDesc "List and manage accounts (add, enable, disable, reset-password, delete)")
                )
        )

usersCommandParser :: Parser UsersCommand
usersCommandParser =
    subparser
        ( command "list" (info (pure UsersList) (progDesc "List accounts with role, state, and database size"))
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
                    )
                    (progDesc "Create an account and print its one-time recovery codes")
                )
            <> command
                "enable"
                ( info
                    (UsersEnable . T.pack <$> strArgument (metavar "NAME|ID" <> help "Username or id"))
                    (progDesc "Enable an account")
                )
            <> command
                "disable"
                ( info
                    (UsersDisable . T.pack <$> strArgument (metavar "NAME|ID" <> help "Username or id"))
                    (progDesc "Disable an account and revoke its sessions")
                )
            <> command
                "reset-password"
                ( info
                    ( UsersResetPassword
                        <$> (T.pack <$> strArgument (metavar "NAME|ID" <> help "Username or id"))
                        <*> switch (long "password-stdin" <> help "Read the temporary password from stdin (never argv)")
                    )
                    (progDesc "Set a temporary password and revoke the account's sessions")
                )
            <> command
                "delete"
                ( info
                    ( UsersDelete
                        <$> (T.pack <$> strArgument (metavar "NAME|ID" <> help "Username or id"))
                        <*> switch (long "delete-db" <> help "Also delete the account's database and snapshots (cannot be undone)")
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
    Init -> runInit cfg
    Serve -> runServer cfg
    Stats userSelector ->
        withLibrary cfg userSelector $ \path conn -> do
            counts <- bookmarkStats conn
            tags <- allTags conn
            putStrLn ("db: " <> path)
            mapM_ (\(k, n) -> putStrLn (T.unpack k <> ": " <> show n)) counts
            putStrLn ("top tags: " <> T.unpack (T.intercalate ", " [tsName t <> " (" <> T.pack (show (tsCount t)) <> ")" | t <- take 12 tags]))
    Verify userSelector ->
        withLibrary cfg userSelector $ \path conn -> do
            counts <- bookmarkStats conn
            ftsCount <- Db.queryScalar conn "SELECT COUNT(*) FROM bookmarks_fts"
            putStrLn ("db: " <> path)
            mapM_ (\(k, n) -> putStrLn (T.unpack k <> ": " <> show n)) counts
            putStrLn ("fts_rows: " <> show ftsCount)
            let bookmarks = maybe 0 id (lookup "bookmarks" counts)
            if ftsCount == bookmarks
                then putStrLn "verify: ok" >> exitSuccess
                else hPutStrLn stderr "verify: FTS row count does not match bookmarks" >> exitFailure
    Backup userSelector -> runBackupCommand cfg userSelector
    CheckDead opts ->
        withLibrary cfg (cdUser opts) $ \_ conn -> do
            (checked, dead, alive) <- checkDead conn (cdLimit opts) (cdOlderThan opts) (cdIncludeDead opts)
            putStrLn (LBS8.unpack (encode (object ["checked" .= checked, "dead" .= dead, "alive" .= alive])))
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

runInit :: Config -> IO ()
runInit cfg = do
    Db.initDb (cfgDbPath cfg)
    withControl cfg (\_ -> pure ())
    putStrLn ("database initialized: " <> cfgDbPath cfg)
    putStrLn ("control database initialized: " <> cfgControlDbPath cfg)

runBackupCommand :: Config -> Maybe Text -> IO ()
runBackupCommand cfg userSelector = do
    result <- runBackup cfg userSelector
    case result of
        Left message -> die ("backup failed: " <> message)
        Right report -> do
            putStrLn ("backup: " <> brRoot report)
            mapM_ (\target -> putStrLn ("  " <> T.unpack (btLabel target) <> " -> " <> btDest target)) (brTargets report)

runHealthcheck :: Config -> IO ()
runHealthcheck cfg = do
    let port = bindPort (cfgBind cfg)
        url = "http://127.0.0.1:" <> show port <> "/healthz"
    manager <- newTlsManager
    request <- parseRequest url
    response <- httpLbs request manager
    if statusCode (responseStatus response) == 200
        then exitSuccess
        else exitFailure

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
                                    passwordHash <- Password.hashPassword (cfgArgon2 cfg) first
                                    Auth.setAccountPassword conn username passwordHash
                                    syncControlUsername cfg controlUser username
                                    if spResetSessions opts
                                        then do
                                            revoked <- Auth.deleteAllSessions conn
                                            putStrLn ("sessions revoked: " <> show revoked)
                                        else pure ()
                                    if spDisable2fa opts
                                        then do
                                            Auth.setRequirePasskey conn False
                                            putStrLn "passkey requirement cleared"
                                        else pure ()
                                    remaining <- Auth.recoveryCodesRemaining conn
                                    putStrLn ("password updated for " <> T.unpack username)
                                    if remaining == 0
                                        then putStrLn "note: no unused recovery codes remain; regenerate them from the account page"
                                        else putStrLn ("recovery codes unchanged: " <> show remaining <> " unused")

{- | The control row is the login lookup key, so a password-set rename must
land there too when the account is registered in the control database.
-}
syncControlUsername :: Config -> Maybe Control.ControlUser -> Text -> IO ()
syncControlUsername _ Nothing _ = pure ()
syncControlUsername cfg (Just user) username
    | Control.cuUsername user == username = pure ()
    | otherwise =
        withControl cfg $ \control -> do
            _ <- Control.setUsername control (Control.cuId user) username
            pure ()

runImportCommand :: Config -> ImportOpts -> IO ()
runImportCommand cfg opts = do
    raw <- BS.readFile (optFile opts)
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
            Left err -> die (Admin.adminErrorMessage err)
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
            Left err -> die (Admin.adminErrorMessage err)
            Right _ -> putStrLn ("enabled " <> T.unpack (Control.cuUsername user))
    UsersDisable selector -> withSelectedUser control selector $ \user -> do
        changed <- Admin.setUserEnabled cfg control (Control.cuId user) False
        case changed of
            Left err -> die (Admin.adminErrorMessage err)
            Right _ -> putStrLn ("disabled " <> T.unpack (Control.cuUsername user) <> " and revoked its sessions")
    UsersResetPassword selector passwordStdin -> withSelectedUser control selector $ \user -> do
        unless passwordStdin $
            die "users reset-password: pass --password-stdin (the password is never read from argv)"
        password <- psReadStdinLine passwords
        result <- Admin.resetUserPassword cfg control (Control.cuId user) password
        case result of
            Left err -> die (Admin.adminErrorMessage err)
            Right () -> putStrLn ("temporary password set for " <> T.unpack (Control.cuUsername user) <> "; sessions revoked")
    UsersDelete selector deleteDb -> withSelectedUser control selector $ \user -> do
        unless deleteDb $
            die "users delete: pass --delete-db to remove the account's database and snapshots as well"
        result <- Admin.deleteUserAccount cfg control (Control.cuId user) True
        case result of
            Left err -> die (Admin.adminErrorMessage err)
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
