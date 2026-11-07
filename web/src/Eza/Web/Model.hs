-- | Client model, route type, and the action vocabulary.
module Eza.Web.Model (
    Route (..),
    Theme (..),
    NoteMode (..),
    ToastKind (..),
    Toast (..),
    Model (..),
    Action (..),
    initialModel,
    routeOfUri,
    routeTitle,
    routeSubtitle,
    rowHeight,
    colCount,
    gridRows,
    visibleRows,
    formatStamp,
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
    GraphData,
    ImportReport,
    SavedSearch,
    SearchPage,
    TagStat,
 )
import Miso
import Miso.Router (Router (..), RoutingError (..), Token (..), parseURI, routes, toCapture, toPath, toQueryParam)
import Miso.Subscription.History (getURI)

import Eza.Web.Types (AccountInfo, ApiError, ConsolGroup, DedupGroup, TagSuggestion, TokenView)

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
        Save title text url ->
            [toPath "save"]
                ++ concat
                    [ [toQueryParam "title" value]
                    | Just value <- [title]
                    ]
                ++ concat
                    [ [toQueryParam "text" value]
                    | Just value <- [text]
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
splitPath = filter (not . null) . go
  where
    go s = case break (== '/') s of
        (a, []) -> [a]
        (a, _ : rest) -> a : go rest

{- | Decode a URL query value (@%XX@ escapes and @+@ as space, UTF-8 aware).
miso's URI lexer keeps query values percent-encoded, and the PWA
share_target passes title/url through the query string.
-}
percentDecode :: Text -> Text
percentDecode raw =
    case decodeUtf8' (BS.pack (map fromIntegral (go (T.unpack raw)))) of
        Right text -> text
        Left _ -> raw
  where
    go [] = []
    go ('%' : a : b : rest)
        | Just hi <- hexValue a
        , Just lo <- hexValue b =
            hi * 16 + lo : go rest
    go ('+' : rest) = 32 : go rest
    go (c : rest) = utf8 (fromEnum c) ++ go rest

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
    AiTags -> "Advisory tag suggestions — nothing is written without you."
    Maintenance -> "Dead-link sweeps, prune candidates, and undo."
    Account -> "Passkeys, recovery codes, and session controls."
    Save _ _ _ -> "Saving a shared link to your library."
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

data ToastKind = ToastInfo | ToastOk | ToastError
    deriving (Eq, Show)

data Toast = Toast
    { toastId :: Int
    , toastMessage :: MisoString
    , toastKind :: ToastKind
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
    | GlobalKey KeyInfo
    | KeyHandled KeyInfo Bool
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
    | -- library
      SearchInput MisoString
    | SearchCommit
    | DebouncedSearch
    | TimerRegistered Int
    | TagToggled Text
    | ClearFilters
    | SortSelected Text
    | UnreadToggled
    | ListLoaded Bool SearchPage
    | ListFailed Bool ApiError
    | LoadMore
    | MarkAllAbove
    | SavedSearchApply SavedSearch
    | ExportClicked
    | -- add modal
      AddOpen
    | AddClose
    | AddUrlInput MisoString
    | AddTitleInput MisoString
    | AddTagsInput MisoString
    | AddSubmit
    | AddSucceeded Int
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
      DetailLoaded BookmarkDetail
    | DetailFailed ApiError
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
    | OpenToggled
    | BacklinksLoaded [Backlink]
    | BacklinksFailed ApiError
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
    | -- dedup
      DedupLoaded [DedupGroup]
    | DedupFailed ApiError
    | DedupKeep Int Int
    | DedupMerge Int
    | DedupMerged Int
    | -- tags
      TagStatsLoaded [TagStat]
    | ConsolLoaded [ConsolGroup]
    | ConsolFailed ApiError
    | TagMerge [Text] Text
    | TagMerged
    | FilterByTag Text
    | TagRenamed Text MisoString
    | TagDeleted Text
    | TagOpFailed ApiError
    | -- AI tags
      AiTagSelected (Maybe Text)
    | SuggestionsLoaded [TagSuggestion]
    | SuggestionsFailed ApiError
    | SuggestionApply Int [Text]
    | SuggestionsApplied
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
    | -- toasts
      ToastAdd MisoString ToastKind
    | ToastDismiss Int

-- | Everything the UI needs to render itself.
data Model = Model
    { -- routing / shell
      mRoute :: Route
    , mTheme :: Theme
    , mBooted :: Bool
    , mVersion :: MisoString
    , mOrigin :: MisoString
    , mWindowOrigin :: MisoString
    , mOnline :: Bool
    , mSignedOut :: Bool
    , -- layout / virtualization
      mWidth :: Int
    , mHeight :: Int
    , mScrollY :: Int
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
    , mSaved :: [SavedSearch]
    , mSavedName :: MisoString
    , -- selection / bulk
      mSelection :: IS.IntSet
    , mSelectAnchor :: Maybe Int
    , mSelectingAll :: Bool
    , mSelectFetched :: Int
    , mBulkBusy :: Bool
    , mTagPrompt :: Maybe Bool
    , mTagPromptValue :: MisoString
    , mConfirmBulkDelete :: Bool
    , -- add modal
      mAddOpen :: Bool
    , mAddUrl :: MisoString
    , mAddTitle :: MisoString
    , mAddTags :: MisoString
    , mAddBusy :: Bool
    , mAddError :: Maybe MisoString
    , -- palette
      mPaletteOpen :: Bool
    , mPaletteQ :: MisoString
    , mPaletteSel :: Int
    , -- detail
      mDetail :: Maybe BookmarkDetail
    , mDetailLoading :: Bool
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
    , mSaving :: Bool
    , mDirty :: Bool
    , mGuardOpen :: Bool
    , mPendingRoute :: Maybe Route
    , -- graph
      mGraph :: Maybe GraphData
    , mGraphLoading :: Bool
    , mGraphDepth :: Int
    , mGraphZoom :: Int
    , mGraphSeed :: Maybe Int
    , mGraphQuery :: MisoString
    , mGraphResults :: [BookmarkSummary]
    , -- dedup
      mDedup :: [DedupGroup]
    , mDedupLoading :: Bool
    , mDedupChoice :: M.Map Int Int
    , -- tags / ai tags
      mConsol :: [ConsolGroup]
    , mConsolLoading :: Bool
    , mAiTag :: Maybe Text
    , mSuggestions :: [TagSuggestion]
    , mSuggestionsLoading :: Bool
    , -- maintenance
      mPrune :: [BookmarkSummary]
    , mPruneSel :: [Int]
    , mDeadCount :: Maybe Int
    , mCheckedCount :: Maybe Int
    , mMaintBusy :: Bool
    , mConfirmPrune :: Bool
    , -- account
      mAccount :: Maybe AccountInfo
    , mAccountLoading :: Bool
    , mRecoveryCodes :: [Text]
    , mCredEdit :: Maybe (Text, MisoString)
    , mTokens :: [TokenView]
    , mTokensLoading :: Bool
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
        , mVersion = "0.1.0"
        , mOrigin = ""
        , mWindowOrigin = ""
        , mOnline = True
        , mSignedOut = False
        , mWidth = 1200
        , mHeight = 900
        , mScrollY = 0
        , mGridTop = 240
        , mQ = ""
        , mTagsFilter = []
        , mSort = "created"
        , mUnreadOnly = False
        , mItems = []
        , mTotal = 0
        , mHasMore = False
        , mOffset = 0
        , mLoading = False
        , mLoadingMore = False
        , mError = Nothing
        , mNotice = Nothing
        , mDebounce = Nothing
        , mTags = []
        , mSaved = []
        , mSavedName = ""
        , mSelection = IS.empty
        , mSelectAnchor = Nothing
        , mSelectingAll = False
        , mSelectFetched = 0
        , mBulkBusy = False
        , mTagPrompt = Nothing
        , mTagPromptValue = ""
        , mConfirmBulkDelete = False
        , mAddOpen = False
        , mAddUrl = ""
        , mAddTitle = ""
        , mAddTags = ""
        , mAddBusy = False
        , mAddError = Nothing
        , mPaletteOpen = False
        , mPaletteQ = ""
        , mPaletteSel = 0
        , mDetail = Nothing
        , mDetailLoading = False
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
        , mSaving = False
        , mDirty = False
        , mGuardOpen = False
        , mPendingRoute = Nothing
        , mGraph = Nothing
        , mGraphLoading = False
        , mGraphDepth = 1
        , mGraphZoom = 100
        , mGraphSeed = Nothing
        , mGraphQuery = ""
        , mGraphResults = []
        , mDedup = []
        , mDedupLoading = False
        , mDedupChoice = M.empty
        , mConsol = []
        , mConsolLoading = False
        , mAiTag = Nothing
        , mSuggestions = []
        , mSuggestionsLoading = False
        , mPrune = []
        , mPruneSel = []
        , mDeadCount = Nothing
        , mCheckedCount = Nothing
        , mMaintBusy = False
        , mConfirmPrune = False
        , mAccount = Nothing
        , mAccountLoading = False
        , mRecoveryCodes = []
        , mCredEdit = Nothing
        , mTokens = []
        , mTokensLoading = False
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
rowHeight :: Int -> Int
rowHeight w
    | w < 768 = 152
    | otherwise = 136

colCount :: Int -> Int
colCount w
    | w >= 1200 = 3
    | w >= 768 = 2
    | otherwise = 1

gridRows :: Model -> Int
gridRows m =
    let n = length (mItems m)
        c = colCount (mWidth m)
     in (n + c - 1) `div` c

-- | First and (exclusive) last row to render, with +/- oversized overscan.
visibleRows :: Model -> (Int, Int)
visibleRows m =
    let rh = rowHeight (mWidth m)
        -- rows scrolled into / past the viewport
        rel = max 0 (mScrollY m - mGridTop m)
        first = max 0 (rel `div` rh - 3)
        viewRows = (mHeight m + rh - 1) `div` rh + 1
     in (first, first + viewRows + 6)

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
paletteEntries m = filter matches (commands ++ bookmarks)
  where
    needle = T.toLower (T.strip (toTextLow (mPaletteQ m)))
    matches (label, hint, _) =
        T.null needle
            || needle `T.isInfixOf` T.toLower (toTextLow label <> " " <> toTextLow hint)

    commands =
        [ ("Add bookmark", "POST", AddOpen)
        , ("Toggle theme", "appearance", ThemeToggled)
        , ("Library", "all bookmarks", Navigate Index)
        , ("Inbox", "unread", Navigate Inbox)
        , ("Graph", "neighbourhood", Navigate Graph)
        , ("Duplicates", "dedup", Navigate Dedup)
        , ("Tags", "consolidate", Navigate Tags)
        , ("AI tags", "suggestions", Navigate AiTags)
        , ("Maintenance", "dead links + prune", Navigate Maintenance)
        , ("Account", "passkeys", Navigate Account)
        , ("Import bookmarks", "Netscape HTML", ImportStart)
        , ("Export bookmarks", "Netscape HTML", ExportClicked)
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
