{- | Tests for the pure graph layout moved into eza-core.

These pin the layout contract: the node-key mapping, determinism, preset
ordering by world span, and hydration round-tripping (server positions rebuild
the same layout the client built locally).
-}
module GraphLayoutSpec (spec) where

import Data.List (nub, sort)
import qualified Data.IntMap.Strict as IM
import Test.Hspec

import Eza.GraphLayout
import Eza.Types (GraphData (..), GraphLink (..), GraphRecord (..), GraphTag (..))

spec :: Spec
spec = do
    describe "graph layout node keys" $ do
        it "maps tag indexes to negative keys and records to their ids" $ do
            tagKeyOf 0 `shouldBe` (-1)
            tagKeyOf 3 `shouldBe` (-4)
            isTagKey (tagKeyOf 0) `shouldBe` True
            isTagKey (recordKeyOf 1) `shouldBe` False
            tagIndexOf (tagKeyOf 42) `shouldBe` 42
            recordKeyOf 42 `shouldBe` 42

    describe "deterministic standard layout" $ do
        it "builds the same layout for the same input twice" $
            buildLayout 7 fixture `shouldBe` buildLayout 7 fixture

        it "builds the same layout with or without the standard preset" $ do
            buildLayoutWith (presetOptions Standard) 0 fixture
                `shouldBe` buildLayout 0 fixture

        it "keeps every node and both edge families" $ do
            let layout = buildLayout 0 fixture
            glTagCount layout `shouldBe` 3
            glRecordCount layout `shouldBe` 4
            glLinkCount layout `shouldBe` 2
            glMemberCount layout `shouldBe` 4
            IM.keys (glPos layout) `shouldMatchList` (map tagKeyOf [0 .. 2] ++ map recordKeyOf [1 .. 4])

    describe "layout presets" $ do
        it "orders compact below standard below airy by world span" $ do
            let spans =
                    [ layoutWorldSpan (buildLayoutWith (presetOptions preset) 0 fixture)
                    | preset <- [Compact, Standard, Airy]
                    ]
            spans `shouldBe` sort spans
            length (nub spans) `shouldBe` 3

    describe "hydrated layout" $ do
        it "rebuilds the locally built layout from its positions and bounds" $ do
            let built = buildLayout 0 fixture
            hydrateLayout fixture (layoutPositions built) `shouldBe` built

        it "takes positions and bounds from the supplied payload" $ do
            let supplied =
                    LayoutPositions
                        { lpTagPositions = IM.fromList [(0, (10, 20)), (1, (30, 40)), (2, (50, 60))]
                        , lpRecordPositions = IM.fromList [(1, (1, 2)), (2, (3, 4)), (3, (5, 6)), (4, (7, 8))]
                        , lpBounds = ((0, 0), (100, 100))
                        }
                layout = hydrateLayout fixture supplied
            IM.lookup (tagKeyOf 0) (glPos layout) `shouldBe` Just (10, 20)
            IM.lookup (recordKeyOf 2) (glPos layout) `shouldBe` Just (3, 4)
            (glMin layout, glMax layout) `shouldBe` ((0, 0), (100, 100))
            glMemberCount layout `shouldBe` 4
            glLinkCount layout `shouldBe` 2

-- | Four records, three tags, one duplicated and one unresolved wikilink.
fixture :: GraphData
fixture =
    GraphData
        { gdTags =
            [ GraphTag "rust" 2
            , GraphTag "toolbar" 1
            , GraphTag "books" 1
            ]
        , gdRecords =
            [ GraphRecord 1 "A" "example.com" 1700000000 False False [0, 1]
            , GraphRecord 2 "B" "example.com" 1700000001 False False [0]
            , GraphRecord 3 "C" "other.test" 1700000002 True False []
            , GraphRecord 4 "D" "third.test" 1700000003 False True [2]
            ]
        , gdLinks =
            [ GraphLink 1 2
            , GraphLink 2 1
            , GraphLink 2 3
            , GraphLink 2 99
            ]
        , gdRevision = "fixture:1"
        }
