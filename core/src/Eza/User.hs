{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Account DTOs shared by the admin API, the CLI, and the Miso client.

The control database stores identity and role; a user's own database stores
the credentials and all library data. These types deliberately expose no
filesystem path and no credential material.
-}
module Eza.User (
    UserRole (..),
    userRoleText,
    parseUserRole,
    UserView (..),
    UserCreateInput (..),
    UserCreateResult (..),
) where

import Data.Aeson
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

data UserRole = RoleAdmin | RoleMember
    deriving (Show, Eq, Generic)

userRoleText :: UserRole -> Text
userRoleText = \case
    RoleAdmin -> "admin"
    RoleMember -> "member"

parseUserRole :: Text -> Maybe UserRole
parseUserRole raw = case T.toLower (T.strip raw) of
    "admin" -> Just RoleAdmin
    "member" -> Just RoleMember
    _ -> Nothing

instance ToJSON UserRole where
    toJSON = String . userRoleText

instance FromJSON UserRole where
    parseJSON = withText "UserRole" $ \raw ->
        maybe (fail "role must be admin or member") pure (parseUserRole raw)

-- | One account as the admin UI sees it.
data UserView = UserView
    { uvId :: Int
    , uvUsername :: Text
    , uvRole :: UserRole
    , uvCreatedAt :: Int
    , uvDisabledAt :: Maybe Int
    , uvLastLoginAt :: Maybe Int
    }
    deriving (Show, Eq, Generic)

instance ToJSON UserView where
    toJSON user =
        object
            [ "id" .= uvId user
            , "username" .= uvUsername user
            , "role" .= uvRole user
            , "created_at" .= uvCreatedAt user
            , "disabled_at" .= uvDisabledAt user
            , "last_login_at" .= uvLastLoginAt user
            ]

instance FromJSON UserView where
    parseJSON = withObject "UserView" $ \o ->
        UserView
            <$> o .:? "id" .!= 0
            <*> o .:? "username" .!= ""
            <*> o .:? "role" .!= RoleMember
            <*> o .:? "created_at" .!= 0
            <*> o .:? "disabled_at"
            <*> o .:? "last_login_at"

{- | The admin form. The password is validated and hashed on the server and
never logged or stored in the control database.
-}
data UserCreateInput = UserCreateInput
    { uciUsername :: Text
    , uciPassword :: Text
    , uciRole :: UserRole
    }
    deriving (Show, Eq, Generic)

instance ToJSON UserCreateInput where
    toJSON input =
        object
            [ "username" .= uciUsername input
            , "password" .= uciPassword input
            , "role" .= uciRole input
            ]

instance FromJSON UserCreateInput where
    parseJSON = withObject "UserCreateInput" $ \o ->
        UserCreateInput
            <$> o .: "username"
            <*> o .: "password"
            <*> o .:? "role" .!= RoleMember

-- | A created account plus the recovery codes that are shown once.
data UserCreateResult = UserCreateResult
    { ucrUser :: UserView
    , ucrRecoveryCodes :: [Text]
    }
    deriving (Show, Eq, Generic)

instance ToJSON UserCreateResult where
    toJSON result =
        object
            [ "user" .= ucrUser result
            , "recovery_codes" .= ucrRecoveryCodes result
            ]

instance FromJSON UserCreateResult where
    parseJSON = withObject "UserCreateResult" $ \o ->
        UserCreateResult
            <$> o .: "user"
            <*> o .:? "recovery_codes" .!= []
