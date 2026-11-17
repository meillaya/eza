{-# LANGUAGE OverloadedStrings #-}

{- | Native tests for the pure per-route-group reducers: one action in, the
model change and the shell effects out. These replace the behaviour checks
that used to need the Miso shell and the browser, and they pin the effect
sequence the shell interpreter consumes.
-}
module UpdateSpec (updateSpec) where

import Data.Aeson (object, (.=))
import qualified Data.IntSet as IS
import Data.List (isInfixOf)
import qualified Data.Text as T
import Test.Hspec

import Eza.Types (SavedSearch (..))
import Eza.View (ViewKind (..))
import Eza.Web.Logic.Api (BookmarkListQuery (..), ClientRequest (..))
import Eza.Web.Logic.Effect (Effect (..), RequestId (..), TimerId (..))
import Eza.Web.Logic.Error (ApiError (..), mkApiError)
import Eza.Web.Logic.Ledger (searchDebounceDelayMs)
import Eza.Web.Logic.Model
import Eza.Web.Logic.Requests (decodeResetPasswordCodes)
import Eza.Web.Logic.Route (Route (..))
import Eza.Web.Logic.Update (update)

{- | Request action, the confirmation it must arm, and the wire request its
confirmed variant must send. The six actions are the ones not covered by the
journal, so they are the ones that ask first.
-}
destructiveSurfaces :: [(Action, ConfirmKind, String)]
destructiveSurfaces =
    [ (ViewDeleteView "old", ConfirmViewDelete "old", "ApiDeleteView")
    , (RuleDelete 3, ConfirmRuleDelete 3, "ApiDeleteRule")
    , (WebhookDelete 3, ConfirmWebhookDelete 3, "ApiDeleteWebhook")
    , (TokenRevoke 3, ConfirmTokenRevoke 3, "ApiRevokeApiToken")
    , (CredentialDeleted "cred", ConfirmCredentialDelete "cred", "ApiDeleteCredential")
    , (RecoveryRegenerate, ConfirmRecoveryRegenerate, "ApiRegenerateRecovery")
    ]

escapeKey :: Action
escapeKey = KeyPressed (KeyEvent "escape" False False False False False Nothing)
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
            let dirty = initialModel{gDetail = (gDetail initialModel){dtDirty = True}, gShell = (gShell initialModel){sfRoute = Bookmark 1}}
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
            let stale = initialModel{gLedger = (gLedger initialModel){lfDebounceTimer = Nothing}}
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
            let selected = initialModel{gLedger = (gLedger initialModel){lfSelection = mempty, lfSelectAnchor = Just 2}}
                (model, _) = update selected (SearchInput "x")
            mSelectAnchor model `shouldBe` Nothing
    describe "detail and reader" $ do
        it "records a note edit and reads the caret afterwards" $ do
            let (model, effects) = run (NoteChanged "hello [[ru")
            mEditNote model `shouldBe` "hello [[ru"
            mDirty model `shouldBe` True
            effects `shouldBe` [OpReadNoteCursor]
        it "drops a stale detail response without touching the record" $ do
            let stale = initialModel{gDetail = (gDetail initialModel){dtDetailEpoch = RequestId 4}}
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
            let armed = initialModel{gMaint = (gMaint initialModel){mnConfirmPrune = True}}
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
        it "an admin reset sends the password and waits for the server codes" $ do
            let pending = initialModel{gAccount = (gAccount initialModel){acUserReset = Just 7, acUserResetPassword = "temp-pass-123"}}
                (model, effects) = update pending UserResetSubmit
            mUserActionError model `shouldBe` Nothing
            effectShows effects `shouldSatisfy` any (isInfixOf "ApiResetAdminPassword")
        it "stores the rotated recovery codes for the one-time reveal" $ do
            let pending = initialModel{gAccount = (gAccount initialModel){acUserReset = Just 7, acUserResetPassword = "temp-pass-123"}}
                (submitted, _) = update pending UserResetSubmit
                (model, _) = update submitted (UserResetDone 7 "temp-pass-123" ["code-one", "code-two"])
            mUserReset model `shouldBe` Nothing
            case mUserResetShown model of
                Just (username, password, codes) -> do
                    username `shouldBe` "7"
                    password `shouldBe` "temp-pass-123"
                    codes `shouldBe` ["code-one", "code-two"]
                Nothing -> expectationFailure "the reset reveal did not keep the recovery codes"
        it "a reset response without recovery codes is a decode error" $ do
            let endpoint = "/api/v1/admin/users/7/password"
                good = object ["ok" .= True, "recovery_codes" .= (["a", "b"] :: [T.Text])]
                bad = object ["ok" .= True]
            decodeResetPasswordCodes endpoint good `shouldBe` Right ["a", "b"]
            case decodeResetPasswordCodes endpoint bad of
                Left _ -> pure ()
                Right _ -> expectationFailure "a reset body without recovery_codes decoded"
    describe "duplicates" $ do
        it "closes the merge confirmation" $ do
            let armed = initialModel{gDedup = (gDedup initialModel){ddDedupConfirm = Just "ab-1"}}
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
            let stale = initialModel{gLedger = (gLedger initialModel){lfStatsEpoch = RequestId 9}}
                (model, effects) = update stale (StatsLoaded (RequestId 8) undefined)
            mStats model `shouldBe` Nothing
            effects `shouldBe` []
    describe "repeat-action guards" $ do
        it "disarms the prune confirmation when a candidate is toggled" $ do
            let armed = initialModel{gMaint = (gMaint initialModel){mnConfirmPrune = True, mnPruneSel = [1]}}
                (model, _) = update armed (PruneToggle 2)
            mConfirmPrune model `shouldBe` False
            mPruneSel model `shouldBe` [1, 2]
        it "requires a fresh confirmation after the prune selection changed" $ do
            let armed = initialModel{gMaint = (gMaint initialModel){mnConfirmPrune = True, mnPruneSel = [1]}}
                (toggled, _) = update armed (PruneToggle 2)
                (model, effects) = update toggled PruneRun
            mConfirmPrune model `shouldBe` True
            effectShows effects `shouldSatisfy` not . any (isInfixOf "ApiRunPrune")
        it "prunes once the confirmation is armed" $ do
            let armed = initialModel{gMaint = (gMaint initialModel){mnConfirmPrune = True, mnPruneSel = [1]}}
                (model, effects) = update armed PruneRun
            mConfirmPrune model `shouldBe` False
            effectShows effects `shouldSatisfy` any (isInfixOf "ApiRunPrune")
        it "drops a second bulk mark while one is in flight" $ do
            let busy = initialModel{gLedger = (gLedger initialModel){lfSelection = IS.fromList [1, 2], lfBulkBusy = True}}
                (_, effects) = update busy (BulkMark True)
            effects `shouldBe` []
        it "sends the first bulk mark request" $ do
            let selected = initialModel{gLedger = (gLedger initialModel){lfSelection = IS.fromList [1, 2]}}
                (_, effects) = update selected (BulkMark True)
            effectShows effects `shouldSatisfy` any (isInfixOf "ApiBulkUpdate")
        it "drops a second bulk tag submit while one is in flight" $ do
            let busy =
                    initialModel
                        { gLedger =
                            (gLedger initialModel)
                                { lfSelection = IS.fromList [1]
                                , lfTagPrompt = Just True
                                , lfTagPromptValue = "rust"
                                , lfBulkBusy = True
                                }
                        }
                (_, effects) = update busy BulkTagSubmit
            effects `shouldBe` []
        it "drops a second bulk delete confirmation while one is in flight" $ do
            let busy =
                    initialModel
                        { gLedger =
                            (gLedger initialModel)
                                { lfSelection = IS.fromList [1]
                                , lfConfirmBulkDelete = True
                                , lfBulkBusy = True
                                }
                        }
                (_, effects) = update busy BulkDeleteConfirm
            effects `shouldBe` []
        it "drops a second view save while the first is in flight" $ do
            let busy =
                    initialModel
                        { gViews =
                            (gViews initialModel)
                                { vwViewUi =
                                    (mViewUi initialModel)
                                        { vuBusy = True
                                        , vuSaveOpen = True
                                        , vuSaveName = "name"
                                        }
                                }
                        }
                (_, effects) = update busy ViewSaveSubmit
            effects `shouldBe` []
        it "sends the first view save request" $ do
            let open =
                    initialModel
                        { gViews =
                            (gViews initialModel)
                                { vwViewUi =
                                    (mViewUi initialModel)
                                        { vuSaveOpen = True
                                        , vuSaveName = "name"
                                        }
                                }
                        }
                (_, effects) = update open ViewSaveSubmit
            effectShows effects `shouldSatisfy` any (isInfixOf "ApiCreateView")
        it "drops a second webhook create while the first is in flight" $ do
            let busy = initialModel{gWebhooks = (gWebhooks initialModel){wkWebhookBusy = True}}
                (_, effects) = update busy WebhookCreate
            effects `shouldBe` []
        it "sends the first webhook create request" $ do
            let (_, effects) = run WebhookCreate
            effectShows effects `shouldSatisfy` any (isInfixOf "ApiCreateWebhook")
    describe "undo preview epoch" $ do
        it "drops an answer for an older request" $ do
            let (first, _) = update initialModel (UndoPreviewRequest 5)
                (second, _) = update first (UndoPreviewRequest 6)
                (stale, _) = update second (UndoPreviewLoaded (RequestId 1) 5 undefined)
            mUndoPreview stale `shouldBe` Nothing
            mUndoPreviewLoading stale `shouldBe` True
            mUndoPreviewId stale `shouldBe` Just 6
        it "drops an answer for a different snapshot at the current epoch" $ do
            let (fetching, _) = update initialModel (UndoPreviewRequest 5)
                (model, _) = update fetching (UndoPreviewLoaded (mUndoPreviewEpoch fetching) 6 undefined)
            mUndoPreview model `shouldBe` Nothing
        it "accepts the current answer" $ do
            let (fetching, _) = update initialModel (UndoPreviewRequest 5)
                (model, _) = update fetching (UndoPreviewLoaded (mUndoPreviewEpoch fetching) 5 undefined)
            mUndoPreviewLoading model `shouldBe` False
            mUndoPreviewId model `shouldBe` Just 5
            case mUndoPreview model of
                Just _ -> pure ()
                Nothing -> expectationFailure "current preview was dropped"
        it "a close invalidates the fetch already in flight" $ do
            let (fetching, _) = update initialModel (UndoPreviewRequest 5)
                (closed, _) = update fetching UndoPreviewClose
                (late, _) = update closed (UndoPreviewLoaded (mUndoPreviewEpoch fetching) 5 undefined)
            mUndoPreviewLoading closed `shouldBe` False
            mUndoPreviewId closed `shouldBe` Nothing
            mUndoPreview late `shouldBe` Nothing
    describe "destructive confirmations" $ do
        it "arms a confirmation for every non-journaled destructive request" $ do
            mapM_
                ( \(requestAction, kind, _) -> do
                    let (model, effects) = run requestAction
                    fmap cfKind (mConfirmation model) `shouldBe` Just kind
                    effects `shouldBe` []
                )
                destructiveSurfaces
        it "runs the action only after acceptance" $ do
            mapM_
                ( \(requestAction, _, marker) -> do
                    let (armed, _) = run requestAction
                        (model, effects) = update armed ConfirmAccepted
                    mConfirmation model `shouldBe` Nothing
                    effectShows effects `shouldSatisfy` any (isInfixOf marker)
                )
                destructiveSurfaces
        it "cancel drops the confirmation without sending anything" $ do
            mapM_
                ( \(requestAction, _, _) -> do
                    let (armed, _) = run requestAction
                        (model, effects) = update armed ConfirmCancelled
                    mConfirmation model `shouldBe` Nothing
                    effects `shouldBe` []
                )
                destructiveSurfaces
        it "accepting with no armed confirmation does nothing" $ do
            let (model, effects) = update initialModel ConfirmAccepted
            mConfirmation model `shouldBe` Nothing
            effects `shouldBe` []
    describe "per-row busy state" $ do
        it "webhook test busy names the active webhook" $ do
            let (model, effects) = run (WebhookTestRequest 3)
            mWebhookTestBusy model `shouldBe` Just 3
            effectShows effects `shouldSatisfy` any (isInfixOf "ApiTestWebhook 3")
        it "a second webhook test while one is in flight is dropped" $ do
            let (first, _) = run (WebhookTestRequest 3)
                (second, effects) = update first (WebhookTestRequest 4)
            mWebhookTestBusy second `shouldBe` Just 3
            effects `shouldBe` []
        it "an answer for another webhook does not clear the active test" $ do
            let (first, _) = run (WebhookTestRequest 3)
                (stale, _) = update first (WebhookTestJobDone 4 Nothing)
            mWebhookTestBusy stale `shouldBe` Just 3
            mWebhookTest stale `shouldBe` Nothing
        it "the active webhook's answer clears busy and reports" $ do
            let (first, _) = run (WebhookTestRequest 3)
                (done, _) = update first (WebhookTestJobFailed 3 (Just "boom"))
            mWebhookTestBusy done `shouldBe` Nothing
            mWebhookTestError done `shouldBe` Just (3, "boom")
        it "suggestion apply busy names the active record" $ do
            let (model, effects) = run (SuggestionApply 4 ["ai"])
            mSuggestionApplyBusy model `shouldBe` Just 4
            effectShows effects `shouldSatisfy` any (isInfixOf "ApiRequest")
        it "a second suggestion apply while one is in flight is dropped" $ do
            let (first, _) = run (SuggestionApply 4 ["ai"])
                (second, effects) = update first (SuggestionApply 5 ["ai"])
            mSuggestionApplyBusy second `shouldBe` Just 4
            effects `shouldBe` []
    describe "escape resolves the top layer" $ do
        it "closes the dirty guard before the palette below it" $ do
            let model =
                    initialModel
                        { gShell =
                            (gShell initialModel)
                                { sfGuardOpen = True
                                , sfPendingRoute = Just Index
                                , sfPaletteOpen = True
                                }
                        }
                (escaped, _) = update model escapeKey
            mGuardOpen escaped `shouldBe` False
            mPendingRoute escaped `shouldBe` Nothing
            mPaletteOpen escaped `shouldBe` True
        it "closes the dirty guard before a record dialog below it" $ do
            let model =
                    initialModel
                        { gShell = (gShell initialModel){sfGuardOpen = True}
                        , gShares = (gShares initialModel){srShareDialogOpen = True}
                        }
                (escaped, _) = update model escapeKey
            mGuardOpen escaped `shouldBe` False
            mShareDialogOpen escaped `shouldBe` True
        it "closes the shell confirmation before everything below it" $ do
            let model =
                    initialModel
                        { gShell =
                            (gShell initialModel)
                                { sfGuardOpen = True
                                , sfConfirmation = Just (Confirmation "t" "m" "go" ConfirmRecoveryRegenerate)
                                }
                        }
                (escaped, _) = update model escapeKey
            mConfirmation escaped `shouldBe` Nothing
            mGuardOpen escaped `shouldBe` True
    describe "web-logic lows" $ do
        it "fallback error text is neutral and keeps a server message" $ do
            aeMessage (mkApiError (Just 404) Nothing) `shouldBe` "Not found."
            aeMessage (mkApiError (Just 403) Nothing) `shouldBe` "Not allowed."
            aeMessage (mkApiError (Just 500) Nothing) `shouldBe` "Request failed (HTTP 500)."
            aeMessage (mkApiError (Just 404) (Just "row missing")) `shouldBe` "row missing"
        it "a route change cancels the pending search debounce" $ do
            let model = initialModel{gLedger = (gLedger initialModel){lfDebounceTimer = Just (TimerId 1)}}
                (changed, effects) = update model (RouteChanged "" Account)
            mDebounceTimer changed `shouldBe` Nothing
            effectShows effects `shouldSatisfy` any (isInfixOf "CancelTimer")
        it "a late debounce fire after the route change is ignored" $ do
            let model = initialModel{gLedger = (gLedger initialModel){lfDebounceTimer = Just (TimerId 2)}}
                (changed, _) = update model (RouteChanged "" Account)
                (_, effects) = update changed (TimerFired (TimerId 2))
            effects `shouldBe` []
        it "applying a saved search adopts its (possibly empty) tag facets" $ do
            let stale =
                    initialModel
                        { gLedger = (gLedger initialModel){lfTagsFilter = ["stale"], lfQ = "old"}
                        }
                savedEmpty = SavedSearch 1 "mine" "rust" [] 0
                (cleared, _) = update stale (SavedSearchApply savedEmpty)
            mTagsFilter cleared `shouldBe` []
            mQ cleared `shouldBe` "rust"
            let savedTags = SavedSearch 2 "tagged" "rust" ["haskell"] 0
                (tagged, _) = update stale (SavedSearchApply savedTags)
            mTagsFilter tagged `shouldBe` ["haskell"]
        it "a history return to the dirty record keeps the editor and drops the guard" $ do
            let dirty =
                    initialModel
                        { gShell = (gShell initialModel){sfRoute = Bookmark 1, sfGuardOpen = True, sfPendingRoute = Just Index}
                        , gDetail = (gDetail initialModel){dtDirty = True, dtEditNote = "mine"}
                        }
                (model, effects) = update dirty (RouteChanged "" (Bookmark 1))
            mDirty model `shouldBe` True
            mEditNote model `shouldBe` "mine"
            mGuardOpen model `shouldBe` False
            mPendingRoute model `shouldBe` Nothing
            effects `shouldBe` []
        it "a boot body that cannot be decoded blocks with the protocol message" $ do
            let (model, _) = run (BootDecodeFailed "boom")
            mBootReady model `shouldBe` True
            fmap (isInfixOf "boot" . T.unpack) (mBlockingError model) `shouldBe` Just True
    describe "shared URL policy" $ do
        it "the add form rejects what the strict isHttpUrl gate rejects" $ do
            mapM_
                ( \bad -> do
                    let model = initialModel{gAdd = (gAdd initialModel){adAddUrl = bad}}
                        (after, effects) = update model AddSubmit
                    mAddError after `shouldBe` Just "Enter a valid http(s) URL."
                    effects `shouldBe` []
                )
                ["http://", "https://user:pass@example.com", "https://exa mple.com", "http://..."]
        it "the add form still accepts a normal https URL" $ do
            let model = initialModel{gAdd = (gAdd initialModel){adAddUrl = "https://example.com/x"}}
                (after, effects) = update model AddSubmit
            mAddBusy after `shouldBe` True
            mAddError after `shouldBe` Nothing
            effectShows effects `shouldSatisfy` any (isInfixOf "ApiCreateBookmark")
        it "the share-target page adopts only a strict http(s) URL" $ do
            let (invalid, _) = run (RouteChanged "" (Save Nothing Nothing (Just "http://")))
            mAddUrl invalid `shouldBe` ""
            let (valid, _) = run (RouteChanged "" (Save Nothing Nothing (Just "https://example.com/x")))
            mAddUrl valid `shouldBe` "https://example.com/x"
