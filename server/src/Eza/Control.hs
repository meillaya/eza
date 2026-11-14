{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The control database: accounts and the mapping to their library database.

One eza process serves many users. The control database holds identity only
(username, role, database path, WebAuthn handle, timestamps). Credentials,
sessions, API tokens, views, webhooks, and all library rows stay in each
user's own SQLite database. See "Eza.Auth" for the credential side and
"Eza.Server" for the per-request resolution.

Schema v1:
@
users(id, username UNIQUE COLLATE NOCASE, db_path UNIQUE,
      role CHECK(admin|member), credential_handle BLOB,
      created_at, disabled_at, last_login_at)
@
-}
module Eza.Control (
    ControlUser (..),
    UserRole (..),
    userRoleText,
    parseUserRole,
    ControlError (..),
    ControlWriteResult (..),
    openControlDb,
    initControlDb,
    controlSchemaVersion,
    controlMigrationPlan,
    checkControlSchema,
    userColumns,
    listUsers,
    lookupUserByUsername,
    lookupUserById,
    countUsers,
    countEnabledUsers,
    countEnabledAdmins,
    createUser,
    setUserDisabled,
    setUserDisabledGuarded,
    setUserLastLogin,
    setUserRole,
    setUserRoleGuarded,
    setUsername,
    updateUserDbPath,
    deleteUserRow,
    setUserCredentialHandle,
    ensureCredentialHandle,
) where

import Control.Exception (SomeException, try)

import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

import qualified Eza.Migrate as Migrate
import Eza.User (UserRole (..), parseUserRole, userRoleText)

-- -------------------------------------------------------------------- types ---

{- | Outcome of a guarded account change. The last-enabled-admin rules are
enforced by the same conditional UPDATE that writes the row, so an invariant
check and its write cannot interleave with another process's write the way a
separate count-then-update can.
-}
data ControlWriteResult
    = ControlWriteOk
    | ControlWriteMissing
    | ControlWriteLastAdmin
    deriving (Show, Eq)

data ControlUser = ControlUser
    { cuId :: Int
    , cuUsername :: Text
    , cuDbPath :: FilePath
    , cuRole :: UserRole
    , cuCredentialHandle :: Maybe ByteString
    , cuCreatedAt :: Int
    , cuDisabledAt :: Maybe Int
    , cuLastLoginAt :: Maybe Int
    }
    deriving (Show, Eq)

data ControlError
    = ControlDuplicateUsername
    | ControlDuplicateDbPath
    | ControlUserNotFound
    | ControlDatabaseError Text
    deriving (Show, Eq)

-- ------------------------------------------------------------------- open ---

{- | Open (and create or migrate) the control database. The parent directory
is created when missing; a database newer than this binary is refused.
-}
openControlDb :: FilePath -> IO Connection
openControlDb path = do
    createDirectoryIfMissing True (takeDirectory path)
    conn <- open path
    mapM_ (execute_ conn) pragmas
    migrate conn
    pure conn

initControlDb :: FilePath -> IO ()
initControlDb path = openControlDb path >> pure ()

controlSchemaVersion :: Int
controlSchemaVersion = 2

pragmas :: [Query]
pragmas =
    [ "PRAGMA journal_mode = WAL"
    , "PRAGMA synchronous = NORMAL"
    , "PRAGMA foreign_keys = ON"
    , "PRAGMA busy_timeout = 5000"
    , "PRAGMA temp_store = MEMORY"
    ]

migrate :: Connection -> IO ()
migrate conn = do
    result <- Migrate.applyMigrations conn controlMigrationPlan
    case result of
        Left message -> ioError (userError (T.unpack message))
        Right _ -> pure ()

{- | The control schema history, append-only. Existing installs are stamped v1
without @schema_meta@; v2 creates the shared metadata table and the engine
backfills v1's checksum without re-running it.
-}
controlMigrationPlan :: Migrate.MigrationPlan
controlMigrationPlan =
    Migrate.MigrationPlan
        { Migrate.planName = "control database"
        , Migrate.planLegacyVersion = 1
        , Migrate.planMigrations =
            [ Migrate.Migration 1 "accounts" schemaV1
            , Migrate.Migration 2 "schema metadata" [Migrate.schemaMetaStatement]
            ]
        }

-- | The control schema state for the @verify@ command; never applies anything.
checkControlSchema :: Connection -> IO (Either Text Migrate.SchemaStatus)
checkControlSchema conn = Migrate.verifySchema conn controlMigrationPlan

schemaV1 :: [Query]
schemaV1 =
    [ "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL UNIQUE COLLATE NOCASE, db_path TEXT NOT NULL UNIQUE, role TEXT NOT NULL DEFAULT 'member' CHECK(role IN ('admin','member')), credential_handle BLOB, created_at INTEGER NOT NULL, disabled_at INTEGER, last_login_at INTEGER)"
    , "CREATE INDEX IF NOT EXISTS idx_control_users_enabled ON users(disabled_at)"
    ]

-- ----------------------------------------------------------------- reading ---

userColumns :: Text
userColumns = "id, username, db_path, role, credential_handle, created_at, disabled_at, last_login_at"

instance FromRow ControlUser where
    fromRow = do
        userId <- field
        username <- field
        dbPath <- field
        roleText <- field
        handle <- field
        createdAt <- field
        disabledAt <- field
        lastLoginAt <- field
        -- The table's CHECK constraint admits only admin and member. A value
        -- outside it means a corrupted control database, so fail closed as a
        -- member rather than granting admin by accident.
        let role = fromMaybe RoleMember (parseUserRole roleText)
        pure (ControlUser userId username dbPath role handle createdAt disabledAt lastLoginAt)

listUsers :: Connection -> IO [ControlUser]
listUsers conn =
    query_
        conn
        (Query ("SELECT " <> userColumns <> " FROM users ORDER BY id ASC"))

lookupUserByUsername :: Connection -> Text -> IO (Maybe ControlUser)
lookupUserByUsername conn username = do
    rows <-
        query
            conn
            (Query ("SELECT " <> userColumns <> " FROM users WHERE username = ? COLLATE NOCASE"))
            (Only username)
    pure (firstRow rows)

lookupUserById :: Connection -> Int -> IO (Maybe ControlUser)
lookupUserById conn userId = do
    rows <-
        query
            conn
            (Query ("SELECT " <> userColumns <> " FROM users WHERE id = ?"))
            (Only userId)
    pure (firstRow rows)

firstRow :: [ControlUser] -> Maybe ControlUser
firstRow rows = case rows of
    (user : _) -> Just user
    [] -> Nothing

countUsers :: Connection -> IO Int
countUsers conn = scalarInt conn "SELECT COUNT(*) FROM users"

countEnabledUsers :: Connection -> IO Int
countEnabledUsers conn = scalarInt conn "SELECT COUNT(*) FROM users WHERE disabled_at IS NULL"

countEnabledAdmins :: Connection -> IO Int
countEnabledAdmins conn =
    scalarInt conn "SELECT COUNT(*) FROM users WHERE disabled_at IS NULL AND role = 'admin'"

scalarInt :: Connection -> Query -> IO Int
scalarInt conn q = do
    rows <- query_ conn q :: IO [Only Int]
    pure (case rows of [Only n] -> n; _ -> 0)

-- ----------------------------------------------------------------- writing ---

epoch :: IO Int
epoch = round <$> getPOSIXTime

{- | Insert an account row with a freshly generated WebAuthn user handle when
the caller does not provide one. The caller allocates and migrates the user
database before or after this insert; the control row is the registry.
-}
createUser :: Connection -> Text -> FilePath -> UserRole -> Maybe ByteString -> IO (Either ControlError ControlUser)
createUser conn username dbPath role suppliedHandle = do
    usernameTaken <- lookupUserByUsername conn username
    pathTaken <-
        query
            conn
            "SELECT 1 FROM users WHERE db_path = ?"
            (Only dbPath) ::
            IO [Only Int]
    case (usernameTaken, null pathTaken) of
        (Just _, _) -> pure (Left ControlDuplicateUsername)
        (_, False) -> pure (Left ControlDuplicateDbPath)
        _ -> do
            handle <- case suppliedHandle of
                Just value -> pure value
                Nothing -> getRandomBytes 16
            now <- epoch
            result <-
                try $
                    withImmediateTransaction conn $
                        execute
                            conn
                            "INSERT INTO users (username, db_path, role, credential_handle, created_at) VALUES (?,?,?,?,?)"
                            (username, dbPath, userRoleText role, handle, now)
            case result of
                Left (err :: SomeException) -> pure (Left (ControlDatabaseError (T.pack (show err))))
                Right () -> do
                    createdId <- fromIntegral <$> lastInsertRowId conn
                    user <- lookupUserById conn createdId
                    pure $ case user of
                        Just value -> Right value
                        Nothing -> Left (ControlDatabaseError "inserted user could not be read back")

setUserDisabled :: Connection -> Int -> Bool -> IO Bool
setUserDisabled conn userId disabled = do
    now <- epoch
    withImmediateTransaction conn $ do
        execute
            conn
            "UPDATE users SET disabled_at = ? WHERE id = ?"
            (if disabled then Just now else Nothing :: Maybe Int, userId)
        changed <- changes conn
        pure (changed > 0)

{- | Change an account's role. The last enabled admin rule lives in
"Eza.Admin"; this is only the row write.
-}
setUserRole :: Connection -> Int -> UserRole -> IO Bool
setUserRole conn userId role = do
    withImmediateTransaction conn $ do
        execute conn "UPDATE users SET role = ? WHERE id = ?" (userRoleText role, userId)
        changed <- changes conn
        pure (changed > 0)

{- | Enable or disable an account with the last-enabled-admin rule enforced by
the same UPDATE. Returns 'ControlWriteLastAdmin' when the write was refused
because it would leave no enabled admin, and 'ControlWriteMissing' when the id
does not exist. Safe to call from the CLI and the server at the same time: the
count is part of the statement, not a preceding read.
-}
setUserDisabledGuarded :: Connection -> Int -> Bool -> IO ControlWriteResult
setUserDisabledGuarded conn userId disabled = do
    if disabled
        then do
            now <- epoch
            withImmediateTransaction conn $ do
                execute
                    conn
                    "UPDATE users SET disabled_at = ? WHERE id = ? AND (disabled_at IS NOT NULL OR role <> 'admin' OR (SELECT COUNT(*) FROM users WHERE disabled_at IS NULL AND role = 'admin') > 1)"
                    (Just now :: Maybe Int, userId)
                result <- changes conn
                if result > 0 then pure ControlWriteOk else classify conn userId
        else withImmediateTransaction conn $ do
            execute conn "UPDATE users SET disabled_at = NULL WHERE id = ?" (Only userId)
            result <- changes conn
            pure (if result > 0 then ControlWriteOk else ControlWriteMissing)

{- | Change an account's role with the last-enabled-admin rule enforced in the
same UPDATE. Promoting is always allowed; demoting or renaming the role of the
last enabled admin is refused.
-}
setUserRoleGuarded :: Connection -> Int -> UserRole -> IO ControlWriteResult
setUserRoleGuarded conn userId role =
    withImmediateTransaction conn $ do
        execute
            conn
            "UPDATE users SET role = ? WHERE id = ? AND (role = ? OR role <> 'admin' OR ? <> 'member' OR disabled_at IS NOT NULL OR (SELECT COUNT(*) FROM users WHERE disabled_at IS NULL AND role = 'admin') > 1)"
            (userRoleText role, userId, userRoleText role, userRoleText role)
        result <- changes conn
        if result > 0 then pure ControlWriteOk else classify conn userId

-- | Why a guarded account write changed no row.
classify :: Connection -> Int -> IO ControlWriteResult
classify conn userId = do
    found <- lookupUserById conn userId
    pure $ case found of
        Nothing -> ControlWriteMissing
        Just user
            | cuRole user == RoleAdmin && isNothing (cuDisabledAt user) -> ControlWriteLastAdmin
            | otherwise -> ControlWriteMissing

setUserLastLogin :: Connection -> Int -> IO ()
setUserLastLogin conn userId = do
    now <- epoch
    withImmediateTransaction conn $
        execute conn "UPDATE users SET last_login_at = ? WHERE id = ?" (now, userId)

{- | Rename an account. The control row is the login lookup source, so the
password setup after a recovery must keep it in step with the user database
account name. Rejects a name another account already owns.
-}
setUsername :: Connection -> Int -> Text -> IO (Either ControlError ())
setUsername conn userId username = do
    taken <- lookupUserByUsername conn username
    case taken of
        Just other | cuId other /= userId -> pure (Left ControlDuplicateUsername)
        _ -> do
            withImmediateTransaction conn $
                execute conn "UPDATE users SET username = ? WHERE id = ?" (username, userId)
            pure (Right ())

updateUserDbPath :: Connection -> Int -> FilePath -> IO Bool
updateUserDbPath conn userId dbPath = do
    withImmediateTransaction conn $ do
        execute conn "UPDATE users SET db_path = ? WHERE id = ?" (dbPath, userId)
        changed <- changes conn
        pure (changed > 0)

{- | Store the per-user WebAuthn user handle. New passkeys are registered with
it; existing credentials keep working because assertions match the
credential id, not the handle.
-}
setUserCredentialHandle :: Connection -> Int -> ByteString -> IO ()
setUserCredentialHandle conn userId handle =
    execute conn "UPDATE users SET credential_handle = ? WHERE id = ?" (handle, userId)

{- | Return the user with a handle, generating and storing one when the row has
none yet (legacy rows registered before handles were per-user).
-}
ensureCredentialHandle :: Connection -> ControlUser -> IO ControlUser
ensureCredentialHandle conn user = case cuCredentialHandle user of
    Just _ -> pure user
    Nothing -> do
        handle <- getRandomBytes 16
        setUserCredentialHandle conn (cuId user) handle
        pure user{cuCredentialHandle = Just handle}

deleteUserRow :: Connection -> Int -> IO Bool
deleteUserRow conn userId = do
    withImmediateTransaction conn $ do
        execute conn "DELETE FROM users WHERE id = ?" (Only userId)
        changed <- changes conn
        pure (changed > 0)
