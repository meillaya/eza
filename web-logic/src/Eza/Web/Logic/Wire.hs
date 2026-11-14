{-# LANGUAGE OverloadedStrings #-}

{- | Client-local wire records that the shell still consumes directly: the
ledger request parameters, the webhook test answer and the import summary.

They live in the native package because the client model and the action
vocabulary reference them; "Eza.Web.Api" re-exports them for its transport
functions.
-}
module Eza.Web.Logic.Wire (
    ListParams (..),
    defaultListParams,
    WebhookTest (..),
    ImportResponse (..),
) where

import Data.Aeson (FromJSON (..), Result (..), fromJSON, withObject, (.:), (.:?))
import Data.Text (Text)

import Eza.Types (ImportReport)

-- ------------------------------------------------------------- list query ---

data ListParams = ListParams
    { lpQ :: Text
    , lpTags :: [Text]
    , lpSort :: Text
    , lpUnreadOnly :: Bool
    , lpOffset :: Int
    , lpLimit :: Int
    }
    deriving (Eq, Show)

defaultListParams :: ListParams
defaultListParams =
    ListParams
        { lpQ = ""
        , lpTags = []
        , lpSort = "created"
        , lpUnreadOnly = False
        , lpOffset = 0
        , lpLimit = 60
        }

-- --------------------------------------------------------------- responses ---

data WebhookTest = WebhookTest
    { wtOk :: Bool
    , wtStatus :: Maybe Int
    , wtError :: Text
    }
    deriving (Eq, Show)

instance FromJSON WebhookTest where
    parseJSON = withObject "webhook test" $ \o ->
        WebhookTest
            <$> o .: "ok"
            <*> o .:? "status"
            <*> o .: "error"

data ImportResponse = ImportResponse
    { imrInserted :: Int
    , imrFound :: Int
    , imrExisting :: Int
    , imrReport :: Maybe ImportReport
    }
    deriving (Eq, Show)

instance FromJSON ImportResponse where
    parseJSON value = do
        (inserted, found, existing) <-
            withObject "import response" (\o -> (,,) <$> o .: "inserted" <*> o .: "found" <*> o .: "existing") value
        pure
            ImportResponse
                { imrInserted = inserted
                , imrFound = found
                , imrExisting = existing
                , imrReport = case fromJSON value :: Result ImportReport of
                    Success report -> Just report
                    Error _ -> Nothing
                }
