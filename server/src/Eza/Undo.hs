{-# LANGUAGE OverloadedStrings #-}

-- Every mutating operation records a snapshot before it changes rows. There
-- are two shapes:
--
--   * A 'side snapshot' (v3 and newer) copies the affected rows into the
--     @undo_*_rows@ tables and leaves a marker row in @undo_snapshots@ with an
--     empty JSON payload. As of schema v7 it covers the bookmark rows
--     themselves, their tag names, the highlights attached to them and the
--     wikilinks whose source or target is affected. Schema v12 adds the
--     browser-clipper capture rows (@captures@ cascades from @bookmarks@), so
--     undoing a delete, prune or merge brings those back too. Tag-only
--     operations use the same marker with 'undo_tag_rows' and
--     'undo_bookmark_tags' rows.
--   * A 'legacy snapshot' stores a JSON payload in @undo_snapshots@. Older
--     binaries wrote those and the restore path is kept so an upgrade does not
--     strand them.
--
-- 'undoLastDetailed' restores one snapshot as a single transaction. Empty or
-- malformed snapshots are discarded instead of blocking the undo record.
-- Restoring never REPLACEs a different bookmark row: a snapshot row is
-- updated by id when its id is still present, inserted when its id and URL are
-- free, and skipped (counted) when the URL has been re-used by a newer row.
-- The FTS index is rebuilt after a bookmark restore so a restore cannot leave
-- stale search terms behind.

-- | Undo snapshots.
module Eza.Undo (
    snapshotBookmarks,
    recordUndo,
    recordUndoIds,
    recordTagUndo,
    restoreBookmarks,
    undoLast,
    undoLastDetailed,
) where

import Control.Monad (foldM, forM_, when)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import GHC.Generics (Generic)

import Eza.Clip (captureColumns)
import Eza.Json (jsonOptions)

{- | The row shape of a legacy JSON snapshot. Kept byte-compatible with old
payloads; do not add fields or old snapshots stop decoding.
-}
data SnapshotRow = SnapshotRow
    { srId :: Int
    , srUrl :: Text
    , srTitle :: Text
    , srDescription :: Text
    , srFaviconUrl :: Text
    , srDomain :: Text
    , srSource :: Text
    , srCreatedAt :: Int
    , srAddedAt :: Int
    , srUpdatedAt :: Int
    , srLastOpenedAt :: Maybe Int
    , srLastCheckedAt :: Maybe Int
    , srOpenCount :: Int
    , srIsDead :: Int
    , srIsRead :: Int
    , srNoteBody :: Text
    , srExtractedText :: Text
    , srAuthor :: Text
    , srSitename :: Text
    , srPublishedAt :: Maybe Int
    , srLanguage :: Text
    , srImageUrl :: Text
    , srFinalUrl :: Text
    , srSnapshotPath :: Text
    , srSnapshotKind :: Text
    , srSnapshotCapturedAt :: Maybe Int
    }
    deriving (Show, Eq, Generic)

instance FromRow SnapshotRow where
    fromRow =
        SnapshotRow
            <$> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field

instance ToJSON SnapshotRow where
    toJSON = genericToJSON (jsonOptions "sr")
instance FromJSON SnapshotRow where
    parseJSON = genericParseJSON (jsonOptions "sr")

{- | Every column of @bookmarks@ in schema order. @undo_bookmark_rows@ mirrors
this list exactly (v1 columns, the v2 enrichment/reading columns and the v5 AI
columns), so a side snapshot restores the complete row.
-}
bookmarkColumns :: Text
bookmarkColumns =
    "id,url,title,description,favicon_url,domain,source,created_at,added_at,updated_at,last_opened_at,last_checked_at,open_count,is_dead,is_read,note_body,extracted_text,author,sitename,published_at,language,image_url,final_url,snapshot_path,snapshot_kind,snapshot_captured_at,enrich_state,enrich_error,enrich_attempts,enriched_at,reading_time_minutes,ai_summary,ai_tagged_at"

-- | The column names of 'bookmarkColumns', in order.
bookmarkColumnList :: [Text]
bookmarkColumnList = T.splitOn "," bookmarkColumns

{- | Columns of the legacy JSON snapshot. The legacy format predates the
enrichment, reading-time and AI columns, so it stays at the v1 shape.
-}
snapshotColumns :: Text
snapshotColumns =
    "id,url,title,description,favicon_url,domain,source,created_at,added_at,updated_at,last_opened_at,last_checked_at,open_count,is_dead,is_read,note_body,extracted_text,author,sitename,published_at,language,image_url,final_url,snapshot_path,snapshot_kind,snapshot_captured_at"

snapshotColumnList :: [Text]
snapshotColumnList = T.splitOn "," snapshotColumns

{- | One complete bookmark row lifted out of @undo_bookmark_rows@. The restore
path decides row by row whether its id can be updated, whether it can be
inserted, or whether its URL is now owned by a different row and must be
skipped.
-}
data SideBookmark = SideBookmark
    { sbId :: Int
    , sbUrl :: Text
    , sbTitle :: Text
    , sbDescription :: Text
    , sbFaviconUrl :: Text
    , sbDomain :: Text
    , sbSource :: Text
    , sbCreatedAt :: Int
    , sbAddedAt :: Int
    , sbUpdatedAt :: Int
    , sbLastOpenedAt :: Maybe Int
    , sbLastCheckedAt :: Maybe Int
    , sbOpenCount :: Int
    , sbIsDead :: Int
    , sbIsRead :: Int
    , sbNoteBody :: Text
    , sbExtractedText :: Text
    , sbAuthor :: Text
    , sbSitename :: Text
    , sbPublishedAt :: Maybe Int
    , sbLanguage :: Text
    , sbImageUrl :: Text
    , sbFinalUrl :: Text
    , sbSnapshotPath :: Text
    , sbSnapshotKind :: Text
    , sbSnapshotCapturedAt :: Maybe Int
    , sbEnrichState :: Text
    , sbEnrichError :: Text
    , sbEnrichAttempts :: Int
    , sbEnrichedAt :: Maybe Int
    , sbReadingTimeMinutes :: Int
    , sbAiSummary :: Text
    , sbAiTaggedAt :: Maybe Int
    }

instance FromRow SideBookmark where
    fromRow =
        SideBookmark
            <$> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field

sideBookmarkParams :: SideBookmark -> [NamedParam]
sideBookmarkParams row =
    [ ":id" := sbId row
    , ":url" := sbUrl row
    , ":title" := sbTitle row
    , ":description" := sbDescription row
    , ":favicon_url" := sbFaviconUrl row
    , ":domain" := sbDomain row
    , ":source" := sbSource row
    , ":created_at" := sbCreatedAt row
    , ":added_at" := sbAddedAt row
    , ":updated_at" := sbUpdatedAt row
    , ":last_opened_at" := sbLastOpenedAt row
    , ":last_checked_at" := sbLastCheckedAt row
    , ":open_count" := sbOpenCount row
    , ":is_dead" := sbIsDead row
    , ":is_read" := sbIsRead row
    , ":note_body" := sbNoteBody row
    , ":extracted_text" := sbExtractedText row
    , ":author" := sbAuthor row
    , ":sitename" := sbSitename row
    , ":published_at" := sbPublishedAt row
    , ":language" := sbLanguage row
    , ":image_url" := sbImageUrl row
    , ":final_url" := sbFinalUrl row
    , ":snapshot_path" := sbSnapshotPath row
    , ":snapshot_kind" := sbSnapshotKind row
    , ":snapshot_captured_at" := sbSnapshotCapturedAt row
    , ":enrich_state" := sbEnrichState row
    , ":enrich_error" := sbEnrichError row
    , ":enrich_attempts" := sbEnrichAttempts row
    , ":enriched_at" := sbEnrichedAt row
    , ":reading_time_minutes" := sbReadingTimeMinutes row
    , ":ai_summary" := sbAiSummary row
    , ":ai_tagged_at" := sbAiTaggedAt row
    ]

{- | Insert one snapshot row. The URL is written as given; the caller has
already checked that no other row owns it.
-}
sideBookmarkInsertSql :: Query
sideBookmarkInsertSql =
    Query
        ( "INSERT INTO bookmarks ("
            <> bookmarkColumns
            <> ") VALUES ("
            <> T.intercalate ", " (map (":" <>) bookmarkColumnList)
            <> ")"
        )

{- | Update the row with the snapshot id. The URL assignment is guarded: when a
different row took the same URL after the snapshot (a re-save of the deleted
page), the current URL stays and the rest of the row is restored, so a restore
never REPLACEs a newer row through the UNIQUE(url) constraint.
-}
sideBookmarkUpdateSql :: Query
sideBookmarkUpdateSql =
    Query
        ( "UPDATE bookmarks SET "
            <> T.intercalate ", " (map assignment (filter (/= "id") bookmarkColumnList))
            <> " WHERE id = :id"
        )
  where
    assignment column
        | column == "url" =
            "url = CASE WHEN EXISTS (SELECT 1 FROM bookmarks AS x WHERE x.url = :url AND x.id <> :id) THEN url ELSE :url END"
        | otherwise = column <> " = :" <> column

sideBookmarkSelectSql :: Query
sideBookmarkSelectSql =
    Query ("SELECT " <> bookmarkColumns <> " FROM undo_bookmark_rows WHERE snapshot_id = ? ORDER BY id")

-- ---------------------------------------------------------------- legacy SQL ---

snapshotParams :: SnapshotRow -> [NamedParam]
snapshotParams row =
    [ ":id" := srId row
    , ":url" := srUrl row
    , ":title" := srTitle row
    , ":description" := srDescription row
    , ":favicon_url" := srFaviconUrl row
    , ":domain" := srDomain row
    , ":source" := srSource row
    , ":created_at" := srCreatedAt row
    , ":added_at" := srAddedAt row
    , ":updated_at" := srUpdatedAt row
    , ":last_opened_at" := srLastOpenedAt row
    , ":last_checked_at" := srLastCheckedAt row
    , ":open_count" := srOpenCount row
    , ":is_dead" := srIsDead row
    , ":is_read" := srIsRead row
    , ":note_body" := srNoteBody row
    , ":extracted_text" := srExtractedText row
    , ":author" := srAuthor row
    , ":sitename" := srSitename row
    , ":published_at" := srPublishedAt row
    , ":language" := srLanguage row
    , ":image_url" := srImageUrl row
    , ":final_url" := srFinalUrl row
    , ":snapshot_path" := srSnapshotPath row
    , ":snapshot_kind" := srSnapshotKind row
    , ":snapshot_captured_at" := srSnapshotCapturedAt row
    ]

legacyInsertSql :: Query
legacyInsertSql =
    Query
        ( "INSERT INTO bookmarks ("
            <> snapshotColumns
            <> ") VALUES ("
            <> T.intercalate ", " (map (":" <>) snapshotColumnList)
            <> ")"
        )

legacyUpdateSql :: Query
legacyUpdateSql =
    Query
        ( "UPDATE bookmarks SET "
            <> T.intercalate ", " (map assignment (filter (/= "id") snapshotColumnList))
            <> " WHERE id = :id"
        )
  where
    assignment column
        | column == "url" =
            "url = CASE WHEN EXISTS (SELECT 1 FROM bookmarks AS x WHERE x.url = :url AND x.id <> :id) THEN url ELSE :url END"
        | otherwise = column <> " = :" <> column

{- | Snapshot the complete rows and tag names for the given bookmark ids as a
legacy JSON payload. Kept for compatibility with old binaries and payloads;
current mutating operations use 'recordUndoIds'.
-}
snapshotBookmarks :: Connection -> [Int] -> IO Value
snapshotBookmarks _ [] = pure (object ["rows" .= ([] :: [Value]), "tags" .= ([] :: [(Int, Text)])])
snapshotBookmarks conn ids = do
    let marks = T.intercalate "," (replicate (length ids) "?")
    rows <- query conn (Query ("SELECT " <> snapshotColumns <> " FROM bookmarks WHERE id IN (" <> marks <> ")")) ids :: IO [SnapshotRow]
    tags <-
        query
            conn
            (Query ("SELECT bt.bookmark_id,t.name FROM bookmark_tags bt JOIN tags t ON t.id=bt.tag_id WHERE bt.bookmark_id IN (" <> marks <> ") ORDER BY t.name"))
            ids ::
            IO [(Int, Text)]
    pure (object ["rows" .= rows, "tags" .= tags])

recordUndo :: Connection -> Text -> Value -> IO ()
recordUndo conn op snapshot = do
    now <- epoch
    execute
        conn
        "INSERT INTO undo_snapshots (payload_json, created_at) VALUES (?, ?)"
        (TE.decodeUtf8 (LBS.toStrict (encode (object ["op" .= op, "snapshot" .= snapshot]))), (now :: Int))

{- | Restore a legacy JSON snapshot. No transaction management: the caller
wraps it. Kept for snapshots written by older binaries; returns the number of
bookmark rows restored and ignores URL-conflict skips.
-}
restoreBookmarks :: Connection -> Value -> IO Int
restoreBookmarks conn payload = fst <$> restoreLegacyPayload conn payload

{- | Record a side snapshot for the given bookmark ids, before the caller
changes them. Must run inside the caller's write transaction.

The marker row (@undo_snapshots@ with an empty JSON payload) plus the side
tables: bookmark rows, bookmark/tag names, the tag rows those names belong to,
the highlights attached to the bookmarks, the wikilinks whose source or target
is one of the bookmarks, and (v12) the clip captures attached to them. That is
everything a delete, prune, bulk update or merge can cascade away.
-}
recordUndoIds :: Connection -> Text -> [Int] -> IO Int
recordUndoIds conn op ids = do
    now <- epoch
    let uniqueIds = dedupeIds ids
    execute
        conn
        "INSERT INTO undo_snapshots (payload_json, op, row_count, created_at) VALUES ('{}', ?, ?, ?)"
        (op, length uniqueIds, now)
    snapshotId <- fromIntegral <$> lastInsertRowId conn
    case uniqueIds of
        [] -> pure snapshotId
        _ -> do
            let marks = T.intercalate "," (replicate (length uniqueIds) "?")
                params = snapshotId : uniqueIds
                inMarks = "(" <> marks <> ")"
            execute
                conn
                (Query ("INSERT OR IGNORE INTO undo_bookmark_rows (snapshot_id," <> bookmarkColumns <> ") SELECT ?," <> bookmarkColumns <> " FROM bookmarks WHERE id IN " <> inMarks))
                params
            execute
                conn
                (Query ("INSERT OR IGNORE INTO undo_bookmark_tags (snapshot_id,bookmark_id,tag_name) SELECT ?, bt.bookmark_id, t.name FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id WHERE bt.bookmark_id IN " <> inMarks))
                params
            execute
                conn
                (Query ("INSERT OR IGNORE INTO undo_tag_rows (snapshot_id,id,name,created_at) SELECT ?, t.id, t.name, t.created_at FROM tags t WHERE t.id IN (SELECT tag_id FROM bookmark_tags WHERE bookmark_id IN " <> inMarks <> ")"))
                params
            execute
                conn
                (Query ("INSERT OR IGNORE INTO undo_highlight_rows (snapshot_id,id,bookmark_id,quote,prefix,suffix,start_offset,end_offset,note,color,created_at,updated_at) SELECT ?, h.id, h.bookmark_id, h.quote, h.prefix, h.suffix, h.start_offset, h.end_offset, h.note, h.color, h.created_at, h.updated_at FROM highlights h WHERE h.bookmark_id IN " <> inMarks))
                params
            execute
                conn
                (Query ("INSERT OR IGNORE INTO undo_link_rows (snapshot_id,id,source_id,target_id,target_title,display_text,line_number) SELECT ?, l.id, l.source_id, l.target_id, l.target_title, l.display_text, l.line_number FROM links l WHERE l.source_id IN " <> inMarks <> " OR l.target_id IN " <> inMarks))
                (snapshotId : (uniqueIds <> uniqueIds))
            execute
                conn
                (Query ("INSERT OR IGNORE INTO undo_capture_rows (snapshot_id," <> captureColumns <> ") SELECT ?," <> captureColumns <> " FROM captures WHERE bookmark_id IN " <> inMarks))
                params
            pure snapshotId

{- | Record a tagged side snapshot for a tag-only operation. @names@ is the set
of tags the operation can touch: the sources and, when it already exists, the
target. Must run inside the caller's write transaction, before the change.

The snapshot stores the current tag rows and every bookmark/tag link that
points at one of those names. Restoring deletes the tag rows for those names
and puts the snapshot back, which also reverts renames and merges.
-}
recordTagUndo :: Connection -> Text -> [Text] -> IO Int
recordTagUndo conn op names = do
    now <- epoch
    let uniqueNames = dedupeNames names
    execute
        conn
        "INSERT INTO undo_snapshots (payload_json, op, row_count, created_at) VALUES (?, ?, ?, ?)"
        (TE.decodeUtf8 (LBS.toStrict (encode (object ["names" .= uniqueNames]))), op, length uniqueNames, (now :: Int))
    snapshotId <- fromIntegral <$> lastInsertRowId conn
    forM_ uniqueNames $ \name -> do
        execute
            conn
            "INSERT OR IGNORE INTO undo_tag_rows (snapshot_id,id,name,created_at) SELECT ?, id, name, created_at FROM tags WHERE name = ?"
            (snapshotId, name)
        execute
            conn
            "INSERT OR IGNORE INTO undo_bookmark_tags (snapshot_id,bookmark_id,tag_name) SELECT ?, bt.bookmark_id, t.name FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id WHERE t.name = ?"
            (snapshotId, name)
    pure snapshotId

{- | Restore a bookmark side snapshot. The caller owns the transaction:
'undoLastDetailed' wraps the whole restore in one immediate transaction. Bookmark
rows are restored first (per-id update, or insert when id and URL are free),
then the tag/highlight/link/capture rows recorded by the snapshot, and finally
the FTS index is rebuilt and the marker row is removed.
-}
restoreSideSnapshot :: Connection -> Int -> IO (Int, Int)
restoreSideSnapshot conn snapshotId = do
    rows <- query conn sideBookmarkSelectSql (Only snapshotId) :: IO [SideBookmark]
    (restored, skipped) <- foldM (restoreSideRow conn) ([], 0) rows
    deleteRestoredChildren conn snapshotId
    restoreSideChildren conn snapshotId
    rebuildFts conn
    execute conn "DELETE FROM undo_snapshots WHERE id = ?" (Only snapshotId)
    pure (length restored, skipped)

{- | Restore one snapshot row and return the accumulated restored ids plus the
number of URL conflicts skipped. A row whose id still exists is updated in
place; a row whose id is gone is inserted only when its URL is free. A row
whose URL was re-used by a newer row is skipped, never REPLACEd away.
-}
restoreSideRow :: Connection -> ([Int], Int) -> SideBookmark -> IO ([Int], Int)
restoreSideRow conn (restored, skipped) row = do
    byId <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only (sbId row)) :: IO [Only Int]
    if not (null byId)
        then do
            executeNamed conn sideBookmarkUpdateSql (sideBookmarkParams row)
            pure (sbId row : restored, skipped)
        else do
            byUrl <- query conn "SELECT 1 FROM bookmarks WHERE url = ?" (Only (sbUrl row)) :: IO [Only Int]
            if null byUrl
                then do
                    executeNamed conn sideBookmarkInsertSql (sideBookmarkParams row)
                    pure (sbId row : restored, skipped)
                else pure (restored, skipped + 1)

{- | Remove the child rows of the restored bookmarks before the snapshot rows
are put back. The id set comes from the snapshot but only ids that exist in
@bookmarks@ now (the restored ones) are touched: a skipped row has no children
to delete, and deleting by its id would be a no-op anyway.
-}
deleteRestoredChildren :: Connection -> Int -> IO ()
deleteRestoredChildren conn snapshotId = do
    let restoredIds =
            "SELECT u.id FROM undo_bookmark_rows u WHERE u.snapshot_id = ? AND EXISTS (SELECT 1 FROM bookmarks b WHERE b.id = u.id)"
    execute conn (Query ("DELETE FROM bookmark_tags WHERE bookmark_id IN (" <> restoredIds <> ")")) (Only snapshotId)
    execute conn (Query ("DELETE FROM highlights WHERE bookmark_id IN (" <> restoredIds <> ")")) (Only snapshotId)
    execute conn (Query ("DELETE FROM captures WHERE bookmark_id IN (" <> restoredIds <> ")")) (Only snapshotId)
    execute conn (Query ("DELETE FROM links WHERE source_id IN (" <> restoredIds <> ") OR target_id IN (" <> restoredIds <> ")")) (snapshotId, snapshotId)

{- | Put back the snapshot's tag rows and the child rows attached to restored
bookmarks. Children are filtered by an existence check on @bookmarks@ so a row
whose bookmark was skipped for a URL conflict cannot violate a foreign key.
-}
restoreSideChildren :: Connection -> Int -> IO ()
restoreSideChildren conn snapshotId = do
    let existsBookmark column =
            "EXISTS (SELECT 1 FROM bookmarks b WHERE b.id = " <> column <> ")"
    execute conn "INSERT OR IGNORE INTO tags (name, created_at) SELECT name, created_at FROM undo_tag_rows WHERE snapshot_id = ?" (Only snapshotId)
    execute conn "INSERT OR IGNORE INTO tags (name, created_at) SELECT DISTINCT tag_name, strftime('%s','now') FROM undo_bookmark_tags WHERE snapshot_id = ?" (Only snapshotId)
    execute
        conn
        ( Query
            ( "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) "
                <> "SELECT ut.bookmark_id, t.id FROM undo_bookmark_tags ut JOIN tags t ON t.name = ut.tag_name "
                <> "WHERE ut.snapshot_id = ? AND "
                <> existsBookmark "ut.bookmark_id"
            )
        )
        (Only snapshotId)
    execute
        conn
        ( Query
            ( "INSERT OR REPLACE INTO highlights (id,bookmark_id,quote,prefix,suffix,start_offset,end_offset,note,color,created_at,updated_at) "
                <> "SELECT id,bookmark_id,quote,prefix,suffix,start_offset,end_offset,note,color,created_at,updated_at "
                <> "FROM undo_highlight_rows WHERE snapshot_id = ? AND "
                <> existsBookmark "undo_highlight_rows.bookmark_id"
            )
        )
        (Only snapshotId)
    execute
        conn
        ( Query
            ( "INSERT OR REPLACE INTO links (id,source_id,target_id,target_title,display_text,line_number) "
                <> "SELECT id,source_id,target_id,target_title,display_text,line_number FROM undo_link_rows ul "
                <> "WHERE ul.snapshot_id = ? "
                <> "AND (ul.source_id IS NULL OR "
                <> existsBookmark "ul.source_id"
                <> ") "
                <> "AND (ul.target_id IS NULL OR "
                <> existsBookmark "ul.target_id"
                <> ")"
            )
        )
        (Only snapshotId)
    execute
        conn
        ( Query
            ( "INSERT OR REPLACE INTO captures ("
                <> captureColumns
                <> ") "
                <> "SELECT "
                <> captureColumns
                <> " FROM undo_capture_rows "
                <> "WHERE snapshot_id = ? AND "
                <> existsBookmark "undo_capture_rows.bookmark_id"
            )
        )
        (Only snapshotId)

{- | Restore a legacy JSON snapshot's bookmark rows. The same id/URL conflict
rules as the side restore apply: update by id, insert when free, skip when the
URL belongs to a newer row. The payload has no highlight/link/capture rows, so
only tags are put back. Returns how many rows were restored and skipped.
-}
restoreLegacyPayload :: Connection -> Value -> IO (Int, Int)
restoreLegacyPayload conn payload = do
    let rows = fromMaybe [] (parseMaybe (withObject "snapshot" (.: "rows")) payload :: Maybe [SnapshotRow])
        tags = fromMaybe [] (parseMaybe (withObject "snapshot" (.: "tags")) payload :: Maybe [(Int, Text)])
    (restored, skipped) <- foldM (restoreLegacyRow conn) ([], 0) rows
    forM_ restored $ \bid -> execute conn "DELETE FROM bookmark_tags WHERE bookmark_id = ?" (Only bid)
    forM_ tags $ \(bid, name) -> do
        present <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only bid) :: IO [Only Int]
        when (not (null present) && bid `elem` restored) $ do
            execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, strftime('%s','now'))" (Only name)
            tagRows <- query conn "SELECT id FROM tags WHERE name = ?" (Only name) :: IO [Only Int]
            case tagRows of
                (Only tid : _) -> execute conn "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?, ?)" (bid, tid)
                _ -> pure ()
    rebuildFts conn
    pure (length restored, skipped)

restoreLegacyRow :: Connection -> ([Int], Int) -> SnapshotRow -> IO ([Int], Int)
restoreLegacyRow conn (restored, skipped) row = do
    byId <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only (srId row)) :: IO [Only Int]
    if not (null byId)
        then do
            executeNamed conn legacyUpdateSql (snapshotParams row)
            pure (srId row : restored, skipped)
        else do
            byUrl <- query conn "SELECT 1 FROM bookmarks WHERE url = ?" (Only (srUrl row)) :: IO [Only Int]
            if null byUrl
                then do
                    executeNamed conn legacyInsertSql (snapshotParams row)
                    pure (srId row : restored, skipped)
                else pure (restored, skipped + 1)

{- | Restore a tag side snapshot. Same transaction contract as
'restoreSideSnapshot'. Deletes the tag rows and bookmark/tag links for every
name the snapshot mentions and rebuilds them from the snapshot, which reverts
delete, detach, rename and merge in one step.
-}
restoreTagSnapshot :: Connection -> Int -> IO Int
restoreTagSnapshot conn snapshotId = do
    tagCount <- countRows conn "undo_tag_rows" snapshotId
    tagRows <-
        query
            conn
            "SELECT id,name,created_at FROM undo_tag_rows WHERE snapshot_id = ? ORDER BY id"
            (Only snapshotId) ::
            IO [(Int, Text, Int)]
    attached <-
        query
            conn
            "SELECT DISTINCT tag_name FROM undo_bookmark_tags WHERE snapshot_id = ?"
            (Only snapshotId) ::
            IO [Only Text]
    recordedNames <- snapshotNames conn snapshotId
    let names =
            dedupeNames
                ( recordedNames
                    <> [name | (_, name, _) <- tagRows]
                    <> [name | Only name <- attached]
                )
        snapshotIds = [tagId | (tagId, _, _) <- tagRows]
    currentIds <-
        if null names
            then pure []
            else do
                rows <-
                    query
                        conn
                        (Query ("SELECT id FROM tags WHERE name IN (" <> questionMarks (length names) <> ")"))
                        names ::
                        IO [Only Int]
                pure [tagId | Only tagId <- rows]
    -- Current tag rows for the affected names *and* the ids the snapshot is
    -- about to reuse. Deleting by id is what makes a rename reversible: the
    -- renamed row still occupies the old id even though its name changed.
    let affectedIds = dedupeIds (snapshotIds <> currentIds)
    if null affectedIds
        then pure ()
        else do
            execute
                conn
                (Query ("DELETE FROM bookmark_tags WHERE tag_id IN (" <> questionMarks (length affectedIds) <> ")"))
                affectedIds
            execute
                conn
                (Query ("DELETE FROM tags WHERE id IN (" <> questionMarks (length affectedIds) <> ")"))
                affectedIds
    forM_ tagRows $ \(tagId, name, createdAt) -> do
        execute conn "INSERT OR IGNORE INTO tags (id,name,created_at) VALUES (?,?,?)" (tagId, name, createdAt)
        restored <- query conn "SELECT 1 FROM tags WHERE name = ?" (Only name) :: IO [Only Int]
        when (null restored) $
            execute conn "INSERT INTO tags (name,created_at) VALUES (?,?)" (name, createdAt)
    execute
        conn
        "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) SELECT ut.bookmark_id, t.id FROM undo_bookmark_tags ut JOIN tags t ON t.name = ut.tag_name WHERE ut.snapshot_id = ?"
        (Only snapshotId)
    execute conn "DELETE FROM undo_snapshots WHERE id = ?" (Only snapshotId)
    pure tagCount

{- | Rebuild the external-content FTS index from @bookmarks@. A restore writes
through UPDATE/INSERT paths the sync triggers may not fully cover (and old
binaries used REPLACE, which skipped the delete trigger), so the index is
rebuilt at the end of every bookmark restore instead of trusted.
-}
rebuildFts :: Connection -> IO ()
rebuildFts conn =
    execute_ conn "INSERT INTO bookmarks_fts(bookmarks_fts) VALUES('rebuild')"

{- | Restore the newest usable snapshot. Empty or malformed snapshots are
discarded one by one instead of blocking the undo record, and the restore is a
single immediate transaction so a failure leaves the library untouched.
Returns the number of rows restored and the number of snapshot rows skipped
because their URL now belongs to a different row.
-}
undoLastDetailed :: Connection -> IO (Int, Int)
undoLastDetailed conn = withImmediateTransaction conn (restoreLatest conn)

-- | Compatibility wrapper for callers that only need the restored count.
undoLast :: Connection -> IO Int
undoLast conn = fst <$> undoLastDetailed conn

-- | The body of 'undoLastDetailed'. Runs inside one immediate transaction.
restoreLatest :: Connection -> IO (Int, Int)
restoreLatest conn = do
    rows <-
        query_ conn "SELECT id, CAST(payload_json AS TEXT) FROM undo_snapshots ORDER BY id DESC LIMIT 1" :: IO [(Int, Text)]
    case rows of
        [] -> pure (0, 0)
        (snapshotId, raw) : _ -> do
            bookmarkRows <- countRows conn "undo_bookmark_rows" snapshotId
            if bookmarkRows > 0
                then restoreSideSnapshot conn snapshotId
                else do
                    tagRows <- countRows conn "undo_tag_rows" snapshotId
                    tagLinks <- countRows conn "undo_bookmark_tags" snapshotId
                    if tagRows > 0 || tagLinks > 0
                        then do
                            restored <- restoreTagSnapshot conn snapshotId
                            pure (restored, 0)
                        else case legacySnapshot raw of
                            Just snapshot -> do
                                (restored, skipped) <- restoreLegacyPayload conn snapshot
                                discardSnapshot conn snapshotId
                                -- An empty legacy snapshot is not a restore: keep looking.
                                if restored > 0 || skipped > 0
                                    then pure (restored, skipped)
                                    else restoreLatest conn
                            Nothing -> do
                                discardSnapshot conn snapshotId
                                restoreLatest conn

{- | A legacy JSON snapshot, if the payload holds one. A side snapshot stores
@{}@, which decodes fine but has no @snapshot@ key.
-}
legacySnapshot :: Text -> Maybe Value
legacySnapshot raw = do
    value <- decode (LBS.fromStrict (TE.encodeUtf8 raw)) :: Maybe Value
    parseMaybe (withObject "undo" (.: "snapshot")) value

discardSnapshot :: Connection -> Int -> IO ()
discardSnapshot conn snapshotId =
    execute conn "DELETE FROM undo_snapshots WHERE id = ?" (Only snapshotId)

{- | Names recorded in a tag snapshot payload. A merge can create a tag that
did not exist before the operation; its name is in the payload (it has no tag
row in the snapshot), so restore knows to delete it again.
-}
snapshotNames :: Connection -> Int -> IO [Text]
snapshotNames conn snapshotId = do
    rows <-
        query
            conn
            "SELECT CAST(payload_json AS TEXT) FROM undo_snapshots WHERE id = ?"
            (Only snapshotId) ::
            IO [Only Text]
    pure $ case rows of
        (Only raw : _) ->
            case decode (LBS.fromStrict (TE.encodeUtf8 raw)) :: Maybe Value of
                Nothing -> []
                Just value ->
                    case parseMaybe (withObject "tag_undo" (.:? "names")) value :: Maybe (Maybe [Text]) of
                        Just (Just names) -> names
                        _ -> []
        [] -> []

{- | Count the side rows of one snapshot table. The table name is an internal
literal from this module, never user input.
-}
countRows :: Connection -> Text -> Int -> IO Int
countRows conn table snapshotId = do
    rows <- query conn (Query ("SELECT COUNT(*) FROM " <> table <> " WHERE snapshot_id = ?")) (Only snapshotId) :: IO [Only Int]
    pure (case rows of [Only n] -> n; _ -> 0)

-- | @?,?,?@ for an @IN@ list of known length.
questionMarks :: Int -> Text
questionMarks n = T.intercalate "," (replicate n "?")

epoch :: IO Int
epoch = floor <$> getPOSIXTime

{- | Filter non-positive ids and duplicate ids while keeping the first
occurrence; a side snapshot must not copy or restore the same row twice.
-}
dedupeIds :: [Int] -> [Int]
dedupeIds = go []
  where
    go _ [] = []
    go seen (i : rest)
        | i <= 0 || i `elem` seen = go seen rest
        | otherwise = i : go (i : seen) rest

-- | Lower-case, trim and de-duplicate tag names for a tag snapshot.
dedupeNames :: [Text] -> [Text]
dedupeNames = go []
  where
    go _ [] = []
    go seen (name : rest) =
        let n = T.toLower (T.strip name)
         in if T.null n || n `elem` seen then go seen rest else n : go (n : seen) rest
