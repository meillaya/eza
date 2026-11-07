{-# LANGUAGE OverloadedStrings #-}
module Eza.Snapshot
  ( captureSnapshot
  ) where

import Control.Exception (SomeException, try)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import System.Directory (createDirectoryIfMissing, doesFileExist, getFileSize)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

import Eza.Config (Config (..))

data SnapshotKind = SnapshotFile | SnapshotWayback
  deriving (Show, Eq)

-- | Capture a single-file snapshot with the configured monolith binary.
-- The subprocess runs outside any write transaction.  On failure the Wayback
-- availability URL is recorded instead, matching the old behaviour.
captureSnapshot :: Config -> Connection -> Int -> IO (Maybe (Text, Text))
captureSnapshot cfg conn bid = do
  rows <- query conn "SELECT url FROM bookmarks WHERE id = ?" (Only bid) :: IO [Only Text]
  case rows of
    [] -> pure Nothing
    (Only url : _) -> do
      createDirectoryIfMissing True (cfgSnapshotDir cfg)
      let path = cfgSnapshotDir cfg </> show bid <> ".html"
      result <- try (timeout (30 * 1000000) (readProcessWithExitCode (cfgMonolith cfg) ["-o", path, T.unpack url] "")) :: IO (Either SomeException (Maybe (ExitCode, String, String)))
      ok <- case result of
        Right (Just (ExitSuccess, _, _)) -> do
          exists <- doesFileExist path
          size <- if exists then getFileSize path else pure 0
          pure (exists && size > 0)
        _ -> pure False
      if ok
        then do
          store conn bid (T.pack path) "file"
          pure (Just ("file", T.pack path))
        else do
          let wayback = "https://web.archive.org/web/2/" <> url
          store conn bid wayback "wayback"
          pure (Just ("wayback", wayback))

store :: Connection -> Int -> Text -> Text -> IO ()
store conn bid value kind =
  withImmediateTransaction conn $
    execute
      conn
      "UPDATE bookmarks SET snapshot_path = ?, snapshot_kind = ?, snapshot_captured_at = strftime('%s','now'), updated_at = strftime('%s','now') WHERE id = ?"
      (value, kind, bid)
