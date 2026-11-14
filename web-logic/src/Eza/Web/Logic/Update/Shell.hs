{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Part of the client update function; see "Eza.Web.Update".
module Eza.Web.Logic.Update.Shell (
    activateRow,
    choosePalette,
    closeTopLayer,
    handle,
    hasModalLayer,
    openCursorRecord,
) where

import Control.Monad
import qualified Data.IntSet as IS
import Data.Maybe
import qualified Data.Text as T

import Eza.Boot
import Eza.Types
import Eza.Web.Logic.Browser
import Eza.Web.Logic.Error
import Eza.Web.Logic.Model
import Eza.Web.Logic.Requests
import Eza.Web.Logic.Route (Route (..), isGraphRoute)
import Eza.Web.Logic.Update.Common
import Eza.Web.Logic.Update.Graph (graphEscape, graphOpenSelected, graphPan)
import qualified Eza.Web.Logic.Update.Job as Job
import Eza.Web.Logic.Update.Monad (Update, dispatch, get, put)
import Eza.Web.Logic.Update.Route (loadRoute, reloadRoute)
import Eza.Web.Logic.Update.ViewDefs (applyGraphView, defaultGraphView, isLocalGraphRoute)

hasModalLayer :: Model -> Bool
hasModalLayer m =
    mPaletteOpen m
        || mAddOpen m
        || mGuardOpen m
        || mConfirmLogout m
        || mSnapshotOpen m
        || mShareDialogOpen m
        || isJust (mTagDialog m)
        || isJust (mDedupConfirm m)
        || mDedupMergeAllOpen m
        || isJust (mSavedShare m)
        || isJust (mTagPrompt m)
        || mConfirmBulkDelete m
        || isJust (mConfirmDelete m)
        || mHighlightNoteOpen m
        || isJust (mHighlightEdit m)
        || vuSaveOpen (mViewUi m)
        || vuImportOpen (mViewUi m)
        || isJust (vuExport (mViewUi m))
        || mUndoPreviewLoading m
        || isJust (mUndoPreview m)
        || isJust (mUndoPreviewError m)

closeTopLayer :: Model -> Update ()
closeTopLayer m
    | mUndoPreviewLoading m || isJust (mUndoPreview m) || isJust (mUndoPreviewError m) = dispatch UndoPreviewClose
    | vuSaveOpen (mViewUi m) = putModel (\x -> x{gViews = (gViews x){vwViewUi = (mViewUi x){vuSaveOpen = False, vuError = Nothing}}})
    | vuImportOpen (mViewUi m) = putModel (\x -> x{gViews = (gViews x){vwViewUi = (mViewUi x){vuImportOpen = False, vuError = Nothing}}})
    | isJust (vuExport (mViewUi m)) = putModel (\x -> x{gViews = (gViews x){vwViewUi = (mViewUi x){vuExport = Nothing}}})
    | mConfirmLogout m = putModel (\x -> x{gShell = (gShell x){sfConfirmLogout = False}})
    | mHighlightNoteOpen m = putModel (\x -> x{gDetail = (gDetail x){dtHighlightNoteOpen = False, dtHighlightNote = ""}})
    | isJust (mHighlightEdit m) = putModel (\x -> x{gDetail = (gDetail x){dtHighlightEdit = Nothing, dtHighlightEditNote = ""}})
    | mShareDialogOpen m = putModel (\x -> x{gShares = (gShares x){srShareDialogOpen = False, srShareUrl = Nothing}})
    | isJust (mSavedShare m) = putModel (\x -> x{gLedger = (gLedger x){lfSavedShare = Nothing}, gShares = (gShares x){srShareUrl = Nothing}})
    | isJust (mTagDialog m) = putModel (\x -> x{gTags = (gTags x){tgTagDialog = Nothing, tgTagDialogError = Nothing}})
    | isJust (mDedupConfirm m) = putModel (\x -> x{gDedup = (gDedup x){ddDedupConfirm = Nothing}})
    | mDedupMergeAllOpen m = putModel (\x -> x{gDedup = (gDedup x){ddDedupMergeAllOpen = False}})
    | mSnapshotOpen m = putModel (\x -> x{gDetail = (gDetail x){dtSnapshotOpen = False}})
    | isJust (mReaderSel m) = putModel (\x -> x{gDetail = (gDetail x){dtReaderSel = Nothing}})
    | mPaletteOpen m = putModel (\x -> x{gShell = (gShell x){sfPaletteOpen = False, sfPaletteQ = "", sfPaletteSel = 0}})
    | mAddOpen m = putModel (\x -> x{gAdd = (gAdd x){adAddOpen = False}})
    | mGuardOpen m = dispatch DirtyGuardClose
    | isJust (mTagPrompt m) = putModel (\x -> x{gLedger = (gLedger x){lfTagPrompt = Nothing, lfTagPromptValue = ""}})
    | mConfirmBulkDelete m = putModel (\x -> x{gLedger = (gLedger x){lfConfirmBulkDelete = False}})
    | isJust (mLinkQuery m) = putModel (\x -> x{gDetail = (gDetail x){dtLinkQuery = Nothing, dtLinkResults = []}})
    | isJust (mDrawer m) = putModel (\x -> x{gLedger = (gLedger x){lfDrawer = Nothing}})
    | isJust (mConfirmDelete m) = putModel (\x -> x{gLedger = (gLedger x){lfConfirmDelete = Nothing}})
    | not (IS.null (mSelection m)) = putModel (\x -> (cancelSelectAllPaging x){gLedger = (gLedger (cancelSelectAllPaging x)){lfSelection = IS.empty, lfSelectAnchor = Nothing}})
    | mSelectingAll m = putModel cancelSelectAllPaging
    | otherwise = pure ()

choosePalette :: Int -> Update ()
choosePalette offsetFromSelection = do
    m <- get
    let entries = paletteEntries m
        selection = max 0 (mPaletteSel m + offsetFromSelection)
    case drop selection entries of
        ((_, _, nextAction) : _) -> do
            putModel (\x -> x{gShell = (gShell x){sfPaletteOpen = False, sfPaletteQ = "", sfPaletteSel = 0}})
            dispatch nextAction
        [] -> pure ()

openCursorRecord :: Model -> Update ()
openCursorRecord m =
    case itemAt (mItems m) (fromMaybe 0 (mLedgerCursor m)) of
        Nothing -> pure ()
        Just b -> dispatch (Navigate (Bookmark (bsId b)))

-- \| Open the row the keyboard is on: it becomes the cursor row first, so
-- returning from the record lands on what the reader activated.

activateRow :: Int -> Update ()
activateRow bookmarkId = do
    m <- get
    case indexOfBookmark (mItems m) bookmarkId of
        Just idx -> putModel (\x -> x{gLedger = (gLedger x){lfLedgerCursor = Just idx}})
        Nothing -> pure ()
    dispatch (Navigate (Bookmark bookmarkId))

-- \| The index of a bookmark in the loaded ledger.

handle :: Action -> Update ()
handle = \case
    Mounted -> do
        putModel (\m -> m{gShell = (gShell m){sfBooted = True}})
        fetchBoot BootLoaded BootFailed
        bootstrapEnvironment
    -- The share-target landing page is a real page now: it renders the
    -- prefilled save form instead of quietly writing a bookmark.
    RouteChanged fragmentText route -> do
        m <- get
        -- The fragment is applied in the same update as the route, so it
        -- cannot land after a tab click and undo it.
        when (route == Account) $
            putModel (\x -> x{gAccount = (gAccount x){acAccountTab = accountTabFromSlug fragmentText}})
        if hasUnsaved m && route /= mRoute m && isDetailRoute (mRoute m)
            then
                -- The browser already changed the address before the
                -- subscription delivered this route. Remember that so
                -- cancelling can put the address back and discarding
                -- can avoid a duplicate history entry.
                put m{gShell = (gShell m){sfGuardOpen = True, sfPendingRoute = Just route, sfGuardFromHistory = True}}
            else do
                -- A history navigation that lands on the rendered route
                -- (e.g. Forward while the guard is open) closes the guard
                -- instead of re-deriving it.
                putModel (\x -> x{gShell = (gShell x){sfGuardOpen = False, sfPendingRoute = Nothing, sfGuardFromHistory = False}})
                Job.cancelAllJobs
                loadRoute route
    Navigate route -> do
        m <- get
        if route == mRoute m
            then pure ()
            else
                if hasUnsaved m && isDetailRoute (mRoute m)
                    then put m{gShell = (gShell m){sfGuardOpen = True, sfPendingRoute = Just route, sfGuardFromHistory = False}}
                    else do
                        Job.cancelAllJobs
                        navigateTo route
    ThemeToggled -> toggleTheme
    ThemeLoaded theme -> putModel (\m -> m{gShell = (gShell m){sfTheme = theme}})
    ConnectivityChanged online -> putModel (\m -> m{gShell = (gShell m){sfOnline = online}})
    WindowOriginKnown origin -> putModel (\m -> m{gShell = (gShell m){sfWindowOrigin = origin}})
    QuickSaved bookmarkId existing -> do
        notify
            ( if existing
                then T.pack ("Already in your library (#" <> show bookmarkId <> ")")
                else "Saved to eza"
            )
            ToastOk
        reloadList
        refreshTags
        refreshStats
    QuickSaveFailed err -> handleApiError err
    CopyBookmarklet bookmarklet
        | T.null (T.strip bookmarklet) ->
            notify "Bookmarklet unavailable." ToastInfo
        | otherwise -> copyText bookmarklet "Bookmarklet copied" "Copy failed. Drag the link instead"
    LayoutChanged width height -> do
        putModel (\m -> m{gShell = (gShell m){sfWidth = width, sfHeight = height}})
        measureLedgerScroll
    Resized -> do
        refreshLayout
        m <- get
        when (isGraphRoute (mRoute m)) (measureGraphCanvas)
    Scrolled -> measureLedgerScroll
    ScrollMetrics Nothing -> pure ()
    ScrollMetrics (Just (scrollY, height, gridTop)) -> do
        -- While a return-to-position is still loading pages, the browser fires
        -- scroll events as the container remounts and clamps the saved offset.
        -- Those are not the reader scrolling, so they must not cancel the
        -- restore; only a scroll after the restore has applied may clear it.
        previous <- get
        let restoring = isJust (mScrollRestore previous)
        putModel
            ( \m ->
                m{gShell = (gShell m){sfScrollY = scrollY, sfHeight = height, sfGridTop = gridTop, sfScrollRestore = if restoring then mScrollRestore m else Nothing}}
            )
        m <- get
        let content = gridTop + ledgerContentHeight m
        when
            (mHasMore m && not (mLoading m) && not (mLoadingMore m) && scrollY + height + 600 >= content)
            loadMore
    KeyPressed key -> do
        m <- get
        let withModifier = keCtrl key || keMeta key
            editable = keEditable key
            plain = not withModifier && not (keAlt key)
            ledger = isListRoute (mRoute m)
            -- A dialog owns the keyboard: no page shortcut below runs while a
            -- modal layer is open, so Enter on a dialog button cannot also
            -- open the record behind it.
            modal = hasModalLayer m
            graphKeys = isGraphRoute (mRoute m) && not editable && plain && not modal
            runAction action = dispatch action
        -- event.key is upper case for a shifted letter; the shortcut names
        -- below are the unshifted ones.
        case T.toLower (keKey key) of
            -- Escape closes the top layer from any focus, including a field.
            -- On the graph it clears the filter line first, then the selection.
            "escape"
                | isGraphRoute (mRoute m) && not modal -> graphEscape m
                | otherwise -> closeTopLayer m
            -- The palette keeps the keys that drive its own list while it is
            -- the top layer.
            "enter" | mPaletteOpen m -> runAction PaletteSelect
            "arrowup" | mPaletteOpen m -> runAction PalettePrev
            "arrowdown" | mPaletteOpen m -> runAction PaletteNext
            -- The command palette is reachable from every screen: the command
            -- mods always, Shift+K outside fields, and a bare k off the ledger
            -- (so the hint on the search line is not the only way in).
            "k" | not modal && withModifier -> runAction PaletteOpen
            "k" | not modal && not editable && keShift key -> runAction PaletteOpen
            "k" | not modal && not editable && plain && ledger -> moveCursor (-1)
            "k" | not modal && not editable && plain -> runAction PaletteOpen
            "j" | not modal && not editable && plain && ledger -> moveCursor 1
            -- The search line: focus it from any screen, but never steal a
            -- slash the user is typing into a field.
            "/" | not modal && not editable -> do
                runAction PaletteClose
                focusElement "search-input"
            -- Enter opens the focused row when the keyboard bridge reports
            -- one; otherwise it falls back to the cursor row.
            "enter" | not modal && not editable && ledger ->
                case keRow key of
                    Just bookmarkId -> activateRow bookmarkId
                    Nothing -> openCursorRecord m
            -- The graph keys live on the global bridge so the canvas never
            -- scrolls the panel while panning; pwa.js cancels the browser
            -- default for arrows and zoom keys on the graph canvas.
            "arrowup" | graphKeys -> graphPan 0 (-1) (keShift key)
            "arrowdown" | graphKeys -> graphPan 0 1 (keShift key)
            "arrowleft" | graphKeys -> graphPan (-1) 0 (keShift key)
            "arrowright" | graphKeys -> graphPan 1 0 (keShift key)
            "+" | graphKeys -> runAction GraphZoomIn
            "=" | graphKeys -> runAction GraphZoomIn
            "-" | graphKeys -> runAction GraphZoomOut
            "_" | graphKeys -> runAction GraphZoomOut
            "0" | graphKeys -> runAction GraphFit
            "f" | graphKeys -> runAction GraphFit
            "enter" | graphKeys -> graphOpenSelected m
            "s" | not modal && withModifier && isDetailRoute (mRoute m) -> runAction SaveBookmark
            _ -> pure ()
    Noop -> pure ()
    -- boot ------------------------------------------------------------------
    -- A boot document built against another wire contract must not be painted:
    -- the payload could be read field-for-field into stale state. Block the
    -- whole interface instead and ask for a reload.
    BootLoaded payload
        | not (bootWireVersionSupported payload) ->
            dispatch (WireVersionMismatch (bpWireVersion payload))
    BootLoaded payload -> do
        putModel
            ( \m ->
                m{gShell = (gShell m){sfVersion = (bpVersion payload), sfOrigin = (bpOrigin payload), sfBootReady = True}, gLedger = (gLedger m){lfTags = bpTags payload, lfStats = Just (bpStats payload), lfSaved = bpSavedSearches payload}, gViews = (gViews m){vwViews = bpViews payload}}
            )
        -- A cold load of /graph?focus=..&local=1 must keep the URL's scope:
        -- the route already applied local mode, so the default whole-library
        -- view must not overwrite it. A plain /graph load still gets it.
        m0 <- get
        unless (isLocalGraphRoute (mRoute m0)) $
            case defaultGraphView (bpViews payload) of
                Just view -> putModel (applyGraphView view)
                Nothing -> pure ()
        m1 <- get
        -- The boot payload can apply a default graph view after the cold
        -- /graph route has already asked for the standard layout. Ask for the
        -- current preset's layout as well; otherwise the preset is selected
        -- but the plate stays on the previous layout.
        when (isGraphRoute (mRoute m1)) $
            when (fmap fst (mGraphLayoutWire m1) /= Just (mGraphPreset m1)) $
                fetchGraphLayout (mGraphPreset m1) (GraphLayoutLoaded (mGraphPreset m1)) GraphLayoutFailed
        m <- get
        let page = bpInitial payload
            deferred = mListDeferred m
            canSeed =
                bootPageMatchesLedger m
                    && (deferred || not (mRouted m))
        if canSeed
            then
                put
                    m
                        { gLedger = (gLedger m){lfItems = spItems page, lfTotal = spTotal page, lfYearHere = spYearCounts page, lfHasMore = spHasMore page, lfOffset = spOffset page + length (spItems page), lfLoading = False, lfLoadingMore = False, lfListDeferred = False, lfError = Nothing, lfSelection = IS.empty, lfSelectAnchor = Nothing, lfSelectingAll = False, lfConfirmMarkAll = False, lfLedgerCursor = Nothing}
                        , gShell =
                            (gShell m)
                                { -- A route loaded before the boot answer consumed the
                                  -- seed immediately; a route still to come consumes the
                                  -- flag in loadIndexList instead of refetching.
                                  sfBootSeeded = not deferred
                                }
                        }
            else when deferred $ do
                putModel (\x -> x{gLedger = (gLedger x){lfListDeferred = False}})
                when (isListRoute (mRoute m)) reloadList
    BootFailed err -> do
        m <- get
        let deferred = mListDeferred m
        putModel (\x -> x{gShell = (gShell x){sfBootReady = True}, gLedger = (gLedger x){lfListDeferred = False}})
        when (deferred && isListRoute (mRoute m)) reloadList
        handleApiError err
        when (aeStatus err == Just 401) $ redirect "/login"
    WireVersionMismatch serverVersion ->
        putModel
            ( \m ->
                m{gShell = (gShell m){sfBootReady = True, sfBlockingError = Just (wireVersionMismatchMessage serverVersion)}}
            )
    ApiUnauthorized -> putModel (\m -> m{gShell = (gShell m){sfSignedOut = True}})
    ApiErrorRaised err -> handleApiError err
    ReloadRoute -> reloadRoute
    LedgerCursorNext -> moveCursor 1
    LedgerCursorPrev -> moveCursor (-1)
    LedgerCursorSet idx -> setCursor idx
    DrawerOpen bid -> do
        m <- get
        let cursor = case indexOfBookmark (mItems m) bid of
                Just idx -> Just idx
                Nothing -> mLedgerCursor m
        putModel (\x -> x{gLedger = (gLedger x){lfDrawer = Just bid, lfLedgerCursor = cursor}})
    DrawerClose -> putModel (\m -> m{gLedger = (gLedger m){lfDrawer = Nothing}})
    PaletteOpen -> do
        putModel (\m -> m{gShell = (gShell m){sfPaletteOpen = True, sfPaletteQ = "", sfPaletteSel = 0}})
        focusElementDelayed "palette-input"
    PaletteClose -> putModel (\m -> m{gShell = (gShell m){sfPaletteOpen = False, sfPaletteQ = "", sfPaletteSel = 0}})
    PaletteInput query -> putModel (\m -> m{gShell = (gShell m){sfPaletteQ = query, sfPaletteSel = 0}})
    PalettePrev -> do
        m <- get
        let count = length (paletteEntries m)
        putModel (\x -> x{gShell = (gShell x){sfPaletteSel = if count == 0 then 0 else max 0 (mPaletteSel x - 1)}})
    PaletteNext -> do
        m <- get
        let count = length (paletteEntries m)
        putModel (\x -> x{gShell = (gShell x){sfPaletteSel = if count == 0 then 0 else min (count - 1) (mPaletteSel x + 1)}})
    PaletteSelect -> choosePalette 0
    PaletteChoose offsetFromSelection -> choosePalette offsetFromSelection
    -- detail ----------------------------------------------------------------
    ToastAdd message kind -> notify message kind
    ToastDismiss dismissed -> putModel (\m -> m{gShell = (gShell m){sfToasts = filter (\toast -> toastId toast /= dismissed) (mToasts m)}})
    _ -> pure ()
