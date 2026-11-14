-- | The browser clipper, clip templates, webhooks, and rules.
module Eza.Api.Extensions where

import Data.Aeson

import Data.Maybe (fromMaybe)

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Database.SQLite.Simple (Connection)

import Network.HTTP.Types
import Network.Wai

import qualified Eza.Auth as Auth

import Eza.Clip (ClipError, ClipRequest (..), ClipTemplate (..), SaveClipResult (..), TemplateError, createTemplate, deleteTemplate, getTemplate, previewClip, saveClip, templatesPayload, updateTemplate)
import qualified Eza.Clip as Clip
import qualified Eza.ClipTemplates as Templates
import Eza.Config

import Eza.Enrich (enqueueEnrichment)

import Eza.Routes (Route (..))

import Eza.Rules (Rule (..), createRule, deleteRule, listRules, matchingBookmarks, updateRule)

import Eza.Tokens (Token (..))

import Eza.Jobs (enqueueTrackedJob)
import Eza.Views (ViewError, deleteView, getView, listViews)
import qualified Eza.Views as Views
import Eza.Webhook (WebhookInput (..))
import Eza.Webhooks (WebhookError, createWebhook, deleteWebhook, getWebhook, listDeliveries, listWebhooks, updateWebhook)
import qualified Eza.Webhooks as Webhooks

import Eza.Api.Auth (payloadTooLargeResponse)
import Eza.Api.Common
import Eza.Api.Context
import Eza.Api.Graph (viewsCreateHandler, viewsUpdateHandler)

isClipPath :: [Text] -> Bool
isClipPath path = case path of
    ("api" : "v1" : "clip" : _) -> True
    ("api" : "v1" : "clip-templates" : _) -> True
    ["api", "v1", "whoami"] -> True
    _ -> False

isExtensionOrigin :: Text -> Bool
isExtensionOrigin origin =
    any
        (`T.isPrefixOf` T.toLower origin)
        [ "chrome-extension://"
        , "moz-extension://"
        , "safari-web-extension://"
        ]

clipOriginAllowed :: Config -> Request -> Bool
clipOriginAllowed cfg req =
    case lookup "Origin" (requestHeaders req) of
        Nothing -> True
        Just raw ->
            let origin = TE.decodeUtf8 raw
             in origin `elem` cfgClipOrigins cfg
                    || origin `elem` cfgAllowedOrigins cfg
                    || isExtensionOrigin origin

requestOriginAllowed :: Config -> Request -> Bool
requestOriginAllowed cfg req
    | isClipPath (pathInfo req) = clipOriginAllowed cfg req
    | otherwise = originAllowed cfg req

corsHeaders :: Config -> Request -> ResponseHeaders
corsHeaders cfg req =
    case lookup "Origin" (requestHeaders req) of
        Just raw
            | clipOriginAllowed cfg req ->
                [ ("Access-Control-Allow-Origin", raw)
                , ("Vary", "Origin")
                , ("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS")
                , ("Access-Control-Allow-Headers", "Authorization, Content-Type, Idempotency-Key, X-Eza-Client")
                , ("Access-Control-Max-Age", "600")
                ]
        _ -> []

withCors :: Config -> Request -> Response -> Response
withCors cfg req = mapResponseHeaders (<> corsHeaders cfg req)

clipPreflight :: Config -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
clipPreflight cfg req respond
    | clipOriginAllowed cfg req =
        respond
            ( mapResponseHeaders
                (<> corsHeaders cfg req)
                (responseLBS status204 [] "")
            )
    | otherwise = respond (jsonProblem status403 "origin" "origin is not allowed")

clipErrorResponse :: Config -> Request -> ClipError -> Response
clipErrorResponse cfg req err =
    withCors cfg req (problemResponse (Clip.toProblem err))

clipSaveHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
clipSaveHandler cfg conn req respond = do
    body <- readBodyLimited (8 * 1024 * 1024) req
    case body of
        Left () -> respond (jsonProblem status413 "payload_too_large" "clip body must be at most 8 MiB")
        Right raw -> case eitherDecode raw of
            Left err -> respond (withCors cfg req (jsonProblem status400 "bad_request" (T.pack err)))
            Right request -> do
                let headerKey = fmap TE.decodeUtf8 (lookup "Idempotency-Key" (requestHeaders req))
                    request' = request{clIdempotencyKey = headerKey `orElse` clIdempotencyKey request}
                result <- saveClip conn request'
                case result of
                    Left err -> respond (clipErrorResponse cfg req err)
                    Right saved -> do
                        if scrNeedsEnrichment saved
                            then enqueueEnrichment conn (scrBookmarkId saved)
                            else pure ()
                        let status = if scrBookmarkCreated saved && not (scrReplayed saved) then status201 else status200
                        respond (withCors cfg req (jsonResponse status saved))
  where
    orElse (Just value) _ = Just value
    orElse Nothing fallback = fallback

clipPreviewHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
clipPreviewHandler cfg conn req respond = do
    body <- readBodyLimited (8 * 1024 * 1024) req
    case body of
        Left () -> respond (payloadTooLargeResponse cfg)
        Right raw -> case eitherDecode raw of
            Left err -> respond (jsonProblem status400 "bad_request" (T.pack err))
            Right request -> do
                result <- previewClip conn request
                case result of
                    Left err -> respond (clipErrorResponse cfg req err)
                    Right preview -> respond (jsonResponse status200 preview)

whoAmI :: Config -> Connection -> Request -> AuthContext -> (Response -> IO ResponseReceived) -> IO ResponseReceived
whoAmI cfg conn req ctx respond =
    case ctx of
        BearerToken token -> do
            account <- Auth.loadAccount conn
            respond
                ( withCors
                    cfg
                    req
                    ( jsonResponse
                        status200
                        ( object
                            [ "username" .= Auth.acctUsername account
                            , "token_name" .= tokenName token
                            , "scopes" .= tokenScopes token
                            ]
                        )
                    )
                )
        CookieSession _ -> do
            account <- Auth.loadAccount conn
            respond
                ( withCors
                    cfg
                    req
                    ( jsonResponse
                        status200
                        ( object
                            [ "username" .= Auth.acctUsername account
                            , "token_name" .= ("" :: Text)
                            , "scopes" .= (["session"] :: [Text])
                            ]
                        )
                    )
                )

templateWriteSession :: (Response -> IO ResponseReceived) -> AuthContext -> IO ResponseReceived -> IO ResponseReceived
templateWriteSession respond ctx action =
    case ctx of
        CookieSession _ -> action
        BearerToken _ -> respond (jsonProblem status403 "session_required" "template writes require a browser session")

templateCreateHandler :: Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
templateCreateHandler conn req respond = do
    body <- readBodyLimited (2 * 1024 * 1024) req
    case body of
        Left () -> respond (jsonProblem status413 "payload_too_large" "template is too large")
        Right raw -> case eitherDecode raw of
            Left err -> respond (jsonProblem status400 "bad_request" (T.pack err))
            Right template -> do
                result <- createTemplate conn template
                case result of
                    Left err -> respond (templateErrorResponse err)
                    Right created -> respond (jsonResponse status201 created)

templateUpdateHandler :: Connection -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
templateUpdateHandler conn templateId req respond = do
    body <- readBodyLimited (2 * 1024 * 1024) req
    case body of
        Left () -> respond (jsonProblem status413 "payload_too_large" "template is too large")
        Right raw -> case eitherDecode raw of
            Left err -> respond (jsonProblem status400 "bad_request" (T.pack err))
            Right template -> do
                result <- updateTemplate conn template{ctId = templateId}
                case result of
                    Left err -> respond (templateErrorResponse err)
                    Right updated -> respond (jsonResponse status200 updated)

templateDeleteHandler :: Connection -> Int -> (Response -> IO ResponseReceived) -> IO ResponseReceived
templateDeleteHandler conn templateId respond = do
    result <- deleteTemplate conn templateId
    case result of
        Left err -> respond (templateErrorResponse err)
        Right () -> respond (emptyResponse status204)

templateErrorResponse :: TemplateError -> Response
templateErrorResponse = problemResponse . Templates.toProblem

-- ---------------------------------------------------------------------------
-- Graph layout and views
-- ---------------------------------------------------------------------------

webhookCreateHandler :: Config -> Connection -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
webhookCreateHandler cfg conn req respond = do
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case fromJSON value :: Result WebhookInput of
            Error message -> respond (jsonProblem status400 "bad_request" (T.pack message))
            Success input -> do
                result <- createWebhook conn input
                case result of
                    Left err -> respond (problemResponse (Webhooks.toProblem err))
                    Right (webhook, secret) ->
                        respond (jsonResponse status201 (object ["webhook" .= webhook, "secret" .= secret]))

webhookUpdateHandler :: Config -> Connection -> Int -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
webhookUpdateHandler cfg conn webhookId req respond = do
    body <- jsonBody cfg req
    case body of
        Left response -> respond response
        Right value -> case fromJSON value :: Result WebhookInput of
            Error message -> respond (jsonProblem status400 "bad_request" (T.pack message))
            Success input -> do
                result <- updateWebhook conn webhookId input
                case result of
                    Left err -> respond (problemResponse (Webhooks.toProblem err))
                    Right webhook -> respond (jsonResponse status200 webhook)

webhookTestHandler ::
    Connection ->
    Int ->
    (Response -> IO ResponseReceived) ->
    IO ResponseReceived
webhookTestHandler conn webhookId respond = do
    existing <- getWebhook conn webhookId
    case existing of
        Nothing -> respond (jsonProblem status404 "not_found" "webhook not found")
        Just _ -> do
            jobId <-
                enqueueTrackedJob
                    conn
                    "webhook_test"
                    ("webhook:" <> T.pack (show webhookId))
                    (object ["webhook_id" .= webhookId])
            respond (jsonResponse status202 (object ["job_id" .= jobId]))

sanitizeRule :: Rule -> Rule
sanitizeRule rule =
    rule
        { ruleName = T.strip (ruleName rule)
        , ruleField = if T.toLower (ruleField rule) `elem` ["url", "domain", "title"] then T.toLower (ruleField rule) else "url"
        , rulePattern = T.strip (rulePattern rule)
        , ruleAddTags = [T.toLower (T.strip tag) | tag <- ruleAddTags rule, not (T.null (T.strip tag))]
        }

webhookErrorResponse :: WebhookError -> Response
webhookErrorResponse = problemResponse . Webhooks.toProblem

viewErrorResponse :: ViewError -> Response
viewErrorResponse = problemResponse . Views.toProblem

-- | Dispatch the handlers this family owns from their "Eza.Routes" constructors.
dispatch :: RequestContext -> Connection -> Route -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
dispatch rctx conn route req respond = case route of
    RouteWhoami -> whoAmI cfg conn req ctx respond
    RouteClip -> clipSaveHandler cfg conn req respond
    RouteClipPreview -> clipPreviewHandler cfg conn req respond
    RouteClipTemplateList -> do
        payload <- templatesPayload conn
        respond (withCors cfg req (jsonResponse status200 payload))
    RouteClipTemplateRead templateId -> do
        found <- getTemplate conn templateId
        case found of
            Nothing -> respond (withCors cfg req (jsonProblem status404 "template_not_found" "template not found"))
            Just template -> respond (withCors cfg req (jsonResponse status200 template))
    RouteClipTemplateCreate -> templateWriteSession respond ctx (templateCreateHandler conn req respond)
    RouteClipTemplateUpdate templateId -> templateWriteSession respond ctx (templateUpdateHandler conn templateId req respond)
    RouteClipTemplateDelete templateId -> templateWriteSession respond ctx (templateDeleteHandler conn templateId respond)
    RouteViewList -> do
        views <- listViews conn
        respond (jsonResponse status200 (object ["views" .= views]))
    RouteViewCreate ->
        viewsCreateHandler cfg conn req respond
    RouteViewRead viewSlug -> do
        found <- getView conn viewSlug
        case found of
            Nothing -> respond (jsonProblem status404 "not_found" "view not found")
            Just view -> respond (jsonResponse status200 view)
    RouteViewUpdate viewSlug ->
        viewsUpdateHandler cfg conn viewSlug req respond
    RouteViewDelete viewSlug -> do
        result <- deleteView conn viewSlug
        case result of
            Left err -> respond (viewErrorResponse err)
            Right () -> respond (emptyResponse status204)
    RouteWebhookList -> do
        webhooks <- listWebhooks conn
        respond (jsonResponse status200 (object ["webhooks" .= webhooks]))
    RouteWebhookCreate ->
        webhookCreateHandler cfg conn req respond
    RouteWebhookRead webhookId -> do
        found <- getWebhook conn webhookId
        case found of
            Nothing -> respond (jsonProblem status404 "not_found" "webhook not found")
            Just webhook -> respond (jsonResponse status200 webhook)
    RouteWebhookUpdate webhookId -> webhookUpdateHandler cfg conn webhookId req respond
    RouteWebhookDelete webhookId -> do
        removed <- deleteWebhook conn webhookId
        if removed
            then respond (emptyResponse status204)
            else respond (jsonProblem status404 "not_found" "webhook not found")
    RouteWebhookTest webhookId ->
        webhookTestHandler conn webhookId respond
    RouteWebhookDeliveries webhookId -> do
        exists <- getWebhook conn webhookId
        case exists of
            Nothing -> respond (jsonProblem status404 "not_found" "webhook not found")
            Just _ -> do
                let limit = fromMaybe 20 (readInt =<< param "limit" req)
                deliveries <- listDeliveries conn webhookId limit
                respond (jsonResponse status200 (object ["deliveries" .= deliveries]))
    RouteRuleList -> do
        rules <- listRules conn
        respond (jsonResponse status200 (object ["rules" .= rules]))
    RouteRuleCreate -> do
        body <- jsonValue cfg req
        case body of
            Left response -> respond response
            Right rule -> do
                created <- createRule conn (sanitizeRule rule)
                respond (jsonResponse status201 created)
    RouteRuleTest -> do
        body <- jsonValue cfg req
        case body of
            Left response -> respond response
            Right rule -> do
                ids <- matchingBookmarks conn (ruleField rule) (rulePattern rule)
                respond (jsonResponse status200 (object ["matches" .= length ids, "bookmark_ids" .= ids]))
    RouteRuleUpdate ruleId -> do
        body <- jsonValue cfg req
        case body of
            Left response -> respond response
            Right rule -> do
                ok <- updateRule conn (sanitizeRule rule){ruleId = ruleId}
                if ok then respond (jsonResponse status200 (object ["ok" .= True])) else respond (jsonProblem status404 "not_found" "rule not found")
    RouteRuleDelete ruleId -> do
        ok <- deleteRule conn ruleId
        if ok then respond (emptyResponse status204) else respond (jsonProblem status404 "not_found" "rule not found")
    _ -> respond (jsonProblem status500 "internal_error" "route has no handler")
  where
    cfg = rcConfig rctx
    ctx = rcAuth rctx

-- | The "Eza.Routes" constructors this family handles.
owns :: Route -> Bool
owns route = case route of
    RouteWhoami -> True
    RouteClip -> True
    RouteClipPreview -> True
    RouteClipTemplateList -> True
    RouteClipTemplateRead _ -> True
    RouteClipTemplateCreate -> True
    RouteClipTemplateUpdate _ -> True
    RouteClipTemplateDelete _ -> True
    RouteViewList -> True
    RouteViewCreate -> True
    RouteViewRead _ -> True
    RouteViewUpdate _ -> True
    RouteViewDelete _ -> True
    RouteWebhookList -> True
    RouteWebhookCreate -> True
    RouteWebhookRead _ -> True
    RouteWebhookUpdate _ -> True
    RouteWebhookDelete _ -> True
    RouteWebhookTest _ -> True
    RouteWebhookDeliveries _ -> True
    RouteRuleList -> True
    RouteRuleCreate -> True
    RouteRuleTest -> True
    RouteRuleUpdate _ -> True
    RouteRuleDelete _ -> True
    _ -> False
