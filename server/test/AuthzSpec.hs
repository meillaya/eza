{-# LANGUAGE OverloadedStrings #-}

{- | Exhaustive checks for the pure authorization matrix.

The documented route table is mirrored here as data. Every route in the
server's deny-by-default table must have an explicit classification, and the
scope/role rules must agree with the token and session semantics that M3 will
adopt from this module.
-}
module AuthzSpec (authzSpec) where

import Control.Monad (forM_)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec
import Test.QuickCheck

import Eza.Authz

{- | One representative request for every documented route. Dynamic segments
use a sample value; the classifications must not depend on the value.
-}
documentedRoutes :: [(Text, [Text])]
documentedRoutes =
    publicRoutes
        ++ shareRoutes
        ++ sessionRoutes
        ++ adminRoutes
        ++ tokenRoutes

publicRoutes :: [(Text, [Text])]
publicRoutes =
    [ ("GET", ["healthz"])
    , ("GET", ["login"])
    , ("GET", ["setup"])
    , ("GET", ["recover"])
    , ("GET", [])
    , ("GET", ["assets", "eza.css"])
    , ("GET", ["assets", "app", "app.wasm"])
    , ("GET", ["favicon.svg"])
    , ("GET", ["theme.js"])
    , ("GET", ["manifest.webmanifest"])
    , ("GET", ["sw.js"])
    , ("POST", ["api", "auth", "login"])
    , ("POST", ["api", "auth", "passkey", "options"])
    , ("POST", ["api", "auth", "passkey", "verify"])
    , ("POST", ["api", "auth", "options"])
    , ("POST", ["api", "auth", "verify"])
    , ("POST", ["api", "setup", "password"])
    , ("POST", ["api", "setup", "options"])
    , ("POST", ["api", "setup", "verify"])
    , ("POST", ["api", "recovery", "redeem"])
    , ("OPTIONS", ["api", "v1", "clip"])
    , ("OPTIONS", ["api", "v1", "clip", "preview"])
    , ("OPTIONS", ["api", "v1", "quick-save"])
    ]

shareRoutes :: [(Text, [Text])]
shareRoutes = [("GET", ["s", "token"])]

sessionRoutes :: [(Text, [Text])]
sessionRoutes =
    [ ("GET", ["save"])
    , ("GET", ["account"])
    , ("GET", ["account", "add-passkey"])
    , ("GET", ["api", "v1", "account"])
    , ("POST", ["api", "v1", "account", "2fa"])
    , ("POST", ["api", "v1", "account", "password"])
    , ("POST", ["api", "v1", "account", "username"])
    , ("POST", ["api", "v1", "account", "sessions", "revoke-others"])
    , ("POST", ["api", "v1", "account", "passkeys", "options"])
    , ("POST", ["api", "v1", "account", "passkeys", "verify"])
    , ("PATCH", ["api", "v1", "account", "passkeys", "cred"])
    , ("DELETE", ["api", "v1", "account", "passkeys", "cred"])
    , ("POST", ["api", "v1", "account", "recovery", "regenerate"])
    , ("GET", ["api", "v1", "tokens"])
    , ("POST", ["api", "v1", "tokens"])
    , ("DELETE", ["api", "v1", "tokens", "1"])
    , ("GET", ["api", "v1", "rules"])
    , ("POST", ["api", "v1", "rules"])
    , ("POST", ["api", "v1", "rules", "test"])
    , ("PATCH", ["api", "v1", "rules", "1"])
    , ("DELETE", ["api", "v1", "rules", "1"])
    , ("POST", ["api", "v1", "clip-templates"])
    , ("PATCH", ["api", "v1", "clip-templates", "1"])
    , ("DELETE", ["api", "v1", "clip-templates", "1"])
    , ("GET", ["api", "v1", "webhooks"])
    , ("POST", ["api", "v1", "webhooks"])
    , ("GET", ["api", "v1", "webhooks", "1"])
    , ("PATCH", ["api", "v1", "webhooks", "1"])
    , ("DELETE", ["api", "v1", "webhooks", "1"])
    , ("POST", ["api", "v1", "webhooks", "1", "test"])
    , ("GET", ["api", "v1", "webhooks", "1", "deliveries"])
    , ("POST", ["api", "auth", "logout"])
    , -- The authenticated SPA shell for every non-API page.
      ("GET", ["graph"])
    , ("GET", ["views", "wide"])
    , ("GET", ["bookmark", "1"])
    , ("GET", ["inbox"])
    , ("GET", ["tags", "ai"])
    , ("GET", ["accessions"])
    , ("GET", ["not", "an", "api", "route"])
    ]

adminRoutes :: [(Text, [Text])]
adminRoutes =
    [ ("GET", ["api", "v1", "admin", "users"])
    , ("POST", ["api", "v1", "admin", "users"])
    , ("PATCH", ["api", "v1", "admin", "users", "1"])
    , ("POST", ["api", "v1", "admin", "users", "1", "password"])
    ]

tokenRoutes :: [(Text, [Text])]
tokenRoutes =
    [ ("GET", ["api", "v1", "whoami"])
    , ("GET", ["api", "v1", "boot"])
    , ("GET", ["api", "v1", "bookmarks"])
    , ("POST", ["api", "v1", "bookmarks"])
    , ("POST", ["api", "v1", "bookmarks", "bulk"])
    , ("GET", ["api", "v1", "bookmarks", "1"])
    , ("PATCH", ["api", "v1", "bookmarks", "1"])
    , ("DELETE", ["api", "v1", "bookmarks", "1"])
    , ("GET", ["api", "v1", "bookmarks", "1", "highlights"])
    , ("POST", ["api", "v1", "bookmarks", "1", "highlights"])
    , ("PATCH", ["api", "v1", "bookmarks", "1", "highlights", "2"])
    , ("DELETE", ["api", "v1", "bookmarks", "1", "highlights", "2"])
    , ("GET", ["api", "v1", "bookmarks", "1", "backlinks"])
    , ("POST", ["api", "v1", "bookmarks", "1", "open"])
    , ("POST", ["api", "v1", "bookmarks", "1", "enrich"])
    , ("GET", ["api", "v1", "bookmarks", "1", "snapshot"])
    , ("POST", ["api", "v1", "bookmarks", "1", "snapshot"])
    , ("GET", ["api", "v1", "favicons", "example.com"])
    , ("POST", ["api", "v1", "quick-save"])
    , ("POST", ["api", "v1", "clip"])
    , ("POST", ["api", "v1", "clip", "preview"])
    , ("GET", ["api", "v1", "clip-templates"])
    , ("GET", ["api", "v1", "clip-templates", "1"])
    , ("GET", ["api", "v1", "tags"])
    , ("GET", ["api", "v1", "tags", "consolidation-candidates"])
    , ("GET", ["api", "v1", "tags", "rust", "suggestions"])
    , ("POST", ["api", "v1", "tags", "apply"])
    , ("POST", ["api", "v1", "tags", "merge"])
    , ("POST", ["api", "v1", "tags", "rust"])
    , ("DELETE", ["api", "v1", "tags", "rust"])
    , ("GET", ["api", "v1", "autocomplete"])
    , ("GET", ["api", "v1", "graph"])
    , ("GET", ["api", "v1", "graph", "layout"])
    , ("GET", ["api", "v1", "saved-searches"])
    , ("POST", ["api", "v1", "saved-searches"])
    , ("DELETE", ["api", "v1", "saved-searches", "1"])
    , ("GET", ["api", "v1", "share-links"])
    , ("POST", ["api", "v1", "share-links"])
    , ("DELETE", ["api", "v1", "share-links", "1"])
    , ("GET", ["api", "v1", "dedup", "candidates"])
    , ("POST", ["api", "v1", "dedup", "merge"])
    , ("POST", ["api", "v1", "dedup", "merge-all"])
    , ("POST", ["api", "v1", "inbox", "mark-all-above"])
    , ("POST", ["api", "v1", "maintenance", "check-dead"])
    , ("GET", ["api", "v1", "maintenance", "prune-candidates"])
    , ("POST", ["api", "v1", "maintenance", "prune"])
    , ("POST", ["api", "v1", "undo"])
    , ("POST", ["api", "v1", "import"])
    , ("POST", ["api", "v1", "import", "json"])
    , ("GET", ["api", "v1", "export"])
    , ("GET", ["api", "v1", "export", "notes"])
    , ("GET", ["api", "v1", "stats"])
    , ("GET", ["api", "v1", "ai", "status"])
    ]

authzSpec :: Spec
authzSpec = describe "Eza.Authz" $ do
    it "classifies every documented route and never falls through to denied" $
        forM_ documentedRoutes $ \(method, path) ->
            shouldSatisfyNamed (method, path) (routeClass method path) (/= DeniedClass)

    it "marks the known public ceremonies and assets public" $
        forM_ publicRoutes $ \(method, path) ->
            routeClass method path `shouldBe` PublicClass

    it "marks public share links as share routes" $
        forM_ shareRoutes $ \(method, path) ->
            routeClass method path `shouldBe` ShareClass

    it "keeps bearer tokens out of session-only routes" $
        forM_ sessionRoutes $ \(method, path) ->
            tokenAllows [ScopeRead, ScopeWrite, ScopeCapture] method path
                `shouldBe` False

    it "keeps bearer tokens out of admin routes" $
        forM_ adminRoutes $ \(method, path) ->
            tokenAllows [ScopeRead, ScopeWrite, ScopeCapture] method path
                `shouldBe` False

    it "allows only admin sessions on admin routes" $
        forM_ adminRoutes $ \(method, path) -> do
            sessionRoleAllows RoleAdmin method path `shouldBe` True
            sessionRoleAllows RoleMember method path `shouldBe` False

    it "lets a member session use every session and token route" $
        forM_ (sessionRoutes ++ tokenRoutes) $ \(method, path) ->
            shouldBeNamed (method, path) (sessionRoleAllows RoleMember method path) True

    it "lets read tokens read and write tokens read/write, on token routes only" $
        forM_ tokenRoutes $ \(method, path) -> do
            let isRead = T.toUpper method `elem` ["GET", "HEAD"]
                isCaptureWrite =
                    method == "POST"
                        && path
                            `elem` [ ["api", "v1", "quick-save"]
                                   , ["api", "v1", "clip"]
                                   , ["api", "v1", "clip", "preview"]
                                   ]
                isCaptureRead =
                    T.toUpper method `elem` ["GET", "HEAD"]
                        && ( path == ["api", "v1", "whoami"]
                                || take 3 path == ["api", "v1", "clip-templates"]
                           )
            tokenAllows [ScopeRead] method path `shouldBe` (isCaptureRead || (isRead && not isCaptureWrite))
            tokenAllows [ScopeWrite] method path `shouldBe` True
            tokenAllows [ScopeCapture] method path `shouldBe` (isCaptureWrite || isCaptureRead)

    it "limits a recovery session to the password setup and its account reads" $ do
        recoverySessionAllows "POST" ["api", "setup", "password"] `shouldBe` True
        recoverySessionAllows "POST" ["api", "auth", "logout"] `shouldBe` True
        recoverySessionAllows "GET" ["api", "v1", "boot"] `shouldBe` True
        recoverySessionAllows "GET" ["api", "v1", "account"] `shouldBe` True
        recoverySessionAllows "GET" ["api", "v1", "bookmarks"] `shouldBe` False
        recoverySessionAllows "POST" ["api", "v1", "bookmarks"] `shouldBe` False
        recoverySessionAllows "GET" ["api", "v1", "admin", "users"] `shouldBe` False

    it "denies unknown methods and paths for every principal" $ forAll arbitraryRequest $ \(method, path) ->
        let unknown = routeClass method path == DeniedClass
         in not unknown
                || ( not (tokenAllows [ScopeRead, ScopeWrite, ScopeCapture] method path)
                        && not (sessionRoleAllows RoleAdmin method path)
                        && not (sessionRoleAllows RoleMember method path)
                   )

    it "treats HEAD like GET for route classification" $ do
        routeClass "HEAD" ["api", "v1", "graph"] `shouldBe` TokenClass
        -- The server's health route is GET-only; a HEAD request falls through
        -- to the auth guard today, so the matrix must not call it public.
        routeClass "HEAD" ["healthz"] `shouldBe` DeniedClass

    it "classifies methods case-insensitively" $ do
        routeClass "get" ["api", "v1", "graph"] `shouldBe` TokenClass
        routeClass "Post" ["api", "v1", "bookmarks"] `shouldBe` TokenClass

shouldSatisfyNamed :: (Show a) => (Text, [Text]) -> a -> (a -> Bool) -> Expectation
shouldSatisfyNamed topic actual predicate
    | predicate actual = pure ()
    | otherwise = expectationFailure (show topic <> ": " <> show actual)

shouldBeNamed :: (Show a, Eq a) => (Text, [Text]) -> a -> a -> Expectation
shouldBeNamed topic actual expected
    | actual == expected = pure ()
    | otherwise = expectationFailure (show topic <> ": " <> show actual <> " /= " <> show expected)

arbitraryRequest :: Gen (Text, [Text])
arbitraryRequest = do
    method <- elements ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"]
    path <- do
        n <- choose (0, 4)
        vectorOf n (elements ["api", "v1", "bookmarks", "admin", "users", "graph", "x"])
    pure (method, path)
