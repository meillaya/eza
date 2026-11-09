{-# LANGUAGE OverloadedStrings #-}

{- | The durable event outbox.

'Writes call 'recordEvent' inside the transaction that changes the data, so an
event row exists exactly when the write committed. Delivery is the webhook
worker's job ("Eza.Webhooks"): it fans the outbox out into deliveries and posts
the signed envelopes.

The v1 catalog is bookmark.created, bookmark.updated, bookmark.deleted and
clip.created. Imports do not emit per-row events (an import can insert
thousands of bookmarks, and an import.completed event kind is not part of the
approved v1 catalog); clips emit clip.created and the bookmark side of a clip
is not re-emitted as bookmark.created/updated.
-}
module Eza.Events (
    recordEvent,
    bookmarkEventData,
    bookmarkEventDataMany,
    clipEventData,
) where

import Control.Monad (forM)
import Data.Aeson (Value, encode, object, (.=))
import qualified Data.ByteString.Lazy as LBS
import Data.List (nub, sortOn)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple

import Eza.Webhook (EventType, eventTypeText)

-- | Append one outbox row in the caller's transaction.
recordEvent :: Connection -> EventType -> Value -> IO ()
recordEvent conn eventType payload = do
    now <- currentEpoch
    execute
        conn
        "INSERT INTO event_log (kind, payload_json, created_at) VALUES (?,?,?)"
        (eventTypeText eventType, TE.decodeUtf8 (LBS.toStrict (encode payload)), now)

{- | The data object for a bookmark event: the fields a webhook consumer
needs to identify the record without a second request. Nothing when the row
is already gone (a delete calls this before removing it).
-}
bookmarkEventData :: Connection -> Int -> IO (Maybe Value)
bookmarkEventData conn bid = do
    rows <-
        query
            conn
            "SELECT url, title, domain, is_read, is_dead FROM bookmarks WHERE id = ?"
            (Only bid) ::
            IO [(Text, Text, Text, Int, Int)]
    case rows of
        [] -> pure Nothing
        ((url, title, domain, isRead, isDead) : _) -> do
            tagRows <-
                query
                    conn
                    "SELECT t.name FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id WHERE bt.bookmark_id = ? ORDER BY t.name"
                    (Only bid) ::
                    IO [Only Text]
            pure (Just (bookmarkValue bid url title domain (isRead /= 0) (isDead /= 0) [name | Only name <- tagRows]))

{- | The data objects for a batch of bookmarks, one query for the rows and one
for the tags per chunk. A delete path calls this before removing the rows. The
result is ordered by id.
-}
bookmarkEventDataMany :: Connection -> [Int] -> IO [Value]
bookmarkEventDataMany _ [] = pure []
bookmarkEventDataMany conn ids = do
    rows <- fetchRows
    tagRows <- fetchTags
    let tagsBy = Map.fromListWith (<>) [(bid, [name]) | (bid, name) <- tagRows]
    pure
        [ bookmarkValue bid url title domain (isRead /= 0) (isDead /= 0) (Map.findWithDefault [] bid tagsBy)
        | (bid, url, title, domain, isRead, isDead) <- sortOn (\(bid, _, _, _, _, _) -> bid) rows
        ]
  where
    chunks = chunksOf idChunkSize (nub ids)
    fetchRows =
        concat
            <$> forM
                chunks
                ( \chunk ->
                    query
                        conn
                        (Query ("SELECT id, url, title, domain, is_read, is_dead FROM bookmarks WHERE id IN (" <> marks chunk <> ")"))
                        chunk ::
                        IO [(Int, Text, Text, Text, Int, Int)]
                )
    fetchTags =
        concat
            <$> forM
                chunks
                ( \chunk ->
                    query
                        conn
                        ( Query
                            ( "SELECT bt.bookmark_id, t.name FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id "
                                <> "WHERE bt.bookmark_id IN ("
                                <> marks chunk
                                <> ") ORDER BY bt.bookmark_id, t.name"
                            )
                        )
                        chunk ::
                        IO [(Int, Text)]
                )
    marks chunk = intercalateComma (replicate (length chunk) "?")
    intercalateComma [] = ""
    intercalateComma [mark] = mark
    intercalateComma (mark : rest) = mark <> "," <> intercalateComma rest

bookmarkValue :: Int -> Text -> Text -> Text -> Bool -> Bool -> [Text] -> Value
bookmarkValue bid url title domain isRead isDead tags =
    object
        [ "id" .= bid
        , "url" .= url
        , "title" .= title
        , "domain" .= domain
        , "is_read" .= isRead
        , "is_dead" .= isDead
        , "tags" .= tags
        ]

-- | Shared chunk size for batched @IN@ queries.
idChunkSize :: Int
idChunkSize = 500

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf size values =
    let (chunk, rest) = splitAt (max 1 size) values
     in chunk : chunksOf size rest

-- | The data object for clip.created.
clipEventData :: Int -> Int -> Value
clipEventData captureId bookmarkId =
    object
        [ "capture_id" .= captureId
        , "bookmark_id" .= bookmarkId
        ]

currentEpoch :: IO Int
currentEpoch = floor <$> getPOSIXTime
