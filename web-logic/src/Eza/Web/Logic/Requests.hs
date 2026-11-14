{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The client request surface: every JSON endpoint the Miso client calls, as
native functions the pure update reducers emit as 'Effect' values.

The HTTP exchange itself lives in the shell ("Eza.Web.Transport"): a reducer
only says which 'ClientRequest' to send, which JSON body to send, and what
'Action' answers the response. The success continuation receives the response
body as a 'Value' because decoding is pure; the typed helpers here decode with
the shared core instances and report an 'ApiError' that names the endpoint.

This module replaces the old @Eza.Web.Api@, which had to live in the shell
because it performed the exchange itself. Keep it free of Miso and JSFFI: it
is native-buildable and tested by @eza-web-logic-test@.
-}
module Eza.Web.Logic.Requests (
    -- * Transport surface used by the reducers
    requestGet,
    requestGetJson,
    requestWriteJson,
    requestWriteValue,
    requestWriteNone,
    requestDeleteNone,
    requestUrl,
    percentEncode,
    decodeResponseAt,
    decodeStatsAt,
    submitImportRequest,

    -- * Shared wire values
    WebhookTest (..),
    ImportResponse (..),
    ListParams (..),
    defaultListParams,

    -- * Local wire records
    QuickSaveResponse (..),
    BookmarkPatchResponse (..),
    MergeResponse (..),
    CheckDeadResponse (..),
    RuleTestResponse (..),
    TokenCreatedResponse (..),
    ShareCreatedResponse (..),
    SuggestionsResponse (..),
    WebhookCreatedResponse (..),
    ViewPatch (..),
    BulkAction (..),

    -- * Reads
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
    fetchWebhooks,
    fetchWebhook,
    fetchWebhookDeliveries,
    fetchAdminUsers,
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
    fetchUndoEntries,
    fetchUndoPreview,

    -- * Writes
    createBookmark,
    quickSave,
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
    patchBookmarkWithResult,
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
    runUndo,
    markLinkAlive,
    recheckLink,
    regenerateRecovery,
    renameCredential,
    deleteCredential,
    patchUsername,
    changePassword,
    setPasskeyRequirement,
    revokeOtherSessions,
    logout,
    submitImport,
    createWebhook,
    updateWebhook,
    deleteWebhook,
    testWebhook,
    createAdminUser,
    patchAdminUser,
    resetAdminPassword,
    deleteAdminUser,
    createView,
    patchView,
    deleteView,

    -- * Download links
    exportUrl,
    exportJsonUrl,
    notesExportUrl,
    bookmarkSnapshotUrl,
) where

import Data.Aeson (FromJSON (..), ToJSON, Value (..), object, toJSON, withObject, (.:), (.:?), (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseMaybe, (.!=))
import Data.Text (Text)
import qualified Data.Text as T

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
import Eza.Webhook (DeliveryView, Webhook, WebhookInput (..))

import Eza.Web.Logic.Api (BookmarkListQuery (..), ClientRequest (..), DedupCandidateQuery (..), requestMethod, requestPath)
import Eza.Web.Logic.Effect (Effect (..))
import Eza.Web.Logic.Error (ApiError (..), mkApiError)
import Eza.Web.Logic.Model (Action)
import qualified Eza.Web.Logic.Route as ClientRoute
import Eza.Web.Logic.Update.Monad (Update, emit)
import Eza.Web.Logic.Wire (ImportResponse (..), ListParams (..), WebhookTest (..), defaultListParams)

-- --------------------------------------------------------------- transport ---

{- | Send one request. The continuation receives the transport outcome (an
'Either' because a failed request is part of the answer, not an exception) so
the decoding stays in the reducer.
-}
requestGet ::
    ClientRequest ->
    (Text -> Value -> Either ApiError a) ->
    (a -> Action) ->
    (ApiError -> Action) ->
    Update ()
requestGet request decodeResponse onOk onErr =
    emit
        ( ApiRequest request Nothing $ \result -> case result of
            Left err -> onErr err
            Right value -> either onErr onOk (decodeResponse (requestPath request) value)
        )

requestGetJson ::
    (FromJSON a) =>
    ClientRequest ->
    (a -> Action) ->
    (ApiError -> Action) ->
    Update ()
requestGetJson request = requestGet request (\endpoint value -> decodeResponseAt endpoint value)

requestWriteJson ::
    (ToJSON b, FromJSON a) =>
    ClientRequest ->
    Maybe b ->
    (a -> Action) ->
    (ApiError -> Action) ->
    Update ()
requestWriteJson request requestBody onOk onErr =
    emit
        ( ApiRequest request (toJSON <$> requestBody) $ \result -> case result of
            Left err -> onErr err
            Right value -> either onErr onOk (decodeResponseAt (requestPath request) value)
        )

requestWriteValue ::
    (ToJSON b) =>
    ClientRequest ->
    Maybe b ->
    (Text -> Value -> Either ApiError a) ->
    (a -> Action) ->
    (ApiError -> Action) ->
    Update ()
requestWriteValue request requestBody decodeResponse onOk onErr =
    emit
        ( ApiRequest request (toJSON <$> requestBody) $ \result -> case result of
            Left err -> onErr err
            Right value -> either onErr onOk (decodeResponse (requestPath request) value)
        )

requestWriteNone ::
    (ToJSON b) =>
    ClientRequest ->
    Maybe b ->
    Action ->
    (ApiError -> Action) ->
    Update ()
requestWriteNone request requestBody onOk onErr =
    emit (ApiRequest request (toJSON <$> requestBody) $ \result -> either onErr (const onOk) result)

requestDeleteNone :: ClientRequest -> Action -> (ApiError -> Action) -> Update ()
requestDeleteNone request onOk onErr =
    emit (ApiRequest request Nothing $ \result -> either onErr (const onOk) result)

{- | The concrete path of a request, also used as the endpoint label in
client-side decode errors.
-}
requestUrl :: ClientRequest -> Text
requestUrl = requestPath

{- | The request the multipart import upload uses; the shell transport needs
its path for the endpoint label.
-}
submitImportRequest :: ClientRequest
submitImportRequest = ApiSubmitImport

{- | Percent-encode a string for a URL component. The implementation lives in
the native route module.
-}
percentEncode :: Text -> Text
percentEncode = ClientRoute.percentEncode

-- ------------------------------------------------------------- decoders ---

bodyError :: Text -> Text -> ApiError
bodyError endpoint detail =
    mkApiError
        Nothing
        (Just ("The response from " <> describeEndpoint endpoint <> " could not be read: " <> detail))

describeEndpoint :: Text -> Text
describeEndpoint endpoint
    | T.null label = "the server"
    | otherwise = label
  where
    label = T.strip endpoint

decodeResponseAt :: (FromJSON a) => Text -> Value -> Either ApiError a
decodeResponseAt endpoint value =
    case A.fromJSON value of
        A.Success a -> Right a
        A.Error errorText -> Left (bodyError endpoint (T.pack errorText))

{- | Read one JSON number field that an endpoint always sends. A missing or
mistyped field is an 'ApiError' that names the endpoint, never a zero.
-}
decodeIntFieldAt :: Text -> Text -> Value -> Either ApiError Int
decodeIntFieldAt endpoint key value =
    case parseMaybe (withObject "response" (\o -> o .: K.fromText key)) value of
        Just number -> Right number
        Nothing -> Left (missingFieldError endpoint key)

{- | Read the one array field an endpoint wraps its rows in. The wrapper key
must be present, and every element must decode as its shared core type.
-}
decodeListFieldAt :: (FromJSON a) => Text -> Text -> Value -> Either ApiError [a]
decodeListFieldAt endpoint key value =
    case parseMaybe (withObject "response" (\o -> o .: K.fromText key)) value of
        Just rows -> Right rows
        Nothing -> Left (missingFieldError endpoint key)

missingFieldError :: Text -> Text -> ApiError
missingFieldError endpoint key =
    mkApiError
        Nothing
        (Just ("The response from " <> describeEndpoint endpoint <> " has no valid \"" <> key <> "\" field."))

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
decodeStatsAt :: Text -> Value -> Either ApiError LibraryStats
decodeStatsAt endpoint value =
    case parseMaybe statsParser value of
        Just stats -> Right stats
        Nothing -> Left (bodyError endpoint "the stats payload is missing a field")
  where
    statsParser =
        A.withObject "LibraryStats" $ \o ->
            LibraryStats
                <$> o .: "bookmarks"
                <*> o .: "tags"
                <*> o .: "bookmark_tags"
                <*> o .: "sources"
                <*> o .: "top_sources"
                <*> o .: "sources_once"
                <*> o .: "first_day"
                <*> o .: "last_day"
                <*> o .: "days"
                <*> o .: "years"
                <*> o .: "filing_days"
                <*> o .: "unread"
                <*> o .: "dead"
                <*> o .: "jobs_pending"
                <*> o .: "favicon_bytes"
                <*> o .: "highlights"
                <*> o .: "shares"

{- | The import response. Both the Netscape parser and the JSON-export path
answer with the summary counts @inserted@, @found@ and @existing@; the full
'Eza.Types.ImportReport' is only present for the Netscape file flow.
-}

-- ------------------------------------------------------------------ reads --

fetchBoot :: (BootPayload -> Action) -> (ApiError -> Action) -> Update ()
fetchBoot = requestGetJson ApiBoot

fetchBookmarks ::
    ListParams ->
    (SearchPage -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchBookmarks lp = fetchBookmarksQuery (listQuery lp)

{- | Fetch one ledger page from the native request record. The native ledger
reducer emits the request it wants; this is the bridge point between that
record and the shared JSON transport. 'fetchBookmarks' keeps the 'ListParams'
surface for the select-all paging chain, which is still shell-side.
-}
fetchBookmarksQuery ::
    BookmarkListQuery ->
    (SearchPage -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchBookmarksQuery query = requestGetJson (ApiBookmarks query)

fetchDetail ::
    Int ->
    (BookmarkDetail -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchDetail bid = requestGetJson (ApiBookmark bid)

-- | Linked + unlinked backlinks as one flat list.
fetchBacklinks ::
    Int ->
    ([Backlink] -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchBacklinks bid onOk onErr =
    requestGet (ApiBookmarkBacklinks bid) decode onOk onErr
  where
    decode endpoint value = fmap flatten (decodeResponseAt endpoint value)
    flatten bks = bksLinked bks ++ bksUnlinked bks

fetchAutocomplete ::
    Text ->
    ([BookmarkSummary] -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchAutocomplete q onOk onErr =
    requestGet (ApiAutocomplete q) (\endpoint value -> decodeListFieldAt endpoint "items" value) onOk onErr

fetchGraph ::
    (GraphData -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchGraph = requestGetJson ApiGraph

{- | The server-built layout for one preset. The payload is the shared
'GraphLayoutWire': @{schema, revision, preset, tags, records, bounds}@ with
positions quantized to 1/100 world unit. The client validates the revision
against 'gdRevision' before hydrating.
-}
fetchGraphLayout ::
    LayoutPreset ->
    (GraphLayoutWire -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchGraphLayout preset onOk onErr =
    requestGet (ApiGraphLayout preset) (\endpoint value -> decodeResponseAt endpoint value) onOk onErr

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

fetchViews :: ([EV.View] -> Action) -> (ApiError -> Action) -> Update ()
fetchViews onOk onErr =
    requestGet ApiViews (\endpoint value -> decodeListFieldAt endpoint "views" value) onOk onErr

fetchView :: Text -> (EV.View -> Action) -> (ApiError -> Action) -> Update ()
fetchView slug onOk onErr =
    requestGetJson (ApiView slug) onOk onErr

createView :: EV.ViewInput -> (EV.View -> Action) -> (ApiError -> Action) -> Update ()
createView input onOk onErr =
    requestWriteJson ApiCreateView (Just input) onOk onErr

patchView :: Text -> ViewPatch -> (EV.View -> Action) -> (ApiError -> Action) -> Update ()
patchView slug patch onOk onErr =
    requestWriteJson (ApiPatchView slug) (Just patch) onOk onErr

deleteView :: Text -> Action -> (ApiError -> Action) -> Update ()
deleteView slug = requestDeleteNone (ApiDeleteView slug)

{- | Account webhooks. Management is session-only on the server; a bearer
token gets 403 @session_required@. The create response is the only place the
64-hex secret ever appears.
-}
fetchWebhooks :: ([Webhook] -> Action) -> (ApiError -> Action) -> Update ()
fetchWebhooks onOk onErr =
    requestGet ApiWebhooks (\endpoint value -> decodeListFieldAt endpoint "webhooks" value) onOk onErr

fetchWebhook :: Int -> (Webhook -> Action) -> (ApiError -> Action) -> Update ()
fetchWebhook webhookId = requestGetJson (ApiWebhook webhookId)

createWebhook ::
    WebhookInput ->
    ((Webhook, Text) -> Action) ->
    (ApiError -> Action) ->
    Update ()
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
    (Webhook -> Action) ->
    (ApiError -> Action) ->
    Update ()
updateWebhook webhookId input onOk onErr =
    requestWriteJson (ApiPatchWebhook webhookId) (Just input) onOk onErr

deleteWebhook :: Int -> Action -> (ApiError -> Action) -> Update ()
deleteWebhook webhookId = requestDeleteNone (ApiDeleteWebhook webhookId)

testWebhook :: Int -> (WebhookTest -> Action) -> (ApiError -> Action) -> Update ()
testWebhook webhookId onOk onErr =
    requestWriteValue
        (ApiTestWebhook webhookId)
        (Nothing :: Maybe Value)
        decodeResponseAt
        onOk
        onErr

fetchWebhookDeliveries :: Int -> ([DeliveryView] -> Action) -> (ApiError -> Action) -> Update ()
fetchWebhookDeliveries webhookId onOk onErr =
    requestGet (ApiWebhookDeliveries webhookId) (\endpoint value -> decodeListFieldAt endpoint "deliveries" value) onOk onErr

fetchAdminUsers :: ([UserView] -> Action) -> (ApiError -> Action) -> Update ()
fetchAdminUsers onOk onErr =
    requestGet ApiAdminUsers (\endpoint value -> decodeListFieldAt endpoint "users" value) onOk onErr

createAdminUser ::
    UserCreateInput ->
    (UserCreateResult -> Action) ->
    (ApiError -> Action) ->
    Update ()
createAdminUser input onOk onErr =
    requestWriteJson ApiCreateAdminUser (Just input) onOk onErr
patchAdminUser ::
    Int ->
    Maybe Bool ->
    Maybe UserRole ->
    (UserView -> Action) ->
    (ApiError -> Action) ->
    Update ()
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
    Action ->
    (ApiError -> Action) ->
    Update ()
resetAdminPassword userId password onOk onErr =
    requestWriteNone (ApiResetAdminPassword userId) (Just (object ["password" .= password])) onOk onErr
deleteAdminUser ::
    Int ->
    Bool ->
    Action ->
    (ApiError -> Action) ->
    Update ()
deleteAdminUser userId deleteDb onOk onErr =
    requestWriteNone
        (ApiDeleteAdminUser userId)
        (Just (object ["confirm" .= True, "delete_db" .= deleteDb]))
        onOk
        onErr

fetchSavedSearches ::
    ([SavedSearch] -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchSavedSearches onOk onErr =
    requestGet ApiSavedSearches (\endpoint value -> decodeListFieldAt endpoint "saved_searches" value) onOk onErr

{- | One page of duplicate candidates. The two sections carry independent
offsets and limits, and the report repeats the exact whole-library counts on
every page, so the client never sums loaded groups to invent a total.
-}
fetchDedupReport ::
    Int ->
    Int ->
    Int ->
    Int ->
    (DedupReport -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchDedupReport urlOffset urlLimit titleOffset titleLimit onOk onErr =
    requestGet request (\endpoint value -> decodeResponseAt endpoint value) onOk onErr
  where
    request =
        ApiDedupCandidates (DedupCandidateQuery urlOffset urlLimit titleOffset titleLimit)

{- | The confirmed one-shot merge of every same-URL group. The server writes
one undo snapshot and answers the report the interface shows.
-}
mergeDedupAll :: (DedupMergeAllReport -> Action) -> (ApiError -> Action) -> Update ()
mergeDedupAll onOk onErr =
    requestWriteJson ApiMergeDedupAll (Just (object ["confirm" .= True])) onOk onErr

fetchConsolidation ::
    ([ConsolidationGroup] -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchConsolidation onOk onErr =
    requestGet ApiTagConsolidationCandidates (\endpoint value -> decodeListFieldAt endpoint "groups" value) onOk onErr

{- | @GET /api/v1/tags/{tag}/suggestions@. The server answers an unconfigured
provider with 200, an empty list and a notice; hand the suggestions and the
notice to the caller so the page can say what happened instead of showing an
empty result that looks like a clean scan.
-}
fetchSuggestions ::
    Text ->
    ([TagSuggestion] -> Maybe Text -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchSuggestions tag onOk onErr =
    requestGet (ApiTagSuggestions tag) decode onOk' onErr
  where
    decode endpoint value =
        fmap (\response -> (sgrSuggestions response, sgrNotice response)) (decodeResponseAt endpoint value)
    onOk' (suggestions, notice) = onOk suggestions notice

fetchPruneCandidates ::
    ([BookmarkSummary] -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchPruneCandidates onOk onErr =
    requestGet ApiMaintenancePruneCandidates (\endpoint value -> decodeListFieldAt endpoint "items" value) onOk onErr

fetchAccount ::
    (AccountInfo -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchAccount = requestGetJson ApiAccount

fetchTags ::
    ([TagStat] -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchTags onOk onErr =
    requestGet ApiTags (\endpoint value -> decodeListFieldAt endpoint "tags" value) onOk onErr

{- | @GET /api/v1/stats@ — the whole library count read again after a write.
The API renames three fields of the shared 'LibraryStats' and adds @links@, so
the payload decodes onto a local wire record and converts to the shared type.
-}
fetchStats ::
    (LibraryStats -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchStats onOk onErr =
    requestGet ApiStats (\endpoint value -> decodeStatsAt endpoint value) onOk onErr

-- ----------------------------------------------------------------- writes --

createBookmark ::
    Text ->
    Text ->
    [Text] ->
    (Int -> Action) ->
    (ApiError -> Action) ->
    Update ()
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
    (Int -> Bool -> Action) ->
    (ApiError -> Action) ->
    Update ()
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
    Action ->
    (ApiError -> Action) ->
    Update ()
patchBookmark bid payload =
    requestWriteNone (ApiPatchBookmark bid) (Just payload)
patchBookmarkWithResult ::
    Int ->
    Value ->
    (Int -> Action) ->
    (ApiError -> Action) ->
    Update ()
patchBookmarkWithResult bid payload onOk onErr =
    requestWriteValue
        (ApiPatchBookmark bid)
        (Just payload)
        decodeResponseAt
        (onOk . bprHighlightsRemoved)
        onErr

deleteBookmark :: Int -> Action -> (ApiError -> Action) -> Update ()
deleteBookmark bid = requestDeleteNone (ApiDeleteBookmark bid)

markAllAbove ::
    Maybe Int ->
    (Int -> Action) ->
    (ApiError -> Action) ->
    Update ()
markAllAbove aboveId onOk onErr =
    requestWriteValue
        ApiMarkAllAbove
        (Just (object ["above_id" .= aboveId]))
        (\endpoint value -> decodeIntFieldAt endpoint "updated" value)
        onOk
        onErr

trackOpen :: Int -> Action -> (ApiError -> Action) -> Update ()
trackOpen bid =
    requestWriteNone (ApiTrackOpen bid) (Nothing :: Maybe Value)
bookmarkAction :: Int -> Text -> Action -> (ApiError -> Action) -> Update ()
bookmarkAction bid verb =
    requestWriteNone (ApiBookmarkAction bid verb) (Nothing :: Maybe Value)

saveSavedSearch ::
    Text ->
    Text ->
    [Text] ->
    (Int -> Action) ->
    (ApiError -> Action) ->
    Update ()
saveSavedSearch name q tags onOk onErr =
    requestWriteValue
        ApiCreateSavedSearch
        (Just (object ["name" .= name, "q" .= q, "tags" .= tags]))
        (\endpoint value -> decodeIntFieldAt endpoint "id" value)
        onOk
        onErr

deleteSavedSearch :: Int -> Action -> (ApiError -> Action) -> Update ()
deleteSavedSearch sid = requestDeleteNone (ApiDeleteSavedSearch sid)

mergeDedup ::
    Int ->
    [Int] ->
    ((Int, Int) -> Action) ->
    (ApiError -> Action) ->
    Update ()
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
    Action ->
    (ApiError -> Action) ->
    Update ()
mergeTags from into =
    requestWriteNone ApiMergeTags (Just (object ["from" .= from, "into" .= into]))

renameTag :: Text -> Text -> Action -> (ApiError -> Action) -> Update ()
renameTag old newName =
    requestWriteNone (ApiRenameTag old) (Just (object ["name" .= newName]))

deleteTag :: Text -> Action -> (ApiError -> Action) -> Update ()
deleteTag tag = requestDeleteNone (ApiDeleteTag tag)
detachTag :: Text -> Action -> (ApiError -> Action) -> Update ()
detachTag tag = requestDeleteNone (ApiDetachTag tag)

applyTagSuggestion ::
    Int ->
    [Text] ->
    Action ->
    (ApiError -> Action) ->
    Update ()
applyTagSuggestion bid tags =
    requestWriteNone
        ApiApplyTagSuggestion
        (Just (object ["bookmark_id" .= bid, "tags" .= tags]))

runPrune :: [Int] -> (Int -> Action) -> (ApiError -> Action) -> Update ()
runPrune ids onOk onErr =
    requestWriteValue
        ApiRunPrune
        (Just (object ["ids" .= ids]))
        (\endpoint value -> decodeIntFieldAt endpoint "pruned" value)
        onOk
        onErr

checkDead :: ((Int, Int, Int) -> Action) -> (ApiError -> Action) -> Update ()
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

fetchUndoEntries :: ([UndoEntry] -> Action) -> (ApiError -> Action) -> Update ()
fetchUndoEntries onOk onErr =
    requestGet ApiUndoEntries (\endpoint value -> decodeListFieldAt endpoint "entries" value) onOk onErr

fetchUndoPreview :: Int -> (UndoPreview -> Action) -> (ApiError -> Action) -> Update ()
fetchUndoPreview snapshotId onOk onErr =
    requestGetJson (ApiUndoPreview snapshotId) onOk onErr

runUndo :: Int -> (UndoResult -> Action) -> (ApiError -> Action) -> Update ()
runUndo snapshotId onOk onErr =
    requestWriteValue
        ApiRunUndo
        (Just (object ["snapshot_id" .= snapshotId]))
        decodeResponseAt
        onOk
        onErr

markLinkAlive :: Int -> Action -> (ApiError -> Action) -> Update ()
markLinkAlive bid =
    requestWriteNone (ApiMarkLinkAlive bid) (Nothing :: Maybe Value)

recheckLink :: Int -> Action -> (ApiError -> Action) -> Update ()
recheckLink bid =
    requestWriteNone (ApiRecheckLink bid) (Nothing :: Maybe Value)

regenerateRecovery :: ([Text] -> Action) -> (ApiError -> Action) -> Update ()
regenerateRecovery onOk onErr =
    requestWriteValue
        ApiRegenerateRecovery
        (Nothing :: Maybe Value)
        (\endpoint value -> decodeListFieldAt endpoint "codes" value)
        onOk
        onErr

renameCredential :: Text -> Text -> Action -> (ApiError -> Action) -> Update ()
renameCredential cid nickname =
    requestWriteNone (ApiRenameCredential cid) (Just (object ["nickname" .= nickname]))

deleteCredential :: Text -> Action -> (ApiError -> Action) -> Update ()
deleteCredential cid = requestDeleteNone (ApiDeleteCredential cid)
patchUsername :: Maybe Text -> Text -> Action -> (ApiError -> Action) -> Update ()
patchUsername currentPassword username =
    requestWriteNone ApiPatchUsername (Just payload)
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
    Action ->
    (ApiError -> Action) ->
    Update ()
changePassword currentPassword newPassword confirm =
    requestWriteNone ApiChangePassword (Just payload)
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
    Action ->
    (ApiError -> Action) ->
    Update ()
setPasskeyRequirement required currentPassword =
    requestWriteNone ApiSetPasskeyRequirement (Just payload)
  where
    payload =
        object
            ( ["required" .= required]
                ++ [ "current_password" .= value
                   | Just value <- [currentPassword]
                   ]
            )
revokeOtherSessions :: (Int -> Action) -> (ApiError -> Action) -> Update ()
revokeOtherSessions onOk onErr =
    requestWriteValue
        ApiRevokeOtherSessions
        (Nothing :: Maybe Value)
        (\endpoint value -> decodeIntFieldAt endpoint "revoked" value)
        onOk
        onErr

logout :: Action -> (ApiError -> Action) -> Update ()
logout = requestWriteNone ApiLogout (Nothing :: Maybe Value)
submitImport ::
    (ImportResponse -> Action) ->
    (ApiError -> Action) ->
    Update ()
submitImport onOk onErr = emit (OpSubmitImport onOk onErr)

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
    (Int -> Action) ->
    (ApiError -> Action) ->
    Update ()
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
    ([TokenView] -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchTokens onOk onErr =
    requestGet ApiTokens (\endpoint value -> decodeListFieldAt endpoint "tokens" value) onOk onErr

-- | @POST /api/v1/tokens@ — returns the raw token once plus its metadata.
createApiToken ::
    Text ->
    [Text] ->
    (Text -> TokenView -> Action) ->
    (ApiError -> Action) ->
    Update ()
createApiToken name scopes onOk onErr =
    requestWriteValue
        ApiCreateApiToken
        (Just (object ["name" .= name, "scopes" .= scopes]))
        decodeResponseAt
        (\response -> onOk (tcrToken response) (tcrTokenInfo response))
        onErr

revokeApiToken :: Int -> Action -> (ApiError -> Action) -> Update ()
revokeApiToken tokenId = requestDeleteNone (ApiRevokeApiToken tokenId)
fetchHighlights ::
    Int ->
    ([Highlight] -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchHighlights bookmarkId onOk onErr =
    requestGet (ApiHighlights bookmarkId) (\endpoint value -> decodeListFieldAt endpoint "highlights" value) onOk onErr

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
    (Highlight -> Action) ->
    (ApiError -> Action) ->
    Update ()
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
    Action ->
    (ApiError -> Action) ->
    Update ()
patchHighlight bookmarkId highlightId note color onOk onErr =
    requestWriteNone
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
    Action ->
    (ApiError -> Action) ->
    Update ()
deleteHighlight bookmarkId highlightId onOk onErr =
    requestDeleteNone (ApiDeleteHighlight bookmarkId highlightId) onOk onErr
fetchShares ::
    ([ShareView] -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchShares onOk onErr =
    requestGet ApiShares (\endpoint value -> decodeListFieldAt endpoint "shares" value) onOk onErr

{- | @POST /api/v1/share-links@ — returns the share id and the public URL
(the raw token is only ever shown here).
-}
createShareLink ::
    Text ->
    Int ->
    Bool ->
    Int ->
    (Int -> Text -> Action) ->
    (ApiError -> Action) ->
    Update ()
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

revokeShareLink :: Int -> Action -> (ApiError -> Action) -> Update ()
revokeShareLink shareId = requestDeleteNone (ApiRevokeShareLink shareId)
fetchAiStatus ::
    (AiStatus -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchAiStatus = requestGetJson ApiAiStatus

-- ----------------------------------------------------------------- rules ---

-- | @GET /api/v1/rules@
fetchRules ::
    ([Rule] -> Action) ->
    (ApiError -> Action) ->
    Update ()
fetchRules onOk onErr =
    requestGet ApiRules (\endpoint value -> decodeListFieldAt endpoint "rules" value) onOk onErr

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
    (Rule -> Action) ->
    (ApiError -> Action) ->
    Update ()
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
    Action ->
    (ApiError -> Action) ->
    Update ()
patchRule ruleId rule onOk onErr =
    requestWriteNone (ApiPatchRule ruleId) (Just body) onOk onErr
  where
    body =
        ruleBody
            (ruleName rule)
            (ruleEnabled rule)
            (ruleField rule)
            (rulePattern rule)
            (ruleAddTags rule)
            (ruleMarkRead rule)
deleteRule :: Int -> Action -> (ApiError -> Action) -> Update ()
deleteRule ruleId = requestDeleteNone (ApiDeleteRule ruleId)
testRule ::
    Text ->
    Text ->
    (Int -> [Int] -> Action) ->
    (ApiError -> Action) ->
    Update ()
testRule field patternText onOk onErr =
    requestWriteValue
        ApiTestRule
        (Just (ruleBody "" True field patternText [] False))
        decodeResponseAt
        (\response -> onOk (rtrMatches response) (rtrBookmarkIds response))
        onErr

exportUrl :: Text
exportUrl = requestUrl ApiExport

-- | The JSON export download the views page links to.
exportJsonUrl :: Text
exportJsonUrl = requestUrl ApiExport <> "?format=json"

notesExportUrl :: Text
notesExportUrl = requestUrl ApiExportNotes

-- | The reading-copy download link for one record (a GET navigation).
bookmarkSnapshotUrl :: Int -> Text
bookmarkSnapshotUrl bookmarkId = requestUrl (ApiBookmarkAction bookmarkId "snapshot")
