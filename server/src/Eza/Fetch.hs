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
    readCappedBody,
    documentOptions,
    anyOptions,
    assertPublicHost,
    assertPublicHostPolicy,
    publicV4,
    publicV6,
) where

import Control.Exception (SomeException, try)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
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
                            allowed <- checkHost (host request)
                            case allowed of
                                Left err -> pure (Left err)
                                Right () -> sendPost request
  where
    stripped = T.strip rawUrl
    schemeNotHttp rawScheme =
        let scheme = map toLower (takeWhile (/= ':') rawScheme)
         in scheme /= "http" && scheme /= "https"
    {- Resolve once more right before the request is handed to the HTTP
    manager. The manager resolves the name again when it opens the
    connection, so this narrows the resolve-then-connect window; it cannot
    close it without pinning the peer address.
    -}
    checkHost rawHost = do
        first <- assertPublicHost opts (TE.decodeUtf8 rawHost)
        case first of
            Left err -> pure (Left err)
            Right () -> assertPublicHost opts (TE.decodeUtf8 rawHost)
    sendPost request = do
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
                    | schemeOf uri /= "http" && schemeOf uri /= "https" ->
                        pure (Left (FetchInvalidUrl url))
                    | otherwise -> do
                        requestResult <- try (parseRequest (T.unpack url))
                        case requestResult of
                            Left (err :: SomeException) ->
                                pure (Left (FetchInvalidUrl (T.pack (show err))))
                            Right request -> do
                                let hostName = TE.decodeUtf8 (host request)
                                allowed <- assertPublicHost opts hostName
                                case allowed of
                                    Left err -> pure (Left err)
                                    {- Resolve once more immediately before the
                                    request; see the note in 'postJson'.
                                    -}
                                    Right () -> do
                                        recheck <- assertPublicHost opts hostName
                                        case recheck of
                                            Left err -> pure (Left err)
                                            Right () -> do
                                                responseResult <-
                                                    try
                                                        ( withResponse
                                                            ( request
                                                                { method = foMethod opts
                                                                , redirectCount = 0
                                                                , responseTimeout = responseTimeoutMicro (foTimeoutMs opts * 1000)
                                                                , requestHeaders = mergeHeaders (requestHeaders request)
                                                                }
                                                            )
                                                            (foManager opts)
                                                            (handleResponse url)
                                                        )
                                                case responseResult of
                                                    Left (err :: HttpException) ->
                                                        pure (Left (FetchNetwork (T.pack (show err))))
                                                    Right (Left err) -> pure (Left err)
                                                    Right (Right (Left next)) -> go (hops + 1) next
                                                    Right (Right (Right page)) -> pure (Right page)

    handleResponse url response = do
        let code = statusCode (responseStatus response)
            headers = responseHeaders response
        if code >= 300 && code < 400
            then case lookup hLocation headers of
                Nothing -> pure (Left (FetchHttp code))
                Just location -> case resolveUrl url (TE.decodeUtf8 location) of
                    Nothing -> pure (Left (FetchInvalidUrl (TE.decodeUtf8 location)))
                    Just next -> pure (Right (Left next))
            else
                if code >= 400
                    then pure (Left (FetchHttp code))
                    else do
                        (body, truncated) <- readCappedBody (foMaxBytes opts) (brRead (responseBody response))
                        let rawContentType = maybe "" TE.decodeUtf8 (lookup hContentType headers)
                            (contentType, headerCharset) = parseContentType rawContentType
                        if foDocument opts && BS.null body
                            then pure (Left FetchEmpty)
                            else
                                if foDocument opts && not (supportedContentType contentType)
                                    then pure (Left (FetchUnsupported contentType))
                                    else
                                        pure
                                            ( Right
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
                                            )

    mergeHeaders existing =
        [ (hUserAgent, userAgent)
        , (hAccept, acceptHeader)
        , (hAcceptLanguage, "en-US,en;q=0.9")
        ]
            <> filter (\(name, _) -> name `notElem` [hUserAgent, hAccept, hAcceptLanguage, hContentType]) existing

    resolveUrl base reference =
        case parseURIReference (T.unpack reference) of
            Just uri
                | uriScheme uri /= "" -> Just (T.pack (show uri))
            _ -> case parseURI (T.unpack base) of
                Just baseUri -> case parseURIReference (T.unpack reference) of
                    Just resolved -> Just (T.pack (show (resolved `relativeTo` baseUri)))
                    Nothing -> Nothing
                Nothing -> Nothing

    schemeOf uri = map toLower (takeWhile (/= ':') (uriScheme uri))

{- | Read at most @limit@ bytes from a chunk reader and report whether more
bytes were available. Keeping the loop separate makes the cap testable without
a live HTTP server; the reader is a single @brRead@-style action.
-}
readCappedBody :: Int -> IO BS.ByteString -> IO (BS.ByteString, Bool)
readCappedBody limit readChunk
    | limit <= 0 = do
        chunk <- readChunk
        pure (BS.empty, not (BS.null chunk))
    | otherwise = go 0 []
  where
    target = limit + 1
    go total chunks = do
        chunk <- readChunk
        if BS.null chunk
            then pure (BS.concat (reverse chunks), False)
            else
                if total + BS.length chunk >= target
                    then
                        let remaining = max 0 (target - total)
                            kept = BS.take remaining chunk
                            body = BS.take limit (BS.concat (reverse (kept : chunks)))
                         in pure (body, total + BS.length chunk > limit)
                    else go (total + BS.length chunk) (chunk : chunks)

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

{- | The public-host policy shared by every egress path. Resolves the host and
rejects loopback, private, link-local, CGNAT, documentation, and multicast
addresses unless the caller opted in. Exposed so callers that spawn their
own network client (the snapshot tool) can enforce the same policy.
-}
assertPublicHostPolicy :: Bool -> Text -> IO (Either FetchError ())
assertPublicHostPolicy allowPrivate host
    | allowPrivate = pure (Right ())
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

assertPublicHost :: FetchOptions -> Text -> IO (Either FetchError ())
assertPublicHost opts = assertPublicHostPolicy (foAllowPrivate opts)

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

{- | Whether an IPv4 address (in host order) may be reached. 100.64.0.0/10 is
counted as private: it is the carrier-grade NAT range, used by Tailscale and
some carriers, and is not a public destination.
-}
publicV4 :: Word32 -> Bool
publicV4 address =
    not
        ( address <= 0xffffff
            || address .&. 0xff000000 == 0x0a000000
            || address .&. 0xff000000 == 0x7f000000
            || address .&. 0xffff0000 == 0xa9fe0000
            || address .&. 0xfff00000 == 0xac100000
            || address .&. 0xffff0000 == 0xc0a80000
            || address .&. 0xffc00000 == 0x64400000
            || address .&. 0xffff0000 == 0xc6120000
            || address .&. 0xffffff00 == 0xc0000000
            || address .&. 0xffffff00 == 0xc0000200
            || address .&. 0xfffe0000 == 0xc6120000
            || address .&. 0xffffff00 == 0xc6336400
            || address .&. 0xffffff00 == 0xcb007100
            || address .&. 0xf0000000 == 0xe0000000
            || address .&. 0xf0000000 == 0xf0000000
        )

{- | Whether an IPv6 address (in network order) may be reached. Besides the
special, private, link-local, multicast, and documentation ranges, the blocked
set covers every prefix that can carry or tunnel an IPv4 address: IPv4-mapped
(@::ffff:0:0/96@), IPv4-compatible (@::/96@), 6to4 (@2002::/16@), Teredo
(@2001:0000::/32@), and the NAT64 prefixes (@64:ff9b::/96@ and
@64:ff9b:1::/48@). On a host that routes one of those prefixes to IPv4, a
literal IPv6 URL would otherwise reach a loopback or private destination and
bypass the policy.
-}
publicV6 :: HostAddress6 -> Bool
publicV6 (a, b, c, d) =
    not
        ( (a, b, c, d) == (0, 0, 0, 0)
            || (a, b, c, d) == (0, 0, 0, 1)
            -- IPv4-compatible: ::/96 embeds an IPv4 address in the low word.
            || a == 0 && b == 0 && c == 0
            -- IPv4-mapped: ::ffff:0:0/96 is the other common embedding.
            || (a, b, c) == (0, 0, 0xffff)
            -- 6to4: 2002::/16 carries an arbitrary IPv4 address in bits 16-47.
            || a .&. 0xffff0000 == 0x20020000
            -- Teredo: 2001:0000::/32 tunnels IPv4 over UDP.
            || a == 0x20010000
            -- NAT64 well-known prefix and the local-use prefix.
            || a == 0x0064ff9b && b == 0 && c == 0
            || a == 0x0064ff9b && b .&. 0xffff0000 == 0x00010000
            -- 100::/64 is the discard-only prefix.
            || a == 0x01000000 && b == 0
            -- 2001:2::/48 is reserved for benchmarking.
            || a == 0x20010002 && b .&. 0xffff0000 == 0
            || a .&. 0xfe000000 == 0xfc000000
            || a .&. 0xffc00000 == 0xfe800000
            || a .&. 0xff000000 == 0xff000000
            || a == 0x20010db8
        )
