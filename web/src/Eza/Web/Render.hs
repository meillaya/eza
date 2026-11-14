{- | The rendering boundary between the native model's 'Text' and Miso's
'MisoString' DOM type.

The pure model stores 'Text'. Only the event attributes need the conversion
today: "Eza.Web.Render.Event" wraps the Miso events that carry a text payload
so the reducer receives native 'Text'. The view modules still read the
`MisoString` accessors on "Eza.Web.Model"; converting them to native accessors
and deleting that facade is the rest of M2-B2b.
-}
module Eza.Web.Render (toText) where

import Data.Text (Text)
import Miso (MisoString, fromMisoString)

-- | The native text for a DOM/FFI value.
toText :: MisoString -> Text
toText = fromMisoString
