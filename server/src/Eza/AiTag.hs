{-# LANGUAGE OverloadedStrings #-}
module Eza.AiTag
  ( Suggestion (..)
  , aiSuggestions
  ) where

import Data.Aeson
import Data.Aeson.Types (Parser, parseMaybe)
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Set as Set
import Database.SQLite.Simple
import GHC.Generics (Generic)
import Network.HTTP.Client
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Header (hContentType)
import System.Environment (lookupEnv)

import Eza.Bookmarks (allTags, bookmarksByIds)
import Eza.Types (BookmarkSummary (..), TagStat (..))

data Suggestion = Suggestion
  { sugBookmark :: BookmarkSummary
  , sugTags :: [Text]
  , sugReason :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON Suggestion where
  toJSON s =
    object
      [ "bookmark" .= sugBookmark s
      , "tags" .= sugTags s
      , "reason" .= sugReason s
      ]

stopwords :: Set.Set Text
stopwords =
  Set.fromList
    [ "imported", "tabs", "archive", "imported sessions", "bookmarks"
    , "bookmarks bar", "favorites", "links", "misc", "saved", "stuff", "temp"
    , "new folder", "useful", "important", "interesting", "various", "general"
    ]

aiSuggestions :: Connection -> Text -> Int -> IO (Either Text [Suggestion])
aiSuggestions conn tagName sampleSize = do
  provider <- fromMaybe "anthropic" <$> lookupEnv "EZA_AI_PROVIDER"
  rawKey <-
    case provider of
      "ollama" -> pure Nothing
      "openai" -> lookupEnv "OPENAI_API_KEY"
      "openai-compatible" -> lookupEnv "OPENAI_API_KEY"
      _ -> lookupEnv "ANTHROPIC_API_KEY"
  let key = case rawKey of
        Just k | not (null k) -> Just k
        _ -> Nothing
  vocab <- map tsName . take 80 <$> allTags conn
  rows <-
    query
      conn
      "SELECT b.id FROM bookmarks b JOIN bookmark_tags bt ON bt.bookmark_id=b.id JOIN tags t ON t.id=bt.tag_id WHERE t.name = ? ORDER BY b.created_at DESC LIMIT ?"
      (T.toLower tagName, max 1 (min 30 sampleSize)) :: IO [Only Int]
  let ids = [i | Only i <- rows]
  if null ids
    then pure (Left "no bookmarks with that tag")
    else if provider /= "ollama" && key == Nothing
      then pure (Left "AI key is not configured (set ANTHROPIC_API_KEY or OPENAI_API_KEY, or use EZA_AI_PROVIDER=ollama)")
      else do
        let apiKey = fromMaybe "" key
        summaries <- bookmarksByIds conn ids
        let listing =
              T.intercalate "\n"
                [ "- " <> bsTitle s <> " — " <> bsUrl s
                | s <- summaries
                ]
            prompt =
              "Suggest 5-10 short topic tags for these bookmarks. "
                <> "Only use tags from this existing vocabulary when possible: "
                <> T.intercalate ", " vocab
                <> ". Return only a JSON array of lowercase strings.\n\n" <> listing
        result <- callProvider provider apiKey prompt
        case result of
          Left e -> pure (Left e)
          Right raw -> do
            let tags =
                  [ T.toLower t
                  | t <- parseTagArray raw
                  , let l = T.toLower (T.strip t)
                  , not (T.null l)
                  , not (Set.member l stopwords)
                  , l `elem` map T.toLower vocab
                  ]
            if null tags
              then pure (Right [])
              else pure (Right [Suggestion s (take 8 tags) "Suggested for this tag bucket" | s <- summaries])

callProvider :: String -> String -> Text -> IO (Either Text Text)
callProvider provider apiKey prompt = do
  manager <- newTlsManager
  result <- tryJson manager (T.pack provider) (T.pack apiKey) prompt
  pure result

tryJson :: Manager -> Text -> Text -> Text -> IO (Either Text Text)
tryJson manager provider apiKey prompt = do
  if provider == "ollama"
    then do
      base <- fromMaybe "http://127.0.0.1:11434" <$> lookupEnv "EZA_OLLAMA_BASE_URL"
      model <- fromMaybe "llama3.2" <$> lookupEnv "EZA_AI_MODEL"
      req0 <- parseRequest (base <> "/api/chat")
      let body =
            object
              [ "model" .= model
              , "stream" .= False
              , "messages" .= [object ["role" .= ("user" :: Text), "content" .= prompt]]
              ]
      resp <- httpLbs req0 {method = "POST", requestHeaders = [(hContentType, "application/json")], requestBody = RequestBodyLBS (encode body)} manager
      pure (extractOllama (responseBody resp))
    else if provider == "openai" || provider == "openai-compatible"
    then do
      base <- fromMaybe "https://api.openai.com/v1" <$> lookupEnv "EZA_OPENAI_BASE_URL"
      req0 <- parseRequest (base <> "/chat/completions")
      let body =
            object
              [ "model" .= ("gpt-4o-mini" :: Text)
              , "messages" .= [object ["role" .= ("user" :: Text), "content" .= prompt]]
              , "max_tokens" .= (256 :: Int)
              ]
      resp <- httpLbs req0 {method = "POST", requestHeaders = [(hContentType, "application/json"), ("Authorization", TE.encodeUtf8 ("Bearer " <> apiKey))], requestBody = RequestBodyLBS (encode body)} manager
      pure (extractOpenAI (responseBody resp))
    else do
      req0 <- parseRequest "https://api.anthropic.com/v1/messages"
      let body =
            object
              [ "model" .= ("claude-haiku-4-5" :: Text)
              , "max_tokens" .= (256 :: Int)
              , "messages" .= [object ["role" .= ("user" :: Text), "content" .= prompt]]
              ]
      resp <- httpLbs req0 {method = "POST", requestHeaders = [(hContentType, "application/json"), ("x-api-key", TE.encodeUtf8 apiKey), ("anthropic-version", "2023-06-01")], requestBody = RequestBodyLBS (encode body)} manager
      pure (extractAnthropic (responseBody resp))

extractOllama :: LBS.ByteString -> Either Text Text
extractOllama body =
  case decode body :: Maybe Value of
    Just v -> case parseMaybe (withObject "ollama" $ \o -> do
        message <- o .: "message" :: Parser Value
        case message of
          Object m -> m .: "content" :: Parser Text
          _ -> fail "no message") v of
      Just t -> Right t
      Nothing -> Left "could not parse Ollama response"
    Nothing -> Left "invalid Ollama response"

extractOpenAI :: LBS.ByteString -> Either Text Text
extractOpenAI body =
  case decode body :: Maybe Value of
    Just v -> case parseMaybe (withObject "openai" $ \o -> do
        choices <- o .: "choices" :: Parser [Value]
        case choices of
          (Object c : _) -> do
            msg <- c .: "message" :: Parser Value
            case msg of
              Object m -> m .: "content" :: Parser Text
              _ -> fail "no message"
          _ -> fail "no choices") v of
      Just t -> Right t
      Nothing -> Left "could not parse OpenAI response"
    Nothing -> Left "invalid OpenAI response"

extractAnthropic :: LBS.ByteString -> Either Text Text
extractAnthropic body =
  case decode body :: Maybe Value of
    Just v -> case parseMaybe (withObject "anthropic" $ \o -> do
        content <- o .: "content" :: Parser [Value]
        case content of
          (Object c : _) -> c .: "text" :: Parser Text
          _ -> fail "no content") v of
      Just t -> Right t
      Nothing -> Left "could not parse Anthropic response"
    Nothing -> Left "invalid Anthropic response"

parseTagArray :: Text -> [Text]
parseTagArray raw =
  let (_, afterOpen) = T.breakOn "[" (T.strip raw)
      candidate = "[" <> T.takeWhile (/= ']') (T.drop 1 afterOpen) <> "]"
   in case decode (LBS.fromStrict (TE.encodeUtf8 candidate)) :: Maybe [Text] of
        Just xs -> xs
        Nothing -> []
