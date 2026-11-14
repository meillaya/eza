{-# OPTIONS_GHC -Wno-orphans #-}

{- | The one Miso boundary the native client model still needs: the orphan
'Router' instance for the pure 'Route' type.

The router is not used to parse URLs (the client classifies them directly in
"Eza.Web.Logic.Route" and falls back to @NotFound@), but Miso's navigation
helpers and the generated links want a 'Router' instance. It lives here rather
than in @eza-web-logic@ because the native package must not import Miso; the
view modules read the native 'Text' model directly and need no other bridge.

'fromRoute' renders the same URL the native 'routeToUri' does; both are pinned
by the native route tests.
-}
module Eza.Web.Model () where

import Miso (fromMisoString, ms)
import Miso.Router (
    Router (..),
    Token (..),
    routes,
    toPath,
    toQueryParam,
 )

import Eza.Web.Logic.Route (Route (..))
import qualified Eza.Web.Logic.Route as ClientRoute

instance Router Route where
    fromRoute target =
        case ClientRoute.routeUriParts target of
            ([], query) -> IndexToken : queryTokens query
            (segments, query) -> map (toPath . ms) segments <> queryTokens query
      where
        queryTokens = map (\(key, value) -> toQueryParam (ms key) (ms value))
    toRoute input = Right (ClientRoute.routeOfUri (fromMisoString input))
    routeParser = routes []
