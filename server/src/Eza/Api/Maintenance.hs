-- | Saved searches, dedup, dead-link/prune maintenance, undo, import, export, stats, and AI status.
module Eza.Api.Maintenance where

import Control.Exception (IOException, SomeException, bracket, bracket_, onException, throwIO, try)

import Data.Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString as BS

import qualified Data.ByteString.Lazy as LBS

import Data.Int (Int64)

import Data.Maybe (catMaybes, fromMaybe, isNothing, mapMaybe)

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Database.SQLite.Simple (Connection, Only (..), query)

import Network.HTTP.Types
import Network.Wai

import System.Environment (lookupEnv)

import Eza.Ai (AiStatus (..))
import Eza.AiTag (resolveAiModel)

import Eza.Bookmarks

import Eza.Config

import qualified Eza.Db as Db
import Eza.DeadLinks (checkDead)
import Eza.Dedup (DedupQuery (..), dedupCandidates, mergeBookmarksWithSnapshot, mergeUrlDuplicatesAll)

import Eza.Export (exportBookmarks)

import Eza.Import (defaultImportOptions, importParsed, parseNetscape)
import Eza.JsonExport (JsonImportReport (..), exportJson, importJson)

import Eza.Routes (Route (..))

import Eza.SavedSearches (createSavedSearch, deleteSavedSearch, listSavedSearches)

import Eza.Types
import Eza.Undo (UndoFailure (..), listUndoEntries, undoById, undoLast, undoPreview)

import Eza.Api.Common
import Eza.Api.Context
import Network.Wai.Parse (File, FileInfo (..), Param, defaultParseRequestBodyOptions, lbsBackEnd, parseRequestBodyEx, setMaxRequestFileSize, setMaxRequestFilesSize, setMaxRequestNumFiles, setMaxRequestParmsSize)

importHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
importHandler cfg conn req respond =
    case lookup hContentType (requestHeaders req) of
        Just contentType | "application/json" `BS.isPrefixOf` contentType -> importJsonBody
        _ -> importMultipart
  where
    importLimit = fromIntegral (cfgImportMaxBytes cfg) :: Int64
    options =
        setMaxRequestNumFiles 1
            . setMaxRequestParmsSize (cfgImportMaxBytes cfg)
            . setMaxRequestFilesSize importLimit
            . setMaxRequestFileSize importLimit
            $ defaultParseRequestBodyOptions

    -- A JSON body is an eza export (the browser-clipper upload path and the
    -- documented portable backup). It answers with the Netscape report shape so
    -- the account import panel can show one result format for both sources.
    importJsonBody = do
        -- The JSON-body variant of the portable-backup import gets the same
        -- EZA_IMPORT_MAX_BYTES cap the multipart parser and the middleware use.
        body <- jsonBodyTo (cfgImportMaxBytes cfg) req
        case body of
            Left response -> respond response
            Right value -> do
                result <- importJson conn value
                case result of
                    Left message -> respond (jsonError status400 "bad_request" message)
                    Right report ->
                        respond
                            ( jsonResponse
                                status200
                                ( object
                                    [ "format" .= ("eza-json" :: Text)
                                    , "json_report" .= report
                                    , "imported" .= jrBookmarks report
                                    , "inserted" .= jrBookmarks report
                                    , "found" .= jrBookmarks report
                                    , "existing" .= (0 :: Int)
                                    , "highlights" .= jrHighlights report
                                    , "captures" .= jrCaptures report
                                    , "views" .= jrViews report
                                    , "clip_templates" .= jrTemplates report
                                    , "skipped" .= jrSkipped report
                                    ]
                                )
                            )

    importMultipart = do
        parsed <- try (parseRequestBodyEx options lbsBackEnd req) :: IO (Either SomeException ([Param], [File LBS.ByteString]))
        case parsed of
            Left _ ->
                -- The wai parser throws when a file or parameter grows past the
                -- configured multipart limits; report it as the same 413 the
                -- size middleware uses rather than a 500.
                respond (requestTooLargeResponse (fromIntegral (cfgImportMaxBytes cfg)))
            Right (_, files) -> case lookup "file" files of
                Nothing -> respond (jsonError status400 "bad_request" "multipart field \"file\" is required")
                Just fileInfo -> do
                    let raw = LBS.toStrict (fileContent fileInfo)
                        -- The account panel uploads .html and .json files under
                        -- the same multipart flow; sniff the JSON format rather
                        -- than relying on the browser's content type.
                        asJson = eitherDecodeStrict' raw :: Either String Value
                    case asJson of
                        Right value | isEzaJsonExport value -> do
                            result <- importJson conn value
                            case result of
                                Left message -> respond (jsonError status400 "bad_request" message)
                                Right report ->
                                    respond
                                        ( jsonResponse
                                            status200
                                            ( object
                                                [ "format" .= ("eza-json" :: Text)
                                                , "json_report" .= report
                                                , "imported" .= jrBookmarks report
                                                , "inserted" .= jrBookmarks report
                                                , "found" .= jrBookmarks report
                                                , "existing" .= (0 :: Int)
                                                , "highlights" .= jrHighlights report
                                                , "captures" .= jrCaptures report
                                                , "views" .= jrViews report
                                                , "clip_templates" .= jrTemplates report
                                                , "skipped" .= jrSkipped report
                                                ]
                                            )
                                        )
                        _ -> do
                            let parsedBookmarks = parseNetscape defaultImportOptions raw
                            report <- importParsed conn defaultImportOptions parsedBookmarks
                            respond (jsonResponse status200 report)

-- | True when the decoded document announces the eza JSON export format.
isEzaJsonExport :: Value -> Bool
isEzaJsonExport (Object o) = case KeyMap.lookup "format" o of
    Just (String "eza-json") -> True
    _ -> False
isEzaJsonExport _ = False

-- | Dispatch the handlers this family owns from their "Eza.Routes" constructors.
dispatch :: RequestContext -> Connection -> Route -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
dispatch rctx conn route req respond = case route of
    RouteSavedSearchList -> do
        s <- listSavedSearches conn
        respond (jsonResponse status200 (object ["saved_searches" .= s]))
    RouteSavedSearchCreate -> do
        body <- jsonBody cfg req
        case body of
            Left response -> respond response
            Right v -> case parseMaybeObj v of
                Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                Just o -> case (parseMaybe (.: "name") o, parseMaybe (.: "q") o, parseMaybe (.: "tags") o) of
                    (Just name, q, tags) -> do
                        sid <- createSavedSearch conn name (fromMaybe "" q) (fromMaybe [] tags)
                        respond (jsonResponse status201 (object ["id" .= sid]))
                    _ -> respond (jsonError status400 "bad_request" "name is required")
    RouteSavedSearchDelete savedSearchId -> do
        ok <- deleteSavedSearch conn savedSearchId
        if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "saved search not found")
    RouteDedupCandidates -> do
        report <- dedupCandidates conn (dedupQueryFrom req)
        respond (jsonResponse status200 report)
    RouteDedupMergeAll -> do
        body <- jsonBody cfg req
        case body of
            Left response -> respond response
            Right v -> case parseMaybeObj v of
                Just o
                    | (parseMaybe (.: "confirm") o :: Maybe Bool) == Just True -> do
                        report <- mergeUrlDuplicatesAll conn
                        respond (jsonResponse status200 report)
                _ -> respond (jsonError status400 "bad_request" "confirm is required")
    RouteDedupMerge -> do
        body <- jsonBody cfg req
        case body of
            Left response -> respond response
            Right v -> case parseMaybeObj v of
                Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                Just o -> case (parseMaybe (.: "keep_id") o, parseMaybe (.: "merge_ids") o) of
                    (Just keep, Just ms) -> do
                        (n, snapshotId) <- mergeBookmarksWithSnapshot conn keep ms
                        respond (jsonResponse status200 (object ["merged" .= n, "snapshot_id" .= snapshotId]))
                    _ -> respond (jsonError status400 "bad_request" "keep_id and merge_ids are required")
    RouteMaintenanceCheckDead -> do
        body <- jsonBody cfg req
        case body of
            Left response -> respond response
            Right v -> do
                let o = fromMaybe mempty (parseMaybeObj v) :: Object
                    limit = fromMaybe 500 (parseMaybe (.: "limit") o :: Maybe Int)
                    older = fromMaybe 0 (parseMaybe (.: "older_than") o :: Maybe Int)
                    includeDead = fromMaybe False (parseMaybe (.: "include_dead") o :: Maybe Bool)
                (checked, dead, alive, totalDead) <- checkDead conn limit older includeDead
                respond (jsonResponse status200 (object ["checked" .= checked, "dead" .= dead, "alive" .= alive, "total_dead" .= totalDead]))
    RouteMaintenancePruneCandidates -> do
        items <- pruneCandidates conn 365
        respond (jsonResponse status200 (object ["items" .= items]))
    RouteMaintenancePrune -> do
        body <- jsonBody cfg req
        case body of
            Left response -> respond response
            Right v -> case parseMaybeObj v of
                Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                Just o -> case parseMaybe (.: "ids") o :: Maybe [Int] of
                    Nothing -> respond (jsonError status400 "bad_request" "ids is required")
                    Just ids -> do
                        n <- pruneApply conn ids
                        respond (jsonResponse status200 (object ["pruned" .= n]))
    RouteUndoList -> do
        let limit = fromMaybe 5 (param "limit" req >>= readInt)
        entries <- listUndoEntries conn limit
        respond (jsonResponse status200 (object ["entries" .= entries]))
    RouteUndoPreview snapshotId -> do
        preview <- undoPreview conn snapshotId
        case preview of
            Nothing -> respond (jsonError status404 "not_found" "undo snapshot not found")
            Just value -> respond (jsonResponse status200 value)
    RouteUndoApply -> do
        raw <- readBodyBoundedTo (cfgMaxBodyBytes cfg) req
        case raw of
            Left response -> respond response
            Right body
                | LBS.null body -> do
                    n <- undoLast conn
                    respond (jsonResponse status200 (object ["restored" .= n]))
                | otherwise -> case eitherDecode body of
                    Left err -> respond (jsonError status400 "bad_request" (T.pack err))
                    Right value -> case (parseMaybe (.: "snapshot_id") value :: Maybe Int) of
                        Nothing -> do
                            n <- undoLast conn
                            respond (jsonResponse status200 (object ["restored" .= n]))
                        Just snapshotId -> do
                            result <- undoById conn snapshotId
                            case result of
                                Left UndoNotFound -> respond (jsonError status404 "not_found" "undo snapshot not found")
                                Left UndoNotNewest -> respond (jsonError status409 "undo_out_of_order" "Undo the newer actions first")
                                Right undoResult -> respond (jsonResponse status200 undoResult)
    RouteImport -> importHandler cfg conn req respond
    RouteImportJson -> do
        body <- jsonBodyTo (cfgImportMaxBytes cfg) req
        case body of
            Left response -> respond response
            Right value -> do
                result <- importJson conn value
                case result of
                    Left err -> respond (jsonError status400 "bad_request" err)
                    Right report -> respond (jsonResponse status200 report)
    RouteExport ->
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
    RouteExportNotes ->
        respond (jsonError status501 "not_implemented" "Markdown note export is coming in a later milestone")
    RouteStats -> do
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
    RouteAiStatus -> do
        let provider = cfgAiProvider cfg
            model = resolveAiModel (T.pack provider) (T.pack (cfgAiModel cfg))
        key <-
            case provider of
                "ollama" -> pure (Just "")
                "openai" -> lookupEnv "OPENAI_API_KEY"
                "openai-compatible" -> lookupEnv "OPENAI_API_KEY"
                "none" -> pure Nothing
                _ -> lookupEnv "ANTHROPIC_API_KEY"
        let configured = provider /= "none" && maybe False (not . null) key
        respond
            ( jsonResponse
                status200
                AiStatus
                    { asProvider = T.pack provider
                    , asModel = model
                    , asConfigured = configured
                    }
            )
    _ -> respond (jsonError status500 "internal_error" "route has no handler")
  where
    cfg = rcConfig rctx

-- | The "Eza.Routes" constructors this family handles.
owns :: Route -> Bool
owns route = case route of
    RouteSavedSearchList -> True
    RouteSavedSearchCreate -> True
    RouteSavedSearchDelete _ -> True
    RouteDedupCandidates -> True
    RouteDedupMergeAll -> True
    RouteDedupMerge -> True
    RouteMaintenanceCheckDead -> True
    RouteMaintenancePruneCandidates -> True
    RouteMaintenancePrune -> True
    RouteUndoList -> True
    RouteUndoPreview _ -> True
    RouteUndoApply -> True
    RouteImport -> True
    RouteImportJson -> True
    RouteExport -> True
    RouteExportNotes -> True
    RouteStats -> True
    RouteAiStatus -> True
    _ -> False
