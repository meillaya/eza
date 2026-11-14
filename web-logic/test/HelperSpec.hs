{-# LANGUAGE OverloadedStrings #-}

{- | Native tests for the pure client helpers extracted in M2-B2a: tag entry,
share-target text, the wikilink completion popup, the route predicates and the
shared request-id staleness rule.
-}
module HelperSpec (helperSpec) where

import qualified Data.Text as T
import Test.Hspec

import Eza.Web.Logic.Effect (RequestId (..), nextRequestId, requestIsCurrent)
import Eza.Web.Logic.Input (
    completeWikilink,
    firstUrlIn,
    parseTagInput,
    splitTags,
    wikilinkQueryAt,
 )
import Eza.Web.Logic.Route (
    Route (..),
    isDetailRoute,
    isListRoute,
    isLocalGraphRoute,
    isSaveRoute,
 )

helperSpec :: Spec
helperSpec = describe "native client helpers" $ do
    describe "splitTags" $ do
        it "splits on commas and semicolons" $
            splitTags "haskell, rust; sqlite" `shouldBe` ["haskell", "rust", "sqlite"]
        it "lower-cases and drops duplicates in order" $
            splitTags "Haskell, haskell, Rust" `shouldBe` ["haskell", "rust"]
        it "ignores empty input" $
            splitTags "  " `shouldBe` []
    describe "parseTagInput" $ do
        it "lower-cases and trims a single tag" $
            parseTagInput "  Haskell  " `shouldBe` Just "haskell"
        it "treats a blank input as no tag" $
            parseTagInput "   " `shouldBe` Nothing
    describe "firstUrlIn" $ do
        it "picks the first http(s) word" $
            firstUrlIn "look at https://example.com/a?b=1 and http://other.test"
                `shouldBe` Just "https://example.com/a?b=1"
        it "strips surrounding whitespace" $
            firstUrlIn "  https://example.com/x  " `shouldBe` Just "https://example.com/x"
        it "reports no URL" $
            firstUrlIn "no link here" `shouldBe` Nothing
    describe "wikilinkQueryAt" $ do
        it "finds an open query before the cursor" $
            wikilinkQueryAt "see [[ru" 9 `shouldBe` Just "ru"
        it "ignores a closed link" $
            wikilinkQueryAt "see [[rust]] more" 13 `shouldBe` Nothing
        it "ignores a newline inside the open query" $
            wikilinkQueryAt "see [[rust\nmore" 14 `shouldBe` Nothing
        it "ignores a query that is too long" $
            wikilinkQueryAt ("[[" <> longQuery) (2 + T.length longQuery) `shouldBe` Nothing
        it "reports nothing when no link is open" $
            wikilinkQueryAt "plain text" 5 `shouldBe` Nothing
    describe "completeWikilink" $ do
        it "replaces the open query and returns the new caret" $
            completeWikilink "see [[ru" 9 "rust" `shouldBe` ("see [[rust]] ", 13)
        it "keeps text after the caret" $
            completeWikilink "see [[ru now" 9 "rust" `shouldBe` ("see [[rust]] now", 13)
    describe "route predicates" $ do
        it "classifies the record page" $ do
            isDetailRoute (Bookmark 3) `shouldBe` True
            isDetailRoute Index `shouldBe` False
        it "classifies the two ledger pages" $ do
            isListRoute Index `shouldBe` True
            isListRoute Inbox `shouldBe` True
            isListRoute Graph `shouldBe` False
        it "classifies the share-target save page" $ do
            isSaveRoute (Save Nothing Nothing Nothing) `shouldBe` True
            isSaveRoute Tags `shouldBe` False
        it "classifies the local graph" $ do
            isLocalGraphRoute (GraphLocal 1 2) `shouldBe` True
            isLocalGraphRoute Graph `shouldBe` False
    describe "request staleness" $ do
        it "accepts only the current request id" $ do
            requestIsCurrent (RequestId 4) (RequestId 4) `shouldBe` True
            requestIsCurrent (RequestId 4) (RequestId 3) `shouldBe` False
        it "allocates monotonically increasing ids" $ do
            nextRequestId (RequestId 0) `shouldBe` RequestId 1
            nextRequestId (nextRequestId (RequestId 0)) `shouldBe` RequestId 2
  where
    longQuery = T.replicate 82 "0"
