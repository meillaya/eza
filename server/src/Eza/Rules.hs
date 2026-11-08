{-# LANGUAGE OverloadedStrings #-}

-- | Deterministic save rules: match a URL, domain, or title and add tags or
-- mark the bookmark read. Rules run inside the save transaction.
module Eza.Rules
  ( Rule (..)
  , listRules
  , createRule
  , updateRule
  , deleteRule
  , applyRules
  , matchingBookmarks
  ) where

import Control.Monad (forM_, when)
import Data.Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import GHC.Generics (Generic)

data Rule = Rule
  { ruleId :: Int
  , ruleName :: Text
  , ruleEnabled :: Bool
  , ruleField :: Text
  , rulePattern :: Text
  , ruleAddTags :: [Text]
  , ruleMarkRead :: Bool
  , ruleCreatedAt :: Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON Rule where
  toJSON rule =
    object
      [ "id" .= ruleId rule
      , "name" .= ruleName rule
      , "enabled" .= ruleEnabled rule
      , "field" .= ruleField rule
      , "pattern" .= rulePattern rule
      , "add_tags" .= ruleAddTags rule
      , "mark_read" .= ruleMarkRead rule
      , "created_at" .= ruleCreatedAt rule
      ]

instance FromJSON Rule where
  parseJSON = withObject "Rule" $ \o ->
    Rule
      <$> o .:? "id" .!= 0
      <*> o .: "name"
      <*> o .:? "enabled" .!= True
      <*> o .:? "field" .!= "url"
      <*> o .: "pattern"
      <*> o .:? "add_tags" .!= []
      <*> o .:? "mark_read" .!= False
      <*> o .:? "created_at" .!= 0

epoch :: IO Int
epoch = floor <$> getPOSIXTime

listRules :: Connection -> IO [Rule]
listRules conn = do
  rows <-
    query_
      conn
      "SELECT id,name,enabled,field,pattern,add_tags,mark_read,created_at FROM rules ORDER BY id" :: IO [(Int, Text, Int, Text, Text, Text, Int, Int)]
  pure [toRule row | row <- rows]
  where
    toRule (rid, name, enabled, ruleFieldName, rulePattern, tags, markRead, created) =
      Rule rid name (enabled /= 0) ruleFieldName rulePattern (parseTags tags) (markRead /= 0) created

createRule :: Connection -> Rule -> IO Rule
createRule conn rule = do
  now <- epoch
  withImmediateTransaction conn $
    execute
      conn
      "INSERT INTO rules (name,enabled,field,pattern,add_tags,mark_read,created_at) VALUES (?,?,?,?,?,?,?)"
      (ruleName rule, if ruleEnabled rule then 1 else 0 :: Int, ruleField rule, rulePattern rule, tagsJson (ruleAddTags rule), if ruleMarkRead rule then 1 else 0 :: Int, now)
  rid <- fromIntegral <$> lastInsertRowId conn
  pure rule {ruleId = rid, ruleCreatedAt = now}

updateRule :: Connection -> Rule -> IO Bool
updateRule conn rule = do
  withImmediateTransaction conn $ do
    execute
      conn
      "UPDATE rules SET name = ?, enabled = ?, field = ?, pattern = ?, add_tags = ?, mark_read = ? WHERE id = ?"
      (ruleName rule, if ruleEnabled rule then 1 else 0 :: Int, ruleField rule, rulePattern rule, tagsJson (ruleAddTags rule), if ruleMarkRead rule then 1 else 0 :: Int, ruleId rule)
    changed <- changes conn
    pure (changed > 0)

deleteRule :: Connection -> Int -> IO Bool
deleteRule conn rid = do
  withImmediateTransaction conn $ do
    execute conn "DELETE FROM rules WHERE id = ?" (Only rid)
    changed <- changes conn
    pure (changed > 0)

-- | Apply all enabled matching rules to one bookmark. Caller owns the write
-- transaction, so this function uses plain statements.
applyRules :: Connection -> Int -> Text -> Text -> IO [Int]
applyRules conn bookmarkId url title = do
  rules <- listRules conn
  let matched = filter (matches url title) rules
  forM_ matched $ \rule -> do
    now <- epoch
    forM_ (ruleAddTags rule) $ \tag -> do
      execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)" (tag, now)
      ids <- query conn "SELECT id FROM tags WHERE name = ?" (Only tag) :: IO [Only Int]
      case ids of
        (Only tagId : _) -> execute conn "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?, ?)" (bookmarkId, tagId)
        _ -> pure ()
    when (ruleMarkRead rule) $
      execute conn "UPDATE bookmarks SET is_read = 1 WHERE id = ?" (Only bookmarkId)
  pure (map ruleId matched)
  where
    matches candidateUrl candidateTitle rule =
      let haystack = T.toLower $ case T.toLower (ruleField rule) of
            "domain" -> domainOf candidateUrl
            "title" -> candidateTitle
            _ -> candidateUrl
          needle = T.toLower (T.strip (rulePattern rule))
       in ruleEnabled rule && not (T.null needle) && needle `T.isInfixOf` haystack

matchingBookmarks :: Connection -> Text -> Text -> IO [Int]
matchingBookmarks conn fieldName rulePattern = do
  let column = case T.toLower fieldName of
        "domain" -> "domain"
        "title" -> "title"
        _ -> "url"
      likePattern = "%" <> T.strip rulePattern <> "%"
  rows <- query conn (Query ("SELECT id FROM bookmarks WHERE " <> column <> " LIKE ? COLLATE NOCASE ORDER BY id LIMIT 100")) (Only likePattern) :: IO [Only Int]
  pure [i | Only i <- rows]

domainOf :: Text -> Text
domainOf url =
  let afterScheme = T.drop 1 (T.dropWhile (/= ':') url)
      afterSlashes = T.dropWhile (== '/') afterScheme
      authority = T.takeWhile (\c -> c /= '/' && c /= '?' && c /= '#') afterSlashes
   in T.toLower (T.takeWhile (\c -> c /= ':') authority)

tagsJson :: [Text] -> Text
tagsJson = TE.decodeUtf8 . LBS.toStrict . encode

parseTags :: Text -> [Text]
parseTags raw =
  case decode (LBS.fromStrict (TE.encodeUtf8 raw)) :: Maybe [Text] of
    Just tags -> tags
    Nothing -> []
