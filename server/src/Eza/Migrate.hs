{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | One append-only migration engine for every eza SQLite database.

Each database (the per-account library in "Eza.Db" and the control registry in
"Eza.Control") owns a "MigrationPlan": a contiguous list of versions @1..n@ and
the number of versions that were applied before the @schema_meta@ table existed
(@planLegacyVersion@, 15 for the library and 1 for the control database). A
plan is applied version by version inside @BEGIN IMMEDIATE@ ... @COMMIT@, and
every applied version is recorded in:

> schema_meta(version INTEGER PRIMARY KEY, checksum TEXT NOT NULL, applied_at INTEGER NOT NULL)

The checksum is sha256 over the version, the migration name and the canonical
statement list, so editing a shipped migration is detected on the next open
instead of silently producing two different schemas under one version number.
Legacy databases that predate @schema_meta@ are upgraded by the first migration
after @planLegacyVersion@ (v16 for the library, v2 for the control database):
that migration creates the table and the engine backfills checksum rows for the
already-applied legacy versions without re-running them.

The engine is forward only. A database newer than the binary, a missing or
unexpected history row, or a checksum mismatch returns an actionable 'Left'
message that callers surface as their own database error; the unknown newer
version keeps its @PRAGMA user_version@ untouched.
-}
module Eza.Migrate (
    Migration (..),
    MigrationPlan (..),
    SchemaStatus (..),
    schemaMetaStatement,
    migrationChecksum,
    currentVersion,
    latestVersion,
    verifySchema,
    applyMigrations,
) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.List (nub, sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import qualified Database.SQLite.Simple as Sqlite

-- | One append-only schema step. @migrationName@ is only used in diagnostics.
data Migration = Migration
    { migrationVersion :: Int
    , migrationName :: Text
    , migrationStatements :: [Query]
    }
    deriving (Show, Eq)

{- | The full migration history of one database. @planLegacyVersion@ is the
version that existed before @schema_meta@: the next migration creates the table
and the engine records the earlier versions with their checksums. A plan must
contain exactly the versions @[1 .. n]@ and @planLegacyVersion < n@.
-}
data MigrationPlan = MigrationPlan
    { planName :: Text
    , planLegacyVersion :: Int
    , planMigrations :: [Migration]
    }
    deriving (Show, Eq)

-- | What the database says about itself, for the @verify@ command.
data SchemaStatus = SchemaStatus
    { ssVersion :: Int
    , ssExpectedVersion :: Int
    , ssLegacy :: Bool
    }
    deriving (Show, Eq)

-- | The shared metadata table. Migrations that introduce it use this statement.
schemaMetaStatement :: Query
schemaMetaStatement =
    "CREATE TABLE IF NOT EXISTS schema_meta ( version INTEGER PRIMARY KEY, checksum TEXT NOT NULL, applied_at INTEGER NOT NULL )"

-- | sha256 over the version, name and canonical statement list of a migration.
migrationChecksum :: Migration -> Text
migrationChecksum migration =
    T.pack
        ( show
            ( hash
                ( TE.encodeUtf8
                    ( T.pack (show (migrationVersion migration))
                        <> "\n"
                        <> migrationName migration
                        <> "\n"
                        <> T.intercalate "\n" (map queryText (migrationStatements migration))
                    )
                ) ::
                Digest SHA256
            )
        )

-- | @PRAGMA user_version@; the version of the last committed migration.
currentVersion :: Connection -> IO Int
currentVersion conn = do
    rows <- query_ conn "PRAGMA user_version" :: IO [Only Int]
    pure (case rows of [Only version] -> version; _ -> 0)

{- | Validate that a plan is append-only and return its target version. A
version is applied by appending to the end: reordering, removing, or editing a
shipped migration is a hard error rather than a silent divergence.
-}
latestVersion :: MigrationPlan -> Either Text Int
latestVersion plan
    | versions /= expected =
        Left
            ( "the "
                <> planName plan
                <> " migration plan is not append-only: expected versions "
                <> renderVersions expected
                <> " but the plan has "
                <> renderVersions versions
            )
    | planLegacyVersion plan < 0 || planLegacyVersion plan >= target =
        Left
            ( "the "
                <> planName plan
                <> " migration plan has an invalid legacy version "
                <> T.pack (show (planLegacyVersion plan))
                <> " for target "
                <> T.pack (show target)
            )
    | otherwise = Right target
  where
    versions = map migrationVersion (planMigrations plan)
    target = length versions
    expected = [1 .. target]

{- | Read the database's schema identity and refuse anything that does not match
the plan: newer version, edited migration, missing history rows, or a legacy
database that already passed the schema_meta version. Total in the sense that
every failure is an actionable message, never an exception.
-}
verifySchema :: Connection -> MigrationPlan -> IO (Either Text SchemaStatus)
verifySchema conn plan =
    case latestVersion plan of
        Left message -> pure (Left message)
        Right target -> do
            version <- currentVersion conn
            hasMeta <- metaTableExists conn
            if version > target
                then pure (Left (newerMessage plan version target))
                else
                    if not hasMeta
                        then pure (verifyLegacy target version)
                        else verifyRecorded version
  where
    verifyLegacy target version
        | version < 0 = Left "the schema version is negative; restore the pre-migration backup"
        | version > planLegacyVersion plan =
            Left
                ( "the "
                    <> planName plan
                    <> " schema is at v"
                    <> T.pack (show version)
                    <> " but has no schema_meta table (v"
                    <> T.pack (show (planLegacyVersion plan + 1))
                    <> " creates it); restore the matching pre-migration backup"
                )
        | otherwise = Right (SchemaStatus version target True)
    verifyRecorded version = do
        rows <- metaRows conn
        let recorded = map fst rows
            expectedChecksums =
                [ (migrationVersion migration, migrationChecksum migration)
                | migration <- planMigrations plan
                , migrationVersion migration <= version
                ]
            checksumMismatch =
                [ version'
                | (version', checksum) <- expectedChecksums
                , lookup version' rows /= Just checksum
                ]
            identityMismatch = recorded /= [1 .. version]
        if null rows && version > 0
            then
                pure
                    ( Left
                        ( "the "
                            <> planName plan
                            <> " schema_meta table is empty but user_version is v"
                            <> T.pack (show version)
                            <> "; restore the matching pre-migration backup"
                        )
                    )
            else
                if identityMismatch
                    then
                        pure
                            ( Left
                                ( "the "
                                    <> planName plan
                                    <> " schema history does not match user_version v"
                                    <> T.pack (show version)
                                    <> " (schema_meta records v"
                                    <> renderVersions recorded
                                    <> "); restore the matching pre-migration backup"
                                )
                            )
                    else case checksumMismatch of
                        (badVersion : _) ->
                            pure
                                ( Left
                                    ( "the "
                                        <> planName plan
                                        <> " migration v"
                                        <> T.pack (show badVersion)
                                        <> " ("
                                        <> migrationNameFor plan badVersion
                                        <> ") checksum does not match: this binary's migration list differs from the one that created the database. Deploy the matching eza release or restore the pre-migration backup."
                                    )
                                )
                        [] -> pure (Right (SchemaStatus version version False))

{- | Verify the database, then apply every missing migration. Each migration
(its statements, its @schema_meta@ hash rows, and @PRAGMA user_version@) is one
@BEGIN IMMEDIATE@ transaction, so a failed statement leaves the previous
version intact. The first update after @planLegacyVersion@ creates
@schema_meta@ and backfills the legacy versions' checksums without re-running
them.
-}
applyMigrations :: Connection -> MigrationPlan -> IO (Either Text SchemaStatus)
applyMigrations conn plan = do
    verified <- verifySchema conn plan
    case verified of
        Left message -> pure (Left message)
        Right status -> applyPending (drop (ssVersion status) (planMigrations plan))
  where
    applyPending [] = verifySchema conn plan
    applyPending (migration : rest) = do
        outcome <- try (applyOne migration) :: IO (Either SomeException ())
        case outcome of
            Left err ->
                pure
                    ( Left
                        ( "the "
                            <> planName plan
                            <> " migration to schema v"
                            <> T.pack (show (migrationVersion migration))
                            <> " failed and was rolled back: "
                            <> T.take 400 (T.pack (show err))
                        )
                    )
            Right () -> applyPending rest

    applyOne migration =
        withImmediateTransaction conn $ do
            mapM_ (Sqlite.execute_ conn) (migrationStatements migration)
            hasMeta <- metaTableExists conn
            when hasMeta $ do
                rows <- metaRows conn
                now <- timestamp
                when (null rows) $
                    forM_ [1 .. planLegacyVersion plan] $ \version ->
                        case migrationForVersion plan version of
                            Nothing -> ioError (userError ("the migration plan is missing v" <> show version))
                            Just expected ->
                                Sqlite.execute
                                    conn
                                    insertMeta
                                    (version, migrationChecksum expected, now)
                Sqlite.execute
                    conn
                    insertMeta
                    (migrationVersion migration, migrationChecksum migration, now)
            Sqlite.execute_ conn (Query ("PRAGMA user_version = " <> T.pack (show (migrationVersion migration))))

-- --------------------------------------------------------------- internals ---

insertMeta :: Query
insertMeta = "INSERT INTO schema_meta (version, checksum, applied_at) VALUES (?,?,?)"

metaTableExists :: Connection -> IO Bool
metaTableExists conn = do
    rows <-
        query
            conn
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'schema_meta'"
            () ::
            IO [Only Int]
    pure (not (null rows))

metaRows :: Connection -> IO [(Int, Text)]
metaRows conn =
    query_ conn "SELECT version, checksum FROM schema_meta ORDER BY version ASC"

migrationForVersion :: MigrationPlan -> Int -> Maybe Migration
migrationForVersion plan version =
    case [migration | migration <- planMigrations plan, migrationVersion migration == version] of
        (migration : _) -> Just migration
        [] -> Nothing

migrationNameFor :: MigrationPlan -> Int -> Text
migrationNameFor plan version = maybe "" migrationName (migrationForVersion plan version)

newerMessage :: MigrationPlan -> Int -> Int -> Text
newerMessage plan version target =
    "the "
        <> planName plan
        <> " schema is newer than this binary (v"
        <> T.pack (show version)
        <> " > v"
        <> T.pack (show target)
        <> "); use the matching eza release instead of opening this database"

timestamp :: IO Int
timestamp = floor <$> getPOSIXTime

renderVersions :: [Int] -> Text
renderVersions versions
    | null versions = "none"
    | otherwise = T.intercalate ", " (map (("v" <>) . T.pack . show) (sort (nub versions)))

queryText :: Query -> Text
queryText (Query text) = text
