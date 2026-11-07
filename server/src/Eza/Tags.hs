{-# LANGUAGE OverloadedStrings #-}
module Eza.Tags
  ( TagGroup (..)
  , TagCleanup (..)
  , consolidationCandidates
  , mergeTags
  , renameTag
  , deleteTag
  ) where

import Control.Monad (forM)
import Data.Aeson (ToJSON (..), genericToJSON)
import Data.Char (toLower)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple
import GHC.Generics (Generic)

import Eza.Json (jsonOptions)
import Eza.Types (TagStat (..))

data TagGroup = TagGroup
  { tgKind :: Text
  , tgTags :: [TagStat]
  , tgSuggested :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON TagGroup where
  toJSON = genericToJSON (jsonOptions "tg")

data TagCleanup = TagCleanup
  { tcGroups :: [TagGroup]
  }
  deriving (Show, Eq, Generic)

instance ToJSON TagCleanup where
  toJSON = genericToJSON (jsonOptions "tc")

consolidationCandidates :: Connection -> IO TagCleanup
consolidationCandidates conn = do
  rows <- query_ conn "SELECT t.name,COUNT(bt.bookmark_id) FROM tags t LEFT JOIN bookmark_tags bt ON bt.tag_id=t.id GROUP BY t.id ORDER BY t.name" :: IO [(Text, Int)]
  let stats = [TagStat name count | (name, count) <- rows]
      byLower = Map.fromListWith (flip (<>)) [(T.toLower (tsName s), [s]) | s <- stats]
      caseGroups =
        [ TagGroup "case" (sortOn (T.toLower . tsName) group) (tsName (head group))
        | group <- Map.elems byLower
        , length group > 1
        ]
      caseNames = Set.fromList (concatMap (map (T.toLower . tsName) . tgTags) caseGroups)
      nonCase = [s | s <- stats, not (Set.member (T.toLower (tsName s)) caseNames)]
      fuzzyGroups = fuzzyPairs nonCase
      junk =
        [ TagGroup "junk" [s] ""
        | s <- stats
        , Set.member (T.toLower (tsName s)) junkNames
        ]
  pure (TagCleanup (caseGroups <> fuzzyGroups <> junk))

junkNames :: Set.Set Text
junkNames =
  Set.fromList
    [ "imported", "tabs", "archive", "imported sessions", "bookmarks"
    , "bookmarks bar", "other bookmarks", "mobile bookmarks", "favorites"
    , "links", "misc", "saved", "stuff", "temp", "temp 2", "new folder"
    , "useful", "important", "interesting", "various", "general"
    ]

fuzzyPairs :: [TagStat] -> [TagGroup]
fuzzyPairs stats = go (sortOn tsName stats) []
  where
    go [] acc = reverse acc
    go (x : xs) acc =
      let matches =
            [ TagGroup "fuzzy" [x, y] (tsName (if tsCount y > tsCount x then y else x))
            | y <- xs
            , similarity (tsName x) (tsName y) >= 0.82
            ]
       in go xs (matches <> acc)

similarity :: Text -> Text -> Double
similarity a b =
  let x = map toLower (T.unpack (T.strip a))
      y = map toLower (T.unpack (T.strip b))
      d = editDistance x y
      m = max (length x) (length y)
   in if m == 0 then 1 else 1 - fromIntegral d / fromIntegral m

editDistance :: String -> String -> Int
editDistance a b = last (finalRow (length a))
  where
    m = length b
    start = [0 .. m]
    finalRow 0 = start
    finalRow i =
      let prev = finalRow (i - 1)
          c = a !! (i - 1)
       in nextRow prev c
    nextRow prev c = (head prev + 1) : go (head prev + 1) 1
      where
        go left j
          | j > m = []
          | otherwise =
              let up = prev !! j
                  diag = prev !! (j - 1)
                  bc = b !! (j - 1)
                  v = minimum [left + 1, up + 1, diag + (if c == bc then 0 else 1)]
               in v : go v (j + 1)

mergeTags :: Connection -> [Text] -> Text -> IO Int
mergeTags conn fromNames into = do
  let target = T.toLower (T.strip into)
      sources =
        [ T.toLower (T.strip n)
        | n <- fromNames
        , not (T.null (T.strip n))
        , T.toLower (T.strip n) /= target
        ]
  if T.null target || null sources
    then pure 0
    else
      withImmediateTransaction conn $ do
        execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, strftime('%s','now'))" (Only target)
        targetRows <- query conn "SELECT id FROM tags WHERE name = ?" (Only target) :: IO [Only Int]
        case targetRows of
          [Only tid] -> do
            n <- forM sources $ \src -> do
              sidRows <- query conn "SELECT id FROM tags WHERE name = ?" (Only src) :: IO [Only Int]
              case sidRows of
                [Only sid] -> do
                  execute conn "UPDATE OR IGNORE bookmark_tags SET tag_id = ? WHERE tag_id = ?" (tid, sid)
                  execute conn "DELETE FROM bookmark_tags WHERE tag_id = ?" (Only sid)
                  execute conn "DELETE FROM tags WHERE id = ?" (Only sid)
                  pure 1
                _ -> pure 0
            pure (sum n)
          _ -> pure 0

renameTag :: Connection -> Text -> Text -> IO Bool
renameTag conn old new = do
  let o = T.toLower (T.strip old)
      n = T.toLower (T.strip new)
  if T.null o || T.null n
    then pure False
    else do
      changed <- withImmediateTransaction conn $ do
        execute conn "UPDATE OR IGNORE tags SET name = ? WHERE name = ?" (n, o)
        changes conn
      pure (changed > 0)

deleteTag :: Connection -> Text -> IO Bool
deleteTag conn name = do
  let n = T.toLower (T.strip name)
  withImmediateTransaction conn $ do
    rows <- query conn "SELECT COUNT(*) FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id WHERE t.name = ?" (Only n) :: IO [Only Int]
    case rows of
      [Only 0] -> do
        execute conn "DELETE FROM tags WHERE name = ?" (Only n)
        changed <- changes conn
        pure (changed > 0)
      _ -> pure False
