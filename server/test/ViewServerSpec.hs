{-# LANGUAGE OverloadedStrings #-}

{- | Server tests for the declarative views stored in schema v10, the default
seed, the boot payload, and the v9 to v10 migration.

The pure validation and JSON live in "Eza.View" and are covered by
"CoreViewSpec"; this module exercises the SQLite side and the HTTP-free boot
assembly.
-}
module ViewServerSpec (spec) where

import Control.Exception (bracket)
import Data.Aeson (Value (..), decode, encode, toJSON)
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Foldable (toList)
import Data.Text (Text)
import qualified Data.Text as T
import Database.SQLite.Simple (Only (..), close)
import qualified Database.SQLite.Simple as Sqlite
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Eza.Version (ezaVersionText)
import Eza.Boot (BootPayload (..))
import Eza.Db
import Eza.Server (bootPayloadFor)
import Eza.View
import Eza.Views

spec :: Spec
spec = do
    describe "views migration v10" $ do
        it "migrates a v9 database to v10, keeps its rows and seeds the default view" $
            withSystemTempDirectory "eza-views-migrate" $ \dir -> do
                let path = dir </> "test.db"
                bracket (Sqlite.open path) Sqlite.close $ \conn -> do
                    mapM_
                        (Sqlite.execute_ conn)
                        ( schemaV1
                            <> schemaV2
                            <> schemaV3
                            <> schemaV4
                            <> schemaV5
                            <> schemaV6
                            <> schemaV7
                            <> schemaV8
                            <> schemaV9
                        )
                    Sqlite.execute_ conn "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES ('https://example.test/v9','V9','example.test',1,1,1)"
                    Sqlite.execute_ conn "INSERT INTO tags (name,created_at) VALUES ('kept',1)"
                    Sqlite.execute_ conn "INSERT INTO bookmark_tags (bookmark_id,tag_id) VALUES (1,1)"
                    Sqlite.execute_ conn "PRAGMA user_version = 9"
                migrated <- openDb path
                version <- schemaVersion migrated
                version `shouldBe` targetSchemaVersion
                version `shouldBe` targetSchemaVersion
                books <- queryScalar migrated "SELECT COUNT(*) FROM bookmarks"
                books `shouldBe` 1
                tags <- queryScalar migrated "SELECT COUNT(*) FROM tags"
                tags `shouldBe` 1
                links <- queryScalar migrated "SELECT COUNT(*) FROM bookmark_tags"
                links `shouldBe` 1
                indexes <-
                    Sqlite.query_
                        migrated
                        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'views'" ::
                        IO [Only Text]
                let indexNames = [name | Only name <- indexes]
                indexNames `shouldSatisfy` any (T.isInfixOf "views_one_default")
                views <- listViews migrated
                length views `shouldBe` 1
                case views of
                    (view : _) -> do
                        vSlug view `shouldBe` "graph"
                        vKind view `shouldBe` GraphKind
                        vIsDefault view `shouldBe` True
                        vDefinition view `shouldBe` GraphDefinition defaultGraphViewDefinition
                    [] -> expectationFailure "the migrated database should seed a default graph view"
                close migrated

        it "seeds the default graph view only once across opens" $
            withSystemTempDirectory "eza-views-seed" $ \dir -> do
                let path = dir </> "test.db"
                first <- openDb path
                length <$> listViews first `shouldReturn` 1
                close first
                second <- openDb path
                views <- listViews second
                length views `shouldBe` 1
                case views of
                    (view : _) -> vSlug view `shouldBe` "graph"
                    [] -> expectationFailure "expected the seeded graph view"
                close second

    describe "view CRUD" $ do
        it "creates, reads, updates, defaults and deletes views" $
            withSystemTempDirectory "eza-views-crud" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                notes <- rightOrFail "create rust notes" =<< createView conn (graphView "Rust notes")
                vSlug notes `shouldBe` "rust-notes"
                vName notes `shouldBe` "Rust notes"
                vKind notes `shouldBe` GraphKind
                vIsDefault notes `shouldBe` False
                sameName <- rightOrFail "create a duplicate name" =<< createView conn (graphView "Rust notes")
                vSlug sameName `shouldBe` "rust-notes-2"
                found <- getView conn "rust-notes"
                fmap vId found `shouldBe` Just (vId notes)
                getView conn "no-such-view" `shouldReturn` Nothing
                -- The seeded graph view owns the default slot; pointing the new
                -- view at it must take the flag over.
                updated <- rightOrFail "update rust notes" =<< updateView conn "rust-notes" (ViewPatch (Just "Rust map") Nothing Nothing (Just True))
                vName updated `shouldBe` "Rust map"
                vIsDefault updated `shouldBe` True
                views <- listViews conn
                length (filter vIsDefault views) `shouldBe` 1
                map vKind (filter vIsDefault views) `shouldBe` [GraphKind]
                deleteView conn "rust-notes" `shouldReturn` Right ()
                getView conn "rust-notes" `shouldReturn` Nothing
                close conn

        it "promotes a remaining view when the default is deleted and re-seeds an empty kind" $
            withSystemTempDirectory "eza-views-delete-default" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                seeded <- listViews conn
                case seeded of
                    (defaultView : _) -> do
                        other <- rightOrFail "create other graph view" =<< createView conn (graphView "Second map")
                        _ <- rightOrFail "make other default" =<< updateView conn (vSlug other) (ViewPatch Nothing Nothing Nothing (Just True))
                        -- Deleting the current default promotes the remaining view.
                        deleteView conn (vSlug other) `shouldReturn` Right ()
                        views <- listViews conn
                        case filter vIsDefault views of
                            (promoted : _) -> vSlug promoted `shouldBe` vSlug defaultView
                            [] -> expectationFailure "expected the previous view to be promoted"
                        -- Deleting the last graph view re-seeds a default one.
                        deleteView conn (vSlug defaultView) `shouldReturn` Right ()
                        reseeded <- listViews conn
                        length reseeded `shouldBe` 1
                        case reseeded of
                            (view : _) -> do
                                vKind view `shouldBe` GraphKind
                                vIsDefault view `shouldBe` True
                                vSlug view `shouldBe` "graph"
                            [] -> expectationFailure "expected a re-seeded default graph view"
                    [] -> expectationFailure "expected the seeded default view"
                close conn

    describe "view validation and limits" $ do
        it "rejects invalid names, definitions, slugs and missing views" $
            withSystemTempDirectory "eza-views-invalid" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                blankName <- createView conn (ViewInput "  " GraphKind (GraphDefinition defaultGraphViewDefinition) Nothing)
                blankName `shouldSatisfy` isInvalid
                linkQuery <-
                    createView
                        conn
                        (ViewInput "Link view" GraphKind (GraphDefinition defaultGraphViewDefinition{gvdQuery = "link:target"}) Nothing)
                linkQuery `shouldSatisfy` isInvalid
                deep <- createView conn (ViewInput "Deep" GraphKind (GraphDefinition defaultGraphViewDefinition{gvdLocalDepth = Just 4}) Nothing)
                deep `shouldSatisfy` isInvalid
                badSlug <-
                    createView
                        conn
                        (ViewInput "Bad slug" GraphKind (GraphDefinition defaultGraphViewDefinition) (Just "Bad Slug"))
                badSlug `shouldSatisfy` isInvalid
                blankRename <- updateView conn "graph" (ViewPatch (Just "") Nothing Nothing Nothing)
                blankRename `shouldSatisfy` isInvalid
                updateView conn "no-such-view" (ViewPatch (Just "Name") Nothing Nothing Nothing)
                    `shouldReturn` Left ViewNotFound
                deleteView conn "no-such-view" `shouldReturn` Left ViewNotFound
                close conn

        it "caps the number of views" $
            withSystemTempDirectory "eza-views-limit" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                existing <- length <$> listViews conn
                let needed = maxViewsPerUser - existing
                created <-
                    mapM
                        (\index -> createView conn (graphView (T.pack ("Map " <> show (index :: Int)))))
                        [1 .. needed]
                mapM_ (`shouldSatisfy` isCreated) created
                createView conn (graphView "One too many") `shouldReturn` Left ViewLimit
                close conn

    describe "boot payload" $ do
        it "carries the views with the full view objects" $
            withSystemTempDirectory "eza-views-boot" $ \dir -> do
                conn <- openDb (dir </> "test.db")
                payload <- bootPayloadFor "http://localhost:8080" conn
                bpVersion payload `shouldBe` ezaVersionText
                bpOrigin payload `shouldBe` "http://localhost:8080"
                map vSlug (bpViews payload) `shouldBe` ["graph"]
                (decode (encode payload) :: Maybe BootPayload) `shouldBe` Just payload
                case toJSON payload of
                    Object objectValue -> do
                        KeyMap.lookup "version" objectValue `shouldBe` Just (String ezaVersionText)
                        KeyMap.lookup "origin" objectValue `shouldBe` Just (String "http://localhost:8080")
                        mapM_
                            (\key -> KeyMap.member key objectValue `shouldBe` True)
                            ["tags", "saved_searches", "initial", "stats", "views"]
                        case KeyMap.lookup "views" objectValue of
                            Just (Array viewsValue) -> case toList viewsValue of
                                [viewValue] -> case viewValue of
                                    Object viewObject -> do
                                        KeyMap.lookup "schema" viewObject `shouldBe` Just (Number 1)
                                        KeyMap.lookup "slug" viewObject `shouldBe` Just (String "graph")
                                        KeyMap.lookup "is_default" viewObject `shouldBe` Just (Bool True)
                                        case KeyMap.lookup "definition" viewObject of
                                            Just (Object definitionObject) -> do
                                                -- The wrapper carries the schema; the
                                                -- definition itself does not.
                                                KeyMap.member "schema" definitionObject `shouldBe` False
                                                KeyMap.lookup "layout_preset" definitionObject `shouldBe` Just (String "standard")
                                            _ -> expectationFailure "a view definition must be an object"
                                    _ -> expectationFailure "a view must be an object"
                                _ -> expectationFailure "expected exactly one seeded view"
                            _ -> expectationFailure "the boot document must carry a views array"
                    _ -> expectationFailure "the boot document must be a JSON object"
                close conn

graphView :: Text -> ViewInput
graphView name = ViewInput name GraphKind (GraphDefinition defaultGraphViewDefinition) Nothing

isInvalid :: Either ViewError View -> Bool
isInvalid (Left (ViewInvalid _)) = True
isInvalid _ = False

isCreated :: Either ViewError View -> Bool
isCreated (Right _) = True
isCreated _ = False

rightOrFail :: String -> Either ViewError View -> IO View
rightOrFail label result = case result of
    Right view -> pure view
    Left err -> expectationFailure (label <> " failed: " <> show err) >> error "unreachable"
