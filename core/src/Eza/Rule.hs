{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Deterministic save rules: when a saved URL, domain or title matches the
pattern, the listed tags are added and/or the bookmark is marked read. The
shape is shared by the server and the client.

A response @Rule@ is decoded strictly: every field is required, so a server
rename is a visible parse failure instead of a defaulted field (the
client-decode rule in @AGENTS.md@). The create/update body is the separate
'RuleInput' type, whose decoder keeps the documented input defaults
(@enabled@ true, @field@ @url@, @add_tags@ empty, @mark_read@ false); a server
turns it into a 'Rule' with 'ruleInputToRule'.
-}
module Eza.Rule (
    Rule (..),
    RuleInput (..),
    ruleInputToRule,
) where

import Data.Aeson (FromJSON (..), ToJSON (..), genericToJSON, object, withObject, (.!=), (.:), (.:?), (.=))
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

{- | The response decoder is strict: the server always writes every field, so a
missing or renamed one fails the parse (never a default).
-}
instance FromJSON Rule where
    parseJSON = withObject "Rule" $ \o ->
        Rule
            <$> o .: "id"
            <*> o .: "name"
            <*> o .: "enabled"
            <*> o .: "field"
            <*> o .: "pattern"
            <*> o .: "add_tags"
            <*> o .: "mark_read"
            <*> o .: "created_at"

{- | The create/update body: no server-assigned fields, and the documented
defaults apply when a field is omitted (@enabled@ true, @field@ @url@,
@add_tags@ empty, @mark_read@ false; @name@ and @pattern@ stay required).
-}
data RuleInput = RuleInput
    { riName :: Text
    , riEnabled :: Bool
    , riField :: Text
    , riPattern :: Text
    , riAddTags :: [Text]
    , riMarkRead :: Bool
    }
    deriving (Show, Eq)

instance ToJSON RuleInput where
    toJSON input =
        object
            [ "name" .= riName input
            , "enabled" .= riEnabled input
            , "field" .= riField input
            , "pattern" .= riPattern input
            , "add_tags" .= riAddTags input
            , "mark_read" .= riMarkRead input
            ]

instance FromJSON RuleInput where
    parseJSON = withObject "RuleInput" $ \o ->
        RuleInput
            <$> o .: "name"
            <*> o .:? "enabled" .!= True
            <*> o .:? "field" .!= "url"
            <*> o .: "pattern"
            <*> o .:? "add_tags" .!= []
            <*> o .:? "mark_read" .!= False

{- | Fill a server-shaped 'Rule' from a create/update body. The server assigns
@id@ and @created_at@ itself, so the defaults here are placeholders that no
write path stores.
-}
ruleInputToRule :: RuleInput -> Rule
ruleInputToRule input =
    Rule
        { ruleId = 0
        , ruleName = riName input
        , ruleEnabled = riEnabled input
        , ruleField = riField input
        , rulePattern = riPattern input
        , ruleAddTags = riAddTags input
        , ruleMarkRead = riMarkRead input
        , ruleCreatedAt = 0
        }
