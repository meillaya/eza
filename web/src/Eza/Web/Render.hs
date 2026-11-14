{- | The rendering boundary between the native model's 'Text' and Miso's
'MisoString' DOM type.

The pure model stores 'Text' and the view modules read it directly. Two
helpers keep the conversions in one place: 'txt' renders native text and
'toText' reads a DOM value, which "Eza.Web.Render.Event" uses to hand the
reducer native 'Text' for input events. Attribute values that are native text
are converted with 'ms' at the one call site.
-}
module Eza.Web.Render (
    txt,
    toText,
) where

import Data.Text (Text)
import Miso (MisoString, View, fromMisoString, ms, text)

-- | Render native text as a text node.
txt :: Text -> View context props model action
txt = text . ms

-- | The native text for a DOM/FFI value.
toText :: MisoString -> Text
toText = fromMisoString
