{-# LANGUAGE OverloadedStrings #-}

{- | One opened user library, and the background workers that belong to it.

A library is the per-account runtime: exactly one writable connection behind
an 'MVar' (SQLite allows one writer), a small pool of read-only connections for
the GET path, the cached graph layout, and the handles of the account's
enrichment, favicon, and webhook worker loops. "Eza.Server" stores one
'Library' per account in its slot map; nothing else opens a user database.

The worker loops own their own database connection (they poll and write
independently and must never hold the request writer for their whole life).
Each loop brackets its 'Eza.Db.openDb' with 'Eza.Db.closeDb', so cancelling the
loop closes the connection instead of leaking it on every supervisor restart or
account disable.
-}
module Eza.Library (
    Library,
    LibraryWorkerConfig (..),
    openLibrary,
    closeLibrary,
    withLibraryWriter,
    withLibraryReader,
    libraryDbPath,
    libraryLayoutCache,
    libraryWorkerIds,
    startLibraryWorkers,
    stopLibraryWorkers,
) where

import Control.Concurrent.Async (Async, async, cancel, poll)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar, withMVar)
import Control.Concurrent.QSem (QSem)
import Control.Exception (onException)
import Control.Monad (filterM, forM)
import Data.Maybe (isNothing)
import Data.Pool (Pool, defaultPoolConfig, destroyAllResources, newPool, withResource)
import Database.SQLite.Simple (Connection)
import qualified Database.SQLite.Simple as Sqlite
import Network.HTTP.Client (Manager)

import Eza.Auth (cleanupExpired)
import Eza.Config (Config (..))
import qualified Eza.Db as Db
import Eza.Egress (runEgressWorkerFor)
import Eza.Enrich (runEnrichWorkerFor, runFaviconWorkerFor)
import Eza.Graph (LayoutCache, emptyLayoutCache)
import Eza.Jobs (resetRunningJobs)
import Eza.Webhooks (WebhookWorkerConfig (..), defaultWebhookWorkerConfig, runWebhookWorker)

{- | The fixed inputs a library's workers need: the configuration, the shared
HTTP manager, and the process-wide enrichment semaphore that caps outbound
network work across every account.
-}
data LibraryWorkerConfig = LibraryWorkerConfig
    { lwcConfig :: Config
    , lwcManager :: Manager
    , lwcEnrichSem :: QSem
    , lwcSnapshotDir :: FilePath
    }

-- | An opened user database and its workers. Close it with 'closeLibrary'.
data Library = Library
    { libDbPath :: FilePath
    , libWrite :: MVar Connection
    , libRead :: Pool Connection
    , libLayoutCache :: MVar LayoutCache
    , libWorkers :: MVar [Async ()]
    }

{- | Open the account's database, apply the per-open maintenance (expired
session cleanup and running-job recovery), and create the writer, the read
pool, and the layout cache. Workers are not started here; the supervisor calls
'startLibraryWorkers' explicitly so a library opened by a request does no
background work until the supervisor says so.
-}
openLibrary :: FilePath -> IO Library
openLibrary dbPath = do
    conn <- Db.openDb dbPath
    let setup = do
            cleanupExpired conn
            resetRunningJobs conn
            writeVar <- newMVar conn
            readPool <-
                newPool
                    ( defaultPoolConfig
                        (openReadConnection dbPath)
                        Db.closeDb
                        60
                        4
                    )
            layoutCache <- newMVar emptyLayoutCache
            workersVar <- newMVar []
            pure
                Library
                    { libDbPath = dbPath
                    , libWrite = writeVar
                    , libRead = readPool
                    , libLayoutCache = layoutCache
                    , libWorkers = workersVar
                    }
    setup `onException` Db.closeDb conn

{- | Stop the workers first, then release the read pool and close the writer.
The slot map owns the library, so this is both the disable path and shutdown.
-}
closeLibrary :: Library -> IO ()
closeLibrary library = do
    stopLibraryWorkers library
    destroyAllResources (libRead library)
    withMVar (libWrite library) Db.closeDb

-- | Run one action on the single writable connection.
withLibraryWriter :: Library -> (Connection -> IO a) -> IO a
withLibraryWriter library = withMVar (libWrite library)

-- | Run one action on a pooled read-only connection.
withLibraryReader :: Library -> (Connection -> IO a) -> IO a
withLibraryReader library = withResource (libRead library)

libraryDbPath :: Library -> FilePath
libraryDbPath = libDbPath

-- | The cached graph layout for this database (empty until first computed).
libraryLayoutCache :: Library -> MVar LayoutCache
libraryLayoutCache = libLayoutCache

-- | How many worker loops this library currently has (tests use it).
libraryWorkerIds :: Library -> IO Int
libraryWorkerIds library = length <$> readMVar (libWorkers library)

{- | Start (or restart) the enrichment, favicon, and webhook loops. A healthy
set is left alone; a set with a dead member is cancelled and replaced. The
enrich semaphore is process-wide, so @EZA_ENRICH_WORKERS@ caps total network
work across every account while each database keeps its own claimer.
-}
startLibraryWorkers :: LibraryWorkerConfig -> Library -> IO ()
startLibraryWorkers workers library =
    modifyMVar_ (libWorkers library) $ \running -> do
        alive <- filterM stillRunning running
        if not (null running) && length alive == length running
            then pure running
            else do
                mapM_ cancel running
                spawnLibraryWorkers workers library

{- | Stop every worker loop. Cancelling an 'Async' waits for its bracket to
close, so the worker connections are gone when this returns.
-}
stopLibraryWorkers :: Library -> IO ()
stopLibraryWorkers library =
    modifyMVar_ (libWorkers library) $ \running -> do
        mapM_ cancel running
        pure []

spawnLibraryWorkers :: LibraryWorkerConfig -> Library -> IO [Async ()]
spawnLibraryWorkers workers library = do
    let cfg = lwcConfig workers
        manager = lwcManager workers
        dbPath = libDbPath library
        enrichCount = cfgEnrichWorkers cfg
        webhookCfg =
            (defaultWebhookWorkerConfig cfg manager)
                { wwcDatabase = dbPath
                }
    enrichWorkers <-
        forM [1 .. enrichCount] $ \_ ->
            async (runEnrichWorkerFor manager cfg dbPath (lwcEnrichSem workers))
    webhookWorker <- async (runWebhookWorker webhookCfg)
    -- One egress loop per account: snapshot, dead-link, AI, webhook-test jobs.
    egressWorker <- async (runEgressWorkerFor manager cfg dbPath (lwcSnapshotDir workers) (lwcEnrichSem workers))
    -- One favicon backfill loop per account: cached domains cost no network,
    -- and each new domain costs one fetch no matter how many links it has.
    faviconWorkers <-
        if cfgFaviconBackfill cfg && enrichCount > 0
            then (: []) <$> async (runFaviconWorkerFor manager cfg dbPath (lwcEnrichSem workers))
            else pure []
    pure (enrichWorkers <> [webhookWorker, egressWorker] <> faviconWorkers)

stillRunning :: Async () -> IO Bool
stillRunning worker = isNothing <$> poll worker

{- | A pooled read-only connection. WAL lets these run alongside the writer;
@query_only@ turns an accidental write from a GET route into a loud error
instead of a lock.
-}
openReadConnection :: FilePath -> IO Connection
openReadConnection path = do
    conn <- Sqlite.open path
    mapM_
        (Sqlite.execute_ conn)
        [ "PRAGMA busy_timeout = 5000"
        , "PRAGMA temp_store = MEMORY"
        , "PRAGMA mmap_size = 268435456"
        , "PRAGMA cache_size = -65536"
        , "PRAGMA query_only = ON"
        ]
    pure conn
