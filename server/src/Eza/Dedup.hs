{-# LANGUAGE OverloadedStrings #-}
module Eza.Dedup
  ( DedupGroup (..)
  , DedupReport (..)
  , dedupCandidates
  , mergeBookmarks
  ) where

import Control.Monad (forM, forM_, when)
import Data.Aeson (ToJSON (..), genericToJSON, encode, object, (.=))
import qualified Data.ByteString.Lazy as LBS
import Data.Char (isAlphaNum, toLower)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import GHC.Generics (Generic)
import Network.URI (URI (..), URIAuth (..), parseURI)

import Eza.Bookmarks (bookmarksByIds)
import Eza.Json (jsonOptions)
import Eza.Undo (recordUndo, snapshotBookmarks)
import Eza.Url (hostOf)
import Eza.Types (BookmarkSummary (..))

data DedupGroup = DedupGroup
  { dgKey :: Text
  , dgItems :: [BookmarkSummary]
  }
  deriving (Show, Eq, Generic)

instance ToJSON DedupGroup where
  toJSON = genericToJSON (jsonOptions "dg")

data DedupReport = DedupReport
  { drGroups :: [DedupGroup]
  }
  deriving (Show, Eq, Generic)

instance ToJSON DedupReport where
  toJSON = genericToJSON (jsonOptions "dr")

dedupCandidates :: Connection -> IO DedupReport
dedupCandidates conn = do
  rows <- query_ conn "SELECT id,url,title,domain FROM bookmarks" :: IO [(Int, Text, Text, Text)]
  let entries = [(i, normalizeUrl u, normalizeTitle t, hostOf u) | (i, u, t, _) <- rows]
      byUrl = Map.fromListWith (<>) [((normalizeDomain d, nu), [i]) | (i, nu, _, d) <- entries]
      urlGroups = [(key, ids) | (key, ids) <- Map.toList byUrl, length ids > 1]
      urlIds = Set.fromList (concatMap snd urlGroups)
      byTitle =
        Map.fromListWith (<>)
          [ ((normalizeDomain d, nt), [i])
          | (i, _, nt, d) <- entries
          , not (Set.member i urlIds)
          , not (T.null nt)
          ]
      titleGroups = [(key, ids) | (key, ids) <- Map.toList byTitle, length ids > 1]
      groups = urlGroups <> titleGroups
  items <- forM groups $ \((dom, key), ids) -> do
    summaries <- bookmarksByIds conn ids
    pure (DedupGroup (dom <> ":" <> key) summaries)
  pure (DedupReport (sortOn dgKey items))

normalizeUrl :: Text -> Text
normalizeUrl raw =
  case parseURI (T.unpack (T.strip raw)) of
    Nothing -> T.toLower (T.strip raw)
    Just uri ->
      let auth = uriAuthority uri
          host = case auth of
            Nothing -> ""
            Just a -> T.toLower (T.pack (uriRegName a))
          host' = fromMaybe host (T.stripPrefix "www." host)
          path = T.pack (uriPath uri)
          path' = if T.length path > 1 && T.last path == '/' then T.init path else path
          params = parseQuery (T.pack (uriQuery uri))
          meaningful = [(k, v) | (k, v) <- params, not (isTracking k)]
          q = if null meaningful then "" else "?" <> T.intercalate "&" [k <> "=" <> v | (k, v) <- meaningful]
       in host' <> path' <> q

parseQuery :: Text -> [(Text, Text)]
parseQuery q =
  [ (k, v)
  | part <- T.splitOn "&" (T.dropWhile (== '?') q)
  , not (T.null part)
  , let (k, rest) = T.breakOn "=" part
  , let v = fromMaybe "" (T.stripPrefix "=" rest)
  ]

isTracking :: Text -> Bool
isTracking k =
  "utm_" `T.isPrefixOf` k || k `elem` ["fbclid", "gclid", "ref", "ref_src"]

normalizeTitle :: Text -> Text
normalizeTitle = T.unwords . T.words . T.toLower . T.map replace
  where
    replace c
      | isAlphaNum c || c == ' ' = c
      | otherwise = ' '

normalizeDomain :: Text -> Text
normalizeDomain = T.toLower . fromMaybe "" . T.stripPrefix "www." . T.takeWhile (\c -> c /= '/' && c /= ':')

mergeBookmarks :: Connection -> Int -> [Int] -> IO Int
mergeBookmarks conn keep mergeIds = do
  now <- (floor <$> getPOSIXTime) :: IO Int
  let merges = filter (/= keep) mergeIds
  if null merges
    then pure 0
    else
      withImmediateTransaction conn $ do
        exists <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only keep) :: IO [Only Int]
        case exists of
          [] -> pure 0
          _ -> do
            let marks = T.intercalate "," (replicate (length merges) "?")
            mergeRows <- query conn (Query ("SELECT id,note_body FROM bookmarks WHERE id IN (" <> marks <> ")")) merges :: IO [(Int, Text)]
            let found = [i | (i, _) <- mergeRows]
            snapshot <- snapshotBookmarks conn (keep : found)
            recordUndo conn "merge" snapshot
            forM_ found $ \mid ->
              execute
                conn
                "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) SELECT ?, tag_id FROM bookmark_tags WHERE bookmark_id = ?"
                (keep, mid)
            keepNote <- query conn "SELECT note_body FROM bookmarks WHERE id = ?" (Only keep) :: IO [Only Text]
            when (maybe True T.null (case keepNote of (Only n : _) -> Just n; _ -> Nothing)) $
              case [n | (_, n) <- mergeRows, not (T.null n)] of
                (n : _) -> execute conn "UPDATE bookmarks SET note_body = ? WHERE id = ?" (n, keep)
                [] -> pure ()
            forM_ found $ \mid -> do
              execute conn (Query ("UPDATE OR IGNORE links SET source_id = ? WHERE source_id = ?")) (keep, mid)
              execute conn (Query ("UPDATE OR IGNORE links SET target_id = ? WHERE target_id = ?")) (keep, mid)
            execute conn (Query ("DELETE FROM links WHERE source_id IN (" <> marks <> ") OR target_id IN (" <> marks <> ")")) (merges <> merges)
            execute conn (Query ("DELETE FROM bookmarks WHERE id IN (" <> marks <> ")")) merges
            pure (length found)
