{-# LANGUAGE OverloadedStrings #-}

{- | CLI integration: the command runner from "Eza.Cli" against a temporary
installation. Passwords come from a stdin handle, the way a deployment script
supplies them; the users subcommands, per-library @--user@ resolution, last
admin protection, and deletion are exercised end to end.
-}
module CliSpec (spec) where

import Control.Exception (bracket, finally, try)
import Control.Monad (forM_)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Database.SQLite.Simple as Sqlite
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle, IOMode (..), hClose, hFlush, openFile, stdout)
import System.IO.Temp (openTempFile, withSystemTempDirectory)
import Test.Hspec

import qualified Eza.Auth as Auth
import qualified Eza.Bookmarks as Bookmarks
import Eza.Cli
import Eza.Config (Config (..))
import Eza.Control (ControlUser (..))
import qualified Eza.Control as Control
import qualified Eza.Db as Db
import qualified Eza.Password as Password
import Eza.User (UserRole (..))
import TestHarness (testAuthConfig, testConfig)

spec :: Spec
spec = describe "CLI" $ do
    it "creates an account from a stdin password and prints one-time recovery codes" $
        withCliConfig $ \cfg -> do
            (_, handle) <- stdinHandle "alice password\n"
            ((), output) <-
                captureOutput
                    (runCli cfg (handleSource handle) (UsersCmd (UsersAdd "alice" RoleAdmin True)))
            hClose handle
            output `shouldSatisfy` T.isInfixOf "created user alice"
            output `shouldSatisfy` T.isInfixOf "recovery codes"
            users <- listControlUsers cfg
            length users `shouldBe` 1
            case users of
                (alice : _) -> do
                    cuUsername alice `shouldBe` "alice"
                    cuRole alice `shouldBe` RoleAdmin
                    let dbPath = cfgUsersDir cfg </> "1" </> "eza.db"
                    exists <- doesFileExist dbPath
                    exists `shouldBe` True
                    bracket (Db.openDb dbPath) Sqlite.close $ \conn -> do
                        remaining <- Auth.recoveryCodesRemaining conn
                        remaining `shouldBe` 10
                        account <- Auth.loadAccount conn
                        Auth.acctUsername account `shouldBe` "alice"
                        Auth.accountHasPassword account `shouldBe` True
                [] -> expectationFailure "expected one account"

    it "refuses users add without --password-stdin" $
        withCliConfig $ \cfg -> do
            expectCliFailure (runCli cfg (textSource "alice password") (UsersCmd (UsersAdd "alice" RoleAdmin False)))
            users <- listControlUsers cfg
            users `shouldBe` []

    it "protects the last enabled admin and deletes with --delete-db only" $
        withCliConfig $ \cfg -> do
            addCliUser cfg "alice" RoleAdmin
            addCliUser cfg "bob" RoleMember
            alice <- mustLookup cfg "alice"
            bob <- mustLookup cfg "bob"
            -- Disabling a member is fine; disabling the only admin is not.
            runOk cfg (UsersCmd (UsersDisable "bob"))
            bob' <- mustLookup cfg "bob"
            (cuDisabledAt bob' `shouldSatisfy` isJust')
            expectCliFailure (runCli cfg (textSource "") (UsersCmd (UsersDisable "alice")))
            alice' <- mustLookup cfg "alice"
            cuDisabledAt alice' `shouldBe` Nothing
            runOk cfg (UsersCmd (UsersEnable "bob"))
            -- Delete without --delete-db is refused and keeps the row.
            expectCliFailure (runCli cfg (textSource "") (UsersCmd (UsersDelete "bob" False)))
            bobStillThere <- withControlCfg cfg (\control -> Control.lookupUserById control (cuId bob))
            bobStillThere `shouldSatisfy` isJustUser
            -- With --delete-db the member and its library are removed.
            runOk cfg (UsersCmd (UsersDelete "bob" True))
            gone <- withControlCfg cfg (\control -> Control.lookupUserById control (cuId bob))
            gone `shouldBe` Nothing
            bobDbExists <- doesFileExist (cuDbPath bob)
            bobDbExists `shouldBe` False
            -- The last admin cannot be deleted.
            expectCliFailure (runCli cfg (textSource "") (UsersCmd (UsersDelete "alice" True)))
            aliceRemains <- withControlCfg cfg (\control -> Control.lookupUserById control (cuId alice))
            aliceRemains `shouldSatisfy` isJustUser

    it "resets a password, revokes sessions, and accepts the temporary password" $
        withCliConfig $ \cfg -> do
            addCliUser cfg "alice" RoleAdmin
            alice <- mustLookup cfg "alice"
            bracket (Db.openDb (cuDbPath alice)) Sqlite.close $ \conn -> do
                _ <- Auth.createSession conn "normal" 3600
                pure ()
            runOkWith cfg (textSource "temporary alice password") (UsersCmd (UsersResetPassword "alice" True))
            bracket (Db.openDb (cuDbPath alice)) Sqlite.close $ \conn -> do
                sessions <- Sqlite.query_ conn "SELECT COUNT(*) FROM sessions" :: IO [Sqlite.Only Int]
                sessions `shouldBe` [Sqlite.Only 0]
                let ac = testAuthConfig cfg
                old <- Auth.verifyPasswordLogin conn ac "alice" "alice password"
                authStatus old `shouldBe` 401
                fresh <- Auth.verifyPasswordLogin conn ac "alice" "temporary alice password"
                authStatus fresh `shouldBe` 200

    it "resolves the library from --user, the only account, or the legacy path" $
        withCliConfig $ \cfg -> do
            addCliUser cfg "alice" RoleAdmin
            alice <- mustLookup cfg "alice"
            bracket (Db.openDb (cuDbPath alice)) Sqlite.close $ \conn -> do
                _ <- Bookmarks.insertBookmark conn "https://alice.example/one" "One" []
                pure ()
            -- One enabled account: no --user needed.
            ((), singleOutput) <- captureOutput (runCli cfg (textSource "") (Stats Nothing))
            singleOutput `shouldSatisfy` T.isInfixOf ("db: " <> T.pack (cuDbPath alice))
            singleOutput `shouldSatisfy` T.isInfixOf "bookmarks: 1"
            addCliUser cfg "bob" RoleMember
            -- Several accounts: the command must not guess.
            expectCliFailure (runCli cfg (textSource "") (Stats Nothing))
            ((), chosenOutput) <- captureOutput (runCli cfg (textSource "") (Stats (Just "bob")))
            bob <- mustLookup cfg "bob"
            chosenOutput `shouldSatisfy` T.isInfixOf ("db: " <> T.pack (cuDbPath bob))

    it "sets a password through the control row and renames it there too" $
        withCliConfig $ \cfg -> do
            addCliUser cfg "alice" RoleAdmin
            alice <- mustLookup cfg "alice"
            let passwords =
                    PasswordSource
                        { psReadHidden = \_ -> pure "renamed alice password"
                        , psReadStdinLine = pure "renamed alice password"
                        }
            runOkWith cfg passwords (SetPasswordCmd SetPasswordOpts{spUsername = Just "alice-renamed", spUser = Just "alice", spResetSessions = False, spDisable2fa = False})
            renamed <- mustLookup cfg "alice-renamed"
            cuId renamed `shouldBe` cuId alice
            bracket (Db.openDb (cuDbPath alice)) Sqlite.close $ \conn -> do
                account <- Auth.loadAccount conn
                Auth.acctUsername account `shouldBe` "alice-renamed"
                fresh <- Auth.verifyPasswordLogin conn (testAuthConfig cfg) "alice-renamed" "renamed alice password"
                authStatus fresh `shouldBe` 200

    it "lists accounts with their state" $
        withCliConfig $ \cfg -> do
            addCliUser cfg "alice" RoleAdmin
            addCliUser cfg "bob" RoleMember
            runOk cfg (UsersCmd (UsersDisable "bob"))
            ((), output) <- captureOutput (runCli cfg (textSource "") (UsersCmd UsersList))
            output `shouldSatisfy` T.isInfixOf "alice"
            output `shouldSatisfy` T.isInfixOf "enabled"
            output `shouldSatisfy` T.isInfixOf "bob"
            output `shouldSatisfy` T.isInfixOf "disabled"

    it "prints --help for every subcommand" $ do
        forM_
            [ ["serve", "--help"]
            , ["import", "--help"]
            , ["users", "add", "--help"]
            , ["backup", "--help"]
            , ["restore", "--help"]
            ]
            $ \args -> case parseCliArgs args of
                Left (_, ExitSuccess) -> pure ()
                Left (_, code) -> expectationFailure (show args <> " exited " <> show code)
                Right _ -> expectationFailure (show args <> " parsed as a command instead of printing help")

    it "reports a healthcheck failure as an exit code, not an exception" $
        withCliConfig $ \cfg -> do
            result <- try (runCli cfg (textSource "") Healthcheck) :: IO (Either ExitCode ())
            case result of
                Left (ExitFailure _) -> pure ()
                Left ExitSuccess -> expectationFailure "a healthcheck with no server must fail"
                Right () -> expectationFailure "a healthcheck with no server must fail"

    it "refuses the legacy fallback unless the legacy database is a claimed eza database" $
        withCliConfig $ \cfg -> do
            expectCliFailure (runCli cfg (textSource "") (Stats Nothing))
            -- An existing but unclaimed database is not enough.
            bracket (Db.openDb (cfgDbPath cfg)) Sqlite.close (\_ -> pure ())
            expectCliFailure (runCli cfg (textSource "") (Stats Nothing))
            -- A claimed legacy database keeps the single-user workflow working.
            bracket (Db.openDb (cfgDbPath cfg)) Sqlite.close $ \conn -> do
                passwordHash <- Password.hashPassword (cfgArgon2 cfg) "legacy password"
                _ <- Auth.completeSetup conn "legacy" passwordHash
                pure ()
            runOk cfg (Stats Nothing)

    it "requires --yes before restoring a stamp" $
        withCliConfig $ \cfg -> do
            expectCliFailure
                ( runCli
                    cfg
                    (textSource "")
                    ( RestoreCmd
                        RestoreOpts
                            { rstStamp = cfgDataDir cfg </> "missing"
                            , rstDryRun = False
                            , rstYes = False
                            , rstForce = False
                            }
                    )
                )

    it "backs up and restores through the command line" $
        withCliConfig $ \cfg -> do
            addCliUser cfg "alice" RoleAdmin
            alice <- mustLookup cfg "alice"
            bracket (Db.openDb (cuDbPath alice)) Sqlite.close $ \conn -> do
                _ <- Bookmarks.insertBookmark conn "https://alice.example/cli" "Cli" []
                pure ()
            ((), backupOutput) <- captureOutput (runCli cfg (textSource "") (Backup Nothing))
            case [T.drop 8 line | line <- T.lines backupOutput, "backup: " `T.isPrefixOf` line] of
                (stamp : _) -> do
                    ((), planOutput) <-
                        captureOutput
                            ( runCli
                                cfg
                                (textSource "")
                                (RestoreCmd RestoreOpts{rstStamp = T.unpack stamp, rstDryRun = True, rstYes = False, rstForce = False})
                            )
                    planOutput `shouldSatisfy` T.isInfixOf "restore plan:"
                    planOutput `shouldSatisfy` T.isInfixOf "dry run only"
                    ((), restoreOutput) <-
                        captureOutput
                            ( runCli
                                cfg
                                (textSource "")
                                (RestoreCmd RestoreOpts{rstStamp = T.unpack stamp, rstDryRun = False, rstYes = True, rstForce = False})
                            )
                    restoreOutput `shouldSatisfy` T.isInfixOf "restore: done"
                    bracket (Db.openDb (cuDbPath alice)) Sqlite.close $ \conn ->
                        (Sqlite.query_ conn "SELECT COUNT(*) FROM bookmarks" :: IO [Sqlite.Only Int])
                            `shouldReturn` [Sqlite.Only 1]
                [] -> expectationFailure "the backup output did not name the stamp"

    it "fails verify when the FTS index drifted" $
        withCliConfig $ \cfg -> do
            addCliUser cfg "alice" RoleAdmin
            alice <- mustLookup cfg "alice"
            bracket (Db.openDb (cuDbPath alice)) Sqlite.close $ \conn -> do
                _ <- Bookmarks.insertBookmark conn "https://alice.example/verify" "Verify" []
                Sqlite.execute_
                    conn
                    "INSERT INTO bookmarks_fts(rowid,title,description,url,note_body,extracted_text) VALUES (999,'Ghost','','https://ghost','','')"
            result <- try (runCli cfg (textSource "") (Verify (Just "alice"))) :: IO (Either ExitCode ())
            case result of
                Left (ExitFailure _) -> pure ()
                Left ExitSuccess -> expectationFailure "verify must fail on a corrupt FTS index"
                Right () -> expectationFailure "verify must fail on a corrupt FTS index"

    it "rejects a set-password rename that collides and keeps the old login working" $
        withCliConfig $ \cfg -> do
            addCliUser cfg "alice" RoleAdmin
            addCliUser cfg "bob" RoleMember
            expectCliFailure
                ( runCli
                    cfg
                    (textSource "renamed alice password")
                    ( SetPasswordCmd
                        SetPasswordOpts
                            { spUsername = Just "bob"
                            , spUser = Just "alice"
                            , spResetSessions = False
                            , spDisable2fa = False
                            }
                    )
                )
            alice <- mustLookup cfg "alice"
            bracket (Db.openDb (cuDbPath alice)) Sqlite.close $ \conn -> do
                account <- Auth.loadAccount conn
                Auth.acctUsername account `shouldBe` "alice"
                fresh <- Auth.verifyPasswordLogin conn (testAuthConfig cfg) "alice" (initialPassword "alice")
                authStatus fresh `shouldBe` 200

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

withCliConfig :: (Config -> IO a) -> IO a
withCliConfig action = withSystemTempDirectory "eza-cli" (\dir -> action (testConfig dir))

textSource :: T.Text -> PasswordSource
textSource value =
    PasswordSource
        { psReadHidden = \_ -> pure value
        , psReadStdinLine = pure value
        }

handleSource :: Handle -> PasswordSource
handleSource handle =
    PasswordSource
        { psReadHidden = \_ -> TIO.hGetLine handle
        , psReadStdinLine = TIO.hGetLine handle
        }

stdinHandle :: T.Text -> IO (FilePath, Handle)
stdinHandle content = do
    (path, writer) <- openTempFile "/tmp" "eza-cli-stdin.txt"
    TIO.hPutStr writer content
    hClose writer
    handle <- openFile path ReadMode
    pure (path, handle)

captureOutput :: IO a -> IO (a, T.Text)
captureOutput action = do
    (path, handle) <- openTempFile "/tmp" "eza-cli-out.txt"
    old <- hDuplicate stdout
    hDuplicateTo handle stdout
    result <-
        action
            `finally` do
                hFlush stdout
                hDuplicateTo old stdout
                hClose handle
    content <- TIO.readFile path
    pure (result, content)

addCliUser :: Config -> T.Text -> UserRole -> IO ()
addCliUser cfg username role =
    runOkWith cfg (textSource (initialPassword username)) (UsersCmd (UsersAdd username role True))

initialPassword :: T.Text -> T.Text
initialPassword username = "initial password for " <> username

runOk :: Config -> CliCommand -> IO ()
runOk cfg = runOkWith cfg (textSource "")

runOkWith :: Config -> PasswordSource -> CliCommand -> IO ()
runOkWith cfg source cliCommand = do
    result <- try (runCli cfg source cliCommand) :: IO (Either ExitCode ())
    case result of
        Right () -> pure ()
        Left code -> expectationFailure ("command failed unexpectedly: " <> show code)

expectCliFailure :: IO () -> IO ()
expectCliFailure action = do
    result <- try action :: IO (Either ExitCode ())
    case result of
        Left (ExitFailure _) -> pure ()
        Left ExitSuccess -> expectationFailure "expected a non-zero exit, got success"
        Right () -> expectationFailure "expected a non-zero exit, got success"

listControlUsers :: Config -> IO [ControlUser]
listControlUsers cfg = withControlCfg cfg Control.listUsers

mustLookup :: Config -> T.Text -> IO ControlUser
mustLookup cfg username = do
    found <- withControlCfg cfg (\control -> Control.lookupUserByUsername control username)
    case found of
        Just user -> pure user
        Nothing -> expectationFailure ("missing account " <> T.unpack username) >> error "unreachable"

openControl :: Config -> IO Sqlite.Connection
openControl cfg = Control.openControlDb (cfgControlDbPath cfg)

withControlCfg :: Config -> (Sqlite.Connection -> IO a) -> IO a
withControlCfg cfg = bracket (openControl cfg) Sqlite.close

authStatus :: Either Auth.AuthError a -> Int
authStatus (Left err) = Auth.aeStatus err
authStatus (Right _) = 200

isJust' :: Maybe a -> Bool
isJust' (Just _) = True
isJust' Nothing = False

isJustUser :: Maybe ControlUser -> Bool
isJustUser (Just _) = True
isJustUser Nothing = False
