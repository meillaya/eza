{-# LANGUAGE OverloadedStrings #-}
-- | Duplicate detection and the explicit merge action.

-- 'dedupCandidates' only reports groups; nothing is ever merged automatically.
-- 'mergeBookmarks' is called from the confirmed merge endpoint and preserves
-- data from every absorbed row: tags are unioned, notes appended with a source
-- heading, highlights and wikilinks moved to the keeper, counters combined and
-- empty keeper metadata filled from the first absorbed row that has it. A side
-- undo snapshot of all affected rows (plus their highlights and wikilinks) is
-- written before anything changes.
module Eza.Dedup
  ( DedupGroup (..)
  , DedupReport (..)
  , dedupCandidates
  , mergeBookmarks
  ) where

import Control.Monad (forM, forM_)
import Data.Aeson (ToJSON (..), genericToJSON)
import Data.Char (isAlphaNum)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import GHC.Generics (Generic)
import Network.URI (URI (..), URIAuth (..), parseURI)

import Eza.Bookmarks (bookmarksByIds)
import Eza.Json (jsonOptions)
import Eza.Types (BookmarkSummary (..))
import Eza.Undo (recordUndoIds)
import Eza.Url (hostOf)

data DedupGroup = DedupGroup
  { dgKey :: Text
  , dgItems :: [BookmarkSummary]
  }
  deriving (Show, Eq, Generic)

instance ToJSON DedupGroup where
  toJSON = genericToJSON (jsonOptions "dg")

data DedupReport = DedupReport
  { drGroups :: [DedupGroup]
  }
  deriving (Show, Eq, Generic)

instance ToJSON DedupReport where
  toJSON = genericToJSON (jsonOptions "dr")

dedupCandidates :: Connection -> IO DedupReport
dedupCandidates conn = do
  rows <- query_ conn "SELECT id,url,title,domain FROM bookmarks" :: IO [(Int, Text, Text, Text)]
  let entries = [(i, normalizeUrl u, normalizeTitle t, hostOf u) | (i, u, t, _) <- rows]
      byUrl = Map.fromListWith (<>) [((normalizeDomain d, nu), [i]) | (i, nu, _, d) <- entries]
      urlGroups = [(key, ids) | (key, ids) <- Map.toList byUrl, length ids > 1]
      urlIds = Set.fromList (concatMap snd urlGroups)
      byTitle =
        Map.fromListWith (<>)
          [ ((normalizeDomain d, nt), [i])
          | (i, _, nt, d) <- entries
          , not (Set.member i urlIds)
          , not (T.null nt)
          ]
      titleGroups = [(key, ids) | (key, ids) <- Map.toList byTitle, length ids > 1]
      groups = urlGroups <> titleGroups
  items <- forM groups $ \((dom, key), ids) -> do
    summaries <- bookmarksByIds conn ids
    pure (DedupGroup (dom <> ":" <> key) summaries)
  pure (DedupReport (sortOn dgKey items))

normalizeUrl :: Text -> Text
normalizeUrl raw =
  case parseURI (T.unpack (T.strip raw)) of
    Nothing -> T.toLower (T.strip raw)
    Just uri ->
      let auth = uriAuthority uri
          host = case auth of
            Nothing -> ""
            Just a -> T.toLower (T.pack (uriRegName a))
          host' = fromMaybe host (T.stripPrefix "www." host)
          path = T.pack (uriPath uri)
          path' = if T.length path > 1 && T.last path == '/' then T.init path else path
          params = parseQuery (T.pack (uriQuery uri))
          meaningful = [(k, v) | (k, v) <- params, not (isTracking k)]
          q = if null meaningful then "" else "?" <> T.intercalate "&" [k <> "=" <> v | (k, v) <- meaningful]
       in host' <> path' <> q

parseQuery :: Text -> [(Text, Text)]
parseQuery q =
  [ (k, v)
  | part <- T.splitOn "&" (T.dropWhile (== '?') q)
  , not (T.null part)
  , let (k, rest) = T.breakOn "=" part
  , let v = fromMaybe "" (T.stripPrefix "=" rest)
  ]

isTracking :: Text -> Bool
isTracking k =
  "utm_" `T.isPrefixOf` k || k `elem` ["fbclid", "gclid", "ref", "ref_src"]

normalizeTitle :: Text -> Text
normalizeTitle = T.unwords . T.words . T.toLower . T.map replace
  where
    replace c
      | isAlphaNum c || c == ' ' = c
      | otherwise = ' '

normalizeDomain :: Text -> Text
normalizeDomain domain =
  let host = T.toLower (T.takeWhile (\c -> c /= '/' && c /= ':') domain)
   in fromMaybe host (T.stripPrefix "www." host)

-- | The bookmark columns a merge reads and combines. @id@ is first so the same
-- row parser works for the keeper and for each absorbed row.
data MergeRow = MergeRow
  { mrCreatedAt :: Int
  , mrAddedAt :: Int
  , mrOpenCount :: Int
  , mrLastOpenedAt :: Maybe Int
  , mrLastCheckedAt :: Maybe Int
  , mrIsRead :: Int
  , mrIsDead :: Int
  , mrFaviconUrl :: Text
  , mrSnapshotPath :: Text
  , mrSnapshotKind :: Text
  , mrSnapshotCapturedAt :: Maybe Int
  , mrAiSummary :: Text
  }

instance FromRow MergeRow where
  fromRow =
    MergeRow <$> field <*> field <*> field <*> field <*> field <*> field
      <*> field <*> field <*> field <*> field <*> field <*> field

mergeRowColumns :: Text
mergeRowColumns =
  "created_at,added_at,open_count,last_opened_at,last_checked_at,is_read,is_dead,favicon_url,snapshot_path,snapshot_kind,snapshot_captured_at,ai_summary"

-- | A note row with the title/url used for the appended source heading.
data NoteRow = NoteRow
  { nrId :: Int
  , nrTitle :: Text
  , nrUrl :: Text
  , nrNote :: Text
  }

instance FromRow NoteRow where
  fromRow = NoteRow <$> field <*> field <*> field <*> field

{- | Merge @mergeIds@ into @keep@ and delete the absorbed rows. Returns the
number of absorbed rows (0 when the keeper is missing or nothing was absorbed).
No automatic merge: this only runs for an explicit confirmed request.
-}
mergeBookmarks :: Connection -> Int -> [Int] -> IO Int
mergeBookmarks conn keep mergeIds = do
  let merges = dedupeIds (filter (/= keep) mergeIds)
  if null merges
    then pure 0
    else
      withImmediateTransaction conn $ do
        exists <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only keep) :: IO [Only Int]
        case exists of
          [] -> pure 0
          _ -> do
            let marks = T.intercalate "," (replicate (length merges) "?")
            noteRows <-
              query
                conn
                (Query ("SELECT id,title,url,note_body FROM bookmarks WHERE id IN (" <> marks <> ") ORDER BY id"))
                merges :: IO [NoteRow]
            let found = map nrId noteRows
            if null found
              then pure 0
              else do
                now <- (floor <$> getPOSIXTime) :: IO Int
                -- Snapshot first: bookmark rows, tags, highlights and links.
                _ <- recordUndoIds conn "merge" (keep : found)
                -- 1. Tags are unioned onto the keeper.
                forM_ found $ \mid ->
                  execute
                    conn
                    "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) SELECT ?, tag_id FROM bookmark_tags WHERE bookmark_id = ?"
                    (keep, mid)
                -- 2. Highlights move to the keeper with quote/offsets intact.
                forM_ found $ \mid ->
                  execute
                    conn
                    "UPDATE highlights SET bookmark_id = ?, updated_at = ? WHERE bookmark_id = ?"
                    (keep, now, mid)
                -- 3. Wikilinks are repointed at the keeper; rows that cannot be
                --    repointed because of the UNIQUE key are deleted afterwards.
                forM_ found $ \mid -> execute conn "UPDATE OR IGNORE links SET source_id = ? WHERE source_id = ?" (keep, mid)
                forM_ found $ \mid -> execute conn "UPDATE OR IGNORE links SET target_id = ? WHERE target_id = ?" (keep, mid)
                execute
                  conn
                  (Query ("DELETE FROM links WHERE source_id IN (" <> marks <> ") OR target_id IN (" <> marks <> ")"))
                  (merges <> merges)
                -- 4. Notes: keep the keeper note and append every absorbed note
                --    under a heading naming its source, so nothing is dropped.
                keeperNoteRows <-
                  query
                    conn
                    "SELECT note_body FROM bookmarks WHERE id = ?"
                    (Only keep) :: IO [Only Text]
                keeperRows <-
                  query
                    conn
                    (Query ("SELECT " <> mergeRowColumns <> " FROM bookmarks WHERE id = ?"))
                    (Only keep) :: IO [MergeRow]
                case keeperRows of
                  [] -> pure 0
                  keeper : _ -> do
                    mergedRows <-
                      query
                        conn
                        (Query ("SELECT " <> mergeRowColumns <> " FROM bookmarks WHERE id IN (" <> marks <> ") ORDER BY id"))
                        merges :: IO [MergeRow]
                    let allRows = keeper : mergedRows
                        baseNote = case keeperNoteRows of
                          (Only n : _) -> n
                          _ -> ""
                        mergedNote =
                          appendNotes
                            baseNote
                            [ noteBlock (nrTitle r) (nrUrl r) (nrNote r)
                            | r <- noteRows
                            , not (T.null (T.strip (nrNote r)))
                            ]
                        openCount = sum (map mrOpenCount allRows)
                        lastOpened = maxJust (map mrLastOpenedAt allRows)
                        lastChecked = maxJust (map mrLastCheckedAt allRows)
                        -- A merged copy that was read makes the keeper read; a
                        -- dead keeper stays dead only when every copy was dead.
                        isRead = if any ((/= 0) . mrIsRead) allRows then (1 :: Int) else 0
                        isDead = if all ((/= 0) . mrIsDead) allRows then (1 :: Int) else 0
                        createdAt = minimum (map mrCreatedAt allRows)
                        addedAt = minimum (map mrAddedAt allRows)
                        capturedAt = firstJust (map mrSnapshotCapturedAt allRows)
                    executeNamed
                      conn
                      "UPDATE bookmarks SET note_body = :note, open_count = :open_count, last_opened_at = :last_opened, last_checked_at = :last_checked, is_read = :is_read, is_dead = :is_dead, created_at = :created, added_at = :added, favicon_url = :favicon, snapshot_path = :snapshot_path, snapshot_kind = :snapshot_kind, snapshot_captured_at = :snapshot_captured, ai_summary = :ai_summary, updated_at = :updated WHERE id = :keep"
                      [ ":note" := mergedNote
                      , ":open_count" := openCount
                      , ":last_opened" := lastOpened
                      , ":last_checked" := lastChecked
                      , ":is_read" := isRead
                      , ":is_dead" := isDead
                      , ":created" := createdAt
                      , ":added" := addedAt
                      , ":favicon" := firstText (map mrFaviconUrl allRows)
                      , ":snapshot_path" := firstText (map mrSnapshotPath allRows)
                      , ":snapshot_kind" := firstText (map mrSnapshotKind allRows)
                      , ":snapshot_captured" := capturedAt
                      , ":ai_summary" := firstText (map mrAiSummary allRows)
                      , ":updated" := now
                      , ":keep" := keep
                      ]
                    execute conn (Query ("DELETE FROM bookmarks WHERE id IN (" <> marks <> ")")) merges
                    pure (length found)

-- | Append notes with a blank line between blocks. Empty notes are skipped and
-- a note identical to the keeper body is not duplicated.
appendNotes :: Text -> [Text] -> Text
appendNotes base extras =
  let baseTrim = T.strip base
      kept = [T.strip e | e <- extras, not (T.null (T.strip e)), T.strip e /= baseTrim]
   in T.intercalate "\n\n" ([baseTrim | not (T.null baseTrim)] <> kept)

-- | One appended note, headed by its source record so the merged text stays
-- attributable.
noteBlock :: Text -> Text -> Text -> Text
noteBlock title url note =
  let heading
        | not (T.null (T.strip title)) = T.strip title
        | not (T.null (T.strip url)) = T.strip url
        | otherwise = "Merged bookmark"
   in "## " <> heading <> "\n\n" <> T.strip note

firstText :: [Text] -> Text
firstText texts = case [T.strip t | t <- texts, not (T.null (T.strip t))] of
  (t : _) -> t
  [] -> ""

firstJust :: [Maybe Int] -> Maybe Int
firstJust [] = Nothing
firstJust (Nothing : rest) = firstJust rest
firstJust (Just value : _) = Just value

maxJust :: [Maybe Int] -> Maybe Int
maxJust values = case [v | Just v <- values] of
  [] -> Nothing
  present -> Just (maximum present)

dedupeIds :: [Int] -> [Int]
dedupeIds ids = [i | (n, i) <- zip [0 :: Int ..] ids, i > 0, not (elem i (take n ids))]
