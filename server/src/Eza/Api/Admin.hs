-- | Admin account management handlers.
module Eza.Api.Admin where

import Data.Aeson

import Data.Aeson.Types (parseMaybe)

import Data.Maybe (fromMaybe)

import qualified Data.Text as T

import Database.SQLite.Simple (Connection)

import Network.HTTP.Types
import Network.Wai

import qualified Eza.Admin as Admin

import Eza.Control (ControlUser (..))
import qualified Eza.Control as Control

import Eza.Routes (Route (..))

import Eza.User (UserCreateInput (..), UserCreateResult (..), UserRole (..))

import Eza.Api.Common
import Eza.Api.Context

adminListUsers :: AppState -> (Response -> IO ResponseReceived) -> IO ResponseReceived
adminListUsers state respond = do
    users <- withControl state Control.listUsers
    respond (jsonResponse status200 (object ["users" .= map Admin.controlUserView users]))

adminCreateUser :: AppState -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
adminCreateUser state req respond = do
    let cfg = asConfig state
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case fromJSON value :: Result UserCreateInput of
            Error message -> respond (jsonProblem status400 "bad_request" (T.pack message))
            Success input -> do
                created <-
                    withControl state $ \control ->
                        Admin.createUserAccount (asConfig state) control (uciUsername input) (uciRole input) (uciPassword input)
                case created of
                    Left err -> respondProblem respond (Admin.toProblem err)
                    Right (user, codes) ->
                        respond (jsonResponse status201 (UserCreateResult (Admin.controlUserView user) codes))

adminPatchUser ::
    AppState ->
    Control.ControlUser ->
    Int ->
    Request ->
    (Response -> IO ResponseReceived) ->
    IO ResponseReceived
adminPatchUser state admin targetId req respond = do
    let cfg = asConfig state
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case parseMaybeObj value of
            Nothing -> respond (jsonProblem status400 "bad_request" "invalid body")
            Just object' -> do
                let wantedEnabled = parseMaybe (.: "enabled") object' :: Maybe Bool
                    wantedRole = parseMaybe (.: "role") object' :: Maybe UserRole
                case (wantedEnabled, wantedRole) of
                    (Nothing, Nothing) ->
                        respond (jsonProblem status400 "bad_request" "enabled or role is required")
                    _
                        | wantedEnabled == Just False && targetId == cuId admin ->
                            respondProblem respond (Admin.toProblem Admin.AdminSelfDisable)
                    _ -> do
                        roleResult <-
                            case wantedRole of
                                Nothing -> pure (Right Nothing)
                                Just role -> do
                                    applied <- withControl state $ \control -> Admin.setUserRole control targetId role
                                    pure (fmap Just applied)
                        case roleResult of
                            Left err -> respondProblem respond (Admin.toProblem err)
                            Right _ -> do
                                enabledResult <-
                                    case wantedEnabled of
                                        Nothing -> pure (Right Nothing)
                                        Just enabled -> do
                                            applied <-
                                                withControl state $ \control ->
                                                    Admin.setUserEnabled (asConfig state) control targetId enabled
                                            pure (fmap Just applied)
                                case enabledResult of
                                    Left err -> respondProblem respond (Admin.toProblem err)
                                    Right _ -> do
                                        updated <- withControl state $ \control -> Control.lookupUserById control targetId
                                        case updated of
                                            Nothing -> respondProblem respond (Admin.toProblem Admin.AdminNotFound)
                                            Just user -> respond (jsonResponse status200 (Admin.controlUserView user))

adminResetPassword :: AppState -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
adminResetPassword state targetId req respond = do
    let cfg = asConfig state
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case parseMaybeObj value of
            Nothing -> respond (jsonProblem status400 "bad_request" "invalid body")
            Just object' -> case parseMaybe (.: "password") object' of
                Nothing -> respond (jsonProblem status400 "bad_request" "password is required")
                Just password -> do
                    result <-
                        withControl state $ \control ->
                            Admin.resetUserPassword (asConfig state) control targetId password
                    case result of
                        Left err -> respondProblem respond (Admin.toProblem err)
                        Right () -> respond (jsonResponse status200 (object ["ok" .= True]))

{- | Delete one account. The control row always goes; the library and its
snapshots go only when @delete_db@ is true, because they are the user's
content. Refuses self-delete and the last enabled admin.
-}
adminDeleteUser :: AppState -> Control.ControlUser -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
adminDeleteUser state admin targetId req respond = do
    body <- jsonBody (asConfig state) req
    case body of
        Left response -> respond response
        Right value -> case parseMaybeObj value of
            Nothing -> respond (jsonProblem status400 "bad_request" "invalid body")
            Just o -> do
                let confirmed = parseMaybe (.: "confirm") o :: Maybe Bool
                    deleteDb = fromMaybe False (parseMaybe (.: "delete_db") o :: Maybe Bool)
                if confirmed /= Just True
                    then respond (jsonProblem status400 "bad_request" "confirm must be true")
                    else
                        if targetId == Control.cuId admin
                            then respondProblem respond (Admin.toProblem Admin.AdminSelfDisable)
                            else do
                                result <-
                                    withControl state $ \control ->
                                        Admin.deleteUserAccount (asConfig state) control targetId deleteDb
                                case result of
                                    Left err -> respondProblem respond (Admin.toProblem err)
                                    Right () -> respond (jsonResponse status200 (object ["ok" .= True]))

-- ---------------------------------------------------------------------------
-- Account handlers
-- ---------------------------------------------------------------------------

-- | Dispatch the handlers this family owns from their "Eza.Routes" constructors.
dispatch :: RequestContext -> Connection -> Route -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
dispatch rctx _conn route req respond = case route of
    RouteAdminUserList -> adminListUsers state respond
    RouteAdminUserCreate -> adminCreateUser state req respond
    RouteAdminUserUpdate userId -> adminPatchUser state user userId req respond
    RouteAdminUserPassword userId -> adminResetPassword state userId req respond
    RouteAdminUserDelete userId -> adminDeleteUser state user userId req respond
    _ -> respond (jsonProblem status500 "internal_error" "route has no handler")
  where
    state = rcState rctx
    user = rcUser rctx

-- | The "Eza.Routes" constructors this family handles.
owns :: Route -> Bool
owns route = case route of
    RouteAdminUserList -> True
    RouteAdminUserCreate -> True
    RouteAdminUserUpdate _ -> True
    RouteAdminUserPassword _ -> True
    RouteAdminUserDelete _ -> True
    _ -> False
