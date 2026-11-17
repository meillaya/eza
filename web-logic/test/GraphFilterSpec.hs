{-# LANGUAGE OverloadedStrings #-}

{- | Native tests for the graph filter and saved graph-view query matching.

The filter is the shared search grammar evaluated against the fields the graph
payload carries — the same matcher the saved colour groups use. These tests pin
the operators @docs/extensions.md@ promises for a graph view query
(@tag:@, @year:@, @day:@, @is:unread@, @-term@) and the saved-view wiring
through 'Eza.View'.
-}
module GraphFilterSpec (graphFilterSpec) where

import qualified Data.IntSet as IS
import qualified Data.Text as T
import Test.Hspec

import Eza.GraphLayout (GraphLayout, LayoutPreset (..), buildLayout, tagKeyOf)
import Eza.Time (daysFromCivil)
import Eza.Types (GraphData (..), GraphRecord (..), GraphTag (..))
import qualified Eza.View as EV

import Eza.Web.Logic.Graph (GraphMatches (..))
import Eza.Web.Logic.Graph.Geometry (matchGraph)
import Eza.Web.Logic.Model
import Eza.Web.Logic.Route (Route (..))
import Eza.Web.Logic.Update (update)

{- | Two tags and five records covering the fields the matcher can see: titles,
domains, filed dates, read/dead flags and tag membership.
-}
fixtureGraph :: GraphData
fixtureGraph =
    GraphData
        { gdTags = [GraphTag "rust" 3, GraphTag "haskell" 2]
        , gdRecords =
            [ GraphRecord 1 "Rust ownership" "blog.example" (day 2025 6 1) False False [0]
            , GraphRecord 2 "Haskell type classes" "wiki.example" (day 2024 1 15) True False [1]
            , GraphRecord 3 "Rust and haskell" "notes.example" (day 2025 1 20) False False [0, 1]
            , GraphRecord 4 "Reading list" "blog.example" (day 2023 12 31) True False []
            , GraphRecord 5 "Systems programming" "rust.example" (day 2025 6 1) False True [0]
            ]
        , gdLinks = []
        , gdRevision = "graph-filter-fixture"
        }
  where
    day y m d = fromIntegral (daysFromCivil y m d * 86400)

fixtureLayout :: GraphLayout
fixtureLayout = buildLayout 1 fixtureGraph

matchesFor :: T.Text -> GraphMatches
matchesFor query = matchGraph query fixtureLayout

matchedIds :: GraphMatches -> [Int]
matchedIds = IS.toAscList . gmIds

graphModel :: Model
graphModel =
    initialModel
        { gGraph = (gGraph initialModel){grGraph = Just fixtureGraph, grGraphLayout = Just fixtureLayout}
        , gShell = (gShell initialModel){sfRoute = Graph}
        }

-- | A saved graph view with just the fields these tests care about.
graphView :: T.Text -> EV.View
graphView query =
    EV.View
        { EV.vId = 9
        , EV.vSlug = "graph-filter-test"
        , EV.vName = "Graph filter test"
        , EV.vKind = EV.GraphKind
        , EV.vIsDefault = False
        , EV.vDefinition =
            EV.GraphDefinition
                EV.GraphViewDefinition
                    { EV.gvdQuery = query
                    , EV.gvdTagsShown = True
                    , EV.gvdLabelMode = EV.LabelAuto
                    , EV.gvdLayoutPreset = Standard
                    , EV.gvdLocalDepth = Nothing
                    , EV.gvdColorGroups = []
                    }
        , EV.vCreatedAt = 0
        , EV.vUpdatedAt = 1
        }

graphFilterSpec :: Spec
graphFilterSpec = describe "graph filter / saved graph-view query" $ do
    describe "shared search grammar" $ do
        it "matches plain terms over title, domain and tag names, case-insensitively" $ do
            matchedIds (matchesFor "rust") `shouldBe` [1, 3, 5]
            matchedIds (matchesFor "RUST") `shouldBe` [1, 3, 5]
            gmCount (matchesFor "rust") `shouldBe` 3
            gmActive (matchesFor "rust") `shouldBe` True
        it "ANDs plain terms and honours -term negation" $ do
            matchedIds (matchesFor "rust -haskell") `shouldBe` [1, 5]
            matchedIds (matchesFor "-rust") `shouldBe` [2, 4]
        it "filters by tag: exactly" $ do
            matchedIds (matchesFor "tag:rust") `shouldBe` [1, 3, 5]
            matchedIds (matchesFor "tag:haskell") `shouldBe` [2, 3]
            IS.toAscList (gmTags (matchesFor "tag:haskell")) `shouldBe` [tagKeyOf 1]
        it "filters by filed year and day in UTC" $ do
            matchedIds (matchesFor "year:2025") `shouldBe` [1, 3, 5]
            matchedIds (matchesFor "day:2025-06-01") `shouldBe` [1, 5]
        it "filters by the read and dead flags" $ do
            matchedIds (matchesFor "is:unread") `shouldBe` [1, 3, 5]
            matchedIds (matchesFor "is:dead") `shouldBe` [5]
        it "combines an operator with a plain term" $
            matchedIds (matchesFor "haskell is:unread") `shouldBe` [3]
        it "treats input the parser drops as no filter" $ do
            gmActive (matchesFor "is:bogus") `shouldBe` False
            gmActive (matchesFor "   ") `shouldBe` False
        it "cannot match link: because the graph carries no URLs" $ do
            gmActive (matchesFor "link:3") `shouldBe` True
            gmCount (matchesFor "link:3") `shouldBe` 0
        it "ranks the top records for the results panel" $
            gmTop (matchesFor "rust") `shouldBe` [1, 3, 5]
    describe "saved graph view" $ do
        it "opens with its year:/tag: query applied and matching records" $ do
            let view = graphView "year:2025 tag:haskell"
                (applied, _) = update graphModel (ViewFetched view)
                (settled, _) = update applied GraphFilterSettled
            mGraphFilter applied `shouldBe` "year:2025 tag:haskell"
            mGraphViewId applied `shouldBe` Just 9
            gmActive (mGraphMatches settled) `shouldBe` True
            matchedIds (mGraphMatches settled) `shouldBe` [3]
        it "opens with its tag: query applied and matching records" $ do
            let (applied, _) = update graphModel (ViewFetched (graphView "tag:haskell"))
                (settled, _) = update applied GraphFilterSettled
            gmCount (mGraphMatches settled) `shouldBe` 2
            matchedIds (mGraphMatches settled) `shouldBe` [2, 3]
