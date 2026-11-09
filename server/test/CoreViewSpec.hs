{-# LANGUAGE OverloadedStrings #-}

{- | Tests for the pure building blocks shared by the graph and view work:
UTC dates, graph matching, and declarative view validation.
-}
module CoreViewSpec (coreViewSpec) where

import Data.Aeson (decode, encode, object, (.=))
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Test.Hspec

import Eza.GraphLayout (LayoutPreset (..))
import Eza.GraphMatch
import Eza.SearchQuery (parseSearchQuery)
import Eza.Time (daysFromCivil, utcDay, utcYear, utcYearDay)
import Eza.TokenPrefix
import Eza.Types (GraphData (..), GraphRecord (..), GraphTag (..))
import Eza.User
import Eza.View
import Eza.Webhook

coreViewSpec :: Spec
coreViewSpec = do
    describe "UTC dates" $ do
        it "converts the epoch, a known save date, and a leap day" $ do
            utcYear 0 `shouldBe` 1970
            utcDay 0 `shouldBe` "1970-01-01"
            utcYearDay 1700000000 `shouldBe` (2023, 11, 14)
            utcDay 1700000000 `shouldBe` "2023-11-14"
            utcDay 1709164800 `shouldBe` "2024-02-29"
        it "round-trips civil dates through daysFromCivil" $ do
            let cases = [(1970, 1, 1), (2000, 2, 29), (2023, 11, 14), (2024, 2, 29), (2038, 1, 19)]
            mapM_
                ( \(year, month, day) ->
                    let seconds = fromInteger (daysFromCivil (toInteger year) month day) * 86400
                     in utcYearDay seconds `shouldBe` (year, month, day)
                )
                cases

    describe "graph matching" $ do
        let graph =
                GraphData
                    { gdTags = [GraphTag "rust" 2, GraphTag "haskell" 1]
                    , gdRecords =
                        [ GraphRecord 1 "Rust ownership" "example.com" 1700000000 False False [0]
                        , GraphRecord 2 "Haskell at work" "work.test" 1735689600 True False [1]
                        , GraphRecord 3 "Gone page" "dead.test" 1700000000 False True [0]
                        ]
                    , gdLinks = []
                    , gdRevision = "test:1"
                    }
            (rustRecord, haskellRecord, deadRecord) = case gdRecords graph of
                (first : second : third : _) -> (first, second, third)
                _ -> error "fixture must contain three records"
        it "matches text, tags, flags, and UTC years/days" $ do
            matchesQueryRecord (parseSearchQuery "rust") graph rustRecord `shouldBe` True
            matchesQueryRecord (parseSearchQuery "tag:rust") graph rustRecord `shouldBe` True
            matchesQueryRecord (parseSearchQuery "tag:haskell") graph rustRecord `shouldBe` False
            matchesQueryRecord (parseSearchQuery "is:unread") graph rustRecord `shouldBe` True
            matchesQueryRecord (parseSearchQuery "is:unread") graph haskellRecord `shouldBe` False
            matchesQueryRecord (parseSearchQuery "is:dead") graph deadRecord `shouldBe` True
            matchesQueryRecord (parseSearchQuery "is:dead") graph rustRecord `shouldBe` False
            matchesQueryRecord (parseSearchQuery "year:2023") graph rustRecord `shouldBe` True
            matchesQueryRecord (parseSearchQuery "day:2025-01-01") graph haskellRecord `shouldBe` True
            matchesQueryRecord (parseSearchQuery "-rust") graph rustRecord `shouldBe` False
        it "does not support link: in the graph matcher" $ do
            matchesQueryRecord (parseSearchQuery "link:target") graph rustRecord `shouldBe` False
        it "assigns color groups in order, first match wins" $ do
            let groups =
                    [ ColorGroup "Rust" "tag:rust" "#C98A3E" True
                    , ColorGroup "Work" "haskell" "#3E8AC9" True
                    , ColorGroup "Disabled" "tag:rust" "#000000" False
                    ]
                assignment = assignGroupColors groups graph
            IM.lookup 1 (caRecordColors assignment) `shouldBe` Just "#C98A3E"
            IM.lookup 2 (caRecordColors assignment) `shouldBe` Just "#3E8AC9"
            M.lookup "rust" (caTagColors assignment) `shouldBe` Just "#C98A3E"
            M.lookup "haskell" (caTagColors assignment) `shouldBe` Just "#3E8AC9"
        it "matches tag nodes by text and tag filters only" $ do
            matchesTag (parseSearchQuery "rust") (TagContext "Rust") `shouldBe` True
            matchesTag (parseSearchQuery "tag:rust") (TagContext "Rust") `shouldBe` True
            matchesTag (parseSearchQuery "is:unread") (TagContext "Rust") `shouldBe` False
            matchesTag (parseSearchQuery "rust") (TagContext "Haskell") `shouldBe` False

    describe "view definitions" $ do
        it "round-trips a graph view through JSON" $ do
            let definition =
                    GraphViewDefinition
                        { gvdQuery = "tag:rust"
                        , gvdTagsShown = True
                        , gvdLabelMode = LabelAuto
                        , gvdLayoutPreset = Standard
                        , gvdLocalDepth = Just 2
                        , gvdColorGroups =
                            [ColorGroup "Rust" "tag:rust" "#C98A3E" True]
                        }
                encoded = encode definition
            (decode encoded :: Maybe GraphViewDefinition) `shouldBe` Just definition
        it "decodes the default definitions" $ do
            (decode (encode defaultGraphViewDefinition) :: Maybe GraphViewDefinition)
                `shouldBe` Just defaultGraphViewDefinition
            (decode (encode defaultLedgerViewDefinition) :: Maybe LedgerViewDefinition)
                `shouldBe` Just defaultLedgerViewDefinition
        it "rejects an unsupported wrapper schema" $ do
            (decode "{\"schema\":2,\"slug\":\"x\",\"name\":\"x\",\"kind\":\"graph\",\"definition\":{}}" :: Maybe View)
                `shouldBe` Nothing
        it "validates names, queries, colors, and group limits" $ do
            validateViewDefinition GraphKind (GraphDefinition defaultGraphViewDefinition)
                `shouldBe` Right ()
            validateViewDefinition GraphKind (GraphDefinition (defaultGraphViewDefinition{gvdColorGroups = [ColorGroup "bad" "" "#zzzzzz" True]}))
                `shouldSatisfy` isLeft
            validateViewDefinition GraphKind (GraphDefinition (defaultGraphViewDefinition{gvdColorGroups = replicate (maxColorGroups + 1) (ColorGroup "x" "" "#C98A3E" True)}))
                `shouldSatisfy` isLeft
            validateViewDefinition GraphKind (GraphDefinition (defaultGraphViewDefinition{gvdLocalDepth = Just 4}))
                `shouldSatisfy` isLeft
            validateViewDefinition GraphKind (GraphDefinition (defaultGraphViewDefinition{gvdQuery = "link:target"}))
                `shouldSatisfy` isLeft
            validateViewDefinition LedgerKind (LedgerDefinition defaultLedgerViewDefinition)
                `shouldBe` Right ()
        it "derives stable slugs" $ do
            slugify "Rust Notes!" `shouldBe` "rust-notes"
            slugify "  " `shouldBe` "view"
            slugify (T.replicate 80 "a") `shouldSatisfy` ((<= 48) . T.length)
        it "encodes every stored view with its kind" $ do
            let view =
                    View
                        { vId = 7
                        , vSlug = "graph"
                        , vName = "Graph"
                        , vKind = GraphKind
                        , vIsDefault = True
                        , vDefinition = GraphDefinition defaultGraphViewDefinition
                        , vCreatedAt = 1
                        , vUpdatedAt = 2
                        }
            decode (encode view) `shouldBe` Just view
        it "rejects an unsupported schema on a create request" $ do
            (decode "{\"schema\":2,\"name\":\"x\",\"kind\":\"graph\",\"definition\":{}}" :: Maybe ViewInput)
                `shouldBe` Nothing
        it "parses a draft and rejects a mismatched definition kind" $ do
            let draft = ViewInput "Graph" GraphKind (GraphDefinition defaultGraphViewDefinition) Nothing
            validateViewDraft draft `shouldBe` Right ()
            validateViewDraft (draft{viDefinition = LedgerDefinition defaultLedgerViewDefinition})
                `shouldSatisfy` isLeft

    describe "account DTOs" $ do
        it "round-trips roles and user views" $ do
            mapM_
                (\role -> parseUserRole (userRoleText role) `shouldBe` Just role)
                [RoleAdmin, RoleMember]
            let user = UserView 7 "alice" RoleAdmin 1700000000 Nothing (Just 1700000100)
            decode (encode user) `shouldBe` Just user
        it "round-trips the admin create form and result" $ do
            let input = UserCreateInput "alice" "correct horse battery staple" RoleAdmin
                result = UserCreateResult (UserView 1 "alice" RoleAdmin 1 Nothing Nothing) ["code-1", "code-2"]
            decode (encode input) `shouldBe` Just input
            decode (encode result) `shouldBe` Just result

    describe "token prefixes" $ do
        it "formats and parses session and API tokens" $ do
            let session = withUserPrefix "u" 12 "abcDEF"
                api = withUserPrefix "eza_pat_u" 7 "xyz"
            session `shouldBe` "u12_abcDEF"
            parseSessionUserId session `shouldBe` Just 12
            splitUserPrefix session `shouldBe` Just (12, "abcDEF")
            api `shouldBe` "eza_pat_u7_xyz"
            parseApiTokenUserId api `shouldBe` Just 7
        it "rejects malformed and legacy tokens" $ do
            parseSessionUserId "legacy-token" `shouldBe` Nothing
            parseSessionUserId "u12" `shouldBe` Nothing
            parseSessionUserId "u_abc" `shouldBe` Nothing
            parseSessionUserId "u12_" `shouldBe` Nothing
            parseSessionUserId "u12abc" `shouldBe` Nothing
            parseApiTokenUserId "eza_pat_abc" `shouldBe` Nothing
            parseSessionUserId "u-1_abc" `shouldBe` Nothing
        it "does not confuse API tokens with session tokens" $ do
            parseSessionUserId "eza_pat_u7_xyz" `shouldBe` Nothing

    describe "webhooks" $ do
        it "round-trips the event catalog and envelope" $ do
            mapM_
                (\event -> parseEventType (eventTypeText event) `shouldBe` Just event)
                allEventTypes
            let envelope =
                    EventEnvelope
                        { eeId = "delivery-1"
                        , eeType = BookmarkCreated
                        , eeOccurredAt = 1700000000
                        , eeData = object ["id" .= (1 :: Int)]
                        }
            decode (encode envelope) `shouldBe` Just envelope
        it "validates a subscription" $ do
            let good =
                    WebhookInput
                        { wiName = "backup"
                        , wiUrl = "https://example.test/hook"
                        , wiEvents = [BookmarkCreated, ClipCreated]
                        , wiEnabled = True
                        }
            validateWebhookInput good `shouldBe` Right ()
            validateWebhookInput good{wiUrl = "ftp://example.test/hook"} `shouldSatisfy` isLeft
            validateWebhookInput good{wiEvents = []} `shouldSatisfy` isLeft
            validateWebhookInput good{wiName = ""} `shouldSatisfy` isLeft
        it "encodes a webhook without a secret" $ do
            let webhook =
                    Webhook 1 "backup" "https://example.test/hook" [BookmarkCreated] True 1 Nothing Nothing "" 0
            decode (encode webhook) `shouldBe` Just webhook

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft (Right _) = False
