-- | Small shared view widgets: icons, buttons, chips, panels, empty states.
module Eza.Web.Widgets
  ( iSearch
  , iPlus
  , iSun
  , iMoon
  , iUser
  , iUpload
  , iDownload
  , iBack
  , iTrash
  , iExternal
  , iRefresh
  , iCheck
  , iGraph
  , iTag
  , iInbox
  , icon
  , btn
  , btnPrimary
  , btnGhost
  , btnSm
  , iconBtn
  , iconBtnDanger
  , tagChip
  , pill
  , statBox
  , panel
  , panelWithHead
  , emptyState
  , spinnerRow
  , bannerView
  , segBtn
  , formatCount
  , disabledAttr
  , checkedAttr
  ) where

import Data.Text (Text)
import Miso
import qualified Miso.Html as H
import qualified Miso.Html.Event as HE
import qualified Miso.Html.Property as HP
import qualified Miso.Svg as Svg
import qualified Miso.Svg.Property as SP

import Eza.Web.Model

-- ------------------------------------------------------------------ icons --

iSearch, iPlus, iSun, iMoon, iUser, iUpload, iDownload, iBack, iTrash, iExternal, iRefresh, iCheck, iGraph, iTag, iInbox :: MisoString
iSearch = "M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16zM21 21l-4.35-4.35"
iPlus = "M12 5v14M5 12h14"
iSun = "M12 17a5 5 0 1 0 0-10 5 5 0 0 0 0 10zM12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42"
iMoon = "M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"
iUser = "M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2M12 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8z"
iUpload = "M12 16V4M7 9l5-5 5 5M4 20h16"
iDownload = "M12 4v12M7 11l5 5 5-5M4 20h16"
iBack = "M19 12H5M12 19l-7-7 7-7"
iTrash = "M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"
iExternal = "M14 4h6v6M20 4l-9 9M19 14v6H4V5h6"
iRefresh = "M20 11a8 8 0 1 0-2 5.3M20 5v6h-6"
iCheck = "M20 6L9 17l-5-5"
iGraph = "M12 3a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM5 15a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM19 15a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM12 9v3M8 16l3-2M16 16l-3-2"
iTag = "M20.6 13.4 12 22l-9-9V4h9l8.6 8.6a1 1 0 0 1 0 1.4zM7.5 7.5h.01"
iInbox = "M4 13h4l2 3h4l2-3h4M5 5h14l2 8v6H3v-6l2-8z"

icon :: MisoString -> View () () Model Action
icon path =
  H.span_
    [HP.class_ "icon", HP.aria_ "hidden" "true"]
    [ Svg.svg_
        [ SP.viewBox_ "0 0 24 24"
        , HP.width_ "18"
        , HP.height_ "18"
        , SP.fill_ "none"
        , SP.stroke_ "currentColor"
        , SP.strokeWidth_ "1.8"
        , SP.strokeLinecap_ "round"
        , SP.strokeLinejoin_ "round"
        ]
        [Svg.path_ [SP.d_ path]]
    ]

-- ---------------------------------------------------------------- buttons --

btn :: MisoString -> [Attribute Model Action] -> [View () () Model Action] -> View () () Model Action
btn extraClass attrs children =
  H.button_ ([HP.class_ ("btn " <> extraClass), HP.type_ "button"] ++ attrs) children

btnPrimary :: MisoString -> Action -> View () () Model Action
btnPrimary label action = btn "btn-primary" [HE.onClick action] [text label]

btnGhost :: MisoString -> Action -> View () () Model Action
btnGhost label action = btn "btn-ghost" [HE.onClick action] [text label]

btnSm :: MisoString -> Action -> View () () Model Action
btnSm label action = btn "btn-sm" [HE.onClick action] [text label]

iconBtn :: MisoString -> MisoString -> Action -> View () () Model Action
iconBtn path title action =
  H.button_
    [HP.class_ "icon-btn", HP.type_ "button", HP.title_ title, HP.aria_ "label" title, HE.onClick action]
    [icon path]

iconBtnDanger :: MisoString -> MisoString -> Action -> View () () Model Action
iconBtnDanger path title action =
  H.button_
    [HP.class_ "icon-btn danger", HP.type_ "button", HP.title_ title, HP.aria_ "label" title, HE.onClick action]
    [icon path]

-- ------------------------------------------------------------------ chips --

tagChip :: Text -> View () () Model Action
tagChip tag = H.span_ [HP.class_ "tag-chip", HP.title_ (ms tag)] [text (ms tag)]

pill :: MisoString -> MisoString -> View () () Model Action
pill extraClass label =
  H.span_ [HP.class_ ("pill " <> extraClass)] [text label]

statBox :: MisoString -> MisoString -> View () () Model Action
statBox number label =
  H.div_ [HP.class_ "stat"]
    [ H.div_ [HP.class_ "stat-num"] [text number]
    , H.div_ [HP.class_ "stat-label"] [text label]
    ]

-- ----------------------------------------------------------------- panels --

panel :: MisoString -> [View () () Model Action] -> View () () Model Action
panel title body =
  H.section_ [HP.class_ "panel"]
    [ H.div_ [HP.class_ "panel-head"] [H.h2_ [HP.class_ "panel-title"] [text title]]
    , H.div_ [HP.class_ "panel-body"] body
    ]

panelWithHead :: MisoString -> [View () () Model Action] -> [View () () Model Action] -> View () () Model Action
panelWithHead title headActions body =
  H.section_ [HP.class_ "panel"]
    [ H.div_ [HP.class_ "panel-head"]
        [H.h2_ [HP.class_ "panel-title"] [text title], H.div_ [HP.class_ "panel-actions"] headActions]
    , H.div_ [HP.class_ "panel-body"] body
    ]

-- ------------------------------------------------------------ empty/load --

emptyState :: MisoString -> MisoString -> [View () () Model Action] -> View () () Model Action
emptyState emoji title actions =
  H.div_ [HP.class_ "empty"]
    ( [H.div_ [HP.class_ "empty-icon"] [text emoji], H.h2_ [] [text title]]
        ++ actions
    )

spinnerRow :: MisoString -> View () () Model Action
spinnerRow label =
  H.div_ [HP.class_ "loading-row", HP.aria_ "live" "polite"]
    [H.span_ [HP.class_ "spinner"] [], text label]

bannerView :: MisoString -> MisoString -> [View () () Model Action] -> View () () Model Action
bannerView extraClass message actions =
  H.div_ [HP.class_ ("banner " <> extraClass), HP.role_ "status"]
    (H.span_ [] [text message] : actions)

-- ------------------------------------------------------------- segmented --

segBtn :: Bool -> MisoString -> Action -> View () () Model Action
segBtn active label action =
  H.button_
    [HP.class_ (if active then "active" else ""), HP.type_ "button", HE.onClick action]
    [text label]

-- ---------------------------------------------------------------- format --

-- | Boolean attributes in Miso are plain 'Attribute' values; build the list
-- conditionally instead of applying them like a setter.
disabledAttr :: Bool -> [Attribute Model Action]
disabledAttr True = [HP.disabled_]
disabledAttr False = []

checkedAttr :: Bool -> [Attribute Model Action]
checkedAttr value = [HP.checked_ value]

formatCount :: Int -> MisoString
formatCount n
  | n >= 1000000 = ms (show (n `div` 100000)) <> "." <> ms (show ((n `div` 10000) `mod` 10)) <> "M"
  | n >= 1000 = ms (show (n `div` 1000)) <> "." <> ms (show ((n `div` 100) `mod` 10)) <> "k"
  | otherwise = ms (show n)
