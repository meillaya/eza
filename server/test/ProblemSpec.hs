{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-deprecations #-}

{- | The one error path: every failure answers the core "Eza.Problem" wire body
@{"error":{"code","message"}}@ with its documented status, the six feature error
ADTs keep their codes and messages, the 404/405 dispatch answers stay JSON, and
the catch-all middleware converts uncaught exceptions into JSON instead of
Warp's text/plain 500.
-}
module ProblemSpec (spec) where

import Control.Concurrent.MVar (modifyMVar_, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, throwIO, toException)
import Data.Aeson (Value (..), decode, encode, object, (.=))
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import Data.ByteString.Builder (toLazyByteString)
import qualified Data.ByteString.Lazy as LBS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple (Error (..), SQLError (..))
import qualified Database.SQLite.Simple as Sqlite
import Network.HTTP.Types (HeaderName, http11, mkStatus)
import Network.Socket (SockAddr (..))
import Network.Wai (Application, RequestBodyLength (..), responseStatus, responseToStream)
import Network.Wai.Internal (Request (..), Response (..))
import Test.Hspec

import Eza.Api.Common (catchAllMiddleware)
import Eza.Config (Config (..))
import qualified Eza.Control as Control
import Eza.Server (AppState (..))
import TestHarness (
    HttpResponse,
    TestServer (..),
    cookieHeaders,
    createTestUser,
    hrespBody,
    hrespStatus,
    httpRequest,
    jsonHeaders,
    loginAs,
    shouldHaveStatus,
    withTestServer,
 )

spec :: Spec
spec = describe "error problems" $ do
    describe "feature error ADTs keep status, code and message" $ do
        it "converts a login failure (Auth)" $ withTestServer $ \server -> do
            response <-
                httpRequest
                    server
                    "POST"
                    "/api/auth/login"
                    jsonHeaders
                    (Just (encode (object ["username" .= ("nobody" :: Text), "password" .= ("wrong" :: Text)])))
            response `shouldHaveStatus` 401
            assertProblem response 401 "invalid_credentials" "invalid username or password"

        it "converts an account conflict (Admin)" $ withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" roleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            response <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/admin/users"
                    (sessionHeaders session csrf)
                    (Just (encode (object ["username" .= ("alice" :: Text), "password" .= ("another password" :: Text), "role" .= ("member" :: Text)])))
            response `shouldHaveStatus` 409
            assertProblem response 409 "username_taken" "that username is already in use"

        it "converts a view validation failure (Views)" $ withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" roleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            response <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/views"
                    (sessionHeaders session csrf)
                    (Just (encode (object ["name" .= ("" :: Text), "kind" .= ("graph" :: Text), "definition" .= object []])))
            response `shouldHaveStatus` 400
            problem <- expectProblem response
            statusOf problem `shouldBe` 400
            codeOf problem `shouldSatisfy` (`elem` ["bad_request", "view_limit"])

        it "converts a webhook validation failure (Webhooks)" $ withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" roleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            response <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/webhooks"
                    (sessionHeaders session csrf)
                    (Just (encode (object ["name" .= ("broken" :: Text), "url" .= ("not-a-url" :: Text), "events" .= (["bookmark.created"] :: [Text]), "enabled" .= True])))
            response `shouldHaveStatus` 400
            assertProblemCode response 400 "bad_request"

        it "converts a template validation failure (ClipTemplates)" $ withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" roleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            response <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/clip-templates"
                    (sessionHeaders session csrf)
                    (Just (encode templateWithEmptyName))
            response `shouldHaveStatus` 400
            assertProblem response 400 "template_name_required" "template name is required"

        it "converts a clip validation failure (Clip)" $ withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" roleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            created <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/tokens"
                    (sessionHeaders session csrf)
                    (Just (encode (object ["name" .= ("capture" :: Text), "scopes" .= (["capture"] :: [Text])])))
            created `shouldHaveStatus` 201
            rawToken <- case decode (hrespBody created) :: Maybe Value of
                Just (Object value) -> case KeyMap.lookup "token" value of
                    Just (String token) -> pure token
                    _ -> expectationFailure "missing token" >> error "unreachable"
                _ -> expectationFailure "bad token body" >> error "unreachable"
            response <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/clip"
                    [("Authorization", TE.encodeUtf8 ("Bearer " <> rawToken)), ("Content-Type", "application/json")]
                    (Just (encode (object ["url" .= ("not-a-url" :: Text)])))
            response `shouldHaveStatus` 400
            assertProblemCode response 400 "invalid_url"

    describe "dispatch errors stay JSON problems" $ do
        it "keeps 404 and 405 as problems" $ withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" roleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            notFound <- httpRequest server "GET" "/api/v1/does-not-exist" (cookieHeaders session csrf) Nothing
            notFound `shouldHaveStatus` 404
            assertProblem notFound 404 "not_found" "No such route"
            notAllowed <- httpRequest server "PUT" "/api/v1/bookmarks" (cookieHeaders session csrf) Nothing
            notAllowed `shouldHaveStatus` 405
            assertProblemCode notAllowed 405 "method_not_allowed"

    describe "catch-all middleware" $ do
        it "answers an uncaught exception with a JSON 500 problem" $ withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" roleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            -- Break the server's control connection, then restore a fresh one
            -- so the fixture teardown still has something to close.
            modifyMVar_ (asControl (tsState server)) $ \conn -> do
                Sqlite.close conn
                pure conn
            response <- httpRequest server "GET" "/api/v1/admin/users" (cookieHeaders session csrf) Nothing
            response `shouldHaveStatus` 500
            assertProblem response 500 "internal_error" "internal server error"
            fresh <- Control.openControlDb (cfgControlDbPath (tsConfig server))
            modifyMVar_ (asControl (tsState server)) (const (pure fresh))

        it "answers SQLite busy/locked with a JSON 503 problem" $ do
            response <- runMiddleware (throwingApp (toException (SQLError ErrorBusy "database is locked" ""))) "/api/v1/bookmarks"
            responseStatus response `shouldBe` mkStatus 503 ""
            body <- responseBody response
            body `shouldSatisfy` hasProblemBody
            problemCodeOf body `shouldBe` Just "database_busy"

        it "answers every other exception with a JSON 500 problem" $ do
            response <- runMiddleware (throwingApp (toException (userError "boom"))) "/api/v1/bookmarks"
            responseStatus response `shouldBe` mkStatus 500 ""
            body <- responseBody response
            problemCodeOf body `shouldBe` Just "internal_error"

-- ---------------------------------------------------------------------------
-- Problem body assertions
-- ---------------------------------------------------------------------------

data ProblemFields = ProblemFields
    { statusOf :: Int
    , codeOf :: Text
    , messageOf :: Text
    }

expectProblem :: HttpResponse -> IO ProblemFields
expectProblem response =
    case decode (hrespBody response) :: Maybe Value of
        Just value -> case problemFields (hrespBody response) of
            Just fields -> pure fields{statusOf = hrespStatus response}
            Nothing -> expectationFailure ("not a problem body: " <> show value) >> error "unreachable"
        Nothing -> expectationFailure ("body is not JSON: " <> show (hrespBody response)) >> error "unreachable"

assertProblem :: HttpResponse -> Int -> Text -> Text -> Expectation
assertProblem response expectedStatus expectedCode expectedMessage = do
    fields <- expectProblem response
    statusOf fields `shouldBe` expectedStatus
    codeOf fields `shouldBe` expectedCode
    messageOf fields `shouldBe` expectedMessage

assertProblemCode :: HttpResponse -> Int -> Text -> Expectation
assertProblemCode response expectedStatus expectedCode = do
    fields <- expectProblem response
    statusOf fields `shouldBe` expectedStatus
    codeOf fields `shouldBe` expectedCode
    messageOf fields `shouldSatisfy` (not . T.null)

{- | The wire shape is exactly @{"error":{"code","message"}}@: one outer key and
exactly the two inner keys.
-}
problemFields :: LBS.ByteString -> Maybe ProblemFields
problemFields raw = case decode raw of
    Just (Object outer)
        | KeyMap.size outer == 1
        , Just (Object inner) <- KeyMap.lookup "error" outer
        , KeyMap.size inner == 2
        , Just (String code) <- KeyMap.lookup "code" inner
        , Just (String message) <- KeyMap.lookup "message" inner ->
            Just (ProblemFields 0 code message)
    _ -> Nothing

hasProblemBody :: LBS.ByteString -> Bool
hasProblemBody raw = case problemFields raw of
    Just _ -> True
    Nothing -> False

problemCodeOf :: LBS.ByteString -> Maybe Text
problemCodeOf raw = codeOf <$> problemFields raw

-- ---------------------------------------------------------------------------
-- Middleware helpers
-- ---------------------------------------------------------------------------

throwingApp :: SomeException -> Application
throwingApp err _ _ = throwIO err

{- | Run the catch-all middleware with a synthetic request and hand back the
response it produced.
-}
runMiddleware :: Application -> String -> IO Response
runMiddleware application path = do
    slot <- newEmptyMVar
    _ <- catchAllMiddleware application (mockRequest "GET" path) $ \response -> do
        putMVar slot response
        pure (error "the middleware's ResponseReceived is never forced in a test")
    takeMVar slot

mockRequest :: BS.ByteString -> String -> Request
mockRequest method path =
    Request
        { requestMethod = method
        , httpVersion = http11
        , rawPathInfo = TE.encodeUtf8 (T.pack path)
        , rawQueryString = ""
        , requestHeaders = []
        , isSecure = False
        , remoteHost = SockAddrInet 0 0
        , pathInfo = filter (not . T.null) (T.splitOn "/" (T.pack path))
        , queryString = []
        , requestBody = pure BS.empty
        , vault = error "the error middleware does not read the vault"
        , requestBodyLength = KnownLength 0
        , requestHeaderHost = Nothing
        , requestHeaderRange = Nothing
        , requestHeaderReferer = Nothing
        , requestHeaderUserAgent = Nothing
        , requestSendEarlyHints = \_ -> pure ()
        }

responseBody :: Response -> IO LBS.ByteString
responseBody response = case responseToStream response of
    (_, _, withBody) -> do
        chunks <- newIORef mempty
        withBody $ \streamBody -> streamBody (\builder -> modifyIORef' chunks (<> builder)) (pure ())
        toLazyByteString <$> readIORef chunks

templateWithEmptyName :: Value
templateWithEmptyName =
    object
        [ "id" .= (0 :: Int)
        , "name" .= ("" :: Text)
        , "description" .= ("" :: Text)
        , "enabled" .= True
        , "title_template" .= ("{{title}}" :: Text)
        , "body_template" .= ("{{content}}" :: Text)
        , "default_tags" .= ([] :: [Text])
        , "trigger_urls" .= ([] :: [Text])
        , "trigger_regex" .= ("" :: Text)
        , "builtin" .= False
        , "created_at" .= (0 :: Int)
        , "updated_at" .= (0 :: Int)
        ]

sessionHeaders :: Text -> Text -> [(HeaderName, BS.ByteString)]
sessionHeaders session csrf =
    cookieHeaders session csrf
        <> [("Content-Type", "application/json"), ("X-CSRF-Token", TE.encodeUtf8 csrf)]

roleAdmin :: Control.UserRole
roleAdmin = Control.RoleAdmin
