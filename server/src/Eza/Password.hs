{-# LANGUAGE OverloadedStrings #-}

{- | Password hashing for the single-owner account.

Argon2id with a random 16-byte salt and a 32-byte tag, stored as a PHC-style
string: @$argon2id$v=19$m=65536,t=3,p=2$<salt>$<tag>@. The encoded string
carries its own parameters, so a stored hash keeps verifying after the
configured cost changes; 'needsRehash' says when to upgrade it.

The parameters live in 'Eza.Config' so a deployment can raise or lower the
cost. Salts come from 'Crypto.Random', and comparisons go through
'Data.ByteArray.constEq' so a wrong password and a wrong tag cost the same.
-}
module Eza.Password
    ( PasswordParams (..)
    , defaultPasswordParams
    , validateUsername
    , validatePassword
    , hashPassword
    , verifyPassword
    , dummyVerify
    , needsRehash
    , constantTimeEq
    ) where

import Crypto.Error (CryptoFailable (..))
import qualified Crypto.KDF.Argon2 as Argon2
import Crypto.Random (getRandomBytes)
import Data.Bits (xor, (.|.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import Data.Char (isAlphaNum)
import Data.List (foldl')
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word32, Word8)
import Text.Read (readMaybe)

-- | Argon2id cost parameters, all taken from the environment at startup.
data PasswordParams = PasswordParams
    { ppMemoryKiB :: Word32
    , ppIterations :: Word32
    , ppParallelism :: Word32
    }
    deriving (Show, Eq)

-- | OWASP's Argon2id baseline: 64 MiB, three passes, two lanes.
defaultPasswordParams :: PasswordParams
defaultPasswordParams = PasswordParams 65536 3 2

-- | A username is trimmed; letters, digits, and @._-@ are allowed.
validateUsername :: Text -> Either Text Text
validateUsername raw
    | T.null name = Left "username is required"
    | T.length name > 64 = Left "username must be at most 64 characters"
    | not (T.all allowed name) = Left "username may contain letters, digits, and . _ - @ + only"
    | otherwise = Right name
  where
    name = T.strip raw
    allowed c = isAlphaNum c || c `elem` ("._-@+" :: String)

-- | The only length limits. A password is otherwise taken as typed.
validatePassword :: Text -> Either Text ()
validatePassword password
    | T.length password < 10 = Left "password must be at least 10 characters"
    | T.length password > 128 = Left "password must be at most 128 characters"
    | otherwise = Right ()

-- | Hash a password with a fresh salt. The returned PHC string is the only
-- thing stored; the plaintext never reaches the database or a log.
hashPassword :: PasswordParams -> Text -> IO Text
hashPassword pp password = do
    salt <- (getRandomBytes 16 :: IO BS.ByteString)
    case Argon2.hash (optionsFrom pp) (TE.encodeUtf8 password) salt 32 :: CryptoFailable BS.ByteString of
        CryptoFailed err -> ioError (userError ("argon2: " <> show err))
        CryptoPassed tag -> pure (encodeHash pp salt tag)

{- | Verify a password against a stored PHC string. The parameters embedded in
the stored string are used, not the current configuration: a hash made with
the old cost still verifies, and 'needsRehash' asks for an upgrade separately.
-}
verifyPassword :: PasswordParams -> Text -> Text -> IO Bool
verifyPassword _pp stored password =
    case parseHash stored of
        Nothing -> pure False
        Just (mem, iter, par, salt, tag) ->
            case Argon2.hash (optionsFrom (PasswordParams mem iter par)) (TE.encodeUtf8 password) salt (BS.length tag) :: CryptoFailable BS.ByteString of
                CryptoFailed _ -> pure False
                CryptoPassed candidate -> pure (constantTimeEq candidate tag)

{- | Compare two byte strings without an early exit. Length is not treated as
secret: a fixed-length tag reveals nothing, and a wrong length must still
report inequality. The fold always walks the shorter string, and the length
check is combined with the byte comparison.
-}
constantTimeEq :: BS.ByteString -> BS.ByteString -> Bool
constantTimeEq left right =
    lengthEqual && foldl' (\acc (a, b) -> acc .|. xor a b) (0 :: Word8) (BS.zip left right) == 0
  where
    lengthEqual = BS.length left == BS.length right

{- | Do the same work as a real verification without a stored hash. Login uses
it when the account is missing so a nonexistent username and a wrong password
take comparable time.
-}
dummyVerify :: PasswordParams -> Text -> IO ()
dummyVerify pp password = do
    salt <- (getRandomBytes 16 :: IO BS.ByteString)
    let result = Argon2.hash (optionsFrom pp) (TE.encodeUtf8 password) salt 32 :: CryptoFailable BS.ByteString
    case result of
        CryptoFailed _ -> pure ()
        CryptoPassed tag -> tag `seq` pure ()

-- | True when a stored hash should be replaced with one using the current
-- parameters (including a malformed hash, which always needs replacing).
needsRehash :: PasswordParams -> Text -> Bool
needsRehash pp stored = case parseHash stored of
    Nothing -> True
    Just (mem, iter, par, _salt, _tag) ->
        (mem, iter, par) /= (ppMemoryKiB pp, ppIterations pp, ppParallelism pp)

-- ---------------------------------------------------------------------------
-- PHC encoding
-- ---------------------------------------------------------------------------

argonVersionText :: Text
argonVersionText = "v=19"

encodeHash :: PasswordParams -> BS.ByteString -> BS.ByteString -> Text
encodeHash pp salt tag =
    T.concat
        [ "$argon2id$"
        , argonVersionText
        , "$m="
        , T.pack (show (ppMemoryKiB pp))
        , ",t="
        , T.pack (show (ppIterations pp))
        , ",p="
        , T.pack (show (ppParallelism pp))
        , "$"
        , encodeB64 salt
        , "$"
        , encodeB64 tag
        ]

encodeB64 :: BS.ByteString -> Text
encodeB64 = TE.decodeUtf8 . B64.encode

decodeB64 :: Text -> Maybe BS.ByteString
decodeB64 raw = case B64.decode (TE.encodeUtf8 raw) of
    Left _ -> Nothing
    Right bytes -> Just bytes

{- | Parse the PHC string. Only Argon2id version 19 is accepted; anything else
is treated as unusable rather than guessed at.
-}
parseHash :: Text -> Maybe (Word32, Word32, Word32, BS.ByteString, BS.ByteString)
parseHash stored = case T.splitOn "$" stored of
    ["", "argon2id", version, params, salt, tag]
        | version == argonVersionText -> do
            (mem, iter, par) <- parseParams params
            saltBytes <- decodeB64 salt
            tagBytes <- decodeB64 tag
            pure (mem, iter, par, saltBytes, tagBytes)
    _ -> Nothing

parseParams :: Text -> Maybe (Word32, Word32, Word32)
parseParams raw = case T.splitOn "," raw of
    [m, t, p] -> (,,) <$> field "m=" m <*> field "t=" t <*> field "p=" p
    _ -> Nothing
  where
    field prefix value = case T.stripPrefix prefix value of
        Nothing -> Nothing
        Just number -> readMaybe (T.unpack number)

optionsFrom :: PasswordParams -> Argon2.Options
optionsFrom pp =
    Argon2.Options
        { Argon2.iterations = ppIterations pp
        , Argon2.memory = ppMemoryKiB pp
        , Argon2.parallelism = ppParallelism pp
        , Argon2.variant = Argon2.Argon2id
        , Argon2.version = Argon2.Version13
        }
