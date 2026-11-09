{-# LANGUAGE OverloadedStrings #-}

{- 'dedupeGroups' is pure: it groups rows by the shared canonical URL key (the
safe duplicates) and, separately, by normalised title on the same source
(advisory only, because different pages can share a title). 'dedupCandidates'
pages those groups and fetches the summaries in bulk, so the cost is one light
scan plus a handful of indexed queries rather than one query per group.

Nothing is ever merged automatically. 'mergeBookmarks' handles one confirmed
group; 'mergeUrlDuplicatesAll' merges every same-URL group in one transaction
behind a single undo snapshot, leaving the advisory title groups for individual
review. Both preserve data from every absorbed row: tags are unioned, notes
appended with a source heading, highlights and wikilinks moved to the keeper,
counters combined and empty keeper metadata filled from the first absorbed row
that has it.
-}

-- | Duplicate detection and the explicit merge actions.
module Eza.Dedup (
    DedupQuery (..),
    defaultDedupQuery,
    GroupIds (..),
    dedupeGroups,
    dedupCandidates,
    mergeBookmarks,
    mergeUrlDuplicatesAll,
) where

import Control.Monad (forM, forM_, when)
import Data.Char (isAlphaNum)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple

import Eza.Events (bookmarkEventData, bookmarkEventDataMany, recordEvent, recordEventMany)
import Eza.Types (BookmarkSummary (..), DedupCounts (..), DedupGroup (..), DedupMergeAllReport (..), DedupReport (..))
import Eza.Undo (recordUndoIds)
import Eza.Url (dedupeKey, domainOf, hostOf)
import Eza.Webhook (EventType (..))

-- ---------------------------------------------------------------------------
-- Detection
-- ---------------------------------------------------------------------------

{- | Pagination for the duplicates view. Limits are clamped to 1..200 when the
report is built; the defaults match the interface's first page.
-}
data DedupQuery = DedupQuery
    { dqUrlOffset :: Int
    , dqUrlLimit :: Int
    , dqTitleOffset :: Int
    , dqTitleLimit :: Int
    }
    deriving (Show, Eq)

defaultDedupQuery :: DedupQuery
defaultDedupQuery = DedupQuery 0 60 0 40

-- | One candidate group before its summaries are loaded.
data GroupIds = GroupIds
    { giKey :: Text
    , giKind :: Text
    , giIds :: [Int]
    }
    deriving (Show, Eq)

{- | Group lightweight rows @(id, url, title, domain)@ into duplicate
candidates. URL groups come first (sorted by key), then advisory
title-on-source groups. Members are sorted by id, so the first member is the
deterministic default keeper.
-}
dedupeGroups :: [(Int, Text, Text, Text)] -> [GroupIds]
dedupeGroups rows =
    let byUrl =
            Map.fromListWith
                (<>)
                [ (dedupeKey url, [(bid, url)])
                | (bid, url, _, _) <- rows
                ]
        urlGroups =
            [ GroupIds key "url" (map fst (sortOn fst items))
            | (key, items) <- Map.toList byUrl
            , length items > 1
            ]
        urlIds = Set.fromList (concatMap giIds urlGroups)
        byTitle =
            Map.fromListWith
                (<>)
                [ ((domainOf (hostOf url), normalizeTitle title), [(bid, url)])
                | (bid, url, title, _) <- rows
                , not (Set.member bid urlIds)
                , let normalized = normalizeTitle title
                , not (T.null normalized)
                ]
        titleGroups =
            [ GroupIds (dom <> ": " <> title) "title" (map fst (sortOn fst items))
            | ((dom, title), items) <- Map.toList byTitle
            , length items > 1
            ]
     in sortOn giKey urlGroups <> sortOn giKey titleGroups

{- | Build the paged duplicate report. Counts always cover the whole library;
only the requested group pages are loaded with summaries.
-}
dedupCandidates :: Connection -> DedupQuery -> IO DedupReport
dedupCandidates conn q = do
    rows <- query_ conn "SELECT id, url, title, domain FROM bookmarks" :: IO [(Int, Text, Text, Text)]
    let groups = dedupeGroups rows
        urlGroups = filter ((== "url") . giKind) groups
        titleGroups = filter ((/= "url") . giKind) groups
        urlPage = pageOf (dqUrlOffset q) (dqUrlLimit q) urlGroups
        titlePage = pageOf (dqTitleOffset q) (dqTitleLimit q) titleGroups
        counts =
            DedupCounts
                { dcUrlGroups = length urlGroups
                , dcUrlRecords = sum (map (length . giIds) urlGroups)
                , dcTitleGroups = length titleGroups
                , dcTitleRecords = sum (map (length . giIds) titleGroups)
                }
    summaries <- fetchSummaries conn (concatMap giIds (urlPage <> titlePage))
    let byId = Map.fromList [(bsId summary, summary) | summary <- summaries]
        toGroup (GroupIds key kind ids) =
            DedupGroup
                { dgKey = key
                , dgKind = kind
                , dgItems = [summary | bid <- ids, Just summary <- [Map.lookup bid byId]]
                }
    pure
        DedupReport
            { drCounts = counts
            , drUrlGroups = map toGroup urlPage
            , drTitleGroups = map toGroup titlePage
            }

pageOf :: Int -> Int -> [a] -> [a]
pageOf offset limit = take (max 1 (min 200 limit)) . drop (max 0 offset)

{- | Load the light summary columns the duplicates view needs (no notes or
extracted text) for the requested ids, chunked to stay well inside SQLite's
variable limit.
-}
fetchSummaries :: Connection -> [Int] -> IO [BookmarkSummary]
fetchSummaries conn ids = do
    chunks <- forM (chunksOf 500 ids) $ \chunk -> do
        rows <-
            query
                conn
                ( Query
                    ( "SELECT id, url, title, domain, favicon_url, created_at, added_at, is_read, is_dead"
                        <> " FROM bookmarks WHERE id IN ("
                        <> marksFor chunk
                        <> ") ORDER BY id"
                    )
                )
                chunk ::
                IO [(Int, Text, Text, Text, Text, Int, Int, Int, Int)]
        tagsById <- tagsForIds conn chunk
        pure
            [ BookmarkSummary
                { bsId = bid
                , bsUrl = url
                , bsTitle = if T.null title then url else title
                , bsDomain = domain
                , bsFaviconUrl = favicon
                , bsCreatedAt = created
                , bsAddedAt = added
                , bsTags = fromMaybe [] (Map.lookup bid tagsById)
                , bsIsRead = isRead /= 0
                , bsIsDead = isDead /= 0
                , bsSnippet = Nothing
                }
            | (bid, url, title, domain, favicon, created, added, isRead, isDead) <- rows
            ]
    pure (concat chunks)

tagsForIds :: Connection -> [Int] -> IO (Map.Map Int [Text])
tagsForIds conn ids = do
    rows <-
        forM (chunksOf 500 ids) $ \chunk ->
            query
                conn
                ( Query
                    ( "SELECT bt.bookmark_id, t.name FROM bookmark_tags bt"
                        <> " JOIN tags t ON t.id = bt.tag_id WHERE bt.bookmark_id IN ("
                        <> marksFor chunk
                        <> ") ORDER BY bt.bookmark_id, t.name"
                    )
                )
                chunk ::
                IO [(Int, Text)]
    pure (foldl' addTag Map.empty (concat rows))
  where
    addTag acc (bid, tag) = Map.insertWith (flip (<>)) bid [tag] acc

normalizeTitle :: Text -> Text
normalizeTitle = T.unwords . T.words . T.toLower . T.map replace
  where
    replace c
        | isAlphaNum c || c == ' ' = c
        | otherwise = ' '

-- ---------------------------------------------------------------------------
-- Single confirmed merge
-- ---------------------------------------------------------------------------

{- | The bookmark columns a merge reads and combines. @id@ is first so the same
row parser works for the keeper and for each absorbed row.
-}
data MergeRow = MergeRow
    { mrTitle :: Text
    , mrDescription :: Text
    , mrExtractedText :: Text
    , mrAuthor :: Text
    , mrSitename :: Text
    , mrPublishedAt :: Maybe Int
    , mrLanguage :: Text
    , mrImageUrl :: Text
    , mrFinalUrl :: Text
    , mrCreatedAt :: Int
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
        MergeRow
            <$> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field

mergeRowColumns :: Text
mergeRowColumns =
    "title,description,extracted_text,author,sitename,published_at,language,image_url,final_url,created_at,added_at,open_count,last_opened_at,last_checked_at,is_read,is_dead,favicon_url,snapshot_path,snapshot_kind,snapshot_captured_at,ai_summary"

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
    let merges = filter (/= keep) mergeIds
    if null merges
        then pure 0
        else withImmediateTransaction conn $ do
            exists <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only keep) :: IO [Only Int]
            case exists of
                [] -> pure 0
                _ -> do
                    found <- existingBookmarkIds conn merges
                    if null found
                        then pure 0
                        else do
                            -- Snapshot first: bookmark rows, tags, highlights and links.
                            _ <- recordUndoIds conn "merge" (keep : found)
                            mergeGroupTx conn keep found False

{- | Fold @merges@ into @keep@ inside the caller's write transaction. The
caller has already recorded the undo snapshot. When @preferHttps@ is set (the
bulk same-URL cleanup) the keeper address is upgraded to the https variant of
the page after the absorbed rows are deleted, so no UNIQUE collision can
occur. Returns the number of absorbed rows.
-}
mergeGroupTx :: Connection -> Int -> [Int] -> Bool -> IO Int
mergeGroupTx conn keep merges preferHttps = do
    let marks = marksFor merges
    noteRows <-
        query
            conn
            (Query ("SELECT id,title,url,note_body FROM bookmarks WHERE id IN (" <> marks <> ") ORDER BY id"))
            merges ::
            IO [NoteRow]
    let found = map nrId noteRows
    if null found
        then pure 0
        else do
            now <- (floor <$> getPOSIXTime) :: IO Int
            -- The deleted events carry the absorbed rows as they are before
            -- the merge touches them; this runs in the caller's transaction.
            deletedData <- bookmarkEventDataMany conn found
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
            -- 4. Notes: keep the keeper note and append every absorbed note under a
            --    heading naming its source, so nothing is dropped.
            keeperNoteRows <-
                query
                    conn
                    "SELECT note_body FROM bookmarks WHERE id = ?"
                    (Only keep) ::
                    IO [Only Text]
            keeperUrlRows <-
                query
                    conn
                    "SELECT url FROM bookmarks WHERE id = ?"
                    (Only keep) ::
                    IO [Only Text]
            keeperRows <-
                query
                    conn
                    (Query ("SELECT " <> mergeRowColumns <> " FROM bookmarks WHERE id = ?"))
                    (Only keep) ::
                    IO [MergeRow]
            case keeperRows of
                [] -> pure 0
                keeper : _ -> do
                    mergedRows <-
                        query
                            conn
                            (Query ("SELECT " <> mergeRowColumns <> " FROM bookmarks WHERE id IN (" <> marks <> ") ORDER BY id"))
                            merges ::
                            IO [MergeRow]
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
                        -- A merged copy that was read makes the keeper read; a dead
                        -- keeper stays dead only when every copy was dead.
                        isRead = if any ((/= 0) . mrIsRead) allRows then (1 :: Int) else 0
                        isDead = if all ((/= 0) . mrIsDead) allRows then (1 :: Int) else 0
                        createdAt = minimum (map mrCreatedAt allRows)
                        addedAt = minimum (map mrAddedAt allRows)
                        capturedAt = firstJust (map mrSnapshotCapturedAt allRows)
                        -- Empty keeper metadata is filled from the first absorbed
                        -- row that has it, so a merge never drops a description,
                        -- extraction text, author, date, language, image or the
                        -- final URL of an absorbed duplicate.
                        firstTitle = firstText (map mrTitle allRows)
                        firstDescription = firstText (map mrDescription allRows)
                        firstExtracted = firstText (map mrExtractedText allRows)
                        firstAuthor = firstText (map mrAuthor allRows)
                        firstSitename = firstText (map mrSitename allRows)
                        firstPublished = firstJust (map mrPublishedAt allRows)
                        firstLanguage = firstText (map mrLanguage allRows)
                        firstImage = firstText (map mrImageUrl allRows)
                        firstFinalUrl = firstText (map mrFinalUrl allRows)
                    executeNamed
                        conn
                        "UPDATE bookmarks SET title = CASE WHEN trim(title) = '' THEN :title ELSE title END, description = CASE WHEN trim(description) = '' THEN :description ELSE description END, extracted_text = CASE WHEN trim(extracted_text) = '' THEN :extracted_text ELSE extracted_text END, author = CASE WHEN trim(author) = '' THEN :author ELSE author END, sitename = CASE WHEN trim(sitename) = '' THEN :sitename ELSE sitename END, published_at = CASE WHEN published_at IS NULL THEN :published ELSE published_at END, language = CASE WHEN trim(language) = '' THEN :language ELSE language END, image_url = CASE WHEN trim(image_url) = '' THEN :image ELSE image_url END, final_url = CASE WHEN trim(final_url) = '' THEN :final_url ELSE final_url END, note_body = :note, open_count = :open_count, last_opened_at = :last_opened, last_checked_at = :last_checked, is_read = :is_read, is_dead = :is_dead, created_at = :created, added_at = :added, favicon_url = :favicon, snapshot_path = :snapshot_path, snapshot_kind = :snapshot_kind, snapshot_captured_at = :snapshot_captured, ai_summary = :ai_summary, updated_at = :updated WHERE id = :keep"
                        [ ":title" := firstTitle
                        , ":description" := firstDescription
                        , ":extracted_text" := firstExtracted
                        , ":author" := firstAuthor
                        , ":sitename" := firstSitename
                        , ":published" := firstPublished
                        , ":language" := firstLanguage
                        , ":image" := firstImage
                        , ":final_url" := firstFinalUrl
                        , ":note" := mergedNote
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
                    when preferHttps $
                        upgradeKeeperUrl conn keep now (keeperUrlRows, noteRows)
                    -- Extension outbox: the keeper's post-merge state and the
                    -- absorbed rows that this transaction removed.
                    keeperData <- bookmarkEventData conn keep
                    forM_ keeperData $ \value -> recordEvent conn BookmarkUpdated value
                    recordEventMany conn BookmarkDeleted deletedData
                    pure (length found)

{- | Upgrade an http keeper to the https address of the same page once the
absorbed rows are gone. @keeperUrlRows@ is the keeper's stored address and
@noteRows@ carries the absorbed addresses.
-}
upgradeKeeperUrl :: Connection -> Int -> Int -> ([Only Text], [NoteRow]) -> IO ()
upgradeKeeperUrl conn keep now (keeperUrlRows, noteRows) = do
    let keeperUrl = case keeperUrlRows of
            (Only u : _) -> T.strip u
            _ -> ""
        httpsCandidate =
            case [T.strip (nrUrl r) | r <- noteRows, "https://" `T.isPrefixOf` T.strip (nrUrl r)] of
                (url : _) -> Just url
                [] -> Nothing
    case httpsCandidate of
        Just newUrl
            | "http://" `T.isPrefixOf` keeperUrl ->
                execute conn "UPDATE bookmarks SET url = ?, updated_at = ? WHERE id = ?" (newUrl, now, keep)
        _ -> pure ()

-- ---------------------------------------------------------------------------
-- Confirmed merge of every same-URL duplicate group
-- ---------------------------------------------------------------------------

{- | Merge every canonical-URL duplicate group at once. The advisory
title-on-source groups are intentionally not touched: different pages can
share a title. One undo snapshot covers every keeper and absorbed row, so a
single undo restores the whole operation.
-}
mergeUrlDuplicatesAll :: Connection -> IO DedupMergeAllReport
mergeUrlDuplicatesAll conn = do
    start <- getPOSIXTime
    withImmediateTransaction conn $ do
        rows <- query_ conn "SELECT id, url, title, domain FROM bookmarks" :: IO [(Int, Text, Text, Text)]
        let groups = [group | group <- dedupeGroups rows, giKind group == "url"]
            plans = mapMaybe planGroup groups
            records = sum (map (length . giIds) groups)
            affected = dedupeIds (concat [keeper : absorbs | (keeper, absorbs) <- plans])
        if null plans
            then
                pure
                    DedupMergeAllReport
                        { dmGroups = 0
                        , dmRecords = 0
                        , dmAffected = 0
                        , dmSnapshotId = 0
                        , dmElapsedMs = 0
                        }
            else do
                snapshotId <- recordUndoIds conn "merge_all" affected
                forM_ plans $ \(keeper, absorbs) -> mergeGroupTx conn keeper absorbs True
                end <- getPOSIXTime
                pure
                    DedupMergeAllReport
                        { dmGroups = length plans
                        , dmRecords = records
                        , dmAffected = length affected
                        , dmSnapshotId = snapshotId
                        , dmElapsedMs = floor ((end - start) * 1000)
                        }
  where
    planGroup group = case sortOn id (giIds group) of
        [] -> Nothing
        (keeper : absorbs) -> Just (keeper, absorbs)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

existingBookmarkIds :: Connection -> [Int] -> IO [Int]
existingBookmarkIds _ [] = pure []
existingBookmarkIds conn ids = do
    rows <-
        query
            conn
            (Query ("SELECT id FROM bookmarks WHERE id IN (" <> marksFor uniqueIds <> ") ORDER BY id"))
            uniqueIds ::
            IO [Only Int]
    pure [bid | Only bid <- rows]
  where
    uniqueIds = dedupeIds ids

dedupeIds :: [Int] -> [Int]
dedupeIds = go Set.empty
  where
    go _ [] = []
    go seen (x : rest)
        | x <= 0 = go seen rest
        | Set.member x seen = go seen rest
        | otherwise = x : go (Set.insert x seen) rest

marksFor :: [Int] -> Text
marksFor values = T.intercalate "," (replicate (length values) "?")

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = take n xs : chunksOf n (drop n xs)

{- | Append notes with a blank line between blocks. Empty notes are skipped and
a note identical to the keeper body is not duplicated.
-}
appendNotes :: Text -> [Text] -> Text
appendNotes base extras =
    let baseTrim = T.strip base
        kept = [T.strip e | e <- extras, not (T.null (T.strip e)), T.strip e /= baseTrim]
     in T.intercalate "\n\n" ([baseTrim | not (T.null baseTrim)] <> kept)

{- | One appended note, headed by its source record so the merged text stays
attributable.
-}
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
