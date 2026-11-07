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
    fetchSavedSearches,
    fetchDedup,
    fetchConsolidation,
    fetchSuggestions,
    fetchPruneCandidates,
    fetchAccount,
    fetchTags,
    fetchTokens,
    -- writes
    createBookmark,
    quickSave,
    BulkAction (..),
    bulkUpdate,
    createApiToken,
    revokeApiToken,
    patchBookmark,
    deleteBookmark,
    markAllAbove,
    trackOpen,
    bookmarkAction,
    saveSavedSearch,
    deleteSavedSearch,
    mergeDedup,
    mergeTags,
    renameTag,
    deleteTag,
    applyTagSuggestion,
    runPrune,
    checkDead,
    runUndo,
    regenerateRecovery,
    renameCredential,
    deleteCredential,
    logout,
    submitImport,
    -- links
    exportUrl,
    notesExportUrl,
) where

import Data.Aeson (FromJSON, ToJSON, Value, object, toJSON, (.=))
import Data.Char (chr, isAlphaNum, ord)
import Data.List (stripPrefix)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Miso
import qualified Miso.JSON as MJ

import Eza.Types (
    Backlink (..),
    Backlinks (..),
    BookmarkDetail,
    BookmarkSummary,
    BootPayload,
    GraphData,
    SavedSearch,
    SearchPage,
    TagStat,
 )

import Eza.Web.Types (
    AccountInfo,
    ApiError,
    ConsolGroup,
    Credential,
    DedupGroup,
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

{- | Fire a request.  The response body is handed over as a raw 'Value' so
callers can decode strictly (shared DTOs) or leniently (planned routes).
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
sendValue method url requestedBody extraHeaders responseType onOk onErr =
    withSink $ \sink -> do
        token <- csrfToken
        bodyVal <- traverse (toJSVal . MJ.encode) requestedBody
        let authHeader =
                if T.null (toText token) then [] else [("X-CSRF-Token", token)]
            headers =
                [ ("Accept", "application/json")
                , ("Content-Type", "application/json")
                ]
                    ++ authHeader
                    ++ extraHeaders
        fetch
            url
            method
            bodyVal
            headers
            (\resp -> sink (onOk (body resp)))
            (\resp -> sink (onErr (responseError resp)))
            responseType

{- | Error callback receives the raw JS response; the server's JSON error
envelope is not available here (fetch rejects before parsing), so we map
the HTTP status to a friendly message.
-}
responseError :: Response JSVal -> ApiError
responseError resp = mkApiError (status resp) Nothing

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

apiPost ::
    (ToJSON b, FromJSON r) =>
    MisoString ->
    b ->
    (r -> action) ->
    (ApiError -> action) ->
    Eff model action
apiPost url requestBody onOk onErr =
    sendValue
        "POST"
        url
        (Just (toJSON requestBody))
        []
        JSON
        (\v -> either onErr onOk (decode v))
        onErr

-- | A write whose response body we do not care about.
apiWrite ::
    (ToJSON b) =>
    MisoString ->
    MisoString ->
    Maybe b ->
    action ->
    (ApiError -> action) ->
    Eff model action
apiWrite method url requestBody onOk onErr =
    sendValue method url (toJSON <$> requestBody) [] JSON (\_ -> onOk) onErr

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
    Maybe Int ->
    Int ->
    (GraphData -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchGraph seed depth =
    apiGet url
  where
    url =
        "/api/v1/graph?depth="
            <> ms (show depth)
            <> maybe "" (\sid -> "&seed=" <> ms (show sid)) seed

fetchSavedSearches ::
    ([SavedSearch] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchSavedSearches onOk onErr =
    getValue "/api/v1/saved-searches" [] (\v -> onOk (fieldList "saved_searches" v)) onErr

fetchDedup ::
    ([DedupGroup] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchDedup onOk onErr =
    getValue "/api/v1/dedup/candidates" [] (\v -> onOk (fieldList "groups" v)) onErr

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

fetchSuggestions ::
    Text ->
    ([TagSuggestion] -> action) ->
    (ApiError -> action) ->
    Eff model action
fetchSuggestions tag onOk onErr =
    getValue
        ("/api/v1/tags/" <> percentEncode (ms tag) <> "/suggestions")
        []
        (\v -> onOk (fieldList "suggestions" v))
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
        (Nothing :: Maybe Value)
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
    -- FileList is not a JS Array, so miso's FromJSVal [File] cannot decode it
    -- (fromJSVal_List requires Array.isArray). Build the FormData in JS and
    -- hand the whole multipart body straight to fetch instead.
    built <-
        inline
            "const el = document.getElementById('import-file'); const fd = new FormData(); if (!el || !el.files || !el.files.length) { return null; } fd.append('file', el.files[0]); return fd;"
            (M.empty :: M.Map MisoString JSVal)
    case built of
        Nothing -> sink (onErr (mkApiError Nothing (Just "Choose an HTML bookmarks file first.")))
        Just formData -> do
            let headers =
                    if T.null (toText token)
                        then []
                        else [("X-CSRF-Token", token)]
            fetch
                "/api/v1/import"
                "POST"
                (Just formData)
                headers
                (\resp -> sink (onOk (body resp)))
                (\resp -> sink (onErr (responseError resp)))
                JSON

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

-- ------------------------------------------------------------------ links --

exportUrl :: MisoString
exportUrl = "/api/v1/export"

notesExportUrl :: MisoString
notesExportUrl = "/api/v1/export/notes"

-- | Keeps the lenient DTO imports exercised on the client.
_unusedLenient :: Maybe (Credential, SavedSearch)
_unusedLenient = Nothing
