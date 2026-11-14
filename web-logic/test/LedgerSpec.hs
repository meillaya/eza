{-# LANGUAGE OverloadedStrings #-}

{- | The ledger/search reducer, tested natively: request ids, the debounce
timer, the forwarded paging and the stale-response policy. Every case calls
'updateLedger' directly and inspects the returned effects, so no browser or
WebAssembly toolchain is involved.
-}
module LedgerSpec (ledgerSpec) where

import Test.Hspec

import Eza.Types (
    BookmarkSummary (..),
    LibraryStats (..),
    SearchPage (..),
 )

import Eza.Web.Logic.Api (BookmarkListQuery (..), ClientRequest (..))
import Eza.Web.Logic.Effect (Effect (..), RequestId (..), TimerId (..))
import Eza.Web.Logic.Ledger (
    LedgerAction (..),
    LedgerState (..),
    debounceTimerIsCurrent,
    defaultLedgerLimit,
    initialLedgerState,
    ledgerListQuery,
    listRequestIsCurrent,
    searchDebounceDelayMs,
    statsRequestIsCurrent,
    updateLedger,
 )

ledgerSpec :: Spec
ledgerSpec = describe "Eza.Web.Logic.Ledger" $ do
    describe "initial state" $ do
        it "is the default unfiltered newest-filed query" $ do
            ledgerListQuery initialLedgerState False
                `shouldBe` BookmarkListQuery
                    { blqQ = ""
                    , blqTags = []
                    , blqSort = "created"
                    , blqUnreadOnly = False
                    , blqOffset = 0
                    , blqLimit = defaultLedgerLimit
                    }
        it "starts with no rows, no error and no pending timer" $ do
            ldItems initialLedgerState `shouldBe` []
            ldHasMore initialLedgerState `shouldBe` False
            ldError initialLedgerState `shouldBe` Nothing
            ldDebounceTimer initialLedgerState `shouldBe` Nothing
            ldListRequest initialLedgerState `shouldBe` RequestId 0
            ldStatsRequest initialLedgerState `shouldBe` RequestId 0
    describe "search input" $ do
        it "keeps the rows visible while the debounce waits" $ do
            let (state, _) = updateLedger withItems (SearchInput "rust")
            ldQuery state `shouldBe` "rust"
            ldLoading state `shouldBe` True
            ldHasMore state `shouldBe` False
            ldLoadingMore state `shouldBe` False
            map bsId (ldItems state) `shouldBe` [1, 2]
        it "invalidates the in-flight page at once" $ do
            let (state, _) = updateLedger withItems (SearchInput "rust")
            ldListRequest state `shouldSatisfy` (> ldListRequest withItems)
        it "schedules the debounce timer under a fresh id" $ do
            let (state, effects) = updateLedger initialLedgerState (SearchInput "rust")
            effects `shouldBe` [Schedule searchDebounceDelayMs (TimerId 1)]
            ldDebounceTimer state `shouldBe` Just (TimerId 1)
            debounceTimerIsCurrent state (TimerId 1) `shouldBe` True
        it "cancels the pending timer before scheduling the next one" $ do
            let (state, _) = updateLedger initialLedgerState (SearchInput "r")
                (state', effects) = updateLedger state (SearchInput "ru")
            effects `shouldBe` [CancelTimer (TimerId 1), Schedule searchDebounceDelayMs (TimerId 2)]
            ldDebounceTimer state' `shouldBe` Just (TimerId 2)
            debounceTimerIsCurrent state' (TimerId 1) `shouldBe` False
        it "clears a previous error immediately" $ do
            let (failed, _) = updateLedger initialLedgerState (ListFailed (RequestId 0) "boom")
                (state, _) = updateLedger failed (SearchInput "x")
            ldError failed `shouldBe` Just "boom"
            ldError state `shouldBe` Nothing
    describe "debounced search" $ do
        it "reloads the first page when the current timer fires" $ do
            let (state, _) = updateLedger initialLedgerState (SearchInput "rust")
                (state', effects) = updateLedger state (SearchDebounceElapsed (TimerId 1))
                requestId = ldListRequest state'
            ldDebounceTimer state' `shouldBe` Nothing
            effects
                `shouldBe` [ Fetch
                                (ApiBookmarks (BookmarkListQuery "rust" [] "created" False 0 defaultLedgerLimit))
                                requestId
                           ]
            requestId `shouldSatisfy` (> ldListRequest state)
            ldLoading state' `shouldBe` True
            listRequestIsCurrent state' requestId `shouldBe` True
        it "ignores a timer that is no longer current" $ do
            let (state, _) = updateLedger initialLedgerState (SearchInput "rust")
                stale = updateLedger state (SearchDebounceElapsed (TimerId 0))
            stale `shouldBe` (state, [])
    describe "committed search" $ do
        it "fetches the first page immediately" $ do
            let (state, effects) = updateLedger withItems SearchCommit
            fetchRequests effects
                `shouldBe` [ApiBookmarks (BookmarkListQuery "" [] "created" False 0 defaultLedgerLimit)]
            ldLoading state `shouldBe` True
            ldListRequest state `shouldSatisfy` (> ldListRequest withItems)
        it "starts a new query generation per commit" $ do
            let (first, firstEffects) = updateLedger initialLedgerState SearchCommit
                (_, secondEffects) = updateLedger first SearchCommit
            fetchRequestIds firstEffects `shouldBe` [RequestId 1]
            fetchRequestIds secondEffects `shouldBe` [RequestId 2]
    describe "tag, sort and unread filters" $ do
        it "toggles one tag filter and refetches" $ do
            let (added, addedEffects) = updateLedger initialLedgerState (TagToggled "haskell")
                (removed, removedEffects) = updateLedger added (TagToggled "haskell")
            ldTagFilters added `shouldBe` ["haskell"]
            listQueryOf addedEffects
                `shouldBe` Just (BookmarkListQuery "" ["haskell"] "created" False 0 defaultLedgerLimit)
            ldTagFilters removed `shouldBe` []
            listQueryOf removedEffects
                `shouldBe` Just (BookmarkListQuery "" [] "created" False 0 defaultLedgerLimit)
        it "keeps tag filters in click order" $ do
            let (state, _) = updateLedger initialLedgerState (TagToggled "a")
                (state', _) = updateLedger state (TagToggled "b")
            ldTagFilters state' `shouldBe` ["a", "b"]
        it "starts a new search from the first page" $ do
            let (loaded, _) = updateLedger initialLedgerState (ListLoaded False (RequestId 0) (page 0 [1, 2] True))
                (_, effects) = updateLedger loaded (SearchInput "rust")
            effects `shouldBe` [Schedule searchDebounceDelayMs (TimerId 1)]
            let (_, fired) = updateLedger (fst (updateLedger loaded (SearchInput "rust"))) (SearchDebounceElapsed (TimerId 1))
            fmap blqOffset (listQueryOf fired) `shouldBe` Just 0
        it "selects a sort key and refetches" $ do
            let (state, effects) = updateLedger initialLedgerState (SortSelected "title")
                query = listQueryOf effects
            ldSort state `shouldBe` "title"
            fmap blqSort query `shouldBe` Just "title"
        it "clears every filter, including the unread toggle" $ do
            let (tagged, _) = updateLedger initialLedgerState (TagToggled "a")
                (unread, _) = updateLedger tagged UnreadToggled
                (state, effects) = updateLedger unread ClearFilters
            ldQuery state `shouldBe` ""
            ldTagFilters state `shouldBe` []
            ldUnreadOnly state `shouldBe` False
            listQueryOf effects
                `shouldBe` Just (BookmarkListQuery "" [] "created" False 0 defaultLedgerLimit)
        it "keeps the inbox filter when the unread toggle flips" $ do
            let inbox = initialLedgerState{ldRouteUnread = True}
                (state, effects) = updateLedger inbox UnreadToggled
            ldUnreadOnly state `shouldBe` True
            fmap blqUnreadOnly (listQueryOf effects) `shouldBe` Just True
            ledgerListQuery state False `shouldSatisfy` blqUnreadOnly
    describe "paging" $ do
        it "refuses to load more without another page" $ do
            updateLedger initialLedgerState LoadMore `shouldBe` (initialLedgerState, [])
        it "refuses to load more while the first page is loading" $ do
            let loading = initialLedgerState{ldHasMore = True, ldLoading = True}
            updateLedger loading LoadMore `shouldBe` (loading, [])
        it "refuses to load more while an append is in flight" $ do
            let appending = initialLedgerState{ldHasMore = True, ldLoadingMore = True}
            updateLedger appending LoadMore `shouldBe` (appending, [])
        it "asks for the page after the loaded rows under the same request id" $ do
            let (loaded, _) = updateLedger initialLedgerState (ListLoaded False (RequestId 0) (page 0 [1, 2] True))
                (state, effects) = updateLedger loaded LoadMore
            ldLoadingMore state `shouldBe` True
            listQueryOf effects
                `shouldBe` Just (BookmarkListQuery "" [] "created" False 2 defaultLedgerLimit)
            fetchRequestIds effects `shouldBe` [ldListRequest loaded]
        it "appends the next page and keeps the first page's year counts" $ do
            let (loaded, _) = updateLedger initialLedgerState (ListLoaded False (RequestId 0) (page 0 [1, 2] True))
                (state, _) = updateLedger loaded (ListLoaded True (RequestId 0) (page 2 [3, 4] False))
            map bsId (ldItems state) `shouldBe` [1, 2, 3, 4]
            ldYearCounts state `shouldBe` [(2026, 12)]
            ldHasMore state `shouldBe` False
            ldOffset state `shouldBe` 4
            ldLoading state `shouldBe` False
            ldLoadingMore state `shouldBe` False
        it "starts the next append after the appended rows" $ do
            let (loaded, _) = updateLedger initialLedgerState (ListLoaded False (RequestId 0) (page 0 [1, 2] True))
                (appended, _) = updateLedger loaded (ListLoaded True (RequestId 0) (page 2 [3, 4] True))
                (_, effects) = updateLedger appended LoadMore
            fmap blqOffset (listQueryOf effects) `shouldBe` Just 4
            fetchRequestIds effects `shouldBe` [RequestId 0]
        it "replaces the rows and the year counts on a first-page answer" $ do
            let (loaded, _) = updateLedger initialLedgerState (ListLoaded False (RequestId 0) (page 0 [1, 2] True))
                (state, _) = updateLedger loaded (ListLoaded False (RequestId 0) (page 0 [9] False))
            map bsId (ldItems state) `shouldBe` [9]
            ldYearCounts state `shouldBe` [(2026, 11)]
            ldOffset state `shouldBe` 1
        it "ignores a page for an older query generation" $ do
            let loaded = initialLedgerState{ldListRequest = RequestId 7}
            updateLedger loaded (ListLoaded False (RequestId 6) (page 0 [1] False))
                `shouldBe` (loaded, [])
    describe "failures" $ do
        it "records the message and stops the loading indicator" $ do
            let loading = initialLedgerState{ldLoading = True, ldHasMore = True}
                (state, effects) = updateLedger loading (ListFailed (RequestId 0) "network down")
            ldError state `shouldBe` Just "network down"
            ldLoading state `shouldBe` False
            ldLoadingMore state `shouldBe` False
            effects `shouldBe` []
        it "ignores a failure for an older query generation" $ do
            let loaded = initialLedgerState{ldListRequest = RequestId 7, ldLoading = True}
            updateLedger loaded (ListFailed (RequestId 6) "late")
                `shouldBe` (loaded, [])
        it "keeps the recovery rows available" $ do
            let (loaded, _) = updateLedger withItems (ListLoaded False (RequestId 0) (page 0 [1, 2] True))
                (failed, _) = updateLedger loaded (ListFailed (RequestId 0) "boom")
            map bsId (ldItems failed) `shouldBe` [1, 2]
        it "clears the error on the next accepted load" $ do
            let failed = initialLedgerState{ldError = Just "boom"}
                (state, _) = updateLedger failed (ListLoaded False (RequestId 0) (page 0 [1] False))
            ldError state `shouldBe` Nothing
    describe "request id monotonicity" $ do
        it "increases the list request id for every new generation" $ do
            let step state action = fst (updateLedger state action)
                generations =
                    scanl
                        step
                        initialLedgerState
                        [SearchCommit, Reload, TagToggled "a", SortSelected "title"]
                ids = map ldListRequest generations
            ids `shouldBe` map RequestId [0, 1, 2, 3, 4]
            ids `shouldSatisfy` strictlyIncreasing
        it "keeps one request id for an append page" $ do
            let (loaded, _) = updateLedger initialLedgerState (ListLoaded False (RequestId 0) (page 0 [1] True))
                (state, effects) = updateLedger loaded LoadMore
            fetchRequestIds effects `shouldBe` [RequestId 0]
            ldListRequest state `shouldBe` RequestId 0
        it "rejects a response with an id that is not current" $ do
            let (state, _) = updateLedger initialLedgerState SearchCommit
            listRequestIsCurrent state (RequestId 1) `shouldBe` True
            listRequestIsCurrent state (RequestId 0) `shouldBe` False
    describe "stats refresh" $ do
        it "fetches the counts under a fresh request id" $ do
            let (state, effects) = updateLedger initialLedgerState StatsRequested
            effects `shouldBe` [Fetch ApiStats (RequestId 1)]
            ldStatsRequest state `shouldBe` RequestId 1
        it "increases the request id on every refresh" $ do
            let (first, _) = updateLedger initialLedgerState StatsRequested
                (second, _) = updateLedger first StatsRequested
            ldStatsRequest second `shouldBe` RequestId 2
        it "stores the counts and clears the error" $ do
            let failed = initialLedgerState{ldStatsError = Just "old"}
                (state, effects) = updateLedger failed (StatsLoaded (RequestId 0) testStats)
            effects `shouldBe` []
            ldStats state `shouldBe` Just testStats
            ldStatsError state `shouldBe` Nothing
        it "ignores a stale answer and a stale failure" $ do
            let requested = initialLedgerState{ldStatsRequest = RequestId 2}
            updateLedger requested (StatsLoaded (RequestId 1) testStats)
                `shouldBe` (requested, [])
            updateLedger requested (StatsFailed (RequestId 1) "late")
                `shouldBe` (requested, [])
            statsRequestIsCurrent requested (RequestId 2) `shouldBe` True
            statsRequestIsCurrent requested (RequestId 1) `shouldBe` False
        it "records a current failure" $ do
            let requested = initialLedgerState{ldStatsRequest = RequestId 1}
                (state, _) = updateLedger requested (StatsFailed (RequestId 1) "no counts")
            ldStatsError state `shouldBe` Just "no counts"
    describe "effect sequences" $ do
        it "emits only the schedule for the first search input" $ do
            snd (updateLedger initialLedgerState (SearchInput "a"))
                `shouldBe` [Schedule 180 (TimerId 1)]
        it "emits cancel then schedule for a replaced debounce" $ do
            let (state, _) = updateLedger initialLedgerState (SearchInput "a")
            snd (updateLedger state (SearchInput "ab"))
                `shouldBe` [CancelTimer (TimerId 1), Schedule 180 (TimerId 2)]
        it "schedules the delay the shell used before the migration" $ do
            searchDebounceDelayMs `shouldBe` 180
        it "returns no effects for a response it accepts" $ do
            snd (updateLedger initialLedgerState (ListLoaded False (RequestId 0) (page 0 [1] False)))
                `shouldBe` []
            snd (updateLedger initialLedgerState (StatsLoaded (RequestId 0) testStats))
                `shouldBe` []

-- ---------------------------------------------------------------- fixtures ---

withItems :: LedgerState
withItems =
    initialLedgerState
        { ldItems = [bookmark 1, bookmark 2]
        , ldTotal = 2
        , ldHasMore = True
        }

bookmark :: Int -> BookmarkSummary
bookmark bookmarkId =
    BookmarkSummary
        { bsId = bookmarkId
        , bsUrl = "https://example.com/"
        , bsTitle = "record"
        , bsDomain = "example.com"
        , bsCreatedAt = 0
        , bsAddedAt = 0
        , bsFaviconUrl = ""
        , bsTags = []
        , bsIsRead = False
        , bsIsDead = False
        , bsSnippet = Nothing
        }

page :: Int -> [Int] -> Bool -> SearchPage
page offset ids hasMore =
    SearchPage
        { spItems = map bookmark ids
        , spTotal = 100
        , spOffset = offset
        , spLimit = defaultLedgerLimit
        , spHasMore = hasMore
        , spYearCounts = [(2026, 10 + length ids)]
        }

testStats :: LibraryStats
testStats =
    LibraryStats
        { lsTotal = 100
        , lsTags = 10
        , lsTagLinks = 40
        , lsSources = 20
        , lsTopSources = []
        , lsSourcesOnce = 0
        , lsFirstDay = ""
        , lsLastDay = ""
        , lsDays = 0
        , lsYears = []
        , lsFilingDays = []
        , lsUnread = 5
        , lsDead = 0
        , lsQueued = 0
        , lsFaviconBytes = 0
        , lsHighlights = 0
        , lsShares = 0
        }

-- --------------------------------------------------------------- utilities ---

fetchRequests :: [Effect] -> [ClientRequest]
fetchRequests effects = [request | Fetch request _ <- effects]

fetchRequestIds :: [Effect] -> [RequestId]
fetchRequestIds effects = [requestId | Fetch _ requestId <- effects]

listQueryOf :: [Effect] -> Maybe BookmarkListQuery
listQueryOf effects = case fetchRequests effects of
    [ApiBookmarks query] -> Just query
    _ -> Nothing

strictlyIncreasing :: (Ord a) => [a] -> Bool
strictlyIncreasing values = and (zipWith (<) values (drop 1 values))
