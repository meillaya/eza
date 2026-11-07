{-# LANGUAGE OverloadedStrings #-}

-- | Signed read-only share links and Atom feeds.
module Eza.Shares
  ( ShareView (..)
  , ShareRecord (..)
  , createShare
  , listShares
  , revokeShare
  , resolveShare
  , shareBookmarkPage
  , shareSearchPage
  , shareSearchFeed
  ) where

import Crypto.Hash (Digest, SHA256, hash)
import qualified Crypto.Random as Random
import Data.Aeson
import qualified Data.ByteString.Base64.URL as B64
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime, posixSecondsToUTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Database.SQLite.Simple
import GHC.Generics (Generic)

import Eza.Types (BookmarkDetail (..), BookmarkSummary (..), SavedSearch (..), SearchPage (..))

data ShareView = ShareView
  { svId :: Int
  , svPrefix :: Text
  , svScope :: Text
  , svTargetId :: Int
  , svIncludeNote :: Bool
  , svCreatedAt :: Int
  , svExpiresAt :: Int
  , svRevokedAt :: Maybe Int
  , svLastAccessedAt :: Maybe Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON ShareView where
  toJSON sv =
    object
      [ "id" .= svId sv
      , "prefix" .= svPrefix sv
      , "scope" .= svScope sv
      , "target_id" .= svTargetId sv
      , "include_note" .= svIncludeNote sv
      , "created_at" .= svCreatedAt sv
      , "expires_at" .= svExpiresAt sv
      , "revoked_at" .= svRevokedAt sv
      , "last_accessed_at" .= svLastAccessedAt sv
      ]

data ShareRecord = ShareRecord
  { srId :: Int
  , srScope :: Text
  , srTargetId :: Int
  , srIncludeNote :: Bool
  }
  deriving (Show, Eq)

epoch :: IO Int
epoch = floor <$> getPOSIXTime

hashToken :: Text -> Text
hashToken raw = T.pack (show (hash (TE.encodeUtf8 raw) :: Digest SHA256))

createShare :: Connection -> Text -> Int -> Bool -> Int -> IO (Either Text (Int, Text))
createShare conn scope targetId includeNote days
  | scope `notElem` ["bookmark", "saved_search"] = pure (Left "unknown share scope")
  | days < 1 || days > 365 = pure (Left "expiry must be between 1 and 365 days")
  | otherwise = do
      target <- case scope of
        "bookmark" -> query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only targetId) :: IO [Only Int]
        _ -> query conn "SELECT 1 FROM saved_searches WHERE id = ?" (Only targetId) :: IO [Only Int]
      if null target
        then pure (Left "share target not found")
        else do
          rawBytes <- Random.getRandomBytes 32
          let raw = TE.decodeUtf8 (B64.encodeUnpadded rawBytes)
          now <- epoch
          withImmediateTransaction conn $
            execute
              conn
              "INSERT INTO share_links (token_hash, token_prefix, scope, target_id, include_note, created_at, expires_at) VALUES (?,?,?,?,?,?,?)"
              (hashToken raw, T.take 12 raw, scope, targetId, if includeNote then 1 else 0 :: Int, now, now + days * 86400)
          sid <- fromIntegral <$> lastInsertRowId conn
          pure (Right (sid, raw))

listShares :: Connection -> IO [ShareView]
listShares conn = do
  rows <-
    query_
      conn
      "SELECT id, token_prefix, scope, target_id, include_note, created_at, expires_at, revoked_at, last_accessed_at FROM share_links ORDER BY id DESC" :: IO [(Int, Text, Text, Int, Int, Int, Int, Maybe Int, Maybe Int)]
  pure
    [ ShareView sid prefix scope target (include /= 0) created expires revoked lastUsed
    | (sid, prefix, scope, target, include, created, expires, revoked, lastUsed) <- rows
    ]

revokeShare :: Connection -> Int -> IO Bool
revokeShare conn shareId = do
  now <- epoch
  withImmediateTransaction conn $ do
    execute conn "UPDATE share_links SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL" (now, shareId)
    changed <- changes conn
    pure (changed > 0)

resolveShare :: Connection -> Text -> IO (Maybe ShareRecord)
resolveShare conn raw = do
  now <- epoch
  rows <-
    query
      conn
      "SELECT id, scope, target_id, include_note FROM share_links WHERE token_hash = ? AND revoked_at IS NULL AND expires_at > ?"
      (hashToken raw, now) :: IO [(Int, Text, Int, Int)]
  case rows of
    [] -> pure Nothing
    [(sid, scope, target, include)] -> do
      withImmediateTransaction conn $
        execute conn "UPDATE share_links SET last_accessed_at = ? WHERE id = ?" (now, sid)
      pure (Just (ShareRecord sid scope target (include /= 0)))

shareBookmarkPage :: BookmarkDetail -> Bool -> Text
shareBookmarkPage bookmark includeNote =
  document
    (bdTitle bookmark)
    ( T.unlines
        [ "<header class=\"share-head\"><div class=\"share-mark\">eza</div>"
        , "<h1>" <> escape (bdTitle bookmark) <> "</h1>"
        , "<a class=\"share-url\" href=\"" <> escape (bdUrl bookmark) <> "\" rel=\"noopener noreferrer\">" <> escape (bdUrl bookmark) <> "</a>"
        , "<div class=\"share-tags\">" <> T.concat ["<span class=\"tag-chip\">" <> escape tag <> "</span>" | tag <- bdTags bookmark] <> "</div>"
        , "</header>"
        , if includeNote && not (T.null (T.strip (bdNoteBody bookmark)))
            then "<section class=\"share-panel\"><h2>Note</h2><p>" <> escape (bdNoteBody bookmark) <> "</p></section>"
            else ""
        , "<p class=\"share-foot\">Shared from eza.</p>"
        ]
    )

shareSearchPage :: SavedSearch -> SearchPage -> Text
shareSearchPage saved page =
  document
    (ssName saved)
    ( T.unlines
        [ "<header class=\"share-head\"><div class=\"share-mark\">eza</div>"
        , "<h1>" <> escape (ssName saved) <> "</h1>"
        , "<p class=\"share-sub\">" <> T.pack (show (spTotal page)) <> " bookmarks</p>"
        , "</header>"
        , "<ul class=\"share-list\">"
        , T.concat
            [ "<li><a href=\"" <> escape (bsUrl bookmark) <> "\" rel=\"noopener noreferrer\">" <> escape (bsTitle bookmark) <> "</a><span>" <> escape (bsDomain bookmark) <> "</span></li>"
            | bookmark <- spItems page
            ]
        , "</ul>"
        , "<p class=\"share-foot\">Shared from eza.</p>"
        ]
    )

shareSearchFeed :: SavedSearch -> SearchPage -> Text
shareSearchFeed saved page =
  T.unlines
    [ "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
    , "<feed xmlns=\"http://www.w3.org/2005/Atom\">"
    , "<title>" <> xmlEscape (ssName saved) <> "</title>"
    , "<id>urn:eza:saved-search:" <> T.pack (show (ssId saved)) <> "</id>"
    , "<updated>" <> atomTime (ssCreatedAt saved) <> "</updated>"
    , "<link href=\"/\" rel=\"alternate\"/>"
    , T.concat
        [ "<entry><title>"
            <> xmlEscape (bsTitle bookmark)
            <> "</title><id>urn:eza:bookmark:"
            <> T.pack (show (bsId bookmark))
            <> "</id><link href=\""
            <> xmlEscape (bsUrl bookmark)
            <> "\"/><updated>"
            <> atomTime (bsCreatedAt bookmark)
            <> "</updated></entry>"
        | bookmark <- spItems page
        ]
    , "</feed>"
    ]

document :: Text -> Text -> Text
document title body =
  T.unlines
    [ "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
    , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    , "<meta name=\"robots\" content=\"noindex,nofollow\">"
    , "<title>" <> escape title <> " — eza</title>"
    , "<link rel=\"stylesheet\" href=\"/assets/eza.css\">"
    , "<link rel=\"icon\" href=\"/assets/favicon.svg\">"
    , "</head><body class=\"share-body\"><main class=\"share-card\">"
    , body
    , "</main></body></html>"
    ]

escape :: Text -> Text
escape value =
  T.replace ">" "&gt;" (T.replace "<" "&lt;" (T.replace "&" "&amp;" (T.replace "\"" "&quot;" value)))

xmlEscape :: Text -> Text
xmlEscape = escape

atomTime :: Int -> Text
atomTime seconds = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (posixSecondsToUTCTime (fromIntegral seconds)))
