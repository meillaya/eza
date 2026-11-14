{-# LANGUAGE OverloadedStrings #-}

{- | The schema-v17 change journal: one append-only table pair with JSON
before-images, the v16→v17 migration (old undo tables and their history are
dropped), the one-way upgrade refusal, generic apply→undo identity per captured
table, and the 100-entry prune limit.
-}
module JournalSpec (spec) where

import Control.Exception (bracket)
import Control.Monad (replicateM_)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import qualified Database.SQLite.Simple as Sqlite
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Eza.Bookmarks (deleteBookmark, insertBookmark)
import qualified Eza.Db as Db
import Eza.Migrate (MigrationPlan (..), applyMigrations, planMigrations, verifySchema)
import Eza.Undo (recordUndoIds, undoLast)

spec :: Spec
spec = describe "change journal" $ do
    it "migrates v16 to the current target with a pre-migration backup and drops the undo history" $
        withSystemTempDirectory "eza-journal-v16" $ \dir -> do
            let path = dir </> "v16.db"
            bracket (Sqlite.open path) Sqlite.close $ \conn -> do
                applied <- applyMigrations conn planV16
                case applied of
                    Left message -> expectationFailure (T.unpack message)
                    Right _ -> pure ()
                version <- Db.schemaVersion conn
                version `shouldBe` 16
                Sqlite.execute_ conn "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES ('https://example.test/v16','V16','example.test',1,1,1)"
                Sqlite.execute_ conn "INSERT INTO undo_snapshots (payload_json,created_at) VALUES ('{}',1)"
            migrated <- Db.openDb path
            version <- Db.schemaVersion migrated
            version `shouldBe` 18
            tables <- tableNames migrated
            ("journal" `elem` tables) `shouldBe` True
            ("journal_rows" `elem` tables) `shouldBe` True
            ("undo_snapshots" `elem` tables) `shouldBe` False
            ("undo_bookmark_rows" `elem` tables) `shouldBe` False
            books <- countRows migrated "SELECT COUNT(*) FROM bookmarks"
            books `shouldBe` 1
            metaRows <- countRows migrated "SELECT COUNT(*) FROM schema_meta"
            metaRows `shouldBe` 18
            Sqlite.close migrated
            backups <- backupsIn dir
            length backups `shouldBe` 1

    it "refuses a current database with the v16 migration plan" $
        withSystemTempDirectory "eza-journal-oneway" $ \dir -> do
            let path = dir </> "oneway.db"
            conn <- Db.openDb path
            verified <- verifySchema conn planV16
            case verified of
                Left message -> message `shouldSatisfy` T.isInfixOf "newer than this binary"
                Right _ -> expectationFailure "the v16 plan must refuse a v17 database"
            -- The current plan still verifies, of course.
            current <- verifySchema conn Db.dbMigrationPlan
            current `shouldSatisfy` isRight
            Sqlite.close conn

    it "restores every captured table to its before-image" $
        withSystemTempDirectory "eza-journal-identity" $ \dir -> do
            conn <- Db.openDb (dir </> "identity.db")
            bid <- mustBookmark conn "https://example.test/journal-target" "Journal target"
            other <- mustBookmark conn "https://example.test/journal-other" "Journal other"
            execute_ conn "INSERT INTO tags (name,created_at) VALUES ('journal-tag',1)"
            tagId <- scalarInt conn "SELECT id FROM tags WHERE name = 'journal-tag'"
            execute conn "INSERT INTO bookmark_tags (bookmark_id,tag_id) VALUES (?,?)" (bid, tagId)
            execute conn "INSERT INTO highlights (bookmark_id,quote,prefix,suffix,start_offset,end_offset,note,color,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)" (bid, "quote" :: Text, "" :: Text, "" :: Text, 0 :: Int, 5 :: Int, "note" :: Text, "yellow" :: Text, 1 :: Int, 1 :: Int)
            execute conn "INSERT INTO links (source_id,target_id,target_title,display_text,line_number) VALUES (?,?,'Other',NULL,NULL)" (bid, other)
            execute conn "INSERT INTO captures (bookmark_id,url,captured_at,created_at) VALUES (?,?,?,?)" (bid, "https://example.test/journal-target" :: Text, 1 :: Int, 1 :: Int)
            execute conn "INSERT INTO bookmark_dead_overrides (bookmark_id,reason,created_at,updated_at) VALUES (?,?,?,?)" (bid, "checked" :: Text, 1 :: Int, 1 :: Int)
            beforeBookmarks <- rowJson conn "bookmarks" "id = " bid
            beforeTags <- queryText conn "SELECT json_object('bookmark_id',bt.bookmark_id,'tag_name',t.name) FROM bookmark_tags bt JOIN tags t ON t.id=bt.tag_id WHERE bt.bookmark_id = ?" (Only bid)
            beforeHighlights <- rowJson conn "highlights" "bookmark_id = " bid
            beforeLinks <- queryText conn "SELECT json_object('id',id,'source_id',source_id,'target_id',target_id,'target_title',target_title,'display_text',display_text,'line_number',line_number) FROM links WHERE source_id = ? OR target_id = ? ORDER BY id" (bid, bid)
            beforeCaptures <- rowJson conn "captures" "bookmark_id = " bid
            beforeOverrides <- rowJson conn "bookmark_dead_overrides" "bookmark_id = " bid
            _ <- deleteBookmark conn bid
            restored <- undoLast conn
            restored `shouldBe` 1
            afterBookmarks <- rowJson conn "bookmarks" "id = " bid
            afterTags <- queryText conn "SELECT json_object('bookmark_id',bt.bookmark_id,'tag_name',t.name) FROM bookmark_tags bt JOIN tags t ON t.id=bt.tag_id WHERE bt.bookmark_id = ?" (Only bid)
            afterHighlights <- rowJson conn "highlights" "bookmark_id = " bid
            afterLinks <- queryText conn "SELECT json_object('id',id,'source_id',source_id,'target_id',target_id,'target_title',target_title,'display_text',display_text,'line_number',line_number) FROM links WHERE source_id = ? OR target_id = ? ORDER BY id" (bid, bid)
            afterCaptures <- rowJson conn "captures" "bookmark_id = " bid
            afterOverrides <- rowJson conn "bookmark_dead_overrides" "bookmark_id = " bid
            afterBookmarks `shouldBe` beforeBookmarks
            afterTags `shouldBe` beforeTags
            afterHighlights `shouldBe` beforeHighlights
            afterLinks `shouldBe` beforeLinks
            afterCaptures `shouldBe` beforeCaptures
            afterOverrides `shouldBe` beforeOverrides
            Sqlite.close conn

    it "prunes the journal to the newest 100 changes" $
        withSystemTempDirectory "eza-journal-prune" $ \dir -> do
            conn <- Db.openDb (dir </> "prune.db")
            bid <- mustBookmark conn "https://example.test/journal-prune" "Journal prune"
            replicateM_ 105 (recordUndoIds conn "bulk_mark_read" [bid])
            journalCount <- countRows conn "SELECT COUNT(*) FROM journal"
            journalCount `shouldBe` 100
            oldestRows <- countRows conn "SELECT COUNT(*) FROM journal_rows WHERE change_id NOT IN (SELECT id FROM journal)"
            oldestRows `shouldBe` 0
            Sqlite.close conn

-- ----------------------------------------------------------------- helpers ---

planV16 :: MigrationPlan
planV16 =
    Db.dbMigrationPlan
        { planMigrations = take 16 (planMigrations Db.dbMigrationPlan)
        }

mustBookmark :: Connection -> Text -> Text -> IO Int
mustBookmark conn url title = do
    inserted <- insertBookmark conn url title []
    case inserted of
        Right bookmarkId -> pure bookmarkId
        Left message -> expectationFailure (T.unpack message) >> error "unreachable"

rowJson :: Connection -> String -> String -> Int -> IO [Text]
rowJson conn table whereClause bookmarkId = do
    columns <- tableColumns conn table
    let args =
            T.intercalate
                ", "
                ["'" <> T.replace "'" "''" column <> "', " <> column | column <- columns]
        sql =
            T.pack
                ( "SELECT json_object("
                    <> T.unpack args
                    <> ") FROM "
                    <> table
                    <> " WHERE "
                    <> whereClause
                    <> show bookmarkId
                    <> " ORDER BY rowid"
                )
    queryText conn sql ()

queryText :: (ToRow params) => Connection -> Text -> params -> IO [Text]
queryText conn sql params =
    map fromOnly <$> (query conn (Query sql) params :: IO [Only Text])
  where
    fromOnly (Only value) = value

tableColumns :: Connection -> String -> IO [Text]
tableColumns conn table = do
    rows <- query conn (Query ("PRAGMA table_info(" <> T.pack table <> ")")) () :: IO [(Int, Text, Text, Int, Maybe Text, Int)]
    pure [name | (_, name, _, _, _, _) <- rows]

scalarInt :: Connection -> String -> IO Int
scalarInt conn sql = do
    rows <- query_ conn (Query (T.pack sql)) :: IO [Only Int]
    pure (case rows of [Only value] -> value; _ -> 0)

countRows :: Connection -> String -> IO Int
countRows conn sql = scalarInt conn sql

tableNames :: Connection -> IO [Text]
tableNames conn = do
    rows <- query_ conn "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name" :: IO [Only Text]
    pure [name | Only name <- rows]

backupsIn :: FilePath -> IO [FilePath]
backupsIn dir = do
    let backupDir = dir </> "backups"
    exists <- doesDirectoryExist backupDir
    if exists then listDirectory backupDir else pure []

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _) = False
