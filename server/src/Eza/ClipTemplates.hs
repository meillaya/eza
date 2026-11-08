-- | Clip templates: the Markdown templates and URL/regex triggers that turn
-- a captured page into the note eza stores.
--
-- A template is a name, an optional title template, a Markdown body template,
-- default tags, and URL triggers. Templates are data, not code: the body uses
-- @{{variable}}@ placeholders with a small set of pipe filters, and a trigger
-- matches either a URL glob (@*@ and @?@ wildcards) or a restricted regular
-- expression (see 'parseRegex').
--
-- The module owns the @clip_templates@ table. The exact schema is declared
-- once in "Eza.Clip" ('Eza.Clip.clipSchema') because a migration belongs to
-- "Eza.Db"; the column names and order in 'templateColumns' must match it.
--
-- Apart from the CRUD functions, which run plain SQLite statements, this
-- module is pure. It never calls the network and never spawns a process.
module Eza.ClipTemplates
  ( -- * Types
    ClipTemplate (..)
  , TemplateVars (..)
  , emptyTemplateVars
  , RenderedTemplate (..)
  , defaultClipTemplate
  , TemplateError (..)
  , TemplateField (..)
  , templateErrorStatus
  , templateErrorCode
  , templateErrorMessage

    -- * Variables and rendering
  , templateVariables
  , renderTemplate
  , renderTemplateText

    -- * Triggers
  , CompiledRegex
  , parseRegex
  , matchRegex
  , globMatch
  , matchTrigger
  , triggerScore
  , dedupeTags

    -- * CRUD
  , templateColumns
  , listTemplates
  , getTemplate
  , createTemplate
  , updateTemplate
  , deleteTemplate
  ) where

import Control.Monad (forM_, when)
import Data.Aeson (FromJSON (..), ToJSON (..), decode, encode, object, withObject, (.:), (.:?), (.!=), (.=))
import qualified Data.ByteString.Lazy as LBS
import Data.Char (isDigit, toLower)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Calendar (toGregorian)
import Data.Time.Clock (UTCTime, utctDay)
import Data.Time.Clock.POSIX (getPOSIXTime, posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import Database.SQLite.Simple
import GHC.Generics (Generic)

import Eza.Url (normalizeUrl)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | One row of @clip_templates@.
data ClipTemplate = ClipTemplate
  { ctId :: Int
  , ctName :: Text
  , ctDescription :: Text
  , ctEnabled :: Bool
  , ctTitleTemplate :: Text
  , ctBodyTemplate :: Text
  , ctDefaultTags :: [Text]
  , ctTriggerUrls :: [Text]
  , ctTriggerRegex :: Text
  , ctBuiltin :: Bool
  , ctCreatedAt :: Int
  , ctUpdatedAt :: Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON ClipTemplate where
  toJSON template =
    object
      [ "id" .= ctId template
      , "name" .= ctName template
      , "description" .= ctDescription template
      , "enabled" .= ctEnabled template
      , "title_template" .= ctTitleTemplate template
      , "body_template" .= ctBodyTemplate template
      , "default_tags" .= ctDefaultTags template
      , "trigger_urls" .= ctTriggerUrls template
      , "trigger_regex" .= ctTriggerRegex template
      , "builtin" .= ctBuiltin template
      , "created_at" .= ctCreatedAt template
      , "updated_at" .= ctUpdatedAt template
      ]

-- | The create/update body. @builtin@ is ignored: only the database decides
-- whether a row is read-only. Missing fields take documented defaults.
instance FromJSON ClipTemplate where
  parseJSON = withObject "ClipTemplate" $ \o ->
    ClipTemplate
      <$> o .:? "id" .!= 0
      <*> o .: "name"
      <*> o .:? "description" .!= ""
      <*> o .:? "enabled" .!= True
      <*> o .:? "title_template" .!= "{{title}}"
      <*> o .:? "body_template" .!= "{{content}}"
      <*> o .:? "default_tags" .!= []
      <*> o .:? "trigger_urls" .!= []
      <*> o .:? "trigger_regex" .!= ""
      <*> o .:? "builtin" .!= False
      <*> o .:? "created_at" .!= 0
      <*> o .:? "updated_at" .!= 0

-- | Values a template may reference. "Eza.Clip" builds this from a validated
-- clip payload.
data TemplateVars = TemplateVars
  { tvTitle :: Text
  , tvUrl :: Text
  , tvCanonicalUrl :: Text
  , tvDomain :: Text
  , tvSite :: Text
  , tvAuthor :: Text
  , tvPublished :: Text
  , tvDescription :: Text
  , tvImage :: Text
  , tvLanguage :: Text
  , tvContent :: Text
  , tvContentText :: Text
  , tvSelection :: Text
  , tvCapturedAt :: Int
  , tvWords :: Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON TemplateVars where
  toJSON vars =
    object
      [ "title" .= tvTitle vars
      , "url" .= tvUrl vars
      , "canonical_url" .= tvCanonicalUrl vars
      , "domain" .= tvDomain vars
      , "site" .= tvSite vars
      , "author" .= tvAuthor vars
      , "published" .= tvPublished vars
      , "description" .= tvDescription vars
      , "image" .= tvImage vars
      , "language" .= tvLanguage vars
      , "content" .= tvContent vars
      , "content_text" .= tvContentText vars
      , "selection" .= tvSelection vars
      , "captured_at" .= tvCapturedAt vars
      , "words" .= tvWords vars
      ]

instance FromJSON TemplateVars where
  parseJSON = withObject "TemplateVars" $ \o ->
    TemplateVars
      <$> o .:? "title" .!= ""
      <*> o .:? "url" .!= ""
      <*> o .:? "canonical_url" .!= ""
      <*> o .:? "domain" .!= ""
      <*> o .:? "site" .!= ""
      <*> o .:? "author" .!= ""
      <*> o .:? "published" .!= ""
      <*> o .:? "description" .!= ""
      <*> o .:? "image" .!= ""
      <*> o .:? "language" .!= ""
      <*> o .:? "content" .!= ""
      <*> o .:? "content_text" .!= ""
      <*> o .:? "selection" .!= ""
      <*> o .:? "captured_at" .!= 0
      <*> o .:? "words" .!= 0

emptyTemplateVars :: TemplateVars
emptyTemplateVars =
  TemplateVars
    { tvTitle = ""
    , tvUrl = ""
    , tvCanonicalUrl = ""
    , tvDomain = ""
    , tvSite = ""
    , tvAuthor = ""
    , tvPublished = ""
    , tvDescription = ""
    , tvImage = ""
    , tvLanguage = ""
    , tvContent = ""
    , tvContentText = ""
    , tvSelection = ""
    , tvCapturedAt = 0
    , tvWords = 0
    }

-- | A rendered capture: the note title, the Markdown body, and the tags the
-- template contributes.
data RenderedTemplate = RenderedTemplate
  { rtTitle :: Text
  , rtMarkdown :: Text
  , rtTags :: [Text]
  }
  deriving (Show, Eq, Generic)

instance ToJSON RenderedTemplate where
  toJSON rendered =
    object
      [ "title" .= rtTitle rendered
      , "markdown" .= rtMarkdown rendered
      , "tags" .= rtTags rendered
      ]

-- | The template used when the caller names no template and no stored
-- template triggers. It is not a database row: its id is 0 and 'ctBuiltin'
-- is true. A seeded @is_builtin = 1@ row behaves the same way.
defaultClipTemplate :: ClipTemplate
defaultClipTemplate =
  ClipTemplate
    { ctId = 0
    , ctName = "Default"
    , ctDescription = "A YAML front matter block, the clipped body, and any selected text."
    , ctEnabled = True
    , ctTitleTemplate = "{{title}}"
    , ctBodyTemplate =
        T.unlines
          [ "---"
          , "title: {{title}}"
          , "url: {{url}}"
          , "site: {{site}}"
          , "author: {{author}}"
          , "published: {{published}}"
          , "captured: {{date}}"
          , "---"
          , ""
          , "# {{title}}"
          , ""
          , "{{content}}"
          , ""
          , "{{selection}}"
          ]
    , ctDefaultTags = []
    , ctTriggerUrls = []
    , ctTriggerRegex = ""
    , ctBuiltin = True
    , ctCreatedAt = 0
    , ctUpdatedAt = 0
    }

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

-- | Which input field an error is about.
data TemplateField
  = FieldName
  | FieldDescription
  | FieldTitleTemplate
  | FieldBodyTemplate
  | FieldTrigger
  | FieldTag
  deriving (Show, Eq)

-- | Every failure a template operation can report. The server maps these with
-- 'templateErrorStatus', 'templateErrorCode', and 'templateErrorMessage'.
data TemplateError
  = TemplateNotFound
  | TemplateBuiltinReadOnly
  | TemplateNameRequired
  | TemplateFieldTooLong TemplateField Int
  | TemplateUnknownVariable Text
  | TemplateInvalidFilter Text
  | TemplateMalformed Text
  | TemplateInvalidTrigger Text
  deriving (Show, Eq)

-- | HTTP status the server should answer with.
templateErrorStatus :: TemplateError -> Int
templateErrorStatus err = case err of
  TemplateNotFound -> 404
  TemplateBuiltinReadOnly -> 409
  TemplateNameRequired -> 400
  TemplateFieldTooLong _ _ -> 400
  TemplateUnknownVariable _ -> 400
  TemplateInvalidFilter _ -> 400
  TemplateMalformed _ -> 400
  TemplateInvalidTrigger _ -> 400

-- | Stable machine-readable error code (snake_case).
templateErrorCode :: TemplateError -> Text
templateErrorCode err = case err of
  TemplateNotFound -> "template_not_found"
  TemplateBuiltinReadOnly -> "template_builtin_readonly"
  TemplateNameRequired -> "template_name_required"
  TemplateFieldTooLong templateField _ -> "template_field_too_long_" <> fieldName templateField
  TemplateUnknownVariable _ -> "template_unknown_variable"
  TemplateInvalidFilter _ -> "template_invalid_filter"
  TemplateMalformed _ -> "template_malformed"
  TemplateInvalidTrigger _ -> "template_invalid_trigger"

-- | Human-readable message. Always says which field is wrong and why.
templateErrorMessage :: TemplateError -> Text
templateErrorMessage err = case err of
  TemplateNotFound -> "template not found"
  TemplateBuiltinReadOnly -> "built-in templates cannot be edited or deleted"
  TemplateNameRequired -> "template name is required"
  TemplateFieldTooLong templateField maxLength ->
    fieldName templateField <> " must be at most " <> T.pack (show maxLength) <> " characters"
  TemplateUnknownVariable name ->
    "unknown template variable {{" <> name <> "}}; allowed variables: " <> T.intercalate ", " templateVariables
  TemplateInvalidFilter message -> "invalid template filter: " <> message
  TemplateMalformed message -> "invalid template: " <> message
  TemplateInvalidTrigger message -> "invalid trigger: " <> message

fieldName :: TemplateField -> Text
fieldName templateField = case templateField of
  FieldName -> "name"
  FieldDescription -> "description"
  FieldTitleTemplate -> "title_template"
  FieldBodyTemplate -> "body_template"
  FieldTrigger -> "trigger_urls"
  FieldTag -> "default_tags"

-- ---------------------------------------------------------------------------
-- Template variables
-- ---------------------------------------------------------------------------

-- | Placeholders a template text may use.
templateVariables :: [Text]
templateVariables =
  [ "title"
  , "url"
  , "canonical_url"
  , "domain"
  , "site"
  , "author"
  , "published"
  , "description"
  , "image"
  , "language"
  , "content"
  , "content_text"
  , "selection"
  , "date"
  , "words"
  ]

variableValue :: Text -> TemplateVars -> Text
variableValue name vars = case name of
  "title" -> tvTitle vars
  "url" -> tvUrl vars
  "canonical_url" -> tvCanonicalUrl vars
  "domain" -> tvDomain vars
  "site" -> tvSite vars
  "author" -> tvAuthor vars
  "published" -> tvPublished vars
  "description" -> tvDescription vars
  "image" -> tvImage vars
  "language" -> tvLanguage vars
  "content" -> tvContent vars
  "content_text" -> tvContentText vars
  "selection" -> tvSelection vars
  "date" -> formatEpoch "YYYY-MM-DD" (tvCapturedAt vars)
  "words" -> T.pack (show (tvWords vars))
  _ -> ""

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- | Render a title template and a body template with the same values. When a
-- template renders to nothing, the payload title/content/selection is used so
-- a malformed template cannot silently drop the capture.
renderTemplate :: ClipTemplate -> TemplateVars -> Either TemplateError RenderedTemplate
renderTemplate template vars = do
  titleFragments <- parseTemplateText (ctTitleTemplate template)
  bodyFragments <- parseTemplateText (ctBodyTemplate template)
  let renderedTitle = T.strip (renderFragments titleFragments vars)
      renderedBody = T.strip (renderFragments bodyFragments vars)
  pure
    RenderedTemplate
      { rtTitle = T.take maxTitleLength (firstNonEmpty [renderedTitle, tvTitle vars, hostOf (tvUrl vars), "Untitled"])
      , rtMarkdown = firstNonEmpty [renderedBody, T.strip (tvContent vars), T.strip (tvSelection vars)]
      , rtTags = dedupeTags (map T.toLower (ctDefaultTags template))
      }
  where
    maxTitleLength = 500

-- | Render one template text sequence. Exported so a preview can render a
-- single field.
renderTemplateText :: Text -> TemplateVars -> Either TemplateError Text
renderTemplateText source vars = do
  fragments <- parseTemplateText source
  pure (renderFragments fragments vars)

data TemplateFragment
  = Literal Text
  | Placeholder Text [TemplateFilter]
  deriving (Show, Eq)

data TemplateFilter
  = FilterTrim
  | FilterLower
  | FilterUpper
  | FilterTruncate Int
  | FilterDefault Text
  | FilterDateFormat Text
  | FilterFirstParagraph
  deriving (Show, Eq)

parseTemplateText :: Text -> Either TemplateError [TemplateFragment]
parseTemplateText source = do
  chunks <- splitDelimiters source
  mapM chunkToFragment chunks
  where
    chunkToFragment chunk = case chunk of
      ChunkLiteral literal -> Right (Literal literal)
      ChunkPlaceholder placeholder -> parsePlaceholder placeholder

data TemplateChunk
  = ChunkLiteral Text
  | ChunkPlaceholder Text
  deriving (Show, Eq)

splitDelimiters :: Text -> Either TemplateError [TemplateChunk]
splitDelimiters source = go [] source
  where
    go acc remaining
      | T.null remaining = Right (reverse acc)
      | otherwise =
          let (before, rest) = T.breakOn "{{" remaining
              acc' = if T.null before then acc else ChunkLiteral before : acc
           in if T.null rest
                then Right (reverse acc')
                else case T.breakOn "}}" (T.drop 2 rest) of
                  (inside, closing)
                    | T.null closing ->
                        Left (TemplateMalformed ("unclosed {{ in: " <> T.take 60 rest))
                    | otherwise -> go (ChunkPlaceholder inside : acc') (T.drop 2 closing)

parsePlaceholder :: Text -> Either TemplateError TemplateFragment
parsePlaceholder inside =
  let pieces = map T.strip (T.splitOn "|" inside)
   in case pieces of
        [] -> Left (TemplateMalformed "empty placeholder")
        (name : filterTexts) -> do
          if name `elem` templateVariables
            then pure ()
            else Left (TemplateUnknownVariable name)
          filters <- mapM parseFilter (filter (not . T.null) filterTexts)
          pure (Placeholder name filters)

parseFilter :: Text -> Either TemplateError TemplateFilter
parseFilter source =
  let (name, rest) = T.breakOn ":" source
      argument = T.strip (T.drop 1 rest)
      hasArgument = not (T.null rest)
      failFilter detail = Left (TemplateInvalidFilter (T.strip source <> ": " <> detail))
   in case T.toLower (T.strip name) of
        "trim"
          | hasArgument -> failFilter "trim takes no argument"
          | otherwise -> Right FilterTrim
        "lower"
          | hasArgument -> failFilter "lower takes no argument"
          | otherwise -> Right FilterLower
        "upper"
          | hasArgument -> failFilter "upper takes no argument"
          | otherwise -> Right FilterUpper
        "first_paragraph"
          | hasArgument -> failFilter "first_paragraph takes no argument"
          | otherwise -> Right FilterFirstParagraph
        "truncate"
          | not hasArgument -> failFilter "truncate needs a character count, for example truncate:200"
          | otherwise -> case parsePositiveInt argument of
              Just n -> Right (FilterTruncate n)
              Nothing -> failFilter "truncate needs a positive whole number"
        "default"
          | not hasArgument -> failFilter "default needs a fallback value"
          | otherwise -> Right (FilterDefault (unwrapQuotes argument))
        "date"
          | not (T.null argument) -> Right (FilterDateFormat argument)
          | otherwise -> failFilter "date needs a format, for example date:YYYY-MM-DD"
        _ -> failFilter ("unknown filter " <> T.strip name)

parsePositiveInt :: Text -> Maybe Int
parsePositiveInt raw =
  let digits = T.unpack (T.strip raw)
   in if not (null digits) && length digits <= 9 && all isDigit digits
        then
          let n = read digits :: Int
           in if n > 0 then Just n else Nothing
        else Nothing

unwrapQuotes :: Text -> Text
unwrapQuotes value
  | T.length value >= 2
  , (T.head value, T.last value) `elem` [('"', '"'), ('\'', '\'')] =
      T.drop 1 (T.dropEnd 1 value)
  | otherwise = value

renderFragments :: [TemplateFragment] -> TemplateVars -> Text
renderFragments fragments vars = T.concat (map renderOne fragments)
  where
    renderOne (Literal text) = text
    renderOne (Placeholder name filters) =
      foldl' applyFilter (variableValue name vars) filters

applyFilter :: Text -> TemplateFilter -> Text
applyFilter value filterSpec = case filterSpec of
  FilterTrim -> T.strip value
  FilterLower -> T.toLower value
  FilterUpper -> T.toUpper value
  FilterTruncate n -> T.take n value
  FilterDefault fallback -> if T.null (T.strip value) then fallback else value
  FilterFirstParagraph -> firstParagraph value
  FilterDateFormat formatText -> formatDateValue formatText value

firstParagraph :: Text -> Text
firstParagraph value =
  case filter (not . T.null . T.strip) (T.splitOn "\n\n" value) of
    (paragraph : _) -> T.strip paragraph
    [] -> ""

-- | Replace the calendar tokens @YYYY@, @MM@, @DD@, @HH@, @mm@, @ss@ in a
-- format string. The value may be an epoch number or a handful of ISO-like
-- date strings; when it cannot be parsed the value is returned unchanged.
formatDateValue :: Text -> Text -> Text
formatDateValue formatText value
  | T.null (T.strip value) = ""
  | otherwise =
      case parseDateValue value of
        Nothing -> value
        Just timestamp -> formatEpoch formatText timestamp

parseDateValue :: Text -> Maybe Int
parseDateValue raw =
  let value = T.strip raw
      asEpoch
        | not (T.null value) && T.length value <= 12 && T.all isDigit value =
            Just (read (T.unpack value) :: Int)
        | otherwise = Nothing
   in case asEpoch of
        Just timestamp -> Just timestamp
        Nothing -> firstJust [parseWith format value | format <- dateFormats]

dateFormats :: [String]
dateFormats =
  [ "%Y-%m-%dT%H:%M:%S%Q%Ez"
  , "%Y-%m-%dT%H:%M:%S%QZ"
  , "%Y-%m-%dT%H:%M:%S%Q"
  , "%Y-%m-%dT%H:%M:%S%Ez"
  , "%Y-%m-%dT%H:%M:%SZ"
  , "%Y-%m-%dT%H:%M:%S"
  , "%Y-%m-%d %H:%M:%S"
  , "%Y-%m-%d"
  , "%Y/%m/%d"
  ]

parseWith :: String -> Text -> Maybe Int
parseWith format value =
  case parseTimeM True defaultTimeLocale format (T.unpack value) :: Maybe UTCTime of
    Nothing -> Nothing
    Just utc -> Just (floor (utcTimeToPOSIXSeconds utc))

firstJust :: [Maybe a] -> Maybe a
firstJust values = case [value | Just value <- values] of
  (value : _) -> Just value
  [] -> Nothing

-- | Format an epoch second with the token scheme above. The epoch is UTC.
formatEpoch :: Text -> Int -> Text
formatEpoch formatText timestamp =
  let utc = posixSecondsToUTCTime (fromIntegral timestamp)
      (year, month, day) = toGregorian (utctDay utc)
      hour = formatTime defaultTimeLocale "%H" utc
      minute = formatTime defaultTimeLocale "%M" utc
      second = formatTime defaultTimeLocale "%S" utc
      replacements =
        [ ("YYYY", pad 4 year)
        , ("MM", pad 2 month)
        , ("DD", pad 2 day)
        , ("HH", T.pack hour)
        , ("mm", T.pack minute)
        , ("ss", T.pack second)
        ]
   in foldl' (\acc (token, replacement) -> T.replace token replacement acc) formatText replacements

pad :: Integral a => Int -> a -> Text
pad width value =
  let rendered = T.pack (show (toInteger value))
      actualWidth = T.length rendered
   in if width > actualWidth then T.replicate (width - actualWidth) "0" <> rendered else rendered

firstNonEmpty :: [Text] -> Text
firstNonEmpty values =
  case filter (not . T.null . T.strip) values of
    (value : _) -> T.strip value
    [] -> ""

dedupeTags :: [Text] -> [Text]
dedupeTags tags = reverse (snd (foldl' step ([], []) tags))
  where
    step (seen, acc) tag
      | T.null (T.strip tag) = (seen, acc)
      | lowered `elem` seen = (seen, acc)
      | otherwise = (lowered : seen, tag : acc)
      where
        lowered = T.toLower (T.strip tag)

hostOf :: Text -> Text
hostOf url =
  let afterScheme = T.drop 1 (T.dropWhile (/= ':') url)
      afterSlashes = T.dropWhile (== '/') afterScheme
      authority = T.takeWhile (\c -> c /= '/' && c /= '?' && c /= '#') afterSlashes
      host = case T.breakOnEnd "@" authority of
        ("", _) -> authority
        (_, h) -> h
   in T.toLower (T.takeWhile (/= ':') host)

-- ---------------------------------------------------------------------------
-- Trigger matching
-- ---------------------------------------------------------------------------

-- | Compiled trigger regex. The grammar is a safe subset of POSIX-ish regex:
--
-- * literal characters, @.@, and @\\d \\D \\w \\W \\s \\S@
-- * character classes @[abc]@, @[a-z]@, @[^abc]@ (escaped @\\d \\w \\s@ work
--   inside a class; use @\\]@, @\\-@ and @\\\\@ for the punctuation)
-- * quantifiers @* + ? {m} {m,} {m,n}@ applied to one atom
-- * @^@ at the start and @$@ at the end; otherwise the match is a substring
--   match. Alternation and groups are intentionally not supported.
--
-- Matching is case-insensitive over at most 2048 characters, which is more
-- than enough for a URL trigger.
data CompiledRegex = CompiledRegex
  { crAnchoredStart :: Bool
  , crAnchoredEnd :: Bool
  , crPieces :: [RegexPiece]
  }
  deriving (Show, Eq)

data RegexPiece = RegexPiece
  { rpAtom :: RegexAtom
  , rpMin :: Int
  , rpMax :: Maybe Int
  }
  deriving (Show, Eq)

data RegexAtom
  = MatchAny
  | MatchDigit
  | MatchNonDigit
  | MatchWord
  | MatchNonWord
  | MatchSpace
  | MatchNonSpace
  | MatchLiteral Char
  | MatchClass Bool [(Char, Char)]
  deriving (Show, Eq)

-- | Parse and validate a trigger regex. Errors are user-facing.
parseRegex :: Text -> Either TemplateError CompiledRegex
parseRegex raw
  | T.length raw > maxPatternLength =
      Left (TemplateInvalidTrigger ("a trigger pattern must be at most " <> T.pack (show maxPatternLength) <> " characters"))
  | otherwise = do
      let lowered = T.toLower raw
          (anchoredStart, afterStart) = case T.uncons lowered of
            Just ('^', rest) -> (True, rest)
            _ -> (False, lowered)
      (pieces, anchoredEnd) <- parseSequence (T.unpack afterStart)
      pure CompiledRegex {crAnchoredStart = anchoredStart, crAnchoredEnd = anchoredEnd, crPieces = pieces}
  where
    maxPatternLength = 200

parseSequence :: [Char] -> Either TemplateError ([RegexPiece], Bool)
parseSequence = go []
  where
    go acc [] = Right (reverse acc, False)
    go acc ['$'] = Right (reverse acc, True)
    go _ ('$' : _) =
      Left (TemplateInvalidTrigger "the $ anchor is only supported at the end of a pattern")
    go _ ('^' : _) =
      Left (TemplateInvalidTrigger "the ^ anchor is only supported at the start of a pattern")
    go acc (c : cs) = do
      (atom, rest) <- parseAtom (c : cs)
      (piece, remaining) <- parseQuantifier atom rest
      go (piece : acc) remaining

parseAtom :: [Char] -> Either TemplateError (RegexAtom, [Char])
parseAtom [] = Left (TemplateInvalidTrigger "unexpected end of pattern")
parseAtom (c : cs) = case c of
  '.' -> Right (MatchAny, cs)
  '\\' -> case cs of
    [] -> Left (TemplateInvalidTrigger "trailing backslash")
    (escaped : rest) -> case escaped of
      'd' -> Right (MatchDigit, rest)
      'D' -> Right (MatchNonDigit, rest)
      'w' -> Right (MatchWord, rest)
      'W' -> Right (MatchNonWord, rest)
      's' -> Right (MatchSpace, rest)
      'S' -> Right (MatchNonSpace, rest)
      other -> Right (MatchLiteral (toLower other), rest)
  '[' -> parseClass cs
  '(' -> unsupported "groups"
  ')' -> unsupported "groups"
  '|' -> unsupported "alternation"
  '*' -> quantifierWithoutAtom
  '+' -> quantifierWithoutAtom
  '?' -> quantifierWithoutAtom
  '{' -> quantifierWithoutAtom
  '}' -> unsupported "a bare }"
  other -> Right (MatchLiteral (toLower other), cs)
  where
    unsupported feature =
      Left (TemplateInvalidTrigger (feature <> " are not supported; use separate URL patterns instead"))
    quantifierWithoutAtom =
      Left (TemplateInvalidTrigger "quantifier without an atom to repeat")

parseClass :: [Char] -> Either TemplateError (RegexAtom, [Char])
parseClass chars0 =
  case chars0 of
    ('^' : rest) -> collect True rest []
    _ -> collect False chars0 []
  where
    collect _ [] _ = Left (TemplateInvalidTrigger "unterminated character class; expected ]")
    collect _ (']' : _) [] = Left (TemplateInvalidTrigger "empty character class")
    collect negated (']' : rest) acc = Right (MatchClass negated (reverse acc), rest)
    collect _ ('\\' : []) _ = Left (TemplateInvalidTrigger "trailing backslash in character class")
    collect negated ('\\' : escaped : rest) acc =
      case classEscape escaped of
        Just ranges -> collect negated rest (reverse ranges ++ acc)
        Nothing -> collect negated rest ((toLower escaped, toLower escaped) : acc)
    collect negated (a : '-' : b : rest) acc
      | a /= ']' && b /= ']' =
          let lo = toLower a
              hi = toLower b
           in if lo <= hi
                then collect negated rest ((lo, hi) : acc)
                else Left (TemplateInvalidTrigger "character class range is reversed")
    collect negated (c : rest) acc = collect negated rest ((toLower c, toLower c) : acc)

classEscape :: Char -> Maybe [(Char, Char)]
classEscape escaped = case escaped of
  'd' -> Just [('0', '9')]
  'w' -> Just [('0', '9'), ('a', 'z'), ('_', '_')]
  's' -> Just [(' ', ' '), ('\t', '\t'), ('\n', '\n'), ('\r', '\r')]
  _ -> Nothing

parseQuantifier :: RegexAtom -> [Char] -> Either TemplateError (RegexPiece, [Char])
parseQuantifier atom chars0 = case chars0 of
  [] -> Right (RegexPiece atom 1 (Just 1), [])
  ('*' : rest) -> Right (RegexPiece atom 0 Nothing, rest)
  ('+' : rest) -> Right (RegexPiece atom 1 Nothing, rest)
  ('?' : rest) -> Right (RegexPiece atom 0 (Just 1), rest)
  ('{' : rest) -> parseBraces atom rest
  _ -> Right (RegexPiece atom 1 (Just 1), chars0)

parseBraces :: RegexAtom -> [Char] -> Either TemplateError (RegexPiece, [Char])
parseBraces atom chars0 =
  let (minDigits, rest1) = span isDigit chars0
   in case (minDigits, rest1) of
        ([], _) -> Left (TemplateInvalidTrigger "expected a repeat count after {")
        (_, '}' : rest2) -> bounded minDigits (Just minDigits) rest2
        (_, ',' : rest2) ->
          let (maxDigits, rest3) = span isDigit rest2
           in case rest3 of
                ('}' : rest4) ->
                  if null maxDigits
                    then bounded minDigits Nothing rest4
                    else bounded minDigits (Just maxDigits) rest4
                _ -> Left (TemplateInvalidTrigger "expected } to close the repeat count")
        _ -> Left (TemplateInvalidTrigger "expected } to close the repeat count")
  where
    bounded minDigits maxDigits rest = do
      minimumValue <- readCount minDigits
      maximumValue <- traverse readCount maxDigits
      case maximumValue of
        Just maximum' | maximum' < minimumValue ->
          Left (TemplateInvalidTrigger "repeat count range is reversed")
        _ -> Right (RegexPiece atom minimumValue maximumValue, rest)
    readCount digits
      | length digits > 6 = Left (TemplateInvalidTrigger "repeat count is too large")
      | otherwise =
          let value = read digits :: Int
           in if value > 1000
                then Left (TemplateInvalidTrigger "repeat count must be at most 1000")
                else Right value

-- | Match a compiled trigger against one URL string, case-insensitively.
matchRegex :: CompiledRegex -> Text -> Bool
matchRegex compiled rawUrl = any matchFromStart starts
  where
    maxSubjectLength = 2048
    subject = map toLower (T.unpack (T.take maxSubjectLength rawUrl))
    starts = if crAnchoredStart compiled then [0] else [0 .. length subject]
    matchFromStart offset = matchPieces (crPieces compiled) (drop offset subject)

    matchPieces pieces rest = case pieces of
      [] -> not (crAnchoredEnd compiled) || null rest
      (piece : continuation) ->
        any (\count -> attempt piece continuation count rest) (repeatCounts piece rest)

    attempt piece continuation count rest =
      case consumeAtoms (rpAtom piece) count rest of
        Nothing -> False
        Just remaining -> matchPieces continuation remaining

    repeatCounts piece rest =
      let maximum' = case rpMax piece of
            Nothing -> length rest
            Just bound -> min bound (length rest)
       in [maximum', maximum' - 1 .. rpMin piece]

consumeAtoms :: RegexAtom -> Int -> String -> Maybe String
consumeAtoms _ count rest
  | count <= 0 = Just rest
consumeAtoms atom count (c : cs)
  | atomMatches atom c = consumeAtoms atom (count - 1) cs
consumeAtoms _ _ _ = Nothing

atomMatches :: RegexAtom -> Char -> Bool
atomMatches atom c = case atom of
  MatchAny -> True
  MatchDigit -> isDigit c
  MatchNonDigit -> not (isDigit c)
  MatchWord -> isWordChar c
  MatchNonWord -> not (isWordChar c)
  MatchSpace -> c `elem` spaceChars
  MatchNonSpace -> c `notElem` spaceChars
  MatchLiteral literal -> c == literal
  MatchClass negated ranges ->
    let inside = any (\(lo, hi) -> c >= lo && c <= hi) ranges
     in if negated then not inside else inside
  where
    spaceChars = [' ', '\t', '\n', '\r', '\f', '\v']

isWordChar :: Char -> Bool
isWordChar c = isDigit c || (c >= 'a' && c <= 'z') || c == '_'

-- | Glob match with @*@ (any run of characters) and @?@ (one character).
-- Both sides are lower-cased first.
globMatch :: Text -> Text -> Bool
globMatch patternText subjectText = go (T.unpack (T.toLower patternText)) (T.unpack (T.toLower subjectText))
  where
    go [] [] = True
    go ('*' : patterns) subjects =
      go patterns subjects || case subjects of
        [] -> False
        (_ : rest) -> go ('*' : patterns) rest
    go ('?' : patterns) (_ : rest) = go patterns rest
    go (p : patterns) (s : rest) = p == s && go patterns rest
    go _ _ = False

-- | Does one template trigger on this URL? Disabled templates never match.
-- @re:@-prefixed URL patterns and @trigger_regex@ use 'parseRegex'; other URL
-- patterns are globs. Both are tried against the normalized URL and against
-- the URL without its scheme, so @example.com/@ patterns work.
matchTrigger :: ClipTemplate -> Text -> Bool
matchTrigger template rawUrl =
  ctEnabled template
    && (any urlPatternMatches (ctTriggerUrls template) || regexPatternMatches (T.strip (ctTriggerRegex template)))
  where
    candidates = urlCandidates rawUrl
    urlPatternMatches pattern' =
      let stripped = T.strip pattern'
       in if T.null stripped
            then False
            else
              if "re:" `T.isPrefixOf` T.toLower stripped
                then case parseRegex (T.drop 3 stripped) of
                  Left _ -> False
                  Right compiled -> any (matchRegex compiled) candidates
                else any (globMatch stripped) candidates
    regexPatternMatches pattern'
      | T.null pattern' = False
      | otherwise = case parseRegex pattern' of
          Left _ -> False
          Right compiled -> any (matchRegex compiled) candidates

-- | How specific a trigger is: the length of the longest URL pattern that
-- matches, or 0 for a regex-only match. "Eza.Clip" picks the most specific
-- matching template first.
triggerScore :: ClipTemplate -> Text -> Maybe Int
triggerScore template rawUrl
  | not (ctEnabled template) = Nothing
  | otherwise =
      let candidates = urlCandidates rawUrl
          globLengths =
            [ T.length (T.strip pattern')
            | pattern' <- ctTriggerUrls template
            , not ("re:" `T.isPrefixOf` T.toLower (T.strip pattern'))
            , not (T.null (T.strip pattern'))
            , any (globMatch (T.strip pattern')) candidates
            ]
          regexMatched =
            any (urlPatternIsRegexAndMatches candidates) (ctTriggerUrls template)
              || regexTriggerMatched candidates
       in case globLengths of
            [] | regexMatched -> Just 0
            [] -> Nothing
            lengths -> Just (maximum lengths)
  where
    regexTriggerMatched candidates =
      let pattern' = T.strip (ctTriggerRegex template)
       in not (T.null pattern')
            && case parseRegex pattern' of
              Left _ -> False
              Right compiled -> any (matchRegex compiled) candidates

urlPatternIsRegexAndMatches :: [Text] -> Text -> Bool
urlPatternIsRegexAndMatches candidates pattern' =
  "re:" `T.isPrefixOf` T.toLower (T.strip pattern')
    && case parseRegex (T.drop 3 (T.strip pattern')) of
      Left _ -> False
      Right compiled -> any (matchRegex compiled) candidates

urlCandidates :: Text -> [Text]
urlCandidates rawUrl =
  let normalized = normalizeUrl rawUrl
      withoutScheme =
        let lowered = T.toLower normalized
            stripped = case T.stripPrefix "https://" lowered of
              Just rest -> Just rest
              Nothing -> T.stripPrefix "http://" lowered
         in fromMaybe lowered stripped
   in if T.null withoutScheme || withoutScheme == normalized
        then [normalized]
        else [normalized, withoutScheme]

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

maxNameLength, maxDescriptionLength, maxTitleTemplateLength, maxBodyTemplateLength :: Int
maxNameLength = 120
maxDescriptionLength = 500
maxTitleTemplateLength = 2000
maxBodyTemplateLength = 20000

maxTriggerCount, maxTriggerLength, maxTagCount, maxTagLength :: Int
maxTriggerCount = 50
maxTriggerLength = 200
maxTagCount = 50
maxTagLength = 64

-- | Trim, cap, parse, and check every field. The validated value is what a
-- CRUD function writes.
validateTemplate :: ClipTemplate -> Either TemplateError ClipTemplate
validateTemplate template = do
  let name = T.strip (ctName template)
  if T.null name
    then Left TemplateNameRequired
    else checkLength FieldName maxNameLength name
  let description = T.strip (ctDescription template)
  checkLength FieldDescription maxDescriptionLength description
  let titleTemplate = T.strip (ctTitleTemplate template)
  checkLength FieldTitleTemplate maxTitleTemplateLength titleTemplate
  let bodyTemplate = ctBodyTemplate template
  checkLength FieldBodyTemplate maxBodyTemplateLength bodyTemplate
  _ <- parseTemplateText titleTemplate
  _ <- parseTemplateText bodyTemplate
  let tags = dedupeTags (map T.strip (ctDefaultTags template))
  when (length tags > maxTagCount) $
    Left (TemplateFieldTooLong FieldTag maxTagCount)
  forM_ tags $ \tag -> checkLength FieldTag maxTagLength tag
  when (length (ctTriggerUrls template) > maxTriggerCount) $
    Left (TemplateFieldTooLong FieldTrigger maxTriggerCount)
  forM_ (map T.strip (ctTriggerUrls template)) $ \pattern' -> do
    when (T.null pattern') $
      Left (TemplateInvalidTrigger "a URL pattern cannot be empty")
    checkLength FieldTrigger maxTriggerLength pattern'
    when ("re:" `T.isPrefixOf` T.toLower pattern') $
      case parseRegex (T.drop 3 pattern') of
        Left err -> Left err
        Right _ -> pure ()
  let regex = T.strip (ctTriggerRegex template)
  if T.null regex
    then pure ()
    else do
      checkLength FieldTrigger maxTriggerLength regex
      case parseRegex regex of
        Left err -> Left err
        Right _ -> pure ()
  pure
    template
      { ctName = name
      , ctDescription = description
      , ctTitleTemplate = titleTemplate
      , ctBodyTemplate = bodyTemplate
      , ctDefaultTags = tags
      , ctTriggerUrls = map T.strip (ctTriggerUrls template)
      , ctTriggerRegex = regex
      }
  where
    checkLength templateField maxLength value =
      if T.length value > maxLength
        then Left (TemplateFieldTooLong templateField maxLength)
        else pure ()

-- ---------------------------------------------------------------------------
-- CRUD
-- ---------------------------------------------------------------------------

-- | Column list shared by the queries. Keep it in sync with the migration in
-- "Eza.Clip.clipSchema".
templateColumns :: Text
templateColumns =
  "id, name, description, enabled, title_template, body_template, default_tags, trigger_urls, trigger_regex, is_builtin, created_at, updated_at"

newtype TemplateRow = TemplateRow ClipTemplate

instance FromRow TemplateRow where
  fromRow =
    TemplateRow
      <$> ( ClipTemplate
              <$> field
              <*> field
              <*> field
              <*> (toBool <$> field)
              <*> field
              <*> field
              <*> (parseTextList <$> field)
              <*> (parseTextList <$> field)
              <*> field
              <*> (toBool <$> field)
              <*> field
              <*> field
          )
    where
      toBool :: Int -> Bool
      toBool value = value /= 0

-- | Templates ordered by name, with built-in rows first.
listTemplates :: Connection -> IO [ClipTemplate]
listTemplates conn = do
  rows <-
    query
      conn
      (Query ("SELECT " <> templateColumns <> " FROM clip_templates ORDER BY is_builtin DESC, name COLLATE NOCASE, id"))
      () ::
      IO [TemplateRow]
  pure [template | TemplateRow template <- rows]

getTemplate :: Connection -> Int -> IO (Maybe ClipTemplate)
getTemplate conn templateId = do
  rows <-
    query
      conn
      (Query ("SELECT " <> templateColumns <> " FROM clip_templates WHERE id = ?"))
      (Only templateId) ::
      IO [TemplateRow]
  pure (case rows of [TemplateRow template] -> Just template; _ -> Nothing)

createTemplate :: Connection -> ClipTemplate -> IO (Either TemplateError ClipTemplate)
createTemplate conn template =
  case validateTemplate template of
    Left err -> pure (Left err)
    Right clean -> do
      now <- epoch
      withImmediateTransaction conn $
        executeNamed
          conn
          ( Query
              ( "INSERT INTO clip_templates (name, description, enabled, title_template, body_template, default_tags, trigger_urls, trigger_regex, is_builtin, created_at, updated_at) "
                  <> "VALUES (:name, :description, :enabled, :title_template, :body_template, :default_tags, :trigger_urls, :trigger_regex, 0, :created_at, :updated_at)"
              )
          )
          [ ":name" := ctName clean
          , ":description" := ctDescription clean
          , ":enabled" := boolToInt (ctEnabled clean)
          , ":title_template" := ctTitleTemplate clean
          , ":body_template" := ctBodyTemplate clean
          , ":default_tags" := encodeTextList (ctDefaultTags clean)
          , ":trigger_urls" := encodeTextList (ctTriggerUrls clean)
          , ":trigger_regex" := ctTriggerRegex clean
          , ":created_at" := now
          , ":updated_at" := now
          ]
      newId <- fromIntegral <$> lastInsertRowId conn
      pure (Right clean {ctId = newId, ctBuiltin = False, ctCreatedAt = now, ctUpdatedAt = now})

-- | Update every editable field. Built-in rows are read-only and the row must
-- exist; the stored @is_builtin@ and @created_at@ are kept.
updateTemplate :: Connection -> ClipTemplate -> IO (Either TemplateError ClipTemplate)
updateTemplate conn template = do
  existing <- getTemplate conn (ctId template)
  case existing of
    Nothing -> pure (Left TemplateNotFound)
    Just stored
      | ctBuiltin stored -> pure (Left TemplateBuiltinReadOnly)
      | otherwise ->
          case validateTemplate template of
            Left err -> pure (Left err)
            Right clean -> do
              now <- epoch
              withImmediateTransaction conn $
                executeNamed
                  conn
                  ( Query
                      ( "UPDATE clip_templates SET name = :name, description = :description, enabled = :enabled, title_template = :title_template, "
                          <> "body_template = :body_template, default_tags = :default_tags, trigger_urls = :trigger_urls, trigger_regex = :trigger_regex, updated_at = :updated_at WHERE id = :id"
                      )
                  )
                  [ ":name" := ctName clean
                  , ":description" := ctDescription clean
                  , ":enabled" := boolToInt (ctEnabled clean)
                  , ":title_template" := ctTitleTemplate clean
                  , ":body_template" := ctBodyTemplate clean
                  , ":default_tags" := encodeTextList (ctDefaultTags clean)
                  , ":trigger_urls" := encodeTextList (ctTriggerUrls clean)
                  , ":trigger_regex" := ctTriggerRegex clean
                  , ":updated_at" := now
                  , ":id" := ctId clean
                  ]
              pure (Right clean {ctBuiltin = False, ctCreatedAt = ctCreatedAt stored, ctUpdatedAt = now})

deleteTemplate :: Connection -> Int -> IO (Either TemplateError ())
deleteTemplate conn templateId = do
  existing <- getTemplate conn templateId
  case existing of
    Nothing -> pure (Left TemplateNotFound)
    Just stored
      | ctBuiltin stored -> pure (Left TemplateBuiltinReadOnly)
      | otherwise -> do
          withImmediateTransaction conn $
            execute conn "DELETE FROM clip_templates WHERE id = ?" (Only templateId)
          pure (Right ())

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

epoch :: IO Int
epoch = floor <$> getPOSIXTime

boolToInt :: Bool -> Int
boolToInt value = if value then 1 else 0

encodeTextList :: [Text] -> Text
encodeTextList = TE.decodeUtf8 . LBS.toStrict . encode

parseTextList :: Text -> [Text]
parseTextList raw =
  case decode (LBS.fromStrict (TE.encodeUtf8 raw)) :: Maybe [Text] of
    Just values -> values
    Nothing -> []
