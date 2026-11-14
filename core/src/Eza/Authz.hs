{- | The pure authorization matrix for the HTTP surface, derived from
"Eza.Routes".

As of M1 the route table is the single source of truth. "Eza.Routes" lists every
method/path pair, its authorization class, and what it needs (a capability);
this module re-exports those types and answers the questions the auth guard
asks. There is no second route-shaped pattern match here: an unknown path is
'DeniedClass', so a request outside the table is rejected instead of falling
through to an accidental allow. Dispatch still lives in "Eza.Server" until M4.

The rule is deny by default:

  * a known public ceremony, asset, or share route is 'PublicClass' or
    'ShareClass';
  * a route that must run on a browser session is 'SessionClass' (or
    'AdminClass' for user administration);
  * every other @/api/v1@ route is 'TokenClass' and accepts a bearer token or
    a normal session, subject to the token scope rules below;
  * anything else is 'DeniedClass' and must never reach a handler.
-}
module Eza.Authz (
    RouteClass (..),
    Capability (..),
    Scope (..),
    Role (..),
    routeClass,
    isPublicRoute,
    requiredCapability,
    tokenAllows,
    sessionRoleAllows,
    recoverySessionAllows,
    scopeFromText,
    scopeText,
) where

import Data.Text (Text)

import Eza.Routes (Capability (..), Role (..), RouteClass (..), Scope (..), scopeFromText, scopeText)
import qualified Eza.Routes as Routes

-- ---------------------------------------------------------------- routing ---

{- | Classify a method and split path. The result is deliberately total: an
unrecognised route is 'DeniedClass' rather than an accidental allow.
-}
routeClass :: Text -> [Text] -> RouteClass
routeClass method path = case Routes.matchRoute method path of
    Just route -> Routes.routeClass route
    Nothing -> DeniedClass

isPublicRoute :: Text -> [Text] -> Bool
isPublicRoute method path = routeClass method path == PublicClass

-- ----------------------------------------------------------- capabilities ---

{- | What a session/token route needs from its principal. Public, share and
denied routes need nothing from either.
-}
requiredCapability :: Text -> [Text] -> Maybe Capability
requiredCapability method path = Routes.matchRoute method path >>= Routes.routeCapability

-- ------------------------------------------------------------- token rules ---

{- | A bearer token may use a token route when its capability allows the
presented scopes. Capture routes are the special case: a capture token reaches
only the capture reads/writes, and ordinary tokens reach the capture writes
with @write@ and the capture reads with any of their scopes.
-}
tokenAllows :: [Scope] -> Text -> [Text] -> Bool
tokenAllows scopes method path = case Routes.matchRoute method path of
    Just route
        | Routes.routeClass route == TokenClass ->
            capabilityAllowsToken scopes (Routes.routeCapability route)
    _ -> False

capabilityAllowsToken :: [Scope] -> Maybe Capability -> Bool
capabilityAllowsToken scopes capability = case capability of
    Just CapCaptureWrite -> has ScopeCapture || has ScopeWrite
    Just CapCaptureRead -> has ScopeCapture || has ScopeWrite || has ScopeRead
    Just CapRead -> has ScopeRead || has ScopeWrite
    Just CapWrite -> has ScopeWrite
    Just CapSession -> False
    Just CapAdmin -> False
    Nothing -> False
  where
    has scope = scope `elem` scopes

-- ----------------------------------------------------------- session rules ---

{- | A normal browser session. The member role matches the old single-account
behaviour; admin routes need the admin role.
-}
sessionRoleAllows :: Role -> Text -> [Text] -> Bool
sessionRoleAllows role method path = case routeClass method path of
    AdminClass -> role == RoleAdmin
    SessionClass -> True
    TokenClass -> True
    PublicClass -> True
    ShareClass -> True
    DeniedClass -> False

{- | A recovery session: only finish the password setup, sign out, and read
the account/boot state that the recovery page needs.
-}
recoverySessionAllows :: Text -> [Text] -> Bool
recoverySessionAllows method path = case Routes.matchRoute method path of
    Just route -> route `elem` recoveryRoutes
    Nothing -> False
  where
    recoveryRoutes =
        [ Routes.RoutePasswordSetup
        , Routes.RouteLogout
        , Routes.RouteBoot
        , Routes.RouteAccountRead
        ]
