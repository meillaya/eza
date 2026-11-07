{-# LANGUAGE OverloadedStrings #-}

-- | Warp application: public auth pages/ceremonies, deny-by-default API,
-- CSRF/session guard, and the bookmark/tag JSON surface.
module Eza.Server
  ( runServer
  ) where

import Control.Concurrent.MVar
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple (Connection)
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Handler.Warp
import qualified Web.Cookie as Cookie
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

import Eza.AiTag (aiSuggestions)
import qualified Eza.Auth as Auth
import Eza.Bookmarks
import Eza.Config
import qualified Eza.Db as Db
import Eza.DeadLinks (checkDead)
import Eza.Dedup (dedupCandidates, mergeBookmarks)
import Eza.Export (exportBookmarks)
import Eza.Extract (enrichBookmark, extractBookmark)
import Eza.Graph (graphNeighborhood)
import Eza.Import (defaultImportOptions, importParsed, parseNetscape)
import Eza.Pages (addPasskeyPage, loginPage, recoverPage, setupPage)
import Eza.SavedSearches (createSavedSearch, deleteSavedSearch, listSavedSearches)
import Eza.Snapshot (captureSnapshot)
import Eza.Tags (consolidationCandidates, deleteTag, mergeTags, renameTag)
import Eza.Types
import Eza.Undo (undoLast)
import Network.Wai.Parse (FileInfo (..), defaultParseRequestBodyOptions, lbsBackEnd, parseRequestBodyEx)

runServer :: Config -> Connection -> IO ()
runServer cfg conn = do
  Auth.cleanupExpired conn
  db <- newMVar conn
  let settings =
        setHost (fromString (bindHost (cfgBind cfg)))
          . setPort (bindPort (cfgBind cfg))
          . setServerName "eza"
          . setBeforeMainLoop (hPutStrLn stderr ("eza listening on " <> cfgBind cfg))
          $ defaultSettings
  runSettings settings (securityMiddleware cfg (app cfg db))

-- | Security headers applied to every response (API, HTML, assets).
securityMiddleware :: Config -> Middleware
securityMiddleware cfg app' req respond =
  app' req (respond . mapResponseHeaders (<> headers))
  where
    headers =
      [ ("X-Content-Type-Options", "nosniff")
      , ("Referrer-Policy", "no-referrer")
      , ("X-Frame-Options", "DENY")
      , ("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
      , ( "Content-Security-Policy"
        , "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
        )
      ]
        <> [("Strict-Transport-Security", "max-age=31536000; includeSubDomains") | cfgSecureCookies cfg]

type DbVar = MVar Connection

authConfig :: Config -> Auth.AuthConfig
authConfig cfg = Auth.AuthConfig (cfgPublicOrigin cfg) (cfgRpId cfg) (cfgRpName cfg)

app :: Config -> DbVar -> Application
app cfg db req respond = do
  case (requestMethod req, pathInfo req) of
    -- Public: health + auth pages/ceremonies.
    ("GET", ["healthz"]) -> health db respond
    ("GET", ["login"]) -> withDb db $ \conn -> do
      msess <- sessionFromReq conn req
      case msess of
        Just _ -> respond (redirectTo "/")
        Nothing -> do
          n <- Auth.countCredentials conn
          if n == 0 then respond (redirectTo "/setup") else respond (htmlResponse loginPage)
    ("GET", ["setup"]) -> withDb db $ \conn -> do
      allowed <- Auth.setupAllowed conn
      if allowed then respond (htmlResponse setupPage) else respond (redirectTo "/login")
    ("GET", ["recover"]) -> respond (htmlResponse recoverPage)
    ("POST", ["api", "auth", "options"]) -> withDb db $ \conn -> do
      ensureOrigin cfg req
      r <- Auth.authenticationOptions conn (authConfig cfg)
      either (respond . authErrResponse) (respond . jsonResponse status200) r
    ("POST", ["api", "auth", "verify"]) -> withDb db $ \conn -> do
      ensureOrigin cfg req
      body <- jsonBody req
      case body of
        Left e -> respond (jsonError status400 "bad_request" e)
        Right v -> do
          r <- Auth.verifyLogin conn (authConfig cfg) v
          case r of
            Left e -> respond (authErrResponse e)
            Right sess -> respond (withAuthCookies cfg sess (jsonResponse status200 (object ["redirect" .= ("/" :: Text)])))
    ("POST", ["api", "setup", "options"]) -> withDb db $ \conn -> do
      ensureOrigin cfg req
      r <- Auth.registrationOptions conn (authConfig cfg) True
      either (respond . authErrResponse) (respond . jsonResponse status200) r
    ("POST", ["api", "setup", "verify"]) -> withDb db $ \conn -> do
      ensureOrigin cfg req
      body <- jsonBody req
      case body of
        Left e -> respond (jsonError status400 "bad_request" e)
        Right v -> do
          r <- Auth.verifyRegistration conn (authConfig cfg) True v
          case r of
            Left e -> respond (authErrResponse e)
            Right (Auth.RegistrationOutcome codes msess) ->
              case msess of
                Nothing -> respond (jsonError status400 "bad_request" "no session")
                Just sess ->
                  respond
                    ( withAuthCookies cfg sess
                        (jsonResponse status200 (object ["codes" .= fromMaybe [] codes, "redirect" .= ("/" :: Text)]))
                    )
    ("POST", ["api", "recovery", "redeem"]) -> withDb db $ \conn -> do
      ensureOrigin cfg req
      body <- jsonBody req
      case body of
        Left e -> respond (jsonError status400 "bad_request" e)
        Right v -> case parseMaybeObj v of
          Nothing -> respond (jsonError status400 "bad_request" "invalid body")
          Just o -> case parseMaybe (.: "code") o of
            Nothing -> respond (jsonError status400 "bad_request" "code is required")
            Just code -> do
              r <- Auth.redeemRecoveryCode conn code
              case r of
                Left e -> respond (authErrResponse e)
                Right sess -> respond (withAuthCookies cfg sess (jsonResponse status200 (object ["redirect" .= ("/setup" :: Text)])))
    ("GET", ("assets" : rest)) -> serveAsset cfg rest respond
    ("GET", ["favicon.svg"]) -> serveAsset cfg ["favicon.svg"] respond
    ("GET", ["theme.js"]) -> serveAsset cfg ["theme.js"] respond
    ("GET", []) -> withDb db $ \conn -> do
      msess <- sessionFromReq conn req
      case msess of
        Nothing -> respond (redirectTo "/login")
        Just _ -> respond (indexResponse cfg)
    -- Authenticated API.
    _ -> withAuthed cfg db req respond $ \sess conn -> authedRoute cfg db req respond sess conn

authedRoute :: Config -> DbVar -> Request -> (Response -> IO ResponseReceived) -> Auth.Session -> Connection -> IO ResponseReceived
authedRoute cfg _db req respond _sess conn =
  case (requestMethod req, pathInfo req) of
    ("GET", ["api", "v1", "boot"]) -> do
      page <- listBookmarks conn defaultListQuery
      tags <- allTags conn
      respond (jsonResponse status200 (BootPayload "0.1.0" (cfgPublicOrigin cfg) tags [] page))
    ("GET", ["api", "v1", "bookmarks"]) -> do
      page <- listBookmarks conn (listQueryFrom req)
      respond (jsonResponse status200 page)
    ("POST", ["api", "v1", "bookmarks"]) -> addBookmark conn req respond
    ("GET", ["api", "v1", "bookmarks", idTxt]) -> case readInt idTxt of
      Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
      Just bid -> do
        m <- getBookmark conn bid
        case m of
          Nothing -> respond (jsonError status404 "not_found" "bookmark not found")
          Just b -> respond (jsonResponse status200 b)
    ("DELETE", ["api", "v1", "bookmarks", idTxt]) -> case readInt idTxt of
      Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
      Just bid -> do
        ok <- deleteBookmark conn bid
        if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "bookmark not found")
    ("GET", ["api", "v1", "tags"]) -> do
      tags <- allTags conn
      respond (jsonResponse status200 (object ["tags" .= tags]))
    ("POST", ["api", "v1", "inbox", "mark-all-above"]) -> markAbove conn req respond
    ("PATCH", ["api", "v1", "bookmarks", idTxt]) -> case readInt idTxt of
      Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
      Just bid -> patchBookmark conn bid req respond
    ("POST", ["api", "v1", "bookmarks", idTxt, action]) -> case readInt idTxt of
      Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
      Just bid -> do
        case action of
          "open" -> recordOpen conn bid >> respond (jsonResponse status200 (object ["ok" .= True]))
          "enrich" -> do
            ok <- enrichBookmark conn bid
            respond (jsonResponse status200 (object ["ok" .= ok]))
          "extract" -> do
            ok <- extractBookmark conn bid
            respond (jsonResponse status200 (object ["ok" .= ok]))
          "snapshot" -> do
            m <- captureSnapshot cfg conn bid
            case m of
              Nothing -> respond (jsonError status404 "not_found" "bookmark not found")
              Just (kind, value) ->
                respond (jsonResponse status200 (object ["ok" .= True, "kind" .= kind, "value" .= value]))
          _ -> respond (jsonError status404 "not_found" "No such action")
    ("GET", ["api", "v1", "bookmarks", idTxt, "backlinks"]) -> case readInt idTxt of
      Nothing -> respond (jsonError status400 "bad_request" "invalid bookmark id")
      Just bid -> do
        bl <- getBacklinks conn bid
        respond (jsonResponse status200 bl)
    ("GET", ["api", "v1", "autocomplete"]) -> do
      let q = fromMaybe "" (param "q" req)
      items <- autocomplete conn q 10
      respond (jsonResponse status200 (object ["items" .= items]))
    ("GET", ["api", "v1", "graph"]) -> do
      case (readInt =<< param "seed" req) of
        Nothing -> respond (jsonError status400 "bad_request" "seed is required")
        Just seed -> do
          let depth = fromMaybe 1 (readInt =<< param "depth" req)
          m <- graphNeighborhood conn seed depth
          case m of
            Nothing -> respond (jsonError status404 "not_found" "bookmark not found")
            Just g -> respond (jsonResponse status200 g)
    ("GET", ["api", "v1", "saved-searches"]) -> do
      s <- listSavedSearches conn
      respond (jsonResponse status200 (object ["saved_searches" .= s]))
    ("POST", ["api", "v1", "saved-searches"]) -> do
      body <- jsonBody req
      case body of
        Left e -> respond (jsonError status400 "bad_request" e)
        Right v -> case parseMaybeObj v of
          Nothing -> respond (jsonError status400 "bad_request" "invalid body")
          Just o -> case (parseMaybe (.: "name") o, parseMaybe (.: "q") o, parseMaybe (.: "tags") o) of
            (Just name, q, tags) -> do
              sid <- createSavedSearch conn name (fromMaybe "" q) (fromMaybe [] tags)
              respond (jsonResponse status201 (object ["id" .= sid]))
            _ -> respond (jsonError status400 "bad_request" "name is required")
    ("DELETE", ["api", "v1", "saved-searches", idTxt]) -> case readInt idTxt of
      Nothing -> respond (jsonError status400 "bad_request" "invalid id")
      Just sid -> do
        ok <- deleteSavedSearch conn sid
        if ok then respond (emptyResponse status204) else respond (jsonError status404 "not_found" "saved search not found")
    ("GET", ["api", "v1", "dedup", "candidates"]) -> do
      report <- dedupCandidates conn
      respond (jsonResponse status200 report)
    ("POST", ["api", "v1", "dedup", "merge"]) -> do
      body <- jsonBody req
      case body of
        Left e -> respond (jsonError status400 "bad_request" e)
        Right v -> case parseMaybeObj v of
          Nothing -> respond (jsonError status400 "bad_request" "invalid body")
          Just o -> case (parseMaybe (.: "keep_id") o, parseMaybe (.: "merge_ids") o) of
            (Just keep, Just ms) -> do
              n <- mergeBookmarks conn keep ms
              respond (jsonResponse status200 (object ["merged" .= n]))
            _ -> respond (jsonError status400 "bad_request" "keep_id and merge_ids are required")
    ("GET", ["api", "v1", "tags", "consolidation-candidates"]) -> do
      report <- consolidationCandidates conn
      respond (jsonResponse status200 report)
    ("POST", ["api", "v1", "tags", "apply"]) -> do
      body <- jsonBody req
      case body of
        Left e -> respond (jsonError status400 "bad_request" e)
        Right v -> case parseMaybeObj v of
          Nothing -> respond (jsonError status400 "bad_request" "invalid body")
          Just o -> case (parseMaybe (.: "bookmark_id") o, parseMaybe (.: "tags") o) of
            (Just bid, Just tags) -> do
              n <- addTagsToBookmark conn bid tags
              respond (jsonResponse status200 (object ["updated" .= n]))
            _ -> respond (jsonError status400 "bad_request" "bookmark_id and tags are required")
    ("POST", ["api", "v1", "tags", "merge"]) -> do
      body <- jsonBody req
      case body of
        Left e -> respond (jsonError status400 "bad_request" e)
        Right v -> case parseMaybeObj v of
          Nothing -> respond (jsonError status400 "bad_request" "invalid body")
          Just o -> case (parseMaybe (.: "from") o, parseMaybe (.: "into") o) of
            (Just froms, Just into) -> do
              n <- mergeTags conn froms into
              respond (jsonResponse status200 (object ["updated" .= n]))
            _ -> respond (jsonError status400 "bad_request" "from and into are required")
    ("GET", ["api", "v1", "tags", tag, "suggestions"]) -> do
      r <- aiSuggestions conn tag 20
      case r of
        Left notice ->
          respond
            ( jsonResponse
                status200
                (object ["suggestions" .= ([] :: [Value]), "configured" .= False, "notice" .= notice])
            )
        Right suggestions -> respond (jsonResponse status200 (object ["suggestions" .= suggestions]))
    ("POST", ("api" : "v1" : "tags" : rest)) -> do
      let tagName = T.intercalate "/" rest
      body <- jsonBody req
      case body of
        Left e -> respond (jsonError status400 "bad_request" e)
        Right v -> case parseMaybeObj v of
          Nothing -> respond (jsonError status400 "bad_request" "invalid body")
          Just o -> case parseMaybe (.: "name") o of
            Nothing -> respond (jsonError status400 "bad_request" "name is required")
            Just newName -> do
              ok <- renameTag conn tagName newName
              if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonError status409 "conflict" "tag rename failed")
    ("DELETE", ("api" : "v1" : "tags" : rest)) -> do
      let tagName = T.intercalate "/" rest
      ok <- deleteTag conn tagName
      if ok then respond (emptyResponse status204) else respond (jsonError status409 "conflict" "tag is not empty or does not exist")
    ("POST", ["api", "v1", "maintenance", "check-dead"]) -> do
      body <- jsonBody req
      case body of
        Left e -> respond (jsonError status400 "bad_request" e)
        Right v -> do
          let o = fromMaybe mempty (parseMaybeObj v) :: Object
              limit = fromMaybe 500 (parseMaybe (.: "limit") o :: Maybe Int)
              older = fromMaybe 0 (parseMaybe (.: "older_than") o :: Maybe Int)
              includeDead = fromMaybe False (parseMaybe (.: "include_dead") o :: Maybe Bool)
          (checked, dead, alive) <- checkDead conn limit older includeDead
          respond (jsonResponse status200 (object ["checked" .= checked, "dead" .= dead, "alive" .= alive]))
    ("GET", ["api", "v1", "maintenance", "prune-candidates"]) -> do
      items <- pruneCandidates conn 365
      respond (jsonResponse status200 (object ["items" .= items]))
    ("POST", ["api", "v1", "maintenance", "prune"]) -> do
      body <- jsonBody req
      case body of
        Left e -> respond (jsonError status400 "bad_request" e)
        Right v -> case parseMaybeObj v of
          Nothing -> respond (jsonError status400 "bad_request" "invalid body")
          Just o -> case parseMaybe (.: "ids") o :: Maybe [Int] of
            Nothing -> respond (jsonError status400 "bad_request" "ids is required")
            Just ids -> do
              n <- pruneApply conn ids
              respond (jsonResponse status200 (object ["pruned" .= n, "restored" .= (0 :: Int)]))
    ("POST", ["api", "v1", "undo"]) -> do
      n <- undoLast conn
      respond (jsonResponse status200 (object ["restored" .= n]))
    ("POST", ["api", "v1", "import"]) -> importHandler conn req respond
    ("GET", ["api", "v1", "export"]) -> do
      content <- exportBookmarks conn
      respond
        ( responseLBS
            status200
            [ (hContentType, "text/html; charset=utf-8")
            , (hContentDisposition, "attachment; filename=\"bookmarks.html\"")
            ]
            (LBS.fromStrict (TE.encodeUtf8 content))
        )
    ("GET", ["api", "v1", "export", "notes"]) ->
      respond (jsonError status501 "not_implemented" "Markdown note export is coming in a later milestone")
    ("GET", ["account", "add-passkey"]) -> respond (htmlResponse addPasskeyPage)
    ("GET", ["api", "v1", "account"]) -> do
      creds <- Auth.listCredentials conn
      remaining <- Auth.recoveryCodesRemaining conn
      respond (jsonResponse status200 (object ["credentials" .= creds, "recovery_codes_remaining" .= remaining]))
    ("POST", ["api", "v1", "account", "passkeys", "options"]) -> do
      r <- Auth.addPasskeyOptions conn (authConfig cfg)
      either (respond . authErrResponse) (respond . jsonResponse status200) r
    ("POST", ["api", "v1", "account", "passkeys", "verify"]) -> do
      body <- jsonBody req
      case body of
        Left e -> respond (jsonError status400 "bad_request" e)
        Right v -> do
          r <- Auth.verifyAddPasskey conn (authConfig cfg) v
          case r of
            Left e -> respond (authErrResponse e)
            Right () -> respond (jsonResponse status200 (object ["ok" .= True]))
    ("PATCH", ["api", "v1", "account", "passkeys", cidTxt]) ->
      case Auth.decodeCredentialId cidTxt of
        Nothing -> respond (jsonError status400 "bad_request" "invalid credential id")
        Just cid -> do
          body <- jsonBody req
          case body of
            Left e -> respond (jsonError status400 "bad_request" e)
            Right v -> case parseMaybeObj v of
              Nothing -> respond (jsonError status400 "bad_request" "nickname is required")
              Just o -> case parseMaybe (.: "nickname") o of
                Nothing -> respond (jsonError status400 "bad_request" "nickname is required")
                Just nick -> do
                  ok <- Auth.renameCredential conn cid nick
                  if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonError status404 "not_found" "passkey not found")
    ("DELETE", ["api", "v1", "account", "passkeys", cidTxt]) ->
      case Auth.decodeCredentialId cidTxt of
        Nothing -> respond (jsonError status400 "bad_request" "invalid credential id")
        Just cid -> do
          r <- Auth.deleteCredential conn cid
          either (respond . authErrResponse) (const (respond (emptyResponse status204))) r
    ("POST", ["api", "v1", "account", "recovery", "regenerate"]) -> do
      codes <- Auth.regenerateRecoveryCodes conn
      respond (jsonResponse status200 (object ["codes" .= codes]))
    ("POST", ["api", "auth", "logout"]) -> do
      Auth.deleteSessionHash conn (Auth.sessId _sess)
      respond (clearAuthCookies cfg (emptyResponse status204))
    ("GET", path)
      | not ("api" `elem` path)
      , acceptsHtml req -> respond (indexResponse cfg)
    _ -> respond (jsonError status404 "not_found" "No such route")

-- ---------------------------------------------------------------------------
-- Auth guard
-- ---------------------------------------------------------------------------

withAuthed :: Config -> DbVar -> Request -> (Response -> IO ResponseReceived) -> (Auth.Session -> Connection -> IO ResponseReceived) -> IO ResponseReceived
withAuthed cfg db req respond action = withMVar db $ \conn -> do
  msess <- sessionFromReq conn req
  case msess of
    Nothing -> respond (unauthorized req)
    Just sess -> do
      if not (recoveryScopeAllowed (requestMethod req) (pathInfo req) (Auth.sessScope sess))
        then respond (jsonError status403 "recovery_scope" "this recovery session may only re-enroll a passkey")
        else
          if not (originAllowed cfg req)
            then respond (jsonError status403 "origin" "origin is not allowed")
            else
              if not (csrfOk req sess)
                then respond (jsonError status403 "csrf" "missing or invalid CSRF token")
                else action sess conn

recoveryScopeAllowed :: Method -> [Text] -> Text -> Bool
recoveryScopeAllowed method path scope
  | scope /= "recovery" = True
  | otherwise = case (method, path) of
      ("POST", ["api", "setup", "options"]) -> True
      ("POST", ["api", "setup", "verify"]) -> True
      ("POST", ["api", "auth", "logout"]) -> True
      ("GET", ["api", "v1", "boot"]) -> True
      ("GET", ["api", "v1", "account"]) -> True
      _ -> False

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

ensureOrigin :: Config -> Request -> IO ()
ensureOrigin cfg req = do
  if originAllowed cfg req then pure () else pure ()
  -- Auth ceremony requests are same-origin; a missing Origin is accepted for
  -- non-browser clients, but a present mismatching Origin is rejected in
  -- withAuthed/CSRF paths. This helper is intentionally a no-op placeholder
  -- for the public ceremony endpoints; rate limiting and stricter origin
  -- checks land with the auth hardening pass.

acceptsHtml :: Request -> Bool
acceptsHtml req =
  case lookup hAccept (requestHeaders req) of
    Nothing -> True
    Just raw -> "text/html" `BS.isInfixOf` raw

sessionFromReq :: Connection -> Request -> IO (Maybe Auth.Session)
sessionFromReq conn req =
  case lookup hCookie (requestHeaders req) of
    Nothing -> pure Nothing
    Just rawCookie -> do
      let cookies = Cookie.parseCookies rawCookie
          rawToken = lookup (TE.encodeUtf8 Auth.sessionCookieName) cookies
      case rawToken of
        Nothing -> pure Nothing
        Just token -> Auth.getSession conn (TE.decodeUtf8 token)

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
    sessionCookie =
      ( hSetCookie
      , BSC.pack
          ( T.unpack
              ( Auth.sessionCookieName
                  <> "=" <> Auth.nsToken sess
                  <> "; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000" <> securePart
              )
          )
      )
    csrfCookie =
      ( hSetCookie
      , BSC.pack
          ( T.unpack
              ( Auth.csrfCookieName
                  <> "=" <> Auth.nsCsrf sess
                  <> "; Path=/; SameSite=Lax; Max-Age=2592000" <> securePart
              )
          )
      )

clearAuthCookies :: Config -> Response -> Response
clearAuthCookies cfg =
  mapResponseHeaders
    ( \hs ->
        hs
          <> [ (hSetCookie, BSC.pack (T.unpack (Auth.sessionCookieName <> "=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0" <> securePart)))
             , (hSetCookie, BSC.pack (T.unpack (Auth.csrfCookieName <> "=; Path=/; SameSite=Lax; Max-Age=0" <> securePart)))
             ]
    )
  where
    securePart = if cfgSecureCookies cfg then "; Secure" else ""

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

health :: DbVar -> (Response -> IO ResponseReceived) -> IO ResponseReceived
health db respond = do
  ok <- withMVar db Db.ping
  if ok
    then respond (jsonResponse status200 (object ["status" .= ("ok" :: Text), "version" .= ("0.1.0" :: Text)]))
    else respond (jsonError status503 "unavailable" "database is unavailable")

data AddBody = AddBody
  { abUrl :: Text
  , abTitle :: Maybe Text
  , abTags :: Maybe [Text]
  }

instance FromJSON AddBody where
  parseJSON = withObject "AddBody" $ \o ->
    AddBody <$> o .: "url" <*> o .:? "title" <*> o .:? "tags"

addBookmark :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
addBookmark conn req respond = do
  body <- strictRequestBody req
  case eitherDecode body of
    Left err -> respond (jsonError status400 "bad_request" (T.pack err))
    Right (AddBody url title tags) ->
      if not (isHttpUrl url)
        then respond (jsonError status400 "bad_request" "url must be http(s)")
        else do
          result <- insertBookmark conn url (fromMaybe "" title) (fromMaybe [] tags)
          case result of
            Left msg -> respond (jsonError status409 "conflict" msg)
            Right bid -> respond (jsonResponse status201 (object ["id" .= bid]))

data MarkAboveBody = MarkAboveBody {mabAboveId :: Maybe Int}

instance FromJSON MarkAboveBody where
  parseJSON = withObject "MarkAboveBody" $ \o -> MarkAboveBody <$> o .:? "above_id"

markAbove :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
markAbove conn req respond = do
  body <- strictRequestBody req
  case eitherDecode body of
    Left err -> respond (jsonError status400 "bad_request" (T.pack err))
    Right (MarkAboveBody aid) -> do
      n <- markAllAbove conn aid
      respond (jsonResponse status200 (object ["updated" .= n]))

data PatchBody = PatchBody
  { pbTitle :: Maybe Text
  , pbNote :: Maybe Text
  , pbRead :: Maybe Bool
  , pbTags :: Maybe [Text]
  }

instance FromJSON PatchBody where
  parseJSON = withObject "PatchBody" $ \o ->
    PatchBody <$> o .:? "title" <*> o .:? "note_body" <*> o .:? "is_read" <*> o .:? "tags"

patchBookmark :: Connection -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
patchBookmark conn bid req respond = do
  body <- strictRequestBody req
  case eitherDecode body of
    Left err -> respond (jsonError status400 "bad_request" (T.pack err))
    Right (PatchBody mTitle mNote mRead mTags)
      | maybe False (T.null . T.strip) mTitle -> respond (jsonError status400 "bad_request" "title must not be empty")
      | all (== Nothing) [fmap (const ()) mTitle, fmap (const ()) mNote, fmap (const ()) mRead, fmap (const ()) mTags] ->
          respond (jsonError status400 "bad_request" "empty patch")
      | otherwise -> do
          ok <- updateBookmark conn bid mTitle mNote mRead mTags
          if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonError status404 "not_found" "bookmark not found")

importHandler :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
importHandler conn req respond = do
  (_, files) <- parseRequestBodyEx defaultParseRequestBodyOptions lbsBackEnd req
  case lookup "file" files of
    Nothing -> respond (jsonError status400 "bad_request" "multipart field \"file\" is required")
    Just fileInfo -> do
      let raw = LBS.toStrict (fileContent fileInfo)
          parsed = parseNetscape defaultImportOptions raw
      report <- importParsed conn defaultImportOptions parsed
      respond (jsonResponse status200 report)

jsonBody :: Request -> IO (Either Text Value)
jsonBody req = do
  body <- strictRequestBody req
  pure (case eitherDecode body :: Either String Value of Left e -> Left (T.pack e); Right v -> Right v)

parseMaybeObj :: Value -> Maybe Object
parseMaybeObj (Object o) = Just o
parseMaybeObj _ = Nothing

resultToMaybe :: Result a -> Maybe a
resultToMaybe (Success a) = Just a
resultToMaybe (Error _) = Nothing

authErrResponse :: Auth.AuthError -> Response
authErrResponse e = jsonError (mkStatus (Auth.aeStatus e) "") (Auth.aeCode e) (Auth.aeMessage e)

-- ---------------------------------------------------------------------------
-- Query parsing
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

serveAsset :: Config -> [Text] -> (Response -> IO ResponseReceived) -> IO ResponseReceived
serveAsset cfg rest respond = case cfgStaticDir cfg of
  Nothing -> respond (jsonError status404 "not_found" "static assets are not configured")
  Just root -> do
    if any (== "..") rest
      then respond (jsonError status400 "bad_request" "invalid asset path")
      else do
        let rel = foldr (</>) "" (map T.unpack rest)
            path = root </> rel
        exists <- doesFileExist path
        if exists
          then respond (responseFile status200 [(hContentType, mimeFor rel)] path Nothing)
          else respond (jsonError status404 "not_found" "asset not found")

indexResponse :: Config -> Response
indexResponse cfg = case cfgStaticDir cfg of
  Just root -> responseFile status200 [(hContentType, "text/html; charset=utf-8")] (root </> "index.html") Nothing
  Nothing -> htmlResponse (placeholderPage cfg)

mimeFor :: FilePath -> BS.ByteString
mimeFor p
  | ".css" `endOf` p = BSC.pack "text/css; charset=utf-8"
  | ".js" `endOf` p = BSC.pack "text/javascript; charset=utf-8"
  | ".mjs" `endOf` p = BSC.pack "text/javascript; charset=utf-8"
  | ".wasm" `endOf` p = BSC.pack "application/wasm"
  | ".html" `endOf` p = BSC.pack "text/html; charset=utf-8"
  | ".svg" `endOf` p = BSC.pack "image/svg+xml"
  | ".json" `endOf` p = BSC.pack "application/json"
  | otherwise = BSC.pack "application/octet-stream"
  where
    endOf suffix s =
      let n = length suffix
       in length s >= n && drop (length s - n) s == suffix

-- ---------------------------------------------------------------------------
-- Responses
-- ---------------------------------------------------------------------------

jsonResponse :: ToJSON a => Status -> a -> Response
jsonResponse status value =
  responseLBS status [(hContentType, "application/json; charset=utf-8")] (encode value)

jsonError :: Status -> Text -> Text -> Response
jsonError status code message =
  jsonResponse status (object ["error" .= object ["code" .= code, "message" .= message]])

emptyResponse :: Status -> Response
emptyResponse status = responseLBS status [(hContentType, "application/json; charset=utf-8")] "{}"

htmlResponse :: Text -> Response
htmlResponse body =
  responseLBS status200 [(hContentType, "text/html; charset=utf-8")] (LBS.fromStrict (TE.encodeUtf8 body))

placeholderPage :: Config -> Text
placeholderPage cfg =
  T.unlines
    [ "<!doctype html>"
    , "<html lang=\"en\"><head><meta charset=\"utf-8\"><title>eza</title>"
    , "<style>body{font:15px system-ui;background:#f7f7f5;color:#171717;margin:0;display:grid;place-items:center;min-height:100vh}main{max-width:540px;padding:32px;border:1px solid #e6e6e1;border-radius:20px;background:#fff}h1{margin:0 0 8px;font-size:28px}code{background:#f1f1ee;padding:2px 6px;border-radius:6px}</style>"
    , "</head><body><main><h1>eza</h1><p>The Haskell server is running.</p><p>Static dir: <code>"
    , T.pack (maybe "(unset)" id (cfgStaticDir cfg))
    , "</code></p><p>Origin: <code>"
    , cfgPublicOrigin cfg
    , "</code></p></main></body></html>"
    ]

withDb :: DbVar -> (Connection -> IO ResponseReceived) -> IO ResponseReceived
withDb db action = withMVar db action

