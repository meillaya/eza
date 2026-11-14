{-# LANGUAGE OverloadedStrings #-}

{- | The dispatch contract: every "Eza.Routes" route classifies as declared,
the server dispatches from the same table, and the two new error shapes are
stable.

A known path with a method the server does not implement answers a JSON 405
that names the allowed methods; an unknown @/api@ path answers a JSON 404 and
never falls through to the SPA shell.
-}
module DispatchSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), encode, object, (.=))
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types (HeaderName)
import Test.Hspec

import qualified Eza.Authz as Authz
import qualified Eza.Control as Control
import Eza.Routes (allRoutes, renderRoutePath, routeClass, routeMethod)
import TestHarness (
    HttpResponse,
    cookieHeaders,
    createTestUser,
    expectJust,
    headerValue,
    hrespBody,
    httpRequest,
    jsonField,
    jsonIntField,
    jsonTextField,
    loginAs,
    shouldHaveStatus,
    withTestServer,
 )

spec :: Spec
spec = describe "route dispatch" $ do
    it "classifies every enumerated route exactly as Eza.Routes declares" $
        forM_ allRoutes $ \route -> do
            let method = routeMethod route
                path = splitPath (renderRoutePath route)
            Authz.routeClass method path `shouldBe` routeClass route

    it "serves a representative public route and keeps HEAD on the GET handler" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" roleAdmin
            health <- httpRequest server "GET" "/healthz" [] Nothing
            health `shouldHaveStatus` 200
            headHealth <- httpRequest server "HEAD" "/healthz" [] Nothing
            headHealth `shouldHaveStatus` 200
            loginPage <- httpRequest server "GET" "/login" [] Nothing
            loginPage `shouldHaveStatus` 200

    it "answers a known path with an unsupported method with a JSON 405" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" roleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            -- GET on the POST-only login ceremony.
            methodOnCeremony <- httpRequest server "GET" "/api/auth/login" (cookieHeaders session csrf) Nothing
            methodOnCeremony `shouldHaveStatus` 405
            errorCode methodOnCeremony `shouldBe` Just "method_not_allowed"
            methodOnCeremony `shouldHaveContentType` "application/json"
            -- PUT on a known token path.
            putBookmarks <- httpRequest server "PUT" "/api/v1/bookmarks" (cookieHeaders session csrf) Nothing
            putBookmarks `shouldHaveStatus` 405
            errorCode putBookmarks `shouldBe` Just "method_not_allowed"
            allow <- expectJust "Allow header" (headerValue putBookmarks "Allow")
            let allowed = decodeAscii allow
            T.isInfixOf "GET" allowed && T.isInfixOf "POST" allowed `shouldBe` True

    it "answers an unknown /api path with a JSON 404 instead of the SPA shell" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" roleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            unknown <- httpRequest server "GET" "/api/v1/no-such-route" (cookieHeaders session csrf) Nothing
            unknown `shouldHaveStatus` 404
            unknown `shouldHaveContentType` "application/json"
            errorCode unknown `shouldBe` Just "not_found"
            rawBody unknown `shouldSatisfy` not . containsMarkup
            -- Without a session the same path is still JSON, not a redirect.
            anonymous <- httpRequest server "GET" "/api/v1/no-such-route" [] Nothing
            anonymous `shouldHaveStatus` 404
            errorCode anonymous `shouldBe` Just "not_found"

    it "serves a representative route from each authenticated class" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" roleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            -- Session class: the account document.
            account <- httpRequest server "GET" "/api/v1/account" (cookieHeaders session csrf) Nothing
            account `shouldHaveStatus` 200
            -- Token class: an ordinary read with the session cookie.
            boot <- httpRequest server "GET" "/api/v1/boot" (cookieHeaders session csrf) Nothing
            boot `shouldHaveStatus` 200
            -- Admin class: user administration.
            users <- httpRequest server "GET" "/api/v1/admin/users" (cookieHeaders session csrf) Nothing
            users `shouldHaveStatus` 200
            -- Token class with a bearer token: whoami.
            created <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/tokens"
                    (sessionHeaders session csrf)
                    (Just (encode (object ["name" .= ("dispatch-spec" :: Text), "scopes" .= (["read"] :: [Text])])))
            created `shouldHaveStatus` 201
            rawToken <- expectJust "token" (jsonTextField "token" (hrespBody created))
            whoami <-
                httpRequest
                    server
                    "GET"
                    "/api/v1/whoami"
                    [("Authorization", TE.encodeUtf8 ("Bearer " <> rawToken))]
                    Nothing
            whoami `shouldHaveStatus` 200
            -- Share class: a public share page for one bookmark.
            bookmark <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/bookmarks"
                    (sessionHeaders session csrf)
                    (Just (encode (object ["url" .= ("https://example.test/share" :: Text), "title" .= ("Shared" :: Text)])))
            bookmark `shouldHaveStatus` 201
            bookmarkId <- expectJust "bookmark id" (jsonIntField "id" (hrespBody bookmark))
            share <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/share-links"
                    (sessionHeaders session csrf)
                    (Just (encode (object ["scope" .= ("bookmark" :: Text), "target_id" .= bookmarkId])))
            share `shouldHaveStatus` 201
            shareUrl <- expectJust "share url" (jsonTextField "url" (hrespBody share))
            shared <- httpRequest server "GET" ("/s/" <> T.unpack (lastSegment shareUrl)) [] Nothing
            shared `shouldHaveStatus` 200

-- ----------------------------------------------------------------- helpers ---

roleAdmin :: Control.UserRole
roleAdmin = Control.RoleAdmin

splitPath :: Text -> [Text]
splitPath = filter (not . T.null) . T.splitOn "/"

sessionHeaders :: Text -> Text -> [(HeaderName, BS.ByteString)]
sessionHeaders session csrf =
    cookieHeaders session csrf
        <> [ ("Content-Type", "application/json")
           , ("X-CSRF-Token", TE.encodeUtf8 csrf)
           ]

lastSegment :: Text -> Text
lastSegment = T.takeWhileEnd (/= '/')

errorCode :: HttpResponse -> Maybe Text
errorCode response = case jsonField "error" (hrespBody response) of
    Just (Object value) -> case KeyMap.lookup "code" value of
        Just (String code) -> Just code
        _ -> Nothing
    _ -> Nothing

shouldHaveContentType :: HttpResponse -> Text -> Expectation
shouldHaveContentType response expected =
    case headerValue response "Content-Type" of
        Just raw | expected `T.isPrefixOf` decodeAscii raw -> pure ()
        other -> expectationFailure ("content type " <> show other <> " does not start with " <> show expected)

rawBody :: HttpResponse -> BS.ByteString
rawBody = LBS.toStrict . hrespBody

containsMarkup :: BS.ByteString -> Bool
containsMarkup raw = "<html" `BS.isInfixOf` BS.map lowerAscii raw
  where
    lowerAscii byte
        | byte >= 65 && byte <= 90 = byte + 32
        | otherwise = byte

decodeAscii :: BS.ByteString -> Text
decodeAscii = TE.decodeUtf8
