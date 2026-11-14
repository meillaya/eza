{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Deterministic save rules: when a saved URL, domain or title matches the
pattern, the listed tags are added and/or the bookmark is marked read. The
shape is shared by the server and the client.
-}
module Eza.Rule (
    Rule (..),
) where

import Data.Aeson (FromJSON (..), ToJSON (..), genericToJSON, withObject, (.!=), (.:), (.:?))
import Data.Text (Text)
import GHC.Generics (Generic)

import Eza.Json (jsonOptions)

data Rule = Rule
    { ruleId :: Int
    , ruleName :: Text
    , ruleEnabled :: Bool
    , ruleField :: Text
    , rulePattern :: Text
    , ruleAddTags :: [Text]
    , ruleMarkRead :: Bool
    , ruleCreatedAt :: Int
    }
    deriving (Show, Eq, Generic)

instance ToJSON Rule where
    toJSON = genericToJSON (jsonOptions "rule")

{- | Request bodies may omit the server-assigned fields (id, created_at) and
take the documented defaults for the rest; responses always carry every field.
-}
instance FromJSON Rule where
    parseJSON = withObject "Rule" $ \o ->
        Rule
            <$> o .:? "id" .!= 0
            <*> o .: "name"
            <*> o .:? "enabled" .!= True
            <*> o .:? "field" .!= "url"
            <*> o .: "pattern"
            <*> o .:? "add_tags" .!= []
            <*> o .:? "mark_read" .!= False
            <*> o .:? "created_at" .!= 0
