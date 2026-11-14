-- | Tag listing, suggestions, consolidation, apply/merge, rename, and delete handlers.
module Eza.Api.Tags where

import Data.Aeson

import Data.Aeson.Types (parseMaybe)

import qualified Data.Text as T

import Database.SQLite.Simple (Connection, Only (..), query)

import Network.HTTP.Types
import Network.Wai

import Eza.AiTag (aiSuggestions)

import Eza.Bookmarks

import Eza.Config

import Eza.Routes (Route (..))

import Eza.Tags (consolidationCandidates, deleteTag, deleteTagWithLinks, mergeTags, renameTag)

import Eza.Api.Common
import Eza.Api.Context

-- | Dispatch the handlers this family owns from their "Eza.Routes" constructors.
dispatch :: RequestContext -> Connection -> Route -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
dispatch rctx conn route req respond = case route of
    RouteTags -> do
        tags <- allTags conn
        respond (jsonResponse status200 (object ["tags" .= tags]))
    RouteTagConsolidationCandidates -> do
        report <- consolidationCandidates conn
        respond (jsonResponse status200 report)
    RouteTagApply -> do
        body <- jsonBody cfg req
        case body of
            Left response -> respond response
            Right v -> case parseMaybeObj v of
                Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                Just o -> case (parseMaybe (.: "bookmark_id") o, parseMaybe (.: "tags") o) of
                    (Just bid, Just tags) -> do
                        n <- addTagsToBookmark conn bid tags
                        respond (jsonResponse status200 (object ["updated" .= n]))
                    _ -> respond (jsonError status400 "bad_request" "bookmark_id and tags are required")
    RouteTagMerge -> do
        body <- jsonBody cfg req
        case body of
            Left response -> respond response
            Right v -> case parseMaybeObj v of
                Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                Just o -> case (parseMaybe (.: "from") o, parseMaybe (.: "into") o) of
                    (Just froms, Just into) -> do
                        n <- mergeTags conn froms into
                        respond (jsonResponse status200 (object ["updated" .= n]))
                    _ -> respond (jsonError status400 "bad_request" "from and into are required")
    RouteTagSuggestions tag -> do
        r <- aiSuggestions (T.pack (cfgAiProvider cfg)) (T.pack (cfgAiModel cfg)) (T.pack (cfgOllamaBaseUrl cfg)) conn tag 20
        case r of
            Left notice ->
                respond
                    ( jsonResponse
                        status200
                        (object ["suggestions" .= ([] :: [Value]), "configured" .= False, "notice" .= notice])
                    )
            Right suggestions -> respond (jsonResponse status200 (object ["suggestions" .= suggestions]))
    RouteTagRename segments -> do
        let tagName = T.intercalate "/" segments
        body <- jsonBody cfg req
        case body of
            Left response -> respond response
            Right v -> case parseMaybeObj v of
                Nothing -> respond (jsonError status400 "bad_request" "invalid body")
                Just o -> case parseMaybe (.: "name") o of
                    Nothing -> respond (jsonError status400 "bad_request" "name is required")
                    Just newName -> do
                        ok <- renameTag conn tagName newName
                        if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonError status409 "conflict" "tag rename failed")
    RouteTagDelete segments -> do
        let tagName = T.intercalate "/" segments
            detach = parseBool =<< param "detach" req
        ok <- if detach == Just True then deleteTagWithLinks conn tagName else deleteTag conn tagName
        if ok then respond (emptyResponse status204) else respond (jsonError status409 "conflict" "tag is not empty or does not exist")
    _ -> respond (jsonError status500 "internal_error" "route has no handler")
  where
    cfg = rcConfig rctx

-- | The "Eza.Routes" constructors this family handles.
owns :: Route -> Bool
owns route = case route of
    RouteTags -> True
    RouteTagConsolidationCandidates -> True
    RouteTagApply -> True
    RouteTagMerge -> True
    RouteTagSuggestions _ -> True
    RouteTagRename _ -> True
    RouteTagDelete _ -> True
    _ -> False

-- build probe
