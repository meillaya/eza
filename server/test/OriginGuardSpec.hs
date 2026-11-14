{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Regression tests for the server auth, egress, body-limit, and public-route
fixes:

  * #6 the Origin and Sec-Fetch-Site denial paths on the public auth POSTs,
  * #34 the JSON import body uses EZA_IMPORT_MAX_BYTES rather than
    EZA_MAX_BODY_BYTES,
  * #39 the global and per-client login limiters stop rotated usernames and
    the limiter bucket map is bounded,
  * #40 publicV6 rejects the IPv4-embedding and tunnelling prefixes,
  * #42 HEAD and OPTIONS on the public surface answer instead of redirecting,
  * #43 EZA_TRUSTED_PROXIES makes X-Forwarded-For name the limiter client.

The asset tests supply a temporary EZA_STATIC_DIR; the rest run the real Warp
application from 'TestHarness'.
-}
module OriginGuardSpec (spec) where

import Control.Exception (bracket)
import Control.Monad (void)
import Data.Aeson (Value (..), encode, object, (.=))
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word32, Word8)
import Network.Socket (SockAddr (..), tupleToHostAddress)
import Network.Wai (defaultRequest, remoteHost, requestHeaders)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import qualified Eza.Auth as Auth
import Eza.Config (Config (..), isTrustedProxy, loadTrustedProxies, parseTrustedProxies, sockAddrKey)
import qualified Eza.Control as Control
import Eza.Fetch (publicV6)
import Eza.Server (clientHostKey)
import TestHarness

spec :: Spec
spec = describe "server auth/egress/route fixes" $ do
    originGuardSpec
    publicMethodSpec
    jsonImportLimitSpec
    loginLimiterSpec
    ipv6GuardSpec
    trustedProxySpec

-- ---------------------------------------------------------------------------
-- #6: Origin / Sec-Fetch-Site denial paths
-- ---------------------------------------------------------------------------

originGuardSpec :: Spec
originGuardSpec = describe "#6 public auth origin guard" $ do
    it "rejects a disallowed Origin on login with the origin error code" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            response <-
                httpRequest
                    server
                    "POST"
                    "/api/auth/login"
                    (("Origin", "http://evil.example") : jsonHeaders)
                    (Just (loginDocument "alice" "alice password"))
            response `shouldHaveStatus` 403
            errorCode response `shouldBe` Just "origin"

    it "allows an allowed Origin and a request without browser headers on login" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            allowed <-
                httpRequest
                    server
                    "POST"
                    "/api/auth/login"
                    (("Origin", "http://localhost:8080") : jsonHeaders)
                    (Just (loginDocument "alice" "alice password"))
            allowed `shouldHaveStatus` 200
            noHeaders <-
                httpRequest
                    server
                    "POST"
                    "/api/auth/login"
                    jsonHeaders
                    (Just (loginDocument "alice" "wrong password 1"))
            noHeaders `shouldHaveStatus` 401
            errorCode noHeaders `shouldBe` Just "invalid_credentials"

    it "rejects Sec-Fetch-Site: cross-site without Origin on login" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            response <-
                httpRequest
                    server
                    "POST"
                    "/api/auth/login"
                    (("Sec-Fetch-Site", "cross-site") : jsonHeaders)
                    (Just (loginDocument "alice" "alice password"))
            response `shouldHaveStatus` 403
            errorCode response `shouldBe` Just "origin"

    it "guards password setup on a fresh install" $
        withTestServer $ \server -> do
            rejected <-
                httpRequest
                    server
                    "POST"
                    "/api/setup/password"
                    (("Origin", "http://evil.example") : jsonHeaders)
                    (Just (setupDocument "owner" "a fresh setup password"))
            rejected `shouldHaveStatus` 403
            errorCode rejected `shouldBe` Just "origin"
            crossSite <-
                httpRequest
                    server
                    "POST"
                    "/api/setup/password"
                    (("Sec-Fetch-Site", "cross-site") : jsonHeaders)
                    (Just (setupDocument "owner" "a fresh setup password"))
            crossSite `shouldHaveStatus` 403
            errorCode crossSite `shouldBe` Just "origin"

    it "allows password setup without browser headers on a fresh install" $
        withTestServer $ \server -> do
            accepted <-
                httpRequest
                    server
                    "POST"
                    "/api/setup/password"
                    jsonHeaders
                    (Just (setupDocument "owner" "a fresh setup password"))
            accepted `shouldHaveStatus` 200

    it "guards recovery redemption" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            let body = Just (encode (object ["username" .= ("alice" :: Text), "code" .= ("aaaa-bbbb" :: Text)]))
            rejected <-
                httpRequest
                    server
                    "POST"
                    "/api/recovery/redeem"
                    (("Origin", "http://evil.example") : jsonHeaders)
                    body
            rejected `shouldHaveStatus` 403
            errorCode rejected `shouldBe` Just "origin"
            crossSite <-
                httpRequest
                    server
                    "POST"
                    "/api/recovery/redeem"
                    (("Sec-Fetch-Site", "cross-site") : jsonHeaders)
                    body
            crossSite `shouldHaveStatus` 403
            errorCode crossSite `shouldBe` Just "origin"
            -- The bad code is reached only after the origin guard passes.
            badCode <- httpRequest server "POST" "/api/recovery/redeem" jsonHeaders body
            badCode `shouldHaveStatus` 400
            errorCode badCode `shouldBe` Just "bad_code"

    it "guards the passkey second-factor options" $
        withTestServer $ \server -> do
            rejected <-
                httpRequest
                    server
                    "POST"
                    "/api/auth/passkey/options"
                    (("Origin", "http://evil.example") : jsonHeaders)
                    Nothing
            rejected `shouldHaveStatus` 403
            errorCode rejected `shouldBe` Just "origin"
            allowed <- httpRequest server "POST" "/api/auth/passkey/options" jsonHeaders Nothing
            allowed `shouldHaveStatus` 401
            errorCode allowed `shouldBe` Just "pending_required"

loginDocument :: Text -> Text -> LBS.ByteString
loginDocument username password =
    encode (object ["username" .= username, "password" .= password])

setupDocument :: Text -> Text -> LBS.ByteString
setupDocument username password =
    encode
        ( object
            [ "username" .= username
            , "password" .= password
            , "confirm" .= password
            ]
        )

-- | The JSON @error.code@ of a response, if it has one.
errorCode :: HttpResponse -> Maybe Text
errorCode response = case jsonBody response :: Maybe Value of
    Just (Object top) -> case KeyMap.lookup "error" top of
        Just (Object err) -> case KeyMap.lookup "code" err of
            Just (String code) -> Just code
            _ -> Nothing
        _ -> Nothing
    _ -> Nothing

-- ---------------------------------------------------------------------------
-- #42: HEAD and OPTIONS on the public surface
-- ---------------------------------------------------------------------------

{- | A server whose static root holds one real asset, so the asset routes have
a file to serve.
-}
withStaticServer :: (TestServer -> IO a) -> IO a
withStaticServer action =
    withSystemTempDirectory "eza-origin-static" $ \dir -> do
        let root = dir </> "static"
        -- The server validates a content-addressed bundle at startup; the
        -- fixture writes the same shape scripts/bundle-web.sh emits.
        writeTestStaticBundle root
        withTestServerCustom (\cfg -> cfg{cfgStaticDir = Just root}) (\_ -> pure ()) action

publicMethodSpec :: Spec
publicMethodSpec = describe "#42 HEAD and OPTIONS on public routes" $ do
    it "answers HEAD on the public health and asset routes with the GET headers" $
        withStaticServer $ \server -> do
            getHealth <- httpRequest server "GET" "/healthz" [] Nothing
            getHealth `shouldHaveStatus` 200
            headHealth <- httpRequest server "HEAD" "/healthz" [] Nothing
            headHealth `shouldHaveStatus` 200
            hrespBody headHealth `shouldBe` ""
            headerValue headHealth "Content-Type" `shouldBe` headerValue getHealth "Content-Type"

            getAsset <- httpRequest server "GET" (T.unpack testBundleCssPath) [] Nothing
            getAsset `shouldHaveStatus` 200
            hrespBody getAsset `shouldSatisfy` containsText "/* eza test asset */"
            headAsset <- httpRequest server "HEAD" (T.unpack testBundleCssPath) [] Nothing
            headAsset `shouldHaveStatus` 200
            hrespBody headAsset `shouldBe` ""
            headerValue headAsset "Content-Type" `shouldBe` headerValue getAsset "Content-Type"
            headerValue headAsset "Content-Length" `shouldBe` headerValue getAsset "Content-Length"

    it "answers OPTIONS on the public routes with the allowed methods" $
        withStaticServer $ \server -> do
            let check path allow = do
                    response <- httpRequest server "OPTIONS" path [] Nothing
                    response `shouldHaveStatus` 204
                    headerValue response "Allow" `shouldBe` Just allow
            check "/healthz" "GET, HEAD, OPTIONS"
            check "/assets/eza.css" "GET, HEAD, OPTIONS"
            check "/login" "GET, HEAD, OPTIONS"
            check "/api/auth/login" "POST, OPTIONS"

-- ---------------------------------------------------------------------------
-- #34: JSON import body limit
-- ---------------------------------------------------------------------------

withImportServer :: (TestServer -> IO a) -> IO a
withImportServer =
    withTestServerCustom
        (\cfg -> cfg{cfgMaxBodyBytes = 1024, cfgImportMaxBytes = 8192})
        (\_ -> pure ())

jsonImportLimitSpec :: Spec
jsonImportLimitSpec = describe "#34 JSON import uses the import body cap" $ do
    it "imports a JSON body above EZA_MAX_BODY_BYTES on both JSON routes" $
        withImportServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            let document = bigJsonExport "eza-big-json-import" 1800
                body = Just (LBS.fromStrict (TE.encodeUtf8 document))
            direct <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/import"
                    (authHeaders session csrf)
                    body
            direct `shouldHaveStatus` 200
            hrespBody direct `shouldSatisfy` containsText "json_report"
            explicit <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/import/json"
                    (authHeaders session csrf)
                    (Just (LBS.fromStrict (TE.encodeUtf8 (bigJsonExport "eza-big-json-explicit" 1800))))
            explicit `shouldHaveStatus` 200
            -- The explicit import route answers with the bare report.
            hrespBody explicit `shouldSatisfy` containsText "bookmarks"

    it "answers an import body above EZA_IMPORT_MAX_BYTES with 413 naming that limit" $
        withImportServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            (session, csrf) <- loginAs server "alice" "alice password"
            response <-
                httpRequest
                    server
                    "POST"
                    "/api/v1/import"
                    (authHeaders session csrf)
                    (Just (LBS.fromStrict (TE.encodeUtf8 (bigJsonExport "eza-too-big" 9000))))
            response `shouldHaveStatus` 413
            hrespBody response `shouldSatisfy` containsText "payload_too_large"
            hrespBody response `shouldSatisfy` containsText "8192"

-- | A valid eza JSON export with a padded title, so the size is controllable.
bigJsonExport :: Text -> Int -> Text
bigJsonExport url padding =
    "{\"format\":\"eza-json\",\"version\":2,\"bookmarks\":[{\"url\":\"https://example.test/"
        <> url
        <> "\",\"title\":\""
        <> T.replicate padding "a"
        <> "\"}]}"

-- ---------------------------------------------------------------------------
-- #39: rotated usernames against the client/host limiters
-- ---------------------------------------------------------------------------

loginLimiterSpec :: Spec
loginLimiterSpec = describe "#39 login limiter bounds rotated usernames" $ do
    it "throttles a stream of distinct usernames from one client host" $
        withTestServer $ \server -> do
            let budget = 30
            statuses <- mapM (loginUnknown server) [1 .. budget + 1]
            -- The per-host budget is checked before the attempt is counted,
            -- so the first budget attempts get through and the next is 429.
            take budget statuses `shouldBe` replicate budget 401
            drop budget statuses `shouldBe` [429]

    it "bounds the number of limiter buckets and still counts a new key" $ do
        limiter <- Auth.newRateLimiter 3 900
        mapM_ (\index -> void (Auth.checkRateLimit limiter ("bucket-" <> T.pack (show index)))) [1 .. 4200 :: Int]
        count <- Auth.rateLimiterKeyCount limiter
        count `shouldSatisfy` (<= 4096)
        outcomes <- mapM (const (Auth.checkRateLimit limiter "late-bucket")) [1 .. 4 :: Int]
        map (either (const ("limited" :: Text)) (const "allowed")) outcomes
            `shouldBe` ["allowed", "allowed", "allowed", "limited"]

loginUnknown :: TestServer -> Int -> IO Int
loginUnknown server index = do
    response <-
        httpRequest
            server
            "POST"
            "/api/auth/login"
            jsonHeaders
            (Just (loginDocument ("rotated-user-" <> T.pack (show index)) "not the password"))
    pure (hrespStatus response)

-- ---------------------------------------------------------------------------
-- #40: IPv6 egress guard prefixes
-- ---------------------------------------------------------------------------

ipv6GuardSpec :: Spec
ipv6GuardSpec = describe "#40 publicV6 blocks IPv4-embedding prefixes" $ do
    it "rejects IPv4-compatible and IPv4-mapped literal addresses" $ do
        publicV6 (0, 0, 0, 0x7f000001) `shouldBe` False
        publicV6 (0, 0, 0, 0x0a000001) `shouldBe` False
        publicV6 (0, 0, 0xffff, 0x7f000001) `shouldBe` False
        publicV6 (0, 0, 0xffff, 0xc0a80101) `shouldBe` False

    it "rejects every 6to4 address, including the encoded private and public IPv4 forms" $ do
        -- 2002:7f00:1:: is 127.0.0.1, 2002:a00:1:: is 10.0.0.1,
        -- 2002:c0a8:101:: is 192.168.1.1.
        publicV6 (0x20027f00, 0x00010000, 0, 0) `shouldBe` False
        publicV6 (0x20020a00, 0x00010000, 0, 0) `shouldBe` False
        publicV6 (0x2002c0a8, 0x01010000, 0, 0) `shouldBe` False
        publicV6 (0x20020808, 0x08080000, 0, 0) `shouldBe` False

    it "rejects Teredo and NAT64 prefixes" $ do
        publicV6 (0x20010000, 0, 0, 1) `shouldBe` False
        publicV6 (0x20010000, 0x4136e378, 0, 0) `shouldBe` False
        publicV6 (0x0064ff9b, 0, 0, 0x7f000001) `shouldBe` False
        publicV6 (0x0064ff9b, 0, 0, 0x0a000001) `shouldBe` False
        publicV6 (0x0064ff9b, 0x00010000, 0, 1) `shouldBe` False

    it "rejects the discard and benchmarking prefixes" $ do
        publicV6 (0x01000000, 0, 0, 1) `shouldBe` False
        publicV6 (0x20010002, 0, 0, 1) `shouldBe` False

    it "keeps ordinary public addresses reachable" $ do
        publicV6 (0x26060000, 0, 0, 1) `shouldBe` True
        publicV6 (0x2a001450, 0x40010000, 0, 0) `shouldBe` True
        publicV6 (0x20010db9, 0, 0, 1) `shouldBe` True

-- ---------------------------------------------------------------------------
-- #43: trusted proxies and X-Forwarded-For
-- ---------------------------------------------------------------------------

trustedProxySpec :: Spec
trustedProxySpec = describe "#43 trusted proxy client keys" $ do
    it "parses CIDR lists and ignores invalid entries" $ do
        proxies <- parseTrustedProxies "127.0.0.1/32, 10.0.0.0/8, fd00::/8, not-a-cidr, 10.0.0.0/99"
        length proxies `shouldBe` 3
        isTrustedProxy proxies (v4 (127, 0, 0, 1)) `shouldBe` True
        isTrustedProxy proxies (v4 (10, 9, 8, 7)) `shouldBe` True
        isTrustedProxy proxies (v4 (8, 8, 8, 8)) `shouldBe` False
        isTrustedProxy proxies (v6Addr (0xfd000000, 0, 0, 1)) `shouldBe` True
        isTrustedProxy proxies (v6Addr (0x26060000, 0, 0, 1)) `shouldBe` False

    it "reads EZA_TRUSTED_PROXIES from the environment" $
        withEnv "EZA_TRUSTED_PROXIES" "127.0.0.1/32" $ do
            proxies <- loadTrustedProxies
            length proxies `shouldBe` 1
            isTrustedProxy proxies (v4 (127, 0, 0, 1)) `shouldBe` True

    it "uses the right-most untrusted forwarded hop only from a trusted peer" $ do
        proxies <- parseTrustedProxies "127.0.0.1/32"
        let trustedPeer =
                defaultRequest
                    { remoteHost = v4 (127, 0, 0, 1)
                    , requestHeaders = [("X-Forwarded-For", "203.0.113.7, 127.0.0.1")]
                    }
        forwarded <- clientHostKey proxies trustedPeer
        forwarded `shouldBe` sockAddrKey (v4 (203, 0, 113, 7))
        -- Without a trusted proxy, a direct client cannot choose its bucket.
        direct <- clientHostKey [] trustedPeer
        direct `shouldBe` sockAddrKey (v4 (127, 0, 0, 1))
        -- The header is ignored when the peer address is not trusted.
        let directPeer =
                defaultRequest
                    { remoteHost = v4 (198, 51, 100, 20)
                    , requestHeaders = [("X-Forwarded-For", "203.0.113.7")]
                    }
        directKey <- clientHostKey proxies directPeer
        directKey `shouldBe` sockAddrKey (v4 (198, 51, 100, 20))

    it "gives two forwarded clients two different keys, skipping trusted hops" $ do
        proxies <- parseTrustedProxies "127.0.0.1/32, 10.0.0.0/8"
        let peer hop =
                defaultRequest
                    { remoteHost = v4 (127, 0, 0, 1)
                    , requestHeaders = [("X-Forwarded-For", hop)]
                    }
        first <- clientHostKey proxies (peer "203.0.113.7")
        second <- clientHostKey proxies (peer "203.0.113.7, 10.1.2.3")
        first `shouldBe` second
        third <- clientHostKey proxies (peer "198.51.100.9")
        third `shouldNotBe` first

    it "splits the recovery limiter per forwarded client when the proxy is trusted" $
        withEnv "EZA_TRUSTED_PROXIES" "127.0.0.1/32" $
            withTestServer $ \server -> do
                _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
                let redeem forward = do
                        httpRequest
                            server
                            "POST"
                            "/api/recovery/redeem"
                            ( [ ("Content-Type", "application/json")
                              , ("X-Forwarded-For", forward)
                              ]
                            )
                            (Just (encode (object ["username" .= ("alice" :: Text), "code" .= ("bad-code" :: Text)])))
                sameClient <- mapM (const (redeem "203.0.113.7")) [1 .. 6 :: Int]
                let (firstFive, afterFive) = splitAt 5 sameClient
                map hrespStatus firstFive `shouldBe` replicate 5 400
                map hrespStatus afterFive `shouldBe` [429]
                -- A second forwarded client has a fresh bucket.
                otherClient <- redeem "198.51.100.9"
                hrespStatus otherClient `shouldBe` 400

    it "ignores the forwarded header when no proxy is trusted" $
        withTestServer $ \server -> do
            _ <- createTestUser server "alice" "alice password" Control.RoleAdmin
            let redeem hop =
                    httpRequest
                        server
                        "POST"
                        "/api/recovery/redeem"
                        ( [ ("Content-Type", "application/json")
                          , ("X-Forwarded-For", hop)
                          ]
                        )
                        (Just (encode (object ["username" .= ("alice" :: Text), "code" .= ("bad-code" :: Text)])))
            statuses <-
                mapM
                    (\index -> hrespStatus <$> redeem (TE.encodeUtf8 ("203.0.113." <> T.pack (show index))))
                    [1 .. 6 :: Int]
            take 5 statuses `shouldBe` replicate 5 400
            drop 5 statuses `shouldBe` [429]

-- | Run an action with one environment variable set, restoring the old value.
withEnv :: String -> String -> IO a -> IO a
withEnv name value action =
    bracket (lookupEnv name) restore (const (setEnv name value >> action))
  where
    restore Nothing = unsetEnv name
    restore (Just previous) = setEnv name previous

v4 :: (Word8, Word8, Word8, Word8) -> SockAddr
v4 (a, b, c, d) = SockAddrInet 0 (tupleToHostAddress (a, b, c, d))

v6Addr :: (Word32, Word32, Word32, Word32) -> SockAddr
v6Addr (a, b, c, d) = SockAddrInet6 0 0 (a, b, c, d) 0
