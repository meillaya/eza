{-# LANGUAGE OverloadedStrings #-}

{- | User-bound token prefixes.

Every session cookie, share token, and API token carries the owning account id
in its prefix: @u<id>_<random>@ for session/share tokens and
@eza_pat_u<id>_<random>@ for API tokens. The server uses the prefix to pick the
user database before it hashes and validates the full token. A rewritten
prefix therefore fails the hash check, and the unprefixed legacy format is
accepted only through the explicit single-user fallback.

The functions here are pure and total so the parser can be shared by the
server, the CLI, and the tests.
-}
module Eza.TokenPrefix (
    UserId,
    sessionPrefix,
    apiTokenPrefix,
    sharePrefix,
    parseSessionUserId,
    parseShareUserId,
    parseApiTokenUserId,
    splitUserPrefix,
    withUserPrefix,
) where

import Data.Char (isDigit)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

{- | The control database's account id. Kept as a plain 'Int' so the core
module does not depend on server types.
-}
type UserId = Int

sessionPrefix :: Text
sessionPrefix = "u"

apiTokenPrefix :: Text
apiTokenPrefix = "eza_pat_u"

sharePrefix :: Text
sharePrefix = "u"

-- | Prepend the account id to a raw random token.
withUserPrefix :: Text -> UserId -> Text -> Text
withUserPrefix marker userId raw = marker <> T.pack (show userId) <> "_" <> raw

-- | Parse a session cookie token such as @u12_abC…@.
parseSessionUserId :: Text -> Maybe UserId
parseSessionUserId raw = fst <$> splitUserPrefix raw

-- | Parse a share token; the wire format is the same as a session token.
parseShareUserId :: Text -> Maybe UserId
parseShareUserId = parseSessionUserId

-- | Parse an API token such as @eza_pat_u12_abC…@.
parseApiTokenUserId :: Text -> Maybe UserId
parseApiTokenUserId raw = fst <$> (parseUserIdAndRest =<< T.stripPrefix apiTokenPrefix raw)

{- | Split @u<id>_<random>@ into the id and the remainder (including the raw
random material). The marker is required, digits only, and the random part
must be non-empty; otherwise legacy handling applies.
-}
splitUserPrefix :: Text -> Maybe (UserId, Text)
splitUserPrefix raw = parseUserIdAndRest =<< T.stripPrefix sessionPrefix raw

parseUserIdAndRest :: Text -> Maybe (UserId, Text)
parseUserIdAndRest rest =
    let (digits, afterDigits) = T.span isDigit rest
        remainder = fromMaybe "" (T.stripPrefix "_" afterDigits)
     in if T.null digits || T.null remainder
            then Nothing
            else case readInt (T.unpack digits) of
                Just userId -> Just (userId, remainder)
                Nothing -> Nothing

readInt :: String -> Maybe Int
readInt [] = Nothing
readInt digits
    | all isDigit digits = Just (foldl (\acc digit -> acc * 10 + fromEnum digit - fromEnum '0') 0 digits)
    | otherwise = Nothing
