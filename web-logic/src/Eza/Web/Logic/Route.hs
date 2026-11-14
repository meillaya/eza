{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The client URL algebra, free of Miso.

The client route type lives here so a native test suite can exercise the URL
grammar without a WebAssembly toolchain. "Eza.Web.Model" keeps only the Miso
boundary: it converts a 'Miso.Router.URI' to 'Text' before calling
'routeOfUri', and it feeds 'routeUriParts' to its 'Miso.Router.Router'
instance.

Parsing is total. Unknown paths become 'NotFound', and percent-decoding never
throws: an invalid escape or invalid UTF-8 falls back to the raw text. Path
segments stay percent-encoded, exactly as the previous Miso-based classifier
kept them; only query values are decoded (with @+@ as space), which is what
the PWA share target sends.
-}
module Eza.Web.Logic.Route (
    Route (..),
    routeOfUri,
    routeToUri,
    routeUriParts,
    routeTitle,
    routeSubtitle,
    isGraphRoute,
    percentDecode,
    percentEncode,
) where

import qualified Data.ByteString as BS
import Data.Char (chr, isAlphaNum, isDigit, ord)
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8')
import Text.Read (readMaybe)

{- | Application routes. @Bookmark@ carries the numeric bookmark id; every
other parameter is a path segment or query value as parsed below.

The constructor set is unchanged from the client's previous local route type,
so a native round-trip test can cover every page the client renders.
-}
data Route
    = Index
    | Bookmark Int
    | Inbox
    | Graph
    | GraphLocal Int Int
    | Views
    | ViewOpen Text
    | Dedup
    | Tags
    | AiTags
    | Maintenance
    | Account
    | History
    | Save (Maybe Text) (Maybe Text) (Maybe Text)
    | NotFound
    deriving (Eq, Show)

-- ---------------------------------------------------------------- parsing ---

{- | Classify a concrete URL path (with optional query string and fragment)
into a 'Route'. The function is total: anything unrecognised is 'NotFound'.

This mirrors the previous Miso classifier step for step: the fragment is
ignored, the path is split on @/@ and empty segments are dropped, and query
values are percent-decoded. The graph-local depth is clamped to 1..3 and
defaults to 1; a focus key without @local=1@ is the whole-library graph.
-}
routeOfUri :: Text -> Route
routeOfUri raw = case pathSegments of
    [] -> Index
    ["bookmark", n] -> maybe NotFound Bookmark (readInt n)
    ["inbox"] -> Inbox
    ["graph"]
        | queryValue "local" == Just "1"
        , Just focusKey <- queryValue "focus" >>= readInt ->
            GraphLocal focusKey (clampDepth (queryValue "depth" >>= readInt))
        | otherwise -> Graph
    ["views"] -> Views
    ["views", slug] -> ViewOpen slug
    ["dedup"] -> Dedup
    ["tags"] -> Tags
    ["tags", "ai"] -> AiTags
    ["maintenance"] -> Maintenance
    ["account"] -> Account
    ["history"] -> History
    ["accessions"] -> History
    -- PWA share_target landing page: /save?title=..&text=..&url=..
    ["save"] -> Save (queryValue "title") (queryValue "text") (queryValue "url")
    _ -> NotFound
  where
    pathSegments = filter (not . T.null) (T.splitOn "/" pathPart)
    (pathPart, queryPart) = T.breakOn "?" (fst (T.breakOn "#" raw))
    -- A missing key and a bare flag both have no value; only a k=v pair
    -- carries a decoded value.
    queryValue key = case lookup key (queryPairs queryPart) of
        Just (Just value) -> Just value
        _ -> Nothing

clampDepth :: Maybe Int -> Int
clampDepth (Just depth) = max 1 (min 3 depth)
clampDepth Nothing = 1

{- | Split a raw query string into key/value pairs. A key without @=@ is a
flag with no value; the first occurrence of a key wins, as the previous
Miso map-based parser did.
-}
queryPairs :: Text -> [(Text, Maybe Text)]
queryPairs queryPart =
    map pair (filter (not . T.null) (T.splitOn "&" (T.dropWhile (== '?') queryPart)))
  where
    pair item = case T.breakOn "=" item of
        (key, rest)
            | T.null rest -> (key, Nothing)
            | otherwise -> (key, Just (percentDecode (T.drop 1 rest)))

readInt :: Text -> Maybe Int
readInt = readMaybe . T.unpack

{- | Decode a URL query value: @%XX@ escapes and @+@ as space, UTF-8 aware.
An invalid escape or byte sequence returns the input unchanged.
-}
percentDecode :: Text -> Text
percentDecode raw =
    case decodeUtf8' (BS.pack (map fromIntegral (decodeBytes (T.unpack raw)))) of
        Right decoded -> decoded
        Left _ -> raw
  where
    decodeBytes [] = []
    decodeBytes ('%' : a : b : rest)
        | Just hi <- hexValue a
        , Just lo <- hexValue b =
            hi * 16 + lo : decodeBytes rest
    decodeBytes ('+' : rest) = 32 : decodeBytes rest
    decodeBytes (c : rest) = utf8 (fromEnum c) ++ decodeBytes rest

    hexValue c
        | isDigit c = Just (fromEnum c - fromEnum '0')
        | c >= 'a' && c <= 'f' = Just (fromEnum c - fromEnum 'a' + 10)
        | c >= 'A' && c <= 'F' = Just (fromEnum c - fromEnum 'A' + 10)
        | otherwise = Nothing

-- ---------------------------------------------------------------- printing ---

{- | Render a route to its concrete path text: the path segments plus the query
string, with no fragment. This is what the client pushes to browser history
and what the @Router@ instance reconstructs its tokens from.

The output matches the previous miso @prettyURI . toURI@ rendering, including
the alphabetical query order that rendering produced through its @Map@.
-}
routeToUri :: Route -> Text
routeToUri route =
    case routeUriParts route of
        ([], []) -> "/"
        (segments, query) -> renderPath segments <> renderQuery query
  where
    renderPath [] = "/"
    renderPath segments = "/" <> T.intercalate "/" segments
    renderQuery [] = ""
    renderQuery query = "?" <> T.intercalate "&" [key <> "=" <> value | (key, value) <- query]

{- | The raw path segments and query parameters of a route. Path segments are
percent-encoded by the caller where an endpoint requires it; 'routeToUri'
renders them verbatim, and the web @Router@ instance turns them back into
tokens. Query parameters are sorted by key to match the client's historical
URL rendering.
-}
routeUriParts :: Route -> ([Text], [(Text, Text)])
routeUriParts = \case
    Index -> ([], [])
    Bookmark bookmarkId -> (["bookmark", intText bookmarkId], [])
    Inbox -> (["inbox"], [])
    Graph -> (["graph"], [])
    GraphLocal rootKey depth ->
        ( ["graph"]
        , sortOn
            fst
            [ ("focus", intText rootKey)
            , ("depth", intText depth)
            , ("local", "1")
            ]
        )
    Views -> (["views"], [])
    ViewOpen slug -> (["views", slug], [])
    Dedup -> (["dedup"], [])
    Tags -> (["tags"], [])
    AiTags -> (["tags", "ai"], [])
    Maintenance -> (["maintenance"], [])
    Account -> (["account"], [])
    History -> (["history"], [])
    Save title body url ->
        ( ["save"]
        , sortOn
            fst
            ( [("title", value) | Just value <- [title]]
                <> [("text", value) | Just value <- [body]]
                <> [("url", value) | Just value <- [url]]
            )
        )
    NotFound -> (["not-found"], [])

intText :: Int -> Text
intText = T.pack . show

-- | Both graph routes share the plate and the graph keyboard handling.
isGraphRoute :: Route -> Bool
isGraphRoute Graph = True
isGraphRoute GraphLocal{} = True
isGraphRoute _ = False

-- ------------------------------------------------------------------ labels ---

-- | The document title for a route.
routeTitle :: Route -> Text
routeTitle = \case
    Index -> "Library"
    Bookmark _ -> "Bookmark"
    Inbox -> "Inbox"
    Graph -> "Graph"
    GraphLocal _ _ -> "Graph"
    Views -> "Views"
    ViewOpen _ -> "View"
    Dedup -> "Duplicates"
    Tags -> "Tags"
    AiTags -> "AI tags"
    Maintenance -> "Maintenance"
    Account -> "Account"
    History -> "History by year"
    Save _ _ _ -> "Save bookmark"
    NotFound -> "Not found"

-- | The one-line subtitle for a route.
routeSubtitle :: Route -> Text
routeSubtitle = \case
    Index -> "All records, newest first."
    Bookmark _ -> "One record."
    Inbox -> "Unread records."
    Graph -> "Records and tags, as a graph."
    GraphLocal _ depth ->
        "A local graph, "
            <> intText depth
            <> " hop"
            <> (if depth == 1 then "" else "s")
            <> " deep."
    Views -> "Saved views."
    ViewOpen _ -> "A saved view."
    Dedup -> "Same address, same title."
    Tags -> "The tag vocabulary."
    AiTags -> "Tag suggestions."
    Maintenance -> "Dead links, prune, undo."
    Account -> "Account settings."
    History -> "Filing by year and source."
    Save _ _ _ -> "File a record."
    NotFound -> "Not found."

-- --------------------------------------------------------------- encoding ---

{- | Percent-encode one URL component (UTF-8 bytes, RFC 3986 unreserved set).
'isAlphaNum' keeps non-ASCII letters literal, matching the client's historical
encoder byte for byte; the server decodes the received path.
-}
percentEncode :: Text -> Text
percentEncode value = T.pack (concatMap encodeChar (T.unpack value))

encodeChar :: Char -> String
encodeChar c
    | isAlphaNum c || c `elem` ("-._~" :: String) = [c]
    | otherwise = concatMap hexByte (utf8 (ord c))
  where
    hexByte b = ['%', hexDigit (b `div` 16), hexDigit (b `mod` 16)]

hexDigit :: Int -> Char
hexDigit n
    | n < 10 = chr (ord '0' + n)
    | otherwise = chr (ord 'A' + n - 10)

utf8 :: Int -> [Int]
utf8 n
    | n <= 0x7f = [n]
    | n <= 0x7ff = [0xc0 + n `div` 64, 0x80 + n `mod` 64]
    | n <= 0xffff =
        [ 0xe0 + n `div` 4096
        , 0x80 + (n `div` 64) `mod` 64
        , 0x80 + n `mod` 64
        ]
    | otherwise =
        [ 0xf0 + n `div` 262144
        , 0x80 + (n `div` 4096) `mod` 64
        , 0x80 + (n `div` 64) `mod` 64
        , 0x80 + n `mod` 64
        ]
