{-# LANGUAGE OverloadedStrings #-}

{- | The one HTTP error body shape.

The wire form is exactly what the v1 API has always returned:

@
{"error":{"code":"not_found","message":"bookmark not found"}}
@

'pStatus' is response metadata and is not encoded; the client takes the HTTP
status from the response. Keeping this type in core means the server, the
client, the browser extension and any generated docs agree on the shape.
-}
module Eza.Problem (
    Problem (..),
    problemBody,
) where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), object, withObject, (.:), (.=))
import Data.Text (Text)

data Problem = Problem
    { pStatus :: Int
    -- ^ HTTP status; not part of the wire body.
    , pCode :: Text
    , pMessage :: Text
    }
    deriving (Eq, Show)

instance ToJSON Problem where
    toJSON problem =
        object
            [ "error"
                .= object
                    [ "code" .= pCode problem
                    , "message" .= pMessage problem
                    ]
            ]

instance FromJSON Problem where
    parseJSON = withObject "Problem" $ \outer -> do
        inner <- outer .: "error"
        Problem 0 <$> (inner .: "code") <*> (inner .: "message")

-- | The wire body for a problem, with the status removed.
problemBody :: Problem -> Value
problemBody problem = case toJSON problem of
    Object objectValue -> Object objectValue
    other -> other
