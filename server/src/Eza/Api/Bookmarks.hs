-- | Bookmark, highlight, share-link, clip quick-save, favicon, and inbox handlers.
module Eza.Api.Bookmarks where

import Control.Exception (SomeException, try)

import Data.Aeson

import qualified Data.ByteString.Lazy as LBS

import Data.List (isPrefixOf)

import Data.Maybe (catMaybes, fromMaybe)

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Database.SQLite.Simple (Connection, Only (..), query)

import Network.HTTP.Types
import Network.Wai

import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist)

import Eza.Assets (assetPath)
import Eza.Version (ezaVersionText)

import Eza.Bookmarks
import Eza.Boot (BootPayload (..), wireVersion)

import Eza.Config

import qualified Eza.Control as Control

import Eza.Enrich (enqueueEnrichment)
import Eza.Jobs (enqueueTrackedJob)

import Eza.Favicon (Favicon (..), getFavicon)

import Eza.Highlights (createHighlight, deleteHighlight, listHighlights, updateHighlight)

import Eza.Routes (Route (..))

import Eza.SavedSearches (listSavedSearches)
import Eza.Shares (createShare, listShares, revokeShare)

import Eza.Types
import Eza.Views (listViews)

import Eza.Api.Common
import Eza.Api.Context
import System.FilePath (addTrailingPathSeparator)

{- | Everything one boot request reads. Exported so the server tests can check
the boot document without starting Warp.
-}
bootPayloadFor :: Text -> Connection -> IO BootPayload
bootPayloadFor origin conn = do
    page <- listBookmarks conn defaultListQuery
    tags <- allTags conn
    stats <- libraryStats conn
    searches <- listSavedSearches conn
    views <- listViews conn
    pure
        BootPayload
            { bpWireVersion = wireVersion
            , bpVersion = ezaVersionText
            , bpOrigin = origin
            , bpTags = tags
            , bpSavedSearches = searches
            , bpInitial = page
            , bpStats = stats
            , bpViews = views
            }

faviconHandler :: Text -> Connection -> Request -> Text -> (Response -> IO ResponseReceived) -> IO ResponseReceived
faviconHandler fallbackUrl conn req domain respond = do
    cached <- getFavicon conn domain
    case cached of
        Nothing -> respond (redirectTo fallbackUrl)
        Just favicon -> do
            let etag = TE.encodeUtf8 (fvEtag favicon)
            case lookup hIfNoneMatch (requestHeaders req) of
                Just raw
                    | raw == etag ->
                        respond
                            ( responseLBS
                                status304
                                [ (hContentType, TE.encodeUtf8 (fvMime favicon))
                                , (hETag, etag)
                                , (hCacheControl, "private, max-age=604800, immutable")
                                , ("Vary", "Cookie")
                                ]
                                ""
                            )
                _ ->
                    respond
                        ( responseLBS
                            status200
                            [ (hContentType, TE.encodeUtf8 (fvMime favicon))
                            , (hETag, etag)
                            , (hCacheControl, "private, max-age=604800, immutable")
                            , ("Vary", "Cookie")
                            ]
                            (LBS.fromStrict (fvBytes favicon))
                        )

data AddBody = AddBody Text (Maybe Text) (Maybe [Text])

instance FromJSON AddBody where
    parseJSON = withObject "AddBody" $ \o ->
        AddBody <$> o .: "url" <*> o .:? "title" <*> o .:? "tags"

addBookmark :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
addBookmark cfg conn req respond = do
    body <- jsonValue cfg req
    case body of
        Left response -> respond response
        Right (AddBody url title tags) ->
            if not (isHttpUrl url)
                then respond (jsonProblem status400 "bad_request" "url must be http(s)")
                else do
                    result <- insertBookmark conn url (fromMaybe "" title) (fromMaybe [] tags)
                    case result of
                        Left msg -> respond (jsonProblem status409 "conflict" msg)
                        Right bid -> do
                            enqueueEnrichment conn bid
                            respond (jsonResponse status201 (object ["id" .= bid]))

data HighlightCreateBody = HighlightCreateBody Text (Maybe Text) (Maybe Text) Int Int (Maybe Text) (Maybe Text)

instance FromJSON HighlightCreateBody where
    parseJSON = withObject "HighlightCreateBody" $ \o ->
        HighlightCreateBody
            <$> o .: "quote"
            <*> o .:? "prefix"
            <*> o .:? "suffix"
            <*> o .: "start_offset"
            <*> o .: "end_offset"
            <*> o .:? "note"
            <*> o .:? "color"

highlightCreateHandler :: Config -> Connection -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
highlightCreateHandler cfg conn bid req respond = do
    body <- jsonValue cfg req
    case body of
        Left response -> respond response
        Right (HighlightCreateBody quote prefix suffix start end note color) -> do
            result <- createHighlight conn bid quote (fromMaybe "" prefix) (fromMaybe "" suffix) start end (fromMaybe "" note) (fromMaybe "yellow" color)
            case result of
                Left err -> respond (jsonProblem status400 "bad_request" err)
                Right highlight -> respond (jsonResponse status201 highlight)

data HighlightPatchBody = HighlightPatchBody (Maybe Text) (Maybe Text)

instance FromJSON HighlightPatchBody where
    parseJSON = withObject "HighlightPatchBody" $ \o ->
        HighlightPatchBody <$> o .:? "note" <*> o .:? "color"

highlightUpdateHandler :: Config -> Connection -> Int -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
highlightUpdateHandler cfg conn bid hid req respond = do
    body <- jsonValue cfg req
    case body of
        Left response -> respond response
        Right (HighlightPatchBody note color) -> do
            ok <- updateHighlight conn bid hid note color
            if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonProblem status404 "not_found" "highlight not found")

data ShareCreateBody = ShareCreateBody Text Int (Maybe Bool) (Maybe Int)

instance FromJSON ShareCreateBody where
    parseJSON = withObject "ShareCreateBody" $ \o ->
        ShareCreateBody <$> o .: "scope" <*> o .: "target_id" <*> o .:? "include_note" <*> o .:? "expires_in_days"

shareCreateHandler :: Config -> Control.ControlUser -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
shareCreateHandler cfg user conn req respond = do
    body <- jsonValue cfg req
    case body of
        Left response -> respond response
        Right (ShareCreateBody scope targetId includeNote expires) -> do
            let days = fromMaybe (cfgShareTtlDays cfg) expires
            result <- createShare conn scope targetId (fromMaybe False includeNote) days
            case result of
                Left err -> respond (jsonProblem status400 "bad_request" err)
                Right (shareId, raw) ->
                    respond (jsonResponse status201 (object ["id" .= shareId, "url" .= (cfgPublicOrigin cfg <> "/s/" <> wireShareToken user raw)]))

{- | Serve a locally captured snapshot. The path must be inside the account's
own snapshots directory; the old global @EZA_SNAPSHOT_DIR@ is accepted as a
second root so snapshots made before the per-user layout keep working.
-}
snapshotHandler :: Config -> UserSlot -> Connection -> Int -> (Response -> IO ResponseReceived) -> IO ResponseReceived
snapshotHandler cfg slot conn bid respond = do
    bookmark <- getBookmark conn bid
    case bookmark of
        Just detail
            | bdSnapshotKind detail /= "file" || T.null (bdSnapshotPath detail) ->
                respond (jsonProblem status404 "not_found" "no local snapshot for this bookmark")
            | otherwise -> do
                let rawPath = T.unpack (bdSnapshotPath detail)
                resolvedResult <- try (canonicalizePath rawPath) :: IO (Either SomeException FilePath)
                roots <- mapM canonicalRoot [usSnapshotDir slot, cfgSnapshotDir cfg]
                let resolved = either (const rawPath) id resolvedResult
                exists <- doesFileExist resolved
                if exists && any (isUnder resolved) (catMaybes roots)
                    then
                        respond
                            ( responseFile
                                status200
                                [ (hContentType, "text/html; charset=utf-8")
                                , ("Content-Security-Policy", "sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data: https:")
                                , ("X-Content-Type-Options", "nosniff")
                                ]
                                resolved
                                Nothing
                            )
                    else respond (jsonProblem status404 "not_found" "snapshot file not found")
        Nothing -> respond (jsonProblem status404 "not_found" "bookmark not found")
  where
    canonicalRoot root = do
        exists <- doesDirectoryExist root
        if not exists
            then pure Nothing
            else do
                result <- try (canonicalizePath root) :: IO (Either SomeException FilePath)
                pure (either (const Nothing) Just result)
    isUnder path root = path == root || (addTrailingPathSeparator root) `isPrefixOf` path

data BulkBody = BulkBody Text [Int] (Maybe [Text]) (Maybe Bool)

instance FromJSON BulkBody where
    parseJSON = withObject "BulkBody" $ \o ->
        BulkBody <$> o .: "action" <*> o .:? "ids" .!= [] <*> o .:? "tags" <*> o .:? "confirm"

bulkHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
bulkHandler cfg conn req respond = do
    body <- jsonValue cfg req
    case body of
        Left response -> respond response
        Right (BulkBody action ids tags confirm) -> do
            let parsed = case action of
                    "add_tags" -> Right (BulkAddTags (fromMaybe [] tags))
                    "remove_tags" -> Right (BulkRemoveTags (fromMaybe [] tags))
                    "mark_read" -> Right (BulkMarkRead True)
                    "mark_unread" -> Right (BulkMarkRead False)
                    "delete" | confirm == Just True -> Right BulkDelete
                    "delete" -> Left "delete requires confirm: true"
                    _ -> Left "unknown bulk action"
            case parsed of
                Left err -> respond (jsonProblem status400 "bad_request" err)
                Right bulkAction -> do
                    result <- bulkUpdate conn bulkAction ids
                    case result of
                        Left err -> respond (jsonProblem status400 "bad_request" err)
                        Right (updated, snapshotId) ->
                            respond (jsonResponse status200 (object ["updated" .= updated, "snapshot_id" .= snapshotId]))

data QuickBody = QuickBody Text (Maybe Text) (Maybe [Text])

instance FromJSON QuickBody where
    parseJSON = withObject "QuickBody" $ \o ->
        QuickBody <$> o .: "url" <*> o .:? "title" <*> o .:? "tags"

quickSaveHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
quickSaveHandler cfg conn req respond = do
    body <- jsonValue cfg req
    case body of
        Left response -> respond response
        Right (QuickBody url title tags)
            | not (isHttpUrl url) -> respond (jsonProblem status400 "bad_request" "url must be http(s)")
            | otherwise -> do
                result <- quickSave conn url (fromMaybe "" title) (fromMaybe [] tags)
                case result of
                    Left message -> respond (jsonProblem status409 "conflict" message)
                    Right (bid, existing) -> do
                        if existing
                            then pure ()
                            else enqueueEnrichment conn bid
                        respond (jsonResponse (if existing then status200 else status201) (object ["id" .= bid, "existing" .= existing]))

data MarkAboveBody = MarkAboveBody (Maybe Int)

instance FromJSON MarkAboveBody where
    parseJSON = withObject "MarkAboveBody" $ \o -> MarkAboveBody <$> o .:? "above_id"

markAbove :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
markAbove cfg conn req respond = do
    body <- jsonValue cfg req
    case body of
        Left response -> respond response
        Right (MarkAboveBody aid) -> do
            n <- markAllAbove conn aid
            respond (jsonResponse status200 (object ["updated" .= n]))

data PatchBody = PatchBody (Maybe Text) (Maybe Text) (Maybe Bool) (Maybe [Text]) (Maybe Text)

instance FromJSON PatchBody where
    parseJSON = withObject "PatchBody" $ \o ->
        PatchBody <$> o .:? "title" <*> o .:? "note_body" <*> o .:? "is_read" <*> o .:? "tags" <*> o .:? "extracted_text"

patchBookmark :: Config -> Connection -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
patchBookmark cfg conn bid req respond = do
    body <- jsonValue cfg req
    case body of
        Left response -> respond response
        Right (PatchBody mTitle mNote mRead mTags mExtracted)
            | maybe False (T.null . T.strip) mTitle -> respond (jsonProblem status400 "bad_request" "title must not be empty")
            | maybe False ((> 2000000) . T.length) mExtracted -> respond (jsonProblem status400 "bad_request" "extracted text is too long")
            | all (== Nothing) [fmap (const ()) mTitle, fmap (const ()) mNote, fmap (const ()) mRead, fmap (const ()) mTags, fmap (const ()) mExtracted] ->
                respond (jsonProblem status400 "bad_request" "empty patch")
            | otherwise -> do
                (ok, removedHighlights) <- updateBookmarkDetailed conn bid mTitle mNote mRead mTags mExtracted
                if ok
                    then respond (jsonResponse status200 (object ["ok" .= True, "highlights_removed" .= removedHighlights]))
                    else respond (jsonProblem status404 "not_found" "bookmark not found")

{- | The six bookmark actions share one body; the route constructor picks the
action literal, so the guard/dispatch answers each endpoint directly.
-}
bookmarkAction ::
    Config ->
    UserSlot ->
    Connection ->
    (Response -> IO ResponseReceived) ->
    Int ->
    Text ->
    IO ResponseReceived
bookmarkAction _cfg _slot conn respond bookmarkId action = do
    exists <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only bookmarkId) :: IO [Only Int]
    if null exists
        then respond (jsonProblem status404 "not_found" "bookmark not found")
        else case action of
            "open" -> recordOpen conn bookmarkId >> respond (jsonResponse status200 (object ["ok" .= True]))
            "enrich" -> do
                enqueueEnrichment conn bookmarkId
                respond (jsonResponse status200 (object ["ok" .= True, "queued" .= True]))
            "extract" -> do
                enqueueEnrichment conn bookmarkId
                respond (jsonResponse status200 (object ["ok" .= True, "queued" .= True]))
            "mark-alive" -> do
                ok <- markLinkAlive conn bookmarkId
                if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonProblem status404 "not_found" "bookmark not found")
            "recheck-link" -> do
                ok <- recheckLink conn bookmarkId
                if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonProblem status404 "not_found" "bookmark not found")
            _ -> respond (jsonProblem status404 "not_found" "No such action")

{- | @POST /api/v1/bookmarks/{id}/snapshot@ validates and enqueues the capture;
the egress worker runs monolith outside the request.
-}
snapshotJobHandler :: Connection -> Int -> (Response -> IO ResponseReceived) -> IO ResponseReceived
snapshotJobHandler conn bookmarkId respond = do
    exists <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only bookmarkId) :: IO [Only Int]
    if null exists
        then respond (jsonProblem status404 "not_found" "bookmark not found")
        else do
            jobId <-
                enqueueTrackedJob
                    conn
                    "snapshot"
                    ("bookmark:" <> T.pack (show bookmarkId))
                    (object ["bookmark_id" .= bookmarkId])
            respond (jsonResponse status202 (object ["job_id" .= jobId]))

-- | Dispatch the handlers this family owns from their "Eza.Routes" constructors.
dispatch :: RequestContext -> Connection -> Route -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
dispatch rctx conn route req respond = case route of
    RouteBoot -> do
        payload <- bootPayloadFor (cfgPublicOrigin cfg) conn
        respond (jsonResponse status200 payload)
    RouteBookmarkList -> do
        page <- listBookmarks conn (listQueryFrom req)
        respond (jsonResponse status200 page)
    RouteBookmarkCreate -> addBookmark cfg conn req respond
    RouteBookmarkBulk -> bulkHandler cfg conn req respond
    RouteBookmarkRead bookmarkId -> do
        m <- getBookmark conn bookmarkId
        case m of
            Nothing -> respond (jsonProblem status404 "not_found" "bookmark not found")
            Just b -> respond (jsonResponse status200 b)
    RouteBookmarkDelete bookmarkId -> do
        ok <- deleteBookmark conn bookmarkId
        if ok then respond (emptyResponse status204) else respond (jsonProblem status404 "not_found" "bookmark not found")
    RouteFaviconRead domain ->
        faviconHandler (assetPath (asAssets state) "favicon-fallback.svg") conn req domain respond
    RouteQuickSave ->
        quickSaveHandler cfg conn req respond
    RouteHighlightList bookmarkId -> do
        highlights <- listHighlights conn bookmarkId
        respond (jsonResponse status200 (object ["highlights" .= highlights]))
    RouteHighlightCreate bookmarkId -> highlightCreateHandler cfg conn bookmarkId req respond
    RouteHighlightUpdate bookmarkId highlightId ->
        case (readInt (T.pack (show bookmarkId)), readInt (T.pack (show highlightId))) of
            (Just bid, Just hid) -> highlightUpdateHandler cfg conn bid hid req respond
            _ -> respond (jsonProblem status400 "bad_request" "invalid highlight id")
    RouteHighlightDelete bookmarkId highlightId ->
        case (readInt (T.pack (show bookmarkId)), readInt (T.pack (show highlightId))) of
            (Just bid, Just hid) -> do
                ok <- deleteHighlight conn bid hid
                if ok then respond (emptyResponse status204) else respond (jsonProblem status404 "not_found" "highlight not found")
            _ -> respond (jsonProblem status400 "bad_request" "invalid highlight id")
    RouteShareLinkList -> do
        shares <- listShares conn
        respond (jsonResponse status200 (object ["shares" .= shares]))
    RouteShareLinkCreate -> shareCreateHandler cfg user conn req respond
    RouteShareLinkRevoke shareId -> do
        ok <- revokeShare conn shareId
        if ok then respond (emptyResponse status204) else respond (jsonProblem status404 "not_found" "share not found")
    RouteBookmarkSnapshotRead bookmarkId -> snapshotHandler cfg slot conn bookmarkId respond
    RouteInboxMarkAbove -> markAbove cfg conn req respond
    RouteBookmarkUpdate bookmarkId -> patchBookmark cfg conn bookmarkId req respond
    RouteBookmarkOpen bookmarkId -> bookmarkAction cfg slot conn respond bookmarkId "open"
    RouteBookmarkEnrich bookmarkId -> bookmarkAction cfg slot conn respond bookmarkId "enrich"
    RouteBookmarkExtract bookmarkId -> bookmarkAction cfg slot conn respond bookmarkId "extract"
    RouteBookmarkMarkAlive bookmarkId -> bookmarkAction cfg slot conn respond bookmarkId "mark-alive"
    RouteBookmarkRecheckLink bookmarkId -> bookmarkAction cfg slot conn respond bookmarkId "recheck-link"
    RouteBookmarkSnapshotWrite bookmarkId -> snapshotJobHandler conn bookmarkId respond
    RouteBookmarkBacklinks bookmarkId -> do
        bl <- getBacklinks conn bookmarkId
        respond (jsonResponse status200 bl)
    RouteAutocomplete -> do
        let q = fromMaybe "" (param "q" req)
        items <- autocomplete conn q 10
        respond (jsonResponse status200 (object ["items" .= items]))
    _ -> respond (jsonProblem status500 "internal_error" "route has no handler")
  where
    cfg = rcConfig rctx
    state = rcState rctx
    user = rcUser rctx
    slot = rcSlot rctx

-- | The "Eza.Routes" constructors this family handles.
owns :: Route -> Bool
owns route = case route of
    RouteBoot -> True
    RouteBookmarkList -> True
    RouteBookmarkCreate -> True
    RouteBookmarkBulk -> True
    RouteBookmarkRead _ -> True
    RouteBookmarkDelete _ -> True
    RouteFaviconRead _ -> True
    RouteQuickSave -> True
    RouteHighlightList _ -> True
    RouteHighlightCreate _ -> True
    RouteHighlightUpdate _ _ -> True
    RouteHighlightDelete _ _ -> True
    RouteShareLinkList -> True
    RouteShareLinkCreate -> True
    RouteShareLinkRevoke _ -> True
    RouteBookmarkSnapshotRead _ -> True
    RouteInboxMarkAbove -> True
    RouteBookmarkUpdate _ -> True
    RouteBookmarkOpen _ -> True
    RouteBookmarkEnrich _ -> True
    RouteBookmarkExtract _ -> True
    RouteBookmarkMarkAlive _ -> True
    RouteBookmarkRecheckLink _ -> True
    RouteBookmarkSnapshotWrite _ -> True
    RouteBookmarkBacklinks _ -> True
    RouteAutocomplete -> True
    _ -> False
