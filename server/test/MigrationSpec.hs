{-# LANGUAGE OverloadedStrings #-}

{- | The shared migration engine: append-only application, checksummed
@schema_meta@ history, legacy v15 backfill, verification on open, rollback of a
failed migration, and the control database's own plan.
-}
module MigrationSpec (spec) where

import Control.Exception (SomeException, bracket, try)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Connection, Only (..), Query (..))
import qualified Database.SQLite.Simple as Sqlite
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import qualified Eza.Control as Control
import qualified Eza.Db as Db
import Eza.Migrate
import Eza.User (UserRole (..))

spec :: Spec
spec = describe "migration engine" $ do
    it "applies every migration to a fresh database and records checksums" $
        withSystemTempDirectory "eza-migrate-fresh" $ \dir -> do
            let path = dir </> "fresh.db"
            conn <- Db.openDb path
            version <- Db.schemaVersion conn
            version `shouldBe` Db.targetSchemaVersion
            Db.targetSchemaVersion `shouldBe` 18
            rows <- metaRows conn
            map fst rows `shouldBe` [1 .. 18]
            map snd rows `shouldBe` map migrationChecksum (planMigrations Db.dbMigrationPlan)
            pendingRows <- metaPending conn
            pendingRows `shouldBe` []
            Sqlite.close conn

    it "reopening a fully migrated database is a no-op" $
        withSystemTempDirectory "eza-migrate-reopen" $ \dir -> do
            let path = dir </> "reopen.db"
            first <- Db.openDb path
            appliedFirst <- metaAppliedAt first
            Sqlite.close first
            second <- Db.openDb path
            appliedSecond <- metaAppliedAt second
            version <- Db.schemaVersion second
            version `shouldBe` 18
            appliedSecond `shouldBe` appliedFirst
            backups <- backupsIn dir
            backups `shouldBe` []
            Sqlite.close second

    it "upgrades a v15 fixture without re-running the shipped migrations" $
        withSystemTempDirectory "eza-migrate-v15" $ \dir -> do
            let path = dir </> "legacy.db"
            makeV15Fixture path
            conn <- Db.openDb path
            version <- Db.schemaVersion conn
            version `shouldBe` 18
            bookmarks <- countBookmarks conn
            bookmarks `shouldBe` 1
            rows <- metaRows conn
            map fst rows `shouldBe` [1 .. 18]
            map snd rows `shouldBe` map migrationChecksum (planMigrations Db.dbMigrationPlan)
            Sqlite.close conn
            backups <- backupsIn dir
            length backups `shouldBe` 1
            -- A second open verifies the checksums and does not migrate again.
            again <- Db.openDb path
            appliedFirst <- metaAppliedAt again
            Sqlite.close again
            backupsAfter <- backupsIn dir
            length backupsAfter `shouldBe` 1
            reopened <- Db.openDb path
            appliedSecond <- metaAppliedAt reopened
            Sqlite.close reopened
            appliedSecond `shouldBe` appliedFirst

    it "refuses a database newer than the binary with an actionable message" $
        withSystemTempDirectory "eza-migrate-newer" $ \dir -> do
            let path = dir </> "newer.db"
            conn <- Db.openDb path
            Sqlite.execute_ conn "PRAGMA user_version = 19"
            verified <- verifySchema conn Db.dbMigrationPlan
            case verified of
                Left message -> message `shouldSatisfy` T.isInfixOf "newer than this binary"
                Right _ -> expectationFailure "a newer database must not verify"
            Sqlite.close conn
            reopened <- try (Db.openDb path) :: IO (Either SomeException Connection)
            case reopened of
                Left err -> T.pack (show err) `shouldSatisfy` T.isInfixOf "newer than this binary"
                Right _ -> expectationFailure "opening a newer database must refuse"

    it "rejects a tampered migration list before applying anything" $
        withSystemTempDirectory "eza-migrate-tamper" $ \dir -> do
            let path = dir </> "tamper.db"
            conn <- Db.openDb path
            let tampered =
                    Db.dbMigrationPlan
                        { planMigrations =
                            [ if migrationVersion migration == 3
                                then migration{migrationStatements = migrationStatements migration <> [Query "SELECT 1"]}
                                else migration
                            | migration <- planMigrations Db.dbMigrationPlan
                            ]
                        }
            verified <- verifySchema conn tampered
            case verified of
                Left message -> do
                    message `shouldSatisfy` T.isInfixOf "checksum does not match"
                    message `shouldSatisfy` T.isInfixOf "migration v3"
                Right _ -> expectationFailure "a tampered migration list must not verify"
            applied <- applyMigrations conn tampered
            case applied of
                Left message -> message `shouldSatisfy` T.isInfixOf "checksum does not match"
                Right _ -> expectationFailure "a tampered migration list must not apply"
            version <- Db.schemaVersion conn
            version `shouldBe` 18
            Sqlite.close conn

    it "rolls back a failed migration statement and keeps the previous version" $
        withSystemTempDirectory "eza-migrate-rollback" $ \dir -> do
            let path = dir </> "rollback.db"
            conn <- Sqlite.open path
            let plan =
                    MigrationPlan
                        { planName = "rollback fixture"
                        , planLegacyVersion = 0
                        , planMigrations =
                            [ Migration 1 "meta and a" [schemaMetaStatement, Query "CREATE TABLE rollback_a (id INTEGER)"]
                            , Migration 2 "b then fail" [Query "CREATE TABLE rollback_b (id INTEGER)", Query "THIS IS NOT SQL"]
                            ]
                        }
            applied <- applyMigrations conn plan
            case applied of
                Left message -> message `shouldSatisfy` T.isInfixOf "rolled back"
                Right _ -> expectationFailure "a failed statement must not apply"
            version <- currentVersion conn
            version `shouldBe` 1
            tableA <- tableExists conn "rollback_a"
            tableA `shouldBe` True
            tableB <- tableExists conn "rollback_b"
            tableB `shouldBe` False
            rows <- metaRows conn
            map fst rows `shouldBe` [1]
            Sqlite.close conn

    it "migrates a fresh control database and records its history" $
        withSystemTempDirectory "eza-migrate-control" $ \dir -> do
            let path = dir </> "control.db"
            conn <- Control.openControlDb path
            Control.controlSchemaVersion `shouldBe` 2
            version <- currentVersion conn
            version `shouldBe` 2
            rows <- metaRows conn
            map fst rows `shouldBe` [1, 2]
            map snd rows `shouldBe` map migrationChecksum (planMigrations Control.controlMigrationPlan)
            verified <- Control.checkControlSchema conn
            case verified of
                Left message -> expectationFailure (T.unpack message)
                Right status -> ssVersion status `shouldBe` 2
            Sqlite.close conn

    it "upgrades an existing control v1 database without re-running v1" $
        withSystemTempDirectory "eza-migrate-control-v1" $ \dir -> do
            let path = dir </> "control.db"
            legacy <- Control.openControlDb path
            _ <- Control.createUser legacy "alice" (dir </> "users" </> "1" </> "eza.db") RoleAdmin Nothing
            Sqlite.execute_ legacy "DROP TABLE schema_meta"
            Sqlite.execute_ legacy "PRAGMA user_version = 1"
            Sqlite.close legacy
            upgraded <- Control.openControlDb path
            version <- currentVersion upgraded
            version `shouldBe` 2
            rows <- metaRows upgraded
            map fst rows `shouldBe` [1, 2]
            users <- Control.listUsers upgraded
            map Control.cuUsername users `shouldBe` ["alice"]
            verified <- Control.checkControlSchema upgraded
            case verified of
                Left message -> expectationFailure (T.unpack message)
                Right status -> do
                    ssVersion status `shouldBe` 2
                    ssLegacy status `shouldBe` False
            Sqlite.close upgraded

-- ---------------------------------------------------------------------------
-- Fixtures and helpers
-- ---------------------------------------------------------------------------

makeV15Fixture :: FilePath -> IO ()
makeV15Fixture path = bracket (Sqlite.open path) Sqlite.close $ \conn -> do
    mapM_
        (Sqlite.execute_ conn)
        (concat [Db.schemaV1, Db.schemaV2, Db.schemaV3, Db.schemaV4, Db.schemaV5, Db.schemaV6, Db.schemaV7, Db.schemaV8, Db.schemaV9, Db.schemaV10, Db.schemaV11, Db.schemaV12, Db.schemaV13, Db.schemaV14, Db.schemaV15])
    Sqlite.execute_
        conn
        "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES ('https://example.test/legacy','Legacy','example.test',1,1,1)"
    Sqlite.execute_ conn "PRAGMA user_version = 15"

metaRows :: Connection -> IO [(Int, Text)]
metaRows conn =
    Sqlite.query_ conn "SELECT version, checksum FROM schema_meta ORDER BY version ASC" ::
        IO [(Int, Text)]

metaAppliedAt :: Connection -> IO [Int]
metaAppliedAt conn =
    map fromOnly <$> (Sqlite.query_ conn "SELECT applied_at FROM schema_meta ORDER BY version ASC" :: IO [Only Int])
  where
    fromOnly (Only value) = value

-- | Versions that are missing a schema_meta row; a complete history has none.
metaPending :: Connection -> IO [Int]
metaPending conn = do
    rows <- metaRows conn
    pure ([1 .. 18] \\ map fst rows)
  where
    (\\) = foldr (\value seen -> filter (/= value) seen)

countBookmarks :: Connection -> IO Int
countBookmarks conn = do
    rows <- Sqlite.query_ conn "SELECT COUNT(*) FROM bookmarks" :: IO [Only Int]
    pure (case rows of [Only value] -> value; _ -> 0)

tableExists :: Connection -> String -> IO Bool
tableExists conn name = do
    rows <-
        Sqlite.query
            conn
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"
            (Only name) ::
            IO [Only Int]
    pure (not (null rows))

backupsIn :: FilePath -> IO [FilePath]
backupsIn dir = do
    let backupDir = dir </> "backups"
    exists <- doesDirectoryExist backupDir
    if exists then listDirectory backupDir else pure []
