{-# LANGUAGE OverloadedStrings #-}

-- Every mutation writes an undo snapshot first: a tag rename or merge keeps the
-- old tag rows and every bookmark/tag link that pointed at the affected names,
-- and a delete keeps the tag row and its links. 'undoLast' restores the whole
-- set, so renaming, merging, deleting or detaching a tag is reversible.

-- | Tag consolidation candidates and the tag mutation actions.
module Eza.Tags (
    ConsolidationGroup (..),
    ConsolidationReport (..),
    consolidationCandidates,
    mergeTags,
    renameTag,
    deleteTag,
    deleteTagWithLinks,
) where

import Control.Monad (forM_)
import Data.Char (toLower)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple

import Eza.Consolidation (ConsolidationGroup (..), ConsolidationReport (..))
import Eza.Types (TagStat (..))
import Eza.Undo (recordTagUndo)

consolidationCandidates :: Connection -> IO ConsolidationReport
consolidationCandidates conn = do
    rows <- query_ conn "SELECT t.name,COUNT(bt.bookmark_id) FROM tags t LEFT JOIN bookmark_tags bt ON bt.tag_id=t.id GROUP BY t.id ORDER BY t.name" :: IO [(Text, Int)]
    let stats = [TagStat name count | (name, count) <- rows]
        byLower = Map.fromListWith (flip (<>)) [(T.toLower (tsName s), [s]) | s <- stats]
        caseGroups =
            [ ConsolidationGroup "case" (sortOn (T.toLower . tsName) group) (mostUsed group)
            | group <- Map.elems byLower
            , length group > 1
            ]
        caseNames = Set.fromList (concatMap (map (T.toLower . tsName) . cgTags) caseGroups)
        nonCase = [s | s <- stats, not (Set.member (T.toLower (tsName s)) caseNames)]
        fuzzyGroups = fuzzyPairs nonCase
        junk =
            [ ConsolidationGroup "junk" [s] ""
            | s <- stats
            , Set.member (T.toLower (tsName s)) junkNames
            ]
    pure (ConsolidationReport (caseGroups <> fuzzyGroups <> junk))

{- | Suggest the most-used member of a group as the merge target. Total: a
group is never empty, but the empty branch keeps the function safe.
-}
mostUsed :: [TagStat] -> Text
mostUsed group = case sortOn (negate . tsCount) group of
    (stat : _) -> tsName stat
    [] -> ""

junkNames :: Set.Set Text
junkNames =
    Set.fromList
        [ "imported"
        , "tabs"
        , "archive"
        , "imported sessions"
        , "bookmarks"
        , "bookmarks bar"
        , "other bookmarks"
        , "mobile bookmarks"
        , "favorites"
        , "links"
        , "misc"
        , "saved"
        , "stuff"
        , "temp"
        , "temp 2"
        , "new folder"
        , "useful"
        , "important"
        , "interesting"
        , "various"
        , "general"
        ]

fuzzyPairs :: [TagStat] -> [ConsolidationGroup]
fuzzyPairs stats = go (sortOn tsName stats) []
  where
    go [] acc = reverse acc
    go (x : xs) acc =
        let matches =
                [ ConsolidationGroup "fuzzy" [x, y] (tsName (if tsCount y > tsCount x then y else x))
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
editDistance a b = last (foldl step [0 .. length b] a)
  where
    step prev c = case prev of
        [] -> []
        (prev0 : prevRest) -> go (prev0 + 1) prev0 (zip prevRest (drop 1 b))
      where
        go _ prevLeft [] = [prevLeft + 1]
        go left prevLeft ((up, bc) : rest) =
            let value = minimum [prevLeft + 1, left + 1, up + (if c == bc then 0 else 1)]
             in value : go value up rest

{- | Merge the source tags into one target name: keep every bookmark/tag link
(union), delete the source tag rows. Nothing happens when no source tag exists.
A tag snapshot of the target and all sources is written first.
-}
mergeTags :: Connection -> [Text] -> Text -> IO Int
mergeTags conn fromNames into = do
    let target = T.toLower (T.strip into)
        sources = [n | n <- lowerNames fromNames, n /= target]
    if T.null target || null sources
        then pure 0
        else withImmediateTransaction conn $ do
            sourceIds <- mapM (tagIdByName conn) sources
            let existingSources = [(src, tagId) | (src, Just tagId) <- zip sources sourceIds]
            if null existingSources
                then pure 0
                else do
                    _ <- recordTagUndo conn "tag_merge" (target : sources)
                    execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, strftime('%s','now'))" (Only target)
                    targetId <- tagIdByName conn target
                    case targetId of
                        Nothing -> pure 0
                        Just keepId -> do
                            forM_ existingSources $ \(_src, sourceId) -> do
                                execute conn "UPDATE OR IGNORE bookmark_tags SET tag_id = ? WHERE tag_id = ?" (keepId, sourceId)
                                execute conn "DELETE FROM bookmark_tags WHERE tag_id = ?" (Only sourceId)
                                execute conn "DELETE FROM tags WHERE id = ?" (Only sourceId)
                            pure (length existingSources)

{- | Rename one tag. Refuses when the old tag is missing or the new name is
already taken (a merge is the operation for that case). The tag snapshot covers
the old and the new name, so undo renames the tag back.
-}
renameTag :: Connection -> Text -> Text -> IO Bool
renameTag conn old new = do
    let o = T.toLower (T.strip old)
        n = T.toLower (T.strip new)
    if T.null o || T.null n || o == n
        then pure False
        else withImmediateTransaction conn $ do
            oldRows <- query conn "SELECT 1 FROM tags WHERE name = ?" (Only o) :: IO [Only Int]
            newRows <- query conn "SELECT 1 FROM tags WHERE name = ?" (Only n) :: IO [Only Int]
            if null oldRows || not (null newRows)
                then pure False
                else do
                    _ <- recordTagUndo conn "tag_rename" [o, n]
                    execute conn "UPDATE tags SET name = ? WHERE name = ?" (n, o)
                    changed <- changes conn
                    pure (changed > 0)

{- | Delete an empty tag. The tag snapshot keeps the tag row, so undo restores
it. Non-empty tags are refused: use 'deleteTagWithLinks' to detach first.
-}
deleteTag :: Connection -> Text -> IO Bool
deleteTag conn name = do
    let n = T.toLower (T.strip name)
    if T.null n
        then pure False
        else withImmediateTransaction conn $ do
            tagRows <- query conn "SELECT id FROM tags WHERE name = ?" (Only n) :: IO [Only Int]
            case tagRows of
                [] -> pure False
                (Only tagId : _) -> do
                    attached <- countTagged conn tagId
                    if attached > 0
                        then pure False
                        else do
                            _ <- recordTagUndo conn "tag_delete" [n]
                            execute conn "DELETE FROM tags WHERE id = ?" (Only tagId)
                            changed <- changes conn
                            pure (changed > 0)

{- | Force-delete a tag: detach it from every bookmark, then delete the tag row.
The snapshot keeps both the tag row and all bookmark/tag links, so
'undoLast' restores the tag and its attachments.
-}
deleteTagWithLinks :: Connection -> Text -> IO Bool
deleteTagWithLinks conn name = do
    let n = T.toLower (T.strip name)
    if T.null n
        then pure False
        else withImmediateTransaction conn $ do
            tagRows <- query conn "SELECT id FROM tags WHERE name = ?" (Only n) :: IO [Only Int]
            case tagRows of
                [] -> pure False
                (Only tagId : _) -> do
                    _ <- recordTagUndo conn "tag_delete_detach" [n]
                    execute conn "DELETE FROM bookmark_tags WHERE tag_id = ?" (Only tagId)
                    execute conn "DELETE FROM tags WHERE id = ?" (Only tagId)
                    changed <- changes conn
                    pure (changed > 0)

countTagged :: Connection -> Int -> IO Int
countTagged conn tagId = do
    rows <- query conn "SELECT COUNT(*) FROM bookmark_tags WHERE tag_id = ?" (Only tagId) :: IO [Only Int]
    pure (case rows of [Only n] -> n; _ -> 0)

-- | Resolve a tag name (case-insensitively, the column is COLLATE NOCASE).
tagIdByName :: Connection -> Text -> IO (Maybe Int)
tagIdByName conn name = do
    rows <- query conn "SELECT id FROM tags WHERE name = ?" (Only name) :: IO [Only Int]
    pure (case rows of (Only tagId : _) -> Just tagId; [] -> Nothing)

-- | Lower-case, trim and de-duplicate tag names, dropping empty ones.
lowerNames :: [Text] -> [Text]
lowerNames = go []
  where
    go _ [] = []
    go seen (name : rest) =
        let n = T.toLower (T.strip name)
         in if T.null n || n `elem` seen then go seen rest else n : go (n : seen) rest
