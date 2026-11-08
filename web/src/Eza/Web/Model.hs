-- | Client model, route type, and the action vocabulary.
module Eza.Web.Model (
    Route (..),
    Theme (..),
    NoteMode (..),
    ToastKind (..),
    Toast (..),
    KeyEvent (..),
    Model (..),
    Action (..),
    initialModel,
    routeOfUri,
    routeTitle,
    routeSubtitle,
    AccountTab (..),
    accountTabSlug,
    accountTabFromSlug,
    TagDialog (..),
    LedgerEntry (..),
    ledgerEntries,
    ledgerContentHeight,
    entryHeight,
    yearOf,
    isoDay,
    formatStamp,
    formatFiled,
    formatProseDate,
    sortLabel,
    themeToMiso,
    themeOfMiso,
    paletteEntries,
    isSelected,
    selectedCount,
) where

import Data.Aeson (Value)
import qualified Data.ByteString as BS
import qualified Data.IntSet as IS
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8')
import Text.Read (readMaybe)

import Eza.Types (
    Backlink,
    BookmarkDetail,
    BookmarkSummary (..),
    BootPayload,
    DedupCounts,
    DedupGroup (..),
    DedupMergeAllReport,
    DedupReport,
    GraphData,
    Highlight (..),
    ImportReport,
    LibraryStats,
    SavedSearch (..),
    SearchPage,
    TagStat,
 )
import Eza.Web.Types (AccountInfo, AiStatus, ApiError, ConsolGroup, ReaderSelection, Rule (..), SessionInfo, ShareView, TagSuggestion, TokenView)
import Miso
import Miso.Router (Router (..), RoutingError (..), Token (..), parseURI, routes, toCapture, toPath, toQueryParam)

-- | Application routes.  @Bookmark@ carries the numeric bookmark id.
data Route
    = Index
    | Bookmark Int
    | Inbox
    | Graph
    | Dedup
    | Tags
    | AiTags
    | Maintenance
    | Account
    | Accessions
    | Save (Maybe Text) (Maybe Text) (Maybe Text)
    | NotFound
    deriving (Eq, Show)

{- | The route parser is not used: the client classifies URLs directly (and
falls back to 'NotFound' instead of failing), so the default is overridden.
-}
instance Router Route where
    fromRoute = \case
        Index -> [IndexToken]
        Bookmark bid -> [toPath "bookmark", toCapture bid]
        Inbox -> [toPath "inbox"]
        Graph -> [toPath "graph"]
        Dedup -> [toPath "dedup"]
        Tags -> [toPath "tags"]
        AiTags -> [toPath "tags", toPath "ai"]
        Maintenance -> [toPath "maintenance"]
        Account -> [toPath "account"]
        Accessions -> [toPath "accessions"]
        Save title body url ->
            [toPath "save"]
                ++ concat
                    [ [toQueryParam "title" value]
                    | Just value <- [title]
                    ]
                ++ concat
                    [ [toQueryParam "text" value]
                    | Just value <- [body]
                    ]
                ++ concat
                    [ [toQueryParam "url" value]
                    | Just value <- [url]
                    ]
        NotFound -> [toPath "not-found"]
    toRoute input = case parseURI input of
        Left err -> Left (LexError input err)
        Right uri -> Right (classifyRoute uri)
    routeParser = routes []

splitPath :: String -> [String]
splitPath = filter (not . null) . step
  where
    step s = case break (== '/') s of
        (a, []) -> [a]
        (a, _ : rest) -> a : step rest

{- | Decode a URL query value (@%XX@ escapes and @+@ as space, UTF-8 aware).
miso's URI lexer keeps query values percent-encoded, and the PWA
share_target passes title/url through the query string.
-}
percentDecode :: Text -> Text
percentDecode raw =
    case decodeUtf8' (BS.pack (map fromIntegral (decode (T.unpack raw)))) of
        Right decoded -> decoded
        Left _ -> raw
  where
    decode [] = []
    decode ('%' : a : b : rest)
        | Just hi <- hexValue a
        , Just lo <- hexValue b =
            hi * 16 + lo : decode rest
    decode ('+' : rest) = 32 : decode rest
    decode (c : rest) = utf8 (fromEnum c) ++ decode rest

    hexValue c
        | c >= '0' && c <= '9' = Just (fromEnum c - fromEnum '0')
        | c >= 'a' && c <= 'f' = Just (fromEnum c - fromEnum 'a' + 10)
        | c >= 'A' && c <= 'F' = Just (fromEnum c - fromEnum 'A' + 10)
        | otherwise = Nothing

    utf8 n
        | n <= 0x7f = [n]
        | n <= 0x7ff = [0xc0 + n `div` 64, 0x80 + n `mod` 64]
        | n <= 0xffff =
            [ 0xe0 + n `div` 4096
            , 0x80 + (n `div` 64) `mod` 64
            , 0x80 + n `mod` 64
            ]
        | otherwise =
            [ 0xf0 + n `div` 262144
            , 0x80 + (n `div` 4096) `mod` 64
            , 0x80 + (n `div` 64) `mod` 64
            , 0x80 + n `mod` 64
            ]

classifyRoute :: URI -> Route
classifyRoute uri = case splitPath (fromMisoString (uriPath uri)) of
    [] -> Index
    ["bookmark", n] -> maybe NotFound Bookmark (readMaybe n)
    ["inbox"] -> Inbox
    ["graph"] -> Graph
    ["dedup"] -> Dedup
    ["tags"] -> Tags
    ["tags", "ai"] -> AiTags
    ["maintenance"] -> Maintenance
    ["account"] -> Account
    ["accessions"] -> Accessions
    -- PWA share_target landing page: /save?title=..&text=..&url=..
    ["save"] -> Save (query "title") (query "text") (query "url")
    _ -> NotFound
  where
    query key =
        fmap (percentDecode . (fromMisoString :: MisoString -> Text))
            =<< M.lookup key (uriQueryString uri)

routeOfUri :: URI -> Route
routeOfUri uri =
    case toRoute (prettyURI uri) of
        Right r -> r
        Left _ -> NotFound

routeTitle :: Route -> MisoString
routeTitle = \case
    Index -> "Library"
    Bookmark _ -> "Bookmark"
    Inbox -> "Inbox"
    Graph -> "Graph"
    Dedup -> "Duplicates"
    Tags -> "Tags"
    AiTags -> "AI tags"
    Maintenance -> "Maintenance"
    Account -> "Account"
    Accessions -> "Accessions by year"
    Save _ _ _ -> "Save bookmark"
    NotFound -> "Not found"

routeSubtitle :: Route -> MisoString
routeSubtitle = \case
    Index -> "Search, filter, and open anything in one keystroke."
    Bookmark _ -> "Read, annotate, and connect this bookmark."
    Inbox -> "Everything you saved but have not read yet."
    Graph -> "Explore the neighbourhood around a bookmark."
    Dedup -> "Review near-identical saves before merging them."
    Tags -> "Consolidate, rename, and prune your tag vocabulary."
    AiTags -> "Advisory tag suggestions. Nothing is written without you."
    Maintenance -> "Dead-link sweeps, prune candidates, and undo."
    Account -> "Username, password, passkeys, sessions, and tokens."
    Accessions -> "The whole archive, set as an index."
    Save _ _ _ -> "Saving a shared link to the catalogue."
    NotFound -> "That page does not exist."

data Theme = ThemeLight | ThemeDark
    deriving (Eq, Show)

themeToMiso :: Theme -> MisoString
themeToMiso ThemeLight = "light"
themeToMiso ThemeDark = "dark"

themeOfMiso :: MisoString -> Theme
themeOfMiso s = if fromMisoString s == ("dark" :: String) then ThemeDark else ThemeLight

data NoteMode = NoteWrite | NotePreview
    deriving (Eq, Show)

{- | Which account panel is showing. The first tab is the sign-in panel; the
slug order is the order of the section list.
-}
data AccountTab
    = AccountSecurity
    | AccountPasskeys
    | AccountRecovery
    | AccountSessions
    | AccountTokens
    | AccountShares
    | AccountRules
    | AccountImport
    | AccountCapture
    | AccountAppearance
    | AccountAbout
    deriving (Eq, Show)

-- | The URL fragment for one account tab, used to make the tabs routable.
accountTabSlug :: AccountTab -> MisoString
accountTabSlug = \case
    AccountSecurity -> "security"
    AccountPasskeys -> "passkeys"
    AccountRecovery -> "recovery"
    AccountSessions -> "sessions"
    AccountTokens -> "tokens"
    AccountShares -> "shares"
    AccountRules -> "rules"
    AccountImport -> "import"
    AccountCapture -> "capture"
    AccountAppearance -> "appearance"
    AccountAbout -> "about"

-- | Read a tab back from @/account#slug@; an unknown fragment is the default.
accountTabFromSlug :: MisoString -> AccountTab
accountTabFromSlug raw =
    case T.toLower (T.dropWhile (== '#') (T.strip (fromMisoString raw))) of
        "passkeys" -> AccountPasskeys
        "recovery" -> AccountRecovery
        "sessions" -> AccountSessions
        "tokens" -> AccountTokens
        "shares" -> AccountShares
        "rules" -> AccountRules
        "import" -> AccountImport
        "capture" -> AccountCapture
        "appearance" -> AccountAppearance
        "about" -> AccountAbout
        _ -> AccountSecurity

-- | One tag operation waiting for confirmation in the tags dialog.
data TagDialog
    = TagRenameDialog Text
    | TagDeleteDialog Text
    | TagMergeDialog [Text] Text
    deriving (Eq, Show)

data ToastKind = ToastInfo | ToastOk | ToastError
    deriving (Eq, Show)

data Toast = Toast
    { toastId :: Int
    , toastMessage :: MisoString
    , toastKind :: ToastKind
    }
    deriving (Eq, Show)

{- | One keyboard event as the JavaScript bridge reports it. @keKey@ is
@event.key@, which is layout independent: it is the character the user meant,
not the physical key code. @keEditable@ says whether focus was in a text field
when the key was pressed, so the update function can tell typing from a
shortcut without probing the DOM.
-}
data KeyEvent = KeyEvent
    { keKey :: Text
    , keShift :: Bool
    , keCtrl :: Bool
    , keMeta :: Bool
    , keAlt :: Bool
    , keEditable :: Bool
    }
    deriving (Eq, Show)

-- | Every user-visible action the client understands.
data Action
    = -- lifecycle / routing
      Mounted
    | RouteChanged (Either RoutingError Route)
    | Navigate Route
    | ThemeToggled
    | LayoutChanged Int Int
    | Scrolled
    | Resized
    | KeyPressed KeyEvent
    | DeleteBookmarkRequest Int
    | DeleteBookmarkCancel
    | DeleteBookmarkConfirm
    | LedgerCursorNext
    | LedgerCursorPrev
    | LedgerCursorSet Int
    | DrawerOpen Int
    | DrawerClose
    | AccountTabSelected AccountTab
    | AccountTabFromHash MisoString
    | Noop
    | -- boot
      BootLoaded BootPayload
    | BootFailed ApiError
    | ApiUnauthorized
    | ApiErrorRaised ApiError
    | ThemeLoaded Theme
    | ConnectivityChanged Bool
    | WindowOriginKnown MisoString
    | CopyBookmarklet MisoString
    | QuickSaved Int Bool
    | QuickSaveFailed ApiError
    | ScrollMetrics (Maybe (Int, Int, Int))
    | TagsRefreshed [TagStat]
    | StatsRefreshed (Maybe LibraryStats)
    | ReloadRoute
    | -- library
      SearchInput MisoString
    | SearchCommit
    | DebouncedSearch
    | TimerRegistered Int
    | TagToggled Text
    | ClearFilters
    | SortSelected Text
    | UnreadToggled
    | ListLoaded Bool Int SearchPage
    | ListFailed Bool Int ApiError
    | LoadMore
    | MarkAllAbove
    | MarkAllDone Int
    | MarkAllFailed ApiError
    | SavedSearchApply SavedSearch
    | ExportClicked
    | -- add modal
      AddOpen
    | AddClose
    | AddUrlInput MisoString
    | AddTitleInput MisoString
    | AddTagsInput MisoString
    | AddNoteInput MisoString
    | AddSubmit
    | AddSucceeded Int
    | AddNoteSaved Int
    | AddNoteFailed Int ApiError
    | AddFailed ApiError
    | -- command palette
      PaletteOpen
    | PaletteClose
    | PaletteInput MisoString
    | PalettePrev
    | PaletteNext
    | PaletteChoose Int
    | PaletteSelect
    | -- detail
      DetailLoaded Int BookmarkDetail
    | DetailFailed Int ApiError
    | TitleInput MisoString
    | NoteChanged MisoString DOMRef
    | NoteMeta Int (Maybe Text)
    | NoteModeChanged NoteMode
    | TagDraftInput MisoString
    | TagAdd
    | TagRemove Text
    | SaveBookmark
    | SavedOk
    | SaveFailed ApiError
    | ReadToggled
    | ReadPatched Bool
    | ReadPatchFailed Bool ApiError
    | OpenToggled
    | BacklinksLoaded Int [Backlink]
    | BacklinksFailed Int ApiError
    | LinkPrev
    | LinkNext
    | LinkChoose Int
    | LinkSuggestions [BookmarkSummary]
    | RunBookmarkAction Int Text
    | DeleteBookmark Int
    | DeletedOk Int
    | DeleteFailed ApiError
    | DirtyGuardOpen Route
    | DirtyGuardClose
    | DirtyGuardDiscard
    | -- import / export
      ImportStart
    | ImportFileChosen
    | ImportDone Value
    | ImportFailed ApiError
    | -- saved searches
      SavedSearchSave
    | SavedSearchNameInput MisoString
    | SavedSearchDelete Int
    | SavedSearchDone
    | SavedSearchFailed ApiError
    | SavedSearchesLoaded [SavedSearch]
    | SavedSearchShareOpen SavedSearch
    | SavedSearchShareClose
    | SavedSearchShareCreate
    | -- graph
      GraphLoaded GraphData
    | GraphFailed ApiError
    | GraphDepthSelected Int
    | GraphZoom Int
    | GraphSeed (Maybe Int)
    | GraphQueryChanged MisoString
    | GraphResults [BookmarkSummary]
    | GraphPickSeed Int
    | OpenGraphAt Int
    | GraphRefresh
    | -- dedup (two independently paged sections)
      DedupLoaded DedupReport
    | DedupFailed ApiError
    | DedupMoreUrl
    | DedupMoreTitle
    | DedupMoreLoaded Bool DedupReport
    | DedupKeep Text Int
    | DedupMerge Text
    | DedupMergeConfirm
    | DedupMergeCancel
    | DedupRefresh
    | DedupMerged Text Int Int
    | DedupMergeAllOpen
    | DedupMergeAllCancel
    | DedupMergeAllConfirm
    | DedupMergeAllDone DedupMergeAllReport
    | DedupMergeAllFailed ApiError
    | -- tags
      TagStatsLoaded [TagStat]
    | ConsolLoaded [ConsolGroup]
    | ConsolFailed ApiError
    | TagMerge [Text] Text
    | TagMerged
    | FilterByTag Text
    | TagRenamed Text MisoString
    | TagDeleted Text
    | TagDialogOpen TagDialog
    | TagDialogInput MisoString
    | TagDialogDetach
    | TagDialogConfirm
    | TagDialogClose
    | TagOpFailed ApiError
    | -- AI tags
      AiTagSelected (Maybe Text)
    | SuggestionsLoaded Bool [TagSuggestion] (Maybe Text)
    | SuggestionsFailed ApiError
    | SuggestionApply Int [Text]
    | SuggestionsApplied
    | AiStatusReload
    | AiSuggestRetry
    | AiSuggestDiscard
    | -- maintenance
      PruneLoaded [BookmarkSummary]
    | PruneFailed ApiError
    | PruneToggle Int
    | PruneAll
    | PruneRun
    | PruneCancel
    | PruneDone Int
    | DeadCheckRun
    | DeadCheckDone Int Int
    | UndoRun
    | UndoDone Int
    | MaintFailed ApiError
    | -- account
      AccountLoaded AccountInfo
    | AccountFailed ApiError
    | RecoveryRegenerate
    | RecoveryLoaded [Text]
    | CredentialRenamed Text MisoString
    | CredentialDeleted Text
    | CredentialOpFailed ApiError
    | CredentialEditStart Text
    | CredentialNameInput MisoString
    | CredentialEditSave
    | CredentialEditCancel
    | CredentialRemoved Text
    | AccountReload
    | SecurityUsernameInput MisoString
    | SecurityCurrentPasswordInput MisoString
    | SecurityNewPasswordInput MisoString
    | SecurityConfirmPasswordInput MisoString
    | Security2faWantedToggled Bool
    | SecurityUsernameSave
    | SecurityPasswordSave
    | Security2faSave
    | SecuritySaved MisoString
    | SecurityFailed ApiError
    | SessionsRevokeOthers
    | SessionsRevoked Int
    | SessionsRevokeFailed ApiError
    | LogoutRequest
    | LogoutCancel
    | Logout
    | LoggedOut
    | -- selection / bulk actions
      SelectToggled Int Bool
    | SelectClear
    | SelectAllLoaded
    | SelectAllMatchingStart
    | SelectPageLoaded [Int] Bool
    | SelectPageFailed ApiError
    | BulkTagPromptOpen Bool
    | BulkTagInput MisoString
    | BulkTagCancel
    | BulkTagSubmit
    | BulkMark Bool
    | BulkDeleteRequest
    | BulkDeleteCancel
    | BulkDeleteConfirm
    | BulkActionDone Int
    | BulkActionFailed ApiError
    | -- API tokens
      TokensLoaded [TokenView]
    | TokensFailed ApiError
    | TokenNameInput MisoString
    | TokenScopeToggled Text
    | TokenCreate
    | TokenCreated Text TokenView
    | TokenCreateFailed ApiError
    | TokenRevoke Int
    | TokenRevoked
    | TokenRevealDismiss
    | TokenCopied Text
    | -- enrichment
      RetryEnrich Int
    | DetailReload Int
    | -- highlights
      HighlightsLoaded Int [Highlight]
    | HighlightsFailed Int ApiError
    | ReaderMouseUp
    | ReaderSelectionFound (Maybe ReaderSelection)
    | ReaderSelectionClear
    | HighlightCreateQuick
    | HighlightNoteOpen
    | HighlightNoteInput MisoString
    | HighlightNoteCancel
    | HighlightNoteSubmit
    | HighlightAdded Highlight
    | HighlightEditStart Int
    | HighlightEditInput MisoString
    | HighlightEditColor Text
    | HighlightEditCancel
    | HighlightEditSave
    | HighlightDelete Int
    | HighlightPatched
    | HighlightDeleted
    | HighlightFailed ApiError
    | -- sharing
      SharesLoaded Int [ShareView]
    | SharesFailed Int ApiError
    | ShareDialogOpen
    | ShareDialogClose
    | ShareIncludeNoteToggle
    | ShareExpirySelected Int
    | ShareCreate
    | ShareCreated Int Text
    | ShareCreateFailed ApiError
    | ShareCopy Text
    | ShareRevoke Int
    | ShareRevoked
    | -- snapshot
      SnapshotOpen
    | SnapshotClose
    | -- ai status
      AiStatusLoaded AiStatus
    | AiStatusFailed ApiError
    | -- rules
      RulesLoaded [Rule]
    | RulesFailed ApiError
    | RuleNameInput MisoString
    | RuleFieldSelected Text
    | RulePatternInput MisoString
    | RuleTagsInput MisoString
    | RuleMarkReadToggled
    | RuleCreate
    | RuleCreated Rule
    | RuleCreateFailed ApiError
    | RuleToggleEnabled Rule
    | RuleToggled Rule
    | RuleDelete Int
    | RuleDeleted Int
    | RuleDryRun
    | RuleDryRunResult Int [Int]
    | RuleDryRunFailed ApiError
    | RuleFailed ApiError
    | -- toasts
      ToastAdd MisoString ToastKind
    | ToastDismiss Int

-- | Everything the UI needs to render itself.
data Model = Model
    { -- routing / shell
      mRoute :: Route
    , mTheme :: Theme
    , mBooted :: Bool
    , -- boot payload reuse: the boot page seeds the default ledger, so a list
      -- route that arrives before /boot answers waits for it instead of
      -- fetching the same page a second time.
      mBootReady :: Bool
    , mBootSeeded :: Bool
    , mRouted :: Bool
    , mListDeferred :: Bool
    , -- list fetch epoch: a response for an older query is dropped
      mListEpoch :: Int
    , mVersion :: MisoString
    , mOrigin :: MisoString
    , mWindowOrigin :: MisoString
    , mOnline :: Bool
    , mSignedOut :: Bool
    , -- layout / virtualization
      mWidth :: Int
    , mHeight :: Int
    , mScrollY :: Int
    , mScrollRestore :: Maybe Int
    , mGridTop :: Int
    , -- library query state
      mQ :: MisoString
    , mTagsFilter :: [Text]
    , mSort :: Text
    , mUnreadOnly :: Bool
    , mItems :: [BookmarkSummary]
    , mTotal :: Int
    , mHasMore :: Bool
    , mOffset :: Int
    , mLoading :: Bool
    , mLoadingMore :: Bool
    , mError :: Maybe MisoString
    , mNotice :: Maybe MisoString
    , mDebounce :: Maybe Int
    , mTags :: [TagStat]
    , mStats :: Maybe LibraryStats
    , mStatsError :: Maybe MisoString
    , mYearHere :: [(Int, Int)]
    , mLedgerCursor :: Maybe Int
    , mDrawer :: Maybe Int
    , mAccountTab :: AccountTab
    , mSessions :: [SessionInfo]
    , mSecurityUsername :: MisoString
    , mSecurityCurrent :: MisoString
    , mSecurityNew :: MisoString
    , mSecurityConfirm :: MisoString
    , mSecurity2faWanted :: Bool
    , mSecurityBusy :: Bool
    , mSecurityError :: Maybe MisoString
    , mSaved :: [SavedSearch]
    , mSavedName :: MisoString
    , mSavedShare :: Maybe SavedSearch
    , -- selection / bulk
      mSelection :: IS.IntSet
    , mSelectAnchor :: Maybe Int
    , mSelectingAll :: Bool
    , mSelectFetched :: Int
    , mBulkBusy :: Bool
    , mTagPrompt :: Maybe Bool
    , mTagPromptValue :: MisoString
    , mConfirmDelete :: Maybe Int
    , mConfirmBulkDelete :: Bool
    , mConfirmMarkAll :: Bool
    , -- add modal
      mAddOpen :: Bool
    , mAddUrl :: MisoString
    , mAddTitle :: MisoString
    , mAddTags :: MisoString
    , mAddNote :: MisoString
    , mAddBusy :: Bool
    , mAddError :: Maybe MisoString
    , -- palette
      mPaletteOpen :: Bool
    , mPaletteQ :: MisoString
    , mPaletteSel :: Int
    , -- detail
      mDetail :: Maybe BookmarkDetail
    , mDetailLoading :: Bool
    , mDetailError :: Maybe MisoString
    , mDetailEpoch :: Int
    , mEditTitle :: MisoString
    , mEditNote :: MisoString
    , mEditTags :: [Text]
    , mNewTag :: MisoString
    , mNoteMode :: NoteMode
    , mNoteCursor :: Int
    , mLinkQuery :: Maybe MisoString
    , mLinkResults :: [BookmarkSummary]
    , mLinkSel :: Int
    , mBacklinks :: [Backlink]
    , mHighlights :: [Highlight]
    , mHighlightsLoading :: Bool
    , mReaderSel :: Maybe ReaderSelection
    , mHighlightNoteOpen :: Bool
    , mHighlightNote :: MisoString
    , mHighlightEdit :: Maybe Int
    , mHighlightEditNote :: MisoString
    , mHighlightEditColor :: Text
    , mSnapshotOpen :: Bool
    , mShares :: [ShareView]
    , mSharesLoading :: Bool
    , mSharesError :: Maybe MisoString
    , mShareDialogOpen :: Bool
    , mShareIncludeNote :: Bool
    , mShareExpiryDays :: Int
    , mShareBusy :: Bool
    , mShareUrl :: Maybe Text
    , mAiStatus :: Maybe AiStatus
    , mRules :: [Rule]
    , mRulesLoading :: Bool
    , mRulesError :: Maybe MisoString
    , mRuleName :: MisoString
    , mRuleField :: Text
    , mRulePattern :: MisoString
    , mRuleTags :: MisoString
    , mRuleMarkRead :: Bool
    , mRuleBusy :: Bool
    , mRuleDryRun :: Maybe (Int, [Int])
    , mSaving :: Bool
    , mDirty :: Bool
    , mGuardOpen :: Bool
    , mPendingRoute :: Maybe Route
    , mConfirmLogout :: Bool
    , -- graph
      mGraph :: Maybe GraphData
    , mGraphLoading :: Bool
    , mGraphDepth :: Int
    , mGraphZoom :: Int
    , mGraphSeed :: Maybe Int
    , mGraphQuery :: MisoString
    , mGraphResults :: [BookmarkSummary]
    , -- dedup: exact counts plus two independently paged sections
      mDedupCounts :: Maybe DedupCounts
    , mDedupUrlGroups :: [DedupGroup]
    , mDedupTitleGroups :: [DedupGroup]
    , mDedupLoading :: Bool
    , mDedupError :: Maybe MisoString
    , mDedupChoice :: M.Map Text Int
    , mDedupConfirm :: Maybe Text
    , mDedupLast :: Maybe (Int, Int)
    , mDedupMoreBusy :: Bool
    , mDedupBusy :: Bool
    , mDedupMergeAllOpen :: Bool
    , mDedupMergeAllReport :: Maybe DedupMergeAllReport
    , -- tags / ai tags
      mConsol :: [ConsolGroup]
    , mConsolLoading :: Bool
    , mConsolError :: Maybe MisoString
    , mTagDialog :: Maybe TagDialog
    , mTagDialogInput :: MisoString
    , mTagDialogBusy :: Bool
    , mTagDialogError :: Maybe MisoString
    , mAiTag :: Maybe Text
    , mSuggestions :: [TagSuggestion]
    , mSuggestionsLoading :: Bool
    , mSuggestionNotice :: Maybe MisoString
    , mSuggestionError :: Maybe MisoString
    , -- maintenance
      mPrune :: [BookmarkSummary]
    , mPruneSel :: [Int]
    , mDeadCount :: Maybe Int
    , mCheckedCount :: Maybe Int
    , mMaintBusy :: Bool
    , mConfirmPrune :: Bool
    , mPruneError :: Maybe MisoString
    , -- account
      mAccount :: Maybe AccountInfo
    , mAccountLoading :: Bool
    , mAccountError :: Maybe MisoString
    , mRecoveryCodes :: [Text]
    , mCredEdit :: Maybe (Text, MisoString)
    , mTokens :: [TokenView]
    , mTokensLoading :: Bool
    , mTokensError :: Maybe MisoString
    , mTokenName :: MisoString
    , mTokenScopes :: [Text]
    , mTokenSecret :: Maybe (Text, TokenView)
    , mTokenBusy :: Bool
    , -- import / export
      mImporting :: Bool
    , mImportReport :: Maybe ImportReport
    , -- toasts
      mToasts :: [Toast]
    , mToastNext :: Int
    }
    deriving (Eq)

initialModel :: Model
initialModel =
    Model
        { mRoute = Index
        , mTheme = ThemeLight
        , mBooted = False
        , mBootReady = False
        , mBootSeeded = False
        , mRouted = False
        , mListDeferred = False
        , mListEpoch = 0
        , mVersion = "0.1.0"
        , mOrigin = ""
        , mWindowOrigin = ""
        , mOnline = True
        , mSignedOut = False
        , mWidth = 1200
        , mHeight = 900
        , mScrollY = 0
        , mScrollRestore = Nothing
        , mGridTop = 240
        , mQ = ""
        , mTagsFilter = []
        , mSort = "created"
        , mUnreadOnly = False
        , mItems = []
        , mTotal = 0
        , mHasMore = False
        , mOffset = 0
        , -- the first paint is a skeleton: the boot payload or the deferred
          -- list fetch fills the ledger
          mLoading = True
        , mLoadingMore = False
        , mError = Nothing
        , mNotice = Nothing
        , mDebounce = Nothing
        , mTags = []
        , mStats = Nothing
        , mStatsError = Nothing
        , mYearHere = []
        , mLedgerCursor = Nothing
        , mDrawer = Nothing
        , mAccountTab = AccountSecurity
        , mSessions = []
        , mSecurityUsername = ""
        , mSecurityCurrent = ""
        , mSecurityNew = ""
        , mSecurityConfirm = ""
        , mSecurity2faWanted = False
        , mSecurityBusy = False
        , mSecurityError = Nothing
        , mSaved = []
        , mSavedName = ""
        , mSavedShare = Nothing
        , mSelection = IS.empty
        , mSelectAnchor = Nothing
        , mSelectingAll = False
        , mSelectFetched = 0
        , mBulkBusy = False
        , mTagPrompt = Nothing
        , mTagPromptValue = ""
        , mConfirmDelete = Nothing
        , mConfirmBulkDelete = False
        , mConfirmMarkAll = False
        , mAddOpen = False
        , mAddUrl = ""
        , mAddTitle = ""
        , mAddTags = ""
        , mAddNote = ""
        , mAddBusy = False
        , mAddError = Nothing
        , mPaletteOpen = False
        , mPaletteQ = ""
        , mPaletteSel = 0
        , mDetail = Nothing
        , mDetailLoading = False
        , mDetailError = Nothing
        , mDetailEpoch = 0
        , mEditTitle = ""
        , mEditNote = ""
        , mEditTags = []
        , mNewTag = ""
        , mNoteMode = NoteWrite
        , mNoteCursor = 0
        , mLinkQuery = Nothing
        , mLinkResults = []
        , mLinkSel = 0
        , mBacklinks = []
        , mHighlights = []
        , mHighlightsLoading = False
        , mReaderSel = Nothing
        , mHighlightNoteOpen = False
        , mHighlightNote = ""
        , mHighlightEdit = Nothing
        , mHighlightEditNote = ""
        , mHighlightEditColor = "yellow"
        , mSnapshotOpen = False
        , mShares = []
        , mSharesLoading = False
        , mSharesError = Nothing
        , mShareDialogOpen = False
        , mShareIncludeNote = False
        , mShareExpiryDays = 30
        , mShareBusy = False
        , mShareUrl = Nothing
        , mAiStatus = Nothing
        , mRules = []
        , mRulesLoading = False
        , mRulesError = Nothing
        , mRuleName = ""
        , mRuleField = "url"
        , mRulePattern = ""
        , mRuleTags = ""
        , mRuleMarkRead = False
        , mRuleBusy = False
        , mRuleDryRun = Nothing
        , mSaving = False
        , mDirty = False
        , mGuardOpen = False
        , mPendingRoute = Nothing
        , mConfirmLogout = False
        , mGraph = Nothing
        , mGraphLoading = False
        , mGraphDepth = 1
        , mGraphZoom = 100
        , mGraphSeed = Nothing
        , mGraphQuery = ""
        , mGraphResults = []
        , mDedupCounts = Nothing
        , mDedupUrlGroups = []
        , mDedupTitleGroups = []
        , mDedupLoading = False
        , mDedupError = Nothing
        , mDedupChoice = M.empty
        , mDedupConfirm = Nothing
        , mDedupLast = Nothing
        , mDedupMoreBusy = False
        , mDedupBusy = False
        , mDedupMergeAllOpen = False
        , mDedupMergeAllReport = Nothing
        , mConsol = []
        , mConsolLoading = False
        , mConsolError = Nothing
        , mTagDialog = Nothing
        , mTagDialogInput = ""
        , mTagDialogBusy = False
        , mTagDialogError = Nothing
        , mAiTag = Nothing
        , mSuggestions = []
        , mSuggestionsLoading = False
        , mSuggestionNotice = Nothing
        , mSuggestionError = Nothing
        , mPrune = []
        , mPruneSel = []
        , mDeadCount = Nothing
        , mCheckedCount = Nothing
        , mMaintBusy = False
        , mConfirmPrune = False
        , mPruneError = Nothing
        , mAccount = Nothing
        , mAccountLoading = False
        , mAccountError = Nothing
        , mRecoveryCodes = []
        , mCredEdit = Nothing
        , mTokens = []
        , mTokensLoading = False
        , mTokensError = Nothing
        , mTokenName = ""
        , mTokenScopes = ["read", "write"]
        , mTokenSecret = Nothing
        , mTokenBusy = False
        , mImporting = False
        , mImportReport = Nothing
        , mToasts = []
        , mToastNext = 0
        }

{- | Virtualized grid metrics.  Card height follows the design brief:
124px desktop, 140px mobile; rows include the 12px gap.
-}

-- | Year of a unix timestamp, in UTC.
yearOf :: Int -> Int
yearOf t = let (y, _, _) = civilFromDays (max 0 t `div` 86400) in y

-- | ISO day (YYYY-MM-DD) of a unix timestamp, in UTC.
isoDay :: Int -> Text
isoDay t =
    let (y, mo, d) = civilFromDays (max 0 t `div` 86400)
     in T.pack (pad y <> "-" <> pad mo <> "-" <> pad d)
  where
    pad :: Int -> String
    pad n = if n < 10 then '0' : show n else show n

-- | One line of the ledger: a year divider or a record row.
data LedgerEntry
    = LedgerYear Int (Maybe Int)
    | LedgerRow Int BookmarkSummary

{- | Group the loaded records into year dividers plus rows. The order the API
returned is kept inside each year and the first appearance of a year decides
where its divider sits, so a title sort still reads as one ledger.
-}
ledgerEntries :: Model -> [LedgerEntry]
ledgerEntries m =
    let here = M.fromList (mYearHere m)
        rows = mItems m
        years = orderedYears rows
        block year =
            LedgerYear year (M.lookup year here)
                : [ LedgerRow idx b
                  | (idx, b) <- zip [0 ..] rows
                  , bsCreatedAt b > 0
                  , yearOf (bsCreatedAt b) == year
                  ]
     in concatMap block years
  where
    orderedYears [] = []
    orderedYears (b : rest) =
        let y = yearOf (bsCreatedAt b)
            restYears = orderedYears rest
         in if y `elem` restYears then restYears else y : restYears

-- | Pixel height of the whole ledger at the current width.
ledgerContentHeight :: Model -> Int
ledgerContentHeight m = sum (map (entryHeight (mWidth m)) (ledgerEntries m))

{- | Pixel height of one ledger entry. These numbers are a contract with
eza.css: on the table layout (at least 768px) every row and year divider has
exactly this height, which the virtualized ledger needs to place its spacers.
The phone sheet keeps its own heights because its rows wrap.
-}
entryHeight :: Int -> LedgerEntry -> Int
entryHeight w = \case
    LedgerYear _ _ -> if w < 768 then 48 else 74
    LedgerRow _ _ -> if w < 768 then 72 else 48

-- | Is a bookmark currently selected for bulk actions?
isSelected :: Model -> Int -> Bool
isSelected m bookmarkId = IS.member bookmarkId (mSelection m)

-- | How many bookmarks are selected.
selectedCount :: Model -> Int
selectedCount = IS.size . mSelection

{- | Command-palette entries: navigation, actions, and recent bookmarks that
match the current palette query.  Kept in the model layer so both the view
and the update function agree on what Enter selects.
-}
paletteEntries :: Model -> [(MisoString, MisoString, Action)]
paletteEntries m = filter matches (commands ++ savedSearches ++ bookmarks)
  where
    needle = T.toLower (T.strip (toTextLow (mPaletteQ m)))
    matches (label, hint, _) =
        T.null needle
            || needle `T.isInfixOf` T.toLower (toTextLow label <> " " <> toTextLow hint)

    commands =
        [ ("Add bookmark", "POST", AddOpen)
        , ("Sign out", "session", LogoutRequest)
        , ("Toggle theme", "appearance", ThemeToggled)
        , ("Library", "all bookmarks", Navigate Index)
        , ("Inbox", "unread", Navigate Inbox)
        , ("Graph", "neighbourhood", Navigate Graph)
        , ("Duplicates", "dedup", Navigate Dedup)
        , ("Tags", "consolidate", Navigate Tags)
        , ("AI tags", "suggestions", Navigate AiTags)
        , ("Maintenance", "dead links + prune", Navigate Maintenance)
        , ("Account", "security", Navigate Account)
        , ("Import bookmarks", "Netscape HTML", ImportStart)
        , ("Export bookmarks", "Netscape HTML", ExportClicked)
        ]

    savedSearches =
        [ (ms (ssName saved), "saved search", SavedSearchApply saved)
        | saved <- mSaved m
        ]

    bookmarks =
        [ (ms (bsTitle b), ms (bsDomain b), Navigate (Bookmark (bsId b)))
        | b <- take 12 (mItems m)
        ]

    toTextLow :: MisoString -> Text
    toTextLow = fromMisoString

-- | Human friendly timestamp from unix seconds (milliseconds also accepted).
formatStamp :: Int -> MisoString
formatStamp t0
    | t0 <= 0 = ""
    | otherwise =
        let t = t0
            (y, mo, d) = civilFromDays (t `div` 86400)
            monthName = pickMonth mo
         in ms monthName <> " " <> ms (show d) <> ", " <> ms (show y)
  where
    pickMonth :: Int -> String
    pickMonth mo = fromMaybe "Jan" (lookup mo months)
    months :: [(Int, String)]
    months =
        [ (1, "Jan")
        , (2, "Feb")
        , (3, "Mar")
        , (4, "Apr")
        , (5, "May")
        , (6, "Jun")
        , (7, "Jul")
        , (8, "Aug")
        , (9, "Sep")
        , (10, "Oct")
        , (11, "Nov")
        , (12, "Dec")
        ]

-- | Filed date in data contexts: 2025.11.03.
formatFiled :: Int -> MisoString
formatFiled t
    | t <= 0 = ""
    | otherwise =
        let (y, mo, d) = civilFromDays (t `div` 86400)
         in ms (two y <> "." <> two mo <> "." <> two d)
  where
    two :: Int -> String
    two n = if n < 10 then '0' : show n else show n

-- | Date in prose contexts: 03 nov 2025.
formatProseDate :: Int -> MisoString
formatProseDate t
    | t <= 0 = ""
    | otherwise =
        let (y, mo, d) = civilFromDays (t `div` 86400)
            name = fromMaybe "jan" (lookup mo proseMonths)
         in ms (two d <> " " <> name <> " " <> show y)
  where
    two :: Int -> String
    two n = if n < 10 then '0' : show n else show n
    proseMonths =
        [ (1, "jan")
        , (2, "feb")
        , (3, "mar")
        , (4, "apr")
        , (5, "may")
        , (6, "jun")
        , (7, "jul")
        , (8, "aug")
        , (9, "sep")
        , (10, "oct")
        , (11, "nov")
        , (12, "dec")
        ]

-- | Howard Hinnant's days-to-civil algorithm.
civilFromDays :: Int -> (Int, Int, Int)
civilFromDays z0 =
    let z = z0 + 719468
        era = z `div` 146097
        doe = z - era * 146097
        yoe = (doe - doe `div` 1460 + doe `div` 36524 - doe `div` 146096) `div` 365
        y = yoe + era * 400
        doy = doe - (365 * yoe + yoe `div` 4 - yoe `div` 100)
        mp = (5 * doy + 2) `div` 153
        d = doy - (153 * mp + 2) `div` 5 + 1
        mo = if mp < 10 then mp + 3 else mp - 9
     in (if mo <= 2 then y + 1 else y, mo, d)

sortLabel :: Text -> MisoString
sortLabel = \case
    "created" -> "Saved date"
    "added" -> "Added date"
    "opened" -> "Last opened"
    _ -> "Saved date"

-- | Keeps the detail DTO in the import graph for the model record field type.
_unusedBookmarkDetail :: BookmarkDetail -> MisoString
_unusedBookmarkDetail _ = ""
