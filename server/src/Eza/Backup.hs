{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Online backup and offline restore of the whole installation.

A backup stamp mirrors the live layout so a restore is a file copy with one
path rewrite:

@
backups/20260101-120000/
    control.db
    manifest.json
    users/3/eza.db
    users/7/eza.db
@

Each database is copied with @VACUUM INTO@ (a consistent online snapshot even
while the writer is active) and then integrity-checked. A failed check removes
the whole stamp directory, so a visible backup is always a verified one. Every
account in the control database is copied, disabled accounts included; the
@--user@ selector narrows the run to one account's library while still copying
the control database. Page snapshots under @users/<id>/snapshots@ are not part
of the stamp (the CLI help says so).

0.4 accepts only this stamp directory shape: a directory without @manifest.json@
(including the first multi-user flat layout @users/<id>.db@ and the single-user
@eza-*.db@ files) is refused, never guessed at.

@restore@ rewrites every control row's @db_path@ to the configured users
directory, backs up the current installation first, copies the user libraries,
and writes @control.db@ last so no reader ever sees rows pointing at files that
have not been restored yet.
-}
module Eza.Backup (
    BackupReport (..),
    BackupTarget (..),
    BackupManifest (..),
    ManifestUser (..),
    RestoreOptions (..),
    RestoreReport (..),
    runBackup,
    runRestore,
    detectStampLayout,
    readManifest,
    pruneBackups,
) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, SomeException, fromException, onException, try)
import Control.Monad (forM_, unless, when)
import Data.Aeson (FromJSON (..), ToJSON (..), decode, encode, object, withObject, (.!=), (.:), (.:?), (.=))
import qualified Data.ByteString.Lazy as LBS
import Data.Char (isDigit)
import Data.List (isPrefixOf, nub)
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime, posixSecondsToUTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Database.SQLite.Simple (Connection, Only (..), Query (..))
import qualified Database.SQLite.Simple as Sqlite
import System.Directory (
    canonicalizePath,
    copyFile,
    createDirectory,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getModificationTime,
    listDirectory,
    removeFile,
    removePathForcibly,
    renameFile,
 )
import System.FilePath (addTrailingPathSeparator, isAbsolute, takeDirectory, takeFileName, (</>))
import System.IO.Error (isAlreadyExistsError)

import qualified Eza.Admin as Admin
import Eza.Config (Config (..))
import Eza.Control (ControlUser (..))
import qualified Eza.Control as Control

-- | One database file in the backup tree.
data BackupTarget = BackupTarget
    { btLabel :: Text
    , btSource :: FilePath
    , btDest :: FilePath
    }
    deriving (Show, Eq)

data BackupReport = BackupReport
    { brRoot :: FilePath
    , brTargets :: [BackupTarget]
    }
    deriving (Show, Eq)

-- ------------------------------------------------------------------ manifest ---

{- | One account recorded in @manifest.json@. The control database stays the
authority for identity and paths; the manifest records which libraries this
run captured, so a restore can tell a partial stamp from a complete one.
-}
data ManifestUser = ManifestUser
    { muId :: Int
    , muUsername :: Text
    , muRole :: Text
    , muEnabled :: Bool
    , muFile :: FilePath
    }
    deriving (Show, Eq)

instance ToJSON ManifestUser where
    toJSON user =
        object
            [ "id" .= muId user
            , "username" .= muUsername user
            , "role" .= muRole user
            , "enabled" .= muEnabled user
            , "file" .= muFile user
            ]

instance FromJSON ManifestUser where
    parseJSON = withObject "ManifestUser" $ \o ->
        ManifestUser
            <$> o .: "id"
            <*> o .: "username"
            <*> o .:? "role" .!= ""
            <*> o .:? "enabled" .!= True
            <*> o .: "file"

data BackupManifest = BackupManifest
    { bmFormat :: Text
    , bmSchema :: Int
    , bmCreatedAt :: Int
    , bmSnapshotsIncluded :: Bool
    , bmUsers :: [ManifestUser]
    }
    deriving (Show, Eq)

instance ToJSON BackupManifest where
    toJSON manifest =
        object
            [ "format" .= bmFormat manifest
            , "schema" .= bmSchema manifest
            , "created_at" .= bmCreatedAt manifest
            , "snapshots_included" .= bmSnapshotsIncluded manifest
            , "users" .= bmUsers manifest
            ]

instance FromJSON BackupManifest where
    parseJSON = withObject "BackupManifest" $ \o ->
        BackupManifest
            <$> o .:? "format" .!= "eza-backup"
            <*> o .:? "schema" .!= 2
            <*> o .:? "created_at" .!= 0
            <*> o .:? "snapshots_included" .!= False
            <*> o .:? "users" .!= []

-- | Read and decode the stamp manifest. 0.4 stamps always have one. -\}
readManifest :: FilePath -> IO (Either Text BackupManifest)
readManifest stamp = do
    let path = stamp </> "manifest.json"
    exists <- doesFileExist path
    if not exists
        then pure (Left ("backup stamp has no manifest.json: " <> T.pack path))
        else do
            raw <- try (LBS.readFile path) :: IO (Either SomeException LBS.ByteString)
            pure $ case raw of
                Left err -> Left ("backup manifest could not be read: " <> T.pack (show err))
                Right bytes -> case decode bytes of
                    Nothing -> Left ("backup manifest is not valid JSON: " <> T.pack path)
                    Just manifest -> Right manifest

detectStampLayout :: FilePath -> IO (Either Text ())
detectStampLayout stamp = do
    exists <- doesDirectoryExist stamp
    if not exists
        then pure (Left ("backup stamp directory does not exist: " <> T.pack stamp))
        else do
            manifestExists <- doesFileExist (stamp </> "manifest.json")
            controlExists <- doesFileExist (stamp </> "control.db")
            pure $
                if manifestExists && controlExists
                    then Right ()
                    else
                        if not manifestExists
                            then Left ("not a 0.4 backup stamp (missing manifest.json); pre-0.4 flat stamps are not accepted: " <> T.pack stamp)
                            else Left ("not a backup stamp (missing control.db): " <> T.pack stamp)

-- -------------------------------------------------------------------- backup ---

{- | Back up the control database and every account library into one verified
stamp directory. @--user@ narrows the user libraries to one account (the
control database is still copied so the stamp keeps the account map).
-}
runBackup :: Config -> Maybe Text -> IO (Either Text BackupReport)
runBackup cfg selector = runBackupInternal cfg selector True

{- | The backup implementation. The restore path disables the retention prune
while it auto-backs the current installation, so an old stamp being restored
cannot be pruned out from under the restore.
-}
runBackupInternal :: Config -> Maybe Text -> Bool -> IO (Either Text BackupReport)
runBackupInternal cfg selector pruneOld = do
    ready <-
        try (createDirectoryIfMissing True (cfgBackupDir cfg)) ::
            IO (Either SomeException ())
    case ready of
        Left (err :: SomeException) ->
            pure
                ( Left
                    ( "the backup directory "
                        <> T.pack (cfgBackupDir cfg)
                        <> " could not be created: "
                        <> T.pack (show err)
                    )
                )
        Right () -> do
            now <- getPOSIXTime
            let stamp = formatTime defaultTimeLocale "%Y%m%d-%H%M%S" (posixSecondsToUTCTime now)
            rootResult <- newStampDir (cfgBackupDir cfg) stamp
            case rootResult of
                Left message -> pure (Left message)
                Right root -> do
                    let controlDest = root </> "control.db"
                        usersDir = root </> "users"
                    opened <- try openControl
                    case opened of
                        Left (err :: SomeException) ->
                            pure (Left ("the control database could not be opened for backup: " <> T.pack (show err)))
                        Right (control, users) -> do
                            result <- try (runPlan cfg control users selector root controlDest usersDir)
                            Sqlite.close control
                            case result of
                                Left (err :: SomeException) -> do
                                    cleanupFailed root
                                    pure (Left (T.pack (show err)))
                                Right report -> do
                                    when pruneOld $ do
                                        pruneBackups (cfgBackupDir cfg) (cfgBackupKeepDays cfg)
                                        prunePreMigrationSiblings cfg users
                                    pure (Right report)
  where
    openControl = do
        conn <- Control.openControlDb (cfgControlDbPath cfg)
        users <- Control.listUsers conn `onException` Sqlite.close conn
        pure (conn, users)

runPlan ::
    Config ->
    Connection ->
    [ControlUser] ->
    Maybe Text ->
    FilePath ->
    FilePath ->
    FilePath ->
    IO BackupReport
runPlan _cfg control users selector root controlDest usersDir = do
    createDirectoryIfMissing True usersDir
    backupFromConnection control controlDest
    controlOk <- verify controlDest
    unless controlOk (ioError (userError "integrity check failed on the control database backup"))
    targets <- selectTargets control users selector usersDir
    forM_ targets $ \target -> do
        backupFile (btSource target) (btDest target)
        ok <- verify (btDest target)
        unless ok (ioError (userError ("integrity check failed for " <> T.unpack (btLabel target))))
    writeManifest root (manifestFor users targets)
    pure (BackupReport root targets)

{- | Every account, or exactly the one @--user@ names. Disabled accounts are
included: the stamp's control database keeps their rows, so leaving their
libraries out would turn a full restore into silent data loss. An installation
with no control rows has nothing authoritative to back up and fails instead of
inventing a flat-file target.
-}
selectTargets ::
    Connection ->
    [ControlUser] ->
    Maybe Text ->
    FilePath ->
    IO [BackupTarget]
selectTargets control users selector usersDir = case selector of
    Just raw -> do
        found <- Admin.resolveSelector control raw
        case found of
            Nothing -> ioError (userError ("no account matches --user " <> T.unpack raw))
            Just user -> pure [targetFor user]
    Nothing ->
        if null users
            then ioError (userError "no accounts are registered in the control database; create an account before backing it up")
            else pure (map targetFor users)
  where
    targetFor user =
        BackupTarget
            ("user " <> cuUsername user)
            (cuDbPath user)
            (usersDir </> show (cuId user) </> "eza.db")

manifestFor :: [ControlUser] -> [BackupTarget] -> BackupManifest
manifestFor users targets =
    BackupManifest
        { bmFormat = "eza-backup"
        , bmSchema = 2
        , bmCreatedAt = 0
        , bmSnapshotsIncluded = False
        , bmUsers = map entry (filter isTargetUser users)
        }
  where
    isTargetUser user =
        any (\target -> takeFileName (takeDirectory (btDest target)) == show (cuId user)) targets
    entry user =
        ManifestUser
            { muId = cuId user
            , muUsername = cuUsername user
            , muRole = if cuRole user == Control.RoleAdmin then "admin" else "member"
            , muEnabled = isNothing (cuDisabledAt user)
            , muFile = "users" </> show (cuId user) </> "eza.db"
            }

writeManifest :: FilePath -> BackupManifest -> IO ()
writeManifest root manifest = do
    now <- floor <$> getPOSIXTime
    LBS.writeFile (root </> "manifest.json") (encode manifest{bmCreatedAt = now})

{- | @VACUUM INTO@ through an existing connection: a consistent snapshot even
while the server is writing.
-}
backupFromConnection :: Connection -> FilePath -> IO ()
backupFromConnection conn dest = do
    removeIfExists dest
    Sqlite.execute_ conn (Query (T.pack ("VACUUM INTO " <> quoteLiteral dest)))

{- | Copy one live user database into the stamp. A separate connection keeps
the control connection out of another database's WAL.
-}
backupFile :: FilePath -> FilePath -> IO ()
backupFile source dest = do
    exists <- doesFileExist source
    unless exists (ioError (userError ("database file is missing: " <> source)))
    createDirectoryIfMissing True (takeDirectory dest)
    removeIfExists dest
    conn <- Sqlite.open source
    result <- try (Sqlite.execute_ conn (Query (T.pack ("VACUUM INTO " <> quoteLiteral dest)))) :: IO (Either SomeException ())
    Sqlite.close conn
    either (ioError . userError . show) pure result

-- | SQLite string literal escaping for the @VACUUM INTO@ target path.
quoteLiteral :: FilePath -> String
quoteLiteral path = "'" <> concatMap escape path <> "'"
  where
    escape '\'' = "''"
    escape c = [c]

verify :: FilePath -> IO Bool
verify path = do
    result <- try $ do
        conn <- Sqlite.open path
        rows <- Sqlite.query_ conn "PRAGMA integrity_check" :: IO [Only Text]
        Sqlite.close conn
        pure (case rows of [Only "ok"] -> True; _ -> False)
    pure (either (const False) id (result :: Either SomeException Bool))

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
    exists <- doesFileExist path
    when exists (removeFile path)

cleanupFailed :: FilePath -> IO ()
cleanupFailed root = voidSafe (removePathForcibly root)

{- | Prune the per-database sibling @backups@ directories as well as the
configured backup directory. "Eza.Db.preMigrationBackup" writes its verified
copy to @EZA_BACKUP_DIR@ when that is set and next to the database
(@users/<id>/backups@) when it is not, so retention has to scan both places or
the default installation would accumulate one full copy per account per schema
migration forever.
-}
prunePreMigrationSiblings :: Config -> [ControlUser] -> IO ()
prunePreMigrationSiblings cfg users =
    forM_ (nub (map (siblingDirectory . cuDbPath) users)) $ \directory -> do
        exists <- doesDirectoryExist directory
        when exists (pruneBackups directory (cfgBackupKeepDays cfg))
  where
    siblingDirectory dbPath = takeDirectory dbPath </> "backups"

{- | Remove backup runs and pre-migration copies older than the keep window.
The @pre-migration-*.db@ copies written by "Eza.Db" are pruned too; they are
full database copies and would otherwise accumulate one per account and schema
version forever.
-}
pruneBackups :: FilePath -> Int -> IO ()
pruneBackups directory keepDays = do
    now <- getCurrentTime
    entries <- listDirectory directory
    forM_ entries $ \name -> do
        let path = directory </> name
            stampLike = isStampName name
            preMigrationFile = "pre-migration-" `T.isPrefixOf` T.pack name && ".db" `T.isSuffixOf` T.pack name
        isDirectory <- if stampLike then doesDirectoryExist path else pure False
        when (isDirectory || preMigrationFile) $ do
            mtime <- getModificationTime path
            when (diffUTCTime now mtime > fromIntegral (max 1 keepDays) * 86400) $
                voidSafe (removePathForcibly path)

{- | A run directory is @YYYYMMDD-HHMMSS@, optionally with a @-N@ suffix when
two runs started within the same second; both forms are pruned.
-}
isStampName :: FilePath -> Bool
isStampName name = case splitAt 15 name of
    (stamp, suffix) ->
        length stamp == 15
            && all (\c -> isDigit c || c == '-') stamp
            && (stamp !! 8) == '-'
            && validSuffix suffix
  where
    validSuffix "" = True
    validSuffix ('-' : rest) = not (null rest) && all isDigit rest
    validSuffix _ = False

{- | Never reuse an existing run directory. The directory is created atomically
(@createDirectory@ fails when it exists) so two backups started in the same
second still get separate stamps. Only an already-existing name is retried, and
only for a handful of attempts: a real creation failure (permissions, a
read-only mount, a full disk) is reported as an actionable error instead of
being retried forever.
-}
newStampDir :: FilePath -> String -> IO (Either Text FilePath)
newStampDir base stamp = go (1 :: Int)
  where
    maxAttempts = 5 :: Int
    go attempt
        | attempt > maxAttempts =
            pure
                ( Left
                    ( "the backup stamp directory could not be created under "
                        <> T.pack base
                        <> ": "
                        <> T.pack (show (attempt - 1))
                        <> " candidate names already exist (check the system clock and the backup directory)"
                    )
                )
        | otherwise = do
            let name = if attempt == (1 :: Int) then stamp else stamp <> "-" <> show attempt
                path = base </> name
            result <- try (createDirectory path) :: IO (Either SomeException ())
            case result of
                Right () -> pure (Right path)
                Left err
                    | Just ioErrorValue <- fromException err :: Maybe IOException
                    , isAlreadyExistsError ioErrorValue -> do
                        -- A same-second collision: wait a moment so the next
                        -- attempt is likely to find a free suffix.
                        threadDelay (attempt * 100 * 1000)
                        go (attempt + 1)
                    | otherwise ->
                        pure
                            ( Left
                                ( "the backup stamp directory could not be created under "
                                    <> T.pack base
                                    <> ": "
                                    <> T.pack (show err)
                                    <> " (check that the backup directory exists and is writable)"
                                )
                            )

-- ------------------------------------------------------------------- restore ---

data RestoreOptions = RestoreOptions
    { roStamp :: FilePath
    , roDryRun :: Bool
    , roForce :: Bool
    -- ^ Continue when the current installation cannot be auto-backed-up.
    }
    deriving (Show, Eq)

data RestoreReport = RestoreReport
    { rrsStamp :: FilePath
    , rrsDryRun :: Bool
    , rrsAutoBackup :: Maybe FilePath
    , rrsRestored :: [(Int, Text)]
    , rrsPreserved :: [(Int, Text)]
    , rrsCarried :: [(Int, Text)]
    {- ^ Accounts that exist only in the current installation: their rows and
    libraries are kept (never deleted by a partial stamp).
    -}
    , rrsDropped :: [(Int, Text)]
    -- ^ Always empty now (kept for the CLI report shape).
    , rrsTargets :: [BackupTarget]
    , rrsControlTarget :: FilePath
    }
    deriving (Show, Eq)

-- | One account the restore will write from the stamp.
data RestoreEntry = RestoreEntry
    { reUser :: ControlUser
    , reSource :: FilePath
    , reDest :: FilePath
    }

{- | One account whose stamp library is absent but whose current installation
still has a copy: keep the current database and rewrite its control path.
-}
data PreservedEntry = PreservedEntry
    { peUser :: ControlUser
    , peCurrent :: FilePath
    , peDest :: FilePath
    }

data RestorePlan = RestorePlan
    { rpStamp :: FilePath
    , rpEntries :: [RestoreEntry]
    , rpPreserved :: [PreservedEntry]
    , rpCarried :: [PreservedEntry]
    -- ^ Current-only accounts: insert their control rows and keep their files.
    , rpControlSource :: FilePath
    }

-- | What a stamp holds.
data StampContents = StampContents
    { scUsers :: [ControlUser]
    , scManifest :: Maybe BackupManifest
    }

{- | Restore a backup stamp over the configured installation.

Ordering matters: the stamp is validated first, the current installation is
backed up, the user libraries are copied, and @control.db@ is written last with
every @db_path@ rewritten to the configured users directory. A crash before
the last step therefore leaves the previous control database (and the previous
installation) in charge.
-}
runRestore :: Config -> RestoreOptions -> IO (Either Text RestoreReport)
runRestore cfg opts = do
    detected <- detectStampLayout (roStamp opts)
    case detected of
        Left message -> pure (Left message)
        Right () -> do
            contents <- readStampContents (roStamp opts)
            case contents of
                Left message -> pure (Left message)
                Right stamp -> do
                    planResult <- buildRestorePlan cfg (roStamp opts) stamp
                    case planResult of
                        Left message -> pure (Left message)
                        Right plan
                            | roDryRun opts -> pure (Right (dryRunReport cfg opts plan))
                            | otherwise -> applyRestore cfg opts plan

readStampContents :: FilePath -> IO (Either Text StampContents)
readStampContents stamp = do
    manifest <- readManifest stamp
    case manifest of
        Left message -> pure (Left message)
        Right value -> do
            result <- try $ do
                conn <- Sqlite.open (stamp </> "control.db")
                users <- Control.listUsers conn
                Sqlite.close conn
                pure users
            pure $ case result of
                Left (err :: SomeException) ->
                    Left ("the stamp control database could not be read: " <> T.pack (show err))
                Right users -> Right (StampContents users (Just value))

buildRestorePlan :: Config -> FilePath -> StampContents -> IO (Either Text RestorePlan)
buildRestorePlan cfg stamp contents = do
    controlOk <- verify (stamp </> "control.db")
    if not controlOk
        then pure (Left "the stamp control database failed its integrity check")
        else do
            currentUsers <- readCurrentUsers cfg
            case validateRestoreAccounts (scUsers contents) currentUsers of
                Left message -> pure (Left message)
                Right () -> do
                    result <- foldRestorePlan cfg stamp contents currentUsers (scUsers contents) ([], [])
                    case result of
                        Left message -> pure (Left message)
                        Right (entries, preserved)
                            | null entries && null preserved ->
                                pure (Left "the stamp contains no account libraries to restore")
                            | otherwise ->
                                pure
                                    ( Right
                                        RestorePlan
                                            { rpStamp = stamp
                                            , rpEntries = entries
                                            , rpPreserved = preserved
                                            , rpCarried = carriedEntries cfg (scUsers contents) currentUsers
                                            , rpControlSource = stamp </> "control.db"
                                            }
                                    )

{- | Decide, for every account in the stamp's control database, whether its
library is restored from the stamp or kept from the current installation (a
partial @--user@ stamp that skipped it). Nothing is dropped or relinked: an
account the stamp does not capture must be present and consistent in the
current installation, otherwise the restore refuses with an actionable error.
A library that exists in the stamp but fails its integrity check refuses the
whole restore.
-}
foldRestorePlan ::
    Config ->
    FilePath ->
    StampContents ->
    [ControlUser] ->
    [ControlUser] ->
    ([RestoreEntry], [PreservedEntry]) ->
    IO (Either Text ([RestoreEntry], [PreservedEntry]))
foldRestorePlan cfg stamp contents currentUsers pending (entries, preserved) =
    case pending of
        [] -> pure (Right (reverse entries, reverse preserved))
        (user : rest) -> do
            sourceResult <- stampSourceFor stamp contents (cuId user)
            let dest = cfgUsersDir cfg </> show (cuId user) </> "eza.db"
            case sourceResult of
                Left message -> pure (Left message)
                Right (Just path) -> do
                    ok <- verify path
                    if not ok
                        then pure (Left ("the stamp library for account " <> cuUsername user <> " failed its integrity check: " <> T.pack path))
                        else
                            foldRestorePlan cfg stamp contents currentUsers rest (RestoreEntry user path dest : entries, preserved)
                Right Nothing ->
                    case lookup (cuId user) [(cuId current, current) | current <- currentUsers] of
                        Just current -> do
                            currentExists <- doesFileExist (cuDbPath current)
                            if currentExists
                                then
                                    foldRestorePlan cfg stamp contents currentUsers rest (entries, PreservedEntry user (cuDbPath current) dest : preserved)
                                else
                                    pure
                                        ( Left
                                            ( "the backup stamp does not capture the library for account "
                                                <> cuUsername user
                                                <> " (id "
                                                <> T.pack (show (cuId user))
                                                <> ") and the current installation has no library file for it; restore a full stamp instead"
                                            )
                                        )
                        Nothing ->
                            pure
                                ( Left
                                    ( "the backup stamp does not capture the library for account "
                                        <> cuUsername user
                                        <> " (id "
                                        <> T.pack (show (cuId user))
                                        <> ") and the current installation has no account with that id; this looks like a partial --user stamp restored on an installation where that account does not exist"
                                    )
                                )

{- | Refuse a restore whose account map cannot be applied safely: the stamp and
the current installation disagree about who owns an account id or a username.
Two different accounts' libraries are never silently relinked.
-}
validateRestoreAccounts :: [ControlUser] -> [ControlUser] -> Either Text ()
validateRestoreAccounts stampUsers currentUsers =
    case idConflicts <> usernameConflicts of
        [] -> Right ()
        (message : _) -> Left message
  where
    findCurrent userId = lookup userId [(cuId current, current) | current <- currentUsers]
    stampIds = map cuId stampUsers
    sameName left right = T.toCaseFold left == T.toCaseFold right
    idConflicts =
        [ "the backup stamp has account id "
            <> T.pack (show (cuId stampUser))
            <> " ("
            <> cuUsername stampUser
            <> ") but the current installation has a different account with that id ("
            <> cuUsername current
            <> "); refusing to relink the libraries"
        | stampUser <- stampUsers
        , Just current <- [findCurrent (cuId stampUser)]
        , not (sameName (cuUsername current) (cuUsername stampUser))
        ]
    usernameConflicts =
        [ "the backup stamp has an account named "
            <> cuUsername stampUser
            <> " (id "
            <> T.pack (show (cuId stampUser))
            <> ") and the current installation has a different account with the same name (id "
            <> T.pack (show (cuId current))
            <> "); refusing to merge the account maps"
        | current <- currentUsers
        , cuId current `notElem` stampIds
        , stampUser <- stampUsers
        , sameName (cuUsername stampUser) (cuUsername current)
        ]

{- | Accounts that exist only in the current installation. Their control rows
and libraries are carried into the restored database instead of being deleted
when the stamp's control copy replaces the current one.
-}
carriedEntries :: Config -> [ControlUser] -> [ControlUser] -> [PreservedEntry]
carriedEntries cfg stampUsers currentUsers =
    [ PreservedEntry current (cuDbPath current) (cfgUsersDir cfg </> show (cuId current) </> "eza.db")
    | current <- currentUsers
    , cuId current `notElem` map cuId stampUsers
    ]

{- | Where a stamp keeps one account's library: always @users/<id>/eza.db@, as
named by the manifest. A manifest that names a file which is missing is
reported as absent (the current installation's copy is kept); a manifest whose
path is not the expected file inside the stamp refuses the whole restore.
-}
stampSourceFor :: FilePath -> StampContents -> Int -> IO (Either Text (Maybe FilePath))
stampSourceFor stamp contents userId =
    case scManifest contents of
        Nothing -> pure (Right Nothing)
        Just manifest ->
            case [muFile user | user <- bmUsers manifest, muId user == userId] of
                [] -> pure (Right Nothing)
                (relative : _) -> do
                    resolved <- stampFileContained stamp ("users" </> show userId </> "eza.db") relative
                    case resolved of
                        Left message -> pure (Left message)
                        Right candidate -> do
                            exists <- doesFileExist candidate
                            pure (Right (if exists then Just candidate else Nothing))

{- | Resolve one file a stamp manifest names. The manifest is stamp data, not
trusted text: the backup layout is fixed, so the entry has to be exactly the
expected relative path and both its lexical form and its canonical form (which
follows symlinks) have to stay inside the stamp. Without this a moved or
tampered manifest could name @../../other.db@ or @/tmp/other.db@ and have that
file copied over an account's library.
-}
stampFileContained :: FilePath -> FilePath -> FilePath -> IO (Either Text FilePath)
stampFileContained stamp expected relative
    | isAbsolute relative || relative /= expected = refuse
    | otherwise = do
        rootResult <- try (canonicalizePath stamp) :: IO (Either SomeException FilePath)
        candidateResult <- try (canonicalizePath (stamp </> expected)) :: IO (Either SomeException FilePath)
        case (rootResult, candidateResult) of
            (Right root, Right candidate)
                | isUnder candidate root -> pure (Right candidate)
            _ -> refuse
  where
    isUnder path root = path == root || addTrailingPathSeparator root `isPrefixOf` path
    refuse =
        pure
            ( Left
                ( "the backup manifest names an invalid file: "
                    <> T.pack relative
                    <> " (expected "
                    <> T.pack expected
                    <> " inside the stamp)"
                )
            )

readCurrentUsers :: Config -> IO [ControlUser]
readCurrentUsers cfg = do
    exists <- doesFileExist (cfgControlDbPath cfg)
    if not exists
        then pure []
        else do
            result <- try $ do
                conn <- Sqlite.open (cfgControlDbPath cfg)
                users <- Control.listUsers conn
                Sqlite.close conn
                pure users
            pure (either (\(_ :: SomeException) -> []) id result)

dryRunReport :: Config -> RestoreOptions -> RestorePlan -> RestoreReport
dryRunReport cfg opts plan =
    RestoreReport
        { rrsStamp = roStamp opts
        , rrsDryRun = True
        , rrsAutoBackup = Nothing
        , rrsRestored = [(cuId (reUser entry), cuUsername (reUser entry)) | entry <- rpEntries plan]
        , rrsPreserved = [(cuId (peUser entry), cuUsername (peUser entry)) | entry <- rpPreserved plan]
        , rrsCarried = [(cuId (peUser entry), cuUsername (peUser entry)) | entry <- rpCarried plan]
        , rrsDropped = []
        , rrsTargets =
            [ BackupTarget ("user " <> cuUsername (reUser entry)) (reSource entry) (reDest entry)
            | entry <- rpEntries plan
            ]
        , rrsControlTarget = cfgControlDbPath cfg
        }

applyRestore :: Config -> RestoreOptions -> RestorePlan -> IO (Either Text RestoreReport)
applyRestore cfg opts plan = do
    backupResult <- autoBackup cfg
    case backupResult of
        Left message
            | not (roForce opts) -> pure (Left message)
            | otherwise -> continue Nothing
        Right stampPath -> continue stampPath
  where
    continue backupStamp = do
        result <- try (applyNow backupStamp) :: IO (Either SomeException RestoreReport)
        pure $ case result of
            Left err -> Left ("restore failed: " <> T.pack (show err))
            Right report -> Right report

    applyNow backupStamp = do
        forM_ (rpPreserved plan) $ \entry ->
            when (peCurrent entry /= peDest entry) (copyDatabaseFile (peCurrent entry) (peDest entry))
        forM_ (rpCarried plan) $ \entry ->
            when (peCurrent entry /= peDest entry) (copyDatabaseFile (peCurrent entry) (peDest entry))
        forM_ (rpEntries plan) $ \entry ->
            copyDatabaseFile (reSource entry) (reDest entry)
        writeRestoredControl cfg plan
        pure
            RestoreReport
                { rrsStamp = rpStamp plan
                , rrsDryRun = False
                , rrsAutoBackup = backupStamp
                , rrsRestored = [(cuId (reUser entry), cuUsername (reUser entry)) | entry <- rpEntries plan]
                , rrsPreserved = [(cuId (peUser entry), cuUsername (peUser entry)) | entry <- rpPreserved plan]
                , rrsCarried = [(cuId (peUser entry), cuUsername (peUser entry)) | entry <- rpCarried plan]
                , rrsDropped = []
                , rrsTargets =
                    [ BackupTarget ("user " <> cuUsername (reUser entry)) (reSource entry) (reDest entry)
                    | entry <- rpEntries plan
                    ]
                , rrsControlTarget = cfgControlDbPath cfg
                }

{- | Back up the current installation before the overwrite. An installation
without a control database has nothing authoritative to back up.
-}
autoBackup :: Config -> IO (Either Text (Maybe FilePath))
autoBackup cfg = do
    exists <- doesFileExist (cfgControlDbPath cfg)
    if not exists
        then pure (Right Nothing)
        else do
            result <- runBackupInternal cfg Nothing False
            pure $ case result of
                Left message ->
                    Left
                        ( "the current installation could not be backed up before restoring: "
                            <> message
                            <> ". Use --force to restore anyway"
                        )
                Right report -> Right (Just (brRoot report))

{- | Rewrite the stamp's control database into place. Every restored or kept
account's @db_path@ is rewritten to the configured users directory; accounts
that exist only in the current installation are inserted so a partial stamp
never deletes them. Nothing is deleted from the restored control database. The
file is written last and atomically.
-}
writeRestoredControl :: Config -> RestorePlan -> IO ()
writeRestoredControl cfg plan = do
    let target = cfgControlDbPath cfg
        temp = target <> ".restore-tmp"
    removeIfExists temp
    removeIfExists (temp <> "-wal")
    removeIfExists (temp <> "-shm")
    createDirectoryIfMissing True (takeDirectory temp)
    copyFile (rpControlSource plan) temp
    conn <- Sqlite.open temp
    forM_ (rpEntries plan) $ \entry ->
        Sqlite.execute
            conn
            "UPDATE users SET db_path = ? WHERE id = ?"
            (reDest entry, cuId (reUser entry))
    forM_ (rpPreserved plan) $ \preserved ->
        Sqlite.execute
            conn
            "UPDATE users SET db_path = ? WHERE id = ?"
            (peDest preserved, cuId (peUser preserved))
    forM_ (rpCarried plan) $ \carried ->
        Sqlite.execute
            conn
            "INSERT INTO users (id, username, db_path, role, credential_handle, created_at, disabled_at, last_login_at) VALUES (?,?,?,?,?,?,?,?)"
            ( cuId (peUser carried)
            , cuUsername (peUser carried)
            , peDest carried
            , Control.userRoleText (cuRole (peUser carried))
            , cuCredentialHandle (peUser carried)
            , cuCreatedAt (peUser carried)
            , cuDisabledAt (peUser carried)
            , cuLastLoginAt (peUser carried)
            )
    rows <- Sqlite.query_ conn "PRAGMA integrity_check" :: IO [Only Text]
    let intact = case rows of [Only "ok"] -> True; _ -> False
    _ <- Sqlite.execute_ conn "PRAGMA journal_mode = DELETE"
    Sqlite.close conn
    unless intact (ioError (userError "the rewritten control database failed its integrity check"))
    removeIfExists (target <> "-wal")
    removeIfExists (target <> "-shm")
    removeIfExists target
    renameFile temp target

{- | Copy one database file over the destination atomically: write a sibling
temp file, drop stale WAL/SHM sidecars, then rename. A stale @-wal@ from
the previous database must never be applied to the restored file.
-}
copyDatabaseFile :: FilePath -> FilePath -> IO ()
copyDatabaseFile source dest = do
    createDirectoryIfMissing True (takeDirectory dest)
    let temp = dest <> ".restore-tmp"
    removeIfExists temp
    copyFile source temp
    removeIfExists (dest <> "-wal")
    removeIfExists (dest <> "-shm")
    removeIfExists (dest <> "-journal")
    removeIfExists dest
    renameFile temp dest

voidSafe :: IO () -> IO ()
voidSafe action = do
    _ <- try action :: IO (Either SomeException ())
    pure ()
