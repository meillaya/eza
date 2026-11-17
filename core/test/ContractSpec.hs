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
import Eza.Types (BookmarkSummary (..), GraphData (..), GraphRecord (..), GraphTag (..), LibraryStats (..), SearchPage (..), TagStat (..))
import Eza.Url (isHttpUrl)
import Eza.User (UserCreateInput (..), UserCreateResult (..), UserRole (..), UserView (..))
import Eza.View (
    ColorGroup (..),
    GraphViewDefinition (..),
    LabelMode (..),
    View (..),
    ViewDefinition (..),
    ViewInput (..),
    ViewKind (..),
    defaultGraphViewDefinition,
    defaultLedgerViewDefinition,
 )
import Eza.Webhook (DeliveryView (..), EventType (..), Webhook (..), WebhookInput (..), validateWebhookInput)

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
        it "decodes a RuleInput create request with the documented defaults" $
            eitherDecode "{\"name\":\"hn\",\"pattern\":\"news.ycombinator\"}"
                `shouldBe` Right (RuleInput "hn" True "url" "news.ycombinator" [] False)
        it "fills a server-shaped rule from a create request" $
            ruleInputToRule (RuleInput "hn" False "domain" "news.ycombinator.com" ["reading"] True)
                `shouldBe` rule{ruleId = 0, ruleEnabled = False, ruleField = "domain", rulePattern = "news.ycombinator.com", ruleAddTags = ["reading"], ruleMarkRead = True, ruleCreatedAt = 0}
        it "rejects a strict rule response without a pattern" $
            (eitherDecode "{\"name\":\"hn\"}" :: Either String Rule) `shouldSatisfy` isLeft
        it "rejects a rule response with a missing or renamed field" $ do
            (eitherDecode (encode (removeKey "enabled" (toJSON rule))) :: Either String Rule) `shouldSatisfy` isLeft
            (eitherDecode (encode (renameKey "add_tags" "tags" (toJSON rule))) :: Either String Rule) `shouldSatisfy` isLeft

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

    describe "Eza.Webhook" $ do
        it "round-trips a stored webhook" $ roundTrip webhook
        it "uses the historical webhook keys" $
            keysOf webhook
                `shouldMatchList` [ "id"
                                  , "name"
                                  , "url"
                                  , "events"
                                  , "enabled"
                                  , "created_at"
                                  , "last_status"
                                  , "last_attempt_at"
                                  , "last_error"
                                  , "fail_streak"
                                  ]
        it "rejects a webhook response with a missing or renamed field" $ do
            (eitherDecode (encode (removeKey "fail_streak" (toJSON webhook))) :: Either String Webhook) `shouldSatisfy` isLeft
            (eitherDecode (encode (renameKey "last_error" "error" (toJSON webhook))) :: Either String Webhook) `shouldSatisfy` isLeft
        it "keeps the documented WebhookInput defaults" $ do
            eitherDecode "{\"name\":\"deploy\",\"url\":\"https://example.com/hook\",\"events\":[\"bookmark.created\"]}"
                `shouldBe` Right (WebhookInput "deploy" "https://example.com/hook" [BookmarkCreated] True)
            eitherDecode "{}"
                `shouldBe` Right (WebhookInput "" "" [] True)
        it "round-trips a delivery view and rejects a missing field" $ do
            roundTrip deliveryView
            (eitherDecode (encode (removeKey "attempts" (toJSON deliveryView))) :: Either String DeliveryView) `shouldSatisfy` isLeft
            (eitherDecode (encode (renameKey "last_error" "error" (toJSON deliveryView))) :: Either String DeliveryView) `shouldSatisfy` isLeft
        it "rejects webhook targets carrying URL credentials or a dot-only host" $ do
            validateWebhookInput goodHook{wiUrl = "https://user:secret@example.com/hook"} `shouldSatisfy` isLeft
            validateWebhookInput goodHook{wiUrl = "https://.../hook"} `shouldSatisfy` isLeft

    describe "Eza.User" $ do
        it "round-trips a user view and rejects a missing or renamed field" $ do
            roundTrip userView
            (eitherDecode (encode (removeKey "role" (toJSON userView))) :: Either String UserView) `shouldSatisfy` isLeft
            (eitherDecode (encode (renameKey "username" "name" (toJSON userView))) :: Either String UserView) `shouldSatisfy` isLeft
        it "requires both fields of a created user result" $ do
            roundTrip userCreateResult
            (eitherDecode (encode (removeKey "recovery_codes" (toJSON userCreateResult))) :: Either String UserCreateResult) `shouldSatisfy` isLeft
        it "keeps the documented UserCreateInput role default" $
            eitherDecode "{\"username\":\"bob\",\"password\":\"a-long-password\"}"
                `shouldBe` Right (UserCreateInput "bob" "a-long-password" RoleMember)

    describe "Eza.View" $ do
        it "round-trips a stored graph view and a stored ledger view" $ do
            roundTrip graphView
            roundTrip ledgerView
        it "uses the historical wrapper keys" $
            keysOf graphView
                `shouldMatchList` [ "schema"
                                  , "id"
                                  , "slug"
                                  , "name"
                                  , "kind"
                                  , "is_default"
                                  , "definition"
                                  , "created_at"
                                  , "updated_at"
                                  ]
        it "rejects a stored view with a missing or renamed wrapper field" $ do
            (eitherDecode (encode (removeKey "updated_at" (toJSON graphView))) :: Either String View) `shouldSatisfy` isLeft
            (eitherDecode (encode (renameKey "is_default" "default" (toJSON graphView))) :: Either String View) `shouldSatisfy` isLeft
        it "rejects a stored view with a missing definition field" $ do
            (eitherDecode "{\"schema\":1,\"id\":1,\"slug\":\"g\",\"name\":\"G\",\"kind\":\"graph\",\"is_default\":false,\"definition\":{\"query\":\"\",\"label_mode\":\"auto\",\"layout_preset\":\"standard\",\"local_depth\":null,\"color_groups\":[]},\"created_at\":0,\"updated_at\":0}" :: Either String View) `shouldSatisfy` isLeft
            (eitherDecode "{\"schema\":1,\"id\":1,\"slug\":\"g\",\"name\":\"G\",\"kind\":\"graph\",\"is_default\":false,\"definition\":{\"query\":\"\",\"tags_shown\":true,\"label_mode\":\"auto\",\"layout_preset\":\"standard\",\"local_depth\":null,\"color_groups\":[{\"name\":\"rust\",\"query\":\"tag:rust\",\"color\":\"#C98A3E\"}]},\"created_at\":0,\"updated_at\":0}" :: Either String View) `shouldSatisfy` isLeft
        it "keeps the documented ViewInput definition defaults" $ do
            eitherDecode "{\"name\":\"Rust\",\"kind\":\"graph\",\"definition\":{}}"
                `shouldBe` Right (ViewInput "Rust" GraphKind (GraphDefinition defaultGraphViewDefinition) Nothing)
            eitherDecode "{\"name\":\"Rust\",\"kind\":\"graph\",\"definition\":{\"color_groups\":[{\"name\":\"rust\"}]}}"
                `shouldBe` Right
                    ( ViewInput
                        "Rust"
                        GraphKind
                        (GraphDefinition defaultGraphViewDefinition{gvdColorGroups = [ColorGroup "rust" "" "#C98A3E" True]})
                        Nothing
                    )

    describe "Eza.Types GraphData" $ do
        it "round-trips the compact graph payload" $ roundTrip graphData
        it "requires the revision field" $ do
            (eitherDecode "{\"tags\":[],\"records\":[],\"links\":[]}" :: Either String GraphData) `shouldSatisfy` isLeft
            (eitherDecode (encode (removeKey "revision" (toJSON graphData))) :: Either String GraphData) `shouldSatisfy` isLeft

    describe "Eza.Url.isHttpUrl" $ do
        it "accepts absolute http(s) URLs with a usable host" $
            map
                isHttpUrl
                [ "http://example.com"
                , "https://example.com/path?q=1#frag"
                , "HTTP://EXAMPLE.COM"
                , "  https://example.com  "
                , "http://example.com:8080"
                , "http://127.0.0.1:9/hook"
                , "https://[::1]"
                , "https://[::1]:8443/x"
                , "https://sub.domain.example/a_b-c~d"
                ]
                `shouldBe` replicate 9 True
        it "rejects empty, hostless, credential, dot-only and malformed hosts" $
            map
                isHttpUrl
                [ ""
                , "   "
                , "http://"
                , "http:///path"
                , "http://?q=1"
                , "http://#frag"
                , "http://."
                , "http://.."
                , "http://./path"
                , "http://exa mple.com"
                , "http://exa\tmple.com"
                , "http://exa\nmple.com"
                , "http://user:secret@example.com"
                , "http://@example.com"
                , "http://example.com:"
                , "http://example.com:not-a-port"
                , "ftp://example.com"
                , "javascript:alert(1)"
                , "//example.com"
                , "http:/example.com"
                , "https:example.com"
                ]
                `shouldBe` replicate 21 False

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

webhook :: Webhook
webhook =
    Webhook
        { whId = 3
        , whName = "deploy"
        , whUrl = "https://example.com/hook"
        , whEvents = [BookmarkCreated, BookmarkDeleted]
        , whEnabled = True
        , whCreatedAt = 1700000000
        , whLastStatus = Just 200
        , whLastAttemptAt = Just 1700000100
        , whLastError = ""
        , whFailStreak = 0
        }

goodHook :: WebhookInput
goodHook = WebhookInput "deploy" "https://example.com/hook" [BookmarkCreated] True

deliveryView :: DeliveryView
deliveryView =
    DeliveryView
        { dvId = 7
        , dvEvent = BookmarkCreated
        , dvState = "delivered"
        , dvAttempts = 1
        , dvLastError = ""
        , dvCreatedAt = 1700000000
        }

userView :: UserView
userView =
    UserView
        { uvId = 1
        , uvUsername = "alice"
        , uvRole = RoleAdmin
        , uvCreatedAt = 1700000000
        , uvDisabledAt = Nothing
        , uvLastLoginAt = Just 1700000100
        }

userCreateResult :: UserCreateResult
userCreateResult = UserCreateResult userView ["code-1", "code-2"]

graphDefinition :: GraphViewDefinition
graphDefinition =
    GraphViewDefinition
        { gvdQuery = "tag:rust"
        , gvdTagsShown = True
        , gvdLabelMode = LabelTags
        , gvdLayoutPreset = Standard
        , gvdLocalDepth = Just 2
        , gvdColorGroups = [ColorGroup "Rust" "tag:rust" "#C98A3E" True]
        }

graphView :: View
graphView =
    View
        { vId = 7
        , vSlug = "graph"
        , vName = "Graph"
        , vKind = GraphKind
        , vIsDefault = True
        , vDefinition = GraphDefinition graphDefinition
        , vCreatedAt = 1
        , vUpdatedAt = 2
        }

ledgerView :: View
ledgerView =
    View
        { vId = 8
        , vSlug = "ledger"
        , vName = "Ledger"
        , vKind = LedgerKind
        , vIsDefault = False
        , vDefinition = LedgerDefinition defaultLedgerViewDefinition
        , vCreatedAt = 1
        , vUpdatedAt = 2
        }

graphData :: GraphData
graphData =
    GraphData
        { gdTags = [GraphTag "rust" 2]
        , gdRecords = [GraphRecord 7 "Title" "example.com" 1700000000 True False [0]]
        , gdLinks = []
        , gdRevision = "r1:3:4:5:2"
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

-- | Drop one object key so a strict response decoder has to fail.
removeKey :: T.Text -> Value -> Value
removeKey key = \case
    Object o -> Object (KeyMap.delete (Key.fromText key) o)
    other -> other

-- | Rename one object key so a strict response decoder cannot find the old name.
renameKey :: T.Text -> T.Text -> Value -> Value
renameKey old new = \case
    Object o -> case KeyMap.lookup (Key.fromText old) o of
        Nothing -> Object o
        Just value -> Object (KeyMap.insert (Key.fromText new) value (KeyMap.delete (Key.fromText old) o))
    other -> other
