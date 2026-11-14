{-# LANGUAGE OverloadedStrings #-}

{- | Pins every client request against the path literal the Miso client built
before it adopted "Eza.Routes". The table is the migration contract: the
method comes from the shared route table, and the rendered path must equal the
old literal byte for byte.
-}
module ApiSpec (apiSpec) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Eza.GraphLayout (LayoutPreset (..))
import Eza.Web.Logic.Api (
    BookmarkListQuery (..),
    ClientRequest (..),
    DedupCandidateQuery (..),
    requestMethod,
    requestPath,
 )

{- | One entry per client endpoint: the request, its method, and the URL
literal "Eza.Web.Api" used before M2-A.
-}
literalTable :: [(ClientRequest, Text, Text)]
literalTable =
    [ -- reads
      (ApiBoot, "GET", "/api/v1/boot")
    , (ApiBookmarks (BookmarkListQuery "" [] "created" False 0 60), "GET", "/api/v1/bookmarks?limit=60&offset=0&sort=created")
    ,
        ( ApiBookmarks (BookmarkListQuery "rust lang" ["a b", "c"] "title" True 20 60)
        , "GET"
        , "/api/v1/bookmarks?limit=60&offset=20&q=rust%20lang&tags=a%20b,c&is_read=0&sort=title"
        )
    , (ApiBookmark 7, "GET", "/api/v1/bookmarks/7")
    , (ApiBookmarkBacklinks 7, "GET", "/api/v1/bookmarks/7/backlinks")
    , (ApiAutocomplete "rust lang", "GET", "/api/v1/autocomplete?q=rust%20lang")
    , (ApiGraph, "GET", "/api/v1/graph")
    , (ApiGraphLayout Compact, "GET", "/api/v1/graph/layout?preset=compact")
    , (ApiGraphLayout Standard, "GET", "/api/v1/graph/layout?preset=standard")
    , (ApiGraphLayout Airy, "GET", "/api/v1/graph/layout?preset=airy")
    , (ApiViews, "GET", "/api/v1/views")
    , (ApiView "two words", "GET", "/api/v1/views/two%20words")
    , (ApiWebhooks, "GET", "/api/v1/webhooks")
    , (ApiWebhook 3, "GET", "/api/v1/webhooks/3")
    , (ApiWebhookDeliveries 3, "GET", "/api/v1/webhooks/3/deliveries?limit=20")
    , (ApiAdminUsers, "GET", "/api/v1/admin/users")
    , (ApiSavedSearches, "GET", "/api/v1/saved-searches")
    ,
        ( ApiDedupCandidates (DedupCandidateQuery 0 50 0 50)
        , "GET"
        , "/api/v1/dedup/candidates?url_offset=0&url_limit=50&title_offset=0&title_limit=50"
        )
    ,
        ( ApiDedupCandidates (DedupCandidateQuery (-5) 25 (-1) 10)
        , "GET"
        , "/api/v1/dedup/candidates?url_offset=0&url_limit=25&title_offset=0&title_limit=10"
        )
    , (ApiTagConsolidationCandidates, "GET", "/api/v1/tags/consolidation-candidates")
    , (ApiAiSuggestionsJob, "POST", "/api/v1/ai/suggestions")
    , (ApiJobStatus 42, "GET", "/api/v1/jobs/42")
    , (ApiMaintenancePruneCandidates, "GET", "/api/v1/maintenance/prune-candidates")
    , (ApiAccount, "GET", "/api/v1/account")
    , (ApiTags, "GET", "/api/v1/tags")
    , (ApiStats, "GET", "/api/v1/stats")
    , (ApiUndoEntries, "GET", "/api/v1/undo?limit=5")
    , (ApiUndoPreview 4, "GET", "/api/v1/undo/4")
    , (ApiTokens, "GET", "/api/v1/tokens")
    , (ApiHighlights 12, "GET", "/api/v1/bookmarks/12/highlights")
    , (ApiShares, "GET", "/api/v1/share-links")
    , (ApiAiStatus, "GET", "/api/v1/ai/status")
    , (ApiRules, "GET", "/api/v1/rules")
    , (ApiExport, "GET", "/api/v1/export")
    , (ApiExportNotes, "GET", "/api/v1/export/notes")
    , (ApiWhoami, "GET", "/api/v1/whoami")
    , (ApiClipTemplates, "GET", "/api/v1/clip-templates")
    , (ApiClipTemplate 9, "GET", "/api/v1/clip-templates/9")
    , -- writes (adopted in M2-B; the literals stay in Eza.Web.Api this round)
      (ApiCreateView, "POST", "/api/v1/views")
    , (ApiPatchView "v 1", "PATCH", "/api/v1/views/v%201")
    , (ApiDeleteView "v 1", "DELETE", "/api/v1/views/v%201")
    , (ApiCreateWebhook, "POST", "/api/v1/webhooks")
    , (ApiPatchWebhook 3, "PATCH", "/api/v1/webhooks/3")
    , (ApiDeleteWebhook 3, "DELETE", "/api/v1/webhooks/3")
    , (ApiTestWebhook 3, "POST", "/api/v1/webhooks/3/test")
    , (ApiCreateAdminUser, "POST", "/api/v1/admin/users")
    , (ApiPatchAdminUser 2, "PATCH", "/api/v1/admin/users/2")
    , (ApiResetAdminPassword 2, "POST", "/api/v1/admin/users/2/password")
    , (ApiDeleteAdminUser 2, "DELETE", "/api/v1/admin/users/2")
    , (ApiCreateBookmark, "POST", "/api/v1/bookmarks")
    , (ApiQuickSave, "POST", "/api/v1/quick-save")
    , (ApiPatchBookmark 7, "PATCH", "/api/v1/bookmarks/7")
    , (ApiDeleteBookmark 7, "DELETE", "/api/v1/bookmarks/7")
    , (ApiMarkAllAbove, "POST", "/api/v1/inbox/mark-all-above")
    , (ApiTrackOpen 7, "POST", "/api/v1/bookmarks/7/open")
    , (ApiBookmarkAction 7 "enrich", "POST", "/api/v1/bookmarks/7/enrich")
    , (ApiBookmarkAction 7 "extract", "POST", "/api/v1/bookmarks/7/extract")
    , (ApiBookmarkAction 7 "mark-alive", "POST", "/api/v1/bookmarks/7/mark-alive")
    , (ApiBookmarkAction 7 "recheck-link", "POST", "/api/v1/bookmarks/7/recheck-link")
    , (ApiBookmarkAction 7 "snapshot", "POST", "/api/v1/bookmarks/7/snapshot")
    , (ApiBookmarkAction 7 "custom-verb", "POST", "/api/v1/bookmarks/7/custom-verb")
    , (ApiCreateSavedSearch, "POST", "/api/v1/saved-searches")
    , (ApiDeleteSavedSearch 5, "DELETE", "/api/v1/saved-searches/5")
    , (ApiMergeDedup, "POST", "/api/v1/dedup/merge")
    , (ApiMergeDedupAll, "POST", "/api/v1/dedup/merge-all")
    , (ApiMergeTags, "POST", "/api/v1/tags/merge")
    , (ApiRenameTag "old tag", "POST", "/api/v1/tags/old%20tag")
    , (ApiDeleteTag "old/tag", "DELETE", "/api/v1/tags/old%2Ftag")
    , (ApiDetachTag "old tag", "DELETE", "/api/v1/tags/old%20tag?detach=true")
    , (ApiApplyTagSuggestion, "POST", "/api/v1/tags/apply")
    , (ApiRunPrune, "POST", "/api/v1/maintenance/prune")
    , (ApiCheckDead, "POST", "/api/v1/maintenance/check-dead")
    , (ApiRunUndo, "POST", "/api/v1/undo")
    , (ApiMarkLinkAlive 7, "POST", "/api/v1/bookmarks/7/mark-alive")
    , (ApiRecheckLink 7, "POST", "/api/v1/bookmarks/7/recheck-link")
    , (ApiRegenerateRecovery, "POST", "/api/v1/account/recovery/regenerate")
    , (ApiRenameCredential "cred id", "PATCH", "/api/v1/account/passkeys/cred%20id")
    , (ApiDeleteCredential "cred id", "DELETE", "/api/v1/account/passkeys/cred%20id")
    , (ApiPatchUsername, "POST", "/api/v1/account/username")
    , (ApiChangePassword, "POST", "/api/v1/account/password")
    , (ApiSetPasskeyRequirement, "POST", "/api/v1/account/2fa")
    , (ApiRevokeOtherSessions, "POST", "/api/v1/account/sessions/revoke-others")
    , (ApiLogout, "POST", "/api/auth/logout")
    , (ApiSubmitImport, "POST", "/api/v1/import")
    , (ApiBulkUpdate, "POST", "/api/v1/bookmarks/bulk")
    , (ApiCreateApiToken, "POST", "/api/v1/tokens")
    , (ApiRevokeApiToken 8, "DELETE", "/api/v1/tokens/8")
    , (ApiCreateHighlight 12, "POST", "/api/v1/bookmarks/12/highlights")
    , (ApiPatchHighlight 12 3, "PATCH", "/api/v1/bookmarks/12/highlights/3")
    , (ApiDeleteHighlight 12 3, "DELETE", "/api/v1/bookmarks/12/highlights/3")
    , (ApiCreateShareLink, "POST", "/api/v1/share-links")
    , (ApiRevokeShareLink 4, "DELETE", "/api/v1/share-links/4")
    , (ApiCreateRule, "POST", "/api/v1/rules")
    , (ApiPatchRule 6, "PATCH", "/api/v1/rules/6")
    , (ApiDeleteRule 6, "DELETE", "/api/v1/rules/6")
    , (ApiTestRule, "POST", "/api/v1/rules/test")
    ]

apiSpec :: Spec
apiSpec = describe "Eza.Web.Logic.Api" $ do
    it "renders the path of every client request as the previous literal" $
        mapM_
            (\(request, _, literal) -> requestPath request `shouldBe` literal)
            literalTable

    it "reads the method from the shared route table" $
        mapM_
            (\(request, method, _) -> requestMethod request `shouldBe` method)
            literalTable

    it "only uses JSON methods" $
        mapM_
            (\(request, _, _) -> requestMethod request `shouldSatisfy` (`elem` ["GET", "POST", "PATCH", "DELETE"]))
            literalTable

    it "addresses the versioned API or the auth ceremony" $
        mapM_
            (\(request, _, _) -> requestPath request `shouldSatisfy` T.isPrefixOf "/api/")
            literalTable
