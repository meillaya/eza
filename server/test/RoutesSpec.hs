{-# LANGUAGE OverloadedStrings #-}

{- | Exhaustive checks for "Eza.Routes", the single route truth, and the
"Eza.Authz" matrix derived from it.

The table in "Eza.Routes" is the authority: these tests walk every enumerated
route, prove the docs template and the concrete renderer agree with the
matcher, and pin the class/capability and scope/role rules the server depended
on before M1. A route added without a class, a capability, or a re-parsable
path fails here.
-}
module RoutesSpec (spec) where

import Control.Monad (forM_)
import Data.List (nub, sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Eza.Authz
import qualified Eza.Authz as Authz
import Eza.Cli (CliCommand (..), parseCliArgs)
import Eza.Routes hiding (routeClass)
import qualified Eza.Routes as Routes

spec :: Spec
spec = describe "Eza.Routes" $ do
    it "renders and re-parses every route to itself" $
        forM_ allRoutes $ \route -> do
            let path = splitPath (renderRoutePath route)
            matchRoute (routeMethod route) path `shouldBe` Just route

    it "classifies every route through the same table the guard uses" $
        forM_ allRoutes $ \route -> do
            let path = splitPath (renderRoutePath route)
            Authz.routeClass (routeMethod route) path `shouldBe` Routes.routeClass route

    it "never classifies an enumerated route as denied" $
        forM_ allRoutes $ \route ->
            Routes.routeClass route `shouldSatisfy` (/= DeniedClass)

    it "covers every non-denied class and every docs label" $ do
        sortOn fromEnum (nub (map Routes.routeClass allRoutes))
            `shouldBe` [PublicClass, SessionClass, TokenClass, AdminClass, ShareClass]
        forM_ allRoutes $ \route -> do
            routeClassText (Routes.routeClass route) `shouldSatisfy` (not . T.null)
            capabilityText (routeCapability route) `shouldSatisfy` (not . T.null)

    it "has one unique method and docs path per route" $ do
        let keys = [(routeMethod route, routePath route) | route <- allRoutes]
        length (nub keys) `shouldBe` length keys

    it "renders the docs template for a parameterised route" $ do
        routePath (RouteBookmarkRead 7) `shouldBe` "/api/v1/bookmarks/{id}"
        routePath (RouteSharePage "u1_abc") `shouldBe` "/s/{token}"
        routePath (RouteStaticAsset ["eza.css"]) `shouldBe` "/assets/{path...}"
        routePath RouteSpaPage `shouldBe` "/{page...}"
        renderRoutePath (RouteBookmarkRead 7) `shouldBe` "/api/v1/bookmarks/7"
        renderRoutePath (RouteTagRename ["rust", "web"]) `shouldBe` "/api/v1/tags/rust/web"
        renderRoutePath (RouteShareFeed "u1_abc") `shouldBe` "/s/u1_abc.xml"

    it "matches concrete parameter values, not just the canonical samples" $ do
        matchRoute "GET" ["api", "v1", "bookmarks", "42"] `shouldBe` Just (RouteBookmarkRead 42)
        matchRoute "DELETE" ["api", "v1", "tags", "rust", "web"] `shouldBe` Just (RouteTagDelete ["rust", "web"])
        matchRoute "GET" ["s", "u1_abc.xml"] `shouldBe` Just (RouteShareFeed "u1_abc")
        matchRoute "GET" ["assets", "app", "app.wasm"] `shouldBe` Just (RouteStaticAsset ["app", "app.wasm"])
        matchRoute "GET" ["inbox"] `shouldBe` Just RouteSpaPage
        matchRoute "GET" ["api", "v1", "bookmarks", "nope"] `shouldBe` Nothing

    it "denies unknown routes and methods" $ do
        matchRoute "GET" ["api", "v1", "no-such-route"] `shouldBe` Nothing
        matchRoute "POST" ["api", "v1", "no-such-route"] `shouldBe` Nothing
        matchRoute "PUT" ["api", "v1", "bookmarks"] `shouldBe` Nothing
        matchRoute "GET" ["api", "v1", "admin", "no-such-route"] `shouldBe` Nothing
        Authz.routeClass "GET" ["api", "v1", "no-such-route"] `shouldBe` DeniedClass
        isPublicRoute "GET" ["api", "v1", "no-such-route"] `shouldBe` False
        -- The retired 0.2/0.3 passkey sign-in routes are not part of 0.4.
        matchRoute "POST" ["api", "auth", "options"] `shouldBe` Nothing
        matchRoute "POST" ["api", "auth", "verify"] `shouldBe` Nothing
        Authz.routeClass "POST" ["api", "auth", "options"] `shouldBe` DeniedClass

    it "keeps class and capability consistent" $
        forM_ allRoutes $ \route -> case Routes.routeClass route of
            PublicClass -> routeCapability route `shouldBe` Nothing
            ShareClass -> routeCapability route `shouldBe` Nothing
            SessionClass -> routeCapability route `shouldBe` Just CapSession
            AdminClass -> routeCapability route `shouldBe` Just CapAdmin
            TokenClass ->
                routeCapability route
                    `shouldSatisfy` maybe False (`elem` [CapRead, CapWrite, CapCaptureRead, CapCaptureWrite])
            DeniedClass -> expectationFailure ("enumerated route is denied: " <> show route)

    it "keeps bearer tokens out of public, share, session, and admin routes" $
        forM_ allRoutes $ \route -> do
            let path = splitPath (renderRoutePath route)
                allows = tokenAllows [ScopeRead, ScopeWrite, ScopeCapture] (routeMethod route) path
            allows `shouldBe` (Routes.routeClass route == TokenClass)

    it "applies the token scope matrix to every token route" $
        forM_ allRoutes $ \route -> do
            let path = splitPath (renderRoutePath route)
                method = routeMethod route
                isToken = Routes.routeClass route == TokenClass
                wants scope =
                    isToken && case routeCapability route of
                        Just CapCaptureWrite -> scope == ScopeCapture || scope == ScopeWrite
                        Just CapCaptureRead -> True
                        Just CapRead -> scope == ScopeRead || scope == ScopeWrite
                        Just CapWrite -> scope == ScopeWrite
                        _ -> False
            forM_ [ScopeRead, ScopeWrite, ScopeCapture] $ \scope ->
                tokenAllows [scope] method path `shouldBe` wants scope

    it "lets a member session use everything except admin routes" $
        forM_ allRoutes $ \route -> do
            let path = splitPath (renderRoutePath route)
                memberAllows = sessionRoleAllows RoleMember (routeMethod route) path
            memberAllows `shouldBe` (Routes.routeClass route /= AdminClass)

    it "lets an admin session use every route" $
        forM_ allRoutes $ \route -> do
            let path = splitPath (renderRoutePath route)
            sessionRoleAllows RoleAdmin (routeMethod route) path `shouldBe` True

    it "limits a recovery session to the password setup and its account reads" $ do
        recoverySessionAllows "POST" ["api", "setup", "password"] `shouldBe` True
        recoverySessionAllows "POST" ["api", "auth", "logout"] `shouldBe` True
        recoverySessionAllows "GET" ["api", "v1", "boot"] `shouldBe` True
        recoverySessionAllows "GET" ["api", "v1", "account"] `shouldBe` True
        recoverySessionAllows "GET" ["api", "v1", "bookmarks"] `shouldBe` False
        recoverySessionAllows "POST" ["api", "v1", "bookmarks"] `shouldBe` False
        recoverySessionAllows "GET" ["api", "v1", "admin", "users"] `shouldBe` False

    it "treats HEAD as a read alias for token routes only" $ do
        matchRoute "HEAD" ["api", "v1", "graph"] `shouldBe` Just RouteGraph
        Authz.routeClass "HEAD" ["api", "v1", "graph"] `shouldBe` TokenClass
        matchRoute "HEAD" ["api", "v1", "account"] `shouldBe` Nothing
        matchRoute "HEAD" ["healthz"] `shouldBe` Nothing
        matchRoute "get" ["api", "v1", "graph"] `shouldBe` Just RouteGraph

    it "represents every client URL literal family in web/src/Eza/Web/Api.hs" $
        forM_ clientRouteSamples $ \(method, path) ->
            Authz.routeClass method (splitPath path) `shouldSatisfy` (/= DeniedClass)

    it "exposes the routes command and its --markdown switch" $ do
        parseCliArgs ["routes", "--markdown"] `shouldBe` Right (RoutesCmd True)
        parseCliArgs ["routes"] `shouldBe` Right (RoutesCmd False)

    it "renders a stable markdown table in path-then-method order" $ do
        T.isPrefixOf "# HTTP routes\n" routesMarkdown `shouldBe` True
        T.isInfixOf "| Method | Path | Class | Capability |" routesMarkdown `shouldBe` True
        let order = [(path, method) | (method, path, _, _) <- routeTable]
        order `shouldBe` sortOn id order
        length routeTable `shouldBe` length allRoutes
        forM_ routeTable $ \(method, path, klass, capability) ->
            T.isInfixOf
                ("| " <> method <> " | `" <> path <> "` | " <> routeClassText klass <> " | " <> capabilityText capability <> " |")
                routesMarkdown
                `shouldBe` True
        -- The header row and one row per route start with "| "; the
        -- separator row starts with "|---".
        let tableLines = filter (T.isPrefixOf "| ") (T.lines routesMarkdown)
        length tableLines `shouldBe` length routeTable + 1

{- | Split a rendered path the way WAI splits @pathInfo@; a trailing or leading
slash is not a segment.
-}
splitPath :: Text -> [Text]
splitPath = filter (not . T.null) . T.splitOn "/"

{- | One request per client URL literal in @web/src/Eza/Web/Api.hs@ (query
strings dropped). The client can replace every literal with a route once it
adopts the table.
-}
clientRouteSamples :: [(Text, Text)]
clientRouteSamples =
    [ ("GET", "/api/v1/bookmarks")
    , ("GET", "/api/v1/bookmarks/1")
    , ("GET", "/api/v1/bookmarks/1/backlinks")
    , ("GET", "/api/v1/bookmarks/1/highlights")
    , ("GET", "/api/v1/boot")
    , ("GET", "/api/v1/autocomplete")
    , ("GET", "/api/v1/graph")
    , ("GET", "/api/v1/graph/layout")
    , ("GET", "/api/v1/views")
    , ("GET", "/api/v1/views/example")
    , ("GET", "/api/v1/webhooks")
    , ("GET", "/api/v1/webhooks/1")
    , ("GET", "/api/v1/webhooks/1/deliveries")
    , ("GET", "/api/v1/admin/users")
    , ("GET", "/api/v1/saved-searches")
    , ("GET", "/api/v1/dedup/candidates")
    , ("GET", "/api/v1/tags/consolidation-candidates")
    , ("POST", "/api/v1/ai/suggestions")
    , ("GET", "/api/v1/jobs/1")
    , ("GET", "/api/v1/maintenance/prune-candidates")
    , ("GET", "/api/v1/account")
    , ("GET", "/api/v1/tags")
    , ("GET", "/api/v1/stats")
    , ("GET", "/api/v1/undo")
    , ("GET", "/api/v1/undo/1")
    , ("GET", "/api/v1/tokens")
    , ("GET", "/api/v1/share-links")
    , ("GET", "/api/v1/ai/status")
    , ("GET", "/api/v1/rules")
    , ("GET", "/api/v1/export")
    , ("GET", "/api/v1/export/notes")
    , ("POST", "/api/v1/views")
    , ("POST", "/api/v1/webhooks")
    , ("POST", "/api/v1/webhooks/1/test")
    , ("POST", "/api/v1/admin/users")
    , ("POST", "/api/v1/admin/users/1/password")
    , ("POST", "/api/v1/bookmarks")
    , ("POST", "/api/v1/bookmarks/bulk")
    , ("POST", "/api/v1/bookmarks/1/highlights")
    , ("POST", "/api/v1/bookmarks/1/open")
    , ("POST", "/api/v1/bookmarks/1/enrich")
    , ("POST", "/api/v1/bookmarks/1/extract")
    , ("POST", "/api/v1/bookmarks/1/snapshot")
    , ("POST", "/api/v1/bookmarks/1/mark-alive")
    , ("POST", "/api/v1/bookmarks/1/recheck-link")
    , ("POST", "/api/v1/quick-save")
    , ("POST", "/api/v1/inbox/mark-all-above")
    , ("POST", "/api/v1/saved-searches")
    , ("POST", "/api/v1/dedup/merge")
    , ("POST", "/api/v1/dedup/merge-all")
    , ("POST", "/api/v1/tags/merge")
    , ("POST", "/api/v1/tags/apply")
    , ("POST", "/api/v1/tags/example")
    , ("POST", "/api/v1/maintenance/prune")
    , ("POST", "/api/v1/maintenance/check-dead")
    , ("POST", "/api/v1/undo")
    , ("POST", "/api/v1/import")
    , ("POST", "/api/v1/tokens")
    , ("POST", "/api/v1/share-links")
    , ("POST", "/api/v1/rules")
    , ("POST", "/api/v1/rules/test")
    , ("POST", "/api/v1/account/recovery/regenerate")
    , ("POST", "/api/v1/account/username")
    , ("POST", "/api/v1/account/password")
    , ("POST", "/api/v1/account/2fa")
    , ("POST", "/api/v1/account/sessions/revoke-others")
    , ("POST", "/api/auth/logout")
    , ("PATCH", "/api/v1/views/example")
    , ("PATCH", "/api/v1/webhooks/1")
    , ("PATCH", "/api/v1/admin/users/1")
    , ("PATCH", "/api/v1/bookmarks/1")
    , ("PATCH", "/api/v1/bookmarks/1/highlights/2")
    , ("PATCH", "/api/v1/account/passkeys/credential")
    , ("PATCH", "/api/v1/rules/1")
    , ("DELETE", "/api/v1/views/example")
    , ("DELETE", "/api/v1/webhooks/1")
    , ("DELETE", "/api/v1/admin/users/1")
    , ("DELETE", "/api/v1/bookmarks/1")
    , ("DELETE", "/api/v1/bookmarks/1/highlights/2")
    , ("DELETE", "/api/v1/account/passkeys/credential")
    , ("DELETE", "/api/v1/tags/example")
    , ("DELETE", "/api/v1/saved-searches/1")
    , ("DELETE", "/api/v1/tokens/1")
    , ("DELETE", "/api/v1/share-links/1")
    , ("DELETE", "/api/v1/rules/1")
    ]
