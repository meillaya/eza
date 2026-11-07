{-# LANGUAGE OverloadedStrings #-}
module Eza.SavedSearches
  ( listSavedSearches
  , createSavedSearch
  , deleteSavedSearch
  ) where

import Data.Aeson (decode, encode)
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple

import Eza.Types (SavedSearch (..))

listSavedSearches :: Connection -> IO [SavedSearch]
listSavedSearches conn = do
  rows <-
    query_
      conn
      "SELECT id,name,q,CAST(tags_json AS TEXT),created_at FROM saved_searches ORDER BY created_at DESC, id DESC" :: IO [(Int, Text, Text, Text, Int)]
  pure
    [ SavedSearch i n q (parseTags tj) c
    | (i, n, q, tj, c) <- rows
    ]
  where
    parseTags raw = case decode (LBS.fromStrict (TE.encodeUtf8 raw)) :: Maybe [Text] of
      Just ts -> ts
      Nothing -> []

createSavedSearch :: Connection -> Text -> Text -> [Text] -> IO Int
createSavedSearch conn name q tags = do
  now <- floor <$> getPOSIXTime
  let tj = encode (filter (not . T.null) tags)
  withImmediateTransaction conn $ do
    execute conn "INSERT INTO saved_searches (name,q,tags_json,created_at) VALUES (?,?,?,?)" (name, q, TE.decodeUtf8 (LBS.toStrict tj), now :: Int)
    fromIntegral <$> lastInsertRowId conn

deleteSavedSearch :: Connection -> Int -> IO Bool
deleteSavedSearch conn sid = do
  n <- withImmediateTransaction conn $ do
    execute conn "DELETE FROM saved_searches WHERE id = ?" (Only sid)
    changes conn
  pure (n > 0)
