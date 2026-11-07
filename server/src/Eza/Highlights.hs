{-# LANGUAGE OverloadedStrings #-}

module Eza.Highlights
  ( listHighlights
  , createHighlight
  , updateHighlight
  , deleteHighlight
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple

import Eza.Types (Highlight (..))

epoch :: IO Int
epoch = floor <$> getPOSIXTime

listHighlights :: Connection -> Int -> IO [Highlight]
listHighlights conn bookmarkId = do
  rows <-
    query
      conn
      "SELECT id, bookmark_id, quote, start_offset, end_offset, note, color, created_at FROM highlights WHERE bookmark_id = ? ORDER BY start_offset ASC, id ASC"
      (Only bookmarkId) :: IO [(Int, Int, Text, Int, Int, Text, Text, Int)]
  pure [Highlight hid bid quote start end note color created | (hid, bid, quote, start, end, note, color, created) <- rows]

createHighlight :: Connection -> Int -> Text -> Text -> Text -> Int -> Int -> Text -> Text -> IO (Either Text Highlight)
createHighlight conn bookmarkId quote prefix suffix startOffset endOffset note color
  | T.null (T.strip quote) = pure (Left "quote is required")
  | T.length quote > 20000 = pure (Left "quote is too long")
  | startOffset < 0 || endOffset <= startOffset = pure (Left "invalid highlight offsets")
  | otherwise = do
      exists <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only bookmarkId) :: IO [Only Int]
      if null exists
        then pure (Left "bookmark not found")
        else do
          now <- epoch
          withImmediateTransaction conn $
            execute
              conn
              "INSERT INTO highlights (bookmark_id, quote, prefix, suffix, start_offset, end_offset, note, color, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)"
              (bookmarkId, T.strip quote, prefix, suffix, startOffset, endOffset, note, if T.null (T.strip color) then "yellow" else color, now, now)
          hid <- fromIntegral <$> lastInsertRowId conn
          pure (Right (Highlight hid bookmarkId (T.strip quote) startOffset endOffset note (if T.null (T.strip color) then "yellow" else color) now))

updateHighlight :: Connection -> Int -> Int -> Maybe Text -> Maybe Text -> IO Bool
updateHighlight conn bookmarkId highlightId note color = do
  exists <- query conn "SELECT 1 FROM highlights WHERE id = ? AND bookmark_id = ?" (highlightId, bookmarkId) :: IO [Only Int]
  if null exists
    then pure False
    else do
      now <- epoch
      withImmediateTransaction conn $ do
        case note of
          Just value -> execute conn "UPDATE highlights SET note = ?, updated_at = ? WHERE id = ? AND bookmark_id = ?" (value, now, highlightId, bookmarkId)
          Nothing -> pure ()
        case color of
          Just value -> execute conn "UPDATE highlights SET color = ?, updated_at = ? WHERE id = ? AND bookmark_id = ?" (value, now, highlightId, bookmarkId)
          Nothing -> pure ()
      pure True

deleteHighlight :: Connection -> Int -> Int -> IO Bool
deleteHighlight conn bookmarkId highlightId = do
  withImmediateTransaction conn $ do
    execute conn "DELETE FROM highlights WHERE id = ? AND bookmark_id = ?" (highlightId, bookmarkId)
    changed <- changes conn
    pure (changed > 0)
