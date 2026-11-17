{-# LANGUAGE OverloadedStrings #-}

{- | The extension's saved-page indicator:
@GET /api/v1/bookmarks/lookup?url=...@ and its database query.

The route answers for one exact normalized URL with only the bookmark summary
(@bookmark: null@ when the page is not saved), so the clipper can paint its
saved/unsaved badge without reading notes or captures. The database tests use
the real schema through 'openDb'; the HTTP tests run the real Warp application
from 'TestHarness'.
-}
module LookupSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), encode, object, (.=))
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple (Only (..), close, execute)
import Network.HTTP.Types (urlEncode)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Eza.Bookmarks (insertBookmark, lookupBookmark, updateBookmark)
import qualified Eza.Control as Control
import Eza.Db (openDb)
import Eza.Types (BookmarkLookup (..), BookmarkSummary (..))
import TestHarness

spec :: Spec
spec = describe "saved-page bookmark lookup" $ do
    databaseLookupSpec
    lookupHttpSpec

-- ---------------------------------------------------------------------------
-- The indexed canonical-URL query
-- ---------------------------------------------------------------------------

databaseLookupSpec :: Spec
databaseLookupSpec = describe "lookupBookmark" $ do
    it "matches one page across www, http/https, trailing-slash, and tracking spellings" $
        withSystemTempDirectory "eza-lookup-db" $ \dir -> do
            conn <- openDb (dir </> "eza.db")
            bookmarkId <- expectRight (insertBookmark conn "http://www.example.test/reading-list/" "Reading list" ["reading", "later"])
            forM_
                [ "https://example.test/reading-list"
                , "http://www.example.test/reading-list/"
                , "HTTPS://WWW.Example.Test:443/reading-list/#section"
                , "https://example.test/reading-list?utm_source=feed"
                ]
                $ \variant -> do
                    found <- lookupBookmark conn variant
                    fmap bsId found `shouldBe` Just bookmarkId
                    fmap bsUrl found `shouldBe` Just "http://example.test/reading-list"
                    fmap bsTitle found `shouldBe` Just "Reading list"
                    fmap bsTags found `shouldBe` Just ["later", "reading"]
            close conn

    it "returns the read and dead flags of the matching row" $
        withSystemTempDirectory "eza-lookup-flags" $ \dir -> do
            conn <- openDb (dir </> "eza.db")
            bookmarkId <- expectRight (insertBookmark conn "https://example.test/flags" "Flags" [])
            _ <- updateBookmark conn bookmarkId Nothing Nothing (Just True) Nothing
            execute conn "UPDATE bookmarks SET is_dead = 1 WHERE id = ?" (Only bookmarkId)
            found <- lookupBookmark conn "http://example.test/flags/"
            fmap bsIsRead found `shouldBe` Just True
            fmap bsIsDead found `shouldBe` Just True
            close conn

    it "returns Nothing for a URL the library does not hold" $
        withSystemTempDirectory "eza-lookup-miss" $ \dir -> do
            conn <- openDb (dir </> "eza.db")
            _ <- insertBookmark conn "https://example.test/saved" "Saved" []
            lookupBookmark conn "https://example.test/only-elsewhere" `shouldReturn` Nothing
            close conn

-- ---------------------------------------------------------------------------
-- The HTTP route
-- ---------------------------------------------------------------------------

lookupHttpSpec :: Spec
lookupHttpSpec = describe "GET /api/v1/bookmarks/lookup" $ do
    it "answers 200 with the summary for a saved page and never exposes note fields" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" roleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            bookmarkId <- createBookmark server session csrf "https://example.test/lookup-summary" "Lookup summary"
            patched <-
                httpRequest
                    server
                    "PATCH"
                    ("/api/v1/bookmarks/" <> show bookmarkId)
                    (authHeaders session csrf)
                    (Just (encode (object ["note_body" .= ("a private note" :: Text), "extracted_text" .= ("the whole article body" :: Text)])))
            patched `shouldHaveStatus` 200
            response <-
                httpRequest
                    server
                    "GET"
                    (lookupPath "https://www.example.test:443/lookup-summary/?utm_source=feed")
                    (cookieHeaders session csrf)
                    Nothing
            response `shouldHaveStatus` 200
            let body = hrespBody response
            jsonTextField "url" body `shouldBe` Just "https://example.test/lookup-summary"
            case jsonBody response :: Maybe BookmarkLookup of
                Nothing -> expectationFailure "response is not a BookmarkLookup"
                Just lookupResult -> do
                    bluUrl lookupResult `shouldBe` "https://example.test/lookup-summary"
                    fmap bsId (bluBookmark lookupResult) `shouldBe` Just bookmarkId
                    fmap bsTitle (bluBookmark lookupResult) `shouldBe` Just "Lookup summary"
            -- The summary DTO has no note, extracted-text, or capture fields at
            -- all; prove the wire document does not grow them back.
            body `shouldSatisfy` not . containsText "note_body"
            body `shouldSatisfy` not . containsText "extracted_text"
            body `shouldSatisfy` not . containsText "private note"
            body `shouldSatisfy` not . containsText "whole article body"

    it "answers 200 with bookmark:null for an unsaved page" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" roleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            response <-
                httpRequest
                    server
                    "GET"
                    (lookupPath "https://example.test/not-in-the-library")
                    (cookieHeaders session csrf)
                    Nothing
            response `shouldHaveStatus` 200
            jsonTextField "url" (hrespBody response) `shouldBe` Just "https://example.test/not-in-the-library"
            -- The key is present with a JSON null, not omitted: an old server
            -- that does not know the route answers 404 instead.
            jsonField "bookmark" (hrespBody response) `shouldBe` Just Null
            case jsonBody response :: Maybe BookmarkLookup of
                Nothing -> expectationFailure "response is not a BookmarkLookup"
                Just lookupResult -> bluBookmark lookupResult `shouldBe` Nothing

    it "answers 400 for a missing, invalid, or over-long url" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" roleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            missing <-
                httpRequest server "GET" "/api/v1/bookmarks/lookup" (cookieHeaders session csrf) Nothing
            missing `shouldHaveStatus` 400
            errorCode missing `shouldBe` Just "bad_request"
            invalid <-
                httpRequest
                    server
                    "GET"
                    (lookupPath "ftp://example.test/a")
                    (cookieHeaders session csrf)
                    Nothing
            invalid `shouldHaveStatus` 400
            errorCode invalid `shouldBe` Just "bad_request"
            tooLong <-
                httpRequest
                    server
                    "GET"
                    (lookupPath ("https://example.test/" <> T.replicate 9000 "a"))
                    (cookieHeaders session csrf)
                    Nothing
            tooLong `shouldHaveStatus` 400
            errorCode tooLong `shouldBe` Just "bad_request"

    it "answers 401 without a session or token" $
        withTestServer $ \server -> do
            response <-
                httpRequest
                    server
                    "GET"
                    (lookupPath "https://example.test/anonymous")
                    []
                    Nothing
            response `shouldHaveStatus` 401
            errorCode response `shouldBe` Just "unauthenticated"

    it "accepts a capture token, the scope the extension holds" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" roleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            _ <- createBookmark server session csrf "https://example.test/capture-token" "Capture token"
            token <- createToken server session csrf ["capture"]
            response <-
                httpRequest
                    server
                    "GET"
                    (lookupPath "https://example.test/capture-token")
                    [("Authorization", "Bearer " <> TE.encodeUtf8 token)]
                    Nothing
            response `shouldHaveStatus` 200
            case jsonBody response :: Maybe BookmarkLookup of
                Nothing -> expectationFailure "response is not a BookmarkLookup"
                Just lookupResult -> fmap bsTitle (bluBookmark lookupResult) `shouldBe` Just "Capture token"

    it "rejects a token whose scopes do not allow the route with 403 token_scope" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" roleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            token <- createToken server session csrf []
            response <-
                httpRequest
                    server
                    "GET"
                    (lookupPath "https://example.test/no-scopes")
                    [("Authorization", "Bearer " <> TE.encodeUtf8 token)]
                    Nothing
            response `shouldHaveStatus` 403
            errorCode response `shouldBe` Just "token_scope"

-- ----------------------------------------------------------------- helpers ---

roleAdmin :: Control.UserRole
roleAdmin = Control.RoleAdmin

{- | The lookup request path for one page URL, percent-encoded like the
extension's @encodeURIComponent(pageUrl)@ query.
-}
lookupPath :: Text -> String
lookupPath url =
    "/api/v1/bookmarks/lookup?url="
        <> T.unpack (TE.decodeUtf8 (urlEncode True (TE.encodeUtf8 url)))

createBookmark :: TestServer -> Text -> Text -> Text -> Text -> IO Int
createBookmark server session csrf url title = do
    created <-
        httpRequest
            server
            "POST"
            "/api/v1/bookmarks"
            (authHeaders session csrf)
            (Just (encode (object ["url" .= url, "title" .= title])))
    created `shouldHaveStatus` 201
    expectJust "bookmark id" (jsonIntField "id" (hrespBody created))

createToken :: TestServer -> Text -> Text -> [Text] -> IO Text
createToken server session csrf scopes = do
    created <-
        httpRequest
            server
            "POST"
            "/api/v1/tokens"
            (authHeaders session csrf)
            (Just (encode (object ["name" .= ("lookup-spec" :: Text), "scopes" .= scopes])))
    created `shouldHaveStatus` 201
    expectJust "token" (jsonTextField "token" (hrespBody created))

errorCode :: HttpResponse -> Maybe Text
errorCode response = case jsonField "error" (hrespBody response) of
    Just (Object value) -> case KeyMap.lookup "code" value of
        Just (String code) -> Just code
        _ -> Nothing
    _ -> Nothing

expectRight :: IO (Either Text Int) -> IO Int
expectRight action = do
    result <- action
    case result of
        Right value -> pure value
        Left err -> expectationFailure (T.unpack err) >> error "unreachable"
