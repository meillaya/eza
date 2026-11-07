module Main (main) where

import Control.Exception (bracket)
import qualified Data.ByteString as BS
import Database.SQLite.Simple (close)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Eza.Bookmarks
import Eza.Db (openDb)
import Eza.Import
import Eza.SearchQuery
import Eza.Types (BookmarkDetail (..), BookmarkSummary (..), ImportReport (..), SearchPage (..))

main :: IO ()
main = hspec $ do
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
          page <- listBookmarks conn (defaultListQuery {lqQ = ""})
          spTotal page `shouldBe` 3
          rust <- listBookmarks conn (defaultListQuery {lqTags = ["rust"]})
          spTotal rust `shouldBe` 2
          fts <- listBookmarks conn (defaultListQuery {lqQ = "B"})
          spTotal fts `shouldBe` 1
          tagged <- listBookmarks conn (defaultListQuery {lqTags = ["toolbar"]})
          spTotal tagged `shouldBe` 1
          detail <- getBookmark conn (head (map bsId (spItems tagged)))
          case detail of
            Nothing -> expectationFailure "expected bookmark detail"
            Just d -> bdTags d `shouldContain` ["toolbar"]

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
