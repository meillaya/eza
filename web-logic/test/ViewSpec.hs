{-# LANGUAGE OverloadedStrings #-}

{- | Native tests for the effective graph label mode: a saved graph view's
definition owns the label mode while it is active; without an active saved
view the shell's current choice is kept.
-}
module ViewSpec (viewSpec) where

import qualified Data.Text as T
import Test.Hspec

import Eza.GraphLayout (LayoutPreset (..))
import qualified Eza.View as EV

import Eza.Web.Logic.Model
import Eza.Web.Logic.Update.ViewDefs (effectiveGraphLabelMode)

graphView :: Int -> EV.LabelMode -> EV.View
graphView viewId mode =
    EV.View
        { EV.vId = viewId
        , EV.vSlug = "graph-" <> T.pack (show viewId)
        , EV.vName = "Graph view"
        , EV.vKind = EV.GraphKind
        , EV.vIsDefault = False
        , EV.vDefinition =
            EV.GraphDefinition
                EV.GraphViewDefinition
                    { EV.gvdQuery = ""
                    , EV.gvdTagsShown = True
                    , EV.gvdLabelMode = mode
                    , EV.gvdLayoutPreset = Standard
                    , EV.gvdLocalDepth = Nothing
                    , EV.gvdColorGroups = []
                    }
        , EV.vCreatedAt = 0
        , EV.vUpdatedAt = 1
        }

ledgerView :: Int -> EV.View
ledgerView viewId =
    (graphView viewId EV.LabelAuto)
        { EV.vKind = EV.LedgerKind
        , EV.vDefinition = EV.LedgerDefinition EV.LedgerViewDefinition{EV.lvdQuery = "", EV.lvdSort = EV.SortCreated}
        }

viewSpec :: Spec
viewSpec = describe "effective graph label mode" $ do
    it "keeps the shell choice when no saved view is active" $ do
        let model = initialModel{mGraphLabelMode = EV.LabelTags}
        effectiveGraphLabelMode model `shouldBe` EV.LabelTags
    it "uses the active saved view's label_mode" $ do
        let model =
                initialModel
                    { mGraphLabelMode = EV.LabelTags
                    , mViews = [graphView 7 EV.LabelNone]
                    , mGraphViewId = Just 7
                    }
        effectiveGraphLabelMode model `shouldBe` EV.LabelNone
    it "supports every label mode the view definition can carry" $ do
        let modeFor mode = effectiveGraphLabelMode initialModel{mViews = [graphView 3 mode], mGraphViewId = Just 3}
        modeFor EV.LabelAuto `shouldBe` EV.LabelAuto
        modeFor EV.LabelTags `shouldBe` EV.LabelTags
        modeFor EV.LabelNone `shouldBe` EV.LabelNone
    it "ignores a view that is not in the loaded list" $ do
        let model =
                initialModel
                    { mGraphLabelMode = EV.LabelTags
                    , mViews = [graphView 7 EV.LabelNone]
                    , mGraphViewId = Just 99
                    }
        effectiveGraphLabelMode model `shouldBe` EV.LabelTags
    it "falls back for a saved view that is not a graph definition" $ do
        let model =
                initialModel
                    { mGraphLabelMode = EV.LabelTags
                    , mViews = [ledgerView 2]
                    , mGraphViewId = Just 2
                    }
        effectiveGraphLabelMode model `shouldBe` EV.LabelTags
    it "updates when the active view changes" $ do
        let views = [graphView 1 EV.LabelNone, graphView 2 EV.LabelAuto]
            first = initialModel{mViews = views, mGraphViewId = Just 1}
            second = first{mGraphViewId = Just 2}
        effectiveGraphLabelMode first `shouldBe` EV.LabelNone
        effectiveGraphLabelMode second `shouldBe` EV.LabelAuto
    it "does not read the saved view without a selected view id" $ do
        let model = initialModel{mGraphLabelMode = EV.LabelAuto, mViews = [graphView 4 EV.LabelNone]}
        effectiveGraphLabelMode model `shouldBe` EV.LabelAuto
