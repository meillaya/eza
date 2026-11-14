{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Background metadata, text, reading-time, and favicon enrichment.
module Eza.Enrich (
    enrichBookmark,
    enqueueEnrichment,
    runEnrichWorkerFor,
    runFaviconWorkerFor,
    backfillCachedFavicons,
    backfillFaviconStep,
    repairStoredFavicons,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.QSem (QSem, signalQSem, waitQSem)
import Control.Exception (SomeException, bracket, bracket_, try)
import Control.Monad (forM_, forever)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import Network.HTTP.Client (Manager)
import Network.URI (URIAuth (..), parseURI, parseURIReference, relativeTo, uriAuthority, uriRegName, uriScheme)
import System.IO (hPutStrLn, stderr)

import Eza.Config (Config (..))
import qualified Eza.Db as Db
import Eza.Extract (Extracted (..), extractHtml)
import Eza.Favicon
import Eza.Fetch
import Eza.Highlights (reanchorHighlights)
import Eza.Jobs
import Eza.Sidecar (sidecarExtract)

enqueueEnrichment :: Connection -> Int -> IO ()
enqueueEnrichment conn bookmarkId = do
    withImmediateTransaction conn $
        execute conn "UPDATE bookmarks SET enrich_state = 'queued', enrich_error = '' WHERE id = ?" (Only bookmarkId)
    enqueueJob conn "enrich" bookmarkId

enrichBookmark :: Manager -> Config -> Connection -> Int -> IO (Either Text ())
enrichBookmark manager cfg conn bookmarkId = do
    rows <- query conn "SELECT url, enrich_attempts, enrich_state FROM bookmarks WHERE id = ?" (Only bookmarkId) :: IO [(Text, Int, Text)]
    case rows of
        [] -> pure (Left "bookmark not found")
        ((url, attempts, state) : _)
            | state == "manual" -> pure (Right ())
            | otherwise -> do
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
                                -- Enrichment and a manual text edit may race. The
                                -- write transaction re-checks the state: if the
                                -- reader saved manual text while this fetch was in
                                -- flight, their text wins and no extraction fields
                                -- are overwritten.
                                withImmediateTransaction conn $ do
                                    states <- query conn "SELECT enrich_state FROM bookmarks WHERE id = ?" (Only bookmarkId) :: IO [Only Text]
                                    case states of
                                        (Only current : _)
                                            | current == "manual" -> pure ()
                                        _ -> do
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
                                            _ <- reanchorHighlights conn bookmarkId text
                                            execute
                                                conn
                                                "UPDATE bookmarks SET extracted_text = ?, final_url = ?, reading_time_minutes = ?, enrich_state = 'ok', enrich_error = '', enriched_at = strftime('%s','now'), updated_at = strftime('%s','now') WHERE id = ?"
                                                (text, finalUrl, reading, bookmarkId)
                                applyCachedFavicon conn (domainOfUrl finalUrl) bookmarkId
                                pure (Right ())

{- | Apply an icon that is already cached for the bookmark's domain. This is
the only icon work enrichment does; a missing domain is the backfill worker's
job, so one domain is never requested once per link.
-}
applyCachedFavicon :: Connection -> Text -> Int -> IO ()
applyCachedFavicon conn domain bookmarkId
    | T.null domain = pure ()
    | otherwise = do
        rows <- query conn "SELECT content_hash FROM favicons WHERE domain = ? AND fail_count = 0 AND length(bytes) > 1" (Only domain) :: IO [Only Text]
        case rows of
            (Only contentHash : _) ->
                withImmediateTransaction conn $
                    execute
                        conn
                        "UPDATE bookmarks SET favicon_url = ? WHERE id = ? AND (favicon_url = '' OR favicon_url NOT LIKE '/api/v1/favicons/%')"
                        (iconUrlFor domain contentHash, bookmarkId)
            [] -> pure ()

{- | Page fetch: a document, with a cap in the 2-5 MiB range and the standard
timeout and private-address guard.
-}
pageFetchOptions :: Manager -> Config -> FetchOptions
pageFetchOptions manager cfg = documentOptions manager (cfgFetchTimeoutMs cfg) pageMaxBytes (cfgAllowPrivateFetch cfg)

pageMaxBytes :: Int
pageMaxBytes = 4 * 1024 * 1024

{- | Decode a response body using the charset resolved by 'Eza.Fetch', falling
back to lenient UTF-8 and then Latin-1.
-}
decodeBody :: Maybe Text -> ByteString -> Text
decodeBody charset body =
    stripBom
        ( case fmap (T.toLower . T.strip) charset of
            Just name
                | name `elem` utf8Names -> TE.decodeUtf8With TEE.lenientDecode body
                | name `elem` latinNames -> TE.decodeLatin1 body
                | name `elem` utf16LeNames -> TE.decodeUtf16LEWith TEE.lenientDecode body
                | name `elem` utf16BeNames -> TE.decodeUtf16BEWith TEE.lenientDecode body
                | name == "utf-16" -> TE.decodeUtf16LEWith TEE.lenientDecode body
            _ -> case TE.decodeUtf8' body of
                Right text -> text
                Left _ -> TE.decodeLatin1 body
        )
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
                    let origin =
                            T.pack (dropTrailingColon (uriScheme uri))
                                <> "://"
                                <> T.pack (uriRegName auth)
                                <> T.pack (uriPort auth)
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
            "UPDATE bookmarks SET enrich_state = 'failed', enrich_error = ?, enrich_attempts = ?, updated_at = strftime('%s','now') WHERE id = ? AND enrich_state <> 'manual'"
            (message, attempts + 1, bookmarkId)

{- | One enrichment loop for one user database. The semaphore is process-wide,
so @EZA_ENRICH_WORKERS@ bounds the network work across every account while
each database still gets its own claimer.
-}
runEnrichWorkerFor :: Manager -> Config -> FilePath -> QSem -> IO ()
runEnrichWorkerFor manager cfg databasePath sem =
    -- The worker owns this connection for its whole life; cancellation (stop
    -- or a dead supervisor) runs the closing bracket instead of leaking it.
    bracket (Db.openDb databasePath) Db.closeDb $ \conn ->
        forever $ do
            claim <- claimJobKind conn "enrich"
            case claim of
                Nothing -> threadDelay (2 * 1000000)
                Just job
                    | jobKind job /= "enrich" -> do
                        completeJob conn (jobId job)
                    | otherwise ->
                        case jobBookmarkId job of
                            Nothing -> completeJob conn (jobId job)
                            Just bookmarkId -> do
                                result <-
                                    bracket_ (waitQSem sem) (signalQSem sem) $
                                        try (enrichBookmark manager cfg conn bookmarkId) ::
                                        IO (Either SomeException (Either Text ()))
                                case result of
                                    Left err -> failJob conn (jobId job) (T.pack (show err)) (jobAttempts job)
                                    Right (Left err) -> failJob conn (jobId job) err (jobAttempts job)
                                    Right (Right ()) -> completeJob conn (jobId job)

-- ---------------------------------------------------------------------------
-- Favicon backfill
-- ---------------------------------------------------------------------------

{- | Fill @bookmarks.favicon_url@ from an icon already cached for that domain.
One SQL update covers every bookmark on the domain, so a site with 500 links
costs one lookup and no network request. A stale hash or a remote/empty URL is
repaired too, not just the empty case. Returns 'True' when it changed rows.
-}
backfillCachedFavicons :: Connection -> IO Bool
backfillCachedFavicons conn = do
    rows <-
        query
            conn
            "SELECT f.domain, f.content_hash FROM favicons f WHERE f.fail_count = 0 AND length(f.bytes) > 1 AND EXISTS (SELECT 1 FROM bookmarks b WHERE b.domain = f.domain AND b.favicon_url <> ('/api/v1/favicons/' || f.domain || '?v=' || substr(f.content_hash,1,8))) ORDER BY f.domain LIMIT 1"
            () ::
            IO [(Text, Text)]
    case rows of
        [] -> pure False
        ((domain, contentHash) : _) -> do
            updateDomainFaviconUrls conn domain contentHash
            pure True

updateDomainFaviconUrls :: Connection -> Text -> Text -> IO ()
updateDomainFaviconUrls conn domain contentHash =
    withImmediateTransaction conn $
        execute
            conn
            "UPDATE bookmarks SET favicon_url = ? WHERE domain = ? AND favicon_url <> ?"
            (iconUrlFor domain contentHash, domain, iconUrlFor domain contentHash)

{- | One-time cache validation at worker start. ICOs are cropped to a complete
entry and rewritten; any other incomplete or unsupported body is deleted and
its bookmark rows are cleared so the normal backfill can refetch it. Stale hash
URLs for valid icons are repaired at the same time. This is the part that
repairs rows written before truncation was rejected; it is not a schema marker.
-}
repairStoredFavicons :: Connection -> IO ()
repairStoredFavicons conn = do
    rows <-
        query
            conn
            "SELECT domain, mime, bytes, source_url, content_hash FROM favicons WHERE fail_count = 0 AND length(bytes) > 1"
            () ::
            IO [(Text, Text, ByteString, Text, Text)]
    forM_ rows $ \(domain, mime, bytes, source, contentHash) ->
        case normalizeIcon bytes of
            Nothing -> do
                withImmediateTransaction conn $ do
                    execute conn "DELETE FROM favicons WHERE domain = ?" (Only domain)
                    execute conn "UPDATE bookmarks SET favicon_url = '' WHERE domain = ?" (Only domain)
            Just (mime', bytes')
                | mime' == mime && bytes' == bytes && not (T.null contentHash) -> pure ()
                | otherwise -> do
                    hashText <- putFavicon conn domain source mime' bytes'
                    updateDomainFaviconUrls conn domain hashText

{- | Fetch one missing domain icon and apply it to every bookmark on that
domain. The domain with the most unfilled bookmarks goes first, so the visible
rows improve early. Domains with no icon at the usual paths are parked after
three attempts. A cached icon with an expired TTL is refreshed after missing
domains have been served. Returns 'True' when this step did something.
-}
backfillFaviconStep :: Manager -> Config -> Connection -> IO Bool
backfillFaviconStep manager cfg conn = do
    cached <- backfillCachedFavicons conn
    if cached
        then pure True
        else do
            remote <- backfillRemoteFavicon manager cfg conn
            if remote
                then pure True
                else backfillExpiredFavicon manager cfg conn

backfillRemoteFavicon :: Manager -> Config -> Connection -> IO Bool
backfillRemoteFavicon manager cfg conn = do
    rows <-
        query
            conn
            "SELECT b.domain FROM bookmarks b LEFT JOIN favicons f ON f.domain = b.domain WHERE b.domain <> '' AND (b.favicon_url = '' OR b.favicon_url NOT LIKE '/api/v1/favicons/%') AND (f.domain IS NULL OR (f.fail_count < 3 AND f.last_error <> '')) GROUP BY b.domain ORDER BY COUNT(*) DESC, b.domain LIMIT 1"
            () ::
            IO [Only Text]
    case rows of
        [] -> pure False
        (Only domain : _) -> do
            sample <- query conn "SELECT url FROM bookmarks WHERE domain = ? LIMIT 1" (Only domain) :: IO [Only Text]
            case sample of
                [] -> pure True
                (Only sampleUrl : _) -> do
                    fetched <- fetchDomainIcon manager cfg sampleUrl
                    case fetched of
                        Nothing -> do
                            recordFaviconFailure conn domain "no icon at the usual paths"
                            pure True
                        Just (mime, bytes, source) -> do
                            hashText <- putFavicon conn domain source mime bytes
                            updateDomainFaviconUrls conn domain hashText
                            pure True

{- | Refresh one valid icon whose @fetched_at@ is older than the configured
TTL, after missing domains have been exhausted. A failed refresh advances the
timestamp instead of parking a good icon, so the retry does not spin.
-}
backfillExpiredFavicon :: Manager -> Config -> Connection -> IO Bool
backfillExpiredFavicon manager cfg conn = do
    now <- floor <$> getPOSIXTime
    let cutoff = now - max 1 (cfgFaviconTtlDays cfg) * 86400
    rows <-
        query
            conn
            "SELECT f.domain FROM favicons f WHERE f.fail_count = 0 AND length(f.bytes) > 1 AND f.fetched_at < ? AND EXISTS (SELECT 1 FROM bookmarks b WHERE b.domain = f.domain) ORDER BY f.fetched_at LIMIT 1"
            (Only cutoff) ::
            IO [Only Text]
    case rows of
        [] -> pure False
        (Only domain : _) -> do
            sample <- query conn "SELECT url FROM bookmarks WHERE domain = ? LIMIT 1" (Only domain) :: IO [Only Text]
            case sample of
                [] -> do
                    withImmediateTransaction conn $
                        execute conn "UPDATE favicons SET fetched_at = ? WHERE domain = ?" (now, domain)
                    pure True
                (Only sampleUrl : _) -> do
                    fetched <- fetchDomainIcon manager cfg sampleUrl
                    case fetched of
                        Nothing -> do
                            withImmediateTransaction conn $
                                execute conn "UPDATE favicons SET fetched_at = ? WHERE domain = ?" (now, domain)
                            pure True
                        Just (mime, bytes, source) -> do
                            hashText <- putFavicon conn domain source mime bytes
                            updateDomainFaviconUrls conn domain hashText
                            pure True

{- | Find one icon for a domain, cheapest path first. Conventional locations
cover most sites with zero page parsing; when they all miss, one homepage fetch
(and, if that fails, the sampled bookmark page) can still expose a declared
@<link rel="icon">@. Inline data:image links are parsed locally. This stays a
per-domain cost: the icon is then cached and applied to every bookmark on the
domain.
-}
fetchDomainIcon :: Manager -> Config -> Text -> IO (Maybe (Text, ByteString, Text))
fetchDomainIcon manager cfg sampleUrl = do
    conventional <- tryIcons (dedupe (concatMap fallbackCandidates (schemeVariants sampleUrl)))
    case conventional of
        Just icon -> pure (Just icon)
        Nothing -> fetchDeclared
  where
    options = iconFetchOptions manager cfg

    tryIcons [] = pure Nothing
    tryIcons (url : rest)
        | "data:image/" `T.isPrefixOf` T.toLower url =
            case parseDataIcon url of
                Just (_, raw)
                    | BS.length raw <= cfgFaviconMaxBytes cfg ->
                        case normalizeIcon raw of
                            Just (mime, bytes) -> pure (Just (mime, bytes, "data:image"))
                            Nothing -> tryIcons rest
                    | otherwise -> tryIcons rest
                Nothing -> tryIcons rest
        | otherwise = do
            result <- fetchUrl options url
            case result of
                Left _ -> tryIcons rest
                Right page ->
                    case normalizeIcon (fpBody page) of
                        Nothing -> tryIcons rest
                        Just (mime, bytes) -> pure (Just (mime, bytes, url))

    -- The homepage is the canonical place for a declared icon; the sampled
    -- bookmark URL is a fallback for sites whose root is a redirect or shell.
    fetchDeclared = go (dedupe [originOf sampleUrl, sampleUrl])
      where
        go [] = pure Nothing
        go (pageUrl : rest) = do
            pageResult <- fetchUrl (pageFetchOptions manager cfg) pageUrl
            case pageResult of
                Left _ -> go rest
                Right page -> do
                    let html = decodeBody (fpCharset page) (fpBody page)
                        finalUrl = if T.null (fpFinalUrl page) then pageUrl else fpFinalUrl page
                    declared <- tryIcons (take 6 (parseIconLinks html finalUrl))
                    case declared of
                        Just icon -> pure (Just icon)
                        Nothing -> go rest

    originOf url = case fallbackCandidates url of
        (candidate : _) -> T.dropEnd (T.length ("/favicon.ico" :: Text)) candidate
        [] -> url

    schemeVariants url
        | "https://" `T.isPrefixOf` url = [url, "http://" <> T.drop 8 url]
        | "http://" `T.isPrefixOf` url = [url, "https://" <> T.drop 7 url]
        | otherwise = [url]

{- | One favicon backfill loop for one account database. It serves cached icons
with no network first, then fetches at most one missing domain per iteration
(the shared enrichment semaphore bounds outbound work across accounts). A
domain that yields a fresh icon still costs a single fetch regardless of how
many bookmarks use it.
-}
runFaviconWorkerFor :: Manager -> Config -> FilePath -> QSem -> IO ()
runFaviconWorkerFor manager cfg databasePath sem =
    -- One connection for the loop, closed when the worker is cancelled.
    bracket (Db.openDb databasePath) Db.closeDb $ \conn -> do
        repaired <- try (repairStoredFavicons conn) :: IO (Either SomeException ())
        case repaired of
            Left err -> hPutStrLn stderr ("eza: favicon repair: " <> show err)
            Right () -> pure ()
        forever $ do
            outcome <-
                bracket_ (waitQSem sem) (signalQSem sem) $
                    try (backfillFaviconStep manager cfg conn) ::
                    IO (Either SomeException Bool)
            case outcome of
                Left err -> hPutStrLn stderr ("eza: favicon worker: " <> show err)
                Right _ -> pure ()
            threadDelay $
                case outcome of
                    Right True -> 250 * 1000
                    _ -> 2 * 1000 * 1000
