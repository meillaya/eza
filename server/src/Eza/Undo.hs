{-# LANGUAGE OverloadedStrings #-}

{- | Undo over the append-only change journal (schema v17).

Every mutating operation records before-images through "Eza.Journal" before it
changes rows; this module keeps the public undo API and turns the journal into
the same @UndoEntry@/@UndoPreview@/@UndoResult@ documents the API has always
served. The old @undo_*@ side tables and their JSON-payload snapshots are gone;
an installation that upgrades to v17 starts with an empty undo history (schema
v17 drops the old tables and does not migrate their contents).

Undo is a stack: only the newest usable change can be restored. A bookmark is
restored by id when its URL is unchanged, inserted when neither its id nor its
URL is free, and skipped (counted, never overwritten) when its URL belongs to a
newer row. The FTS index is rebuilt after a bookmark restore.
-}
module Eza.Undo (
    recordUndoIds,
    recordTagUndo,
    undoLast,
    undoLastDetailed,
    listUndoEntries,
    undoPreview,
    undoById,
    UndoFailure (..),
) where

import Control.Monad (forM)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple

import Eza.Journal (Change (..), ChangeCounts (..))
import qualified Eza.Journal as Journal
import Eza.Types (UndoBookmarkRef (..), UndoEntry (..), UndoPreview (..), UndoResult (..))

{- | Why an explicit undo request was refused. A missing change is a 404; an
older change is a 409 because undo is a stack.
-}
data UndoFailure = UndoNotFound | UndoNotNewest
    deriving (Show, Eq)

{- | Record the before-images for a bookmark mutation and return the new change
id (0 when the id list is empty). Must run inside the caller's write
transaction, before the rows change.
-}
recordUndoIds :: Connection -> Text -> [Int] -> IO Int
recordUndoIds = Journal.recordBookmarks

-- | Record the before-images for a tag mutation; see 'recordUndoIds'.
recordTagUndo :: Connection -> Text -> [Text] -> IO Int
recordTagUndo = Journal.recordTags

-- --------------------------------------------------------------- listing ---

listUndoEntries :: Connection -> Int -> IO [UndoEntry]
listUndoEntries conn limit = do
    journalChanges <- Journal.listChanges conn (max 1 limit)
    entries <- forM journalChanges (entryFor conn)
    pure (markNewest (filter usableEntry entries))

undoPreview :: Connection -> Int -> IO (Maybe UndoPreview)
undoPreview conn changeId = do
    found <- Journal.findChange conn changeId
    case found of
        Nothing -> pure Nothing
        Just change -> do
            newest <- Journal.newestUsableChange conn
            entry <- entryFor conn change
            (bookmarkValues, tagNames) <- Journal.changeSamples conn changeId 100
            let bookmarks = mapMaybe bookmarkRef bookmarkValues
                tags = take 100 tagNames
                truncated =
                    unBookmarkCount entry > length bookmarks
                        || unTagCount entry > length tags
            pure
                ( Just
                    UndoPreview
                        { upEntry = entry{unCanUndo = fmap chId newest == Just changeId}
                        , upBookmarks = bookmarks
                        , upTags = tags
                        , upTruncated = truncated
                        }
                )

{- | Restore the newest usable change. Unusable changes are discarded one by
one, and the restore runs in one immediate transaction so a failure leaves the
library untouched. Returns the number of rows restored and the number of
bookmark rows skipped because their URL now belongs to a different row.
-}
undoLastDetailed :: Connection -> IO (Int, Int)
undoLastDetailed conn = withImmediateTransaction conn $ do
    Journal.cleanupUnusableChanges conn
    newest <- Journal.newestUsableChange conn
    case newest of
        Nothing -> pure (0, 0)
        Just change -> do
            result <- Journal.restoreChange conn (chId change)
            Journal.cleanupUnusableChanges conn
            pure result

-- | Compatibility wrapper for callers that only need the restored count.
undoLast :: Connection -> IO Int
undoLast conn = fst <$> undoLastDetailed conn

{- | Restore one change by id. Only the newest usable change may be restored:
undo is a stack, so an older request returns 'UndoNotNewest' and the client
keeps the list intact.
-}
undoById :: Connection -> Int -> IO (Either UndoFailure UndoResult)
undoById conn changeId = withImmediateTransaction conn $ do
    found <- Journal.findChange conn changeId
    case found of
        Nothing -> pure (Left UndoNotFound)
        Just change -> do
            newest <- Journal.newestUsableChange conn
            case newest of
                Nothing -> pure (Left UndoNotFound)
                Just latest
                    | chId latest /= changeId -> pure (Left UndoNotNewest)
                    | otherwise -> do
                        (restored, skipped) <- Journal.restoreChange conn changeId
                        pure (Right (UndoResult restored skipped changeId (displayLabel change)))

-- ---------------------------------------------------------------- helpers ---

entryFor :: Connection -> Change -> IO UndoEntry
entryFor conn change = do
    counts <- Journal.changeCounts conn (chId change)
    (bookmarkValues, tagNames) <- Journal.changeSamples conn (chId change) 4
    pure
        UndoEntry
            { unId = chId change
            , unOp = displayLabel change
            , unCreatedAt = chCreatedAt change
            , unRowCount = max (ccBookmarks counts) (ccTagNames counts)
            , unBookmarkCount = ccBookmarks counts
            , unTagCount = ccTagNames counts
            , unHighlightCount = ccHighlights counts
            , unCaptureCount = ccCaptures counts
            , unLinkCount = ccLinks counts
            , unCanUndo = False
            , unLegacy = False
            , unBookmarks = mapMaybe bookmarkRef bookmarkValues
            , unTags = take 4 tagNames
            }

usableEntry :: UndoEntry -> Bool
usableEntry entry =
    unBookmarkCount entry > 0
        || unTagCount entry > 0
        || unHighlightCount entry > 0
        || unCaptureCount entry > 0
        || unLinkCount entry > 0

markNewest :: [UndoEntry] -> [UndoEntry]
markNewest [] = []
markNewest (entry : rest) =
    entry{unCanUndo = usableEntry entry} : map (\other -> other{unCanUndo = False}) rest

displayLabel :: Change -> Text
displayLabel change
    | T.null (T.strip (chLabel change)) = chOp change
    | otherwise = chLabel change

bookmarkRef :: Value -> Maybe UndoBookmarkRef
bookmarkRef (Object value) = do
    bookmarkId <- jsonInt (KeyMap.lookup "id" value)
    title <- textField "title" value
    url <- textField "url" value
    domain <- textField "domain" value
    pure (UndoBookmarkRef bookmarkId title url domain)
bookmarkRef _ = Nothing

textField :: Text -> KeyMap.KeyMap Value -> Maybe Text
textField name value = case KeyMap.lookup (Data.Aeson.Key.fromText name) value of
    Just (String text) -> Just text
    _ -> Nothing

jsonInt :: Maybe Value -> Maybe Int
jsonInt (Just (Number number)) = Just (truncate number)
jsonInt _ = Nothing
