{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Backup-all: control database plus enabled user databases into one verified
stamp directory, with the @--user@ narrowing and disabled-account exclusion.
-}
module BackupSpec (spec) where

import Control.Exception (bracket)
import qualified Data.Text as T
import Database.SQLite.Simple (Only (..), Query (..))
import qualified Database.SQLite.Simple as Sqlite
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import qualified Eza.Admin as Admin
import Eza.Backup (BackupReport (..), BackupTarget (..), runBackup)
import qualified Eza.Bookmarks as Bookmarks
import Eza.Config (Config (..))
import Eza.Control (ControlUser (..))
import qualified Eza.Control as Control
import qualified Eza.Db as Db
import Eza.User (UserRole (..))
import TestHarness (testConfig)

spec :: Spec
spec = describe "backup-all" $ do
    it "backs up the control database and every enabled account into one stamp" $
        withSystemTempDirectory "eza-backup" $ \dir -> do
            let cfg = testConfig dir
            (alice, bob) <- createAccounts cfg
            addBookmarkTo cfg alice "https://alice.example/one"
            addBookmarkTo cfg bob "https://bob.example/one"
            addBookmarkTo cfg bob "https://bob.example/two"
            result <- runBackup cfg Nothing
            case result of
                Left message -> expectationFailure ("backup failed: " <> T.unpack message)
                Right report -> do
                    let root = brRoot report
                        aliceFile = root </> "users" </> show (cuId alice) <> ".db"
                        bobFile = root </> "users" </> show (cuId bob) <> ".db"
                    controlExists <- doesFileExist (root </> "control.db")
                    controlExists `shouldBe` True
                    aliceExists <- doesFileExist aliceFile
                    aliceExists `shouldBe` True
                    bobExists <- doesFileExist bobFile
                    bobExists `shouldBe` True
                    map btLabel (brTargets report) `shouldBe` ["user alice", "user bob"]
                    map btDest (brTargets report) `shouldBe` [aliceFile, bobFile]
                    -- The stamp is a restorable set: same accounts, same rows.
                    usersCount <- rawCount (root </> "control.db") "SELECT COUNT(*) FROM users"
                    usersCount `shouldBe` 2
                    aliceRows <- rawCount aliceFile "SELECT COUNT(*) FROM bookmarks"
                    aliceRows `shouldBe` 1
                    bobRows <- rawCount bobFile "SELECT COUNT(*) FROM bookmarks"
                    bobRows `shouldBe` 2
                    -- The root is a directory named with the run stamp, not a
                    -- single loose file.
                    rootIsDirectory <- doesDirectoryExist root
                    rootIsDirectory `shouldBe` True
                    entries <- listDirectory (root </> "users")
                    length entries `shouldBe` 2

    it "narrows the run to one account with --user" $
        withSystemTempDirectory "eza-backup-user" $ \dir -> do
            let cfg = testConfig dir
            (alice, bob) <- createAccounts cfg
            result <- runBackup cfg (Just "bob")
            firstRoot <- case result of
                Left message -> expectationFailure ("backup failed: " <> T.unpack message) >> error "unreachable"
                Right report -> do
                    map btLabel (brTargets report) `shouldBe` ["user bob"]
                    let root = brRoot report
                    controlExists <- doesFileExist (root </> "control.db")
                    controlExists `shouldBe` True
                    bobExists <- doesFileExist (root </> "users" </> show (cuId bob) <> ".db")
                    bobExists `shouldBe` True
                    aliceExists <- doesFileExist (root </> "users" </> show (cuId alice) <> ".db")
                    aliceExists `shouldBe` False
                    pure root
            -- Two runs in the same second must not share a stamp directory.
            second <- runBackup cfg (Just "bob")
            case second of
                Left message -> expectationFailure ("second backup failed: " <> T.unpack message)
                Right secondReport -> brRoot secondReport `shouldNotBe` firstRoot
            missing <- runBackup cfg (Just "nobody")
            case missing of
                Left _ -> pure ()
                Right _ -> expectationFailure "a backup for an unknown --user should fail"

    it "leaves disabled accounts out of the default run" $
        withSystemTempDirectory "eza-backup-disabled" $ \dir -> do
            let cfg = testConfig dir
            (_, bob) <- createAccounts cfg
            withControl cfg $ \control -> do
                disabled <- Admin.setUserEnabled cfg control (cuId bob) False
                disabled `shouldSatisfy` isRight
            result <- runBackup cfg Nothing
            case result of
                Left message -> expectationFailure ("backup failed: " <> T.unpack message)
                Right report -> do
                    map btLabel (brTargets report) `shouldBe` ["user alice"]
                    let root = brRoot report
                    bobExists <- doesFileExist (root </> "users" </> show (cuId bob) <> ".db")
                    bobExists `shouldBe` False
            narrowed <- runBackup cfg (Just "bob")
            case narrowed of
                Left message -> expectationFailure ("--user should still back up a disabled account: " <> T.unpack message)
                Right report -> map btLabel (brTargets report) `shouldBe` ["user bob"]

createAccounts :: Config -> IO (ControlUser, ControlUser)
createAccounts cfg = withControl cfg $ \control -> do
    alice <- mustCreate (Admin.createUserAccount cfg control "alice" RoleAdmin "alice password")
    bob <- mustCreate (Admin.createUserAccount cfg control "bob" RoleMember "bob password")
    pure (alice, bob)

mustCreate :: IO (Either Admin.AdminError (ControlUser, [T.Text])) -> IO ControlUser
mustCreate action = do
    result <- action
    case result of
        Right (user, _) -> pure user
        Left err -> expectationFailure ("could not create a test account: " <> show err) >> error "unreachable"

withControl :: Config -> (Sqlite.Connection -> IO a) -> IO a
withControl cfg = bracket (Control.openControlDb (cfgControlDbPath cfg)) Sqlite.close

addBookmarkTo :: Config -> ControlUser -> T.Text -> IO ()
addBookmarkTo _ user url =
    bracket (Db.openDb (cuDbPath user)) Sqlite.close $ \conn -> do
        _ <- Bookmarks.insertBookmark conn url "Entry" []
        pure ()

rawCount :: FilePath -> String -> IO Int
rawCount path sql =
    bracket (Sqlite.open path) Sqlite.close $ \conn -> do
        rows <- Sqlite.query_ conn (Query (T.pack sql)) :: IO [Only Int]
        pure (case rows of [Only value] -> value; _ -> 0)

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _) = False
