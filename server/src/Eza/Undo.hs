{-# LANGUAGE OverloadedStrings #-}
module Eza.Undo
  ( snapshotBookmarks
  , recordUndo
  , restoreBookmarks
  , undoLast
  ) where

import Control.Monad (forM, forM_)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import GHC.Generics (Generic)

import Eza.Json (jsonOptions)

data SnapshotRow = SnapshotRow
  { srId :: Int
  , srUrl :: Text
  , srTitle :: Text
  , srDescription :: Text
  , srFaviconUrl :: Text
  , srDomain :: Text
  , srSource :: Text
  , srCreatedAt :: Int
  , srAddedAt :: Int
  , srUpdatedAt :: Int
  , srLastOpenedAt :: Maybe Int
  , srLastCheckedAt :: Maybe Int
  , srOpenCount :: Int
  , srIsDead :: Int
  , srIsRead :: Int
  , srNoteBody :: Text
  , srExtractedText :: Text
  , srAuthor :: Text
  , srSitename :: Text
  , srPublishedAt :: Maybe Int
  , srLanguage :: Text
  , srImageUrl :: Text
  , srFinalUrl :: Text
  , srSnapshotPath :: Text
  , srSnapshotKind :: Text
  , srSnapshotCapturedAt :: Maybe Int
  }
  deriving (Show, Eq, Generic)

instance FromRow SnapshotRow where
  fromRow =
    SnapshotRow <$> field <*> field <*> field <*> field <*> field <*> field
      <*> field <*> field <*> field <*> field <*> field <*> field
      <*> field <*> field <*> field <*> field <*> field <*> field
      <*> field <*> field <*> field <*> field <*> field <*> field
      <*> field <*> field

instance ToJSON SnapshotRow where
  toJSON = genericToJSON (jsonOptions "sr")
instance FromJSON SnapshotRow where
  parseJSON = genericParseJSON (jsonOptions "sr")

snapshotColumns :: Text
snapshotColumns =
  "id,url,title,description,favicon_url,domain,source,created_at,added_at,updated_at,last_opened_at,last_checked_at,open_count,is_dead,is_read,note_body,extracted_text,author,sitename,published_at,language,image_url,final_url,snapshot_path,snapshot_kind,snapshot_captured_at"

-- | Snapshot the complete rows and tag names for the given bookmark ids.
snapshotBookmarks :: Connection -> [Int] -> IO Value
snapshotBookmarks _ [] = pure (object ["rows" .= ([] :: [Value]), "tags" .= ([] :: [(Int, Text)])])
snapshotBookmarks conn ids = do
  let marks = T.intercalate "," (replicate (length ids) "?")
  rows <- query conn (Query ("SELECT " <> snapshotColumns <> " FROM bookmarks WHERE id IN (" <> marks <> ")")) ids :: IO [SnapshotRow]
  tags <-
    query
      conn
      (Query ("SELECT bt.bookmark_id,t.name FROM bookmark_tags bt JOIN tags t ON t.id=bt.tag_id WHERE bt.bookmark_id IN (" <> marks <> ") ORDER BY t.name"))
      ids :: IO [(Int, Text)]
  pure (object ["rows" .= rows, "tags" .= tags])

recordUndo :: Connection -> Text -> Value -> IO ()
recordUndo conn op snapshot = do
  now <- floor <$> getPOSIXTime
  execute
    conn
    "INSERT INTO undo_snapshots (payload_json, created_at) VALUES (?, ?)"
    (TE.decodeUtf8 (LBS.toStrict (encode (object ["op" .= op, "snapshot" .= snapshot]))), (now :: Int))

restoreBookmarks :: Connection -> Value -> IO Int
restoreBookmarks conn payload = do
  let rows = fromMaybe [] (parseMaybe (withObject "snapshot" (.: "rows")) payload :: Maybe [SnapshotRow])
      tags = fromMaybe [] (parseMaybe (withObject "snapshot" (.: "tags")) payload :: Maybe [(Int, Text)])
  forM_ rows $ \r ->
    executeNamed
      conn
      "INSERT OR REPLACE INTO bookmarks (id,url,title,description,favicon_url,domain,source,created_at,added_at,updated_at,last_opened_at,last_checked_at,open_count,is_dead,is_read,note_body,extracted_text,author,sitename,published_at,language,image_url,final_url,snapshot_path,snapshot_kind,snapshot_captured_at) VALUES (:id,:url,:title,:description,:favicon,:domain,:source,:created,:added,:updated,:opened,:checked,:open_count,:dead,:read,:note,:extracted,:author,:sitename,:published,:language,:image,:final,:snapshot_path,:snapshot_kind,:snapshot_captured)"
      [ ":id" := srId r
      , ":url" := srUrl r
      , ":title" := srTitle r
      , ":description" := srDescription r
      , ":favicon" := srFaviconUrl r
      , ":domain" := srDomain r
      , ":source" := srSource r
      , ":created" := srCreatedAt r
      , ":added" := srAddedAt r
      , ":updated" := srUpdatedAt r
      , ":opened" := srLastOpenedAt r
      , ":checked" := srLastCheckedAt r
      , ":open_count" := srOpenCount r
      , ":dead" := srIsDead r
      , ":read" := srIsRead r
      , ":note" := srNoteBody r
      , ":extracted" := srExtractedText r
      , ":author" := srAuthor r
      , ":sitename" := srSitename r
      , ":published" := srPublishedAt r
      , ":language" := srLanguage r
      , ":image" := srImageUrl r
      , ":final" := srFinalUrl r
      , ":snapshot_path" := srSnapshotPath r
      , ":snapshot_kind" := srSnapshotKind r
      , ":snapshot_captured" := srSnapshotCapturedAt r
      ]
  forM_ rows $ \r -> execute conn "DELETE FROM bookmark_tags WHERE bookmark_id = ?" (Only (srId r))
  forM_ tags $ \(bid, name) -> do
    execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, strftime('%s','now'))" (Only name)
    tagRows <- query conn "SELECT id FROM tags WHERE name = ?" (Only name) :: IO [Only Int]
    case tagRows of
      (Only tid : _) -> execute conn "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?, ?)" (bid, tid)
      _ -> pure ()
  pure (length rows)

undoLast :: Connection -> IO Int
undoLast conn = do
  rows <-
    query_ conn "SELECT id, CAST(payload_json AS TEXT) FROM undo_snapshots ORDER BY id DESC LIMIT 1" :: IO [(Int, Text)]
  case rows of
    [] -> pure 0
    ((snapshotId, raw) : _) ->
      case decode (LBS.fromStrict (TE.encodeUtf8 raw)) :: Maybe Value of
        Nothing -> pure 0
        Just value ->
          case parseMaybe (withObject "undo" (.: "snapshot")) value of
            Nothing -> pure 0
            Just snapshot -> do
              n <- restoreBookmarks conn snapshot
              execute conn "DELETE FROM undo_snapshots WHERE id = ?" (Only snapshotId)
              pure n