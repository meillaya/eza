{-# LANGUAGE OverloadedStrings #-}

{- | Native tests for the post-release polish slice: the visible failure states
and the in-flight guards that keep a repeat click from sending a second
request.
-}
module PolishSpec (polishSpec) where

import Data.Aeson (object, (.=))
import Data.List (isInfixOf)
import Test.Hspec

import Eza.Ai (AiStatus (..))

import Eza.Web.Logic.Effect (Effect (..))
import Eza.Web.Logic.Error (mkApiError)
import Eza.Web.Logic.Model
import Eza.Web.Logic.Update (update)

run :: Action -> (Model, [Effect])
run action = update initialModel action

effectShows :: [Effect] -> [String]
effectShows = map show

polishSpec :: Spec
polishSpec = describe "client polish" $ do
    describe "webhook test failure" $ do
        it "a failed job stores the error against the webhook and clears busy" $ do
            let (model, _) = run (WebhookTestJobFailed 3 (Just "boom"))
            mWebhookTestBusy model `shouldBe` False
            mWebhookTestError model `shouldBe` Just (3, "boom")
        it "a retry clears the previous failure" $ do
            let (failed, _) = run (WebhookTestJobFailed 3 (Just "boom"))
                (retried, _) = update failed (WebhookTestRequest 3)
            mWebhookTestError retried `shouldBe` Nothing
            mWebhookTestBusy retried `shouldBe` True
        it "a successful result clears the error" $ do
            let (failed, _) = run (WebhookTestJobFailed 3 (Just "boom"))
                (ok, _) = update failed (WebhookTestJobDone 3 (Just (object ["ok" .= True, "status" .= (200 :: Int)])))
            mWebhookTestError ok `shouldBe` Nothing
            mWebhookTestBusy ok `shouldBe` False
    describe "ai provider status" $ do
        it "stores a failed status read but keeps a previous status" $ do
            let status = AiStatus "anthropic" "claude" True
                (loaded, _) = run (AiStatusLoaded status)
                (failed, _) = update loaded (AiStatusFailed (mkApiError Nothing (Just "no provider")))
            mAiStatus failed `shouldBe` Just status
            mAiStatusError failed `shouldBe` Just "no provider"
        it "a successful reload clears the error" $ do
            let (failed, _) = run (AiStatusFailed (mkApiError Nothing (Just "no provider")))
                (loaded, _) = update failed (AiStatusLoaded (AiStatus "ollama" "llama" True))
            mAiStatusError loaded `shouldBe` Nothing
            mAiStatus loaded `shouldBe` Just (AiStatus "ollama" "llama" True)
        it "asking again clears the inline error first" $ do
            let (failed, _) = run (AiStatusFailed (mkApiError Nothing (Just "no provider")))
                (reloading, _) = update failed AiStatusReload
            mAiStatusError reloading `shouldBe` Nothing
    describe "snapshot viewer" $ do
        it "a load failure shows the unavailable state" $ do
            let (model, _) = run SnapshotViewerFailed
            mSnapshotViewerFailed model `shouldBe` True
        it "try again and opening the dialog both clear the unavailable state" $ do
            let (failed, _) = run SnapshotViewerFailed
                (retried, _) = update failed SnapshotViewerRetry
                (reopened, _) = update failed SnapshotOpen
            mSnapshotViewerFailed retried `shouldBe` False
            mSnapshotViewerFailed reopened `shouldBe` False
    describe "in-flight guards" $ do
        it "a second revoke click is a no-op while the first is in flight" $ do
            let (first, firstEffects) = run (ShareRevoke 9)
                (second, secondEffects) = update first (ShareRevoke 9)
            mShareBusy first `shouldBe` True
            effectShows firstEffects `shouldSatisfy` any (isInfixOf "ApiRequest")
            secondEffects `shouldBe` []
            mShareBusy second `shouldBe` True
        it "the revoke answer clears the guard" $ do
            let (busy, _) = run (ShareRevoke 9)
                (done, _) = update busy ShareRevoked
            mShareBusy done `shouldBe` False
        it "a second apply click is a no-op while the first is in flight" $ do
            let (first, firstEffects) = run (SuggestionApply 4 ["ai"])
                (second, secondEffects) = update first (SuggestionApply 4 ["ai"])
            mSuggestionApplyBusy first `shouldBe` True
            effectShows firstEffects `shouldSatisfy` any (isInfixOf "ApiRequest")
            secondEffects `shouldBe` []
            mSuggestionApplyBusy second `shouldBe` True
        it "the apply failure clears the guard and reports the error" $ do
            let (busy, _) = run (SuggestionApply 4 ["ai"])
                (failed, _) = update busy (SuggestionApplyFailed (mkApiError Nothing (Just "nope")))
            mSuggestionApplyBusy failed `shouldBe` False
            mSuggestionError failed `shouldBe` Just "nope"
    describe "saved-search refresh" $ do
        it "a failed background refresh keeps the list and raises one notice" $ do
            let apiError = mkApiError Nothing (Just "network down")
                (failed, firstEffects) = run (SavedSearchesRefreshFailed apiError)
                (_, secondEffects) = update failed (SavedSearchesRefreshFailed apiError)
            mSavedSearchesError failed `shouldBe` Just "network down"
            length (mToasts failed) `shouldBe` 1
            effectShows firstEffects `shouldSatisfy` any (isInfixOf "OpScheduleAction")
            effectShows secondEffects `shouldSatisfy` not . any (isInfixOf "OpScheduleAction")
        it "a successful load clears the notice" $ do
            let (failed, _) = run (SavedSearchesRefreshFailed (mkApiError Nothing (Just "network down")))
                (loaded, _) = update failed (SavedSearchesLoaded [])
            mSavedSearchesError loaded `shouldBe` Nothing
