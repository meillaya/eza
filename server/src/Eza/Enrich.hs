{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Background metadata, text, reading-time, and favicon enrichment.
module Eza.Enrich
  ( enrichBookmark
  , enqueueEnrichment
  , runEnrichWorker
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (forever)
import Data.ByteString (ByteString)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Database.SQLite.Simple
import Network.HTTP.Client (Manager)
import Network.URI (URIAuth (..), parseURI, parseURIReference, relativeTo, uriAuthority, uriRegName, uriScheme)

import Eza.Config (Config (..))
import Eza.Extract (Extracted (..), extractHtml)
import Eza.Favicon
import Eza.Fetch
import Eza.Jobs
import Eza.Sidecar (sidecarExtract)
import qualified Eza.Db as Db

enqueueEnrichment :: Connection -> Int -> IO ()
enqueueEnrichment conn bookmarkId = do
  withImmediateTransaction conn $
    execute conn "UPDATE bookmarks SET enrich_state = 'queued', enrich_error = '' WHERE id = ?" (Only bookmarkId)
  enqueueJob conn "enrich" bookmarkId

enrichBookmark :: Manager -> Config -> Connection -> Int -> IO (Either Text ())
enrichBookmark manager cfg conn bookmarkId = do
  rows <- query conn "SELECT url, enrich_attempts FROM bookmarks WHERE id = ?" (Only bookmarkId) :: IO [(Text, Int)]
  case rows of
    [] -> pure (Left "bookmark not found")
    ((url, attempts) : _) -> do
      pageResult <- fetchUrl (pageFetchOptions manager cfg) url
      case pageResult of
        Left err -> do
          markFailed conn bookmarkId (T.pack (show err)) attempts
          pure (Left (T.pack (show err)))
        Right page -> do
          let html = decodeBody (fpCharset page) (fpBody page)
              finalUrl = if T.null (fpFinalUrl page) then url else fpFinalUrl page
          extracted <- case cfgSidecarCmd cfg of
            Just command -> do
              sidecar <- sidecarExtract (T.pack command) finalUrl html
              pure (either (const (extractHtml html)) id sidecar)
            Nothing -> pure (extractHtml html)
          let text = exText extracted
              wordCount = length (T.words text)
              reading = if wordCount == 0 then 0 else (wordCount + 219) `div` 220
              image = resolveAgainst finalUrl (exImage extracted)
          if T.null (T.strip text)
            then do
              markFailed conn bookmarkId "empty extraction" attempts
              pure (Left "empty extraction")
            else do
              favicon <- fetchIcon manager cfg html finalUrl
              -- Two statements inside one transaction: sqlite-simple only has
              -- ToRow instances up to 10-tuples, and the FTS triggers only fire
              -- for the columns that actually changed.
              withImmediateTransaction conn $ do
                execute
                  conn
                  "UPDATE bookmarks SET title = CASE WHEN trim(title) = '' THEN ? ELSE title END, description = CASE WHEN trim(description) = '' THEN ? ELSE description END, author = CASE WHEN trim(author) = '' THEN ? ELSE author END, sitename = CASE WHEN trim(sitename) = '' THEN ? ELSE sitename END, published_at = CASE WHEN published_at IS NULL THEN ? ELSE published_at END, language = CASE WHEN trim(language) = '' THEN ? ELSE language END, image_url = CASE WHEN trim(image_url) = '' THEN ? ELSE image_url END, enrich_attempts = enrich_attempts + 1, updated_at = strftime('%s','now') WHERE id = ?"
                  ( exTitle extracted
                  , exDescription extracted
                  , exAuthor extracted
                  , exSitename extracted
                  , exPublished extracted
                  , exLanguage extracted
                  , image
                  , bookmarkId
                  )
                execute
                  conn
                  "UPDATE bookmarks SET extracted_text = ?, final_url = ?, reading_time_minutes = ?, enrich_state = 'ok', enrich_error = '', enriched_at = strftime('%s','now'), updated_at = strftime('%s','now') WHERE id = ?"
                  (text, finalUrl, reading, bookmarkId)
              case favicon of
                Nothing -> pure ()
                Just (mime, bytes, source) -> do
                  hashText <- putFavicon conn (domainOfUrl finalUrl) source mime bytes
                  withImmediateTransaction conn $
                    execute conn "UPDATE bookmarks SET favicon_url = ? WHERE id = ?" (iconUrlFor (domainOfUrl finalUrl) hashText, bookmarkId)
              pure (Right ())

-- | Page fetch: a document, with a cap in the 2-5 MiB range and the standard
-- timeout and private-address guard.
pageFetchOptions :: Manager -> Config -> FetchOptions
pageFetchOptions manager cfg = documentOptions manager (cfgFetchTimeoutMs cfg) pageMaxBytes (cfgAllowPrivateFetch cfg)

pageMaxBytes :: Int
pageMaxBytes = 4 * 1024 * 1024

-- | Decode a response body using the charset resolved by 'Eza.Fetch', falling
-- back to lenient UTF-8 and then Latin-1.
decodeBody :: Maybe Text -> ByteString -> Text
decodeBody charset body = stripBom (case fmap (T.toLower . T.strip) charset of
  Just name
    | name `elem` utf8Names -> TE.decodeUtf8With TEE.lenientDecode body
    | name `elem` latinNames -> TE.decodeLatin1 body
    | name `elem` utf16LeNames -> TE.decodeUtf16LEWith TEE.lenientDecode body
    | name `elem` utf16BeNames -> TE.decodeUtf16BEWith TEE.lenientDecode body
    | name == "utf-16" -> TE.decodeUtf16LEWith TEE.lenientDecode body
  _ -> case TE.decodeUtf8' body of
    Right text -> text
    Left _ -> TE.decodeLatin1 body)
  where
    stripBom text = fromMaybe text (T.stripPrefix "\xFEFF" text)
    utf8Names = ["utf-8", "utf8", "unicode-1-1-utf-8"]
    latinNames = ["iso-8859-1", "latin1", "latin-1", "windows-1252", "cp1252", "us-ascii", "ascii"]
    utf16LeNames = ["utf-16le", "utf-16-le"]
    utf16BeNames = ["utf-16be", "utf-16-be"]

-- | Resolve a possibly-relative image URL against the final page URL.
resolveAgainst :: Text -> Text -> Text
resolveAgainst base value
  | T.null value = ""
  | otherwise =
      case parseURIReference (T.unpack value) of
        Just reference
          | uriScheme reference /= "" -> value
        _ -> case parseURI (T.unpack base) of
          Just baseUri -> case parseURIReference (T.unpack value) of
            Just reference -> T.pack (show (reference `relativeTo` baseUri))
            Nothing -> value
          Nothing -> value

fetchIcon :: Manager -> Config -> Text -> Text -> IO (Maybe (Text, ByteString, Text))
fetchIcon manager cfg html finalUrl = do
  let candidates = take 4 (parseIconLinks html finalUrl) <> fallbackCandidates finalUrl
  tryCandidates (dedupe candidates)
  where
    tryCandidates [] = pure Nothing
    tryCandidates (url : rest) = do
      result <- fetchUrl (iconFetchOptions manager cfg) url
      case result of
        Left _ -> tryCandidates rest
        Right page ->
          case sniffImage (fpBody page) of
            Nothing -> tryCandidates rest
            Just mime -> pure (Just (mime, fpBody page, url))

iconFetchOptions :: Manager -> Config -> FetchOptions
iconFetchOptions manager cfg = anyOptions manager (cfgFetchTimeoutMs cfg) (cfgFaviconMaxBytes cfg) (cfgAllowPrivateFetch cfg)

fallbackCandidates :: Text -> [Text]
fallbackCandidates url =
  case parseURI (T.unpack url) of
    Nothing -> []
    Just uri ->
      case uriAuthority uri of
        Nothing -> []
        Just auth ->
          let origin = T.pack (dropTrailingColon (uriScheme uri)) <> "://" <> T.pack (uriRegName auth)
           in [origin <> "/favicon.ico", origin <> "/favicon.png", origin <> "/apple-touch-icon.png"]
  where
    dropTrailingColon s = if not (null s) && last s == ':' then init s else s

dedupe :: [Text] -> [Text]
dedupe = foldr (\value seen -> if value `elem` seen then seen else value : seen) []

domainOfUrl :: Text -> Text
domainOfUrl url =
  case parseURI (T.unpack url) of
    Just uri -> maybe "" (T.pack . uriRegName) (uriAuthority uri)
    Nothing -> T.takeWhile (/= '/') (T.drop 8 url)

markFailed :: Connection -> Int -> Text -> Int -> IO ()
markFailed conn bookmarkId message attempts = do
  withImmediateTransaction conn $
    execute
      conn
      "UPDATE bookmarks SET enrich_state = 'failed', enrich_error = ?, enrich_attempts = ?, updated_at = strftime('%s','now') WHERE id = ?"
      (message, attempts + 1, bookmarkId)

runEnrichWorker :: Manager -> Config -> IO ()
runEnrichWorker manager cfg = do
  conn <- Db.openDb (cfgDbPath cfg)
  forever $ do
    claim <- claimJob conn
    case claim of
      Nothing -> threadDelay (2 * 1000000)
      Just job
        | jobKind job /= "enrich" -> do
            completeJob conn (jobId job)
        | otherwise ->
            case jobBookmarkId job of
              Nothing -> completeJob conn (jobId job)
              Just bookmarkId -> do
                result <- try (enrichBookmark manager cfg conn bookmarkId) :: IO (Either SomeException (Either Text ()))
                case result of
                  Left err -> failJob conn (jobId job) (T.pack (show err)) (jobAttempts job)
                  Right (Left err) -> failJob conn (jobId job) err (jobAttempts job)
                  Right (Right ()) -> completeJob conn (jobId job)
