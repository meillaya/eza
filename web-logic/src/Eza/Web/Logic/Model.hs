{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The whole pure client state and action vocabulary.

This module is Miso-free: it stores 'Text' instead of the shell's 'Text'
and names no browser type, so the model can be built and tested natively. The
web shell keeps only the rendering boundary ("Eza.Web.Render"), the URL/router
instance ("Eza.Web.Model") and the effect interpreter ("Eza.Web.Interpreter").

The route type and its URL grammar live in "Eza.Web.Logic.Route"; the request
algebra lives in "Eza.Web.Logic.Api".
-}
module Eza.Web.Logic.Model where

import Data.Aeson (FromJSON (..), Value, withObject, (.:))
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Eza.Account (AccountInfo, SessionInfo, TokenView)
import Eza.Ai (AiStatus, TagSuggestion)
import Eza.Boot (BootPayload (..), wireVersion)
import Eza.Consolidation (ConsolidationGroup)
import Eza.GraphLayout (GraphLayout, GraphLayoutWire, LayoutPreset (..))
import Eza.GraphMatch (ColorAssignment)
import Eza.Ledger (LedgerEntry (..))
import qualified Eza.Ledger as Ledger
import Eza.Rule (Rule (..))
import Eza.Share (ShareView)
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
import Eza.Webhook (DeliveryView, EventType, Webhook (..))

import Eza.Web.Logic.Error (ApiError (..))
import Eza.Web.Logic.Graph (
    GraphDrag,
    GraphMatches,
    GraphView,
    emptyMatches,
    initialGraphView,
 )
import Eza.Web.Logic.Ids (RequestId (..), TimerId (..))
import Eza.Web.Logic.Job (JobKind (..), JobPoll (..), JobStatus (..))
import Eza.Web.Logic.Route (Route (..))
import Eza.Web.Logic.Wire (ImportResponse (..), ListParams, WebhookTest (..))

{- | A text selection inside the reader, with character offsets relative to
the extracted text (used for highlight creation). This is client-local UI
state read from the DOM, not a server wire type.
-}
data ReaderSelection = ReaderSelection
    { rsStart :: Int
    , rsEnd :: Int
    , rsQuote :: Text
    }
    deriving (Eq, Show)

instance FromJSON ReaderSelection where
    parseJSON = withObject "ReaderSelection" $ \o ->
        ReaderSelection
            <$> o .: "start"
            <*> o .: "end"
            <*> o .: "quote"

-- | Which color-group field an editor keystroke changes.
data ColorGroupField = GroupName | GroupQuery | GroupColor
    deriving (Eq, Show)

-- | Transient state for the views manager and the save/import dialogs.
data ViewUi = ViewUi
    { vuSaveOpen :: Bool
    , vuSaveName :: Text
    , vuSaveKind :: ViewKind
    , vuImportOpen :: Bool
    , vuImportText :: Text
    , vuExport :: Maybe Text
    , vuRename :: Maybe (Text, Text)
    , vuError :: Maybe Text
    , vuBusy :: Bool
    }
    deriving (Eq, Show)

{- | The layout the plate is showing: the local neighbourhood when local mode
is on, otherwise the whole-library layout.
-}
activeGraphLayout :: Model -> Maybe GraphLayout
activeGraphLayout m
    | mGraphLocal m = mGraphLocalLayout m
    | otherwise = mGraphLayout m

{- | Does the boot document belong to this client's wire contract? A client
built against another version could misread the payload, so the update path
blocks the interface on a mismatch instead of painting defaults.
-}
bootWireVersionSupported :: BootPayload -> Bool
bootWireVersionSupported payload = bpWireVersion payload == wireVersion

-- | The blocking message shown when the boot document's wire version differs.
wireVersionMismatchMessage :: Int -> Text
wireVersionMismatchMessage serverVersion =
    T.pack
        ( "This page was built for wire version "
            <> show wireVersion
            <> ", but the server answers with wire version "
            <> show serverVersion
            <> ". Reload the page to load a matching build."
        )

data Theme = ThemeLight | ThemeDark
    deriving (Eq, Show)

-- | The theme name the browser storage and payload use.
themeToText :: Theme -> Text
themeToText ThemeLight = "light"
themeToText ThemeDark = "dark"

-- | Read a stored theme name back; anything else is the light theme.
themeOfText :: Text -> Theme
themeOfText name = if T.toLower (T.strip name) == "dark" then ThemeDark else ThemeLight

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
accountTabSlug :: AccountTab -> Text
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
accountTabFromSlug :: Text -> AccountTab
accountTabFromSlug raw =
    case T.toLower (T.dropWhile (== '#') (T.strip raw)) of
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
    , toastMessage :: Text
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
    | RouteChanged Text Route
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
    | -- a boot document built for another wire contract: block the UI
      WireVersionMismatch Int
    | ApiErrorRaised ApiError
    | ThemeLoaded Theme
    | ConnectivityChanged Bool
    | WindowOriginKnown Text
    | CopyBookmarklet Text
    | QuickSaved Int Bool
    | QuickSaveFailed ApiError
    | ScrollMetrics (Maybe (Int, Int, Int))
    | TagsRefreshed [TagStat]
    | StatsLoaded RequestId LibraryStats
    | StatsFailed RequestId ApiError
    | ReloadRoute
    | -- library
      SearchInput Text
    | SearchCommit
    | TimerRegistered Int
    | TimerFired TimerId
    | TagToggled Text
    | ClearFilters
    | SortSelected Text
    | UnreadToggled
    | ListLoaded Bool RequestId SearchPage
    | ListFailed Bool RequestId ApiError
    | MarkAllAbove
    | MarkAllDone Int
    | MarkAllFailed ApiError
    | SavedSearchApply SavedSearch
    | ExportClicked
    | -- add modal
      AddOpen
    | AddClose
    | AddUrlInput Text
    | AddTitleInput Text
    | AddTagsInput Text
    | AddNoteInput Text
    | AddSubmit
    | AddSucceeded Int
    | AddNoteSaved Int
    | AddNoteFailed Int ApiError
    | AddFailed ApiError
    | -- command palette
      PaletteOpen
    | PaletteClose
    | PaletteInput Text
    | PalettePrev
    | PaletteNext
    | PaletteChoose Int
    | PaletteSelect
    | -- detail
      DetailLoaded RequestId BookmarkDetail
    | DetailFailed RequestId ApiError
    | TitleInput Text
    | NoteChanged Text
    | NoteMeta Int (Maybe Text)
    | -- | The note editor caret offset, read by the shell after NoteChanged.
      NoteCursorRead Int
    | NoteModeChanged NoteMode
    | TagDraftInput Text
    | TagAdd
    | TagRemove Text
    | SaveBookmark
    | ExtractEditStart
    | ExtractEditChanged Text
    | ExtractEditCancel
    | ExtractSaved Int
    | MarkLinkAlive
    | LinkMarkedAlive
    | RecheckLink
    | LinkRechecked
    | SavedOk Int
    | SaveFailed ApiError
    | ReadToggled
    | ReadPatched RequestId Bool
    | ReadPatchFailed RequestId Bool ApiError
    | BacklinksLoaded RequestId [Backlink]
    | BacklinksFailed RequestId ApiError
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
    | ImportDone ImportResponse
    | ImportFailed ApiError
    | -- saved searches
      SavedSearchSave
    | SavedSearchNameInput Text
    | SavedSearchDelete Int
    | SavedSearchDone
    | SavedSearchFailed ApiError
    | SavedSearchesLoaded [SavedSearch]
    | SavedSearchesRefreshFailed ApiError
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
    | GraphFilterChanged Text
    | GraphFilterArmed Int
    | GraphFilterSettled
    | GraphTagsToggled
    | GraphSelect Int
    | GraphClearSelection
    | GraphSettled RequestId
    | GraphDetailStep RequestId Int
    | GraphLayoutLoaded LayoutPreset GraphLayoutWire
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
    | ViewRenameInput Text
    | ViewRenameSubmit
    | ViewDuplicateView Text
    | ViewSaveOpen ViewKind
    | ViewSaveNameInput Text
    | ViewSaveKindSelected ViewKind
    | ViewRenameCancel
    | ViewSaveSubmit
    | ViewSaveCancel
    | ViewImportOpen
    | ViewImportTextInput Text
    | ViewImportSubmit
    | ViewImportCancel
    | ViewGroupEditorToggle
    | ViewGroupAdd
    | ViewGroupRemove Int
    | ViewGroupField Int ColorGroupField Text
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
    | ConsolLoaded [ConsolidationGroup]
    | ConsolFailed ApiError
    | TagMerge [Text] Text
    | TagMerged
    | FilterByTag Text
    | FilterByQuery Text
    | TagRenamed Text Text
    | TagDeleted Text
    | TagDialogOpen TagDialog
    | TagDialogInput Text
    | TagDialogDetach
    | TagDialogConfirm
    | TagDialogClose
    | TagOpFailed ApiError
    | -- AI tags
      AiTagSelected (Maybe Text)
    | AiSuggestionsJobQueued (Maybe Text) Int
    | AiSuggestionsJobDone Int (Maybe Value)
    | AiSuggestionsJobFailed (Maybe Text)
    | AiSuggestionsJobAbandoned
    | SuggestionApply Int [Text]
    | SuggestionApplyFailed ApiError
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
    | DeadCheckJobQueued Int
    | DeadCheckJobDone (Maybe Value)
    | DeadCheckJobFailed (Maybe Text)
    | DeadCheckJobAbandoned
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
    | CredentialRenamed Text Text
    | CredentialDeleted Text
    | CredentialOpFailed ApiError
    | CredentialEditStart Text
    | CredentialNameInput Text
    | CredentialEditSave
    | CredentialEditCancel
    | CredentialRemoved Text
    | AccountReload
    | SecurityUsernameInput Text
    | SecurityCurrentPasswordInput Text
    | SecurityNewPasswordInput Text
    | SecurityConfirmPasswordInput Text
    | Security2faWantedToggled Bool
    | SecurityUsernameSave
    | SecurityPasswordSave
    | Security2faSave
    | SecuritySaved Text
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
    | SelectPageLoaded RequestId [Int] Bool
    | SelectPageFailed RequestId ApiError
    | BulkTagPromptOpen Bool
    | BulkTagInput Text
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
    | TokenNameInput Text
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
      HighlightsLoaded RequestId [Highlight]
    | HighlightsFailed RequestId ApiError
    | ReaderMouseUp
    | ReaderSelectionFound (Maybe ReaderSelection)
    | ReaderSelectionClear
    | HighlightCreateQuick
    | HighlightNoteOpen
    | HighlightNoteInput Text
    | HighlightNoteCancel
    | HighlightNoteSubmit
    | HighlightAdded Highlight
    | HighlightEditStart Int
    | HighlightEditInput Text
    | HighlightEditColor Text
    | HighlightEditCancel
    | HighlightEditSave
    | HighlightDelete Int
    | HighlightPatched
    | HighlightDeleted
    | HighlightFailed ApiError
    | -- sharing
      SharesLoaded RequestId [ShareView]
    | SharesFailed RequestId ApiError
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
    | SnapshotJobQueued Int Int
    | SnapshotJobDone Int (Maybe Value)
    | SnapshotJobFailed Int (Maybe Text)
    | SnapshotJobAbandoned Int
    | SnapshotClose
    | SnapshotViewerFailed
    | SnapshotViewerRetry
    | -- ai status
      AiStatusLoaded AiStatus
    | AiStatusFailed ApiError
    | -- admin users
      AdminUsersLoaded [UserView]
    | AdminUsersFailed ApiError
    | UserNameInput Text
    | UserPasswordInput Text
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
    | UserDeleteNameInput Text
    | UserDeleteLibraryToggled
    | UserDeleteSubmit
    | UserDeleted Int
    | UserDeleteFailed ApiError
    | UserResetPasswordInput Text
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
    | WebhookNameInput Text
    | WebhookUrlInput Text
    | WebhookEventToggled EventType
    | WebhookEnabledToggled
    | WebhookCreate
    | WebhookCreated Webhook Text
    | WebhookCreateFailed ApiError
    | WebhookToggle Webhook
    | WebhookToggled Webhook
    | WebhookToggleFailed ApiError
    | WebhookTestRequest Int
    | WebhookTestJobQueued Int Int
    | WebhookTestJobDone Int (Maybe Value)
    | WebhookTestJobFailed Int (Maybe Text)
    | WebhookTestJobAbandoned Int
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
    | RuleNameInput Text
    | RuleFieldSelected Text
    | RulePatternInput Text
    | RuleTagsInput Text
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
      ToastAdd Text ToastKind
    | ToastDismiss Int
    | -- async job polling (M4-D)
      JobStarted JobKind Int
    | JobTick JobKind Int TimerId
    | JobStatusLoaded JobKind Int RequestId JobStatus
    | JobStatusFailed JobKind Int RequestId ApiError
    | JobAbandoned JobKind Int
    | JobTimedOut JobKind Int

-- | Everything the UI needs to render itself.
data ShellFields = ShellFields
    -- routing / shell
    { sfRoute :: Route
    , sfTheme :: Theme
    , sfBooted :: Bool
    , -- boot payload reuse: the boot page seeds the default ledger, so a list
      -- route that arrives before /boot answers waits for it instead of
      -- fetching the same page a second time.
      sfBootReady :: Bool
    , sfBootSeeded :: Bool
    , sfRouted :: Bool
    , sfVersion :: Text
    , sfOrigin :: Text
    , sfWindowOrigin :: Text
    , sfOnline :: Bool
    , sfSignedOut :: Bool
    , -- a blocking screen message: the page may not paint stale state. Set
      -- when the boot document's wire version does not match this build.
      sfBlockingError :: Maybe Text
    , -- layout / virtualization
      sfWidth :: Int
    , sfHeight :: Int
    , sfScrollY :: Int
    , sfScrollRestore :: Maybe Int
    , sfGridTop :: Int
    , -- palette
      sfPaletteOpen :: Bool
    , sfPaletteQ :: Text
    , sfPaletteSel :: Int
    , sfGuardOpen :: Bool
    , sfPendingRoute :: Maybe Route
    , -- the guard was opened by a history navigation (Back/Forward): the
      -- address already moved, so cancelling restores it and discarding does
      -- not push a second entry
      sfGuardFromHistory :: Bool
    , sfConfirmLogout :: Bool
    , -- toasts
      sfToasts :: [Toast]
    , sfToastNext :: Int
    }
    deriving (Eq)

data LedgerFields = LedgerFields
    { lfListDeferred :: Bool
    , -- list fetch request id: a response for an older query is dropped
      lfListEpoch :: RequestId
    , -- library query state
      lfQ :: Text
    , lfTagsFilter :: [Text]
    , lfSort :: Text
    , lfUnreadOnly :: Bool
    , lfItems :: [BookmarkSummary]
    , lfTotal :: Int
    , lfHasMore :: Bool
    , lfOffset :: Int
    , lfLoading :: Bool
    , lfLoadingMore :: Bool
    , lfError :: Maybe Text
    , lfNotice :: Maybe Text
    {- ^ Browser timeout handle for the search debounce. Owned by the shell
        interpreter (it is what @clearTimeout@ needs); the native reducer owns
        the logical TimerId in @mDebounceTimer@.
    -}
    , -- the browser timeout handle of the pending search debounce

      lfDebounce :: Maybe Int
    , -- the native ledger's debounce TimerId and the last allocated timer id
      lfDebounceTimer :: Maybe TimerId
    -- ^ Next logical timer id, owned by the native ledger reducer.
    , lfTimerSeq :: TimerId
    , lfTags :: [TagStat]
    , lfStats :: Maybe LibraryStats
    , lfStatsError :: Maybe Text
    , -- the current stats request id: an answer for an older refresh is dropped
      lfStatsEpoch :: RequestId
    , lfYearHere :: [(Int, Int)]
    , lfLedgerCursor :: Maybe Int
    , lfDrawer :: Maybe Int
    , lfSaved :: [SavedSearch]
    , lfSavedName :: Text
    , lfSavedShare :: Maybe SavedSearch
    , lfSavedSearchesError :: Maybe Text
    , -- selection / bulk
      lfSelection :: IS.IntSet
    , lfSelectAnchor :: Maybe Int
    , lfSelectingAll :: Bool
    , lfSelectFetched :: Int
    , -- token for the "select all matching" paging chain; every start, clear,
      -- search change, reload or route load bumps it so a response for an
      -- abandoned chain cannot repopulate the selection
      lfSelectEpoch :: RequestId
    , -- the list epoch captured when the chain started; a newer result set
      -- stops the chain even when a reload only bumps the list epoch
      lfSelectListEpoch :: RequestId
    , -- the stable query/filter/sort the chain pages through
      lfSelectParams :: Maybe ListParams
    , lfBulkBusy :: Bool
    , lfTagPrompt :: Maybe Bool
    , lfTagPromptValue :: Text
    , lfConfirmDelete :: Maybe Int
    , lfConfirmBulkDelete :: Bool
    , lfConfirmMarkAll :: Bool
    }
    deriving (Eq)

data DetailFields = DetailFields
    -- detail
    { dtDetail :: Maybe BookmarkDetail
    , dtDetailLoading :: Bool
    , dtDetailError :: Maybe Text
    , -- detail fetch request id: a response for an older record is dropped
      dtDetailEpoch :: RequestId
    , -- monotonically increasing id for read-state PATCHes; a response older
      -- than the latest toggle is dropped
      dtReadRequest :: RequestId
    , -- a read PATCH is in flight, so a note save must not echo a possibly
      -- stale is_read flag back to the server
      dtReadPending :: Bool
    , dtEditTitle :: Text
    , dtEditNote :: Text
    , dtEditTags :: [Text]
    , dtNewTag :: Text
    , dtNoteMode :: NoteMode
    , dtNoteCursor :: Int
    , dtLinkQuery :: Maybe Text
    , dtLinkResults :: [BookmarkSummary]
    , dtLinkSel :: Int
    , dtBacklinks :: [Backlink]
    , dtHighlights :: [Highlight]
    , dtReaderSel :: Maybe ReaderSelection
    , dtHighlightNoteOpen :: Bool
    , dtHighlightNote :: Text
    , dtHighlightEdit :: Maybe Int
    , dtHighlightEditNote :: Text
    , dtHighlightEditColor :: Text
    , dtSnapshotOpen :: Bool
    , dtSaving :: Bool
    , dtDirty :: Bool
    , -- extracted text editor
      dtExtractEditing :: Bool
    , dtExtractDraft :: Text
    , dtExtractDirty :: Bool
    , dtExtractSaving :: Bool
    , -- snapshot capture in flight: busy while the enqueue/poll runs, and the
      -- job id once the server accepted it
      dtSnapshotBusy :: Bool
    , dtSnapshotViewerFailed :: Bool
    }
    deriving (Eq)

data GraphFields = GraphFields
    -- graph: the fields a drag, hover, zoom or keystroke changes come
    -- first, so the derived Eq for Model short-circuits here instead of
    -- walking the heavy layout and payload at the end of the record
    { grGraphView :: GraphView
    , grGraphViewReady :: Bool
    , grGraphHover :: Maybe Int
    , grGraphSelected :: Maybe Int
    , grGraphFocus :: Maybe Int
    , grGraphDrag :: Maybe GraphDrag
    , grGraphMatches :: GraphMatches
    , grGraphFilter :: Text
    , grGraphFilterTimer :: Maybe Int
    {- ^ The reader's last label-mode choice. While a saved view is active,
        its definition supplies the rendered mode (see
        'effectiveGraphLabelMode'); this field is the fallback.
    -}
    , grGraphLabelMode :: LabelMode
    , grGraphPreset :: LayoutPreset
    , grGraphLayoutWire :: Maybe (LayoutPreset, GraphLayoutWire)
    , grGraphLayoutSource :: Text
    , grGraphViewId :: Maybe Int
    , grGraphViewRev :: Int
    , grGraphColorGroups :: [ColorGroup]
    , grGraphGroupDrafts :: [ColorGroup]
    , grGraphGroupDirty :: Bool
    , grGraphGroupEditor :: Bool
    , grGraphLocal :: Bool
    , grGraphLocalDepth :: Int
    , grGraphLocalRoot :: Maybe Int
    , grGraphLocalCapped :: Bool
    , grGraphSettled :: Bool
    , -- settle/settle-plate request id: a timer armed for an older gesture is
      -- dropped; mGraphDetailPhase and mGraphDetailChunks are the frame
      -- progress counters of the accepted settle, not staleness ids
      grGraphSettleEpoch :: RequestId
    , grGraphDetailPhase :: Int
    , grGraphDetailChunks :: Int
    , grGraphTagsShown :: Bool
    , grGraphLoading :: Bool
    , grGraphError :: Maybe Text
    , grGraphGen :: Int
    , grGraphLayout :: Maybe GraphLayout
    , grGraphLocalLayout :: Maybe GraphLayout
    , grGraphColors :: Maybe ColorAssignment
    , grGraphGroupCounts :: [Int]
    , grGraph :: Maybe GraphData
    }
    deriving (Eq)

data ViewFields = ViewFields
    { vwViews :: [View]
    , vwViewsLoading :: Bool
    , vwViewsError :: Maybe Text
    , vwViewUi :: ViewUi
    }
    deriving (Eq)

data TagsFields = TagsFields
    { tgAiStatus :: Maybe AiStatus
    , -- tags / ai tags
      tgConsol :: [ConsolidationGroup]
    , tgConsolLoading :: Bool
    , tgConsolError :: Maybe Text
    , tgTagDialog :: Maybe TagDialog
    , tgTagDialogInput :: Text
    , tgTagDialogBusy :: Bool
    , tgTagDialogError :: Maybe Text
    , tgAiTag :: Maybe Text
    , tgSuggestions :: [TagSuggestion]
    , tgSuggestionsLoading :: Bool
    , tgSuggestionNotice :: Maybe Text
    , tgSuggestionError :: Maybe Text
    , tgAiStatusError :: Maybe Text
    , tgSuggestionApplyBusy :: Bool
    }
    deriving (Eq)

data DedupFields = DedupFields
    -- dedup: exact counts plus two independently paged sections
    { ddDedupCounts :: Maybe DedupCounts
    , ddDedupUrlGroups :: [DedupGroup]
    , ddDedupTitleGroups :: [DedupGroup]
    , ddDedupLoading :: Bool
    , ddDedupError :: Maybe Text
    , ddDedupChoice :: M.Map Text Int
    , ddDedupConfirm :: Maybe Text
    , ddDedupLast :: Maybe (Int, Int)
    , ddDedupLastSnapshot :: Maybe Int
    , ddDedupMoreBusy :: Bool
    , ddDedupBusy :: Bool
    , ddDedupMergeAllOpen :: Bool
    , ddDedupMergeAllReport :: Maybe DedupMergeAllReport
    }
    deriving (Eq)

data MaintFields = MaintFields
    -- maintenance
    { mnPrune :: [BookmarkSummary]
    , mnPruneSel :: [Int]
    , mnDeadCount :: Maybe Int
    , mnCheckedCount :: Maybe Int
    , mnMaintBusy :: Bool
    , mnConfirmPrune :: Bool
    , mnPruneError :: Maybe Text
    , mnUndoEntries :: [UndoEntry]
    , mnUndoLoading :: Bool
    , mnUndoError :: Maybe Text
    , mnUndoPreview :: Maybe UndoPreview
    , mnUndoPreviewLoading :: Bool
    , mnUndoPreviewError :: Maybe Text
    , mnUndoBusy :: Bool
    }
    deriving (Eq)

data AccountFields = AccountFields
    { acAccountTab :: AccountTab
    , acSessions :: [SessionInfo]
    , acSecurityUsername :: Text
    , acSecurityCurrent :: Text
    , acSecurityNew :: Text
    , acSecurityConfirm :: Text
    , acSecurity2faWanted :: Bool
    , acSecurityBusy :: Bool
    , acSecurityError :: Maybe Text
    , -- account
      acAccount :: Maybe AccountInfo
    , acAccountLoading :: Bool
    , acAccountError :: Maybe Text
    , acRecoveryCodes :: [Text]
    , acCredEdit :: Maybe (Text, Text)
    , acTokens :: [TokenView]
    , acTokensLoading :: Bool
    , acTokensError :: Maybe Text
    , acAdminUsers :: [UserView]
    , acAdminUsersAllowed :: Bool
    , acAdminUsersLoading :: Bool
    , acAdminUsersError :: Maybe Text
    , acUserName :: Text
    , acUserPassword :: Text
    , acUserRole :: UserRole
    , acUserFormError :: Maybe Text
    , acUserBusy :: Bool
    , acUserRecovery :: Maybe (Text, [Text])
    , acUserReset :: Maybe Int
    , acUserResetPassword :: Text
    , acUserResetShown :: Maybe (Text, Text)
    , acUserActionError :: Maybe Text
    , acUserDelete :: Maybe UserView
    , acUserDeleteName :: Text
    , acUserDeleteLibrary :: Bool
    , acUserDeleteBusy :: Bool
    , acTokenName :: Text
    , acTokenScopes :: [Text]
    , acTokenSecret :: Maybe (Text, TokenView)
    , acTokenBusy :: Bool
    }
    deriving (Eq)

data SharesFields = SharesFields
    { srShares :: [ShareView]
    , srSharesLoading :: Bool
    , srSharesError :: Maybe Text
    , srShareDialogOpen :: Bool
    , srShareIncludeNote :: Bool
    , srShareExpiryDays :: Int
    , srShareBusy :: Bool
    , srShareUrl :: Maybe Text
    }
    deriving (Eq)

data RuleFields = RuleFields
    { ruRules :: [Rule]
    , ruRulesLoading :: Bool
    , ruRulesError :: Maybe Text
    , ruRuleName :: Text
    , ruRuleField :: Text
    , ruRulePattern :: Text
    , ruRuleTags :: Text
    , ruRuleMarkRead :: Bool
    , ruRuleBusy :: Bool
    , ruRuleDryRun :: Maybe (Int, [Int])
    }
    deriving (Eq)

data WebhookFields = WebhookFields
    { wkWebhooks :: [Webhook]
    , wkWebhooksLoading :: Bool
    , wkWebhooksError :: Maybe Text
    , wkWebhookName :: Text
    , wkWebhookUrl :: Text
    , wkWebhookEvents :: [EventType]
    , wkWebhookEnabled :: Bool
    , wkWebhookSecret :: Maybe Text
    , wkWebhookFormError :: Maybe Text
    , wkWebhookBusy :: Bool
    , wkWebhookTest :: Maybe (Int, WebhookTest)
    , wkWebhookTestError :: Maybe (Int, Text)
    , wkWebhookDeliveries :: Maybe (Int, [DeliveryView])
    , wkWebhookDeliveriesError :: Maybe Text
    , wkWebhookTestBusy :: Bool
    }
    deriving (Eq)

data AddFields = AddFields
    -- add modal
    { adAddOpen :: Bool
    , adAddUrl :: Text
    , adAddTitle :: Text
    , adAddTags :: Text
    , adAddNote :: Text
    , adAddBusy :: Bool
    , adAddError :: Maybe Text
    }
    deriving (Eq)

data ImportFields = ImportFields
    -- import / export
    { ipImporting :: Bool
    , ipImportReport :: Maybe ImportReport
    }
    deriving (Eq)

data JobFields = JobFields
    -- async job polling (M4-D)
    { jbJobPolls :: IM.IntMap JobPoll
    , jbJobTimerNext :: TimerId
    , jbJobRequestNext :: RequestId
    }
    deriving (Eq)

data Model = Model
    { gShell :: ShellFields
    , gLedger :: LedgerFields
    , gDetail :: DetailFields
    , gGraph :: GraphFields
    , gViews :: ViewFields
    , gTags :: TagsFields
    , gDedup :: DedupFields
    , gMaint :: MaintFields
    , gAccount :: AccountFields
    , gShares :: SharesFields
    , gRules :: RuleFields
    , gWebhooks :: WebhookFields
    , gAdd :: AddFields
    , gImport :: ImportFields
    , gJobs :: JobFields
    }
    deriving (Eq)

initialModel :: Model
initialModel =
    Model
        { gShell =
            ShellFields
                { sfRoute = Index
                , sfTheme = ThemeLight
                , sfBooted = False
                , sfBootReady = False
                , sfBootSeeded = False
                , sfRouted = False
                , sfVersion = "0.1.0"
                , sfOrigin = ""
                , sfWindowOrigin = ""
                , sfOnline = True
                , sfSignedOut = False
                , sfBlockingError = Nothing
                , sfWidth = 1200
                , sfHeight = 900
                , sfScrollY = 0
                , sfScrollRestore = Nothing
                , sfGridTop = 240
                , sfPaletteOpen = False
                , sfPaletteQ = ""
                , sfPaletteSel = 0
                , sfGuardOpen = False
                , sfPendingRoute = Nothing
                , sfGuardFromHistory = False
                , sfConfirmLogout = False
                , sfToasts = []
                , sfToastNext = 0
                }
        , gLedger =
            LedgerFields
                { lfListDeferred = False
                , lfListEpoch = RequestId 0
                , lfQ = ""
                , lfTagsFilter = []
                , lfSort = "created"
                , lfUnreadOnly = False
                , lfItems = []
                , lfTotal = 0
                , lfHasMore = False
                , lfOffset = 0
                , -- the first paint is a skeleton: the boot payload or the deferred
                  -- list fetch fills the ledger
                  lfLoading = True
                , lfLoadingMore = False
                , lfError = Nothing
                , lfNotice = Nothing
                , lfDebounce = Nothing
                , lfDebounceTimer = Nothing
                , lfTimerSeq = TimerId 0
                , lfTags = []
                , lfStats = Nothing
                , lfStatsError = Nothing
                , lfStatsEpoch = RequestId 0
                , lfYearHere = []
                , lfLedgerCursor = Nothing
                , lfDrawer = Nothing
                , lfSaved = []
                , lfSavedName = ""
                , lfSavedShare = Nothing
                , lfSavedSearchesError = Nothing
                , lfSelection = IS.empty
                , lfSelectAnchor = Nothing
                , lfSelectingAll = False
                , lfSelectFetched = 0
                , lfSelectEpoch = RequestId 0
                , lfSelectListEpoch = RequestId 0
                , lfSelectParams = Nothing
                , lfBulkBusy = False
                , lfTagPrompt = Nothing
                , lfTagPromptValue = ""
                , lfConfirmDelete = Nothing
                , lfConfirmBulkDelete = False
                , lfConfirmMarkAll = False
                }
        , gDetail =
            DetailFields
                { dtDetail = Nothing
                , dtDetailLoading = False
                , dtDetailError = Nothing
                , dtDetailEpoch = RequestId 0
                , dtReadRequest = RequestId 0
                , dtReadPending = False
                , dtEditTitle = ""
                , dtEditNote = ""
                , dtEditTags = []
                , dtNewTag = ""
                , dtNoteMode = NoteWrite
                , dtNoteCursor = 0
                , dtLinkQuery = Nothing
                , dtLinkResults = []
                , dtLinkSel = 0
                , dtBacklinks = []
                , dtHighlights = []
                , dtReaderSel = Nothing
                , dtHighlightNoteOpen = False
                , dtHighlightNote = ""
                , dtHighlightEdit = Nothing
                , dtHighlightEditNote = ""
                , dtHighlightEditColor = "yellow"
                , dtSnapshotOpen = False
                , dtSaving = False
                , dtDirty = False
                , dtExtractEditing = False
                , dtExtractDraft = ""
                , dtExtractDirty = False
                , dtExtractSaving = False
                , dtSnapshotBusy = False
                , dtSnapshotViewerFailed = False
                }
        , gGraph =
            GraphFields
                { grGraphView = initialGraphView
                , grGraphViewReady = False
                , grGraphHover = Nothing
                , grGraphSelected = Nothing
                , grGraphFocus = Nothing
                , grGraphDrag = Nothing
                , grGraphMatches = emptyMatches
                , grGraphFilter = ""
                , grGraphFilterTimer = Nothing
                , grGraphLabelMode = LabelAuto
                , grGraphPreset = Standard
                , grGraphLayoutWire = Nothing
                , grGraphLayoutSource = ""
                , grGraphViewId = Nothing
                , grGraphViewRev = 0
                , grGraphColorGroups = []
                , grGraphGroupDrafts = []
                , grGraphGroupDirty = False
                , grGraphGroupEditor = False
                , grGraphLocal = False
                , grGraphLocalDepth = 1
                , grGraphLocalRoot = Nothing
                , grGraphLocalCapped = False
                , grGraphSettled = False
                , grGraphSettleEpoch = RequestId 0
                , grGraphDetailPhase = 0
                , grGraphDetailChunks = 0
                , grGraphTagsShown = True
                , grGraphLoading = False
                , grGraphError = Nothing
                , grGraphGen = 0
                , grGraphLayout = Nothing
                , grGraphLocalLayout = Nothing
                , grGraphColors = Nothing
                , grGraphGroupCounts = []
                , grGraph = Nothing
                }
        , gViews =
            ViewFields
                { vwViews = []
                , vwViewsLoading = False
                , vwViewsError = Nothing
                , vwViewUi = ViewUi False "" GraphKind False "" Nothing Nothing Nothing False
                }
        , gTags =
            TagsFields
                { tgAiStatus = Nothing
                , tgConsol = []
                , tgConsolLoading = False
                , tgConsolError = Nothing
                , tgTagDialog = Nothing
                , tgTagDialogInput = ""
                , tgTagDialogBusy = False
                , tgTagDialogError = Nothing
                , tgAiTag = Nothing
                , tgSuggestions = []
                , tgSuggestionsLoading = False
                , tgSuggestionNotice = Nothing
                , tgSuggestionError = Nothing
                , tgAiStatusError = Nothing
                , tgSuggestionApplyBusy = False
                }
        , gDedup =
            DedupFields
                { ddDedupCounts = Nothing
                , ddDedupUrlGroups = []
                , ddDedupTitleGroups = []
                , ddDedupLoading = False
                , ddDedupError = Nothing
                , ddDedupChoice = M.empty
                , ddDedupConfirm = Nothing
                , ddDedupLast = Nothing
                , ddDedupLastSnapshot = Nothing
                , ddDedupMoreBusy = False
                , ddDedupBusy = False
                , ddDedupMergeAllOpen = False
                , ddDedupMergeAllReport = Nothing
                }
        , gMaint =
            MaintFields
                { mnPrune = []
                , mnPruneSel = []
                , mnDeadCount = Nothing
                , mnCheckedCount = Nothing
                , mnMaintBusy = False
                , mnConfirmPrune = False
                , mnPruneError = Nothing
                , mnUndoEntries = []
                , mnUndoLoading = False
                , mnUndoError = Nothing
                , mnUndoPreview = Nothing
                , mnUndoPreviewLoading = False
                , mnUndoPreviewError = Nothing
                , mnUndoBusy = False
                }
        , gAccount =
            AccountFields
                { acAccountTab = AccountSecurity
                , acSessions = []
                , acSecurityUsername = ""
                , acSecurityCurrent = ""
                , acSecurityNew = ""
                , acSecurityConfirm = ""
                , acSecurity2faWanted = False
                , acSecurityBusy = False
                , acSecurityError = Nothing
                , acAccount = Nothing
                , acAccountLoading = False
                , acAccountError = Nothing
                , acRecoveryCodes = []
                , acCredEdit = Nothing
                , acTokens = []
                , acTokensLoading = False
                , acTokensError = Nothing
                , acAdminUsers = []
                , acAdminUsersAllowed = False
                , acAdminUsersLoading = False
                , acAdminUsersError = Nothing
                , acUserName = ""
                , acUserPassword = ""
                , acUserRole = RoleMember
                , acUserFormError = Nothing
                , acUserBusy = False
                , acUserRecovery = Nothing
                , acUserReset = Nothing
                , acUserResetPassword = ""
                , acUserResetShown = Nothing
                , acUserActionError = Nothing
                , acUserDelete = Nothing
                , acUserDeleteName = ""
                , acUserDeleteLibrary = False
                , acUserDeleteBusy = False
                , acTokenName = ""
                , acTokenScopes = ["read", "write"]
                , acTokenSecret = Nothing
                , acTokenBusy = False
                }
        , gShares =
            SharesFields
                { srShares = []
                , srSharesLoading = False
                , srSharesError = Nothing
                , srShareDialogOpen = False
                , srShareIncludeNote = False
                , srShareExpiryDays = 30
                , srShareBusy = False
                , srShareUrl = Nothing
                }
        , gRules =
            RuleFields
                { ruRules = []
                , ruRulesLoading = False
                , ruRulesError = Nothing
                , ruRuleName = ""
                , ruRuleField = "url"
                , ruRulePattern = ""
                , ruRuleTags = ""
                , ruRuleMarkRead = False
                , ruRuleBusy = False
                , ruRuleDryRun = Nothing
                }
        , gWebhooks =
            WebhookFields
                { wkWebhooks = []
                , wkWebhooksLoading = False
                , wkWebhooksError = Nothing
                , wkWebhookName = ""
                , wkWebhookUrl = ""
                , wkWebhookEvents = []
                , wkWebhookEnabled = True
                , wkWebhookSecret = Nothing
                , wkWebhookFormError = Nothing
                , wkWebhookBusy = False
                , wkWebhookTest = Nothing
                , wkWebhookTestError = Nothing
                , wkWebhookDeliveries = Nothing
                , wkWebhookDeliveriesError = Nothing
                , wkWebhookTestBusy = False
                }
        , gAdd =
            AddFields
                { adAddOpen = False
                , adAddUrl = ""
                , adAddTitle = ""
                , adAddTags = ""
                , adAddNote = ""
                , adAddBusy = False
                , adAddError = Nothing
                }
        , gImport =
            ImportFields
                { ipImporting = False
                , ipImportReport = Nothing
                }
        , gJobs =
            JobFields
                { jbJobPolls = IM.empty
                , jbJobTimerNext = TimerId 0
                , jbJobRequestNext = RequestId 0
                }
        }
{-# INLINE mRoute #-}
mRoute :: Model -> Route
mRoute model = sfRoute (gShell model)

{-# INLINE mTheme #-}
mTheme :: Model -> Theme
mTheme model = sfTheme (gShell model)

{-# INLINE mBooted #-}
mBooted :: Model -> Bool
mBooted model = sfBooted (gShell model)

{-# INLINE mBootReady #-}
mBootReady :: Model -> Bool
mBootReady model = sfBootReady (gShell model)

{-# INLINE mBootSeeded #-}
mBootSeeded :: Model -> Bool
mBootSeeded model = sfBootSeeded (gShell model)

{-# INLINE mRouted #-}
mRouted :: Model -> Bool
mRouted model = sfRouted (gShell model)

{-# INLINE mListDeferred #-}
mListDeferred :: Model -> Bool
mListDeferred model = lfListDeferred (gLedger model)

{-# INLINE mListEpoch #-}
mListEpoch :: Model -> RequestId
mListEpoch model = lfListEpoch (gLedger model)

{-# INLINE mVersion #-}
mVersion :: Model -> Text
mVersion model = sfVersion (gShell model)

{-# INLINE mOrigin #-}
mOrigin :: Model -> Text
mOrigin model = sfOrigin (gShell model)

{-# INLINE mWindowOrigin #-}
mWindowOrigin :: Model -> Text
mWindowOrigin model = sfWindowOrigin (gShell model)

{-# INLINE mOnline #-}
mOnline :: Model -> Bool
mOnline model = sfOnline (gShell model)

{-# INLINE mSignedOut #-}
mSignedOut :: Model -> Bool
mSignedOut model = sfSignedOut (gShell model)

{-# INLINE mBlockingError #-}
mBlockingError :: Model -> Maybe Text
mBlockingError model = sfBlockingError (gShell model)

{-# INLINE mWidth #-}
mWidth :: Model -> Int
mWidth model = sfWidth (gShell model)

{-# INLINE mHeight #-}
mHeight :: Model -> Int
mHeight model = sfHeight (gShell model)

{-# INLINE mScrollY #-}
mScrollY :: Model -> Int
mScrollY model = sfScrollY (gShell model)

{-# INLINE mScrollRestore #-}
mScrollRestore :: Model -> Maybe Int
mScrollRestore model = sfScrollRestore (gShell model)

{-# INLINE mGridTop #-}
mGridTop :: Model -> Int
mGridTop model = sfGridTop (gShell model)

{-# INLINE mQ #-}
mQ :: Model -> Text
mQ model = lfQ (gLedger model)

{-# INLINE mTagsFilter #-}
mTagsFilter :: Model -> [Text]
mTagsFilter model = lfTagsFilter (gLedger model)

{-# INLINE mSort #-}
mSort :: Model -> Text
mSort model = lfSort (gLedger model)

{-# INLINE mUnreadOnly #-}
mUnreadOnly :: Model -> Bool
mUnreadOnly model = lfUnreadOnly (gLedger model)

{-# INLINE mItems #-}
mItems :: Model -> [BookmarkSummary]
mItems model = lfItems (gLedger model)

{-# INLINE mTotal #-}
mTotal :: Model -> Int
mTotal model = lfTotal (gLedger model)

{-# INLINE mHasMore #-}
mHasMore :: Model -> Bool
mHasMore model = lfHasMore (gLedger model)

{-# INLINE mOffset #-}
mOffset :: Model -> Int
mOffset model = lfOffset (gLedger model)

{-# INLINE mLoading #-}
mLoading :: Model -> Bool
mLoading model = lfLoading (gLedger model)

{-# INLINE mLoadingMore #-}
mLoadingMore :: Model -> Bool
mLoadingMore model = lfLoadingMore (gLedger model)

{-# INLINE mError #-}
mError :: Model -> Maybe Text
mError model = lfError (gLedger model)

{-# INLINE mNotice #-}
mNotice :: Model -> Maybe Text
mNotice model = lfNotice (gLedger model)

{-# INLINE mDebounce #-}
mDebounce :: Model -> Maybe Int
mDebounce model = lfDebounce (gLedger model)

{-# INLINE mDebounceTimer #-}
mDebounceTimer :: Model -> Maybe TimerId
mDebounceTimer model = lfDebounceTimer (gLedger model)

{-# INLINE mTimerSeq #-}
mTimerSeq :: Model -> TimerId
mTimerSeq model = lfTimerSeq (gLedger model)

{-# INLINE mTags #-}
mTags :: Model -> [TagStat]
mTags model = lfTags (gLedger model)

{-# INLINE mStats #-}
mStats :: Model -> Maybe LibraryStats
mStats model = lfStats (gLedger model)

{-# INLINE mStatsError #-}
mStatsError :: Model -> Maybe Text
mStatsError model = lfStatsError (gLedger model)

{-# INLINE mStatsEpoch #-}
mStatsEpoch :: Model -> RequestId
mStatsEpoch model = lfStatsEpoch (gLedger model)

{-# INLINE mYearHere #-}
mYearHere :: Model -> [(Int, Int)]
mYearHere model = lfYearHere (gLedger model)

{-# INLINE mLedgerCursor #-}
mLedgerCursor :: Model -> Maybe Int
mLedgerCursor model = lfLedgerCursor (gLedger model)

{-# INLINE mDrawer #-}
mDrawer :: Model -> Maybe Int
mDrawer model = lfDrawer (gLedger model)

{-# INLINE mAccountTab #-}
mAccountTab :: Model -> AccountTab
mAccountTab model = acAccountTab (gAccount model)

{-# INLINE mSessions #-}
mSessions :: Model -> [SessionInfo]
mSessions model = acSessions (gAccount model)

{-# INLINE mSecurityUsername #-}
mSecurityUsername :: Model -> Text
mSecurityUsername model = acSecurityUsername (gAccount model)

{-# INLINE mSecurityCurrent #-}
mSecurityCurrent :: Model -> Text
mSecurityCurrent model = acSecurityCurrent (gAccount model)

{-# INLINE mSecurityNew #-}
mSecurityNew :: Model -> Text
mSecurityNew model = acSecurityNew (gAccount model)

{-# INLINE mSecurityConfirm #-}
mSecurityConfirm :: Model -> Text
mSecurityConfirm model = acSecurityConfirm (gAccount model)

{-# INLINE mSecurity2faWanted #-}
mSecurity2faWanted :: Model -> Bool
mSecurity2faWanted model = acSecurity2faWanted (gAccount model)

{-# INLINE mSecurityBusy #-}
mSecurityBusy :: Model -> Bool
mSecurityBusy model = acSecurityBusy (gAccount model)

{-# INLINE mSecurityError #-}
mSecurityError :: Model -> Maybe Text
mSecurityError model = acSecurityError (gAccount model)

{-# INLINE mSaved #-}
mSaved :: Model -> [SavedSearch]
mSaved model = lfSaved (gLedger model)

{-# INLINE mSavedName #-}
mSavedName :: Model -> Text
mSavedName model = lfSavedName (gLedger model)

{-# INLINE mSavedShare #-}
mSavedShare :: Model -> Maybe SavedSearch
mSavedShare model = lfSavedShare (gLedger model)

{-# INLINE mSelection #-}
mSelection :: Model -> IS.IntSet
mSelection model = lfSelection (gLedger model)

{-# INLINE mSelectAnchor #-}
mSelectAnchor :: Model -> Maybe Int
mSelectAnchor model = lfSelectAnchor (gLedger model)

{-# INLINE mSelectingAll #-}
mSelectingAll :: Model -> Bool
mSelectingAll model = lfSelectingAll (gLedger model)

{-# INLINE mSelectFetched #-}
mSelectFetched :: Model -> Int
mSelectFetched model = lfSelectFetched (gLedger model)

{-# INLINE mSelectEpoch #-}
mSelectEpoch :: Model -> RequestId
mSelectEpoch model = lfSelectEpoch (gLedger model)

{-# INLINE mSelectListEpoch #-}
mSelectListEpoch :: Model -> RequestId
mSelectListEpoch model = lfSelectListEpoch (gLedger model)

{-# INLINE mSelectParams #-}
mSelectParams :: Model -> Maybe ListParams
mSelectParams model = lfSelectParams (gLedger model)

{-# INLINE mBulkBusy #-}
mBulkBusy :: Model -> Bool
mBulkBusy model = lfBulkBusy (gLedger model)

{-# INLINE mTagPrompt #-}
mTagPrompt :: Model -> Maybe Bool
mTagPrompt model = lfTagPrompt (gLedger model)

{-# INLINE mTagPromptValue #-}
mTagPromptValue :: Model -> Text
mTagPromptValue model = lfTagPromptValue (gLedger model)

{-# INLINE mConfirmDelete #-}
mConfirmDelete :: Model -> Maybe Int
mConfirmDelete model = lfConfirmDelete (gLedger model)

{-# INLINE mConfirmBulkDelete #-}
mConfirmBulkDelete :: Model -> Bool
mConfirmBulkDelete model = lfConfirmBulkDelete (gLedger model)

{-# INLINE mConfirmMarkAll #-}
mConfirmMarkAll :: Model -> Bool
mConfirmMarkAll model = lfConfirmMarkAll (gLedger model)

{-# INLINE mAddOpen #-}
mAddOpen :: Model -> Bool
mAddOpen model = adAddOpen (gAdd model)

{-# INLINE mAddUrl #-}
mAddUrl :: Model -> Text
mAddUrl model = adAddUrl (gAdd model)

{-# INLINE mAddTitle #-}
mAddTitle :: Model -> Text
mAddTitle model = adAddTitle (gAdd model)

{-# INLINE mAddTags #-}
mAddTags :: Model -> Text
mAddTags model = adAddTags (gAdd model)

{-# INLINE mAddNote #-}
mAddNote :: Model -> Text
mAddNote model = adAddNote (gAdd model)

{-# INLINE mAddBusy #-}
mAddBusy :: Model -> Bool
mAddBusy model = adAddBusy (gAdd model)

{-# INLINE mAddError #-}
mAddError :: Model -> Maybe Text
mAddError model = adAddError (gAdd model)

{-# INLINE mPaletteOpen #-}
mPaletteOpen :: Model -> Bool
mPaletteOpen model = sfPaletteOpen (gShell model)

{-# INLINE mPaletteQ #-}
mPaletteQ :: Model -> Text
mPaletteQ model = sfPaletteQ (gShell model)

{-# INLINE mPaletteSel #-}
mPaletteSel :: Model -> Int
mPaletteSel model = sfPaletteSel (gShell model)

{-# INLINE mDetail #-}
mDetail :: Model -> Maybe BookmarkDetail
mDetail model = dtDetail (gDetail model)

{-# INLINE mDetailLoading #-}
mDetailLoading :: Model -> Bool
mDetailLoading model = dtDetailLoading (gDetail model)

{-# INLINE mDetailError #-}
mDetailError :: Model -> Maybe Text
mDetailError model = dtDetailError (gDetail model)

{-# INLINE mDetailEpoch #-}
mDetailEpoch :: Model -> RequestId
mDetailEpoch model = dtDetailEpoch (gDetail model)

{-# INLINE mReadRequest #-}
mReadRequest :: Model -> RequestId
mReadRequest model = dtReadRequest (gDetail model)

{-# INLINE mReadPending #-}
mReadPending :: Model -> Bool
mReadPending model = dtReadPending (gDetail model)

{-# INLINE mEditTitle #-}
mEditTitle :: Model -> Text
mEditTitle model = dtEditTitle (gDetail model)

{-# INLINE mEditNote #-}
mEditNote :: Model -> Text
mEditNote model = dtEditNote (gDetail model)

{-# INLINE mEditTags #-}
mEditTags :: Model -> [Text]
mEditTags model = dtEditTags (gDetail model)

{-# INLINE mNewTag #-}
mNewTag :: Model -> Text
mNewTag model = dtNewTag (gDetail model)

{-# INLINE mNoteMode #-}
mNoteMode :: Model -> NoteMode
mNoteMode model = dtNoteMode (gDetail model)

{-# INLINE mNoteCursor #-}
mNoteCursor :: Model -> Int
mNoteCursor model = dtNoteCursor (gDetail model)

{-# INLINE mLinkQuery #-}
mLinkQuery :: Model -> Maybe Text
mLinkQuery model = dtLinkQuery (gDetail model)

{-# INLINE mLinkResults #-}
mLinkResults :: Model -> [BookmarkSummary]
mLinkResults model = dtLinkResults (gDetail model)

{-# INLINE mLinkSel #-}
mLinkSel :: Model -> Int
mLinkSel model = dtLinkSel (gDetail model)

{-# INLINE mBacklinks #-}
mBacklinks :: Model -> [Backlink]
mBacklinks model = dtBacklinks (gDetail model)

{-# INLINE mHighlights #-}
mHighlights :: Model -> [Highlight]
mHighlights model = dtHighlights (gDetail model)

{-# INLINE mReaderSel #-}
mReaderSel :: Model -> Maybe ReaderSelection
mReaderSel model = dtReaderSel (gDetail model)

{-# INLINE mHighlightNoteOpen #-}
mHighlightNoteOpen :: Model -> Bool
mHighlightNoteOpen model = dtHighlightNoteOpen (gDetail model)

{-# INLINE mHighlightNote #-}
mHighlightNote :: Model -> Text
mHighlightNote model = dtHighlightNote (gDetail model)

{-# INLINE mHighlightEdit #-}
mHighlightEdit :: Model -> Maybe Int
mHighlightEdit model = dtHighlightEdit (gDetail model)

{-# INLINE mHighlightEditNote #-}
mHighlightEditNote :: Model -> Text
mHighlightEditNote model = dtHighlightEditNote (gDetail model)

{-# INLINE mHighlightEditColor #-}
mHighlightEditColor :: Model -> Text
mHighlightEditColor model = dtHighlightEditColor (gDetail model)

{-# INLINE mSnapshotOpen #-}
mSnapshotOpen :: Model -> Bool
mSnapshotOpen model = dtSnapshotOpen (gDetail model)

{-# INLINE mShares #-}
mShares :: Model -> [ShareView]
mShares model = srShares (gShares model)

{-# INLINE mSharesLoading #-}
mSharesLoading :: Model -> Bool
mSharesLoading model = srSharesLoading (gShares model)

{-# INLINE mSharesError #-}
mSharesError :: Model -> Maybe Text
mSharesError model = srSharesError (gShares model)

{-# INLINE mShareDialogOpen #-}
mShareDialogOpen :: Model -> Bool
mShareDialogOpen model = srShareDialogOpen (gShares model)

{-# INLINE mShareIncludeNote #-}
mShareIncludeNote :: Model -> Bool
mShareIncludeNote model = srShareIncludeNote (gShares model)

{-# INLINE mShareExpiryDays #-}
mShareExpiryDays :: Model -> Int
mShareExpiryDays model = srShareExpiryDays (gShares model)

{-# INLINE mShareBusy #-}
mShareBusy :: Model -> Bool
mShareBusy model = srShareBusy (gShares model)

{-# INLINE mShareUrl #-}
mShareUrl :: Model -> Maybe Text
mShareUrl model = srShareUrl (gShares model)

{-# INLINE mAiStatus #-}
mAiStatus :: Model -> Maybe AiStatus
mAiStatus model = tgAiStatus (gTags model)

{-# INLINE mRules #-}
mRules :: Model -> [Rule]
mRules model = ruRules (gRules model)

{-# INLINE mRulesLoading #-}
mRulesLoading :: Model -> Bool
mRulesLoading model = ruRulesLoading (gRules model)

{-# INLINE mRulesError #-}
mRulesError :: Model -> Maybe Text
mRulesError model = ruRulesError (gRules model)

{-# INLINE mRuleName #-}
mRuleName :: Model -> Text
mRuleName model = ruRuleName (gRules model)

{-# INLINE mRuleField #-}
mRuleField :: Model -> Text
mRuleField model = ruRuleField (gRules model)

{-# INLINE mRulePattern #-}
mRulePattern :: Model -> Text
mRulePattern model = ruRulePattern (gRules model)

{-# INLINE mRuleTags #-}
mRuleTags :: Model -> Text
mRuleTags model = ruRuleTags (gRules model)

{-# INLINE mRuleMarkRead #-}
mRuleMarkRead :: Model -> Bool
mRuleMarkRead model = ruRuleMarkRead (gRules model)

{-# INLINE mRuleBusy #-}
mRuleBusy :: Model -> Bool
mRuleBusy model = ruRuleBusy (gRules model)

{-# INLINE mRuleDryRun #-}
mRuleDryRun :: Model -> Maybe (Int, [Int])
mRuleDryRun model = ruRuleDryRun (gRules model)

{-# INLINE mSaving #-}
mSaving :: Model -> Bool
mSaving model = dtSaving (gDetail model)

{-# INLINE mDirty #-}
mDirty :: Model -> Bool
mDirty model = dtDirty (gDetail model)

{-# INLINE mGuardOpen #-}
mGuardOpen :: Model -> Bool
mGuardOpen model = sfGuardOpen (gShell model)

{-# INLINE mPendingRoute #-}
mPendingRoute :: Model -> Maybe Route
mPendingRoute model = sfPendingRoute (gShell model)

{-# INLINE mGuardFromHistory #-}
mGuardFromHistory :: Model -> Bool
mGuardFromHistory model = sfGuardFromHistory (gShell model)

{-# INLINE mConfirmLogout #-}
mConfirmLogout :: Model -> Bool
mConfirmLogout model = sfConfirmLogout (gShell model)

{-# INLINE mGraphView #-}
mGraphView :: Model -> GraphView
mGraphView model = grGraphView (gGraph model)

{-# INLINE mGraphViewReady #-}
mGraphViewReady :: Model -> Bool
mGraphViewReady model = grGraphViewReady (gGraph model)

{-# INLINE mGraphHover #-}
mGraphHover :: Model -> Maybe Int
mGraphHover model = grGraphHover (gGraph model)

{-# INLINE mGraphSelected #-}
mGraphSelected :: Model -> Maybe Int
mGraphSelected model = grGraphSelected (gGraph model)

{-# INLINE mGraphFocus #-}
mGraphFocus :: Model -> Maybe Int
mGraphFocus model = grGraphFocus (gGraph model)

{-# INLINE mGraphDrag #-}
mGraphDrag :: Model -> Maybe GraphDrag
mGraphDrag model = grGraphDrag (gGraph model)

{-# INLINE mGraphMatches #-}
mGraphMatches :: Model -> GraphMatches
mGraphMatches model = grGraphMatches (gGraph model)

{-# INLINE mGraphFilter #-}
mGraphFilter :: Model -> Text
mGraphFilter model = grGraphFilter (gGraph model)

{-# INLINE mGraphFilterTimer #-}
mGraphFilterTimer :: Model -> Maybe Int
mGraphFilterTimer model = grGraphFilterTimer (gGraph model)

{-# INLINE mGraphLabelMode #-}
mGraphLabelMode :: Model -> LabelMode
mGraphLabelMode model = grGraphLabelMode (gGraph model)

{-# INLINE mGraphPreset #-}
mGraphPreset :: Model -> LayoutPreset
mGraphPreset model = grGraphPreset (gGraph model)

{-# INLINE mGraphLayoutWire #-}
mGraphLayoutWire :: Model -> Maybe (LayoutPreset, GraphLayoutWire)
mGraphLayoutWire model = grGraphLayoutWire (gGraph model)

{-# INLINE mGraphLayoutSource #-}
mGraphLayoutSource :: Model -> Text
mGraphLayoutSource model = grGraphLayoutSource (gGraph model)

{-# INLINE mViews #-}
mViews :: Model -> [View]
mViews model = vwViews (gViews model)

{-# INLINE mViewsLoading #-}
mViewsLoading :: Model -> Bool
mViewsLoading model = vwViewsLoading (gViews model)

{-# INLINE mViewsError #-}
mViewsError :: Model -> Maybe Text
mViewsError model = vwViewsError (gViews model)

{-# INLINE mViewUi #-}
mViewUi :: Model -> ViewUi
mViewUi model = vwViewUi (gViews model)

{-# INLINE mGraphViewId #-}
mGraphViewId :: Model -> Maybe Int
mGraphViewId model = grGraphViewId (gGraph model)

{-# INLINE mGraphViewRev #-}
mGraphViewRev :: Model -> Int
mGraphViewRev model = grGraphViewRev (gGraph model)

{-# INLINE mGraphColorGroups #-}
mGraphColorGroups :: Model -> [ColorGroup]
mGraphColorGroups model = grGraphColorGroups (gGraph model)

{-# INLINE mGraphGroupDrafts #-}
mGraphGroupDrafts :: Model -> [ColorGroup]
mGraphGroupDrafts model = grGraphGroupDrafts (gGraph model)

{-# INLINE mGraphGroupDirty #-}
mGraphGroupDirty :: Model -> Bool
mGraphGroupDirty model = grGraphGroupDirty (gGraph model)

{-# INLINE mGraphGroupEditor #-}
mGraphGroupEditor :: Model -> Bool
mGraphGroupEditor model = grGraphGroupEditor (gGraph model)

{-# INLINE mGraphLocal #-}
mGraphLocal :: Model -> Bool
mGraphLocal model = grGraphLocal (gGraph model)

{-# INLINE mGraphLocalDepth #-}
mGraphLocalDepth :: Model -> Int
mGraphLocalDepth model = grGraphLocalDepth (gGraph model)

{-# INLINE mGraphLocalRoot #-}
mGraphLocalRoot :: Model -> Maybe Int
mGraphLocalRoot model = grGraphLocalRoot (gGraph model)

{-# INLINE mGraphLocalCapped #-}
mGraphLocalCapped :: Model -> Bool
mGraphLocalCapped model = grGraphLocalCapped (gGraph model)

{-# INLINE mGraphSettled #-}
mGraphSettled :: Model -> Bool
mGraphSettled model = grGraphSettled (gGraph model)

{-# INLINE mGraphSettleEpoch #-}
mGraphSettleEpoch :: Model -> RequestId
mGraphSettleEpoch model = grGraphSettleEpoch (gGraph model)

{-# INLINE mGraphDetailPhase #-}
mGraphDetailPhase :: Model -> Int
mGraphDetailPhase model = grGraphDetailPhase (gGraph model)

{-# INLINE mGraphDetailChunks #-}
mGraphDetailChunks :: Model -> Int
mGraphDetailChunks model = grGraphDetailChunks (gGraph model)

{-# INLINE mGraphTagsShown #-}
mGraphTagsShown :: Model -> Bool
mGraphTagsShown model = grGraphTagsShown (gGraph model)

{-# INLINE mGraphLoading #-}
mGraphLoading :: Model -> Bool
mGraphLoading model = grGraphLoading (gGraph model)

{-# INLINE mGraphError #-}
mGraphError :: Model -> Maybe Text
mGraphError model = grGraphError (gGraph model)

{-# INLINE mGraphGen #-}
mGraphGen :: Model -> Int
mGraphGen model = grGraphGen (gGraph model)

{-# INLINE mGraphLayout #-}
mGraphLayout :: Model -> Maybe GraphLayout
mGraphLayout model = grGraphLayout (gGraph model)

{-# INLINE mGraphLocalLayout #-}
mGraphLocalLayout :: Model -> Maybe GraphLayout
mGraphLocalLayout model = grGraphLocalLayout (gGraph model)

{-# INLINE mGraphColors #-}
mGraphColors :: Model -> Maybe ColorAssignment
mGraphColors model = grGraphColors (gGraph model)

{-# INLINE mGraphGroupCounts #-}
mGraphGroupCounts :: Model -> [Int]
mGraphGroupCounts model = grGraphGroupCounts (gGraph model)

{-# INLINE mGraph #-}
mGraph :: Model -> Maybe GraphData
mGraph model = grGraph (gGraph model)

{-# INLINE mDedupCounts #-}
mDedupCounts :: Model -> Maybe DedupCounts
mDedupCounts model = ddDedupCounts (gDedup model)

{-# INLINE mDedupUrlGroups #-}
mDedupUrlGroups :: Model -> [DedupGroup]
mDedupUrlGroups model = ddDedupUrlGroups (gDedup model)

{-# INLINE mDedupTitleGroups #-}
mDedupTitleGroups :: Model -> [DedupGroup]
mDedupTitleGroups model = ddDedupTitleGroups (gDedup model)

{-# INLINE mDedupLoading #-}
mDedupLoading :: Model -> Bool
mDedupLoading model = ddDedupLoading (gDedup model)

{-# INLINE mDedupError #-}
mDedupError :: Model -> Maybe Text
mDedupError model = ddDedupError (gDedup model)

{-# INLINE mDedupChoice #-}
mDedupChoice :: Model -> M.Map Text Int
mDedupChoice model = ddDedupChoice (gDedup model)

{-# INLINE mDedupConfirm #-}
mDedupConfirm :: Model -> Maybe Text
mDedupConfirm model = ddDedupConfirm (gDedup model)

{-# INLINE mDedupLast #-}
mDedupLast :: Model -> Maybe (Int, Int)
mDedupLast model = ddDedupLast (gDedup model)

{-# INLINE mDedupLastSnapshot #-}
mDedupLastSnapshot :: Model -> Maybe Int
mDedupLastSnapshot model = ddDedupLastSnapshot (gDedup model)

{-# INLINE mDedupMoreBusy #-}
mDedupMoreBusy :: Model -> Bool
mDedupMoreBusy model = ddDedupMoreBusy (gDedup model)

{-# INLINE mDedupBusy #-}
mDedupBusy :: Model -> Bool
mDedupBusy model = ddDedupBusy (gDedup model)

{-# INLINE mDedupMergeAllOpen #-}
mDedupMergeAllOpen :: Model -> Bool
mDedupMergeAllOpen model = ddDedupMergeAllOpen (gDedup model)

{-# INLINE mDedupMergeAllReport #-}
mDedupMergeAllReport :: Model -> Maybe DedupMergeAllReport
mDedupMergeAllReport model = ddDedupMergeAllReport (gDedup model)

{-# INLINE mConsol #-}
mConsol :: Model -> [ConsolidationGroup]
mConsol model = tgConsol (gTags model)

{-# INLINE mConsolLoading #-}
mConsolLoading :: Model -> Bool
mConsolLoading model = tgConsolLoading (gTags model)

{-# INLINE mConsolError #-}
mConsolError :: Model -> Maybe Text
mConsolError model = tgConsolError (gTags model)

{-# INLINE mTagDialog #-}
mTagDialog :: Model -> Maybe TagDialog
mTagDialog model = tgTagDialog (gTags model)

{-# INLINE mTagDialogInput #-}
mTagDialogInput :: Model -> Text
mTagDialogInput model = tgTagDialogInput (gTags model)

{-# INLINE mTagDialogBusy #-}
mTagDialogBusy :: Model -> Bool
mTagDialogBusy model = tgTagDialogBusy (gTags model)

{-# INLINE mTagDialogError #-}
mTagDialogError :: Model -> Maybe Text
mTagDialogError model = tgTagDialogError (gTags model)

{-# INLINE mAiTag #-}
mAiTag :: Model -> Maybe Text
mAiTag model = tgAiTag (gTags model)

{-# INLINE mSuggestions #-}
mSuggestions :: Model -> [TagSuggestion]
mSuggestions model = tgSuggestions (gTags model)

{-# INLINE mSuggestionsLoading #-}
mSuggestionsLoading :: Model -> Bool
mSuggestionsLoading model = tgSuggestionsLoading (gTags model)

{-# INLINE mSuggestionNotice #-}
mSuggestionNotice :: Model -> Maybe Text
mSuggestionNotice model = tgSuggestionNotice (gTags model)

{-# INLINE mSuggestionError #-}
mSuggestionError :: Model -> Maybe Text
mSuggestionError model = tgSuggestionError (gTags model)

{-# INLINE mExtractEditing #-}
mExtractEditing :: Model -> Bool
mExtractEditing model = dtExtractEditing (gDetail model)

{-# INLINE mExtractDraft #-}
mExtractDraft :: Model -> Text
mExtractDraft model = dtExtractDraft (gDetail model)

{-# INLINE mExtractDirty #-}
mExtractDirty :: Model -> Bool
mExtractDirty model = dtExtractDirty (gDetail model)

{-# INLINE mExtractSaving #-}
mExtractSaving :: Model -> Bool
mExtractSaving model = dtExtractSaving (gDetail model)

{-# INLINE mPrune #-}
mPrune :: Model -> [BookmarkSummary]
mPrune model = mnPrune (gMaint model)

{-# INLINE mPruneSel #-}
mPruneSel :: Model -> [Int]
mPruneSel model = mnPruneSel (gMaint model)

{-# INLINE mDeadCount #-}
mDeadCount :: Model -> Maybe Int
mDeadCount model = mnDeadCount (gMaint model)

{-# INLINE mCheckedCount #-}
mCheckedCount :: Model -> Maybe Int
mCheckedCount model = mnCheckedCount (gMaint model)

{-# INLINE mMaintBusy #-}
mMaintBusy :: Model -> Bool
mMaintBusy model = mnMaintBusy (gMaint model)

{-# INLINE mConfirmPrune #-}
mConfirmPrune :: Model -> Bool
mConfirmPrune model = mnConfirmPrune (gMaint model)

{-# INLINE mPruneError #-}
mPruneError :: Model -> Maybe Text
mPruneError model = mnPruneError (gMaint model)

{-# INLINE mUndoEntries #-}
mUndoEntries :: Model -> [UndoEntry]
mUndoEntries model = mnUndoEntries (gMaint model)

{-# INLINE mUndoLoading #-}
mUndoLoading :: Model -> Bool
mUndoLoading model = mnUndoLoading (gMaint model)

{-# INLINE mUndoError #-}
mUndoError :: Model -> Maybe Text
mUndoError model = mnUndoError (gMaint model)

{-# INLINE mUndoPreview #-}
mUndoPreview :: Model -> Maybe UndoPreview
mUndoPreview model = mnUndoPreview (gMaint model)

{-# INLINE mUndoPreviewLoading #-}
mUndoPreviewLoading :: Model -> Bool
mUndoPreviewLoading model = mnUndoPreviewLoading (gMaint model)

{-# INLINE mUndoPreviewError #-}
mUndoPreviewError :: Model -> Maybe Text
mUndoPreviewError model = mnUndoPreviewError (gMaint model)

{-# INLINE mUndoBusy #-}
mUndoBusy :: Model -> Bool
mUndoBusy model = mnUndoBusy (gMaint model)

{-# INLINE mAccount #-}
mAccount :: Model -> Maybe AccountInfo
mAccount model = acAccount (gAccount model)

{-# INLINE mAccountLoading #-}
mAccountLoading :: Model -> Bool
mAccountLoading model = acAccountLoading (gAccount model)

{-# INLINE mAccountError #-}
mAccountError :: Model -> Maybe Text
mAccountError model = acAccountError (gAccount model)

{-# INLINE mRecoveryCodes #-}
mRecoveryCodes :: Model -> [Text]
mRecoveryCodes model = acRecoveryCodes (gAccount model)

{-# INLINE mCredEdit #-}
mCredEdit :: Model -> Maybe (Text, Text)
mCredEdit model = acCredEdit (gAccount model)

{-# INLINE mTokens #-}
mTokens :: Model -> [TokenView]
mTokens model = acTokens (gAccount model)

{-# INLINE mTokensLoading #-}
mTokensLoading :: Model -> Bool
mTokensLoading model = acTokensLoading (gAccount model)

{-# INLINE mTokensError #-}
mTokensError :: Model -> Maybe Text
mTokensError model = acTokensError (gAccount model)

{-# INLINE mWebhooks #-}
mWebhooks :: Model -> [Webhook]
mWebhooks model = wkWebhooks (gWebhooks model)

{-# INLINE mWebhooksLoading #-}
mWebhooksLoading :: Model -> Bool
mWebhooksLoading model = wkWebhooksLoading (gWebhooks model)

{-# INLINE mWebhooksError #-}
mWebhooksError :: Model -> Maybe Text
mWebhooksError model = wkWebhooksError (gWebhooks model)

{-# INLINE mWebhookName #-}
mWebhookName :: Model -> Text
mWebhookName model = wkWebhookName (gWebhooks model)

{-# INLINE mWebhookUrl #-}
mWebhookUrl :: Model -> Text
mWebhookUrl model = wkWebhookUrl (gWebhooks model)

{-# INLINE mWebhookEvents #-}
mWebhookEvents :: Model -> [EventType]
mWebhookEvents model = wkWebhookEvents (gWebhooks model)

{-# INLINE mWebhookEnabled #-}
mWebhookEnabled :: Model -> Bool
mWebhookEnabled model = wkWebhookEnabled (gWebhooks model)

{-# INLINE mWebhookSecret #-}
mWebhookSecret :: Model -> Maybe Text
mWebhookSecret model = wkWebhookSecret (gWebhooks model)

{-# INLINE mWebhookFormError #-}
mWebhookFormError :: Model -> Maybe Text
mWebhookFormError model = wkWebhookFormError (gWebhooks model)

{-# INLINE mWebhookBusy #-}
mWebhookBusy :: Model -> Bool
mWebhookBusy model = wkWebhookBusy (gWebhooks model)

{-# INLINE mWebhookTest #-}
mWebhookTest :: Model -> Maybe (Int, WebhookTest)
mWebhookTest model = wkWebhookTest (gWebhooks model)

{-# INLINE mWebhookTestError #-}
mWebhookTestError :: Model -> Maybe (Int, Text)
mWebhookTestError model = wkWebhookTestError (gWebhooks model)

{-# INLINE mWebhookDeliveries #-}
mWebhookDeliveries :: Model -> Maybe (Int, [DeliveryView])
mWebhookDeliveries model = wkWebhookDeliveries (gWebhooks model)

{-# INLINE mWebhookDeliveriesError #-}
mWebhookDeliveriesError :: Model -> Maybe Text
mWebhookDeliveriesError model = wkWebhookDeliveriesError (gWebhooks model)

{-# INLINE mAdminUsers #-}
mAdminUsers :: Model -> [UserView]
mAdminUsers model = acAdminUsers (gAccount model)

{-# INLINE mAdminUsersAllowed #-}
mAdminUsersAllowed :: Model -> Bool
mAdminUsersAllowed model = acAdminUsersAllowed (gAccount model)

{-# INLINE mAdminUsersLoading #-}
mAdminUsersLoading :: Model -> Bool
mAdminUsersLoading model = acAdminUsersLoading (gAccount model)

{-# INLINE mAdminUsersError #-}
mAdminUsersError :: Model -> Maybe Text
mAdminUsersError model = acAdminUsersError (gAccount model)

{-# INLINE mUserName #-}
mUserName :: Model -> Text
mUserName model = acUserName (gAccount model)

{-# INLINE mUserPassword #-}
mUserPassword :: Model -> Text
mUserPassword model = acUserPassword (gAccount model)

{-# INLINE mUserRole #-}
mUserRole :: Model -> UserRole
mUserRole model = acUserRole (gAccount model)

{-# INLINE mUserFormError #-}
mUserFormError :: Model -> Maybe Text
mUserFormError model = acUserFormError (gAccount model)

{-# INLINE mUserBusy #-}
mUserBusy :: Model -> Bool
mUserBusy model = acUserBusy (gAccount model)

{-# INLINE mUserRecovery #-}
mUserRecovery :: Model -> Maybe (Text, [Text])
mUserRecovery model = acUserRecovery (gAccount model)

{-# INLINE mUserReset #-}
mUserReset :: Model -> Maybe Int
mUserReset model = acUserReset (gAccount model)

{-# INLINE mUserResetPassword #-}
mUserResetPassword :: Model -> Text
mUserResetPassword model = acUserResetPassword (gAccount model)

{-# INLINE mUserResetShown #-}
mUserResetShown :: Model -> Maybe (Text, Text)
mUserResetShown model = acUserResetShown (gAccount model)

{-# INLINE mUserActionError #-}
mUserActionError :: Model -> Maybe Text
mUserActionError model = acUserActionError (gAccount model)

{-# INLINE mUserDelete #-}
mUserDelete :: Model -> Maybe UserView
mUserDelete model = acUserDelete (gAccount model)

{-# INLINE mUserDeleteName #-}
mUserDeleteName :: Model -> Text
mUserDeleteName model = acUserDeleteName (gAccount model)

{-# INLINE mUserDeleteLibrary #-}
mUserDeleteLibrary :: Model -> Bool
mUserDeleteLibrary model = acUserDeleteLibrary (gAccount model)

{-# INLINE mUserDeleteBusy #-}
mUserDeleteBusy :: Model -> Bool
mUserDeleteBusy model = acUserDeleteBusy (gAccount model)

{-# INLINE mTokenName #-}
mTokenName :: Model -> Text
mTokenName model = acTokenName (gAccount model)

{-# INLINE mTokenScopes #-}
mTokenScopes :: Model -> [Text]
mTokenScopes model = acTokenScopes (gAccount model)

{-# INLINE mTokenSecret #-}
mTokenSecret :: Model -> Maybe (Text, TokenView)
mTokenSecret model = acTokenSecret (gAccount model)

{-# INLINE mTokenBusy #-}
mTokenBusy :: Model -> Bool
mTokenBusy model = acTokenBusy (gAccount model)

{-# INLINE mImporting #-}
mImporting :: Model -> Bool
mImporting model = ipImporting (gImport model)

{-# INLINE mImportReport #-}
mImportReport :: Model -> Maybe ImportReport
mImportReport model = ipImportReport (gImport model)

{-# INLINE mToasts #-}
mToasts :: Model -> [Toast]
mToasts model = sfToasts (gShell model)

{-# INLINE mToastNext #-}
mToastNext :: Model -> Int
mToastNext model = sfToastNext (gShell model)

{-# INLINE mJobPolls #-}
mJobPolls :: Model -> IM.IntMap JobPoll
mJobPolls model = jbJobPolls (gJobs model)

{-# INLINE mJobTimerNext #-}
mJobTimerNext :: Model -> TimerId
mJobTimerNext model = jbJobTimerNext (gJobs model)

{-# INLINE mJobRequestNext #-}
mJobRequestNext :: Model -> RequestId
mJobRequestNext model = jbJobRequestNext (gJobs model)

{-# INLINE mSnapshotBusy #-}
mSnapshotBusy :: Model -> Bool
mSnapshotBusy model = dtSnapshotBusy (gDetail model)

{-# INLINE mWebhookTestBusy #-}
mWebhookTestBusy :: Model -> Bool
mWebhookTestBusy model = wkWebhookTestBusy (gWebhooks model)

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
paletteEntries :: Model -> [(Text, Text, Action)]
paletteEntries m = filter matches (fileRecord ++ savedSearches ++ bookmarks ++ sections ++ accountActions)
  where
    needle = T.toLower (T.strip (toTextLow (mPaletteQ m)))
    matches (label, hint, _) =
        T.null needle
            || needle `T.isInfixOf` T.toLower (toTextLow label <> " " <> toTextLow hint)

    fileRecord = [("file a record", "add", AddOpen)]

    savedSearches =
        [ (ssName saved, "saved search", SavedSearchApply saved)
        | saved <- mSaved m
        ]

    bookmarks =
        [ (bsTitle b, bsDomain b, Navigate (Bookmark (bsId b)))
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

    toTextLow :: Text -> Text
    toTextLow = id

-- | Human friendly timestamp from unix seconds (milliseconds also accepted).
formatStamp :: Int -> Text
formatStamp t0
    | t0 <= 0 = ""
    | otherwise =
        let t = t0
            (y, mo, d) = civilFromDays (t `div` 86400)
            monthName = pickMonth mo
         in T.pack monthName <> " " <> T.pack (show d) <> ", " <> T.pack (show y)
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
formatStampUtc :: Int -> Text
formatStampUtc t
    | t <= 0 = ""
    | otherwise =
        let (y, mo, d) = civilFromDays (t `div` 86400)
            seconds = t `mod` 86400
            two n = if n < 10 then '0' : show n else show n
         in T.pack (show y <> "." <> two mo <> "." <> two d <> " " <> two (seconds `div` 3600) <> ":" <> two ((seconds `mod` 3600) `div` 60) <> " UTC")

-- | Filed date in data contexts: 2025.11.03.
formatFiled :: Int -> Text
formatFiled t
    | t <= 0 = ""
    | otherwise =
        let (y, mo, d) = civilFromDays (t `div` 86400)
         in T.pack (two y <> "." <> two mo <> "." <> two d)
  where
    two :: Int -> String
    two n = if n < 10 then '0' : show n else show n

-- | Date in prose contexts: 03 nov 2025.
formatProseDate :: Int -> Text
formatProseDate t
    | t <= 0 = ""
    | otherwise =
        let (y, mo, d) = civilFromDays (t `div` 86400)
            name = fromMaybe "jan" (lookup mo proseMonths)
         in T.pack (two d <> " " <> name <> " " <> show y)
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

sortLabel :: Text -> Text
sortLabel = \case
    "created" -> "Saved date"
    "added" -> "Added date"
    "opened" -> "Last opened"
    _ -> "Saved date"

-- | Keeps the detail DTO in the import graph for the model record field type.
_unusedBookmarkDetail :: BookmarkDetail -> Text
_unusedBookmarkDetail _ = ""

{-# INLINE mSnapshotViewerFailed #-}
mSnapshotViewerFailed :: Model -> Bool
mSnapshotViewerFailed model = dtSnapshotViewerFailed (gDetail model)

{-# INLINE mAiStatusError #-}
mAiStatusError :: Model -> Maybe Text
mAiStatusError model = tgAiStatusError (gTags model)

{-# INLINE mSuggestionApplyBusy #-}
mSuggestionApplyBusy :: Model -> Bool
mSuggestionApplyBusy model = tgSuggestionApplyBusy (gTags model)

{-# INLINE mSavedSearchesError #-}
mSavedSearchesError :: Model -> Maybe Text
mSavedSearchesError model = lfSavedSearchesError (gLedger model)
