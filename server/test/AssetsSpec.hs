{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Tests for the server half of the content-addressed asset pipeline:
'Eza.Assets' manifest loading and validation, and the static routes that serve
the generated bundle. The fixture bundle lives in 'TestHarness' so the static
security tests share the same shape the bundler emits.
-}
module AssetsSpec (spec) where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Eza.Assets
import Eza.Config (Config (..))
import qualified Eza.Control as Control
import TestHarness

spec :: Spec
spec = do
    describe "asset manifest loading" $ do
        it "loads a valid bundle and exposes the hashed paths" $
            withBundleDir $ \root -> do
                result <- loadAssets root
                case result of
                    Left err -> expectationFailure (T.unpack err)
                    Right assets -> do
                        assetsAvailable assets `shouldBe` True
                        assetsBuildId assets `shouldBe` testBundleBuildId
                        assetPath assets "eza.css" `shouldBe` testBundleCssPath
                        assetPath assets "theme.js" `shouldBe` testBundleThemeJsPath
                        -- Total lookup: an unknown name falls back to the
                        -- unhashed path instead of failing the page render.
                        assetPath assets "not-a-real-asset" `shouldBe` "/assets/not-a-real-asset"
                        assetRelativePath assets "eza.css" `shouldBe` Just "eza.deadbeef.css"
                        -- Fixed routes (the web manifest) have no relative
                        -- path under /assets/, so only hashed assets resolve.
                        assetRelativePath assets "manifest.webmanifest" `shouldBe` Nothing
                        assetRelativePath assets "not-a-real-asset" `shouldBe` Nothing
                        isImmutableAsset assets testBundleCssPath `shouldBe` True
                        isImmutableAsset assets testBundleWasmPath `shouldBe` True
                        isImmutableAsset assets "/assets/eza.css" `shouldBe` False
                        TE.decodeUtf8 (assetsIndexHtml assets) `shouldSatisfy` T.isInfixOf testBundleCssPath
                        assetsPrecache assets `shouldSatisfy` elem "/"
                        assetsServiceWorker assets `shouldSatisfy` containsBytes ("eza-app-shell-" <> TE.encodeUtf8 testBundleBuildId)

        it "fails with the bundler hint when the manifest is missing" $
            withSystemTempDirectory "eza-assets-missing" $ \dir -> do
                let root = dir </> "static"
                createDirectoryIfMissing True root
                message <- loadFailure root
                message `shouldSatisfy` T.isInfixOf "asset-manifest.json"
                message `shouldSatisfy` T.isInfixOf "EZA_STATIC_DIR="
                message `shouldSatisfy` T.isInfixOf "bundle-web.sh"
                message `shouldSatisfy` T.isInfixOf "release image"

        it "fails when the manifest is not valid JSON" $
            withBundleDir $ \root -> do
                BS.writeFile (root </> "asset-manifest.json") "{ not json"
                message <- loadFailure root
                message `shouldSatisfy` T.isInfixOf "not valid JSON"
                message `shouldSatisfy` T.isInfixOf "bundle-web.sh"

        it "fails when a required asset is missing from the manifest" $
            withBundleDir $ \root -> do
                let manifest = modifyField "assets" (KeyMap.delete (AesonKey.fromText "eza.css")) testBundleManifest
                rewriteManifest root manifest
                message <- loadFailure root
                message `shouldSatisfy` T.isInfixOf "eza.css"
                message `shouldSatisfy` T.isInfixOf "missing required"

        it "fails when a manifest path tries to traverse out of the static dir" $
            withBundleDir $ \root -> do
                let manifest = setKey "assets" "eza.css" (Aeson.String "/assets/../../secret.txt") testBundleManifest
                rewriteManifest root manifest
                message <- loadFailure root
                message `shouldSatisfy` T.isInfixOf "traversal"
                message `shouldSatisfy` T.isInfixOf "eza.css"

        it "fails when a shell ref disagrees with the assets map" $
            withBundleDir $ \root -> do
                let manifest = setKey "shell" "css" (Aeson.String "/assets/eza.00000000.css") testBundleManifest
                rewriteManifest root manifest
                message <- loadFailure root
                message `shouldSatisfy` T.isInfixOf "shell ref"
                message `shouldSatisfy` T.isInfixOf "css"

        it "fails when the generated shell does not reference a manifest path" $
            withBundleDir $ \root -> do
                let brokenShell = T.replace testBundleThemeJsPath "no-theme-script" testBundleShellHtml
                BS.writeFile (root </> "index.html") (TE.encodeUtf8 brokenShell)
                message <- loadFailure root
                message `shouldSatisfy` T.isInfixOf "does not reference"
                message `shouldSatisfy` T.isInfixOf "theme"

        it "fails when the build id is not a content address" $
            withBundleDir $ \root -> do
                let manifest = setKey "" "build_id" (Aeson.String "not-a-build-id") testBundleManifest
                rewriteManifest root manifest
                message <- loadFailure root
                message `shouldSatisfy` T.isInfixOf "build_id"

    describe "a server without a bundle" $ do
        it "keeps the unhashed asset paths for the placeholder and auth pages" $ do
            assetsAvailable emptyAssets `shouldBe` False
            assetsBuildId emptyAssets `shouldBe` ""
            assetPath emptyAssets "eza.css" `shouldBe` "/assets/eza.css"
            assetPath emptyAssets "auth.js" `shouldBe` "/assets/auth.js"

    describe "static serving from the manifest" $ do
        it "serves the shell no-store with the build id header" $
            withBundleServer $ \server -> do
                _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
                (session, csrf) <- loginAs server "alice" "alice password"
                response <- httpRequest server "GET" "/" (authHeaders session csrf) Nothing
                response `shouldHaveStatus` 200
                headerValue response "cache-control" `shouldBe` Just "no-store"
                headerValue response "x-eza-build" `shouldBe` Just (TE.encodeUtf8 testBundleBuildId)
                hrespBody response `shouldSatisfy` containsText testBundleCssPath

        it "serves a hashed asset immutable with an ETag and answers 304" $
            withBundleServer $ \server -> do
                response <- httpRequest server "GET" (T.unpack testBundleCssPath) [] Nothing
                response `shouldHaveStatus` 200
                headerValue response "cache-control" `shouldBe` Just "public, max-age=31536000, immutable"
                hrespBody response `shouldSatisfy` containsText "eza test asset"
                etag <- expectJust "asset etag" (headerValue response "etag")
                fresh <- httpRequest server "GET" (T.unpack testBundleCssPath) [("If-None-Match", etag)] Nothing
                fresh `shouldHaveStatus` 304

        it "serves /sw.js no-cache with the build id as ETag and answers 304" $
            withBundleServer $ \server -> do
                response <- httpRequest server "GET" "/sw.js" [] Nothing
                response `shouldHaveStatus` 200
                headerValue response "cache-control" `shouldBe` Just "no-cache"
                headerValue response "etag" `shouldBe` Just ("\"" <> TE.encodeUtf8 testBundleBuildId <> "\"")
                hrespBody response `shouldSatisfy` containsText ("eza-app-shell-" <> testBundleBuildId)
                etag <- expectJust "worker etag" (headerValue response "etag")
                fresh <- httpRequest server "GET" "/sw.js" [("If-None-Match", etag)] Nothing
                fresh `shouldHaveStatus` 304

        it "serves the stable favicon route from the manifest copy" $
            withBundleServer $ \server -> do
                response <- httpRequest server "GET" "/favicon.svg" [] Nothing
                response `shouldHaveStatus` 200
                headerValue response "cache-control" `shouldBe` Just "public, max-age=31536000, immutable"
                headerValue response "content-type" `shouldBe` Just "image/svg+xml"
                hrespBody response `shouldSatisfy` containsText "<svg"

        it "serves the generated web manifest at its fixed route" $
            withBundleServer $ \server -> do
                response <- httpRequest server "GET" "/manifest.webmanifest" [] Nothing
                response `shouldHaveStatus` 200
                headerValue response "content-type" `shouldBe` Just "application/manifest+json"

        it "renders the auth pages with the manifest's hashed URLs" $
            withBundleServer $ \server -> do
                _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
                response <- httpRequest server "GET" "/login" [] Nothing
                response `shouldHaveStatus` 200
                hrespBody response `shouldSatisfy` containsText testBundleCssPath
                hrespBody response `shouldSatisfy` containsText testBundleThemeJsPath
                hrespBody response `shouldSatisfy` containsText testBundleAuthJsPath
                hrespBody response `shouldSatisfy` containsText testBundleFaviconPath

        it "404s an unhashed asset path that the bundle does not name" $
            withBundleServer $ \server -> do
                response <- httpRequest server "GET" "/assets/eza.css" [] Nothing
                response `shouldHaveStatus` 404

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

withBundleDir :: (FilePath -> IO a) -> IO a
withBundleDir action =
    withSystemTempDirectory "eza-assets-bundle" $ \dir -> do
        let root = dir </> "static"
        writeTestStaticBundle root
        action root

withBundleServer :: (TestServer -> IO a) -> IO a
withBundleServer action =
    withSystemTempDirectory "eza-assets-server" $ \dir -> do
        let root = dir </> "static"
        withTestServerCustom
            (\cfg -> cfg{cfgStaticDir = Just root})
            (\_ -> writeTestStaticBundle root)
            action

loadFailure :: FilePath -> IO Text
loadFailure root = do
    result <- loadAssets root
    case result of
        Left message -> pure message
        Right _ -> do
            expectationFailure "expected the bundle to be rejected"
            pure ""

rewriteManifest :: FilePath -> Aeson.Value -> IO ()
rewriteManifest root value =
    BS.writeFile (root </> "asset-manifest.json") (LBS.toStrict (Aeson.encode value))

-- | Replace the top-level @field@ object with @transform@'s result.
modifyField :: Text -> (KeyMap.KeyMap Aeson.Value -> KeyMap.KeyMap Aeson.Value) -> Aeson.Value -> Aeson.Value
modifyField field transform (Aeson.Object top) =
    Aeson.Object (KeyMap.fromList (map adjustEntry (KeyMap.toList top)))
  where
    target = AesonKey.fromText field
    adjustEntry (key, value)
        | key == target = (key, case value of Aeson.Object entries -> Aeson.Object (transform entries); other -> other)
        | otherwise = (key, value)
modifyField _ _ value = value

{- | Set one string key inside a top-level object field; an empty field name
means the top level itself.
-}
setKey :: Text -> Text -> Aeson.Value -> Aeson.Value -> Aeson.Value
setKey field key value
    | T.null field = \top -> case top of
        Aeson.Object entries -> Aeson.Object (KeyMap.insert (AesonKey.fromText key) value entries)
        other -> other
    | otherwise = modifyField field (KeyMap.insert (AesonKey.fromText key) value)

containsBytes :: BS.ByteString -> BS.ByteString -> Bool
containsBytes needle haystack = needle `BS.isInfixOf` haystack
