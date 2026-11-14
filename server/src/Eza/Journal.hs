{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The append-only change journal that replaces the per-feature undo side
tables (schema v17).

Every mutating operation records one @journal@ row (op, label, created_at) and
the before-images of the rows it is about to change in @journal_rows@ as JSON
objects keyed by column name. The journal keeps the newest 'journalLimit'
changes; older entries are pruned as new ones are recorded.

Restore is newest-first only and runs inside the caller's transaction. A
bookmark before-image is restored by id when its URL is unchanged, inserted
when neither its id nor its URL is taken, and skipped (counted, never written
over) when its URL was re-used by a newer row. Child rows are removed for the
bookmarks that are actually restored and then put back from their before-image;
the FTS index is rebuilt after a bookmark restore so no stale search terms
survive.
-}
module Eza.Journal (
    Change (..),
    ChangeCounts (..),
    changeCounts,
    changeSamples,
    journalLimit,
    cleanupUnusableChanges,
    findChange,
    listChanges,
    newestUsableChange,
    recordBookmarks,
    recordTags,
    restoreChange,
) where

import Control.Monad (forM_, unless, when)
import Data.Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Bifunctor (first)
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple

-- | How many changes the journal retains.
journalLimit :: Int
journalLimit = 100

-- | Look one journal entry up by id.
findChange :: Connection -> Int -> IO (Maybe Change)
findChange conn changeId = do
    rows <-
        query
            conn
            "SELECT id, op, label, created_at FROM journal WHERE id = ?"
            (Only changeId) ::
            IO [(Int, Text, Text, Int)]
    pure (case rows of [row] -> Just (toChange row); _ -> Nothing)

-- | One journal entry, without its before-images.
data Change = Change
    { chId :: Int
    , chOp :: Text
    , chLabel :: Text
    , chCreatedAt :: Int
    }
    deriving (Show, Eq)

-- | Per-table row counts of one change, used by the undo API's DTO.
data ChangeCounts = ChangeCounts
    { ccBookmarks :: Int
    , ccTagNames :: Int
    , ccHighlights :: Int
    , ccLinks :: Int
    , ccCaptures :: Int
    , ccDeadOverrides :: Int
    }
    deriving (Show, Eq)

-- ---------------------------------------------------------------- records ---

{- | Capture the before-images of the given bookmarks and everything a delete,
prune, bulk change, or merge can cascade away: the full bookmark rows, tag
names, highlights, wikilinks, captures, and dead-link overrides. Returns the
new change id (0 when there is nothing to record). Must run inside the caller's
write transaction, before the rows are changed.
-}
recordBookmarks :: Connection -> Text -> [Int] -> IO Int
recordBookmarks conn op ids = do
    let uniqueIds = dedupeIds ids
    if null uniqueIds
        then pure 0
        else do
            changeId <- insertChange conn op
            let list = intList uniqueIds
            capture conn changeId bookmarkSpec ("id IN (" <> list <> ")")
            capture conn changeId bookmarkTagSpec ("bt.bookmark_id IN (" <> list <> ")")
            capture conn changeId highlightSpec ("bookmark_id IN (" <> list <> ")")
            capture conn changeId linkSpec ("source_id IN (" <> list <> ") OR target_id IN (" <> list <> ")")
            capture conn changeId captureSpec ("bookmark_id IN (" <> list <> ")")
            capture conn changeId deadOverrideSpec ("bookmark_id IN (" <> list <> ")")
            pruneJournal conn
            pure changeId

{- | Capture the before-images for a tag operation. Every affected name is
recorded in the @tags@ journal table: the existing row when there is one, or
just the name with @present=false@ so restore can delete a name the operation
creates (a merge target, a rename target). The links of those names are kept as
@bookmark_tags@ before-images. Must run inside the caller's write transaction.
-}
recordTags :: Connection -> Text -> [Text] -> IO Int
recordTags conn op names = do
    let uniqueNames = dedupeNames names
    if null uniqueNames
        then pure 0
        else do
            changeId <- insertChange conn op
            existing <- tagRowsFor conn uniqueNames
            forM_ existing $ \(tagId, name, createdAt) ->
                insertRow conn changeId "tags" name (jsonTag tagId name createdAt True)
            let presentNames = [name | (_, name, _) <- existing]
            forM_ (filter (`notElem` presentNames) uniqueNames) $ \name ->
                insertRow conn changeId "tags" name (jsonTagAbsent name)
            capture conn changeId tagLinkSpec ("t.name IN (" <> textList uniqueNames <> ")")
            pruneJournal conn
            pure changeId

distinctTagNames :: Connection -> Int -> IO Int
distinctTagNames conn changeId = do
    rows <-
        query
            conn
            "SELECT COUNT(DISTINCT json_extract(before_json, '$.tag_name')) FROM journal_rows WHERE change_id = ? AND table_name = 'bookmark_tags'"
            (Only changeId) ::
            IO [Only Int]
    pure (case rows of [Only value] -> value; _ -> 0)

-- -------------------------------------------------------------- summaries ---

listChanges :: Connection -> Int -> IO [Change]
listChanges conn limit = do
    rows <-
        query
            conn
            "SELECT id, op, label, created_at FROM journal ORDER BY id DESC LIMIT ?"
            (Only (max 1 limit)) ::
            IO [(Int, Text, Text, Int)]
    pure [Change changeId op label createdAt | (changeId, op, label, createdAt) <- rows]

{- | Discard entries whose before-images are all unreadable so they can never
block the undo stack.
-}
cleanupUnusableChanges :: Connection -> IO ()
cleanupUnusableChanges conn = do
    entries <- allChanges conn
    forM_ entries $ \row -> do
        usable <- changeUsable conn (fst4 row)
        unless usable (deleteChange conn (fst4 row))
  where
    fst4 (value, _, _, _) = value

{- | The newest change that can still restore something. A journal entry whose
before-images are all unreadable is pruned rather than blocking the stack.
-}
newestUsableChange :: Connection -> IO (Maybe Change)
newestUsableChange conn = go . map toChange =<< allChanges conn
  where
    go [] = pure Nothing
    go (change : rest) = do
        usable <- changeUsable conn (chId change)
        if usable then pure (Just change) else go rest

allChanges :: Connection -> IO [(Int, Text, Text, Int)]
allChanges conn =
    query_ conn "SELECT id, op, label, created_at FROM journal ORDER BY id DESC" ::
        IO [(Int, Text, Text, Int)]

toChange :: (Int, Text, Text, Int) -> Change
toChange (changeId, op, label, createdAt) = Change changeId op label createdAt

changeCounts :: Connection -> Int -> IO ChangeCounts
changeCounts conn changeId = do
    rows <-
        query
            conn
            "SELECT table_name, COUNT(*) FROM journal_rows WHERE change_id = ? GROUP BY table_name"
            (Only changeId) ::
            IO [(Text, Int)]
    linkedNames <- distinctTagNames conn changeId
    let count name = fromMaybe 0 (lookup name rows)
    pure
        ChangeCounts
            { ccBookmarks = count "bookmarks"
            , ccTagNames = max (count "tags") linkedNames
            , ccHighlights = count "highlights"
            , ccLinks = count "links"
            , ccCaptures = count "captures"
            , ccDeadOverrides = count "bookmark_dead_overrides"
            }

{- | Up to @limit@ bookmark references and tag names for the confirmation
preview. Bookmarks that were deleted still come from their own before-image;
for a tag-only change the current bookmark rows named by the captured tag links
are used.
-}
changeSamples :: Connection -> Int -> Int -> IO ([Value], [Text])
changeSamples conn changeId limit = do
    bookmarkRows <- bookmarkSamples conn changeId limit
    tags <- tagNameSamples conn changeId limit
    pure (bookmarkRows, tags)

bookmarkSamples :: Connection -> Int -> Int -> IO [Value]
bookmarkSamples conn changeId limit = do
    own <- mapMaybe bookmarkRefRows <$> rowsFor conn changeId "bookmarks"
    if not (null own)
        then pure (take limit own)
        else do
            ids <- tagBookmarkIds conn changeId limit
            case ids of
                [] -> pure []
                _ -> do
                    rows <-
                        query_
                            conn
                            ( Query
                                ( "SELECT id, title, url, domain FROM bookmarks WHERE id IN ("
                                    <> intList ids
                                    <> ") ORDER BY id LIMIT "
                                    <> T.pack (show limit)
                                )
                            ) ::
                            IO [(Int, Text, Text, Text)]
                    pure [object ["id" .= bid, "title" .= title, "url" .= url, "domain" .= domain] | (bid, title, url, domain) <- rows]

tagNameSamples :: Connection -> Int -> Int -> IO [Text]
tagNameSamples conn changeId limit = do
    stored <- rowsFor conn changeId "tags"
    let names = mapMaybe tagNameOf stored
    linked <- mapMaybe tagNameOfLinked <$> rowsFor conn changeId "bookmark_tags"
    pure (take limit (stableNub (names <> linked)))
  where
    tagNameOf raw = case jsonObject raw of
        Just value -> case KeyMap.lookup "name" value of
            Just (String name) -> Just name
            _ -> Nothing
        Nothing -> Nothing
    tagNameOfLinked raw = case jsonObject raw of
        Just value -> case KeyMap.lookup "tag_name" value of
            Just (String name) -> Just name
            _ -> Nothing
        Nothing -> Nothing

tagBookmarkIds :: Connection -> Int -> Int -> IO [Int]
tagBookmarkIds conn changeId limit = do
    rows <- rowsFor conn changeId "bookmark_tags"
    pure (take limit (mapMaybe bookmarkIdOf rows))
  where
    bookmarkIdOf raw = case jsonObject raw of
        Just value -> jsonInt (KeyMap.lookup "bookmark_id" value)
        Nothing -> Nothing

-- ---------------------------------------------------------------- restore ---

{- | Restore one change. Returns (rows restored, bookmark rows skipped because
their URL belongs to a newer row) and deletes the consumed change. The caller
wraps this in the write transaction; a failure leaves the library untouched.
-}
restoreChange :: Connection -> Int -> IO (Int, Int)
restoreChange conn changeId = do
    rows <- rowsFor conn changeId "bookmarks"
    tagRows <- rowsFor conn changeId "tags"
    (restoredIds, skipped) <- restoreBookmarks conn rows
    when (not (null restoredIds)) (deleteRestoredChildren conn restoredIds)
    restoreTags conn tagRows
    restoreBookmarkTags conn changeId restoredIds
    restoreHighlights conn changeId restoredIds
    restoreLinks conn changeId restoredIds
    restoreCaptures conn changeId restoredIds
    restoreDeadOverrides conn changeId restoredIds
    when (not (null restoredIds)) (rebuildFts conn)
    deleteChange conn changeId
    let restored
            | not (null rows) = length restoredIds
            | otherwise = length tagRows
    pure (restored, skipped)

restoreBookmarks :: Connection -> [Text] -> IO ([Int], Int)
restoreBookmarks conn = go ([], 0)
  where
    go state [] = pure state
    go state (raw : rest) = case bookmarkImage raw of
        Nothing -> go state rest
        Just (bookmarkId, url) -> do
            restored <- canRestoreBookmark conn bookmarkId url
            if restored
                then do
                    upsertBookmarkImage conn bookmarkId raw
                    go (first (bookmarkId :) state) rest
                else go (fst state, snd state + 1) rest

canRestoreBookmark :: Connection -> Int -> Text -> IO Bool
canRestoreBookmark conn bookmarkId url = do
    byId <- query conn "SELECT url FROM bookmarks WHERE id = ?" (Only bookmarkId) :: IO [Only Text]
    case byId of
        (Only currentUrl : _) -> do
            owner <- urlOwner conn url bookmarkId
            pure (currentUrl == url || owner == Nothing)
        [] -> do
            owner <- urlOwner conn url bookmarkId
            pure (owner == Nothing)

urlOwner :: Connection -> Text -> Int -> IO (Maybe Int)
urlOwner conn url bookmarkId = do
    rows <- query conn "SELECT id FROM bookmarks WHERE url = ? AND id <> ?" (url, bookmarkId) :: IO [Only Int]
    pure (case rows of [Only owner] -> Just owner; _ -> Nothing)

upsertBookmarkImage :: Connection -> Int -> Text -> IO ()
upsertBookmarkImage conn bookmarkId raw = do
    exists <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only bookmarkId) :: IO [Only Int]
    if null exists
        then executeJsonInsert conn "bookmarks" bookmarkColumns raw
        else executeJsonUpdate conn "bookmarks" bookmarkColumns "id" bookmarkId raw

deleteRestoredChildren :: Connection -> [Int] -> IO ()
deleteRestoredChildren conn ids = do
    let list = intList ids
    execute_ conn (Query ("DELETE FROM bookmark_tags WHERE bookmark_id IN (" <> list <> ")"))
    execute_ conn (Query ("DELETE FROM highlights WHERE bookmark_id IN (" <> list <> ")"))
    execute_ conn (Query ("DELETE FROM bookmark_dead_overrides WHERE bookmark_id IN (" <> list <> ")"))
    execute_ conn (Query ("DELETE FROM captures WHERE bookmark_id IN (" <> list <> ")"))
    execute_ conn (Query ("DELETE FROM links WHERE source_id IN (" <> list <> ") OR target_id IN (" <> list <> ")"))

{- | Restore the recorded tag rows first: every name the operation touched is
removed (that is how a merge/rename target disappears again) and the tag rows
that existed before are put back. Links are re-created afterwards by name.
-}
restoreTags :: Connection -> [Text] -> IO ()
restoreTags conn tagRows = do
    let names = mapMaybe tagImageName tagRows
    unless (null names) $ do
        let list = textList names
        execute_ conn (Query ("DELETE FROM bookmark_tags WHERE tag_id IN (SELECT id FROM tags WHERE name IN (" <> list <> "))"))
        execute_ conn (Query ("DELETE FROM tags WHERE name IN (" <> list <> ")"))
        forM_ tagRows $ \raw -> case (jsonObject raw, tagImageId raw) of
            (Just value, Just tagId)
                | KeyMap.lookup "present" value == Just (Bool True) -> do
                    let createdAt = fromMaybe 0 (jsonInt (KeyMap.lookup "created_at" value))
                    idTaken <- query conn "SELECT 1 FROM tags WHERE id = ?" (Only tagId) :: IO [Only Int]
                    if null idTaken
                        then execute conn "INSERT INTO tags (id,name,created_at) VALUES (?,?,?)" (tagId, tagImageName raw, createdAt)
                        else execute conn "INSERT INTO tags (name,created_at) VALUES (?,?)" (tagImageName raw, createdAt)
            _ -> pure ()
  where
    tagImageId raw = case jsonObject raw of
        Just value -> jsonInt (KeyMap.lookup "id" value)
        Nothing -> Nothing

restoreBookmarkTags :: Connection -> Int -> [Int] -> IO ()
restoreBookmarkTags conn changeId restoredIds = do
    rows <- rowsFor conn changeId "bookmark_tags"
    forM_ rows $ \raw -> case bookmarkTagImage raw of
        Nothing -> pure ()
        Just (bookmarkId, tagName) -> do
            parent <- bookmarkExists conn bookmarkId
            when (parent && (null restoredIds || bookmarkId `elem` restoredIds)) $ do
                execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, strftime('%s','now'))" (Only tagName)
                tagIds <- query conn "SELECT id FROM tags WHERE name = ?" (Only tagName) :: IO [Only Int]
                case tagIds of
                    (Only tagId : _) ->
                        execute conn "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?,?)" (bookmarkId, tagId)
                    _ -> pure ()

restoreHighlights :: Connection -> Int -> [Int] -> IO ()
restoreHighlights conn changeId restoredIds = do
    rows <- rowsFor conn changeId "highlights"
    forM_ rows $ \raw -> case bookmarkIdOfImage raw of
        Nothing -> pure ()
        Just bookmarkId -> do
            parent <- bookmarkExists conn bookmarkId
            when (parent && (null restoredIds || bookmarkId `elem` restoredIds)) $
                executeJsonReplace conn "highlights" highlightColumns raw

restoreLinks :: Connection -> Int -> [Int] -> IO ()
restoreLinks conn changeId restoredIds = do
    rows <- rowsFor conn changeId "links"
    forM_ rows $ \raw -> case jsonObject raw of
        Nothing -> pure ()
        Just value -> do
            let source = jsonInt (KeyMap.lookup "source_id" value)
            let target = jsonInt (KeyMap.lookup "target_id" value)
            sourceOk <- maybe (pure True) (bookmarkExists conn) source
            targetOk <- maybe (pure True) (bookmarkExists conn) target
            let touched = maybe True (`elem` restoredIds) source || maybe True (`elem` restoredIds) target
            when (sourceOk && targetOk && (null restoredIds || touched)) $
                executeJsonReplace conn "links" linkColumns raw

restoreCaptures :: Connection -> Int -> [Int] -> IO ()
restoreCaptures conn changeId restoredIds = do
    rows <- rowsFor conn changeId "captures"
    forM_ rows $ \raw -> case bookmarkIdOfImage raw of
        Nothing -> pure ()
        Just bookmarkId -> do
            parent <- bookmarkExists conn bookmarkId
            when (parent && (null restoredIds || bookmarkId `elem` restoredIds)) $
                executeJsonReplace conn "captures" captureColumns raw

restoreDeadOverrides :: Connection -> Int -> [Int] -> IO ()
restoreDeadOverrides conn changeId restoredIds = do
    rows <- rowsFor conn changeId "bookmark_dead_overrides"
    forM_ rows $ \raw -> case bookmarkIdOfImage raw of
        Nothing -> pure ()
        Just bookmarkId -> do
            parent <- bookmarkExists conn bookmarkId
            when (parent && (null restoredIds || bookmarkId `elem` restoredIds)) $
                executeJsonReplace conn "bookmark_dead_overrides" deadOverrideColumns raw

rebuildFts :: Connection -> IO ()
rebuildFts conn =
    execute_ conn "INSERT INTO bookmarks_fts(bookmarks_fts) VALUES('rebuild')"

-- -------------------------------------------------------------- primitives ---

data TableSpec = TableSpec
    { specTable :: Text
    , specFrom :: Text
    , specRowKey :: Text
    , specJsonArgs :: Text
    }

bookmarkSpec :: TableSpec
bookmarkSpec = spec "bookmarks" "bookmarks" "CAST(id AS TEXT)" bookmarkColumns

bookmarkTagSpec :: TableSpec
bookmarkTagSpec =
    TableSpec
        { specTable = "bookmark_tags"
        , specFrom = "bookmark_tags bt JOIN tags t ON t.id = bt.tag_id"
        , specRowKey = "bt.bookmark_id || ':' || t.name"
        , specJsonArgs = "json_object('bookmark_id', bt.bookmark_id, 'tag_name', t.name)"
        }

highlightSpec :: TableSpec
highlightSpec = spec "highlights" "highlights" "CAST(id AS TEXT)" highlightColumns

linkSpec :: TableSpec
linkSpec = spec "links" "links" "CAST(id AS TEXT)" linkColumns

captureSpec :: TableSpec
captureSpec = spec "captures" "captures" "CAST(id AS TEXT)" captureColumns

deadOverrideSpec :: TableSpec
deadOverrideSpec = spec "bookmark_dead_overrides" "bookmark_dead_overrides" "CAST(bookmark_id AS TEXT)" deadOverrideColumns

tagLinkSpec :: TableSpec
tagLinkSpec =
    TableSpec
        { specTable = "bookmark_tags"
        , specFrom = "bookmark_tags bt JOIN tags t ON t.id = bt.tag_id"
        , specRowKey = "bt.bookmark_id || ':' || t.name"
        , specJsonArgs = "json_object('bookmark_id', bt.bookmark_id, 'tag_name', t.name)"
        }

spec :: Text -> Text -> Text -> Text -> TableSpec
spec table from rowKey columns =
    TableSpec
        { specTable = table
        , specFrom = from
        , specRowKey = rowKey
        , specJsonArgs = jsonObjectArgs columns
        }

capture :: Connection -> Int -> TableSpec -> Text -> IO ()
capture conn changeId tableSpec whereSql = do
    rows <-
        query_
            conn
            ( Query
                ( "SELECT "
                    <> specRowKey tableSpec
                    <> ", "
                    <> specJsonArgs tableSpec
                    <> " FROM "
                    <> specFrom tableSpec
                    <> " WHERE "
                    <> whereSql
                )
            ) ::
            IO [(Text, Text)]
    forM_ rows $ \(rowKey, raw) -> insertRow conn changeId (specTable tableSpec) rowKey raw

insertChange :: Connection -> Text -> IO Int
insertChange conn op = do
    now <- epoch
    execute conn "INSERT INTO journal (op, created_at, label) VALUES (?,?,?)" (op, now, op)
    fromIntegral <$> lastInsertRowId conn

insertRow :: Connection -> Int -> Text -> Text -> Text -> IO ()
insertRow conn changeId table rowKey raw =
    execute
        conn
        "INSERT OR REPLACE INTO journal_rows (change_id, table_name, row_key, before_json) VALUES (?,?,?,?)"
        (changeId, table, rowKey, raw)

deleteChange :: Connection -> Int -> IO ()
deleteChange conn changeId =
    execute conn "DELETE FROM journal WHERE id = ?" (Only changeId)

rowsFor :: Connection -> Int -> Text -> IO [Text]
rowsFor conn changeId table =
    map fromOnly <$> (query conn "SELECT before_json FROM journal_rows WHERE change_id = ? AND table_name = ? ORDER BY rowid" (changeId, table) :: IO [Only Text])
  where
    fromOnly (Only raw) = raw

changeUsable :: Connection -> Int -> IO Bool
changeUsable conn changeId = do
    rows <- query conn "SELECT before_json FROM journal_rows WHERE change_id = ?" (Only changeId) :: IO [Only Text]
    pure (any (isJustObject . fromOnly) rows)
  where
    fromOnly (Only raw) = raw

isJustObject :: Text -> Bool
isJustObject raw = case decode (LBS.fromStrict (TE.encodeUtf8 raw)) of
    Just (Object _) -> True
    _ -> False

pruneJournal :: Connection -> IO ()
pruneJournal conn =
    execute_
        conn
        ( Query
            ( "DELETE FROM journal WHERE id NOT IN (SELECT id FROM journal ORDER BY id DESC LIMIT "
                <> T.pack (show journalLimit)
                <> ")"
            )
        )

tagRowsFor :: Connection -> [Text] -> IO [(Int, Text, Int)]
tagRowsFor conn names =
    query_
        conn
        ( Query
            ( "SELECT id, name, created_at FROM tags WHERE name IN ("
                <> textList names
                <> ") ORDER BY name"
            )
        ) ::
        IO [(Int, Text, Int)]

textList :: [Text] -> Text
textList values = T.intercalate "," (map quoted values)
  where
    quoted value = "'" <> T.replace "'" "''" value <> "'"

intList :: [Int] -> Text
intList = T.intercalate "," . map (T.pack . show)

jsonObjectArgs :: Text -> Text
jsonObjectArgs columns =
    "json_object("
        <> T.intercalate ", " [quotedText column <> ", " <> column | column <- T.splitOn "," columns]
        <> ")"
  where
    quotedText column = "'" <> T.replace "'" "''" column <> "'"

jsonTag :: Int -> Text -> Int -> Bool -> Text
jsonTag tagId name createdAt present =
    TE.decodeUtf8 (LBS.toStrict (encode (object ["id" .= tagId, "name" .= name, "created_at" .= createdAt, "present" .= present])))

jsonTagAbsent :: Text -> Text
jsonTagAbsent name =
    TE.decodeUtf8 (LBS.toStrict (encode (object ["name" .= name, "present" .= False])))

bookmarkIdOfImage :: Text -> Maybe Int
bookmarkIdOfImage raw = case jsonObject raw of
    Just value -> jsonInt (KeyMap.lookup "bookmark_id" value)
    Nothing -> Nothing

bookmarkImage :: Text -> Maybe (Int, Text)
bookmarkImage raw = do
    value <- jsonObject raw
    bookmarkId <- jsonInt (KeyMap.lookup "id" value)
    url <- case KeyMap.lookup "url" value of
        Just (String text) -> Just text
        _ -> Nothing
    pure (bookmarkId, url)

bookmarkRefRows :: Text -> Maybe Value
bookmarkRefRows raw = do
    value <- jsonObject raw
    bookmarkId <- jsonInt (KeyMap.lookup "id" value)
    let text name = case KeyMap.lookup name value of
            Just (String textValue) -> textValue
            _ -> ""
    pure
        ( object
            [ "id" .= bookmarkId
            , "title" .= text "title"
            , "url" .= text "url"
            , "domain" .= text "domain"
            ]
        )

tagImageName :: Text -> Maybe Text
tagImageName raw = do
    value <- jsonObject raw
    case KeyMap.lookup "name" value of
        Just (String name) -> Just name
        _ -> Nothing

bookmarkTagImage :: Text -> Maybe (Int, Text)
bookmarkTagImage raw = do
    value <- jsonObject raw
    bookmarkId <- jsonInt (KeyMap.lookup "bookmark_id" value)
    tagName <- case KeyMap.lookup "tag_name" value of
        Just (String name) -> Just name
        _ -> Nothing
    pure (bookmarkId, tagName)

jsonObject :: Text -> Maybe Object
jsonObject raw = case decode (LBS.fromStrict (TE.encodeUtf8 raw)) of
    Just (Object value) -> Just value
    _ -> Nothing

jsonInt :: Maybe Value -> Maybe Int
jsonInt (Just (Number number)) = Just (truncate number)
jsonInt _ = Nothing

bookmarkExists :: Connection -> Int -> IO Bool
bookmarkExists conn bookmarkId = do
    rows <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only bookmarkId) :: IO [Only Int]
    pure (not (null rows))

executeJsonInsert :: Connection -> Text -> Text -> Text -> IO ()
executeJsonInsert conn table columns raw =
    executeNamed
        conn
        (Query ("INSERT INTO " <> table <> " (" <> columns <> ") SELECT " <> jsonSelect columns))
        [":json" := raw]

executeJsonUpdate :: Connection -> Text -> Text -> Text -> Int -> Text -> IO ()
executeJsonUpdate conn table columns keyColumn keyValue raw =
    executeNamed
        conn
        ( Query
            ( "UPDATE "
                <> table
                <> " SET "
                <> T.intercalate ", " [column <> " = json_extract(:json, '$." <> column <> "')" | column <- T.splitOn "," columns, column /= keyColumn]
                <> " WHERE "
                <> keyColumn
                <> " = "
                <> T.pack (show keyValue)
            )
        )
        [":json" := raw]

executeJsonReplace :: Connection -> Text -> Text -> Text -> IO ()
executeJsonReplace conn table columns raw =
    executeNamed
        conn
        (Query ("INSERT OR REPLACE INTO " <> table <> " (" <> columns <> ") SELECT " <> jsonSelect columns))
        [":json" := raw]

jsonSelect :: Text -> Text
jsonSelect columns =
    T.intercalate
        ", "
        [ "json_extract(:json, '$." <> column <> "')"
        | column <- T.splitOn "," columns
        ]

bookmarkColumns :: Text
bookmarkColumns =
    "id,url,title,description,favicon_url,domain,source,created_at,added_at,updated_at,last_opened_at,last_checked_at,open_count,is_dead,is_read,note_body,extracted_text,author,sitename,published_at,language,image_url,final_url,snapshot_path,snapshot_kind,snapshot_captured_at,enrich_state,enrich_error,enrich_attempts,enriched_at,reading_time_minutes,ai_summary,ai_tagged_at"

highlightColumns :: Text
highlightColumns =
    "id,bookmark_id,quote,prefix,suffix,start_offset,end_offset,note,color,created_at,updated_at"

linkColumns :: Text
linkColumns = "id,source_id,target_id,target_title,display_text,line_number"

captureColumns :: Text
captureColumns =
    "id,bookmark_id,url,canonical_url,title,author,site,description,published,language,image_url,favicon_url,content_markdown,rendered_markdown,content_text,content_html,selection,tags,template_id,template_name,source,client,idempotency_key,request_hash,extractor,extractor_version,metadata_json,word_count,parse_time_ms,captured_at,created_at"

deadOverrideColumns :: Text
deadOverrideColumns = "bookmark_id,reason,created_at,updated_at"

stableNub :: [Text] -> [Text]
stableNub = go []
  where
    go _ [] = []
    go seen (value : rest)
        | value `elem` seen = go seen rest
        | otherwise = value : go (value : seen) rest

dedupeIds :: [Int] -> [Int]
dedupeIds = go []
  where
    go _ [] = []
    go seen (value : rest)
        | value <= 0 || value `elem` seen = go seen rest
        | otherwise = value : go (value : seen) rest

dedupeNames :: [Text] -> [Text]
dedupeNames = go []
  where
    go _ [] = []
    go seen (name : rest) =
        let clean = T.toLower (T.strip name)
         in if T.null clean || clean `elem` seen then go seen rest else clean : go (clean : seen) rest

epoch :: IO Int
epoch = floor <$> getPOSIXTime
