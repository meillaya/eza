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

import Data.Aeson (FromJSON (..), withObject, (.:))
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

import Eza.Web.Logic.Effect (RequestId (..), TimerId)
import Eza.Web.Logic.Error (ApiError (..))
import Eza.Web.Logic.Graph (
    GraphDrag,
    GraphMatches,
    GraphView,
    emptyMatches,
    initialGraphView,
 )
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
    | ApiUnauthorized
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
    | OpenToggled
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
    | SuggestionsLoaded [TagSuggestion] (Maybe Text)
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
    | SnapshotClose
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
    , -- list fetch request id: a response for an older query is dropped
      mListEpoch :: RequestId
    , mVersion :: Text
    , mOrigin :: Text
    , mWindowOrigin :: Text
    , mOnline :: Bool
    , mSignedOut :: Bool
    , -- a blocking screen message: the page may not paint stale state. Set
      -- when the boot document's wire version does not match this build.
      mBlockingError :: Maybe Text
    , -- layout / virtualization
      mWidth :: Int
    , mHeight :: Int
    , mScrollY :: Int
    , mScrollRestore :: Maybe Int
    , mGridTop :: Int
    , -- library query state
      mQ :: Text
    , mTagsFilter :: [Text]
    , mSort :: Text
    , mUnreadOnly :: Bool
    , mItems :: [BookmarkSummary]
    , mTotal :: Int
    , mHasMore :: Bool
    , mOffset :: Int
    , mLoading :: Bool
    , mLoadingMore :: Bool
    , mError :: Maybe Text
    , mNotice :: Maybe Text
    , -- the browser timeout handle of the pending search debounce
      mDebounce :: Maybe Int
    , -- the native ledger's debounce TimerId and the last allocated timer id
      mDebounceTimer :: Maybe TimerId
    , mTimerSeq :: Int
    , mTags :: [TagStat]
    , mStats :: Maybe LibraryStats
    , mStatsError :: Maybe Text
    , -- the current stats request id: an answer for an older refresh is dropped
      mStatsEpoch :: RequestId
    , mYearHere :: [(Int, Int)]
    , mLedgerCursor :: Maybe Int
    , mDrawer :: Maybe Int
    , mAccountTab :: AccountTab
    , mSessions :: [SessionInfo]
    , mSecurityUsername :: Text
    , mSecurityCurrent :: Text
    , mSecurityNew :: Text
    , mSecurityConfirm :: Text
    , mSecurity2faWanted :: Bool
    , mSecurityBusy :: Bool
    , mSecurityError :: Maybe Text
    , mSaved :: [SavedSearch]
    , mSavedName :: Text
    , mSavedShare :: Maybe SavedSearch
    , -- selection / bulk
      mSelection :: IS.IntSet
    , mSelectAnchor :: Maybe Int
    , mSelectingAll :: Bool
    , mSelectFetched :: Int
    , -- token for the "select all matching" paging chain; every start, clear,
      -- search change, reload or route load bumps it so a response for an
      -- abandoned chain cannot repopulate the selection
      mSelectEpoch :: RequestId
    , -- the list epoch captured when the chain started; a newer result set
      -- stops the chain even when a reload only bumps the list epoch
      mSelectListEpoch :: RequestId
    , -- the stable query/filter/sort the chain pages through
      mSelectParams :: Maybe ListParams
    , mBulkBusy :: Bool
    , mTagPrompt :: Maybe Bool
    , mTagPromptValue :: Text
    , mConfirmDelete :: Maybe Int
    , mConfirmBulkDelete :: Bool
    , mConfirmMarkAll :: Bool
    , -- add modal
      mAddOpen :: Bool
    , mAddUrl :: Text
    , mAddTitle :: Text
    , mAddTags :: Text
    , mAddNote :: Text
    , mAddBusy :: Bool
    , mAddError :: Maybe Text
    , -- palette
      mPaletteOpen :: Bool
    , mPaletteQ :: Text
    , mPaletteSel :: Int
    , -- detail
      mDetail :: Maybe BookmarkDetail
    , mDetailLoading :: Bool
    , mDetailError :: Maybe Text
    , -- detail fetch request id: a response for an older record is dropped
      mDetailEpoch :: RequestId
    , -- monotonically increasing id for read-state PATCHes; a response older
      -- than the latest toggle is dropped
      mReadRequest :: RequestId
    , -- a read PATCH is in flight, so a note save must not echo a possibly
      -- stale is_read flag back to the server
      mReadPending :: Bool
    , mEditTitle :: Text
    , mEditNote :: Text
    , mEditTags :: [Text]
    , mNewTag :: Text
    , mNoteMode :: NoteMode
    , mNoteCursor :: Int
    , mLinkQuery :: Maybe Text
    , mLinkResults :: [BookmarkSummary]
    , mLinkSel :: Int
    , mBacklinks :: [Backlink]
    , mHighlights :: [Highlight]
    , mHighlightsLoading :: Bool
    , mReaderSel :: Maybe ReaderSelection
    , mHighlightNoteOpen :: Bool
    , mHighlightNote :: Text
    , mHighlightEdit :: Maybe Int
    , mHighlightEditNote :: Text
    , mHighlightEditColor :: Text
    , mSnapshotOpen :: Bool
    , mShares :: [ShareView]
    , mSharesLoading :: Bool
    , mSharesError :: Maybe Text
    , mShareDialogOpen :: Bool
    , mShareIncludeNote :: Bool
    , mShareExpiryDays :: Int
    , mShareBusy :: Bool
    , mShareUrl :: Maybe Text
    , mAiStatus :: Maybe AiStatus
    , mRules :: [Rule]
    , mRulesLoading :: Bool
    , mRulesError :: Maybe Text
    , mRuleName :: Text
    , mRuleField :: Text
    , mRulePattern :: Text
    , mRuleTags :: Text
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
    , mGraphFilter :: Text
    , mGraphFilterTimer :: Maybe Int
    , -- TODO(M1/task-13): the label mode comes from the active graph view.
      mGraphLabelMode :: LabelMode
    , mGraphPreset :: LayoutPreset
    , mGraphLayoutWire :: Maybe (LayoutPreset, GraphLayoutWire)
    , mGraphLayoutSource :: Text
    , mViews :: [View]
    , mViewsLoading :: Bool
    , mViewsError :: Maybe Text
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
    , -- settle/settle-plate request id: a timer armed for an older gesture is
      -- dropped; mGraphDetailPhase and mGraphDetailChunks are the frame
      -- progress counters of the accepted settle, not staleness ids
      mGraphSettleEpoch :: RequestId
    , mGraphDetailPhase :: Int
    , mGraphDetailChunks :: Int
    , mGraphTagsShown :: Bool
    , mGraphLoading :: Bool
    , mGraphError :: Maybe Text
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
    , mDedupError :: Maybe Text
    , mDedupChoice :: M.Map Text Int
    , mDedupConfirm :: Maybe Text
    , mDedupLast :: Maybe (Int, Int)
    , mDedupLastSnapshot :: Maybe Int
    , mDedupMoreBusy :: Bool
    , mDedupBusy :: Bool
    , mDedupMergeAllOpen :: Bool
    , mDedupMergeAllReport :: Maybe DedupMergeAllReport
    , -- tags / ai tags
      mConsol :: [ConsolidationGroup]
    , mConsolLoading :: Bool
    , mConsolError :: Maybe Text
    , mTagDialog :: Maybe TagDialog
    , mTagDialogInput :: Text
    , mTagDialogBusy :: Bool
    , mTagDialogError :: Maybe Text
    , mAiTag :: Maybe Text
    , mSuggestions :: [TagSuggestion]
    , mSuggestionsLoading :: Bool
    , mSuggestionNotice :: Maybe Text
    , mSuggestionError :: Maybe Text
    , -- extracted text editor
      mExtractEditing :: Bool
    , mExtractDraft :: Text
    , mExtractDirty :: Bool
    , mExtractSaving :: Bool
    , -- maintenance
      mPrune :: [BookmarkSummary]
    , mPruneSel :: [Int]
    , mDeadCount :: Maybe Int
    , mCheckedCount :: Maybe Int
    , mMaintBusy :: Bool
    , mConfirmPrune :: Bool
    , mPruneError :: Maybe Text
    , mUndoEntries :: [UndoEntry]
    , mUndoLoading :: Bool
    , mUndoError :: Maybe Text
    , mUndoPreview :: Maybe UndoPreview
    , mUndoPreviewLoading :: Bool
    , mUndoPreviewError :: Maybe Text
    , mUndoBusy :: Bool
    , -- account
      mAccount :: Maybe AccountInfo
    , mAccountLoading :: Bool
    , mAccountError :: Maybe Text
    , mRecoveryCodes :: [Text]
    , mCredEdit :: Maybe (Text, Text)
    , mTokens :: [TokenView]
    , mTokensLoading :: Bool
    , mTokensError :: Maybe Text
    , mWebhooks :: [Webhook]
    , mWebhooksLoading :: Bool
    , mWebhooksError :: Maybe Text
    , mWebhookName :: Text
    , mWebhookUrl :: Text
    , mWebhookEvents :: [EventType]
    , mWebhookEnabled :: Bool
    , mWebhookSecret :: Maybe Text
    , mWebhookFormError :: Maybe Text
    , mWebhookBusy :: Bool
    , mWebhookTest :: Maybe (Int, WebhookTest)
    , mWebhookTestError :: Maybe Text
    , mWebhookDeliveries :: Maybe (Int, [DeliveryView])
    , mWebhookDeliveriesError :: Maybe Text
    , mAdminUsers :: [UserView]
    , mAdminUsersAllowed :: Bool
    , mAdminUsersLoading :: Bool
    , mAdminUsersError :: Maybe Text
    , mUserName :: Text
    , mUserPassword :: Text
    , mUserRole :: UserRole
    , mUserFormError :: Maybe Text
    , mUserBusy :: Bool
    , mUserRecovery :: Maybe (Text, [Text])
    , mUserReset :: Maybe Int
    , mUserResetPassword :: Text
    , mUserResetShown :: Maybe (Text, Text)
    , mUserActionError :: Maybe Text
    , mUserDelete :: Maybe UserView
    , mUserDeleteName :: Text
    , mUserDeleteLibrary :: Bool
    , mUserDeleteBusy :: Bool
    , mTokenName :: Text
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
        , mListEpoch = RequestId 0
        , mVersion = "0.1.0"
        , mOrigin = ""
        , mWindowOrigin = ""
        , mOnline = True
        , mSignedOut = False
        , mBlockingError = Nothing
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
        , mDebounceTimer = Nothing
        , mTimerSeq = 0
        , mTags = []
        , mStats = Nothing
        , mStatsError = Nothing
        , mStatsEpoch = RequestId 0
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
        , mSelectEpoch = RequestId 0
        , mSelectListEpoch = RequestId 0
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
        , mDetailEpoch = RequestId 0
        , mReadRequest = RequestId 0
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
        , mGraphLayoutSource = ""
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
        , mGraphSettleEpoch = RequestId 0
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
