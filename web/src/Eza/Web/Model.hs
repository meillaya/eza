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
    ViewUi (..),
    ColorGroupField (..),
    LedgerEntry (..),
    ledgerEntries,
    ledgerContentHeight,
    entryHeight,
    yearOf,
    isoDay,
    formatStamp,
    formatStampUtc,
    formatFiled,
    formatProseDate,
    sortLabel,
    themeToMiso,
    themeOfMiso,
    paletteEntries,
    isSelected,
    selectedCount,
    isGraphRoute,
    activeGraphLayout,
) where

import Data.Aeson (Value)
import qualified Data.ByteString as BS
import Data.Char (isDigit)
import qualified Data.IntSet as IS
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8')
import Text.Read (readMaybe)

import Eza.Boot (BootPayload)
import Eza.GraphMatch (ColorAssignment)
import Eza.Ledger (LedgerEntry (..))
import qualified Eza.Ledger as Ledger
import Eza.Types (
    Backlink,
    BookmarkDetail,
    BookmarkSummary (..),
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
    UndoEntry,
    UndoPreview,
    UndoResult,
 )
import Eza.User (UserCreateResult, UserRole (..), UserView (..))
import Eza.View (
    ColorGroup (..),
    LabelMode (..),
    View (..),
    ViewKind (..),
 )
import Eza.Web.Api (LayoutWire (..), ListParams, WebhookTest (..))
import Eza.Web.Graph (
    GraphDrag,
    GraphLayout,
    GraphMatches,
    GraphView,
    LayoutPreset (..),
    emptyMatches,
    initialGraphView,
 )
import Eza.Webhook (DeliveryView, EventType, Webhook (..))

import Eza.Web.Types (AccountInfo, AiStatus, ApiError, ConsolGroup, ReaderSelection, Rule (..), SessionInfo, ShareView, TagSuggestion, TokenView)
import Miso hiding (View)
import Miso.Router (Router (..), RoutingError (..), Token (..), parseURI, routes, toCapture, toPath, toQueryParam)

-- | Which color-group field an editor keystroke changes.
data ColorGroupField = GroupName | GroupQuery | GroupColor
    deriving (Eq, Show)

-- | Transient state for the views manager and the save/import dialogs.
data ViewUi = ViewUi
    { vuSaveOpen :: Bool
    , vuSaveName :: MisoString
    , vuSaveKind :: ViewKind
    , vuImportOpen :: Bool
    , vuImportText :: MisoString
    , vuExport :: Maybe Text
    , vuRename :: Maybe (Text, MisoString)
    , vuError :: Maybe MisoString
    , vuBusy :: Bool
    }
    deriving (Eq, Show)

-- | Application routes.  @Bookmark@ carries the numeric bookmark id.
data Route
    = Index
    | Bookmark Int
    | Inbox
    | Graph
    | GraphLocal Int Int
    | Views
    | ViewOpen Text
    | Dedup
    | Tags
    | AiTags
    | Maintenance
    | Account
    | History
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
        GraphLocal rootKey depth ->
            [ toPath "graph"
            , toQueryParam "focus" (T.pack (show rootKey))
            , toQueryParam "depth" (T.pack (show depth))
            , toQueryParam "local" ("1" :: Text)
            ]
        Views -> [toPath "views"]
        ViewOpen slug -> [toPath "views", toPath (ms (T.unpack slug))]
        Dedup -> [toPath "dedup"]
        Tags -> [toPath "tags"]
        AiTags -> [toPath "tags", toPath "ai"]
        Maintenance -> [toPath "maintenance"]
        Account -> [toPath "account"]
        History -> [toPath "history"]
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
        | isDigit c = Just (fromEnum c - fromEnum '0')
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
    ["graph"]
        | queryText "local" == Just "1"
        , Just focusKey <- query "focus" >>= readMaybe . T.unpack ->
            GraphLocal focusKey (clampDepth (query "depth" >>= readMaybe . T.unpack))
        | otherwise -> Graph
    ["views"] -> Views
    ["views", slug] -> ViewOpen (fromMisoString (ms slug :: MisoString))
    ["dedup"] -> Dedup
    ["tags"] -> Tags
    ["tags", "ai"] -> AiTags
    ["maintenance"] -> Maintenance
    ["account"] -> Account
    ["history"] -> History
    ["accessions"] -> History
    -- PWA share_target landing page: /save?title=..&text=..&url=..
    ["save"] -> Save (query "title") (query "text") (query "url")
    _ -> NotFound
  where
    query key =
        fmap (percentDecode . (fromMisoString :: MisoString -> Text))
            =<< M.lookup key (uriQueryString uri)
    queryText key = query key
    clampDepth (Just depth) = max 1 (min 3 depth)
    clampDepth Nothing = 1

routeOfUri :: URI -> Route
routeOfUri uri =
    case toRoute (prettyURI uri) of
        Right r -> r
        Left _ -> NotFound

{- | The layout the plate is showing: the local neighbourhood when local mode
is on, otherwise the whole-library layout.
-}
activeGraphLayout :: Model -> Maybe GraphLayout
activeGraphLayout m
    | mGraphLocal m = mGraphLocalLayout m
    | otherwise = mGraphLayout m

-- | Both graph routes share the plate and the graph keyboard handling.
isGraphRoute :: Route -> Bool
isGraphRoute Graph = True
isGraphRoute GraphLocal{} = True
isGraphRoute _ = False

routeTitle :: Route -> MisoString
routeTitle = \case
    Index -> "Library"
    Bookmark _ -> "Bookmark"
    Inbox -> "Inbox"
    Graph -> "Graph"
    GraphLocal _ _ -> "Graph"
    Views -> "Views"
    ViewOpen _ -> "View"
    Dedup -> "Duplicates"
    Tags -> "Tags"
    AiTags -> "AI tags"
    Maintenance -> "Maintenance"
    Account -> "Account"
    History -> "History by year"
    Save _ _ _ -> "Save bookmark"
    NotFound -> "Not found"

routeSubtitle :: Route -> MisoString
routeSubtitle = \case
    Index -> "All records, newest first."
    Bookmark _ -> "One record."
    Inbox -> "Unread records."
    Graph -> "Records and tags, as a graph."
    GraphLocal _ depth -> "A local graph, " <> ms (show depth) <> " hop" <> (if depth == 1 then "" else "s") <> " deep."
    Views -> "Saved views."
    ViewOpen _ -> "A saved view."
    Dedup -> "Same address, same title."
    Tags -> "The tag vocabulary."
    AiTags -> "Tag suggestions."
    Maintenance -> "Dead links, prune, undo."
    Account -> "Account settings."
    History -> "Filing by year and source."
    Save _ _ _ -> "File a record."
    NotFound -> "Not found."

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
    | AccountWebhooks
    | AccountUsers
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
    AccountWebhooks -> "webhooks"
    AccountUsers -> "users"
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
        "webhooks" -> AccountWebhooks
        "users" -> AccountUsers
        "shares" -> AccountShares
        "rules" -> AccountRules
        "import" -> AccountImport
        "export" -> AccountImport
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
    , keRow :: Maybe Int
    {- ^ The bookmark id of the ledger row that owns the focused element,
    when the key was pressed inside one. Lets @Enter@ activate the row
    the reader tabbed to instead of the cursor row.
    -}
    }
    deriving (Eq, Show)

-- | Every user-visible action the client understands.
data Action
    = -- lifecycle / routing
      Mounted
    | RouteChanged MisoString (Either RoutingError Route)
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
    | ExtractEditStart
    | ExtractEditChanged MisoString
    | ExtractEditCancel
    | ExtractSaved Int
    | MarkLinkAlive
    | LinkMarkedAlive
    | RecheckLink
    | LinkRechecked
    | SavedOk Int
    | SaveFailed ApiError
    | ReadToggled
    | ReadPatched Int Bool
    | ReadPatchFailed Int Bool ApiError
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
    | GraphRefresh
    | OpenGraphAt Int
    | GraphMeasured Double Double Double
    | GraphPointerDown Double Double
    | GraphPointerMove Double Double
    | GraphPointerUp Double Double
    | GraphPointerLeave
    | GraphWheel Double Double Double
    | GraphZoomIn
    | GraphZoomOut
    | GraphFit
    | GraphFilterChanged MisoString
    | GraphFilterArmed Int
    | GraphFilterSettled
    | GraphTagsToggled
    | GraphSelect Int
    | GraphClearSelection
    | GraphSettled Int
    | GraphDetailStep Int Int
    | GraphLayoutLoaded LayoutPreset LayoutWire
    | GraphLayoutFailed ApiError
    | GraphLabelModeSelected LabelMode
    | GraphPresetSelected LayoutPreset
    | GraphScopeToggled
    | GraphLocalDepthSelected Int
    | GraphLocalAt Int Int
    | -- views
      ViewsLoaded [View]
    | ViewsFailed ApiError
    | ViewSaved View
    | ViewSaveFailed ApiError
    | ViewDeleted Text
    | ViewDeleteFailed ApiError
    | ViewFetched View
    | ViewFetchFailed ApiError
    | ViewOpenView Text
    | ViewDefaultView Text
    | ViewDeleteView Text
    | ViewExportView Text
    | ViewExportClose
    | ViewRenameStart Text
    | ViewRenameInput MisoString
    | ViewRenameSubmit
    | ViewDuplicateView Text
    | ViewSaveOpen ViewKind
    | ViewSaveNameInput MisoString
    | ViewSaveKindSelected ViewKind
    | ViewRenameCancel
    | ViewSaveSubmit
    | ViewSaveCancel
    | ViewImportOpen
    | ViewImportTextInput MisoString
    | ViewImportSubmit
    | ViewImportCancel
    | ViewGroupEditorToggle
    | ViewGroupAdd
    | ViewGroupRemove Int
    | ViewGroupField Int ColorGroupField MisoString
    | ViewGroupToggleEnabled Int
    | ViewGroupsSave
    | ViewGroupsCancel
    | ViewSaveGraph
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
    | DedupMerged Text Int Int (Maybe Int)
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
    | FilterByQuery Text
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
    | DeadCheckDone Int Int Int
    | UndoRefresh
    | UndoEntriesLoaded [UndoEntry]
    | UndoEntriesFailed ApiError
    | UndoPreviewRequest Int
    | UndoPreviewLoaded UndoPreview
    | UndoPreviewFailed ApiError
    | UndoPreviewClose
    | UndoConfirm Int
    | UndoDone UndoResult
    | UndoFailed ApiError
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
    | SelectAllMatchingCancel
    | SelectPageLoaded Int [Int] Bool
    | SelectPageFailed Int ApiError
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
    | -- admin users
      AdminUsersLoaded [UserView]
    | AdminUsersFailed ApiError
    | UserNameInput MisoString
    | UserPasswordInput MisoString
    | UserRoleSelected UserRole
    | UserCreate
    | UserCreated UserCreateResult
    | UserCreateFailed ApiError
    | UserToggleEnabled UserView
    | UserRoleChange UserView
    | UserUpdated UserView
    | UserUpdateFailed ApiError
    | UserResetOpen Int
    | UserDeleteOpen UserView
    | UserDeleteCancel
    | UserDeleteNameInput MisoString
    | UserDeleteLibraryToggled
    | UserDeleteSubmit
    | UserDeleted Int
    | UserDeleteFailed ApiError
    | UserResetPasswordInput MisoString
    | UserResetSubmit
    | UserResetCancel
    | UserResetDone Int Text
    | UserResetFailed ApiError
    | UserRecoveryCopied Text
    | UserRecoveryDismiss
    | UserResetShownDismiss
    | -- webhooks
      WebhooksLoaded [Webhook]
    | WebhooksFailed ApiError
    | WebhookNameInput MisoString
    | WebhookUrlInput MisoString
    | WebhookEventToggled EventType
    | WebhookEnabledToggled
    | WebhookCreate
    | WebhookCreated Webhook Text
    | WebhookCreateFailed ApiError
    | WebhookToggle Webhook
    | WebhookToggled Webhook
    | WebhookToggleFailed ApiError
    | WebhookTestRequest Int
    | WebhookTested Int WebhookTest
    | WebhookTestFailed ApiError
    | WebhookDelete Int
    | WebhookDeleted Int
    | WebhookDeleteFailed ApiError
    | WebhookSecretCopied Text
    | WebhookSecretDismiss
    | WebhookDeliveriesOpen Int
    | WebhookDeliveriesLoaded Int [DeliveryView]
    | WebhookDeliveriesFailed Int ApiError
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
    , -- token for the "select all matching" paging chain; every start, clear,
      -- search change, reload or route load bumps it so a response for an
      -- abandoned chain cannot repopulate the selection
      mSelectEpoch :: Int
    , -- the list epoch captured when the chain started; a newer result set
      -- stops the chain even when a reload only bumps the list epoch
      mSelectListEpoch :: Int
    , -- the stable query/filter/sort the chain pages through
      mSelectParams :: Maybe ListParams
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
    , -- monotonically increasing id for read-state PATCHes; a response older
      -- than the latest toggle is dropped
      mReadRequest :: Int
    , -- a read PATCH is in flight, so a note save must not echo a possibly
      -- stale is_read flag back to the server
      mReadPending :: Bool
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
    , -- the guard was opened by a history navigation (Back/Forward): the
      -- address already moved, so cancelling restores it and discarding does
      -- not push a second entry
      mGuardFromHistory :: Bool
    , mConfirmLogout :: Bool
    , -- graph: the fields a drag, hover, zoom or keystroke changes come
      -- first, so the derived Eq for Model short-circuits here instead of
      -- walking the heavy layout and payload at the end of the record
      mGraphView :: GraphView
    , mGraphViewReady :: Bool
    , mGraphHover :: Maybe Int
    , mGraphSelected :: Maybe Int
    , mGraphFocus :: Maybe Int
    , mGraphDrag :: Maybe GraphDrag
    , mGraphMatches :: GraphMatches
    , mGraphFilter :: MisoString
    , mGraphFilterTimer :: Maybe Int
    , -- TODO(M1/task-13): the label mode comes from the active graph view.
      mGraphLabelMode :: LabelMode
    , mGraphPreset :: LayoutPreset
    , mGraphLayoutWire :: Maybe (LayoutPreset, LayoutWire)
    , mGraphLayoutSource :: MisoString
    , mViews :: [View]
    , mViewsLoading :: Bool
    , mViewsError :: Maybe MisoString
    , mViewUi :: ViewUi
    , mGraphViewId :: Maybe Int
    , mGraphViewRev :: Int
    , mGraphColorGroups :: [ColorGroup]
    , mGraphGroupDrafts :: [ColorGroup]
    , mGraphGroupDirty :: Bool
    , mGraphGroupEditor :: Bool
    , mGraphLocal :: Bool
    , mGraphLocalDepth :: Int
    , mGraphLocalRoot :: Maybe Int
    , mGraphLocalCapped :: Bool
    , mGraphSettled :: Bool
    , mGraphSettleEpoch :: Int
    , mGraphDetailPhase :: Int
    , mGraphDetailChunks :: Int
    , mGraphTagsShown :: Bool
    , mGraphLoading :: Bool
    , mGraphError :: Maybe MisoString
    , mGraphGen :: Int
    , mGraphLayout :: Maybe GraphLayout
    , mGraphLocalLayout :: Maybe GraphLayout
    , mGraphColors :: Maybe ColorAssignment
    , mGraphGroupCounts :: [Int]
    , mGraph :: Maybe GraphData
    , -- dedup: exact counts plus two independently paged sections
      mDedupCounts :: Maybe DedupCounts
    , mDedupUrlGroups :: [DedupGroup]
    , mDedupTitleGroups :: [DedupGroup]
    , mDedupLoading :: Bool
    , mDedupError :: Maybe MisoString
    , mDedupChoice :: M.Map Text Int
    , mDedupConfirm :: Maybe Text
    , mDedupLast :: Maybe (Int, Int)
    , mDedupLastSnapshot :: Maybe Int
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
    , -- extracted text editor
      mExtractEditing :: Bool
    , mExtractDraft :: MisoString
    , mExtractDirty :: Bool
    , mExtractSaving :: Bool
    , -- maintenance
      mPrune :: [BookmarkSummary]
    , mPruneSel :: [Int]
    , mDeadCount :: Maybe Int
    , mCheckedCount :: Maybe Int
    , mMaintBusy :: Bool
    , mConfirmPrune :: Bool
    , mPruneError :: Maybe MisoString
    , mUndoEntries :: [UndoEntry]
    , mUndoLoading :: Bool
    , mUndoError :: Maybe MisoString
    , mUndoPreview :: Maybe UndoPreview
    , mUndoPreviewLoading :: Bool
    , mUndoPreviewError :: Maybe MisoString
    , mUndoBusy :: Bool
    , -- account
      mAccount :: Maybe AccountInfo
    , mAccountLoading :: Bool
    , mAccountError :: Maybe MisoString
    , mRecoveryCodes :: [Text]
    , mCredEdit :: Maybe (Text, MisoString)
    , mTokens :: [TokenView]
    , mTokensLoading :: Bool
    , mTokensError :: Maybe MisoString
    , mWebhooks :: [Webhook]
    , mWebhooksLoading :: Bool
    , mWebhooksError :: Maybe MisoString
    , mWebhookName :: MisoString
    , mWebhookUrl :: MisoString
    , mWebhookEvents :: [EventType]
    , mWebhookEnabled :: Bool
    , mWebhookSecret :: Maybe Text
    , mWebhookFormError :: Maybe MisoString
    , mWebhookBusy :: Bool
    , mWebhookTest :: Maybe (Int, WebhookTest)
    , mWebhookTestError :: Maybe MisoString
    , mWebhookDeliveries :: Maybe (Int, [DeliveryView])
    , mWebhookDeliveriesError :: Maybe MisoString
    , mAdminUsers :: [UserView]
    , mAdminUsersAllowed :: Bool
    , mAdminUsersLoading :: Bool
    , mAdminUsersError :: Maybe MisoString
    , mUserName :: MisoString
    , mUserPassword :: MisoString
    , mUserRole :: UserRole
    , mUserFormError :: Maybe MisoString
    , mUserBusy :: Bool
    , mUserRecovery :: Maybe (Text, [Text])
    , mUserReset :: Maybe Int
    , mUserResetPassword :: MisoString
    , mUserResetShown :: Maybe (Text, Text)
    , mUserActionError :: Maybe MisoString
    , mUserDelete :: Maybe UserView
    , mUserDeleteName :: MisoString
    , mUserDeleteLibrary :: Bool
    , mUserDeleteBusy :: Bool
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
        , mSelectEpoch = 0
        , mSelectListEpoch = 0
        , mSelectParams = Nothing
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
        , mReadRequest = 0
        , mReadPending = False
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
        , mGuardFromHistory = False
        , mConfirmLogout = False
        , mGraphView = initialGraphView
        , mGraphViewReady = False
        , mGraphHover = Nothing
        , mGraphSelected = Nothing
        , mGraphFocus = Nothing
        , mGraphDrag = Nothing
        , mGraphMatches = emptyMatches
        , mGraphFilter = ""
        , mGraphFilterTimer = Nothing
        , mGraphLabelMode = LabelAuto
        , mGraphPreset = Standard
        , mGraphLayoutWire = Nothing
        , mGraphLayoutSource = "local"
        , mViews = []
        , mViewsLoading = False
        , mViewsError = Nothing
        , mViewUi = ViewUi False "" GraphKind False "" Nothing Nothing Nothing False
        , mGraphViewId = Nothing
        , mGraphViewRev = 0
        , mGraphColorGroups = []
        , mGraphGroupDrafts = []
        , mGraphGroupDirty = False
        , mGraphGroupEditor = False
        , mGraphLocal = False
        , mGraphLocalDepth = 1
        , mGraphLocalRoot = Nothing
        , mGraphLocalCapped = False
        , mGraphSettled = False
        , mGraphSettleEpoch = 0
        , mGraphDetailPhase = 0
        , mGraphDetailChunks = 0
        , mGraphTagsShown = True
        , mGraphLoading = False
        , mGraphError = Nothing
        , mGraphGen = 0
        , mGraphLayout = Nothing
        , mGraphLocalLayout = Nothing
        , mGraphColors = Nothing
        , mGraphGroupCounts = []
        , mGraph = Nothing
        , mDedupCounts = Nothing
        , mDedupUrlGroups = []
        , mDedupTitleGroups = []
        , mDedupLoading = False
        , mDedupError = Nothing
        , mDedupChoice = M.empty
        , mDedupConfirm = Nothing
        , mDedupLast = Nothing
        , mDedupLastSnapshot = Nothing
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
        , mExtractEditing = False
        , mExtractDraft = ""
        , mExtractDirty = False
        , mExtractSaving = False
        , mPrune = []
        , mPruneSel = []
        , mDeadCount = Nothing
        , mCheckedCount = Nothing
        , mMaintBusy = False
        , mConfirmPrune = False
        , mPruneError = Nothing
        , mUndoEntries = []
        , mUndoLoading = False
        , mUndoError = Nothing
        , mUndoPreview = Nothing
        , mUndoPreviewLoading = False
        , mUndoPreviewError = Nothing
        , mUndoBusy = False
        , mAccount = Nothing
        , mAccountLoading = False
        , mAccountError = Nothing
        , mRecoveryCodes = []
        , mCredEdit = Nothing
        , mTokens = []
        , mTokensLoading = False
        , mTokensError = Nothing
        , mWebhooks = []
        , mWebhooksLoading = False
        , mWebhooksError = Nothing
        , mWebhookName = ""
        , mWebhookUrl = ""
        , mWebhookEvents = []
        , mWebhookEnabled = True
        , mWebhookSecret = Nothing
        , mWebhookFormError = Nothing
        , mWebhookBusy = False
        , mWebhookTest = Nothing
        , mWebhookTestError = Nothing
        , mWebhookDeliveries = Nothing
        , mWebhookDeliveriesError = Nothing
        , mAdminUsers = []
        , mAdminUsersAllowed = False
        , mAdminUsersLoading = False
        , mAdminUsersError = Nothing
        , mUserName = ""
        , mUserPassword = ""
        , mUserRole = RoleMember
        , mUserFormError = Nothing
        , mUserBusy = False
        , mUserRecovery = Nothing
        , mUserReset = Nothing
        , mUserResetPassword = ""
        , mUserResetShown = Nothing
        , mUserActionError = Nothing
        , mUserDelete = Nothing
        , mUserDeleteName = ""
        , mUserDeleteLibrary = False
        , mUserDeleteBusy = False
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

{- | One line of the ledger: a year divider or a record row.

The type and the pure grouping live in "Eza.Ledger" so the native test
suite can cover the divider order.
-}

{- | Group the loaded records into one year section per filed year, in the
order each year first appears in the loaded results. The grouping itself is
'Eza.Ledger.ledgerEntries'; the model only supplies the per-year match counts.
-}
ledgerEntries :: Model -> [LedgerEntry]
ledgerEntries m = Ledger.ledgerEntries (mYearHere m) (mItems m)

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
paletteEntries m = filter matches (fileRecord ++ savedSearches ++ bookmarks ++ sections ++ accountActions)
  where
    needle = T.toLower (T.strip (toTextLow (mPaletteQ m)))
    matches (label, hint, _) =
        T.null needle
            || needle `T.isInfixOf` T.toLower (toTextLow label <> " " <> toTextLow hint)

    fileRecord = [("file a record", "add", AddOpen)]

    savedSearches =
        [ (ms (ssName saved), "saved search", SavedSearchApply saved)
        | saved <- mSaved m
        ]

    bookmarks =
        [ (ms (bsTitle b), ms (bsDomain b), Navigate (Bookmark (bsId b)))
        | b <- take 12 (mItems m)
        ]

    sections =
        [ ("ledger", "all records", Navigate Index)
        , ("inbox", "unread", Navigate Inbox)
        , ("graph", "records and tags", Navigate Graph)
        , ("views", "saved views", Navigate Views)
        , ("duplicates", "same address", Navigate Dedup)
        , ("tags", "vocabulary", Navigate Tags)
        , ("ai tags", "suggestions", Navigate AiTags)
        , ("maintenance", "dead links and prune", Navigate Maintenance)
        , ("history", "by year", Navigate History)
        , ("account", "security", Navigate Account)
        ]

    accountActions =
        [ ("import bookmarks", "Netscape HTML", ImportStart)
        , ("export bookmarks", "Netscape HTML", ExportClicked)
        , ("toggle theme", "appearance", ThemeToggled)
        , ("sign out", "session", LogoutRequest)
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

-- | Undo history timestamp in UTC: 2026.11.09 18:42 UTC.
formatStampUtc :: Int -> MisoString
formatStampUtc t
    | t <= 0 = ""
    | otherwise =
        let (y, mo, d) = civilFromDays (t `div` 86400)
            seconds = t `mod` 86400
            two n = if n < 10 then '0' : show n else show n
         in ms (show y <> "." <> two mo <> "." <> two d <> " " <> two (seconds `div` 3600) <> ":" <> two ((seconds `mod` 3600) `div` 60) <> " UTC")

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
