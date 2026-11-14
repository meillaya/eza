{-# LANGUAGE OverloadedStrings #-}

{- | Tests for duplicate grouping, pagination and the confirmed one-shot
merge (one transaction, one undo snapshot, title matches untouched).
-}
module DedupSpec (spec) where

import Control.Exception (bracket)
import Data.Text (Text)
import Database.SQLite.Simple (Connection, Only (..), close, execute, lastInsertRowId, query, query_)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Eza.Db (openDb)
import Eza.Dedup (DedupQuery (..), GroupIds (..), dedupCandidates, dedupeGroups, mergeUrlDuplicatesAll)
import Eza.Types (BookmarkSummary (..), DedupCounts (..), DedupGroup (..), DedupMergeAllReport (..), DedupReport (..))
import Eza.Undo (undoLast)

spec :: Spec
spec = do
    describe "duplicate grouping" $ do
        it "groups http/https/www/trailing-slash variants by canonical URL and keeps titles advisory" $
            withDb $ \conn -> do
                first <- addRaw conn "http://example.com/page" "Page" "example.com"
                second <- addRaw conn "https://example.com/page" "Page https" "example.com"
                third <- addRaw conn "https://www.example.com/page/" "Page www" "www.example.com"
                titleA <- addRaw conn "https://example.com/alpha" "Shared title" "example.com"
                titleB <- addRaw conn "https://example.com/beta" "Shared title" "example.com"
                _ <- addRaw conn "https://other.test/unique" "Unique" "other.test"
                rows <- bookmarks conn
                let groups = dedupeGroups rows
                case groups of
                    [urlGroup, titleGroup] -> do
                        giKind urlGroup `shouldBe` "url"
                        giKey urlGroup `shouldBe` "example.com/page"
                        giIds urlGroup `shouldBe` [first, second, third]
                        giKind titleGroup `shouldBe` "title"
                        giIds titleGroup `shouldBe` [titleA, titleB]
                    _ -> expectationFailure ("expected one URL group and one title group, got " <> show groups)

    describe "paged candidates" $ do
        it "returns exact counts with a bounded page and light summaries" $
            withDb $ \conn -> do
                pairs <-
                    mapM
                        ( \i -> do
                            http <- addRaw conn ("http://example.com/p" <> i) ("P" <> i) "example.com"
                            https <- addRaw conn ("https://example.com/p" <> i) ("P" <> i) "example.com"
                            pure [http, https]
                        )
                        ["1", "2", "3"]
                report <- dedupCandidates conn (DedupQuery 0 2 0 10)
                dcUrlGroups (drCounts report) `shouldBe` 3
                dcUrlRecords (drCounts report) `shouldBe` 6
                dcTitleGroups (drCounts report) `shouldBe` 0
                length (drUrlGroups report) `shouldBe` 2
                map (length . dgItems) (drUrlGroups report) `shouldBe` [2, 2]
                case drUrlGroups report of
                    (group : _) -> do
                        map bsId (dgItems group) `shouldBe` concat (take 1 pairs)
                        map bsSnippet (dgItems group) `shouldBe` [Nothing, Nothing]
                    [] -> expectationFailure "expected a URL group page"
                secondPage <- dedupCandidates conn (DedupQuery 2 2 0 10)
                length (drUrlGroups secondPage) `shouldBe` 1

    describe "one-shot merge" $ do
        it "merges every same-URL group behind one snapshot and leaves title matches alone" $
            withDb $ \conn -> do
                keeperA <- addRaw conn "http://example.com/a" "A" "example.com"
                absorbedA <- addRaw conn "https://example.com/a" "A https" "example.com"
                keeperB <- addRaw conn "https://example.com/b" "B" "example.com"
                _absorbedB <- addRaw conn "http://example.com/b" "B http" "example.com"
                titleA <- addRaw conn "https://example.com/t1" "Same title" "example.com"
                titleB <- addRaw conn "https://example.com/t2" "Same title" "example.com"
                addTag conn absorbedA "alpha"
                snapshotCount <- countSnapshots conn
                snapshotCount `shouldBe` 0
                report <- mergeUrlDuplicatesAll conn
                dmGroups report `shouldBe` 2
                dmRecords report `shouldBe` 4
                dmAffected report `shouldBe` 4
                dmSnapshotId report `shouldSatisfy` (> 0)
                countBookmarks conn `shouldReturn` 4
                snapshots <- query_ conn "SELECT op, label FROM journal" :: IO [(Text, Text)]
                snapshots `shouldBe` [("merge_all", "merge_all")]
                keeperAUrl <- bookmarkUrl conn keeperA
                keeperAUrl `shouldBe` "https://example.com/a"
                keeperBUrl <- bookmarkUrl conn keeperB
                keeperBUrl `shouldBe` "https://example.com/b"
                keeperATags <- bookmarkTags conn keeperA
                keeperATags `shouldBe` ["alpha"]
                titleRows <- query_ conn "SELECT id FROM bookmarks WHERE title = 'Same title' ORDER BY id" :: IO [Only Int]
                map (\(Only bid) -> bid) titleRows `shouldBe` [titleA, titleB]
                restored <- undoLast conn
                restored `shouldBe` 4
                countBookmarks conn `shouldReturn` 6
                restoredUrl <- bookmarkUrl conn keeperA
                restoredUrl `shouldBe` "http://example.com/a"
                absorbedUrl <- bookmarkUrl conn absorbedA
                absorbedUrl `shouldBe` "https://example.com/a"
                absorbedTags <- bookmarkTags conn absorbedA
                absorbedTags `shouldBe` ["alpha"]

        it "does nothing and writes no snapshot when there are no same-URL groups" $
            withDb $ \conn -> do
                _ <- addRaw conn "https://example.com/one" "One" "example.com"
                _ <- addRaw conn "https://other.test/two" "Two" "other.test"
                report <- mergeUrlDuplicatesAll conn
                dmGroups report `shouldBe` 0
                dmRecords report `shouldBe` 0
                dmSnapshotId report `shouldBe` 0
                snapshotCount <- countSnapshots conn
                snapshotCount `shouldBe` 0

    describe "advisory groups" $ do
        it "keeps title-on-source matches out of the bulk merge" $
            withDb $ \conn -> do
                _ <- addRaw conn "https://example.com/x1" "Shared" "example.com"
                _ <- addRaw conn "https://example.com/x2" "Shared" "example.com"
                initialReport <- dedupCandidates conn (DedupQuery 0 10 0 10)
                dcUrlGroups (drCounts initialReport) `shouldBe` 0
                dcTitleGroups (drCounts initialReport) `shouldBe` 1
                report <- mergeUrlDuplicatesAll conn
                dmGroups report `shouldBe` 0
                countBookmarks conn `shouldReturn` 2

withDb :: (Connection -> IO a) -> IO a
withDb action =
    withSystemTempDirectory "eza-dedup" $ \dir ->
        bracket (openDb (dir </> "test.db")) close action

bookmarks :: Connection -> IO [(Int, Text, Text, Text)]
bookmarks conn = query_ conn "SELECT id, url, title, domain FROM bookmarks ORDER BY id"

addRaw :: Connection -> Text -> Text -> Text -> IO Int
addRaw conn url title domain = do
    execute
        conn
        "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at,is_read,is_dead) VALUES (?,?,?,?,?,?,?,?)"
        (url, title, domain, (1 :: Int), (1 :: Int), (1 :: Int), (0 :: Int), (0 :: Int))
    fromIntegral <$> lastInsertRowId conn

addTag :: Connection -> Int -> Text -> IO ()
addTag conn bid name = do
    execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)" (name, (1 :: Int))
    rows <- query conn "SELECT id FROM tags WHERE name = ?" (Only name) :: IO [Only Int]
    case rows of
        (Only tagId : _) ->
            execute conn "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?, ?)" (bid, tagId)
        [] -> pure ()

bookmarkUrl :: Connection -> Int -> IO Text
bookmarkUrl conn bid = do
    rows <- query conn "SELECT url FROM bookmarks WHERE id = ?" (Only bid) :: IO [Only Text]
    pure (case rows of (Only url : _) -> url; [] -> "")

bookmarkTags :: Connection -> Int -> IO [Text]
bookmarkTags conn bid = do
    rows <-
        query
            conn
            "SELECT t.name FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id WHERE bt.bookmark_id = ? ORDER BY t.name"
            (Only bid) ::
            IO [Only Text]
    pure [tag | Only tag <- rows]

countBookmarks :: Connection -> IO Int
countBookmarks conn = do
    rows <- query_ conn "SELECT COUNT(*) FROM bookmarks" :: IO [Only Int]
    pure (case rows of (Only n : _) -> n; [] -> 0)

countSnapshots :: Connection -> IO Int
countSnapshots conn = do
    rows <- query_ conn "SELECT COUNT(*) FROM journal" :: IO [Only Int]
    pure (case rows of (Only n : _) -> n; [] -> 0)
