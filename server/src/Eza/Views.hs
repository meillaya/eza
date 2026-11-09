{-# LANGUAGE OverloadedStrings #-}

{- | Storage for declarative views.

The pure shape, validation, slugs and JSON live in "Eza.View"; this module is
the SQLite side: the shared @views@ table (schema v10), the default seeds, and
create/update/delete with the per-installation cap and default uniqueness.

Default rules:

* every opened database gets one default graph view seeded when it has none
  (@seedDefaultViews@), so a fresh install always has something to open;
* setting @is_default@ on one view clears it on the other views of the same
  kind in the same transaction, matching the partial unique index;
* deleting the current default promotes the lowest-id remaining view of that
  kind, and re-seeds the default graph view when the kind has no views left.
-}
module Eza.Views
    ( ViewError (..)
    , viewErrorStatus
    , viewErrorCode
    , viewErrorMessage
    , ViewPatch (..)
    , seedDefaultViews
    , listViews
    , getView
    , createView
    , updateView
    , deleteView
    ) where

import Control.Monad (when)
import qualified Data.Aeson as Aeson
import Data.Aeson (FromJSON (..), Value, withObject, (.:?))
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple

import Eza.View

-- ------------------------------------------------------------------ errors ---

data ViewError
    = ViewInvalid [Text]
    | ViewNotFound
    | ViewLimit
    deriving (Show, Eq)

viewErrorStatus :: ViewError -> Int
viewErrorStatus err = case err of
    ViewInvalid _ -> 400
    ViewNotFound -> 404
    ViewLimit -> 409

viewErrorCode :: ViewError -> Text
viewErrorCode err = case err of
    ViewInvalid _ -> "bad_request"
    ViewNotFound -> "not_found"
    ViewLimit -> "view_limit"

viewErrorMessage :: ViewError -> Text
viewErrorMessage err = case err of
    ViewInvalid messages -> T.intercalate "; " messages
    ViewNotFound -> "view not found"
    ViewLimit -> "at most " <> T.pack (show maxViewsPerUser) <> " views are allowed"

-- ---------------------------------------------------------------- patches ---

-- | A PATCH body. The definition arrives as a raw value because it can only be
-- decoded once the stored view's kind is known.
data ViewPatch = ViewPatch
    { vpName :: Maybe Text
    , vpSlug :: Maybe Text
    , vpDefinition :: Maybe Value
    , vpIsDefault :: Maybe Bool
    }
    deriving (Show, Eq)

instance FromJSON ViewPatch where
    parseJSON = withObject "ViewPatch" $ \o ->
        ViewPatch
            <$> o .:? "name"
            <*> o .:? "slug"
            <*> o .:? "definition"
            <*> o .:? "is_default"

-- -------------------------------------------------------------------- rows ---

data ViewRow = ViewRow
    { vrId :: Int
    , vrSlug :: Text
    , vrName :: Text
    , vrKind :: Text
    , vrDefinitionJson :: Text
    , vrIsDefault :: Int
    , vrCreatedAt :: Int
    , vrUpdatedAt :: Int
    }

instance FromRow ViewRow where
    fromRow =
        ViewRow
            <$> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field

viewColumns :: Text
viewColumns = "id, slug, name, kind, definition_json, is_default, created_at, updated_at"

viewOfRow :: ViewRow -> Maybe View
viewOfRow row = do
    kind <- parseViewKind (vrKind row)
    value <- either (const Nothing) Just (Aeson.eitherDecodeStrict' (TE.encodeUtf8 (vrDefinitionJson row)))
    definition <- either (const Nothing) Just (decodeViewDefinition kind value)
    pure
        View
            { vId = vrId row
            , vSlug = vrSlug row
            , vName = vrName row
            , vKind = kind
            , vIsDefault = vrIsDefault row /= 0
            , vDefinition = definition
            , vCreatedAt = vrCreatedAt row
            , vUpdatedAt = vrUpdatedAt row
            }

nowEpoch :: IO Int
nowEpoch = floor <$> getPOSIXTime

-- ----------------------------------------------------------------- reading ---

-- | Every view, default first, then graph before ledger, then slug.
listViews :: Connection -> IO [View]
listViews conn = do
    rows <-
        query_
            conn
            (Query ("SELECT " <> viewColumns <> " FROM views ORDER BY is_default DESC, kind ASC, slug ASC")) ::
            IO [ViewRow]
    pure (mapMaybe viewOfRow rows)

getView :: Connection -> Text -> IO (Maybe View)
getView conn slug = do
    rows <-
        query
            conn
            (Query ("SELECT " <> viewColumns <> " FROM views WHERE slug = ?"))
            (Only slug) ::
            IO [ViewRow]
    pure (firstViewOfRow rows)

firstViewOfRow :: [ViewRow] -> Maybe View
firstViewOfRow rows = case rows of
    (row : _) -> viewOfRow row
    [] -> Nothing

-- ----------------------------------------------------------------- seeding ---

-- | Seed the default graph view when the database has no default graph view.
-- Idempotent and safe to call on every open, which is what @Eza.Db.openDb@
-- does after migrating.
seedDefaultViews :: Connection -> IO ()
seedDefaultViews conn =
    withImmediateTransaction conn $ do
        rows <- query_ conn "SELECT COUNT(*) FROM views WHERE kind = 'graph' AND is_default = 1" :: IO [Only Int]
        when (case rows of [Only n] -> n == 0; _ -> True) $ do
            now <- nowEpoch
            slug <- uniqueSlug conn "graph" Nothing
            insertSeed conn slug now

insertSeed :: Connection -> Text -> Int -> IO ()
insertSeed conn slug now =
    execute
        conn
        "INSERT INTO views (slug, name, kind, definition_json, is_default, created_at, updated_at) VALUES (?,?,?,?,1,?,?)"
        ( slug
        , "Graph" :: Text
        , viewKindText GraphKind
        , encodeViewDefinition (GraphDefinition defaultGraphViewDefinition)
        , now
        , now
        )

-- ---------------------------------------------------------------- creating ---

createView :: Connection -> ViewInput -> IO (Either ViewError View)
createView conn input =
    case validateViewDraft input of
        Left messages -> pure (Left (ViewInvalid messages))
        Right () -> do
            count <- countViews conn
            if count >= maxViewsPerUser
                then pure (Left ViewLimit)
                else do
                    now <- nowEpoch
                    slug <- uniqueSlug conn (fromMaybe (slugify (viName input)) (viSlug input)) Nothing
                    execute
                        conn
                        "INSERT INTO views (slug, name, kind, definition_json, is_default, created_at, updated_at) VALUES (?,?,?,?,0,?,?)"
                        ( slug
                        , T.strip (viName input)
                        , viewKindText (viKind input)
                        , encodeViewDefinition (viDefinition input)
                        , now
                        , now
                        )
                    view <- getView conn slug
                    pure $ case view of
                        Just created -> Right created
                        Nothing -> Left ViewNotFound

countViews :: Connection -> IO Int
countViews conn = do
    rows <- query_ conn "SELECT COUNT(*) FROM views" :: IO [Only Int]
    pure (case rows of [Only n] -> n; _ -> 0)

-- | A slug that no other view row uses. The numeric suffix is what makes two
-- views with the same name distinguishable.
uniqueSlug :: Connection -> Text -> Maybe Int -> IO Text
uniqueSlug conn base excludeId = go 1
  where
    clean = if T.null (T.strip base) then "view" else base
    go attempt = do
        let candidate = case attempt of
                (1 :: Int) -> clean
                n -> suffixed n
        taken <- slugTaken candidate
        if taken then go (attempt + 1) else pure candidate
    suffixed n =
        let suffix = "-" <> T.pack (show n)
            room = max 1 (48 - T.length suffix)
         in T.take room clean <> suffix
    slugTaken candidate = do
        rows <-
            query
                conn
                "SELECT 1 FROM views WHERE slug = ? AND id <> ?"
                (candidate, fromMaybe (-1) excludeId) ::
                IO [Only Int]
        pure (not (null rows))

-- ---------------------------------------------------------------- updating ---

updateView :: Connection -> Text -> ViewPatch -> IO (Either ViewError View)
updateView conn slug patch = do
    existing <- getView conn slug
    case existing of
        Nothing -> pure (Left ViewNotFound)
        Just view -> do
            let newName = fromMaybe (vName view) (vpName patch)
            case mergeDefinition view of
                Left err -> pure (Left err)
                Right newDefinition ->
                    case validateViewDraft (ViewInput newName (vKind view) newDefinition (vpSlug patch)) of
                        Left messages -> pure (Left (ViewInvalid messages))
                        Right () -> do
                            newSlug <- case vpSlug patch of
                                Nothing -> pure (vSlug view)
                                Just _ -> uniqueSlug conn (fromMaybe (slugify newName) (vpSlug patch)) (Just (vId view))
                            now <- nowEpoch
                            withImmediateTransaction conn $ do
                                when (vpIsDefault patch == Just True) $
                                    execute
                                        conn
                                        "UPDATE views SET is_default = 0 WHERE kind = ? AND is_default = 1"
                                        (Only (viewKindText (vKind view)))
                                execute
                                    conn
                                    "UPDATE views SET slug = ?, name = ?, definition_json = ?, is_default = ?, updated_at = ? WHERE id = ?"
                                    ( newSlug
                                    , newName
                                    , encodeViewDefinition newDefinition
                                    , fromMaybe (vIsDefault view) (vpIsDefault patch)
                                    , now
                                    , vId view
                                    )
                            updated <- getView conn newSlug
                            pure $ case updated of
                                Just result -> Right result
                                Nothing -> Left ViewNotFound
  where
    mergeDefinition view = case vpDefinition patch of
        Nothing -> Right (vDefinition view)
        Just raw ->
            case decodeViewDefinition (vKind view) raw of
                Right value -> Right value
                Left message -> Left (ViewInvalid ["invalid definition: " <> message])

-- ---------------------------------------------------------------- deleting ---

deleteView :: Connection -> Text -> IO (Either ViewError ())
deleteView conn slug = do
    existing <- getView conn slug
    case existing of
        Nothing -> pure (Left ViewNotFound)
        Just view -> do
            withImmediateTransaction conn $ do
                execute conn "DELETE FROM views WHERE id = ?" (Only (vId view))
                when (vIsDefault view) $ do
                    now <- nowEpoch
                    next <-
                        query
                            conn
                            "SELECT MIN(id) FROM views WHERE kind = ?"
                            (Only (viewKindText (vKind view))) ::
                            IO [Only (Maybe Int)]
                    case next of
                        (Only (Just nextId) : _) ->
                            execute
                                conn
                                "UPDATE views SET is_default = 1, updated_at = ? WHERE id = ?"
                                (now, nextId)
                        _ ->
                            when (vKind view == GraphKind) $ do
                                seededSlug <- uniqueSlug conn "graph" Nothing
                                insertSeed conn seededSlug now
            pure (Right ())
