{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Hashed bearer tokens for extensions and small clients.
module Eza.Tokens (
    Token (..),
    TokenView (..),
    createToken,
    listTokens,
    revokeToken,
    authenticateToken,
    tokenAllows,
) where

import Crypto.Hash (Digest, SHA256, hash)
import qualified Crypto.Random as Random
import Data.Aeson
import qualified Data.ByteString.Base64.URL as B64
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import GHC.Generics (Generic)

data Token = Token
    { tokenId :: Int
    , tokenName :: Text
    , tokenScopes :: [Text]
    }
    deriving (Show, Eq)

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
    toJSON tv =
        object
            [ "id" .= tvId tv
            , "name" .= tvName tv
            , "prefix" .= tvPrefix tv
            , "scopes" .= tvScopes tv
            , "created_at" .= tvCreatedAt tv
            , "last_used_at" .= tvLastUsedAt tv
            , "revoked_at" .= tvRevokedAt tv
            ]

epoch :: IO Int
epoch = floor <$> getPOSIXTime

hashToken :: Text -> Text
hashToken raw = T.pack (show (hash (TE.encodeUtf8 raw) :: Digest SHA256))

createToken :: Connection -> Text -> [Text] -> IO (Int, Text, TokenView)
createToken conn name scopes = do
    rawBytes <- Random.getRandomBytes 32
    let raw = "eza_pat_" <> TE.decodeUtf8 (B64.encodeUnpadded rawBytes)
        prefix = T.take 16 raw
        scopeText = T.intercalate "," scopes
    now <- epoch
    withImmediateTransaction conn $
        execute
            conn
            "INSERT INTO api_tokens (name, token_hash, token_prefix, scopes, created_at) VALUES (?,?,?,?,?)"
            (name, hashToken raw, prefix, scopeText, now)
    rows <- query conn "SELECT id, name, token_prefix, scopes, created_at FROM api_tokens WHERE token_hash = ?" (Only (hashToken raw)) :: IO [(Int, Text, Text, Text, Int)]
    let view = case rows of
            [(tid, tname, pfx, sc, created)] -> TokenView tid tname pfx (splitScopes sc) created Nothing Nothing
            _ -> TokenView 0 name prefix scopes now Nothing Nothing
    pure (tvId view, raw, view)

listTokens :: Connection -> IO [TokenView]
listTokens conn = do
    rows <-
        query_
            conn
            "SELECT id, name, token_prefix, scopes, created_at, last_used_at, revoked_at FROM api_tokens ORDER BY id DESC" ::
            IO [(Int, Text, Text, Text, Int, Maybe Int, Maybe Int)]
    pure [TokenView tid name prefix (splitScopes scopes) created lastUsed revoked | (tid, name, prefix, scopes, created, lastUsed, revoked) <- rows]

revokeToken :: Connection -> Int -> IO Bool
revokeToken conn tokenId = do
    now <- epoch
    withImmediateTransaction conn $ do
        execute conn "UPDATE api_tokens SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL" (now, tokenId)
        changed <- changes conn
        pure (changed > 0)

authenticateToken :: Connection -> Text -> IO (Maybe Token)
authenticateToken conn raw = do
    rows <-
        query
            conn
            "SELECT id, name, scopes FROM api_tokens WHERE token_hash = ? AND revoked_at IS NULL"
            (Only (hashToken raw)) ::
            IO [(Int, Text, Text)]
    case rows of
        [] -> pure Nothing
        (tid, name, scopes) : _ -> do
            now <- epoch
            withImmediateTransaction conn $
                execute conn "UPDATE api_tokens SET last_used_at = ? WHERE id = ?" (now, tid)
            pure (Just (Token tid name (splitScopes scopes)))

tokenAllows :: Token -> Text -> [Text] -> Bool
tokenAllows token method path =
    let scopes = map T.toLower (tokenScopes token)
        allowed values = any (\value -> value `elem` scopes) values
        captureWrite =
            method == "POST"
                && path
                    `elem` [ ["api", "v1", "quick-save"]
                           , ["api", "v1", "clip"]
                           , ["api", "v1", "clip", "preview"]
                           ]
        captureRead =
            method == "GET"
                && ( path == ["api", "v1", "whoami"]
                        || prefix ["api", "v1", "clip-templates"] path
                   )
     in if captureWrite
            then allowed ["capture", "write"]
            else
                if captureRead
                    then allowed ["capture", "write", "read"]
                    else
                        if method == "GET"
                            then allowed ["read", "write"]
                            else allowed ["write"]
  where
    prefix pre candidate = pre `isPrefixOf` candidate

splitScopes :: Text -> [Text]
splitScopes = filter (not . T.null) . map T.strip . T.splitOn ","
