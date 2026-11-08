{-# LANGUAGE OverloadedStrings #-}

-- | Optional bridge to the Node/Defuddle extraction sidecar.
--
-- The sidecar is a small JSON-lines process (see @sidecar/README.md@). The
-- server keeps the Haskell extractor as the default and calls the sidecar only
-- when @EZA_DEFUDDLE_CMD@ is configured, so a bare binary still works.
module Eza.Sidecar
  ( sidecarExtract
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

import Eza.Extract (Extracted (..))

data SidecarResult = SidecarResult
  { srTitle :: Text
  , srAuthor :: Text
  , srPublished :: Text
  , srSite :: Text
  , srDescription :: Text
  , srLanguage :: Text
  , srImage :: Text
  , srCanonical :: Text
  , srContentText :: Text
  , srContentMarkdown :: Text
  }
  deriving (Show, Eq)

instance FromJSON SidecarResult where
  parseJSON = withObject "sidecar" $ \o ->
    SidecarResult
      <$> o .:? "title" .!= ""
      <*> o .:? "author" .!= ""
      <*> o .:? "published" .!= ""
      <*> o .:? "site" .!= ""
      <*> o .:? "description" .!= ""
      <*> o .:? "language" .!= ""
      <*> o .:? "image" .!= ""
      <*> o .:? "canonical_url" .!= ""
      <*> o .:? "content_text" .!= ""
      <*> o .:? "content_markdown" .!= ""

-- | Run one extraction. The command is executed through @sh -c@ and receives
-- one JSON request line on stdin. Any failure (missing command, timeout,
-- malformed response, empty body) returns @Left@ so callers can fall back to
-- the in-process extractor.
sidecarExtract :: Text -> Text -> Text -> IO (Either Text Extracted)
sidecarExtract command url html = do
    let request = encode (object ["id" .= (1 :: Int), "url" .= url, "html" .= html])
    outcome <-
        timeout 20000
            ( try (readProcessWithExitCode "sh" ["-c", T.unpack command] (LBS8.unpack request <> "\n"))
                :: IO (Either SomeException (ExitCode, String, String))
            )
    pure $ case outcome of
        Nothing -> Left "sidecar timed out"
        Just (Left err) -> Left (T.pack (show err))
        Just (Right (ExitFailure code, _, _)) -> Left ("sidecar exited with " <> T.pack (show code))
        Just (Right (ExitSuccess, stdout, _)) -> parseOutput stdout

parseOutput :: String -> Either Text Extracted
parseOutput stdout =
    let line = firstNonEmpty (lines stdout)
     in case eitherDecode (LBS8.pack line) :: Either String Value of
            Left err -> Left ("sidecar response: " <> T.pack err)
            Right value -> case fromJSON value of
                Error err -> Left ("sidecar response: " <> T.pack err)
                Success result
                    | T.null (T.strip (srContentText result)) -> Left "sidecar returned no text"
                    | otherwise -> Right (toExtracted result)
  where
    firstNonEmpty [] = ""
    firstNonEmpty (line : rest)
        | T.null (T.strip (T.pack line)) = firstNonEmpty rest
        | otherwise = line
    toExtracted result =
        Extracted
            { exTitle = srTitle result
            , exDescription = srDescription result
            , exText = srContentText result
            , exAuthor = srAuthor result
            , exSitename = srSite result
            , exPublished = parsePublished (srPublished result)
            , exLanguage = srLanguage result
            , exImage = srImage result
            , exCanonical = srCanonical result
            }
    parsePublished raw =
        let value = T.strip raw
            parsed =
                parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Z" (T.unpack value)
                    `orElse` parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (T.unpack value)
                    `orElse` parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S" (T.unpack value)
                    `orElse` parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack value)
         in if T.null value then Nothing else fmap (floor . utcTimeToPOSIXSeconds) parsed
    orElse (Just value) _ = Just value
    orElse Nothing fallback = fallback
