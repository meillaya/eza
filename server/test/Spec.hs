module Main (main) where

import Control.Exception (bracket)
import Data.Aeson (Value (..), decode, encode, object, toJSON)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Foldable (toList)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (close)
import qualified Database.SQLite.Simple as Sqlite
import System.Directory (doesFileExist, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import qualified AdminSpec
import qualified AuthzSpec
import qualified BackupSpec
import qualified CliSpec
import qualified ClipSpec
import qualified ControlSpec
import qualified CoreViewSpec
import qualified DataIntegritySpec
import qualified DedupSpec
import qualified Eza.Auth as Auth
import Eza.Bookmarks
import Eza.Db (openDb, queryScalar, schemaV1, schemaV2, schemaV3, schemaV4, schemaV5, schemaVersion, targetSchemaVersion)
import Eza.Favicon (Favicon (..), getFavicon, parseDataIcon, parseIconLinks, putFavicon, recordFaviconFailure, sniffImage)
import Eza.Graph (GraphLayoutPayload (..), emptyLayoutCache, globalGraph, graphLayoutPayload, graphRevision, layoutPresetFromText, layoutPresetText, lookupCachedLayout, storeCachedLayout)
import Eza.GraphLayout (LayoutPreset (..))
import Eza.Highlights (createHighlight, deleteHighlight, listHighlights, updateHighlight)
import Eza.Import
import Eza.JsonExport (JsonImportReport (..), exportJson, importJson)
import qualified Eza.Password as Password
import Eza.Rules (Rule (..), createRule, listRules, matchingBookmarks)
import Eza.SearchQuery
import Eza.Shares (ShareRecord (..), ShareState (..), ShareUnavailable (..), createShare, resolveShare, resolveShareState, revokeShare, shareUnavailablePage)
import Eza.Types (BookmarkDetail (..), BookmarkSummary (..), GraphData (..), GraphLink (..), GraphRecord (..), GraphTag (..), Highlight (..), ImportReport (..), LibraryStats (..), SearchPage (..))
import Eza.Url (dedupeKey, dedupeLookupUrls, normalizeUrl)
import qualified GraphLayoutSpec
import qualified IsolationSpec
import qualified LedgerSpec
import qualified PerfSpec
import qualified SecuritySpec
import qualified ViewContractSpec
import qualified ViewServerSpec
import qualified WebhookSpec
import qualified WorkerSpec

main :: IO ()
main = hspec $ do
    describe "URL normalization" $ do
        it "lowercases scheme and host, drops the default port and fragment, and trims a root slash" $ do
            normalizeUrl "HTTPS://Example.COM:443/a/#frag" `shouldBe` "https://example.com/a"
            normalizeUrl "https://example.com/" `shouldBe` "https://example.com"
            normalizeUrl "http://example.com:80/path/" `shouldBe` "http://example.com/path"

    describe "canonical dedupe key" $ do
        it "ignores the http(s) scheme, www and trailing slash but keeps non-default ports" $ do
            dedupeKey "http://Example.COM:80/a/" `shouldBe` dedupeKey "https://example.com/a"
            dedupeKey "https://www.example.com" `shouldBe` T.pack "example.com"
            dedupeKey "http://example.com:8080/a" `shouldNotBe` dedupeKey "http://example.com/a"
        it "lists the exact stored-URL candidates for a canonical lookup" $ do
            dedupeLookupUrls "HTTPS://Example.com:443/a/" `shouldMatchList` map T.pack ["https://example.com/a", "http://example.com/a"]
            dedupeLookupUrls "mailto:owner@example.com" `shouldBe` [T.pack "mailto:owner@example.com"]

    describe "favicon parsing" $ do
        it "resolves relative icon links against a directory URL" $ do
            let html = "<html><head><link rel=\"icon\" href=\"assets/favicon.png\"></head></html>"
            parseIconLinks html "https://www.haskell.org/ghcup" `shouldContain` ["https://www.haskell.org/ghcup/assets/favicon.png"]
        it "accepts a data URL and recognizes PNG magic bytes" $ do
            case parseDataIcon "data:image/png;base64,iVBORw0KGgo=" of
                Nothing -> expectationFailure "expected a data icon"
                Just (mime, bytes) -> do
                    mime `shouldBe` "image/png"
                    sniffImage bytes `shouldBe` Just "image/png"
        it "rejects an SVG body" $ do
            sniffImage (BS.pack [0x3c, 0x73, 0x76, 0x67]) `shouldBe` Nothing
        it "does not serve a failure placeholder as an icon" $
            withSystemTempDirectory "eza-favicon" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                _ <- putFavicon conn "example.test" "https://example.test/favicon.ico" "image/png" (BS.pack [0x89, 0x50, 0x4E, 0x47])
                stored <- getFavicon conn "example.test"
                pure (fmap fvMime stored) `shouldReturn` Just "image/png"
                recordFaviconFailure conn "broken.test" "no icon"
                getFavicon conn "broken.test" `shouldReturn` Nothing
                close conn

    describe "schema migration" $ do
        it "backs up a v1 database and migrates it to the current version without losing rows" $
            withSystemTempDirectory "eza-migrate" $ \dir -> do
                let path = dir </> "test.db"
                bracket (Sqlite.open path) Sqlite.close $ \conn -> do
                    mapM_ (Sqlite.execute_ conn) schemaV1
                    Sqlite.execute_ conn "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES ('https://example.test','Example','example.test',1,1,1)"
                    Sqlite.execute_ conn "INSERT INTO tags (name,created_at) VALUES ('test',1)"
                    Sqlite.execute_ conn "INSERT INTO bookmark_tags (bookmark_id,tag_id) VALUES (1,1)"
                    Sqlite.execute_ conn "PRAGMA user_version = 1"
                migrated <- openDb path
                version <- schemaVersion migrated
                version `shouldBe` targetSchemaVersion
                books <- queryScalar migrated "SELECT COUNT(*) FROM bookmarks"
                books `shouldBe` 1
                tags <- queryScalar migrated "SELECT COUNT(*) FROM tags"
                tags `shouldBe` 1
                links <- queryScalar migrated "SELECT COUNT(*) FROM bookmark_tags"
                links `shouldBe` 1
                fts <- queryScalar migrated "SELECT COUNT(*) FROM bookmarks_fts"
                fts `shouldBe` 1
                backups <- listDirectory (dir </> "backups")
                length backups `shouldBe` 1
                close migrated

    describe "save rules" $ do
        it "adds tags and marks a matching save as read" $
            withSystemTempDirectory "eza-rules" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                _ <- createRule conn (Rule 0 "domain rule" True "domain" "example.test" ["ruled"] True 0)
                _ <- insertBookmark conn "https://example.test/rule" "Rule test" []
                _ <- insertBookmark conn "https://other.test/rule" "Other" []
                rules <- listRules conn
                length rules `shouldBe` 1
                matches <- matchingBookmarks conn "domain" "example.test"
                matches `shouldBe` [1]
                page <- listBookmarks conn (defaultListQuery{lqTags = ["ruled"]})
                spTotal page `shouldBe` 1
                detail <- getBookmark conn 1
                fmap bdIsRead detail `shouldBe` Just True
                close conn

    describe "JSON export" $ do
        it "round-trips a bookmark into a new database" $
            withSystemTempDirectory "eza-json" $ \dir -> do
                source <- openDb (dir </> "source.db")
                Sqlite.execute_ source "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES ('https://example.test/json','JSON','example.test',1,1,1)"
                document <- exportJson source
                close source
                target <- openDb (dir </> "target.db")
                result <- importJson target document
                case result of
                    Left err -> expectationFailure (T.unpack err)
                    Right report -> jrBookmarks report `shouldBe` 1
                count <- queryScalar target "SELECT COUNT(*) FROM bookmarks"
                count `shouldBe` 1
                close target

    describe "JSON export version 2" $ do
        it "carries captures and the highlight anchors through a round-trip" $
            withSystemTempDirectory "eza-json-v2" $ \dir -> do
                source <- openDb (dir </> "source.db")
                Sqlite.execute_ source "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at,note_body) VALUES ('https://example.test/v2','V2','example.test',1,1,1,'a note')"
                Sqlite.execute_ source "INSERT INTO highlights (bookmark_id,quote,prefix,suffix,start_offset,end_offset,note,color,created_at,updated_at) VALUES (1,'quote','before ',' after',1,6,'', 'yellow',1,1)"
                Sqlite.execute_ source "INSERT INTO captures (bookmark_id,url,content_html,content_text,captured_at,created_at) VALUES (1,'https://example.test/v2','<p>captured</p>','captured',1,1)"
                document <- exportJson source
                close source
                target <- openDb (dir </> "target.db")
                result <- importJson target document
                case result of
                    Left err -> expectationFailure (T.unpack err)
                    Right report -> do
                        jrBookmarks report `shouldBe` 1
                        jrCaptures report `shouldBe` 1
                captures <- queryScalar target "SELECT COUNT(*) FROM captures"
                captures `shouldBe` 1
                prefix <- Sqlite.query_ target "SELECT prefix, suffix FROM highlights" :: IO [(Text, Text)]
                prefix `shouldBe` [("before ", " after")]
                close target

    describe "tag-aware search" $ do
        it "finds a record by a tag name in free-text search" $
            withSystemTempDirectory "eza-tag-search" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                _ <- insertBookmark conn "https://example.test/rust-only" "No matching words" ["rust", "tooling"]
                _ <- insertBookmark conn "https://example.test/other" "Different words" ["haskell"]
                rust <- listBookmarks conn defaultListQuery{lqQ = "rust"}
                map bsId (spItems rust) `shouldBe` [1]
                both <- listBookmarks conn defaultListQuery{lqQ = "rust tooling"}
                map bsId (spItems both) `shouldBe` [1]
                none <- listBookmarks conn defaultListQuery{lqQ = "rust missing"}
                spTotal none `shouldBe` 0
                close conn

    describe "domain search" $ do
        it "finds a record by its source domain even when the URL omits www" $
            withSystemTempDirectory "eza-domain-search" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                _ <- insertBookmark conn "https://reddit.com/r/haskell" "Unrelated title" []
                _ <- insertBookmark conn "https://example.test/other" "Another record" []
                -- The import keeps the source facet's domain, which can carry a
                -- www prefix the saved URL does not have.
                Sqlite.execute_ conn "UPDATE bookmarks SET domain = 'www.reddit.com' WHERE id = 1"
                byFullDomain <- listBookmarks conn defaultListQuery{lqQ = "www.reddit.com"}
                map bsId (spItems byFullDomain) `shouldBe` [1]
                byBareDomain <- listBookmarks conn defaultListQuery{lqQ = "reddit.com"}
                map bsId (spItems byBareDomain) `shouldBe` [1]
                close conn

    describe "highlights" $ do
        it "creates, lists, updates, and deletes a highlight" $
            withSystemTempDirectory "eza-highlight" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                Sqlite.execute_ conn "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES ('https://example.test/h','H','example.test',1,1,1)"
                bid <- fromIntegral <$> Sqlite.lastInsertRowId conn
                created <- createHighlight conn bid "H" "" "" 0 1 "note" "yellow"
                case created of
                    Left err -> expectationFailure (T.unpack err)
                    Right highlight -> hQuote highlight `shouldBe` "H"
                listed <- listHighlights conn bid
                length listed `shouldBe` 1
                case listed of
                    (highlight : _) -> do
                        updated <- updateHighlight conn bid (hId highlight) (Just "changed") (Just "blue")
                        updated `shouldBe` True
                        deleted <- deleteHighlight conn bid (hId highlight)
                        deleted `shouldBe` True
                    [] -> expectationFailure "expected one highlight"
                close conn

    describe "share links" $ do
        it "resolves a bookmark share, reports a revocation, and renders the gone page" $
            withSystemTempDirectory "eza-share" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                Sqlite.execute_ conn "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES ('https://example.test/s','S','example.test',1,1,1)"
                bid <- fromIntegral <$> Sqlite.lastInsertRowId conn
                shared <- createShare conn "bookmark" bid False 7
                case shared of
                    Left err -> expectationFailure (T.unpack err)
                    Right (sid, raw) -> do
                        record <- resolveShare conn raw
                        fmap srTargetId record `shouldBe` Just bid
                        readable <- resolveShareState conn raw
                        case readable of
                            ShareReadable found -> srTargetId found `shouldBe` bid
                            ShareGone _ -> expectationFailure "expected a readable share"
                        revoked <- revokeShare conn sid
                        revoked `shouldBe` True
                        resolveShare conn raw `shouldReturn` Nothing
                        gone <- resolveShareState conn raw
                        case gone of
                            ShareGone ShareRevoked -> pure ()
                            _ -> expectationFailure "expected a revoked share"
                        shareUnavailablePage ShareRevoked `shouldSatisfy` T.isInfixOf "revoked"
                close conn
        it "reports an expired share as gone and keeps the expiry date" $
            withSystemTempDirectory "eza-share-expired" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                Sqlite.execute_ conn "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES ('https://example.test/e','E','example.test',1,1,1)"
                bid <- fromIntegral <$> Sqlite.lastInsertRowId conn
                shared <- createShare conn "bookmark" bid False 7
                case shared of
                    Left err -> expectationFailure (T.unpack err)
                    Right (shareId, raw) -> do
                        Sqlite.execute conn "UPDATE share_links SET expires_at = 1 WHERE id = ?" (Sqlite.Only shareId)
                        state <- resolveShareState conn raw
                        case state of
                            ShareGone (ShareExpired expiry) -> expiry `shouldBe` 1
                            _ -> expectationFailure "expected an expired share"
                        shareUnavailablePage (ShareExpired 1700000000) `shouldSatisfy` T.isInfixOf "2023.11.14"
                close conn

    describe "parseSearchQuery" $ do
        it "extracts tags and unread" $ do
            let q = parseSearchQuery "rust tag:code is:unread"
            sqTags q `shouldBe` ["code"]
            sqIsUnread q `shouldBe` True
            sqFts q `shouldBe` Just "\"rust\"*"
        it "drops malformed operators" $ do
            let q = parseSearchQuery "tag: is:whatever -web"
            sqTags q `shouldBe` []
            sqIsUnread q `shouldBe` False
            sqNegated q `shouldBe` ["web"]
        it "extracts year and day filters without treating them as search terms" $ do
            let q = parseSearchQuery "rust year:2023 day:2023-11-14"
            sqYear q `shouldBe` Just 2023
            sqDay q `shouldBe` Just "2023-11-14"
            sqFts q `shouldBe` Just "\"rust\"*"
            sqTerms q `shouldBe` ["rust"]
            sqDay (parseSearchQuery "day:2024-02-29") `shouldBe` Just "2024-02-29"
        it "drops malformed year and day filters silently" $ do
            let q = parseSearchQuery "year:23 year:20233 day:2023-13-01 day:2023-02-30 day:2023-02-29 day:2023-1-04 rust"
            sqYear q `shouldBe` Nothing
            sqDay q `shouldBe` Nothing
            sqTerms q `shouldBe` ["rust"]

    describe "Netscape import" $ do
        it "debug fixture" $ do
            raw <- BS.readFile (".." </> "tests" </> "fixtures" </> "mini-bookmarks.html")
            let p = parseNetscape defaultImportOptions raw
            piUntagged p `shouldBe` 1
            map (iiTags . snd) (zip [1 :: Int ..] (piItems p)) `shouldBe` [["toolbar", "rust"], ["rust"], []]
        it "collapses duplicate anchors, folds folders into tags, and skips noise" $ do
            raw <- BS.readFile (".." </> "tests" </> "fixtures" </> "mini-bookmarks.html")
            let p = parseNetscape defaultImportOptions raw
            piFound p `shouldBe` 5
            piHttp p `shouldBe` 4
            piNonHttp p `shouldBe` 1
            piDuplicates p `shouldBe` 1
            length (piItems p) `shouldBe` 3
            piUntagged p `shouldBe` 1
            piFoldersSkipped p `shouldBe` 1

        it "imports into SQLite and searches the result" $
            withSystemTempDirectory "eza-test" $ \dir -> do
                raw <- BS.readFile (".." </> "tests" </> "fixtures" </> "mini-bookmarks.html")
                bracket (openDb (dir </> "test.db")) close $ \conn -> do
                    let parsed = parseNetscape defaultImportOptions raw
                    report <- importParsed conn defaultImportOptions parsed
                    irInserted report `shouldBe` 3
                    irTagsCreated report `shouldBe` 2
                    irTagLinksAdded report `shouldBe` 3
                    stats <- bookmarkStats conn
                    lookup "bookmarks" stats `shouldBe` Just 3
                    lookup "tags" stats `shouldBe` Just 2
                    page <- listBookmarks conn (defaultListQuery{lqQ = ""})
                    spTotal page `shouldBe` 3
                    rust <- listBookmarks conn (defaultListQuery{lqTags = ["rust"]})
                    spTotal rust `shouldBe` 2
                    fts <- listBookmarks conn (defaultListQuery{lqQ = "B"})
                    spTotal fts `shouldBe` 1
                    enrichJobs <- queryScalar conn "SELECT COUNT(*) FROM jobs WHERE kind = 'enrich' AND state = 'queued'"
                    enrichJobs `shouldBe` 3
                    tagged <- listBookmarks conn (defaultListQuery{lqTags = ["toolbar"]})
                    spTotal tagged `shouldBe` 1
                    case map bsId (spItems tagged) of
                        (firstId : _) -> do
                            detail <- getBookmark conn firstId
                            case detail of
                                Nothing -> expectationFailure "expected bookmark detail"
                                Just d -> bdTags d `shouldContain` ["toolbar"]
                        [] -> expectationFailure "expected a tagged bookmark"

    describe "import pre-deduplication" $ do
        it "collapses http/https variants in the file before writing a row" $ do
            let raw =
                    BSC.pack
                        ( "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n"
                            <> "<DT><A HREF=\"http://example.com/page\" ADD_DATE=\"1700000000\" TAGS=\"alpha\">A http</A>\n"
                            <> "<DT><A HREF=\"https://example.com/page#section\" ADD_DATE=\"1700000001\" TAGS=\"beta\">A https</A>\n"
                            <> "</DL><p>\n"
                        )
                parsed = parseNetscape defaultImportOptions raw
            piDuplicates parsed `shouldBe` 1
            length (piItems parsed) `shouldBe` 1
            map iiUrl (piItems parsed) `shouldBe` [T.pack "https://example.com/page"]
            map iiTags (piItems parsed) `shouldBe` [[T.pack "alpha", T.pack "beta"]]

        it "merges a re-import into the existing canonical row and records the run" $
            withSystemTempDirectory "eza-dedupe-import" $ \dir ->
                bracket (openDb (dir </> "test.db")) close $ \conn -> do
                    existing <- insertRawBookmark conn (T.pack "https://example.com/page") (T.pack "Existing")
                    let raw =
                            BSC.pack
                                ( "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n"
                                    <> "<DT><A HREF=\"http://example.com/page\" TAGS=\"alpha\">A http</A>\n"
                                    <> "</DL><p>\n"
                                )
                        parsed = parseNetscape defaultImportOptions raw
                    report <- importParsed conn defaultImportOptions parsed
                    irInserted report `shouldBe` 0
                    irExisting report `shouldBe` 1
                    bookmarkCount conn `shouldReturn` 1
                    bookmarkUrlAt conn existing `shouldReturn` T.pack "https://example.com/page"
                    bookmarkTagNames conn existing `shouldReturn` [T.pack "alpha"]
                    runs <- Sqlite.query_ conn "SELECT COUNT(*) FROM import_runs" :: IO [Sqlite.Only Int]
                    runs `shouldBe` [Sqlite.Only 1]

        it "heals a legacy fragment URL when the importer matches it" $
            withSystemTempDirectory "eza-dedupe-heal" $ \dir ->
                bracket (openDb (dir </> "test.db")) close $ \conn -> do
                    existing <- insertRawBookmark conn (T.pack "https://example.com/legacy#/section") (T.pack "Legacy")
                    let raw =
                            BSC.pack
                                ( "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n"
                                    <> "<DT><A HREF=\"https://example.com/legacy\">Legacy clean</A>\n"
                                    <> "</DL><p>\n"
                                )
                        parsed = parseNetscape defaultImportOptions raw
                    report <- importParsed conn defaultImportOptions parsed
                    irInserted report `shouldBe` 0
                    irExisting report `shouldBe` 1
                    bookmarkUrlAt conn existing `shouldReturn` T.pack "https://example.com/legacy"

    describe "library stats" $ do
        it "counts rows, sources, top sources, years, and filing days" $
            withSystemTempDirectory "eza-stats" $ \dir -> do
                raw <- BS.readFile (".." </> "tests" </> "fixtures" </> "mini-bookmarks.html")
                bracket (openDb (dir </> "test.db")) close $ \conn -> do
                    let parsed = parseNetscape defaultImportOptions raw
                    _ <- importParsed conn defaultImportOptions parsed
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

    describe "year and day filters" $ do
        it "filters the ledger by the UTC filed date" $
            withSystemTempDirectory "eza-date-filter" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                first <- insertFiledBookmark conn "https://d.test/a" "A" "d.test" 1700000000 0 -- 2023-11-14T22:13:20Z
                second <- insertFiledBookmark conn "https://d.test/b" "B" "d.test" 1699999999 0 -- 2023-11-14T22:13:19Z
                monthEnd <- insertFiledBookmark conn "https://d.test/c" "C" "d.test" 1701388799 0 -- 2023-11-30T23:59:59Z
                monthStart <- insertFiledBookmark conn "https://d.test/d" "D" "d.test" 1701388800 0 -- 2023-12-01T00:00:00Z
                fifth <- insertFiledBookmark conn "https://d.test/e" "E" "d.test" 1717200000 0 -- 2024-06-01T00:00:00Z
                _ <- insertFiledBookmark conn "https://d.test/epoch" "Epoch" "d.test" 0 0
                attachTag conn first "rust"
                attachTag conn fifth "rust"
                year2023 <- listBookmarks conn (defaultListQuery{lqQ = "year:2023"})
                spTotal year2023 `shouldBe` 4
                spYearCounts year2023 `shouldBe` [(2023, 4)]
                map bsId (spItems year2023) `shouldBe` [monthStart, monthEnd, first, second]
                year2024 <- listBookmarks conn (defaultListQuery{lqQ = "year:2024"})
                spTotal year2024 `shouldBe` 1
                map bsId (spItems year2024) `shouldBe` [fifth]
                nov14 <- listBookmarks conn (defaultListQuery{lqQ = "day:2023-11-14"})
                spTotal nov14 `shouldBe` 2
                map bsId (spItems nov14) `shouldBe` [first, second]
                monthEndDay <- listBookmarks conn (defaultListQuery{lqQ = "day:2023-11-30"})
                spTotal monthEndDay `shouldBe` 1
                map bsId (spItems monthEndDay) `shouldBe` [monthEnd]
                monthStartDay <- listBookmarks conn (defaultListQuery{lqQ = "day:2023-12-01"})
                spTotal monthStartDay `shouldBe` 1
                map bsId (spItems monthStartDay) `shouldBe` [monthStart]
                -- created_at = 0 has no UTC filing date, so it is not a 1970 row.
                epochYear <- listBookmarks conn (defaultListQuery{lqQ = "year:1970"})
                spTotal epochYear `shouldBe` 0
                epochDay <- listBookmarks conn (defaultListQuery{lqQ = "day:1970-01-01"})
                spTotal epochDay `shouldBe` 0
                -- The date predicate ANDs with the other filters.
                combined <- listBookmarks conn (defaultListQuery{lqQ = "year:2023 tag:rust"})
                spTotal combined `shouldBe` 1
                spYearCounts combined `shouldBe` [(2023, 1)]
                map bsId (spItems combined) `shouldBe` [first]
                taggedYear <- listBookmarks conn (defaultListQuery{lqQ = "year:2024 tag:rust", lqTags = ["rust"]})
                spTotal taggedYear `shouldBe` 1
                map bsId (spItems taggedYear) `shouldBe` [fifth]
                close conn

        it "keeps FTS snippets after a date filter" $
            withSystemTempDirectory "eza-date-snippet" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                first <- insertFiledBookmark conn "https://d.test/s" "S" "d.test" 1700000000 0
                _ <- insertFiledBookmark conn "https://d.test/t" "T" "d.test" 1717200000 0
                Sqlite.execute conn "UPDATE bookmarks SET note_body = 'hello rustacean world' WHERE id = ?" (Sqlite.Only first)
                page <- listBookmarks conn (defaultListQuery{lqQ = "rustacean day:2023-11-14"})
                spTotal page `shouldBe` 1
                case spItems page of
                    (item : _) -> bsSnippet item `shouldSatisfy` maybe False (T.isInfixOf "rustacean")
                    [] -> expectationFailure "expected the dated search to find the bookmark"
                close conn

    describe "searched list ordering" $ do
        it "orders full-text matches by created_at, not by rank" $
            withSystemTempDirectory "eza-search-sort-created" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                old <- insertFiledBookmark conn "https://s.test/old" "Rust old" "s.test" 1672531200 0
                middle <- insertFiledBookmark conn "https://s.test/middle" "Rust middle" "s.test" 1700000000 0
                recent <- insertFiledBookmark conn "https://s.test/recent" "Rust recent" "s.test" 1717200000 0
                page <- listBookmarks conn (defaultListQuery{lqQ = "Rust"})
                map bsId (spItems page) `shouldBe` [recent, middle, old]
                close conn

        it "orders a searched list by added_at when asked" $
            withSystemTempDirectory "eza-search-sort-added" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                first <- insertFiledBookmark conn "https://s.test/a" "Rust a" "s.test" 1700000000 0
                second <- insertFiledBookmark conn "https://s.test/b" "Rust b" "s.test" 1700000001 0
                third <- insertFiledBookmark conn "https://s.test/c" "Rust c" "s.test" 1700000002 0
                setAddedAt conn first 300
                setAddedAt conn second 100
                setAddedAt conn third 200
                page <- listBookmarks conn (defaultListQuery{lqQ = "Rust", lqSort = "added"})
                map bsId (spItems page) `shouldBe` [first, third, second]
                close conn

        it "orders a searched list by last_opened_at when asked" $
            withSystemTempDirectory "eza-search-sort-opened" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                first <- insertFiledBookmark conn "https://s.test/a" "Rust a" "s.test" 1700000000 0
                second <- insertFiledBookmark conn "https://s.test/b" "Rust b" "s.test" 1700000001 0
                third <- insertFiledBookmark conn "https://s.test/c" "Rust c" "s.test" 1700000002 0
                setLastOpenedAt conn first 100
                setLastOpenedAt conn third 200
                page <- listBookmarks conn (defaultListQuery{lqQ = "Rust", lqSort = "opened"})
                map bsId (spItems page) `shouldBe` [third, first, second]
                close conn

        it "keeps tag-name fallback matches after the full-text hits" $
            withSystemTempDirectory "eza-search-sort-fallback" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                textHit <- insertFiledBookmark conn "https://s.test/text" "Rust notes" "s.test" 1672531200 0
                fallback <- insertFiledBookmark conn "https://s.test/tag" "Unrelated record" "s.test" 1790000000 0
                attachTag conn fallback "rust"
                page <- listBookmarks conn (defaultListQuery{lqQ = "rust"})
                spTotal page `shouldBe` 2
                map bsId (spItems page) `shouldBe` [textHit, fallback]
                close conn

    describe "global graph" $ do
        it "returns an empty graph for an empty database" $
            withSystemTempDirectory "eza-graph-empty" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                globalGraph conn `shouldReturn` GraphData [] [] [] "0:0:0:0:0"
                close conn

        it "orders tags by count and name and points records at their tag indexes" $
            withSystemTempDirectory "eza-graph-populated" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                first <- insertFiledBookmark conn "https://g.test/a" "A" "g.test" 1700000000 0
                second <- insertFiledBookmark conn "https://g.test/b" "" "g.test" 1700000001 1
                third <- insertFiledBookmark conn "https://g.test/c" "C" "g.test" 1700000002 0
                _ <- Sqlite.execute conn "UPDATE bookmarks SET is_dead = 1 WHERE id = ?" (Sqlite.Only second)
                attachTag conn first "rust"
                attachTag conn first "toolbar"
                attachTag conn second "rust"
                attachTag conn third "alpha"
                attachTag conn third "zeta"
                insertLink conn first second
                insertLink conn second third
                Sqlite.execute conn "INSERT INTO links (source_id, target_id, target_title) VALUES (?,NULL,'unresolved')" (Sqlite.Only first)
                -- A dangling endpoint can only exist in a database written
                -- with foreign keys off. The payload still has to drop it.
                Sqlite.execute_ conn "PRAGMA foreign_keys = OFF"
                insertLink conn first 9999
                insertLink conn 9998 third
                Sqlite.execute_ conn "PRAGMA foreign_keys = ON"
                graph <- globalGraph conn
                gdTags graph `shouldBe` [GraphTag "rust" 2, GraphTag "alpha" 1, GraphTag "toolbar" 1, GraphTag "zeta" 1]
                gdRecords graph
                    `shouldBe` [ GraphRecord first "A" "g.test" 1700000000 False False [0, 2]
                               , GraphRecord second "g.test" "g.test" 1700000001 True True [0]
                               , GraphRecord third "C" "g.test" 1700000002 False False [1, 3]
                               ]
                gdLinks graph `shouldBe` [GraphLink first second, GraphLink second third]
                gdRevision graph `shouldBe` "3:" <> T.pack (show (1700000002 :: Int)) <> ":4:5:4"
                -- Touching a record changes the revision; unrelated reads do not.
                revBefore <- graphRevision conn
                graphAgain <- globalGraph conn
                gdRevision graphAgain `shouldBe` revBefore
                _ <- Sqlite.execute conn "UPDATE bookmarks SET title = 'A2', updated_at = 1700000010 WHERE id = ?" (Sqlite.Only first)
                changed <- graphRevision conn
                changed `shouldNotBe` revBefore
                close conn

        it "round-trips through the compact array JSON" $ do
            let graph =
                    GraphData
                        [GraphTag "rust" 2, GraphTag "toolbar" 1]
                        [ GraphRecord 7 "Title" "example.com" 1700000000 True False [0, 1]
                        , GraphRecord 8 "example.com" "example.com" 0 False True []
                        ]
                        [GraphLink 7 8]
                        "r1:3:4:5:2"
                wire =
                    "{\"tags\":[[\"rust\",2],[\"toolbar\",1]],"
                        <> "\"records\":[[7,\"Title\",\"example.com\",1700000000,true,false,[0,1]],"
                        <> "[8,\"example.com\",\"example.com\",0,false,true,[]]],"
                        <> "\"links\":[[7,8]],"
                        <> "\"revision\":\"r1:3:4:5:2\"}"
            decode (encode graph) `shouldBe` Just graph
            (decode wire :: Maybe GraphData) `shouldBe` Just graph
            -- Older payloads had no revision; the decoder defaults it.
            (decode "{\"tags\":[],\"records\":[],\"links\":[]}" :: Maybe GraphData)
                `shouldBe` Just (GraphData [] [] [] "")
            -- The compact shapes cannot drift: tag 2, record 7, link 2.
            arrayLength (toJSON (GraphTag "rust" 2)) `shouldBe` Just 2
            arrayLength (toJSON (GraphRecord 7 "Title" "example.com" 1700000000 True False [0, 1])) `shouldBe` Just 7
            arrayLength (toJSON (GraphLink 7 8)) `shouldBe` Just 2

    describe "graph layout payload" $ do
        it "ships quantized positions for one preset with the graph revision" $
            withSystemTempDirectory "eza-graph-layout" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                first <- insertFiledBookmark conn "https://l.test/a" "A" "l.test" 1700000000 0
                second <- insertFiledBookmark conn "https://l.test/b" "B" "l.test" 1700000001 0
                attachTag conn first "rust"
                attachTag conn second "rust"
                insertLink conn first second
                graph <- globalGraph conn
                let payload = graphLayoutPayload Standard graph
                glpSchema payload `shouldBe` 1
                glpRevision payload `shouldBe` gdRevision graph
                glpPreset payload `shouldBe` Standard
                length (glpTags payload) `shouldBe` 1
                length (glpRecords payload) `shouldBe` 2
                let (minX, minY, maxX, maxY) = glpBounds payload
                minX <= maxX `shouldBe` True
                minY <= maxY `shouldBe` True
                -- Every coordinate is a whole number of hundredths.
                let quantized value =
                        (value * 100) `shouldBe` (fromIntegral (round (value * 100) :: Int) :: Double)
                mapM_ quantized (concatMap (\(x, y) -> [x, y]) (glpTags payload <> glpRecords payload) <> [minX, minY, maxX, maxY])
                close conn

        it "encodes the documented layout object" $ do
            let graph =
                    GraphData
                        [GraphTag "rust" 2]
                        [GraphRecord 1 "A" "a.test" 1700000000 False False [0]]
                        []
                        "r1"
            case toJSON (graphLayoutPayload Compact graph) of
                Object objectValue -> do
                    KeyMap.lookup "schema" objectValue `shouldBe` Just (toJSON (1 :: Int))
                    KeyMap.lookup "preset" objectValue `shouldBe` Just (toJSON ("compact" :: Text))
                    KeyMap.lookup "revision" objectValue `shouldBe` Just (toJSON ("r1" :: Text))
                    case KeyMap.lookup "tags" objectValue of
                        Just (Array tags) -> case toList tags of
                            [pair] -> case pair of
                                Array coordinates -> length coordinates `shouldBe` 2
                                _ -> expectationFailure "a tag position must be an [x,y] array"
                            _ -> expectationFailure "one tag tag position expected"
                        _ -> expectationFailure "tags must be an array of [x,y] pairs"
                    case KeyMap.lookup "records" objectValue of
                        Just (Array recordsValue) -> length recordsValue `shouldBe` 1
                        _ -> expectationFailure "records must be an array"
                    case KeyMap.lookup "bounds" objectValue of
                        Just (Array bounds) -> length bounds `shouldBe` 4
                        _ -> expectationFailure "bounds must be a four-element array"
                _ -> expectationFailure "layout payload must be a JSON object"

        it "parses every preset name and rejects the rest" $ do
            layoutPresetFromText "compact" `shouldBe` Just Compact
            layoutPresetFromText " Standard " `shouldBe` Just Standard
            layoutPresetFromText "airy" `shouldBe` Just Airy
            layoutPresetFromText "huge" `shouldBe` Nothing
            map layoutPresetText [Compact, Standard, Airy] `shouldBe` ["compact", "standard", "airy"]

        it "sizes the presets compact < standard < airy" $ do
            let graph =
                    GraphData
                        [GraphTag "rust" 2, GraphTag "toolbar" 1]
                        [ GraphRecord 1 "A" "a.test" 1700000000 False False [0, 1]
                        , GraphRecord 2 "B" "b.test" 1700000001 False False [0]
                        ]
                        [GraphLink 1 2]
                        "r1"
                spanOf payload =
                    let (minX, minY, maxX, maxY) = glpBounds payload
                     in max (maxX - minX) (maxY - minY)
                spans = map (spanOf . (`graphLayoutPayload` graph)) [Compact, Standard, Airy]
            spans
                `shouldSatisfy` ( \values -> case values of
                                    [compactSpan, standardSpan, airySpan] -> compactSpan < standardSpan && standardSpan < airySpan
                                    _ -> False
                                )

        it "caches one payload per revision and preset" $ do
            let graph =
                    GraphData
                        [GraphTag "rust" 2]
                        [GraphRecord 1 "A" "a.test" 1700000000 False False [0]]
                        []
                        "r1"
                built = graphLayoutPayload Standard graph
                cached = storeCachedLayout "r1" Standard built emptyLayoutCache
            lookupCachedLayout "r1" Standard emptyLayoutCache `shouldBe` Nothing
            lookupCachedLayout "r1" Standard cached `shouldBe` Just built
            lookupCachedLayout "r2" Standard cached `shouldBe` Nothing
            lookupCachedLayout "r1" Compact cached `shouldBe` Nothing
            let replaced = storeCachedLayout "r2" Standard built cached
            lookupCachedLayout "r2" Standard replaced `shouldBe` Just built
            lookupCachedLayout "r1" Standard replaced `shouldBe` Nothing

    describe "full export counts" $ do
        it "matches the analysed 2026-08 export" $ do
            mpath <- lookupEnv "EZA_IMPORT_FIXTURE"
            case mpath of
                Nothing -> pendingWith "set EZA_IMPORT_FIXTURE to run the full-file acceptance test"
                Just path -> do
                    exists <- doesFileExist path
                    if not exists
                        then pendingWith ("EZA_IMPORT_FIXTURE does not exist: " <> path)
                        else do
                            raw <- BS.readFile path
                            let p = parseNetscape defaultImportOptions raw
                            piFound p `shouldBe` 9457
                            piHttp p `shouldBe` 9453
                            piNonHttp p `shouldBe` 4
                            -- Normalizes www., fragments, tracking parameters
                            -- and trailing slashes before deduplicating, so
                            -- this is higher than the 465 raw duplicate
                            -- anchors.
                            piDuplicates p `shouldBe` 548
                            length (piItems p) `shouldBe` 8905
                            piUntagged p `shouldBe` 238
        it "parses the deterministic export slice with the default leaf mode" $ do
            let path = ".." </> "tests" </> "fixtures" </> "export-slice.html"
            exists <- doesFileExist path
            if not exists
                then pendingWith ("tests/fixtures/export-slice.html is not present: " <> path)
                else do
                    raw <- BS.readFile path
                    let p = parseNetscape defaultImportOptions raw
                    piFound p `shouldBe` 14
                    piHttp p `shouldBe` 12
                    piNonHttp p `shouldBe` 2
                    piDuplicates p `shouldBe` 4
                    length (piItems p) `shouldBe` 8

    describe "password hashing" $ do
        it "round-trips a password and rejects a wrong one" $
            withSystemTempDirectory "eza-password" $ \_dir -> do
                let params = Password.PasswordParams 1024 1 1
                stored <- Password.hashPassword params "correct horse battery"
                T.isPrefixOf "$argon2id$v=19$m=1024,t=1,p=1$" stored `shouldBe` True
                Password.verifyPassword params stored "correct horse battery" `shouldReturn` True
                Password.verifyPassword params stored "correct horse batterY" `shouldReturn` False
        it "asks for a rehash when the configured cost changes" $ do
            let weak = Password.PasswordParams 1024 1 1
                strong = Password.PasswordParams 65536 3 2
            stored <- Password.hashPassword weak "correct horse battery"
            Password.needsRehash strong stored `shouldBe` True
            Password.needsRehash weak stored `shouldBe` False
            Password.needsRehash weak "not-a-phc-string" `shouldBe` True
        it "validates usernames and password lengths" $ do
            Password.validateUsername "  owner  " `shouldBe` Right "owner"
            Password.validateUsername "  " `shouldSatisfy` isLeft
            Password.validateUsername "bad name" `shouldSatisfy` isLeft
            Password.validatePassword "short" `shouldSatisfy` isLeft
            Password.validatePassword "long enough" `shouldBe` Right ()

    describe "schema v6 migration" $ do
        it "keeps v5 rows and adds the account columns" $
            withSystemTempDirectory "eza-v6" $ \dir -> do
                let path = dir </> "test.db"
                bracket (Sqlite.open path) Sqlite.close $ \conn -> do
                    mapM_ (Sqlite.execute_ conn) (schemaV1 <> schemaV2 <> schemaV3 <> schemaV4 <> schemaV5)
                    Sqlite.execute_ conn "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES ('https://example.test/v5','V5','example.test',1,1,1)"
                    Sqlite.execute_ conn "UPDATE app_state SET setup_claimed = 1 WHERE id = 1"
                    Sqlite.execute_ conn "INSERT INTO recovery_codes (code_hash,used,created_at) VALUES ('deadbeef',0,1)"
                    Sqlite.execute_ conn "PRAGMA user_version = 5"
                migrated <- openDb path
                version <- schemaVersion migrated
                version `shouldBe` targetSchemaVersion
                books <- queryScalar migrated "SELECT COUNT(*) FROM bookmarks"
                books `shouldBe` 1
                claimed <- queryScalar migrated "SELECT setup_claimed FROM app_state WHERE id = 1"
                claimed `shouldBe` 1
                account <- Auth.loadAccount migrated
                Auth.acctUsername account `shouldBe` ""
                Auth.accountHasPassword account `shouldBe` False
                Auth.acctRequirePasskey account `shouldBe` False
                codes <- Auth.recoveryCodesRemaining migrated
                codes `shouldBe` 1
                close migrated
        it "keeps a legacy passkey database in legacy passkey mode" $
            withSystemTempDirectory "eza-legacy" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                Sqlite.execute_ conn "UPDATE app_state SET setup_claimed = 1 WHERE id = 1"
                Sqlite.execute_ conn "INSERT INTO passkey_credentials (credential_id,user_handle,public_key,created_at) VALUES (x'01',x'02',x'03',1)"
                allowed <- Auth.setupAllowed conn
                allowed `shouldBe` False
                configured <- Auth.accountConfigured conn
                configured `shouldBe` False
                legacy <- Auth.legacyPasskeyLoginAllowed conn
                legacy `shouldBe` True
                close conn

    describe "password login" $ do
        it "opens a session with the configured TTL and expires it" $
            withSystemTempDirectory "eza-login" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                let params = Password.PasswordParams 1024 1 1
                    ac = testAuthConfig params 3600 3 900
                stored <- Password.hashPassword params "correct horse battery"
                Auth.setAccountPassword conn "owner" stored
                configured <- Auth.accountConfigured conn
                configured `shouldBe` True
                result <- Auth.verifyPasswordLogin conn ac "owner" "correct horse battery"
                case result of
                    Left err -> expectationFailure ("login failed: " <> T.unpack (Auth.aeCode err))
                    Right (Auth.LoginNeedsPasskey _) -> expectationFailure "expected a normal session when two-factor is off"
                    Right (Auth.LoginComplete sess) -> do
                        Auth.nsScope sess `shouldBe` "normal"
                        Auth.nsTtlSeconds sess `shouldBe` 3600
                        found <- Auth.getSession conn (Auth.nsToken sess)
                        fmap Auth.sessScope found `shouldBe` Just "normal"
                        case found of
                            Nothing -> expectationFailure "expected a session"
                            Just active -> do
                                Sqlite.execute conn "UPDATE sessions SET expires_at = 1 WHERE id = ?" (Sqlite.Only (Auth.sessId active))
                                expired <- Auth.getSession conn (Auth.nsToken sess)
                                expired `shouldBe` Nothing
                close conn
        it "locks after the configured failures and reports Retry-After" $
            withSystemTempDirectory "eza-lockout" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                let params = Password.PasswordParams 1024 1 1
                    ac = testAuthConfig params 3600 3 900
                stored <- Password.hashPassword params "correct horse battery"
                Auth.setAccountPassword conn "owner" stored
                first <- Auth.verifyPasswordLogin conn ac "owner" "wrong password one"
                authStatus first `shouldBe` 401
                second <- Auth.verifyPasswordLogin conn ac "owner" "wrong password two"
                authStatus second `shouldBe` 401
                third <- Auth.verifyPasswordLogin conn ac "owner" "wrong password three"
                authStatus third `shouldBe` 429
                retryAfter third `shouldBe` Just 900
                locked <- Auth.verifyPasswordLogin conn ac "owner" "correct horse battery"
                authStatus locked `shouldBe` 429
                Sqlite.execute_ conn "UPDATE app_state SET login_blocked_until = 1 WHERE id = 1"
                unlocked <- Auth.verifyPasswordLogin conn ac "owner" "correct horse battery"
                authStatus unlocked `shouldBe` 200
                close conn
        it "rejects an unknown username with the same generic error" $
            withSystemTempDirectory "eza-login-unknown" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                let params = Password.PasswordParams 1024 1 1
                    ac = testAuthConfig params 3600 5 900
                stored <- Password.hashPassword params "correct horse battery"
                Auth.setAccountPassword conn "owner" stored
                result <- Auth.verifyPasswordLogin conn ac "other" "correct horse battery"
                authStatus result `shouldBe` 401
                close conn

    describe "recovery codes" $ do
        it "redeems a code, clears the password and passkeys, and rotates the codes on setup" $
            withSystemTempDirectory "eza-recovery" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                let params = Password.PasswordParams 1024 1 1
                stored <- Password.hashPassword params "correct horse battery"
                codes <- Auth.completeSetup conn "owner" stored
                length codes `shouldBe` 10
                Sqlite.execute_ conn "INSERT INTO passkey_credentials (credential_id,user_handle,public_key,created_at) VALUES (x'01',x'02',x'03',1)"
                case codes of
                    (firstCode : secondCode : _) -> do
                        redeemed <- Auth.redeemRecoveryCode conn firstCode
                        case redeemed of
                            Left err -> expectationFailure ("redeem failed: " <> T.unpack (Auth.aeCode err))
                            Right sess -> Auth.nsScope sess `shouldBe` "recovery"
                        passkeys <- Auth.countCredentials conn
                        passkeys `shouldBe` 0
                        account <- Auth.loadAccount conn
                        Auth.accountHasPassword account `shouldBe` False
                        recoverable <- Auth.setupAllowed conn
                        recoverable `shouldBe` True
                        freshHash <- Password.hashPassword params "another good password"
                        _ <- Auth.completeSetup conn "owner" freshHash
                        remaining <- Auth.recoveryCodesRemaining conn
                        remaining `shouldBe` 10
                        stale <- Auth.redeemRecoveryCode conn secondCode
                        authStatus stale `shouldBe` 400
                    _ -> expectationFailure "expected at least two recovery codes"
                close conn

    describe "legacy passkey retirement" $ do
        it "stops passkey login and setup once a password exists" $
            withSystemTempDirectory "eza-retire" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                let params = Password.PasswordParams 1024 1 1
                Sqlite.execute_ conn "UPDATE app_state SET setup_claimed = 1 WHERE id = 1"
                Sqlite.execute_ conn "INSERT INTO passkey_credentials (credential_id,user_handle,public_key,created_at) VALUES (x'01',x'02',x'03',1)"
                legacyBefore <- Auth.legacyPasskeyLoginAllowed conn
                legacyBefore `shouldBe` True
                stored <- Password.hashPassword params "correct horse battery"
                Auth.setAccountPassword conn "owner" stored
                legacyAfter <- Auth.legacyPasskeyLoginAllowed conn
                legacyAfter `shouldBe` False
                stillAllowed <- Auth.setupAllowed conn
                stillAllowed `shouldBe` False
                removed <- Auth.deleteCredential conn (BS.pack [0x01])
                removed `shouldBe` Right ()
                close conn

    describe "passkey two-factor" $ do
        it "refuses to enable two-factor without a passkey or the current password" $
            withSystemTempDirectory "eza-2fa-enable" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                let params = testPasswordParams
                    ac = testAuthConfig params 3600 5 900
                seedPasswordAccount conn params
                withoutPasskey <- Auth.setTwoFactorRequirement conn ac True "correct horse battery"
                authStatus withoutPasskey `shouldBe` 409
                account <- Auth.loadAccount conn
                Auth.acctRequirePasskey account `shouldBe` False
                insertTestCredential conn (BS.pack [0x01])
                wrongPassword <- Auth.setTwoFactorRequirement conn ac True "wrong password"
                authStatus wrongPassword `shouldBe` 403
                stillOff <- Auth.loadAccount conn
                Auth.acctRequirePasskey stillOff `shouldBe` False
                wrongDisable <- Auth.setTwoFactorRequirement conn ac False "wrong password"
                authStatus wrongDisable `shouldBe` 403
                enabled <- Auth.setTwoFactorRequirement conn ac True "correct horse battery"
                case enabled of
                    Left err -> expectationFailure ("enabling two-factor failed: " <> T.unpack (Auth.aeCode err))
                    Right accountAfter -> Auth.acctRequirePasskey accountAfter `shouldBe` True
                required <- Auth.twoFactorRequired conn
                required `shouldBe` True
                disabled <- Auth.setTwoFactorRequirement conn ac False "correct horse battery"
                case disabled of
                    Left err -> expectationFailure ("disabling two-factor failed: " <> T.unpack (Auth.aeCode err))
                    Right accountOff -> Auth.acctRequirePasskey accountOff `shouldBe` False
                close conn
        it "keeps passkey enrollment available for a password account" $
            withSystemTempDirectory "eza-2fa-enroll" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                let params = testPasswordParams
                    ac = testAuthConfig params 3600 5 900
                seedPasswordAccount conn params
                options <- Auth.addPasskeyOptions conn ac (BS.pack [0x01])
                case options of
                    Left err -> expectationFailure ("passkey options were retired: " <> T.unpack (Auth.aeCode err))
                    Right _ -> pure ()
                challenges <- queryScalar conn "SELECT COUNT(*) FROM webauthn_challenges WHERE purpose = 'registration'"
                challenges `shouldBe` 1
                insertTestCredential conn (BS.pack [0x02])
                off <- Auth.secondFactorOptions conn ac
                authStatus off `shouldBe` 403
                _ <- Auth.setTwoFactorRequirement conn ac True "correct horse battery"
                on <- Auth.secondFactorOptions conn ac
                case on of
                    Left err -> expectationFailure ("second-factor options failed: " <> T.unpack (Auth.aeCode err))
                    Right _ -> pure ()
                secondFactorChallenges <- queryScalar conn "SELECT COUNT(*) FROM webauthn_challenges WHERE purpose = 'second_factor'"
                secondFactorChallenges `shouldBe` 1
                close conn
        it "runs a password login through a pending passkey session" $
            withSystemTempDirectory "eza-2fa-pending" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                let params = testPasswordParams
                    ac = testAuthConfig params 3600 5 900
                seedPasswordAccount conn params
                insertTestCredential conn (BS.pack [0x01])
                _ <- Auth.setTwoFactorRequirement conn ac True "correct horse battery"
                result <- Auth.verifyPasswordLogin conn ac "owner" "correct horse battery"
                case result of
                    Left err -> expectationFailure ("login failed: " <> T.unpack (Auth.aeCode err))
                    Right (Auth.LoginComplete _) -> expectationFailure "expected a pending session while two-factor is on"
                    Right (Auth.LoginNeedsPasskey pendingLogin) -> do
                        Auth.nsScope pendingLogin `shouldBe` Auth.pendingScope
                        Auth.nsTtlSeconds pendingLogin `shouldBe` Auth.pendingSessionTtlSeconds
                        found <- Auth.getSession conn (Auth.nsToken pendingLogin)
                        case found of
                            Nothing -> expectationFailure "expected a pending session row"
                            Just pendingSession -> do
                                Auth.sessScope pendingSession `shouldBe` Auth.pendingScope
                                -- A normal session cannot be completed as pending.
                                normalOnly <- Auth.createSession conn "normal" 60
                                normalFound <- Auth.getSession conn (Auth.nsToken normalOnly)
                                case normalFound of
                                    Nothing -> expectationFailure "expected a normal session row"
                                    Just normalSession -> do
                                        refused <- Auth.completePendingLogin conn ac normalSession
                                        authStatus refused `shouldBe` 400
                                garbage <- Auth.verifySecondFactor conn ac (object [])
                                authStatus garbage `shouldBe` 400
                                completed <- Auth.completePendingLogin conn ac pendingSession
                                case completed of
                                    Left err -> expectationFailure ("completing the pending session failed: " <> T.unpack (Auth.aeCode err))
                                    Right normalSession -> do
                                        Auth.nsScope normalSession `shouldBe` "normal"
                                        gone <- Auth.getSession conn (Auth.nsToken pendingLogin)
                                        gone `shouldBe` Nothing
                                        live <- Auth.getSession conn (Auth.nsToken normalSession)
                                        fmap Auth.sessScope live `shouldBe` Just "normal"
                close conn
        it "keeps pending sessions out of the session list and the API scope" $
            withSystemTempDirectory "eza-2fa-scope" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                let params = testPasswordParams
                    ac = testAuthConfig params 3600 5 900
                seedPasswordAccount conn params
                insertTestCredential conn (BS.pack [0x01])
                _ <- Auth.setTwoFactorRequirement conn ac True "correct horse battery"
                result <- Auth.verifyPasswordLogin conn ac "owner" "correct horse battery"
                case result of
                    Right (Auth.LoginNeedsPasskey pendingLogin) -> do
                        found <- Auth.getSession conn (Auth.nsToken pendingLogin)
                        case found of
                            Nothing -> expectationFailure "expected a pending session row"
                            Just pendingSession -> do
                                sessions <- Auth.listSessions conn (Just pendingSession)
                                length sessions `shouldBe` 0
                                Auth.scopeAllows (Auth.pendingScope) "GET" ["api", "v1", "boot"] `shouldBe` False
                                Auth.scopeAllows (Auth.pendingScope) "GET" ["api", "v1", "account"] `shouldBe` False
                                Auth.scopeAllows (Auth.pendingScope) "GET" ["account", "add-passkey"] `shouldBe` False
                    _ -> expectationFailure "expected a pending login"
                Auth.scopeAllows "normal" "GET" ["api", "v1", "boot"] `shouldBe` True
                Auth.scopeAllows "normal" "GET" ["api", "v1", "account"] `shouldBe` True
                Auth.scopeAllows "recovery" "POST" ["api", "setup", "password"] `shouldBe` True
                Auth.scopeAllows "recovery" "GET" ["api", "v1", "account"] `shouldBe` True
                Auth.scopeAllows "recovery" "GET" ["api", "v1", "boot"] `shouldBe` True
                Auth.scopeAllows "recovery" "POST" ["api", "v1", "bookmarks"] `shouldBe` False
                close conn
        it "refuses to revoke the last passkey while two-factor is on" $
            withSystemTempDirectory "eza-2fa-last" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                let params = testPasswordParams
                    ac = testAuthConfig params 3600 5 900
                seedPasswordAccount conn params
                insertTestCredential conn (BS.pack [0x01])
                _ <- Auth.setTwoFactorRequirement conn ac True "correct horse battery"
                denied <- Auth.deleteCredential conn (BS.pack [0x01])
                authStatus denied `shouldBe` 409
                remaining <- Auth.countCredentials conn
                remaining `shouldBe` 1
                _ <- Auth.setTwoFactorRequirement conn ac False "correct horse battery"
                allowed <- Auth.deleteCredential conn (BS.pack [0x01])
                allowed `shouldBe` Right ()
                left <- Auth.countCredentials conn
                left `shouldBe` 0
                close conn

    DataIntegritySpec.spec
    DedupSpec.spec
    LedgerSpec.spec
    GraphLayoutSpec.spec
    AuthzSpec.authzSpec
    CoreViewSpec.coreViewSpec
    ControlSpec.controlSpec
    ViewContractSpec.viewContractSpec
    PerfSpec.spec
    ClipSpec.spec
    ViewServerSpec.spec
    IsolationSpec.spec
    AdminSpec.spec
    BackupSpec.spec
    CliSpec.spec
    WorkerSpec.spec
    WebhookSpec.spec
    SecuritySpec.spec

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

testAuthConfig :: Password.PasswordParams -> Int -> Int -> Int -> Auth.AuthConfig
testAuthConfig params ttlSeconds attempts lockoutSeconds =
    Auth.AuthConfig
        { Auth.acOrigin = "http://localhost:8080"
        , Auth.acRpId = "localhost"
        , Auth.acRpName = "eza"
        , Auth.acSessionTtlSeconds = ttlSeconds
        , Auth.acPasswordParams = params
        , Auth.acLoginMaxAttempts = attempts
        , Auth.acLoginLockoutSeconds = lockoutSeconds
        }

authStatus :: Either Auth.AuthError a -> Int
authStatus (Left err) = Auth.aeStatus err
authStatus (Right _) = 200

retryAfter :: Either Auth.AuthError a -> Maybe Int
retryAfter (Left err) = Auth.aeRetryAfter err
retryAfter (Right _) = Nothing

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft (Right _) = False

testPasswordParams :: Password.PasswordParams
testPasswordParams = Password.PasswordParams 1024 1 1

-- | A claimed password account, the starting point for the two-factor tests.
seedPasswordAccount :: Sqlite.Connection -> Password.PasswordParams -> IO ()
seedPasswordAccount conn params = do
    stored <- Password.hashPassword params "correct horse battery"
    Auth.setAccountPassword conn "owner" stored

{- | A passkey row with a fixed credential id. WebAuthn assertions cannot be
fabricated in a test, so the auth tests work at the database and Auth level.
-}
insertTestCredential :: Sqlite.Connection -> BS.ByteString -> IO ()
insertTestCredential conn credentialId = do
    Sqlite.execute
        conn
        "INSERT INTO passkey_credentials (credential_id,user_handle,public_key,created_at) VALUES (?,?,?,1)"
        (credentialId, BS.pack [0x02], BS.pack [0x03])

-- | Raw row insert for import/dedupe tests that do not need a normal save.
insertRawBookmark :: Sqlite.Connection -> Text -> Text -> IO Int
insertRawBookmark conn url title = do
    Sqlite.execute
        conn
        "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES (?,?,?,?,?,?)"
        (url, title, T.pack "example.com", (1 :: Int), (1 :: Int), (1 :: Int))
    fromIntegral <$> Sqlite.lastInsertRowId conn

bookmarkCount :: Sqlite.Connection -> IO Int
bookmarkCount conn = do
    rows <- Sqlite.query_ conn "SELECT COUNT(*) FROM bookmarks" :: IO [Sqlite.Only Int]
    pure (case rows of (Sqlite.Only n : _) -> n; [] -> 0)

bookmarkUrlAt :: Sqlite.Connection -> Int -> IO Text
bookmarkUrlAt conn bid = do
    rows <- Sqlite.query conn "SELECT url FROM bookmarks WHERE id = ?" (Sqlite.Only bid) :: IO [Sqlite.Only Text]
    pure (case rows of (Sqlite.Only url : _) -> url; [] -> T.pack "")

bookmarkTagNames :: Sqlite.Connection -> Int -> IO [Text]
bookmarkTagNames conn bid = do
    rows <-
        Sqlite.query
            conn
            "SELECT t.name FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id WHERE bt.bookmark_id = ? ORDER BY t.name"
            (Sqlite.Only bid) ::
            IO [Sqlite.Only Text]
    pure [name | Sqlite.Only name <- rows]

{- | Raw bookmark insert with a chosen original save date and read flag, for
the date-filter and graph tests.
-}
insertFiledBookmark :: Sqlite.Connection -> Text -> Text -> Text -> Int -> Int -> IO Int
insertFiledBookmark conn url title domain createdAt isRead = do
    Sqlite.execute
        conn
        "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at,is_read) VALUES (?,?,?,?,?,?,?)"
        (url, title, domain, createdAt, createdAt, createdAt, isRead)
    fromIntegral <$> Sqlite.lastInsertRowId conn

-- | Move a bookmark's added date, for the searched-sort tests.
setAddedAt :: Sqlite.Connection -> Int -> Int -> IO ()
setAddedAt conn bid value =
    Sqlite.execute conn "UPDATE bookmarks SET added_at = ? WHERE id = ?" (value, bid)

-- | Move a bookmark's last-opened date, for the searched-sort tests.
setLastOpenedAt :: Sqlite.Connection -> Int -> Int -> IO ()
setLastOpenedAt conn bid value =
    Sqlite.execute conn "UPDATE bookmarks SET last_opened_at = ? WHERE id = ?" (value, bid)

-- | Create the tag when needed and attach it to the bookmark.
attachTag :: Sqlite.Connection -> Int -> Text -> IO ()
attachTag conn bid name = do
    Sqlite.execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, 1)" (Sqlite.Only name)
    rows <- Sqlite.query conn "SELECT id FROM tags WHERE name = ?" (Sqlite.Only name) :: IO [Sqlite.Only Int]
    case rows of
        (Sqlite.Only tid : _) ->
            Sqlite.execute conn "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?,?)" (bid, tid)
        [] -> pure ()

{- | A resolved wikilink row; unresolved targets stay NULL and are not part of
the graph payload.
-}
insertLink :: Sqlite.Connection -> Int -> Int -> IO ()
insertLink conn source target =
    Sqlite.execute
        conn
        "INSERT INTO links (source_id, target_id, target_title) VALUES (?,?, '')"
        (source, Just target :: Maybe Int)

-- | The length of a JSON array, or 'Nothing' for any other value.
arrayLength :: Value -> Maybe Int
arrayLength (Array values) = Just (length values)
arrayLength _ = Nothing
