{-# LANGUAGE OverloadedStrings #-}

module RouteSpec (routeSpec) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Eza.Web.Logic.Route (
    Route (..),
    isGraphRoute,
    percentDecode,
    percentEncode,
    routeOfUri,
    routeSubtitle,
    routeTitle,
    routeToUri,
 )

-- | One representative of every 'Route' constructor.
routeSamples :: [Route]
routeSamples =
    [ Index
    , Bookmark 42
    , Inbox
    , Graph
    , GraphLocal 7 2
    , Views
    , ViewOpen "week-one"
    , Dedup
    , Tags
    , AiTags
    , Maintenance
    , Account
    , History
    , Save (Just "Title") (Just "body") (Just "https://example.com")
    , NotFound
    ]

routeSpec :: Spec
routeSpec = do
    describe "routeOfUri" $ do
        it "classifies every route constructor from its rendered URI" $
            mapM_
                (\route -> routeOfUri (routeToUri route) `shouldBe` route)
                routeSamples

        it "treats an empty or slash-only path as Index" $ do
            routeOfUri "" `shouldBe` Index
            routeOfUri "/" `shouldBe` Index
            routeOfUri "///" `shouldBe` Index

        it "classifies a numeric bookmark route" $
            routeOfUri "/bookmark/7" `shouldBe` Bookmark 7

        it "turns a non-numeric bookmark id into NotFound" $ do
            routeOfUri "/bookmark/nope" `shouldBe` NotFound
            routeOfUri "/bookmark/7/extra" `shouldBe` NotFound

        it "keeps the accessions alias for the history page" $
            routeOfUri "/accessions" `shouldBe` History

        it "parses a local graph with its clamped depth" $ do
            routeOfUri "/graph?local=1&focus=7&depth=2" `shouldBe` GraphLocal 7 2
            routeOfUri "/graph?local=1&focus=7&depth=9" `shouldBe` GraphLocal 7 3
            routeOfUri "/graph?local=1&focus=7&depth=0" `shouldBe` GraphLocal 7 1
            routeOfUri "/graph?local=1&focus=7" `shouldBe` GraphLocal 7 1

        it "falls back to the whole-library graph without a focus key" $ do
            routeOfUri "/graph" `shouldBe` Graph
            routeOfUri "/graph?focus=7" `shouldBe` Graph
            routeOfUri "/graph?local=1" `shouldBe` Graph

        it "does not decode a percent-encoded view path segment" $
            routeOfUri "/views/week%20one" `shouldBe` ViewOpen "week%20one"

        it "decodes the save query values, including + as space" $
            routeOfUri "/save?title=Hello+World&text=body&url=https%3A%2F%2Fexample.com"
                `shouldBe` Save (Just "Hello World") (Just "body") (Just "https://example.com")

        it "ignores the fragment" $ do
            routeOfUri "/save?title=x#fragment" `shouldBe` Save (Just "x") Nothing Nothing
            routeOfUri "/account#tokens" `shouldBe` Account

        it "returns NotFound for an unknown path" $
            routeOfUri "/not-a-route" `shouldBe` NotFound

    describe "routeToUri" $ do
        it "renders every route constructor" $
            map routeToUri routeSamples
                `shouldBe` [ "/"
                           , "/bookmark/42"
                           , "/inbox"
                           , "/graph"
                           , "/graph?depth=2&focus=7&local=1"
                           , "/views"
                           , "/views/week-one"
                           , "/dedup"
                           , "/tags"
                           , "/tags/ai"
                           , "/maintenance"
                           , "/account"
                           , "/history"
                           , "/save?text=body&title=Title&url=https://example.com"
                           , "/not-found"
                           ]

        it "omits the save query parameters that are absent" $ do
            routeToUri (Save Nothing Nothing Nothing) `shouldBe` "/save"
            routeToUri (Save (Just "T") Nothing Nothing) `shouldBe` "/save?title=T"
            routeToUri (Save Nothing (Just "B") Nothing) `shouldBe` "/save?text=B"
            routeToUri (Save Nothing Nothing (Just "U")) `shouldBe` "/save?url=U"

    describe "labels" $ do
        it "gives every route a title and a subtitle" $
            mapM_
                ( \route -> do
                    routeTitle route `shouldSatisfy` (not . T.null)
                    routeSubtitle route `shouldSatisfy` (not . T.null)
                )
                routeSamples

        it "spells the local graph subtitle for one and several hops" $ do
            routeSubtitle (GraphLocal 1 1) `shouldBe` "A local graph, 1 hop deep."
            routeSubtitle (GraphLocal 1 3) `shouldBe` "A local graph, 3 hops deep."

        it "marks both graph routes as graph routes" $ do
            isGraphRoute Graph `shouldBe` True
            isGraphRoute (GraphLocal 1 1) `shouldBe` True
            isGraphRoute Index `shouldBe` False

    describe "percentDecode" $ do
        it "decodes escapes and plus signs" $ do
            percentDecode "a%20b" `shouldBe` "a b"
            percentDecode "a+b" `shouldBe` "a b"
            percentDecode "caf%C3%A9" `shouldBe` "café"

        it "is total for malformed input" $ do
            percentDecode "%zz" `shouldBe` "%zz"
            percentDecode "100%" `shouldBe` "100%"
            percentDecode "%ff" `shouldBe` "%ff"
            percentDecode "" `shouldBe` ""

    describe "percentEncode" $ do
        it "leaves unreserved characters alone" $
            percentEncode "aZ09-._~" `shouldBe` "aZ09-._~"

        it "encodes reserved characters as UTF-8 bytes" $ do
            percentEncode "a b" `shouldBe` "a%20b"
            percentEncode "a/b" `shouldBe` "a%2Fb"
            percentEncode "c++" `shouldBe` "c%2B%2B"

        it "round-trips through percentDecode" $
            mapM_
                (\value -> percentDecode (percentEncode value) `shouldBe` (value :: Text))
                ["plain", "two words", "a/b?c&d=e", "caffè", "100%"]
