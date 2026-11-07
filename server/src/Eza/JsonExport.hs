{-# LANGUAGE OverloadedStrings #-}

module Eza.JsonExport
  ( exportJson
  , importJson
  , JsonImportReport (..)
  ) where

import Control.Monad (forM_)
import Data.Aeson
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import GHC.Generics (Generic)

data JsonImportReport = JsonImportReport
  { jrBookmarks :: Int
  , jrHighlights :: Int
  , jrSkipped :: Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON JsonImportReport where
  toJSON report =
    object
      [ "bookmarks" .= jrBookmarks report
      , "highlights" .= jrHighlights report
      , "skipped" .= jrSkipped report
      ]

exportJson :: Connection -> IO Value
exportJson conn = do
  now <- (floor <$> getPOSIXTime) :: IO Int
  bookmarks <- query_ conn "SELECT id,url,title,description,domain,note_body,extracted_text,is_read,created_at,added_at FROM bookmarks ORDER BY id" :: IO [(Int, Text, Text, Text, Text, Text, Text, Int, Int, Int)]
  tagRows <- query_ conn "SELECT bookmark_id, t.name FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id ORDER BY t.name" :: IO [(Int, Text)]
  highlights <- query_ conn "SELECT id,bookmark_id,quote,start_offset,end_offset,note,color,created_at FROM highlights ORDER BY id" :: IO [(Int, Int, Text, Int, Int, Text, Text, Int)]
  searches <- query_ conn "SELECT id,name,q,tags_json,created_at FROM saved_searches ORDER BY id" :: IO [(Int, Text, Text, Text, Int)]
  rules <- query_ conn "SELECT id,name,enabled,field,pattern,add_tags,mark_read,created_at FROM rules ORDER BY id" :: IO [(Int, Text, Int, Text, Text, Text, Int, Int)]
  let tagsFor bid = [name | (bookmarkId, name) <- tagRows, bookmarkId == bid]
      bookmarkValue (bid, url, title, description, domain, note, extracted, read, created, added) =
        object
          [ "id" .= bid, "url" .= url, "title" .= title, "description" .= description
          , "domain" .= domain, "note_body" .= note, "extracted_text" .= extracted
          , "is_read" .= (read /= 0), "created_at" .= created, "added_at" .= added
          , "tags" .= tagsFor bid
          ]
      highlightValue (hid, bid, quote, start, end, note, color, created) =
        object ["id" .= hid, "bookmark_id" .= bid, "quote" .= quote, "start_offset" .= start, "end_offset" .= end, "note" .= note, "color" .= color, "created_at" .= created]
      searchValue (sid, name, q, tags, created) = object ["id" .= sid, "name" .= name, "q" .= q, "tags" .= tags, "created_at" .= created]
      ruleValue (rid, name, enabled, field, pattern, tags, markRead, created) = object ["id" .= rid, "name" .= name, "enabled" .= (enabled /= 0), "field" .= field, "pattern" .= pattern, "add_tags" .= tags, "mark_read" .= (markRead /= 0), "created_at" .= created]
  pure
    ( object
        [ "format" .= ("eza-json" :: Text)
        , "version" .= (1 :: Int)
        , "exported_at" .= now
        , "bookmarks" .= map bookmarkValue bookmarks
        , "highlights" .= map highlightValue highlights
        , "saved_searches" .= map searchValue searches
        , "rules" .= map ruleValue rules
        ]
    )

importJson :: Connection -> Value -> IO (Either Text JsonImportReport)
importJson conn value =
  case parseMaybe (withObject "eza-json" $ \o -> do
      format <- o .:? "format" .!= ("" :: Text)
      bookmarks <- o .:? "bookmarks" .!= []
      pure (format, bookmarks :: [Value])) value of
    Nothing -> pure (Left "invalid eza JSON document")
    Just (format, bookmarks)
      | format /= "eza-json" -> pure (Left "document is not an eza JSON export")
      | otherwise -> do
          now <- (floor <$> getPOSIXTime) :: IO Int
          inserted <- mapM (importBookmark now) bookmarks
          let count = length [() | Right _ <- inserted]
              skipped = length [() | Left _ <- inserted]
          pure (Right (JsonImportReport count 0 skipped))
  where
    importBookmark :: Int -> Value -> IO (Either Text ())
    importBookmark now raw =
      case parseMaybe (withObject "bookmark" $ \o -> do
          url <- o .: "url" :: Parser Text
          title <- o .:? "title" .!= ("" :: Text)
          description <- o .:? "description" .!= ("" :: Text)
          note <- o .:? "note_body" .!= ("" :: Text)
          read <- o .:? "is_read" .!= False
          created <- o .:? "created_at" .!= now
          tags <- o .:? "tags" .!= []
          pure (url, title, description, note, read, created :: Int, tags :: [Text])) raw of
        Nothing -> pure (Left "invalid bookmark")
        Just (url, title, description, note, read, created, tags) -> do
          existing <- query conn "SELECT id FROM bookmarks WHERE url = ?" (Only url) :: IO [Only Int]
          case existing of
            (_ : _) -> pure (Left "exists")
            [] -> do
              _ <- withImmediateTransaction conn $ do
                execute
                  conn
                  "INSERT INTO bookmarks (url,title,description,domain,note_body,is_read,created_at,added_at,updated_at,source) VALUES (?,?,?,?,?,?,?,?,?,?)"
                  (url, title, description, domainOf url, note, (if read then 1 else 0) :: Int, (created :: Int), (now :: Int), (now :: Int), ("json" :: Text))
                bid <- (fromIntegral <$> lastInsertRowId conn) :: IO Int
                forM_ tags $ \tag -> do
                  execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)" (T.toLower (T.strip tag), now)
                  idRows <- query conn "SELECT id FROM tags WHERE name = ?" (Only (T.toLower (T.strip tag))) :: IO [Only Int]
                  case idRows of
                    (Only tid : _) -> execute conn "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?, ?)" (bid, tid)
                    _ -> pure ()
                pure ()
              pure (Right ())
    domainOf url =
      let afterScheme = T.drop 1 (T.dropWhile (/= ':') url)
          afterSlashes = T.dropWhile (== '/') afterScheme
          authority = T.takeWhile (\c -> c /= '/' && c /= '?' && c /= '#') afterSlashes
       in T.toLower (T.takeWhile (\c -> c /= ':') authority)
