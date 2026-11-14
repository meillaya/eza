{-# LANGUAGE OverloadedStrings #-}

{- | Tests for the control database: account rows, role rules and the
per-user database path registry.
-}
module ControlSpec (controlSpec) where

import Control.Exception (bracket)
import Database.SQLite.Simple (close)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Eza.Control

controlSpec :: Spec
controlSpec = describe "Eza.Control" $ do
    it "creates a control schema and starts with no users" $
        withSystemTempDirectory "eza-control" $ \dir -> do
            let path = dir </> "control.db"
            bracket (openControlDb path) close $ \conn -> do
                controlSchemaVersion `shouldBe` 2
                users <- listUsers conn
                users `shouldBe` []
                usersCount <- countUsers conn
                usersCount `shouldBe` 0
                enabledCount <- countEnabledUsers conn
                enabledCount `shouldBe` 0
                adminCount <- countEnabledAdmins conn
                adminCount `shouldBe` 0

    it "registers accounts with unique usernames and database paths" $
        withSystemTempDirectory "eza-control" $ \dir -> do
            createDirectoryIfMissing True (dir </> "users")
            bracket (openControlDb (dir </> "control.db")) close $ \conn -> do
                let path1 = dir </> "users" </> "1" </> "eza.db"
                    path2 = dir </> "users" </> "2" </> "eza.db"
                _ <- mustUser (createUser conn "alice" path1 RoleAdmin Nothing)
                _ <- mustUser (createUser conn "Bob" path2 RoleMember Nothing)
                duplicate <- createUser conn "ALICE" (dir </> "users" </> "3" </> "eza.db") RoleMember Nothing
                duplicate `shouldBe` Left ControlDuplicateUsername
                samePath <- createUser conn "carol" path1 RoleMember Nothing
                samePath `shouldBe` Left ControlDuplicateDbPath
                users <- listUsers conn
                length users `shouldBe` 2
                map cuUsername users `shouldBe` ["alice", "Bob"]
                map cuRole users `shouldBe` [RoleAdmin, RoleMember]
                found <- lookupUserByUsername conn "bob"
                found `shouldSatisfy` isJustUser
                missing <- lookupUserByUsername conn "nobody"
                missing `shouldBe` Nothing
                adminCount <- countEnabledAdmins conn
                adminCount `shouldBe` 1

    it "disables and re-enables an account without deleting the row" $
        withSystemTempDirectory "eza-control" $ \dir -> do
            bracket (openControlDb (dir </> "control.db")) close $ \conn -> do
                first <- fmap (either (error . show) id) (createUser conn "alice" (dir </> "1.db") RoleAdmin Nothing)
                disabled <- setUserDisabled conn (cuId first) True
                disabled `shouldBe` True
                afterDisable <- lookupUserById conn (cuId first)
                (afterDisable >>= cuDisabledAt) `shouldSatisfy` isJust
                enabledCount <- countEnabledUsers conn
                enabledCount `shouldBe` 0
                adminCount <- countEnabledAdmins conn
                adminCount `shouldBe` 0
                reenabled <- setUserDisabled conn (cuId first) False
                reenabled `shouldBe` True
                enabledAfter <- countEnabledUsers conn
                enabledAfter `shouldBe` 1
                adminsAfter <- countEnabledAdmins conn
                adminsAfter `shouldBe` 1

    it "records the last login and allows a database path update" $
        withSystemTempDirectory "eza-control" $ \dir -> do
            bracket (openControlDb (dir </> "control.db")) close $ \conn -> do
                user <- fmap (either (error . show) id) (createUser conn "alice" (dir </> "a.db") RoleAdmin Nothing)
                setUserLastLogin conn (cuId user)
                afterLogin <- lookupUserById conn (cuId user)
                (afterLogin >>= cuLastLoginAt) `shouldSatisfy` isJust
                moved <- updateUserDbPath conn (cuId user) (dir </> "b.db")
                moved `shouldBe` True
                afterMove <- lookupUserById conn (cuId user)
                fmap cuDbPath afterMove `shouldBe` Just (dir </> "b.db")

    it "deletes an account row only when asked" $
        withSystemTempDirectory "eza-control" $ \dir -> do
            bracket (openControlDb (dir </> "control.db")) close $ \conn -> do
                user <- fmap (either (error . show) id) (createUser conn "alice" (dir </> "a.db") RoleAdmin Nothing)
                deleted <- deleteUserRow conn (cuId user)
                deleted `shouldBe` True
                remaining <- countUsers conn
                remaining `shouldBe` 0
                again <- deleteUserRow conn (cuId user)
                again `shouldBe` False

    it "keeps usernames case-insensitive for lookup" $
        withSystemTempDirectory "eza-control" $ \dir -> do
            bracket (openControlDb (dir </> "control.db")) close $ \conn -> do
                _ <- createUser conn "Alice" (dir </> "a.db") RoleAdmin Nothing
                found <- lookupUserByUsername conn "alice"
                fmap cuUsername found `shouldBe` Just "Alice"

mustUser :: IO (Either ControlError ControlUser) -> IO ControlUser
mustUser action = do
    result <- action
    case result of
        Right user -> pure user
        Left err -> expectationFailure ("expected a created user, got " <> show err) >> error "unreachable"

isJustUser :: Maybe ControlUser -> Bool
isJustUser (Just _) = True
isJustUser Nothing = False

isJust :: Maybe a -> Bool
isJust (Just _) = True
isJust Nothing = False
