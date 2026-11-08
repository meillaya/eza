{-# LANGUAGE OverloadedStrings #-}

-- | Tolerant HTML extraction for bookmarks.
--
-- The extractor keeps readable body copy and page metadata.  A skip stack
-- discards contents of non-content elements (@script@, @style@, @head@,
-- @title@, @svg@, @noscript@, @template@, @iframe@) and boilerplate
-- containers (@nav@, @header@, @footer@, @aside@, @form@).  Block boundaries
-- become blank lines, list items and code lines keep their line breaks, and
-- whitespace is collapsed only inside a paragraph.  Metadata comes from
-- OpenGraph, Twitter, generic @meta@ tags, @link rel=canonical@, and JSON-LD.
module Eza.Extract
  ( Extracted (..)
  , extractHtml
  ) where

import Data.Aeson (Value (..), decodeStrict')
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.Time.LocalTime (LocalTime, localTimeToUTC, utc)
import Text.HTML.TagSoup (Tag (..), parseTags)

-- | Page metadata and readable text.  @exPublished@ is epoch seconds.
data Extracted = Extracted
  { exTitle :: Text
  , exDescription :: Text
  , exText :: Text
  , exAuthor :: Text
  , exSitename :: Text
  , exPublished :: Maybe Int
  , exLanguage :: Text
  , exImage :: Text
  , exCanonical :: Text
  }
  deriving (Show, Eq)

-- | Maximum number of characters kept from the body.
maxTextLength :: Int
maxTextLength = 100000

-- | Per-field cap for metadata so a hostile page cannot blow up the column.
maxMetaLength :: Int
maxMetaLength = 4000

-- | What happens to text while inside a skipped element.
data Capture = CaptureTitle | CaptureJsonLd | CaptureDrop
  deriving (Show, Eq)

data SkipCtx = SkipCtx
  { scName :: Text
  , scMode :: Capture
  }
  deriving (Show, Eq)

data ExtractState = ExtractState
  { esSkip :: [SkipCtx]
  , esTitleBuf :: Text
  , esJsonBuf :: Text
  , esJsonLd :: [Text]
  , esLines :: [Text]
  , esCurrent :: Text
  , esPreDepth :: Int
  , esMeta :: Map.Map Text Text
  }

initialState :: ExtractState
initialState =
  ExtractState
    { esSkip = []
    , esTitleBuf = ""
    , esJsonBuf = ""
    , esJsonLd = []
    , esLines = []
    , esCurrent = ""
    , esPreDepth = 0
    , esMeta = Map.empty
    }

extractHtml :: Text -> Extracted
extractHtml html =
  let st = foldl' step initialState (parseTags html :: [Tag Text])
      st' = flushLine st
      bodyLines = trimBlankLines (reverse (esLines st'))
      body = T.strip (T.intercalate "\n" bodyLines)
      jsonLd = parseJsonLd (reverse (esJsonLd st'))
      meta = esMeta st'
      title = firstNonEmpty [metaText meta "og:title", metaText meta "twitter:title", jlTitle jsonLd, metaText meta "title", clean (esTitleBuf st')]
      description = firstNonEmpty [metaText meta "og:description", metaText meta "twitter:description", jlDescription jsonLd, metaText meta "description"]
      author = firstNonEmpty [metaText meta "author", metaText meta "article:author", metaText meta "dc.creator", jlAuthor jsonLd]
      sitename = firstNonEmpty [metaText meta "og:site_name", metaText meta "application-name", stripAt (metaText meta "twitter:site"), jlPublisher jsonLd]
      published = firstJust (map (parsePublished . metaText meta) publishedKeys) `orElse` (jlDate jsonLd >>= parsePublished)
      language = firstNonEmpty [metaText meta "html.lang", metaText meta "content-language", metaText meta "language", normalizeLocale (metaText meta "og:locale"), jlLanguage jsonLd]
      image = firstNonEmpty [metaText meta "og:image", metaText meta "og:image:url", metaText meta "og:image:secure_url", metaText meta "twitter:image", metaText meta "twitter:image:src", metaText meta "link.image_src", jlImage jsonLd]
      canonical = firstNonEmpty [metaText meta "link.canonical", metaText meta "og:url", jlUrl jsonLd]
   in Extracted
        { exTitle = capMeta (clean title)
        , exDescription = capMeta (clean description)
        , exText = T.take maxTextLength (T.strip body)
        , exAuthor = capMeta (clean author)
        , exSitename = capMeta (clean sitename)
        , exPublished = published
        , exLanguage = capMeta (T.toLower (clean language))
        , exImage = capMeta (clean image)
        , exCanonical = capMeta (clean canonical)
        }
  where
    publishedKeys =
      [ "article:published_time"
      , "og:article:published_time"
      , "parsely-pub-date"
      , "sailthru.date"
      , "date"
      , "pubdate"
      , "publish-date"
      , "publish_date"
      , "dc.date"
      , "dc.date.issued"
      ]

-- ---------------------------------------------------------------------------
-- State machine
-- ---------------------------------------------------------------------------

step :: ExtractState -> Tag Text -> ExtractState
step st = \case
  TagOpen rawName attrs -> onOpen st (T.toLower rawName) attrs
  TagClose rawName -> onClose st (T.toLower rawName)
  TagText txt
    | not (null (esSkip st)) -> skipText st txt
    | otherwise -> bodyText st txt
  _ -> st

onOpen :: ExtractState -> Text -> [(Text, Text)] -> ExtractState
onOpen st name attrs
  | not (null (esSkip st)) =
      let captured = captureMeta st name attrs
       in if name `elem` voidElements
            then captured
            else captured {esSkip = SkipCtx name (childCapture (esSkip st) name attrs) : esSkip st}
  | name `elem` voidElements = voidOpen st name attrs
  | name `elem` skipContainers = (captureMeta st name attrs) {esSkip = [SkipCtx name (rootCapture name attrs)]}
  | otherwise = captureMeta st name attrs `withBodyOpen` name
  where
    withBodyOpen s n
      | n == "br" = flushLine s
      | n == "hr" = blankLine (flushLine s)
      | n == "li" = flushLine s
      | n == "pre" = (blankLine (flushLine s)) {esPreDepth = esPreDepth s + 1}
      | n `elem` blockTags = blankLine (flushLine s)
      | otherwise = s

voidOpen :: ExtractState -> Text -> [(Text, Text)] -> ExtractState
voidOpen st name attrs
  | name == "br" = flushLine st
  | name == "hr" = blankLine (flushLine st)
  | otherwise = captureMeta st name attrs

onClose :: ExtractState -> Text -> ExtractState
onClose st name
  | not (null (esSkip st)) = closeSkip st name
  | name == "pre" = blankLine (flushLine (st {esPreDepth = max 0 (esPreDepth st - 1)}))
  | name == "li" = flushLine st
  | name `elem` blockTags = blankLine (flushLine st)
  | otherwise = st

-- | Leave the skip stack.  A close tag may close more than its own element
-- when the document uses optional end tags; the first matching open wins.
closeSkip :: ExtractState -> Text -> ExtractState
closeSkip st name =
  case break ((== name) . scName) (esSkip st) of
    (_, []) -> st
    (popped, matched : rest) ->
      let st' = foldl' finishCapture st (popped <> [matched])
       in st' {esSkip = rest}

finishCapture :: ExtractState -> SkipCtx -> ExtractState
finishCapture st ctx
  | scMode ctx == CaptureJsonLd =
      st {esJsonBuf = "", esJsonLd = esJsonBuf st : esJsonLd st}
  | otherwise = st

skipText :: ExtractState -> Text -> ExtractState
skipText st txt = case esSkip st of
  (SkipCtx _ CaptureTitle : _) -> st {esTitleBuf = esTitleBuf st <> txt}
  (SkipCtx _ CaptureJsonLd : _) -> st {esJsonBuf = esJsonBuf st <> txt}
  _ -> st

rootCapture :: Text -> [(Text, Text)] -> Capture
rootCapture name attrs
  | name == "script" && isJsonLdScript attrs = CaptureJsonLd
  | name == "title" = CaptureTitle
  | otherwise = CaptureDrop

childCapture :: [SkipCtx] -> Text -> [(Text, Text)] -> Capture
childCapture stack name attrs
  | any ((== CaptureTitle) . scMode) stack = CaptureTitle
  | any ((== CaptureJsonLd) . scMode) stack = CaptureJsonLd
  | name == "script" && isJsonLdScript attrs = CaptureJsonLd
  | name == "title" && not (any ((== "svg") . scName) stack) = CaptureTitle
  | otherwise = CaptureDrop

isJsonLdScript :: [(Text, Text)] -> Bool
isJsonLdScript attrs = "ld+json" `T.isInfixOf` T.toLower (attrText "type" attrs)

-- | Elements whose contents never reach the reading text.
skipContainers :: [Text]
skipContainers =
  [ "script"
  , "style"
  , "title"
  , "head"
  , "noscript"
  , "svg"
  , "template"
  , "iframe"
  , "nav"
  , "header"
  , "footer"
  , "aside"
  , "form"
  , "button"
  , "select"
  , "option"
  , "textarea"
  , "dialog"
  , "menu"
  , "canvas"
  , "video"
  , "audio"
  , "object"
  ]

-- | HTML void elements: TagSoup emits no closing tag for these.
voidElements :: [Text]
voidElements =
  [ "area"
  , "base"
  , "br"
  , "col"
  , "embed"
  , "hr"
  , "img"
  , "input"
  , "link"
  , "meta"
  , "param"
  , "source"
  , "track"
  , "wbr"
  ]

-- | Elements that start and end a text block.
blockTags :: [Text]
blockTags =
  [ "p"
  , "div"
  , "section"
  , "article"
  , "main"
  , "h1"
  , "h2"
  , "h3"
  , "h4"
  , "h5"
  , "h6"
  , "blockquote"
  , "pre"
  , "ul"
  , "ol"
  , "dl"
  , "dt"
  , "dd"
  , "table"
  , "thead"
  , "tbody"
  , "tfoot"
  , "tr"
  , "td"
  , "th"
  , "figure"
  , "figcaption"
  , "address"
  , "details"
  , "summary"
  , "fieldset"
  ]

-- ---------------------------------------------------------------------------
-- Text assembly
-- ---------------------------------------------------------------------------

bodyText :: ExtractState -> Text -> ExtractState
bodyText st txt
  | T.null txt = st
  | esPreDepth st > 0 = preText st txt
  | otherwise =
      let part = T.unwords (T.words txt)
       in if T.null part then st else st {esCurrent = appendPart (esCurrent st) part}

appendPart :: Text -> Text -> Text
appendPart current part
  | T.null current = part
  | T.last current == ' ' = current <> part
  | otherwise = current <> " " <> part

preText :: ExtractState -> Text -> ExtractState
preText st txt =
  case T.splitOn "\n" txt of
    [] -> st
    [single] -> st {esCurrent = esCurrent st <> single}
    (firstPart : rest) ->
      let st' = st {esCurrent = esCurrent st <> firstPart}
       in foldl' (\acc part -> (flushLine acc) {esCurrent = part}) st' rest

flushLine :: ExtractState -> ExtractState
flushLine st =
  let current = T.stripEnd (esCurrent st)
   in if T.null (T.strip current)
        then st {esCurrent = ""}
        else st {esLines = current : esLines st, esCurrent = ""}

blankLine :: ExtractState -> ExtractState
blankLine st =
  let st' = flushLine st
   in case esLines st' of
        [] -> st'
        (line : _) | T.null line -> st'
        _ -> st' {esLines = "" : esLines st'}

trimBlankLines :: [Text] -> [Text]
trimBlankLines = reverse . dropWhile T.null . reverse . dropWhile T.null

-- ---------------------------------------------------------------------------
-- Metadata
-- ---------------------------------------------------------------------------

captureMeta :: ExtractState -> Text -> [(Text, Text)] -> ExtractState
captureMeta st name attrs = case name of
  "meta" -> storeMeta st attrs
  "link" -> storeLink st attrs
  "html" -> storeHtmlLang st attrs
  _ -> st

storeMeta :: ExtractState -> [(Text, Text)] -> ExtractState
storeMeta st attrs =
  let key = T.toLower (T.strip (firstNonEmpty [attrText "property" attrs, attrText "name" attrs, attrText "itemprop" attrs, attrText "http-equiv" attrs]))
      content = clean (attrText "content" attrs)
   in if T.null key || T.null content then st else st {esMeta = Map.insertWith (\_ old -> old) key content (esMeta st)}

storeLink :: ExtractState -> [(Text, Text)] -> ExtractState
storeLink st attrs =
  let rel = T.toLower (T.strip (attrText "rel" attrs))
      href = clean (attrText "href" attrs)
      key
        | "canonical" `elem` T.words rel = Just "link.canonical"
        | "image_src" `elem` T.words rel || "image_src" `T.isInfixOf` rel = Just "link.image_src"
        | otherwise = Nothing
   in case key of
        Just name | not (T.null href) -> st {esMeta = Map.insertWith (\_ old -> old) name href (esMeta st)}
        _ -> st

storeHtmlLang :: ExtractState -> [(Text, Text)] -> ExtractState
storeHtmlLang st attrs =
  let lang = clean (firstNonEmpty [attrText "lang" attrs, attrText "xml:lang" attrs])
   in if T.null lang then st else st {esMeta = Map.insertWith (\_ old -> old) "html.lang" lang (esMeta st)}

attrText :: Text -> [(Text, Text)] -> Text
attrText key attrs =
  fromMaybe "" (lookup (T.toLower key) [(T.toLower k, v) | (k, v) <- attrs])

metaText :: Map.Map Text Text -> Text -> Text
metaText meta key = Map.findWithDefault "" key meta

-- ---------------------------------------------------------------------------
-- JSON-LD
-- ---------------------------------------------------------------------------

data JsonLd = JsonLd
  { jlTitle :: Text
  , jlDescription :: Text
  , jlAuthor :: Text
  , jlPublisher :: Text
  , jlDate :: Maybe Text
  , jlLanguage :: Text
  , jlImage :: Text
  , jlUrl :: Text
  }
  deriving (Show, Eq)

emptyJsonLd :: JsonLd
emptyJsonLd = JsonLd "" "" "" "" Nothing "" "" ""

parseJsonLd :: [Text] -> JsonLd
parseJsonLd texts = foldl' mergeJsonLd emptyJsonLd (mapMaybe jsonLdFromText texts)

jsonLdFromText :: Text -> Maybe JsonLd
jsonLdFromText raw = do
  value <- decodeStrict' (TE.encodeUtf8 (T.strip raw)) :: Maybe Value
  case jsonLdObjects value of
    [] -> Nothing
    objects -> Just (foldl' mergeJsonLd emptyJsonLd (map objectJsonLd objects))

jsonLdObjects :: Value -> [KM.KeyMap Value]
jsonLdObjects value = case value of
  Array items -> concatMap jsonLdObjects (toList items)
  Object object ->
    object
      : case KM.lookup (Key.fromText "@graph") object of
        Just graph -> jsonLdObjects graph
        Nothing -> []
  _ -> []

objectJsonLd :: KM.KeyMap Value -> JsonLd
objectJsonLd object =
  JsonLd
    { jlTitle = firstNonEmpty [lookupField object ["headline"], lookupField object ["name"]]
    , jlDescription = lookupField object ["description"]
    , jlAuthor = firstNonEmpty [lookupName object "author", lookupName object "creator"]
    , jlPublisher = lookupName object "publisher"
    , jlDate = firstJust (map (\key -> nonEmpty (lookupField object [key])) (["datePublished", "dateCreated", "uploadDate"] :: [Text]))
    , jlLanguage = lookupLanguage object
    , jlImage = firstNonEmpty [lookupImage object]
    , jlUrl = lookupUrl object
    }

mergeJsonLd :: JsonLd -> JsonLd -> JsonLd
mergeJsonLd left right =
  JsonLd
    { jlTitle = firstNonEmpty [jlTitle left, jlTitle right]
    , jlDescription = firstNonEmpty [jlDescription left, jlDescription right]
    , jlAuthor = firstNonEmpty [jlAuthor left, jlAuthor right]
    , jlPublisher = firstNonEmpty [jlPublisher left, jlPublisher right]
    , jlDate = jlDate left `orElse` jlDate right
    , jlLanguage = firstNonEmpty [jlLanguage left, jlLanguage right]
    , jlImage = firstNonEmpty [jlImage left, jlImage right]
    , jlUrl = firstNonEmpty [jlUrl left, jlUrl right]
    }

lookupField :: KM.KeyMap Value -> [Text] -> Text
lookupField object keys = firstNonEmpty [maybe "" fieldText (KM.lookup (Key.fromText key) object) | key <- keys]

fieldText :: Value -> Text
fieldText value = case value of
  String text -> clean text
  Object object -> firstNonEmpty [maybe "" fieldText (KM.lookup (Key.fromText key) object) | key <- ["@id", "url", "name", "value"]]
  Array items -> firstNonEmpty (map fieldText (toList items))
  _ -> ""

lookupName :: KM.KeyMap Value -> Text -> Text
lookupName object key =
  case KM.lookup (Key.fromText key) object of
    Just (String text) -> clean text
    Just (Object inner) -> lookupField inner ["name", "legalName"]
    Just (Array items) -> firstNonEmpty (map valueName (toList items))
    _ -> ""
  where
    valueName (String text) = clean text
    valueName (Object inner) = lookupField inner ["name", "legalName"]
    valueName _ = ""

lookupImage :: KM.KeyMap Value -> Text
lookupImage object =
  case KM.lookup (Key.fromText "image") object of
    Just (String text) -> clean text
    Just (Object inner) -> lookupField inner ["url", "contentUrl"]
    Just (Array items) -> firstNonEmpty (map imageValue (toList items))
    _ -> ""
  where
    imageValue (String text) = clean text
    imageValue (Object inner) = lookupField inner ["url", "contentUrl"]
    imageValue _ = ""

lookupLanguage :: KM.KeyMap Value -> Text
lookupLanguage object =
  case KM.lookup (Key.fromText "inLanguage") object of
    Just (String text) -> clean text
    Just (Object inner) -> lookupField inner ["alternateName", "name"]
    Just (Array items) -> firstNonEmpty (map valueText (toList items))
    _ -> ""
  where
    valueText (String text) = clean text
    valueText (Object inner) = lookupField inner ["alternateName", "name"]
    valueText _ = ""

lookupUrl :: KM.KeyMap Value -> Text
lookupUrl object = firstNonEmpty (map urlOf [KM.lookup (Key.fromText key) object | key <- ["url", "mainEntityOfPage"]])
  where
    urlOf (Just (String text))
      | "#" `T.isPrefixOf` T.strip text = ""
      | otherwise = clean text
    urlOf (Just (Object inner)) = lookupField inner ["url", "@id"]
    urlOf _ = ""

-- ---------------------------------------------------------------------------
-- Published dates
-- ---------------------------------------------------------------------------

parsePublished :: Text -> Maybe Int
parsePublished raw =
  let input = T.unpack (clean raw)
   in if null input
        then Nothing
        else
          firstJust (map (utcEpoch input) utcFormats)
            `orElse` firstJust (map (localEpoch input) localFormats)
  where
    utcEpoch input format = floor . utcTimeToPOSIXSeconds <$> (parseTimeM True defaultTimeLocale format input :: Maybe UTCTime)
    localEpoch input format = floor . utcTimeToPOSIXSeconds . localTimeToUTC utc <$> (parseTimeM True defaultTimeLocale format input :: Maybe LocalTime)
    utcFormats =
      [ "%Y-%m-%dT%H:%M:%S%QZ"
      , "%Y-%m-%dT%H:%M:%SZ"
      , "%Y-%m-%dT%H:%M:%S%Q%z"
      , "%Y-%m-%dT%H:%M:%S%z"
      , "%Y-%m-%d %H:%M:%S%QZ"
      , "%Y-%m-%dT%H:%MZ"
      ]
    localFormats =
      [ "%Y-%m-%dT%H:%M:%S%Q"
      , "%Y-%m-%dT%H:%M:%S"
      , "%Y-%m-%dT%H:%M"
      , "%Y-%m-%d"
      ]

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

clean :: Text -> Text
clean = T.unwords . T.words . T.strip

capMeta :: Text -> Text
capMeta = T.take maxMetaLength

firstNonEmpty :: [Text] -> Text
firstNonEmpty = fromMaybe "" . listToMaybe . filter (not . T.null . T.strip)

firstJust :: [Maybe a] -> Maybe a
firstJust = listToMaybe . mapMaybe id

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just value) _ = Just value
orElse Nothing fallback = fallback

nonEmpty :: Text -> Maybe Text
nonEmpty text =
  let trimmed = T.strip text
   in if T.null trimmed then Nothing else Just trimmed

normalizeLocale :: Text -> Text
normalizeLocale = T.replace "_" "-"

stripAt :: Text -> Text
stripAt = T.dropWhile (== '@')
