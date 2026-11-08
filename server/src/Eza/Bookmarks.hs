{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Bookmark/tag/search queries.
module Eza.Bookmarks (
    ListQuery (..),
    defaultListQuery,
    listBookmarks,
    getBookmark,
    allTags,
    insertBookmark,
    findBookmarkIdByUrl,
    quickSave,
    updateBookmark,
    addTagsToBookmark,
    deleteBookmark,
    BulkAction (..),
    bulkUpdate,
    markAllAbove,
    recordOpen,
    autocomplete,
    getBacklinks,
    pruneCandidates,
    pruneApply,
    bookmarksByIds,
    backfillDomains,
    bookmarkStats,
    libraryStats,
) where

import Control.Monad (forM, forM_)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple

import Eza.Links (syncLinks)
import Eza.Rules (applyRules)
import Eza.SearchQuery
import Eza.Types
import Eza.Undo (recordUndoIds)
import Eza.Url (hostOf, normalizeUrl)

data ListQuery = ListQuery
    { lqQ :: Text
    , lqTags :: [Text]
    , lqIsRead :: Maybe Bool
    , lqIsDead :: Maybe Bool
    , lqSort :: Text
    , lqOffset :: Int
    , lqLimit :: Int
    }
    deriving (Show, Eq)

defaultListQuery :: ListQuery
defaultListQuery = ListQuery "" [] Nothing Nothing "created" 0 60

data SummaryRow = SummaryRow
    { srId :: Int
    , srUrl :: Text
    , srTitle :: Text
    , srDescription :: Text
    , srDomain :: Text
    , srFaviconUrl :: Text
    , srCreatedAt :: Int
    , srAddedAt :: Int
    , srIsRead :: Int
    , srIsDead :: Int
    , srNoteBody :: Text
    , srExtractedText :: Text
    }

instance FromRow SummaryRow where
    fromRow =
        SummaryRow
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

summaryColumns :: Text
summaryColumns =
    "b.id, b.url, b.title, b.description, b.domain, b.favicon_url, b.created_at, b.added_at, b.is_read, b.is_dead, b.note_body, b.extracted_text"

listBookmarks :: Connection -> ListQuery -> IO SearchPage
listBookmarks conn q = do
    let parsed = parseSearchQuery (lqQ q)
        tags = dedupeText (sqTags parsed <> map (T.toLower . T.strip) (lqTags q))
        (joinSql, whereSql, params, orderSql) = buildFilter q parsed tags
        pageSql =
            Query
                ( "SELECT "
                    <> summaryColumns
                    <> " FROM bookmarks b "
                    <> joinSql
                    <> whereSql
                    <> orderSql
                    <> " LIMIT :limit OFFSET :offset"
                )
        pageParams = params <> [(":limit" := lqLimit q), (":offset" := lqOffset q)]
    yearRows <-
        queryNamed
            conn
            ( Query
                ( "SELECT CAST(strftime('%Y', b.created_at, 'unixepoch') AS INTEGER), COUNT(*) "
                    <> "FROM bookmarks b "
                    <> joinSql
                    <> whereSql
                    <> " GROUP BY 1 ORDER BY 1 DESC"
                )
            )
            params ::
            IO [(Int, Int)]
    let total = sum (map snd yearRows)
    rows <- queryNamed conn pageSql pageParams :: IO [SummaryRow]
    tagsById <- tagsForIds conn (map srId rows)
    let terms = sqTerms parsed
        toSummary r =
            BookmarkSummary
                { bsId = srId r
                , bsUrl = srUrl r
                , bsTitle = if T.null (srTitle r) then srUrl r else srTitle r
                , bsDomain = srDomain r
                , bsCreatedAt = srCreatedAt r
                , bsAddedAt = srAddedAt r
                , bsFaviconUrl = srFaviconUrl r
                , bsTags = fromMaybe [] (lookup (srId r) tagsById)
                , bsIsRead = srIsRead r /= 0
                , bsIsDead = srIsDead r /= 0
                , bsSnippet =
                    if null terms
                        then Nothing
                        else
                            let s = snippetFor terms [srTitle r, srDescription r, srUrl r, srNoteBody r, srExtractedText r]
                             in if T.null s then Nothing else Just s
                }
        items = map toSummary rows
    pure
        SearchPage
            { spItems = items
            , spTotal = total
            , spOffset = lqOffset q
            , spLimit = lqLimit q
            , spHasMore = lqOffset q + length items < total
            , spYearCounts = yearRows
            }

buildFilter :: ListQuery -> SearchQuery -> [Text] -> (Text, Text, [NamedParam], Text)
buildFilter q parsed tags =
    (joinSql, whereSql, params, orderSql)
  where
    joinSql = case sqFts parsed of
        Just _ -> " JOIN (SELECT rowid, rank FROM bookmarks_fts WHERE bookmarks_fts MATCH :fts) f ON f.rowid = b.id "
        Nothing -> ""
    orderSql = case sqFts parsed of
        Just _ -> " ORDER BY f.rank ASC, " <> sortClause
        Nothing -> " ORDER BY " <> sortClause
    sortClause = case T.toLower (T.strip (lqSort q)) of
        "added" -> "b.added_at DESC, b.id DESC"
        "opened" -> "COALESCE(b.last_opened_at, 0) DESC, b.id DESC"
        _ -> "b.created_at DESC, b.id DESC"

    ftsParams = case sqFts parsed of
        Nothing -> []
        Just expr -> [":fts" := expr]

    tagFilter = case tags of
        [] -> Nothing
        _ ->
            let names = [":tag" <> T.pack (show i) | i <- [0 .. length tags - 1]]
                placeholders = T.intercalate ", " names
                sql =
                    "b.id IN (SELECT bookmark_id FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id "
                        <> "WHERE t.name IN ("
                        <> placeholders
                        <> ") "
                        <> "GROUP BY bookmark_id HAVING COUNT(DISTINCT bt.tag_id) = :tagCount)"
                ps = zipWith (\n t -> n := t) names tags <> [":tagCount" := length tags]
             in Just (sql, ps)

    flagFilters :: [(Text, [NamedParam])]
    flagFilters =
        [("b.is_read = 0", []) | sqIsUnread parsed]
            <> [("b.is_dead = 1", []) | sqIsDead parsed]
            <> maybe [] (\b -> [("b.is_read = :isRead", [":isRead" := (if b then 1 else 0 :: Int)])]) (lqIsRead q)
            <> maybe [] (\b -> [("b.is_dead = :isDead", [":isDead" := (if b then 1 else 0 :: Int)])]) (lqIsDead q)

    negFilters :: [(Text, [NamedParam])]
    negFilters =
        [ ( "b.id NOT IN (SELECT rowid FROM bookmarks_fts WHERE bookmarks_fts MATCH :neg" <> T.pack (show i) <> ")"
          , [":neg" <> T.pack (show i) := quoteFts term]
          )
        | (i, term) <- zip [0 :: Int ..] (sqNegated parsed)
        ]

    linkFilters :: [(Text, [NamedParam])]
    linkFilters =
        [ ( "EXISTS (SELECT 1 FROM links l WHERE l.source_id = b.id AND l.target_id IN "
                <> "(SELECT id FROM bookmarks WHERE title = :link"
                <> n
                <> " OR title LIKE :linkLike"
                <> n
                <> " COLLATE NOCASE OR url LIKE :linkLike"
                <> n
                <> " COLLATE NOCASE))"
          , [":link" <> n := target, ":linkLike" <> n := ("%" <> target <> "%")]
          )
        | (i, target) <- zip [0 :: Int ..] (sqLinkTargets parsed)
        , let n = T.pack (show i)
        ]

    parts =
        (case tagFilter of Nothing -> []; Just x -> [x])
            <> flagFilters
            <> negFilters
            <> linkFilters
    params = ftsParams <> concatMap snd parts
    whereSql = case parts of
        [] -> ""
        _ -> " WHERE " <> T.intercalate " AND " (map fst parts)

quoteFts :: Text -> Text
quoteFts t = "\"" <> sanitizeToken t <> "\"*"

tagsForIds :: Connection -> [Int] -> IO [(Int, [Text])]
tagsForIds _ [] = pure []
tagsForIds conn ids = do
    let names = [":id" <> T.pack (show i) | i <- [0 .. length ids - 1]]
        placeholders = T.intercalate ", " names
        params = zipWith (\n i -> n := i) names ids
        sql =
            Query
                ( "SELECT bt.bookmark_id, t.name FROM bookmark_tags bt "
                    <> "JOIN tags t ON t.id = bt.tag_id "
                    <> "WHERE bt.bookmark_id IN ("
                    <> placeholders
                    <> ") "
                    <> "ORDER BY bt.bookmark_id, t.name"
                )
    rows <- queryNamed conn sql params :: IO [(Int, Text)]
    pure (groupTags rows)
  where
    groupTags [] = []
    groupTags ((bid, name) : rest) =
        let (same, other) = span (\(b, _) -> b == bid) rest
         in (bid, name : map snd same) : groupTags other

getBookmark :: Connection -> Int -> IO (Maybe BookmarkDetail)
getBookmark conn bid = do
    rows <- query conn (Query ("SELECT " <> detailColumns <> " FROM bookmarks b WHERE b.id = ?")) (Only bid) :: IO [DetailRow]
    case rows of
        [] -> pure Nothing
        (r : _) -> do
            tagRows <- tagsForIds conn [bid]
            links <- outgoingLinks conn bid
            pure
                ( Just
                    BookmarkDetail
                        { bdId = drId r
                        , bdUrl = drUrl r
                        , bdTitle = if T.null (drTitle r) then drUrl r else drTitle r
                        , bdDomain = drDomain r
                        , bdCreatedAt = drCreatedAt r
                        , bdAddedAt = drAddedAt r
                        , bdFaviconUrl = drFaviconUrl r
                        , bdTags = fromMaybe [] (lookup bid tagRows)
                        , bdIsRead = drIsRead r /= 0
                        , bdIsDead = drIsDead r /= 0
                        , bdSnippet = Nothing
                        , bdNoteBody = drNoteBody r
                        , bdExtractedText = drExtractedText r
                        , bdAuthor = drAuthor r
                        , bdSitename = drSitename r
                        , bdPublishedAt = drPublishedAt r
                        , bdLanguage = drLanguage r
                        , bdImageUrl = drImageUrl r
                        , bdFinalUrl = drFinalUrl r
                        , bdSnapshotPath = drSnapshotPath r
                        , bdSnapshotKind = drSnapshotKind r
                        , bdLastOpenedAt = drLastOpenedAt r
                        , bdLastCheckedAt = drLastCheckedAt r
                        , bdEnrichState = drEnrichState r
                        , bdEnrichError = drEnrichError r
                        , bdReadingTimeMinutes = drReadingTimeMinutes r
                        , bdLinks = links
                        }
                )

detailColumns :: Text
detailColumns =
    "b.id, b.url, b.title, b.domain, b.favicon_url, b.created_at, b.added_at, "
        <> "b.is_read, b.is_dead, b.note_body, b.extracted_text, b.author, b.sitename, "
        <> "b.published_at, b.language, b.image_url, b.final_url, b.snapshot_path, "
        <> "b.snapshot_kind, b.last_opened_at, b.last_checked_at, b.enrich_state, b.enrich_error, b.reading_time_minutes"

data DetailRow = DetailRow
    { drId :: Int
    , drUrl :: Text
    , drTitle :: Text
    , drDomain :: Text
    , drFaviconUrl :: Text
    , drCreatedAt :: Int
    , drAddedAt :: Int
    , drIsRead :: Int
    , drIsDead :: Int
    , drNoteBody :: Text
    , drExtractedText :: Text
    , drAuthor :: Text
    , drSitename :: Text
    , drPublishedAt :: Maybe Int
    , drLanguage :: Text
    , drImageUrl :: Text
    , drFinalUrl :: Text
    , drSnapshotPath :: Text
    , drSnapshotKind :: Text
    , drLastOpenedAt :: Maybe Int
    , drLastCheckedAt :: Maybe Int
    , drEnrichState :: Text
    , drEnrichError :: Text
    , drReadingTimeMinutes :: Int
    }

instance FromRow DetailRow where
    fromRow =
        DetailRow
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
            <*> field
            <*> field
            <*> field

outgoingLinks :: Connection -> Int -> IO [Backlink]
outgoingLinks conn bid = do
    rows <-
        query
            conn
            "SELECT COALESCE(target_id,0), target_title, COALESCE(display_text,''), COALESCE(line_number,0) FROM links WHERE source_id = ? ORDER BY line_number"
            (Only bid) ::
            IO [(Int, Text, Text, Int)]
    pure
        [ Backlink
            { blSourceId = tid
            , blSourceTitle = title
            , blSnippet = display
            , blLine = if line == 0 then Nothing else Just line
            , blResolved = tid > 0
            }
        | (tid, title, display, line) <- rows
        ]

allTags :: Connection -> IO [TagStat]
allTags conn = do
    rows <-
        query_
            conn
            "SELECT t.name, COUNT(bt.bookmark_id) FROM tags t LEFT JOIN bookmark_tags bt ON bt.tag_id = t.id GROUP BY t.id ORDER BY COUNT(bt.bookmark_id) DESC, t.name ASC" ::
            IO [(Text, Int)]
    pure [TagStat name count | (name, count) <- rows]

findBookmarkIdByUrl :: Connection -> Text -> IO (Maybe Int)
findBookmarkIdByUrl conn url = do
    let normalized = normalizeUrl url
    rows <-
        query
            conn
            "SELECT id FROM bookmarks WHERE url = ? OR url = ? ORDER BY id LIMIT 1"
            (url, normalized) ::
            IO [Only Int]
    pure (case rows of [Only i] -> Just i; _ -> Nothing)

{- | Fast save path: normalize, return an existing row, or insert a minimal
row. Enrichment is queued by the caller after a successful insert.
-}
quickSave :: Connection -> Text -> Text -> [Text] -> IO (Either Text (Int, Bool))
quickSave conn rawUrl title tags = do
    let url = normalizeUrl rawUrl
    existing <- findBookmarkIdByUrl conn url
    case existing of
        Just bid -> pure (Right (bid, True))
        Nothing -> do
            result <- insertBookmark conn url title tags
            case result of
                Right bid -> pure (Right (bid, False))
                Left message -> do
                    raced <- findBookmarkIdByUrl conn url
                    pure (maybe (Left message) (\bid -> Right (bid, True)) raced)

insertBookmark :: Connection -> Text -> Text -> [Text] -> IO (Either Text Int)
insertBookmark conn rawUrl title tags = do
    now <- (floor <$> getPOSIXTime) :: IO Int
    let url = normalizeUrl rawUrl
    existing <- findBookmarkIdByUrl conn rawUrl
    case existing of
        Just i -> pure (Left ("already saved as bookmark " <> T.pack (show i)))
        Nothing -> do
            bid <-
                withImmediateTransaction conn $ do
                    execute
                        conn
                        "INSERT INTO bookmarks (url,title,domain,source,created_at,added_at,updated_at) VALUES (?,?,?,?,?,?,?)"
                        (url, title, hostOfSimple url, "api" :: Text, now, now, now)
                    newId <- fromIntegral <$> lastInsertRowId conn
                    forM_ (dedupeText tags) $ \tag -> do
                        execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)" (tag, now)
                        idRows <- query conn "SELECT id FROM tags WHERE name = ?" (Only tag) :: IO [Only Int]
                        case idRows of
                            (Only tid : _) -> execute conn "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?, ?)" (newId, tid)
                            _ -> pure ()
                    _ <- applyRules conn newId url title
                    pure newId
            pure (Right bid)

{- | Delete one bookmark. The side snapshot recorded first also captures the
highlights and wikilinks that the delete cascades away, so undo restores the
whole record rather than an empty shell. -}
deleteBookmark :: Connection -> Int -> IO Bool
deleteBookmark conn bid = do
    n <- withImmediateTransaction conn $ do
        exists <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only bid) :: IO [Only Int]
        if null exists
            then pure 0
            else do
                _ <- recordUndoIds conn "delete" [bid]
                execute conn "DELETE FROM bookmarks WHERE id = ?" (Only bid)
                changes conn
    pure (n > 0)

data BulkAction
    = BulkAddTags [Text]
    | BulkRemoveTags [Text]
    | BulkMarkRead Bool
    | BulkDelete
    deriving (Show, Eq)

-- | Apply one action to at most 10,000 bookmarks and snapshot the rows first.
bulkUpdate :: Connection -> BulkAction -> [Int] -> IO (Either Text (Int, Int))
bulkUpdate conn action ids
    | null ids = pure (Left "no bookmark ids supplied")
    | length ids > 10000 = pure (Left "at most 10,000 bookmarks per bulk request")
    | otherwise =
        let uniqueIds = dedupeTextIds ids
            op = case action of
                BulkAddTags _ -> "bulk_add_tags"
                BulkRemoveTags _ -> "bulk_remove_tags"
                BulkMarkRead True -> "bulk_mark_read"
                BulkMarkRead False -> "bulk_mark_unread"
                BulkDelete -> "bulk_delete"
         in if null uniqueIds
                then pure (Left "no valid bookmark ids supplied")
                else
                    withImmediateTransaction conn $ do
                        snapshotId <- recordUndoIds conn op uniqueIds
                        updated <- applyBulk uniqueIds
                        pure (Right (updated, snapshotId))
  where
    applyBulk uniqueIds = case action of
        BulkAddTags tags -> do
            now <- (floor <$> getPOSIXTime) :: IO Int
            forM_ (dedupeText tags) $ \tag -> do
                execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)" (tag, now)
                idRows <- query conn "SELECT id FROM tags WHERE name = ?" (Only tag) :: IO [Only Int]
                case idRows of
                    (Only tid : _) ->
                        forM_ uniqueIds $ \bid ->
                            execute conn "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?, ?)" (bid, tid)
                    _ -> pure ()
            pure (length uniqueIds)
        BulkRemoveTags tags -> do
            let idNames = [":bid" <> T.pack (show i) | i <- [0 .. length uniqueIds - 1]]
                tagNames = [":tag" <> T.pack (show i) | i <- [0 .. length tags - 1]]
                marks = T.intercalate "," idNames
                tagMarks = T.intercalate "," tagNames
                params = zipWith (\name bid -> name := bid) idNames uniqueIds <> zipWith (\name tag -> name := tag) tagNames tags
            executeNamed
                conn
                (Query ("DELETE FROM bookmark_tags WHERE bookmark_id IN (" <> marks <> ") AND tag_id IN (SELECT id FROM tags WHERE name IN (" <> tagMarks <> "))"))
                params
            pure (length uniqueIds)
        BulkMarkRead value -> do
            let marks = T.intercalate "," (replicate (length uniqueIds) "?")
            execute
                conn
                (Query ("UPDATE bookmarks SET is_read = ?, updated_at = strftime('%s','now') WHERE id IN (" <> marks <> ")"))
                ((if value then 1 else 0 :: Int) : uniqueIds)
            pure (length uniqueIds)
        BulkDelete -> do
            let marks = T.intercalate "," (replicate (length uniqueIds) "?")
            execute conn (Query ("DELETE FROM bookmarks WHERE id IN (" <> marks <> ")")) uniqueIds
            pure (length uniqueIds)

dedupeTextIds :: [Int] -> [Int]
dedupeTextIds = go []
  where
    go seen [] = reverse seen
    go seen (x : xs) = if x <= 0 || x `elem` seen then go seen xs else go (x : seen) xs

{- | Mark the unread rows at or above one boundary in the ledger. The caller
must name a real row: an empty list previously meant "mark the whole library
read", which is not a safe interpretation of an empty inbox. -}
markAllAbove :: Connection -> Maybe Int -> IO Int
markAllAbove _conn Nothing = pure 0
markAllAbove conn (Just bid) =
    withImmediateTransaction conn $ do
        boundary <- query conn "SELECT created_at FROM bookmarks WHERE id = ?" (Only bid) :: IO [Only Int]
        case boundary of
            [Only createdAt] -> do
                execute
                    conn
                    "UPDATE bookmarks SET is_read = 1 WHERE is_read = 0 AND created_at >= ?"
                    (Only createdAt)
                changes conn
            _ -> pure 0

{- | Keep stored wikilinks pointing at a renamed bookmark, and resolve any
unresolved links that now match its new title. -}
resolveIncomingLinks :: Connection -> Int -> Text -> IO ()
resolveIncomingLinks conn targetId newTitle =
    execute
        conn
        "UPDATE links SET target_id = ?, target_title = ? WHERE target_id = ? OR (target_id IS NULL AND lower(target_title) = lower(?))"
        (targetId, newTitle, targetId, newTitle)

{- | Apply a partial edit.  Title/note/read are updated only when supplied;
tags are authoritative when supplied.  Returns False when the row is gone.
-}
updateBookmark :: Connection -> Int -> Maybe Text -> Maybe Text -> Maybe Bool -> Maybe [Text] -> IO Bool
updateBookmark conn bid mTitle mNote mRead mTags = do
    now <- (floor <$> getPOSIXTime) :: IO Int
    exists <- query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only bid) :: IO [Only Int]
    if null exists
        then pure False
        else do
            withImmediateTransaction conn $ do
                case mTitle of
                    Just t -> do
                        execute conn "UPDATE bookmarks SET title = ? WHERE id = ?" (t, bid)
                        resolveIncomingLinks conn bid t
                    Nothing -> pure ()
                case mNote of
                    Just n -> do
                        execute conn "UPDATE bookmarks SET note_body = ? WHERE id = ?" (n, bid)
                        syncLinks conn bid n
                    Nothing -> pure ()
                case mRead of
                    Just r -> execute conn "UPDATE bookmarks SET is_read = ? WHERE id = ?" ((if r then 1 else 0) :: Int, bid)
                    Nothing -> pure ()
                case mTags of
                    Nothing -> pure ()
                    Just tags -> do
                        execute conn "DELETE FROM bookmark_tags WHERE bookmark_id = ?" (Only bid)
                        forM_ (dedupeText tags) $ \tag -> do
                            execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)" (tag, now)
                            idRows <- query conn "SELECT id FROM tags WHERE name = ?" (Only tag) :: IO [Only Int]
                            case idRows of
                                (Only tid : _) -> execute conn "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?, ?)" (bid, tid)
                                _ -> pure ()
                execute conn "UPDATE bookmarks SET updated_at = ? WHERE id = ?" (now, bid)
            pure True

addTagsToBookmark :: Connection -> Int -> [Text] -> IO Int
addTagsToBookmark conn bid tags = do
    now <- (floor <$> getPOSIXTime) :: IO Int
    withImmediateTransaction conn $ do
        n <- forM (dedupeText tags) $ \tag -> do
            execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)" (tag, now)
            idRows <- query conn "SELECT id FROM tags WHERE name = ?" (Only tag) :: IO [Only Int]
            case idRows of
                (Only tid : _) -> do
                    execute conn "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?, ?)" (bid, tid)
                    changes conn
                _ -> pure 0
        pure (sum n)

recordOpen :: Connection -> Int -> IO ()
recordOpen conn bid = do
    now <- (floor <$> getPOSIXTime) :: IO Int
    withImmediateTransaction conn $
        execute conn "UPDATE bookmarks SET open_count = open_count + 1, last_opened_at = ? WHERE id = ?" (now, bid)

autocomplete :: Connection -> Text -> Int -> IO [BookmarkSummary]
autocomplete conn q limit = do
    let queryText = T.strip q
    if T.null queryText
        then pure []
        else do
            let likePattern = "%" <> queryText <> "%"
                prefix = queryText <> "%"
            rows <-
                query
                    conn
                    ( Query
                        ( "SELECT "
                            <> summaryColumns
                            <> " FROM bookmarks b "
                            <> "WHERE b.title LIKE ? COLLATE NOCASE OR b.url LIKE ? COLLATE NOCASE "
                            <> "ORDER BY CASE WHEN b.title LIKE ? COLLATE NOCASE THEN 0 ELSE 1 END, b.title COLLATE NOCASE LIMIT ?"
                        )
                    )
                    (likePattern, likePattern, prefix, limit) ::
                    IO [SummaryRow]
            summariesFromRows conn rows

getBacklinks :: Connection -> Int -> IO Backlinks
getBacklinks conn bid = do
    targetRows <- query conn "SELECT title FROM bookmarks WHERE id = ?" (Only bid) :: IO [Only Text]
    linkedRows <-
        query
            conn
            "SELECT b.id,b.title,COALESCE(l.display_text,''),COALESCE(l.line_number,0) FROM links l JOIN bookmarks b ON b.id=l.source_id WHERE l.target_id = ? ORDER BY b.title"
            (Only bid) ::
            IO [(Int, Text, Text, Int)]
    let linked =
            [ Backlink
                { blSourceId = sid
                , blSourceTitle = title
                , blSnippet = displayText
                , blLine = if line == 0 then Nothing else Just line
                , blResolved = True
                }
            | (sid, title, displayText, line) <- linkedRows
            ]
        linkedIds = map blSourceId linked
        needle = case targetRows of (Only t : _) -> T.strip t; [] -> ""
    unlinkedRows <-
        if T.null needle
            then pure []
            else
                query
                    conn
                    "SELECT id,title,note_body FROM bookmarks WHERE id != ? AND note_body LIKE ? ORDER BY title LIMIT 20"
                    (bid, "%" <> needle <> "%") ::
                    IO [(Int, Text, Text)]
    let unlinked =
            [ Backlink
                { blSourceId = sid
                , blSourceTitle = title
                , blSnippet = snippetFor [needle] [note]
                , blLine = Nothing
                , blResolved = False
                }
            | (sid, title, note) <- unlinkedRows
            , sid `notElem` linkedIds
            , not (T.null (T.strip note))
            ]
    pure (Backlinks linked unlinked)

pruneCandidates :: Connection -> Int -> IO [BookmarkSummary]
pruneCandidates conn days = do
    now <- (floor <$> getPOSIXTime) :: IO Int
    let cutoff = now - max 1 days * 86400
    rows <-
        query
            conn
            ( Query
                ( "SELECT "
                    <> summaryColumns
                    <> " FROM bookmarks b "
                    <> "WHERE b.open_count = 0 AND b.last_opened_at IS NULL AND b.added_at < ? "
                    <> "ORDER BY b.added_at ASC"
                )
            )
            (Only cutoff) ::
            IO [SummaryRow]
    summariesFromRows conn rows

{- | Delete the pruned rows. Prune is destructive, so it writes the same side
snapshot as a delete (bookmark rows, tags, highlights, wikilinks) before it
touches anything; undo restores all of it. The legacy JSON snapshot path is
deliberately not used here. -}
pruneApply :: Connection -> [Int] -> IO Int
pruneApply conn ids =
    let uniqueIds = dedupeTextIds ids
     in if null uniqueIds
            then pure 0
            else
                withImmediateTransaction conn $ do
                    let marks = T.intercalate "," (replicate (length uniqueIds) "?")
                    rows <- query conn (Query ("SELECT id FROM bookmarks WHERE id IN (" <> marks <> ")")) uniqueIds :: IO [Only Int]
                    let found = [i | Only i <- rows]
                    if null found
                        then pure 0
                        else do
                            _ <- recordUndoIds conn "prune" found
                            execute conn (Query ("DELETE FROM bookmarks WHERE id IN (" <> marks <> ")")) uniqueIds
                            pure (length found)

bookmarksByIds :: Connection -> [Int] -> IO [BookmarkSummary]
bookmarksByIds _ [] = pure []
bookmarksByIds conn ids = do
    let marks = T.intercalate "," (replicate (length ids) "?")
    rows <- query conn (Query ("SELECT " <> summaryColumns <> " FROM bookmarks b WHERE b.id IN (" <> marks <> ")")) ids :: IO [SummaryRow]
    summariesFromRows conn rows

summariesFromRows :: Connection -> [SummaryRow] -> IO [BookmarkSummary]
summariesFromRows conn rows = do
    tagsById <- tagsForIds conn (map srId rows)
    pure
        [ BookmarkSummary
            { bsId = srId r
            , bsUrl = srUrl r
            , bsTitle = if T.null (srTitle r) then srUrl r else srTitle r
            , bsDomain = srDomain r
            , bsCreatedAt = srCreatedAt r
            , bsAddedAt = srAddedAt r
            , bsFaviconUrl = srFaviconUrl r
            , bsTags = fromMaybe [] (lookup (srId r) tagsById)
            , bsIsRead = srIsRead r /= 0
            , bsIsDead = srIsDead r /= 0
            , bsSnippet = Nothing
            }
        | r <- rows
        ]

backfillDomains :: Connection -> IO Int
backfillDomains conn = do
    rows <- query_ conn "SELECT id,url FROM bookmarks WHERE domain = ''" :: IO [(Int, Text)]
    withImmediateTransaction conn $ do
        forM_ rows $ \(bid, url) ->
            execute conn "UPDATE bookmarks SET domain = ? WHERE id = ?" (hostOf url, bid)
        pure (length rows)

bookmarkStats :: Connection -> IO [(Text, Int)]
bookmarkStats conn = do
    b <- count "SELECT COUNT(*) FROM bookmarks"
    t <- count "SELECT COUNT(*) FROM tags"
    bt <- count "SELECT COUNT(*) FROM bookmark_tags"
    l <- count "SELECT COUNT(*) FROM links"
    pure [("bookmarks", b), ("tags", t), ("bookmark_tags", bt), ("links", l)]
  where
    count sql = do
        [Only n] <- query_ conn sql :: IO [Only Int]
        pure n

{- | Whole-library figures for the boot payload, the accessions page and the
account panels. Counts are live; nothing here is cached or estimated.
-}
libraryStats :: Connection -> IO LibraryStats
libraryStats conn = do
    [Only total] <- query_ conn "SELECT COUNT(*) FROM bookmarks" :: IO [Only Int]
    [Only tags] <- query_ conn "SELECT COUNT(*) FROM tags" :: IO [Only Int]
    [Only tagLinks] <- query_ conn "SELECT COUNT(*) FROM bookmark_tags" :: IO [Only Int]
    [Only sources] <-
        query_ conn "SELECT COUNT(DISTINCT domain) FROM bookmarks WHERE domain <> ''" :: IO [Only Int]
    topSources <-
        query_
            conn
            "SELECT domain, COUNT(*) AS c FROM bookmarks WHERE domain <> '' GROUP BY domain ORDER BY c DESC, domain ASC LIMIT 24" ::
            IO [(Text, Int)]
    [Only sourcesOnce] <-
        query_
            conn
            "SELECT COUNT(*) FROM (SELECT domain FROM bookmarks WHERE domain <> '' GROUP BY domain HAVING COUNT(*) = 1)" ::
            IO [Only Int]
    dayRows <-
        query_
            conn
            "SELECT COALESCE(MIN(date(created_at, 'unixepoch')), ''), COALESCE(MAX(date(created_at, 'unixepoch')), '') FROM bookmarks WHERE created_at > 0" ::
            IO [(Text, Text)]
    let (firstDay, lastDay) = case dayRows of
            ((first, lastRow) : _) -> (first, lastRow)
            [] -> ("", "")
    [Only days] <-
        query_
            conn
            "SELECT COUNT(DISTINCT date(created_at, 'unixepoch')) FROM bookmarks WHERE created_at > 0" ::
            IO [Only Int]
    years <-
        query_
            conn
            "SELECT CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER), COUNT(*) FROM bookmarks WHERE created_at > 0 GROUP BY 1 ORDER BY 1 DESC" ::
            IO [(Int, Int)]
    filingDays <-
        query_
            conn
            "SELECT date(created_at, 'unixepoch'), COUNT(*) FROM bookmarks WHERE created_at > 0 GROUP BY 1 ORDER BY 1 ASC" ::
            IO [(Text, Int)]
    [Only unread] <- query_ conn "SELECT COUNT(*) FROM bookmarks WHERE is_read = 0" :: IO [Only Int]
    [Only dead] <- query_ conn "SELECT COUNT(*) FROM bookmarks WHERE is_dead = 1" :: IO [Only Int]
    [Only queued] <- query_ conn "SELECT COUNT(*) FROM jobs WHERE state IN ('queued','running')" :: IO [Only Int]
    [Only faviconBytes] <- query_ conn "SELECT COALESCE(SUM(LENGTH(bytes)),0) FROM favicons" :: IO [Only Int]
    [Only highlights] <- query_ conn "SELECT COUNT(*) FROM highlights" :: IO [Only Int]
    [Only shares] <-
        query_ conn "SELECT COUNT(*) FROM share_links WHERE revoked_at IS NULL" :: IO [Only Int]
    pure
        LibraryStats
            { lsTotal = total
            , lsTags = tags
            , lsTagLinks = tagLinks
            , lsSources = sources
            , lsTopSources = topSources
            , lsSourcesOnce = sourcesOnce
            , lsFirstDay = firstDay
            , lsLastDay = lastDay
            , lsDays = days
            , lsYears = years
            , lsFilingDays = filingDays
            , lsUnread = unread
            , lsDead = dead
            , lsQueued = queued
            , lsFaviconBytes = faviconBytes
            , lsHighlights = highlights
            , lsShares = shares
            }

hostOfSimple :: Text -> Text
hostOfSimple u =
    let after = T.drop 1 (T.dropWhile (/= ':') u)
        afterSlashes = T.dropWhile (== '/') after
        authority = T.takeWhile (\c -> c /= '/' && c /= '?' && c /= '#') afterSlashes
     in T.toLower (T.takeWhile (\c -> c /= ':') authority)

dedupeText :: [Text] -> [Text]
dedupeText = go []
  where
    go seen [] = reverse seen
    go seen (x : xs) =
        let n = T.toLower (T.strip x)
         in if T.null n || n `elem` seen then go seen xs else go (n : seen) xs
