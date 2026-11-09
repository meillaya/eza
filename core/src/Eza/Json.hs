-- | JSON options shared by the server and the Miso client.
module Eza.Json (
    jsonOptions,
    snakeOptions,
) where

import Data.Aeson (Options (..), defaultOptions)
import Data.Char (isUpper, toLower)

{- | Aeson options that turn camelCase record fields into snake_case keys and
strip the two-character record prefix used by the shared DTOs.

>>> fieldLabelModifier (jsonOptions "bs") "bsCreatedAt"
"created_at"
-}
jsonOptions :: String -> Options
jsonOptions prefix =
    defaultOptions
        { fieldLabelModifier = camelTo2 '_' . drop (length prefix)
        , omitNothingFields = True
        }

-- | snake_case options without a prefix (for simple records).
snakeOptions :: Options
snakeOptions = defaultOptions{fieldLabelModifier = camelTo2 '_', omitNothingFields = True}

{- | A small local copy of aeson's 'camelTo2' so we do not depend on the
non-public helper module.
-}
camelTo2 :: Char -> String -> String
camelTo2 sep = dropWhile (== sep) . concatMap one
  where
    one ch
        | isUpper ch = [sep, toLower ch]
        | otherwise = [ch]
