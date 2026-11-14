{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- | AI-tagging surface shared by the server and the client.

Suggestions are explicit, never automatic: the server only proposes tags when
the user asks for them. 'AiStatus' reports the provider/model and whether the
HTTP call path is configured; it carries no key material.
-}
module Eza.Ai (
    AiStatus (..),
    TagSuggestion (..),
) where

import Data.Aeson (FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

import Eza.Json (jsonOptions)
import Eza.Types (BookmarkSummary)

-- | Provider/model status for the AI-tags page.
data AiStatus = AiStatus
    { asProvider :: Text
    , asModel :: Text
    , asConfigured :: Bool
    }
    deriving (Show, Eq, Generic)

instance ToJSON AiStatus where
    toJSON = genericToJSON (jsonOptions "as")
instance FromJSON AiStatus where
    parseJSON = genericParseJSON (jsonOptions "as")

{- | One suggestion for a bookmark. The bookmark summary is always present;
the old client type made it optional only because the decoder was lenient.
-}
data TagSuggestion = TagSuggestion
    { tsgBookmark :: BookmarkSummary
    , tsgTags :: [Text]
    , tsgReason :: Text
    }
    deriving (Show, Eq, Generic)

instance ToJSON TagSuggestion where
    toJSON = genericToJSON (jsonOptions "tsg")
instance FromJSON TagSuggestion where
    parseJSON = genericParseJSON (jsonOptions "tsg")
