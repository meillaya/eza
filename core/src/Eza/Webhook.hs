{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Declarative webhook subscriptions and the event envelope.

Webhooks are the external-extension surface: the server records events in the
same transaction as the write, a per-library worker delivers them with HMAC
signing and retries, and a disabled subscription has no effect. The types here
are shared by the server, the client, and the JSON Schema contract.

Response decoding is strict (a missing or renamed field is a parse failure, per
the client-decode rule in @AGENTS.md@); the create/update payload 'WebhookInput'
keeps the documented input defaults.
-}
module Eza.Webhook (
    -- * Events
    EventType (..),
    eventTypeText,
    parseEventType,
    allEventTypes,
    EventEnvelope (..),

    -- * Subscriptions
    Webhook (..),
    WebhookInput (..),
    DeliveryView (..),
    maxWebhooks,
    maxWebhookName,
    maxWebhookUrl,
    validateWebhookInput,
) where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

import Eza.Url (isHttpUrl)

-- ----------------------------------------------------------------- events ---

data EventType
    = BookmarkCreated
    | BookmarkUpdated
    | BookmarkDeleted
    | ClipCreated
    deriving (Show, Eq, Enum, Bounded, Generic)

eventTypeText :: EventType -> Text
eventTypeText = \case
    BookmarkCreated -> "bookmark.created"
    BookmarkUpdated -> "bookmark.updated"
    BookmarkDeleted -> "bookmark.deleted"
    ClipCreated -> "clip.created"

parseEventType :: Text -> Maybe EventType
parseEventType raw = case T.toLower (T.strip raw) of
    "bookmark.created" -> Just BookmarkCreated
    "bookmark.updated" -> Just BookmarkUpdated
    "bookmark.deleted" -> Just BookmarkDeleted
    "clip.created" -> Just ClipCreated
    _ -> Nothing

allEventTypes :: [EventType]
allEventTypes = [minBound .. maxBound]

{- | The signed delivery body. @occurred_at@ is POSIX seconds; the client can
render it as a UTC day without trusting the sender's clock format.
-}
data EventEnvelope = EventEnvelope
    { eeId :: Text
    , eeType :: EventType
    , eeOccurredAt :: Int
    , eeData :: Value
    }
    deriving (Show, Eq, Generic)

instance ToJSON EventEnvelope where
    toJSON envelope =
        object
            [ "id" .= eeId envelope
            , "type" .= eventTypeText (eeType envelope)
            , "occurred_at" .= eeOccurredAt envelope
            , "data" .= eeData envelope
            ]

instance FromJSON EventEnvelope where
    parseJSON = withObject "EventEnvelope" $ \o -> do
        rawType <- o .: "type" :: Parser Text
        eventType <- maybe (fail "unknown event type") pure (parseEventType rawType)
        occurredAt <- o .:? "occurred_at" .!= 0
        EventEnvelope
            <$> (o .:? "id" .!= "")
            <*> pure eventType
            <*> pure occurredAt
            <*> (o .:? "data" .!= object [])

-- ------------------------------------------------------------ subscriptions ---

maxWebhooks :: Int
maxWebhooks = 16

maxWebhookName :: Int
maxWebhookName = 80

maxWebhookUrl :: Int
maxWebhookUrl = 2048

{- | One stored subscription. The secret is never part of the list payload;
the reveal-once value belongs to the create response only. The response codec is
strict: every field on the wire is required, including the nullable last-*
fields (which the server writes as JSON null when unknown).
-}
data Webhook = Webhook
    { whId :: Int
    , whName :: Text
    , whUrl :: Text
    , whEvents :: [EventType]
    , whEnabled :: Bool
    , whCreatedAt :: Int
    , whLastStatus :: Maybe Int
    , whLastAttemptAt :: Maybe Int
    , whLastError :: Text
    , whFailStreak :: Int
    }
    deriving (Show, Eq, Generic)

instance ToJSON Webhook where
    toJSON webhook =
        object
            [ "id" .= whId webhook
            , "name" .= whName webhook
            , "url" .= whUrl webhook
            , "events" .= map eventTypeText (whEvents webhook)
            , "enabled" .= whEnabled webhook
            , "created_at" .= whCreatedAt webhook
            , "last_status" .= whLastStatus webhook
            , "last_attempt_at" .= whLastAttemptAt webhook
            , "last_error" .= whLastError webhook
            , "fail_streak" .= whFailStreak webhook
            ]

instance FromJSON Webhook where
    parseJSON = withObject "Webhook" $ \o -> do
        rawEvents <- o .: "events"
        events <- traverse parseEvent rawEvents
        Webhook
            <$> o .: "id"
            <*> o .: "name"
            <*> o .: "url"
            <*> pure events
            <*> o .: "enabled"
            <*> o .: "created_at"
            <*> o .: "last_status"
            <*> o .: "last_attempt_at"
            <*> o .: "last_error"
            <*> o .: "fail_streak"
      where
        parseEvent raw = maybe (fail "unknown webhook event") pure (parseEventType raw)

{- | Create/update payload. Decoding is intentionally lenient for the documented
input defaults: an omitted @enabled@ means true and omitted @events@ means the
empty list (the server then validates the required name/url and the
at-least-one-event rule). Responses always use the strict 'Webhook' codec.
-}
data WebhookInput = WebhookInput
    { wiName :: Text
    , wiUrl :: Text
    , wiEvents :: [EventType]
    , wiEnabled :: Bool
    }
    deriving (Show, Eq, Generic)

instance ToJSON WebhookInput where
    toJSON input =
        object
            [ "name" .= wiName input
            , "url" .= wiUrl input
            , "events" .= map eventTypeText (wiEvents input)
            , "enabled" .= wiEnabled input
            ]

instance FromJSON WebhookInput where
    parseJSON = withObject "WebhookInput" $ \o -> do
        rawEvents <- o .:? "events" .!= ([] :: [Text])
        events <- traverse parseEvent rawEvents
        WebhookInput
            <$> (o .:? "name" .!= "")
            <*> (o .:? "url" .!= "")
            <*> pure events
            <*> (o .:? "enabled" .!= True)
      where
        parseEvent raw = maybe (fail "unknown webhook event") pure (parseEventType raw)

{- | One recent delivery shown in the account UI. The response codec is strict:
every field is required, so a server rename fails the client parse instead of
showing an empty delivery row.
-}
data DeliveryView = DeliveryView
    { dvId :: Int
    , dvEvent :: EventType
    , dvState :: Text
    , dvAttempts :: Int
    , dvLastError :: Text
    , dvCreatedAt :: Int
    }
    deriving (Show, Eq, Generic)

instance ToJSON DeliveryView where
    toJSON delivery =
        object
            [ "id" .= dvId delivery
            , "event" .= eventTypeText (dvEvent delivery)
            , "state" .= dvState delivery
            , "attempts" .= dvAttempts delivery
            , "last_error" .= dvLastError delivery
            , "created_at" .= dvCreatedAt delivery
            ]

instance FromJSON DeliveryView where
    parseJSON = withObject "DeliveryView" $ \o -> do
        rawEvent <- o .: "event" :: Parser Text
        eventType <- maybe (fail "unknown delivery event") pure (parseEventType rawEvent)
        DeliveryView
            <$> o .: "id"
            <*> pure eventType
            <*> o .: "state"
            <*> o .: "attempts"
            <*> o .: "last_error"
            <*> o .: "created_at"

-- ---------------------------------------------------------------- validation ---

validateWebhookInput :: WebhookInput -> Either [Text] ()
validateWebhookInput input = do
    let name = T.strip (wiName input)
        url = T.strip (wiUrl input)
        events = wiEvents input
    if T.null name then Left ["name is required"] else Right ()
    if T.length name > maxWebhookName then Left ["name is too long"] else Right ()
    if T.null url then Left ["url is required"] else Right ()
    if T.length url > maxWebhookUrl then Left ["url is too long"] else Right ()
    if isHttpUrl url then Right () else Left ["url must be an http(s) URL"]
    if null events then Left ["at least one event is required"] else Right ()
    if length events > length allEventTypes then Left ["too many events"] else Right ()
    if all (`elem` allEventTypes) events then Right () else Left ["unknown event type"]
