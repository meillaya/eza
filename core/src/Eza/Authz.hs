{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The single, pure authorization matrix for the HTTP surface.
--
-- Today the route table in "Eza.Server" and the scope checks in "Eza.Tokens"
-- and "Eza.Auth" decide access with separate pattern matches. This module
-- mirrors those decisions in one place, so the matrix can be exercised
-- exhaustively in tests and later become the server's source of truth (M3).
--
-- The rule is deny by default:
--
--   * a known public ceremony, asset, or share route is 'PublicClass' or
--     'ShareClass';
--   * a route that must run on a browser session is 'SessionClass' (or
--     'AdminClass' for the planned user-administration routes);
--   * every other @/api/v1@ route is 'TokenClass' and accepts a bearer token
--     or a normal session, subject to the token scope rules below;
--   * an unknown method/path is 'DeniedClass' and must never reach a handler.
module Eza.Authz
    ( RouteClass (..)
    , Capability (..)
    , Scope (..)
    , Role (..)
    , routeClass
    , isPublicRoute
    , requiredCapability
    , tokenAllows
    , sessionRoleAllows
    , recoverySessionAllows
    , scopeFromText
    , scopeText
    ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | How a request reaches a handler.
data RouteClass
    = PublicClass
    | SessionClass
    | TokenClass
    | AdminClass
    | ShareClass
    | DeniedClass
    deriving (Show, Eq, Enum, Bounded)

-- | What a route needs, independent of who presents it.
data Capability
    = CapRead
    | CapWrite
    | CapCaptureRead
    | CapCaptureWrite
    | CapSession
    | CapAdmin
    deriving (Show, Eq, Enum, Bounded)

-- | API token scopes. The wire form is @read@, @write@, @capture@.
data Scope
    = ScopeRead
    | ScopeWrite
    | ScopeCapture
    deriving (Show, Eq, Enum, Bounded)

-- | Browser-session roles. The member role has every authorisation the old
-- single-account installation had; the admin role adds user administration.
data Role
    = RoleAdmin
    | RoleMember
    deriving (Show, Eq, Enum, Bounded)

-- ---------------------------------------------------------------- routing ---

-- | Classify a method and split path. The result is deliberately total: an
-- unrecognised route is 'DeniedClass' rather than an accidental allow.
routeClass :: Text -> [Text] -> RouteClass
routeClass method path
    | isPublicRoute method path = PublicClass
    | isShareRoute method path = ShareClass
    | isAdminRoute method path = AdminClass
    | isSessionRoute method path = SessionClass
    | isTokenRoute method path = TokenClass
    | otherwise = DeniedClass

isPublicRoute :: Text -> [Text] -> Bool
isPublicRoute method path = case (upper method, path) of
    ("GET", ["healthz"]) -> True
    ("GET", ["login"]) -> True
    ("GET", ["setup"]) -> True
    ("GET", ["recover"]) -> True
    ("GET", []) -> True
    ("GET", "assets" : _) -> True
    ("GET", ["favicon.svg"]) -> True
    ("GET", ["theme.js"]) -> True
    ("GET", ["manifest.webmanifest"]) -> True
    ("GET", ["sw.js"]) -> True
    ("POST", ["api", "auth", "login"]) -> True
    ("POST", ["api", "auth", "passkey", "options"]) -> True
    ("POST", ["api", "auth", "passkey", "verify"]) -> True
    ("POST", ["api", "auth", "options"]) -> True
    ("POST", ["api", "auth", "verify"]) -> True
    ("POST", ["api", "setup", "password"]) -> True
    ("POST", ["api", "setup", "options"]) -> True
    ("POST", ["api", "setup", "verify"]) -> True
    ("POST", ["api", "recovery", "redeem"]) -> True
    ("OPTIONS", "api" : "v1" : _) | isClipPath path -> True
    _ -> False

isShareRoute :: Text -> [Text] -> Bool
isShareRoute method path =
    upper method == "GET" && case path of
        ["s", _] -> True
        _ -> False

isAdminRoute :: Text -> [Text] -> Bool
isAdminRoute method path =
    upper method `elem` ["GET", "POST", "PATCH", "DELETE"]
        && case path of
            ("api" : "v1" : "admin" : _) -> True
            _ -> False

-- | Routes that only a browser session may use. Bearer tokens are rejected
-- even when they carry the @write@ scope.
isSessionRoute :: Text -> [Text] -> Bool
isSessionRoute method path =
    ( upper method `elem` ["GET", "POST", "PATCH", "DELETE"]
        && case path of
            ["save"] -> upper method == "GET"
            ["account"] -> True
            ["account", _] -> True
            ("api" : "v1" : "account" : _) -> True
            ("api" : "v1" : "tokens" : _) -> True
            ("api" : "v1" : "rules" : _) -> True
            ["api", "v1", "clip-templates"] -> upper method `elem` ["POST", "PATCH", "DELETE"]
            ["api", "v1", "clip-templates", _] -> upper method `elem` ["PATCH", "DELETE"]
            ("api" : "v1" : "webhooks" : _) -> True
            ["api", "auth", "logout"] -> True
            _ -> False
    )
        || ( upper method == "GET"
                && take 1 path /= ["api"]
                && "assets" `notElem` path
           )

-- | Every other authenticated JSON route. The current server's auth guard
-- rejects unknown @/api@ paths with 401 before they can 404, so treating the
-- whole namespace as token-or-session is consistent with the guard.
isTokenRoute :: Text -> [Text] -> Bool
isTokenRoute method path =
    upper method `elem` ["GET", "HEAD", "POST", "PATCH", "DELETE"]
        && case path of
            ("api" : "v1" : _) -> True
            _ -> False

isClipPath :: [Text] -> Bool
isClipPath path = case path of
    ["api", "v1", "clip"] -> True
    ["api", "v1", "clip", "preview"] -> True
    ["api", "v1", "quick-save"] -> True
    _ -> False

upper :: Text -> Text
upper = T.toUpper

-- ----------------------------------------------------------- capabilities ---

-- | What a session/token route needs from its principal. Public, share and
-- denied routes need nothing from either.
requiredCapability :: Text -> [Text] -> Maybe Capability
requiredCapability method path = case routeClass method path of
    SessionClass -> Just CapSession
    AdminClass -> Just CapAdmin
    TokenClass
        | isCaptureWrite method path -> Just CapCaptureWrite
        | isCaptureRead method path -> Just CapCaptureRead
        | upper method `elem` ["GET", "HEAD"] -> Just CapRead
        | otherwise -> Just CapWrite
    _ -> Nothing

-- ------------------------------------------------------------- token rules ---

-- | Mirror of "Eza.Tokens.tokenAllows": capture tokens reach the clip routes
-- and their reads; read/write tokens reach ordinary reads and writes; a
-- session-only or admin route never accepts a bearer token.
tokenAllows :: [Scope] -> Text -> [Text] -> Bool
tokenAllows scopes method path
    | routeClass method path /= TokenClass = False
    | isCaptureWrite method path = has ScopeCapture || has ScopeWrite
    | isCaptureRead method path = has ScopeCapture || has ScopeWrite || has ScopeRead
    | upper method `elem` ["GET", "HEAD"] = has ScopeRead || has ScopeWrite
    | otherwise = has ScopeWrite
  where
    has scope = scope `elem` scopes

isCaptureWrite :: Text -> [Text] -> Bool
isCaptureWrite method path =
    upper method == "POST"
        && path
            `elem` [ ["api", "v1", "quick-save"]
                   , ["api", "v1", "clip"]
                   , ["api", "v1", "clip", "preview"]
                   ]

isCaptureRead :: Text -> [Text] -> Bool
isCaptureRead method path =
    upper method `elem` ["GET", "HEAD"]
        && ( path == ["api", "v1", "whoami"]
                || prefix ["api", "v1", "clip-templates"] path
           )

prefix :: [Text] -> [Text] -> Bool
prefix pre candidate = take (length pre) candidate == pre

-- ----------------------------------------------------------- session rules ---

-- | A normal browser session. The member role matches the old single-account
-- behaviour; admin routes need the admin role.
sessionRoleAllows :: Role -> Text -> [Text] -> Bool
sessionRoleAllows role method path = case routeClass method path of
    AdminClass -> role == RoleAdmin
    SessionClass -> True
    TokenClass -> True
    PublicClass -> True
    ShareClass -> True
    DeniedClass -> False

-- | A recovery session: only finish the password setup, sign out, and read
-- the account/boot state that the recovery page needs.
recoverySessionAllows :: Text -> [Text] -> Bool
recoverySessionAllows method path = case (upper method, path) of
    ("POST", ["api", "setup", "password"]) -> True
    ("POST", ["api", "auth", "logout"]) -> True
    ("GET", ["api", "v1", "boot"]) -> True
    ("GET", ["api", "v1", "account"]) -> True
    _ -> False

-- ----------------------------------------------------------------- scopes ---

scopeFromText :: Text -> Maybe Scope
scopeFromText raw = case T.toLower (T.strip raw) of
    "read" -> Just ScopeRead
    "write" -> Just ScopeWrite
    "capture" -> Just ScopeCapture
    _ -> Nothing

scopeText :: Scope -> Text
scopeText = \case
    ScopeRead -> "read"
    ScopeWrite -> "write"
    ScopeCapture -> "capture"
