module Main (main) where

import Control.Exception (bracket)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (close)
import qualified Database.SQLite.Simple as Sqlite
import System.Directory (listDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Eza.Bookmarks
import Eza.Db (openDb, queryScalar, schemaV1, schemaVersion)
import Eza.Favicon (parseDataIcon, parseIconLinks, sniffImage)
import Eza.Highlights (createHighlight, deleteHighlight, listHighlights, updateHighlight)
import Eza.Import
import Eza.JsonExport (JsonImportReport (..), exportJson, importJson)
import Eza.Rules (Rule (..), createRule, listRules, matchingBookmarks)
import Eza.SearchQuery
import Eza.Shares (ShareRecord (..), ShareState (..), ShareUnavailable (..), createShare, resolveShare, resolveShareState, revokeShare, shareUnavailablePage)
import Eza.Types (BookmarkDetail (..), BookmarkSummary (..), Highlight (..), ImportReport (..), LibraryStats (..), SearchPage (..))
import Eza.Url (normalizeUrl)

main :: IO ()
main = hspec $ do
    describe "URL normalization" $ do
        it "lowercases scheme and host, drops the default port and fragment, and trims a root slash" $ do
            normalizeUrl "HTTPS://Example.COM:443/a/#frag" `shouldBe` "https://example.com/a"
            normalizeUrl "https://example.com/" `shouldBe` "https://example.com"
            normalizeUrl "http://example.com:80/path/" `shouldBe` "http://example.com/path"

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
                version `shouldBe` 5
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
                updated <- updateHighlight conn bid (hId (head listed)) (Just "changed") (Just "blue")
                updated `shouldBe` True
                deleted <- deleteHighlight conn bid (hId (head listed))
                deleted `shouldBe` True
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
                    tagged <- listBookmarks conn (defaultListQuery{lqTags = ["toolbar"]})
                    spTotal tagged `shouldBe` 1
                    detail <- getBookmark conn (head (map bsId (spItems tagged)))
                    case detail of
                        Nothing -> expectationFailure "expected bookmark detail"
                        Just d -> bdTags d `shouldContain` ["toolbar"]

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

    describe "full export counts" $ do
        it "matches the analysed 2026-08 export" $ do
            mpath <- lookupEnv "EZA_IMPORT_FIXTURE"
            case mpath of
                Nothing -> pendingWith "set EZA_IMPORT_FIXTURE to run the full-file acceptance test"
                Just path -> do
                    raw <- BS.readFile path
                    let p = parseNetscape defaultImportOptions raw
                    piFound p `shouldBe` 9457
                    piHttp p `shouldBe` 9453
                    piNonHttp p `shouldBe` 4
                    piDuplicates p `shouldBe` 465
                    length (piItems p) `shouldBe` 8988
                    piUntagged p `shouldBe` 87
