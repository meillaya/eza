{-# LANGUAGE OverloadedStrings #-}

{- | Backup and restore: a stamp mirrors the live layout (@control.db@,
@manifest.json@, @users/<id>/eza.db@), includes disabled accounts, prunes on
the configured keep window, and restores new and old flat stamps with the
control paths rewritten and the current installation backed up first.
-}
module BackupSpec (spec) where

import Control.Exception (bracket)
import Control.Monad (forM_)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.SQLite.Simple as Sqlite
import System.Directory (
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
    removeFile,
    removePathForcibly,
    renameFile,
 )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import System.Posix.Files (setFileTimes)

import qualified Eza.Admin as Admin
import Eza.Backup
import qualified Eza.Bookmarks as Bookmarks
import Eza.Config (Config (..))
import Eza.Control (ControlUser (..))
import qualified Eza.Control as Control
import qualified Eza.Db as Db
import Eza.User (UserRole (..))
import TestHarness (testConfig)

spec :: Spec
spec = describe "backup and restore" $ do
    it "backs up every account, disabled accounts included, into one manifest stamp" $
        withSystemTempDirectory "eza-backup" $ \dir -> do
            let cfg = testConfig dir
            (alice, bob) <- createAccounts cfg
            addBookmarkTo cfg alice "https://alice.example/one"
            addBookmarkTo cfg bob "https://bob.example/one"
            addBookmarkTo cfg bob "https://bob.example/two"
            addCaptureTo cfg alice "https://alice.example/one" "captured html" "captured text"
            disabled <- withControl cfg $ \control -> Admin.setUserEnabled cfg control (cuId bob) False
            case disabled of
                Right _ -> pure ()
                Left err -> expectationFailure ("disable failed: " <> show err)
            result <- runBackup cfg Nothing
            report <- expectBackup result
            let root = brRoot report
                aliceFile = root </> "users" </> show (cuId alice) </> "eza.db"
                bobFile = root </> "users" </> show (cuId bob) </> "eza.db"
            (root </> "control.db") `shouldExist` True
            (root </> "manifest.json") `shouldExist` True
            aliceFile `shouldExist` True
            bobFile `shouldExist` True
            map btLabel (brTargets report) `shouldBe` ["user alice", "user bob"]
            map btDest (brTargets report) `shouldBe` [aliceFile, bobFile]
            rawCount (root </> "control.db") "SELECT COUNT(*) FROM users" `shouldReturn` 2
            rawCount aliceFile "SELECT COUNT(*) FROM bookmarks" `shouldReturn` 1
            rawCount bobFile "SELECT COUNT(*) FROM bookmarks" `shouldReturn` 2
            rawCount aliceFile "SELECT COUNT(*) FROM captures" `shouldReturn` 1
            manifest <- expectRightIO "manifest" (readManifest root)
            bmSnapshotsIncluded manifest `shouldBe` False
            map muId (bmUsers manifest) `shouldBe` [cuId alice, cuId bob]
            map muEnabled (bmUsers manifest) `shouldBe` [True, False]

    it "narrows the run to one account with --user but still copies control.db" $
        withSystemTempDirectory "eza-backup-user" $ \dir -> do
            let cfg = testConfig dir
            (alice, bob) <- createAccounts cfg
            result <- runBackup cfg (Just "bob")
            report <- expectBackup result
            let root = brRoot report
            map btLabel (brTargets report) `shouldBe` ["user bob"]
            (root </> "control.db") `shouldExist` True
            (root </> "users" </> show (cuId bob) </> "eza.db") `shouldExist` True
            (root </> "users" </> show (cuId alice) </> "eza.db") `shouldExist` False
            manifest <- expectRightIO "manifest" (readManifest root)
            map muId (bmUsers manifest) `shouldBe` [cuId bob]
            -- Two runs in the same second must not share a stamp directory.
            second <- runBackup cfg (Just "bob")
            secondReport <- expectBackup second
            brRoot secondReport `shouldNotBe` root
            missing <- runBackup cfg (Just "nobody")
            case missing of
                Left _ -> pure ()
                Right _ -> expectationFailure "a backup for an unknown --user should fail"

    it "round-trips a new-layout stamp and auto-backs-up the current installation" $
        withSystemTempDirectory "eza-backup-roundtrip" $ \dir -> do
            let cfg = testConfig dir
            (alice, bob) <- createAccounts cfg
            addBookmarkTo cfg alice "https://alice.example/first"
            addCaptureTo cfg alice "https://alice.example/first" "<p>first</p>" "first"
            firstBackup <- expectBackup =<< runBackup cfg Nothing
            let firstRoot = brRoot firstBackup
            -- The installation moves on after the backup.
            addBookmarkTo cfg alice "https://alice.example/second"
            bracket (Db.openDb (cuDbPath alice)) Sqlite.close $ \conn ->
                scalar conn "SELECT COUNT(*) FROM bookmarks" `shouldReturn` 2
            result <- runRestore cfg (RestoreOptions firstRoot False False)
            report <- expectRestore result
            rrsDryRun report `shouldBe` False
            rrsRestored report `shouldBe` [(cuId alice, "alice"), (cuId bob, "bob")]
            autoRoot <- expectJust "auto backup" (rrsAutoBackup report)
            (autoRoot </> "control.db") `shouldExist` True
            (autoRoot </> "users" </> show (cuId alice) </> "eza.db") `shouldExist` True
            -- The restored library is the first backup's state, captures included.
            bracket (Db.openDb (cuDbPath alice)) Sqlite.close $ \conn -> do
                scalar conn "SELECT COUNT(*) FROM bookmarks" `shouldReturn` 1
                scalar conn "SELECT COUNT(*) FROM captures" `shouldReturn` 1
            users <- listUsers cfg
            case users of
                (user : _) -> cuDbPath user `shouldBe` cfgUsersDir cfg </> show (cuId alice) </> "eza.db"
                [] -> expectationFailure "the restored installation has no account"

    it "restores an old flat stamp and keeps the current library of accounts the stamp skipped" $
        withSystemTempDirectory "eza-backup-flat" $ \dir -> do
            let cfg = testConfig dir
            (alice, bob) <- createAccounts cfg
            addBookmarkTo cfg alice "https://alice.example/flat"
            addBookmarkTo cfg bob "https://bob.example/flat"
            backup <- expectBackup =<< runBackup cfg Nothing
            flatRoot <- flattenStamp (brRoot backup)
            layout <- expectRightIO "layout" (detectStampLayout flatRoot)
            layout `shouldBe` StampLayoutFlat
            -- The flat stamp only has alice's library (the M1 backup skipped
            -- disabled/missing accounts); bob must keep the current copy.
            removeIfExists (flatRoot </> "users" </> show (cuId bob) <> ".db")
            addBookmarkTo cfg alice "https://alice.example/post-backup"
            result <- runRestore cfg (RestoreOptions flatRoot False False)
            report <- expectRestore result
            rrsRestored report `shouldBe` [(cuId alice, "alice")]
            rrsPreserved report `shouldBe` [(cuId bob, "bob")]
            bracket (Db.openDb (cuDbPath alice)) Sqlite.close $ \conn ->
                scalar conn "SELECT COUNT(*) FROM bookmarks" `shouldReturn` 1
            bracket (Db.openDb (cuDbPath bob)) Sqlite.close $ \conn ->
                scalar conn "SELECT COUNT(*) FROM bookmarks" `shouldReturn` 1
            users <- listUsers cfg
            map cuDbPath users
                `shouldBe` [ cfgUsersDir cfg </> show (cuId alice) </> "eza.db"
                           , cfgUsersDir cfg </> show (cuId bob) </> "eza.db"
                           ]

    it "does not write anything on a dry run" $
        withSystemTempDirectory "eza-backup-dry" $ \dir -> do
            let cfg = testConfig dir
            (alice, bob) <- createAccounts cfg
            addBookmarkTo cfg alice "https://alice.example/dry"
            backup <- expectBackup =<< runBackup cfg Nothing
            backupsBefore <- listDirectory (cfgBackupDir cfg)
            result <- runRestore cfg (RestoreOptions (brRoot backup) True False)
            report <- expectRestore result
            rrsDryRun report `shouldBe` True
            rrsAutoBackup report `shouldBe` Nothing
            rrsRestored report `shouldBe` [(cuId alice, "alice"), (cuId bob, "bob")]
            backupsAfter <- listDirectory (cfgBackupDir cfg)
            backupsAfter `shouldBe` backupsBefore
            bracket (Db.openDb (cuDbPath alice)) Sqlite.close $ \conn ->
                scalar conn "SELECT COUNT(*) FROM bookmarks" `shouldReturn` 1

    it "refuses a corrupt stamp before touching the current installation" $
        withSystemTempDirectory "eza-backup-corrupt" $ \dir -> do
            let cfg = testConfig dir
            (alice, _) <- createAccounts cfg
            addBookmarkTo cfg alice "https://alice.example/intact"
            backup <- expectBackup =<< runBackup cfg Nothing
            let corruptFile = brRoot backup </> "users" </> show (cuId alice) </> "eza.db"
            BS.writeFile corruptFile "this is not a sqlite database"
            result <- runRestore cfg (RestoreOptions (brRoot backup) False False)
            case result of
                Left message -> message `shouldSatisfy` T.isInfixOf "integrity"
                Right _ -> expectationFailure "a corrupt stamp must not restore"
            bracket (Db.openDb (cuDbPath alice)) Sqlite.close $ \conn ->
                scalar conn "SELECT COUNT(*) FROM bookmarks" `shouldReturn` 1

    it "prunes old stamps and pre-migration copies on the keep window" $
        withSystemTempDirectory "eza-backup-prune" $ \dir -> do
            let backupDir = dir </> "backups"
                oldStamp = backupDir </> "20200101-000000"
                newStamp = backupDir </> "20260101-000000"
                oldPreMigration = backupDir </> "pre-migration-v11-eza.db-1-abc.db"
            createDirectoryIfMissing True oldStamp
            createDirectoryIfMissing True newStamp
            BS.writeFile oldPreMigration ""
            setFileTimes oldStamp 0 0
            setFileTimes oldPreMigration 0 0
            pruneBackups backupDir 7
            doesDirectoryExist oldStamp `shouldReturn` False
            doesFileExist oldPreMigration `shouldReturn` False
            doesDirectoryExist newStamp `shouldReturn` True

-- --------------------------------------------------------------------------- helpers

withControl :: Config -> (Sqlite.Connection -> IO a) -> IO a
withControl cfg action = bracket (Control.openControlDb (cfgControlDbPath cfg)) Sqlite.close action

createAccounts :: Config -> IO (ControlUser, ControlUser)
createAccounts cfg = withControl cfg $ \control -> do
    alice <- mustCreate (Admin.createUserAccount cfg control "alice" RoleAdmin "alice password")
    bob <- mustCreate (Admin.createUserAccount cfg control "bob" RoleMember "bob password")
    pure (alice, bob)

mustCreate :: IO (Either Admin.AdminError (ControlUser, [Text])) -> IO ControlUser
mustCreate action = do
    result <- action
    case result of
        Right (user, _) -> pure user
        Left err -> expectationFailure ("account creation failed: " <> show err) >> error "unreachable"

addBookmarkTo :: Config -> ControlUser -> Text -> IO ()
addBookmarkTo _cfg user url =
    bracket (Db.openDb (cuDbPath user)) Sqlite.close $ \conn -> do
        result <- Bookmarks.insertBookmark conn url "Backed up" []
        case result of
            Right _ -> pure ()
            Left message -> expectationFailure ("bookmark insert failed: " <> T.unpack message)

addCaptureTo :: Config -> ControlUser -> Text -> Text -> Text -> IO ()
addCaptureTo _cfg user url html text =
    bracket (Db.openDb (cuDbPath user)) Sqlite.close $ \conn ->
        Sqlite.execute
            conn
            "INSERT INTO captures (bookmark_id,url,content_html,content_text,captured_at,created_at) SELECT id,?,?,?,?,? FROM bookmarks WHERE url = ?"
            (url, html, text, (1 :: Int), (1 :: Int), url)

listUsers :: Config -> IO [ControlUser]
listUsers cfg = withControl cfg Control.listUsers

expectBackup :: Either Text BackupReport -> IO BackupReport
expectBackup result = case result of
    Left message -> expectationFailure ("backup failed: " <> T.unpack message) >> error "unreachable"
    Right report -> pure report

expectRestore :: Either Text RestoreReport -> IO RestoreReport
expectRestore result = case result of
    Left message -> expectationFailure ("restore failed: " <> T.unpack message) >> error "unreachable"
    Right report -> pure report

expectRightIO :: String -> IO (Either Text a) -> IO a
expectRightIO label action = do
    result <- action
    case result of
        Left message -> expectationFailure (label <> ": " <> T.unpack message) >> error "unreachable"
        Right value -> pure value

expectJust :: String -> Maybe a -> IO a
expectJust label = maybe (expectationFailure ("missing " <> label) >> error "unreachable") pure

shouldExist :: FilePath -> Bool -> Expectation
shouldExist path expected = doesFileExist path `shouldReturn` expected

scalar :: Sqlite.Connection -> Text -> IO Int
scalar conn sql = do
    rows <- Sqlite.query_ conn (Sqlite.Query sql) :: IO [Sqlite.Only Int]
    pure (case rows of [Sqlite.Only n] -> n; _ -> 0)

rawCount :: FilePath -> Text -> IO Int
rawCount path sql = bracket (Sqlite.open path) Sqlite.close $ \conn -> do
    rows <- Sqlite.query_ conn (Sqlite.Query sql) :: IO [Sqlite.Only Int]
    pure (case rows of [Sqlite.Only n] -> n; _ -> 0)

{- | Turn a new-layout stamp into the first multi-user flat layout
(@users/<id>.db@, no manifest).
-}
flattenStamp :: FilePath -> IO FilePath
flattenStamp root = do
    entries <- listDirectory (root </> "users")
    forM_ entries $ \name -> do
        let dir = root </> "users" </> name
        isDirectory <- doesDirectoryExist dir
        if isDirectory
            then do
                let file = dir </> "eza.db"
                exists <- doesFileExist file
                if exists
                    then renameFile file (root </> "users" </> name <> ".db")
                    else pure ()
                removePathForcibly dir
            else pure ()
    removeIfExists (root </> "manifest.json")
    pure root

removeIfExists :: FilePath -> IO ()
removeIfExists path = do
    exists <- doesFileExist path
    if exists then removeFile path else pure ()
