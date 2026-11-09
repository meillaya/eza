{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Online, point-in-time backup of the whole installation.

The layout is one stamp directory per backup run:

@
backups/20260101-120000/control.db
backups/20260101-120000/users/3.db
backups/20260101-120000/users/7.db
@

Each database is copied with @VACUUM INTO@ (a consistent online snapshot even
while the writer is active) and then integrity-checked. A failed check removes
the whole stamp directory, so a visible backup is always a verified one. The
@--user@ selector narrows the run to one account's database; the control
database is always included because it is the map from accounts to files.
-}
module Eza.Backup (
    BackupReport (..),
    BackupTarget (..),
    runBackup,
) where

import Control.Exception (SomeException, onException, try)
import Control.Monad (forM_, unless, when)
import Data.Char (isDigit)
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime, posixSecondsToUTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Database.SQLite.Simple (Connection, Only (..), Query (..))
import qualified Database.SQLite.Simple as Sqlite
import System.Directory (
    copyFile,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getModificationTime,
    listDirectory,
    removeFile,
    removePathForcibly,
 )
import System.Environment (lookupEnv)
import System.FilePath (takeFileName, (</>))

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

runBackup :: Config -> Maybe Text -> IO (Either Text BackupReport)
runBackup cfg selector = do
    createDirectoryIfMissing True (cfgBackupDir cfg)
    now <- getPOSIXTime
    let stamp = formatTime defaultTimeLocale "%Y%m%d-%H%M%S" (posixSecondsToUTCTime now)
    root <- uniqueStampDir (cfgBackupDir cfg) stamp
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
                    copyOffsite root
                    prune (cfgBackupDir cfg) 14
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
    pure (BackupReport root targets)

{- | Every enabled account, or exactly the one @--user@ names. An install that
still has no control rows backs up the legacy single-user database so an
upgrade path never loses the only copy.
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
    Nothing -> do
        let enabled = filter (isNothing . cuDisabledAt) users
        if null enabled
            then do
                legacyExists <- doesFileExist (cfgDbPath cfg)
                pure
                    [ BackupTarget "legacy" (cfgDbPath cfg) (usersDir </> "legacy.db")
                    | legacyExists
                    ]
            else pure (map targetFor enabled)
  where
    targetFor user =
        BackupTarget
            ("user " <> cuUsername user)
            (cuDbPath user)
            (usersDir </> show (cuId user) <> ".db")

backupFromConnection :: Connection -> FilePath -> IO ()
backupFromConnection conn dest = do
    removeIfExists dest
    Sqlite.execute_ conn (Query (T.pack ("VACUUM INTO " <> quoteLiteral dest)))

backupFile :: FilePath -> FilePath -> IO ()
backupFile source dest = do
    exists <- doesFileExist source
    unless exists (ioError (userError ("database file is missing: " <> source)))
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

copyOffsite :: FilePath -> IO ()
copyOffsite root = do
    offsite <- lookupEnv "EZA_BACKUP_OFFSITE"
    case offsite of
        Nothing -> pure ()
        Just directory -> do
            let dest = directory </> takeFileName root
            createDirectoryIfMissing True directory
            removeIfExistsDirectory dest
            copyTree root dest

removeIfExistsDirectory :: FilePath -> IO ()
removeIfExistsDirectory path = do
    exists <- doesDirectoryExist path
    when exists (voidSafe (removePathForcibly path))

copyTree :: FilePath -> FilePath -> IO ()
copyTree source dest = do
    createDirectoryIfMissing True dest
    entries <- listDirectory source
    forM_ entries $ \entry -> do
        let from = source </> entry
            to = dest </> entry
        isDirectory <- doesDirectoryExist from
        if isDirectory
            then copyTree from to
            else copyFile from to

{- | Remove backup runs older than the keep window. Legacy flat
@eza-<stamp>.db@ files from the single-user layout are pruned too.
-}
prune :: FilePath -> Int -> IO ()
prune directory keepDays = do
    now <- getCurrentTime
    entries <- listDirectory directory
    forM_ entries $ \name -> do
        let path = directory </> name
            stampLike = isStampName name
            legacyFile = "eza-" `T.isPrefixOf` T.pack name && ".db" `T.isSuffixOf` T.pack name
        isDirectory <- if stampLike then doesDirectoryExist path else pure False
        when (isDirectory || legacyFile) $ do
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

{- | Never reuse an existing run directory, so two backups in the same second
cannot mix their files.
-}
uniqueStampDir :: FilePath -> String -> IO FilePath
uniqueStampDir base stamp = go (1 :: Int)
  where
    go attempt = do
        let name = if attempt == (1 :: Int) then stamp else stamp <> "-" <> show attempt
            path = base </> name
        exists <- doesDirectoryExist path
        if exists then go (attempt + 1) else pure path

voidSafe :: IO () -> IO ()
voidSafe action = do
    _ <- try action :: IO (Either SomeException ())
    pure ()
