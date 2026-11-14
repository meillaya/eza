{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Golden contract tests for the core wire types.

Each test round-trips a value through the exact encoder the server uses and
the exact decoder the client uses, and checks the wire keys where a rename
would otherwise only show up as a broken browser screen.
-}
module ContractSpec (contractTests) where

import Data.Aeson (FromJSON, ToJSON, Value (..), eitherDecode, encode, toJSON)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.Text as T
import Test.Hspec

import Eza.Account
import Eza.Ai
import Eza.Boot
import Eza.Consolidation
import Eza.GraphLayout (GraphLayoutWire (..), LayoutPreset (..), graphLayoutWireSchema)
import Eza.Problem
import Eza.Rule
import Eza.Share
import Eza.Types (BookmarkSummary (..), LibraryStats (..), SearchPage (..), TagStat (..))
import Eza.User (UserRole (..))

contractTests :: Spec
contractTests = do
    describe "Eza.Account" $ do
        it "round-trips a credential" $ roundTrip credential
        it "uses the historical credential keys" $
            keysOf credential
                `shouldMatchList` ["id", "nickname", "created_at", "backup_eligible"]
        it "round-trips a session" $ roundTrip sessionInfo
        it "uses the historical session keys" $
            keysOf sessionInfo
                `shouldMatchList` ["created_at", "last_seen_at", "expires_at", "current"]
        it "round-trips an account payload" $ roundTrip accountInfo
        it "uses the historical account keys" $
            keysOf accountInfo
                `shouldMatchList` [ "username"
                                  , "role"
                                  , "has_password"
                                  , "require_passkey"
                                  , "account_configured"
                                  , "credentials"
                                  , "recovery_codes_remaining"
                                  , "sessions"
                                  ]
        it "round-trips a token view" $ roundTrip tokenView
        it "uses the historical token keys" $
            keysOf tokenView
                `shouldMatchList` ["id", "name", "prefix", "scopes", "created_at"]

    describe "Eza.Rule" $ do
        it "round-trips a rule" $ roundTrip rule
        it "uses the historical rule keys" $
            keysOf rule
                `shouldMatchList` [ "id"
                                  , "name"
                                  , "enabled"
                                  , "field"
                                  , "pattern"
                                  , "add_tags"
                                  , "mark_read"
                                  , "created_at"
                                  ]
        it "decodes a create request with the documented defaults" $
            eitherDecode "{\"name\":\"hn\",\"pattern\":\"news.ycombinator\"}"
                `shouldBe` Right
                    Rule
                        { ruleId = 0
                        , ruleName = "hn"
                        , ruleEnabled = True
                        , ruleField = "url"
                        , rulePattern = "news.ycombinator"
                        , ruleAddTags = []
                        , ruleMarkRead = False
                        , ruleCreatedAt = 0
                        }
        it "rejects a rule response without a pattern" $
            (eitherDecode "{\"name\":\"hn\"}" :: Either String Rule) `shouldSatisfy` isLeft

    describe "Eza.Share" $ do
        it "round-trips a share" $ roundTrip shareView
        it "uses the historical share keys" $
            keysOf shareView
                `shouldMatchList` [ "id"
                                  , "prefix"
                                  , "scope"
                                  , "target_id"
                                  , "include_note"
                                  , "created_at"
                                  , "expires_at"
                                  ]

    describe "Eza.Ai" $ do
        it "round-trips the status" $ roundTrip aiStatus
        it "uses the historical status keys" $
            keysOf aiStatus `shouldMatchList` ["provider", "model", "configured"]
        it "round-trips a suggestion" $ roundTrip tagSuggestion
        it "requires a bookmark in a suggestion" $
            (eitherDecode "{\"tags\":[],\"reason\":\"\"}" :: Either String TagSuggestion)
                `shouldSatisfy` isLeft

    describe "Eza.Consolidation" $ do
        it "keeps the groups wrapper" $
            case toJSON (ConsolidationReport [consolidationGroup]) of
                Object o -> KeyMap.keys o `shouldMatchList` [Key.fromText "groups"]
                other -> expectationFailure ("unexpected consolidation body: " <> show other)
        it "round-trips a report" $ roundTrip (ConsolidationReport [consolidationGroup])

    describe "Eza.GraphLayout" $ do
        it "declares wire schema 1" $ graphLayoutWireSchema `shouldBe` 1
        it "round-trips the layout wire" $ roundTrip graphLayoutWire
        it "keeps the historical layout keys" $
            keysOf graphLayoutWire
                `shouldMatchList` ["schema", "revision", "preset", "tags", "records", "bounds"]
        it "renders the preset as a bare word" $
            toJSON Compact `shouldBe` String "compact"
        it "parses the preset words" $ do
            eitherDecode "\"compact\"" `shouldBe` Right Compact
            eitherDecode "\"standard\"" `shouldBe` Right Standard
            eitherDecode "\"airy\"" `shouldBe` Right Airy
        it "rejects an unknown preset" $
            (eitherDecode "\"bogus\"" :: Either String LayoutPreset) `shouldSatisfy` isLeft
        it "rejects an unknown layout schema" $
            ( eitherDecode
                "{\"schema\":2,\"revision\":\"r\",\"preset\":\"standard\",\"tags\":[],\"records\":[],\"bounds\":[0,0,1,1]}" ::
                Either String GraphLayoutWire
            )
                `shouldSatisfy` isLeft
        it "encodes bounds as a four-array" $
            case toJSON graphLayoutWire of
                Object o ->
                    case KeyMap.lookup (Key.fromText "bounds") o of
                        Just (Array values) -> length values `shouldBe` 4
                        other -> expectationFailure ("bounds is not an array: " <> show other)
                other -> expectationFailure ("unexpected layout body: " <> show other)

    describe "Eza.Problem" $ do
        it "encodes the historical error envelope" $
            toJSON (Problem 404 "not_found" "bookmark not found")
                `shouldBe` objectValue
                    [ ("error", objectValue [("code", String "not_found"), ("message", String "bookmark not found")])
                    ]
        it "does not encode the HTTP status" $
            case toJSON (Problem 500 "internal_error" "boom") of
                Object o -> KeyMap.keys o `shouldMatchList` [Key.fromText "error"]
                other -> expectationFailure ("unexpected problem body: " <> show other)
        it "decodes the envelope with status 0" $
            eitherDecode "{\"error\":{\"code\":\"not_found\",\"message\":\"missing\"}}"
                `shouldBe` Right (Problem 0 "not_found" "missing")

    describe "Eza.Boot" $ do
        it "declares wire version 1" $ wireVersion `shouldBe` 1
        it "carries wire_version in the boot payload" $
            keysOf bootPayload
                `shouldContain` [Key.fromText "wire_version"]
        it "round-trips the boot payload" $ roundTrip bootPayload
        it "rejects a boot payload without wire_version" $
            (eitherDecode "{}" :: Either String BootPayload) `shouldSatisfy` isLeft

-- ------------------------------------------------------------------ samples ---

credential :: Credential
credential =
    Credential
        { crId = "cred-1"
        , crNickname = "laptop"
        , crCreatedAt = 1700000000
        , crLastUsedAt = Nothing
        , crBackupEligible = True
        }

sessionInfo :: SessionInfo
sessionInfo =
    SessionInfo
        { siCreatedAt = 1700000000
        , siLastSeenAt = Just 1700000100
        , siExpiresAt = 1700003600
        , siCurrent = True
        }

accountInfo :: AccountInfo
accountInfo =
    AccountInfo
        { aiUsername = "mei"
        , aiRole = RoleAdmin
        , aiHasPassword = True
        , aiRequirePasskey = False
        , aiAccountConfigured = True
        , aiCredentials = [credential]
        , aiRecoveryCodesRemaining = 7
        , aiSessions = [sessionInfo]
        }

tokenView :: TokenView
tokenView =
    TokenView
        { tvId = 3
        , tvName = "clipper"
        , tvPrefix = "eza_pat_u1_abc"
        , tvScopes = ["capture"]
        , tvCreatedAt = 1700000000
        , tvLastUsedAt = Nothing
        , tvRevokedAt = Nothing
        }

rule :: Rule
rule =
    Rule
        { ruleId = 4
        , ruleName = "hn"
        , ruleEnabled = True
        , ruleField = "domain"
        , rulePattern = "news.ycombinator.com"
        , ruleAddTags = ["reading"]
        , ruleMarkRead = False
        , ruleCreatedAt = 1700000000
        }

shareView :: ShareView
shareView =
    ShareView
        { svId = 9
        , svPrefix = "abc123"
        , svScope = "bookmark"
        , svTargetId = 42
        , svIncludeNote = True
        , svCreatedAt = 1700000000
        , svExpiresAt = 1700086400
        , svRevokedAt = Nothing
        , svLastAccessedAt = Nothing
        }

aiStatus :: AiStatus
aiStatus = AiStatus{asProvider = "ollama", asModel = "llama3.2", asConfigured = True}

bookmarkSummary :: BookmarkSummary
bookmarkSummary =
    BookmarkSummary
        { bsId = 42
        , bsUrl = "https://example.com/"
        , bsTitle = "Example"
        , bsDomain = "example.com"
        , bsCreatedAt = 1700000000
        , bsAddedAt = 1700000001
        , bsFaviconUrl = ""
        , bsTags = ["reading"]
        , bsIsRead = False
        , bsIsDead = False
        , bsSnippet = Nothing
        }

tagSuggestion :: TagSuggestion
tagSuggestion =
    TagSuggestion
        { tsgBookmark = bookmarkSummary
        , tsgTags = ["haskell"]
        , tsgReason = "Suggested for this tag bucket"
        }

consolidationGroup :: ConsolidationGroup
consolidationGroup =
    ConsolidationGroup
        { cgKind = "case"
        , cgTags = [TagStat "Haskell" 3, TagStat "haskell" 2]
        , cgSuggested = "Haskell"
        }

graphLayoutWire :: GraphLayoutWire
graphLayoutWire =
    GraphLayoutWire
        { glwSchema = graphLayoutWireSchema
        , glwRevision = "rev-1"
        , glwPreset = Standard
        , glwTags = [(-1.5, 2.25)]
        , glwRecords = [(3.5, -4.75)]
        , glwBounds = (-10, -10, 10, 10)
        }

bootPayload :: BootPayload
bootPayload =
    BootPayload
        { bpWireVersion = wireVersion
        , bpVersion = "0.3.0"
        , bpOrigin = "http://localhost:8080"
        , bpTags = []
        , bpSavedSearches = []
        , bpInitial =
            SearchPage
                { spItems = []
                , spTotal = 0
                , spOffset = 0
                , spLimit = 50
                , spHasMore = False
                , spYearCounts = []
                }
        , bpStats =
            LibraryStats
                { lsTotal = 0
                , lsTags = 0
                , lsTagLinks = 0
                , lsSources = 0
                , lsTopSources = []
                , lsSourcesOnce = 0
                , lsFirstDay = ""
                , lsLastDay = ""
                , lsDays = 0
                , lsYears = []
                , lsFilingDays = []
                , lsUnread = 0
                , lsDead = 0
                , lsQueued = 0
                , lsFaviconBytes = 0
                , lsHighlights = 0
                , lsShares = 0
                }
        , bpViews = []
        }

-- ------------------------------------------------------------------ helpers ---

roundTrip :: (Eq a, Show a, ToJSON a, FromJSON a) => a -> Expectation
roundTrip value = eitherDecode (encode value) `shouldBe` Right value

keysOf :: (ToJSON a) => a -> [Key.Key]
keysOf value = case toJSON value of
    Object o -> KeyMap.keys o
    _ -> []

objectValue :: [(T.Text, Value)] -> Value
objectValue pairs =
    Object (KeyMap.fromList [(Key.fromText k, v) | (k, v) <- pairs])

isLeft :: Either a b -> Bool
isLeft = \case
    Left _ -> True
    Right _ -> False
