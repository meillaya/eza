{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Declarative views: the data behind the graph and ledger customisation and
the first extension kind.

A view is data, not code. The server validates a view before storing it, the
client renders only the known fields, and unknown schema versions or kinds are
rejected. Everything here is pure so the server, the WASM client, and the tests
share one definition.
-}
module Eza.View (
    -- * Kinds and enums
    ViewKind (..),
    viewKindText,
    parseViewKind,
    LabelMode (..),
    labelModeText,
    parseLabelMode,
    LedgerSort (..),
    ledgerSortText,
    parseLedgerSort,

    -- * Definitions
    ColorGroup (..),
    GraphViewDefinition (..),
    LedgerViewDefinition (..),
    ViewDefinition (..),
    View (..),
    ViewInput (..),

    -- * Defaults and helpers
    defaultGraphViewDefinition,
    defaultLedgerViewDefinition,
    slugify,
    validateViewName,
    validateQueryText,
    validateColor,
    validateViewDefinition,
    validateViewDraft,
    decodeViewDefinition,
    encodeViewDefinition,
    definitionByteLimit,
    maxColorGroups,
    maxViewName,
    maxQueryLength,
    maxViewsPerUser,
    viewDefinitionKind,
) where

import Control.Monad (when)
import Data.Aeson
import Data.Aeson.Types (Parser)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Char (isAlphaNum, isAsciiLower, isDigit, toLower)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)

import Eza.GraphLayout (LayoutPreset (..))
import Eza.SearchQuery (parseSearchQuery, sqLinkTargets)

-- ------------------------------------------------------------------ kinds ---

data ViewKind = GraphKind | LedgerKind
    deriving (Show, Eq, Generic)

viewKindText :: ViewKind -> Text
viewKindText = \case
    GraphKind -> "graph"
    LedgerKind -> "ledger"

parseViewKind :: Text -> Maybe ViewKind
parseViewKind raw = case T.toLower (T.strip raw) of
    "graph" -> Just GraphKind
    "ledger" -> Just LedgerKind
    _ -> Nothing

data LabelMode = LabelAuto | LabelTags | LabelNone
    deriving (Show, Eq, Enum, Bounded, Generic)

labelModeText :: LabelMode -> Text
labelModeText = \case
    LabelAuto -> "auto"
    LabelTags -> "tags"
    LabelNone -> "none"

parseLabelMode :: Text -> Maybe LabelMode
parseLabelMode raw = case T.toLower (T.strip raw) of
    "auto" -> Just LabelAuto
    "tags" -> Just LabelTags
    "none" -> Just LabelNone
    _ -> Nothing

data LedgerSort = SortCreated | SortAdded | SortOpened
    deriving (Show, Eq, Enum, Bounded, Generic)

ledgerSortText :: LedgerSort -> Text
ledgerSortText = \case
    SortCreated -> "created"
    SortAdded -> "added"
    SortOpened -> "opened"

parseLedgerSort :: Text -> Maybe LedgerSort
parseLedgerSort raw = case T.toLower (T.strip raw) of
    "created" -> Just SortCreated
    "added" -> Just SortAdded
    "opened" -> Just SortOpened
    _ -> Nothing

-- -------------------------------------------------------------- definitions ---

data ColorGroup = ColorGroup
    { cgName :: Text
    , cgQuery :: Text
    , cgColor :: Text
    , cgEnabled :: Bool
    }
    deriving (Show, Eq, Generic)

instance ToJSON ColorGroup where
    toJSON group =
        object
            [ "name" .= cgName group
            , "query" .= cgQuery group
            , "color" .= cgColor group
            , "enabled" .= cgEnabled group
            ]

instance FromJSON ColorGroup where
    parseJSON = withObject "ColorGroup" $ \o ->
        ColorGroup
            <$> o .:? "name" .!= ""
            <*> o .:? "query" .!= ""
            <*> o .:? "color" .!= "#C98A3E"
            <*> o .:? "enabled" .!= True

data GraphViewDefinition = GraphViewDefinition
    { gvdQuery :: Text
    , gvdTagsShown :: Bool
    , gvdLabelMode :: LabelMode
    , gvdLayoutPreset :: LayoutPreset
    , gvdLocalDepth :: Maybe Int
    , gvdColorGroups :: [ColorGroup]
    }
    deriving (Show, Eq, Generic)

data LedgerViewDefinition = LedgerViewDefinition
    { lvdQuery :: Text
    , lvdSort :: LedgerSort
    }
    deriving (Show, Eq, Generic)

data ViewDefinition = GraphDefinition GraphViewDefinition | LedgerDefinition LedgerViewDefinition
    deriving (Show, Eq, Generic)

instance ToJSON GraphViewDefinition where
    toJSON definition =
        object
            [ "query" .= gvdQuery definition
            , "tags_shown" .= gvdTagsShown definition
            , "label_mode" .= labelModeText (gvdLabelMode definition)
            , "layout_preset" .= layoutPresetText (gvdLayoutPreset definition)
            , "local_depth" .= gvdLocalDepth definition
            , "color_groups" .= gvdColorGroups definition
            ]

instance FromJSON GraphViewDefinition where
    parseJSON = withObject "GraphViewDefinition" $ \o -> do
        mode <- o .:? "label_mode" .!= ("auto" :: Text)
        labelMode <- maybe (fail "label_mode must be auto, tags, or none") pure (parseLabelMode mode)
        preset <- o .:? "layout_preset" .!= ("standard" :: Text)
        layoutPreset <- maybe (fail "layout_preset must be compact, standard, or airy") pure (parseLayoutPreset preset)
        GraphViewDefinition
            <$> (o .:? "query" .!= "")
            <*> (o .:? "tags_shown" .!= True)
            <*> pure labelMode
            <*> pure layoutPreset
            <*> o .:? "local_depth"
            <*> (o .:? "color_groups" .!= [])

instance ToJSON LedgerViewDefinition where
    toJSON definition =
        object
            [ "query" .= lvdQuery definition
            , "sort" .= ledgerSortText (lvdSort definition)
            ]

instance FromJSON LedgerViewDefinition where
    parseJSON = withObject "LedgerViewDefinition" $ \o -> do
        rawSort <- o .:? "sort" .!= ("created" :: Text)
        sortValue <- maybe (fail "sort must be created, added, or opened") pure (parseLedgerSort rawSort)
        LedgerViewDefinition
            <$> (o .:? "query" .!= "")
            <*> pure sortValue

instance ToJSON ViewDefinition where
    toJSON = \case
        GraphDefinition definition -> toJSON definition
        LedgerDefinition definition -> toJSON definition

-- | A stored view with its server-assigned identity and timestamps.
data View = View
    { vId :: Int
    , vSlug :: Text
    , vName :: Text
    , vKind :: ViewKind
    , vIsDefault :: Bool
    , vDefinition :: ViewDefinition
    , vCreatedAt :: Int
    , vUpdatedAt :: Int
    }
    deriving (Show, Eq, Generic)

instance ToJSON View where
    toJSON view =
        object
            [ "schema" .= (1 :: Int)
            , "id" .= vId view
            , "slug" .= vSlug view
            , "name" .= vName view
            , "kind" .= viewKindText (vKind view)
            , "is_default" .= vIsDefault view
            , "definition" .= vDefinition view
            , "created_at" .= vCreatedAt view
            , "updated_at" .= vUpdatedAt view
            ]

instance FromJSON View where
    parseJSON = withObject "View" $ \o -> do
        schema <- o .:? "schema" .!= (1 :: Int)
        when (schema /= 1) (fail "unsupported view schema")
        rawKind <- o .: "kind" :: Parser Text
        kind <- maybe (fail "kind must be graph or ledger") pure (parseViewKind rawKind)
        rawDefinition <- o .: "definition" :: Parser Value
        definition <- either (fail . T.unpack) pure (decodeViewDefinition kind rawDefinition)
        View
            <$> (o .:? "id" .!= 0)
            <*> (o .:? "slug" .!= "")
            <*> (o .:? "name" .!= "")
            <*> pure kind
            <*> (o .:? "is_default" .!= False)
            <*> pure definition
            <*> (o .:? "created_at" .!= 0)
            <*> (o .:? "updated_at" .!= 0)

-- | The create/update body: no server-owned fields.
data ViewInput = ViewInput
    { viName :: Text
    , viKind :: ViewKind
    , viDefinition :: ViewDefinition
    , viSlug :: Maybe Text
    }
    deriving (Show, Eq, Generic)

instance FromJSON ViewInput where
    parseJSON = withObject "ViewInput" $ \o -> do
        schema <- o .:? "schema" :: Parser (Maybe Int)
        case schema of
            Just version | version /= 1 -> fail "unsupported view schema"
            _ -> pure ()
        rawKind <- o .: "kind" :: Parser Text
        kind <- maybe (fail "kind must be graph or ledger") pure (parseViewKind rawKind)
        rawDefinition <- o .: "definition" :: Parser Value
        definition <- either (fail . T.unpack) pure (decodeViewDefinition kind rawDefinition)
        ViewInput
            <$> (o .: "name")
            <*> pure kind
            <*> pure definition
            <*> o .:? "slug"

instance ToJSON ViewInput where
    toJSON input =
        object
            [ "name" .= viName input
            , "kind" .= viewKindText (viKind input)
            , "definition" .= viDefinition input
            , "slug" .= viSlug input
            ]

-- --------------------------------------------------------------- defaults ---

defaultGraphViewDefinition :: GraphViewDefinition
defaultGraphViewDefinition =
    GraphViewDefinition
        { gvdQuery = ""
        , gvdTagsShown = True
        , gvdLabelMode = LabelAuto
        , gvdLayoutPreset = Standard
        , gvdLocalDepth = Nothing
        , gvdColorGroups = []
        }

defaultLedgerViewDefinition :: LedgerViewDefinition
defaultLedgerViewDefinition =
    LedgerViewDefinition
        { lvdQuery = ""
        , lvdSort = SortCreated
        }

-- ---------------------------------------------------------------- helpers ---

maxViewName :: Int
maxViewName = 80

maxQueryLength :: Int
maxQueryLength = 512

maxColorGroups :: Int
maxColorGroups = 24

maxViewsPerUser :: Int
maxViewsPerUser = 64

definitionByteLimit :: Int
definitionByteLimit = 65536

{- | A URL slug derived from a display name. The server appends a numeric
suffix when the slug is already used by the same user.
-}
slugify :: Text -> Text
slugify raw =
    let lowered = T.toLower raw
        cleaned = T.map keep lowered
        collapsed = collapse '-' (T.strip cleaned)
        trimmed = T.dropAround (== '-') collapsed
     in if T.null trimmed then "view" else T.take 48 trimmed
  where
    keep c
        | isAlphaNum c = toLower c
        | c == '-' || c == '_' || c == ' ' = '-'
        | otherwise = '-'
    collapse ch text
        | T.null text = text
        | T.head text == ch = ch `T.cons` collapse ch (T.dropWhile (== ch) text)
        | otherwise = T.head text `T.cons` collapse ch (T.tail text)

validateViewName :: Text -> Either [Text] ()
validateViewName name
    | T.null (T.strip name) = Left ["name is required"]
    | T.length (T.strip name) > maxViewName = Left ["name is too long"]
    | otherwise = Right ()

validateQueryText :: Text -> Either [Text] ()
validateQueryText query
    | T.length query > maxQueryLength = Left ["query is too long"]
    | otherwise = Right ()

validateColor :: Text -> Either [Text] ()
validateColor color
    | isHexColor color = Right ()
    | otherwise = Left ["color must be #rrggbb"]

isHexColor :: Text -> Bool
isHexColor color = case T.unpack color of
    ('#' : rest) -> length rest == 6 && all isHexDigit rest
    _ -> False
  where
    isHexDigit c = c `elem` ("0123456789abcdefABCDEF" :: String)

-- | Validate a definition for a kind, including the group query limits.
validateViewDefinition :: ViewKind -> ViewDefinition -> Either [Text] ()
validateViewDefinition kind definition = case (kind, definition) of
    (GraphKind, GraphDefinition graph) -> validateGraph graph
    (LedgerKind, LedgerDefinition ledger) -> validateLedger ledger
    _ -> Left ["definition kind does not match the view kind"]
  where
    validateGraph graph = do
        validateQueryText (gvdQuery graph)
        validateLocalDepth (gvdLocalDepth graph)
        validateGroups (gvdColorGroups graph)
        case sqLinkTargets (parseSearchQuery (gvdQuery graph)) of
            [] -> Right ()
            _ -> Left ["link: is not supported in graph views"]
    validateLocalDepth Nothing = Right ()
    validateLocalDepth (Just depth)
        | depth >= 1 && depth <= 3 = Right ()
        | otherwise = Left ["local_depth must be 1, 2, or 3"]
    validateGroups groups
        | length groups > maxColorGroups = Left ["too many color groups"]
        | otherwise = mapM_ validateGroup groups
    validateGroup group = do
        if T.null (T.strip (cgName group)) then Left ["color group name is required"] else Right ()
        if T.length (cgName group) > maxViewName then Left ["color group name is too long"] else Right ()
        validateQueryText (cgQuery group)
        case sqLinkTargets (parseSearchQuery (cgQuery group)) of
            [] -> Right ()
            _ -> Left ["link: is not supported in color group queries"]
        validateColor (cgColor group)
    validateLedger ledger = validateQueryText (lvdQuery ledger)

-- | Validate the user-supplied pieces of a draft.
validateViewDraft :: ViewInput -> Either [Text] ()
validateViewDraft input = do
    validateViewName (viName input)
    validateViewDefinition (viKind input) (viDefinition input)
    let encoded = encodeViewDefinition (viDefinition input)
    if BS.length (TE.encodeUtf8 encoded) > definitionByteLimit
        then Left ["view definition is too large"]
        else Right ()
    case viSlug input of
        Nothing -> Right ()
        Just slug
            | T.null slug -> Left ["slug must not be empty"]
            | T.any (not . isSlugChar) slug -> Left ["slug may only use lower-case letters, digits, and hyphens"]
            | T.length slug > 48 -> Left ["slug is too long"]
            | otherwise -> Right ()
  where
    isSlugChar c = isAsciiLower c || isDigit c || c == '-'

viewDefinitionKind :: ViewDefinition -> ViewKind
viewDefinitionKind = \case
    GraphDefinition _ -> GraphKind
    LedgerDefinition _ -> LedgerKind

-- ---------------------------------------------------------------- JSON ------

-- | Encode a definition for the @definition_json@ column.
encodeViewDefinition :: ViewDefinition -> Text
encodeViewDefinition = TE.decodeUtf8 . LBS.toStrict . encode

decodeViewDefinition :: ViewKind -> Value -> Either Text ViewDefinition
decodeViewDefinition kind value = case kind of
    GraphKind -> GraphDefinition <$> decodeValue value
    LedgerKind -> LedgerDefinition <$> decodeValue value
  where
    decodeValue :: (FromJSON a) => Value -> Either Text a
    decodeValue raw = case fromJSON raw of
        Error message -> Left (T.pack message)
        Success parsed -> Right parsed

layoutPresetText :: LayoutPreset -> Text
layoutPresetText = \case
    Compact -> "compact"
    Standard -> "standard"
    Airy -> "airy"

parseLayoutPreset :: Text -> Maybe LayoutPreset
parseLayoutPreset raw = case T.toLower (T.strip raw) of
    "compact" -> Just Compact
    "standard" -> Just Standard
    "airy" -> Just Airy
    _ -> Nothing
