{- | "Miso.Html.Event" with the text events handing the reducer native 'Text'
instead of a DOM 'Miso.MisoString'. Only the four text-carrying events are
overridden; the rest are re-exported unchanged.
-}
module Eza.Web.Render.Event (
    onClick,
    onClickPrevent,
    onClickWithOptions,
    onKeyDown,
    onMouseUp,
    onPointerDown,
    onPointerLeave,
    onPointerMove,
    onPointerUp,
    onSubmit,
    onInput,
    onChange,
    onInputWith,
    onChangeWith,
) where

import Data.Text (Text)
import Miso (Attribute, DOMRef)
import Miso.Html.Event (
    onClick,
    onClickPrevent,
    onClickWithOptions,
    onKeyDown,
    onMouseUp,
    onPointerDown,
    onPointerLeave,
    onPointerMove,
    onPointerUp,
    onSubmit,
 )
import qualified Miso.Html.Event as E

import Eza.Web.Render (toText)

onInput :: (Text -> action) -> Attribute model action
onInput f = E.onInput (f . toText)

onChange :: (Text -> action) -> Attribute model action
onChange f = E.onChange (f . toText)

onInputWith :: (Text -> DOMRef -> action) -> Attribute model action
onInputWith f = E.onInputWith (\value domRef -> f (toText value) domRef)

onChangeWith :: (Text -> DOMRef -> action) -> Attribute model action
onChangeWith f = E.onChangeWith (\value domRef -> f (toText value) domRef)
