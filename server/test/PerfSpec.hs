{- | Tests for the query/stats performance work and the v9 indexes.

These tests pin the behaviour the performance rewrite must not change: the
three-query @libraryStats@ has to reproduce the old query-per-aggregate
result exactly, the ledger page keeps its totals when it skips the year
counts, the @sort=opened@ ordering matches the old @COALESCE@ ordering, and
the v8 to v9 migration adds the indexes the fast paths rely on.
-}
module PerfSpec (spec) where

import Control.Exception (bracket)
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Database.SQLite.Simple (Only (..), Query (..), close)
import qualified Database.SQLite.Simple as Sqlite
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Eza.Bookmarks
import Eza.Db
import Eza.Graph (globalGraph)
import Eza.Types (BookmarkSummary (..), GraphData (..), GraphLink (..), GraphRecord (..), GraphTag (..), LibraryStats (..), SearchPage (..))

spec :: Spec
spec = do
    describe "libraryStats" $ do
        it "matches the previous query implementation on a populated database" $
            withSystemTempDirectory "eza-perf-stats" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                seedPopulatedLibrary conn
                stats <- libraryStats conn
                reference <- previousLibraryStats conn
                stats `shouldBe` reference
                close conn

        it "reports zeroes for an empty database" $
            withSystemTempDirectory "eza-perf-stats-empty" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                stats <- libraryStats conn
                stats `shouldBe` LibraryStats 0 0 0 0 [] 0 "" "" 0 [] [] 0 0 0 0 0 0
                close conn

        it "matches the mini-export reference expectations from the test suite" $
            withSystemTempDirectory "eza-perf-stats-mini" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                seedMiniExport conn
                stats <- libraryStats conn
                lsTotal stats `shouldBe` 3
                lsTags stats `shouldBe` 2
                lsTagLinks stats `shouldBe` 3
                lsSources stats `shouldBe` 1
                lsTopSources stats `shouldBe` [("example.com", 3)]
                lsSourcesOnce stats `shouldBe` 0
                lsFirstDay stats `shouldBe` "2023-11-14"
                lsLastDay stats `shouldBe` "2023-11-14"
                lsDays stats `shouldBe` 1
                lsYears stats `shouldBe` [(2023, 3)]
                lsFilingDays stats `shouldBe` [("2023-11-14", 3)]
                page <- listBookmarks conn defaultListQuery
                spYearCounts page `shouldBe` [(2023, 3)]
                close conn

    describe "listBookmarks" $ do
        it "returns the year counts on the first page" $
            withSystemTempDirectory "eza-perf-list-first" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                seedPopulatedLibrary conn
                page <- listBookmarks conn defaultListQuery
                expectedYears <- yearsOf conn
                spTotal page `shouldBe` 6
                spOffset page `shouldBe` 0
                spYearCounts page `shouldBe` expectedYears
                length (spItems page) `shouldBe` 6
                close conn

        it "omits the year counts but keeps the total on later pages" $
            withSystemTempDirectory "eza-perf-list-offset" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                seedPopulatedLibrary conn
                page <- listBookmarks conn defaultListQuery{lqOffset = 2, lqLimit = 2}
                spYearCounts page `shouldBe` []
                spTotal page `shouldBe` 6
                spOffset page `shouldBe` 2
                length (spItems page) `shouldBe` 2
                spHasMore page `shouldBe` True
                lastPage <- listBookmarks conn defaultListQuery{lqOffset = 6, lqLimit = 2}
                spYearCounts lastPage `shouldBe` []
                spTotal lastPage `shouldBe` 6
                spItems lastPage `shouldBe` []
                spHasMore lastPage `shouldBe` False
                close conn

        it "keeps filtered totals on later pages" $
            withSystemTempDirectory "eza-perf-list-filter" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                seedPopulatedLibrary conn
                firstPage <- listBookmarks conn defaultListQuery{lqTags = ["rust"]}
                expectedYears <- yearsOfFiltered conn "rust"
                spTotal firstPage `shouldBe` 2
                spYearCounts firstPage `shouldBe` expectedYears
                laterPage <- listBookmarks conn defaultListQuery{lqTags = ["rust"], lqOffset = 1, lqLimit = 1}
                spYearCounts laterPage `shouldBe` []
                spTotal laterPage `shouldBe` 2
                spHasMore laterPage `shouldBe` False
                close conn

        it "orders sort=opened like the previous COALESCE ordering" $
            withSystemTempDirectory "eza-perf-list-opened" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                seedOpenedLibrary conn
                page <- listBookmarks conn defaultListQuery{lqSort = "opened", lqLimit = 50}
                let actual = map bsId (spItems page)
                    expected =
                        map
                            snd
                            ( sortOn
                                (\(opened, bid) -> (negate (fromMaybe 0 opened), negate bid))
                                ([(Just 300, 2), (Nothing, 1), (Just 100, 3), (Just 200, 4), (Nothing, 5)] :: [(Maybe Int, Int)])
                            )
                actual `shouldBe` expected
                actual `shouldBe` [2, 4, 3, 5, 1]
                close conn

        it "only extracts a snippet when the query has FTS terms" $
            withSystemTempDirectory "eza-perf-list-snippet" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                _ <- insertSeed conn (seedBookmark "https://example.com/r" "Rust notes" "example.com" 1700000000 0 0 Nothing "hello rustacean world")
                plain <- listBookmarks conn defaultListQuery
                map bsSnippet (spItems plain) `shouldBe` [Nothing]
                searched <- listBookmarks conn defaultListQuery{lqQ = "rustacean"}
                case spItems searched of
                    (item : _) -> bsSnippet item `shouldSatisfy` maybe False (T.isInfixOf "rustacean")
                    [] -> expectationFailure "expected the FTS query to find the bookmark"
                close conn

    describe "migration v9 and v10" $ do
        it "migrates a v8 database through v9 to v10 and creates the performance indexes" $
            withSystemTempDirectory "eza-perf-migrate" $ \dir -> do
                let path = dir </> "test.db"
                bracket (Sqlite.open path) Sqlite.close $ \conn -> do
                    mapM_ (Sqlite.execute_ conn) (schemaV1 <> schemaV2 <> schemaV3 <> schemaV4 <> schemaV5 <> schemaV6 <> schemaV7 <> schemaV8)
                    Sqlite.execute_ conn "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES ('https://example.test/v8','V8','example.test',1,1,1)"
                    Sqlite.execute_ conn "INSERT INTO tags (name,created_at) VALUES ('kept',1)"
                    Sqlite.execute_ conn "INSERT INTO bookmark_tags (bookmark_id,tag_id) VALUES (1,1)"
                    Sqlite.execute_ conn "PRAGMA user_version = 8"
                migrated <- openDb path
                version <- schemaVersion migrated
                version `shouldBe` targetSchemaVersion
                version `shouldBe` targetSchemaVersion
                books <- queryScalar migrated "SELECT COUNT(*) FROM bookmarks"
                books `shouldBe` 1
                tags <- queryScalar migrated "SELECT COUNT(*) FROM tags"
                tags `shouldBe` 1
                links <- queryScalar migrated "SELECT COUNT(*) FROM bookmark_tags"
                links `shouldBe` 1
                indexRows <-
                    Sqlite.query_
                        migrated
                        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='bookmarks'" ::
                        IO [Only T.Text]
                let indexes = [name | Only name <- indexRows]
                indexes `shouldSatisfy` contains "idx_bookmarks_opened"
                indexes `shouldSatisfy` contains "idx_bookmarks_unread"
                indexes `shouldSatisfy` contains "idx_bookmarks_dead"
                indexes `shouldSatisfy` contains "idx_bookmarks_year"
                planRows <-
                    Sqlite.query_
                        migrated
                        "EXPLAIN QUERY PLAN SELECT id FROM bookmarks ORDER BY last_opened_at DESC, id DESC LIMIT 5" ::
                        IO [(Int, Int, Int, T.Text)]
                let plan = [detail | (_, _, _, detail) <- planRows]
                plan `shouldSatisfy` any (T.isInfixOf "idx_bookmarks_opened")
                close migrated

    describe "globalGraph" $ do
        it "returns every record and tag, plus the resolved links only" $
            withSystemTempDirectory "eza-perf-graph" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                first <- insertSeed conn (seedBookmark "https://g.test/a" "A" "g.test" 1700000000 0 0 Nothing "")
                second <- insertSeed conn (seedBookmark "https://g.test/b" "B" "g.test" 1700000000 0 0 Nothing "")
                addTag conn first "one"
                addTag conn second "one"
                Sqlite.execute
                    conn
                    "INSERT INTO links (source_id, target_id, target_title) VALUES (?,?, '')"
                    (first, Just second :: Maybe Int)
                Sqlite.execute
                    conn
                    "INSERT INTO links (source_id, target_id, target_title) VALUES (?,NULL,'unresolved')"
                    (Only first)
                graph <- globalGraph conn
                gdTags graph `shouldBe` [GraphTag "one" 2]
                map grId (gdRecords graph) `shouldBe` [first, second]
                gdLinks graph `shouldBe` [GraphLink first second]
                close conn

        it "returns an empty graph for an empty database" $
            withSystemTempDirectory "eza-perf-graph-empty" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                globalGraph conn `shouldReturn` GraphData [] [] [] "0:0:0:0:0"
                close conn

    describe "bookmarksByIdsLight" $ do
        it "returns the light summary fields in id order with tags" $
            withSystemTempDirectory "eza-perf-light" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                first <- insertSeed conn (seedBookmark "https://one.test/a" "One" "one.test" 1700000000 0 0 Nothing "long note body")
                second <- insertSeed conn (seedBookmark "https://two.test/b" "" "two.test" 1700000001 1 1 Nothing "")
                third <- insertSeed conn (seedBookmark "https://three.test/c" "Three" "three.test" 1700000002 0 0 Nothing "")
                addTag conn first "rust"
                addTag conn second "toolbar"
                addTag conn second "rust"
                summaries <- bookmarksByIdsLight conn [third, first, second]
                map bsId summaries `shouldBe` [first, second, third]
                case summaries of
                    (one : two : three : _) -> do
                        bsUrl one `shouldBe` "https://one.test/a"
                        bsTitle one `shouldBe` "One"
                        bsDomain one `shouldBe` "one.test"
                        bsCreatedAt one `shouldBe` 1700000000
                        bsAddedAt one `shouldBe` 1700000000
                        bsIsRead one `shouldBe` False
                        bsIsDead one `shouldBe` False
                        bsSnippet one `shouldBe` Nothing
                        bsTags one `shouldBe` ["rust"]
                        bsTitle two `shouldBe` "https://two.test/b"
                        bsIsRead two `shouldBe` True
                        bsIsDead two `shouldBe` True
                        bsTags two `shouldBe` ["rust", "toolbar"]
                        bsTitle three `shouldBe` "Three"
                        bsTags three `shouldBe` []
                    _ -> expectationFailure "expected three summaries"
                close conn

        it "is what bookmarksByIds returns for the same ids" $
            withSystemTempDirectory "eza-perf-light-alias" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                first <- insertSeed conn (seedBookmark "https://one.test/a" "One" "one.test" 1700000000 0 0 Nothing "")
                second <- insertSeed conn (seedBookmark "https://two.test/b" "Two" "two.test" 1700000001 0 0 Nothing "")
                viaIds <- bookmarksByIds conn [second, first]
                viaLight <- bookmarksByIdsLight conn [second, first]
                viaIds `shouldBe` viaLight
                close conn

        it "chunks a long id list instead of exceeding the parameter limit" $
            withSystemTempDirectory "eza-perf-light-chunk" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                first <- insertSeed conn (seedBookmark "https://one.test/a" "One" "one.test" 1700000000 0 0 Nothing "")
                summaries <- bookmarksByIdsLight conn (first : [1000 .. 1600])
                map bsId summaries `shouldBe` [first]
                close conn

        it "returns nothing for an empty id list" $
            withSystemTempDirectory "eza-perf-light-empty" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                bookmarksByIdsLight conn [] `shouldReturn` ([] :: [BookmarkSummary])
                close conn

    describe "findBookmarkIdByUrl" $ do
        it "matches a saved page across scheme, www. and trailing-slash variants" $
            withSystemTempDirectory "eza-perf-find" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                bid <- insertSeed conn (seedBookmark "https://example.com/page" "Page" "example.com" 1700000000 0 0 Nothing "")
                findBookmarkIdByUrl conn "http://www.example.com/page/" `shouldReturn` Just bid
                findBookmarkIdByUrl conn "https://EXAMPLE.com/page#section" `shouldReturn` Just bid
                findBookmarkIdByUrl conn "https://example.com/other" `shouldReturn` Nothing
                close conn

        it "prefers the lowest id when http and https rows both exist" $
            withSystemTempDirectory "eza-perf-find-race" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                older <- insertSeed conn (seedBookmark "http://dup.test/x" "HTTP" "dup.test" 1700000000 0 0 Nothing "")
                _newer <- insertSeed conn (seedBookmark "https://dup.test/x" "HTTPS" "dup.test" 1700000001 0 0 Nothing "")
                findBookmarkIdByUrl conn "https://dup.test/x" `shouldReturn` Just older
                close conn

        it "makes the save paths reuse an existing row with one lookup each" $
            withSystemTempDirectory "eza-perf-save" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                first <- insertBookmark conn "https://example.com/page" "Page" []
                case first of
                    Left err -> expectationFailure ("first save failed: " <> T.unpack err)
                    Right _ -> pure ()
                duplicate <- insertBookmark conn "http://www.example.com/page/" "Page" []
                case duplicate of
                    Left err -> T.isInfixOf "already saved" err `shouldBe` True
                    Right _ -> expectationFailure "expected the second insert to report the existing row"
                saved <- quickSave conn "http://www.example.com/page/" "Page" []
                case saved of
                    Left err -> expectationFailure ("quick save failed: " <> T.unpack err)
                    Right (bid, existing) -> do
                        existing `shouldBe` True
                        findBookmarkIdByUrl conn "https://example.com/page" `shouldReturn` Just bid
                fresh <- quickSave conn "https://fresh.example.com/new" "New" []
                case fresh of
                    Left err -> expectationFailure ("fresh quick save failed: " <> T.unpack err)
                    Right (_, existing) -> existing `shouldBe` False
                count <- queryScalar conn "SELECT COUNT(*) FROM bookmarks"
                count `shouldBe` 2
                close conn

-- ---------------------------------------------------------------------------
-- Reference implementations and fixtures
-- ---------------------------------------------------------------------------

{- | The query-per-aggregate 'libraryStats' that the three-query version
replaces. It is kept here, in the test, as the reference the new result must
reproduce field for field.
-}
previousLibraryStats :: Sqlite.Connection -> IO LibraryStats
previousLibraryStats conn = do
    total <- scalar "SELECT COUNT(*) FROM bookmarks"
    tags <- scalar "SELECT COUNT(*) FROM tags"
    tagLinks <- scalar "SELECT COUNT(*) FROM bookmark_tags"
    sources <- scalar "SELECT COUNT(DISTINCT domain) FROM bookmarks WHERE domain <> ''"
    topSources <-
        Sqlite.query_
            conn
            "SELECT domain, COUNT(*) AS c FROM bookmarks WHERE domain <> '' GROUP BY domain ORDER BY c DESC, domain ASC LIMIT 24" ::
            IO [(T.Text, Int)]
    sourcesOnce <-
        scalar
            "SELECT COUNT(*) FROM (SELECT domain FROM bookmarks WHERE domain <> '' GROUP BY domain HAVING COUNT(*) = 1)"
    dayRows <-
        Sqlite.query_
            conn
            "SELECT COALESCE(MIN(date(created_at, 'unixepoch')), ''), COALESCE(MAX(date(created_at, 'unixepoch')), '') FROM bookmarks WHERE created_at > 0" ::
            IO [(T.Text, T.Text)]
    let (firstDay, lastDay) = case dayRows of
            ((first, lastRow) : _) -> (first, lastRow)
            [] -> ("", "")
    days <- scalar "SELECT COUNT(DISTINCT date(created_at, 'unixepoch')) FROM bookmarks WHERE created_at > 0"
    years <-
        Sqlite.query_
            conn
            "SELECT CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER), COUNT(*) FROM bookmarks WHERE created_at > 0 GROUP BY 1 ORDER BY 1 DESC" ::
            IO [(Int, Int)]
    filingDays <-
        Sqlite.query_
            conn
            "SELECT date(created_at, 'unixepoch'), COUNT(*) FROM bookmarks WHERE created_at > 0 GROUP BY 1 ORDER BY 1 ASC" ::
            IO [(T.Text, Int)]
    unread <- scalar "SELECT COUNT(*) FROM bookmarks WHERE is_read = 0"
    dead <- scalar "SELECT COUNT(*) FROM bookmarks WHERE is_dead = 1"
    queued <- scalar "SELECT COUNT(*) FROM jobs WHERE state IN ('queued','running')"
    faviconBytes <- scalar "SELECT COALESCE(SUM(LENGTH(bytes)),0) FROM favicons"
    highlights <- scalar "SELECT COUNT(*) FROM highlights"
    shares <- scalar "SELECT COUNT(*) FROM share_links WHERE revoked_at IS NULL"
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
  where
    scalar :: Query -> IO Int
    scalar sql = do
        rows <- Sqlite.query_ conn sql :: IO [Only Int]
        pure (case rows of [Only n] -> n; _ -> 0)

-- | The ledger's per-year counts, straight from the old query, for comparisons.
yearsOf :: Sqlite.Connection -> IO [(Int, Int)]
yearsOf conn =
    Sqlite.query_
        conn
        "SELECT CAST(strftime('%Y', created_at, 'unixepoch') AS INTEGER), COUNT(*) FROM bookmarks WHERE created_at > 0 GROUP BY 1 ORDER BY 1 DESC" ::
        IO [(Int, Int)]

yearsOfFiltered :: Sqlite.Connection -> T.Text -> IO [(Int, Int)]
yearsOfFiltered conn tagName =
    Sqlite.query
        conn
        ( Query
            ( "SELECT CAST(strftime('%Y', b.created_at, 'unixepoch') AS INTEGER), COUNT(*) "
                <> "FROM bookmarks b WHERE b.id IN (SELECT bookmark_id FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id WHERE t.name = ?) "
                <> "GROUP BY 1 ORDER BY 1 DESC"
            )
        )
        (Only tagName) ::
        IO [(Int, Int)]

data SeedBookmark = SeedBookmark
    { seedUrl :: T.Text
    , seedTitle :: T.Text
    , seedDomain :: T.Text
    , seedCreatedAt :: Int
    , seedRead :: Int
    , seedDead :: Int
    , seedLastOpenedAt :: Maybe Int
    , seedNote :: T.Text
    }

seedBookmark :: T.Text -> T.Text -> T.Text -> Int -> Int -> Int -> Maybe Int -> T.Text -> SeedBookmark
seedBookmark = SeedBookmark

insertSeed :: Sqlite.Connection -> SeedBookmark -> IO Int
insertSeed conn seed = do
    Sqlite.execute
        conn
        "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at,is_read,is_dead,last_opened_at,note_body) VALUES (?,?,?,?,?,?,?,?,?,?)"
        ( seedUrl seed
        , seedTitle seed
        , seedDomain seed
        , seedCreatedAt seed
        , seedCreatedAt seed
        , seedCreatedAt seed
        , seedRead seed
        , seedDead seed
        , seedLastOpenedAt seed
        , seedNote seed
        )
    fromIntegral <$> Sqlite.lastInsertRowId conn

addTag :: Sqlite.Connection -> Int -> T.Text -> IO ()
addTag conn bid name = do
    Sqlite.execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, 1)" (Only name)
    tagRows <- Sqlite.query conn "SELECT id FROM tags WHERE name = ?" (Only name) :: IO [Only Int]
    case tagRows of
        (Only tid : _) ->
            Sqlite.execute conn "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?, ?)" (bid, tid)
        [] -> pure ()

{- | Six rows across three years, four domains (one empty), flags and tags, so
every aggregate in 'libraryStats' has a non-trivial value.
-}
seedPopulatedLibrary :: Sqlite.Connection -> IO ()
seedPopulatedLibrary conn = do
    first <- insertSeed conn (seedBookmark "https://a.test/one" "One" "a.test" 1700000000 0 0 Nothing "")
    second <- insertSeed conn (seedBookmark "https://a.test/two" "Two" "a.test" 1700000001 1 0 Nothing "")
    _ <- insertSeed conn (seedBookmark "https://b.test/x" "B" "b.test" 1600000000 0 1 Nothing "")
    fourth <- insertSeed conn (seedBookmark "https://c.test/" "C" "c.test" 1600000000 0 0 Nothing "note")
    _ <- insertSeed conn (seedBookmark "https://d.test/only" "D" "d.test" 1731536000 0 0 Nothing "")
    _ <- insertSeed conn (seedBookmark "https://a.test/no-domain" "No domain" "" 1700000002 0 0 Nothing "")
    addTag conn first "rust"
    addTag conn second "rust"
    addTag conn second "toolbar"
    addTag conn fourth "books"
    Sqlite.execute_ conn "INSERT INTO jobs (kind, bookmark_id, state, available_at, created_at, updated_at) VALUES ('enrich', 1, 'queued', 1, 1, 1)"
    Sqlite.execute_ conn "INSERT INTO jobs (kind, bookmark_id, state, available_at, created_at, updated_at) VALUES ('enrich', 2, 'done', 1, 1, 1)"
    Sqlite.execute_ conn "INSERT INTO favicons (domain, mime, bytes, fetched_at) VALUES ('a.test', 'image/png', x'010203', 1)"
    Sqlite.execute_ conn "INSERT INTO highlights (bookmark_id, quote, start_offset, end_offset, created_at, updated_at) VALUES (1, 'quote', 0, 5, 1, 1)"
    Sqlite.execute_ conn "INSERT INTO share_links (token_hash, token_prefix, scope, target_id, created_at, expires_at) VALUES ('hash-one', 'p', 'bookmark', 1, 1, 9999999999)"
    Sqlite.execute_ conn "INSERT INTO share_links (token_hash, token_prefix, scope, target_id, created_at, expires_at, revoked_at) VALUES ('hash-two', 'p', 'bookmark', 1, 1, 9999999999, 2)"

{- | The three bookmarks the mini export test in Spec.hs expects: one domain,
one filing day, two tags and three tag links.
-}
seedMiniExport :: Sqlite.Connection -> IO ()
seedMiniExport conn = do
    first <- insertSeed conn (seedBookmark "https://example.com/one" "One" "example.com" 1700000000 0 0 Nothing "")
    second <- insertSeed conn (seedBookmark "https://example.com/two" "Two" "example.com" 1700000000 0 0 Nothing "")
    _ <- insertSeed conn (seedBookmark "https://example.com/three" "Three" "example.com" 1700000000 0 0 Nothing "")
    addTag conn first "toolbar"
    addTag conn first "rust"
    addTag conn second "rust"

{- | Opened timestamps with NULLs, which is what an imported library starts
with. The expected order is the old @COALESCE(last_opened_at, 0)@ ordering.
-}
seedOpenedLibrary :: Sqlite.Connection -> IO ()
seedOpenedLibrary conn = do
    _ <- insertSeed conn (seedBookmark "https://o.test/1" "1" "o.test" 1700000000 0 0 Nothing "")
    _ <- insertSeed conn (seedBookmark "https://o.test/2" "2" "o.test" 1700000000 0 0 (Just 300) "")
    _ <- insertSeed conn (seedBookmark "https://o.test/3" "3" "o.test" 1700000000 0 0 (Just 100) "")
    _ <- insertSeed conn (seedBookmark "https://o.test/4" "4" "o.test" 1700000000 0 0 (Just 200) "")
    _ <- insertSeed conn (seedBookmark "https://o.test/5" "5" "o.test" 1700000000 0 0 Nothing "")
    pure ()

contains :: T.Text -> [T.Text] -> Bool
contains needle = any (T.isInfixOf needle)
