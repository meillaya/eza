{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Tag-consolidation candidates shared by the server and the client.

A group is one cleanup suggestion: the tags that look like the same tag (case
variants, near-duplicates, junk names) and the member the server suggests as
the merge target.
-}
module Eza.Consolidation (
    ConsolidationGroup (..),
    ConsolidationReport (..),
) where

import Data.Aeson (FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

import Eza.Json (jsonOptions)
import Eza.Types (TagStat)

data ConsolidationGroup = ConsolidationGroup
    { cgKind :: Text
    , cgTags :: [TagStat]
    , cgSuggested :: Text
    }
    deriving (Show, Eq, Generic)

instance ToJSON ConsolidationGroup where
    toJSON = genericToJSON (jsonOptions "cg")
instance FromJSON ConsolidationGroup where
    parseJSON = genericParseJSON (jsonOptions "cg")

-- | The wire wrapper: @{"groups":[...]}@.
data ConsolidationReport = ConsolidationReport
    { crGroups :: [ConsolidationGroup]
    }
    deriving (Show, Eq, Generic)

instance ToJSON ConsolidationReport where
    toJSON = genericToJSON (jsonOptions "cr")
instance FromJSON ConsolidationReport where
    parseJSON = genericParseJSON (jsonOptions "cr")
