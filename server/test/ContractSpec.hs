{-# LANGUAGE OverloadedStrings #-}

{- | Server-side contract tests.

These start the real server, fetch the responses the Miso client consumes and
decode them with the shared core 'FromJSON' instances. A server change that
renames or drops a field therefore fails natively, before the browser sees a
blank or half-defaulted screen.
-}
module ContractSpec (contractSpec) where

import Control.Monad (void)
import Data.Aeson (FromJSON (..), Result (..), Value (..), eitherDecode, fromJSON)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Text (Text)
import Test.Hspec

import Eza.Account (AccountInfo, TokenView)
import Eza.Ai (AiStatus, TagSuggestion)
import Eza.Boot (BootPayload (..), wireVersion)
import qualified Eza.Control as Control
import Eza.Rule (Rule)
import Eza.Share (ShareView)
import TestHarness

contractSpec :: Spec
contractSpec =
    around withTestServer $
        describe "core DTO contract over the real server" $ do
            it "serves a strict boot payload" $ \server -> do
                (session, csrf) <- loginFixture server
                payload <- getAs server session csrf "/api/v1/boot" :: IO BootPayload
                bpWireVersion payload `shouldBe` wireVersion

            it "serves a strict account payload" $ \server -> do
                (session, csrf) <- loginFixture server
                void (getAs server session csrf "/api/v1/account" :: IO AccountInfo)

            it "serves strict token and share views" $ \server -> do
                (session, csrf) <- loginFixture server
                tokens <- getWrapped server session csrf "/api/v1/tokens" "tokens" :: IO [TokenView]
                tokens `shouldBe` []
                shares <- getWrapped server session csrf "/api/v1/share-links" "shares" :: IO [ShareView]
                shares `shouldBe` []

            it "serves strict rules and AI status" $ \server -> do
                (session, csrf) <- loginFixture server
                rules <- getWrapped server session csrf "/api/v1/rules" "rules" :: IO [Rule]
                rules `shouldBe` []
                void (getAs server session csrf "/api/v1/ai/status" :: IO AiStatus)

            it "serves the strict AI suggestion wrapper" $ \server -> do
                (session, csrf) <- loginFixture server
                suggestions <-
                    getWrapped
                        server
                        session
                        csrf
                        "/api/v1/tags/haskell/suggestions"
                        "suggestions" ::
                        IO [TagSuggestion]
                suggestions `shouldBe` []

-- ----------------------------------------------------------------- helpers ---

loginFixture :: TestServer -> IO (Text, Text)
loginFixture server = do
    _ <- createTestUser server "contract" "contract-password-123" Control.RoleAdmin
    loginAs server "contract" "contract-password-123"

getAs :: (FromJSON a) => TestServer -> Text -> Text -> String -> IO a
getAs server session csrf path = do
    response <- httpRequest server "GET" path (cookieHeaders session csrf) Nothing
    response `shouldHaveStatus` 200
    case eitherDecode (hrespBody response) of
        Left err -> failTest (path <> ": " <> err)
        Right value -> pure value

getWrapped ::
    (FromJSON a) =>
    TestServer ->
    Text ->
    Text ->
    String ->
    Text ->
    IO [a]
getWrapped server session csrf path key = do
    response <- httpRequest server "GET" path (cookieHeaders session csrf) Nothing
    response `shouldHaveStatus` 200
    body <-
        case eitherDecode (hrespBody response) :: Either String Value of
            Left err -> failTest (path <> ": " <> err)
            Right value -> pure value
    field <-
        maybe
            (failTest (path <> ": missing '" <> show key <> "'"))
            pure
            (fieldOf key body)
    case fromJSON field of
        Error err -> failTest (path <> "." <> show key <> ": " <> err)
        Success values -> pure values

fieldOf :: Text -> Value -> Maybe Value
fieldOf key value = case value of
    Object objectValue -> KeyMap.lookup (Key.fromText key) objectValue
    _ -> Nothing

failTest :: String -> IO a
failTest message = expectationFailure message >> ioError (userError message)
