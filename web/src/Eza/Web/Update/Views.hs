{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Part of the client update function; see "Eza.Web.Update".
module Eza.Web.Update.Views (
    handle,
    openSavedView,
    openSavedViewNow,
    saveCurrentGraphView,
) where

import Control.Monad
import Data.Aeson
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Eza.Web.Logic.Effect (nextRequestId)

import Miso

import qualified Eza.View as EV
import Eza.Web.Api
import Eza.Web.Error
import Eza.Web.Interpreter
import Eza.Web.Logic.Model
import Eza.Web.Logic.Route (Route (..))
import {-# SOURCE #-} Eza.Web.Update (updateModel)
import Eza.Web.Update.Common (putModel)
import Eza.Web.Update.Graph (applyGraphScope, fitActiveView)
import Eza.Web.Update.ViewDefs (applyGraphView, currentGraphDefinition, currentLedgerDefinition, defaultGraphView, findViewBySlug, recomputeGraphColors, removeAt, setAt, upsertView)

openSavedView :: Text -> Effect () () Model Action
openSavedView slug = do
    m <- get
    case findViewBySlug slug (mViews m) of
        Just view -> openSavedViewNow view
        Nothing -> fetchView slug ViewFetched ViewFetchFailed

openSavedViewNow :: EV.View -> Effect () () Model Action
openSavedViewNow view = case EV.vDefinition view of
    EV.GraphDefinition definition -> do
        putModel (applyGraphView view)
        m <- get
        when (isJust (mGraphLayout m)) $
            updateModel (GraphPresetSelected (EV.gvdLayoutPreset definition))
        putModel recomputeGraphColors
        updateModel (Navigate Graph)
    EV.LedgerDefinition definition -> do
        putModel
            ( \x ->
                x
                    { mQ = EV.lvdQuery definition
                    , mSort = EV.ledgerSortText (EV.lvdSort definition)
                    , mTagsFilter = []
                    , mUnreadOnly = False
                    }
            )
        updateModel (Navigate Index)

-- | PATCH the active (or default) graph view with the current state.
saveCurrentGraphView :: Model -> Effect () () Model Action
saveCurrentGraphView m =
    case graphTarget of
        Nothing -> updateModel (ViewSaveOpen EV.GraphKind)
        Just view -> do
            putModel (\x -> x{mViewUi = (mViewUi x){vuBusy = True, vuError = Nothing}})
            patchView
                (EV.vSlug view)
                ( ViewPatch
                    Nothing
                    Nothing
                    (Just (currentGraphDefinition m))
                    (Just (EV.vIsDefault view))
                )
                ViewSaved
                ViewSaveFailed
  where
    graphTarget = case mGraphViewId m of
        Just viewId -> case [view | view <- mViews m, EV.vId view == viewId] of
            (view : _) -> Just view
            [] -> defaultGraphView (mViews m)
        Nothing -> defaultGraphView (mViews m)

handle :: Action -> Effect () () Model Action
handle = \case
    ViewsLoaded views -> do
        putModel (\x -> x{mViews = views, mViewsLoading = False, mViewsError = Nothing})
        m <- get
        when (mGraphViewId m == Nothing) $
            case defaultGraphView views of
                Just view -> putModel (applyGraphView view)
                Nothing -> pure ()
        putModel recomputeGraphColors
    ViewsFailed err ->
        putModel (\x -> x{mViewsLoading = False, mViewsError = Just ((aeMessage err))})
    ViewSaved view -> do
        notify "View saved" ToastOk
        putModel
            ( \x ->
                let ui = mViewUi x
                    isGraph = EV.vKind view == EV.GraphKind
                    viewsAfter = upsertView view (mViews x)
                    viewsFinal
                        | EV.vIsDefault view =
                            [ if EV.vKind candidate == EV.vKind view && EV.vSlug candidate /= EV.vSlug view
                                then candidate{EV.vIsDefault = False}
                                else candidate
                            | candidate <- viewsAfter
                            ]
                        | otherwise = viewsAfter
                 in x
                        { mViews = viewsFinal
                        , mViewsLoading = False
                        , mViewsError = Nothing
                        , mViewUi =
                            ui
                                { vuSaveOpen = False
                                , vuImportOpen = False
                                , vuImportText = ""
                                , vuBusy = False
                                , vuError = Nothing
                                }
                        , mGraphViewId = if isGraph then Just (EV.vId view) else mGraphViewId x
                        , mGraphViewRev = if isGraph then EV.vUpdatedAt view else mGraphViewRev x
                        , mGraphColorGroups = if isGraph then mGraphGroupDrafts x else mGraphColorGroups x
                        , mGraphGroupDirty = if isGraph then False else mGraphGroupDirty x
                        , mGraphGroupEditor = if isGraph then False else mGraphGroupEditor x
                        }
            )
        putModel recomputeGraphColors
    ViewSaveFailed err ->
        putModel
            ( \x ->
                let ui = mViewUi x
                 in x{mViewUi = ui{vuBusy = False, vuError = Just ((aeMessage err))}}
            )
    ViewDeleted slug -> do
        notify "View deleted" ToastOk
        -- The server promotes another view of the same kind to default in the
        -- same transaction; refetch so the manager shows the surviving default
        -- badge instead of none. If the deleted view was the active one, drop
        -- the id so the refetched default becomes active again.
        m <- get
        let deletedId = EV.vId <$> findViewBySlug slug (mViews m)
        putModel
            ( \x ->
                x
                    { mViews = [view | view <- mViews x, EV.vSlug view /= slug]
                    , mViewsLoading = True
                    , mGraphViewId =
                        case deletedId of
                            Just viewId | mGraphViewId x == Just viewId -> Nothing
                            _ -> mGraphViewId x
                    }
            )
        fetchViews ViewsLoaded ViewsFailed
    ViewDeleteFailed err ->
        putModel (\x -> x{mViewsError = Just ((aeMessage err))})
    ViewOpenView slug -> openSavedView slug
    ViewFetched view -> openSavedViewNow view
    ViewFetchFailed err ->
        putModel (\x -> x{mViewsError = Just ((aeMessage err))})
    ViewDefaultView slug -> do
        putModel (\x -> x{mViewUi = (mViewUi x){vuBusy = True, vuError = Nothing}})
        patchView slug (ViewPatch Nothing Nothing Nothing (Just True)) ViewSaved ViewSaveFailed
    ViewDeleteView slug -> deleteView slug (ViewDeleted slug) ViewDeleteFailed
    ViewExportView slug -> do
        m <- get
        case findViewBySlug slug (mViews m) of
            Just view ->
                putModel
                    ( \x ->
                        let ui = mViewUi x
                         in x{mViewUi = ui{vuExport = Just (TE.decodeUtf8 (BL.toStrict (encode view)))}}
                    )
            Nothing -> pure ()
    ViewExportClose ->
        putModel (\x -> x{mViewUi = (mViewUi x){vuExport = Nothing}})
    ViewRenameStart slug -> do
        m <- get
        case findViewBySlug slug (mViews m) of
            Just view ->
                putModel
                    ( \x ->
                        let ui = mViewUi x
                         in x{mViewUi = ui{vuRename = Just (EV.vSlug view, EV.vName view)}}
                    )
            Nothing -> pure ()
    ViewRenameInput name ->
        putModel
            ( \x ->
                let ui = mViewUi x
                 in x{mViewUi = ui{vuRename = fmap (\(slug, _) -> (slug, name)) (vuRename ui)}}
            )
    ViewRenameSubmit -> do
        m <- get
        case vuRename (mViewUi m) of
            Just (slug, name)
                | not (T.null (T.strip name)) -> do
                    putModel (\x -> x{mViewUi = (mViewUi x){vuBusy = True, vuError = Nothing}})
                    patchView slug (ViewPatch (Just (T.strip name)) Nothing Nothing Nothing) ViewSaved ViewSaveFailed
            _ -> pure ()
    ViewDuplicateView slug -> do
        m <- get
        case findViewBySlug slug (mViews m) of
            Just view -> do
                notify "Duplicating view" ToastInfo
                createView
                    ( EV.ViewInput
                        (EV.vName view <> " copy")
                        (EV.vKind view)
                        (EV.vDefinition view)
                        Nothing
                    )
                    ViewSaved
                    ViewSaveFailed
            Nothing -> pure ()
    ViewSaveOpen kind ->
        putModel
            ( \x ->
                let ui = mViewUi x
                 in x{mViewUi = ui{vuSaveOpen = True, vuSaveKind = kind, vuSaveName = "", vuError = Nothing, vuBusy = False}}
            )
    ViewSaveNameInput name ->
        putModel (\x -> x{mViewUi = (mViewUi x){vuSaveName = name}})
    ViewSaveKindSelected kind ->
        putModel (\x -> x{mViewUi = (mViewUi x){vuSaveKind = kind, vuError = Nothing}})
    ViewRenameCancel ->
        putModel (\x -> x{mViewUi = (mViewUi x){vuRename = Nothing}})
    ViewSaveSubmit -> do
        m <- get
        let ui = mViewUi m
            name = T.strip ((vuSaveName ui))
            definition = case vuSaveKind ui of
                EV.GraphKind -> currentGraphDefinition m
                EV.LedgerKind -> currentLedgerDefinition m
        if T.null name
            then putModel (\x -> x{mViewUi = (mViewUi x){vuError = Just "a name is required"}})
            else do
                putModel (\x -> x{mViewUi = (mViewUi x){vuBusy = True, vuError = Nothing}})
                createView (EV.ViewInput name (vuSaveKind ui) definition Nothing) ViewSaved ViewSaveFailed
    ViewSaveCancel ->
        putModel (\x -> x{mViewUi = (mViewUi x){vuSaveOpen = False, vuBusy = False, vuError = Nothing}})
    ViewImportOpen ->
        putModel (\x -> x{mViewUi = (mViewUi x){vuImportOpen = True, vuImportText = "", vuError = Nothing}})
    ViewImportTextInput rawText ->
        putModel (\x -> x{mViewUi = (mViewUi x){vuImportText = rawText}})
    ViewImportSubmit -> do
        m <- get
        let ui = mViewUi m
            raw = TE.encodeUtf8 (vuImportText ui)
        case Aeson.eitherDecodeStrict' raw :: Either String EV.ViewInput of
            Left message ->
                putModel (\x -> x{mViewUi = (mViewUi x){vuError = Just (T.pack message)}})
            Right input -> do
                putModel (\x -> x{mViewUi = (mViewUi x){vuBusy = True, vuError = Nothing}})
                createView input ViewSaved ViewSaveFailed
    ViewImportCancel ->
        putModel (\x -> x{mViewUi = (mViewUi x){vuImportOpen = False, vuError = Nothing}})
    ViewGroupEditorToggle ->
        putModel (\x -> x{mGraphGroupEditor = not (mGraphGroupEditor x)})
    ViewGroupAdd -> do
        m <- get
        when (length (mGraphGroupDrafts m) < EV.maxColorGroups) $ do
            let group = EV.ColorGroup "group" "" "#C98A3E" True
            putModel
                ( \x ->
                    x
                        { mGraphGroupDrafts = mGraphGroupDrafts x ++ [group]
                        , mGraphGroupDirty = True
                        }
                )
            putModel recomputeGraphColors
    ViewGroupRemove index -> do
        putModel (\x -> x{mGraphGroupDrafts = removeAt index (mGraphGroupDrafts x), mGraphGroupDirty = True, mGraphGroupEditor = True})
        putModel recomputeGraphColors
    ViewGroupField index field value -> do
        let valueText = value
            update group = case field of
                GroupName -> group{EV.cgName = valueText}
                GroupQuery -> group{EV.cgQuery = valueText}
                GroupColor -> group{EV.cgColor = valueText}
        putModel (\x -> x{mGraphGroupDrafts = setAt index update (mGraphGroupDrafts x), mGraphGroupDirty = True, mGraphGroupEditor = True})
        putModel recomputeGraphColors
    ViewGroupToggleEnabled index -> do
        putModel (\x -> x{mGraphGroupDrafts = setAt index (\group -> group{EV.cgEnabled = not (EV.cgEnabled group)}) (mGraphGroupDrafts x), mGraphGroupDirty = True, mGraphGroupEditor = True})
        putModel recomputeGraphColors
    ViewGroupsSave -> do
        m <- get
        saveCurrentGraphView m
    ViewGroupsCancel -> do
        putModel
            ( \x ->
                x
                    { mGraphGroupDrafts = mGraphColorGroups x
                    , mGraphGroupDirty = False
                    , mGraphGroupEditor = False
                    }
            )
        putModel recomputeGraphColors
    ViewSaveGraph -> do
        m <- get
        saveCurrentGraphView m
    GraphLabelModeSelected mode -> putModel (\m -> m{mGraphLabelMode = mode})
    GraphPresetSelected preset -> do
        m <- get
        putModel (\x -> x{mGraphPreset = preset, mGraphLoading = True, mGraphError = Nothing})
        case mGraph m of
            Nothing -> pure ()
            Just _ -> fetchGraphLayout preset (GraphLayoutLoaded preset) GraphLayoutFailed
    GraphScopeToggled -> do
        putModel
            ( \x ->
                x
                    { mGraphLocal = not (mGraphLocal x)
                    , mGraphHover = Nothing
                    , mGraphFocus = Nothing
                    , mGraphSettled = False
                    , mGraphSettleEpoch = nextRequestId (mGraphSettleEpoch x)
                    , mGraphDetailPhase = 0
                    }
            )
        putModel (\x -> fitActiveView (applyGraphScope x))
    GraphLocalDepthSelected depth -> do
        putModel
            ( \x ->
                x
                    { mGraphLocal = True
                    , mGraphLocalDepth = max 1 (min 3 depth)
                    , mGraphHover = Nothing
                    , mGraphSettled = False
                    , mGraphSettleEpoch = nextRequestId (mGraphSettleEpoch x)
                    , mGraphDetailPhase = 0
                    }
            )
        putModel (\x -> fitActiveView (applyGraphScope x))
    GraphLocalAt root depth -> do
        putModel
            ( \x ->
                x
                    { mGraphLocal = True
                    , mGraphLocalRoot = Just root
                    , mGraphLocalDepth = max 1 (min 3 depth)
                    , mGraphHover = Nothing
                    , mGraphSettled = False
                    , mGraphSettleEpoch = nextRequestId (mGraphSettleEpoch x)
                    , mGraphDetailPhase = 0
                    }
            )
        putModel (\x -> fitActiveView (applyGraphScope x))
        measureGraphCanvas GraphMeasured
    GraphSelect key ->
        putModel (\m -> m{mGraphSelected = Just key, mGraphFocus = Nothing})
    GraphClearSelection ->
        putModel (\m -> m{mGraphSelected = Nothing, mGraphFocus = Nothing})
    -- dedup ----------------------------------------------------------------
    _ -> pure ()
