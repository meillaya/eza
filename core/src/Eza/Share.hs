{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- | A public share link as the account screen sees it. The raw token is only
known at creation time; this view carries the short prefix for identification
afterwards.
-}
module Eza.Share (
    ShareView (..),
) where

import Data.Aeson (FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

import Eza.Json (jsonOptions)

data ShareView = ShareView
    { svId :: Int
    , svPrefix :: Text
    , svScope :: Text
    , svTargetId :: Int
    , svIncludeNote :: Bool
    , svCreatedAt :: Int
    , svExpiresAt :: Int
    , svRevokedAt :: Maybe Int
    , svLastAccessedAt :: Maybe Int
    }
    deriving (Show, Eq, Generic)

instance ToJSON ShareView where
    toJSON = genericToJSON (jsonOptions "sv")
instance FromJSON ShareView where
    parseJSON = genericParseJSON (jsonOptions "sv")
