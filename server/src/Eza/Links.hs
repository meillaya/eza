{-# LANGUAGE OverloadedStrings #-}
module Eza.Links
  ( syncLinks
  ) where

import Control.Monad (forM_)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple

import Eza.Wikilink (Wikilink (..), parseWikilinks)

-- | Replace the outgoing wikilinks for a bookmark from its note body.
-- Targets are resolved by exact title (case-insensitively); unresolved links
-- keep their target_title so the UI can show them and offer to create one.
syncLinks :: Connection -> Int -> Text -> IO ()
syncLinks conn sourceId note = do
  execute conn "DELETE FROM links WHERE source_id = ?" (Only sourceId)
  forM_ (parseWikilinks note) $ \link -> do
    rows <-
      query
        conn
        "SELECT id FROM bookmarks WHERE lower(title) = lower(?) OR url = ? LIMIT 1"
        (wlTarget link, wlTarget link) :: IO [Only Int]
    case rows of
      [Only targetId] ->
        execute
          conn
          "INSERT OR IGNORE INTO links (source_id, target_id, target_title, display_text, line_number) VALUES (?,?,?,?,?)"
          (sourceId, Just targetId :: Maybe Int, wlTarget link, wlDisplay link, wlLine link)
      _ ->
        execute
          conn
          "INSERT OR IGNORE INTO links (source_id, target_id, target_title, display_text, line_number) VALUES (?,?,?,?,?)"
          (sourceId, Nothing :: Maybe Int, wlTarget link, wlDisplay link, wlLine link)
