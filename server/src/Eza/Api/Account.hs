-- | Account, token, and passkey handlers.
module Eza.Api.Account where

import Control.Monad (void)
import Data.Aeson

import Data.Aeson.Types (parseMaybe)

import Data.Maybe (fromMaybe)

import Data.Text (Text)
import qualified Data.Text as T

import Database.SQLite.Simple (Connection)

import Network.HTTP.Types
import Network.Wai

import Eza.Account (AccountInfo (..))

import qualified Eza.Auth as Auth

import Eza.Config
import Eza.Control (ControlUser (..))
import qualified Eza.Control as Control

import Eza.Password (validatePassword, validateUsername)
import qualified Eza.Password as Password
import Eza.Routes (Route (..))

import Eza.Tokens (createToken, listTokens, revokeToken)

import Eza.Api.Common
import Eza.Api.Context

data TokenCreateBody = TokenCreateBody Text (Maybe [Text])

instance FromJSON TokenCreateBody where
    parseJSON = withObject "TokenCreateBody" $ \o ->
        TokenCreateBody <$> o .: "name" <*> o .:? "scopes"

{- | The account document. @GET /api/v1/account@ and the two-factor toggle
return the same shape, so the account page can replace its copy after a
change without a second request.
-}
accountPayload :: Connection -> AuthContext -> Control.UserRole -> IO Value
accountPayload conn ctx role = do
    creds <- Auth.listCredentials conn
    remaining <- Auth.recoveryCodesRemaining conn
    sessions <- Auth.listSessions conn (case ctx of CookieSession sess -> Just sess; BearerToken _ -> Nothing)
    account <- Auth.loadAccount conn
    configured <- Auth.accountConfigured conn
    pure
        ( toJSON
            AccountInfo
                { aiUsername = Auth.acctUsername account
                , aiRole = role
                , aiHasPassword = Auth.accountHasPassword account
                , aiRequirePasskey = Auth.acctRequirePasskey account
                , aiAccountConfigured = configured
                , aiCredentials = creds
                , aiRecoveryCodesRemaining = remaining
                , aiSessions = sessions
                }
        )

{- | Turn optional passkey two-factor on or off. Both directions need the
current password, and turning it on needs an already-registered passkey.
-}
accountTwoFactorHandler :: Config -> Connection -> AuthContext -> Control.UserRole -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
accountTwoFactorHandler cfg conn ctx role req respond = do
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case parseMaybeObj value of
            Nothing -> respond (jsonProblem status400 "bad_request" "invalid body")
            Just o -> case parseMaybe (.: "required") o :: Maybe Bool of
                Nothing -> respond (jsonProblem status400 "bad_request" "required is required")
                Just required -> do
                    let current = fromMaybe "" (parseMaybe (.: "current_password") o :: Maybe Text)
                    result <- Auth.setTwoFactorRequirement conn (authConfig cfg) required current
                    case result of
                        Left err -> respond (authErrResponse err)
                        Right _ -> do
                            payload <- accountPayload conn ctx role
                            respond (jsonResponse status200 payload)

{- | Change the account password. A current password is required once one
exists; the session vouches for the first password on a legacy passkey-only
account. Other browser sessions are revoked so a stolen session does not keep
the old access.
-}
accountPasswordHandler :: Config -> Connection -> AuthContext -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
accountPasswordHandler cfg conn ctx req respond = do
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case parseMaybeObj value of
            Nothing -> respond (jsonProblem status400 "bad_request" "invalid body")
            Just o -> do
                let current = parseMaybe (.: "current_password") o :: Maybe Text
                    newPassword = parseMaybe (.: "new_password") o :: Maybe Text
                    confirm = parseMaybe (.: "confirm") o :: Maybe Text
                case (newPassword, confirm) of
                    (Just wanted, Just repeated)
                        | wanted /= repeated ->
                            respond (jsonProblem status400 "password_mismatch" "the new passwords do not match")
                        | otherwise -> case validatePassword wanted of
                            Left message -> respond (jsonProblem status400 "weak_password" message)
                            Right () -> do
                                account <- Auth.loadAccount conn
                                authorized <- case current of
                                    Just currentPassword -> Auth.verifyCurrentPassword conn (authConfig cfg) currentPassword
                                    Nothing -> pure (not (Auth.accountHasPassword account))
                                if not authorized
                                    then respond (jsonProblem status403 "invalid_password" "the current password is incorrect")
                                    else
                                        if T.null (Auth.acctUsername account)
                                            then respond (jsonProblem status409 "username_required" "set a username before setting a password")
                                            else do
                                                passwordHash <- Password.hashPassword (cfgArgon2 cfg) wanted
                                                Auth.setAccountPassword conn (Auth.acctUsername account) passwordHash
                                                case ctx of
                                                    CookieSession sess -> void (Auth.deleteOtherSessions conn sess)
                                                    BearerToken _ -> pure ()
                                                respond (jsonResponse status200 (object ["ok" .= True]))
                    _ -> respond (jsonProblem status400 "bad_request" "new_password and confirm are required")

-- | Rename the single account. A password, when set, must be confirmed.

{- | Rename the signed-in account. The control row is the login lookup source,
so it changes with the user database account name.
-}
accountUsernameHandler :: Config -> AppState -> Control.ControlUser -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
accountUsernameHandler cfg state user conn req respond = do
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case parseMaybeObj value of
            Nothing -> respond (jsonProblem status400 "bad_request" "invalid body")
            Just o -> do
                let current = parseMaybe (.: "current_password") o :: Maybe Text
                    wanted = parseMaybe (.: "username") o :: Maybe Text
                case wanted of
                    Nothing -> respond (jsonProblem status400 "bad_request" "username is required")
                    Just rawUsername -> do
                        account <- Auth.loadAccount conn
                        authorized <- case current of
                            Just currentPassword -> Auth.verifyCurrentPassword conn (authConfig cfg) currentPassword
                            Nothing -> pure (not (Auth.accountHasPassword account))
                        if not authorized
                            then respond (jsonProblem status403 "invalid_password" "the current password is incorrect")
                            else case validateUsername rawUsername of
                                Left message -> respond (jsonProblem status400 "invalid_username" message)
                                Right username -> do
                                    renamed <- withControl state $ \control -> Control.setUsername control (cuId user) username
                                    case renamed of
                                        Left Control.ControlDuplicateUsername ->
                                            respond (jsonProblem status409 "username_taken" "that username is already in use")
                                        Left err -> respond (jsonProblem status500 "control" (T.pack (show err)))
                                        Right () -> do
                                            Auth.setAccountUsername conn username
                                            respond (jsonResponse status200 (object ["ok" .= True]))

-- ---------------------------------------------------------------------------
-- Query parsing
-- ---------------------------------------------------------------------------

-- | Dispatch the handlers this family owns from their "Eza.Routes" constructors.
dispatch :: RequestContext -> Connection -> Route -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
dispatch rctx conn route req respond = case route of
    RouteTokenList -> do
        tokens <- listTokens conn
        respond (jsonResponse status200 (object ["tokens" .= tokens]))
    RouteTokenCreate -> do
        body <- jsonValue cfg req
        case body of
            Left response -> respond response
            Right (TokenCreateBody name scopes) -> do
                (_, raw, view) <- createToken conn name (fromMaybe ["read", "write"] scopes)
                respond (jsonResponse status201 (object ["token" .= wireApiToken user raw, "token_info" .= view]))
    RouteTokenRevoke tokenId -> do
        ok <- revokeToken conn tokenId
        if ok then respond (emptyResponse status204) else respond (jsonProblem status404 "not_found" "token not found")
    RouteAccountRead -> do
        payload <- accountPayload conn ctx (Control.cuRole user)
        respond (jsonResponse status200 payload)
    RouteAccountTwoFactor -> accountTwoFactorHandler cfg conn ctx (Control.cuRole user) req respond
    RouteAccountPassword ->
        accountPasswordHandler cfg conn ctx req respond
    RouteAccountUsername ->
        accountUsernameHandler cfg state user conn req respond
    RouteAccountSessionsRevokeOthers -> case ctx of
        CookieSession sess -> do
            revoked <- Auth.deleteOtherSessions conn sess
            respond (jsonResponse status200 (object ["revoked" .= revoked]))
        BearerToken _ -> respond (jsonProblem status403 "session_required" "a bearer token cannot revoke browser sessions")
    RouteAccountPasskeyOptions -> do
        handle <- passkeyHandle state user
        r <- Auth.addPasskeyOptions conn (authConfig cfg) handle
        either (respond . authErrResponse) (respond . jsonResponse status200) r
    RouteAccountPasskeyVerify -> do
        body <- jsonBody cfg req
        case body of
            Left response -> respond response
            Right v -> do
                handle <- passkeyHandle state user
                r <- Auth.verifyAddPasskey conn (authConfig cfg) handle v
                case r of
                    Left e -> respond (authErrResponse e)
                    Right () -> respond (jsonResponse status200 (object ["ok" .= True]))
    RouteAccountPasskeyRename cidTxt ->
        case Auth.decodeCredentialId cidTxt of
            Nothing -> respond (jsonProblem status400 "bad_request" "invalid credential id")
            Just cid -> do
                body <- jsonBody cfg req
                case body of
                    Left response -> respond response
                    Right v -> case parseMaybeObj v of
                        Nothing -> respond (jsonProblem status400 "bad_request" "nickname is required")
                        Just o -> case parseMaybe (.: "nickname") o of
                            Nothing -> respond (jsonProblem status400 "bad_request" "nickname is required")
                            Just nick -> do
                                ok <- Auth.renameCredential conn cid nick
                                if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonProblem status404 "not_found" "passkey not found")
    RouteAccountPasskeyDelete cidTxt ->
        case Auth.decodeCredentialId cidTxt of
            Nothing -> respond (jsonProblem status400 "bad_request" "invalid credential id")
            Just cid -> do
                r <- Auth.deleteCredential conn cid
                either (respond . authErrResponse) (const (respond (emptyResponse status204))) r
    RouteAccountRecoveryRegenerate -> do
        codes <- Auth.regenerateRecoveryCodes conn
        respond (jsonResponse status200 (object ["codes" .= codes]))
    _ -> respond (jsonProblem status500 "internal_error" "route has no handler")
  where
    cfg = rcConfig rctx
    state = rcState rctx
    user = rcUser rctx
    ctx = rcAuth rctx

-- | The "Eza.Routes" constructors this family handles.
owns :: Route -> Bool
owns route = case route of
    RouteTokenList -> True
    RouteTokenCreate -> True
    RouteTokenRevoke _ -> True
    RouteAccountRead -> True
    RouteAccountTwoFactor -> True
    RouteAccountPassword -> True
    RouteAccountUsername -> True
    RouteAccountSessionsRevokeOthers -> True
    RouteAccountPasskeyOptions -> True
    RouteAccountPasskeyVerify -> True
    RouteAccountPasskeyRename _ -> True
    RouteAccountPasskeyDelete _ -> True
    RouteAccountRecoveryRegenerate -> True
    _ -> False
