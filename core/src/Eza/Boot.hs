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
    wireVersion,
) where

import Data.Aeson (FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

import Eza.Json (jsonOptions)
import Eza.Types (LibraryStats, SavedSearch, SearchPage, TagStat)
import Eza.View (View)

{- | Wire-contract version for the boot document and the client that reads it.
Bump when a client built against the old shape could silently misread the new
one; the client refuses to paint on a mismatch instead of showing defaults.
-}
wireVersion :: Int
wireVersion = 1

data BootPayload = BootPayload
    { bpWireVersion :: Int
    , bpVersion :: Text
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
