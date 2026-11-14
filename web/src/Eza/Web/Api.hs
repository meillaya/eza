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
    searchUrl,
    percentEncode,
    toText,
    fromText,
    -- reads
    fetchBoot,
    fetchBookmarks,
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
    notesExportUrl,
) where

import Data.Aeson (FromJSON (..), Result (..), ToJSON, Value (..), fromJSON, object, toJSON, withObject, (.:), (.:?), (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Char (chr, isAlphaNum, ord)
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
import Eza.GraphLayout (GraphLayoutWire, LayoutPreset (..), layoutPresetText)
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
    ImportReport,
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
    | T.null text = "the server"
    | otherwise = text
  where
    text = T.strip (toText endpoint)

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

apiGet ::
    (FromJSON a) =>
    MisoString ->
    (a -> action) ->
    (ApiError -> action) ->
    Eff model action
apiGet url onOk onErr =
    getValue url [] (\v -> either onErr onOk (decodeResponseAt url v)) onErr

getValue ::
    MisoString ->
    [(MisoString, MisoString)] ->
    (Value -> action) ->
    (ApiError -> action) ->
    Eff model action
getValue url headers = sendValue "GET" url Nothing headers JSON

-- | A write whose response body we do not care about.
apiWrite ::
    (ToJSON b) =>
    MisoString ->
    MisoString ->
    Maybe b ->
    action ->
    (ApiError -> action) ->
    Eff model action

{- | Writes whose response body the client never reads.  They use 'NONE':
the server answers most of them with @204 No Content@, and a JSON decode of
an empty 204 body would turn a successful write into an error.
-}
apiWrite method url requestBody onOk onErr =
    sendValue method url (toJSON <$> requestBody) [] NONE (\_ -> onOk) onErr

apiDelete :: MisoString -> action -> (ApiError -> action) -> Eff model action
apiDelete url onOk onErr =
    sendValue "DELETE" url Nothing [] NONE (\_ -> onOk) onErr

-- ------------------------------------------------------------- list query --

data ListParams = ListParams
    { lpQ :: MisoString
    , lpTags :: [Text]
    , lpSort :: Text
    , lpUnreadOnly :: Bool
    , lpOffset :: Int
    , lpLimit :: Int
    }
    deriving (Eq, Show)

defaultListParams :: ListParams
defaultListParams =
    ListParams
        { lpQ = ""
        , lpTags = []
        , lpSort = "created"
        , lpUnreadOnly = False
        , lpOffset = 0
        , lpLimit = 60
        }

-- | @GET /api/v1/bookmarks@ with the full filter set from the API contract.
searchUrl :: ListParams -> MisoString
searchUrl lp =
    "/api/v1/bookmarks?limit="
        <> ms (show (lpLimit lp))
        <> "&offset="
        <> ms (show (lpOffset lp))
        <> qPart
        <> tagsPart
        <> readPart
        <> sortPart
  where
    qPart
        | T.null (T.strip (toText (lpQ lp))) = ""
        | otherwise = "&q=" <> percentEncode (lpQ lp)
    tagsPart = case lpTags lp of
        [] -> ""
        ts -> "&tags=" <> ms (intercalateText "," (map (percentEncode . (ms :: Text -> MisoString)) ts))
    readPart = if lpUnreadOnly lp then "&is_read=0" else ""
    sortPart = "&sort=" <> percentEncode (ms (lpSort lp))
    intercalateText sep = T.intercalate sep . map toText

-- | Percent-encode a string for a URL query (UTF-8 bytes, RFC 3986).
percentEncode :: MisoString -> MisoString
percentEncode value = ms (concatMap encodeChar (fromMisoString value :: String))

encodeChar :: Char -> String
encodeChar c
    | isAlphaNum c || c `elem` ("-._~" :: String) = [c]
    | otherwise = concatMap hexByte (utf8 (ord c))
  where
    hexByte b = ['%', hexDigit (b `div` 16), hexDigit (b `mod` 16)]
    hexDigit n
        | n < 10 = chr (ord '0' + n)
        | otherwise = chr (ord 'A' + n - 10)

utf8 :: Int -> [Int]
utf8 n
    | n <= 0x7F = [n]
    | n <= 0x7FF = [0xC0 + n `div` 64, 0x80 + n `mod` 64]
    | n <= 0xFFFF =
        [ 0xE0 + n `div` 4096
        , 0x80 + (n `div` 64) `mod` 64
        , 0x80 + n `mod` 64
        ]
    | otherwise =
        [ 0xF0 + n `div` 262144
        , 0x80 + (n `div` 4096) `mod` 64
        , 0x80 + (n `div` 64) `mod` 64
        , 0x80 + n `mod` 64
        ]

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
data ImportResponse = ImportResponse
    { imrInserted :: Int
    , imrFound :: Int
    , imrExisting :: Int
    , imrReport :: Maybe ImportReport
    }
    deriving (Eq, Show)

instance FromJSON ImportResponse where
    parseJSON value = do
        (inserted, found, existing) <-
            withObject "import response" (\o -> (,,) <$> o .: "inserted" <*> o .: "found" <*> o .: "existing") value
        pure
            ImportResponse
                { imrInserted = inserted
                , imrFound = found
                , imrExisting = existing
                , imrReport = case fromJSON value :: Result ImportReport of
                    Success report -> Just report
                    Error _ -> Nothing
                }

-- ------------------------------------------------------------------ reads --

fetchBoot :: (BootPayload -> action) -> (ApiError -> action) -> Eff model action
fetchBoot = apiGet "/api/v1/boot"

fetchBookmarks ::
    ListParams ->
    (SearchPage -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchBookmarks lp = apiGet (searchUrl lp)

fetchDetail ::
    Int ->
    (BookmarkDetail -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchDetail bid = apiGet ("/api/v1/bookmarks/" <> ms (show bid))

-- | Linked + unlinked backlinks as one flat list.
fetchBacklinks ::
    Int ->
    ([Backlink] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchBacklinks bid onOk onErr =
    getValue url [] (either onErr (onOk . flatten) . decodeResponseAt url) onErr
  where
    url = "/api/v1/bookmarks/" <> ms (show bid) <> "/backlinks"
    flatten bks = bksLinked bks ++ bksUnlinked bks

fetchAutocomplete ::
    MisoString ->
    ([BookmarkSummary] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchAutocomplete q onOk onErr =
    getValue url [] (either onErr onOk . decodeListFieldAt url "items") onErr
  where
    url = "/api/v1/autocomplete?q=" <> percentEncode q

fetchGraph ::
    (GraphData -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchGraph = apiGet "/api/v1/graph"

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
    getValue url [] (either onErr onOk . decodeResponseAt url) onErr
  where
    url = "/api/v1/graph/layout?preset=" <> presetSlug preset

presetSlug :: LayoutPreset -> MisoString
presetSlug = ms . T.unpack . layoutPresetText

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
    getValue "/api/v1/views" [] (either onErr onOk . decodeListFieldAt "/api/v1/views" "views") onErr

fetchView :: Text -> (EV.View -> action) -> (ApiError -> action) -> Eff model action
fetchView slug onOk onErr =
    apiGet ("/api/v1/views/" <> percentEncode (ms (T.unpack slug))) onOk onErr

createView :: EV.ViewInput -> (EV.View -> action) -> (ApiError -> action) -> Eff model action
createView input onOk onErr =
    sendValue
        "POST"
        "/api/v1/views"
        (Just (toJSON input))
        []
        JSON
        (either onErr onOk . decodeResponseAt "/api/v1/views")
        onErr

patchView :: Text -> ViewPatch -> (EV.View -> action) -> (ApiError -> action) -> Eff model action
patchView slug patch onOk onErr =
    sendValue
        "PATCH"
        url
        (Just (toJSON patch))
        []
        JSON
        (either onErr onOk . decodeResponseAt url)
        onErr
  where
    url = "/api/v1/views/" <> percentEncode (ms (T.unpack slug))

deleteView :: Text -> action -> (ApiError -> action) -> Eff model action
deleteView slug =
    apiDelete ("/api/v1/views/" <> percentEncode (ms (T.unpack slug)))

{- | Account webhooks. Management is session-only on the server; a bearer
token gets 403 @session_required@. The create response is the only place the
64-hex secret ever appears.
-}
data WebhookTest = WebhookTest
    { wtOk :: Bool
    , wtStatus :: Maybe Int
    , wtError :: Text
    }
    deriving (Eq, Show)

instance FromJSON WebhookTest where
    parseJSON = withObject "webhook test" $ \o ->
        WebhookTest
            <$> o .: "ok"
            <*> o .:? "status"
            <*> o .: "error"

fetchWebhooks :: ([Webhook] -> action) -> (ApiError -> action) -> Eff model action
fetchWebhooks onOk onErr =
    getValue url [] (either onErr onOk . decodeListFieldAt url "webhooks") onErr
  where
    url = "/api/v1/webhooks"

fetchWebhook :: Int -> (Webhook -> action) -> (ApiError -> action) -> Eff model action
fetchWebhook webhookId = apiGet (webhookUrl webhookId)

createWebhook ::
    WebhookInput ->
    ((Webhook, Text) -> action) ->
    (ApiError -> action) ->
    Eff model action
createWebhook input onOk onErr =
    sendValue
        "POST"
        url
        (Just (toJSON input))
        []
        JSON
        (either onErr (\(wcr) -> onOk (wcrWebhook wcr, wcrSecret wcr)) . decodeResponseAt url)
        onErr
  where
    url = "/api/v1/webhooks"

updateWebhook ::
    Int ->
    WebhookInput ->
    (Webhook -> action) ->
    (ApiError -> action) ->
    Eff model action
updateWebhook webhookId input onOk onErr =
    sendValue
        "PATCH"
        url
        (Just (toJSON input))
        []
        JSON
        (either onErr onOk . decodeResponseAt url)
        onErr
  where
    url = webhookUrl webhookId

deleteWebhook :: Int -> action -> (ApiError -> action) -> Eff model action
deleteWebhook webhookId = apiDelete (webhookUrl webhookId)

testWebhook :: Int -> (WebhookTest -> action) -> (ApiError -> action) -> Eff model action
testWebhook webhookId onOk onErr =
    sendValue
        "POST"
        (webhookUrl webhookId <> "/test")
        (Nothing :: Maybe Value)
        []
        JSON
        (either onErr onOk . decodeResponseAt (webhookUrl webhookId <> "/test"))
        onErr

fetchWebhookDeliveries :: Int -> ([DeliveryView] -> action) -> (ApiError -> action) -> Eff model action
fetchWebhookDeliveries webhookId onOk onErr =
    getValue url [] (either onErr onOk . decodeListFieldAt url "deliveries") onErr
  where
    url = webhookUrl webhookId <> "/deliveries?limit=20"

webhookUrl :: Int -> MisoString
webhookUrl webhookId = "/api/v1/webhooks/" <> ms (show webhookId)

{- | Admin user management. The server admits only admin browser sessions
(Authz AdminClass); members get 403 @forbidden@ and bearer tokens 403
@session_required@. Recovery codes are revealed once on create.
-}
fetchAdminUsers :: ([UserView] -> action) -> (ApiError -> action) -> Eff model action
fetchAdminUsers onOk onErr =
    getValue url [] (either onErr onOk . decodeListFieldAt url "users") onErr
  where
    url = "/api/v1/admin/users"

createAdminUser ::
    UserCreateInput ->
    (UserCreateResult -> action) ->
    (ApiError -> action) ->
    Eff model action
createAdminUser input onOk onErr =
    sendValue
        "POST"
        "/api/v1/admin/users"
        (Just (toJSON input))
        []
        JSON
        (either onErr onOk . decodeResponseAt "/api/v1/admin/users")
        onErr

-- | Enable/disable or change a role. Absent fields keep their current value.
patchAdminUser ::
    Int ->
    Maybe Bool ->
    Maybe UserRole ->
    (UserView -> action) ->
    (ApiError -> action) ->
    Eff model action
patchAdminUser userId enabled role onOk onErr =
    sendValue
        "PATCH"
        url
        (Just (object (["enabled" .= value | Just value <- [enabled]] ++ ["role" .= value | Just value <- [role]])))
        []
        JSON
        (either onErr onOk . decodeResponseAt url)
        onErr
  where
    url = "/api/v1/admin/users/" <> ms (show userId)

{- | Break-glass temporary password. The server clears the target's 2FA flag
and revokes that user's sessions.
-}
resetAdminPassword ::
    Int ->
    Text ->
    action ->
    (ApiError -> action) ->
    Eff model action
resetAdminPassword userId password onOk onErr =
    apiWrite
        "POST"
        ("/api/v1/admin/users/" <> ms (show userId) <> "/password")
        (Just (object ["password" .= password]))
        onOk
        onErr

{- | Delete an account. The library and snapshots are removed only when
@deleteDb@ is set; the server refuses the last enabled admin and self-delete.
-}
deleteAdminUser ::
    Int ->
    Bool ->
    action ->
    (ApiError -> action) ->
    Eff model action
deleteAdminUser userId deleteDb onOk onErr =
    apiWrite
        "DELETE"
        ("/api/v1/admin/users/" <> ms (show userId))
        (Just (object ["confirm" .= True, "delete_db" .= deleteDb]))
        onOk
        onErr

fetchSavedSearches ::
    ([SavedSearch] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchSavedSearches onOk onErr =
    getValue url [] (either onErr onOk . decodeListFieldAt url "saved_searches") onErr
  where
    url = "/api/v1/saved-searches"

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
    getValue
        (dedupCandidatesUrl urlOffset urlLimit titleOffset titleLimit)
        []
        (\v -> either onErr onOk (decodeResponseAt (dedupCandidatesUrl urlOffset urlLimit titleOffset titleLimit) v))
        onErr

dedupCandidatesUrl :: Int -> Int -> Int -> Int -> MisoString
dedupCandidatesUrl urlOffset urlLimit titleOffset titleLimit =
    "/api/v1/dedup/candidates?url_offset="
        <> ms (show (max 0 urlOffset))
        <> "&url_limit="
        <> ms (show urlLimit)
        <> "&title_offset="
        <> ms (show (max 0 titleOffset))
        <> "&title_limit="
        <> ms (show titleLimit)

{- | The confirmed one-shot merge of every same-URL group. The server writes
one undo snapshot and answers the report the interface shows.
-}
mergeDedupAll :: (DedupMergeAllReport -> action) -> (ApiError -> action) -> Eff model action
mergeDedupAll onOk onErr =
    sendValue
        "POST"
        "/api/v1/dedup/merge-all"
        (Just (object ["confirm" .= True]))
        []
        JSON
        (either onErr onOk . decodeResponseAt "/api/v1/dedup/merge-all")
        onErr

fetchConsolidation ::
    ([ConsolidationGroup] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchConsolidation onOk onErr =
    getValue url [] (either onErr onOk . decodeListFieldAt url "groups") onErr
  where
    url = "/api/v1/tags/consolidation-candidates"

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
    getValue url [] (either onErr (\response -> onOk (sgrSuggestions response) (sgrNotice response)) . decodeResponseAt url) onErr
  where
    url = "/api/v1/tags/" <> percentEncode (ms tag) <> "/suggestions"

fetchPruneCandidates ::
    ([BookmarkSummary] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchPruneCandidates onOk onErr =
    getValue url [] (either onErr onOk . decodeListFieldAt url "items") onErr
  where
    url = "/api/v1/maintenance/prune-candidates"

fetchAccount ::
    (AccountInfo -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchAccount = apiGet "/api/v1/account"

fetchTags ::
    ([TagStat] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchTags onOk onErr =
    getValue url [] (either onErr onOk . decodeListFieldAt url "tags") onErr
  where
    url = "/api/v1/tags"

{- | @GET /api/v1/stats@ — the whole library count read again after a write.
The API renames three fields of the shared 'LibraryStats' and adds @links@, so
the payload decodes onto a local wire record and converts to the shared type.
-}
fetchStats ::
    (LibraryStats -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchStats onOk onErr =
    getValue url [] (either onErr onOk . decodeStatsAt url) onErr
  where
    url = "/api/v1/stats"

-- ----------------------------------------------------------------- writes --

createBookmark ::
    MisoString ->
    MisoString ->
    [Text] ->
    (Int -> action) ->
    (ApiError -> action) ->
    Eff model action
createBookmark url title tags onOk onErr =
    sendValue
        "POST"
        "/api/v1/bookmarks"
        ( Just
            ( object
                [ "url" .= url
                , "title" .= title
                , "tags" .= tags
                ]
            )
        )
        []
        JSON
        (either onErr onOk . decodeIntFieldAt "/api/v1/bookmarks" "id")
        onErr

{- | @POST /api/v1/quick-save@ — idempotent capture used by the PWA share
target and the account-page bookmarklet.
-}
quickSave ::
    MisoString ->
    MisoString ->
    (Int -> Bool -> action) ->
    (ApiError -> action) ->
    Eff model action
quickSave url title onOk onErr =
    sendValue
        "POST"
        "/api/v1/quick-save"
        ( Just
            ( object
                [ "url" .= url
                , "title" .= title
                , "tags" .= ([] :: [Text])
                ]
            )
        )
        []
        JSON
        (either onErr (\response -> onOk (qsrId response) (qsrExisting response)) . decodeResponseAt "/api/v1/quick-save")
        onErr

patchBookmark ::
    Int ->
    Value ->
    action ->
    (ApiError -> action) ->
    Eff model action
patchBookmark bid payload =
    apiWrite "PATCH" ("/api/v1/bookmarks/" <> ms (show bid)) (Just payload)

{- | PATCH with the server's highlight-repair count. The note/title/read editor
keeps the simple 'patchBookmark'; the extracted-text save uses this one.
-}
patchBookmarkWithResult ::
    Int ->
    Value ->
    (Int -> action) ->
    (ApiError -> action) ->
    Eff model action
patchBookmarkWithResult bid payload onOk onErr =
    sendValue
        "PATCH"
        url
        (Just payload)
        []
        JSON
        (either onErr (onOk . bprHighlightsRemoved) . decodeResponseAt url)
        onErr
  where
    url = "/api/v1/bookmarks/" <> ms (show bid)

deleteBookmark :: Int -> action -> (ApiError -> action) -> Eff model action
deleteBookmark bid = apiDelete ("/api/v1/bookmarks/" <> ms (show bid))

markAllAbove ::
    Maybe Int ->
    (Int -> action) ->
    (ApiError -> action) ->
    Eff model action
markAllAbove aboveId onOk onErr =
    sendValue
        "POST"
        "/api/v1/inbox/mark-all-above"
        (Just (object ["above_id" .= aboveId]))
        []
        JSON
        (either onErr onOk . decodeIntFieldAt "/api/v1/inbox/mark-all-above" "updated")
        onErr

trackOpen :: Int -> action -> (ApiError -> action) -> Eff model action
trackOpen bid =
    apiWrite "POST" ("/api/v1/bookmarks/" <> ms (show bid) <> "/open") (Nothing :: Maybe Value)

-- | One of the bookmark post-actions: open/enrich/extract/snapshot.
bookmarkAction :: Int -> Text -> action -> (ApiError -> action) -> Eff model action
bookmarkAction bid verb =
    apiWrite "POST" ("/api/v1/bookmarks/" <> ms (show bid) <> "/" <> ms verb) (Nothing :: Maybe Value)

saveSavedSearch ::
    MisoString ->
    MisoString ->
    [Text] ->
    (Int -> action) ->
    (ApiError -> action) ->
    Eff model action
saveSavedSearch name q tags onOk onErr =
    sendValue
        "POST"
        "/api/v1/saved-searches"
        (Just (object ["name" .= name, "q" .= q, "tags" .= tags]))
        []
        JSON
        (either onErr onOk . decodeIntFieldAt "/api/v1/saved-searches" "id")
        onErr

deleteSavedSearch :: Int -> action -> (ApiError -> action) -> Eff model action
deleteSavedSearch sid = apiDelete ("/api/v1/saved-searches/" <> ms (show sid))

mergeDedup ::
    Int ->
    [Int] ->
    ((Int, Int) -> action) ->
    (ApiError -> action) ->
    Eff model action
mergeDedup keep mergeIds onOk onErr =
    sendValue
        "POST"
        "/api/v1/dedup/merge"
        (Just (object ["keep_id" .= keep, "merge_ids" .= mergeIds]))
        []
        JSON
        (either onErr (\response -> onOk (mrMerged response, mrSnapshotId response)) . decodeResponseAt "/api/v1/dedup/merge")
        onErr

mergeTags ::
    [Text] ->
    Text ->
    action ->
    (ApiError -> action) ->
    Eff model action
mergeTags from into =
    apiWrite "POST" "/api/v1/tags/merge" (Just (object ["from" .= from, "into" .= into]))

renameTag :: Text -> Text -> action -> (ApiError -> action) -> Eff model action
renameTag old newName =
    apiWrite "POST" ("/api/v1/tags/" <> percentEncode (ms old)) (Just (object ["name" .= newName]))

deleteTag :: Text -> action -> (ApiError -> action) -> Eff model action
deleteTag tag = apiDelete ("/api/v1/tags/" <> percentEncode (ms tag))

{- | @DELETE /api/v1/tags/{tag}?detach=true@ removes a non-empty tag from every
record that carries it and leaves the records in place. A server that predates
the detach query ignores it and answers 409 for a non-empty tag; the UI shows
that message instead of pretending the tag was removed.
-}
detachTag :: Text -> action -> (ApiError -> action) -> Eff model action
detachTag tag = apiDelete ("/api/v1/tags/" <> percentEncode (ms tag) <> "?detach=true")

applyTagSuggestion ::
    Int ->
    [Text] ->
    action ->
    (ApiError -> action) ->
    Eff model action
applyTagSuggestion bid tags =
    apiWrite
        "POST"
        "/api/v1/tags/apply"
        (Just (object ["bookmark_id" .= bid, "tags" .= tags]))

runPrune :: [Int] -> (Int -> action) -> (ApiError -> action) -> Eff model action
runPrune ids onOk onErr =
    sendValue
        "POST"
        "/api/v1/maintenance/prune"
        (Just (object ["ids" .= ids]))
        []
        JSON
        (either onErr onOk . decodeIntFieldAt "/api/v1/maintenance/prune" "pruned")
        onErr

checkDead :: ((Int, Int, Int) -> action) -> (ApiError -> action) -> Eff model action
checkDead onOk onErr =
    sendValue
        "POST"
        "/api/v1/maintenance/check-dead"
        -- The handler parses a JSON object; include_dead makes the explicit
        -- maintenance recheck revisit records that are already marked dead.
        (Just (object ["include_dead" .= True]))
        []
        JSON
        ( either
            onErr
            (\response -> onOk (cdrChecked response, cdrDead response, cdrTotalDead response))
            . decodeResponseAt "/api/v1/maintenance/check-dead"
        )
        onErr

fetchUndoEntries :: ([UndoEntry] -> action) -> (ApiError -> action) -> Eff model action
fetchUndoEntries onOk onErr =
    getValue url [] (either onErr onOk . decodeListFieldAt url "entries") onErr
  where
    url = "/api/v1/undo?limit=5"

fetchUndoPreview :: Int -> (UndoPreview -> action) -> (ApiError -> action) -> Eff model action
fetchUndoPreview snapshotId onOk onErr =
    apiGet ("/api/v1/undo/" <> ms (show snapshotId)) onOk onErr

runUndo :: Int -> (UndoResult -> action) -> (ApiError -> action) -> Eff model action
runUndo snapshotId onOk onErr =
    sendValue
        "POST"
        "/api/v1/undo"
        (Just (object ["snapshot_id" .= snapshotId]))
        []
        JSON
        (either onErr onOk . decodeResponseAt "/api/v1/undo")
        onErr

markLinkAlive :: Int -> action -> (ApiError -> action) -> Eff model action
markLinkAlive bid = apiWrite "POST" ("/api/v1/bookmarks/" <> ms (show bid) <> "/mark-alive") (Nothing :: Maybe Value)

recheckLink :: Int -> action -> (ApiError -> action) -> Eff model action
recheckLink bid = apiWrite "POST" ("/api/v1/bookmarks/" <> ms (show bid) <> "/recheck-link") (Nothing :: Maybe Value)

regenerateRecovery :: ([Text] -> action) -> (ApiError -> action) -> Eff model action
regenerateRecovery onOk onErr =
    sendValue
        "POST"
        "/api/v1/account/recovery/regenerate"
        (Nothing :: Maybe Value)
        []
        JSON
        (either onErr onOk . decodeListFieldAt "/api/v1/account/recovery/regenerate" "codes")
        onErr

renameCredential :: Text -> Text -> action -> (ApiError -> action) -> Eff model action
renameCredential cid nickname =
    apiWrite
        "PATCH"
        ("/api/v1/account/passkeys/" <> percentEncode (ms cid))
        (Just (object ["nickname" .= nickname]))

deleteCredential :: Text -> action -> (ApiError -> action) -> Eff model action
deleteCredential cid = apiDelete ("/api/v1/account/passkeys/" <> percentEncode (ms cid))

{- | @POST /api/v1/account/username@ renames the one account. Once a password
exists the current password must be sent with the change.
-}
patchUsername :: Maybe Text -> Text -> action -> (ApiError -> action) -> Eff model action
patchUsername currentPassword username =
    apiWrite "POST" "/api/v1/account/username" (Just payload)
  where
    payload =
        object
            ( ["username" .= username]
                ++ [ "current_password" .= value
                   | Just value <- [currentPassword]
                   ]
            )

{- | @POST /api/v1/account/password@ sets or changes the password. Other
browser sessions are revoked by the server on success.
-}
changePassword ::
    Maybe Text ->
    Text ->
    Text ->
    action ->
    (ApiError -> action) ->
    Eff model action
changePassword currentPassword newPassword confirm =
    apiWrite "POST" "/api/v1/account/password" (Just payload)
  where
    payload =
        object
            ( ["new_password" .= newPassword, "confirm" .= confirm]
                ++ [ "current_password" .= value
                   | Just value <- [currentPassword]
                   ]
            )

{- | @POST /api/v1/account/2fa@ requires or clears the passkey second factor.
The body is @{"required": Bool, "current_password": Text?}@; the option is
listed in "docs/API.md" as planned, so a server that has not shipped it yet is
reported rather than papered over.
-}
setPasskeyRequirement ::
    Bool ->
    Maybe Text ->
    action ->
    (ApiError -> action) ->
    Eff model action
setPasskeyRequirement required currentPassword =
    apiWrite "POST" "/api/v1/account/2fa" (Just payload)
  where
    payload =
        object
            ( ["required" .= required]
                ++ [ "current_password" .= value
                   | Just value <- [currentPassword]
                   ]
            )

-- | @POST /api/v1/account/sessions/revoke-others@ — keep only this browser.
revokeOtherSessions :: (Int -> action) -> (ApiError -> action) -> Eff model action
revokeOtherSessions onOk onErr =
    sendValue
        "POST"
        "/api/v1/account/sessions/revoke-others"
        (Nothing :: Maybe Value)
        []
        JSON
        (either onErr onOk . decodeIntFieldAt "/api/v1/account/sessions/revoke-others" "revoked")
        onErr

logout :: action -> (ApiError -> action) -> Eff model action
logout = apiWrite "POST" "/api/auth/logout" (Nothing :: Maybe Value)

{- | Multipart import of a Netscape bookmarks HTML file picked via the hidden
@#import-file@ input.  Builds a @FormData@ in the browser and POSTs it with
the CSRF header; the server answers with an import report and summary counts.
-}
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
        sink $ case rawOutcome "/api/v1/import" JSON (rawResponse status body transportError) of
            Left err -> onErr err
            Right value -> either onErr onOk (decodeResponseAt "/api/v1/import" value)
    net <- jsg ("EzaNet" :: MisoString)
    inputId <- toJSVal ("import-file" :: MisoString)
    tokenValue <- toJSVal token
    _ <- net # ("upload" :: MisoString) $ (inputId, tokenValue, finish)
    pure ()

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
    sendValue
        "POST"
        "/api/v1/bookmarks/bulk"
        (Just (object fields))
        []
        JSON
        (either onErr onOk . decodeIntFieldAt "/api/v1/bookmarks/bulk" "updated")
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

-- ---------------------------------------------------------------- tokens ---

{- | @GET /api/v1/tokens@ — browser-session only (bearer tokens cannot manage
tokens).
-}
fetchTokens ::
    ([TokenView] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchTokens onOk onErr =
    getValue url [] (either onErr onOk . decodeListFieldAt url "tokens") onErr
  where
    url = "/api/v1/tokens"

-- | @POST /api/v1/tokens@ — returns the raw token once plus its metadata.
createApiToken ::
    Text ->
    [Text] ->
    (Text -> TokenView -> action) ->
    (ApiError -> action) ->
    Eff model action
createApiToken name scopes onOk onErr =
    sendValue
        "POST"
        "/api/v1/tokens"
        (Just (object ["name" .= name, "scopes" .= scopes]))
        []
        JSON
        (either onErr (\response -> onOk (tcrToken response) (tcrTokenInfo response)) . decodeResponseAt "/api/v1/tokens")
        onErr

-- | @DELETE /api/v1/tokens/{id}@ — revoke (keeps the row, sets revoked_at).
revokeApiToken :: Int -> action -> (ApiError -> action) -> Eff model action
revokeApiToken tokenId = apiDelete ("/api/v1/tokens/" <> ms (show tokenId))

-- ------------------------------------------------------------ highlights --

-- | @GET /api/v1/bookmarks/{id}/highlights@
fetchHighlights ::
    Int ->
    ([Highlight] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchHighlights bookmarkId onOk onErr =
    getValue url [] (either onErr onOk . decodeListFieldAt url "highlights") onErr
  where
    url = "/api/v1/bookmarks/" <> ms (show bookmarkId) <> "/highlights"

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
    sendValue
        "POST"
        url
        (Just (object fields))
        []
        JSON
        (either onErr onOk . decodeResponseAt url)
        onErr
  where
    url = "/api/v1/bookmarks/" <> ms (show bookmarkId) <> "/highlights"
    fields =
        [ "quote" .= quote
        , "prefix" .= prefix
        , "suffix" .= suffix
        , "start_offset" .= startOffset
        , "end_offset" .= endOffset
        , "note" .= note
        , "color" .= color
        ]

-- | @PATCH /api/v1/bookmarks/{id}/highlights/{highlightId}@
patchHighlight ::
    Int ->
    Int ->
    (Maybe Text) ->
    (Maybe Text) ->
    action ->
    (ApiError -> action) ->
    Eff model action
patchHighlight bookmarkId highlightId note color onOk onErr =
    sendValue "PATCH" url (Just payload) [] NONE (\_ -> onOk) onErr
  where
    url =
        "/api/v1/bookmarks/"
            <> ms (show bookmarkId)
            <> "/highlights/"
            <> ms (show highlightId)
    payload =
        object
            ( [("note" .= value) | Just value <- [note]]
                ++ [("color" .= value) | Just value <- [color]]
            )

-- | @DELETE /api/v1/bookmarks/{id}/highlights/{highlightId}@
deleteHighlight ::
    Int ->
    Int ->
    action ->
    (ApiError -> action) ->
    Eff model action
deleteHighlight bookmarkId highlightId onOk onErr =
    apiDelete
        ( "/api/v1/bookmarks/"
            <> ms (show bookmarkId)
            <> "/highlights/"
            <> ms (show highlightId)
        )
        onOk
        onErr

-- ---------------------------------------------------------------- shares ---

-- | @GET /api/v1/share-links@ (all share links for the account).
fetchShares ::
    ([ShareView] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchShares onOk onErr =
    getValue url [] (either onErr onOk . decodeListFieldAt url "shares") onErr
  where
    url = "/api/v1/share-links"

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
    sendValue
        "POST"
        "/api/v1/share-links"
        ( Just
            ( object
                [ "scope" .= scope
                , "target_id" .= targetId
                , "include_note" .= includeNote
                , "expires_in_days" .= expiresInDays
                ]
            )
        )
        []
        JSON
        ( either
            onErr
            (\response -> onOk (scrId response) (scrUrl response))
            . decodeResponseAt "/api/v1/share-links"
        )
        onErr

-- | @DELETE /api/v1/share-links/{id}@ — revoke a share link.
revokeShareLink :: Int -> action -> (ApiError -> action) -> Eff model action
revokeShareLink shareId = apiDelete ("/api/v1/share-links/" <> ms (show shareId))

-- ---------------------------------------------------------------- ai ------

-- | @GET /api/v1/ai/status@ — provider/model/configured for the AI-tags page.
fetchAiStatus ::
    (AiStatus -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchAiStatus = apiGet "/api/v1/ai/status"

-- ----------------------------------------------------------------- rules ---

-- | @GET /api/v1/rules@
fetchRules ::
    ([Rule] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchRules onOk onErr =
    getValue url [] (either onErr onOk . decodeListFieldAt url "rules") onErr
  where
    url = "/api/v1/rules"

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
    sendValue
        "POST"
        "/api/v1/rules"
        (Just (ruleBody name enabled field patternText addTags markRead))
        []
        JSON
        (either onErr onOk . decodeResponseAt "/api/v1/rules")
        onErr

{- | @PATCH /api/v1/rules/{id}@ — the API replaces all fields, so callers pass
the complete rule with the change applied. The response body is ignored: the
caller already has the rule it submitted.
-}
patchRule ::
    Int ->
    Rule ->
    action ->
    (ApiError -> action) ->
    Eff model action
patchRule ruleId rule onOk onErr =
    sendValue "PATCH" ("/api/v1/rules/" <> ms (show ruleId)) (Just body) [] NONE (\_ -> onOk) onErr
  where
    body =
        ruleBody
            (ruleName rule)
            (ruleEnabled rule)
            (ruleField rule)
            (rulePattern rule)
            (ruleAddTags rule)
            (ruleMarkRead rule)

-- | @DELETE /api/v1/rules/{id}@
deleteRule :: Int -> action -> (ApiError -> action) -> Eff model action
deleteRule ruleId = apiDelete ("/api/v1/rules/" <> ms (show ruleId))

-- | @POST /api/v1/rules/test@ — dry run against the existing library.
testRule ::
    Text ->
    Text ->
    (Int -> [Int] -> action) ->
    (ApiError -> action) ->
    Eff model action
testRule field patternText onOk onErr =
    sendValue
        "POST"
        "/api/v1/rules/test"
        (Just (ruleBody "" True field patternText [] False))
        []
        JSON
        (either onErr (\response -> onOk (rtrMatches response) (rtrBookmarkIds response)) . decodeResponseAt "/api/v1/rules/test")
        onErr

-- ------------------------------------------------------------------ links --

exportUrl :: MisoString
exportUrl = "/api/v1/export"

notesExportUrl :: MisoString
notesExportUrl = "/api/v1/export/notes"
