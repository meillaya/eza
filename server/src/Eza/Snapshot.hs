{-# LANGUAGE OverloadedStrings #-}

-- | Single-file page snapshots through the configured monolith binary.
module Eza.Snapshot (
    captureSnapshot,
) where

import Control.Exception (SomeException, try)
import Control.Monad (void, when)
import Data.Char (toLower)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import Network.URI (URIAuth (..), parseURI, uriAuthority, uriScheme)
import System.Directory (createDirectoryIfMissing, doesFileExist, getFileSize, removeFile, renameFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

import Eza.Config (Config (..))
import Eza.Fetch (assertPublicHostPolicy)

{- | Capture a single-file snapshot with the configured monolith binary into
the given per-user snapshots directory (M3b: snapshots live at
@users/<id>/snapshots@ so two libraries' bookmark ids cannot collide).
The subprocess runs outside any write transaction.  On failure nothing is
recorded: a bookmark without a real local file has no snapshot, and the
caller reports it rather than storing a placeholder URL.

The bookmark URL is checked against the same public-address policy as every
other egress path before the tool is spawned: a private, loopback, or
non-http(s) source is refused (unless @EZA_ALLOW_PRIVATE_FETCH@ opts in), so
snapshot capture cannot be used to reach the host or the local network. The
output is captured to a temporary name and only published when it is non-empty
and at most 'cfgSnapshotMaxBytes'; a failed or oversized run therefore never
replaces a previous good snapshot.
-}
captureSnapshot :: Config -> FilePath -> Connection -> Int -> IO (Maybe (Text, Text))
captureSnapshot cfg snapshotDirectory conn bid = do
    rows <- query conn "SELECT url FROM bookmarks WHERE id = ?" (Only bid) :: IO [Only Text]
    case rows of
        [] -> pure Nothing
        (Only url : _) -> do
            allowed <- snapshotSourceAllowed cfg url
            if not allowed
                then pure Nothing
                else capture url
  where
    targetName = show bid <> ".html"
    targetPath = snapshotDirectory </> targetName
    -- Monolith selects its output format from the file name, so the temporary
    -- file keeps the final @.html@ suffix.
    partialPath = snapshotDirectory </> ("." <> show bid <> ".html.partial.html")

    capture sourceUrl = do
        createDirectoryIfMissing True snapshotDirectory
        result <-
            try (timeout (30 * 1000000) (readProcessWithExitCode (cfgMonolith cfg) ["-o", partialPath, T.unpack sourceUrl] "")) ::
                IO (Either SomeException (Maybe (ExitCode, String, String)))
        captured <- case result of
            Right (Just (ExitSuccess, _, _)) -> withinLimit partialPath
            _ -> pure False
        if captured
            then do
                renamed <- try (renameFile partialPath targetPath) :: IO (Either SomeException ())
                case renamed of
                    Left _ -> discardPartialFile >> pure Nothing
                    Right () -> do
                        store conn bid (T.pack targetPath) "file"
                        -- Only the basename is reported: the absolute path is an
                        -- internal detail and the client ignores the value.
                        pure (Just ("file", T.pack targetName))
            else do
                discardPartialFile
                pure Nothing

    withinLimit path = do
        exists <- doesFileExist path
        if not exists
            then pure False
            else do
                size <- getFileSize path
                pure (size > 0 && size <= fromIntegral (cfgSnapshotMaxBytes cfg))

    discardPartialFile = do
        exists <- doesFileExist partialPath
        when exists $ void (try (removeFile partialPath) :: IO (Either SomeException ()))

{- | Only an absolute http(s) URL whose host passes the public-address policy
may be fetched. The check happens before the tool is spawned.
-}
snapshotSourceAllowed :: Config -> Text -> IO Bool
snapshotSourceAllowed cfg rawUrl =
    case parseURI (T.unpack (T.strip rawUrl)) of
        Nothing -> pure False
        Just uri
            -- uriScheme keeps the trailing colon.
            | let scheme = map toLower (takeWhile (/= ':') (uriScheme uri)), scheme /= "http" && scheme /= "https" -> pure False
            | otherwise -> case uriAuthority uri of
                Nothing -> pure False
                Just authority -> do
                    result <- assertPublicHostPolicy (cfgAllowPrivateFetch cfg) (hostOfAuthority authority)
                    pure (either (const False) (const True) result)
  where
    hostOfAuthority authority =
        let rawHost = T.pack (uriRegName authority)
         in if T.isPrefixOf "[" rawHost && T.isSuffixOf "]" rawHost
                then T.drop 1 (T.dropEnd 1 rawHost)
                else rawHost

store :: Connection -> Int -> Text -> Text -> IO ()
store conn bid value kind =
    withImmediateTransaction conn $
        execute
            conn
            "UPDATE bookmarks SET snapshot_path = ?, snapshot_kind = ?, snapshot_captured_at = strftime('%s','now'), updated_at = strftime('%s','now') WHERE id = ?"
            (value, kind, bid)
