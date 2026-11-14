{- | HTTP client for the eza v1 JSON API.

Every unsafe request carries @X-CSRF-Token@ read from the @eza_csrf@
cookie.  Responses are decoded with the shared "Eza.Types" (and the other
@eza-core@ wire modules) aeson instances; a missing or renamed field fails the
call with an 'ApiError' that names the endpoint instead of filling in a
default. Only calls whose response body the client never reads skip decoding
('apiWrite' and 'apiDelete').
-}
module Eza.Web.Api (
    Eff,
    ListParams (..),
    defaultListParams,
    percentEncode,
    toText,
    fromText,
    -- reads
    fetchBoot,
    fetchBookmarks,
    fetchBookmarksQuery,
    fetchDetail,
    fetchBacklinks,
    fetchAutocomplete,
    fetchGraph,
    fetchGraphLayout,
    fetchViews,
    fetchView,
    WebhookTest (..),
    fetchWebhooks,
    fetchWebhook,
    createWebhook,
    updateWebhook,
    deleteWebhook,
    testWebhook,
    fetchWebhookDeliveries,
    fetchAdminUsers,
    createAdminUser,
    patchAdminUser,
    resetAdminPassword,
    deleteAdminUser,
    ViewPatch (..),
    createView,
    patchView,
    deleteView,
    fetchSavedSearches,
    fetchDedupReport,
    fetchConsolidation,
    fetchSuggestions,
    fetchPruneCandidates,
    fetchAccount,
    fetchTags,
    fetchStats,
    fetchTokens,
    fetchHighlights,
    fetchShares,
    fetchAiStatus,
    fetchRules,
    -- writes
    createBookmark,
    quickSave,
    BulkAction (..),
    bulkUpdate,
    createApiToken,
    revokeApiToken,
    createHighlight,
    patchHighlight,
    deleteHighlight,
    createShareLink,
    revokeShareLink,
    createRule,
    patchRule,
    deleteRule,
    testRule,
    patchBookmark,
    deleteBookmark,
    markAllAbove,
    trackOpen,
    bookmarkAction,
    saveSavedSearch,
    deleteSavedSearch,
    mergeDedup,
    mergeDedupAll,
    mergeTags,
    renameTag,
    deleteTag,
    detachTag,
    applyTagSuggestion,
    runPrune,
    checkDead,
    fetchUndoEntries,
    fetchUndoPreview,
    runUndo,
    markLinkAlive,
    recheckLink,
    patchBookmarkWithResult,
    regenerateRecovery,
    renameCredential,
    deleteCredential,
    patchUsername,
    changePassword,
    setPasskeyRequirement,
    revokeOtherSessions,
    logout,
    submitImport,
    ImportResponse (..),
    -- links
    exportUrl,
    exportJsonUrl,
    notesExportUrl,
    bookmarkSnapshotUrl,
) where

import Data.Aeson (FromJSON (..), ToJSON, Value (..), object, toJSON, withObject, (.:), (.:?), (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (stripPrefix)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Miso
import qualified Miso.JSON as MJ

import Eza.Account (AccountInfo, TokenView)
import Eza.Ai (AiStatus, TagSuggestion)
import Eza.Boot (BootPayload)
import Eza.Consolidation (ConsolidationGroup)
import Eza.GraphLayout (GraphLayoutWire, LayoutPreset (..))
import Eza.Rule (Rule (..))
import Eza.Share (ShareView)
import Eza.Types (
    Backlink (..),
    Backlinks (..),
    BookmarkDetail,
    BookmarkSummary,
    DedupMergeAllReport,
    DedupReport,
    GraphData (..),
    Highlight,
    LibraryStats (..),
    SavedSearch,
    SearchPage,
    TagStat,
    UndoEntry,
    UndoPreview,
    UndoResult,
 )
import Eza.User (UserCreateInput (..), UserCreateResult (..), UserRole (..), UserView (..))
import qualified Eza.View as EV
import Eza.Web.Error (ApiError (..), mkApiError)
import Eza.Web.Logic.Api (
    BookmarkListQuery (..),
    ClientRequest (..),
    DedupCandidateQuery (..),
    requestMethod,
    requestPath,
 )
import qualified Eza.Web.Logic.Route as ClientRoute
import Eza.Web.Logic.Wire (ImportResponse (..), ListParams (..), WebhookTest (..), defaultListParams)
import Eza.Webhook (DeliveryView, Webhook, WebhookInput (..))

-- | Convenience alias: the API module is polymorphic in the app model/action.
type Eff model action = Effect () () model action

toText :: MisoString -> Text
toText = fromMisoString

fromText :: Text -> MisoString
fromText = ms

-- --------------------------------------------------------------- requests --

csrfToken :: IO MisoString
csrfToken = do
    cookie <- fromJSVal =<< (jsg "document" ! "cookie")
    pure $ case (cookie :: Maybe MisoString) of
        Nothing -> ""
        Just raw -> ms (findCookie "eza_csrf" (fromMisoString raw))

findCookie :: String -> String -> String
findCookie name raw =
    fromMaybe "" $
        case [v | part <- splitSemi raw, Just v <- [stripPrefix (name ++ "=") (trim part)]] of
            (v : _) -> Just v
            [] -> Nothing

splitSemi :: String -> [String]
splitSemi s = case break (== ';') s of
    (a, []) -> [a]
    (a, _ : rest) -> a : splitSemi rest

trim :: String -> String
trim = dropWhile isSpaceEnd . reverse . dropWhile isSpaceEnd . reverse

isSpaceEnd :: Char -> Bool
isSpaceEnd c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

{- | One raw HTTP exchange as the browser reports it.  @rfStatus@ is @0@ when
the request never reached the server; @rfError@ then carries the transport
message.  The body is read before deciding success, so the server's JSON
error envelope (a duplicate 409, a 403, a 404) survives instead of only its
status code.
-}
data RawResponse = RawResponse
    { rfStatus :: Int
    , rfText :: Text
    , rfError :: Maybe Text
    }

{- | The network helper reports the three fields as separate JS arguments.
Keeping the body out of a JSON envelope avoids stringifying, parsing,
unpacking and re-encoding every response before the real decoder sees it.
-}
rawResponse :: Int -> MisoString -> MisoString -> RawResponse
rawResponse status body transportError =
    RawResponse
        { rfStatus = status
        , rfText = toText body
        , rfError =
            let message = toText transportError
             in if T.null (T.strip message) then Nothing else Just message
        }

{- | Build the request headers: JSON in and JSON out, plus the CSRF token
when the cookie is present.
-}
requestHeaders :: [(MisoString, MisoString)] -> MisoString -> [(MisoString, MisoString)]
requestHeaders extra token =
    [ ("Accept", "application/json")
    , ("Content-Type", "application/json")
    ]
        ++ (if T.null (toText token) then [] else [("X-CSRF-Token", token)])
        ++ extra

{- | Map a raw exchange onto the API contract: transport failure, non-2xx
(envelope message preserved), then a strict JSON parse. The endpoint label goes
into the error so the toast says which call returned an unreadable body.
-}
rawOutcome :: MisoString -> CONTENT_TYPE -> RawResponse -> Either ApiError Value
rawOutcome endpoint responseType raw = case (rfStatus raw, rfError raw) of
    (0, Just message)
        | not (T.null (T.strip message)) -> Left (mkApiError Nothing (Just message))
    (status, _)
        | status < 200 || status >= 300 -> Left (statusError status raw)
        | responseType == JSON ->
            case A.eitherDecodeStrict' (TE.encodeUtf8 (rfText raw)) :: Either String Value of
                Right value -> Right value
                Left err -> Left (bodyError endpoint (T.pack err))
        | otherwise -> Right Null

-- | A response body that is not the JSON the endpoint promises.
bodyError :: MisoString -> Text -> ApiError
bodyError endpoint detail =
    mkApiError
        Nothing
        (Just ("The response from " <> describeEndpoint endpoint <> " could not be read: " <> detail))

-- | How an endpoint is named in a client-side decode error.
describeEndpoint :: MisoString -> Text
describeEndpoint endpoint
    | T.null label = "the server"
    | otherwise = label
  where
    label = T.strip (toText endpoint)

{- | The server answers failures with @{"error":{"code":...,"message":...}}@.
The message is worth showing verbatim: it explains duplicates, expired
sessions and refused writes.
-}
statusError :: Int -> RawResponse -> ApiError
statusError status raw = mkApiError (Just status) (serverMessage (rfText raw))

serverMessage :: Text -> Maybe Text
serverMessage body
    | T.null trimmed = Nothing
    | "{" `T.isPrefixOf` trimmed =
        case A.eitherDecodeStrict' (TE.encodeUtf8 trimmed) :: Either String Value of
            Right value -> firstText [["error", "message"], ["message"], ["error", "code"]] value
            Left _ -> Nothing
    | "<" `T.isPrefixOf` trimmed = Nothing
    | otherwise = Just (T.take 300 trimmed)
  where
    trimmed = T.strip body

firstText :: [[Text]] -> Value -> Maybe Text
firstText paths value = firstJust (map (`textAtPath` value) paths)

firstJust :: [Maybe a] -> Maybe a
firstJust [] = Nothing
firstJust (Just value : _) = Just value
firstJust (Nothing : rest) = firstJust rest

textAtPath :: [Text] -> Value -> Maybe Text
textAtPath [] value = case value of
    A.String message | not (T.null (T.strip message)) -> Just (T.strip message)
    _ -> Nothing
textAtPath (key : rest) value = case value of
    A.Object fields -> textAtPath rest =<< KM.lookup (K.fromText key) fields
    _ -> Nothing

{- | Fire a request.  The success callback receives the decoded body for JSON
responses; failures carry the server's own message.
-}
sendValue ::
    MisoString ->
    MisoString ->
    Maybe Value ->
    [(MisoString, MisoString)] ->
    CONTENT_TYPE ->
    (Value -> action) ->
    (ApiError -> action) ->
    Eff model action
sendValue method url requestedBody extraHeaders responseType onOk onErr = withSink $ \sink -> do
    token <- csrfToken
    encodedBody <- traverse (toJSVal . MJ.encode) requestedBody
    let report raw =
            case rawOutcome url responseType raw of
                Left err -> onErr err
                Right value -> onOk value
    finish <- asyncCallback3 $ \statusValue textValue errorValue -> do
        statusNumber <- fromJSVal statusValue :: IO (Maybe Double)
        body <- fromMaybe "" <$> (fromJSVal textValue :: IO (Maybe MisoString))
        transportError <- fromMaybe "" <$> (fromJSVal errorValue :: IO (Maybe MisoString))
        let status = maybe 0 round statusNumber
        sink (report (rawResponse status body transportError))
    net <- jsg ("EzaNet" :: MisoString)
    urlValue <- toJSVal url
    methodValue <- toJSVal method
    bodyValue <- toJSVal encodedBody
    headersValue <- toJSVal (M.fromList (requestHeaders extraHeaders token))
    _ <- net # ("fetch" :: MisoString) $ (urlValue, methodValue, bodyValue, headersValue, finish)
    pure ()

{- | Decode a response body into a shared core DTO. A parse failure becomes an
'ApiError' that names the endpoint; the caller's error branch decides how the
message is shown.
-}
decodeResponseAt :: (FromJSON a) => MisoString -> Value -> Either ApiError a
decodeResponseAt endpoint value =
    case MJ.fromJSON value of
        MJ.Success a -> Right a
        MJ.Error e -> Left (bodyError endpoint (toText e))

{- | Send a write through the shared client request table. The HTTP method and
the concrete URL of every write come from "Eza.Web.Logic.Api" (and through it
from the route truth), so a write can never drift from the endpoint it names;
only the body is caller-supplied.

The four variants mirror the old @apiWrite@/@apiDelete@ helpers: ignored body,
shared-type decode, caller decode and ignored-body delete.
-}
apiWriteRequest ::
    (ToJSON b) =>
    ClientRequest ->
    Maybe b ->
    action ->
    (ApiError -> action) ->
    Eff model action
apiWriteRequest request requestBody onOk onErr =
    sendValue
        (requestMethodText request)
        (requestUrl request)
        (toJSON <$> requestBody)
        []
        NONE
        (\_ -> onOk)
        onErr

-- | A write with a JSON body whose answer decodes as a shared core type.
requestWriteJson ::
    (ToJSON b, FromJSON a) =>
    ClientRequest ->
    Maybe b ->
    (a -> action) ->
    (ApiError -> action) ->
    Eff model action
requestWriteJson request requestBody onOk onErr =
    sendValue
        (requestMethodText request)
        url
        (toJSON <$> requestBody)
        []
        JSON
        (\value -> either onErr onOk (decodeResponseAt url value))
        onErr
  where
    url = requestUrl request

{- | A write whose caller decodes the JSON answer: endpoints that rename a core
field or answer a local wire record.
-}
requestWriteValue ::
    (ToJSON b) =>
    ClientRequest ->
    Maybe b ->
    (MisoString -> Value -> Either ApiError a) ->
    (a -> action) ->
    (ApiError -> action) ->
    Eff model action
requestWriteValue request requestBody decodeResponse onOk onErr =
    sendValue
        (requestMethodText request)
        url
        (toJSON <$> requestBody)
        []
        JSON
        (\value -> either onErr onOk (decodeResponse url value))
        onErr
  where
    url = requestUrl request

-- | A delete whose answer body the client never reads.
apiDeleteRequest :: ClientRequest -> action -> (ApiError -> action) -> Eff model action
apiDeleteRequest request onOk onErr =
    sendValue
        (requestMethodText request)
        (requestUrl request)
        Nothing
        []
        NONE
        (\_ -> onOk)
        onErr

-- ------------------------------------------------------------- list query --

{- | Read a client request through the native request model. Both the HTTP
method and the URL come from the shared route truth, so a read fetcher cannot
drift from the endpoint it names.
-}
requestGet ::
    ClientRequest ->
    (MisoString -> Value -> Either ApiError a) ->
    (a -> action) ->
    (ApiError -> action) ->
    Eff model action
requestGet request decodeResponse onOk onErr =
    sendValue (requestMethodText request) url Nothing [] JSON (\value -> either onErr onOk (decodeResponse url value)) onErr
  where
    url = requestUrl request

-- | A read request whose body decodes directly as a shared core wire type.
requestGetJson ::
    (FromJSON a) =>
    ClientRequest ->
    (a -> action) ->
    (ApiError -> action) ->
    Eff model action
requestGetJson request = requestGet request (\url value -> decodeResponseAt url value)

requestUrl :: ClientRequest -> MisoString
requestUrl request = fromText (requestPath request)

requestMethodText :: ClientRequest -> MisoString
requestMethodText = fromText . requestMethod

-- | The list filter record the native request model renders.
listQuery :: ListParams -> BookmarkListQuery
listQuery lp =
    BookmarkListQuery
        { blqQ = lpQ lp
        , blqTags = lpTags lp
        , blqSort = lpSort lp
        , blqUnreadOnly = lpUnreadOnly lp
        , blqOffset = lpOffset lp
        , blqLimit = lpLimit lp
        }

{- | Percent-encode a string for a URL component. The implementation lives in
the native client logic; this wrapper keeps the MisoString surface for the
write requests that still build their URLs here.
-}
percentEncode :: MisoString -> MisoString
percentEncode = fromText . ClientRoute.percentEncode . toText

-- ------------------------------------------------- response envelopes ------

{- | Read one JSON number field that an endpoint always sends. A missing or
mistyped field is an 'ApiError' that names the endpoint, never a zero.
-}
decodeIntFieldAt :: MisoString -> Text -> Value -> Either ApiError Int
decodeIntFieldAt endpoint key value =
    case MJ.parseMaybe (MJ.withObject "response" (\o -> o MJ..: fromText key)) value of
        Just number -> Right number
        Nothing -> Left (missingFieldError endpoint key)

{- | Read the one array field an endpoint wraps its rows in. The wrapper key
must be present, and every element must decode as its shared core type.
-}
decodeListFieldAt :: (FromJSON a) => MisoString -> Text -> Value -> Either ApiError [a]
decodeListFieldAt endpoint key value =
    case MJ.parseMaybe (MJ.withObject "response" (\o -> o MJ..: fromText key)) value of
        Just rows -> Right rows
        Nothing -> Left (missingFieldError endpoint key)

missingFieldError :: MisoString -> Text -> ApiError
missingFieldError endpoint key =
    mkApiError
        Nothing
        ( Just
            ( "The response from "
                <> describeEndpoint endpoint
                <> " has no valid \""
                <> key
                <> "\" field."
            )
        )

-- | @POST /api/v1/quick-save@: the row id and whether it already existed.
data QuickSaveResponse = QuickSaveResponse
    { qsrId :: Int
    , qsrExisting :: Bool
    }

instance FromJSON QuickSaveResponse where
    parseJSON = withObject "quick-save" $ \o ->
        QuickSaveResponse
            <$> o .: "id"
            <*> o .: "existing"

-- | @PATCH /api/v1/bookmarks/{id}@: how many highlights were re-anchored away.
newtype BookmarkPatchResponse = BookmarkPatchResponse {bprHighlightsRemoved :: Int}

instance FromJSON BookmarkPatchResponse where
    parseJSON = withObject "bookmark patch" $ \o ->
        BookmarkPatchResponse <$> o .: "highlights_removed"

-- | @POST /api/v1/dedup/merge@.
data MergeResponse = MergeResponse
    { mrMerged :: Int
    , mrSnapshotId :: Int
    }

instance FromJSON MergeResponse where
    parseJSON = withObject "merge" $ \o ->
        MergeResponse
            <$> o .: "merged"
            <*> o .: "snapshot_id"

-- | @POST /api/v1/maintenance/check-dead@.
data CheckDeadResponse = CheckDeadResponse
    { cdrChecked :: Int
    , cdrDead :: Int
    , cdrTotalDead :: Int
    }

instance FromJSON CheckDeadResponse where
    parseJSON = withObject "check-dead" $ \o ->
        CheckDeadResponse
            <$> o .: "checked"
            <*> o .: "dead"
            <*> o .: "total_dead"

-- | @POST /api/v1/rules/test@: the dry-run match count and its ids.
data RuleTestResponse = RuleTestResponse
    { rtrMatches :: Int
    , rtrBookmarkIds :: [Int]
    }

instance FromJSON RuleTestResponse where
    parseJSON = withObject "rule dry run" $ \o ->
        RuleTestResponse
            <$> o .: "matches"
            <*> o .: "bookmark_ids"

{- | @POST /api/v1/tokens@: the raw token appears exactly once, next to its
metadata.
-}
data TokenCreatedResponse = TokenCreatedResponse
    { tcrToken :: Text
    , tcrTokenInfo :: TokenView
    }

instance FromJSON TokenCreatedResponse where
    parseJSON = withObject "created token" $ \o ->
        TokenCreatedResponse
            <$> o .: "token"
            <*> o .: "token_info"

-- | @POST /api/v1/share-links@: the new share id and its public URL.
data ShareCreatedResponse = ShareCreatedResponse
    { scrId :: Int
    , scrUrl :: Text
    }

instance FromJSON ShareCreatedResponse where
    parseJSON = withObject "created share" $ \o ->
        ShareCreatedResponse
            <$> o .: "id"
            <*> o .: "url"

{- | @GET /api/v1/tags/{tag}/suggestions@. The server includes @notice@ only
when it has something to say (for example that no AI provider is configured);
@suggestions@ is always present.
-}
data SuggestionsResponse = SuggestionsResponse
    { sgrSuggestions :: [TagSuggestion]
    , sgrNotice :: Maybe Text
    }

instance FromJSON SuggestionsResponse where
    parseJSON = withObject "suggestions" $ \o ->
        SuggestionsResponse
            <$> o .: "suggestions"
            <*> o .:? "notice"

-- | @POST /api/v1/webhooks@: the stored webhook and its one-time secret.
data WebhookCreatedResponse = WebhookCreatedResponse
    { wcrWebhook :: Webhook
    , wcrSecret :: Text
    }

instance FromJSON WebhookCreatedResponse where
    parseJSON = withObject "created webhook" $ \o ->
        WebhookCreatedResponse
            <$> o .: "webhook"
            <*> o .: "secret"

{- | @GET /api/v1/stats@ renames three fields of the shared 'LibraryStats'
(@bookmarks@, @bookmark_tags@, @jobs_pending@) and adds @links@, so it cannot
use the core instance directly. Every field the dashboard reads is required.
-}
decodeStatsAt :: MisoString -> Value -> Either ApiError LibraryStats
decodeStatsAt endpoint value =
    case MJ.parseMaybe statsParser value of
        Just stats -> Right stats
        Nothing -> Left (bodyError endpoint "the stats payload is missing a field")
  where
    statsParser =
        MJ.withObject "LibraryStats" $ \o ->
            LibraryStats
                <$> o MJ..: "bookmarks"
                <*> o MJ..: "tags"
                <*> o MJ..: "bookmark_tags"
                <*> o MJ..: "sources"
                <*> o MJ..: "top_sources"
                <*> o MJ..: "sources_once"
                <*> o MJ..: "first_day"
                <*> o MJ..: "last_day"
                <*> o MJ..: "days"
                <*> o MJ..: "years"
                <*> o MJ..: "filing_days"
                <*> o MJ..: "unread"
                <*> o MJ..: "dead"
                <*> o MJ..: "jobs_pending"
                <*> o MJ..: "favicon_bytes"
                <*> o MJ..: "highlights"
                <*> o MJ..: "shares"

{- | The import response. Both the Netscape parser and the JSON-export path
answer with the summary counts @inserted@, @found@ and @existing@; the full
'Eza.Types.ImportReport' is only present for the Netscape file flow.
-}

-- ------------------------------------------------------------------ reads --

fetchBoot :: (BootPayload -> action) -> (ApiError -> action) -> Eff model action
fetchBoot = requestGetJson ApiBoot

fetchBookmarks ::
    ListParams ->
    (SearchPage -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchBookmarks lp = fetchBookmarksQuery (listQuery lp)

{- | Fetch one ledger page from the native request record. The native ledger
reducer emits the request it wants; this is the bridge point between that
record and the shared JSON transport. 'fetchBookmarks' keeps the 'ListParams'
surface for the select-all paging chain, which is still shell-side.
-}
fetchBookmarksQuery ::
    BookmarkListQuery ->
    (SearchPage -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchBookmarksQuery query = requestGetJson (ApiBookmarks query)

fetchDetail ::
    Int ->
    (BookmarkDetail -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchDetail bid = requestGetJson (ApiBookmark bid)

-- | Linked + unlinked backlinks as one flat list.
fetchBacklinks ::
    Int ->
    ([Backlink] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchBacklinks bid onOk onErr =
    requestGet (ApiBookmarkBacklinks bid) decode onOk onErr
  where
    decode url value = fmap flatten (decodeResponseAt url value)
    flatten bks = bksLinked bks ++ bksUnlinked bks

fetchAutocomplete ::
    Text ->
    ([BookmarkSummary] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchAutocomplete q onOk onErr =
    requestGet (ApiAutocomplete q) (\url value -> decodeListFieldAt url "items" value) onOk onErr

fetchGraph ::
    (GraphData -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchGraph = requestGetJson ApiGraph

{- | The server-built layout for one preset. The payload is the shared
'GraphLayoutWire': @{schema, revision, preset, tags, records, bounds}@ with
positions quantized to 1/100 world unit. The client validates the revision
against 'gdRevision' before hydrating.
-}
fetchGraphLayout ::
    LayoutPreset ->
    (GraphLayoutWire -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchGraphLayout preset onOk onErr =
    requestGet (ApiGraphLayout preset) (\url value -> decodeResponseAt url value) onOk onErr

{- | The user's declarative views. @GET /api/v1/views@ answers
@{"views":[...]}@; create and patch answer the stored view object.
-}
data ViewPatch = ViewPatch
    { vpName :: Maybe Text
    , vpSlug :: Maybe Text
    , vpDefinition :: Maybe EV.ViewDefinition
    , vpIsDefault :: Maybe Bool
    }
    deriving (Eq, Show)

instance ToJSON ViewPatch where
    toJSON patch =
        object
            [ "name" .= vpName patch
            , "slug" .= vpSlug patch
            , "definition" .= vpDefinition patch
            , "is_default" .= vpIsDefault patch
            ]

fetchViews :: ([EV.View] -> action) -> (ApiError -> action) -> Eff model action
fetchViews onOk onErr =
    requestGet ApiViews (\url value -> decodeListFieldAt url "views" value) onOk onErr

fetchView :: Text -> (EV.View -> action) -> (ApiError -> action) -> Eff model action
fetchView slug onOk onErr =
    requestGetJson (ApiView slug) onOk onErr

createView :: EV.ViewInput -> (EV.View -> action) -> (ApiError -> action) -> Eff model action
createView input onOk onErr =
    requestWriteJson ApiCreateView (Just input) onOk onErr

patchView :: Text -> ViewPatch -> (EV.View -> action) -> (ApiError -> action) -> Eff model action
patchView slug patch onOk onErr =
    requestWriteJson (ApiPatchView slug) (Just patch) onOk onErr

deleteView :: Text -> action -> (ApiError -> action) -> Eff model action
deleteView slug = apiDeleteRequest (ApiDeleteView slug)

{- | Account webhooks. Management is session-only on the server; a bearer
token gets 403 @session_required@. The create response is the only place the
64-hex secret ever appears.
-}
fetchWebhooks :: ([Webhook] -> action) -> (ApiError -> action) -> Eff model action
fetchWebhooks onOk onErr =
    requestGet ApiWebhooks (\url value -> decodeListFieldAt url "webhooks" value) onOk onErr

fetchWebhook :: Int -> (Webhook -> action) -> (ApiError -> action) -> Eff model action
fetchWebhook webhookId = requestGetJson (ApiWebhook webhookId)

createWebhook ::
    WebhookInput ->
    ((Webhook, Text) -> action) ->
    (ApiError -> action) ->
    Eff model action
createWebhook input onOk onErr =
    requestWriteValue
        ApiCreateWebhook
        (Just input)
        decodeResponseAt
        (\created -> onOk (wcrWebhook created, wcrSecret created))
        onErr

updateWebhook ::
    Int ->
    WebhookInput ->
    (Webhook -> action) ->
    (ApiError -> action) ->
    Eff model action
updateWebhook webhookId input onOk onErr =
    requestWriteJson (ApiPatchWebhook webhookId) (Just input) onOk onErr

deleteWebhook :: Int -> action -> (ApiError -> action) -> Eff model action
deleteWebhook webhookId = apiDeleteRequest (ApiDeleteWebhook webhookId)

testWebhook :: Int -> (WebhookTest -> action) -> (ApiError -> action) -> Eff model action
testWebhook webhookId onOk onErr =
    requestWriteValue
        (ApiTestWebhook webhookId)
        (Nothing :: Maybe Value)
        decodeResponseAt
        onOk
        onErr

fetchWebhookDeliveries :: Int -> ([DeliveryView] -> action) -> (ApiError -> action) -> Eff model action
fetchWebhookDeliveries webhookId onOk onErr =
    requestGet (ApiWebhookDeliveries webhookId) (\url value -> decodeListFieldAt url "deliveries" value) onOk onErr

fetchAdminUsers :: ([UserView] -> action) -> (ApiError -> action) -> Eff model action
fetchAdminUsers onOk onErr =
    requestGet ApiAdminUsers (\url value -> decodeListFieldAt url "users" value) onOk onErr

createAdminUser ::
    UserCreateInput ->
    (UserCreateResult -> action) ->
    (ApiError -> action) ->
    Eff model action
createAdminUser input onOk onErr =
    requestWriteJson ApiCreateAdminUser (Just input) onOk onErr
patchAdminUser ::
    Int ->
    Maybe Bool ->
    Maybe UserRole ->
    (UserView -> action) ->
    (ApiError -> action) ->
    Eff model action
patchAdminUser userId enabled role onOk onErr =
    requestWriteValue
        (ApiPatchAdminUser userId)
        (Just (object (["enabled" .= value | Just value <- [enabled]] ++ ["role" .= value | Just value <- [role]])))
        decodeResponseAt
        onOk
        onErr
resetAdminPassword ::
    Int ->
    Text ->
    action ->
    (ApiError -> action) ->
    Eff model action
resetAdminPassword userId password onOk onErr =
    apiWriteRequest (ApiResetAdminPassword userId) (Just (object ["password" .= password])) onOk onErr
deleteAdminUser ::
    Int ->
    Bool ->
    action ->
    (ApiError -> action) ->
    Eff model action
deleteAdminUser userId deleteDb onOk onErr =
    apiWriteRequest
        (ApiDeleteAdminUser userId)
        (Just (object ["confirm" .= True, "delete_db" .= deleteDb]))
        onOk
        onErr

fetchSavedSearches ::
    ([SavedSearch] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchSavedSearches onOk onErr =
    requestGet ApiSavedSearches (\url value -> decodeListFieldAt url "saved_searches" value) onOk onErr

{- | One page of duplicate candidates. The two sections carry independent
offsets and limits, and the report repeats the exact whole-library counts on
every page, so the client never sums loaded groups to invent a total.
-}
fetchDedupReport ::
    Int ->
    Int ->
    Int ->
    Int ->
    (DedupReport -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchDedupReport urlOffset urlLimit titleOffset titleLimit onOk onErr =
    requestGet request (\url value -> decodeResponseAt url value) onOk onErr
  where
    request =
        ApiDedupCandidates (DedupCandidateQuery urlOffset urlLimit titleOffset titleLimit)

{- | The confirmed one-shot merge of every same-URL group. The server writes
one undo snapshot and answers the report the interface shows.
-}
mergeDedupAll :: (DedupMergeAllReport -> action) -> (ApiError -> action) -> Eff model action
mergeDedupAll onOk onErr =
    requestWriteJson ApiMergeDedupAll (Just (object ["confirm" .= True])) onOk onErr

fetchConsolidation ::
    ([ConsolidationGroup] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchConsolidation onOk onErr =
    requestGet ApiTagConsolidationCandidates (\url value -> decodeListFieldAt url "groups" value) onOk onErr

{- | @GET /api/v1/tags/{tag}/suggestions@. The server answers an unconfigured
provider with 200, an empty list and a notice; hand the suggestions and the
notice to the caller so the page can say what happened instead of showing an
empty result that looks like a clean scan.
-}
fetchSuggestions ::
    Text ->
    ([TagSuggestion] -> Maybe Text -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchSuggestions tag onOk onErr =
    requestGet (ApiTagSuggestions tag) decode onOk' onErr
  where
    decode url value =
        fmap (\response -> (sgrSuggestions response, sgrNotice response)) (decodeResponseAt url value)
    onOk' (suggestions, notice) = onOk suggestions notice

fetchPruneCandidates ::
    ([BookmarkSummary] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchPruneCandidates onOk onErr =
    requestGet ApiMaintenancePruneCandidates (\url value -> decodeListFieldAt url "items" value) onOk onErr

fetchAccount ::
    (AccountInfo -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchAccount = requestGetJson ApiAccount

fetchTags ::
    ([TagStat] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchTags onOk onErr =
    requestGet ApiTags (\url value -> decodeListFieldAt url "tags" value) onOk onErr

{- | @GET /api/v1/stats@ — the whole library count read again after a write.
The API renames three fields of the shared 'LibraryStats' and adds @links@, so
the payload decodes onto a local wire record and converts to the shared type.
-}
fetchStats ::
    (LibraryStats -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchStats onOk onErr =
    requestGet ApiStats (\url value -> decodeStatsAt url value) onOk onErr

-- ----------------------------------------------------------------- writes --

createBookmark ::
    Text ->
    Text ->
    [Text] ->
    (Int -> action) ->
    (ApiError -> action) ->
    Eff model action
createBookmark url title tags onOk onErr =
    requestWriteValue
        ApiCreateBookmark
        ( Just
            ( object
                [ "url" .= url
                , "title" .= title
                , "tags" .= tags
                ]
            )
        )
        (\endpoint value -> decodeIntFieldAt endpoint "id" value)
        onOk
        onErr
quickSave ::
    Text ->
    Text ->
    (Int -> Bool -> action) ->
    (ApiError -> action) ->
    Eff model action
quickSave url title onOk onErr =
    requestWriteValue
        ApiQuickSave
        ( Just
            ( object
                [ "url" .= url
                , "title" .= title
                , "tags" .= ([] :: [Text])
                ]
            )
        )
        decodeResponseAt
        (\response -> onOk (qsrId response) (qsrExisting response))
        onErr

patchBookmark ::
    Int ->
    Value ->
    action ->
    (ApiError -> action) ->
    Eff model action
patchBookmark bid payload =
    apiWriteRequest (ApiPatchBookmark bid) (Just payload)
patchBookmarkWithResult ::
    Int ->
    Value ->
    (Int -> action) ->
    (ApiError -> action) ->
    Eff model action
patchBookmarkWithResult bid payload onOk onErr =
    requestWriteValue
        (ApiPatchBookmark bid)
        (Just payload)
        decodeResponseAt
        (onOk . bprHighlightsRemoved)
        onErr

deleteBookmark :: Int -> action -> (ApiError -> action) -> Eff model action
deleteBookmark bid = apiDeleteRequest (ApiDeleteBookmark bid)

markAllAbove ::
    Maybe Int ->
    (Int -> action) ->
    (ApiError -> action) ->
    Eff model action
markAllAbove aboveId onOk onErr =
    requestWriteValue
        ApiMarkAllAbove
        (Just (object ["above_id" .= aboveId]))
        (\endpoint value -> decodeIntFieldAt endpoint "updated" value)
        onOk
        onErr

trackOpen :: Int -> action -> (ApiError -> action) -> Eff model action
trackOpen bid =
    apiWriteRequest (ApiTrackOpen bid) (Nothing :: Maybe Value)
bookmarkAction :: Int -> Text -> action -> (ApiError -> action) -> Eff model action
bookmarkAction bid verb =
    apiWriteRequest (ApiBookmarkAction bid verb) (Nothing :: Maybe Value)

saveSavedSearch ::
    Text ->
    Text ->
    [Text] ->
    (Int -> action) ->
    (ApiError -> action) ->
    Eff model action
saveSavedSearch name q tags onOk onErr =
    requestWriteValue
        ApiCreateSavedSearch
        (Just (object ["name" .= name, "q" .= q, "tags" .= tags]))
        (\endpoint value -> decodeIntFieldAt endpoint "id" value)
        onOk
        onErr

deleteSavedSearch :: Int -> action -> (ApiError -> action) -> Eff model action
deleteSavedSearch sid = apiDeleteRequest (ApiDeleteSavedSearch sid)

mergeDedup ::
    Int ->
    [Int] ->
    ((Int, Int) -> action) ->
    (ApiError -> action) ->
    Eff model action
mergeDedup keep mergeIds onOk onErr =
    requestWriteValue
        ApiMergeDedup
        (Just (object ["keep_id" .= keep, "merge_ids" .= mergeIds]))
        decodeResponseAt
        (\response -> onOk (mrMerged response, mrSnapshotId response))
        onErr

mergeTags ::
    [Text] ->
    Text ->
    action ->
    (ApiError -> action) ->
    Eff model action
mergeTags from into =
    apiWriteRequest ApiMergeTags (Just (object ["from" .= from, "into" .= into]))

renameTag :: Text -> Text -> action -> (ApiError -> action) -> Eff model action
renameTag old newName =
    apiWriteRequest (ApiRenameTag old) (Just (object ["name" .= newName]))

deleteTag :: Text -> action -> (ApiError -> action) -> Eff model action
deleteTag tag = apiDeleteRequest (ApiDeleteTag tag)
detachTag :: Text -> action -> (ApiError -> action) -> Eff model action
detachTag tag = apiDeleteRequest (ApiDetachTag tag)

applyTagSuggestion ::
    Int ->
    [Text] ->
    action ->
    (ApiError -> action) ->
    Eff model action
applyTagSuggestion bid tags =
    apiWriteRequest
        ApiApplyTagSuggestion
        (Just (object ["bookmark_id" .= bid, "tags" .= tags]))

runPrune :: [Int] -> (Int -> action) -> (ApiError -> action) -> Eff model action
runPrune ids onOk onErr =
    requestWriteValue
        ApiRunPrune
        (Just (object ["ids" .= ids]))
        (\endpoint value -> decodeIntFieldAt endpoint "pruned" value)
        onOk
        onErr

checkDead :: ((Int, Int, Int) -> action) -> (ApiError -> action) -> Eff model action
checkDead onOk onErr =
    requestWriteValue
        ApiCheckDead
        -- The handler parses a JSON object; include_dead makes the explicit
        -- maintenance recheck revisit records that are already marked dead.
        (Just (object ["include_dead" .= True]))
        decodeResponseAt
        ( \response ->
            onOk (cdrChecked response, cdrDead response, cdrTotalDead response)
        )
        onErr

fetchUndoEntries :: ([UndoEntry] -> action) -> (ApiError -> action) -> Eff model action
fetchUndoEntries onOk onErr =
    requestGet ApiUndoEntries (\url value -> decodeListFieldAt url "entries" value) onOk onErr

fetchUndoPreview :: Int -> (UndoPreview -> action) -> (ApiError -> action) -> Eff model action
fetchUndoPreview snapshotId onOk onErr =
    requestGetJson (ApiUndoPreview snapshotId) onOk onErr

runUndo :: Int -> (UndoResult -> action) -> (ApiError -> action) -> Eff model action
runUndo snapshotId onOk onErr =
    requestWriteValue
        ApiRunUndo
        (Just (object ["snapshot_id" .= snapshotId]))
        decodeResponseAt
        onOk
        onErr

markLinkAlive :: Int -> action -> (ApiError -> action) -> Eff model action
markLinkAlive bid =
    apiWriteRequest (ApiMarkLinkAlive bid) (Nothing :: Maybe Value)

recheckLink :: Int -> action -> (ApiError -> action) -> Eff model action
recheckLink bid =
    apiWriteRequest (ApiRecheckLink bid) (Nothing :: Maybe Value)

regenerateRecovery :: ([Text] -> action) -> (ApiError -> action) -> Eff model action
regenerateRecovery onOk onErr =
    requestWriteValue
        ApiRegenerateRecovery
        (Nothing :: Maybe Value)
        (\endpoint value -> decodeListFieldAt endpoint "codes" value)
        onOk
        onErr

renameCredential :: Text -> Text -> action -> (ApiError -> action) -> Eff model action
renameCredential cid nickname =
    apiWriteRequest (ApiRenameCredential cid) (Just (object ["nickname" .= nickname]))

deleteCredential :: Text -> action -> (ApiError -> action) -> Eff model action
deleteCredential cid = apiDeleteRequest (ApiDeleteCredential cid)
patchUsername :: Maybe Text -> Text -> action -> (ApiError -> action) -> Eff model action
patchUsername currentPassword username =
    apiWriteRequest ApiPatchUsername (Just payload)
  where
    payload =
        object
            ( ["username" .= username]
                ++ [ "current_password" .= value
                   | Just value <- [currentPassword]
                   ]
            )
changePassword ::
    Maybe Text ->
    Text ->
    Text ->
    action ->
    (ApiError -> action) ->
    Eff model action
changePassword currentPassword newPassword confirm =
    apiWriteRequest ApiChangePassword (Just payload)
  where
    payload =
        object
            ( ["new_password" .= newPassword, "confirm" .= confirm]
                ++ [ "current_password" .= value
                   | Just value <- [currentPassword]
                   ]
            )
setPasskeyRequirement ::
    Bool ->
    Maybe Text ->
    action ->
    (ApiError -> action) ->
    Eff model action
setPasskeyRequirement required currentPassword =
    apiWriteRequest ApiSetPasskeyRequirement (Just payload)
  where
    payload =
        object
            ( ["required" .= required]
                ++ [ "current_password" .= value
                   | Just value <- [currentPassword]
                   ]
            )
revokeOtherSessions :: (Int -> action) -> (ApiError -> action) -> Eff model action
revokeOtherSessions onOk onErr =
    requestWriteValue
        ApiRevokeOtherSessions
        (Nothing :: Maybe Value)
        (\endpoint value -> decodeIntFieldAt endpoint "revoked" value)
        onOk
        onErr

logout :: action -> (ApiError -> action) -> Eff model action
logout = apiWriteRequest ApiLogout (Nothing :: Maybe Value)
submitImport ::
    (ImportResponse -> action) ->
    (ApiError -> action) ->
    Eff model action
submitImport onOk onErr = withSink $ \sink -> do
    token <- csrfToken
    -- The file input and the multipart FormData live in the external
    -- @EzaNet.upload@ helper (static/pwa.js): the CSP forbids eval, so the
    -- client cannot build JavaScript at runtime.
    finish <- asyncCallback3 $ \statusValue textValue errorValue -> do
        statusNumber <- fromJSVal statusValue :: IO (Maybe Double)
        body <- fromMaybe "" <$> (fromJSVal textValue :: IO (Maybe MisoString))
        transportError <- fromMaybe "" <$> (fromJSVal errorValue :: IO (Maybe MisoString))
        let status = maybe 0 round statusNumber
        sink $ case rawOutcome endpoint JSON (rawResponse status body transportError) of
            Left err -> onErr err
            Right value -> either onErr onOk (decodeResponseAt endpoint value)
    net <- jsg ("EzaNet" :: MisoString)
    inputId <- toJSVal ("import-file" :: MisoString)
    tokenValue <- toJSVal token
    _ <- net # ("upload" :: MisoString) $ (inputId, tokenValue, finish)
    pure ()
  where
    -- The multipart transport lives in pwa.js; the endpoint label still comes
    -- from the shared request table.
    endpoint = requestUrl ApiSubmitImport

-- ------------------------------------------------------------------ bulk --

-- | Bulk bookmark mutations (selection bar).
data BulkAction
    = BulkAddTags [Text]
    | BulkRemoveTags [Text]
    | BulkMarkRead Bool
    | BulkDelete
    deriving (Eq, Show)

{- | @POST /api/v1/bookmarks/bulk@ — one undo snapshot, one response with the
number of updated rows.
-}
bulkUpdate ::
    BulkAction ->
    [Int] ->
    (Int -> action) ->
    (ApiError -> action) ->
    Eff model action
bulkUpdate bulkAction ids onOk onErr =
    requestWriteValue
        ApiBulkUpdate
        (Just (object fields))
        (\endpoint value -> decodeIntFieldAt endpoint "updated" value)
        onOk
        onErr
  where
    fields = case bulkAction of
        BulkAddTags tags -> base "add_tags" <> [("tags" .= tags)]
        BulkRemoveTags tags -> base "remove_tags" <> [("tags" .= tags)]
        BulkMarkRead True -> base "mark_read"
        BulkMarkRead False -> base "mark_unread"
        BulkDelete -> base "delete" <> [("confirm" .= True)]
    base name =
        [ "action" .= (name :: Text)
        , "ids" .= ids
        ]

fetchTokens ::
    ([TokenView] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchTokens onOk onErr =
    requestGet ApiTokens (\url value -> decodeListFieldAt url "tokens" value) onOk onErr

-- | @POST /api/v1/tokens@ — returns the raw token once plus its metadata.
createApiToken ::
    Text ->
    [Text] ->
    (Text -> TokenView -> action) ->
    (ApiError -> action) ->
    Eff model action
createApiToken name scopes onOk onErr =
    requestWriteValue
        ApiCreateApiToken
        (Just (object ["name" .= name, "scopes" .= scopes]))
        decodeResponseAt
        (\response -> onOk (tcrToken response) (tcrTokenInfo response))
        onErr

revokeApiToken :: Int -> action -> (ApiError -> action) -> Eff model action
revokeApiToken tokenId = apiDeleteRequest (ApiRevokeApiToken tokenId)
fetchHighlights ::
    Int ->
    ([Highlight] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchHighlights bookmarkId onOk onErr =
    requestGet (ApiHighlights bookmarkId) (\url value -> decodeListFieldAt url "highlights" value) onOk onErr

{- | @POST /api/v1/bookmarks/{id}/highlights@ — offsets are character offsets
into the extracted text; prefix/suffix are the server's drift anchors.
-}
createHighlight ::
    Int ->
    Text ->
    Text ->
    Text ->
    Int ->
    Int ->
    Text ->
    Text ->
    (Highlight -> action) ->
    (ApiError -> action) ->
    Eff model action
createHighlight bookmarkId quote prefix suffix startOffset endOffset note color onOk onErr =
    requestWriteValue
        (ApiCreateHighlight bookmarkId)
        (Just (object fields))
        decodeResponseAt
        onOk
        onErr
  where
    fields =
        [ "quote" .= quote
        , "prefix" .= prefix
        , "suffix" .= suffix
        , "start_offset" .= startOffset
        , "end_offset" .= endOffset
        , "note" .= note
        , "color" .= color
        ]

patchHighlight ::
    Int ->
    Int ->
    (Maybe Text) ->
    (Maybe Text) ->
    action ->
    (ApiError -> action) ->
    Eff model action
patchHighlight bookmarkId highlightId note color onOk onErr =
    apiWriteRequest
        (ApiPatchHighlight bookmarkId highlightId)
        (Just payload)
        onOk
        onErr
  where
    payload =
        object
            ( [("note" .= value) | Just value <- [note]]
                ++ [("color" .= value) | Just value <- [color]]
            )
deleteHighlight ::
    Int ->
    Int ->
    action ->
    (ApiError -> action) ->
    Eff model action
deleteHighlight bookmarkId highlightId onOk onErr =
    apiDeleteRequest (ApiDeleteHighlight bookmarkId highlightId) onOk onErr
fetchShares ::
    ([ShareView] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchShares onOk onErr =
    requestGet ApiShares (\url value -> decodeListFieldAt url "shares" value) onOk onErr

{- | @POST /api/v1/share-links@ — returns the share id and the public URL
(the raw token is only ever shown here).
-}
createShareLink ::
    Text ->
    Int ->
    Bool ->
    Int ->
    (Int -> Text -> action) ->
    (ApiError -> action) ->
    Eff model action
createShareLink scope targetId includeNote expiresInDays onOk onErr =
    requestWriteValue
        ApiCreateShareLink
        ( Just
            ( object
                [ "scope" .= scope
                , "target_id" .= targetId
                , "include_note" .= includeNote
                , "expires_in_days" .= expiresInDays
                ]
            )
        )
        decodeResponseAt
        (\response -> onOk (scrId response) (scrUrl response))
        onErr

revokeShareLink :: Int -> action -> (ApiError -> action) -> Eff model action
revokeShareLink shareId = apiDeleteRequest (ApiRevokeShareLink shareId)
fetchAiStatus ::
    (AiStatus -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchAiStatus = requestGetJson ApiAiStatus

-- ----------------------------------------------------------------- rules ---

-- | @GET /api/v1/rules@
fetchRules ::
    ([Rule] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchRules onOk onErr =
    requestGet ApiRules (\url value -> decodeListFieldAt url "rules" value) onOk onErr

ruleBody :: Text -> Bool -> Text -> Text -> [Text] -> Bool -> Value
ruleBody name enabled field patternText addTags markRead =
    object
        [ "name" .= name
        , "enabled" .= enabled
        , "field" .= field
        , "pattern" .= patternText
        , "add_tags" .= addTags
        , "mark_read" .= markRead
        ]

-- | @POST /api/v1/rules@
createRule ::
    Text ->
    Bool ->
    Text ->
    Text ->
    [Text] ->
    Bool ->
    (Rule -> action) ->
    (ApiError -> action) ->
    Eff model action
createRule name enabled field patternText addTags markRead onOk onErr =
    requestWriteValue
        ApiCreateRule
        (Just (ruleBody name enabled field patternText addTags markRead))
        decodeResponseAt
        onOk
        onErr

patchRule ::
    Int ->
    Rule ->
    action ->
    (ApiError -> action) ->
    Eff model action
patchRule ruleId rule onOk onErr =
    apiWriteRequest (ApiPatchRule ruleId) (Just body) onOk onErr
  where
    body =
        ruleBody
            (ruleName rule)
            (ruleEnabled rule)
            (ruleField rule)
            (rulePattern rule)
            (ruleAddTags rule)
            (ruleMarkRead rule)
deleteRule :: Int -> action -> (ApiError -> action) -> Eff model action
deleteRule ruleId = apiDeleteRequest (ApiDeleteRule ruleId)
testRule ::
    Text ->
    Text ->
    (Int -> [Int] -> action) ->
    (ApiError -> action) ->
    Eff model action
testRule field patternText onOk onErr =
    requestWriteValue
        ApiTestRule
        (Just (ruleBody "" True field patternText [] False))
        decodeResponseAt
        (\response -> onOk (rtrMatches response) (rtrBookmarkIds response))
        onErr

exportUrl :: Text
exportUrl = toText (requestUrl ApiExport)

-- | The JSON export download the views page links to.
exportJsonUrl :: Text
exportJsonUrl = toText (requestUrl ApiExport) <> "?format=json"

notesExportUrl :: Text
notesExportUrl = toText (requestUrl ApiExportNotes)

-- | The reading-copy download link for one record (a GET navigation).
bookmarkSnapshotUrl :: Int -> Text
bookmarkSnapshotUrl bookmarkId = toText (requestUrl (ApiBookmarkAction bookmarkId "snapshot"))
