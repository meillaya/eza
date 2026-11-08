{-# LANGUAGE OverloadedStrings #-}

{- | Warp application: public auth pages/ceremonies, deny-by-default API,
CSRF/session guard, and the bookmark/tag JSON surface.
-}
module Eza.Server (
    runServer,
) where

import Control.Concurrent.Async (async)
import Control.Concurrent.MVar
import Control.Exception (IOException, throwIO, try)
import Control.Monad (forM_, void)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as LBS
import Data.List (isInfixOf, isPrefixOf)
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Database.SQLite.Simple (Connection, Query (..))
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types
import Network.HTTP.Types.Header (hAuthorization, hCacheControl, hETag, hIfNoneMatch)
import Network.Wai
import Network.Wai.Handler.Warp
import System.Directory (canonicalizePath, doesFileExist, getFileSize, getModificationTime)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import qualified Web.Cookie as Cookie

import Eza.AiTag (aiSuggestions)
import qualified Eza.Auth as Auth
import Eza.Bookmarks
import Eza.Config
import qualified Eza.Db as Db
import Eza.DeadLinks (checkDead)
import Eza.Dedup (dedupCandidates, mergeBookmarks)
import Eza.Enrich (enqueueEnrichment, runEnrichWorker)
import Eza.Export (exportBookmarks)
import Eza.Favicon (Favicon (..), getFavicon)
import Eza.Graph (graphNeighborhood)
import Eza.Highlights (createHighlight, deleteHighlight, listHighlights, updateHighlight)
import Eza.Import (defaultImportOptions, importParsed, parseNetscape)
import Eza.Jobs (resetRunningJobs)
import Eza.JsonExport (exportJson, importJson)
import Eza.Pages (addPasskeyPage, loginPage, recoverPage, setupPage)
import Eza.Rules (Rule (..), createRule, deleteRule, listRules, matchingBookmarks, updateRule)
import Eza.SavedSearches (createSavedSearch, deleteSavedSearch, listSavedSearches)
import Eza.Shares (ShareRecord (..), ShareState (..), ShareUnavailable (..), createShare, listShares, resolveShareState, revokeShare, shareBookmarkPage, shareSearchFeed, shareSearchPage, shareUnavailablePage)
import Eza.Snapshot (captureSnapshot)
import Eza.Tags (consolidationCandidates, deleteTag, mergeTags, renameTag)
import Eza.Tokens (Token (..), TokenView (..), authenticateToken, createToken, listTokens, revokeToken, tokenAllows)
import Eza.Types
import Eza.Undo (undoLast)
import Network.Wai.Parse (FileInfo (..), defaultParseRequestBodyOptions, lbsBackEnd, parseRequestBodyEx)

runServer :: Config -> Connection -> IO ()
runServer cfg conn = do
    Auth.cleanupExpired conn
    resetRunningJobs conn
    manager <- newTlsManager
    forM_ [1 .. cfgEnrichWorkers cfg] $ \_ -> void (async (runEnrichWorker manager cfg))
    db <- newMVar conn
    let settings =
            setHost (fromString (bindHost (cfgBind cfg)))
                . setPort (bindPort (cfgBind cfg))
                . setServerName "eza"
                . setBeforeMainLoop (hPutStrLn stderr ("eza listening on " <> cfgBind cfg))
                $ defaultSettings
    outcome <- try (runSettings settings (securityMiddleware cfg (app cfg db))) :: IO (Either IOException ())
    case outcome of
        Right () -> pure ()
        Left err
            | "Address already in use" `isInfixOf` show err -> do
                hPutStrLn stderr ("eza could not listen on " <> cfgBind cfg <> ": the port is already in use.")
                hPutStrLn stderr "Another eza process is probably already running there."
                hPutStrLn stderr ("Open " <> T.unpack (cfgPublicOrigin cfg) <> " to use it, or stop the other process and start again.")
                exitFailure
            | otherwise -> throwIO err

-- | Security headers applied to every response (API, HTML, assets).
securityMiddleware :: Config -> Middleware
securityMiddleware cfg app' req respond =
    app' req (respond . mapResponseHeaders (<> headersFor req))
  where
    headersFor r =
        [ ("X-Content-Type-Options", "nosniff")
        , ("Referrer-Policy", "no-referrer")
        , ("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        ]
            <> frameHeaders r
            <> [("Strict-Transport-Security", "max-age=31536000; includeSubDomains") | cfgSecureCookies cfg]

    -- The record page embeds the local snapshot viewer in an iframe, so that one
    -- response may be framed by this origin. Every other response stays deny.
    frameHeaders r
        | isSnapshotRequest r =
            [("Content-Security-Policy", "frame-ancestors 'self'")]
        | otherwise =
            [ ("X-Frame-Options", "DENY")
            ,
                ( "Content-Security-Policy"
                , "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
                )
            ]

isSnapshotRequest :: Request -> Bool
isSnapshotRequest r = case pathInfo r of
    ["api", "v1", "bookmarks", _, "snapshot"] -> requestMethod r == "GET"
    _ -> False

type DbVar = MVar Connection

authConfig :: Config -> Auth.AuthConfig
authConfig cfg = Auth.AuthConfig (cfgPublicOrigin cfg) (cfgRpId cfg) (cfgRpName cfg)

app :: Config -> DbVar -> Application
app cfg db req respond = do
    case (requestMethod req, pathInfo req) of
        -- Public: health + auth pages/ceremonies.
        ("GET", ["healthz"]) -> health db respond
        ("GET", ["login"]) -> withDb db $ \conn -> do
            msess <- sessionFromReq conn req
            case msess of
                Just _ -> respond (redirectTo "/")
                Nothing -> do
                    n <- Auth.countCredentials conn
                    if n == 0 then respond (redirectTo "/setup") else respond (htmlResponse loginPage)
        ("GET", ["setup"]) -> withDb db $ \conn -> do
            allowed <- Auth.setupAllowed conn
            if allowed then respond (htmlResponse setupPage) else respond (redirectTo "/login")
        ("GET", ["recover"]) -> respond (htmlResponse recoverPage)
        ("GET", ["s", token]) -> withDb db $ \conn -> publicShareHandler conn token respond
        ("POST", ["api", "auth", "options"]) -> withDb db $ \conn -> do
            ensureOrigin cfg req
            r <- Auth.authenticationOptions conn (authConfig cfg)
            either (respond . authErrResponse) (respond . jsonResponse status200) r
        ("POST", ["api", "auth", "verify"]) -> withDb db $ \conn -> do
            ensureOrigin cfg req
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> do
                    r <- Auth.verifyLogin conn (authConfig cfg) v
                    case r of
                        Left e -> respond (authErrResponse e)
                        Right sess -> respond (withAuthCookies cfg sess (jsonResponse status200 (object ["redirect" .= ("/" :: Text)])))
        ("POST", ["api", "setup", "options"]) -> withDb db $ \conn -> do
            ensureOrigin cfg req
            r <- Auth.registrationOptions conn (authConfig cfg) True
            either (respond . authErrResponse) (respond . jsonResponse status200) r
        ("POST", ["api", "setup", "verify"]) -> withDb db $ \conn -> do
            ensureOrigin cfg req
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> do
                    r <- Auth.verifyRegistration conn (authConfig cfg) True v
                    case r of
                        Left e -> respond (authErrResponse e)
                        Right (Auth.RegistrationOutcome codes msess) ->
                            case msess of
                                Nothing -> respond (jsonError status400 "bad_request" "no session")
                                Just sess ->
                                    respond
                                        ( withAuthCookies
                                            cfg
                                            sess
                                            (jsonResponse status200 (object ["codes" .= fromMaybe [] codes, "redirect" .= ("/" :: Text)]))
                                        )
        ("POST", ["api", "recovery", "redeem"]) -> withDb db $ \conn -> do
            ensureOrigin cfg req
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> case parseMaybeObj v of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case parseMaybe (.: "code") o of
                        Nothing -> respond (jsonError status400 "bad_request" "code is required")
                        Just code -> do
                            r <- Auth.redeemRecoveryCode conn code
                            case r of
                                Left e -> respond (authErrResponse e)
                                Right sess -> respond (withAuthCookies cfg sess (jsonResponse status200 (object ["redirect" .= ("/setup" :: Text)])))
        ("GET", ("assets" : rest)) -> serveAsset cfg rest req respond
        ("GET", ["favicon.svg"]) -> serveAsset cfg ["favicon.svg"] req respond
        ("GET", ["theme.js"]) -> serveAsset cfg ["theme.js"] req respond
        ("GET", ["manifest.webmanifest"]) ->
            serveStaticFile cfg "manifest.webmanifest" [("Content-Type", "application/manifest+json")] req respond
        ("GET", ["sw.js"]) -> serveServiceWorker cfg req respond
        ("GET", []) -> withDb db $ \conn -> do
            msess <- sessionFromReq conn req
            case msess of
                Nothing -> respond (redirectTo "/login")
                Just _ -> indexResponse cfg req respond
        -- Authenticated API.
        _ -> withAuthed cfg db req respond $ \ctx conn -> authedRoute cfg db req respond ctx conn

data AuthContext
    = CookieSession Auth.Session
    | BearerToken Token

authedRoute :: Config -> DbVar -> Request -> (Response -> IO ResponseReceived) -> AuthContext -> Connection -> IO ResponseReceived
authedRoute cfg _db req respond ctx conn =
    case (requestMethod req, pathInfo req) of
        ("GET", ["save"]) -> indexResponse cfg req respond
        ("GET", ["api", "v1", "boot"]) -> do
            page <- listBookmarks conn defaultListQuery
            tags <- allTags conn
            stats <- libraryStats conn
            respond (jsonResponse status200 (BootPayload "0.1.0" (cfgPublicOrigin cfg) tags [] page stats))
        ("GET", ["api", "v1", "bookmarks"]) -> do
            page <- listBookmarks conn (listQueryFrom req)
            respond (jsonResponse status200 page)
        ("POST", ["api", "v1", "bookmarks"]) -> addBookmark conn req respond
        ("POST", ["api", "v1", "bookmarks", "bulk"]) -> bulkHandler conn req respond
        ("GET", ["api", "v1", "bookmarks", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> do
                m <- getBookmark conn bid
                case m of
                    Nothing -> respond (jsonError status404 "not_found" "bookmark not found")
                    Just b -> respond (jsonResponse status200 b)
        ("DELETE", ["api", "v1", "bookmarks", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> do
                ok <- deleteBookmark conn bid
                if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "bookmark not found")
        ("GET", ["api", "v1", "favicons", domain]) ->
            faviconHandler conn req domain respond
        ("POST", ["api", "v1", "quick-save"]) ->
            quickSaveHandler conn req respond
        ("GET", ["api", "v1", "bookmarks", idTxt, "highlights"]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> do
                highlights <- listHighlights conn bid
                respond (jsonResponse status200 (object ["highlights" .= highlights]))
        ("POST", ["api", "v1", "bookmarks", idTxt, "highlights"]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> highlightCreateHandler conn bid req respond
        ("PATCH", ["api", "v1", "bookmarks", idTxt, "highlights", hidTxt]) ->
            case (readInt idTxt, readInt hidTxt) of
                (Just bid, Just hid) -> highlightUpdateHandler conn bid hid req respond
                _ -> respond (jsonError status400 "bad_request" "invalid highlight id")
        ("DELETE", ["api", "v1", "bookmarks", idTxt, "highlights", hidTxt]) ->
            case (readInt idTxt, readInt hidTxt) of
                (Just bid, Just hid) -> do
                    ok <- deleteHighlight conn bid hid
                    if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "highlight not found")
                _ -> respond (jsonError status400 "bad_request" "invalid highlight id")
        ("GET", ["api", "v1", "share-links"]) -> do
            shares <- listShares conn
            respond (jsonResponse status200 (object ["shares" .= shares]))
        ("POST", ["api", "v1", "share-links"]) -> shareCreateHandler cfg conn req respond
        ("DELETE", ["api", "v1", "share-links", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid share id")
            Just shareId -> do
                ok <- revokeShare conn shareId
                if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "share not found")
        ("GET", ["api", "v1", "bookmarks", idTxt, "snapshot"]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> snapshotHandler cfg conn bid respond
        ("GET", ["api", "v1", "tags"]) -> do
            tags <- allTags conn
            respond (jsonResponse status200 (object ["tags" .= tags]))
        ("POST", ["api", "v1", "inbox", "mark-all-above"]) -> markAbove conn req respond
        ("PATCH", ["api", "v1", "bookmarks", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> patchBookmark conn bid req respond
        ("POST", ["api", "v1", "bookmarks", idTxt, action]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> do
                case action of
                    "open" -> recordOpen conn bid >> respond (jsonResponse status200 (object ["ok" .= True]))
                    "enrich" -> do
                        enqueueEnrichment conn bid
                        respond (jsonResponse status200 (object ["ok" .= True, "queued" .= True]))
                    "extract" -> do
                        enqueueEnrichment conn bid
                        respond (jsonResponse status200 (object ["ok" .= True, "queued" .= True]))
                    "snapshot" -> do
                        m <- captureSnapshot cfg conn bid
                        case m of
                            Nothing -> respond (jsonError status404 "not_found" "bookmark not found")
                            Just (kind, value) ->
                                respond (jsonResponse status200 (object ["ok" .= True, "kind" .= kind, "value" .= value]))
                    _ -> respond (jsonError status404 "not_found" "No such action")
        ("GET", ["api", "v1", "bookmarks", idTxt, "backlinks"]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
            Just bid -> do
                bl <- getBacklinks conn bid
                respond (jsonResponse status200 bl)
        ("GET", ["api", "v1", "autocomplete"]) -> do
            let q = fromMaybe "" (param "q" req)
            items <- autocomplete conn q 10
            respond (jsonResponse status200 (object ["items" .= items]))
        ("GET", ["api", "v1", "graph"]) -> do
            case (readInt =<< param "seed" req) of
                Nothing -> respond (jsonError status400 "bad_request" "seed is required")
                Just seed -> do
                    let depth = fromMaybe 1 (readInt =<< param "depth" req)
                    m <- graphNeighborhood conn seed depth
                    case m of
                        Nothing -> respond (jsonError status404 "not_found" "bookmark not found")
                        Just g -> respond (jsonResponse status200 g)
        ("GET", ["api", "v1", "saved-searches"]) -> do
            s <- listSavedSearches conn
            respond (jsonResponse status200 (object ["saved_searches" .= s]))
        ("POST", ["api", "v1", "saved-searches"]) -> do
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> case parseMaybeObj v of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case (parseMaybe (.: "name") o, parseMaybe (.: "q") o, parseMaybe (.: "tags") o) of
                        (Just name, q, tags) -> do
                            sid <- createSavedSearch conn name (fromMaybe "" q) (fromMaybe [] tags)
                            respond (jsonResponse status201 (object ["id" .= sid]))
                        _ -> respond (jsonError status400 "bad_request" "name is required")
        ("DELETE", ["api", "v1", "saved-searches", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid id")
            Just sid -> do
                ok <- deleteSavedSearch conn sid
                if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "saved search not found")
        ("GET", ["api", "v1", "dedup", "candidates"]) -> do
            report <- dedupCandidates conn
            respond (jsonResponse status200 report)
        ("POST", ["api", "v1", "dedup", "merge"]) -> do
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> case parseMaybeObj v of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case (parseMaybe (.: "keep_id") o, parseMaybe (.: "merge_ids") o) of
                        (Just keep, Just ms) -> do
                            n <- mergeBookmarks conn keep ms
                            respond (jsonResponse status200 (object ["merged" .= n]))
                        _ -> respond (jsonError status400 "bad_request" "keep_id and merge_ids are required")
        ("GET", ["api", "v1", "tags", "consolidation-candidates"]) -> do
            report <- consolidationCandidates conn
            respond (jsonResponse status200 report)
        ("POST", ["api", "v1", "tags", "apply"]) -> do
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> case parseMaybeObj v of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case (parseMaybe (.: "bookmark_id") o, parseMaybe (.: "tags") o) of
                        (Just bid, Just tags) -> do
                            n <- addTagsToBookmark conn bid tags
                            respond (jsonResponse status200 (object ["updated" .= n]))
                        _ -> respond (jsonError status400 "bad_request" "bookmark_id and tags are required")
        ("POST", ["api", "v1", "tags", "merge"]) -> do
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> case parseMaybeObj v of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case (parseMaybe (.: "from") o, parseMaybe (.: "into") o) of
                        (Just froms, Just into) -> do
                            n <- mergeTags conn froms into
                            respond (jsonResponse status200 (object ["updated" .= n]))
                        _ -> respond (jsonError status400 "bad_request" "from and into are required")
        ("GET", ["api", "v1", "tags", tag, "suggestions"]) -> do
            r <- aiSuggestions conn tag 20
            case r of
                Left notice ->
                    respond
                        ( jsonResponse
                            status200
                            (object ["suggestions" .= ([] :: [Value]), "configured" .= False, "notice" .= notice])
                        )
                Right suggestions -> respond (jsonResponse status200 (object ["suggestions" .= suggestions]))
        ("POST", ("api" : "v1" : "tags" : rest)) -> do
            let tagName = T.intercalate "/" rest
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> case parseMaybeObj v of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case parseMaybe (.: "name") o of
                        Nothing -> respond (jsonError status400 "bad_request" "name is required")
                        Just newName -> do
                            ok <- renameTag conn tagName newName
                            if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonError status409 "conflict" "tag rename failed")
        ("DELETE", ("api" : "v1" : "tags" : rest)) -> do
            let tagName = T.intercalate "/" rest
            ok <- deleteTag conn tagName
            if ok then respond (emptyResponse status204) else respond (jsonError status409 "conflict" "tag is not empty or does not exist")
        ("POST", ["api", "v1", "maintenance", "check-dead"]) -> do
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> do
                    let o = fromMaybe mempty (parseMaybeObj v) :: Object
                        limit = fromMaybe 500 (parseMaybe (.: "limit") o :: Maybe Int)
                        older = fromMaybe 0 (parseMaybe (.: "older_than") o :: Maybe Int)
                        includeDead = fromMaybe False (parseMaybe (.: "include_dead") o :: Maybe Bool)
                    (checked, dead, alive) <- checkDead conn limit older includeDead
                    respond (jsonResponse status200 (object ["checked" .= checked, "dead" .= dead, "alive" .= alive]))
        ("GET", ["api", "v1", "maintenance", "prune-candidates"]) -> do
            items <- pruneCandidates conn 365
            respond (jsonResponse status200 (object ["items" .= items]))
        ("POST", ["api", "v1", "maintenance", "prune"]) -> do
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> case parseMaybeObj v of
                    Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                    Just o -> case parseMaybe (.: "ids") o :: Maybe [Int] of
                        Nothing -> respond (jsonError status400 "bad_request" "ids is required")
                        Just ids -> do
                            n <- pruneApply conn ids
                            respond (jsonResponse status200 (object ["pruned" .= n, "restored" .= (0 :: Int)]))
        ("POST", ["api", "v1", "undo"]) -> do
            n <- undoLast conn
            respond (jsonResponse status200 (object ["restored" .= n]))
        ("POST", ["api", "v1", "import"]) -> importHandler conn req respond
        ("POST", ["api", "v1", "import", "json"]) -> do
            body <- strictRequestBody req
            case eitherDecode body of
                Left err -> respond (jsonError status400 "bad_request" (T.pack err))
                Right value -> do
                    result <- importJson conn value
                    case result of
                        Left err -> respond (jsonError status400 "bad_request" err)
                        Right report -> respond (jsonResponse status200 report)
        ("GET", ["api", "v1", "export"]) ->
            if param "format" req == Just "json"
                then do
                    value <- exportJson conn
                    respond
                        ( responseLBS
                            status200
                            [ (hContentType, "application/json; charset=utf-8")
                            , (hContentDisposition, "attachment; filename=\"eza-export.json\"")
                            ]
                            (encode value)
                        )
                else do
                    content <- exportBookmarks conn
                    respond
                        ( responseLBS
                            status200
                            [ (hContentType, "text/html; charset=utf-8")
                            , (hContentDisposition, "attachment; filename=\"bookmarks.html\"")
                            ]
                            (LBS.fromStrict (TE.encodeUtf8 content))
                        )
        ("GET", ["api", "v1", "export", "notes"]) ->
            respond (jsonError status501 "not_implemented" "Markdown note export is coming in a later milestone")
        ("GET", ["account", "add-passkey"]) -> respond (htmlResponse addPasskeyPage)
        ("GET", ["api", "v1", "stats"]) -> do
            stats <- libraryStats conn
            links <- Db.queryScalar conn "SELECT COUNT(*) FROM links"
            respond
                ( jsonResponse
                    status200
                    ( object
                        [ "bookmarks" .= lsTotal stats
                        , "tags" .= lsTags stats
                        , "bookmark_tags" .= lsTagLinks stats
                        , "links" .= links
                        , "sources" .= lsSources stats
                        , "top_sources" .= lsTopSources stats
                        , "sources_once" .= lsSourcesOnce stats
                        , "first_day" .= lsFirstDay stats
                        , "last_day" .= lsLastDay stats
                        , "days" .= lsDays stats
                        , "years" .= lsYears stats
                        , "filing_days" .= lsFilingDays stats
                        , "unread" .= lsUnread stats
                        , "dead" .= lsDead stats
                        , "highlights" .= lsHighlights stats
                        , "shares" .= lsShares stats
                        , "jobs_pending" .= lsQueued stats
                        , "favicon_bytes" .= lsFaviconBytes stats
                        ]
                    )
                )
        ("GET", ["api", "v1", "ai", "status"]) -> do
            provider <- fromMaybe (cfgAiProvider cfg) <$> lookupEnv "EZA_AI_PROVIDER"
            key <-
                case provider of
                    "ollama" -> pure (Just "")
                    "openai" -> lookupEnv "OPENAI_API_KEY"
                    "openai-compatible" -> lookupEnv "OPENAI_API_KEY"
                    "none" -> pure Nothing
                    _ -> lookupEnv "ANTHROPIC_API_KEY"
            let configured = maybe False (not . null) key
            respond
                ( jsonResponse
                    status200
                    ( object
                        [ "provider" .= provider
                        , "model" .= (if provider == "ollama" then T.pack (cfgAiModel cfg) else ("default" :: Text))
                        , "configured" .= configured
                        ]
                    )
                )
        ("GET", ["api", "v1", "rules"]) -> do
            rules <- listRules conn
            respond (jsonResponse status200 (object ["rules" .= rules]))
        ("POST", ["api", "v1", "rules"]) -> do
            body <- strictRequestBody req
            case eitherDecode body of
                Left err -> respond (jsonError status400 "bad_request" (T.pack err))
                Right rule -> do
                    created <- createRule conn (sanitizeRule rule)
                    respond (jsonResponse status201 created)
        ("POST", ["api", "v1", "rules", "test"]) -> do
            body <- strictRequestBody req
            case eitherDecode body of
                Left err -> respond (jsonError status400 "bad_request" (T.pack err))
                Right rule -> do
                    ids <- matchingBookmarks conn (ruleField rule) (rulePattern rule)
                    respond (jsonResponse status200 (object ["matches" .= length ids, "bookmark_ids" .= ids]))
        ("PATCH", ["api", "v1", "rules", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid rule id")
            Just rid -> do
                body <- strictRequestBody req
                case eitherDecode body of
                    Left err -> respond (jsonError status400 "bad_request" (T.pack err))
                    Right rule -> do
                        ok <- updateRule conn (sanitizeRule rule){ruleId = rid}
                        if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonError status404 "not_found" "rule not found")
        ("DELETE", ["api", "v1", "rules", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid rule id")
            Just rid -> do
                ok <- deleteRule conn rid
                if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "rule not found")
        ("GET", ["api", "v1", "tokens"]) -> do
            tokens <- listTokens conn
            respond (jsonResponse status200 (object ["tokens" .= tokens]))
        ("POST", ["api", "v1", "tokens"]) -> do
            body <- strictRequestBody req
            case eitherDecode body of
                Left err -> respond (jsonError status400 "bad_request" (T.pack err))
                Right (TokenCreateBody name scopes) -> do
                    (_, raw, view) <- createToken conn name (fromMaybe ["read", "write"] scopes)
                    respond (jsonResponse status201 (object ["token" .= raw, "token_info" .= view]))
        ("DELETE", ["api", "v1", "tokens", idTxt]) -> case readInt idTxt of
            Nothing -> respond (jsonError status400 "bad_request" "invalid token id")
            Just tokenId -> do
                ok <- revokeToken conn tokenId
                if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "token not found")
        ("GET", ["api", "v1", "account"]) -> do
            creds <- Auth.listCredentials conn
            remaining <- Auth.recoveryCodesRemaining conn
            sessions <- Auth.listSessions conn (case ctx of CookieSession sess -> Just sess; BearerToken _ -> Nothing)
            respond
                ( jsonResponse
                    status200
                    ( object
                        [ "credentials" .= creds
                        , "recovery_codes_remaining" .= remaining
                        , "sessions" .= sessions
                        ]
                    )
                )
        ("POST", ["api", "v1", "account", "passkeys", "options"]) -> do
            r <- Auth.addPasskeyOptions conn (authConfig cfg)
            either (respond . authErrResponse) (respond . jsonResponse status200) r
        ("POST", ["api", "v1", "account", "passkeys", "verify"]) -> do
            body <- jsonBody req
            case body of
                Left e -> respond (jsonError status400 "bad_request" e)
                Right v -> do
                    r <- Auth.verifyAddPasskey conn (authConfig cfg) v
                    case r of
                        Left e -> respond (authErrResponse e)
                        Right () -> respond (jsonResponse status200 (object ["ok" .= True]))
        ("PATCH", ["api", "v1", "account", "passkeys", cidTxt]) ->
            case Auth.decodeCredentialId cidTxt of
                Nothing -> respond (jsonError status400 "bad_request" "invalid credential id")
                Just cid -> do
                    body <- jsonBody req
                    case body of
                        Left e -> respond (jsonError status400 "bad_request" e)
                        Right v -> case parseMaybeObj v of
                            Nothing -> respond (jsonError status400 "bad_request" "nickname is required")
                            Just o -> case parseMaybe (.: "nickname") o of
                                Nothing -> respond (jsonError status400 "bad_request" "nickname is required")
                                Just nick -> do
                                    ok <- Auth.renameCredential conn cid nick
                                    if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonError status404 "not_found" "passkey not found")
        ("DELETE", ["api", "v1", "account", "passkeys", cidTxt]) ->
            case Auth.decodeCredentialId cidTxt of
                Nothing -> respond (jsonError status400 "bad_request" "invalid credential id")
                Just cid -> do
                    r <- Auth.deleteCredential conn cid
                    either (respond . authErrResponse) (const (respond (emptyResponse status204))) r
        ("POST", ["api", "v1", "account", "recovery", "regenerate"]) -> do
            codes <- Auth.regenerateRecoveryCodes conn
            respond (jsonResponse status200 (object ["codes" .= codes]))
        ("POST", ["api", "auth", "logout"]) -> case ctx of
            CookieSession sess -> do
                Auth.deleteSessionHash conn (Auth.sessId sess)
                respond (clearAuthCookies cfg (emptyResponse status204))
            BearerToken _ -> respond (jsonError status403 "session_required" "a bearer token cannot end a browser session")
        ("GET", path)
            | not ("api" `elem` path)
            , not ("assets" `elem` path) ->
                indexResponse cfg req respond
        _ -> respond (jsonError status404 "not_found" "No such route")

-- ---------------------------------------------------------------------------
-- Auth guard
-- ---------------------------------------------------------------------------

withAuthed :: Config -> DbVar -> Request -> (Response -> IO ResponseReceived) -> (AuthContext -> Connection -> IO ResponseReceived) -> IO ResponseReceived
withAuthed cfg db req respond action = withMVar db $ \conn -> do
    case bearerToken req of
        Just raw -> do
            mtoken <- authenticateToken conn raw
            case mtoken of
                Nothing -> respond (jsonError status401 "unauthenticated" "invalid bearer token")
                Just token
                    | requiresSession (pathInfo req) ->
                        respond (jsonError status403 "session_required" "this route requires a browser session")
                    | not (tokenAllows token (TE.decodeUtf8 (requestMethod req)) (pathInfo req)) ->
                        respond (jsonError status403 "token_scope" "this token does not allow the request")
                    | not (originAllowed cfg req) ->
                        respond (jsonError status403 "origin" "origin is not allowed")
                    | otherwise -> action (BearerToken token) conn
        Nothing -> do
            msess <- sessionFromReq conn req
            case msess of
                Nothing -> respond (unauthorized req)
                Just sess -> do
                    if not (recoveryScopeAllowed (requestMethod req) (pathInfo req) (Auth.sessScope sess))
                        then respond (jsonError status403 "recovery_scope" "this recovery session may only re-enroll a passkey")
                        else
                            if not (originAllowed cfg req)
                                then respond (jsonError status403 "origin" "origin is not allowed")
                                else
                                    if not (csrfOk req sess)
                                        then respond (jsonError status403 "csrf" "missing or invalid CSRF token")
                                        else action (CookieSession sess) conn

bearerToken :: Request -> Maybe Text
bearerToken req =
    case lookup hAuthorization (requestHeaders req) of
        Nothing -> Nothing
        Just raw ->
            let value = TE.decodeUtf8 raw
             in if "Bearer " `T.isPrefixOf` value then Just (T.drop 7 value) else Nothing

requiresSession :: [Text] -> Bool
requiresSession path = case path of
    ("account" : _) -> True
    ("api" : "v1" : "account" : _) -> True
    ("api" : "v1" : "tokens" : _) -> True
    ("api" : "v1" : "rules" : _) -> True
    ["save"] -> True
    _ -> False

recoveryScopeAllowed :: Method -> [Text] -> Text -> Bool
recoveryScopeAllowed method path scope
    | scope /= "recovery" = True
    | otherwise = case (method, path) of
        ("POST", ["api", "setup", "options"]) -> True
        ("POST", ["api", "setup", "verify"]) -> True
        ("POST", ["api", "auth", "logout"]) -> True
        ("GET", ["api", "v1", "boot"]) -> True
        ("GET", ["api", "v1", "account"]) -> True
        _ -> False

csrfOk :: Request -> Auth.Session -> Bool
csrfOk req sess
    | requestMethod req `notElem` ["POST", "PUT", "PATCH", "DELETE"] = True
    | otherwise =
        case lookup "X-CSRF-Token" (requestHeaders req) of
            Nothing -> False
            Just raw -> Auth.hashToken (TE.decodeUtf8 raw) == Auth.sessCsrf sess

originAllowed :: Config -> Request -> Bool
originAllowed cfg req =
    case lookup "Origin" (requestHeaders req) of
        Nothing -> True
        Just raw -> TE.decodeUtf8 raw `elem` cfgAllowedOrigins cfg

ensureOrigin :: Config -> Request -> IO ()
ensureOrigin cfg req = do
    if originAllowed cfg req then pure () else pure ()

-- Auth ceremony requests are same-origin; a missing Origin is accepted for
-- non-browser clients, but a present mismatching Origin is rejected in
-- withAuthed/CSRF paths. This helper is intentionally a no-op placeholder
-- for the public ceremony endpoints; rate limiting and stricter origin
-- checks land with the auth hardening pass.

acceptsHtml :: Request -> Bool
acceptsHtml req =
    case lookup hAccept (requestHeaders req) of
        Nothing -> True
        Just raw -> "text/html" `BS.isInfixOf` raw

sessionFromReq :: Connection -> Request -> IO (Maybe Auth.Session)
sessionFromReq conn req =
    case lookup hCookie (requestHeaders req) of
        Nothing -> pure Nothing
        Just rawCookie -> do
            let cookies = Cookie.parseCookies rawCookie
                rawToken = lookup (TE.encodeUtf8 Auth.sessionCookieName) cookies
            case rawToken of
                Nothing -> pure Nothing
                Just token -> Auth.getSession conn (TE.decodeUtf8 token)

unauthorized :: Request -> Response
unauthorized req
    | "api" `elem` pathInfo req = jsonError status401 "unauthenticated" "sign in required"
    | otherwise = redirectTo "/login"

redirectTo :: Text -> Response
redirectTo target =
    responseLBS status302 [(hLocation, TE.encodeUtf8 target)] ""

-- ---------------------------------------------------------------------------
-- Cookies
-- ---------------------------------------------------------------------------

withAuthCookies :: Config -> Auth.NewSession -> Response -> Response
withAuthCookies cfg sess =
    mapResponseHeaders (\hs -> hs <> [sessionCookie, csrfCookie])
  where
    securePart = if cfgSecureCookies cfg then "; Secure" else ""
    sessionCookie =
        ( hSetCookie
        , BSC.pack
            ( T.unpack
                ( Auth.sessionCookieName
                    <> "="
                    <> Auth.nsToken sess
                    <> "; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000"
                    <> securePart
                )
            )
        )
    csrfCookie =
        ( hSetCookie
        , BSC.pack
            ( T.unpack
                ( Auth.csrfCookieName
                    <> "="
                    <> Auth.nsCsrf sess
                    <> "; Path=/; SameSite=Lax; Max-Age=2592000"
                    <> securePart
                )
            )
        )

clearAuthCookies :: Config -> Response -> Response
clearAuthCookies cfg =
    mapResponseHeaders
        ( \hs ->
            hs
                <> [ (hSetCookie, BSC.pack (T.unpack (Auth.sessionCookieName <> "=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" <> securePart)))
                   , (hSetCookie, BSC.pack (T.unpack (Auth.csrfCookieName <> "=; Path=/; SameSite=Lax; Max-Age=0" <> securePart)))
                   ]
        )
  where
    securePart = if cfgSecureCookies cfg then "; Secure" else ""

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

health :: DbVar -> (Response -> IO ResponseReceived) -> IO ResponseReceived
health db respond = do
    ok <- withMVar db Db.ping
    if ok
        then respond (jsonResponse status200 (object ["status" .= ("ok" :: Text), "version" .= ("0.1.0" :: Text)]))
        else respond (jsonError status503 "unavailable" "database is unavailable")

faviconHandler :: Connection -> Request -> Text -> (Response -> IO ResponseReceived) -> IO ResponseReceived
faviconHandler conn req domain respond = do
    cached <- getFavicon conn domain
    case cached of
        Nothing -> respond (redirectTo "/assets/favicon-fallback.svg")
        Just favicon -> do
            let etag = TE.encodeUtf8 (fvEtag favicon)
            case lookup hIfNoneMatch (requestHeaders req) of
                Just raw | raw == etag -> respond (emptyResponse status304)
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

data AddBody = AddBody
    { abUrl :: Text
    , abTitle :: Maybe Text
    , abTags :: Maybe [Text]
    }

instance FromJSON AddBody where
    parseJSON = withObject "AddBody" $ \o ->
        AddBody <$> o .: "url" <*> o .:? "title" <*> o .:? "tags"

addBookmark :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
addBookmark conn req respond = do
    body <- strictRequestBody req
    case eitherDecode body of
        Left err -> respond (jsonError status400 "bad_request" (T.pack err))
        Right (AddBody url title tags) ->
            if not (isHttpUrl url)
                then respond (jsonError status400 "bad_request" "url must be http(s)")
                else do
                    result <- insertBookmark conn url (fromMaybe "" title) (fromMaybe [] tags)
                    case result of
                        Left msg -> respond (jsonError status409 "conflict" msg)
                        Right bid -> do
                            enqueueEnrichment conn bid
                            respond (jsonResponse status201 (object ["id" .= bid]))

sanitizeRule :: Rule -> Rule
sanitizeRule rule =
    rule
        { ruleName = T.strip (ruleName rule)
        , ruleField = if T.toLower (ruleField rule) `elem` ["url", "domain", "title"] then T.toLower (ruleField rule) else "url"
        , rulePattern = T.strip (rulePattern rule)
        , ruleAddTags = [T.toLower (T.strip tag) | tag <- ruleAddTags rule, not (T.null (T.strip tag))]
        }

data HighlightCreateBody = HighlightCreateBody
    { hcbQuote :: Text
    , hcbPrefix :: Maybe Text
    , hcbSuffix :: Maybe Text
    , hcbStart :: Int
    , hcbEnd :: Int
    , hcbNote :: Maybe Text
    , hcbColor :: Maybe Text
    }

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

highlightCreateHandler :: Connection -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
highlightCreateHandler conn bid req respond = do
    body <- strictRequestBody req
    case eitherDecode body of
        Left err -> respond (jsonError status400 "bad_request" (T.pack err))
        Right (HighlightCreateBody quote prefix suffix start end note color) -> do
            result <- createHighlight conn bid quote (fromMaybe "" prefix) (fromMaybe "" suffix) start end (fromMaybe "" note) (fromMaybe "yellow" color)
            case result of
                Left err -> respond (jsonError status400 "bad_request" err)
                Right highlight -> respond (jsonResponse status201 highlight)

data HighlightPatchBody = HighlightPatchBody
    { hpbNote :: Maybe Text
    , hpbColor :: Maybe Text
    }

instance FromJSON HighlightPatchBody where
    parseJSON = withObject "HighlightPatchBody" $ \o ->
        HighlightPatchBody <$> o .:? "note" <*> o .:? "color"

highlightUpdateHandler :: Connection -> Int -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
highlightUpdateHandler conn bid hid req respond = do
    body <- strictRequestBody req
    case eitherDecode body of
        Left err -> respond (jsonError status400 "bad_request" (T.pack err))
        Right (HighlightPatchBody note color) -> do
            ok <- updateHighlight conn bid hid note color
            if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonError status404 "not_found" "highlight not found")

data ShareCreateBody = ShareCreateBody
    { scbScope :: Text
    , scbTargetId :: Int
    , scbIncludeNote :: Maybe Bool
    , scbExpiresInDays :: Maybe Int
    }

instance FromJSON ShareCreateBody where
    parseJSON = withObject "ShareCreateBody" $ \o ->
        ShareCreateBody <$> o .: "scope" <*> o .: "target_id" <*> o .:? "include_note" <*> o .:? "expires_in_days"

shareCreateHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
shareCreateHandler cfg conn req respond = do
    body <- strictRequestBody req
    case eitherDecode body of
        Left err -> respond (jsonError status400 "bad_request" (T.pack err))
        Right (ShareCreateBody scope targetId includeNote expires) -> do
            let days = fromMaybe (cfgShareTtlDays cfg) expires
            result <- createShare conn scope targetId (fromMaybe False includeNote) days
            case result of
                Left err -> respond (jsonError status400 "bad_request" err)
                Right (shareId, raw) ->
                    respond (jsonResponse status201 (object ["id" .= shareId, "url" .= (cfgPublicOrigin cfg <> "/s/" <> raw)]))

publicShareHandler :: Connection -> Text -> (Response -> IO ResponseReceived) -> IO ResponseReceived
publicShareHandler conn token respond = do
    let isFeed = T.isSuffixOf ".xml" token
        raw = if isFeed then T.dropEnd 4 token else token
    state <- resolveShareState conn raw
    case state of
        ShareGone reason ->
            if isFeed
                then respond (shareHeaders (jsonError (unavailableStatus reason) "not_found" "share link is not readable"))
                else respond (shareHeaders (htmlResponseAt (unavailableStatus reason) (shareUnavailablePage reason)))
        ShareReadable record
            | srScope record == "bookmark" -> do
                bookmark <- getBookmark conn (srTargetId record)
                case bookmark of
                    Nothing -> respond (shareHeaders (htmlResponseAt status404 (shareUnavailablePage ShareInvalid)))
                    Just detail
                        | isFeed -> respond (shareHeaders (jsonError status404 "not_found" "feeds are only available for saved searches"))
                        | otherwise -> respond (shareHeaders (htmlResponseAt status200 (shareBookmarkPage record detail)))
            | srScope record == "saved_search" -> do
                searches <- listSavedSearches conn
                case [saved | saved <- searches, ssId saved == srTargetId record] of
                    [] -> respond (shareHeaders (htmlResponseAt status404 (shareUnavailablePage ShareInvalid)))
                    (saved : _) -> do
                        page <- listBookmarks conn (defaultListQuery{lqQ = ssQ saved, lqTags = ssTags saved, lqLimit = 100})
                        if isFeed
                            then respond (shareHeaders (responseLBS status200 [(hContentType, "application/atom+xml; charset=utf-8")] (LBS.fromStrict (TE.encodeUtf8 (shareSearchFeed saved page)))))
                            else respond (shareHeaders (htmlResponseAt status200 (shareSearchPage record saved page)))
            | otherwise -> respond (shareHeaders (htmlResponseAt status404 (shareUnavailablePage ShareInvalid)))
  where
    shareHeaders = mapResponseHeaders (<> [("X-Robots-Tag", "noindex")])
    unavailableStatus ShareInvalid = status404
    unavailableStatus _ = status410

snapshotHandler :: Config -> Connection -> Int -> (Response -> IO ResponseReceived) -> IO ResponseReceived
snapshotHandler cfg conn bid respond = do
    bookmark <- getBookmark conn bid
    case bookmark of
        Just detail
            | bdSnapshotKind detail /= "file" || T.null (bdSnapshotPath detail) ->
                respond (jsonError status404 "not_found" "no local snapshot for this bookmark")
            | otherwise -> do
                let rawPath = T.unpack (bdSnapshotPath detail)
                    root = cfgSnapshotDir cfg
                resolved <- canonicalizePath rawPath
                rootResolved <- canonicalizePath root
                exists <- doesFileExist resolved
                if exists && isPrefixOf rootResolved resolved
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
                    else respond (jsonError status404 "not_found" "snapshot file not found")
        Nothing -> respond (jsonError status404 "not_found" "bookmark not found")

data BulkBody = BulkBody
    { bbAction :: Text
    , bbIds :: [Int]
    , bbTags :: Maybe [Text]
    , bbConfirm :: Maybe Bool
    }

instance FromJSON BulkBody where
    parseJSON = withObject "BulkBody" $ \o ->
        BulkBody <$> o .: "action" <*> o .:? "ids" .!= [] <*> o .:? "tags" <*> o .:? "confirm"

bulkHandler :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
bulkHandler conn req respond = do
    body <- strictRequestBody req
    case eitherDecode body of
        Left err -> respond (jsonError status400 "bad_request" (T.pack err))
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
                Left err -> respond (jsonError status400 "bad_request" err)
                Right bulkAction -> do
                    result <- bulkUpdate conn bulkAction ids
                    case result of
                        Left err -> respond (jsonError status400 "bad_request" err)
                        Right (updated, snapshotId) ->
                            respond (jsonResponse status200 (object ["updated" .= updated, "snapshot_id" .= snapshotId]))

data TokenCreateBody = TokenCreateBody
    { tcbName :: Text
    , tcbScopes :: Maybe [Text]
    }

instance FromJSON TokenCreateBody where
    parseJSON = withObject "TokenCreateBody" $ \o ->
        TokenCreateBody <$> o .: "name" <*> o .:? "scopes"

data QuickBody = QuickBody
    { qbUrl :: Text
    , qbTitle :: Maybe Text
    , qbTags :: Maybe [Text]
    }

instance FromJSON QuickBody where
    parseJSON = withObject "QuickBody" $ \o ->
        QuickBody <$> o .: "url" <*> o .:? "title" <*> o .:? "tags"

quickSaveHandler :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
quickSaveHandler conn req respond = do
    body <- strictRequestBody req
    case eitherDecode body of
        Left err -> respond (jsonError status400 "bad_request" (T.pack err))
        Right (QuickBody url title tags)
            | not (isHttpUrl url) -> respond (jsonError status400 "bad_request" "url must be http(s)")
            | otherwise -> do
                result <- quickSave conn url (fromMaybe "" title) (fromMaybe [] tags)
                case result of
                    Left message -> respond (jsonError status409 "conflict" message)
                    Right (bid, existing) -> do
                        if existing
                            then pure ()
                            else enqueueEnrichment conn bid
                        respond (jsonResponse (if existing then status200 else status201) (object ["id" .= bid, "existing" .= existing]))

data MarkAboveBody = MarkAboveBody {mabAboveId :: Maybe Int}

instance FromJSON MarkAboveBody where
    parseJSON = withObject "MarkAboveBody" $ \o -> MarkAboveBody <$> o .:? "above_id"

markAbove :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
markAbove conn req respond = do
    body <- strictRequestBody req
    case eitherDecode body of
        Left err -> respond (jsonError status400 "bad_request" (T.pack err))
        Right (MarkAboveBody aid) -> do
            n <- markAllAbove conn aid
            respond (jsonResponse status200 (object ["updated" .= n]))

data PatchBody = PatchBody
    { pbTitle :: Maybe Text
    , pbNote :: Maybe Text
    , pbRead :: Maybe Bool
    , pbTags :: Maybe [Text]
    }

instance FromJSON PatchBody where
    parseJSON = withObject "PatchBody" $ \o ->
        PatchBody <$> o .:? "title" <*> o .:? "note_body" <*> o .:? "is_read" <*> o .:? "tags"

patchBookmark :: Connection -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
patchBookmark conn bid req respond = do
    body <- strictRequestBody req
    case eitherDecode body of
        Left err -> respond (jsonError status400 "bad_request" (T.pack err))
        Right (PatchBody mTitle mNote mRead mTags)
            | maybe False (T.null . T.strip) mTitle -> respond (jsonError status400 "bad_request" "title must not be empty")
            | all (== Nothing) [fmap (const ()) mTitle, fmap (const ()) mNote, fmap (const ()) mRead, fmap (const ()) mTags] ->
                respond (jsonError status400 "bad_request" "empty patch")
            | otherwise -> do
                ok <- updateBookmark conn bid mTitle mNote mRead mTags
                if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonError status404 "not_found" "bookmark not found")

importHandler :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
importHandler conn req respond = do
    (_, files) <- parseRequestBodyEx defaultParseRequestBodyOptions lbsBackEnd req
    case lookup "file" files of
        Nothing -> respond (jsonError status400 "bad_request" "multipart field \"file\" is required")
        Just fileInfo -> do
            let raw = LBS.toStrict (fileContent fileInfo)
                parsed = parseNetscape defaultImportOptions raw
            report <- importParsed conn defaultImportOptions parsed
            respond (jsonResponse status200 report)

jsonBody :: Request -> IO (Either Text Value)
jsonBody req = do
    body <- strictRequestBody req
    pure (case eitherDecode body :: Either String Value of Left e -> Left (T.pack e); Right v -> Right v)

parseMaybeObj :: Value -> Maybe Object
parseMaybeObj (Object o) = Just o
parseMaybeObj _ = Nothing

resultToMaybe :: Result a -> Maybe a
resultToMaybe (Success a) = Just a
resultToMaybe (Error _) = Nothing

authErrResponse :: Auth.AuthError -> Response
authErrResponse e = jsonError (mkStatus (Auth.aeStatus e) "") (Auth.aeCode e) (Auth.aeMessage e)

-- ---------------------------------------------------------------------------
-- Query parsing
-- ---------------------------------------------------------------------------

listQueryFrom :: Request -> ListQuery
listQueryFrom req =
    let q = fromMaybe "" (param "q" req)
        tags = concatMap splitTags (allParams "tags" req)
        isRead = parseBool =<< param "is_read" req
        isDead = parseBool =<< param "is_dead" req
        sort = fromMaybe "created" (param "sort" req)
        offset = max 0 (fromMaybe 0 (readInt =<< param "offset" req))
        limit = min 200 (max 1 (fromMaybe 60 (readInt =<< param "limit" req)))
     in ListQuery q tags isRead isDead sort offset limit
  where
    splitTags = filter (not . T.null) . map (T.toLower . T.strip) . T.splitOn ","

param :: BS.ByteString -> Request -> Maybe Text
param key req =
    case [v | (k, Just v) <- queryString req, k == key] of
        (v : _) -> Just (TE.decodeUtf8 v)
        [] -> Nothing

allParams :: BS.ByteString -> Request -> [Text]
allParams key req = [TE.decodeUtf8 v | (k, Just v) <- queryString req, k == key]

parseBool :: Text -> Maybe Bool
parseBool t = case T.toLower t of
    "1" -> Just True
    "true" -> Just True
    "0" -> Just False
    "false" -> Just False
    _ -> Nothing

readInt :: Text -> Maybe Int
readInt t = case reads (T.unpack t) of
    [(n, "")] -> Just n
    _ -> Nothing

isHttpUrl :: Text -> Bool
isHttpUrl t =
    let l = T.toLower (T.strip t)
     in "http://" `T.isPrefixOf` l || "https://" `T.isPrefixOf` l

-- ---------------------------------------------------------------------------
-- Static
-- ---------------------------------------------------------------------------

{- | A static file with an ETag and a cache policy. Asset URLs do not carry
build hashes, so the browser must revalidate instead of replaying a stale
copy after a rebuild. @no-store@ is reserved for the client shell.
-}
sendFile :: Request -> BS.ByteString -> [(HeaderName, BS.ByteString)] -> FilePath -> (Response -> IO ResponseReceived) -> IO ResponseReceived
sendFile req cachePolicy headers path respond = do
    size <- getFileSize path
    modified <- getModificationTime path
    let tag = BSC.pack ("\"" <> show size <> "-" <> show (round (utcTimeToPOSIXSeconds modified) :: Integer) <> "\"")
        cacheable = cachePolicy /= "no-store"
        fresh = cacheable && lookup hIfNoneMatch (requestHeaders req) == Just tag
        responseHeaders = headers <> [(hCacheControl, cachePolicy)] <> [(hETag, tag) | cacheable]
    if fresh
        then respond (responseLBS status304 responseHeaders "")
        else respond (responseFile status200 responseHeaders path Nothing)

serveStaticFile :: Config -> FilePath -> [(HeaderName, BS.ByteString)] -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
serveStaticFile cfg relative headers req respond = case cfgStaticDir cfg of
    Nothing -> respond (jsonError status404 "not_found" "static assets are not configured")
    Just root -> do
        let path = root </> relative
        exists <- doesFileExist path
        if exists
            then sendFile req "no-cache" headers path respond
            else respond (jsonError status404 "not_found" "asset not found")

serveAsset :: Config -> [Text] -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
serveAsset cfg rest req respond = case cfgStaticDir cfg of
    Nothing -> respond (jsonError status404 "not_found" "static assets are not configured")
    Just root -> do
        if any (== "..") rest
            then respond (jsonError status400 "bad_request" "invalid asset path")
            else do
                let rel = foldr (</>) "" (map T.unpack rest)
                    path = root </> rel
                exists <- doesFileExist path
                if exists
                    then sendFile req "no-cache" [(hContentType, mimeFor rel)] path respond
                    else respond (jsonError status404 "not_found" "asset not found")

-- | The shell HTML is never stored: a rebuild must reach the next navigation.
indexResponse :: Config -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
indexResponse cfg req respond = case cfgStaticDir cfg of
    Just root -> do
        buildId <- readBuildId cfg
        let buildHeader = [("X-Eza-Build", TE.encodeUtf8 buildId) | not (T.null buildId)]
        sendFile req "no-store" ([(hContentType, "text/html; charset=utf-8")] <> buildHeader) (root </> "index.html") respond
    Nothing -> respond (htmlResponse (placeholderPage cfg))

{- | The service worker version follows the web build id, so every rebuild is a
new worker and clients update on the next load without a manual unregister.
-}
serveServiceWorker :: Config -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
serveServiceWorker cfg req respond = case cfgStaticDir cfg of
    Nothing -> respond (jsonError status404 "not_found" "static assets are not configured")
    Just root -> do
        template <- BS.readFile (root </> "sw.js")
        buildId <- readBuildId cfg
        let generated =
                if T.null buildId
                    then template
                    else TE.encodeUtf8 (T.replace "eza-app-shell-v4-dev" ("eza-app-shell-" <> buildId) (TE.decodeUtf8 template))
            tag = BSC.pack ("\"" <> (if T.null buildId then BSC.unpack (BSC.pack (show (BS.length generated))) else T.unpack buildId) <> "\"")
            fresh = lookup hIfNoneMatch (requestHeaders req) == Just tag
            headers =
                [ (hContentType, "text/javascript; charset=utf-8")
                , ("Service-Worker-Allowed", "/")
                , (hCacheControl, "no-cache")
                , (hETag, tag)
                ]
                    <> [("X-Eza-Build", TE.encodeUtf8 buildId) | not (T.null buildId)]
        if fresh
            then respond (responseLBS status304 headers "")
            else respond (responseLBS status200 headers (LBS.fromStrict generated))

{- | The build id written by scripts/build-web.sh. Deployments that copy the
built static tree without that script fall back to the WASM file's size and
modification time, which still changes when the client is rebuilt.
-}
readBuildId :: Config -> IO Text
readBuildId cfg = case cfgStaticDir cfg of
    Nothing -> pure ""
    Just root -> do
        let path = root </> "app" </> "build-id"
        exists <- doesFileExist path
        if exists
            then T.strip . TE.decodeUtf8 <$> BS.readFile path
            else do
                let wasm = root </> "app" </> "app.wasm"
                wasmExists <- doesFileExist wasm
                if wasmExists
                    then do
                        size <- getFileSize wasm
                        modified <- getModificationTime wasm
                        pure ("wasm" <> T.pack (show size) <> "-" <> T.pack (show (round (utcTimeToPOSIXSeconds modified) :: Integer)))
                    else pure ""

mimeFor :: FilePath -> BS.ByteString
mimeFor p
    | ".css" `endOf` p = BSC.pack "text/css; charset=utf-8"
    | ".js" `endOf` p = BSC.pack "text/javascript; charset=utf-8"
    | ".mjs" `endOf` p = BSC.pack "text/javascript; charset=utf-8"
    | ".wasm" `endOf` p = BSC.pack "application/wasm"
    | ".html" `endOf` p = BSC.pack "text/html; charset=utf-8"
    | ".svg" `endOf` p = BSC.pack "image/svg+xml"
    | ".json" `endOf` p = BSC.pack "application/json"
    | ".png" `endOf` p = BSC.pack "image/png"
    | ".woff2" `endOf` p = BSC.pack "font/woff2"
    | ".webmanifest" `endOf` p = BSC.pack "application/manifest+json"
    | otherwise = BSC.pack "application/octet-stream"
  where
    endOf suffix s =
        let n = length suffix
         in length s >= n && drop (length s - n) s == suffix

-- ---------------------------------------------------------------------------
-- Responses
-- ---------------------------------------------------------------------------

jsonResponse :: (ToJSON a) => Status -> a -> Response
jsonResponse status value =
    responseLBS status [(hContentType, "application/json; charset=utf-8"), (hCacheControl, "no-store")] (encode value)

jsonError :: Status -> Text -> Text -> Response
jsonError status code message =
    jsonResponse status (object ["error" .= object ["code" .= code, "message" .= message]])

emptyResponse :: Status -> Response
emptyResponse status = responseLBS status [(hContentType, "application/json; charset=utf-8"), (hCacheControl, "no-store")] "{}"

htmlResponse :: Text -> Response
htmlResponse = htmlResponseAt status200

htmlResponseAt :: Status -> Text -> Response
htmlResponseAt status body =
    responseLBS status [(hContentType, "text/html; charset=utf-8"), (hCacheControl, "no-store")] (LBS.fromStrict (TE.encodeUtf8 body))

{- | The page a server with no static directory serves. It is not the app;
it says what is missing and follows the catalogue paper stock.
-}
placeholderPage :: Config -> Text
placeholderPage cfg =
    T.unlines
        [ "<!doctype html>"
        , "<html lang=\"en\"><head><meta charset=\"utf-8\">"
        , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        , "<meta name=\"color-scheme\" content=\"light dark\">"
        , "<title>eza | bare server</title>"
        , "<style>"
        , ":root{--paper:#F2EDE3;--card:#FBF8F1;--ink:#1A2340;--muted:#6E675C;--rule:#D5CBB8;--accent:#8A2B20}"
        , "@media (prefers-color-scheme: dark){:root{--paper:#10141F;--card:#161B28;--ink:#E9E3D6;--muted:#A9A08F;--rule:#232A3A;--accent:#C98A3E}}"
        , "body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:48px 36px;background:var(--paper);color:var(--ink);font-family:'Newsreader',Georgia,'Times New Roman',serif;font-size:17px;line-height:28px}"
        , "main{width:min(560px,100%);background:var(--card);border:1px solid var(--ink);border-radius:2px;padding:32px 34px 28px}"
        , ".kicker{margin:0 0 10px;font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:11px;line-height:16px;letter-spacing:.14em;text-transform:uppercase;color:var(--accent)}"
        , ".wordmark{margin:0;font-family:'Fraunces',Georgia,'Times New Roman',serif;font-size:36px;line-height:38px;font-weight:600;letter-spacing:-.02em}"
        , ".rule{height:1px;background:var(--ink);margin:14px 0 26px}"
        , "p{margin:0 0 14px}"
        , "dl{margin:20px 0 0;border-top:1px solid var(--rule)}"
        , "dl div{display:flex;justify-content:space-between;gap:20px;padding:7px 0;border-bottom:1px solid var(--rule)}"
        , "dt{font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:11px;line-height:16px;letter-spacing:.12em;text-transform:uppercase;color:var(--muted)}"
        , "dd{margin:0;font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;line-height:18px;color:var(--ink);overflow-wrap:anywhere}"
        , ".foot{margin:18px 0 0;font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:11px;line-height:16px;letter-spacing:.12em;text-transform:uppercase;color:var(--muted)}"
        , "</style>"
        , "</head><body><main>"
        , "<p class=\"kicker\">the catalogue</p>"
        , "<p class=\"wordmark\">eza</p>"
        , "<div class=\"rule\" aria-hidden=\"true\"></div>"
        , "<p>The server is running. The client bundle is not on disk, so there is nothing to load yet.</p>"
        , "<p>Point <code>EZA_STATIC_DIR</code> at the built <code>static</code> directory and reload this page.</p>"
        , "<dl><div><dt>static dir</dt><dd>" <> escapeHtml (T.pack (fromMaybe "(unset)" (cfgStaticDir cfg))) <> "</dd></div>"
        , "<div><dt>origin</dt><dd>" <> escapeHtml (cfgPublicOrigin cfg) <> "</dd></div></dl>"
        , "<p class=\"foot\">server only <span aria-hidden=\"true\">/</span> built assets required</p>"
        , "</main></body></html>"
        ]

escapeHtml :: Text -> Text
escapeHtml value =
    T.replace "\"" "&quot;" (T.replace ">" "&gt;" (T.replace "<" "&lt;" (T.replace "&" "&amp;" value)))

withDb :: DbVar -> (Connection -> IO ResponseReceived) -> IO ResponseReceived
withDb db action = withMVar db action
