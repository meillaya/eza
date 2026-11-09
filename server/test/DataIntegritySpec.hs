{-# LANGUAGE OverloadedStrings #-}

{- | Data-integrity tests for the schema v7 undo/merge/tag tranche. Wiring:
add @DataIntegritySpec@ to the test-suite @other-modules@ and call
@DataIntegritySpec.spec@ from Spec.hs main. Kept in its own module so the
auth and data workstreams do not touch the same test file.
-}
module DataIntegritySpec (spec) where

import Control.Exception (bracket)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import qualified Database.SQLite.Simple as Sqlite
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Eza.Bookmarks
import Eza.Db (openDb, queryScalar, schemaV1, schemaV2, schemaV3, schemaV4, schemaV5, schemaV6, schemaVersion, targetSchemaVersion)
import Eza.Dedup (mergeBookmarks)
import Eza.Highlights (createHighlight, listHighlights)
import Eza.Tags (deleteTag, deleteTagWithLinks, mergeTags, renameTag)
import Eza.Types (BookmarkDetail (..), Highlight (..), SearchPage (..))
import Eza.Undo (recordUndo, recordUndoIds, snapshotBookmarks, undoLast)

spec :: Spec
spec = do
    describe "schema v7" $ do
        it "migrates v6 to v7 and adds the undo side tables" $
            withSystemTempDirectory "eza-v7-migrate" $ \dir -> do
                let path = dir </> "test.db"
                bracket (Sqlite.open path) Sqlite.close $ \conn -> do
                    mapM_ (Sqlite.execute_ conn) (schemaV1 <> schemaV2 <> schemaV3 <> schemaV4 <> schemaV5 <> schemaV6)
                    Sqlite.execute_ conn "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES ('https://example.test/v6','V6','example.test',1,1,1)"
                    Sqlite.execute_ conn "INSERT INTO tags (name,created_at) VALUES ('legacy',1)"
                    Sqlite.execute_ conn "INSERT INTO bookmark_tags (bookmark_id,tag_id) VALUES (1,1)"
                    Sqlite.execute_ conn "PRAGMA user_version = 6"
                migrated <- openDb path
                version <- schemaVersion migrated
                version `shouldBe` targetSchemaVersion
                books <- queryScalar migrated "SELECT COUNT(*) FROM bookmarks"
                books `shouldBe` 1
                tagged <- queryScalar migrated "SELECT COUNT(*) FROM bookmark_tags"
                tagged `shouldBe` 1
                tables <- tableNames migrated
                ("undo_highlight_rows" `elem` tables) `shouldBe` True
                ("undo_link_rows" `elem` tables) `shouldBe` True
                ("undo_tag_rows" `elem` tables) `shouldBe` True
                -- undo_bookmark_rows must mirror every current bookmarks column.
                bookmarkColumns <- columnNames migrated "bookmarks"
                undoColumns <- columnNames migrated "undo_bookmark_rows"
                filter (/= "snapshot_id") undoColumns `shouldBe` bookmarkColumns
                close migrated

    describe "delete undo" $ do
        it "restores a deleted bookmark with its highlight, backlink and tags" $
            withDb $ \conn -> do
                target <- addBookmark conn "https://example.test/target" "Target"
                source <- addBookmark conn "https://example.test/source" "Source"
                addLink conn source target
                _ <- createHighlight conn target "quoted text" "" "" 0 11 "a note" "yellow"
                tagBookmark conn target "kept"
                deleted <- deleteBookmark conn target
                deleted `shouldBe` True
                countRows conn "SELECT COUNT(*) FROM highlights" `shouldReturn` 0
                countRows conn "SELECT COUNT(*) FROM links" `shouldReturn` 0
                restored <- undoLast conn
                restored `shouldBe` 1
                detail <- requireBookmark conn target
                bdTitle detail `shouldBe` "Target"
                bdTags detail `shouldBe` ["kept"]
                highlights <- listHighlights conn target
                map hQuote highlights `shouldBe` ["quoted text"]
                hasLink conn source target `shouldReturn` True
                -- The restored row is searchable again (FTS triggers ran).
                page <- listBookmarks conn (defaultListQuery{lqQ = "Target"})
                spTotal page `shouldBe` 1

        it "restores the enrichment, reading-time and AI columns" $
            withDb $ \conn -> do
                bid <- addBookmark conn "https://example.test/enriched" "Enriched"
                execute
                    conn
                    "UPDATE bookmarks SET enrich_state = 'ok', enrich_error = '', enrich_attempts = 2, enriched_at = 77, reading_time_minutes = 9, ai_summary = 'summary text', ai_tagged_at = 88 WHERE id = ?"
                    (Only bid)
                _ <- deleteBookmark conn bid
                _ <- undoLast conn
                row <- requireEnrichment conn bid
                row `shouldBe` ("ok", 2, Just 77, 9, "summary text", Just 88)

        it "undoes a bulk delete as one transaction" $
            withDb $ \conn -> do
                first <- addBookmark conn "https://example.test/bulk-a" "Bulk A"
                second <- addBookmark conn "https://example.test/bulk-b" "Bulk B"
                _ <- createHighlight conn first "quote a" "" "" 0 7 "" "green"
                _ <- createHighlight conn second "quote b" "" "" 0 7 "" "blue"
                result <- bulkUpdate conn BulkDelete [first, second]
                case result of
                    Left err -> expectationFailure (T.unpack err)
                    Right (_, sn) -> sn `shouldSatisfy` (> 0)
                countRows conn "SELECT COUNT(*) FROM bookmarks" `shouldReturn` 0
                restored <- undoLast conn
                restored `shouldBe` 2
                firstHighlights <- listHighlights conn first
                secondHighlights <- listHighlights conn second
                map hColor firstHighlights `shouldBe` ["green"]
                map hColor secondHighlights `shouldBe` ["blue"]

    describe "prune undo" $ do
        it "restores pruned rows, their tags and their children" $
            withDb $ \conn -> do
                first <- addBookmark conn "https://example.test/prune-a" "Prune A"
                second <- addBookmark conn "https://example.test/prune-b" "Prune B"
                tagBookmark conn first "old"
                _ <- createHighlight conn first "pruned quote" "" "" 0 12 "note" "red"
                pruned <- pruneApply conn [first, second]
                pruned `shouldBe` 2
                countRows conn "SELECT COUNT(*) FROM bookmarks" `shouldReturn` 0
                restored <- undoLast conn
                restored `shouldBe` 2
                detail <- requireBookmark conn first
                bdTags detail `shouldBe` ["old"]
                highlights <- listHighlights conn first
                map hQuote highlights `shouldBe` ["pruned quote"]
                -- A second undo has nothing left: it must return 0, not wedge.
                again <- undoLast conn
                again `shouldBe` 0

    describe "merge undo" $ do
        it "preserves notes, tags, highlights, links and counters, and undo reverts it" $
            withDb $ \conn -> do
                keep <- addBookmark conn "https://example.test/keep" "Keeper"
                absorbed <- addBookmark conn "https://example.test/absorbed" "Absorbed"
                other <- addBookmark conn "https://example.test/other" "Other"
                setNote conn keep "keeper note"
                setNote conn absorbed "absorbed note body"
                tagBookmark conn keep "alpha"
                tagBookmark conn absorbed "beta"
                _ <- createHighlight conn absorbed "absorbed quote" "" "" 0 14 "highlight note" "yellow"
                addLink conn other absorbed
                addLink conn absorbed other
                execute
                    conn
                    "UPDATE bookmarks SET open_count = 3, is_read = 1, is_dead = 1, last_opened_at = 500, created_at = 200, added_at = 200, favicon_url = 'https://example.test/fav.ico', ai_summary = 'absorbed summary' WHERE id = ?"
                    (Only absorbed)
                execute conn "UPDATE bookmarks SET open_count = 2, created_at = 300, added_at = 300 WHERE id = ?" (Only keep)
                merged <- mergeBookmarks conn keep [absorbed]
                merged `shouldBe` 1
                countRows conn "SELECT COUNT(*) FROM bookmarks" `shouldReturn` 2
                detail <- requireBookmark conn keep
                bdTags detail `shouldBe` ["alpha", "beta"]
                bdNoteBody detail `shouldSatisfy` T.isInfixOf "keeper note"
                bdNoteBody detail `shouldSatisfy` T.isInfixOf "absorbed note body"
                bdNoteBody detail `shouldSatisfy` T.isInfixOf "## Absorbed"
                keeperHighlights <- listHighlights conn keep
                map hQuote keeperHighlights `shouldBe` ["absorbed quote"]
                hasLink conn other keep `shouldReturn` True
                hasLink conn keep other `shouldReturn` True
                counters <- requireCounters conn keep
                -- Summed opens, OR-ed read, dead only when every copy was dead.
                counters `shouldBe` (5, 1, 0, Just 500, 200, 200)
                favicon <- requireText conn "favicon_url" keep
                favicon `shouldBe` "https://example.test/fav.ico"
                summary <- requireText conn "ai_summary" keep
                summary `shouldBe` "absorbed summary"
                -- Undo puts both records and all their children back: the snapshot
                -- covers the keeper and the absorbed row (2 bookmark rows).
                restored <- undoLast conn
                restored `shouldBe` 2
                absorbedDetail <- requireBookmark conn absorbed
                bdTitle absorbedDetail `shouldBe` "Absorbed"
                bdTags absorbedDetail `shouldBe` ["beta"]
                bdNoteBody absorbedDetail `shouldBe` "absorbed note body"
                absorbedHighlights <- listHighlights conn absorbed
                map hQuote absorbedHighlights `shouldBe` ["absorbed quote"]
                hasLink conn other absorbed `shouldReturn` True
                hasLink conn absorbed other `shouldReturn` True
                keeperAfter <- requireBookmark conn keep
                bdTags keeperAfter `shouldBe` ["alpha"]
                bdNoteBody keeperAfter `shouldBe` "keeper note"
                absorbedCounters <- requireCounters conn absorbed
                absorbedCounters `shouldBe` (3, 1, 1, Just 500, 200, 200)
                keeperCounters <- requireCounters conn keep
                keeperCounters `shouldBe` (2, 0, 0, Nothing, 300, 300)

    describe "tag undo" $ do
        it "restores a tag merged into another name, with its attachments" $
            withDb $ \conn -> do
                first <- addBookmark conn "https://example.test/tag-a" "Tag A"
                second <- addBookmark conn "https://example.test/tag-b" "Tag B"
                tagBookmark conn first "rust"
                tagBookmark conn second "code"
                merged <- mergeTags conn ["rust", "code"] "programming"
                merged `shouldBe` 2
                firstTags <- bdTags <$> requireBookmark conn first
                secondTags <- bdTags <$> requireBookmark conn second
                firstTags `shouldBe` ["programming"]
                secondTags `shouldBe` ["programming"]
                tagNames <- tagNamesInDb conn
                tagNames `shouldBe` ["programming"]
                _ <- undoLast conn
                restoredFirst <- bdTags <$> requireBookmark conn first
                restoredSecond <- bdTags <$> requireBookmark conn second
                restoredFirst `shouldBe` ["rust"]
                restoredSecond `shouldBe` ["code"]
                restoredTags <- tagNamesInDb conn
                restoredTags `shouldBe` ["code", "rust"]

        it "restores a rename and an empty-tag delete" $
            withDb $ \conn -> do
                bid <- addBookmark conn "https://example.test/tag-rename" "Tag rename"
                tagBookmark conn bid "old-name"
                renamed <- renameTag conn "old-name" "new-name"
                renamed `shouldBe` True
                tagsAfter <- bdTags <$> requireBookmark conn bid
                tagsAfter `shouldBe` ["new-name"]
                _ <- undoLast conn
                tagsRestored <- bdTags <$> requireBookmark conn bid
                tagsRestored `shouldBe` ["old-name"]
                -- Create an empty tag, delete it, then undo.
                execute_ conn "INSERT INTO tags (name,created_at) VALUES ('orphan',1)"
                deleted <- deleteTag conn "orphan"
                deleted `shouldBe` True
                countRows conn "SELECT COUNT(*) FROM tags WHERE name = 'orphan'" `shouldReturn` 0
                _ <- undoLast conn
                countRows conn "SELECT COUNT(*) FROM tags WHERE name = 'orphan'" `shouldReturn` 1

        it "detaches and restores a non-empty tag through deleteTagWithLinks" $
            withDb $ \conn -> do
                bid <- addBookmark conn "https://example.test/tag-detach" "Tag detach"
                tagBookmark conn bid "detachable"
                refused <- deleteTag conn "detachable"
                refused `shouldBe` False
                forced <- deleteTagWithLinks conn "detachable"
                forced `shouldBe` True
                tagsAfter <- bdTags <$> requireBookmark conn bid
                tagsAfter `shouldBe` []
                countRows conn "SELECT COUNT(*) FROM tags WHERE name = 'detachable'" `shouldReturn` 0
                _ <- undoLast conn
                tagsRestored <- bdTags <$> requireBookmark conn bid
                tagsRestored `shouldBe` ["detachable"]
                countRows conn "SELECT COUNT(*) FROM tags WHERE name = 'detachable'" `shouldReturn` 1

    describe "undo robustness" $ do
        it "discards empty side snapshots instead of wedging the record" $
            withDb $ \conn -> do
                _ <- recordUndoIds conn "delete" []
                restored <- undoLast conn
                restored `shouldBe` 0
                remaining <- countRows conn "SELECT COUNT(*) FROM undo_snapshots"
                remaining `shouldBe` 0

        it "skips malformed snapshots and still restores the older one" $
            withDb $ \conn -> do
                bid <- addBookmark conn "https://example.test/malformed" "Malformed"
                _ <- deleteBookmark conn bid
                execute_ conn "INSERT INTO undo_snapshots (payload_json,created_at) VALUES ('not json',1)"
                restored <- undoLast conn
                restored `shouldBe` 1
                detail <- requireBookmark conn bid
                bdTitle detail `shouldBe` "Malformed"
                remaining <- countRows conn "SELECT COUNT(*) FROM undo_snapshots"
                remaining `shouldBe` 0

        it "still restores a legacy JSON snapshot" $
            withDb $ \conn -> do
                bid <- addBookmark conn "https://example.test/legacy" "Legacy"
                tagBookmark conn bid "legacy-tag"
                payload <- snapshotBookmarks conn [bid]
                recordUndo conn "legacy" payload
                execute conn "DELETE FROM bookmarks WHERE id = ?" (Only bid)
                restored <- undoLast conn
                restored `shouldBe` 1
                detail <- requireBookmark conn bid
                bdTitle detail `shouldBe` "Legacy"
                bdTags detail `shouldBe` ["legacy-tag"]

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

withDb :: (Connection -> IO a) -> IO a
withDb action =
    withSystemTempDirectory "eza-integrity" $ \dir ->
        bracket (openDb (dir </> "test.db")) close action

addBookmark :: Connection -> Text -> Text -> IO Int
addBookmark conn url title = do
    execute
        conn
        "INSERT INTO bookmarks (url,title,domain,source,created_at,added_at,updated_at) VALUES (?,?,?,?,?,?,?)"
        (url, title, ("example.test" :: Text), ("test" :: Text), (100 :: Int), (100 :: Int), (100 :: Int))
    fromIntegral <$> lastInsertRowId conn

setNote :: Connection -> Int -> Text -> IO ()
setNote conn bid note =
    execute conn "UPDATE bookmarks SET note_body = ? WHERE id = ?" (note, bid)

tagBookmark :: Connection -> Int -> Text -> IO ()
tagBookmark conn bid name = do
    execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)" (name, (100 :: Int))
    ids <- query conn "SELECT id FROM tags WHERE name = ?" (Only name) :: IO [Only Int]
    case ids of
        (Only tagId : _) -> execute conn "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?, ?)" (bid, tagId)
        [] -> pure ()

addLink :: Connection -> Int -> Int -> IO ()
addLink conn source target =
    execute
        conn
        "INSERT INTO links (source_id, target_id, target_title) VALUES (?,?,?)"
        (source, target, ("Target" :: Text))

hasLink :: Connection -> Int -> Int -> IO Bool
hasLink conn source target = do
    rows <- query conn "SELECT 1 FROM links WHERE source_id = ? AND target_id = ?" (source, target) :: IO [Only Int]
    pure (not (null rows))

countRows :: Connection -> Text -> IO Int
countRows conn sql = do
    rows <- query_ conn (Query sql) :: IO [Only Int]
    pure (case rows of [Only n] -> n; _ -> 0)

tableNames :: Connection -> IO [Text]
tableNames conn = do
    rows <- query_ conn "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name" :: IO [Only Text]
    pure [name | Only name <- rows]

columnNames :: Connection -> Text -> IO [Text]
columnNames conn table = do
    rows <-
        query_
            conn
            (Query ("SELECT name FROM pragma_table_info('" <> table <> "') ORDER BY cid")) ::
            IO [Only Text]
    pure [name | Only name <- rows]

tagNamesInDb :: Connection -> IO [Text]
tagNamesInDb conn = do
    rows <- query_ conn "SELECT name FROM tags ORDER BY name" :: IO [Only Text]
    pure [name | Only name <- rows]

requireBookmark :: Connection -> Int -> IO BookmarkDetail
requireBookmark conn bid = do
    found <- getBookmark conn bid
    case found of
        Nothing -> do
            expectationFailure ("bookmark " <> show bid <> " is missing")
            fail "unreachable: bookmark missing"
        Just detail -> pure detail

-- | (open_count, is_read, is_dead, last_opened_at, created_at, added_at)
requireCounters :: Connection -> Int -> IO (Int, Int, Int, Maybe Int, Int, Int)
requireCounters conn bid = do
    rows <-
        query
            conn
            "SELECT open_count,is_read,is_dead,last_opened_at,created_at,added_at FROM bookmarks WHERE id = ?"
            (Only bid) ::
            IO [(Int, Int, Int, Maybe Int, Int, Int)]
    case rows of
        (counters : _) -> pure counters
        [] -> do
            expectationFailure "expected bookmark counters"
            fail "unreachable: bookmark missing"

requireText :: Connection -> Text -> Int -> IO Text
requireText conn column bid = do
    rows <-
        query
            conn
            (Query ("SELECT " <> column <> " FROM bookmarks WHERE id = ?"))
            (Only bid) ::
            IO [Only Text]
    case rows of
        (Only value : _) -> pure value
        [] -> do
            expectationFailure "expected a text column"
            fail "unreachable: bookmark missing"

{- | (enrich_state, enrich_attempts, enriched_at, reading_time_minutes,
ai_summary, ai_tagged_at)
-}
requireEnrichment :: Connection -> Int -> IO (Text, Int, Maybe Int, Int, Text, Maybe Int)
requireEnrichment conn bid = do
    rows <-
        query
            conn
            "SELECT enrich_state,enrich_attempts,enriched_at,reading_time_minutes,ai_summary,ai_tagged_at FROM bookmarks WHERE id = ?"
            (Only bid) ::
            IO [(Text, Int, Maybe Int, Int, Text, Maybe Int)]
    case rows of
        (row : _) -> pure row
        [] -> do
            expectationFailure "expected enrichment columns"
            fail "unreachable: bookmark missing"
