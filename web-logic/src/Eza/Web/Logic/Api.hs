{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The client request model: every JSON endpoint the Miso client calls, as
data instead of a hand-written URL string.

Each 'ClientRequest' maps to an "Eza.Routes" 'Eza.Routes.Route' where the route
truth has the endpoint; 'requestMethod' therefore reads the method from the
shared table, and 'requestPath' renders the concrete path with
'Eza.Routes.renderRoutePath'. Query strings that the route table cannot carry
(the list filters, pagination, the layout preset and the tag detach flag) are
appended here, next to the endpoint they belong to.

The module is Miso-free and native-buildable, so @eza-web-logic-test@ pins
every path against the literal the client used before the route table was
adopted. 'Eza.Web.Api' uses the read constructors for its GET fetchers; the
write constructors are the M2-B adoption target and are tested here so the
whole literal set is covered.
-}
module Eza.Web.Logic.Api (
    ClientRequest (..),
    BookmarkListQuery (..),
    DedupCandidateQuery (..),
    requestMethod,
    requestPath,
) where

import Data.Text (Text)
import qualified Data.Text as T

import Eza.GraphLayout (LayoutPreset, layoutPresetText)
import Eza.Routes (Route (..), renderRoutePath, routeMethod)

import Eza.Web.Logic.Route (percentEncode)

-- ------------------------------------------------------------------ query ---

-- | The filter set behind @GET /api/v1/bookmarks@.
data BookmarkListQuery = BookmarkListQuery
    { blqQ :: Text
    , blqTags :: [Text]
    , blqSort :: Text
    , blqUnreadOnly :: Bool
    , blqOffset :: Int
    , blqLimit :: Int
    }
    deriving (Eq, Show)

-- | The two independently paged sections of the duplicate report.
data DedupCandidateQuery = DedupCandidateQuery
    { dcqUrlOffset :: Int
    , dcqUrlLimit :: Int
    , dcqTitleOffset :: Int
    , dcqTitleLimit :: Int
    }
    deriving (Eq, Show)

-- ---------------------------------------------------------------- requests ---

{- | One client JSON request. Constructors that would collide with route names
carry the @Api@ prefix; read requests are the ones "Eza.Web.Api" renders
through 'requestPath' today.
-}
data ClientRequest
    = -- reads (GET)
      ApiBoot
    | ApiBookmarks BookmarkListQuery
    | ApiBookmark Int
    | ApiBookmarkBacklinks Int
    | ApiAutocomplete Text
    | ApiGraph
    | ApiGraphLayout LayoutPreset
    | ApiViews
    | ApiView Text
    | ApiWebhooks
    | ApiWebhook Int
    | ApiWebhookDeliveries Int
    | ApiAdminUsers
    | ApiSavedSearches
    | ApiDedupCandidates DedupCandidateQuery
    | ApiTagConsolidationCandidates
    | ApiTagSuggestions Text
    | ApiMaintenancePruneCandidates
    | ApiAccount
    | ApiTags
    | ApiStats
    | ApiUndoEntries
    | ApiUndoPreview Int
    | ApiTokens
    | ApiHighlights Int
    | ApiShares
    | ApiAiStatus
    | ApiRules
    | ApiExport
    | ApiExportNotes
    | ApiWhoami
    | ApiClipTemplates
    | ApiClipTemplate Int
    | -- writes (kept as literals in "Eza.Web.Api" until M2-B)
      ApiCreateView
    | ApiPatchView Text
    | ApiDeleteView Text
    | ApiCreateWebhook
    | ApiPatchWebhook Int
    | ApiDeleteWebhook Int
    | ApiTestWebhook Int
    | ApiCreateAdminUser
    | ApiPatchAdminUser Int
    | ApiResetAdminPassword Int
    | ApiDeleteAdminUser Int
    | ApiCreateBookmark
    | ApiQuickSave
    | ApiPatchBookmark Int
    | ApiDeleteBookmark Int
    | ApiMarkAllAbove
    | ApiTrackOpen Int
    | ApiBookmarkAction Int Text
    | ApiCreateSavedSearch
    | ApiDeleteSavedSearch Int
    | ApiMergeDedup
    | ApiMergeDedupAll
    | ApiMergeTags
    | ApiRenameTag Text
    | ApiDeleteTag Text
    | ApiDetachTag Text
    | ApiApplyTagSuggestion
    | ApiRunPrune
    | ApiCheckDead
    | ApiRunUndo
    | ApiMarkLinkAlive Int
    | ApiRecheckLink Int
    | ApiRegenerateRecovery
    | ApiRenameCredential Text
    | ApiDeleteCredential Text
    | ApiPatchUsername
    | ApiChangePassword
    | ApiSetPasskeyRequirement
    | ApiRevokeOtherSessions
    | ApiLogout
    | ApiSubmitImport
    | ApiBulkUpdate
    | ApiCreateApiToken
    | ApiRevokeApiToken Int
    | ApiCreateHighlight Int
    | ApiPatchHighlight Int Int
    | ApiDeleteHighlight Int Int
    | ApiCreateShareLink
    | ApiRevokeShareLink Int
    | ApiCreateRule
    | ApiPatchRule Int
    | ApiDeleteRule Int
    | ApiTestRule
    deriving (Eq, Show)

-- ---------------------------------------------------------------- methods ---

{- | The HTTP method of a request, read from "Eza.Routes" wherever the route
truth has the endpoint. The only request without a route constructor is a
bookmark post-action with a verb the table does not list; every verb the
client sends has one ("open", "enrich", "extract", "mark-alive",
"recheck-link", "snapshot").
-}
requestMethod :: ClientRequest -> Text
requestMethod request = case apiRoute request of
    Just route -> routeMethod route
    Nothing -> "POST"

-- ------------------------------------------------------------------ paths ---

{- | The concrete request path and query string. Parameterised routes render
through 'renderRoutePath' after their path parameter has been percent-encoded,
so a slug or tag with a reserved character stays one path segment.
-}
requestPath :: ClientRequest -> Text
requestPath request = case request of
    ApiBookmarks query -> routePath RouteBookmarkList <> bookmarkListQueryText query
    ApiAutocomplete query -> routePath RouteAutocomplete <> "?q=" <> percentEncode query
    ApiGraphLayout preset -> routePath RouteGraphLayout <> "?preset=" <> layoutPresetText preset
    ApiWebhookDeliveries webhookId -> routePath (RouteWebhookDeliveries webhookId) <> "?limit=20"
    ApiDedupCandidates query -> routePath RouteDedupCandidates <> dedupCandidateQueryText query
    ApiUndoEntries -> routePath RouteUndoList <> "?limit=5"
    ApiDetachTag tag -> routePath (RouteTagDelete [percentEncode tag]) <> "?detach=true"
    ApiBookmarkAction bookmarkId verb -> case bookmarkActionRoute bookmarkId verb of
        Just route -> routePath route
        -- A verb the route table does not know cannot pass the auth guard, but
        -- the client still builds the same path it always did.
        Nothing -> "/api/v1/bookmarks/" <> intText bookmarkId <> "/" <> verb
    _ -> case apiRoute request of
        Just route -> routePath route
        Nothing -> "/"
  where
    routePath = renderRoutePath

{- | The route-table entry for a request, with its path parameters already
percent-encoded. 'Nothing' only for a bookmark action verb the table does not
list.
-}
apiRoute :: ClientRequest -> Maybe Route
apiRoute = \case
    ApiBoot -> Just RouteBoot
    ApiBookmarks _ -> Just RouteBookmarkList
    ApiBookmark bookmarkId -> Just (RouteBookmarkRead bookmarkId)
    ApiBookmarkBacklinks bookmarkId -> Just (RouteBookmarkBacklinks bookmarkId)
    ApiAutocomplete _ -> Just RouteAutocomplete
    ApiGraph -> Just RouteGraph
    ApiGraphLayout _ -> Just RouteGraphLayout
    ApiViews -> Just RouteViewList
    ApiView slug -> Just (RouteViewRead (percentEncode slug))
    ApiWebhooks -> Just RouteWebhookList
    ApiWebhook webhookId -> Just (RouteWebhookRead webhookId)
    ApiWebhookDeliveries webhookId -> Just (RouteWebhookDeliveries webhookId)
    ApiAdminUsers -> Just RouteAdminUserList
    ApiSavedSearches -> Just RouteSavedSearchList
    ApiDedupCandidates _ -> Just RouteDedupCandidates
    ApiTagConsolidationCandidates -> Just RouteTagConsolidationCandidates
    ApiTagSuggestions tag -> Just (RouteTagSuggestions (percentEncode tag))
    ApiMaintenancePruneCandidates -> Just RouteMaintenancePruneCandidates
    ApiAccount -> Just RouteAccountRead
    ApiTags -> Just RouteTags
    ApiStats -> Just RouteStats
    ApiUndoEntries -> Just RouteUndoList
    ApiUndoPreview snapshotId -> Just (RouteUndoPreview snapshotId)
    ApiTokens -> Just RouteTokenList
    ApiHighlights bookmarkId -> Just (RouteHighlightList bookmarkId)
    ApiShares -> Just RouteShareLinkList
    ApiAiStatus -> Just RouteAiStatus
    ApiRules -> Just RouteRuleList
    ApiExport -> Just RouteExport
    ApiExportNotes -> Just RouteExportNotes
    ApiWhoami -> Just RouteWhoami
    ApiClipTemplates -> Just RouteClipTemplateList
    ApiClipTemplate templateId -> Just (RouteClipTemplateRead templateId)
    ApiCreateView -> Just RouteViewCreate
    ApiPatchView slug -> Just (RouteViewUpdate (percentEncode slug))
    ApiDeleteView slug -> Just (RouteViewDelete (percentEncode slug))
    ApiCreateWebhook -> Just RouteWebhookCreate
    ApiPatchWebhook webhookId -> Just (RouteWebhookUpdate webhookId)
    ApiDeleteWebhook webhookId -> Just (RouteWebhookDelete webhookId)
    ApiTestWebhook webhookId -> Just (RouteWebhookTest webhookId)
    ApiCreateAdminUser -> Just RouteAdminUserCreate
    ApiPatchAdminUser userId -> Just (RouteAdminUserUpdate userId)
    ApiResetAdminPassword userId -> Just (RouteAdminUserPassword userId)
    ApiDeleteAdminUser userId -> Just (RouteAdminUserDelete userId)
    ApiCreateBookmark -> Just RouteBookmarkCreate
    ApiQuickSave -> Just RouteQuickSave
    ApiPatchBookmark bookmarkId -> Just (RouteBookmarkUpdate bookmarkId)
    ApiDeleteBookmark bookmarkId -> Just (RouteBookmarkDelete bookmarkId)
    ApiMarkAllAbove -> Just RouteInboxMarkAbove
    ApiTrackOpen bookmarkId -> Just (RouteBookmarkOpen bookmarkId)
    ApiBookmarkAction bookmarkId verb -> bookmarkActionRoute bookmarkId verb
    ApiCreateSavedSearch -> Just RouteSavedSearchCreate
    ApiDeleteSavedSearch savedSearchId -> Just (RouteSavedSearchDelete savedSearchId)
    ApiMergeDedup -> Just RouteDedupMerge
    ApiMergeDedupAll -> Just RouteDedupMergeAll
    ApiMergeTags -> Just RouteTagMerge
    ApiRenameTag tag -> Just (RouteTagRename [percentEncode tag])
    ApiDeleteTag tag -> Just (RouteTagDelete [percentEncode tag])
    ApiDetachTag tag -> Just (RouteTagDelete [percentEncode tag])
    ApiApplyTagSuggestion -> Just RouteTagApply
    ApiRunPrune -> Just RouteMaintenancePrune
    ApiCheckDead -> Just RouteMaintenanceCheckDead
    ApiRunUndo -> Just RouteUndoApply
    ApiMarkLinkAlive bookmarkId -> Just (RouteBookmarkMarkAlive bookmarkId)
    ApiRecheckLink bookmarkId -> Just (RouteBookmarkRecheckLink bookmarkId)
    ApiRegenerateRecovery -> Just RouteAccountRecoveryRegenerate
    ApiRenameCredential credential -> Just (RouteAccountPasskeyRename (percentEncode credential))
    ApiDeleteCredential credential -> Just (RouteAccountPasskeyDelete (percentEncode credential))
    ApiPatchUsername -> Just RouteAccountUsername
    ApiChangePassword -> Just RouteAccountPassword
    ApiSetPasskeyRequirement -> Just RouteAccountTwoFactor
    ApiRevokeOtherSessions -> Just RouteAccountSessionsRevokeOthers
    ApiLogout -> Just RouteLogout
    ApiSubmitImport -> Just RouteImport
    ApiBulkUpdate -> Just RouteBookmarkBulk
    ApiCreateApiToken -> Just RouteTokenCreate
    ApiRevokeApiToken tokenId -> Just (RouteTokenRevoke tokenId)
    ApiCreateHighlight bookmarkId -> Just (RouteHighlightCreate bookmarkId)
    ApiPatchHighlight bookmarkId highlightId -> Just (RouteHighlightUpdate bookmarkId highlightId)
    ApiDeleteHighlight bookmarkId highlightId -> Just (RouteHighlightDelete bookmarkId highlightId)
    ApiCreateShareLink -> Just RouteShareLinkCreate
    ApiRevokeShareLink shareId -> Just (RouteShareLinkRevoke shareId)
    ApiCreateRule -> Just RouteRuleCreate
    ApiPatchRule ruleId -> Just (RouteRuleUpdate ruleId)
    ApiDeleteRule ruleId -> Just (RouteRuleDelete ruleId)
    ApiTestRule -> Just RouteRuleTest

-- | The bookmark post-actions the route table enumerates.
bookmarkActionRoute :: Int -> Text -> Maybe Route
bookmarkActionRoute bookmarkId verb = case verb of
    "open" -> Just (RouteBookmarkOpen bookmarkId)
    "enrich" -> Just (RouteBookmarkEnrich bookmarkId)
    "extract" -> Just (RouteBookmarkExtract bookmarkId)
    "mark-alive" -> Just (RouteBookmarkMarkAlive bookmarkId)
    "recheck-link" -> Just (RouteBookmarkRecheckLink bookmarkId)
    "snapshot" -> Just (RouteBookmarkSnapshotWrite bookmarkId)
    _ -> Nothing

-- ------------------------------------------------------------ query text ---

{- | The list filter query string, in the exact order the client historically
built it: @limit@, @offset@, then @q@, @tags@, @is_read@ and @sort@ when set.
-}
bookmarkListQueryText :: BookmarkListQuery -> Text
bookmarkListQueryText query =
    "?limit="
        <> intText (blqLimit query)
        <> "&offset="
        <> intText (blqOffset query)
        <> qPart
        <> tagsPart
        <> readPart
        <> sortPart
  where
    qPart
        | T.null (T.strip (blqQ query)) = ""
        | otherwise = "&q=" <> percentEncode (blqQ query)
    tagsPart = case blqTags query of
        [] -> ""
        tags -> "&tags=" <> T.intercalate "," (map percentEncode tags)
    readPart = if blqUnreadOnly query then "&is_read=0" else ""
    sortPart = "&sort=" <> percentEncode (blqSort query)

{- | The duplicate-report page query. A negative offset is clamped to zero,
matching the client's previous URL builder.
-}
dedupCandidateQueryText :: DedupCandidateQuery -> Text
dedupCandidateQueryText query =
    "?url_offset="
        <> intText (max 0 (dcqUrlOffset query))
        <> "&url_limit="
        <> intText (dcqUrlLimit query)
        <> "&title_offset="
        <> intText (max 0 (dcqTitleOffset query))
        <> "&title_limit="
        <> intText (dcqTitleLimit query)

intText :: Int -> Text
intText = T.pack . show
