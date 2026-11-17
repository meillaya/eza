{-# LANGUAGE OverloadedStrings #-}

{- | The own-library job routes: @GET /api/v1/jobs/{id}@ returns one job's
status and @POST /api/v1/jobs/{id}/cancel@ requests its cancellation. Each
library database holds only its own jobs, so an id from another account is a 404
here, never a 403 and never a leak.
-}
module Eza.Api.Jobs (owns, dispatch) where

import Data.Aeson (Value (..), object, (.=))
import Data.Maybe (fromMaybe)
import Database.SQLite.Simple (Connection)
import Network.HTTP.Types (status200, status404, status409)
import Network.Wai (Request, Response, ResponseReceived)

import Eza.Jobs (JobView (..), getJobView, requestJobCancel)
import Eza.Routes (Route (..))

import Eza.Api.Common (jsonProblem, jsonResponse)
import Eza.Api.Context (RequestContext)

-- | The "Eza.Routes" constructors this family handles.
owns :: Route -> Bool
owns route = case route of
    RouteJobStatus _ -> True
    RouteJobCancel _ -> True
    _ -> False

dispatch :: RequestContext -> Connection -> Route -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
dispatch _rctx conn route _req respond = case route of
    RouteJobStatus jobId -> do
        view <- getJobView conn jobId
        case view of
            Nothing -> respond (jsonProblem status404 "not_found" "job not found")
            Just job -> respond (jsonResponse status200 (jobStatusJson job))
    RouteJobCancel jobId -> do
        -- The job id is resolved in the caller's own library first (the
        -- connection is that library), so another account's id is a plain 404.
        -- requestJobCancel marks a queued/running row cancelled immediately and
        -- keeps the durable cancel_requested flag; a worker already running the
        -- job discards its late result.
        cancelled <- requestJobCancel conn jobId
        view <- getJobView conn jobId
        case view of
            Nothing -> respond (jsonProblem status404 "not_found" "job not found")
            Just job
                | cancelled || jvState job == "cancelled" ->
                    respond (jsonResponse status200 (jobStatusJson job))
                | otherwise ->
                    respond (jsonProblem status409 "not_cancellable" "job is already finished")
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
