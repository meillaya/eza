{-# LANGUAGE OverloadedStrings #-}

{- | Contract checks between spec/schema examples and the Haskell codecs.

The formal specs and JSON Schemas are design artifacts; these tests make sure
the documents the repository ships as examples are exactly what the server
accepts, and that every counterexample is rejected by the same validators.
-}
module ViewContractSpec (viewContractSpec) where

import Control.Monad (filterM, forM_)
import Data.Aeson (Result (..), Value, decodeStrict', fromJSON)
import qualified Data.ByteString as BS
import Data.Either (isLeft)
import System.Directory (doesDirectoryExist, getCurrentDirectory)
import System.FilePath ((</>))
import Test.Hspec

import Eza.View
import Eza.Webhook

viewContractSpec :: Spec
viewContractSpec = do
    it "accepts every valid example document with the server codecs" $ do
        root <- findRepoRoot
        -- Graph and ledger examples are stored views; they must decode and
        -- pass the same validation the API applies to a draft.
        forM_ ["graph-view.json", "ledger-view.json"] $ \name -> do
            value <- readJson (root </> "spec" </> "examples" </> name)
            case fromJSON value :: Result View of
                Error message -> expectationFailure (name <> " failed to decode: " <> message)
                Success view ->
                    validateViewDraft
                        (ViewInput (vName view) (vKind view) (vDefinition view) (Just (vSlug view)))
                        `shouldBe` Right ()
        -- The webhook example is an input document.
        value <- readJson (root </> "spec" </> "examples" </> "webhook.json")
        case fromJSON value :: Result WebhookInput of
            Error message -> expectationFailure ("webhook.json failed to decode: " <> message)
            Success input -> validateWebhookInput input `shouldBe` Right ()

    it "rejects every counterexample document" $ do
        root <- findRepoRoot
        let badView name = do
                value <- readJson (root </> "spec" </> "bad" </> name)
                takeViewDraft value `shouldBe` Nothing
        mapM_ badView ["unknown-kind.json", "bad-schema.json", "bad-color.json", "bad-slug.json", "too-many-groups.json"]
        value <- readJson (root </> "spec" </> "bad" </> "webhook-unknown-event.json")
        (fromJSON value :: Result WebhookInput) `shouldSatisfy` isError
        ( case fromJSON value :: Result WebhookInput of
                Error _ -> Nothing
                Success input -> either (const Nothing) (const (Just input)) (validateWebhookInput input)
            )
            `shouldBe` Nothing

    it "agrees with the schema on the slug first character and colour case" $ do
        -- The schema pattern requires a slug to start with [a-z0-9].
        validateViewDraft
            (ViewInput "Name" LedgerKind (LedgerDefinition defaultLedgerViewDefinition) (Just "-leading"))
            `shouldSatisfy` isLeft
        validateViewDraft
            (ViewInput "Name" LedgerKind (LedgerDefinition defaultLedgerViewDefinition) (Just "0-leading"))
            `shouldBe` Right ()
        -- The schema pattern accepts upper-case hex digits; its description
        -- says so too, so the validator must accept them.
        validateColor "#AABBCC" `shouldBe` Right ()
        validateColor "#00ff0" `shouldSatisfy` isLeft

    it "parses the JSON Schema files as JSON" $ do
        root <- findRepoRoot
        forM_ ["view.schema.json", "webhook.schema.json"] $ \name -> do
            _ <- readJson (root </> "spec" </> "schema" </> name)
            pure ()

{- | Decode a stored-view wrapper, then apply the draft validation the API
applies. Any step failing means the document is not a valid view.
-}
takeViewDraft :: Value -> Maybe ViewInput
takeViewDraft value = case fromJSON value :: Result View of
    Error _ -> Nothing
    Success view -> case validateViewDraft (ViewInput (vName view) (vKind view) (vDefinition view) (Just (vSlug view))) of
        Left _ -> Nothing
        Right () -> Just (ViewInput (vName view) (vKind view) (vDefinition view) (Just (vSlug view)))

readJson :: FilePath -> IO Value
readJson path = do
    raw <- BS.readFile path
    case decodeStrict' raw of
        Nothing -> ioError (userError ("not valid JSON: " <> path))
        Just value -> pure value

isError :: Result a -> Bool
isError (Error _) = True
isError (Success _) = False

{- | Cabal runs the test suite from the package directory (server/) and the
e2e tools from the repository root; support both without hard-coding a path.
-}
findRepoRoot :: IO FilePath
findRepoRoot = do
    cwd <- getCurrentDirectory
    let candidates = [cwd, cwd </> "..", cwd </> ".." </> ".."]
    found <- filterM (\dir -> doesDirectoryExist (dir </> "spec" </> "examples")) candidates
    case found of
        (dir : _) -> pure dir
        [] -> ioError (userError ("cannot find spec/examples from " <> cwd))
