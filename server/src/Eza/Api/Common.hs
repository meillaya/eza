-- | Shared HTTP helpers: response constructors, JSON bodies, query parameters, cookies.
module Eza.Api.Common where

import Data.Aeson

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as LBS

import Data.Maybe (catMaybes, fromMaybe, isNothing, mapMaybe)

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Data.Word (Word64)

import Network.HTTP.Types
import Network.Wai

import qualified Web.Cookie as Cookie

import qualified Eza.Auth as Auth

import Eza.Bookmarks

import Eza.Config

import Eza.Dedup (DedupQuery (..), dedupCandidates, mergeBookmarksWithSnapshot, mergeUrlDuplicatesAll)

requestTooLargeResponse :: Word64 -> Response
requestTooLargeResponse limit =
    jsonError
        status413
        "payload_too_large"
        ("request body must be at most " <> T.pack (show limit) <> " bytes")

readBodyLimited :: Int -> Request -> IO (Either () LBS.ByteString)
readBodyLimited limit req = go [] 0
  where
    go chunks total = do
        chunk <- getRequestBodyChunk req
        if BS.null chunk
            then pure (Right (LBS.fromChunks (reverse chunks)))
            else
                let total' = total + BS.length chunk
                 in if total' > limit then pure (Left ()) else go (chunk : chunks) total'

csrfOk :: Request -> Auth.Session -> Bool
csrfOk req sess
    | requestMethod req `notElem` ["POST", "PUT", "PATCH", "DELETE"] = True
    | otherwise =
        case lookup "X-CSRF-Token" (requestHeaders req) of
            Nothing -> False
            Just raw -> Auth.hashToken (TE.decodeUtf8 raw) == Auth.sessCsrf sess

originAllowed :: Config -> Request -> Bool
originAllowed cfg req =
    case lookup "Origin" (requestHeaders req) of
        Nothing -> True
        Just raw -> TE.decodeUtf8 raw `elem` cfgAllowedOrigins cfg

cookieValue :: Request -> Text -> Maybe Text
cookieValue req name =
    case lookup hCookie (requestHeaders req) of
        Nothing -> Nothing
        Just rawCookie -> do
            rawValue <- lookup (TE.encodeUtf8 name) (Cookie.parseCookies rawCookie)
            pure (TE.decodeUtf8 rawValue)

unauthorized :: Request -> Response
unauthorized req
    | "api" `elem` pathInfo req = jsonError status401 "unauthenticated" "sign in required"
    | otherwise = redirectTo "/login"

redirectTo :: Text -> Response
redirectTo target =
    responseLBS status302 [(hLocation, TE.encodeUtf8 target)] ""

-- ---------------------------------------------------------------------------
-- Cookies
-- ---------------------------------------------------------------------------

withAuthCookies :: Config -> Auth.NewSession -> Response -> Response
withAuthCookies cfg sess =
    mapResponseHeaders (\hs -> hs <> [sessionCookie, csrfCookie])
  where
    securePart = if cfgSecureCookies cfg then "; Secure" else ""
    maxAge = T.pack (show (Auth.nsTtlSeconds sess))
    sessionCookie =
        ( hSetCookie
        , BSC.pack
            ( T.unpack
                ( Auth.sessionCookieName
                    <> "="
                    <> Auth.nsToken sess
                    <> "; Path=/; HttpOnly; SameSite=Lax; Max-Age="
                    <> maxAge
                    <> securePart
                )
            )
        )
    csrfCookie =
        ( hSetCookie
        , BSC.pack
            ( T.unpack
                ( Auth.csrfCookieName
                    <> "="
                    <> Auth.nsCsrf sess
                    <> "; Path=/; SameSite=Lax; Max-Age="
                    <> maxAge
                    <> securePart
                )
            )
        )

{- | The short-lived cookie of a two-factor sign-in. It is HttpOnly, carries no
CSRF token, and can only finish the passkey step; it never opens a route on its
own.
-}
withPendingCookie :: Config -> Auth.NewSession -> Response -> Response
withPendingCookie cfg sess =
    mapResponseHeaders (\hs -> hs <> [pendingCookie (Auth.nsToken sess) (Auth.nsTtlSeconds sess)])
  where
    pendingCookie token ttl =
        ( hSetCookie
        , BSC.pack
            ( T.unpack
                ( Auth.pendingCookieName
                    <> "="
                    <> token
                    <> "; Path=/; HttpOnly; SameSite=Lax; Max-Age="
                    <> T.pack (show ttl)
                    <> securePart
                )
            )
        )
    securePart = if cfgSecureCookies cfg then "; Secure" else ""

clearPendingCookie :: Config -> Response -> Response
clearPendingCookie cfg =
    mapResponseHeaders
        ( \hs ->
            hs
                <> [(hSetCookie, BSC.pack (T.unpack (Auth.pendingCookieName <> "=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" <> securePart)))]
        )
  where
    securePart = if cfgSecureCookies cfg then "; Secure" else ""

clearAuthCookies :: Config -> Response -> Response
clearAuthCookies cfg =
    mapResponseHeaders
        ( \hs ->
            hs
                <> [ (hSetCookie, BSC.pack (T.unpack (Auth.sessionCookieName <> "=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" <> securePart)))
                   , (hSetCookie, BSC.pack (T.unpack (Auth.csrfCookieName <> "=; Path=/; SameSite=Lax; Max-Age=0" <> securePart)))
                   , (hSetCookie, BSC.pack (T.unpack (Auth.pendingCookieName <> "=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" <> securePart)))
                   ]
        )
  where
    securePart = if cfgSecureCookies cfg then "; Secure" else ""

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

{- | The same bounded reader with an explicit cap. The import routes use
'EZA_IMPORT_MAX_BYTES' so a declared-length body inside the import cap is not
rejected by the general 8 MiB limit while the multipart parser and the
size-limit middleware both allow the import cap. The 413 names that limit.
-}
readBodyBoundedTo :: Int -> Request -> IO (Either Response LBS.ByteString)
readBodyBoundedTo limit req = do
    body <- readBodyLimited limit req
    pure $ case body of
        Left () -> Left (requestTooLargeResponse (fromIntegral limit))
        Right raw -> Right raw

{- | Decode a bounded JSON body. A body over the cap is a ready-made 413; a
parse failure keeps the existing generic 400 shape.
-}
jsonBody :: Config -> Request -> IO (Either Response Value)
jsonBody cfg = jsonBodyTo (cfgMaxBodyBytes cfg)

-- | Decode a JSON body under an explicit cap, for the import routes.
jsonBodyTo :: Int -> Request -> IO (Either Response Value)
jsonBodyTo limit req = do
    body <- readBodyBoundedTo limit req
    pure $ case body of
        Left response -> Left response
        Right raw -> case eitherDecode raw of
            Left err -> Left (jsonError status400 "bad_request" (T.pack err))
            Right value -> Right value

-- | Decode a bounded JSON body as one typed value.
jsonValue :: (FromJSON a) => Config -> Request -> IO (Either Response a)
jsonValue cfg req = do
    body <- jsonBody cfg req
    pure $ case body of
        Left response -> Left response
        Right value -> case fromJSON value of
            Error err -> Left (jsonError status400 "bad_request" (T.pack err))
            Success parsed -> Right parsed

parseMaybeObj :: Value -> Maybe Object
parseMaybeObj (Object o) = Just o
parseMaybeObj _ = Nothing

authErrResponse :: Auth.AuthError -> Response
authErrResponse e =
    let base = jsonError (mkStatus (Auth.aeStatus e) "") (Auth.aeCode e) (Auth.aeMessage e)
     in case Auth.aeRetryAfter e of
            Nothing -> base
            Just seconds -> mapResponseHeaders (<> [("Retry-After", BSC.pack (show seconds))]) base

-- ---------------------------------------------------------------------------
-- Admin API
-- ---------------------------------------------------------------------------

listQueryFrom :: Request -> ListQuery
listQueryFrom req =
    let q = fromMaybe "" (param "q" req)
        tags = concatMap splitTags (allParams "tags" req)
        isRead = parseBool =<< param "is_read" req
        isDead = parseBool =<< param "is_dead" req
        sort = fromMaybe "created" (param "sort" req)
        offset = max 0 (fromMaybe 0 (readInt =<< param "offset" req))
        limit = min 200 (max 1 (fromMaybe 60 (readInt =<< param "limit" req)))
     in ListQuery q tags isRead isDead sort offset limit
  where
    splitTags = filter (not . T.null) . map (T.toLower . T.strip) . T.splitOn ","

dedupQueryFrom :: Request -> DedupQuery
dedupQueryFrom req =
    DedupQuery
        { dqUrlOffset = max 0 (fromMaybe 0 (readInt =<< param "url_offset" req))
        , dqUrlLimit = min 200 (max 1 (fromMaybe 60 (readInt =<< param "url_limit" req)))
        , dqTitleOffset = max 0 (fromMaybe 0 (readInt =<< param "title_offset" req))
        , dqTitleLimit = min 200 (max 1 (fromMaybe 40 (readInt =<< param "title_limit" req)))
        }

param :: BS.ByteString -> Request -> Maybe Text
param key req =
    case [v | (k, Just v) <- queryString req, k == key] of
        (v : _) -> Just (TE.decodeUtf8 v)
        [] -> Nothing

allParams :: BS.ByteString -> Request -> [Text]
allParams key req = [TE.decodeUtf8 v | (k, Just v) <- queryString req, k == key]

parseBool :: Text -> Maybe Bool
parseBool t = case T.toLower t of
    "1" -> Just True
    "true" -> Just True
    "0" -> Just False
    "false" -> Just False
    _ -> Nothing

readInt :: Text -> Maybe Int
readInt t = case reads (T.unpack t) of
    [(n, "")] -> Just n
    _ -> Nothing

isHttpUrl :: Text -> Bool
isHttpUrl t =
    let l = T.toLower (T.strip t)
     in "http://" `T.isPrefixOf` l || "https://" `T.isPrefixOf` l

-- ---------------------------------------------------------------------------
-- Static
-- ---------------------------------------------------------------------------

jsonResponse :: (ToJSON a) => Status -> a -> Response
jsonResponse status value =
    responseLBS status [(hContentType, "application/json; charset=utf-8"), (hCacheControl, "no-store")] (encode value)

jsonError :: Status -> Text -> Text -> Response
jsonError status code message =
    jsonResponse status (object ["error" .= object ["code" .= code, "message" .= message]])

emptyResponse :: Status -> Response
emptyResponse status = responseLBS status [(hContentType, "application/json; charset=utf-8"), (hCacheControl, "no-store")] "{}"

htmlResponse :: Text -> Response
htmlResponse = htmlResponseAt status200

htmlResponseAt :: Status -> Text -> Response
htmlResponseAt status body =
    responseLBS status [(hContentType, "text/html; charset=utf-8"), (hCacheControl, "no-store")] (LBS.fromStrict (TE.encodeUtf8 body))

{- | The page a server with no static directory serves. It is not the app;
it says what is missing and follows the catalogue paper stock.
-}
placeholderPage :: Config -> Text
placeholderPage cfg =
    T.unlines
        [ "<!doctype html>"
        , "<html lang=\"en\"><head><meta charset=\"utf-8\">"
        , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        , "<meta name=\"color-scheme\" content=\"light dark\">"
        , "<title>eza | bare server</title>"
        , "<style>"
        , ":root{--paper:#F2EDE3;--card:#FBF8F1;--ink:#1A2340;--muted:#6E675C;--rule:#D5CBB8;--accent:#8A2B20}"
        , "@media (prefers-color-scheme: dark){:root{--paper:#10141F;--card:#161B28;--ink:#E9E3D6;--muted:#A9A08F;--rule:#232A3A;--accent:#C98A3E}}"
        , "body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:48px 36px;background:var(--paper);color:var(--ink);font-family:'Newsreader',Georgia,'Times New Roman',serif;font-size:17px;line-height:28px}"
        , "main{width:min(560px,100%);background:var(--card);border:1px solid var(--ink);border-radius:2px;padding:32px 34px 28px}"
        , ".kicker{margin:0 0 10px;font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:11px;line-height:16px;letter-spacing:.14em;text-transform:uppercase;color:var(--accent)}"
        , ".wordmark{margin:0;font-family:'Fraunces',Georgia,'Times New Roman',serif;font-size:36px;line-height:38px;font-weight:600;letter-spacing:-.02em}"
        , ".rule{height:1px;background:var(--ink);margin:14px 0 26px}"
        , "p{margin:0 0 14px}"
        , "dl{margin:20px 0 0;border-top:1px solid var(--rule)}"
        , "dl div{display:flex;justify-content:space-between;gap:20px;padding:7px 0;border-bottom:1px solid var(--rule)}"
        , "dt{font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:11px;line-height:16px;letter-spacing:.12em;text-transform:uppercase;color:var(--muted)}"
        , "dd{margin:0;font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;line-height:18px;color:var(--ink);overflow-wrap:anywhere}"
        , ".foot{margin:18px 0 0;font-family:'IBM Plex Mono',ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:11px;line-height:16px;letter-spacing:.12em;text-transform:uppercase;color:var(--muted)}"
        , "</style>"
        , "</head><body><main>"
        , "<p class=\"kicker\">the catalogue</p>"
        , "<p class=\"wordmark\">eza</p>"
        , "<div class=\"rule\" aria-hidden=\"true\"></div>"
        , "<p>The server is running. The client bundle is not on disk, so there is nothing to load yet.</p>"
        , "<p>Point <code>EZA_STATIC_DIR</code> at the built <code>static</code> directory and reload this page.</p>"
        , "<dl><div><dt>static dir</dt><dd>" <> escapeHtml (T.pack (fromMaybe "(unset)" (cfgStaticDir cfg))) <> "</dd></div>"
        , "<div><dt>origin</dt><dd>" <> escapeHtml (cfgPublicOrigin cfg) <> "</dd></div></dl>"
        , "<p class=\"foot\">server only <span aria-hidden=\"true\">/</span> built assets required</p>"
        , "</main></body></html>"
        ]

escapeHtml :: Text -> Text
escapeHtml value =
    T.replace "\"" "&quot;" (T.replace ">" "&gt;" (T.replace "<" "&lt;" (T.replace "&" "&amp;" value)))
