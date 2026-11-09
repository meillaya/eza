{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Account operations shared by the CLI (@eza-bookmarks users ...@), the
admin JSON API, and the server's first-setup path.

The control database is identity; each account's own SQLite library holds the
credentials and content. Everything here works through the control row, so a
caller never supplies a database path: the path is allocated, recorded, and
only then opened.
-}
module Eza.Admin (
    AdminError (..),
    adminErrorStatus,
    adminErrorCode,
    adminErrorMessage,
    UserSummary (..),
    controlUserView,
    listUserSummaries,
    createUserAccount,
    setUserEnabled,
    setUserRole,
    resetUserPassword,
    deleteUserAccount,
    missingUserDatabases,
    userLimitWarning,
    resolveSelector,
    resolveLibraryPath,
    resolveLibraryTarget,
    userDir,
    userSnapshotDir,
    userDbPathFor,
) where

import Control.Exception (SomeException, try)
import Control.Monad (filterM, forM, forM_, void, when)
import Crypto.Random (getRandomBytes)
import qualified Data.ByteString.Base64.URL as B64
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Database.SQLite.Simple (Connection)
import qualified Database.SQLite.Simple as Sqlite
import System.Directory (doesDirectoryExist, doesFileExist, getFileSize, listDirectory, removeDirectoryRecursive, removeFile)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)

import qualified Eza.Auth as Auth
import Eza.Config (Config (..))
import Eza.Control (ControlError (..), ControlUser (..))
import qualified Eza.Control as Control
import qualified Eza.Db as Db
import qualified Eza.Password as Password
import Eza.User (UserRole (..), UserView (..))

-- ------------------------------------------------------------------ errors ---

data AdminError
    = AdminInvalidUsername Text
    | AdminWeakPassword Text
    | AdminUsernameTaken
    | AdminNotFound
    | AdminLastAdmin
    | AdminSelfDisable
    | AdminUserLimit
    | AdminInternal Text
    deriving (Show, Eq)

adminErrorStatus :: AdminError -> Int
adminErrorStatus err = case err of
    AdminInvalidUsername _ -> 400
    AdminWeakPassword _ -> 400
    AdminUsernameTaken -> 409
    AdminNotFound -> 404
    AdminLastAdmin -> 409
    AdminSelfDisable -> 409
    AdminUserLimit -> 409
    AdminInternal _ -> 500

adminErrorCode :: AdminError -> Text
adminErrorCode err = case err of
    AdminInvalidUsername _ -> "invalid_username"
    AdminWeakPassword _ -> "weak_password"
    AdminUsernameTaken -> "username_taken"
    AdminNotFound -> "user_not_found"
    AdminLastAdmin -> "last_admin"
    AdminSelfDisable -> "self_disable"
    AdminUserLimit -> "user_limit"
    AdminInternal _ -> "internal"

adminErrorMessage :: AdminError -> Text
adminErrorMessage err = case err of
    AdminInvalidUsername message -> message
    AdminWeakPassword message -> message
    AdminUsernameTaken -> "that username is already in use"
    AdminNotFound -> "no such account"
    AdminLastAdmin -> "the last enabled admin cannot be disabled, demoted, or deleted"
    AdminSelfDisable -> "an admin cannot disable their own account"
    AdminUserLimit -> "the account limit (EZA_MAX_USERS) has been reached"
    AdminInternal message -> message

-- --------------------------------------------------------------- summaries ---

{- | One account as @users list@ shows it. The size figures are informational;
the CLI never prints another user's credentials.
-}
data UserSummary = UserSummary
    { usmId :: Int
    , usmUsername :: Text
    , usmRole :: UserRole
    , usmEnabled :: Bool
    , usmDbPath :: FilePath
    , usmDbBytes :: Integer
    , usmSnapshotCount :: Int
    , usmCreatedAt :: Int
    , usmLastLoginAt :: Maybe Int
    }

controlUserView :: ControlUser -> UserView
controlUserView user =
    UserView
        { uvId = cuId user
        , uvUsername = cuUsername user
        , uvRole = cuRole user
        , uvCreatedAt = cuCreatedAt user
        , uvDisabledAt = cuDisabledAt user
        , uvLastLoginAt = cuLastLoginAt user
        }

listUserSummaries :: Config -> Connection -> IO [UserSummary]
listUserSummaries cfg control = do
    users <- Control.listUsers control
    forM users $ \user -> do
        size <- dbBytes (cuDbPath user)
        snapshots <- snapshotCount (userSnapshotDir cfg (cuId user))
        pure
            UserSummary
                { usmId = cuId user
                , usmUsername = cuUsername user
                , usmRole = cuRole user
                , usmEnabled = isNothing (cuDisabledAt user)
                , usmDbPath = cuDbPath user
                , usmDbBytes = size
                , usmSnapshotCount = snapshots
                , usmCreatedAt = cuCreatedAt user
                , usmLastLoginAt = cuLastLoginAt user
                }

dbBytes :: FilePath -> IO Integer
dbBytes path = do
    main <- fileSize path
    wal <- fileSize (path <> "-wal")
    pure (main + wal)

fileSize :: FilePath -> IO Integer
fileSize path = do
    exists <- doesFileExist path
    if exists then getFileSize path else pure 0

snapshotCount :: FilePath -> IO Int
snapshotCount dir = do
    exists <- doesDirectoryExist dir
    if not exists
        then pure 0
        else do
            result <- try (listDirectory dir) :: IO (Either SomeException [FilePath])
            pure (either (const 0) length result)

{- | The message the per-library CLI commands print when there is no account to
use and the legacy @EZA_DB@ file is not a claimed eza database. Naming both the
control path and the legacy path makes the next step obvious: create an
account, or point the command at an account with @--user@.
-}
noAccountMessage :: Config -> Text
noAccountMessage cfg =
    "no accounts are registered in the control database ("
        <> T.pack (cfgControlDbPath cfg)
        <> ") and the legacy database ("
        <> T.pack (cfgDbPath cfg)
        <> ") is missing or has no claimed account. Start the server and finish /setup to create the first account, or pass --user <name|id> for an existing account"

{- | Enabled accounts whose library database file is missing. The server can
warn at startup instead of silently opening (and creating) a fresh empty
library when a request first resolves the account.
-}
missingUserDatabases :: Config -> Connection -> IO [ControlUser]
missingUserDatabases _cfg control = do
    users <- Control.listUsers control
    filterM (fmap not . doesFileExist . cuDbPath) [user | user <- users, isNothing (cuDisabledAt user)]

{- | A startup warning when more enabled accounts exist than @EZA_MAX_USERS@
slots, because the accounts past the limit cannot sign in while the process
runs.
-}
userLimitWarning :: Config -> Connection -> IO (Maybe Text)
userLimitWarning cfg control = do
    enabled <- Control.countEnabledUsers control
    pure $
        if enabled > cfgMaxUsers cfg
            then
                Just
                    ( "eza: "
                        <> T.pack (show enabled)
                        <> " enabled accounts but EZA_MAX_USERS="
                        <> T.pack (show (cfgMaxUsers cfg))
                        <> "; the accounts past the limit cannot sign in until the limit is raised or the server restarts"
                    )
            else Nothing

-- ------------------------------------------------------------------ paths ---

userDir :: Config -> Int -> FilePath
userDir cfg userId = cfgUsersDir cfg </> show userId

-- | Snapshots are per account so two libraries' bookmark ids cannot collide.
userSnapshotDir :: Config -> Int -> FilePath
userSnapshotDir cfg userId = userDir cfg userId </> "snapshots"

{- | The first free @users\/<id>\/eza.db@ (or @users\/<id>-N\/eza.db@ when a
deleted account's file is still on disk). A request or a create never uses a
path that already exists.
-}
userDbPathFor :: Config -> Int -> IO FilePath
userDbPathFor cfg userId = go (1 :: Int)
  where
    go attempt = do
        let name =
                if attempt == (1 :: Int)
                    then show userId
                    else show userId <> "-" <> show attempt
            path = cfgUsersDir cfg </> name </> "eza.db"
        exists <- doesFileExist path
        if exists then go (attempt + 1) else pure path

pendingDbPath :: Config -> IO FilePath
pendingDbPath cfg = do
    bytes <- getRandomBytes 12
    pure
        ( cfgUsersDir cfg
            </> (".pending-" <> T.unpack (TE.decodeUtf8 (B64.encodeUnpadded bytes)) <> ".db")
        )

-- --------------------------------------------------------------- creating ---

{- | Create one account: the control row, a migrated user database, and a
finished password setup with fresh recovery codes. The caller only ever passes
identity and a password; the database path comes from the allocated control id.

On any failure the partial control row and database are removed, so a retry
with the same username starts clean.
-}
createUserAccount ::
    Config ->
    Connection ->
    Text ->
    UserRole ->
    Text ->
    IO (Either AdminError (ControlUser, [Text]))
createUserAccount cfg control rawUsername role password =
    case Password.validateUsername rawUsername of
        Left message -> pure (Left (AdminInvalidUsername message))
        Right username -> case Password.validatePassword password of
            Left message -> pure (Left (AdminWeakPassword message))
            Right () -> do
                existing <- Control.countUsers control
                if existing >= cfgMaxUsers cfg
                    then pure (Left AdminUserLimit)
                    else do
                        placeholder <- pendingDbPath cfg
                        created <- Control.createUser control username placeholder role Nothing
                        case created of
                            Left ControlDuplicateUsername -> pure (Left AdminUsernameTaken)
                            Left err -> pure (Left (AdminInternal (T.pack (show err))))
                            Right user -> finish user
  where
    finish user = do
        path <- userDbPathFor cfg (cuId user)
        moved <- Control.updateUserDbPath control (cuId user) path
        if not moved
            then do
                cleanupPartial cfg control (cuId user) path
                pure (Left (AdminInternal "the account path could not be recorded"))
            else do
                result <- try (provision user path) :: IO (Either SomeException (ControlUser, [Text]))
                case result of
                    Left err -> do
                        cleanupPartial cfg control (cuId user) path
                        pure (Left (AdminInternal (T.pack (show err))))
                    Right done -> pure (Right done)

    provision user path = do
        passwordHash <- Password.hashPassword (cfgArgon2 cfg) password
        conn <- Db.openDb path
        codes <- Auth.completeSetup conn (cuUsername user) passwordHash
        Sqlite.close conn
        updated <- Control.lookupUserById control (cuId user)
        pure (maybe user id updated, codes)

cleanupPartial :: Config -> Connection -> Int -> FilePath -> IO ()
cleanupPartial _cfg control userId path = do
    void (try (Control.deleteUserRow control userId) :: IO (Either SomeException Bool))
    removeDbFiles path
    void (try (removeDirectoryRecursive (takeDirectory path)) :: IO (Either SomeException ()))
    hPutStrLn stderr ("eza: removed the partial account " <> show userId <> " after a failed create")
    pure ()

-- ------------------------------------------------------------- enable/role ---

{- | Enable or disable one account. Disabling deletes that account's sessions
and the worker supervisor stops its workers. The last enabled admin is kept.
-}
setUserEnabled :: Config -> Connection -> Int -> Bool -> IO (Either AdminError ControlUser)
setUserEnabled _cfg control userId enabled = do
    outcome <- Control.setUserDisabledGuarded control userId (not enabled)
    case outcome of
        Control.ControlWriteLastAdmin -> pure (Left AdminLastAdmin)
        Control.ControlWriteMissing -> pure (Left AdminNotFound)
        Control.ControlWriteOk -> do
            found <- Control.lookupUserById control userId
            case found of
                Nothing -> pure (Left AdminNotFound)
                Just user -> do
                    when (not enabled) (void (try (dropSessions (cuDbPath user)) :: IO (Either SomeException ())))
                    pure (Right user)

-- | Change one account's role, keeping at least one enabled admin.
setUserRole :: Connection -> Int -> UserRole -> IO (Either AdminError ControlUser)
setUserRole control userId role = do
    outcome <- Control.setUserRoleGuarded control userId role
    case outcome of
        Control.ControlWriteLastAdmin -> pure (Left AdminLastAdmin)
        Control.ControlWriteMissing -> pure (Left AdminNotFound)
        Control.ControlWriteOk -> do
            updated <- Control.lookupUserById control userId
            pure (maybe (Left AdminNotFound) Right updated)

dropSessions :: FilePath -> IO ()
dropSessions path = do
    exists <- doesFileExist path
    when exists $ do
        conn <- Sqlite.open path
        void (try (Auth.deleteAllSessions conn) :: IO (Either SomeException Int))
        Sqlite.close conn

-- -------------------------------------------------------------- passwords ---

{- | Admin password reset: set a temporary password, clear the optional passkey
second factor (an admin reset is a break-glass path for a user who lost the
device), and revoke every session of that account. The control username stays
authoritative.
-}
resetUserPassword :: Config -> Connection -> Int -> Text -> IO (Either AdminError ())
resetUserPassword cfg control userId newPassword = do
    found <- Control.lookupUserById control userId
    case found of
        Nothing -> pure (Left AdminNotFound)
        Just user -> case Password.validatePassword newPassword of
            Left message -> pure (Left (AdminWeakPassword message))
            Right () -> do
                exists <- doesFileExist (cuDbPath user)
                if not exists
                    then pure (Left (AdminInternal "the account database file is missing"))
                    else do
                        result <- try $ do
                            passwordHash <- Password.hashPassword (cfgArgon2 cfg) newPassword
                            conn <- Db.openDb (cuDbPath user)
                            Auth.setAccountPassword conn (cuUsername user) passwordHash
                            Auth.setRequirePasskey conn False
                            void (Auth.deleteAllSessions conn)
                            Sqlite.close conn
                        pure $ case result of
                            Left (err :: SomeException) -> Left (AdminInternal (T.pack (show err)))
                            Right () -> Right ()

-- --------------------------------------------------------------- deleting ---

{- | Delete one account. The control row always goes; the library database and
snapshots go only when @deleteDb@ is set, because those are the user's content.
The last enabled admin is never removed.
-}
deleteUserAccount :: Config -> Connection -> Int -> Bool -> IO (Either AdminError ())
deleteUserAccount cfg control userId deleteDb = do
    found <- Control.lookupUserById control userId
    case found of
        Nothing -> pure (Left AdminNotFound)
        Just user -> do
            admins <- Control.countEnabledAdmins control
            let removingLastAdmin =
                    cuRole user == RoleAdmin
                        && isNothing (cuDisabledAt user)
                        && admins <= 1
            if removingLastAdmin
                then pure (Left AdminLastAdmin)
                else do
                    removed <- Control.deleteUserRow control userId
                    if not removed
                        then pure (Left AdminNotFound)
                        else do
                            when deleteDb $ do
                                removeDbFiles (cuDbPath user)
                                void (try (removeDirectoryRecursive (userDir cfg userId)) :: IO (Either SomeException ()))
                            pure (Right ())

removeDbFiles :: FilePath -> IO ()
removeDbFiles path =
    forM_ [path, path <> "-wal", path <> "-shm"] $ \candidate -> do
        exists <- doesFileExist candidate
        when exists (void (try (removeFile candidate) :: IO (Either SomeException ())))

-- -------------------------------------------------------------- resolving ---

{- | @--user@ accepts an id or a username (case-insensitive, from the control
table's unique index).
-}
resolveSelector :: Connection -> Text -> IO (Maybe ControlUser)
resolveSelector control raw =
    case readIntText (T.strip raw) of
        Just userId -> Control.lookupUserById control userId
        Nothing -> Control.lookupUserByUsername control (T.strip raw)

readIntText :: Text -> Maybe Int
readIntText value = case reads (T.unpack (T.strip value)) of
    [(number, "")] -> Just number
    _ -> Nothing

{- | The library path a per-library CLI command should use.

With @--user@ the account is looked up in the control table. Without it, an
install with exactly one enabled account uses that account; a control database
with no rows falls back to the legacy @EZA_DB@ path so single-user installs and
pre-control workflows keep working; several accounts is an error that names
@--user@.
-}
resolveLibraryPath :: Config -> Maybe Text -> IO (Either Text FilePath)
resolveLibraryPath cfg selector = fmap snd <$> resolveLibraryTarget cfg selector

resolveLibraryTarget :: Config -> Maybe Text -> IO (Either Text (Maybe ControlUser, FilePath))
resolveLibraryTarget cfg selector = do
    result <-
        try (Control.openControlDb (cfgControlDbPath cfg)) ::
            IO (Either SomeException Connection)
    case result of
        Left err ->
            pure
                ( Left
                    ( "the control database could not be opened: "
                        <> T.pack (show err)
                    )
                )
        Right control -> do
            outcome <- try (pick control) :: IO (Either SomeException (Either Text (Maybe ControlUser, FilePath)))
            Sqlite.close control
            pure $ case outcome of
                Left err -> Left ("the account could not be resolved: " <> T.pack (show err))
                Right picked -> picked
  where
    pick control = case selector of
        Just raw -> do
            found <- resolveSelector control raw
            pure $ case found of
                Nothing -> Left ("no account matches --user " <> T.strip raw)
                Just user -> Right (Just user, cuDbPath user)
        Nothing -> do
            users <- Control.listUsers control
            let enabled = filter (isNothing . cuDisabledAt) users
            case (users, enabled) of
                ([], _) -> do
                    claimed <- Db.databaseClaimed (cfgDbPath cfg)
                    pure $
                        if claimed
                            then Right (Nothing, cfgDbPath cfg)
                            else Left (noAccountMessage cfg)
                (_, [only]) -> pure (Right (Just only, cuDbPath only))
                (_, []) -> pure (Left "every account is disabled; choose one with --user <name|id>")
                _ -> pure (Left "several accounts exist; choose one with --user <name|id>")
