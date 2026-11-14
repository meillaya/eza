{-# LANGUAGE OverloadedStrings #-}

{- | @GET /api/v1/jobs/{id}@: the own-library status of one durable job. Each
library database holds only its own jobs, so an id from another account is a
404 here, never a 403 and never a leak.
-}
module Eza.Api.Jobs (owns, dispatch) where

import Data.Aeson (Value (..), object, (.=))
import Data.Maybe (fromMaybe)
import Database.SQLite.Simple (Connection)
import Network.HTTP.Types (status200, status404)
import Network.Wai (Request, Response, ResponseReceived)

import Eza.Jobs (JobView (..), getJobView)
import Eza.Routes (Route (..))

import Eza.Api.Common (jsonProblem, jsonResponse)
import Eza.Api.Context (RequestContext)

-- | The "Eza.Routes" constructors this family handles.
owns :: Route -> Bool
owns route = case route of
    RouteJobStatus _ -> True
    _ -> False

dispatch :: RequestContext -> Connection -> Route -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
dispatch _rctx conn route _req respond = case route of
    RouteJobStatus jobId -> do
        view <- getJobView conn jobId
        case view of
            Nothing -> respond (jsonProblem status404 "not_found" "job not found")
            Just job -> respond (jsonResponse status200 (jobStatusJson job))
    _ -> respond (jsonProblem status404 "not_found" "No such route")

jobStatusJson :: JobView -> Value
jobStatusJson job =
    object
        [ "id" .= jvId job
        , "kind" .= jvKind job
        , "state" .= jvState job
        , "attempts" .= jvAttempts job
        , "result" .= fromMaybe Null (jvResult job)
        , "error" .= maybe Null String (jvError job)
        ]
