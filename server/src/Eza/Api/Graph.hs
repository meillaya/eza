-- | The graph payload and graph-layout endpoints, plus view documents.
module Eza.Api.Graph where

import Control.Concurrent.MVar

import Data.Aeson

import Data.Maybe (catMaybes, fromMaybe, isNothing, mapMaybe)

import Data.Text (Text)
import qualified Data.Text as T

import Database.SQLite.Simple (Connection, Only (..), query)

import Network.HTTP.Types
import Network.Wai

import Eza.Config

import Eza.Graph (globalGraph, graphLayoutPayload, graphRevision, layoutPresetFromText, lookupCachedLayout, storeCachedLayout)

import qualified Eza.Library as Library

import Eza.Routes (Route (..))

import Eza.Types

import Eza.View (ViewInput (..))
import Eza.Views (ViewError, ViewPatch (..), createView, deleteView, getView, listViews, updateView, viewErrorCode, viewErrorMessage, viewErrorStatus)

import Eza.Api.Common
import Eza.Api.Context

{- | @GET /api/v1/graph/layout?preset=...@. The positions are built from the
same graph data the graph endpoint returns and cached per database until the
revision changes, so switching presets after the first load is a map lookup.
-}
graphLayoutHandler :: UserSlot -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
graphLayoutHandler slot conn req respond =
    case layoutPresetFromText (fromMaybe "standard" (param "preset" req)) of
        Nothing ->
            respond (jsonError status400 "bad_request" "preset must be compact, standard, or airy")
        Just preset -> do
            revision <- graphRevision conn
            let cacheVar = Library.libraryLayoutCache (usLibrary slot)
            cached <- withMVar cacheVar $ \cache -> pure (lookupCachedLayout revision preset cache)
            payload <- case cached of
                Just hit -> pure hit
                Nothing -> do
                    graph <- globalGraph conn
                    let built = graphLayoutPayload preset graph
                    modifyMVar_ cacheVar $ \cache ->
                        pure (storeCachedLayout (gdRevision graph) preset built cache)
                    pure built
            respond (jsonResponse status200 payload)

viewsCreateHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
viewsCreateHandler cfg conn req respond = do
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case fromJSON value :: Result ViewInput of
            Error message -> respond (jsonError status400 "bad_request" (T.pack message))
            Success input -> do
                result <- createView conn input
                case result of
                    Left err -> respond (viewErrorResponse err)
                    Right view -> respond (jsonResponse status201 view)

viewsUpdateHandler :: Config -> Connection -> Text -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
viewsUpdateHandler cfg conn viewSlug req respond = do
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case fromJSON value :: Result ViewPatch of
            Error message -> respond (jsonError status400 "bad_request" (T.pack message))
            Success patch -> do
                result <- updateView conn viewSlug patch
                case result of
                    Left err -> respond (viewErrorResponse err)
                    Right view -> respond (jsonResponse status200 view)

viewErrorResponse :: ViewError -> Response
viewErrorResponse err =
    jsonError (mkStatus (viewErrorStatus err) "") (viewErrorCode err) (viewErrorMessage err)

-- ---------------------------------------------------------------------------
-- Webhooks
-- ---------------------------------------------------------------------------

-- | Dispatch the handlers this family owns from their "Eza.Routes" constructors.
dispatch :: RequestContext -> Connection -> Route -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
dispatch rctx conn route req respond = case route of
    RouteGraph -> do
        graph <- globalGraph conn
        respond (jsonResponse status200 graph)
    RouteGraphLayout ->
        graphLayoutHandler slot conn req respond
    _ -> respond (jsonError status500 "internal_error" "route has no handler")
  where
    slot = rcSlot rctx

-- | The "Eza.Routes" constructors this family handles.
owns :: Route -> Bool
owns route = case route of
    RouteGraph -> True
    RouteGraphLayout -> True
    _ -> False
