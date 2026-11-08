{-# LANGUAGE OverloadedStrings #-}

-- | The clipper save path: a new capture, an idempotent replay, and a
-- conflicting reuse of the same idempotency key. Kept apart from Spec.hs so the
-- auth/data modules stay independent.
module ClipSpec (spec) where

import Control.Exception (bracket)
import Data.Text (Text)
import Database.SQLite.Simple
import Test.Hspec
import System.IO.Temp (withSystemTempDirectory)

import Eza.Clip
import Eza.Db (openDb, queryScalar)

spec :: Spec
spec = describe "browser clipper" $ do
  it "saves a capture, replays it, and rejects a conflicting key" $
    withSystemTempDirectory "eza-clip" $ \dir -> do
      bracket (openDb (dir <> "/eza.db")) close $ \conn -> do
        let request = sampleClip "first"
        first <- saveClip conn request
        case first of
          Left err -> expectationFailure ("first save failed: " <> show err)
          Right saved -> do
            scrBookmarkCreated saved `shouldBe` True
            scrBookmarkId saved `shouldSatisfy` (> 0)
            scrCaptureId saved `shouldSatisfy` (> 0)
            captures <- queryScalar conn "SELECT COUNT(*) FROM captures" :: IO Int
            captures `shouldBe` 1
            replay <- saveClip conn request
            case replay of
              Left err -> expectationFailure ("replay failed: " <> show err)
              Right again -> do
                scrReplayed again `shouldBe` True
                scrCaptureId again `shouldBe` scrCaptureId saved
                scrBookmarkId again `shouldBe` scrBookmarkId saved
            conflict <- saveClip conn (request {clTitle = "a different title"})
            conflict `shouldBe` Left ClipIdempotencyConflict

sampleClip :: Text -> ClipRequest
sampleClip title =
  ClipRequest
    { clUrl = "https://example.com/clip-test"
    , clTitle = title
    , clContentMarkdown = ""
    , clContentText = "A real body sentence for the capture."
    , clContentHtml = ""
    , clSelection = ""
    , clTags = ["clip-test"]
    , clTemplateId = Nothing
    , clSource = "extension"
    , clClient = "e2e"
    , clCapturedAt = Nothing
    , clIdempotencyKey = Just "clip-test-key"
    , clMetadata = emptyClipMetadata
    }
