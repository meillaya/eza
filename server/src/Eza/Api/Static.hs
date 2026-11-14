-- | Static asset serving: hashed assets, the shell, named assets, and the service worker.
module Eza.Api.Static where

import Control.Exception (SomeException, try)

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as LBS
import Data.Char (toLower)

import Data.List (isPrefixOf)

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)

import Network.HTTP.Types
import Network.Wai

import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, getFileSize, getModificationTime)

import System.FilePath (addTrailingPathSeparator, (</>))

import Eza.Assets (Assets, assetRelativePath, assetsAvailable, assetsBuildId, assetsServiceWorker, isImmutableAsset)

import Eza.Config

import Eza.Shell (shellPage)

import Eza.Api.Common
import Eza.Api.Context

{- | A static file with an ETag and a cache policy. Hashed asset URLs are
served immutable because the name is the content address; unhashed files and
the web manifest keep the revalidating no-cache policy. @no-store@ is reserved
for the client shell.
-}
sendFile :: Request -> BS.ByteString -> [(HeaderName, BS.ByteString)] -> FilePath -> (Response -> IO ResponseReceived) -> IO ResponseReceived
sendFile req cachePolicy headers path respond = do
    sourceModified <- getModificationTime path
    gzipExists <- doesFileExist (path <> ".gz")
    gzipModified <- if gzipExists then Just <$> getModificationTime (path <> ".gz") else pure Nothing
    let
        -- A sidecar older than the source would serve stale bytes (the usual
        -- case while editing an asset without running the web build). Treat it
        -- as absent instead of trusting the extension.
        gzipFresh = case gzipModified of
            Just modified -> modified >= sourceModified
            Nothing -> False
        useGzip = gzipFresh && acceptsGzip req
        servedPath = if useGzip then path <> ".gz" else path
        compressionHeaders =
            [ (hVary, "Accept-Encoding")
            | gzipFresh
            ]
                <> [ (hContentEncoding, "gzip")
                   | useGzip
                   ]
    size <- getFileSize servedPath
    modified <- getModificationTime servedPath
    let tag = BSC.pack ("\"" <> show size <> "-" <> show (round (utcTimeToPOSIXSeconds modified) :: Integer) <> "\"")
        cacheable = cachePolicy /= "no-store"
        fresh = cacheable && lookup hIfNoneMatch (requestHeaders req) == Just tag
        allHeaders = headers <> compressionHeaders <> [(hCacheControl, cachePolicy)] <> [(hETag, tag) | cacheable]
    if fresh
        then respond (responseLBS status304 allHeaders "")
        else respond (responseFile status200 allHeaders servedPath Nothing)

{- | The one-year immutable policy for content-addressed asset names. Safe
because any change to the bytes changes the name the bundler emits.
-}
immutableCache :: BS.ByteString
immutableCache = "public, max-age=31536000, immutable"

{- | Whether the request's @Accept-Encoding@ allows gzip. Header values are
tokens; browsers send lowercase, so a lowercase-insensitive containment
check is enough here.
-}
acceptsGzip :: Request -> Bool
acceptsGzip req =
    case lookup hAcceptEncoding (requestHeaders req) of
        Nothing -> False
        Just value -> BSC.isInfixOf "gzip" (BSC.map toLower value)

serveStaticFile :: Config -> FilePath -> [(HeaderName, BS.ByteString)] -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
serveStaticFile cfg relative headers req respond = case cfgStaticDir cfg of
    Nothing -> respond (jsonProblem status404 "not_found" "static assets are not configured")
    Just root -> do
        let path = root </> relative
        exists <- doesFileExist path
        if exists
            then sendFile req "no-cache" headers path respond
            else respond (jsonProblem status404 "not_found" "asset not found")

{- | Resolve one decoded asset path against the static root. Returns the
canonical file path only when every segment is a plain name and the canonical
candidate stays inside the canonical root.

WAI splits the raw path on @/@ and percent-decodes each segment afterwards, so
@..%2f..%2fetc%2fpasswd@ arrives as a single segment whose text contains
slashes. Comparing a decoded segment with @".."@ alone is therefore not enough:
any segment containing a path separator (or @.@/@..@, empty, or NUL) is
rejected, and the surviving candidate is canonicalized and prefix-checked like
the snapshot route does. This is also what stops @%2e%2e%2f@ and a backslash
form.
-}
resolveStaticPath :: FilePath -> [Text] -> IO (Maybe FilePath)
resolveStaticPath root rest
    | invalidStaticSegments rest = pure Nothing
    | otherwise = do
        rootExists <- doesDirectoryExist root
        if not rootExists
            then pure Nothing
            else do
                rootResult <- try (canonicalizePath root) :: IO (Either SomeException FilePath)
                case rootResult of
                    Left (_ :: SomeException) -> pure Nothing
                    Right canonicalRoot -> do
                        let rel = foldr ((</>) . T.unpack) "" rest
                            candidate = canonicalRoot </> rel
                        exists <- doesFileExist candidate
                        if not exists
                            then pure Nothing
                            else do
                                resolvedResult <- try (canonicalizePath candidate) :: IO (Either SomeException FilePath)
                                pure $ case resolvedResult of
                                    Left (_ :: SomeException) -> Nothing
                                    Right resolved
                                        | resolved /= canonicalRoot
                                        , isUnder resolved canonicalRoot ->
                                            Just resolved
                                        | otherwise -> Nothing
  where
    isUnder path canonicalRoot =
        path == canonicalRoot
            || addTrailingPathSeparator canonicalRoot `isPrefixOf` path

{- | A decoded path segment is only a plain file name: no empty segment, no
@.@/@..@, no separators of either kind, and no NUL. The encoded-slash
traversal arrives here as one segment containing @/@, so it is rejected before
any filesystem call.
-}
invalidStaticSegments :: [Text] -> Bool
invalidStaticSegments = any unsafeStaticSegment
  where
    unsafeStaticSegment segment =
        T.null segment
            || segment == "."
            || segment == ".."
            || T.any (== '/') segment
            || T.any (== '\\') segment
            || T.any (== '\NUL') segment

{- | Serve one @/assets/*@ file. The path is resolved with the same
traversal-safe resolver as before; a path the manifest lists as a hashed asset
is served immutable (the filename is its content address), anything else keeps
the revalidating no-cache policy.
-}
serveAsset :: Config -> Assets -> [Text] -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
serveAsset cfg assets rest req respond = case cfgStaticDir cfg of
    Nothing -> respond (jsonProblem status404 "not_found" "static assets are not configured")
    Just root -> do
        if invalidStaticSegments rest
            then respond (jsonProblem status400 "bad_request" "invalid asset path")
            else do
                resolved <- resolveStaticPath root rest
                case resolved of
                    Nothing -> respond (jsonProblem status404 "not_found" "asset not found")
                    Just path -> do
                        let rel = foldr ((</>) . T.unpack) "" rest
                            urlPath = "/assets/" <> T.intercalate "/" rest
                            cachePolicy = if isImmutableAsset assets urlPath then immutableCache else "no-cache"
                        sendFile req cachePolicy [(hContentType, mimeFor rel)] path respond

{- | Serve one of the two stable asset URLs (/favicon.svg, /theme.js) from the
manifest's hashed copy. Keeping the stable routes means an old link or an
already-installed PWA icon still resolves while the payload is addressed.
-}
serveNamedAsset :: Config -> Assets -> Text -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
serveNamedAsset cfg assets name req respond = case cfgStaticDir cfg of
    Nothing -> respond (jsonProblem status404 "not_found" "static assets are not configured")
    Just root -> case assetRelativePath assets name of
        Nothing -> respond (jsonProblem status404 "not_found" "asset not found")
        Just relative -> do
            let segments = T.splitOn "/" relative
            if invalidStaticSegments segments
                then respond (jsonProblem status400 "bad_request" "invalid asset path")
                else do
                    resolved <- resolveStaticPath root segments
                    case resolved of
                        Nothing -> respond (jsonProblem status404 "not_found" "asset not found")
                        Just path -> sendFile req immutableCache [(hContentType, mimeFor (T.unpack relative))] path respond

{- | The shell HTML is generated by the bundler from its tracked template and
cached in 'Assets' at startup. It is never stored: a rebuild must reach the
next navigation. A server without a bundle keeps the placeholder page.
-}
indexResponse :: AppState -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
indexResponse state _req respond
    | assetsAvailable assets = respond (shellPage assets)
    | otherwise = respond (htmlResponse (placeholderPage (asConfig state)))
  where
    assets = asAssets state

{- | The service worker is generated by the bundler with the build id embedded
and is served from the validated copy, not re-generated per request. The ETag
is the build id, so a rebuild replaces the worker even though the URL is a
fixed /sw.js, and no-cache makes every navigation revalidate it.
-}
serveServiceWorker :: Assets -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
serveServiceWorker assets req respond
    | not (assetsAvailable assets) =
        respond (jsonProblem status404 "not_found" "static assets are not configured")
    | otherwise =
        let buildId = assetsBuildId assets
            tag = BSC.pack ("\"" <> T.unpack buildId <> "\"")
            headers =
                [ (hContentType, "text/javascript; charset=utf-8")
                , ("Service-Worker-Allowed", "/")
                , (hCacheControl, "no-cache")
                , (hETag, tag)
                ]
                    <> [("X-Eza-Build", TE.encodeUtf8 buildId) | not (T.null buildId)]
            body = LBS.fromStrict (assetsServiceWorker assets)
         in if lookup hIfNoneMatch (requestHeaders req) == Just tag
                then respond (responseLBS status304 headers "")
                else respond (responseLBS status200 headers body)

mimeFor :: FilePath -> BS.ByteString
mimeFor p
    | ".css" `endOf` p = BSC.pack "text/css; charset=utf-8"
    | ".js" `endOf` p = BSC.pack "text/javascript; charset=utf-8"
    | ".mjs" `endOf` p = BSC.pack "text/javascript; charset=utf-8"
    | ".wasm" `endOf` p = BSC.pack "application/wasm"
    | ".html" `endOf` p = BSC.pack "text/html; charset=utf-8"
    | ".svg" `endOf` p = BSC.pack "image/svg+xml"
    | ".json" `endOf` p = BSC.pack "application/json"
    | ".png" `endOf` p = BSC.pack "image/png"
    | ".woff2" `endOf` p = BSC.pack "font/woff2"
    | ".webmanifest" `endOf` p = BSC.pack "application/manifest+json"
    | otherwise = BSC.pack "application/octet-stream"
  where
    endOf suffix s =
        let n = length suffix
         in length s >= n && drop (length s - n) s == suffix

-- ---------------------------------------------------------------------------
-- Responses
-- ---------------------------------------------------------------------------
