{-# LANGUAGE OverloadedStrings #-}

-- | Favicon parsing, storage, and serving. Icons are stored as bytes in
-- SQLite so a single database backup contains the whole state.
module Eza.Favicon
  ( Favicon (..)
  , faviconFor
  , getFavicon
  , putFavicon
  , recordFaviconFailure
  , parseIconLinks
  , parseDataIcon
  , sniffImage
  , iconUrlFor
  ) where

import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.List (sortOn)
import qualified Data.ByteString.Base64 as B64
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import Network.URI (parseURI, parseURIReference, relativeTo, uriScheme)
import Text.HTML.TagSoup

data Favicon = Favicon
  { fvDomain :: Text
  , fvMime :: Text
  , fvBytes :: ByteString
  , fvEtag :: Text
  , fvSourceUrl :: Text
  }
  deriving (Show, Eq)

epoch :: IO Int
epoch = floor <$> getPOSIXTime

faviconFor :: Text -> Text
faviconFor domain = "/api/v1/favicons/" <> domain

iconUrlFor :: Text -> Text -> Text
iconUrlFor domain contentHash
  | T.null contentHash = faviconFor domain
  | otherwise = faviconFor domain <> "?v=" <> T.take 8 contentHash

getFavicon :: Connection -> Text -> IO (Maybe Favicon)
getFavicon conn domain = do
  rows <-
    query
      conn
      "SELECT domain, mime, bytes, etag, source_url FROM favicons WHERE domain = ?"
      (Only domain) :: IO [(Text, Text, ByteString, Text, Text)]
  pure $ case rows of
    [(d, mime, bytes, etag, source)] -> Just (Favicon d mime bytes etag source)
    _ -> Nothing

putFavicon :: Connection -> Text -> Text -> Text -> ByteString -> IO Text
putFavicon conn domain source mime bytes = do
  now <- epoch
  let contentHash = T.pack (show (hash bytes :: Digest SHA256))
      etag = "\"" <> T.take 32 contentHash <> "\""
  withImmediateTransaction conn $
    execute
      conn
      "INSERT INTO favicons (domain, source_url, mime, bytes, content_hash, etag, fetched_at, last_error, fail_count) VALUES (?,?,?,?,?,?,?,'',0) ON CONFLICT(domain) DO UPDATE SET source_url=excluded.source_url, mime=excluded.mime, bytes=excluded.bytes, content_hash=excluded.content_hash, etag=excluded.etag, fetched_at=excluded.fetched_at, last_error='', fail_count=0"
      (domain, source, mime, bytes, contentHash, etag, now)
  pure contentHash

recordFaviconFailure :: Connection -> Text -> Text -> IO ()
recordFaviconFailure conn domain message = do
  now <- epoch
  execute
    conn
    "INSERT INTO favicons (domain, source_url, mime, bytes, fetched_at, last_error, fail_count) VALUES (?,?,'image/x-icon',x'00',?,?,1) ON CONFLICT(domain) DO UPDATE SET last_error=excluded.last_error, fail_count=favicons.fail_count+1"
    (domain, ("" :: Text), now, message)
  pure ()

-- | Return icon links in preference order: larger declared sizes first, then
-- apple-touch-icon, then shortcut and plain icon.
parseIconLinks :: Text -> Text -> [Text]
parseIconLinks html baseUrl =
  let links = [attrs | TagOpen "link" attrs <- parseTags html]
      candidates =
        [ (score attrs, resolve baseUrl href)
        | attrs <- links
        , let rel = T.toLower (attr "rel" attrs)
        , ("icon" `T.isInfixOf` rel) || ("apple-touch-icon" `T.isInfixOf` rel)
        , let href = T.strip (attr "href" attrs)
        , not (T.null href)
        ]
   in dedupe [url | (_, Just url) <- reverse (sortOn fst candidates)]
  where
    attr key attrs = maybe "" id (lookup key [(T.toLower k, v) | (k, v) <- attrs])
    score attrs =
      let rel = T.toLower (attr "rel" attrs)
          size = attr "sizes" attrs
          numeric = case T.breakOn "x" size of
            (w, _) -> maybe 0 id (readMaybeText w)
       in (if "apple-touch-icon" `T.isInfixOf` rel then 1 else 0 :: Int, numeric)
    readMaybeText t = case reads (T.unpack t) of
      [(n, "")] -> Just (n :: Int)
      _ -> Nothing
    resolve base href =
      let base' = ensureDirectoryBase base
       in case parseURIReference (T.unpack href) of
        Just uri | uriScheme uri /= "" -> Just (T.pack (show uri))
        _ -> case parseURI (T.unpack base') of
          Just baseUri -> case parseURIReference (T.unpack href) of
            Just resolved -> Just (T.pack (show (resolved `relativeTo` baseUri)))
            Nothing -> Nothing
          Nothing -> Nothing
    ensureDirectoryBase base =
      let (path, queryPart) = T.breakOn "?" base
          lastSegment = snd (T.breakOnEnd "/" path)
       in if T.null queryPart && not (T.null lastSegment) && not ("." `T.isInfixOf` lastSegment)
            then path <> "/" <> queryPart
            else base
    dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

parseDataIcon :: Text -> Maybe (Text, ByteString)
parseDataIcon value
  | not ("data:image/" `T.isPrefixOf` T.toLower value) = Nothing
  | otherwise =
      let after = T.drop 5 value
          (mimePart, rest) = T.breakOn ";" after
          mime = T.toLower (T.strip mimePart)
          (_, payload) = T.breakOn "," rest
          bytes = B64.decode (TE.encodeUtf8 (T.drop 1 payload))
       in case bytes of
            Right raw | not (BS.null raw) -> Just (mime, raw)
            _ -> Nothing

-- | Minimum magic-byte check. SVG is rejected because serving an untrusted
-- SVG from the eza origin would create an active-content path.
sniffImage :: ByteString -> Maybe Text
sniffImage bytes
  | BS.take 8 bytes == BS.pack [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] = Just "image/png"
  | BS.take 3 bytes == BS.pack [0xff, 0xd8, 0xff] = Just "image/jpeg"
  | BS.take 4 bytes == BS.pack [0x00, 0x00, 0x01, 0x00] = Just "image/x-icon"
  | BS.take 4 bytes == BS.pack [0x52, 0x49, 0x46, 0x46] && BS.take 4 (BS.drop 8 bytes) == BS.pack [0x57, 0x45, 0x42, 0x50] = Just "image/webp"
  | otherwise = Nothing
