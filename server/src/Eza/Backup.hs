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

A stamp written by the first multi-user layout (@users/<id>.db@, no manifest)
still restores: the account list comes from its control database, and a
missing library for an account keeps the current installation's copy when one
exists.

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
    StampLayout (..),
    RestoreOptions (..),
    RestoreReport (..),
    runBackup,
    runRestore,
    detectStampLayout,
    readManifest,
    pruneBackups,
) where

import Control.Exception (SomeException, onException, try)
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
    , bmLegacyDb :: Maybe FilePath
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
            , "legacy_db" .= bmLegacyDb manifest
            ]

instance FromJSON BackupManifest where
    parseJSON = withObject "BackupManifest" $ \o ->
        BackupManifest
            <$> o .:? "format" .!= "eza-backup"
            <*> o .:? "schema" .!= 2
            <*> o .:? "created_at" .!= 0
            <*> o .:? "snapshots_included" .!= False
            <*> o .:? "users" .!= []
            <*> o .:? "legacy_db"

{- | How the libraries inside a stamp are laid out. New stamps have a manifest
and @users/<id>/eza.db@; the first multi-user stamps wrote @users/<id>.db@
and had no manifest.
-}
data StampLayout = StampLayoutManifest | StampLayoutFlat
    deriving (Show, Eq)

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

detectStampLayout :: FilePath -> IO (Either Text StampLayout)
detectStampLayout stamp = do
    exists <- doesDirectoryExist stamp
    if not exists
        then pure (Left ("backup stamp directory does not exist: " <> T.pack stamp))
        else do
            manifestExists <- doesFileExist (stamp </> "manifest.json")
            controlExists <- doesFileExist (stamp </> "control.db")
            pure $
                if manifestExists
                    then Right StampLayoutManifest
                    else
                        if controlExists
                            then Right StampLayoutFlat
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
    createDirectoryIfMissing True (cfgBackupDir cfg)
    now <- getPOSIXTime
    let stamp = formatTime defaultTimeLocale "%Y%m%d-%H%M%S" (posixSecondsToUTCTime now)
    rootResult <- try (newStampDir (cfgBackupDir cfg) stamp)
    case rootResult of
        Left (err :: SomeException) ->
            pure (Left ("the backup stamp directory could not be created: " <> T.pack (show err)))
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
runPlan cfg control users selector root controlDest usersDir = do
    createDirectoryIfMissing True usersDir
    backupFromConnection control controlDest
    controlOk <- verify controlDest
    unless controlOk (ioError (userError "integrity check failed on the control database backup"))
    targets <- selectTargets cfg control users selector usersDir
    forM_ targets $ \target -> do
        backupFile (btSource target) (btDest target)
        ok <- verify (btDest target)
        unless ok (ioError (userError ("integrity check failed for " <> T.unpack (btLabel target))))
    writeManifest root (manifestFor users targets)
    pure (BackupReport root targets)

{- | Every account, or exactly the one @--user@ names. Disabled accounts are
included: the stamp's control database keeps their rows, so leaving their
libraries out would turn a full restore into silent data loss. An install
that still has no control rows backs up the legacy single-user database so
an upgrade path never loses the only copy.
-}
selectTargets ::
    Config ->
    Connection ->
    [ControlUser] ->
    Maybe Text ->
    FilePath ->
    IO [BackupTarget]
selectTargets cfg control users selector usersDir = case selector of
    Just raw -> do
        found <- Admin.resolveSelector control raw
        case found of
            Nothing -> ioError (userError ("no account matches --user " <> T.unpack raw))
            Just user -> pure [targetFor user]
    Nothing ->
        if null users
            then do
                legacyExists <- doesFileExist (cfgDbPath cfg)
                pure
                    [ BackupTarget "legacy" (cfgDbPath cfg) (usersDir </> "legacy.db")
                    | legacyExists
                    ]
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
        , bmLegacyDb = if hasLegacy targets then Just ("users" </> "legacy.db") else Nothing
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
    hasLegacy = any ((== "legacy") . btLabel)

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
    forM_ (nub (map siblingDirectory (cfgDbPath cfg : map cuDbPath users))) $ \directory -> do
        exists <- doesDirectoryExist directory
        when exists (pruneBackups directory (cfgBackupKeepDays cfg))
  where
    siblingDirectory dbPath = takeDirectory dbPath </> "backups"

{- | Remove backup runs and pre-migration copies older than the keep window.
Legacy flat @eza-<stamp>.db@ files from the single-user layout and the
@pre-migration-*.db@ copies written by "Eza.Db" are pruned too; the latter are
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
            legacyFile = "eza-" `T.isPrefixOf` T.pack name && ".db" `T.isSuffixOf` T.pack name
            preMigrationFile = "pre-migration-" `T.isPrefixOf` T.pack name && ".db" `T.isSuffixOf` T.pack name
        isDirectory <- if stampLike then doesDirectoryExist path else pure False
        when (isDirectory || legacyFile || preMigrationFile) $ do
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
second still get separate stamps.
-}
newStampDir :: FilePath -> String -> IO FilePath
newStampDir base stamp = go (1 :: Int)
  where
    go attempt = do
        let name = if attempt == (1 :: Int) then stamp else stamp <> "-" <> show attempt
            path = base </> name
        result <- try (createDirectory path) :: IO (Either SomeException ())
        case result of
            Right () -> pure path
            Left _ -> go (attempt + 1)

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
    , rrsDropped :: [(Int, Text)]
    , rrsTargets :: [BackupTarget]
    , rrsControlTarget :: FilePath
    , rrsLegacyTarget :: Maybe FilePath
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
    , rpDropped :: [ControlUser]
    , rpLegacySource :: Maybe FilePath
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
        Right layout -> do
            contents <- readStampContents (roStamp opts) layout
            case contents of
                Left message -> pure (Left message)
                Right stamp -> do
                    planResult <- buildRestorePlan cfg (roStamp opts) layout stamp
                    case planResult of
                        Left message -> pure (Left message)
                        Right plan
                            | roDryRun opts -> pure (Right (dryRunReport cfg opts plan))
                            | otherwise -> applyRestore cfg opts plan

readStampContents :: FilePath -> StampLayout -> IO (Either Text StampContents)
readStampContents stamp layout = do
    manifest <-
        case layout of
            StampLayoutFlat -> pure (Right Nothing)
            StampLayoutManifest -> do
                found <- readManifest stamp
                pure (Just <$> found)
    case manifest of
        Left message -> pure (Left message)
        Right manifestValue -> do
            result <- try $ do
                conn <- Sqlite.open (stamp </> "control.db")
                users <- Control.listUsers conn
                Sqlite.close conn
                pure users
            pure $ case result of
                Left (err :: SomeException) ->
                    Left ("the stamp control database could not be read: " <> T.pack (show err))
                Right users -> Right (StampContents users manifestValue)

buildRestorePlan :: Config -> FilePath -> StampLayout -> StampContents -> IO (Either Text RestorePlan)
buildRestorePlan cfg stamp layout contents = do
    controlOk <- verify (stamp </> "control.db")
    if not controlOk
        then pure (Left "the stamp control database failed its integrity check")
        else do
            legacyResult <- case layout of
                StampLayoutFlat -> do
                    exists <- doesFileExist (stamp </> "users" </> "legacy.db")
                    pure (Right (if exists then Just (stamp </> "users" </> "legacy.db") else Nothing))
                StampLayoutManifest ->
                    case scManifest contents >>= bmLegacyDb of
                        Nothing -> pure (Right Nothing)
                        Just relative -> do
                            resolved <- stampFileContained stamp ("users" </> "legacy.db") relative
                            pure (fmap Just resolved)
            case legacyResult of
                Left message -> pure (Left message)
                Right legacySource -> do
                    legacyOk <- case legacySource of
                        Nothing -> pure True
                        Just path -> verify path
                    if not legacyOk
                        then pure (Left "the stamp's legacy database failed its integrity check")
                        else do
                            currentUsers <- readCurrentUsers cfg
                            result <- foldRestorePlan cfg stamp layout contents currentUsers (scUsers contents) ([], [], [])
                            case result of
                                Left message -> pure (Left message)
                                Right (entries, preserved, dropped)
                                    | null entries && null preserved && legacySource == Nothing ->
                                        pure (Left "the stamp contains no account libraries to restore")
                                    | otherwise ->
                                        pure
                                            ( Right
                                                RestorePlan
                                                    { rpStamp = stamp
                                                    , rpEntries = entries
                                                    , rpPreserved = preserved
                                                    , rpDropped = dropped
                                                    , rpLegacySource = legacySource
                                                    , rpControlSource = stamp </> "control.db"
                                                    }
                                            )

{- | Decide, for every account in the stamp's control database, whether its
library is restored from the stamp, kept from the current installation (an old
stamp that skipped disabled accounts), or dropped (no copy anywhere). A
library that exists in the stamp but fails its integrity check refuses the
whole restore.
-}
foldRestorePlan ::
    Config ->
    FilePath ->
    StampLayout ->
    StampContents ->
    [ControlUser] ->
    [ControlUser] ->
    ([RestoreEntry], [PreservedEntry], [ControlUser]) ->
    IO (Either Text ([RestoreEntry], [PreservedEntry], [ControlUser]))
foldRestorePlan cfg stamp layout contents currentUsers pending (entries, preserved, dropped) =
    case pending of
        [] -> pure (Right (reverse entries, reverse preserved, reverse dropped))
        (user : rest) -> do
            sourceResult <- stampSourceFor stamp layout contents (cuId user)
            let dest = cfgUsersDir cfg </> show (cuId user) </> "eza.db"
            case sourceResult of
                Left message -> pure (Left message)
                Right (Just path) -> do
                    ok <- verify path
                    if not ok
                        then pure (Left ("the stamp library for account " <> cuUsername user <> " failed its integrity check: " <> T.pack path))
                        else
                            foldRestorePlan cfg stamp layout contents currentUsers rest (RestoreEntry user path dest : entries, preserved, dropped)
                Right Nothing ->
                    case lookup (cuId user) [(cuId current, current) | current <- currentUsers] of
                        Just current -> do
                            currentExists <- doesFileExist (cuDbPath current)
                            if currentExists
                                then
                                    foldRestorePlan cfg stamp layout contents currentUsers rest (entries, PreservedEntry user (cuDbPath current) dest : preserved, dropped)
                                else
                                    foldRestorePlan cfg stamp layout contents currentUsers rest (entries, preserved, user : dropped)
                        Nothing ->
                            foldRestorePlan cfg stamp layout contents currentUsers rest (entries, preserved, user : dropped)

{- | Where a stamp keeps one account's library. New stamps name the file in
the manifest; flat stamps use @users/<id>.db@. A manifest that names a file
which is missing is reported as absent (the current installation's copy is
kept); a manifest whose path is not the expected file inside the stamp refuses
the whole restore.
-}
stampSourceFor :: FilePath -> StampLayout -> StampContents -> Int -> IO (Either Text (Maybe FilePath))
stampSourceFor stamp layout contents userId = case layout of
    StampLayoutFlat -> do
        let path = stamp </> "users" </> show userId <> ".db"
        exists <- doesFileExist path
        pure (Right (if exists then Just path else Nothing))
    StampLayoutManifest ->
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
        , rrsDropped = [(cuId user, cuUsername user) | user <- rpDropped plan]
        , rrsTargets =
            [ BackupTarget ("user " <> cuUsername (reUser entry)) (reSource entry) (reDest entry)
            | entry <- rpEntries plan
            ]
        , rrsControlTarget = cfgControlDbPath cfg
        , rrsLegacyTarget = rpLegacySource plan >> Just (cfgDbPath cfg)
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
        forM_ (rpEntries plan) $ \entry ->
            copyDatabaseFile (reSource entry) (reDest entry)
        forM_ (rpLegacySource plan) $ \source ->
            copyDatabaseFile source (cfgDbPath cfg)
        writeRestoredControl cfg plan
        pure
            RestoreReport
                { rrsStamp = rpStamp plan
                , rrsDryRun = False
                , rrsAutoBackup = backupStamp
                , rrsRestored = [(cuId (reUser entry), cuUsername (reUser entry)) | entry <- rpEntries plan]
                , rrsPreserved = [(cuId (peUser entry), cuUsername (peUser entry)) | entry <- rpPreserved plan]
                , rrsDropped = [(cuId user, cuUsername user) | user <- rpDropped plan]
                , rrsTargets =
                    [ BackupTarget ("user " <> cuUsername (reUser entry)) (reSource entry) (reDest entry)
                    | entry <- rpEntries plan
                    ]
                , rrsControlTarget = cfgControlDbPath cfg
                , rrsLegacyTarget = rpLegacySource plan >> Just (cfgDbPath cfg)
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

{- | Rewrite the stamp's control database into place. Every kept account's
@db_path@ is rewritten to the configured users directory; accounts whose
library could not be restored are removed so the control row never points at
a file that does not exist. The file is written last and atomically.
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
    forM_ (rpDropped plan) $ \user ->
        Sqlite.execute conn "DELETE FROM users WHERE id = ?" (Only (cuId user))
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
