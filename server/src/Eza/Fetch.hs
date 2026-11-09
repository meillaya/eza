{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Outbound HTTP with a size cap, a timeout, and a private-network guard.
The guard resolves the host on every hop and rejects loopback, link-local,
private, documentation, and multicast addresses unless the caller opts in.

Requests identify eza with a versioned user agent, negotiate HTML with
@Accept@, and ask for English pages.  Responses expose the parsed content
type, the resolved charset (BOM, HTTP header, or meta tag), and whether the
body was truncated at the configured cap.  Document requests reject
non-text payloads and empty bodies instead of treating them as success.
-}
module Eza.Fetch (
    FetchOptions (..),
    FetchPage (..),
    FetchError (..),
    fetchUrl,
    postJson,
    documentOptions,
    anyOptions,
) where

import Control.Exception (SomeException, try)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as LBS
import Data.Char (isAlphaNum, toLower)
import Data.List (find)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word32)
import Network.HTTP.Client
import Network.HTTP.Types.Header (HeaderName, hAccept, hAcceptLanguage, hContentType, hLocation, hUserAgent)
import Network.HTTP.Types.Status (statusCode)
import Network.Socket
import Network.URI (parseURI, parseURIReference, relativeTo, uriScheme)

{- | Options for one fetch.  @foDocument@ marks a page fetch: non-text
content and empty bodies become errors.  @foMethod@ lets callers use HEAD.
-}
data FetchOptions = FetchOptions
    { foManager :: Manager
    , foTimeoutMs :: Int
    , foMaxBytes :: Int
    , foAllowPrivate :: Bool
    , foMethod :: BS.ByteString
    , foDocument :: Bool
    }

data FetchPage = FetchPage
    { fpFinalUrl :: Text
    , fpStatus :: Int
    , fpContentType :: Text
    , fpCharset :: Maybe Text
    , fpBody :: BS.ByteString
    , fpTruncated :: Bool
    }
    deriving (Show, Eq)

data FetchError
    = FetchInvalidUrl Text
    | FetchBlocked Text
    | FetchTooLarge
    | FetchRedirect
    | FetchHttp Int
    | FetchNetwork Text
    | FetchUnsupported Text
    | FetchEmpty
    deriving (Show, Eq)

-- | A page fetch with the default GET method.
documentOptions :: Manager -> Int -> Int -> Bool -> FetchOptions
documentOptions manager timeoutMs maxBytes allowPrivate =
    FetchOptions
        { foManager = manager
        , foTimeoutMs = timeoutMs
        , foMaxBytes = maxBytes
        , foAllowPrivate = allowPrivate
        , foMethod = "GET"
        , foDocument = True
        }

-- | A status/assets fetch: any content type and an empty body is acceptable.
anyOptions :: Manager -> Int -> Int -> Bool -> FetchOptions
anyOptions manager timeoutMs maxBytes allowPrivate =
    (documentOptions manager timeoutMs maxBytes allowPrivate){foDocument = False}

{- | POST one JSON body to an absolute http(s) URL. The response body is
drained (bounded) and discarded, and only the status code comes back, so a
webhook receiver cannot fill the database with its answer. Redirects are not
followed: a 3xx is 'FetchRedirect'. The private-network guard runs on the host
exactly like 'fetchUrl'. @foMaxBytes@ caps both the request body and the bytes
drained from the response.
-}
postJson :: FetchOptions -> Text -> [(HeaderName, BS.ByteString)] -> BS.ByteString -> IO (Either FetchError Int)
postJson opts rawUrl extraHeaders body
    | T.null stripped = pure (Left (FetchInvalidUrl rawUrl))
    | BS.length body > foMaxBytes opts = pure (Left FetchTooLarge)
    | otherwise =
        case parseURI (T.unpack stripped) of
            Nothing -> pure (Left (FetchInvalidUrl rawUrl))
            Just uri
                | schemeNotHttp (uriScheme uri) -> pure (Left (FetchInvalidUrl rawUrl))
                | otherwise -> do
                    requestResult <- try (parseRequest (T.unpack stripped))
                    case requestResult of
                        Left (err :: SomeException) -> pure (Left (FetchInvalidUrl (T.pack (show err))))
                        Right request -> do
                            allowed <- assertPublicHost opts (TE.decodeUtf8 (host request))
                            case allowed of
                                Left err -> pure (Left err)
                                Right () -> do
                                    let baseHeaders =
                                            [ (hContentType, "application/json")
                                            , (hUserAgent, userAgent)
                                            , (hAccept, "application/json")
                                            ]
                                        headers = baseHeaders <> filter (\(name, _) -> name `notElem` map fst baseHeaders) extraHeaders
                                        prepared =
                                            request
                                                { method = "POST"
                                                , redirectCount = 0
                                                , responseTimeout = responseTimeoutMicro (foTimeoutMs opts * 1000)
                                                , requestHeaders = headers
                                                , requestBody = RequestBodyBS body
                                                }
                                    outcome <-
                                        try
                                            ( withResponse prepared (foManager opts) $ \response -> do
                                                let code = statusCode (responseStatus response)
                                                drainBody 0 (responseBody response)
                                                pure code
                                            )
                                    pure $ case outcome of
                                        Left (err :: HttpException) -> Left (FetchNetwork (T.pack (show err)))
                                        Right code
                                            | code >= 200 && code < 300 -> Right code
                                            | code >= 300 && code < 400 -> Left FetchRedirect
                                            | otherwise -> Left (FetchHttp code)
  where
    stripped = T.strip rawUrl
    schemeNotHttp rawScheme =
        let scheme = map toLower (takeWhile (/= ':') rawScheme)
         in scheme /= "http" && scheme /= "https"
    drainBody total reader
        | total >= foMaxBytes opts = pure ()
        | otherwise = do
            chunk <- brRead reader
            if BS.null chunk then pure () else drainBody (total + BS.length chunk) reader

fetchUrl :: FetchOptions -> Text -> IO (Either FetchError FetchPage)
fetchUrl opts rawUrl
    | T.null (T.strip rawUrl) = pure (Left (FetchInvalidUrl rawUrl))
    | otherwise = go (0 :: Int) (T.strip rawUrl)
  where
    go hops url
        | hops > 4 = pure (Left FetchRedirect)
        | otherwise =
            case parseURI (T.unpack url) of
                Nothing -> pure (Left (FetchInvalidUrl url))
                Just uri
                    | scheme /= "http" && scheme /= "https" -> pure (Left (FetchInvalidUrl url))
                    | otherwise -> do
                        requestResult <- try (parseRequest (T.unpack url))
                        case requestResult of
                            Left (err :: SomeException) -> pure (Left (FetchInvalidUrl (T.pack (show err))))
                            Right request -> do
                                let hostName = TE.decodeUtf8 (host request)
                                allowed <- assertPublicHost opts hostName
                                case allowed of
                                    Left err -> pure (Left err)
                                    Right () -> do
                                        responseResult <-
                                            try
                                                ( httpLbs
                                                    ( request
                                                        { method = foMethod opts
                                                        , redirectCount = 0
                                                        , responseTimeout = responseTimeoutMicro (foTimeoutMs opts * 1000)
                                                        , requestHeaders = mergeHeaders (requestHeaders request)
                                                        }
                                                    )
                                                    (foManager opts)
                                                )
                                        case responseResult of
                                            Left (err :: HttpException) -> pure (Left (FetchNetwork (T.pack (show err))))
                                            Right response ->
                                                let code = statusCode (responseStatus response)
                                                    headers = responseHeaders response
                                                 in if code >= 300 && code < 400
                                                        then case lookup hLocation headers of
                                                            Nothing -> pure (Left (FetchHttp code))
                                                            Just location -> case resolve url (TE.decodeUtf8 location) of
                                                                Nothing -> pure (Left (FetchInvalidUrl (TE.decodeUtf8 location)))
                                                                Just next -> go (hops + 1) next
                                                        else
                                                            if code >= 400
                                                                then pure (Left (FetchHttp code))
                                                                else do
                                                                    let fullBody = LBS.toStrict (LBS.take (fromIntegral (foMaxBytes opts) + 1) (responseBody response))
                                                                        truncated = BS.length fullBody > foMaxBytes opts
                                                                        body = BS.take (foMaxBytes opts) fullBody
                                                                        rawContentType = maybe "" TE.decodeUtf8 (lookup hContentType headers)
                                                                        (contentType, headerCharset) = parseContentType rawContentType
                                                                    if foDocument opts && BS.null body
                                                                        then pure (Left FetchEmpty)
                                                                        else
                                                                            if foDocument opts && not (supportedContentType contentType)
                                                                                then pure (Left (FetchUnsupported contentType))
                                                                                else
                                                                                    pure
                                                                                        ( Right
                                                                                            FetchPage
                                                                                                { fpFinalUrl = url
                                                                                                , fpStatus = code
                                                                                                , fpContentType = contentType
                                                                                                , fpCharset = detectCharset body headerCharset
                                                                                                , fpBody = body
                                                                                                , fpTruncated = truncated
                                                                                                }
                                                                                        )
                  where
                    scheme = map toLower (takeWhile (/= ':') (uriScheme uri))

    mergeHeaders existing =
        [ (hUserAgent, userAgent)
        , (hAccept, acceptHeader)
        , (hAcceptLanguage, "en-US,en;q=0.9")
        ]
            <> filter (\(name, _) -> name `notElem` [hUserAgent, hAccept, hAcceptLanguage, hContentType]) existing

    resolve base reference =
        case parseURIReference (T.unpack reference) of
            Just uri
                | uriScheme uri /= "" -> Just (T.pack (show uri))
            _ -> case parseURI (T.unpack base) of
                Just baseUri -> case parseURIReference (T.unpack reference) of
                    Just resolved -> Just (T.pack (show (resolved `relativeTo` baseUri)))
                    Nothing -> Nothing
                Nothing -> Nothing

userAgent :: BS.ByteString
userAgent = "eza-bookmarks/0.1 (+https://github.com/meillaya/eza)"

acceptHeader :: BS.ByteString
acceptHeader = "text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,image/*;q=0.7,*/*;q=0.5"

-- | Split @text/html; charset=UTF-8@ into the media type and the charset.
parseContentType :: Text -> (Text, Maybe Text)
parseContentType raw =
    let parts = T.splitOn ";" raw
        mediaType = T.toLower (T.strip (fromMaybe "" (listToMaybe parts)))
        charset =
            listToMaybe
                [ T.toLower (trimQuotes (T.drop (T.length "charset=") trimmed))
                | param <- drop 1 parts
                , let trimmed = T.strip param
                , let lowered = T.toLower trimmed
                , "charset=" `T.isPrefixOf` lowered
                ]
     in (mediaType, charset)
  where
    trimQuotes value =
        let unquoted = T.dropAround (\c -> c == '"' || c == '\'') value
         in T.filter (\c -> not (c == ' ' || c == '\t')) unquoted

-- | Document requests only accept text-ish payloads.
supportedContentType :: Text -> Bool
supportedContentType contentType
    | T.null contentType = True
    | contentType `elem` ["application/xhtml+xml", "application/xml", "application/xml-dtd"] = True
    | "json" `T.isSuffixOf` contentType = False
    | "+json" `T.isSuffixOf` contentType = False
    | "text/" `T.isPrefixOf` contentType = True
    | otherwise = False

-- | Pick a charset from the BOM, then the HTTP header, then a meta tag.
detectCharset :: BS.ByteString -> Maybe Text -> Maybe Text
detectCharset body headerCharset =
    case bomCharset body of
        Just charset -> Just charset
        Nothing -> headerCharset `orElse` metaCharset (BS.take 4096 body)

bomCharset :: BS.ByteString -> Maybe Text
bomCharset body
    | BS.take 3 body == BS.pack [0xEF, 0xBB, 0xBF] = Just "utf-8"
    | BS.take 2 body == BS.pack [0xFF, 0xFE] = Just "utf-16le"
    | BS.take 2 body == BS.pack [0xFE, 0xFF] = Just "utf-16be"
    | otherwise = Nothing

metaCharset :: BS.ByteString -> Maybe Text
metaCharset prefix =
    let lowered = T.toLower (T.pack (BSC.unpack (BS.map (\byte -> if byte < 128 then byte else 32) prefix)))
        candidates =
            [ takeCharset afterEq
            | (_, afterEq) <- splitsOn "charset=" lowered
            ]
     in listToMaybe (mapMaybe id candidates)
  where
    splitsOn needle haystack =
        case T.breakOn needle haystack of
            (_, rest) | T.null rest -> []
            (before, rest) -> (before, T.drop (T.length needle) rest) : splitsOn needle (T.drop (T.length needle) rest)
    takeCharset value =
        let cleaned = T.takeWhile (\c -> isAlphaNum c || c == '-' || c == '_') (T.dropWhile (\c -> c == '"' || c == '\'' || c == ' ' || c == '\t') value)
         in if T.null cleaned then Nothing else Just (T.toLower cleaned)

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just value) _ = Just value
orElse Nothing fallback = fallback

-- ---------------------------------------------------------------------------
-- Private-network guard
-- ---------------------------------------------------------------------------

assertPublicHost :: FetchOptions -> Text -> IO (Either FetchError ())
assertPublicHost opts host
    | foAllowPrivate opts = pure (Right ())
    | T.null host = pure (Left (FetchInvalidUrl host))
    | otherwise = do
        result <- try (getAddrInfo (Just defaultHints{addrSocketType = Stream}) (Just (T.unpack host)) Nothing)
        case result of
            Left (err :: SomeException) -> pure (Left (FetchNetwork (T.pack (show err))))
            Right [] -> pure (Left (FetchNetwork ("no address for " <> host)))
            Right addresses ->
                pure $ case find (isPrivateAddress . addrAddress) addresses of
                    Just _ -> Left (FetchBlocked ("refusing private address for " <> host))
                    Nothing -> Right ()

isPrivateAddress :: SockAddr -> Bool
isPrivateAddress address = case address of
    -- SockAddrInet stores the address in network byte order; the masks below
    -- are written in host order.
    SockAddrInet _ hostAddress -> not (publicV4 (byteSwap32 hostAddress))
    SockAddrInet6 _ _ hostAddress _ -> not (publicV6 hostAddress)
    _ -> True

byteSwap32 :: Word32 -> Word32
byteSwap32 value =
    (value .&. 0x000000ff) `shiftL` 24
        .|. (value .&. 0x0000ff00) `shiftL` 8
        .|. (value .&. 0x00ff0000) `shiftR` 8
        .|. (value .&. 0xff000000) `shiftR` 24

publicV4 :: Word32 -> Bool
publicV4 address =
    not
        ( address <= 0xffffff
            || address .&. 0xff000000 == 0x0a000000
            || address .&. 0xff000000 == 0x7f000000
            || address .&. 0xffff0000 == 0xa9fe0000
            || address .&. 0xfff00000 == 0xac100000
            || address .&. 0xffff0000 == 0xc0a80000
            || address .&. 0xffff0000 == 0xc6120000
            || address .&. 0xffffff00 == 0xc0000000
            || address .&. 0xffffff00 == 0xc0000200
            || address .&. 0xfffe0000 == 0xc6120000
            || address .&. 0xffffff00 == 0xc6336400
            || address .&. 0xffffff00 == 0xcb007100
            || address .&. 0xf0000000 == 0xe0000000
            || address .&. 0xf0000000 == 0xf0000000
        )

publicV6 :: HostAddress6 -> Bool
publicV6 (a, b, c, d) =
    not
        ( (a, b, c, d) == (0, 0, 0, 0)
            || (a, b, c, d) == (0, 0, 0, 1)
            || (a, b, c) == (0, 0, 0xffff)
            || a .&. 0xfe000000 == 0xfc000000
            || a .&. 0xffc00000 == 0xfe800000
            || a .&. 0xff000000 == 0xff000000
            || a == 0x20010db8
        )
