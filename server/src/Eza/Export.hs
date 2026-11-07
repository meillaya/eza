{-# LANGUAGE OverloadedStrings #-}
module Eza.Export
  ( exportBookmarks
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple

import Eza.Url (isHttpUrl)

-- | Canonical Chromium-compatible Netscape bookmarks.html with CRLF endings.
-- The tag "toolbar" becomes the toolbar folder; every other bookmark is
-- written in the flattened "Other bookmarks" bucket.
exportBookmarks :: Connection -> IO Text
exportBookmarks conn = do
  rows <-
    query_
      conn
      "SELECT b.id,b.url,b.title,b.created_at FROM bookmarks b ORDER BY b.created_at ASC, b.id ASC" :: IO [(Int, Text, Text, Int)]
  tagRows <-
    query_
      conn
      "SELECT bt.bookmark_id,t.name FROM bookmark_tags bt JOIN tags t ON t.id=bt.tag_id ORDER BY t.name" :: IO [(Int, Text)]
  let tagsBy = Map.fromListWith (flip (<>)) [(i, [t]) | (i, t) <- tagRows]
      usable = [(i, u, t, c) | (i, u, t, c) <- rows, isHttpUrl u]
      toolbar = [(i, u, t, c) | (i, u, t, c) <- usable, maybe False (elem "toolbar") (Map.lookup i tagsBy)]
      other = [(i, u, t, c) | (i, u, t, c) <- usable, not (maybe False (elem "toolbar") (Map.lookup i tagsBy))]
      line (_, u, t, c) =
        "    <DT><A HREF=\"" <> escapeAttr u <> "\" ADD_DATE=\"" <> T.pack (show c) <> "\">"
          <> escapeContent (if T.null (T.strip t) then u else t)
          <> "</A>\r\n"
      header =
        T.concat
          [ "<!DOCTYPE NETSCAPE-Bookmark-file-1>\r\n"
          , "<!-- This is an automatically generated file.\r\n"
          , "     It will be read and overwritten.\r\n"
          , "     DO NOT EDIT! -->\r\n"
          , "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\r\n"
          , "<TITLE>Bookmarks</TITLE>\r\n"
          , "<H1>Bookmarks</H1>\r\n"
          , "<DL><p>\r\n"
          ]
      toolbarBlock =
        if null toolbar
          then ""
          else
            T.concat
              [ "    <DT><H3 ADD_DATE=\"0\" LAST_MODIFIED=\"0\" PERSONAL_TOOLBAR_FOLDER=\"true\">Bookmarks bar</H3>\r\n"
              , "    <DL><p>\r\n"
              , T.concat (map line toolbar)
              , "    </DL><p>\r\n"
              ]
      footer = "</DL><p>\r\n"
  pure (header <> toolbarBlock <> T.concat (map line other) <> footer)

escapeAttr :: Text -> Text
escapeAttr = T.replace "&" "&amp;" . T.replace "\"" "&quot;" . T.replace ">" "&gt;" . T.replace "<" "&lt;"

escapeContent :: Text -> Text
escapeContent = T.replace "&" "&amp;" . T.replace ">" "&gt;" . T.replace "<" "&lt;"