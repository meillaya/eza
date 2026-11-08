{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | SQLite data layer: connection setup, schema, migrations, and low-level
-- helpers. The schema is forward only. Every step runs in its own transaction
-- and a verified online backup is written before an existing database changes.
module Eza.Db
  ( initDb
  , openDb
  , migrate
  , ping
  , queryScalar
  , schemaVersion
  , targetSchemaVersion
  , schemaV1
  , schemaV2
  , schemaV3
  , schemaV4
  , schemaV5
  , schemaV6
  , schemaV7
  , schemaV8
  , DbError (..)
  ) where

import Control.Exception (Exception, SomeException, bracket, throwIO, try)
import Control.Monad (forM_, when)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import qualified Database.SQLite.Simple as Sqlite
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))

import Eza.Clip (clipSchema)

newtype DbError = DbError Text
  deriving (Show)

instance Exception DbError

targetSchemaVersion :: Int
targetSchemaVersion = 8

-- | Open the database and bring the schema up to date.
openDb :: FilePath -> IO Sqlite.Connection
openDb path = do
  createDirectoryIfMissing True (takeDirectory path)
  conn <- Sqlite.open path
  mapM_ (Sqlite.execute_ conn) pragmas
  checkFts conn
  migrate path conn
  pure conn

initDb :: FilePath -> IO ()
initDb path = openDb path >> pure ()

migrate :: FilePath -> Sqlite.Connection -> IO ()
migrate dbPath conn = do
  version <- schemaVersion conn
  when (version > targetSchemaVersion) $
    throwIO (DbError ("database schema is newer than this binary: " <> T.pack (show version)))
  when (version > 0) (ensureCompatible conn version)
  when (version > 0 && version < targetSchemaVersion) (preMigrationBackup dbPath conn version)
  applyFrom conn version

-- A v1-v6 database without app_state belongs to the old Python application.
ensureCompatible :: Sqlite.Connection -> Int -> IO ()
ensureCompatible conn version = do
  hasAppState <- tableExists conn "app_state"
  when (not hasAppState && version >= 1 && version <= 6) $
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

preMigrationBackup :: FilePath -> Sqlite.Connection -> Int -> IO ()
preMigrationBackup dbPath conn fromVersion = do
  configured <- lookupEnv "EZA_BACKUP_DIR"
  let backupDir = fromMaybe (takeDirectory dbPath </> "backups") configured
  createDirectoryIfMissing True backupDir
  now <- floor <$> getPOSIXTime :: IO Integer
  let target = backupDir </> ("pre-migration-v" <> show fromVersion <> "-" <> show now <> ".db")
      escaped = T.replace "'" "''" (T.pack target)
  Sqlite.execute_ conn (Query ("VACUUM INTO '" <> escaped <> "'"))
  bracket (Sqlite.open target) Sqlite.close $ \backup -> do
    rows <- query_ backup "PRAGMA integrity_check" :: IO [Only Text]
    case rows of
      [Only "ok"] -> pure ()
      _ -> throwIO (DbError ("backup verification failed: " <> T.pack target))

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
  , "PRAGMA busy_timeout = 5000"
  , "PRAGMA temp_store = MEMORY"
  , "PRAGMA mmap_size = 268435456"
  , "PRAGMA cache_size = -65536"
  ]

migrations :: [(Int, [Query])]
migrations = [(1, schemaV1), (2, schemaV2), (3, schemaV3), (4, schemaV4), (5, schemaV5), (6, schemaV6), (7, schemaV7), (8, schemaV8)]

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
