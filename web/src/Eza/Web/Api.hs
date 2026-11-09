{- | HTTP client for the eza v1 JSON API.

Every unsafe request carries @X-CSRF-Token@ read from the @eza_csrf@
cookie.  Responses are decoded with the shared "Eza.Types" aeson instances;
planned endpoints decode leniently (see "Eza.Web.Types") so a missing route
only shows a soft notice instead of breaking the page.
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
    LayoutWire (..),
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
    runUndo,
    regenerateRecovery,
    renameCredential,
    deleteCredential,
    patchUsername,
    changePassword,
    setPasskeyRequirement,
    revokeOtherSessions,
    logout,
    submitImport,
    -- links
    exportUrl,
    notesExportUrl,
) where

import Data.Aeson (FromJSON, ToJSON, Value (..), object, toJSON, withObject, (.!=), (.:), (.:?), (.=))
import qualified Data.Aeson as A
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Char (chr, isAlphaNum, ord)
import Data.List (stripPrefix)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Miso
import qualified Miso.JSON as MJ

import Eza.Boot (BootPayload)
import Eza.GraphLayout (LayoutPositions (..), LayoutPreset (..))
import qualified Eza.View as EV
import Eza.User (UserCreateInput (..), UserCreateResult (..), UserRole (..), UserView (..))
import Eza.Webhook (DeliveryView, Webhook, WebhookInput (..))
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
 )

import Eza.Web.Types (
    AccountInfo,
    AiStatus,
    ApiError,
    ConsolGroup,
    Credential,
    Rule (..),
    ShareView,
    TagSuggestion,
    TokenView,
    fieldBool,
    fieldInt,
    fieldList,
    fieldObject,
    fieldText,
    mkApiError,
 )

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

instance FromJSON RawResponse where
    parseJSON = withObject "RawResponse" $ \o ->
        RawResponse
            <$> o .:? "status" .!= 0
            <*> o .:? "text" .!= ""
            <*> o .:? "error"

decodeRawResponse :: MisoString -> RawResponse
decodeRawResponse raw = case MJ.eitherDecode raw of
    Right response -> response
    Left err -> RawResponse 0 "" (Just (toText err))

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
(envelope message preserved), then body decoding.
-}
rawOutcome :: CONTENT_TYPE -> RawResponse -> Either ApiError Value
rawOutcome responseType raw = case (rfStatus raw, rfError raw) of
    (0, Just message)
        | not (T.null (T.strip message)) -> Left (mkApiError Nothing (Just message))
    (status, _)
        | status < 200 || status >= 300 -> Left (statusError status raw)
        | responseType == JSON ->
            case (MJ.eitherDecode (ms (T.unpack (rfText raw))) :: Either MisoString Value) of
                Right value -> Right value
                Left err ->
                    Left
                        ( mkApiError
                            (Just status)
                            (Just ("the server sent a response the client could not read: " <> toText err))
                        )
        | otherwise -> Right Null

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
        case (MJ.eitherDecode (ms (T.unpack trimmed)) :: Either MisoString Value) of
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
            case rawOutcome responseType raw of
                Left err -> onErr err
                Right value -> onOk value
    finish <- asyncCallback1 $ \raw -> do
        rawText <- fromJSVal raw
        sink (report (decodeRawResponse (fromMaybe "" (rawText :: Maybe MisoString))))
    net <- jsg ("EzaNet" :: MisoString)
    urlValue <- toJSVal url
    methodValue <- toJSVal method
    bodyValue <- toJSVal encodedBody
    headersValue <- toJSVal (M.fromList (requestHeaders extraHeaders token))
    _ <- net # ("fetch" :: MisoString) $ (urlValue, methodValue, bodyValue, headersValue, finish)
    pure ()

-- | Decode a raw body into the shared (or lenient) DTO.
decode :: (FromJSON a) => Value -> Either ApiError a
decode value =
    case MJ.fromJSON value of
        MJ.Success a -> Right a
        MJ.Error e -> Left (mkApiError Nothing (Just (toText e)))

apiGet ::
    (FromJSON a) =>
    MisoString ->
    (a -> action) ->
    (ApiError -> action) ->
    Eff model action
apiGet url onOk onErr =
    getValue url [] (\v -> either onErr onOk (decode v)) onErr

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

-- | Linked + unlinked backlinks; falls back to a lenient decode.
fetchBacklinks ::
    Int ->
    ([Backlink] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchBacklinks bid onOk onErr =
    getValue
        ("/api/v1/bookmarks/" <> ms (show bid) <> "/backlinks")
        []
        (\v -> onOk (extractBacklinks v))
        onErr
  where
    extractBacklinks v =
        case decode v :: Either ApiError Backlinks of
            Right bks -> bksLinked bks ++ bksUnlinked bks
            Left _ -> fieldList "linked" v ++ fieldList "unlinked" v

fetchAutocomplete ::
    MisoString ->
    ([BookmarkSummary] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchAutocomplete q onOk onErr =
    getValue
        ("/api/v1/autocomplete?q=" <> percentEncode q)
        []
        ( \v ->
            let items = fieldList "items" v
             in onOk (if null items then fieldList "bookmarks" v else items)
        )
        onErr

fetchGraph ::
    (GraphData -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchGraph onOk onErr =
    getValue "/api/v1/graph" [] (\value -> either onErr onOk (decode value)) onErr

{- | The server-built layout for one preset. The payload is the server's
compact form: @{schema, revision, preset, tags, records, bounds}@ with integer
positions quantized to 1/100 world unit. The client validates the revision
against 'gdRevision' before hydrating.
-}
data LayoutWire = LayoutWire
    { lwRevision :: Text
    , lwTags :: [(Double, Double)]
    , lwRecords :: [(Double, Double)]
    , lwBounds :: ((Double, Double), (Double, Double))
    }
    deriving (Eq, Show)

fetchGraphLayout ::
    LayoutPreset ->
    (LayoutWire -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchGraphLayout preset onOk onErr =
    getValue ("/api/v1/graph/layout?preset=" <> presetSlug preset) [] (\value -> either onErr onOk (decodeLayoutWire value)) onErr

presetSlug :: LayoutPreset -> MisoString
presetSlug preset = case preset of
    Compact -> "compact"
    Standard -> "standard"
    Airy -> "airy"

decodeLayoutWire :: Value -> Either ApiError LayoutWire
decodeLayoutWire value =
    case parseEither parseWire value of
        Left message -> Left (mkApiError Nothing (Just (T.pack message)))
        Right wire -> Right wire
  where
    parseWire = withObject "graph layout" $ \o -> do
        schema <- o .: "schema" :: Parser Int
        if schema /= (1 :: Int)
            then fail ("unsupported graph layout schema " <> show schema)
            else pure ()
        revision <- o .: "revision"
        tags <- o .: "tags" >>= traverse pairOf
        records <- o .: "records" >>= traverse pairOf
        bounds <- o .: "bounds" >>= boundsOf
        pure (LayoutWire revision tags records bounds)
    pairOf [x, y] = pure (x, y)
    pairOf _ = fail "graph layout positions must be [x,y] pairs"
    boundsOf [minX, minY, maxX, maxY] = pure ((minX, minY), (maxX, maxY))
    boundsOf _ = fail "graph layout bounds must be [minx,miny,maxx,maxy]"

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
    getValue "/api/v1/views" [] (\value -> onOk (fieldList "views" value)) onErr

fetchView :: Text -> (EV.View -> action) -> (ApiError -> action) -> Eff model action
fetchView slug onOk onErr =
    getValue ("/api/v1/views/" <> percentEncode (ms (T.unpack slug))) [] (\value -> either onErr onOk (decode value)) onErr

createView :: EV.ViewInput -> (EV.View -> action) -> (ApiError -> action) -> Eff model action
createView input onOk onErr =
    sendValue
        "POST"
        "/api/v1/views"
        (Just (toJSON input))
        []
        JSON
        (\value -> either onErr onOk (decode value))
        onErr

patchView :: Text -> ViewPatch -> (EV.View -> action) -> (ApiError -> action) -> Eff model action
patchView slug patch onOk onErr =
    sendValue
        "PATCH"
        ("/api/v1/views/" <> percentEncode (ms (T.unpack slug)))
        (Just (toJSON patch))
        []
        JSON
        (\value -> either onErr onOk (decode value))
        onErr

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

fetchWebhooks :: ([Webhook] -> action) -> (ApiError -> action) -> Eff model action
fetchWebhooks onOk onErr =
    getValue "/api/v1/webhooks" [] (\value -> onOk (fieldList "webhooks" value)) onErr

fetchWebhook :: Int -> (Webhook -> action) -> (ApiError -> action) -> Eff model action
fetchWebhook webhookId onOk onErr =
    getValue (webhookUrl webhookId) [] (\value -> either onErr onOk (decode value)) onErr

createWebhook ::
    WebhookInput ->
    ((Webhook, Text) -> action) ->
    (ApiError -> action) ->
    Eff model action
createWebhook input onOk onErr =
    sendValue
        "POST"
        "/api/v1/webhooks"
        (Just (toJSON input))
        []
        JSON
        ( \value -> case (fieldObject "webhook" value :: Maybe Value) of
            Nothing -> onErr (mkApiError Nothing (Just "the create response had no webhook object"))
            Just raw -> case decode raw of
                Right webhook -> onOk (webhook, fieldText "secret" value)
                Left err -> onErr err
        )
        onErr

updateWebhook ::
    Int ->
    WebhookInput ->
    (Webhook -> action) ->
    (ApiError -> action) ->
    Eff model action
updateWebhook webhookId input onOk onErr =
    sendValue
        "PATCH"
        (webhookUrl webhookId)
        (Just (toJSON input))
        []
        JSON
        (\value -> either onErr onOk (decode value))
        onErr

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
        ( \value ->
            onOk
                ( WebhookTest
                    (fieldBool "ok" value)
                    (fieldObject "status" value)
                    (fieldText "error" value)
                )
        )
        onErr

fetchWebhookDeliveries :: Int -> ([DeliveryView] -> action) -> (ApiError -> action) -> Eff model action
fetchWebhookDeliveries webhookId onOk onErr =
    getValue
        (webhookUrl webhookId <> "/deliveries?limit=20")
        []
        (\value -> onOk (fieldList "deliveries" value))
        onErr

webhookUrl :: Int -> MisoString
webhookUrl webhookId = "/api/v1/webhooks/" <> ms (show webhookId)

{- | Admin user management. The server admits only admin browser sessions
(Authz AdminClass); members get 403 @forbidden@ and bearer tokens 403
@session_required@. Recovery codes are revealed once on create.
-}
fetchAdminUsers :: ([UserView] -> action) -> (ApiError -> action) -> Eff model action
fetchAdminUsers onOk onErr =
    getValue "/api/v1/admin/users" [] (\value -> onOk (fieldList "users" value)) onErr

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
        ( \value ->
            case (fieldObject "user" value :: Maybe Value) of
                Nothing -> onErr (mkApiError Nothing (Just "the create response had no user object"))
                Just rawUser -> case decode rawUser of
                    Right user ->
                        onOk
                            ( UserCreateResult
                                user
                                (fieldList "recovery_codes" value)
                            )
                    Left err -> onErr err
        )
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
        ("/api/v1/admin/users/" <> ms (show userId))
        (Just (object (["enabled" .= value | Just value <- [enabled]] ++ ["role" .= value | Just value <- [role]])))
        []
        JSON
        (\value -> either onErr onOk (decode value))
        onErr

-- | Break-glass temporary password. The server clears the target's 2FA flag
-- and revokes that user's sessions.
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

fetchSavedSearches ::
    ([SavedSearch] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchSavedSearches onOk onErr =
    getValue "/api/v1/saved-searches" [] (\v -> onOk (fieldList "saved_searches" v)) onErr

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
        (\v -> either onErr onOk (decode v))
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
        (\v -> either onErr onOk (decode v))
        onErr

fetchConsolidation ::
    ([ConsolGroup] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchConsolidation onOk onErr =
    getValue
        "/api/v1/tags/consolidation-candidates"
        []
        (\v -> onOk (fieldList "groups" v))
        onErr

{- | @GET /api/v1/tags/{tag}/suggestions@.  The server answers an unconfigured
provider with 200, @configured: false@, an empty list and a notice; hand all
three to the caller so the page can say what happened instead of showing an
empty result that looks like a clean scan.
-}
fetchSuggestions ::
    Text ->
    (Bool -> [TagSuggestion] -> Maybe Text -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchSuggestions tag onOk onErr =
    getValue
        ("/api/v1/tags/" <> percentEncode (ms tag) <> "/suggestions")
        []
        ( \v ->
            let fields = case v of
                    A.Object o -> o
                    _ -> KM.empty
                configured =
                    not (KM.member (K.fromText "configured") fields)
                        || fieldBool "configured" v
                notice = case T.strip (fieldText "notice" v) of
                    "" -> Nothing
                    text -> Just text
             in onOk configured (fieldList "suggestions" v) notice
        )
        onErr

fetchPruneCandidates ::
    ([BookmarkSummary] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchPruneCandidates onOk onErr =
    getValue
        "/api/v1/maintenance/prune-candidates"
        []
        (\v -> onOk (fieldList "items" v))
        onErr

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
    getValue "/api/v1/tags" [] (\v -> onOk (fieldList "tags" v)) onErr

{- | @GET /api/v1/stats@ — the whole library count read again after a write.
The API names three fields differently from the shared DTO (@bookmarks@,
@bookmark_tags@, @jobs_pending@); decode the payload straight onto
'LibraryStats' rather than round-tripping through an intermediate 'Value'.
-}
fetchStats ::
    (Maybe LibraryStats -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchStats onOk onErr =
    getValue "/api/v1/stats" [] (\value -> onOk (statsFromPayload value)) onErr

statsFromPayload :: Value -> Maybe LibraryStats
statsFromPayload =
    MJ.parseMaybe $
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
        (\v -> onOk (fieldInt "id" v))
        onErr

{- | @PATCH /api/v1/bookmarks/{id}@ — the detail editor save path.
| @POST /api/v1/quick-save@ — idempotent capture used by the PWA share
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
        (\v -> onOk (fieldInt "id" v) (fieldBool "existing" v))
        onErr

patchBookmark ::
    Int ->
    Value ->
    action ->
    (ApiError -> action) ->
    Eff model action
patchBookmark bid payload =
    apiWrite "PATCH" ("/api/v1/bookmarks/" <> ms (show bid)) (Just payload)

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
        (\v -> onOk (fieldInt "updated" v))
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
        (\v -> onOk (fieldInt "id" v))
        onErr

deleteSavedSearch :: Int -> action -> (ApiError -> action) -> Eff model action
deleteSavedSearch sid = apiDelete ("/api/v1/saved-searches/" <> ms (show sid))

mergeDedup ::
    Int ->
    [Int] ->
    (Int -> action) ->
    (ApiError -> action) ->
    Eff model action
mergeDedup keep mergeIds onOk onErr =
    sendValue
        "POST"
        "/api/v1/dedup/merge"
        (Just (object ["keep_id" .= keep, "merge_ids" .= mergeIds]))
        []
        JSON
        (\v -> onOk (fieldInt "merged" v))
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
        (\v -> onOk (fieldInt "pruned" v))
        onErr

checkDead :: ((Int, Int) -> action) -> (ApiError -> action) -> Eff model action
checkDead onOk onErr =
    sendValue
        "POST"
        "/api/v1/maintenance/check-dead"
        -- the handler parses a JSON object even though every field is optional
        (Just (object []))
        []
        JSON
        (\v -> onOk (fieldInt "checked" v, fieldInt "dead" v))
        onErr

runUndo :: (Int -> action) -> (ApiError -> action) -> Eff model action
runUndo onOk onErr =
    sendValue
        "POST"
        "/api/v1/undo"
        (Nothing :: Maybe Value)
        []
        JSON
        (\v -> onOk (fieldInt "restored" v))
        onErr

regenerateRecovery :: ([Text] -> action) -> (ApiError -> action) -> Eff model action
regenerateRecovery onOk onErr =
    sendValue
        "POST"
        "/api/v1/account/recovery/regenerate"
        (Nothing :: Maybe Value)
        []
        JSON
        (\v -> onOk (fieldList "codes" v))
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
        (\v -> onOk (fieldInt "revoked" v))
        onErr

logout :: action -> (ApiError -> action) -> Eff model action
logout = apiWrite "POST" "/api/auth/logout" (Nothing :: Maybe Value)

{- | Multipart import of a Netscape bookmarks HTML file picked via the hidden
@#import-file@ input.  Builds a @FormData@ in the browser and POSTs it with
the CSRF header; the server answers with an "Eza.Types.ImportReport".
-}
submitImport ::
    (Value -> action) ->
    (ApiError -> action) ->
    Eff model action
submitImport onOk onErr = withSink $ \sink -> do
    token <- csrfToken
    -- The file input and the multipart FormData live in the external
    -- @EzaNet.upload@ helper (static/pwa.js): the CSP forbids eval, so the
    -- client cannot build JavaScript at runtime.
    finish <- asyncCallback1 $ \raw -> do
        rawText <- fromJSVal raw
        let raw' = decodeRawResponse (fromMaybe "" (rawText :: Maybe MisoString))
        sink $ case rawOutcome JSON raw' of
            Left err -> onErr err
            Right value -> onOk value
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
        (\v -> onOk (fieldInt "updated" v))
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
    getValue "/api/v1/tokens" [] (\v -> onOk (fieldList "tokens" v)) onErr

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
        ( \v -> case fieldObject "token_info" v of
            Just info -> onOk (fieldText "token" v) info
            Nothing -> onErr (mkApiError Nothing (Just "token response is missing token_info"))
        )
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
    getValue
        ("/api/v1/bookmarks/" <> ms (show bookmarkId) <> "/highlights")
        []
        (\v -> onOk (fieldList "highlights" v))
        onErr

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
        ( \v -> case decodeHighlight v of
            Just highlight -> onOk highlight
            Nothing -> onErr (mkApiError Nothing (Just "invalid highlight response"))
        )
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

-- | Decode a raw 'Value' into the shared 'Highlight' DTO.
decodeHighlight :: Value -> Maybe Highlight
decodeHighlight value = case MJ.fromJSON value of
    MJ.Success highlight -> Just highlight
    MJ.Error _ -> Nothing

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
    sendValue "PATCH" url (Just payload) [] JSON (\_ -> onOk) onErr
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
    getValue "/api/v1/share-links" [] (\v -> onOk (fieldList "shares" v)) onErr

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
        (\v -> onOk (fieldInt "id" v) (fieldText "url" v))
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
    getValue "/api/v1/rules" [] (\v -> onOk (fieldList "rules" v)) onErr

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

decodeRule :: Value -> Maybe Rule
decodeRule value = case MJ.fromJSON value of
    MJ.Success rule -> Just rule
    MJ.Error _ -> Nothing

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
        ( \v -> case decodeRule v of
            Just rule -> onOk rule
            Nothing -> onErr (mkApiError Nothing (Just "invalid rule response"))
        )
        onErr

{- | @PATCH /api/v1/rules/{id}@ — the API replaces all fields, so callers pass
the complete rule with the change applied.
-}
patchRule ::
    Int ->
    Rule ->
    action ->
    (ApiError -> action) ->
    Eff model action
patchRule ruleId rule onOk onErr =
    sendValue "PATCH" ("/api/v1/rules/" <> ms (show ruleId)) (Just body) [] JSON (\_ -> onOk) onErr
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
        (\v -> onOk (fieldInt "matches" v) (fieldList "bookmark_ids" v))
        onErr

-- ------------------------------------------------------------------ links --

exportUrl :: MisoString
exportUrl = "/api/v1/export"

notesExportUrl :: MisoString
notesExportUrl = "/api/v1/export/notes"

-- | Keeps the lenient DTO imports exercised on the client.
_unusedLenient :: Maybe (Credential, SavedSearch)
_unusedLenient = Nothing
