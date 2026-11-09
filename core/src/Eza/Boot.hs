{-# LANGUAGE OverloadedStrings #-}

{- | The boot document: one request that gives the client everything it needs
to paint the shell, the default ledger page and the saved views.

This lives outside "Eza.Types" because it includes 'View' values and
"Eza.View" already depends on "Eza.GraphLayout", which depends on
"Eza.Types"; putting it in "Eza.Types" would close an import cycle. The wire
shape is unchanged: the same object keys as before, plus @views@.
-}
module Eza.Boot (
    BootPayload (..),
) where

import Data.Aeson (FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

import Eza.Json (jsonOptions)
import Eza.Types (LibraryStats, SavedSearch, SearchPage, TagStat)
import Eza.View (View)

data BootPayload = BootPayload
    { bpVersion :: Text
    , bpOrigin :: Text
    , bpTags :: [TagStat]
    , bpSavedSearches :: [SavedSearch]
    , bpInitial :: SearchPage
    , bpStats :: LibraryStats
    , bpViews :: [View]
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON BootPayload where
    toJSON = genericToJSON (jsonOptions "bp")
instance FromJSON BootPayload where
    parseJSON = genericParseJSON (jsonOptions "bp")
