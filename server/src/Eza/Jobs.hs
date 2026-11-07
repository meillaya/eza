{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Small durable job queue. Workers claim a job in an immediate transaction
-- and perform network work outside it.
module Eza.Jobs
  ( Job (..)
  , enqueueJob
  , claimJob
  , completeJob
  , failJob
  , resetRunningJobs
  , cleanupJobs
  , jobStats
  ) where

import Control.Monad (when)
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import qualified Database.SQLite.Simple as Sqlite

data Job = Job
  { jobId :: Int
  , jobKind :: Text
  , jobBookmarkId :: Maybe Int
  , jobAttempts :: Int
  }
  deriving (Show, Eq)

epoch :: IO Int
epoch = floor <$> getPOSIXTime

-- | Queue a job. The partial unique index makes an active duplicate a no-op.
enqueueJob :: Connection -> Text -> Int -> IO ()
enqueueJob conn kind bookmarkId = do
  now <- epoch
  execute
    conn
    "INSERT OR IGNORE INTO jobs (kind, bookmark_id, state, attempts, available_at, created_at, updated_at) VALUES (?,?,'queued',0,?,?,?)"
    (kind, bookmarkId, now, now, now)

-- | Claim the oldest ready job. Runs under an immediate transaction so two
-- workers cannot claim the same row.
claimJob :: Connection -> IO (Maybe Job)
claimJob conn = do
  now <- epoch
  withImmediateTransaction conn $ do
    rows <-
      query
        conn
        "SELECT id, kind, bookmark_id, attempts FROM jobs WHERE state = 'queued' AND available_at <= ? ORDER BY id LIMIT 1"
        (Only now) :: IO [(Int, Text, Maybe Int, Int)]
    case rows of
      [] -> pure Nothing
      ((jobId, kind, bookmarkId, attempts) : _) -> do
        execute
          conn
          "UPDATE jobs SET state = 'running', updated_at = ? WHERE id = ?"
          (now, jobId)
        pure (Just (Job jobId kind bookmarkId attempts))

completeJob :: Connection -> Int -> IO ()
completeJob conn jobId = do
  now <- epoch
  execute conn "UPDATE jobs SET state = 'done', updated_at = ? WHERE id = ?" (now, jobId)

-- | Retry with a short backoff, then park the job as failed.
failJob :: Connection -> Int -> Text -> Int -> IO ()
failJob conn jobId message attempts = do
  now <- epoch
  let next = attempts + 1
      backoff = case next of
        1 -> 60
        2 -> 600
        _ -> 3600
      state = if next >= 3 then "failed" else "queued"
  execute
    conn
    "UPDATE jobs SET state = ?, attempts = ?, available_at = ?, last_error = ?, updated_at = ? WHERE id = ?"
    (state :: Text, next, now + backoff, message, now, jobId)

resetRunningJobs :: Connection -> IO ()
resetRunningJobs conn =
  withImmediateTransaction conn $
    execute_ conn "UPDATE jobs SET state = 'queued', available_at = strftime('%s','now') WHERE state = 'running'"

cleanupJobs :: Connection -> IO ()
cleanupJobs conn = do
  now <- epoch
  execute conn "DELETE FROM jobs WHERE state IN ('done','failed') AND updated_at < ?" (Only (now - 7 * 86400))

jobStats :: Connection -> IO [(Text, Int)]
jobStats conn = do
  rows <- query_ conn "SELECT state, COUNT(*) FROM jobs GROUP BY state ORDER BY state" :: IO [(Text, Int)]
  pure rows
