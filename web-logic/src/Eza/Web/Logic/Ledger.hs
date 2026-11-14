{- | The native ledger/search reducer: the pure state machine behind the
library page's query box, tag facets, sort order, paging and count refreshes.

The state is built from @eza-core@ wire types only ('BookmarkSummary',
'SearchPage', 'LibraryStats'). The Miso shell projects its existing model
fields into a 'LedgerState' (@Eza.Web.LedgerBridge@) rather than owning a
second copy, so views keep reading the same fields while this module owns the
transitions.

== Requests, paging and staleness

The ledger knows one /list request stream/ and one /stats request stream/. A
new list request (a reload, or the first page after a debounce) takes the next
'RequestId'; an append page keeps the id of the page before it, because both
answer the same query generation. A response whose id is not the current one
is dropped without touching the state. That replaces the shell's old epoch
comparison and keeps the policy here, where a native test can exercise it.

Every load carries the query it answers, so an append is just the same query
at @offset = length items@. The reducer sets 'ldLoadingMore' exactly when the
in-flight request is an append; the bridge reads that flag when the response
arrives to decide whether to append or replace. 'ldOffset' records the number
of rows the next page starts after, matching what the shell displayed before.

== Timers

The search debounce is a timer in this reducer. 'SearchInput' cancels the
pending 'TimerId' (when there is one) and schedules a new one; the timer firing
comes back as 'SearchDebounceElapsed', accepted only for the current id. The
delay lives in 'searchDebounceDelayMs' so the native test pins it.

== Not in this slice

Bulk selection, the keyboard cursor, scroll restoration, tag vocabulary
refresh and every write request stay in the shell for M2-B2. 'updateLedger' is
total and returns effects instead of performing them.
-}
module Eza.Web.Logic.Ledger (
    LedgerState (..),
    LedgerAction (..),
    initialLedgerState,
    updateLedger,
    ledgerListQuery,
    listRequestIsCurrent,
    statsRequestIsCurrent,
    debounceTimerIsCurrent,
    defaultLedgerLimit,
    searchDebounceDelayMs,
) where

import Data.Text (Text)

import Eza.Types (
    BookmarkSummary,
    LibraryStats,
    SearchPage (..),
 )

import Eza.Web.Logic.Api (
    BookmarkListQuery (..),
    ClientRequest (..),
 )
import Eza.Web.Logic.Effect (Effect (..), RequestId (..), TimerId (..), nextRequestId)

-- ----------------------------------------------------------------- state ---

{- | Everything the ledger reducer owns. The shell keeps selection, cursor and
scroll state; the bridge projects only these fields across.

@ldRouteUnread@ is the unread filter implied by the current route (the inbox);
the bridge sets it from the route and no action changes it. The effective
filter of a request is @ldRouteUnread || ldUnreadOnly@, so toggling the unread
control on the inbox page cannot turn the route's own filter off, which is the
behaviour the shell had before this module existed.
-}
data LedgerState = LedgerState
    { ldQuery :: Text
    -- ^ The text currently in the search box (not yet committed).
    , ldTagFilters :: [Text]
    -- ^ Active tag facets, in click order.
    , ldSort :: Text
    -- ^ The server sort key (@created@, @added@ or @opened@).
    , ldUnreadOnly :: Bool
    -- ^ The unread-only toggle.
    , ldRouteUnread :: Bool
    -- ^ The route's unread filter (inbox); set by the bridge, never by an action.
    , ldLimit :: Int
    -- ^ Page size.
    , ldOffset :: Int
    -- ^ Rows before the next page, i.e. @spOffset + length items@ of the last load.
    , ldItems :: [BookmarkSummary]
    , ldTotal :: Int
    , ldYearCounts :: [(Int, Int)]
    -- ^ Per-year match counts, first page only.
    , ldHasMore :: Bool
    , ldLoading :: Bool
    , ldLoadingMore :: Bool
    , ldError :: Maybe Text
    -- ^ The last accepted failure message, cleared by the next accepted load.
    , ldListRequest :: RequestId
    -- ^ The current list request id.
    , ldDebounceTimer :: Maybe TimerId
    -- ^ The pending search debounce timer.
    , ldTimerSeq :: Int
    -- ^ Last allocated timer id; keeps ids unique across cancels and fires.
    , ldStats :: Maybe LibraryStats
    , ldStatsError :: Maybe Text
    , ldStatsRequest :: RequestId
    -- ^ The current stats request id.
    }
    deriving (Eq, Show)

-- | The page size the shell has always requested.
defaultLedgerLimit :: Int
defaultLedgerLimit = 60

-- | How long the search box waits before reloading the list, in milliseconds.
searchDebounceDelayMs :: Int
searchDebounceDelayMs = 180

{- | A fresh ledger: the default (unfiltered, newest-filed) query with no
pages loaded. The bridge projects the shell's initial model onto this, so the
initial loading flag comes from the shell (@True@ on the first paint).
-}
initialLedgerState :: LedgerState
initialLedgerState =
    LedgerState
        { ldQuery = ""
        , ldTagFilters = []
        , ldSort = "created"
        , ldUnreadOnly = False
        , ldRouteUnread = False
        , ldLimit = defaultLedgerLimit
        , ldOffset = 0
        , ldItems = []
        , ldTotal = 0
        , ldYearCounts = []
        , ldHasMore = False
        , ldLoading = False
        , ldLoadingMore = False
        , ldError = Nothing
        , ldListRequest = RequestId 0
        , ldDebounceTimer = Nothing
        , ldTimerSeq = 0
        , ldStats = Nothing
        , ldStatsError = Nothing
        , ldStatsRequest = RequestId 0
        }

-- --------------------------------------------------------------- actions ---

{- | One ledger event: a view interaction or a response from the shell. The
constructor set mirrors the shell actions the slice delegates, so the wiring
stays a name-for-name mapping.

@ListLoaded@ / @ListFailed@ carry the id of the request they answer. A stale
id is dropped. @StatsLoaded@ / @StatsFailed@ do the same for the counts.
-}
data LedgerAction
    = -- inputs
      SearchInput Text
    | SearchCommit
    | SearchDebounceElapsed TimerId
    | TagToggled Text
    | ClearFilters
    | SortSelected Text
    | UnreadToggled
    | -- paging
      Reload
    | LoadMore
    | -- responses
      ListLoaded Bool RequestId SearchPage
    | ListFailed RequestId Text
    | StatsRequested
    | StatsLoaded RequestId LibraryStats
    | StatsFailed RequestId Text
    deriving (Eq, Show)

-- --------------------------------------------------------------- reducer ---

{- | Apply one action. Total and pure: it never performs a request, timer or
navigation, it returns the effects for the bridge to interpret.
-}
updateLedger :: LedgerState -> LedgerAction -> (LedgerState, [Effect])
updateLedger state action = case action of
    -- The input invalidates the in-flight page at once, so a response for the
    -- old query cannot paint while the debounce waits. Items are kept until
    -- the new page arrives, as the shell has always done.
    SearchInput query ->
        case allocateTimer state of
            (state', timerId) ->
                ( state'
                    { ldQuery = query
                    , ldDebounceTimer = Just timerId
                    , ldListRequest = nextRequestId (ldListRequest state')
                    , ldLoading = True
                    , ldLoadingMore = False
                    , ldHasMore = False
                    , ldError = Nothing
                    }
                , cancelPending state <> [Schedule searchDebounceDelayMs timerId]
                )
    SearchCommit -> reload state
    SearchDebounceElapsed timerId
        | acceptsTimer state timerId -> reload state{ldDebounceTimer = Nothing}
        | otherwise -> (state, [])
    TagToggled tag -> reload state{ldTagFilters = toggleTag tag (ldTagFilters state)}
    ClearFilters ->
        reload
            state
                { ldQuery = ""
                , ldTagFilters = []
                , ldUnreadOnly = False
                }
    SortSelected sort -> reload state{ldSort = sort}
    UnreadToggled -> reload state{ldUnreadOnly = not (ldUnreadOnly state)}
    Reload -> reload state
    LoadMore
        | ldLoading state || ldLoadingMore state || not (ldHasMore state) -> (state, [])
        | otherwise ->
            ( state{ldLoadingMore = True}
            , [Fetch (ApiBookmarks (ledgerListQuery state True)) (ldListRequest state)]
            )
    ListLoaded append requestId page
        | not (acceptsListRequest state requestId) -> (state, [])
        | otherwise ->
            ( state
                { ldItems =
                    if append
                        then ldItems state <> spItems page
                        else spItems page
                , ldTotal = spTotal page
                , ldYearCounts =
                    if append
                        then ldYearCounts state
                        else spYearCounts page
                , ldHasMore = spHasMore page
                , ldOffset = spOffset page + length (spItems page)
                , ldLoading = False
                , ldLoadingMore = False
                , ldError = Nothing
                }
            , []
            )
    ListFailed requestId message
        | not (acceptsListRequest state requestId) -> (state, [])
        | otherwise ->
            ( state
                { ldLoading = False
                , ldLoadingMore = False
                , ldError = Just message
                }
            , []
            )
    StatsRequested ->
        let requestId = nextRequestId (ldStatsRequest state)
         in ( state{ldStatsRequest = requestId}
            , [Fetch ApiStats requestId]
            )
    StatsLoaded requestId stats
        | not (acceptsStatsRequest state requestId) -> (state, [])
        | otherwise ->
            ( state
                { ldStats = Just stats
                , ldStatsError = Nothing
                }
            , []
            )
    StatsFailed requestId message
        | not (acceptsStatsRequest state requestId) -> (state, [])
        | otherwise -> (state{ldStatsError = Just message}, [])

{- | Reload the first page for the current query. A new request id is taken so
responses for the previous query generation are rejected; @hasMore@ and the
loaded items stay until the new page arrives, matching the shell's old
@reloadList@.
-}
reload :: LedgerState -> (LedgerState, [Effect])
reload state =
    let requestId = nextRequestId (ldListRequest state)
        state' =
            state
                { ldListRequest = requestId
                , ldLoading = True
                , ldLoadingMore = False
                , ldError = Nothing
                }
     in (state', [Fetch (ApiBookmarks (ledgerListQuery state' False)) requestId])

{- | The list request for the current query. An append page starts after the
loaded rows; a reload or a debounce answer starts at zero.
-}
ledgerListQuery :: LedgerState -> Bool -> BookmarkListQuery
ledgerListQuery state append =
    BookmarkListQuery
        { blqQ = ldQuery state
        , blqTags = ldTagFilters state
        , blqSort = ldSort state
        , blqUnreadOnly = ldRouteUnread state || ldUnreadOnly state
        , blqOffset = if append then length (ldItems state) else 0
        , blqLimit = ldLimit state
        }

-- ------------------------------------------------------------ staleness ---

-- | Is the response with this id still the answer the ledger waits for?
listRequestIsCurrent :: LedgerState -> RequestId -> Bool
listRequestIsCurrent = acceptsListRequest

-- | Is the stats response with this id still current?
statsRequestIsCurrent :: LedgerState -> RequestId -> Bool
statsRequestIsCurrent = acceptsStatsRequest

-- | Is this the pending debounce timer? A late fire of an older timer is not.
debounceTimerIsCurrent :: LedgerState -> TimerId -> Bool
debounceTimerIsCurrent = acceptsTimer

acceptsListRequest :: LedgerState -> RequestId -> Bool
acceptsListRequest state requestId = requestId == ldListRequest state

acceptsStatsRequest :: LedgerState -> RequestId -> Bool
acceptsStatsRequest state requestId = requestId == ldStatsRequest state

acceptsTimer :: LedgerState -> TimerId -> Bool
acceptsTimer state timerId = ldDebounceTimer state == Just timerId

-- --------------------------------------------------------------- helpers ---

-- | Take the next timer id and record it as the highest allocated.
allocateTimer :: LedgerState -> (LedgerState, TimerId)
allocateTimer state =
    let sequenceNumber = ldTimerSeq state + 1
     in (state{ldTimerSeq = sequenceNumber}, TimerId sequenceNumber)

-- | Cancel the timer that is still pending, if any.
cancelPending :: LedgerState -> [Effect]
cancelPending state = case ldDebounceTimer state of
    Just timerId -> [CancelTimer timerId]
    Nothing -> []

{- | Toggle one tag filter: appended at the end when added, removed when
present. The order is the order the facade panel showed.
-}
toggleTag :: Text -> [Text] -> [Text]
toggleTag tag tags
    | tag `elem` tags = filter (/= tag) tags
    | otherwise = tags <> [tag]
