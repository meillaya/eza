{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | SQLite data layer: connection setup, schema, migrations, and low-level
helpers. The schema is forward only. Every step runs in its own transaction
and a verified online backup is written before an existing database changes.
-}
module Eza.Db (
    initDb,
    openDb,
    migrate,
    ping,
    queryScalar,
    schemaVersion,
    targetSchemaVersion,
    schemaV1,
    schemaV2,
    schemaV3,
    schemaV4,
    schemaV5,
    schemaV6,
    schemaV7,
    schemaV8,
    schemaV9,
    schemaV10,
    schemaV11,
    schemaV12,
    schemaV13,
    schemaV14,
    schemaV15,
    maxStoredTimestamp,
    normaliseTimestamp,
    databaseClaimed,
    ftsIntegrityCheck,
    DbError (..),
) where

import Control.Exception (Exception, SomeException, bracket, throwIO, try)
import Control.Monad (forM_, when)
import Crypto.Random (getRandomBytes)
import qualified Data.ByteString as BS
import Data.Char (isAlphaNum)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import qualified Database.SQLite.Simple as Sqlite
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, takeFileName, (</>))

import Eza.Clip (clipSchema)
import Eza.Views (seedDefaultViews)

newtype DbError = DbError Text
    deriving (Show)

instance Exception DbError

targetSchemaVersion :: Int
targetSchemaVersion = 15

{- | The last POSIX second SQLite can render as a calendar date: 9999-12-31
23:59:59 UTC. A stored @created_at@ above this makes @strftime@ and @date@
return NULL, which used to break a whole list or statistics query.
-}
maxStoredTimestamp :: Int
maxStoredTimestamp = 253402300799

{- | Normalise an imported timestamp before it is written to @created_at@.

A seconds value outside @[0, maxStoredTimestamp]@ cannot be rendered by
SQLite, so it is never stored as-is: the common 13-digit millisecond exporter
bug is converted to seconds, and any other out-of-range value becomes 0
("no original save date"), which is the value an export without a founding
date already uses. Zero stays zero because a row with no filing date is
legitimate.
-}
normaliseTimestamp :: Int -> Int
normaliseTimestamp raw
    | raw <= 0 = 0
    | raw <= maxStoredTimestamp = raw
    | raw >= firstPlausibleMillisecond && raw <= maxStoredTimestamp * 1000 = raw `div` 1000
    | otherwise = 0
  where
    -- 2000-01-01 as milliseconds. A millisecond @ADD_DATE@ below that is not
    -- a real saved date, so it is dropped rather than divided into a bogus
    -- 1970s second value.
    firstPlausibleMillisecond = 946684800000

{- | Open the database and bring the schema up to date. Every open also makes
sure the default graph view exists, so a fresh or migrated database always
has something the graph screen can open.
-}
openDb :: FilePath -> IO Sqlite.Connection
openDb path = do
    createDirectoryIfMissing True (takeDirectory path)
    conn <- Sqlite.open path
    mapM_ (Sqlite.execute_ conn) pragmas
    checkFts conn
    migrate path conn
    seedDefaultViews conn
    pure conn

initDb :: FilePath -> IO ()
initDb path = openDb path >> pure ()

migrate :: FilePath -> Sqlite.Connection -> IO ()
migrate dbPath conn = do
    version <- schemaVersion conn
    when (version > targetSchemaVersion) $
        throwIO (DbError ("database schema is newer than this binary: " <> T.pack (show version)))
    ensureCompatible conn version
    when (version > 0 && version < targetSchemaVersion) (preMigrationBackup dbPath conn version)
    applyFrom conn version

-- A v1-v6 database without app_state belongs to the old Python application.
-- So does a never-stamped (user_version 0) Python database: its bookmarks
-- table predates the added_at column the new schema requires.
ensureCompatible :: Sqlite.Connection -> Int -> IO ()
ensureCompatible conn version = do
    hasAppState <- tableExists conn "app_state"
    hasBookmarks <- tableExists conn "bookmarks"
    hasAddedAt <- if hasBookmarks then columnExists conn "bookmarks" "added_at" else pure True
    let versionedPython = not hasAppState && version >= 1 && version <= 6
        unstampedPython = version == 0 && hasBookmarks && not hasAddedAt
    when (versionedPython || unstampedPython) $
        throwIO (DbError "legacy Python eza DB detected; the new app expects a fresh database (data/eza.db). Import the HTML export instead.")

applyFrom :: Sqlite.Connection -> Int -> IO ()
applyFrom conn start = forM_ (filter ((> start) . fst) migrations) $ \(version, statements) -> do
    Sqlite.execute_ conn "BEGIN IMMEDIATE"
    result <- runStatements statements
    case result of
        Left err -> do
            Sqlite.execute_ conn "ROLLBACK"
            throwIO (DbError ("migration to schema v" <> T.pack (show version) <> " failed: " <> err))
        Right () -> do
            Sqlite.execute_ conn (Query ("PRAGMA user_version = " <> T.pack (show version)))
            Sqlite.execute_ conn "COMMIT"
  where
    runStatements [] = pure (Right ())
    runStatements (statement : rest) = do
        outcome <- try (Sqlite.execute_ conn statement) :: IO (Either SomeException ())
        case outcome of
            Left err -> pure (Left (T.pack (show err)))
            Right () -> runStatements rest

{- | Copy the database before a migration with @VACUUM INTO@ and verify the
copy. The name carries the database file name and random bytes: every user
database in one installation shares @EZA_BACKUP_DIR@, so a name that only had
the version and the second would collide when two accounts migrate within the
same second.

The copy goes to @EZA_BACKUP_DIR@ when it is set. When it is unset the copy
lands next to the database in @users/<id>/backups/@ (or @data/backups/@ for
the legacy bootstrap database); @Eza.Backup.pruneBackups@ prunes the configured
directory and those sibling directories on the normal keep window.
-}
preMigrationBackup :: FilePath -> Sqlite.Connection -> Int -> IO ()
preMigrationBackup dbPath conn fromVersion = do
    configured <- lookupEnv "EZA_BACKUP_DIR"
    let backupDir = fromMaybe (takeDirectory dbPath </> "backups") configured
    createDirectoryIfMissing True backupDir
    now <- floor <$> getPOSIXTime :: IO Integer
    suffix <- randomHex
    let target =
            backupDir
                </> ( "pre-migration-v"
                        <> show fromVersion
                        <> "-"
                        <> sanitizeName (takeFileName dbPath)
                        <> "-"
                        <> show now
                        <> "-"
                        <> suffix
                        <> ".db"
                    )
        escaped = T.replace "'" "''" (T.pack target)
    Sqlite.execute_ conn (Query ("VACUUM INTO '" <> escaped <> "'"))
    bracket (Sqlite.open target) Sqlite.close $ \backup -> do
        rows <- query_ backup "PRAGMA integrity_check" :: IO [Only Text]
        case rows of
            [Only "ok"] -> pure ()
            _ -> throwIO (DbError ("backup verification failed: " <> T.pack target))

-- | A short random hex suffix for a file name.
randomHex :: IO String
randomHex = do
    bytes <- getRandomBytes 6 :: IO BS.ByteString
    pure (concatMap hexByte (BS.unpack bytes))
  where
    hexByte byte =
        let (high, low) = (byte `div` 16, byte `mod` 16)
         in [hexDigit high, hexDigit low]
    hexDigit value
        | value < 10 = toEnum (fromEnum '0' + fromIntegral value :: Int)
        | otherwise = toEnum (fromEnum 'a' + fromIntegral (value - 10) :: Int)

-- | Keep a file name safe for a backup directory entry.
sanitizeName :: String -> String
sanitizeName = map (\c -> if isAlphaNum c || c `elem` ("-._" :: String) then c else '_')

{- | True when the database at the path is an eza database whose account was
claimed (@app_state.setup_claimed = 1@). Missing, malformed, and non-eza files
return False without creating or migrating anything; the CLI uses this to tell
an unclaimed legacy file from a real account.
-}
databaseClaimed :: FilePath -> IO Bool
databaseClaimed path = do
    exists <- doesFileExist path
    if not exists
        then pure False
        else do
            result <-
                try
                    ( bracket (Sqlite.open path) Sqlite.close $ \conn -> do
                        rows <- query_ conn "SELECT setup_claimed FROM app_state WHERE id = 1" :: IO [Only Int]
                        pure (case rows of [Only n] -> n /= 0; _ -> False)
                    ) ::
                    IO (Either SomeException Bool)
            pure (either (const False) id result)

{- | Check the FTS5 index against the content table. The bare
@integrity-check@ command validates the index structure; the second form with
@rank = 1@ also re-reads the external content table and raises
@database disk image is malformed@ when the index and @bookmarks@ have drifted
apart (for example after a restore that bypassed the sync triggers). Returns
the error text, or @Right ()@ when the index is consistent.
-}
ftsIntegrityCheck :: Sqlite.Connection -> IO (Either Text ())
ftsIntegrityCheck conn = do
    structure <-
        try (Sqlite.execute_ conn "INSERT INTO bookmarks_fts(bookmarks_fts) VALUES('integrity-check')") ::
            IO (Either SomeException ())
    case structure of
        Left err -> pure (Left (T.pack (show err)))
        Right () -> do
            content <-
                try (Sqlite.execute_ conn "INSERT INTO bookmarks_fts(bookmarks_fts, rank) VALUES('integrity-check', 1)") ::
                    IO (Either SomeException ())
            pure (either (Left . T.pack . show) Right content)

schemaVersion :: Sqlite.Connection -> IO Int
schemaVersion conn = do
    rows <- Sqlite.query_ conn "PRAGMA user_version" :: IO [Only Int]
    pure (case rows of [Only n] -> n; _ -> 0)

ping :: Sqlite.Connection -> IO Bool
ping conn = do
    rows <- Sqlite.query_ conn "SELECT 1" :: IO [Only Int]
    pure (not (null rows))

queryScalar :: Sqlite.Connection -> Query -> IO Int
queryScalar conn q = do
    rows <- Sqlite.query_ conn q :: IO [Only Int]
    pure (case rows of [Only n] -> n; _ -> 0)

tableExists :: Sqlite.Connection -> String -> IO Bool
tableExists conn name = do
    rows <- Sqlite.query conn "SELECT name FROM sqlite_master WHERE type='table' AND name=?" (Only (T.pack name)) :: IO [Only Text]
    pure (not (null rows))

columnExists :: Sqlite.Connection -> String -> String -> IO Bool
columnExists conn table column = do
    rows <-
        Sqlite.query
            conn
            "SELECT name FROM pragma_table_info(?) WHERE name = ?"
            (T.pack table, T.pack column) ::
            IO [Only Text]
    pure (not (null rows))

checkFts :: Sqlite.Connection -> IO ()
checkFts conn = do
    options <- Sqlite.query_ conn "PRAGMA compile_options" :: IO [Only Text]
    let hasFts = any (\(Only o) -> "ENABLE_FTS5" `T.isInfixOf` o) options
    if hasFts
        then pure ()
        else throwIO (DbError "SQLite was built without FTS5. Rebuild direct-sqlite with the fulltextsearch flag (or use a system SQLite built with FTS5).")

pragmas :: [Query]
pragmas =
    [ "PRAGMA journal_mode = WAL"
    , "PRAGMA synchronous = NORMAL"
    , "PRAGMA foreign_keys = ON"
    , "PRAGMA recursive_triggers = ON"
    , "PRAGMA busy_timeout = 5000"
    , "PRAGMA temp_store = MEMORY"
    , "PRAGMA mmap_size = 268435456"
    , "PRAGMA cache_size = -65536"
    ]

migrations :: [(Int, [Query])]
migrations =
    [ (1, schemaV1)
    , (2, schemaV2)
    , (3, schemaV3)
    , (4, schemaV4)
    , (5, schemaV5)
    , (6, schemaV6)
    , (7, schemaV7)
    , (8, schemaV8)
    , (9, schemaV9)
    , (10, schemaV10)
    , (11, schemaV11)
    , (12, schemaV12)
    , (13, schemaV13)
    , (14, schemaV14)
    , (15, schemaV15)
    ]

schemaV1 :: [Query]
schemaV1 =
    [ "CREATE TABLE IF NOT EXISTS bookmarks (     id INTEGER PRIMARY KEY AUTOINCREMENT,     url TEXT NOT NULL UNIQUE,     title TEXT NOT NULL DEFAULT '',     description TEXT NOT NULL DEFAULT '',     favicon_url TEXT NOT NULL DEFAULT '',     domain TEXT NOT NULL DEFAULT '',     source TEXT NOT NULL DEFAULT 'manual',     created_at INTEGER NOT NULL,     added_at INTEGER NOT NULL,     updated_at INTEGER NOT NULL,     last_opened_at INTEGER,     last_checked_at INTEGER,     open_count INTEGER NOT NULL DEFAULT 0,     is_dead INTEGER NOT NULL DEFAULT 0,     is_read INTEGER NOT NULL DEFAULT 0,     note_body TEXT NOT NULL DEFAULT '',     extracted_text TEXT NOT NULL DEFAULT '',     author TEXT NOT NULL DEFAULT '',     sitename TEXT NOT NULL DEFAULT '',     published_at INTEGER,     language TEXT NOT NULL DEFAULT '',     image_url TEXT NOT NULL DEFAULT '',     final_url TEXT NOT NULL DEFAULT '',     snapshot_path TEXT NOT NULL DEFAULT '',     snapshot_kind TEXT NOT NULL DEFAULT '',     snapshot_captured_at INTEGER     )"
    , "CREATE INDEX IF NOT EXISTS idx_bookmarks_created ON bookmarks(created_at DESC, id DESC)"
    , "CREATE INDEX IF NOT EXISTS idx_bookmarks_added ON bookmarks(added_at DESC, id DESC)"
    , "CREATE INDEX IF NOT EXISTS idx_bookmarks_domain ON bookmarks(domain)"
    , "CREATE INDEX IF NOT EXISTS idx_bookmarks_checked ON bookmarks(last_checked_at)"
    , "CREATE TABLE IF NOT EXISTS tags (     id INTEGER PRIMARY KEY AUTOINCREMENT,     name TEXT NOT NULL UNIQUE COLLATE NOCASE,     created_at INTEGER NOT NULL     )"
    , "CREATE TABLE IF NOT EXISTS bookmark_tags (     bookmark_id INTEGER NOT NULL REFERENCES bookmarks(id) ON DELETE CASCADE,     tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,     PRIMARY KEY (bookmark_id, tag_id)     )"
    , "CREATE INDEX IF NOT EXISTS idx_bookmark_tags_tag ON bookmark_tags(tag_id)"
    , "CREATE TABLE IF NOT EXISTS links (     id INTEGER PRIMARY KEY AUTOINCREMENT,     source_id INTEGER REFERENCES bookmarks(id) ON DELETE CASCADE,     target_id INTEGER REFERENCES bookmarks(id) ON DELETE CASCADE,     target_title TEXT NOT NULL DEFAULT '',     display_text TEXT,     line_number INTEGER,     UNIQUE(source_id, target_id, line_number)     )"
    , "CREATE INDEX IF NOT EXISTS idx_links_source ON links(source_id)"
    , "CREATE INDEX IF NOT EXISTS idx_links_target ON links(target_id)"
    , "CREATE TABLE IF NOT EXISTS saved_searches (     id INTEGER PRIMARY KEY AUTOINCREMENT,     name TEXT NOT NULL,     q TEXT NOT NULL DEFAULT '',     tags_json TEXT NOT NULL DEFAULT '[]',     created_at INTEGER NOT NULL     )"
    , "CREATE TABLE IF NOT EXISTS undo_snapshots (     id INTEGER PRIMARY KEY AUTOINCREMENT,     payload_json TEXT NOT NULL,     created_at INTEGER NOT NULL     )"
    , "CREATE TABLE IF NOT EXISTS app_state (     id INTEGER PRIMARY KEY CHECK (id = 1),     setup_claimed INTEGER NOT NULL DEFAULT 0,     created_at INTEGER NOT NULL     )"
    , "INSERT OR IGNORE INTO app_state (id, setup_claimed, created_at) VALUES (1, 0, strftime('%s','now'))"
    , "CREATE TABLE IF NOT EXISTS passkey_credentials (     credential_id BLOB PRIMARY KEY,     user_handle BLOB NOT NULL,     public_key BLOB NOT NULL,     sign_count INTEGER NOT NULL DEFAULT 0,     transports TEXT NOT NULL DEFAULT '[]',     backup_eligible INTEGER NOT NULL DEFAULT 0,     backup_state INTEGER NOT NULL DEFAULT 0,     aaguid BLOB,     nickname TEXT NOT NULL DEFAULT '',     created_at INTEGER NOT NULL,     last_used_at INTEGER     )"
    , "CREATE TABLE IF NOT EXISTS webauthn_challenges (     challenge BLOB PRIMARY KEY,     purpose TEXT NOT NULL,     created_at INTEGER NOT NULL,     expires_at INTEGER NOT NULL     )"
    , "CREATE TABLE IF NOT EXISTS sessions (     id TEXT PRIMARY KEY,     csrf_hash TEXT NOT NULL,     scope TEXT NOT NULL DEFAULT 'normal',     created_at INTEGER NOT NULL,     expires_at INTEGER NOT NULL,     last_seen_at INTEGER     )"
    , "CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at)"
    , "CREATE TABLE IF NOT EXISTS recovery_codes (     code_hash TEXT PRIMARY KEY,     used INTEGER NOT NULL DEFAULT 0,     created_at INTEGER NOT NULL,     redeemed_at INTEGER     )"
    , "CREATE TABLE IF NOT EXISTS import_runs (     id INTEGER PRIMARY KEY AUTOINCREMENT,     source TEXT NOT NULL,     started_at INTEGER NOT NULL,     finished_at INTEGER,     report_json TEXT NOT NULL DEFAULT '{}'     )"
    , "CREATE VIRTUAL TABLE IF NOT EXISTS bookmarks_fts USING fts5(     title, description, url, note_body, extracted_text,     content='bookmarks', content_rowid='id', tokenize='porter unicode61'     )"
    , "CREATE TRIGGER IF NOT EXISTS bookmarks_ai AFTER INSERT ON bookmarks BEGIN     INSERT INTO bookmarks_fts(rowid, title, description, url, note_body, extracted_text)     VALUES (new.id, new.title, new.description, new.url, new.note_body, new.extracted_text);     END"
    , "CREATE TRIGGER IF NOT EXISTS bookmarks_ad AFTER DELETE ON bookmarks BEGIN     INSERT INTO bookmarks_fts(bookmarks_fts, rowid, title, description, url, note_body, extracted_text)     VALUES('delete', old.id, old.title, old.description, old.url, old.note_body, old.extracted_text);     END"
    , "CREATE TRIGGER IF NOT EXISTS bookmarks_au AFTER UPDATE ON bookmarks     WHEN old.title IS NOT new.title OR old.description IS NOT new.description     OR old.url IS NOT new.url OR old.note_body IS NOT new.note_body     OR old.extracted_text IS NOT new.extracted_text     BEGIN     INSERT INTO bookmarks_fts(bookmarks_fts, rowid, title, description, url, note_body, extracted_text)     VALUES('delete', old.id, old.title, old.description, old.url, old.note_body, old.extracted_text);     INSERT INTO bookmarks_fts(rowid, title, description, url, note_body, extracted_text)     VALUES (new.id, new.title, new.description, new.url, new.note_body, new.extracted_text);     END"
    , "INSERT INTO bookmarks_fts(bookmarks_fts) VALUES('rebuild')"
    ]

schemaV2 :: [Query]
schemaV2 =
    [ "ALTER TABLE bookmarks ADD COLUMN enrich_state TEXT NOT NULL DEFAULT 'idle'"
    , "ALTER TABLE bookmarks ADD COLUMN enrich_error TEXT NOT NULL DEFAULT ''"
    , "ALTER TABLE bookmarks ADD COLUMN enrich_attempts INTEGER NOT NULL DEFAULT 0"
    , "ALTER TABLE bookmarks ADD COLUMN enriched_at INTEGER"
    , "ALTER TABLE bookmarks ADD COLUMN reading_time_minutes INTEGER NOT NULL DEFAULT 0"
    , "CREATE TABLE IF NOT EXISTS favicons (     domain TEXT PRIMARY KEY,     source_url TEXT NOT NULL DEFAULT '',     mime TEXT NOT NULL,     bytes BLOB NOT NULL,     content_hash TEXT NOT NULL DEFAULT '',     etag TEXT NOT NULL DEFAULT '',     last_modified TEXT NOT NULL DEFAULT '',     fetched_at INTEGER NOT NULL,     last_error TEXT NOT NULL DEFAULT '',     fail_count INTEGER NOT NULL DEFAULT 0     )"
    , "CREATE TABLE IF NOT EXISTS jobs (     id INTEGER PRIMARY KEY AUTOINCREMENT,     kind TEXT NOT NULL,     bookmark_id INTEGER REFERENCES bookmarks(id) ON DELETE CASCADE,     state TEXT NOT NULL DEFAULT 'queued',     attempts INTEGER NOT NULL DEFAULT 0,     available_at INTEGER NOT NULL,     last_error TEXT NOT NULL DEFAULT '',     created_at INTEGER NOT NULL,     updated_at INTEGER NOT NULL     )"
    , "CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_active ON jobs(kind, bookmark_id) WHERE state IN ('queued','running')"
    , "CREATE INDEX IF NOT EXISTS idx_jobs_ready ON jobs(state, available_at)"
    ]

schemaV3 :: [Query]
schemaV3 =
    [ "CREATE TABLE IF NOT EXISTS api_tokens (     id INTEGER PRIMARY KEY AUTOINCREMENT,     name TEXT NOT NULL,     token_hash TEXT NOT NULL UNIQUE,     token_prefix TEXT NOT NULL,     scopes TEXT NOT NULL DEFAULT 'read,write',     created_at INTEGER NOT NULL,     last_used_at INTEGER,     revoked_at INTEGER     )"
    , "ALTER TABLE undo_snapshots ADD COLUMN op TEXT NOT NULL DEFAULT ''"
    , "ALTER TABLE undo_snapshots ADD COLUMN row_count INTEGER NOT NULL DEFAULT 0"
    , "CREATE TABLE IF NOT EXISTS undo_bookmark_rows (     snapshot_id INTEGER NOT NULL REFERENCES undo_snapshots(id) ON DELETE CASCADE,     id INTEGER NOT NULL,     url TEXT NOT NULL DEFAULT '',     title TEXT NOT NULL DEFAULT '',     description TEXT NOT NULL DEFAULT '',     favicon_url TEXT NOT NULL DEFAULT '',     domain TEXT NOT NULL DEFAULT '',     source TEXT NOT NULL DEFAULT '',     created_at INTEGER NOT NULL,     added_at INTEGER NOT NULL,     updated_at INTEGER NOT NULL,     last_opened_at INTEGER,     last_checked_at INTEGER,     open_count INTEGER NOT NULL DEFAULT 0,     is_dead INTEGER NOT NULL DEFAULT 0,     is_read INTEGER NOT NULL DEFAULT 0,     note_body TEXT NOT NULL DEFAULT '',     extracted_text TEXT NOT NULL DEFAULT '',     author TEXT NOT NULL DEFAULT '',     sitename TEXT NOT NULL DEFAULT '',     published_at INTEGER,     language TEXT NOT NULL DEFAULT '',     image_url TEXT NOT NULL DEFAULT '',     final_url TEXT NOT NULL DEFAULT '',     snapshot_path TEXT NOT NULL DEFAULT '',     snapshot_kind TEXT NOT NULL DEFAULT '',     snapshot_captured_at INTEGER,     enrich_state TEXT NOT NULL DEFAULT 'idle',     enrich_error TEXT NOT NULL DEFAULT '',     enrich_attempts INTEGER NOT NULL DEFAULT 0,     enriched_at INTEGER,     reading_time_minutes INTEGER NOT NULL DEFAULT 0,     PRIMARY KEY (snapshot_id, id)     )"
    , "CREATE TABLE IF NOT EXISTS undo_bookmark_tags (     snapshot_id INTEGER NOT NULL REFERENCES undo_snapshots(id) ON DELETE CASCADE,     bookmark_id INTEGER NOT NULL,     tag_name TEXT NOT NULL,     PRIMARY KEY (snapshot_id, bookmark_id, tag_name)     )"
    ]

schemaV4 :: [Query]
schemaV4 =
    [ "CREATE TABLE IF NOT EXISTS highlights (     id INTEGER PRIMARY KEY AUTOINCREMENT,     bookmark_id INTEGER NOT NULL REFERENCES bookmarks(id) ON DELETE CASCADE,     quote TEXT NOT NULL,     prefix TEXT NOT NULL DEFAULT '',     suffix TEXT NOT NULL DEFAULT '',     start_offset INTEGER NOT NULL,     end_offset INTEGER NOT NULL,     note TEXT NOT NULL DEFAULT '',     color TEXT NOT NULL DEFAULT 'yellow',     created_at INTEGER NOT NULL,     updated_at INTEGER NOT NULL     )"
    , "CREATE INDEX IF NOT EXISTS idx_highlights_bookmark ON highlights(bookmark_id)"
    , "CREATE TABLE IF NOT EXISTS share_links (     id INTEGER PRIMARY KEY AUTOINCREMENT,     token_hash TEXT NOT NULL UNIQUE,     token_prefix TEXT NOT NULL,     scope TEXT NOT NULL,     target_id INTEGER NOT NULL,     include_note INTEGER NOT NULL DEFAULT 0,     created_at INTEGER NOT NULL,     expires_at INTEGER NOT NULL,     revoked_at INTEGER,     last_accessed_at INTEGER     )"
    , "CREATE INDEX IF NOT EXISTS idx_share_links_target ON share_links(scope, target_id)"
    ]

schemaV5 :: [Query]
schemaV5 =
    [ "ALTER TABLE bookmarks ADD COLUMN ai_summary TEXT NOT NULL DEFAULT ''"
    , "ALTER TABLE bookmarks ADD COLUMN ai_tagged_at INTEGER"
    , "ALTER TABLE undo_bookmark_rows ADD COLUMN ai_summary TEXT NOT NULL DEFAULT ''"
    , "ALTER TABLE undo_bookmark_rows ADD COLUMN ai_tagged_at INTEGER"
    , "CREATE TABLE IF NOT EXISTS rules (     id INTEGER PRIMARY KEY AUTOINCREMENT,     name TEXT NOT NULL,     enabled INTEGER NOT NULL DEFAULT 1,     field TEXT NOT NULL DEFAULT 'url',     pattern TEXT NOT NULL,     add_tags TEXT NOT NULL DEFAULT '[]',     mark_read INTEGER NOT NULL DEFAULT 0,     created_at INTEGER NOT NULL     )"
    ]

{- | v6 turns the passkey-only account into a single username/password account.
The passkey tables stay for installations that migrate from v5; passkeys are
legacy credentials once a password exists. The login counters live on the same
single row so a failed attempt survives a restart.
-}
schemaV6 :: [Query]
schemaV6 =
    [ "ALTER TABLE app_state ADD COLUMN username TEXT NOT NULL DEFAULT ''"
    , "ALTER TABLE app_state ADD COLUMN password_hash TEXT NOT NULL DEFAULT ''"
    , "ALTER TABLE app_state ADD COLUMN password_updated_at INTEGER"
    , "ALTER TABLE app_state ADD COLUMN require_passkey INTEGER NOT NULL DEFAULT 0"
    , "ALTER TABLE app_state ADD COLUMN failed_login_count INTEGER NOT NULL DEFAULT 0"
    , "ALTER TABLE app_state ADD COLUMN failed_login_at INTEGER"
    , "ALTER TABLE app_state ADD COLUMN login_blocked_until INTEGER"
    , "ALTER TABLE app_state ADD COLUMN last_login_at INTEGER"
    ]

{- | v7 makes undo lossless for the data that hangs off a bookmark or a tag.

A side snapshot used to copy only bookmark rows and bookmark/tag names. It now
also copies the highlights attached to the affected bookmarks, the wikilinks
whose source or target is affected, and the tag rows themselves, so undoing a
delete, prune, bulk operation or merge can bring those rows back instead of
silently dropping them. Tag-only operations get their own snapshot tables: the
affected tag rows and the bookmark/tag links that pointed at them.

'undo_bookmark_rows' already carries every column of @bookmarks@ (v1 columns
plus the v2 enrichment/reading columns and the v5 AI columns), so this step
only adds the missing companion tables.
-}
schemaV7 :: [Query]
schemaV7 =
    [ "CREATE TABLE IF NOT EXISTS undo_highlight_rows (     snapshot_id INTEGER NOT NULL REFERENCES undo_snapshots(id) ON DELETE CASCADE,     id INTEGER NOT NULL,     bookmark_id INTEGER NOT NULL,     quote TEXT NOT NULL DEFAULT '',     prefix TEXT NOT NULL DEFAULT '',     suffix TEXT NOT NULL DEFAULT '',     start_offset INTEGER NOT NULL DEFAULT 0,     end_offset INTEGER NOT NULL DEFAULT 0,     note TEXT NOT NULL DEFAULT '',     color TEXT NOT NULL DEFAULT 'yellow',     created_at INTEGER NOT NULL DEFAULT 0,     updated_at INTEGER NOT NULL DEFAULT 0,     PRIMARY KEY (snapshot_id, id)     )"
    , "CREATE TABLE IF NOT EXISTS undo_link_rows (     snapshot_id INTEGER NOT NULL REFERENCES undo_snapshots(id) ON DELETE CASCADE,     id INTEGER NOT NULL,     source_id INTEGER,     target_id INTEGER,     target_title TEXT NOT NULL DEFAULT '',     display_text TEXT,     line_number INTEGER,     PRIMARY KEY (snapshot_id, id)     )"
    , "CREATE TABLE IF NOT EXISTS undo_tag_rows (     snapshot_id INTEGER NOT NULL REFERENCES undo_snapshots(id) ON DELETE CASCADE,     id INTEGER NOT NULL,     name TEXT NOT NULL COLLATE NOCASE,     created_at INTEGER NOT NULL DEFAULT 0,     PRIMARY KEY (snapshot_id, id)     )"
    ]

{- | v8 adds the browser-clipper capture history and the data-driven clip
templates. The statements live in "Eza.Clip" so the payload contract and the
schema stay together; migrations remain append-only.
-}
schemaV8 :: [Query]
schemaV8 = map Query clipSchema

{- | v9 adds the indexes the list and statistics queries need, measured on the
reference database with EXPLAIN QUERY PLAN:

* @idx_bookmarks_opened@ turns the @sort=opened@ ledger page from a full scan
  with a temporary B-tree into an ordered index scan.
* @idx_bookmarks_unread@ and @idx_bookmarks_dead@ are partial, so the flag
  filters only pay for the matching rows.
* @idx_bookmarks_year@ covers the per-year ledger counts that every first page
  carries. Without it SQLite scans the created_at index and builds a temporary
  B-tree for @GROUP BY strftime('%Y', ...)@; with it the same query is a plain
  index scan (measured 3.7 ms to 0.75 ms on 14,582 rows).

A @date(created_at, 'unixepoch')@ expression index was also tried for the
statistics day grouping and made that query slower, so it is not shipped here.
-}
schemaV9 :: [Query]
schemaV9 =
    [ "CREATE INDEX IF NOT EXISTS idx_bookmarks_opened ON bookmarks(last_opened_at DESC, id DESC)"
    , "CREATE INDEX IF NOT EXISTS idx_bookmarks_unread ON bookmarks(created_at DESC, id DESC) WHERE is_read = 0"
    , "CREATE INDEX IF NOT EXISTS idx_bookmarks_dead ON bookmarks(created_at DESC, id DESC) WHERE is_dead = 1"
    , "CREATE INDEX IF NOT EXISTS idx_bookmarks_year ON bookmarks(CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER))"
    ]

{- | v10 adds the declarative views table. A view is user data (name, kind,
definition JSON, default flag), never schema: the client renders only the
fields it knows and the server validates every definition before storing it.

The partial unique index keeps at most one default per kind, which is what the
graph screen relies on when it opens the default view. Rows are seeded by
'Eza.Views.seedDefaultViews' after the migration, not by this step, so a
database that migrates and a fresh database take the same path.
-}
schemaV10 :: [Query]
schemaV10 =
    [ "CREATE TABLE IF NOT EXISTS views (     id INTEGER PRIMARY KEY AUTOINCREMENT,     slug TEXT NOT NULL UNIQUE,     name TEXT NOT NULL,     kind TEXT NOT NULL CHECK(kind IN ('graph','ledger')),     definition_json TEXT NOT NULL,     is_default INTEGER NOT NULL DEFAULT 0,     created_at INTEGER NOT NULL,     updated_at INTEGER NOT NULL     )"
    , "CREATE UNIQUE INDEX IF NOT EXISTS idx_views_one_default ON views(kind) WHERE is_default = 1"
    ]

{- | v11 adds the M2 extension platform: the durable event outbox, the webhook
subscriptions, and the delivery queue.

The outbox row exists only when the write that produced it committed, because
writes call 'Eza.Events.recordEvent' inside their own transaction. The
delivery queue has a UNIQUE(webhook_id, event_id) guard so fan-out is
idempotent, and @app_state.event_cursor@ is the persistent per-database
dispatcher cursor: events up to that id have been fanned out.

Note that @webhook_deliveries.event_id@ deliberately has no foreign key: events
are purged after 30 days while their delivery history is kept.
-}
schemaV11 :: [Query]
schemaV11 =
    [ "CREATE TABLE IF NOT EXISTS event_log (     id INTEGER PRIMARY KEY AUTOINCREMENT,     kind TEXT NOT NULL,     payload_json TEXT NOT NULL,     created_at INTEGER NOT NULL     )"
    , "CREATE INDEX IF NOT EXISTS idx_event_log_created ON event_log(created_at)"
    , "CREATE TABLE IF NOT EXISTS webhooks (     id INTEGER PRIMARY KEY AUTOINCREMENT,     name TEXT NOT NULL,     url TEXT NOT NULL,     secret TEXT NOT NULL,     events_json TEXT NOT NULL,     enabled INTEGER NOT NULL DEFAULT 1,     created_at INTEGER NOT NULL,     last_status INTEGER,     last_attempt_at INTEGER,     last_error TEXT NOT NULL DEFAULT '',     fail_streak INTEGER NOT NULL DEFAULT 0     )"
    , "CREATE TABLE IF NOT EXISTS webhook_deliveries (     id INTEGER PRIMARY KEY AUTOINCREMENT,     webhook_id INTEGER NOT NULL REFERENCES webhooks(id) ON DELETE CASCADE,     event_id INTEGER NOT NULL,     state TEXT NOT NULL DEFAULT 'queued',     attempts INTEGER NOT NULL DEFAULT 0,     available_at INTEGER NOT NULL,     last_error TEXT NOT NULL DEFAULT '',     created_at INTEGER NOT NULL,     UNIQUE(webhook_id, event_id)     )"
    , "CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_ready ON webhook_deliveries(state, available_at)"
    , "ALTER TABLE app_state ADD COLUMN event_cursor INTEGER NOT NULL DEFAULT 0"
    ]

{- | v12 makes undo lossless for browser-clipper captures.

Schema v8 added @captures@ with @ON DELETE CASCADE@ from bookmarks, but the v7
side snapshot only copied bookmarks, tags, highlights and wikilinks. Deleting,
pruning or merging a bookmark therefore destroyed its capture history even
though undo restored the bookmark row. @undo_capture_rows@ mirrors every
column of @captures@ so a side snapshot restore can put the capture rows back
in the same transaction. The primary key and the cascade from
@undo_snapshots@ match the other @undo_*_rows@ tables, so discarding a snapshot
removes its capture copies too.
-}
schemaV12 :: [Query]
schemaV12 =
    [ "CREATE TABLE IF NOT EXISTS undo_capture_rows (     snapshot_id INTEGER NOT NULL REFERENCES undo_snapshots(id) ON DELETE CASCADE,     id INTEGER NOT NULL,     bookmark_id INTEGER NOT NULL,     url TEXT NOT NULL DEFAULT '',     canonical_url TEXT NOT NULL DEFAULT '',     title TEXT NOT NULL DEFAULT '',     author TEXT NOT NULL DEFAULT '',     site TEXT NOT NULL DEFAULT '',     description TEXT NOT NULL DEFAULT '',     published TEXT NOT NULL DEFAULT '',     language TEXT NOT NULL DEFAULT '',     image_url TEXT NOT NULL DEFAULT '',     favicon_url TEXT NOT NULL DEFAULT '',     content_markdown TEXT NOT NULL DEFAULT '',     rendered_markdown TEXT NOT NULL DEFAULT '',     content_text TEXT NOT NULL DEFAULT '',     content_html TEXT NOT NULL DEFAULT '',     selection TEXT NOT NULL DEFAULT '',     tags TEXT NOT NULL DEFAULT '[]',     template_id INTEGER,     template_name TEXT NOT NULL DEFAULT '',     source TEXT NOT NULL DEFAULT '',     client TEXT NOT NULL DEFAULT '',     idempotency_key TEXT NOT NULL DEFAULT '',     request_hash TEXT NOT NULL DEFAULT '',     extractor TEXT NOT NULL DEFAULT '',     extractor_version TEXT NOT NULL DEFAULT '',     metadata_json TEXT NOT NULL DEFAULT '{}',     word_count INTEGER NOT NULL DEFAULT 0,     parse_time_ms INTEGER NOT NULL DEFAULT 0,     captured_at INTEGER NOT NULL,     created_at INTEGER NOT NULL,     PRIMARY KEY (snapshot_id, id)     )"
    ]

{- | v13 adds the source domain to the full-text index. The domain is what the
ledger's source facets show and what a clicked source writes into the query;
URLs are not a reliable substitute because an import can record
@www.reddit.com@ while the saved URL is @https://reddit.com/...@. The external
content table has to be recreated to add a column, so this migration drops the
old triggers and index and rebuilds both from @bookmarks@.
-}
schemaV13 :: [Query]
schemaV13 =
    [ "DROP TRIGGER IF EXISTS bookmarks_ai"
    , "DROP TRIGGER IF EXISTS bookmarks_ad"
    , "DROP TRIGGER IF EXISTS bookmarks_au"
    , "DROP TABLE IF EXISTS bookmarks_fts"
    , "CREATE VIRTUAL TABLE bookmarks_fts USING fts5(     title, description, url, note_body, extracted_text, domain,     content='bookmarks', content_rowid='id', tokenize='porter unicode61'     )"
    , "CREATE TRIGGER bookmarks_ai AFTER INSERT ON bookmarks BEGIN     INSERT INTO bookmarks_fts(rowid, title, description, url, note_body, extracted_text, domain)     VALUES (new.id, new.title, new.description, new.url, new.note_body, new.extracted_text, new.domain);     END"
    , "CREATE TRIGGER bookmarks_ad AFTER DELETE ON bookmarks BEGIN     INSERT INTO bookmarks_fts(bookmarks_fts, rowid, title, description, url, note_body, extracted_text, domain)     VALUES('delete', old.id, old.title, old.description, old.url, old.note_body, old.extracted_text, old.domain);     END"
    , "CREATE TRIGGER bookmarks_au AFTER UPDATE ON bookmarks     WHEN old.title IS NOT new.title OR old.description IS NOT new.description     OR old.url IS NOT new.url OR old.note_body IS NOT new.note_body     OR old.extracted_text IS NOT new.extracted_text OR old.domain IS NOT new.domain     BEGIN     INSERT INTO bookmarks_fts(bookmarks_fts, rowid, title, description, url, note_body, extracted_text, domain)     VALUES('delete', old.id, old.title, old.description, old.url, old.note_body, old.extracted_text, old.domain);     INSERT INTO bookmarks_fts(rowid, title, description, url, note_body, extracted_text, domain)     VALUES (new.id, new.title, new.description, new.url, new.note_body, new.extracted_text, new.domain);     END"
    , "INSERT INTO bookmarks_fts(bookmarks_fts) VALUES('rebuild')"
    ]

{- | v14 keeps the webhook delivery history readable after the 30-day event
purge. @webhook_deliveries.event_id@ deliberately has no foreign key because
the delivery history outlives the event rows, but the read path joined the
event kind from @event_log@, so a purged event hid its deliveries. The
delivery row now records the kind it was fanned out for; the kind of every
event still present is copied into the existing rows. A delivery whose event
was already purged before this migration keeps an empty kind (the kind is not
recoverable) and stays out of the list, as before.
-}
schemaV14 :: [Query]
schemaV14 =
    [ "ALTER TABLE webhook_deliveries ADD COLUMN event_kind TEXT NOT NULL DEFAULT ''"
    , "UPDATE webhook_deliveries SET event_kind = COALESCE((SELECT e.kind FROM event_log e WHERE e.id = webhook_deliveries.event_id), '')"
    ]

{- | v15 holds two pieces of repair that share a release.

The dead override is user intent, separate from the machine @is_dead@ column:
it keeps a link out of the sweep without teaching every row-copy path about a
new bookmark column. The undo table makes delete/prune undo restore that
intent too.

The favicon cleanup is cache repair, not user data. Failure rows only hold a
one-byte placeholder; deleting them lets the worker retry domains that were
parked before the declared-icon parser landed. Absolute/remote icon URLs are
cleared because the client now only renders the local per-domain cache.
Bookmark rows whose cached icon is at the old 64 KiB cap are reset so a broken
image cannot be served while the worker validates and refetches; the code path
in "Eza.Enrich" crops complete ICOs and rejects anything still incomplete.
-}
schemaV15 :: [Query]
schemaV15 =
    [ "CREATE TABLE IF NOT EXISTS bookmark_dead_overrides ( bookmark_id INTEGER PRIMARY KEY REFERENCES bookmarks(id) ON DELETE CASCADE, reason TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL )"
    , "CREATE TABLE IF NOT EXISTS undo_dead_override_rows ( snapshot_id INTEGER NOT NULL REFERENCES undo_snapshots(id) ON DELETE CASCADE, bookmark_id INTEGER NOT NULL, reason TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (snapshot_id, bookmark_id) )"
    , "DELETE FROM favicons WHERE fail_count > 0 OR length(bytes) <= 1"
    , "UPDATE bookmarks SET favicon_url = '' WHERE favicon_url <> '' AND favicon_url NOT LIKE '/api/v1/favicons/%'"
    , "UPDATE bookmarks SET favicon_url = '' WHERE domain IN (SELECT domain FROM favicons WHERE length(bytes) >= 65536)"
    ]
