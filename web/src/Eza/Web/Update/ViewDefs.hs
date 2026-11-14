{-# LANGUAGE OverloadedStrings #-}

-- | Part of the client update function; see "Eza.Web.Update".
module Eza.Web.Update.ViewDefs (
    activeGraphDefinition,
    applyGraphView,
    currentGraphDefinition,
    currentLedgerDefinition,
    defaultGraphView,
    findViewBySlug,
    isLocalGraphRoute,
    isUserEnabled,
    recomputeGraphColors,
    removeAt,
    setAt,
    upsertUser,
    upsertView,
    upsertWebhook,
) where

import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Eza.Web.Logic.Route as ClientRoute

import Miso

import qualified Eza.GraphMatch as GM
import Eza.SearchQuery
import Eza.Types
import Eza.User
import qualified Eza.View as EV
import Eza.Web.Model
import Eza.Webhook

findViewBySlug :: Text -> [EV.View] -> Maybe EV.View
findViewBySlug slug views =
    case [view | view <- views, EV.vSlug view == slug] of
        (view : _) -> Just view
        [] -> Nothing

defaultGraphView :: [EV.View] -> Maybe EV.View
defaultGraphView views =
    case [view | view <- views, EV.vKind view == EV.GraphKind, EV.vIsDefault view] of
        (view : _) -> Just view
        [] -> case [view | view <- views, EV.vKind view == EV.GraphKind] of
            (view : _) -> Just view
            [] -> Nothing

{- | Apply a graph view definition to the graph state. Color maps are rebuilt
from the graph data by 'recomputeGraphColors'.
-}
applyGraphView :: EV.View -> Model -> Model
applyGraphView view m = case EV.vDefinition view of
    EV.GraphDefinition definition ->
        m
            { mGraphViewId = Just (EV.vId view)
            , mGraphViewRev = EV.vUpdatedAt view
            , mGraphFilter = ms (T.unpack (EV.gvdQuery definition))
            , mGraphTagsShown = EV.gvdTagsShown definition
            , mGraphLabelMode = EV.gvdLabelMode definition
            , mGraphPreset = EV.gvdLayoutPreset definition
            , mGraphLocal = isJust (EV.gvdLocalDepth definition)
            , mGraphLocalDepth = fromMaybe 1 (EV.gvdLocalDepth definition)
            , mGraphLocalRoot = Nothing
            , mGraphColorGroups = EV.gvdColorGroups definition
            , mGraphGroupDrafts = EV.gvdColorGroups definition
            , mGraphGroupDirty = False
            , mGraphGroupEditor = False
            }
    _ -> m

-- | The current graph state as a view definition, ready to PATCH or POST.
currentGraphDefinition :: Model -> EV.ViewDefinition
currentGraphDefinition m =
    EV.GraphDefinition
        EV.GraphViewDefinition
            { EV.gvdQuery = fromMisoString (mGraphFilter m)
            , EV.gvdTagsShown = mGraphTagsShown m
            , EV.gvdLabelMode = mGraphLabelMode m
            , EV.gvdLayoutPreset = mGraphPreset m
            , EV.gvdLocalDepth = if mGraphLocal m then Just (mGraphLocalDepth m) else Nothing
            , EV.gvdColorGroups = mGraphGroupDrafts m
            }

currentLedgerDefinition :: Model -> EV.ViewDefinition
currentLedgerDefinition m =
    EV.LedgerDefinition
        EV.LedgerViewDefinition
            { EV.lvdQuery = fromMisoString (mQ m)
            , EV.lvdSort = case mSort m of
                "added" -> EV.SortAdded
                "opened" -> EV.SortOpened
                _ -> EV.SortCreated
            }

-- | Build the record and tag color maps once per graph/view/groups change.
recomputeGraphColors :: Model -> Model
recomputeGraphColors m =
    case mGraph m of
        Nothing -> m{mGraphColors = Nothing, mGraphGroupCounts = []}
        Just graph ->
            let groups = mGraphGroupDrafts m
                assignment = GM.assignGroupColors groups graph
                countFor group
                    | not (EV.cgEnabled group) = 0
                    | otherwise =
                        length
                            [ ()
                            | record <- gdRecords graph
                            , GM.matchesQueryRecord (parseSearchQuery (EV.cgQuery group)) graph record
                            ]
             in m
                    { mGraphColors = Just assignment
                    , mGraphGroupCounts = map countFor groups
                    }

upsertView :: EV.View -> [EV.View] -> [EV.View]
upsertView view views =
    view : [existing | existing <- views, EV.vSlug existing /= EV.vSlug view]

{- | Open a saved view: graph views switch the graph route to the definition,
ledger views load the ledger with the saved query and sort.
-}
setAt :: Int -> (a -> a) -> [a] -> [a]
setAt index update list = [if position == index then update value else value | (position, value) <- zip [0 :: Int ..] list]

removeAt :: Int -> [a] -> [a]
removeAt index list = [value | (position, value) <- zip [0 :: Int ..] list, position /= index]

-- | The definition of the active saved graph view, when one is selected.
activeGraphDefinition :: Model -> Maybe EV.GraphViewDefinition
activeGraphDefinition m = do
    viewId <- mGraphViewId m
    view <- case [candidate | candidate <- mViews m, EV.vId candidate == viewId] of
        (candidate : _) -> Just candidate
        [] -> Nothing
    case EV.vDefinition view of
        EV.GraphDefinition definition -> Just definition
        _ -> Nothing

isLocalGraphRoute :: Route -> Bool
isLocalGraphRoute = ClientRoute.isLocalGraphRoute

isUserEnabled :: UserView -> Bool
isUserEnabled user = isNothing (uvDisabledAt user)

upsertUser :: UserView -> [UserView] -> [UserView]
upsertUser user users =
    user : [existing | existing <- users, uvId existing /= uvId user]

upsertWebhook :: Webhook -> [Webhook] -> [Webhook]
upsertWebhook webhook webhooks =
    webhook : [existing | existing <- webhooks, whId existing /= whId webhook]

{- | Do two layouts paint the same pixels? Compare the source maps and the
derived primitives; the generation is deliberately excluded.
-}
