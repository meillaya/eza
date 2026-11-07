{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | SQLite data layer: connection setup, schema, migrations, and low-level
-- helpers.  The pool/writer split and the query modules live here as the
-- server grows.
module Eza.Db
  ( initDb
  , openDb
  , migrate
  , ping
  , queryScalar
  , schemaVersion
  , DbError (..)
  ) where

import Control.Exception (Exception, throwIO)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import qualified Database.SQLite.Simple as Sqlite
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

newtype DbError = DbError Text
  deriving (Show)

instance Exception DbError

-- | Open the database and bring the schema up to date.
openDb :: FilePath -> IO Sqlite.Connection
openDb path = do
  createDirectoryIfMissing True (takeDirectory path)
  conn <- Sqlite.open path
  mapM_ (\pragma -> Sqlite.execute_ conn pragma) pragmas
  checkFts conn
  migrate conn
  pure conn

initDb :: FilePath -> IO ()
initDb path = openDb path >> pure ()

migrate :: Sqlite.Connection -> IO ()
migrate conn = do
  version <- schemaVersion conn
  case version of
    0 -> do
      -- Fresh database.  Apply schema v1 in one transaction.
      Sqlite.execute_ conn "BEGIN IMMEDIATE"
      mapM_ (Sqlite.execute_ conn) schemaV1
      Sqlite.execute_ conn "PRAGMA user_version = 1"
      Sqlite.execute_ conn "COMMIT"
    n
      | n >= 1 && n <= 6 -> do
          hasAppState <- tableExists conn "app_state"
          if hasAppState
            then pure ()
            else throwIO (DbError "legacy Python eza DB detected; the new app expects a fresh database (data/eza.db). Import the HTML export instead.")
      | n == 1 -> pure ()
      | otherwise -> pure ()

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

schemaV1 :: [Query]
schemaV1 =
  [ "CREATE TABLE IF NOT EXISTS bookmarks (\
    \ id INTEGER PRIMARY KEY AUTOINCREMENT,\
    \ url TEXT NOT NULL UNIQUE,\
    \ title TEXT NOT NULL DEFAULT '',\
    \ description TEXT NOT NULL DEFAULT '',\
    \ favicon_url TEXT NOT NULL DEFAULT '',\
    \ domain TEXT NOT NULL DEFAULT '',\
    \ source TEXT NOT NULL DEFAULT 'manual',\
    \ created_at INTEGER NOT NULL,\
    \ added_at INTEGER NOT NULL,\
    \ updated_at INTEGER NOT NULL,\
    \ last_opened_at INTEGER,\
    \ last_checked_at INTEGER,\
    \ open_count INTEGER NOT NULL DEFAULT 0,\
    \ is_dead INTEGER NOT NULL DEFAULT 0,\
    \ is_read INTEGER NOT NULL DEFAULT 0,\
    \ note_body TEXT NOT NULL DEFAULT '',\
    \ extracted_text TEXT NOT NULL DEFAULT '',\
    \ author TEXT NOT NULL DEFAULT '',\
    \ sitename TEXT NOT NULL DEFAULT '',\
    \ published_at INTEGER,\
    \ language TEXT NOT NULL DEFAULT '',\
    \ image_url TEXT NOT NULL DEFAULT '',\
    \ final_url TEXT NOT NULL DEFAULT '',\
    \ snapshot_path TEXT NOT NULL DEFAULT '',\
    \ snapshot_kind TEXT NOT NULL DEFAULT '',\
    \ snapshot_captured_at INTEGER\
    \ )"
  , "CREATE INDEX IF NOT EXISTS idx_bookmarks_created ON bookmarks(created_at DESC, id DESC)"
  , "CREATE INDEX IF NOT EXISTS idx_bookmarks_added ON bookmarks(added_at DESC, id DESC)"
  , "CREATE INDEX IF NOT EXISTS idx_bookmarks_domain ON bookmarks(domain)"
  , "CREATE INDEX IF NOT EXISTS idx_bookmarks_checked ON bookmarks(last_checked_at)"
  , "CREATE TABLE IF NOT EXISTS tags (\
    \ id INTEGER PRIMARY KEY AUTOINCREMENT,\
    \ name TEXT NOT NULL UNIQUE COLLATE NOCASE,\
    \ created_at INTEGER NOT NULL\
    \ )"
  , "CREATE TABLE IF NOT EXISTS bookmark_tags (\
    \ bookmark_id INTEGER NOT NULL REFERENCES bookmarks(id) ON DELETE CASCADE,\
    \ tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,\
    \ PRIMARY KEY (bookmark_id, tag_id)\
    \ )"
  , "CREATE INDEX IF NOT EXISTS idx_bookmark_tags_tag ON bookmark_tags(tag_id)"
  , "CREATE TABLE IF NOT EXISTS links (\
    \ id INTEGER PRIMARY KEY AUTOINCREMENT,\
    \ source_id INTEGER REFERENCES bookmarks(id) ON DELETE CASCADE,\
    \ target_id INTEGER REFERENCES bookmarks(id) ON DELETE CASCADE,\
    \ target_title TEXT NOT NULL DEFAULT '',\
    \ display_text TEXT,\
    \ line_number INTEGER,\
    \ UNIQUE(source_id, target_id, line_number)\
    \ )"
  , "CREATE INDEX IF NOT EXISTS idx_links_source ON links(source_id)"
  , "CREATE INDEX IF NOT EXISTS idx_links_target ON links(target_id)"
  , "CREATE TABLE IF NOT EXISTS saved_searches (\
    \ id INTEGER PRIMARY KEY AUTOINCREMENT,\
    \ name TEXT NOT NULL,\
    \ q TEXT NOT NULL DEFAULT '',\
    \ tags_json TEXT NOT NULL DEFAULT '[]',\
    \ created_at INTEGER NOT NULL\
    \ )"
  , "CREATE TABLE IF NOT EXISTS undo_snapshots (\
    \ id INTEGER PRIMARY KEY AUTOINCREMENT,\
    \ payload_json TEXT NOT NULL,\
    \ created_at INTEGER NOT NULL\
    \ )"
  , "CREATE TABLE IF NOT EXISTS app_state (\
    \ id INTEGER PRIMARY KEY CHECK (id = 1),\
    \ setup_claimed INTEGER NOT NULL DEFAULT 0,\
    \ created_at INTEGER NOT NULL\
    \ )"
  , "INSERT OR IGNORE INTO app_state (id, setup_claimed, created_at) VALUES (1, 0, strftime('%s','now'))"
  , "CREATE TABLE IF NOT EXISTS passkey_credentials (\
    \ credential_id BLOB PRIMARY KEY,\
    \ user_handle BLOB NOT NULL,\
    \ public_key BLOB NOT NULL,\
    \ sign_count INTEGER NOT NULL DEFAULT 0,\
    \ transports TEXT NOT NULL DEFAULT '[]',\
    \ backup_eligible INTEGER NOT NULL DEFAULT 0,\
    \ backup_state INTEGER NOT NULL DEFAULT 0,\
    \ aaguid BLOB,\
    \ nickname TEXT NOT NULL DEFAULT '',\
    \ created_at INTEGER NOT NULL,\
    \ last_used_at INTEGER\
    \ )"
  , "CREATE TABLE IF NOT EXISTS webauthn_challenges (\
    \ challenge BLOB PRIMARY KEY,\
    \ purpose TEXT NOT NULL,\
    \ created_at INTEGER NOT NULL,\
    \ expires_at INTEGER NOT NULL\
    \ )"
  , "CREATE TABLE IF NOT EXISTS sessions (\
    \ id TEXT PRIMARY KEY,\
    \ csrf_hash TEXT NOT NULL,\
    \ scope TEXT NOT NULL DEFAULT 'normal',\
    \ created_at INTEGER NOT NULL,\
    \ expires_at INTEGER NOT NULL,\
    \ last_seen_at INTEGER\
    \ )"
  , "CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at)"
  , "CREATE TABLE IF NOT EXISTS recovery_codes (\
    \ code_hash TEXT PRIMARY KEY,\
    \ used INTEGER NOT NULL DEFAULT 0,\
    \ created_at INTEGER NOT NULL,\
    \ redeemed_at INTEGER\
    \ )"
  , "CREATE TABLE IF NOT EXISTS import_runs (\
    \ id INTEGER PRIMARY KEY AUTOINCREMENT,\
    \ source TEXT NOT NULL,\
    \ started_at INTEGER NOT NULL,\
    \ finished_at INTEGER,\
    \ report_json TEXT NOT NULL DEFAULT '{}'\
    \ )"
  , "CREATE VIRTUAL TABLE IF NOT EXISTS bookmarks_fts USING fts5(\
    \ title, description, url, note_body, extracted_text,\
    \ content='bookmarks', content_rowid='id', tokenize='porter unicode61'\
    \ )"
  , "CREATE TRIGGER IF NOT EXISTS bookmarks_ai AFTER INSERT ON bookmarks BEGIN\
    \ INSERT INTO bookmarks_fts(rowid, title, description, url, note_body, extracted_text)\
    \ VALUES (new.id, new.title, new.description, new.url, new.note_body, new.extracted_text);\
    \ END"
  , "CREATE TRIGGER IF NOT EXISTS bookmarks_ad AFTER DELETE ON bookmarks BEGIN\
    \ INSERT INTO bookmarks_fts(bookmarks_fts, rowid, title, description, url, note_body, extracted_text)\
    \ VALUES('delete', old.id, old.title, old.description, old.url, old.note_body, old.extracted_text);\
    \ END"
  , "CREATE TRIGGER IF NOT EXISTS bookmarks_au AFTER UPDATE ON bookmarks\
    \ WHEN old.title IS NOT new.title OR old.description IS NOT new.description\
    \ OR old.url IS NOT new.url OR old.note_body IS NOT new.note_body\
    \ OR old.extracted_text IS NOT new.extracted_text\
    \ BEGIN\
    \ INSERT INTO bookmarks_fts(bookmarks_fts, rowid, title, description, url, note_body, extracted_text)\
    \ VALUES('delete', old.id, old.title, old.description, old.url, old.note_body, old.extracted_text);\
    \ INSERT INTO bookmarks_fts(rowid, title, description, url, note_body, extracted_text)\
    \ VALUES (new.id, new.title, new.description, new.url, new.note_body, new.extracted_text);\
    \ END"
  , "INSERT INTO bookmarks_fts(bookmarks_fts) VALUES('rebuild')"
  ]
