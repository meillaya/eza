-- | Tag listing, suggestions, consolidation, apply/merge, rename, and delete handlers.
module Eza.Api.Tags where

import Data.Aeson

import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)

import qualified Data.Text as T

import Database.SQLite.Simple (Connection)

import Network.HTTP.Types
import Network.Wai

import Eza.Jobs (enqueueTrackedJob)

import Eza.Bookmarks

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
                Nothing -> respond (jsonProblem status400 "bad_request" "invalid body")
                Just o -> case (parseMaybe (.: "bookmark_id") o, parseMaybe (.: "tags") o) of
                    (Just bid, Just tags) -> do
                        n <- addTagsToBookmark conn bid tags
                        respond (jsonResponse status200 (object ["updated" .= n]))
                    _ -> respond (jsonProblem status400 "bad_request" "bookmark_id and tags are required")
    RouteTagMerge -> do
        body <- jsonBody cfg req
        case body of
            Left response -> respond response
            Right v -> case parseMaybeObj v of
                Nothing -> respond (jsonProblem status400 "bad_request" "invalid body")
                Just o -> case (parseMaybe (.: "from") o, parseMaybe (.: "into") o) of
                    (Just froms, Just into) -> do
                        n <- mergeTags conn froms into
                        respond (jsonResponse status200 (object ["updated" .= n]))
                    _ -> respond (jsonProblem status400 "bad_request" "from and into are required")
    RouteAiSuggestions -> do
        body <- jsonBody cfg req
        case body of
            Left response -> respond response
            Right v -> do
                let rawTag = parseMaybeObj v >>= \o -> parseMaybe (.: "tag") o :: Maybe T.Text
                    tag = fromMaybe "" rawTag
                    scope = if T.null (T.strip tag) then "all" else T.strip tag
                    payload =
                        if T.null (T.strip tag)
                            then object []
                            else object ["tag" .= T.strip tag]
                jobId <- enqueueTrackedJob conn "ai_suggestions" scope payload
                respond (jsonResponse status202 (object ["job_id" .= jobId]))
    RouteTagRename segments -> do
        let tagName = T.intercalate "/" segments
        body <- jsonBody cfg req
        case body of
            Left response -> respond response
            Right v -> case parseMaybeObj v of
                Nothing -> respond (jsonProblem status400 "bad_request" "invalid body")
                Just o -> case parseMaybe (.: "name") o of
                    Nothing -> respond (jsonProblem status400 "bad_request" "name is required")
                    Just newName -> do
                        ok <- renameTag conn tagName newName
                        if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonProblem status409 "conflict" "tag rename failed")
    RouteTagDelete segments -> do
        let tagName = T.intercalate "/" segments
            detach = parseBool =<< param "detach" req
        ok <- if detach == Just True then deleteTagWithLinks conn tagName else deleteTag conn tagName
        if ok then respond (emptyResponse status204) else respond (jsonProblem status409 "conflict" "tag is not empty or does not exist")
    _ -> respond (jsonProblem status500 "internal_error" "route has no handler")
  where
    cfg = rcConfig rctx

-- | The "Eza.Routes" constructors this family handles.
owns :: Route -> Bool
owns route = case route of
    RouteTags -> True
    RouteTagConsolidationCandidates -> True
    RouteTagApply -> True
    RouteTagMerge -> True
    RouteAiSuggestions -> True
    RouteTagRename _ -> True
    RouteTagDelete _ -> True
    _ -> False

-- build probe
