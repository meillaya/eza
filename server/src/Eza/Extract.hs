{-# LANGUAGE OverloadedStrings #-}
module Eza.Extract
  ( Extracted (..)
  , extractHtml
  , fetchHtml
  , extractBookmark
  , enrichBookmark
  ) where

import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Database.SQLite.Simple
import Network.HTTP.Client
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)
import Text.HTML.TagSoup

data Extracted = Extracted
  { exTitle :: Text
  , exDescription :: Text
  , exText :: Text
  , exAuthor :: Text
  , exSitename :: Text
  }
  deriving (Show, Eq)

extractHtml :: Text -> Extracted
extractHtml html =
  let tags = parseTags html :: [Tag Text]
      st = foldl step initial tags
   in Extracted
        { exTitle = clean (esTitle st)
        , exDescription = clean (esDescription st)
        , exText = T.take 100000 (clean (esText st))
        , exAuthor = clean (esAuthor st)
        , exSitename = clean (esSitename st)
        }
  where
    initial = ES "" "" "" "" ""
    step st = \case
      TagOpen name attrs
        | lname name `elem` ["script", "style", "svg", "noscript"] -> st
        | lname name == "title" -> st
        | lname name == "meta" ->
            let content = attr "content" attrs
                key = T.toLower (attr "property" attrs <> " " <> attr "name" attrs)
             in if "og:title" `T.isInfixOf` key || key == " title" || key == "title"
                  then st {esTitle = content}
                  else if "og:description" `T.isInfixOf` key || "description" `T.isInfixOf` key
                    then st {esDescription = content}
                    else if "author" `T.isInfixOf` key
                      then st {esAuthor = content}
                      else if "og:site_name" `T.isInfixOf` key
                        then st {esSitename = content}
                        else st
        | lname name `elem` ["p", "li", "h1", "h2", "h3", "blockquote"] -> st
        | otherwise -> st
      TagText txt
        | not (T.null (T.strip txt)) -> st {esText = esText st <> " " <> txt}
      _ -> st
    lname = T.toLower
    attr key attrs = maybe "" id (lookup (T.toLower key) [(T.toLower k, v) | (k, v) <- attrs])
    clean = T.unwords . T.words . T.strip

fetchHtml :: Text -> IO (Maybe Text)
fetchHtml url = do
  manager <- newTlsManager
  result <- try (do
    req <- parseRequest (T.unpack url)
    resp <- httpLbs req {responseTimeout = responseTimeoutMicro (12 * 1000000), redirectCount = 5, requestHeaders = [("User-Agent", "eza extractor")]} manager
    let code = statusCode (responseStatus resp)
    if code >= 400 then pure Nothing
      else do
        let body = BS.take (2 * 1024 * 1024) (LBS.toStrict (responseBody resp))
        pure (Just (TE.decodeUtf8With TEE.lenientDecode body))) :: IO (Either SomeException (Maybe Text))
  pure (either (const Nothing) id result)

extractBookmark :: Connection -> Int -> IO Bool
extractBookmark conn bid = do
  rows <- query conn "SELECT url FROM bookmarks WHERE id = ?" (Only bid) :: IO [Only Text]
  case rows of
    [] -> pure False
    (Only url : _) -> do
      mhtml <- fetchHtml url
      case mhtml of
        Nothing -> pure False
        Just html -> do
          let e = extractHtml html
          withImmediateTransaction conn $ do
            execute
              conn
              "UPDATE bookmarks SET extracted_text = ?, author = CASE WHEN author = '' THEN ? ELSE author END, sitename = CASE WHEN sitename = '' THEN ? ELSE sitename END, title = CASE WHEN title = '' THEN ? ELSE title END, updated_at = strftime('%s','now') WHERE id = ?"
              (exText e, exAuthor e, exSitename e, exTitle e, bid)
          pure True

enrichBookmark :: Connection -> Int -> IO Bool
enrichBookmark conn bid = do
  rows <- query conn "SELECT url FROM bookmarks WHERE id = ?" (Only bid) :: IO [Only Text]
  case rows of
    [] -> pure False
    (Only url : _) -> do
      mhtml <- fetchHtml url
      case mhtml of
        Nothing -> pure False
        Just html -> do
          let e = extractHtml html
          withImmediateTransaction conn $ do
            execute
              conn
              "UPDATE bookmarks SET title = CASE WHEN title = '' THEN ? ELSE title END, description = CASE WHEN description = '' THEN ? ELSE description END, sitename = CASE WHEN sitename = '' THEN ? ELSE sitename END, updated_at = strftime('%s','now') WHERE id = ?"
              (exTitle e, exDescription e, exSitename e, bid)
          pure True

data ES = ES
  { esTitle :: Text
  , esDescription :: Text
  , esText :: Text
  , esAuthor :: Text
  , esSitename :: Text
  }
