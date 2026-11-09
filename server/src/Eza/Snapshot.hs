{-# LANGUAGE OverloadedStrings #-}

-- | Single-file page snapshots through the configured monolith binary.
module Eza.Snapshot (
    captureSnapshot,
) where

import Control.Exception (SomeException, try)
import Control.Monad (void, when)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import System.Directory (createDirectoryIfMissing, doesFileExist, getFileSize, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

import Eza.Config (Config (..))

{- | Capture a single-file snapshot with the configured monolith binary into
the given per-user snapshots directory (M3b: snapshots live at
@users/<id>/snapshots@ so two libraries' bookmark ids cannot collide).
The subprocess runs outside any write transaction.  On failure nothing is
recorded: a bookmark without a real local file has no snapshot, and the
caller reports it rather than storing a placeholder URL.
-}
captureSnapshot :: Config -> FilePath -> Connection -> Int -> IO (Maybe (Text, Text))
captureSnapshot cfg snapshotDirectory conn bid = do
    rows <- query conn "SELECT url FROM bookmarks WHERE id = ?" (Only bid) :: IO [Only Text]
    case rows of
        [] -> pure Nothing
        (Only url : _) -> do
            createDirectoryIfMissing True snapshotDirectory
            let path = snapshotDirectory </> show bid <> ".html"
            result <-
                try (timeout (30 * 1000000) (readProcessWithExitCode (cfgMonolith cfg) ["-o", path, T.unpack url] "")) ::
                    IO (Either SomeException (Maybe (ExitCode, String, String)))
            ok <- case result of
                Right (Just (ExitSuccess, _, _)) -> fileHasContent path
                _ -> pure False
            if ok
                then do
                    store conn bid (T.pack path) "file"
                    pure (Just ("file", T.pack path))
                else do
                    discardPartialFile path
                    pure Nothing

fileHasContent :: FilePath -> IO Bool
fileHasContent path = do
    exists <- doesFileExist path
    if not exists
        then pure False
        else do
            size <- getFileSize path
            pure (size > 0)

{- | Remove a zero-byte file left by a failed monolith run.  A previous
successful snapshot is never deleted.
-}
discardPartialFile :: FilePath -> IO ()
discardPartialFile path = do
    exists <- doesFileExist path
    when exists $ do
        size <- getFileSize path
        when (size == 0) $
            void (try (removeFile path) :: IO (Either SomeException ()))

store :: Connection -> Int -> Text -> Text -> IO ()
store conn bid value kind =
    withImmediateTransaction conn $
        execute
            conn
            "UPDATE bookmarks SET snapshot_path = ?, snapshot_kind = ?, snapshot_captured_at = strftime('%s','now'), updated_at = strftime('%s','now') WHERE id = ?"
            (value, kind, bid)
