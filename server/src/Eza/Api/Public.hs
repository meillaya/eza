-- | Public pages, the health endpoint, and public share pages.
module Eza.Api.Public where

import Control.Exception (SomeException, try)

import Data.Aeson

import qualified Data.ByteString.Lazy as LBS

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Database.SQLite.Simple (Connection)

import Network.HTTP.Types
import Network.Wai

import Eza.Bookmarks

import qualified Eza.Db as Db

import Eza.Pages (addPasskeyPage)

import Eza.Routes (Route (..))

import Eza.SavedSearches (listSavedSearches)
import Eza.Shares (ShareRecord (..), ShareState (..), ShareUnavailable (..), resolveShareState, shareBookmarkPage, shareSearchFeed, shareSearchPage, shareUnavailablePage)
import Eza.Shell (pageAssets)

import Eza.Types

import Eza.Api.Common
import Eza.Api.Context

import Eza.Api.Static

health :: AppState -> (Response -> IO ResponseReceived) -> IO ResponseReceived
health state respond = do
    result <- try (withControl state Db.ping) :: IO (Either SomeException Bool)
    case result of
        Right True -> respond (jsonResponse status200 (object ["status" .= ("ok" :: Text), "version" .= ("0.1.0" :: Text)]))
        _ -> respond (jsonProblem status503 "unavailable" "database is unavailable")

{- | A share link is public but still resolves to one account: the token prefix
names the database to read. A revoked, expired, or wrong-database token gets
the same unavailable page family as before.
-}
publicShareHandler :: AppState -> Text -> (Response -> IO ResponseReceived) -> IO ResponseReceived
publicShareHandler state token respond = do
    let isFeed = T.isSuffixOf ".xml" token
        wire = if isFeed then T.dropEnd 4 token else token
    resolved <- resolveShareOwner state wire
    case resolved of
        Left _ -> respond shareGone
        Right Nothing -> respond shareGone
        Right (Just (_, slot, bare)) -> withDb slot $ \conn -> do
            shareState <- resolveShareState conn bare
            case shareState of
                ShareGone reason ->
                    if isFeed
                        then respond (shareHeaders (jsonProblem (unavailableStatus reason) "not_found" "share link is not readable"))
                        else respond (shareHeaders (htmlResponseAt (unavailableStatus reason) (shareUnavailablePage reason)))
                ShareReadable record
                    | srScope record == "bookmark" -> do
                        bookmark <- getBookmark conn (srTargetId record)
                        case bookmark of
                            Nothing -> respond (shareHeaders (htmlResponseAt status404 (shareUnavailablePage ShareInvalid)))
                            Just detail
                                | isFeed -> respond (shareHeaders (jsonProblem status404 "not_found" "feeds are only available for saved searches"))
                                | otherwise -> respond (shareHeaders (htmlResponseAt status200 (shareBookmarkPage record detail)))
                    | srScope record == "saved_search" -> do
                        searches <- listSavedSearches conn
                        case [saved | saved <- searches, ssId saved == srTargetId record] of
                            [] -> respond (shareHeaders (htmlResponseAt status404 (shareUnavailablePage ShareInvalid)))
                            (saved : _) -> do
                                page <- listBookmarks conn (defaultListQuery{lqQ = ssQ saved, lqTags = ssTags saved, lqLimit = 100})
                                if isFeed
                                    then respond (shareHeaders (responseLBS status200 [(hContentType, "application/atom+xml; charset=utf-8")] (LBS.fromStrict (TE.encodeUtf8 (shareSearchFeed saved page)))))
                                    else respond (shareHeaders (htmlResponseAt status200 (shareSearchPage record saved page)))
                    | otherwise -> respond (shareHeaders (htmlResponseAt status404 (shareUnavailablePage ShareInvalid)))
  where
    shareHeaders = mapResponseHeaders (<> [("X-Robots-Tag", "noindex")])
    unavailableStatus ShareInvalid = status404
    unavailableStatus _ = status410
    shareGone = shareHeaders (htmlResponseAt status404 (shareUnavailablePage ShareInvalid))

-- | Dispatch the handlers this family owns from their "Eza.Routes" constructors.
dispatch :: RequestContext -> Connection -> Route -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
dispatch rctx _conn route req respond = case route of
    RouteSavePage -> indexResponse state req respond
    RouteAddPasskeyPage -> respond (htmlResponse (addPasskeyPage (pageAssets (asAssets state))))
    RouteSpaPage ->
        indexResponse state req respond
    _ -> respond (jsonProblem status500 "internal_error" "route has no handler")
  where
    state = rcState rctx

-- | The "Eza.Routes" constructors this family handles.
owns :: Route -> Bool
owns route = case route of
    RouteSavePage -> True
    RouteAddPasskeyPage -> True
    RouteSpaPage -> True
    _ -> False
