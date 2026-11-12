{-# LANGUAGE OverloadedStrings #-}

{- | Favicon parsing, storage, and serving. Icons are stored as bytes in
SQLite so a single database backup contains the whole state.
-}
module Eza.Favicon (
    Favicon (..),
    faviconFor,
    getFavicon,
    putFavicon,
    recordFaviconFailure,
    parseIconLinks,
    parseDataIcon,
    sniffImage,
    iconUrlFor,
    normalizeIcon,
) where

import Crypto.Hash (Digest, SHA256, hash)
import Data.Bits (shiftL)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Data.List (minimumBy, sortOn)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word16, Word32)
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
    -- Failure rows keep the domain parked and are not icons: a placeholder
    -- byte must never be served as an image. The handler redirects to the
    -- static fallback instead.
    rows <-
        query
            conn
            "SELECT domain, mime, bytes, etag, source_url FROM favicons WHERE domain = ? AND fail_count = 0 AND length(bytes) > 1"
            (Only domain) ::
            IO [(Text, Text, ByteString, Text, Text)]
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

{- | Return icon links in preference order. Plain @icon@ links come before
apple-touch icons, light/no-media before dark variants, declared sizes close to
64px before very large or unknown icons, and raster before SVG (SVG is rejected
later). Relative links honor @<base href>@ and resolve against the page URL per
RFC 3986; the historical directory-style resolution is kept as a fallback for
extensionless pages.
-}
parseIconLinks :: Text -> Text -> [Text]
parseIconLinks html baseUrl =
    dedupe
        ( concat
            [ resolveCandidates effectiveBase href
            | attrs <- sorted
            , let href = T.strip (attr "href" attrs)
            , not (T.null href)
            ]
        )
  where
    tags = parseTags html
    baseHref = listToMaybe [T.strip (attr "href" attrs) | TagOpen "base" attrs <- tags, not (T.null (T.strip (attr "href" attrs)))]
    effectiveBase = fromMaybe baseUrl (baseHref >>= resolveOne baseUrl)
    sorted =
        map
            snd
            ( sortOn
                fst
                [ (score index attrs, attrs)
                | (index, TagOpen "link" attrs) <- zip [0 :: Int ..] tags
                , let rel = T.toLower (attr "rel" attrs)
                , ("icon" `T.isInfixOf` rel) || ("apple-touch-icon" `T.isInfixOf` rel)
                , not (T.null (T.strip (attr "href" attrs)))
                ]
            )
    score index attrs =
        let rel = T.toLower (attr "rel" attrs)
            media = T.toLower (attr "media" attrs)
            typeAttr = T.toLower (attr "type" attrs)
            apple = if "apple-touch-icon" `T.isInfixOf` rel then 1 else 0 :: Int
            svg = if "svg" `T.isInfixOf` typeAttr then 1 else 0 :: Int
            dark = if "dark" `T.isInfixOf` media then 1 else 0 :: Int
            width = declaredWidth (attr "sizes" attrs)
            oversize = if apple == 0 && width > 128 then 1 else 0 :: Int
            sizeRank
                | width >= 32 && width <= 96 = 0 :: Int
                | width >= 16 && width <= 128 = 1
                | width > 128 = 2
                | otherwise = 3
            distance = if width == 0 then 32 else abs (width - 64)
         in (oversize, svg, apple, dark, sizeRank, distance, index)
    attr key attrs = maybe "" id (lookup key [(T.toLower k, v) | (k, v) <- attrs])
    declaredWidth sizes =
        let raw = T.takeWhile (\c -> c /= 'x' && c /= 'X') (T.strip sizes)
         in case reads (T.unpack raw) of
                [(n, "")] -> n :: Int
                _ -> 0
    resolveCandidates base href =
        case resolveOne base href of
            Nothing -> []
            Just primary ->
                case resolveOne (ensureDirectoryBase base) href of
                    Just fallback | fallback /= primary -> [primary, fallback]
                    _ -> [primary]
    resolveOne base href =
        case parseURIReference (T.unpack href) of
            Just uri | uriScheme uri /= "" -> Just (T.pack (show uri))
            _ -> case parseURI (T.unpack base) of
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
            (_, rest) = T.breakOn ";" after
            (_, payload) = T.breakOn "," rest
            bytes = B64.decode (TE.encodeUtf8 (T.drop 1 payload))
         in case bytes of
                Right raw | not (BS.null raw) ->
                    case sniffImage raw of
                        Just mime -> Just (mime, raw)
                        Nothing -> Nothing
                _ -> Nothing

{- | Validate and normalize an icon body. ICO files are cropped to a complete
entry (the largest complete entry at or below 128px where possible); PNG/JPEG/
WebP must be complete. SVG is deliberately rejected. Returns the sniffed MIME
and the bytes to store.
-}
normalizeIcon :: ByteString -> Maybe (Text, ByteString)
normalizeIcon bytes = do
    mime <- sniffImage bytes
    normalized <-
        case mime of
            "image/x-icon" -> normalizeIco bytes
            _
                | imageComplete mime bytes -> Just bytes
                | otherwise -> Nothing
    pure (mime, normalized)

imageComplete :: Text -> ByteString -> Bool
imageComplete mime bytes = case mime of
    "image/png" -> pngIend `BS.isSuffixOf` bytes
    "image/jpeg" -> jpegEoi `BS.isSuffixOf` bytes
    "image/webp" -> webpComplete bytes
    _ -> False
  where
    pngIend = BS.pack [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]
    jpegEoi = BS.pack [0xff, 0xd9]
    webpComplete raw =
        BS.length raw >= 12
            && BS.take 4 raw == BS.pack [0x52, 0x49, 0x46, 0x46]
            && BS.take 4 (BS.drop 8 raw) == BS.pack [0x57, 0x45, 0x42, 0x50]
            && (fromIntegral (word32At raw 4) :: Int) + 8 <= BS.length raw

data IcoEntry = IcoEntry
    { ieWidth :: Int
    , ieHeight :: Int
    , ieBits :: Int
    , ieSize :: Int
    , ieOffset :: Int
    , ieRaw :: ByteString
    }

normalizeIco :: ByteString -> Maybe ByteString
normalizeIco bytes = do
    entries <- icoEntries bytes
    let complete =
            [ entry
            | entry <- entries
            , ieSize entry > 0
            , ieOffset entry + ieSize entry <= BS.length bytes
            ]
    chosen <- case complete of
        [] -> Nothing
        (first : rest) -> Just (minimumBy (comparing entryKey) (first : rest))
    let entry = rewriteOffset chosen
        header =
            BB.word16LE 0
                <> BB.word16LE 1
                <> BB.word16LE 1
        payload = BS.take (ieSize chosen) (BS.drop (ieOffset chosen) bytes)
    pure (BL.toStrict (BB.toLazyByteString (header <> BB.byteString entry <> BB.byteString payload)))
  where
    entryKey entry = (rank (ieWidth entry), abs (ieWidth entry - 64), negate (ieWidth entry), ieBits entry)
    rank width
        | width >= 32 && width <= 96 = 0 :: Int
        | width >= 16 && width <= 128 = 1
        | otherwise = 2
    rewriteOffset entry =
        let raw = ieRaw entry
         in BL.toStrict
                ( BB.toLazyByteString
                    (BB.byteString (BS.take 12 raw) <> BB.word32LE 22 <> BB.byteString (BS.drop 16 raw))
                )

icoEntries :: ByteString -> Maybe [IcoEntry]
icoEntries bytes
    | BS.length bytes < 6 = Nothing
    | word16At bytes 0 /= 0 = Nothing
    | word16At bytes 2 `notElem` [1, 2] = Nothing
    | count <= 0 = Nothing
    | 6 + 16 * count > BS.length bytes = Nothing
    | otherwise = Just (map entryAt [0 .. count - 1])
  where
    count = fromIntegral (word16At bytes 4) :: Int
    entryAt index =
        let offset = 6 + 16 * index
            raw = BS.take 16 (BS.drop offset bytes)
            width = fromIntegral (BS.index bytes offset) :: Int
            height = fromIntegral (BS.index bytes (offset + 1)) :: Int
            bits = fromIntegral (word16At bytes (offset + 6)) :: Int
            size = fromIntegral (word32At bytes (offset + 8)) :: Int
            imageOffset = fromIntegral (word32At bytes (offset + 12)) :: Int
         in IcoEntry
                { ieWidth = if width == 0 then 256 else width
                , ieHeight = if height == 0 then 256 else height
                , ieBits = bits
                , ieSize = size
                , ieOffset = imageOffset
                , ieRaw = raw
                }

word16At :: ByteString -> Int -> Word16
word16At bytes index =
    fromIntegral (BS.index bytes index)
        + (fromIntegral (BS.index bytes (index + 1)) `shiftL` 8)

word32At :: ByteString -> Int -> Word32
word32At bytes index =
    fromIntegral (BS.index bytes index)
        + (fromIntegral (BS.index bytes (index + 1)) `shiftL` 8)
        + (fromIntegral (BS.index bytes (index + 2)) `shiftL` 16)
        + (fromIntegral (BS.index bytes (index + 3)) `shiftL` 24)

{- | Minimum magic-byte check. SVG is rejected because serving an untrusted
SVG from the eza origin would create an active-content path.
-}
sniffImage :: ByteString -> Maybe Text
sniffImage bytes
    | BS.take 8 bytes == BS.pack [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] = Just "image/png"
    | BS.take 3 bytes == BS.pack [0xff, 0xd8, 0xff] = Just "image/jpeg"
    | BS.take 4 bytes == BS.pack [0x00, 0x00, 0x01, 0x00] = Just "image/x-icon"
    | BS.take 4 bytes == BS.pack [0x52, 0x49, 0x46, 0x46] && BS.take 4 (BS.drop 8 bytes) == BS.pack [0x57, 0x45, 0x42, 0x50] = Just "image/webp"
    | otherwise = Nothing
