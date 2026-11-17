{-# LANGUAGE OverloadedStrings #-}

-- | Single-file page snapshots through the configured monolith binary.
module Eza.Snapshot (
    SnapshotOutcome (..),
    captureSnapshot,
) where

import Control.Concurrent.Async (AsyncCancelled)
import Control.Exception (AsyncException, SomeException, fromException, tryJust)
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

{- | The result of one capture attempt.

'SnapshotRefused' is a deterministic refusal: the bookmark no longer exists, the
URL is not allowed by the public-address policy, or the output is larger than
the configured cap. Retrying cannot succeed, so the egress worker marks the job
failed immediately.

'SnapshotUnavailable' is a transient failure: the tool could not be spawned or
timed out, it exited non-zero, or it produced no usable file. The egress worker
retries those with the bounded backoff.
-}
data SnapshotOutcome
    = -- | Snapshot kind and file name.
      SnapshotCaptured Text Text
    | SnapshotRefused Text
    | SnapshotUnavailable Text
    deriving (Show, Eq)

{- | Capture a single-file snapshot with the configured monolith binary into
the given per-user snapshots directory (M3b: snapshots live at
@users/<id>/snapshots@ so two libraries' bookmark ids cannot collide).
The subprocess runs outside any write transaction. On failure nothing is
recorded: a bookmark without a real local file has no snapshot, and the caller
reports it rather than storing a placeholder URL.

The bookmark URL is checked against the same public-address policy as every
other egress path before the tool is spawned: a private, loopback, or
non-http(s) source is refused (unless @EZA_ALLOW_PRIVATE_FETCH@ opts in), so
snapshot capture cannot be used to reach the host or the local network. The
output is captured to a temporary name and only published when it is non-empty
and at most 'cfgSnapshotMaxBytes'; a failed or oversized run therefore never
replaces a previous good snapshot.

The outcome distinguishes refusals (permanent) from transient tool failures so
the egress worker can retry the latter.
-}
captureSnapshot :: Config -> FilePath -> Connection -> Int -> IO SnapshotOutcome
captureSnapshot cfg snapshotDirectory conn bid = do
    rows <- query conn "SELECT url FROM bookmarks WHERE id = ?" (Only bid) :: IO [Only Text]
    case rows of
        [] -> pure (SnapshotRefused "the bookmark no longer exists")
        (Only url : _) -> do
            allowed <- snapshotSourceAllowed cfg url
            if not allowed
                then pure (SnapshotRefused "the bookmark URL is not allowed for snapshot capture (http(s) and a public address are required unless EZA_ALLOW_PRIVATE_FETCH is set)")
                else do
                    outcome <- capture url
                    case outcome of
                        SnapshotCaptured _ _ -> pure outcome
                        _ -> discardPartialFile >> pure outcome
  where
    targetName = show bid <> ".html"
    targetPath = snapshotDirectory </> targetName
    -- Monolith selects its output format from the file name, so the temporary
    -- file keeps the final @.html@ suffix.
    partialPath = snapshotDirectory </> ("." <> show bid <> ".html.partial.html")

    capture sourceUrl = do
        createDirectoryIfMissing True snapshotDirectory
        result <-
            tryNonAsync (timeout (30 * 1000000) (readProcessWithExitCode (cfgMonolith cfg) ["-o", partialPath, T.unpack sourceUrl] "")) ::
                IO (Either SomeException (Maybe (ExitCode, String, String)))
        case result of
            Left err ->
                pure (SnapshotUnavailable ("the snapshot tool could not run: " <> T.pack (show err)))
            Right Nothing ->
                pure (SnapshotUnavailable "snapshot capture timed out")
            Right (Just (ExitFailure code, _, _)) ->
                pure (SnapshotUnavailable ("the snapshot tool exited with status " <> T.pack (show code)))
            Right (Just (ExitSuccess, _, _)) -> do
                produced <- producedSize partialPath
                case produced of
                    Nothing -> pure (SnapshotUnavailable "the snapshot tool produced no output file")
                    Just 0 -> pure (SnapshotUnavailable "the snapshot tool produced an empty output file")
                    Just size
                        | size > fromIntegral (cfgSnapshotMaxBytes cfg) ->
                            pure (SnapshotRefused ("the snapshot exceeded EZA_SNAPSHOT_MAX_BYTES (" <> T.pack (show size) <> " bytes)"))
                        | otherwise -> publish
              where
                publish = do
                    renamed <- tryNonAsync (renameFile partialPath targetPath) :: IO (Either SomeException ())
                    case renamed of
                        Left err -> pure (SnapshotUnavailable ("the captured snapshot could not be published: " <> T.pack (show err)))
                        Right () -> do
                            store conn bid (T.pack targetPath) "file"
                            -- Only the basename is reported: the absolute path is
                            -- an internal detail and the client ignores the value.
                            pure (SnapshotCaptured "file" (T.pack targetName))

    producedSize path = do
        exists <- doesFileExist path
        if not exists
            then pure Nothing
            else Just <$> getFileSize path

    discardPartialFile = do
        exists <- doesFileExist partialPath
        when exists $ void (tryNonAsync (removeFile partialPath) :: IO (Either SomeException ()))

{- | Run an action and catch synchronous failures only: asynchronous exceptions
(worker cancellation) are rethrown so cancelling a snapshot worker stops it
instead of being recorded as a failed capture. @AsyncCancelled@ is not an
@AsyncException@ subtype, so both are checked.
-}
tryNonAsync :: IO a -> IO (Either SomeException a)
tryNonAsync action = tryJust isSyncFailure action
  where
    isSyncFailure err
        | isAsync err = Nothing
        | otherwise = Just err
    isAsync err = case fromException err :: Maybe AsyncException of
        Just _ -> True
        Nothing -> case fromException err :: Maybe AsyncCancelled of
            Just _ -> True
            Nothing -> False

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
