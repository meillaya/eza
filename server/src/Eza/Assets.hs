{-# LANGUAGE OverloadedStrings #-}

{- | Content-addressed web assets, loaded from @EZA_STATIC_DIR@.

The bundler (@scripts/bundle-web.sh@) writes @static/asset-manifest.json@ plus
the hashed files it names. This module reads the manifest once at startup,
validates its shape, its required keys, and every file it references, and
caches the generated shell and service worker. It is the only place the server
learns asset names: the static routes, 'Eza.Shell', and 'Eza.Pages' all look
their URLs up here, so no other module keeps an asset list.

A server started with @EZA_STATIC_DIR@ set but without a valid bundle must not
start silently: 'loadAssetsForStartup' prints one actionable error and exits
instead of serving a shell that cannot boot.
-}
module Eza.Assets (
    Assets,
    emptyAssets,
    loadAssets,
    loadAssetsForStartup,
    assetsAvailable,
    assetsBuildId,
    assetsRoot,
    assetsShellPaths,
    assetsPrecache,
    assetsServiceWorker,
    assetsIndexHtml,
    assetPath,
    assetRelativePath,
    isImmutableAsset,
    requiredAssetKeys,
) where

import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_, unless)
import Data.Aeson (Value (..), eitherDecodeStrict')
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import Data.Char (isHexDigit)
import Data.List (isPrefixOf, nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, doesPathExist)
import System.Exit (exitFailure)
import System.FilePath (addTrailingPathSeparator, (</>))
import System.IO (hPutStrLn, stderr)

-- ---------------------------------------------------------------------------
-- The loaded bundle
-- ---------------------------------------------------------------------------

{- | One validated bundle. The constructor stays private: a value only exists
after 'loadAssets' has checked the manifest and the files it names.
-}
data Assets = Assets
    { asRoot :: Maybe FilePath
    -- ^ The static root; 'Nothing' for a server started without a bundle.
    , asBuildId :: Text
    , asPaths :: Map Text Text
    -- ^ Logical asset name (e.g. @eza.css@) to served path.
    , asShell :: Map Text Text
    -- ^ Shell ref name (e.g. @css@) to served path.
    , asPrecache :: [Text]
    -- ^ The service-worker precache list, in manifest order.
    , asIndexHtml :: BS.ByteString
    -- ^ The generated shell, served no-store.
    , asServiceWorker :: BS.ByteString
    -- ^ The generated worker, served no-cache with the build id as ETag.
    , asUrlPaths :: Set Text
    -- ^ Every hashed @/assets/@ path; requests for these are immutable.
    }

{- | A server with no bundle configured: the placeholder page and the auth
pages' unhashed fallback paths are all it can serve.
-}
emptyAssets :: Assets
emptyAssets = Assets Nothing "" Map.empty Map.empty [] "" "" Set.empty

assetsAvailable :: Assets -> Bool
assetsAvailable = isJust . asRoot

assetsBuildId :: Assets -> Text
assetsBuildId = asBuildId

assetsRoot :: Assets -> Maybe FilePath
assetsRoot = asRoot

assetsShellPaths :: Assets -> Map Text Text
assetsShellPaths = asShell

assetsPrecache :: Assets -> [Text]
assetsPrecache = asPrecache

assetsServiceWorker :: Assets -> BS.ByteString
assetsServiceWorker = asServiceWorker

assetsIndexHtml :: Assets -> BS.ByteString
assetsIndexHtml = asIndexHtml

{- | Total lookup of a logical asset name. An unknown name falls back to the
unhashed @/assets/\<name\>@ path so a server without a bundle can still render
its placeholder and auth pages without a partial function. A missing logical
name is a programming error that the required-key check at startup prevents.
-}
assetPath :: Assets -> Text -> Text
assetPath assets name = Map.findWithDefault ("/assets/" <> name) name (asPaths assets)

{- | The static-root relative path for a logical asset name, when the bundle
names one. Named public routes such as @\/favicon.svg@ use this to serve the
hashed file without keeping a second asset list.
-}
assetRelativePath :: Assets -> Text -> Maybe Text
assetRelativePath assets name = do
    url <- Map.lookup name (asPaths assets)
    T.stripPrefix "/assets/" url

-- | Whether a served URL path is one of the bundle's hashed assets.
isImmutableAsset :: Assets -> Text -> Bool
isImmutableAsset assets urlPath = Set.member urlPath (asUrlPaths assets)

-- ---------------------------------------------------------------------------
-- Loading and validation
-- ---------------------------------------------------------------------------

{- | Load and validate one bundle. The 'Left' value is an operator-facing
message; 'loadAssetsForStartup' prints it and exits.
-}
loadAssets :: FilePath -> IO (Either Text Assets)
loadAssets root = do
    let manifestPath = root </> "asset-manifest.json"
    manifestExists <- doesFileExist manifestPath
    if not manifestExists
        then pure (Left (missingManifestMessage root))
        else do
            readResult <- try (BS.readFile manifestPath) :: IO (Either SomeException BS.ByteString)
            case readResult of
                Left err -> pure (Left (invalidBundleMessage root ("could not read asset-manifest.json: " <> T.pack (show err))))
                Right raw -> case eitherDecodeStrict' raw of
                    Left err -> pure (Left (invalidBundleMessage root ("asset-manifest.json is not valid JSON: " <> T.pack err)))
                    Right value -> case parseManifest value of
                        Left err -> pure (Left (invalidBundleMessage root err))
                        Right manifest -> validateAssets root manifest

data Manifest = Manifest
    { mBuildId :: Text
    , mAssets :: Map Text Text
    , mShell :: Map Text Text
    , mPrecache :: [Text]
    }

parseManifest :: Value -> Either Text Manifest
parseManifest (Object top) = do
    case KeyMap.lookup (AesonKey.fromText "schema_version") top of
        Just (Number version)
            | version == 1 -> pure ()
            | otherwise -> Left ("asset-manifest.json has unsupported schema_version " <> T.pack (show version) <> "; this server understands 1")
        Just _ -> Left "asset-manifest.json field schema_version must be a number"
        Nothing -> Left "asset-manifest.json is missing field schema_version"
    buildId <- textField top "build_id"
    assets <- textObjectField top "assets"
    shell <- textObjectField top "shell"
    precache <- textListField top "precache"
    pure Manifest{mBuildId = buildId, mAssets = assets, mShell = shell, mPrecache = precache}
parseManifest _ = Left "asset-manifest.json must contain a JSON object"

textField :: KeyMap.KeyMap Value -> Text -> Either Text Text
textField object name = case KeyMap.lookup (AesonKey.fromText name) object of
    Nothing -> Left ("asset-manifest.json is missing field " <> quote name)
    Just (String value) -> Right value
    Just _ -> Left ("asset-manifest.json field " <> quote name <> " must be a string")

textObjectField :: KeyMap.KeyMap Value -> Text -> Either Text (Map Text Text)
textObjectField object name = case KeyMap.lookup (AesonKey.fromText name) object of
    Nothing -> Left ("asset-manifest.json is missing field " <> quote name)
    Just (Object entries) -> do
        pairs <-
            forM (KeyMap.toList entries) $ \(key, value) -> case value of
                String text -> Right (AesonKey.toText key, text)
                _ -> Left ("asset-manifest.json entry " <> quote (AesonKey.toText key) <> " in " <> quote name <> " must be a string")
        pure (Map.fromList pairs)
    Just _ -> Left ("asset-manifest.json field " <> quote name <> " must be an object")

textListField :: KeyMap.KeyMap Value -> Text -> Either Text [Text]
textListField object name = case KeyMap.lookup (AesonKey.fromText name) object of
    Nothing -> Left ("asset-manifest.json is missing field " <> quote name)
    Just (Array entries) -> forM (foldr (:) [] entries) $ \value -> case value of
        String text -> Right text
        _ -> Left ("asset-manifest.json field " <> quote name <> " must contain only strings")
    Just _ -> Left ("asset-manifest.json field " <> quote name <> " must be an array")

quote :: Text -> Text
quote value = "\"" <> value <> "\""

{- | The logical names the server code and the shell reference by name. The
bundler always emits all of them; a manifest missing one is stale or
hand-written.
-}
requiredAssetKeys :: [Text]
requiredAssetKeys =
    [ "app.ghc_wasm_jsffi.js"
    , "app.index.js"
    , "app.wasm"
    , "auth.js"
    , "eza.css"
    , "favicon-fallback.svg"
    , "favicon.svg"
    , "fonts/newsreader-300-800.woff2"
    , "icons/icon-192.png"
    , "icons/icon-512.png"
    , "manifest.webmanifest"
    , "pwa.js"
    , "theme.js"
    , "vendor/browser_wasi_shim"
    ]

-- | Shell ref name to the logical asset name it must equal.
shellRefKeys :: [(Text, Text)]
shellRefKeys =
    [ ("apple_touch_icon", "icons/icon-192.png")
    , ("auth_js", "auth.js")
    , ("css", "eza.css")
    , ("favicon", "favicon.svg")
    , ("favicon_fallback", "favicon-fallback.svg")
    , ("manifest", "manifest.webmanifest")
    , ("module_js", "app.index.js")
    , ("preload_font", "fonts/newsreader-300-800.woff2")
    , ("pwa_js", "pwa.js")
    , ("theme_js", "theme.js")
    ]

validateAssets :: FilePath -> Manifest -> IO (Either Text Assets)
validateAssets root manifest = case validateShape manifest of
    Left err -> pure (Left (invalidBundleMessage root err))
    Right () -> do
        fileResults <- forM (Map.toList (mAssets manifest)) $ \(logicalName, urlPath) -> do
            fileResult <- resolveAssetPath root urlPath
            pure $ case fileResult of
                Left err -> Left (invalidBundleMessage root ("asset " <> quote logicalName <> " (" <> urlPath <> "): " <> err))
                Right resolved -> Right resolved
        case sequence fileResults of
            Left err -> pure (Left err)
            Right _files -> do
                shellResult <- loadFixedFile root "index.html"
                workerResult <- loadFixedFile root "sw.js"
                precacheResult <- checkPrecache root (mPrecache manifest)
                pure $ do
                    shellBytes <- shellResult
                    workerBytes <- workerResult
                    () <- precacheResult
                    let shellText = TE.decodeUtf8With lenientDecode shellBytes
                        workerText = TE.decodeUtf8With lenientDecode workerBytes
                    checkShellHtml (mShell manifest) shellText
                    checkServiceWorker (mBuildId manifest) (mPrecache manifest) workerText
                    Right
                        Assets
                            { asRoot = Just root
                            , asBuildId = mBuildId manifest
                            , asPaths = mAssets manifest
                            , asShell = mShell manifest
                            , asPrecache = mPrecache manifest
                            , asIndexHtml = shellBytes
                            , asServiceWorker = workerBytes
                            , asUrlPaths =
                                Set.fromList
                                    [ url
                                    | url <- Map.elems (mAssets manifest)
                                    , "/assets/" `T.isPrefixOf` url
                                    ]
                            }

-- | The shape rules that need no filesystem access.
validateShape :: Manifest -> Either Text ()
validateShape manifest = do
    unless (validBuildId (mBuildId manifest)) $
        Left ("asset-manifest.json build_id " <> quote (mBuildId manifest) <> " is not a 16-character lowercase hex build id; rerun the bundler")
    unless (not (Map.null (mAssets manifest))) $
        Left "asset-manifest.json has an empty assets map"
    forM_ (Map.toList (mAssets manifest)) $ \(logicalName, urlPath) -> do
        unless (validLogicalName logicalName) $
            Left ("asset-manifest.json has unsafe logical asset name " <> quote logicalName)
        unless (validServedPath urlPath) $
            Left ("asset-manifest.json path " <> quote urlPath <> " for " <> quote logicalName <> " is not a safe /assets/... path (path traversal is rejected)")
    let missing = [key | key <- requiredAssetKeys, not (Map.member key (mAssets manifest))]
    unless (null missing) $
        Left ("asset-manifest.json is missing required assets: " <> T.intercalate ", " missing <> "; rebuild the bundle with scripts/bundle-web.sh")
    forM_ shellRefKeys $ \(shellRef, logicalName) -> do
        shellValue <- maybe (Left ("asset-manifest.json shell map is missing " <> quote shellRef)) Right (Map.lookup shellRef (mShell manifest))
        assetValue <- maybe (Left ("asset-manifest.json assets map is missing " <> quote logicalName)) Right (Map.lookup logicalName (mAssets manifest))
        unless (shellValue == assetValue) $
            Left ("asset-manifest.json shell ref " <> quote shellRef <> " is " <> quote shellValue <> " but the " <> quote logicalName <> " asset is " <> quote assetValue)
    let urls = Map.elems (mAssets manifest)
    unless (length (nub urls) == length urls) $
        Left "asset-manifest.json maps two logical names to the same path"
    unless (not (null (mPrecache manifest))) $
        Left "asset-manifest.json has an empty precache list"

validBuildId :: Text -> Bool
validBuildId value = T.length value == 16 && T.all isHexDigit value

{- | Logical names are slash-separated plain names. No empty, dot, or parent
segments, and no path separators of either kind inside a segment.
-}
validLogicalName :: Text -> Bool
validLogicalName value =
    let segments = T.splitOn "/" value
     in not (T.null value) && all validSegment segments

validSegment :: Text -> Bool
validSegment segment =
    not (T.null segment)
        && segment /= "."
        && segment /= ".."
        && T.all (\c -> c /= '\\' && c /= '\NUL' && c /= '/') segment

{- | A served path is either exactly the fixed web-manifest route or a hashed
@/assets/@ path. The hashed path must contain an eight-hex content-address
token, which is what makes the immutable cache policy safe.
-}
validServedPath :: Text -> Bool
validServedPath value
    | value == "/manifest.webmanifest" = True
    | otherwise = case T.stripPrefix "/assets/" value of
        Nothing -> False
        Just rest ->
            let segments = T.splitOn "/" rest
             in not (T.null rest)
                    && all validSegment segments
                    && any hasHashToken segments

hasHashToken :: Text -> Bool
hasHashToken segment = any isHashPart (T.splitOn "." segment)
  where
    isHashPart part = T.length part == 8 && T.all isHexDigit part

resolveAssetPath :: FilePath -> Text -> IO (Either Text FilePath)
resolveAssetPath root urlPath = case servedRelativePath urlPath of
    Nothing -> pure (Left "path is not a safe static-file path")
    Just relative -> resolveUnderRoot root relative

{- | Map a served path to the static-root relative path. Applied only after
'validServedPath', which already rejected traversal segments.
-}
servedRelativePath :: Text -> Maybe Text
servedRelativePath urlPath = case T.stripPrefix "/assets/" urlPath of
    Just rest -> Just rest
    Nothing -> T.stripPrefix "/" urlPath

loadFixedFile :: FilePath -> FilePath -> IO (Either Text BS.ByteString)
loadFixedFile root name = do
    let path = root </> name
    exists <- doesFileExist path
    if not exists
        then pure (Left (invalidBundleMessage root (T.pack name <> " is missing from the bundle")))
        else do
            result <- try (BS.readFile path) :: IO (Either SomeException BS.ByteString)
            pure $ case result of
                Left err -> Left (invalidBundleMessage root ("could not read " <> T.pack name <> ": " <> T.pack (show err)))
                Right bytes -> Right bytes

checkPrecache :: FilePath -> [Text] -> IO (Either Text ())
checkPrecache root entries = do
    results <- forM entries $ \entry ->
        if entry == "/"
            then pure (Right ())
            else case servedRelativePath entry of
                Nothing -> pure (Left (invalidBundleMessage root ("precache entry " <> quote entry <> " is not a safe path")))
                Just relative -> do
                    resolved <- resolveUnderRoot root relative
                    pure (() <$ resolved)
    pure (sequence_ results)

checkShellHtml :: Map Text Text -> Text -> Either Text ()
checkShellHtml shell html =
    forM_ [key | key <- shellRefKeysList, key /= "auth_js"] $ \key ->
        case Map.lookup key shell of
            Nothing -> Left ("asset-manifest.json shell map is missing " <> quote key)
            Just ref ->
                unless (ref `T.isInfixOf` html) $
                    Left ("generated static/index.html does not reference the manifest path " <> quote ref <> "; rerun scripts/bundle-web.sh")
  where
    shellRefKeysList = map fst shellRefKeys

checkServiceWorker :: Text -> [Text] -> Text -> Either Text ()
checkServiceWorker buildId precache worker = do
    unless (("eza-app-shell-" <> buildId) `T.isInfixOf` worker) $
        Left ("generated static/sw.js does not carry build id " <> quote buildId <> "; rerun scripts/bundle-web.sh")
    forM_ precache $ \entry ->
        unless (entry `T.isInfixOf` worker) $
            Left ("generated static/sw.js does not precache " <> quote entry <> "; rerun scripts/bundle-web.sh")

{- | Resolve a validated relative path inside the static root. Both the root and
the candidate are canonicalized and the candidate must stay under the root, so
a symlinked asset cannot escape the bundle directory.
-}
resolveUnderRoot :: FilePath -> Text -> IO (Either Text FilePath)
resolveUnderRoot root relative = do
    let candidate = root </> T.unpack relative
    rootExists <- doesDirectoryExist root
    if not rootExists
        then pure (Left ("static directory " <> T.pack root <> " does not exist"))
        else do
            rootResult <- try (canonicalizePath root) :: IO (Either SomeException FilePath)
            case rootResult of
                Left err -> pure (Left ("could not resolve the static directory: " <> T.pack (show err)))
                Right canonicalRoot -> do
                    exists <- doesPathExist candidate
                    if not exists
                        then pure (Left ("no file at " <> T.pack candidate))
                        else do
                            resolvedResult <- try (canonicalizePath candidate) :: IO (Either SomeException FilePath)
                            pure $ case resolvedResult of
                                Left err -> Left ("could not resolve " <> T.pack candidate <> ": " <> T.pack (show err))
                                Right resolved
                                    | resolved /= canonicalRoot
                                    , addTrailingPathSeparator canonicalRoot `isPrefixOf` resolved ->
                                        Right resolved
                                    | otherwise -> Left "resolves outside the static directory (path traversal is rejected)"

-- ---------------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------------

{- | Load the bundle a serving process needs. A server without @EZA_STATIC_DIR@
runs in placeholder mode; a server pointed at a directory must have a valid
bundle, and an invalid one is a startup error with the fix in the message.
-}
loadAssetsForStartup :: Maybe FilePath -> IO Assets
loadAssetsForStartup Nothing = pure emptyAssets
loadAssetsForStartup (Just root) = do
    result <- loadAssets root
    case result of
        Right assets -> pure assets
        Left message -> do
            hPutStrLn stderr ("eza: " <> T.unpack message)
            exitFailure

missingManifestMessage :: FilePath -> Text
missingManifestMessage root =
    "EZA_STATIC_DIR="
        <> T.pack root
        <> " has no asset-manifest.json, so the web client cannot be served. "
        <> "Build the bundle with 'bash scripts/build-web.sh' (or rebuild just the bundle over an existing static/app with 'bash scripts/bundle-web.sh --no-build'), "
        <> "or point EZA_STATIC_DIR at the release image's share/eza/static, then restart eza."

invalidBundleMessage :: FilePath -> Text -> Text
invalidBundleMessage root detail =
    "the asset bundle at EZA_STATIC_DIR="
        <> T.pack root
        <> " is invalid: "
        <> detail
        <> ". Rebuild it with 'bash scripts/bundle-web.sh --no-build' (or 'bash scripts/build-web.sh'), or use the release image."
