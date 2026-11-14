{-# LANGUAGE OverloadedStrings #-}

{- | Native tests for the pure per-route-group reducers: one action in, the
model change and the shell effects out. These replace the behaviour checks
that used to need the Miso shell and the browser, and they pin the effect
sequence the shell interpreter consumes.
-}
module UpdateSpec (updateSpec) where

import Data.List (isInfixOf)
import qualified Data.Text as T
import Test.Hspec

import Eza.View (ViewKind (..))
import Eza.Web.Logic.Api (BookmarkListQuery (..), ClientRequest (..))
import Eza.Web.Logic.Effect (Effect (..), RequestId (..), TimerId (..))
import Eza.Web.Logic.Ledger (searchDebounceDelayMs)
import Eza.Web.Logic.Model
import Eza.Web.Logic.Route (Route (..))
import Eza.Web.Logic.Update (update)

run :: Action -> (Model, [Effect])
run action = update initialModel action

effectShows :: [Effect] -> [String]
effectShows = map show

updateSpec :: Spec
updateSpec = describe "native per-group update" $ do
    describe "shell" $ do
        it "boots: marks the app booted, reads /boot and the environment" $ do
            let (model, effects) = run Mounted
            mBooted model `shouldBe` True
            case effects of
                (ApiRequest ApiBoot Nothing _ : OpBootstrapEnvironment : _) -> pure ()
                other -> expectationFailure ("unexpected effects: " <> show other)
        it "pushes a route through the history command" $ do
            let (model, effects) = run (Navigate (Bookmark 3))
            mRoute model `shouldBe` Index
            effects `shouldBe` [OpNavigate (Bookmark 3)]
        it "adds a toast and schedules its dismissal" $ do
            let (model, effects) = run (ToastAdd "saved" ToastOk)
            map toastId (mToasts model) `shouldBe` [mToastNext initialModel]
            effectShows effects `shouldSatisfy` any (isInfixOf "OpScheduleAction 4800")
        it "starts the dirty guard instead of navigating away from an edit" $ do
            let dirty = initialModel{mDirty = True, mRoute = Bookmark 1}
                (model, effects) = update dirty (Navigate Index)
            mGuardOpen model `shouldBe` True
            mPendingRoute model `shouldBe` Just Index
            effects `shouldBe` []
    describe "ledger" $ do
        it "keeps the search text and schedules the debounce timer" $ do
            let (model, effects) = run (SearchInput "rust")
            mQ model `shouldBe` "rust"
            case effects of
                [Schedule delay (TimerId 1)] -> delay `shouldBe` searchDebounceDelayMs
                other -> expectationFailure ("unexpected effects: " <> show other)
        it "a late timer does not reload the list" $ do
            let stale = initialModel{mDebounceTimer = Nothing}
                (_, effects) = update stale (TimerFired (TimerId 42))
            effects `shouldBe` []
        it "committing the search reloads the first page" $ do
            let (model, effects) = update initialModel SearchCommit
            mLoading model `shouldBe` True
            case effects of
                (Fetch (ApiBookmarks query) _ : _) ->
                    (blqQ query, blqOffset query) `shouldBe` ("", 0)
                other -> expectationFailure ("unexpected effects: " <> show other)
        it "clears the selection when the query changes" $ do
            let selected = initialModel{mSelection = mempty, mSelectAnchor = Just 2}
                (model, _) = update selected (SearchInput "x")
            mSelectAnchor model `shouldBe` Nothing
    describe "detail and reader" $ do
        it "records a note edit and reads the caret afterwards" $ do
            let (model, effects) = run (NoteChanged "hello [[ru")
            mEditNote model `shouldBe` "hello [[ru"
            mDirty model `shouldBe` True
            effects `shouldBe` [OpReadNoteCursor]
        it "drops a stale detail response without touching the record" $ do
            let stale = initialModel{mDetailEpoch = RequestId 4}
                (model, effects) = update stale (DetailLoaded (RequestId 3) undefined)
            mDetail model `shouldBe` Nothing
            effects `shouldBe` []
        it "opens the add dialog from the palette action list" $ do
            let (model, _) = run AddOpen
            mAddOpen model `shouldBe` True
    describe "graph" $ do
        it "keeps the filter text and debounces the settle" $ do
            let (model, effects) = run (GraphFilterChanged "tag:rust")
            mGraphFilter model `shouldBe` "tag:rust"
            effects `shouldBe` [OpGraphFilterSettle]
        it "zooms only when a layout is present" $ do
            let (_, effects) = run GraphZoomIn
            effects `shouldBe` []
    describe "tags and views" $ do
        it "filters the ledger by one tag (already on the index)" $ do
            let (model, effects) = run (FilterByTag "rust")
            mTagsFilter model `shouldBe` ["rust"]
            effects `shouldBe` []
        it "opens the rename dialog with the tag it names" $ do
            let (model, _) = run (TagDialogOpen (TagRenameDialog "old"))
            mTagDialog model `shouldBe` Just (TagRenameDialog "old")
        it "opens the save-view sheet for a graph view" $ do
            let (model, _) = run (ViewSaveOpen GraphKind)
            vuSaveOpen (mViewUi model) `shouldBe` True
    describe "maintenance" $ do
        it "cancels a prune confirmation" $ do
            let armed = initialModel{mConfirmPrune = True}
                (model, _) = update armed PruneCancel
            mConfirmPrune model `shouldBe` False
        it "starts the dead-link sweep with a write request" $ do
            let (model, effects) = run DeadCheckRun
            mMaintBusy model `shouldBe` True
            case effects of
                (ApiRequest ApiCheckDead (Just _) _ : _) -> pure ()
                other -> expectationFailure ("unexpected effects: " <> show other)
    describe "import and export" $ do
        it "opens the file picker" $ do
            let (_, effects) = run ImportStart
            effects `shouldBe` [OpTriggerFileInput "import-file"]
    describe "account and admin" $ do
        it "records the username edit" $ do
            let (model, _) = run (SecurityUsernameInput "new-user")
            mSecurityUsername model `shouldBe` "new-user"
        it "switches the account tab" $ do
            let (model, _) = run (AccountTabSelected AccountAppearance)
            mAccountTab model `shouldBe` AccountAppearance
        it "cancels a webhook test dialog" $ do
            let (model, effects) = run (WebhookSecretDismiss)
            effects `shouldBe` []
            mWebhookSecret model `shouldBe` Nothing
    describe "duplicates" $ do
        it "closes the merge confirmation" $ do
            let armed = initialModel{mDedupConfirm = Just "ab-1"}
                (model, _) = update armed DedupMergeCancel
            mDedupConfirm model `shouldBe` Nothing
        it "refreshes both duplicate sections" $ do
            let (model, effects) = update initialModel DedupRefresh
            mDedupLoading model `shouldBe` True
            case effects of
                (ApiRequest (ApiDedupCandidates _) Nothing _ : _) -> pure ()
                other -> expectationFailure ("unexpected effects: " <> show other)
    describe "route loading" $ do
        it "fetches the record a bookmark route names" $ do
            let (_, effects) = run (RouteChanged "" (Bookmark 7))
            effectShows effects
                `shouldSatisfy` any (isInfixOf "ApiRequest ApiBookmark 7")
            effectShows effects
                `shouldSatisfy` any (isInfixOf "OpSetDocumentTitle")
        it "defers the index list until /boot answers on a first paint" $ do
            let (model, effects) = run (RouteChanged "" Index)
            mRoute model `shouldBe` Index
            mLoading model `shouldBe` True
            mListDeferred model `shouldBe` True
            effectShows effects `shouldBe` ["OpSetDocumentTitle \"eza\""]
    describe "request id ordering" $ do
        it "accepts a toast id sequence without gaps" $ do
            let (model1, _) = run (ToastAdd "one" ToastOk)
                (model2, _) = update model1 (ToastAdd "two" ToastInfo)
            map toastId (mToasts model2) `shouldBe` [mToastNext initialModel, mToastNext initialModel + 1]
        it "drops a stale stats answer" $ do
            let stale = initialModel{mStatsEpoch = RequestId 9}
                (model, effects) = update stale (StatsLoaded (RequestId 8) undefined)
            mStats model `shouldBe` Nothing
            effects `shouldBe` []
