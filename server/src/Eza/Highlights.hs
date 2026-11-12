{-# LANGUAGE OverloadedStrings #-}

module Eza.Highlights (
    listHighlights,
    createHighlight,
    updateHighlight,
    deleteHighlight,
    reanchorHighlights,
) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple

import Eza.Types (Highlight (..))

epoch :: IO Int
epoch = floor <$> getPOSIXTime

listHighlights :: Connection -> Int -> IO [Highlight]
listHighlights conn bookmarkId = do
    rows <-
        query
            conn
            "SELECT id, bookmark_id, quote, start_offset, end_offset, note, color, created_at FROM highlights WHERE bookmark_id = ? ORDER BY start_offset ASC, id ASC"
            (Only bookmarkId) ::
            IO [(Int, Int, Text, Int, Int, Text, Text, Int)]
    pure [Highlight hid bid quote start end note color created | (hid, bid, quote, start, end, note, color, created) <- rows]

createHighlight :: Connection -> Int -> Text -> Text -> Text -> Int -> Int -> Text -> Text -> IO (Either Text Highlight)
createHighlight conn bookmarkId quote prefix suffix startOffset endOffset note color
    | T.null (T.strip quote) = pure (Left "quote is required")
    | T.length quote > 20000 = pure (Left "quote is too long")
    | startOffset < 0 || endOffset <= startOffset = pure (Left "invalid highlight offsets")
    | otherwise = do
        exists <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only bookmarkId) :: IO [Only Int]
        if null exists
            then pure (Left "bookmark not found")
            else do
                now <- epoch
                withImmediateTransaction conn $
                    execute
                        conn
                        "INSERT INTO highlights (bookmark_id, quote, prefix, suffix, start_offset, end_offset, note, color, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)"
                        (bookmarkId, T.strip quote, prefix, suffix, startOffset, endOffset, note, if T.null (T.strip color) then "yellow" else color, now, now)
                hid <- fromIntegral <$> lastInsertRowId conn
                pure (Right (Highlight hid bookmarkId (T.strip quote) startOffset endOffset note (if T.null (T.strip color) then "yellow" else color) now))

updateHighlight :: Connection -> Int -> Int -> Maybe Text -> Maybe Text -> IO Bool
updateHighlight conn bookmarkId highlightId note color = do
    exists <- query conn "SELECT 1 FROM highlights WHERE id = ? AND bookmark_id = ?" (highlightId, bookmarkId) :: IO [Only Int]
    if null exists
        then pure False
        else do
            now <- epoch
            withImmediateTransaction conn $ do
                case note of
                    Just value -> execute conn "UPDATE highlights SET note = ?, updated_at = ? WHERE id = ? AND bookmark_id = ?" (value, now, highlightId, bookmarkId)
                    Nothing -> pure ()
                case color of
                    Just value -> execute conn "UPDATE highlights SET color = ?, updated_at = ? WHERE id = ? AND bookmark_id = ?" (value, now, highlightId, bookmarkId)
                    Nothing -> pure ()
            pure True

deleteHighlight :: Connection -> Int -> Int -> IO Bool
deleteHighlight conn bookmarkId highlightId = do
    withImmediateTransaction conn $ do
        execute conn "DELETE FROM highlights WHERE id = ? AND bookmark_id = ?" (highlightId, bookmarkId)
        changed <- changes conn
        pure (changed > 0)

{- | Re-anchor highlights after the reading text changes. Client offsets are
hints: keep an offset pair when it still quotes the same text, otherwise find
the quote (preferring the stored prefix/suffix context), and delete only the
highlight whose quote is gone. Returns the number deleted.
-}
reanchorHighlights :: Connection -> Int -> Text -> IO Int
reanchorHighlights conn bookmarkId text = do
    rows <-
        query
            conn
            "SELECT id,quote,prefix,suffix,start_offset,end_offset FROM highlights WHERE bookmark_id = ? ORDER BY id"
            (Only bookmarkId) ::
            IO [(Int, Text, Text, Text, Int, Int)]
    now <- epoch
    removed <- foldMapM (reanchorOne now) rows
    pure removed
  where
    foldMapM f = fmap sum . mapM f
    reanchorOne now (highlightId, quote, prefix, suffix, oldStart, oldEnd) =
        case locate text quote prefix suffix oldStart oldEnd of
            Nothing -> do
                execute conn "DELETE FROM highlights WHERE id = ? AND bookmark_id = ?" (highlightId, bookmarkId)
                pure 1
            Just (newStart, newEnd) -> do
                let before = T.takeEnd 32 (T.take (max 0 newStart) text)
                    after = T.take 32 (T.drop (max 0 newEnd) text)
                execute
                    conn
                    "UPDATE highlights SET start_offset = ?, end_offset = ?, prefix = ?, suffix = ?, updated_at = ? WHERE id = ? AND bookmark_id = ?"
                    (newStart, newEnd, before, after, now, highlightId, bookmarkId)
                pure 0

locate :: Text -> Text -> Text -> Text -> Int -> Int -> Maybe (Int, Int)
locate text quote prefix suffix oldStart oldEnd
    | oldStart >= 0
    , oldEnd <= T.length text
    , T.take (oldEnd - oldStart) (T.drop oldStart text) == quote =
        Just (oldStart, oldEnd)
    | otherwise =
        case uniqueOccurrence (prefix <> quote <> suffix) text of
            Just start -> Just (start + T.length prefix, start + T.length prefix + T.length quote)
            Nothing -> case uniqueOccurrence quote text of
                Just start -> Just (start, start + T.length quote)
                Nothing -> Nothing

uniqueOccurrence :: Text -> Text -> Maybe Int
uniqueOccurrence needle haystack
    | T.null needle = Nothing
    | T.count needle haystack /= 1 = Nothing
    | otherwise =
        let (before, _) = T.breakOn needle haystack
         in Just (T.length before)
