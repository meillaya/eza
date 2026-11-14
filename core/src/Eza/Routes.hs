{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The single route truth for the whole HTTP surface.

Every method/path pair the server answers is one 'Route' constructor here,
together with its authorization class and capability. "Eza.Authz" derives its
matrix from this module, and @eza-bookmarks routes --markdown@ renders the
reference table in @docs/generated/routes.md@.

The rule is deny by default: 'matchRoute' returns 'Nothing' for anything that
is not in this table, and the caller classifies that as
'Eza.Authz.DeniedClass' (unknown API paths answer 404, never an accidental
allow). Dispatch still lives in "Eza.Server" until M4; this module is the
candidate source of truth it will be replaced by.

= Client route literals

The Miso client in "Eza.Web.Api" still builds its URLs from literals. Every
one of them is representable by a 'Route' below, so the client can adopt the
table without a new URL syntax. The literals, grouped by method:

@
GET
  \/api\/v1\/bookmarks?limit=...                RouteBookmarkList
  \/api\/v1\/boot                              RouteBoot
  \/api\/v1\/bookmarks\/{id}                   RouteBookmarkRead
  \/api\/v1\/bookmarks\/{id}\/backlinks        RouteBookmarkBacklinks
  \/api\/v1\/autocomplete?q=...                RouteAutocomplete
  \/api\/v1\/graph                             RouteGraph
  \/api\/v1\/graph\/layout?preset=...          RouteGraphLayout
  \/api\/v1\/views                             RouteViewList
  \/api\/v1\/views\/{slug}                     RouteViewRead
  \/api\/v1\/webhooks                          RouteWebhookList
  \/api\/v1\/webhooks\/{id}                    RouteWebhookRead
  \/api\/v1\/webhooks\/{id}\/deliveries?limit=...  RouteWebhookDeliveries
  \/api\/v1\/admin\/users                      RouteAdminUserList
  \/api\/v1\/saved-searches                    RouteSavedSearchList
  \/api\/v1\/dedup\/candidates?...              RouteDedupCandidates
  \/api\/v1\/tags\/consolidation-candidates    RouteTagConsolidationCandidates
  \/api\/v1\/tags\/{tag}\/suggestions          RouteTagSuggestions
  \/api\/v1\/maintenance\/prune-candidates     RouteMaintenancePruneCandidates
  \/api\/v1\/account                           RouteAccountRead
  \/api\/v1\/tags                              RouteTags
  \/api\/v1\/stats                             RouteStats
  \/api\/v1\/undo?limit=5                      RouteUndoList
  \/api\/v1\/undo\/{id}                        RouteUndoPreview
  \/api\/v1\/tokens                            RouteTokenList
  \/api\/v1\/bookmarks\/{id}\/highlights       RouteHighlightList
  \/api\/v1\/share-links                       RouteShareLinkList
  \/api\/v1\/ai\/status                        RouteAiStatus
  \/api\/v1\/rules                             RouteRuleList
  \/api\/v1\/export                            RouteExport
  \/api\/v1\/export\/notes                     RouteExportNotes

POST
  \/api\/v1\/views                             RouteViewCreate
  \/api\/v1\/webhooks                          RouteWebhookCreate
  \/api\/v1\/webhooks\/{id}\/test              RouteWebhookTest
  \/api\/v1\/admin\/users                      RouteAdminUserCreate
  \/api\/v1\/admin\/users\/{id}\/password      RouteAdminUserPassword
  \/api\/v1\/bookmarks                         RouteBookmarkCreate
  \/api\/v1\/quick-save                        RouteQuickSave
  \/api\/v1\/inbox\/mark-all-above             RouteInboxMarkAbove
  \/api\/v1\/saved-searches                    RouteSavedSearchCreate
  \/api\/v1\/dedup\/merge                      RouteDedupMerge
  \/api\/v1\/dedup\/merge-all                  RouteDedupMergeAll
  \/api\/v1\/tags\/merge                       RouteTagMerge
  \/api\/v1\/tags\/{tag}                       RouteTagRename
  \/api\/v1\/tags\/apply                       RouteTagApply
  \/api\/v1\/maintenance\/prune                RouteMaintenancePrune
  \/api\/v1\/maintenance\/check-dead           RouteMaintenanceCheckDead
  \/api\/v1\/undo                              RouteUndoApply
  \/api\/v1\/bookmarks\/{id}\/open             RouteBookmarkOpen
  \/api\/v1\/bookmarks\/{id}\/{verb}           RouteBookmarkEnrich \/ Extract \/
                                               RouteBookmarkSnapshotWrite
  \/api\/v1\/bookmarks\/{id}\/mark-alive       RouteBookmarkMarkAlive
  \/api\/v1\/bookmarks\/{id}\/recheck-link     RouteBookmarkRecheckLink
  \/api\/v1\/account\/recovery\/regenerate     RouteAccountRecoveryRegenerate
  \/api\/v1\/account\/username                 RouteAccountUsername
  \/api\/v1\/account\/password                 RouteAccountPassword
  \/api\/v1\/account\/2fa                      RouteAccountTwoFactor
  \/api\/v1\/account\/sessions\/revoke-others  RouteAccountSessionsRevokeOthers
  \/api\/auth\/logout                          RouteLogout
  \/api\/v1\/bookmarks\/bulk                   RouteBookmarkBulk
  \/api\/v1\/tokens                            RouteTokenCreate
  \/api\/v1\/bookmarks\/{id}\/highlights       RouteHighlightCreate
  \/api\/v1\/share-links                       RouteShareLinkCreate
  \/api\/v1\/rules                             RouteRuleCreate
  \/api\/v1\/rules\/test                       RouteRuleTest

PATCH
  \/api\/v1\/views\/{slug}                     RouteViewUpdate
  \/api\/v1\/webhooks\/{id}                    RouteWebhookUpdate
  \/api\/v1\/admin\/users\/{id}                RouteAdminUserUpdate
  \/api\/v1\/bookmarks\/{id}                   RouteBookmarkUpdate
  \/api\/v1\/bookmarks\/{id}\/highlights\/{highlightId}  RouteHighlightUpdate
  \/api\/v1\/account\/passkeys\/{id}           RouteAccountPasskeyRename
  \/api\/v1\/rules\/{id}                       RouteRuleUpdate

DELETE
  \/api\/v1\/views\/{slug}                     RouteViewDelete
  \/api\/v1\/webhooks\/{id}                    RouteWebhookDelete
  \/api\/v1\/admin\/users\/{id}                RouteAdminUserDelete
  \/api\/v1\/bookmarks\/{id}                   RouteBookmarkDelete
  \/api\/v1\/bookmarks\/{id}\/highlights\/{highlightId}  RouteHighlightDelete
  \/api\/v1\/account\/passkeys\/{id}           RouteAccountPasskeyDelete
  \/api\/v1\/tags\/{tag}                       RouteTagDelete
  \/api\/v1\/saved-searches\/{id}              RouteSavedSearchDelete
  \/api\/v1\/tokens\/{id}                      RouteTokenRevoke
  \/api\/v1\/share-links\/{id}                 RouteShareLinkRevoke
  \/api\/v1\/rules\/{id}                       RouteRuleDelete
@
-}
module Eza.Routes (
    Route (..),
    RouteClass (..),
    Capability (..),
    Scope (..),
    Role (..),
    routeMethod,
    routePath,
    renderRoutePath,
    routeClass,
    routeCapability,
    matchRoute,
    allRoutes,
    RouteRow,
    routeTable,
    routesMarkdown,
    routeClassText,
    capabilityText,
    scopeFromText,
    scopeText,
) where

import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)

-- ---------------------------------------------------------------- classes ---

-- | How a request reaches a handler.
data RouteClass
    = PublicClass
    | SessionClass
    | TokenClass
    | AdminClass
    | ShareClass
    | DeniedClass
    deriving (Show, Eq, Enum, Bounded)

-- | What a route needs, independent of who presents it.
data Capability
    = CapRead
    | CapWrite
    | CapCaptureRead
    | CapCaptureWrite
    | CapSession
    | CapAdmin
    deriving (Show, Eq, Enum, Bounded)

-- | API token scopes. The wire form is @read@, @write@, @capture@.
data Scope
    = ScopeRead
    | ScopeWrite
    | ScopeCapture
    deriving (Show, Eq, Enum, Bounded)

{- | Browser-session roles. The member role has every authorisation the old
single-account installation had; the admin role adds user administration.
-}
data Role
    = RoleAdmin
    | RoleMember
    deriving (Show, Eq, Enum, Bounded)

-- ----------------------------------------------------------------- routes ---

{- | Every method/path pair the HTTP surface answers.

The constructors carry the parsed path parameters: @Int@ ids, '@Text@
segments, and, for the tag and asset families, the remaining path segments.
Wildcard families ('RouteStaticAsset', 'RouteSpaPage', 'RouteTagRename',
'RouteTagDelete') are matched against a whole sub-tree; the tag families are
parameterised by segments because a tag name may itself contain a slash.
-}
data Route
    = -- public pages, health, assets
      RouteHealth
    | RouteLoginPage
    | RouteSetupPage
    | RouteRecoverPage
    | RouteRootPage
    | RouteStaticAsset [Text]
    | RouteFavicon
    | RouteThemeJs
    | RouteManifest
    | RouteServiceWorker
    | -- public auth ceremonies (POST)
      RoutePasswordLogin
    | RoutePasskeyLoginOptions
    | RoutePasskeyLoginVerify
    | RouteLegacyPasskeyOptions
    | RouteLegacyPasskeyVerify
    | RoutePasswordSetup
    | RoutePasskeySetupOptionsRetired
    | RoutePasskeySetupVerifyRetired
    | RouteRecoveryRedeem
    | -- public CORS preflight (OPTIONS)
      RouteCorsPreflightClip
    | RouteCorsPreflightClipPreview
    | RouteCorsPreflightClipTemplates
    | RouteCorsPreflightClipTemplate Int
    | RouteCorsPreflightWhoami
    | RouteCorsPreflightQuickSave
    | -- public share links
      RouteSharePage Text
    | RouteShareFeed Text
    | -- authenticated SPA shell and session-only pages
      RouteSpaPage
    | RouteSavePage
    | RouteAddPasskeyPage
    | RouteLogout
    | -- session-only account, token, rule, template, and webhook routes
      RouteAccountRead
    | RouteAccountTwoFactor
    | RouteAccountPassword
    | RouteAccountUsername
    | RouteAccountSessionsRevokeOthers
    | RouteAccountPasskeyOptions
    | RouteAccountPasskeyVerify
    | RouteAccountPasskeyRename Text
    | RouteAccountPasskeyDelete Text
    | RouteAccountRecoveryRegenerate
    | RouteTokenList
    | RouteTokenCreate
    | RouteTokenRevoke Int
    | RouteRuleList
    | RouteRuleCreate
    | RouteRuleTest
    | RouteRuleUpdate Int
    | RouteRuleDelete Int
    | RouteClipTemplateCreate
    | RouteClipTemplateUpdate Int
    | RouteClipTemplateDelete Int
    | RouteWebhookList
    | RouteWebhookCreate
    | RouteWebhookRead Int
    | RouteWebhookUpdate Int
    | RouteWebhookDelete Int
    | RouteWebhookTest Int
    | RouteWebhookDeliveries Int
    | -- token-or-session JSON routes
      RouteWhoami
    | RouteClip
    | RouteClipPreview
    | RouteClipTemplateList
    | RouteClipTemplateRead Int
    | RouteBoot
    | RouteBookmarkList
    | RouteBookmarkCreate
    | RouteBookmarkBulk
    | RouteBookmarkRead Int
    | RouteBookmarkUpdate Int
    | RouteBookmarkDelete Int
    | RouteHighlightList Int
    | RouteHighlightCreate Int
    | RouteHighlightUpdate Int Int
    | RouteHighlightDelete Int Int
    | RouteBookmarkBacklinks Int
    | RouteBookmarkSnapshotRead Int
    | RouteBookmarkOpen Int
    | RouteBookmarkEnrich Int
    | RouteBookmarkExtract Int
    | RouteBookmarkMarkAlive Int
    | RouteBookmarkRecheckLink Int
    | RouteBookmarkSnapshotWrite Int
    | RouteFaviconRead Text
    | RouteQuickSave
    | RouteInboxMarkAbove
    | RouteShareLinkList
    | RouteShareLinkCreate
    | RouteShareLinkRevoke Int
    | RouteTags
    | RouteTagSuggestions Text
    | RouteTagConsolidationCandidates
    | RouteTagApply
    | RouteTagMerge
    | RouteTagRename [Text]
    | RouteTagDelete [Text]
    | RouteAutocomplete
    | RouteGraph
    | RouteGraphLayout
    | RouteViewList
    | RouteViewCreate
    | RouteViewRead Text
    | RouteViewUpdate Text
    | RouteViewDelete Text
    | RouteSavedSearchList
    | RouteSavedSearchCreate
    | RouteSavedSearchDelete Int
    | RouteDedupCandidates
    | RouteDedupMergeAll
    | RouteDedupMerge
    | RouteMaintenanceCheckDead
    | RouteMaintenancePruneCandidates
    | RouteMaintenancePrune
    | RouteUndoList
    | RouteUndoPreview Int
    | RouteUndoApply
    | RouteImport
    | RouteImportJson
    | RouteExport
    | RouteExportNotes
    | RouteStats
    | RouteAiStatus
    | -- admin user management
      RouteAdminUserList
    | RouteAdminUserCreate
    | RouteAdminUserUpdate Int
    | RouteAdminUserPassword Int
    | RouteAdminUserDelete Int
    deriving (Show, Eq)

-- | One row of the generated reference: method, template path, class, capability.
type RouteRow = (Text, Text, RouteClass, Maybe Capability)

{- | The static half of every route: method, docs path template, class, and
capability. This is the table the docs and the authorization matrix are
derived from; the dynamic path parameters are rendered by 'renderRoutePath'.
-}
routeInfo :: Route -> RouteRow
routeInfo = \case
    RouteHealth -> row "GET" "/healthz" PublicClass Nothing
    RouteLoginPage -> row "GET" "/login" PublicClass Nothing
    RouteSetupPage -> row "GET" "/setup" PublicClass Nothing
    RouteRecoverPage -> row "GET" "/recover" PublicClass Nothing
    RouteRootPage -> row "GET" "/" PublicClass Nothing
    RouteStaticAsset _ -> row "GET" "/assets/{path...}" PublicClass Nothing
    RouteFavicon -> row "GET" "/favicon.svg" PublicClass Nothing
    RouteThemeJs -> row "GET" "/theme.js" PublicClass Nothing
    RouteManifest -> row "GET" "/manifest.webmanifest" PublicClass Nothing
    RouteServiceWorker -> row "GET" "/sw.js" PublicClass Nothing
    RoutePasswordLogin -> row "POST" "/api/auth/login" PublicClass Nothing
    RoutePasskeyLoginOptions -> row "POST" "/api/auth/passkey/options" PublicClass Nothing
    RoutePasskeyLoginVerify -> row "POST" "/api/auth/passkey/verify" PublicClass Nothing
    RouteLegacyPasskeyOptions -> row "POST" "/api/auth/options" PublicClass Nothing
    RouteLegacyPasskeyVerify -> row "POST" "/api/auth/verify" PublicClass Nothing
    RoutePasswordSetup -> row "POST" "/api/setup/password" PublicClass Nothing
    RoutePasskeySetupOptionsRetired -> row "POST" "/api/setup/options" PublicClass Nothing
    RoutePasskeySetupVerifyRetired -> row "POST" "/api/setup/verify" PublicClass Nothing
    RouteRecoveryRedeem -> row "POST" "/api/recovery/redeem" PublicClass Nothing
    RouteCorsPreflightClip -> row "OPTIONS" "/api/v1/clip" PublicClass Nothing
    RouteCorsPreflightClipPreview -> row "OPTIONS" "/api/v1/clip/preview" PublicClass Nothing
    RouteCorsPreflightClipTemplates -> row "OPTIONS" "/api/v1/clip-templates" PublicClass Nothing
    RouteCorsPreflightClipTemplate _ -> row "OPTIONS" "/api/v1/clip-templates/{id}" PublicClass Nothing
    RouteCorsPreflightWhoami -> row "OPTIONS" "/api/v1/whoami" PublicClass Nothing
    RouteCorsPreflightQuickSave -> row "OPTIONS" "/api/v1/quick-save" PublicClass Nothing
    RouteSharePage _ -> row "GET" "/s/{token}" ShareClass Nothing
    RouteShareFeed _ -> row "GET" "/s/{token}.xml" ShareClass Nothing
    RouteSpaPage -> row "GET" "/{page...}" SessionClass (Just CapSession)
    RouteSavePage -> row "GET" "/save" SessionClass (Just CapSession)
    RouteAddPasskeyPage -> row "GET" "/account/add-passkey" SessionClass (Just CapSession)
    RouteLogout -> row "POST" "/api/auth/logout" SessionClass (Just CapSession)
    RouteAccountRead -> row "GET" "/api/v1/account" SessionClass (Just CapSession)
    RouteAccountTwoFactor -> row "POST" "/api/v1/account/2fa" SessionClass (Just CapSession)
    RouteAccountPassword -> row "POST" "/api/v1/account/password" SessionClass (Just CapSession)
    RouteAccountUsername -> row "POST" "/api/v1/account/username" SessionClass (Just CapSession)
    RouteAccountSessionsRevokeOthers -> row "POST" "/api/v1/account/sessions/revoke-others" SessionClass (Just CapSession)
    RouteAccountPasskeyOptions -> row "POST" "/api/v1/account/passkeys/options" SessionClass (Just CapSession)
    RouteAccountPasskeyVerify -> row "POST" "/api/v1/account/passkeys/verify" SessionClass (Just CapSession)
    RouteAccountPasskeyRename _ -> row "PATCH" "/api/v1/account/passkeys/{id}" SessionClass (Just CapSession)
    RouteAccountPasskeyDelete _ -> row "DELETE" "/api/v1/account/passkeys/{id}" SessionClass (Just CapSession)
    RouteAccountRecoveryRegenerate -> row "POST" "/api/v1/account/recovery/regenerate" SessionClass (Just CapSession)
    RouteTokenList -> row "GET" "/api/v1/tokens" SessionClass (Just CapSession)
    RouteTokenCreate -> row "POST" "/api/v1/tokens" SessionClass (Just CapSession)
    RouteTokenRevoke _ -> row "DELETE" "/api/v1/tokens/{id}" SessionClass (Just CapSession)
    RouteRuleList -> row "GET" "/api/v1/rules" SessionClass (Just CapSession)
    RouteRuleCreate -> row "POST" "/api/v1/rules" SessionClass (Just CapSession)
    RouteRuleTest -> row "POST" "/api/v1/rules/test" SessionClass (Just CapSession)
    RouteRuleUpdate _ -> row "PATCH" "/api/v1/rules/{id}" SessionClass (Just CapSession)
    RouteRuleDelete _ -> row "DELETE" "/api/v1/rules/{id}" SessionClass (Just CapSession)
    RouteClipTemplateCreate -> row "POST" "/api/v1/clip-templates" SessionClass (Just CapSession)
    RouteClipTemplateUpdate _ -> row "PATCH" "/api/v1/clip-templates/{id}" SessionClass (Just CapSession)
    RouteClipTemplateDelete _ -> row "DELETE" "/api/v1/clip-templates/{id}" SessionClass (Just CapSession)
    RouteWebhookList -> row "GET" "/api/v1/webhooks" SessionClass (Just CapSession)
    RouteWebhookCreate -> row "POST" "/api/v1/webhooks" SessionClass (Just CapSession)
    RouteWebhookRead _ -> row "GET" "/api/v1/webhooks/{id}" SessionClass (Just CapSession)
    RouteWebhookUpdate _ -> row "PATCH" "/api/v1/webhooks/{id}" SessionClass (Just CapSession)
    RouteWebhookDelete _ -> row "DELETE" "/api/v1/webhooks/{id}" SessionClass (Just CapSession)
    RouteWebhookTest _ -> row "POST" "/api/v1/webhooks/{id}/test" SessionClass (Just CapSession)
    RouteWebhookDeliveries _ -> row "GET" "/api/v1/webhooks/{id}/deliveries" SessionClass (Just CapSession)
    RouteWhoami -> row "GET" "/api/v1/whoami" TokenClass (Just CapCaptureRead)
    RouteClip -> row "POST" "/api/v1/clip" TokenClass (Just CapCaptureWrite)
    RouteClipPreview -> row "POST" "/api/v1/clip/preview" TokenClass (Just CapCaptureWrite)
    RouteClipTemplateList -> row "GET" "/api/v1/clip-templates" TokenClass (Just CapCaptureRead)
    RouteClipTemplateRead _ -> row "GET" "/api/v1/clip-templates/{id}" TokenClass (Just CapCaptureRead)
    RouteBoot -> row "GET" "/api/v1/boot" TokenClass (Just CapRead)
    RouteBookmarkList -> row "GET" "/api/v1/bookmarks" TokenClass (Just CapRead)
    RouteBookmarkCreate -> row "POST" "/api/v1/bookmarks" TokenClass (Just CapWrite)
    RouteBookmarkBulk -> row "POST" "/api/v1/bookmarks/bulk" TokenClass (Just CapWrite)
    RouteBookmarkRead _ -> row "GET" "/api/v1/bookmarks/{id}" TokenClass (Just CapRead)
    RouteBookmarkUpdate _ -> row "PATCH" "/api/v1/bookmarks/{id}" TokenClass (Just CapWrite)
    RouteBookmarkDelete _ -> row "DELETE" "/api/v1/bookmarks/{id}" TokenClass (Just CapWrite)
    RouteHighlightList _ -> row "GET" "/api/v1/bookmarks/{id}/highlights" TokenClass (Just CapRead)
    RouteHighlightCreate _ -> row "POST" "/api/v1/bookmarks/{id}/highlights" TokenClass (Just CapWrite)
    RouteHighlightUpdate _ _ -> row "PATCH" "/api/v1/bookmarks/{id}/highlights/{highlightId}" TokenClass (Just CapWrite)
    RouteHighlightDelete _ _ -> row "DELETE" "/api/v1/bookmarks/{id}/highlights/{highlightId}" TokenClass (Just CapWrite)
    RouteBookmarkBacklinks _ -> row "GET" "/api/v1/bookmarks/{id}/backlinks" TokenClass (Just CapRead)
    RouteBookmarkSnapshotRead _ -> row "GET" "/api/v1/bookmarks/{id}/snapshot" TokenClass (Just CapRead)
    RouteBookmarkOpen _ -> row "POST" "/api/v1/bookmarks/{id}/open" TokenClass (Just CapWrite)
    RouteBookmarkEnrich _ -> row "POST" "/api/v1/bookmarks/{id}/enrich" TokenClass (Just CapWrite)
    RouteBookmarkExtract _ -> row "POST" "/api/v1/bookmarks/{id}/extract" TokenClass (Just CapWrite)
    RouteBookmarkMarkAlive _ -> row "POST" "/api/v1/bookmarks/{id}/mark-alive" TokenClass (Just CapWrite)
    RouteBookmarkRecheckLink _ -> row "POST" "/api/v1/bookmarks/{id}/recheck-link" TokenClass (Just CapWrite)
    RouteBookmarkSnapshotWrite _ -> row "POST" "/api/v1/bookmarks/{id}/snapshot" TokenClass (Just CapWrite)
    RouteFaviconRead _ -> row "GET" "/api/v1/favicons/{domain}" TokenClass (Just CapRead)
    RouteQuickSave -> row "POST" "/api/v1/quick-save" TokenClass (Just CapCaptureWrite)
    RouteInboxMarkAbove -> row "POST" "/api/v1/inbox/mark-all-above" TokenClass (Just CapWrite)
    RouteShareLinkList -> row "GET" "/api/v1/share-links" TokenClass (Just CapRead)
    RouteShareLinkCreate -> row "POST" "/api/v1/share-links" TokenClass (Just CapWrite)
    RouteShareLinkRevoke _ -> row "DELETE" "/api/v1/share-links/{id}" TokenClass (Just CapWrite)
    RouteTags -> row "GET" "/api/v1/tags" TokenClass (Just CapRead)
    RouteTagSuggestions _ -> row "GET" "/api/v1/tags/{tag}/suggestions" TokenClass (Just CapRead)
    RouteTagConsolidationCandidates -> row "GET" "/api/v1/tags/consolidation-candidates" TokenClass (Just CapRead)
    RouteTagApply -> row "POST" "/api/v1/tags/apply" TokenClass (Just CapWrite)
    RouteTagMerge -> row "POST" "/api/v1/tags/merge" TokenClass (Just CapWrite)
    RouteTagRename _ -> row "POST" "/api/v1/tags/{tag...}" TokenClass (Just CapWrite)
    RouteTagDelete _ -> row "DELETE" "/api/v1/tags/{tag...}" TokenClass (Just CapWrite)
    RouteAutocomplete -> row "GET" "/api/v1/autocomplete" TokenClass (Just CapRead)
    RouteGraph -> row "GET" "/api/v1/graph" TokenClass (Just CapRead)
    RouteGraphLayout -> row "GET" "/api/v1/graph/layout" TokenClass (Just CapRead)
    RouteViewList -> row "GET" "/api/v1/views" TokenClass (Just CapRead)
    RouteViewCreate -> row "POST" "/api/v1/views" TokenClass (Just CapWrite)
    RouteViewRead _ -> row "GET" "/api/v1/views/{slug}" TokenClass (Just CapRead)
    RouteViewUpdate _ -> row "PATCH" "/api/v1/views/{slug}" TokenClass (Just CapWrite)
    RouteViewDelete _ -> row "DELETE" "/api/v1/views/{slug}" TokenClass (Just CapWrite)
    RouteSavedSearchList -> row "GET" "/api/v1/saved-searches" TokenClass (Just CapRead)
    RouteSavedSearchCreate -> row "POST" "/api/v1/saved-searches" TokenClass (Just CapWrite)
    RouteSavedSearchDelete _ -> row "DELETE" "/api/v1/saved-searches/{id}" TokenClass (Just CapWrite)
    RouteDedupCandidates -> row "GET" "/api/v1/dedup/candidates" TokenClass (Just CapRead)
    RouteDedupMergeAll -> row "POST" "/api/v1/dedup/merge-all" TokenClass (Just CapWrite)
    RouteDedupMerge -> row "POST" "/api/v1/dedup/merge" TokenClass (Just CapWrite)
    RouteMaintenanceCheckDead -> row "POST" "/api/v1/maintenance/check-dead" TokenClass (Just CapWrite)
    RouteMaintenancePruneCandidates -> row "GET" "/api/v1/maintenance/prune-candidates" TokenClass (Just CapRead)
    RouteMaintenancePrune -> row "POST" "/api/v1/maintenance/prune" TokenClass (Just CapWrite)
    RouteUndoList -> row "GET" "/api/v1/undo" TokenClass (Just CapRead)
    RouteUndoPreview _ -> row "GET" "/api/v1/undo/{id}" TokenClass (Just CapRead)
    RouteUndoApply -> row "POST" "/api/v1/undo" TokenClass (Just CapWrite)
    RouteImport -> row "POST" "/api/v1/import" TokenClass (Just CapWrite)
    RouteImportJson -> row "POST" "/api/v1/import/json" TokenClass (Just CapWrite)
    RouteExport -> row "GET" "/api/v1/export" TokenClass (Just CapRead)
    RouteExportNotes -> row "GET" "/api/v1/export/notes" TokenClass (Just CapRead)
    RouteStats -> row "GET" "/api/v1/stats" TokenClass (Just CapRead)
    RouteAiStatus -> row "GET" "/api/v1/ai/status" TokenClass (Just CapRead)
    RouteAdminUserList -> row "GET" "/api/v1/admin/users" AdminClass (Just CapAdmin)
    RouteAdminUserCreate -> row "POST" "/api/v1/admin/users" AdminClass (Just CapAdmin)
    RouteAdminUserUpdate _ -> row "PATCH" "/api/v1/admin/users/{id}" AdminClass (Just CapAdmin)
    RouteAdminUserPassword _ -> row "POST" "/api/v1/admin/users/{id}/password" AdminClass (Just CapAdmin)
    RouteAdminUserDelete _ -> row "DELETE" "/api/v1/admin/users/{id}" AdminClass (Just CapAdmin)
  where
    row method path klass capability = (method, path, klass, capability)

-- | The HTTP method a route answers. Case-normalised to upper case.
routeMethod :: Route -> Text
routeMethod route = case routeInfo route of
    (method, _, _, _) -> method

{- | The path template shown in the reference documentation. Fixed routes
render their literal path; parameterised routes render @{id}@, @{token}@ etc.
so the reference has one row per route family.
-}
routePath :: Route -> Text
routePath route = case routeInfo route of
    (_, path, _, _) -> path

-- | The route's authorization class.
routeClass :: Route -> RouteClass
routeClass route = case routeInfo route of
    (_, _, klass, _) -> klass

-- | What the route needs from its principal; public and share routes need nothing.
routeCapability :: Route -> Maybe Capability
routeCapability route = case routeInfo route of
    (_, _, _, capability) -> capability

-- | All enumerated routes, one representative per parameterised family.
allRoutes :: [Route]
allRoutes =
    [ RouteHealth
    , RouteLoginPage
    , RouteSetupPage
    , RouteRecoverPage
    , RouteRootPage
    , RouteStaticAsset ["{path...}"]
    , RouteFavicon
    , RouteThemeJs
    , RouteManifest
    , RouteServiceWorker
    , RoutePasswordLogin
    , RoutePasskeyLoginOptions
    , RoutePasskeyLoginVerify
    , RouteLegacyPasskeyOptions
    , RouteLegacyPasskeyVerify
    , RoutePasswordSetup
    , RoutePasskeySetupOptionsRetired
    , RoutePasskeySetupVerifyRetired
    , RouteRecoveryRedeem
    , RouteCorsPreflightClip
    , RouteCorsPreflightClipPreview
    , RouteCorsPreflightClipTemplates
    , RouteCorsPreflightClipTemplate 1
    , RouteCorsPreflightWhoami
    , RouteCorsPreflightQuickSave
    , RouteSharePage "u1_token"
    , RouteShareFeed "u1_token"
    , RouteSpaPage
    , RouteSavePage
    , RouteAddPasskeyPage
    , RouteLogout
    , RouteAccountRead
    , RouteAccountTwoFactor
    , RouteAccountPassword
    , RouteAccountUsername
    , RouteAccountSessionsRevokeOthers
    , RouteAccountPasskeyOptions
    , RouteAccountPasskeyVerify
    , RouteAccountPasskeyRename "credential"
    , RouteAccountPasskeyDelete "credential"
    , RouteAccountRecoveryRegenerate
    , RouteTokenList
    , RouteTokenCreate
    , RouteTokenRevoke 1
    , RouteRuleList
    , RouteRuleCreate
    , RouteRuleTest
    , RouteRuleUpdate 1
    , RouteRuleDelete 1
    , RouteClipTemplateCreate
    , RouteClipTemplateUpdate 1
    , RouteClipTemplateDelete 1
    , RouteWebhookList
    , RouteWebhookCreate
    , RouteWebhookRead 1
    , RouteWebhookUpdate 1
    , RouteWebhookDelete 1
    , RouteWebhookTest 1
    , RouteWebhookDeliveries 1
    , RouteWhoami
    , RouteClip
    , RouteClipPreview
    , RouteClipTemplateList
    , RouteClipTemplateRead 1
    , RouteBoot
    , RouteBookmarkList
    , RouteBookmarkCreate
    , RouteBookmarkBulk
    , RouteBookmarkRead 1
    , RouteBookmarkUpdate 1
    , RouteBookmarkDelete 1
    , RouteHighlightList 1
    , RouteHighlightCreate 1
    , RouteHighlightUpdate 1 2
    , RouteHighlightDelete 1 2
    , RouteBookmarkBacklinks 1
    , RouteBookmarkSnapshotRead 1
    , RouteBookmarkOpen 1
    , RouteBookmarkEnrich 1
    , RouteBookmarkExtract 1
    , RouteBookmarkMarkAlive 1
    , RouteBookmarkRecheckLink 1
    , RouteBookmarkSnapshotWrite 1
    , RouteFaviconRead "example.com"
    , RouteQuickSave
    , RouteInboxMarkAbove
    , RouteShareLinkList
    , RouteShareLinkCreate
    , RouteShareLinkRevoke 1
    , RouteTags
    , RouteTagSuggestions "example"
    , RouteTagConsolidationCandidates
    , RouteTagApply
    , RouteTagMerge
    , RouteTagRename ["example"]
    , RouteTagDelete ["example"]
    , RouteAutocomplete
    , RouteGraph
    , RouteGraphLayout
    , RouteViewList
    , RouteViewCreate
    , RouteViewRead "example"
    , RouteViewUpdate "example"
    , RouteViewDelete "example"
    , RouteSavedSearchList
    , RouteSavedSearchCreate
    , RouteSavedSearchDelete 1
    , RouteDedupCandidates
    , RouteDedupMergeAll
    , RouteDedupMerge
    , RouteMaintenanceCheckDead
    , RouteMaintenancePruneCandidates
    , RouteMaintenancePrune
    , RouteUndoList
    , RouteUndoPreview 1
    , RouteUndoApply
    , RouteImport
    , RouteImportJson
    , RouteExport
    , RouteExportNotes
    , RouteStats
    , RouteAiStatus
    , RouteAdminUserList
    , RouteAdminUserCreate
    , RouteAdminUserUpdate 1
    , RouteAdminUserPassword 1
    , RouteAdminUserDelete 1
    ]

{- | The docs table, ordered by path then method. The ordering is the stable
contract of @docs/generated/routes.md@.
-}
routeTable :: [RouteRow]
routeTable =
    sortOn
        (\(method, path, _, _) -> (path, method))
        [routeInfo route | route <- allRoutes]

-- --------------------------------------------------------------- matching ---

{- | Match a request method and split path against the route table. The result
is total: anything that is not an enumerated route is 'Nothing', which callers
must treat as denied.

HEAD is accepted as a read alias for the token routes, because a bearer token
may read them with HEAD. Public pages are served for HEAD by the dispatcher
before the authorization guard, and the session-only routes are GET/POST/
PATCH/DELETE only, so they do not classify HEAD here.
-}
matchRoute :: Text -> [Text] -> Maybe Route
matchRoute method path = case T.toUpper method of
    "GET" -> matchGet path
    "HEAD" -> matchHead path
    "POST" -> matchPost path
    "PATCH" -> matchPatch path
    "DELETE" -> matchDelete path
    "OPTIONS" -> matchOptions path
    _ -> Nothing

matchHead :: [Text] -> Maybe Route
matchHead path = case matchGet path of
    Just route
        | routeClass route == TokenClass -> Just route
    _ -> Nothing

matchGet :: [Text] -> Maybe Route
matchGet path = case path of
    ["healthz"] -> Just RouteHealth
    ["login"] -> Just RouteLoginPage
    ["setup"] -> Just RouteSetupPage
    ["recover"] -> Just RouteRecoverPage
    [] -> Just RouteRootPage
    ["favicon.svg"] -> Just RouteFavicon
    ["theme.js"] -> Just RouteThemeJs
    ["manifest.webmanifest"] -> Just RouteManifest
    ["sw.js"] -> Just RouteServiceWorker
    ["save"] -> Just RouteSavePage
    ["account", "add-passkey"] -> Just RouteAddPasskeyPage
    ("assets" : segments) -> Just (RouteStaticAsset segments)
    ["s", token] -> Just (sharePageRoute token)
    ["api", "v1", "whoami"] -> Just RouteWhoami
    ["api", "v1", "clip-templates"] -> Just RouteClipTemplateList
    ["api", "v1", "clip-templates", idText] -> RouteClipTemplateRead <$> readInt idText
    ["api", "v1", "boot"] -> Just RouteBoot
    ["api", "v1", "bookmarks"] -> Just RouteBookmarkList
    ["api", "v1", "bookmarks", idText] -> RouteBookmarkRead <$> readInt idText
    ["api", "v1", "bookmarks", idText, "highlights"] -> RouteHighlightList <$> readInt idText
    ["api", "v1", "bookmarks", idText, "backlinks"] -> RouteBookmarkBacklinks <$> readInt idText
    ["api", "v1", "bookmarks", idText, "snapshot"] -> RouteBookmarkSnapshotRead <$> readInt idText
    ["api", "v1", "favicons", domain] -> Just (RouteFaviconRead domain)
    ["api", "v1", "share-links"] -> Just RouteShareLinkList
    ["api", "v1", "tags"] -> Just RouteTags
    ["api", "v1", "tags", "consolidation-candidates"] -> Just RouteTagConsolidationCandidates
    ["api", "v1", "tags", tag, "suggestions"] -> Just (RouteTagSuggestions tag)
    ["api", "v1", "autocomplete"] -> Just RouteAutocomplete
    ["api", "v1", "graph"] -> Just RouteGraph
    ["api", "v1", "graph", "layout"] -> Just RouteGraphLayout
    ["api", "v1", "views"] -> Just RouteViewList
    ["api", "v1", "views", slug] -> Just (RouteViewRead slug)
    ["api", "v1", "webhooks"] -> Just RouteWebhookList
    ["api", "v1", "webhooks", idText] -> RouteWebhookRead <$> readInt idText
    ["api", "v1", "webhooks", idText, "deliveries"] -> RouteWebhookDeliveries <$> readInt idText
    ["api", "v1", "saved-searches"] -> Just RouteSavedSearchList
    ["api", "v1", "dedup", "candidates"] -> Just RouteDedupCandidates
    ["api", "v1", "maintenance", "prune-candidates"] -> Just RouteMaintenancePruneCandidates
    ["api", "v1", "undo"] -> Just RouteUndoList
    ["api", "v1", "undo", idText] -> RouteUndoPreview <$> readInt idText
    ["api", "v1", "export"] -> Just RouteExport
    ["api", "v1", "export", "notes"] -> Just RouteExportNotes
    ["api", "v1", "stats"] -> Just RouteStats
    ["api", "v1", "ai", "status"] -> Just RouteAiStatus
    ["api", "v1", "rules"] -> Just RouteRuleList
    ["api", "v1", "tokens"] -> Just RouteTokenList
    ["api", "v1", "account"] -> Just RouteAccountRead
    ["api", "v1", "admin", "users"] -> Just RouteAdminUserList
    _ -> matchSpaPage path

matchPost :: [Text] -> Maybe Route
matchPost path = case path of
    ["api", "auth", "login"] -> Just RoutePasswordLogin
    ["api", "auth", "passkey", "options"] -> Just RoutePasskeyLoginOptions
    ["api", "auth", "passkey", "verify"] -> Just RoutePasskeyLoginVerify
    ["api", "auth", "options"] -> Just RouteLegacyPasskeyOptions
    ["api", "auth", "verify"] -> Just RouteLegacyPasskeyVerify
    ["api", "auth", "logout"] -> Just RouteLogout
    ["api", "setup", "password"] -> Just RoutePasswordSetup
    ["api", "setup", "options"] -> Just RoutePasskeySetupOptionsRetired
    ["api", "setup", "verify"] -> Just RoutePasskeySetupVerifyRetired
    ["api", "recovery", "redeem"] -> Just RouteRecoveryRedeem
    ["api", "v1", "clip"] -> Just RouteClip
    ["api", "v1", "clip", "preview"] -> Just RouteClipPreview
    ["api", "v1", "clip-templates"] -> Just RouteClipTemplateCreate
    ["api", "v1", "bookmarks"] -> Just RouteBookmarkCreate
    ["api", "v1", "bookmarks", "bulk"] -> Just RouteBookmarkBulk
    ["api", "v1", "bookmarks", idText, "highlights"] -> RouteHighlightCreate <$> readInt idText
    ["api", "v1", "bookmarks", idText, action] -> do
        bookmarkId <- readInt idText
        bookmarkActionRoute bookmarkId action
    ["api", "v1", "quick-save"] -> Just RouteQuickSave
    ["api", "v1", "inbox", "mark-all-above"] -> Just RouteInboxMarkAbove
    ["api", "v1", "share-links"] -> Just RouteShareLinkCreate
    ["api", "v1", "views"] -> Just RouteViewCreate
    ["api", "v1", "webhooks"] -> Just RouteWebhookCreate
    ["api", "v1", "webhooks", idText, "test"] -> RouteWebhookTest <$> readInt idText
    ["api", "v1", "saved-searches"] -> Just RouteSavedSearchCreate
    ["api", "v1", "dedup", "merge-all"] -> Just RouteDedupMergeAll
    ["api", "v1", "dedup", "merge"] -> Just RouteDedupMerge
    ["api", "v1", "tags", "apply"] -> Just RouteTagApply
    ["api", "v1", "tags", "merge"] -> Just RouteTagMerge
    ("api" : "v1" : "tags" : segments)
        | not (null segments) -> Just (RouteTagRename segments)
    ["api", "v1", "maintenance", "check-dead"] -> Just RouteMaintenanceCheckDead
    ["api", "v1", "maintenance", "prune"] -> Just RouteMaintenancePrune
    ["api", "v1", "undo"] -> Just RouteUndoApply
    ["api", "v1", "import"] -> Just RouteImport
    ["api", "v1", "import", "json"] -> Just RouteImportJson
    ["api", "v1", "rules"] -> Just RouteRuleCreate
    ["api", "v1", "rules", "test"] -> Just RouteRuleTest
    ["api", "v1", "tokens"] -> Just RouteTokenCreate
    ["api", "v1", "account", "2fa"] -> Just RouteAccountTwoFactor
    ["api", "v1", "account", "password"] -> Just RouteAccountPassword
    ["api", "v1", "account", "username"] -> Just RouteAccountUsername
    ["api", "v1", "account", "sessions", "revoke-others"] -> Just RouteAccountSessionsRevokeOthers
    ["api", "v1", "account", "passkeys", "options"] -> Just RouteAccountPasskeyOptions
    ["api", "v1", "account", "passkeys", "verify"] -> Just RouteAccountPasskeyVerify
    ["api", "v1", "account", "recovery", "regenerate"] -> Just RouteAccountRecoveryRegenerate
    ["api", "v1", "admin", "users"] -> Just RouteAdminUserCreate
    ["api", "v1", "admin", "users", idText, "password"] -> RouteAdminUserPassword <$> readInt idText
    _ -> Nothing

bookmarkActionRoute :: Int -> Text -> Maybe Route
bookmarkActionRoute bookmarkId action = case action of
    "open" -> Just (RouteBookmarkOpen bookmarkId)
    "enrich" -> Just (RouteBookmarkEnrich bookmarkId)
    "extract" -> Just (RouteBookmarkExtract bookmarkId)
    "mark-alive" -> Just (RouteBookmarkMarkAlive bookmarkId)
    "recheck-link" -> Just (RouteBookmarkRecheckLink bookmarkId)
    "snapshot" -> Just (RouteBookmarkSnapshotWrite bookmarkId)
    _ -> Nothing

matchPatch :: [Text] -> Maybe Route
matchPatch path = case path of
    ["api", "v1", "bookmarks", idText] -> RouteBookmarkUpdate <$> readInt idText
    ["api", "v1", "bookmarks", idText, "highlights", highlightText] ->
        RouteHighlightUpdate <$> readInt idText <*> readInt highlightText
    ["api", "v1", "clip-templates", idText] -> RouteClipTemplateUpdate <$> readInt idText
    ["api", "v1", "views", slug] -> Just (RouteViewUpdate slug)
    ["api", "v1", "webhooks", idText] -> RouteWebhookUpdate <$> readInt idText
    ["api", "v1", "rules", idText] -> RouteRuleUpdate <$> readInt idText
    ["api", "v1", "account", "passkeys", credential] ->
        Just (RouteAccountPasskeyRename credential)
    ["api", "v1", "admin", "users", idText] -> RouteAdminUserUpdate <$> readInt idText
    _ -> Nothing

matchDelete :: [Text] -> Maybe Route
matchDelete path = case path of
    ["api", "v1", "bookmarks", idText] -> RouteBookmarkDelete <$> readInt idText
    ["api", "v1", "bookmarks", idText, "highlights", highlightText] ->
        RouteHighlightDelete <$> readInt idText <*> readInt highlightText
    ["api", "v1", "clip-templates", idText] -> RouteClipTemplateDelete <$> readInt idText
    ["api", "v1", "share-links", idText] -> RouteShareLinkRevoke <$> readInt idText
    ["api", "v1", "views", slug] -> Just (RouteViewDelete slug)
    ["api", "v1", "webhooks", idText] -> RouteWebhookDelete <$> readInt idText
    ["api", "v1", "saved-searches", idText] -> RouteSavedSearchDelete <$> readInt idText
    ["api", "v1", "tokens", idText] -> RouteTokenRevoke <$> readInt idText
    ["api", "v1", "rules", idText] -> RouteRuleDelete <$> readInt idText
    ["api", "v1", "account", "passkeys", credential] ->
        Just (RouteAccountPasskeyDelete credential)
    ["api", "v1", "admin", "users", idText] -> RouteAdminUserDelete <$> readInt idText
    ("api" : "v1" : "tags" : segments)
        | not (null segments) -> Just (RouteTagDelete segments)
    _ -> Nothing

matchOptions :: [Text] -> Maybe Route
matchOptions path = case path of
    ["api", "v1", "clip"] -> Just RouteCorsPreflightClip
    ["api", "v1", "clip", "preview"] -> Just RouteCorsPreflightClipPreview
    ["api", "v1", "clip-templates"] -> Just RouteCorsPreflightClipTemplates
    ["api", "v1", "clip-templates", idText] ->
        RouteCorsPreflightClipTemplate <$> readInt idText
    ["api", "v1", "whoami"] -> Just RouteCorsPreflightWhoami
    ["api", "v1", "quick-save"] -> Just RouteCorsPreflightQuickSave
    _ -> Nothing

{- | The share handler also serves an Atom feed for a saved-search share: the
token keeps its wire form and only the @.xml@ suffix selects the feed.
-}
sharePageRoute :: Text -> Route
sharePageRoute token
    | ".xml" `T.isSuffixOf` token = RouteShareFeed (T.dropEnd 4 token)
    | otherwise = RouteSharePage token

{- | The authenticated single-page-app shell: every GET that is neither an API
path nor an asset serves the shell. This mirrors the session fallback in
"Eza.Authz" that the guard has always applied.
-}
matchSpaPage :: [Text] -> Maybe Route
matchSpaPage path = case path of
    [] -> Nothing
    ("api" : _) -> Nothing
    _
        | "assets" `elem` path -> Nothing
        | otherwise -> Just RouteSpaPage

readInt :: Text -> Maybe Int
readInt text = readMaybe (T.unpack text)

-- ---------------------------------------------------------------- concrete ---

{- | Render a route to the concrete request path, filling in its parsed
parameters. 'routePath' returns the docs template; this function is what a
caller uses to build or re-parse an actual request.
-}
renderRoutePath :: Route -> Text
renderRoutePath route = case route of
    RouteStaticAsset segments -> renderSegments "/assets" segments
    RouteSharePage token -> "/s/" <> token
    RouteShareFeed token -> "/s/" <> token <> ".xml"
    RouteCorsPreflightClipTemplate templateId -> "/api/v1/clip-templates/" <> intText templateId
    RouteAccountPasskeyRename credential -> "/api/v1/account/passkeys/" <> credential
    RouteAccountPasskeyDelete credential -> "/api/v1/account/passkeys/" <> credential
    RouteTokenRevoke tokenId -> idPath "/api/v1/tokens" tokenId
    RouteRuleUpdate ruleId -> idPath "/api/v1/rules" ruleId
    RouteRuleDelete ruleId -> idPath "/api/v1/rules" ruleId
    RouteClipTemplateUpdate templateId -> idPath "/api/v1/clip-templates" templateId
    RouteClipTemplateDelete templateId -> idPath "/api/v1/clip-templates" templateId
    RouteClipTemplateRead templateId -> idPath "/api/v1/clip-templates" templateId
    RouteWebhookRead webhookId -> idPath "/api/v1/webhooks" webhookId
    RouteWebhookUpdate webhookId -> idPath "/api/v1/webhooks" webhookId
    RouteWebhookDelete webhookId -> idPath "/api/v1/webhooks" webhookId
    RouteWebhookTest webhookId -> idPath "/api/v1/webhooks" webhookId <> "/test"
    RouteWebhookDeliveries webhookId -> idPath "/api/v1/webhooks" webhookId <> "/deliveries"
    RouteBookmarkRead bookmarkId -> idPath "/api/v1/bookmarks" bookmarkId
    RouteBookmarkUpdate bookmarkId -> idPath "/api/v1/bookmarks" bookmarkId
    RouteBookmarkDelete bookmarkId -> idPath "/api/v1/bookmarks" bookmarkId
    RouteHighlightList bookmarkId -> idPath "/api/v1/bookmarks" bookmarkId <> "/highlights"
    RouteHighlightCreate bookmarkId -> idPath "/api/v1/bookmarks" bookmarkId <> "/highlights"
    RouteHighlightUpdate bookmarkId highlightId ->
        idPath "/api/v1/bookmarks" bookmarkId <> "/highlights/" <> intText highlightId
    RouteHighlightDelete bookmarkId highlightId ->
        idPath "/api/v1/bookmarks" bookmarkId <> "/highlights/" <> intText highlightId
    RouteBookmarkBacklinks bookmarkId -> idPath "/api/v1/bookmarks" bookmarkId <> "/backlinks"
    RouteBookmarkSnapshotRead bookmarkId -> idPath "/api/v1/bookmarks" bookmarkId <> "/snapshot"
    RouteBookmarkSnapshotWrite bookmarkId -> idPath "/api/v1/bookmarks" bookmarkId <> "/snapshot"
    RouteBookmarkOpen bookmarkId -> idPath "/api/v1/bookmarks" bookmarkId <> "/open"
    RouteBookmarkEnrich bookmarkId -> idPath "/api/v1/bookmarks" bookmarkId <> "/enrich"
    RouteBookmarkExtract bookmarkId -> idPath "/api/v1/bookmarks" bookmarkId <> "/extract"
    RouteBookmarkMarkAlive bookmarkId -> idPath "/api/v1/bookmarks" bookmarkId <> "/mark-alive"
    RouteBookmarkRecheckLink bookmarkId -> idPath "/api/v1/bookmarks" bookmarkId <> "/recheck-link"
    RouteFaviconRead domain -> "/api/v1/favicons/" <> domain
    RouteShareLinkRevoke shareId -> idPath "/api/v1/share-links" shareId
    RouteTagSuggestions tag -> "/api/v1/tags/" <> tag <> "/suggestions"
    RouteTagRename segments -> renderSegments "/api/v1/tags" segments
    RouteTagDelete segments -> renderSegments "/api/v1/tags" segments
    RouteViewRead slug -> "/api/v1/views/" <> slug
    RouteViewUpdate slug -> "/api/v1/views/" <> slug
    RouteViewDelete slug -> "/api/v1/views/" <> slug
    RouteSavedSearchDelete savedSearchId -> idPath "/api/v1/saved-searches" savedSearchId
    RouteUndoPreview snapshotId -> idPath "/api/v1/undo" snapshotId
    RouteAdminUserUpdate userId -> idPath "/api/v1/admin/users" userId
    RouteAdminUserPassword userId -> idPath "/api/v1/admin/users" userId <> "/password"
    RouteAdminUserDelete userId -> idPath "/api/v1/admin/users" userId
    RouteSpaPage -> routePath route
    _ -> routePath route

idPath :: Text -> Int -> Text
idPath prefix value = prefix <> "/" <> intText value

intText :: Int -> Text
intText = T.pack . show

renderSegments :: Text -> [Text] -> Text
renderSegments prefix segments = case segments of
    [] -> prefix
    _ -> prefix <> "/" <> T.intercalate "/" segments

-- ------------------------------------------------------------------ docs ---

-- | The class label used in the generated reference.
routeClassText :: RouteClass -> Text
routeClassText = \case
    PublicClass -> "public"
    SessionClass -> "session"
    TokenClass -> "token"
    AdminClass -> "admin"
    ShareClass -> "share"
    DeniedClass -> "denied"

-- | The capability label used in the generated reference.
capabilityText :: Maybe Capability -> Text
capabilityText Nothing = "-"
capabilityText (Just capability) = case capability of
    CapRead -> "read"
    CapWrite -> "write"
    CapCaptureRead -> "capture-read"
    CapCaptureWrite -> "capture-write"
    CapSession -> "session"
    CapAdmin -> "admin"

{- | The generated Markdown reference. This is the exact payload of
@eza-bookmarks routes --markdown@ and the content of
@docs/generated/routes.md@; do not edit the generated file by hand.
-}
routesMarkdown :: Text
routesMarkdown =
    T.unlines
        ( [ "# HTTP routes"
          , ""
          , "Generated by `eza-bookmarks routes --markdown`; do not edit by hand."
          , ""
          , "| Method | Path | Class | Capability |"
          , "|---|---|---|---|"
          ]
            <> map markdownRow routeTable
        )

markdownRow :: RouteRow -> Text
markdownRow (method, path, klass, capability) =
    T.intercalate
        " | "
        [ "| " <> method
        , "`" <> path <> "`"
        , routeClassText klass
        , capabilityText capability <> " |"
        ]

-- ----------------------------------------------------------------- scopes ---

scopeFromText :: Text -> Maybe Scope
scopeFromText raw = case T.toLower (T.strip raw) of
    "read" -> Just ScopeRead
    "write" -> Just ScopeWrite
    "capture" -> Just ScopeCapture
    _ -> Nothing

scopeText :: Scope -> Text
scopeText = \case
    ScopeRead -> "read"
    ScopeWrite -> "write"
    ScopeCapture -> "capture"
