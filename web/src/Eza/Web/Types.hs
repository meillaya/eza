-- | lenient client-side DTOs for the planned M2-M4 endpoints.
--
-- The shared DTOs live in "Eza.Types" (and their aeson instances are reused
-- verbatim on the WASM client). The types here cover endpoints whose payloads
-- are not part of the shared contract yet; every decoder is deliberately
-- field-optional so the UI degrades gracefully while the server catches up.
module Eza.Web.Types
  ( ApiError (..)
  , DedupGroup (..)
  , ConsolGroup (..)
  , TagSuggestion (..)
  , Credential (..)
  , AccountInfo (..)
  , mkApiError
  , fieldInt
  , fieldText
  , fieldList
  , fieldObject
  ) where

import Data.Aeson
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.Types as AT
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Eza.Types (BookmarkSummary, TagStat)

-- | A failed API call.  @aeStatus@ is @Nothing@ for network/parse failures.
data ApiError = ApiError
  { aeStatus :: Maybe Int
  , aeMessage :: Text
  }
  deriving (Eq, Show)

-- | Build an 'ApiError' from the response status and any server message.
mkApiError :: Maybe Int -> Maybe Text -> ApiError
mkApiError status msg =
  ApiError status $ case msg of
    Just m | not (T.null (T.strip m)) -> m
    _ -> case status of
      Just 401 -> "Your session expired. Sign in again to continue."
      Just 403 -> "Not allowed (CSRF token missing or stale)."
      Just 404 -> "This endpoint is not available yet (planned route)."
      Just 409 -> "Conflict: the server refused the change."
      Just 413 -> "That file is too large."
      Just 429 -> "Rate limited: try again in a moment."
      Just n -> "Request failed (HTTP " <> T.pack (show n) <> ")."
      Nothing -> "Network error: the server did not answer."

-- | One duplicate-detection candidate group.
data DedupGroup = DedupGroup
  { dgKey :: Text
  , dgItems :: [BookmarkSummary]
  }
  deriving (Eq, Show)

instance FromJSON DedupGroup where
  parseJSON = withObject "DedupGroup" $ \o ->
    DedupGroup
      <$> o .:? "key" .!= ""
      <*> o .:? "items" .!= []

-- | One tag-consolidation candidate group.
data ConsolGroup = ConsolGroup
  { cgKind :: Text
  , cgTags :: [TagStat]
  , cgSuggested :: Text
  }
  deriving (Eq, Show)

instance FromJSON ConsolGroup where
  parseJSON = withObject "ConsolGroup" $ \o ->
    ConsolGroup
      <$> o .:? "kind" .!= "case"
      <*> o .:? "tags" .!= []
      <*> o .:? "suggested" .!= ""

-- | One AI/heuristic tag suggestion for a bookmark.
data TagSuggestion = TagSuggestion
  { tsgBookmark :: Maybe BookmarkSummary
  , tsgTags :: [Text]
  , tsgReason :: Text
  }
  deriving (Eq, Show)

instance FromJSON TagSuggestion where
  parseJSON = withObject "TagSuggestion" $ \o ->
    TagSuggestion
      <$> o .:? "bookmark"
      <*> o .:? "tags" .!= []
      <*> o .:? "reason" .!= ""

-- | A registered passkey (id is a base64url Text, never an Int).
data Credential = Credential
  { crId :: Text
  , crNickname :: Text
  , crCreatedAt :: Int
  , crLastUsedAt :: Maybe Int
  , crBackupEligible :: Bool
  }
  deriving (Eq, Show)

instance FromJSON Credential where
  parseJSON = withObject "Credential" $ \o ->
    Credential
      <$> o .:? "id" .!= ""
      <*> o .:? "nickname" .!= ""
      <*> o .:? "created_at" .!= 0
      <*> o .:? "last_used_at"
      <*> o .:? "backup_eligible" .!= False

-- | Account screen payload.
data AccountInfo = AccountInfo
  { aiCredentials :: [Credential]
  , aiRecoveryRemaining :: Int
  }
  deriving (Eq, Show)

instance FromJSON AccountInfo where
  parseJSON = withObject "AccountInfo" $ \o ->
    AccountInfo
      <$> o .:? "credentials" .!= []
      <*> o .:? "recovery_codes_remaining" .!= 0

-- | Read an integer field from a loose JSON object (0 when absent/mistyped).
fieldInt :: Text -> Value -> Int
fieldInt k v = fromMaybe 0 (AT.parseMaybe (withObject "" (\o -> o .:? K.fromText k .!= (0 :: Int))) v)

-- | Read a text field from a loose JSON object.
fieldText :: Text -> Value -> Text
fieldText k v = fromMaybe "" (AT.parseMaybe (withObject "" (\o -> o .:? K.fromText k .!= "")) v)

-- | Read a list field from a loose JSON object.
fieldList :: FromJSON a => Text -> Value -> [a]
fieldList k v = fromMaybe [] (AT.parseMaybe (withObject "" (\o -> o .:? K.fromText k .!= [])) v)

-- | Read an object/optional value field.
fieldObject :: FromJSON a => Text -> Value -> Maybe a
fieldObject k v = AT.parseMaybe (withObject "" (\o -> o .: K.fromText k)) v