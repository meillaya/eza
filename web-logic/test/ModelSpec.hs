{-# LANGUAGE OverloadedStrings #-}

{- | Native tests for the migrated pure client model: the initial state, the
formatting/label helpers, the graph state types, the client-local wire records
and the action vocabulary. These would have needed a WASM toolchain before the
model moved out of the Miso shell.
-}
module ModelSpec (modelSpec) where

import Data.Aeson (decode)
import qualified Data.Text as T
import Test.Hspec

import Eza.GraphLayout (LayoutPreset (..))
import Eza.Types (SavedSearch (..))

import Eza.Web.Logic.Effect (RequestId (..))
import Eza.Web.Logic.Graph (GraphView (..), initialGraphView)
import Eza.Web.Logic.Model
import Eza.Web.Logic.Route (Route (..))
import Eza.Web.Logic.Wire (ImportResponse (..), ListParams (..), WebhookTest (..))

modelSpec :: Spec
modelSpec = describe "native client model" $ do
    describe "initial model" $ do
        it "starts on the index route with an empty, loading ledger" $ do
            mRoute initialModel `shouldBe` Index
            mQ initialModel `shouldBe` ""
            mItems initialModel `shouldBe` []
            mLoading initialModel `shouldBe` True
            mHasMore initialModel `shouldBe` False
        it "starts with zeroed request ids and no graph layout" $ do
            mListEpoch initialModel `shouldBe` RequestId 0
            mStatsEpoch initialModel `shouldBe` RequestId 0
            mDetailEpoch initialModel `shouldBe` RequestId 0
            mGraphLayout initialModel `shouldBe` Nothing
            activeGraphLayout initialModel `shouldBe` Nothing
        it "starts with the default query and sort" $ do
            mSort initialModel `shouldBe` "created"
            mTagsFilter initialModel `shouldBe` []
            mUnreadOnly initialModel `shouldBe` False
            mNoteMode initialModel `shouldBe` NoteWrite
    describe "theme helpers" $ do
        it "round-trips the stored theme name" $ do
            themeToText ThemeDark `shouldBe` "dark"
            themeToText ThemeLight `shouldBe` "light"
            themeOfText "dark" `shouldBe` ThemeDark
            themeOfText "light" `shouldBe` ThemeLight
            themeOfText " DARK " `shouldBe` ThemeDark
            themeOfText "unknown" `shouldBe` ThemeLight
    describe "route labels and tabs" $ do
        it "renders the account tab slugs used by the URL fragment" $ do
            accountTabSlug AccountSecurity `shouldBe` "security"
            accountTabSlug AccountAppearance `shouldBe` "appearance"
            accountTabFromSlug "capture" `shouldBe` AccountCapture
            accountTabFromSlug "nonsense" `shouldBe` AccountSecurity
        it "explains a wire-version mismatch with both versions" $ do
            let message = wireVersionMismatchMessage 99
            message `shouldSatisfy` T.isInfixOf "wire version"
            message `shouldSatisfy` T.isInfixOf "99"
    describe "formatting helpers" $ do
        it "formats timestamps without throwing for zero and large values" $ do
            let stamp = 1760000000
            formatStamp stamp `shouldSatisfy` (not . T.null)
            formatStampUtc stamp `shouldSatisfy` (not . T.null)
            formatFiled stamp `shouldSatisfy` (not . T.null)
            formatProseDate stamp `shouldSatisfy` (not . T.null)
        it "labels the sort keys" $ do
            sortLabel "created" `shouldBe` "Saved date"
            sortLabel "added" `shouldBe` "Added date"
            sortLabel "opened" `shouldBe` "Last opened"
            sortLabel "other" `shouldBe` "Saved date"
    describe "palette entries" $ do
        it "offers the global actions on an empty query" $ do
            let actions = [action | (_, _, action) <- paletteEntries initialModel]
            null actions `shouldBe` False
        it "filters the catalogue by the palette query" $ do
            let model = initialModel{gShell = (gShell initialModel){sfPaletteQ = "theme"}}
                labels = [T.toLower label | (label, _, _) <- paletteEntries model]
            labels `shouldSatisfy` all (T.isInfixOf "theme")
        it "adds a saved-search entry" $ do
            let saved = SavedSearch 3 "rust reading" "rust" [] 0
                model = initialModel{gLedger = (gLedger initialModel){lfSaved = [saved]}, gShell = (gShell initialModel){sfPaletteQ = "rust"}}
            any (\(label, hint, _) -> label == "rust reading" && hint == "saved search") (paletteEntries model)
                `shouldBe` True
    describe "graph state types" $ do
        it "keeps the initial viewport and layout preset" $ do
            gvWidth initialGraphView `shouldBe` 920
            gvScale initialGraphView `shouldBe` 1
            mGraphPreset initialModel `shouldBe` Standard
    describe "client-local wire records" $ do
        it "decodes the import summary" $ do
            (decode "{\"inserted\":2,\"found\":3,\"existing\":1}" :: Maybe ImportResponse)
                `shouldBe` Just (ImportResponse 2 3 1 Nothing)
        it "decodes the webhook test answer" $ do
            (decode "{\"ok\":true,\"status\":200,\"error\":\"\"}" :: Maybe WebhookTest)
                `shouldBe` Just (WebhookTest True (Just 200) "")
        it "keeps the list parameters native" $ do
            ListParams "" [] "created" False 0 60 `shouldBe` ListParams "" [] "created" False 0 60
    describe "reader selection" $ do
        it "decodes offsets and quote from the DOM bridge payload" $ do
            (decode "{\"start\":3,\"end\":8,\"quote\":\"hello\"}" :: Maybe ReaderSelection)
                `shouldBe` Just (ReaderSelection 3 8 "hello")
        it "is kept in the action vocabulary as key state" $ do
            KeyEvent "Enter" True True False False False (Just 7)
                `shouldBe` KeyEvent "Enter" True True False False False (Just 7)
            mToasts initialModel `shouldBe` []
