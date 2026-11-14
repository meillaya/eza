{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Account-surface DTOs shared by the server and the Miso client.

The control database owns identity; these views carry no filesystem path and
no credential material. Wire field names are produced by the shared
'Eza.Json.jsonOptions' prefix rules, so the server and the client cannot drift
without a compile or test failure.
-}
module Eza.Account (
    Credential (..),
    SessionInfo (..),
    AccountInfo (..),
    TokenView (..),
) where

import Data.Aeson (FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

import Eza.Json (jsonOptions)
import Eza.User (UserRole)

-- | One registered passkey. The id is base64url text, never an Int.
data Credential = Credential
    { crId :: Text
    , crNickname :: Text
    , crCreatedAt :: Int
    , crLastUsedAt :: Maybe Int
    , crBackupEligible :: Bool
    }
    deriving (Show, Eq, Generic)

instance ToJSON Credential where
    toJSON = genericToJSON (jsonOptions "cr")
instance FromJSON Credential where
    parseJSON = genericParseJSON (jsonOptions "cr")

{- | One browser session as the account page sees it. Ids and hashes stay on
the server.
-}
data SessionInfo = SessionInfo
    { siCreatedAt :: Int
    , siLastSeenAt :: Maybe Int
    , siExpiresAt :: Int
    , siCurrent :: Bool
    }
    deriving (Show, Eq, Generic)

instance ToJSON SessionInfo where
    toJSON = genericToJSON (jsonOptions "si")
instance FromJSON SessionInfo where
    parseJSON = genericParseJSON (jsonOptions "si")

{- | The account screen payload: role and password state, passkeys, unused
recovery codes and sessions. All fields are server-assigned.
-}
data AccountInfo = AccountInfo
    { aiUsername :: Text
    , aiRole :: UserRole
    , aiHasPassword :: Bool
    , aiRequirePasskey :: Bool
    , aiAccountConfigured :: Bool
    , aiCredentials :: [Credential]
    , aiRecoveryCodesRemaining :: Int
    , aiSessions :: [SessionInfo]
    }
    deriving (Show, Eq, Generic)

instance ToJSON AccountInfo where
    toJSON = genericToJSON (jsonOptions "ai")
instance FromJSON AccountInfo where
    parseJSON = genericParseJSON (jsonOptions "ai")

{- | Bearer token metadata. The raw token is returned only on creation; this
view carries the prefix the server exposes for identification.
-}
data TokenView = TokenView
    { tvId :: Int
    , tvName :: Text
    , tvPrefix :: Text
    , tvScopes :: [Text]
    , tvCreatedAt :: Int
    , tvLastUsedAt :: Maybe Int
    , tvRevokedAt :: Maybe Int
    }
    deriving (Show, Eq, Generic)

instance ToJSON TokenView where
    toJSON = genericToJSON (jsonOptions "tv")
instance FromJSON TokenView where
    parseJSON = genericParseJSON (jsonOptions "tv")
