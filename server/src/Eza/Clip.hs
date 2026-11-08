{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Browser clipping: the typed capture payload, validation, template
-- selection, the save/preview operations, and the API/schema contract.
--
-- = Contract for the server wiring
--
-- "Eza.Server" reads the JSON body with 'eitherDecode' (the 'FromJSON'
-- instance on 'ClipRequest'), reads the @Idempotency-Key@ request header into
-- 'clIdempotencyKey', and calls 'saveClip' or 'previewClip'. Every operation
-- returns 'Either' with a 'ClipError'; the helpers 'clipErrorStatus',
-- 'clipErrorCode', and 'clipErrorMessage' produce the JSON error shape the
-- rest of the API uses:
--
-- > {"error":{"code":"...","message":"..."}}
--
-- == Payload
--
-- > POST /api/v1/clip
-- > POST /api/v1/clip/preview
-- > Authorization: Bearer eza_pat_...
-- > Idempotency-Key: <uuid>            (optional, clip only)
-- > Content-Type: application/json
-- >
-- > {
-- >   "url": "https://example.com/article",
-- >   "title": "The Quiet Ledger",
-- >   "content_markdown": "# The Quiet Ledger\n\n…",
-- >   "content_text": "The Quiet Ledger\n\n…",
-- >   "content_html": "<article>…</article>",
-- >   "selection": "a quoted passage",
-- >   "tags": ["reading", "ledgers"],
-- >   "template_id": 3,
-- >   "source": "extension",
-- >   "client": "eza-clipper/0.1.0",
-- >   "captured_at": 1762549200,
-- >   "metadata": {
-- >     "author": "Ada Lovelace",
-- >     "site": "The Example Press",
-- >     "published": "2024-03-01T10:00:00Z",
-- >     "description": "…",
-- >     "language": "en",
-- >     "image": "https://example.com/cover.jpg",
-- >     "favicon": "https://example.com/favicon.ico",
-- >     "canonical_url": "https://example.com/article",
-- >     "extractor": "defuddle",
-- >     "extractor_version": "0.19.6",
-- >     "word_count": 118,
-- >     "parse_time_ms": 84
-- >   }
-- > }
--
-- Only @url@ is required. @content_markdown@ is preferred; @content_text@
-- falls back into it when the template asks for @{{content}}@. @selection@ is
-- the highlighted passage when the clip came from "Save selection".
-- @template_id@ 0 or absent selects by trigger, then the built-in default.
-- @captured_at@ is epoch seconds; when absent the save time is used.
--
-- == Routes
--
-- > GET    /api/v1/whoami                  -> 200 {"username","scopes","token_name"}
-- > POST   /api/v1/clip                    -> 201 SaveClipResult (200 on idempotent replay)
-- > POST   /api/v1/clip/preview            -> 200 ClipPreview
-- > GET    /api/v1/clip-templates          -> 200 {"templates":[ClipTemplate],"builtin":ClipTemplate}
-- > GET    /api/v1/clip-templates/{id}     -> 200 ClipTemplate (404 template_not_found)
-- > POST   /api/v1/clip-templates          -> 201 ClipTemplate
-- > PATCH  /api/v1/clip-templates/{id}     -> 200 ClipTemplate
-- > DELETE /api/v1/clip-templates/{id}     -> 204 (404 template_not_found, 409 template_builtin_readonly)
--
-- @GET /api/v1/whoami@ is the extension options page's connection test. It
-- should answer with the authenticated username, the token scopes, and the
-- token name; it never echoes the raw token.
--
-- Capture scope (tighten 'Eza.Tokens.tokenAllows' so a capture token allows
-- only these plus the existing @POST /api/v1/quick-save@):
--
-- > GET  /api/v1/whoami
-- > POST /api/v1/clip
-- > POST /api/v1/clip/preview
-- > GET  /api/v1/clip-templates
-- > GET  /api/v1/clip-templates/{id}
--
-- Template writes and every other bookmark route stay behind @write@ scope or
-- a browser session. Add @api/v1/clip-templates@ to 'requiresSession' for
-- unsafe methods so a bearer token cannot manage templates.
--
-- The clipper is a Chrome extension, so its requests carry
-- @Origin: chrome-extension://<id>@. The bearer branch of
-- 'Eza.Server.withAuthed' must accept extension origins (a bearer token has no
-- ambient cookie authority, so this does not weaken the CSRF guard); without
-- that change every clip answers 403 @origin@. Alternatively pin the extension
-- id in an env var and compare it exactly.
--
-- The route handler reads the @Idempotency-Key@ request header and puts it in
-- 'clIdempotencyKey' (header wins over the optional JSON field). Answer 201
-- when @bookmark_created && not replayed@, otherwise 200.
--
-- == Behaviour
--
-- * Validation normalizes the URL with 'Eza.Url.normalizeUrl' and rejects
--   non-http(s) URLs, oversize content, bad tags, and bad idempotency keys.
-- * Idempotency: with a key, a replay whose request hash matches returns the
--   stored result with @replayed = true@; the same key with a different
--   request returns 409 @idempotency_conflict@. The hash ignores
--   @captured_at@, @word_count@, and @parse_time_ms@, so an extension retry
--   after a failed response is safe.
-- * The first save for a URL inserts a bookmark (source = the clip source,
--   note_body = the rendered template, extracted_text = the clipped text) and
--   applies the deterministic save rules. A save for an existing URL attaches
--   a capture row and fills only empty metadata columns; it never overwrites
--   the title, note, or existing text.
-- * A template renders a title and Markdown body; the default template adds
--   YAML front matter. When no template is named, the most specific URL
--   trigger wins, else the built-in default (id 0).
-- * This module performs no network I/O. @enrich_state@ is @ok@ when the clip
--   carried text; when 'scrNeedsEnrichment' is true the caller may queue
--   @enqueueEnrichment@ for the new bookmark after 'saveClip' returns.
--
-- = Schema (migration v8)
--
-- "Eza.Db" must append these statements as a new schema version (the project
-- is at v7 while this module lands; the Lead owns the migration). They are
-- exported as 'clipSchema' so the migration can be pasted verbatim rather
-- than retyped:
--
-- @
-- CREATE TABLE IF NOT EXISTS clip_templates (
--   id INTEGER PRIMARY KEY AUTOINCREMENT,
--   name TEXT NOT NULL,
--   description TEXT NOT NULL DEFAULT '',
--   enabled INTEGER NOT NULL DEFAULT 1,
--   title_template TEXT NOT NULL DEFAULT '{{title}}',
--   body_template TEXT NOT NULL DEFAULT '{{content}}',
--   default_tags TEXT NOT NULL DEFAULT '[]',
--   trigger_urls TEXT NOT NULL DEFAULT '[]',
--   trigger_regex TEXT NOT NULL DEFAULT '',
--   is_builtin INTEGER NOT NULL DEFAULT 0,
--   created_at INTEGER NOT NULL,
--   updated_at INTEGER NOT NULL
-- );
-- CREATE INDEX IF NOT EXISTS idx_clip_templates_enabled ON clip_templates(enabled, id);
--
-- CREATE TABLE IF NOT EXISTS captures (
--   id INTEGER PRIMARY KEY AUTOINCREMENT,
--   bookmark_id INTEGER NOT NULL REFERENCES bookmarks(id) ON DELETE CASCADE,
--   url TEXT NOT NULL,
--   canonical_url TEXT NOT NULL DEFAULT '',
--   title TEXT NOT NULL DEFAULT '',
--   author TEXT NOT NULL DEFAULT '',
--   site TEXT NOT NULL DEFAULT '',
--   description TEXT NOT NULL DEFAULT '',
--   published TEXT NOT NULL DEFAULT '',
--   language TEXT NOT NULL DEFAULT '',
--   image_url TEXT NOT NULL DEFAULT '',
--   favicon_url TEXT NOT NULL DEFAULT '',
--   content_markdown TEXT NOT NULL DEFAULT '',
--   rendered_markdown TEXT NOT NULL DEFAULT '',
--   content_text TEXT NOT NULL DEFAULT '',
--   content_html TEXT NOT NULL DEFAULT '',
--   selection TEXT NOT NULL DEFAULT '',
--   tags TEXT NOT NULL DEFAULT '[]',
--   template_id INTEGER REFERENCES clip_templates(id) ON DELETE SET NULL,
--   template_name TEXT NOT NULL DEFAULT '',
--   source TEXT NOT NULL DEFAULT '',
--   client TEXT NOT NULL DEFAULT '',
--   idempotency_key TEXT NOT NULL DEFAULT '',
--   request_hash TEXT NOT NULL DEFAULT '',
--   extractor TEXT NOT NULL DEFAULT '',
--   extractor_version TEXT NOT NULL DEFAULT '',
--   metadata_json TEXT NOT NULL DEFAULT '{}',
--   word_count INTEGER NOT NULL DEFAULT 0,
--   parse_time_ms INTEGER NOT NULL DEFAULT 0,
--   captured_at INTEGER NOT NULL,
--   created_at INTEGER NOT NULL
-- );
-- CREATE INDEX IF NOT EXISTS idx_captures_bookmark ON captures(bookmark_id);
-- CREATE INDEX IF NOT EXISTS idx_captures_created ON captures(created_at DESC, id DESC);
-- CREATE UNIQUE INDEX IF NOT EXISTS idx_captures_idempotency ON captures(idempotency_key) WHERE idempotency_key <> '';
-- @
module Eza.Clip
  ( -- * Payload
    ClipRequest (..)
  , ClipMetadata (..)
  , emptyClipMetadata
  , SaveClipResult (..)
  , ClipPreview (..)
  , ClipError (..)
  , ClipField (..)
  , clipErrorStatus
  , clipErrorCode
  , clipErrorMessage

    -- * Validation and fingerprints
  , validateClip
  , clipRequestHash

    -- * Operations
  , saveClip
  , previewClip
  , selectTemplate
  , templatesPayload

    -- * Schema
  , clipSchema

    -- * Template API re-exports
  , ClipTemplate (..)
  , TemplateError (..)
  , TemplateField (..)
  , TemplateVars (..)
  , RenderedTemplate (..)
  , templateErrorStatus
  , templateErrorCode
  , templateErrorMessage
  , defaultClipTemplate
  , listTemplates
  , getTemplate
  , createTemplate
  , updateTemplate
  , deleteTemplate
  ) where

import Control.Monad (forM_, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (FromJSON (..), ToJSON (..), Value, decode, encode, object, withObject, (.:?), (.!=), (.=))
import qualified Data.ByteString.Lazy as LBS
import Data.Char (isDigit)
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX (getPOSIXTime, utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Database.SQLite.Simple
import GHC.Generics (Generic)

import Eza.ClipTemplates
import Eza.Rules (applyRules)
import Eza.Url (domainOf, hostOf, isHttpUrl, normalizeUrl)

-- ---------------------------------------------------------------------------
-- Payload
-- ---------------------------------------------------------------------------

-- | Page metadata captured by the clipper's extractor. Every field is
-- optional; oversize values are truncated by 'validateClip'.
data ClipMetadata = ClipMetadata
  { cmAuthor :: Text
  , cmSite :: Text
  , cmPublished :: Text
  , cmDescription :: Text
  , cmLanguage :: Text
  , cmImage :: Text
  , cmFavicon :: Text
  , cmCanonicalUrl :: Text
  , cmExtractor :: Text
  , cmExtractorVersion :: Text
  , cmWordCount :: Maybe Int
  , cmParseTimeMs :: Maybe Int
  }
  deriving (Show, Eq, Generic)

emptyClipMetadata :: ClipMetadata
emptyClipMetadata =
  ClipMetadata
    { cmAuthor = ""
    , cmSite = ""
    , cmPublished = ""
    , cmDescription = ""
    , cmLanguage = ""
    , cmImage = ""
    , cmFavicon = ""
    , cmCanonicalUrl = ""
    , cmExtractor = ""
    , cmExtractorVersion = ""
    , cmWordCount = Nothing
    , cmParseTimeMs = Nothing
    }

instance ToJSON ClipMetadata where
  toJSON metadata =
    object
      [ "author" .= cmAuthor metadata
      , "site" .= cmSite metadata
      , "published" .= cmPublished metadata
      , "description" .= cmDescription metadata
      , "language" .= cmLanguage metadata
      , "image" .= cmImage metadata
      , "favicon" .= cmFavicon metadata
      , "canonical_url" .= cmCanonicalUrl metadata
      , "extractor" .= cmExtractor metadata
      , "extractor_version" .= cmExtractorVersion metadata
      , "word_count" .= cmWordCount metadata
      , "parse_time_ms" .= cmParseTimeMs metadata
      ]

instance FromJSON ClipMetadata where
  parseJSON = withObject "ClipMetadata" $ \o ->
    ClipMetadata
      <$> o .:? "author" .!= ""
      <*> o .:? "site" .!= ""
      <*> o .:? "published" .!= ""
      <*> o .:? "description" .!= ""
      <*> o .:? "language" .!= ""
      <*> o .:? "image" .!= ""
      <*> o .:? "favicon" .!= ""
      <*> o .:? "canonical_url" .!= ""
      <*> o .:? "extractor" .!= ""
      <*> o .:? "extractor_version" .!= ""
      <*> o .:? "word_count"
      <*> o .:? "parse_time_ms"

-- | One clip as the browser extension or another client sends it.
data ClipRequest = ClipRequest
  { clUrl :: Text
  , clTitle :: Text
  , clContentMarkdown :: Text
  , clContentText :: Text
  , clContentHtml :: Text
  , clSelection :: Text
  , clTags :: [Text]
  , clTemplateId :: Maybe Int
  , clSource :: Text
  , clClient :: Text
  , clCapturedAt :: Maybe Int
  , clIdempotencyKey :: Maybe Text
  , clMetadata :: ClipMetadata
  }
  deriving (Show, Eq, Generic)

instance ToJSON ClipRequest where
  toJSON request =
    object
      ( [ "url" .= clUrl request
        , "title" .= clTitle request
        , "content_markdown" .= clContentMarkdown request
        , "content_text" .= clContentText request
        , "content_html" .= clContentHtml request
        , "selection" .= clSelection request
        , "tags" .= clTags request
        , "source" .= clSource request
        , "client" .= clClient request
        , "metadata" .= clMetadata request
        ]
          <> maybe [] (\templateId -> ["template_id" .= templateId]) (clTemplateId request)
          <> maybe [] (\capturedAt -> ["captured_at" .= capturedAt]) (clCapturedAt request)
          <> maybe [] (\key -> ["idempotency_key" .= key]) (clIdempotencyKey request)
      )

instance FromJSON ClipRequest where
  parseJSON = withObject "ClipRequest" $ \o ->
    ClipRequest
      <$> o .:? "url" .!= ""
      <*> o .:? "title" .!= ""
      <*> o .:? "content_markdown" .!= ""
      <*> o .:? "content_text" .!= ""
      <*> o .:? "content_html" .!= ""
      <*> o .:? "selection" .!= ""
      <*> o .:? "tags" .!= []
      <*> o .:? "template_id"
      <*> o .:? "source" .!= "api"
      <*> o .:? "client" .!= ""
      <*> o .:? "captured_at"
      <*> o .:? "idempotency_key"
      <*> o .:? "metadata" .!= emptyClipMetadata

-- | Result of a save. The replay flag and request status:
--
-- * new capture and new bookmark: 201, @bookmark_created = true@
-- * existing bookmark attached: 200, @bookmark_created = false@
-- * idempotent replay: 200, @replayed = true@
data SaveClipResult = SaveClipResult
  { scrCaptureId :: Int
  , scrBookmarkId :: Int
  , scrBookmarkCreated :: Bool
  , scrReplayed :: Bool
  , scrTitle :: Text
  , scrMarkdown :: Text
  , scrTags :: [Text]
  , scrTemplateId :: Int
  , scrTemplateName :: Text
  , scrNeedsEnrichment :: Bool
  }
  deriving (Show, Eq, Generic)

instance ToJSON SaveClipResult where
  toJSON result =
    object
      [ "capture_id" .= scrCaptureId result
      , "bookmark_id" .= scrBookmarkId result
      , "bookmark_created" .= scrBookmarkCreated result
      , "replayed" .= scrReplayed result
      , "title" .= scrTitle result
      , "markdown" .= scrMarkdown result
      , "tags" .= scrTags result
      , "template_id" .= scrTemplateId result
      , "template_name" .= scrTemplateName result
      , "needs_enrichment" .= scrNeedsEnrichment result
      ]

-- | What a preview shows before anything is written.
data ClipPreview = ClipPreview
  { cpTitle :: Text
  , cpMarkdown :: Text
  , cpTags :: [Text]
  , cpTemplateId :: Int
  , cpTemplateName :: Text
  , cpExistingBookmarkId :: Maybe Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON ClipPreview where
  toJSON preview =
    object
      [ "title" .= cpTitle preview
      , "markdown" .= cpMarkdown preview
      , "tags" .= cpTags preview
      , "template_id" .= cpTemplateId preview
      , "template_name" .= cpTemplateName preview
      , "existing_bookmark_id" .= cpExistingBookmarkId preview
      ]

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

-- | Which payload field an error names in its code.
data ClipField
  = ClipFieldUrl
  | ClipFieldTitle
  | ClipFieldTags
  | ClipFieldIdempotency
  | ClipFieldSource
  | ClipFieldClient
  deriving (Show, Eq)

-- | Every validation or save failure a clip can report.
data ClipError
  = ClipInvalidUrl Text
  | ClipFieldTooLong ClipField Int
  | ClipContentTooLarge Text Int
  | ClipInvalidTag Text
  | ClipTooManyTags Int
  | ClipInvalidIdempotencyKey Text
  | ClipIdempotencyConflict
  | ClipTemplateDisabled Int
  | ClipTemplateFailed TemplateError
  | ClipSaveFailed Text
  deriving (Show, Eq)

-- | HTTP status the server should answer with.
clipErrorStatus :: ClipError -> Int
clipErrorStatus err = case err of
  ClipInvalidUrl _ -> 400
  ClipFieldTooLong _ _ -> 400
  ClipContentTooLarge _ _ -> 413
  ClipInvalidTag _ -> 400
  ClipTooManyTags _ -> 400
  ClipInvalidIdempotencyKey _ -> 400
  ClipIdempotencyConflict -> 409
  ClipTemplateDisabled _ -> 409
  ClipTemplateFailed templateError -> templateErrorStatus templateError
  ClipSaveFailed _ -> 500

-- | Stable machine-readable error code (snake_case).
clipErrorCode :: ClipError -> Text
clipErrorCode err = case err of
  ClipInvalidUrl _ -> "invalid_url"
  ClipFieldTooLong clipField _ -> "field_too_long_" <> clipFieldName clipField
  ClipContentTooLarge contentField _ -> "content_too_large_" <> contentField
  ClipInvalidTag _ -> "invalid_tag"
  ClipTooManyTags _ -> "too_many_tags"
  ClipInvalidIdempotencyKey _ -> "invalid_idempotency_key"
  ClipIdempotencyConflict -> "idempotency_conflict"
  ClipTemplateDisabled _ -> "template_disabled"
  ClipTemplateFailed templateError -> templateErrorCode templateError
  ClipSaveFailed _ -> "save_failed"

-- | Human-readable message; it names the offending field or limit.
clipErrorMessage :: ClipError -> Text
clipErrorMessage err = case err of
  ClipInvalidUrl message -> "url is invalid: " <> message
  ClipFieldTooLong clipField maxLength ->
    clipFieldName clipField <> " must be at most " <> T.pack (show maxLength) <> " characters"
  ClipContentTooLarge contentField maxLength ->
    contentField <> " must be at most " <> T.pack (show maxLength) <> " characters"
  ClipInvalidTag tag -> "invalid tag " <> T.pack (show tag)
  ClipTooManyTags maxTags -> "at most " <> T.pack (show maxTags) <> " tags are allowed"
  ClipInvalidIdempotencyKey message -> "invalid Idempotency-Key: " <> message
  ClipIdempotencyConflict -> "this Idempotency-Key was already used for a different clip"
  ClipTemplateDisabled templateId -> "template " <> T.pack (show templateId) <> " is disabled"
  ClipTemplateFailed templateError -> templateErrorMessage templateError
  ClipSaveFailed message -> "the clip could not be saved: " <> message

clipFieldName :: ClipField -> Text
clipFieldName clipField = case clipField of
  ClipFieldUrl -> "url"
  ClipFieldTitle -> "title"
  ClipFieldTags -> "tags"
  ClipFieldIdempotency -> "idempotency_key"
  ClipFieldSource -> "source"
  ClipFieldClient -> "client"

-- ---------------------------------------------------------------------------
-- Limits
-- ---------------------------------------------------------------------------

maxUrlLength, maxTitleInputLength, maxStoredTitleLength :: Int
maxUrlLength = 4000
maxTitleInputLength = 2000
maxStoredTitleLength = 500

maxMarkdownLength, maxTextLength, maxHtmlLength, maxSelectionLength :: Int
maxMarkdownLength = 1000000
maxTextLength = 1000000
maxHtmlLength = 2000000
maxSelectionLength = 100000

maxTagCount, maxTagLength, maxMetadataLength :: Int
maxTagCount = 100
maxTagLength = 64
maxMetadataLength = 4000

maxIdempotencyKeyLength, maxSourceLength, maxClientLength :: Int
maxIdempotencyKeyLength = 200
maxSourceLength = 40
maxClientLength = 120

maxExtractorLength :: Int
maxExtractorLength = 40

maxReasonableEpoch, maxWordCount, maxParseTimeMs :: Int
maxReasonableEpoch = 4102444800 -- 2100-01-01, guards a client clock far in the future
maxWordCount = 1000000000
maxParseTimeMs = 600000

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

-- | Normalize and check a request. The result is what 'saveClip' and
-- 'previewClip' operate on; they re-run it so a direct call is safe.
validateClip :: ClipRequest -> Either ClipError ClipRequest
validateClip request = do
  let rawUrl = T.strip (clUrl request)
  when (T.null rawUrl) $
    Left (ClipInvalidUrl "a URL is required")
  when (not (isHttpUrl rawUrl)) $
    Left (ClipInvalidUrl "only http(s) URLs can be clipped")
  when (T.length rawUrl > maxUrlLength) $
    Left (ClipFieldTooLong ClipFieldUrl maxUrlLength)
  let url = normalizeUrl rawUrl

  let title = T.strip (clTitle request)
  when (T.length title > maxTitleInputLength) $
    Left (ClipFieldTooLong ClipFieldTitle maxTitleInputLength)

  let markdown = T.strip (clContentMarkdown request)
  when (T.length markdown > maxMarkdownLength) $
    Left (ClipContentTooLarge "content_markdown" maxMarkdownLength)
  let text = T.strip (clContentText request)
  when (T.length text > maxTextLength) $
    Left (ClipContentTooLarge "content_text" maxTextLength)
  let html = clContentHtml request
  when (T.length html > maxHtmlLength) $
    Left (ClipContentTooLarge "content_html" maxHtmlLength)
  let selection = T.strip (clSelection request)
  when (T.length selection > maxSelectionLength) $
    Left (ClipContentTooLarge "selection" maxSelectionLength)

  tags <- validateTags (clTags request)
  key <- validateIdempotencyKey (clIdempotencyKey request)
  let source = T.take maxSourceLength (T.strip (clSource request))
      client = T.take maxClientLength (T.strip (clClient request))
  let capturedAt = case clCapturedAt request of
        Just value | value > 0 && value <= maxReasonableEpoch -> Just value
        _ -> Nothing
  let templateId = case clTemplateId request of
        Just value | value > 0 -> Just value
        _ -> Nothing
  let metadata = trimMetadata (clMetadata request)
  pure
    request
      { clUrl = url
      , clTitle = T.take maxStoredTitleLength title
      , clContentMarkdown = markdown
      , clContentText = text
      , clContentHtml = html
      , clSelection = selection
      , clTags = tags
      , clTemplateId = templateId
      , clSource = if T.null source then "clip" else source
      , clClient = client
      , clCapturedAt = capturedAt
      , clIdempotencyKey = key
      , clMetadata = metadata
      }

validateTags :: [Text] -> Either ClipError [Text]
validateTags rawTags = do
  when (length rawTags > maxTagCount) $
    Left (ClipTooManyTags maxTagCount)
  forM_ rawTags $ \tag ->
    when (T.length (T.strip tag) > maxTagLength) $
      Left (ClipInvalidTag (T.take 80 (T.strip tag)))
  pure (dedupeTags (map T.strip rawTags))

validateIdempotencyKey :: Maybe Text -> Either ClipError (Maybe Text)
validateIdempotencyKey rawKey = case fmap T.strip rawKey of
  Nothing -> pure Nothing
  Just key
    | T.null key -> pure Nothing
    | T.length key > maxIdempotencyKeyLength ->
        Left (ClipInvalidIdempotencyKey ("at most " <> T.pack (show maxIdempotencyKeyLength) <> " characters"))
    | T.any (\c -> c <= ' ' || c == '\DEL') key ->
        Left (ClipInvalidIdempotencyKey "only visible characters are allowed")
    | otherwise -> pure (Just key)

trimMetadata :: ClipMetadata -> ClipMetadata
trimMetadata metadata =
  metadata
    { cmAuthor = trimLength (cmAuthor metadata)
    , cmSite = trimLength (cmSite metadata)
    , cmPublished = trimLength (cmPublished metadata)
    , cmDescription = trimLength (cmDescription metadata)
    , cmLanguage = trimLength (cmLanguage metadata)
    , cmImage = trimLength (cmImage metadata)
    , cmFavicon = trimLength (cmFavicon metadata)
    , cmCanonicalUrl = trimLength (cmCanonicalUrl metadata)
    , cmExtractor = T.take maxExtractorLength (T.strip (cmExtractor metadata))
    , cmExtractorVersion = T.take maxExtractorLength (T.strip (cmExtractorVersion metadata))
    , cmWordCount = clampCount maxWordCount (cmWordCount metadata)
    , cmParseTimeMs = clampCount maxParseTimeMs (cmParseTimeMs metadata)
    }
  where
    trimLength value = T.take maxMetadataLength (T.strip value)
    clampCount _ Nothing = Nothing
    clampCount maximum' (Just value)
      | value < 0 = Just 0
      | value > maximum' = Just maximum'
      | otherwise = Just value

-- ---------------------------------------------------------------------------
-- Request fingerprints
-- ---------------------------------------------------------------------------

-- | Hash of the stable parts of a validated request: two retries of the same
-- clip hash the same even when @captured_at@ or the extractor timing differs.
-- The fingerprint never leaves the server (the extension does not compute it).
clipRequestHash :: ClipRequest -> Text
clipRequestHash request = T.pack (show (hash (TE.encodeUtf8 packed) :: Digest SHA256))
  where
    metadata = clMetadata request
    fields =
      [ clUrl request
      , clTitle request
      , clContentMarkdown request
      , clContentText request
      , clContentHtml request
      , clSelection request
      , T.intercalate "\n" (sortOn id (map T.toLower (clTags request)))
      , maybe "0" (T.pack . show) (clTemplateId request)
      , clSource request
      , clClient request
      , cmAuthor metadata
      , cmSite metadata
      , cmPublished metadata
      , cmDescription metadata
      , cmLanguage metadata
      , cmImage metadata
      , cmFavicon metadata
      , cmCanonicalUrl metadata
      , cmExtractor metadata
      , cmExtractorVersion metadata
      ]
    packed = T.intercalate "\US" (map packField fields)
    packField value = T.pack (show (T.length value)) <> ":" <> value

-- ---------------------------------------------------------------------------
-- Template selection and rendering values
-- ---------------------------------------------------------------------------

-- | Choose the template for a request: an explicit id (404/409 when missing
-- or disabled), otherwise the most specific matching trigger, otherwise the
-- built-in default (id 0).
selectTemplate :: Connection -> ClipRequest -> IO (Either ClipError ClipTemplate)
selectTemplate conn request = do
  templates <- listTemplates conn
  case clTemplateId request of
    Just templateId -> do
      stored <- getTemplate conn templateId
      pure $ case stored of
        Nothing -> Left (ClipTemplateFailed TemplateNotFound)
        Just template
          | not (ctEnabled template) -> Left (ClipTemplateDisabled templateId)
          | otherwise -> Right template
    Nothing -> do
      let matches =
            [ (score, template)
            | template <- templates
            , Just score <- [triggerScore template (clUrl request)]
            ]
      pure $ case sortOn (\(score, template) -> (negate score, ctId template)) matches of
        ((_, template) : _) -> Right template
        [] -> Right defaultClipTemplate

clipVars :: ClipRequest -> Int -> TemplateVars
clipVars request capturedAt =
  TemplateVars
    { tvTitle = clTitle request
    , tvUrl = clUrl request
    , tvCanonicalUrl = cmCanonicalUrl metadata
    , tvDomain = domainOf (hostOf (clUrl request))
    , tvSite = cmSite metadata
    , tvAuthor = cmAuthor metadata
    , tvPublished = cmPublished metadata
    , tvDescription = cmDescription metadata
    , tvImage = cmImage metadata
    , tvLanguage = cmLanguage metadata
    , tvContent = firstNonEmpty [clContentMarkdown request, clContentText request]
    , tvContentText = clContentText request
    , tvSelection = clSelection request
    , tvCapturedAt = capturedAt
    , tvWords = fromMaybe (countWords (clContentText request)) (cmWordCount metadata)
    }
  where
    metadata = clMetadata request

-- ---------------------------------------------------------------------------
-- Preview
-- ---------------------------------------------------------------------------

-- | Render the note the save would write, without writing anything. Useful
-- for the extension popup and for a template editor. Reads only.
previewClip :: Connection -> ClipRequest -> IO (Either ClipError ClipPreview)
previewClip conn request =
  case validateClip request of
    Left err -> pure (Left err)
    Right clean -> do
      now <- epoch
      templateResult <- selectTemplate conn clean
      case templateResult of
        Left err -> pure (Left err)
        Right template ->
          case renderTemplate template (clipVars clean (fromMaybe now (clCapturedAt clean))) of
            Left err -> pure (Left (ClipTemplateFailed err))
            Right rendered -> do
              existing <- findBookmark conn (clUrl clean)
              pure
                ( Right
                    ClipPreview
                      { cpTitle = bookmarkTitle clean rendered
                      , cpMarkdown = rtMarkdown rendered
                      , cpTags = mergeTags rendered (clTags clean)
                      , cpTemplateId = ctId template
                      , cpTemplateName = ctName template
                      , cpExistingBookmarkId = existing
                      }
                )

-- ---------------------------------------------------------------------------
-- Save
-- ---------------------------------------------------------------------------

-- | Validate, select a template, render, and save a capture. The bookmark,
-- capture row, and tags are written in one immediate transaction. The
-- returned 'ClipError' carries the status/code the server should answer with.
saveClip :: Connection -> ClipRequest -> IO (Either ClipError SaveClipResult)
saveClip conn request =
  case validateClip request of
    Left err -> pure (Left err)
    Right clean -> do
      now <- epoch
      fastReplay <- replayCaptureConflict conn clean
      case fastReplay of
        Left err -> pure (Left err)
        Right (Just result) -> pure (Right result)
        Right Nothing -> do
          templateResult <- selectTemplate conn clean
          case templateResult of
            Left err -> pure (Left err)
            Right template -> do
              let capturedAt = fromMaybe now (clCapturedAt clean)
                  vars = clipVars clean capturedAt
              case renderTemplate template vars of
                Left err -> pure (Left (ClipTemplateFailed err))
                Right rendered -> do
                  let tags = mergeTags rendered (clTags clean)
                      title = bookmarkTitle clean rendered
                  result <-
                    withImmediateTransaction conn $ do
                      replay <- replayCaptureConflict conn clean
                      case replay of
                        Left err -> pure (Left err)
                        Right (Just value) -> pure (Right value)
                        Right Nothing -> do
                          (bookmarkId, created) <- upsertBookmark conn clean now title rendered tags
                          captureId <- insertCapture conn clean now title rendered tags template bookmarkId
                          pure
                            ( Right
                                SaveClipResult
                                  { scrCaptureId = captureId
                                  , scrBookmarkId = bookmarkId
                                  , scrBookmarkCreated = created
                                  , scrReplayed = False
                                  , scrTitle = title
                                  , scrMarkdown = rtMarkdown rendered
                                  , scrTags = tags
                                  , scrTemplateId = ctId template
                                  , scrTemplateName = ctName template
                                  , scrNeedsEnrichment = created && T.null (T.strip (clContentText clean))
                                  }
                            )
                  pure result

replayResult :: CaptureRow -> SaveClipResult
replayResult row =
  SaveClipResult
    { scrCaptureId = captureId row
    , scrBookmarkId = captureBookmarkId row
    , scrBookmarkCreated = False
    , scrReplayed = True
    , scrTitle = captureTitle row
    , scrMarkdown = captureRenderedMarkdown row
    , scrTags = parseTextListJson (captureTagsJson row)
    , scrTemplateId = fromMaybe 0 (captureTemplateId row)
    , scrTemplateName = captureTemplateName row
    , scrNeedsEnrichment = False
    }

-- | Conflicting replay detection: a key that maps to a different request hash
-- is an error, not a silent overwrite. Checked before and inside the write
-- transaction so a race cannot create a second capture.
replayCaptureConflict :: Connection -> ClipRequest -> IO (Either ClipError (Maybe SaveClipResult))
replayCaptureConflict conn cleanRequest = case clIdempotencyKey cleanRequest of
  Nothing -> pure (Right Nothing)
  Just key -> do
    stored <- lookupCapture conn key
    pure $ case stored of
      Nothing -> Right Nothing
      Just row
        | captureRequestHash row == clipRequestHash cleanRequest -> Right (Just (replayResult row))
        | otherwise -> Left ClipIdempotencyConflict

-- | Insert or find the bookmark for the clip URL, then make sure its rendered
-- note and tags are recorded. Never overwrites a non-empty user field.
upsertBookmark ::
  Connection ->
  ClipRequest ->
  Int ->
  Text ->
  RenderedTemplate ->
  [Text] ->
  IO (Int, Bool)
upsertBookmark conn request now title rendered tags = do
  existing <- findBookmark conn (clUrl request)
  case existing of
    Just bookmarkId -> do
      updateExistingBookmark conn request bookmarkId now title
      insertTags conn bookmarkId tags now
      pure (bookmarkId, False)
    Nothing -> do
      let capturedAt = fromMaybe now (clCapturedAt request)
          text = clContentText request
          hasText = not (T.null (T.strip text))
          metadata = clMetadata request
          reading = readingMinutes (countWords text)
          publishedAt = parsePublishedAt (cmPublished metadata)
          finalUrl = firstNonEmpty [cmCanonicalUrl metadata, clUrl request]
      executeNamed
        conn
        ( Query
            ( "INSERT INTO bookmarks (url, title, description, favicon_url, domain, source, created_at, added_at, updated_at, "
                <> "note_body, extracted_text, author, sitename, published_at, language, image_url, final_url, enrich_state, reading_time_minutes, enriched_at) "
                <> "VALUES (:url, :title, :description, :favicon_url, :domain, :source, :created_at, :added_at, :updated_at, "
                <> ":note_body, :extracted_text, :author, :sitename, :published_at, :language, :image_url, :final_url, :enrich_state, :reading_time_minutes, :enriched_at)"
            )
        )
        [ ":url" := clUrl request
        , ":title" := title
        , ":description" := cmDescription metadata
        , ":favicon_url" := cmFavicon metadata
        , ":domain" := hostOf (clUrl request)
        , ":source" := clSource request
        , ":created_at" := capturedAt
        , ":added_at" := now
        , ":updated_at" := now
        , ":note_body" := rtMarkdown rendered
        , ":extracted_text" := text
        , ":author" := cmAuthor metadata
        , ":sitename" := cmSite metadata
        , ":published_at" := (publishedAt :: Maybe Int)
        , ":language" := cmLanguage metadata
        , ":image_url" := cmImage metadata
        , ":final_url" := finalUrl
        , ":enrich_state" := (if hasText then "ok" else "idle" :: Text)
        , ":reading_time_minutes" := reading
        , ":enriched_at" := (if hasText then Just now else Nothing :: Maybe Int)
        ]
      bookmarkId <- fromIntegral <$> lastInsertRowId conn
      insertTags conn bookmarkId tags now
      _ <- applyRules conn bookmarkId (clUrl request) title
      pure (bookmarkId, True)

updateExistingBookmark :: Connection -> ClipRequest -> Int -> Int -> Text -> IO ()
updateExistingBookmark conn request bookmarkId now title = do
  let metadata = clMetadata request
      text = clContentText request
      publishedAt = parsePublishedAt (cmPublished metadata)
      finalUrl = firstNonEmpty [cmCanonicalUrl metadata, clUrl request]
  executeNamed
    conn
    ( Query
        ( "UPDATE bookmarks SET "
            <> "title = CASE WHEN trim(title) = '' AND :title <> '' THEN :title ELSE title END, "
            <> "description = CASE WHEN trim(description) = '' THEN :description ELSE description END, "
            <> "author = CASE WHEN trim(author) = '' THEN :author ELSE author END, "
            <> "sitename = CASE WHEN trim(sitename) = '' THEN :sitename ELSE sitename END, "
            <> "published_at = CASE WHEN published_at IS NULL THEN :published_at ELSE published_at END, "
            <> "language = CASE WHEN trim(language) = '' THEN :language ELSE language END, "
            <> "image_url = CASE WHEN trim(image_url) = '' THEN :image_url ELSE image_url END, "
            <> "favicon_url = CASE WHEN trim(favicon_url) = '' THEN :favicon_url ELSE favicon_url END, "
            <> "final_url = CASE WHEN trim(final_url) = '' THEN :final_url ELSE final_url END, "
            <> "extracted_text = CASE WHEN trim(extracted_text) = '' THEN :extracted_text ELSE extracted_text END, "
            <> "reading_time_minutes = CASE WHEN reading_time_minutes = 0 THEN :reading_time_minutes ELSE reading_time_minutes END, "
            <> "updated_at = :updated_at "
            <> "WHERE id = :id"
        )
    )
    [ ":title" := title
    , ":description" := cmDescription metadata
    , ":author" := cmAuthor metadata
    , ":sitename" := cmSite metadata
    , ":published_at" := (publishedAt :: Maybe Int)
    , ":language" := cmLanguage metadata
    , ":image_url" := cmImage metadata
    , ":favicon_url" := cmFavicon metadata
    , ":final_url" := finalUrl
    , ":extracted_text" := text
    , ":reading_time_minutes" := readingMinutes (countWords text)
    , ":updated_at" := now
    , ":id" := bookmarkId
    ]

insertCapture ::
  Connection ->
  ClipRequest ->
  Int ->
  Text ->
  RenderedTemplate ->
  [Text] ->
  ClipTemplate ->
  Int ->
  IO Int
insertCapture conn request now title rendered tags template bookmarkId = do
  let metadata = clMetadata request
  executeNamed
    conn
    ( Query
        ( "INSERT INTO captures (bookmark_id, url, canonical_url, title, author, site, description, published, language, image_url, "
            <> "favicon_url, content_markdown, rendered_markdown, content_text, content_html, selection, tags, template_id, template_name, "
            <> "source, client, idempotency_key, request_hash, extractor, extractor_version, metadata_json, word_count, parse_time_ms, captured_at, created_at) "
            <> "VALUES (:bookmark_id, :url, :canonical_url, :title, :author, :site, :description, :published, :language, :image_url, "
            <> ":favicon_url, :content_markdown, :rendered_markdown, :content_text, :content_html, :selection, :tags, :template_id, :template_name, "
            <> ":source, :client, :idempotency_key, :request_hash, :extractor, :extractor_version, :metadata_json, :word_count, :parse_time_ms, :captured_at, :created_at)"
        )
    )
    [ ":bookmark_id" := bookmarkId
    , ":url" := clUrl request
    , ":canonical_url" := cmCanonicalUrl metadata
    , ":title" := title
    , ":author" := cmAuthor metadata
    , ":site" := cmSite metadata
    , ":description" := cmDescription metadata
    , ":published" := cmPublished metadata
    , ":language" := cmLanguage metadata
    , ":image_url" := cmImage metadata
    , ":favicon_url" := cmFavicon metadata
    , ":content_markdown" := clContentMarkdown request
    , ":rendered_markdown" := rtMarkdown rendered
    , ":content_text" := clContentText request
    , ":content_html" := clContentHtml request
    , ":selection" := clSelection request
    , ":tags" := encodeTextListJson tags
    , ":template_id" := ((if ctBuiltin template then Nothing else Just (ctId template)) :: Maybe Int)
    , ":template_name" := ctName template
    , ":source" := clSource request
    , ":client" := clClient request
    , ":idempotency_key" := fromMaybe "" (clIdempotencyKey request)
    , ":request_hash" := clipRequestHash request
    , ":extractor" := cmExtractor metadata
    , ":extractor_version" := cmExtractorVersion metadata
    , ":metadata_json" := TE.decodeUtf8 (LBS.toStrict (encode metadata))
    , ":word_count" := fromMaybe (countWords (clContentText request)) (cmWordCount metadata)
    , ":parse_time_ms" := fromMaybe 0 (cmParseTimeMs metadata)
    , ":captured_at" := fromMaybe now (clCapturedAt request)
    , ":created_at" := now
    ]
  fromIntegral <$> lastInsertRowId conn

-- ---------------------------------------------------------------------------
-- Bookmark and capture lookups
-- ---------------------------------------------------------------------------

findBookmark :: Connection -> Text -> IO (Maybe Int)
findBookmark conn url = do
  rows <-
    query
      conn
      "SELECT id FROM bookmarks WHERE url = ? OR url = ? ORDER BY id LIMIT 1"
      (url, normalizeUrl url) ::
      IO [Only Int]
  pure (case rows of [Only bookmarkId] -> Just bookmarkId; _ -> Nothing)

insertTags :: Connection -> Int -> [Text] -> Int -> IO ()
insertTags conn bookmarkId tags now =
  forM_ (dedupeTags tags) $ \tag -> do
    execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)" (tag, now)
    ids <- query conn "SELECT id FROM tags WHERE name = ?" (Only tag) :: IO [Only Int]
    case ids of
      (Only tagId : _) ->
        execute
          conn
          "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?, ?)"
          (bookmarkId, tagId)
      _ -> pure ()

data CaptureRow = CaptureRow
  { captureId :: Int
  , captureBookmarkId :: Int
  , captureTitle :: Text
  , captureRenderedMarkdown :: Text
  , captureTagsJson :: Text
  , captureTemplateId :: Maybe Int
  , captureTemplateName :: Text
  , captureRequestHash :: Text
  }

instance FromRow CaptureRow where
  fromRow =
    CaptureRow
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

lookupCapture :: Connection -> Text -> IO (Maybe CaptureRow)
lookupCapture conn key = do
  rows <-
    query
      conn
      ( Query
          ( "SELECT id, bookmark_id, title, rendered_markdown, tags, template_id, template_name, request_hash "
              <> "FROM captures WHERE idempotency_key = ?"
          )
      )
      (Only key) ::
      IO [CaptureRow]
  pure (case rows of [row] -> Just row; _ -> Nothing)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

epoch :: IO Int
epoch = floor <$> getPOSIXTime

encodeTextListJson :: [Text] -> Text
encodeTextListJson = TE.decodeUtf8 . LBS.toStrict . encode

parseTextListJson :: Text -> [Text]
parseTextListJson raw =
  case decode (LBS.fromStrict (TE.encodeUtf8 raw)) :: Maybe [Text] of
    Just values -> values
    Nothing -> []

mergeTags :: RenderedTemplate -> [Text] -> [Text]
mergeTags rendered requestTags = dedupeTags (rtTags rendered <> requestTags)

bookmarkTitle :: ClipRequest -> RenderedTemplate -> Text
bookmarkTitle request rendered =
  T.take maxStoredTitleLength (firstNonEmpty [rtTitle rendered, clTitle request, hostOf (clUrl request), "Untitled"])

firstNonEmpty :: [Text] -> Text
firstNonEmpty values =
  case filter (not . T.null . T.strip) values of
    (value : _) -> T.strip value
    [] -> ""

countWords :: Text -> Int
countWords = length . T.words

readingMinutes :: Int -> Int
readingMinutes wordCount
  | wordCount <= 0 = 0
  | otherwise = (wordCount + 219) `div` 220

parsePublishedAt :: Text -> Maybe Int
parsePublishedAt raw =
  let value = T.strip raw
      asEpoch
        | not (T.null value) && T.length value <= 12 && T.all isDigit value = Just (read (T.unpack value) :: Int)
        | otherwise = Nothing
   in case asEpoch of
        Just epochValue -> Just epochValue
        Nothing ->
          case [timestamp | format <- publishedFormats, Just timestamp <- [parseWith format value]] of
            (timestamp : _) -> Just timestamp
            [] -> Nothing
  where
    publishedFormats =
      [ "%Y-%m-%dT%H:%M:%S%Q%Ez"
      , "%Y-%m-%dT%H:%M:%S%QZ"
      , "%Y-%m-%dT%H:%M:%S%Q"
      , "%Y-%m-%dT%H:%M:%SZ"
      , "%Y-%m-%dT%H:%M:%S"
      , "%Y-%m-%d %H:%M:%S"
      , "%Y-%m-%d"
      ]
    parseWith format value' =
      case parseTimeM True defaultTimeLocale format (T.unpack value') :: Maybe UTCTime of
        Nothing -> Nothing
        Just utc -> Just (floor (utcTimeToPOSIXSeconds utc))

-- | The extension's template dropdown renders this. The built-in default is
-- returned separately so the client can show it even when no rows exist.
templatesPayload :: Connection -> IO Value
templatesPayload conn = do
  templates <- listTemplates conn
  pure (object ["templates" .= templates, "builtin" .= defaultClipTemplate])

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

-- | Migration v8 statements for @captures@ and @clip_templates@. Append to
-- "Eza.Db" as a new migration version; never edit a shipped migration.
clipSchema :: [Text]
clipSchema =
  [ "CREATE TABLE IF NOT EXISTS clip_templates ( id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '', enabled INTEGER NOT NULL DEFAULT 1, title_template TEXT NOT NULL DEFAULT '{{title}}', body_template TEXT NOT NULL DEFAULT '{{content}}', default_tags TEXT NOT NULL DEFAULT '[]', trigger_urls TEXT NOT NULL DEFAULT '[]', trigger_regex TEXT NOT NULL DEFAULT '', is_builtin INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL )"
  , "CREATE INDEX IF NOT EXISTS idx_clip_templates_enabled ON clip_templates(enabled, id)"
  , "CREATE TABLE IF NOT EXISTS captures ( id INTEGER PRIMARY KEY AUTOINCREMENT, bookmark_id INTEGER NOT NULL REFERENCES bookmarks(id) ON DELETE CASCADE, url TEXT NOT NULL, canonical_url TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '', author TEXT NOT NULL DEFAULT '', site TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '', published TEXT NOT NULL DEFAULT '', language TEXT NOT NULL DEFAULT '', image_url TEXT NOT NULL DEFAULT '', favicon_url TEXT NOT NULL DEFAULT '', content_markdown TEXT NOT NULL DEFAULT '', rendered_markdown TEXT NOT NULL DEFAULT '', content_text TEXT NOT NULL DEFAULT '', content_html TEXT NOT NULL DEFAULT '', selection TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '[]', template_id INTEGER REFERENCES clip_templates(id) ON DELETE SET NULL, template_name TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '', client TEXT NOT NULL DEFAULT '', idempotency_key TEXT NOT NULL DEFAULT '', request_hash TEXT NOT NULL DEFAULT '', extractor TEXT NOT NULL DEFAULT '', extractor_version TEXT NOT NULL DEFAULT '', metadata_json TEXT NOT NULL DEFAULT '{}', word_count INTEGER NOT NULL DEFAULT 0, parse_time_ms INTEGER NOT NULL DEFAULT 0, captured_at INTEGER NOT NULL, created_at INTEGER NOT NULL )"
  , "CREATE INDEX IF NOT EXISTS idx_captures_bookmark ON captures(bookmark_id)"
  , "CREATE INDEX IF NOT EXISTS idx_captures_created ON captures(created_at DESC, id DESC)"
  , "CREATE UNIQUE INDEX IF NOT EXISTS idx_captures_idempotency ON captures(idempotency_key) WHERE idempotency_key <> ''"
  ]
