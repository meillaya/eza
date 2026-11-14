{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The durable job queue shared by enrichment and asynchronous egress work.

Workers claim a job kind in an immediate transaction and perform network or
subprocess work outside it; handlers only validate and enqueue. Each job carries
a @target@ (the stable dedupe key, e.g. @bookmark:42@) and an opaque JSON
@payload@; egress jobs store a JSON @result@ when they finish. At most one
active job per @(kind, target)@ exists (partial unique index), and the older
@(kind, bookmark_id)@ index keeps enrichment deduplicated.
-}
module Eza.Jobs (
    Job (..),
    JobView (..),
    enqueueJob,
    enqueueTrackedJob,
    claimJob,
    claimJobKind,
    completeJob,
    completeJobResult,
    failJob,
    failJobPermanent,
    cancelJob,
    jobCancelRequested,
    getJob,
    getJobView,
    resetRunningJobs,
    cleanupJobs,
    jobStats,
) where

import Data.Aeson (Value, decode, encode)
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import qualified Database.SQLite.Simple as Sqlite

-- | A claimed job, with everything execute needs.
data Job = Job
    { jobId :: Int
    , jobKind :: Text
    , jobBookmarkId :: Maybe Int
    , jobTarget :: Text
    , jobPayload :: Text
    , jobAttempts :: Int
    }
    deriving (Show, Eq)

-- | The own-library status document served by @GET /api/v1/jobs/{id}@.
data JobView = JobView
    { jvId :: Int
    , jvKind :: Text
    , jvState :: Text
    , jvAttempts :: Int
    , jvResult :: Maybe Value
    , jvError :: Maybe Text
    }
    deriving (Show, Eq)

epoch :: IO Int
epoch = floor <$> getPOSIXTime

jobKinds :: [Text]
jobKinds = ["enrich", "snapshot", "check_dead", "ai_suggestions", "webhook_test"]

{- | Queue an enrichment-style job keyed by bookmark id. The
@(kind, bookmark_id)@ partial unique index makes an active duplicate a no-op.
-}
enqueueJob :: Connection -> Text -> Int -> IO ()
enqueueJob conn kind bookmarkId = do
    now <- epoch
    execute
        conn
        "INSERT OR IGNORE INTO jobs (kind, bookmark_id, target, payload, state, attempts, available_at, created_at, updated_at) VALUES (?,?,'','{}','queued',0,?,?,?)"
        (kind, bookmarkId, now, now, now)

{- | Queue an egress job keyed by @kind@ and @target@ and return its id. When an
active job for the same pair exists its id is returned instead of creating a
second one (the partial unique index is the source of truth).
-}
enqueueTrackedJob :: Connection -> Text -> Text -> Value -> IO Int
enqueueTrackedJob conn kind target payload = do
    now <- epoch
    let encoded = TE.decodeUtf8 (LBS.toStrict (encode payload))
    execute
        conn
        "INSERT OR IGNORE INTO jobs (kind, bookmark_id, target, payload, state, attempts, available_at, created_at, updated_at) VALUES (?,NULL,?,?,'queued',0,?,?,?)"
        (kind, target, encoded, now, now, now)
    rows <-
        query
            conn
            "SELECT id FROM jobs WHERE kind = ? AND target = ? AND state IN ('queued','running') ORDER BY id LIMIT 1"
            (kind, target) ::
            IO [Only Int]
    pure (case rows of [Only jobId] -> jobId; _ -> 0)

{- | Claim the oldest ready job of one kind. Runs under an immediate
transaction so two workers cannot claim the same row; a claim by another kind
worker never observes this row.
-}
claimJobKind :: Connection -> Text -> IO (Maybe Job)
claimJobKind conn kind = do
    now <- epoch
    withImmediateTransaction conn $ do
        rows <-
            query
                conn
                "SELECT id, kind, bookmark_id, target, payload, attempts FROM jobs WHERE kind = ? AND state = 'queued' AND available_at <= ? ORDER BY id LIMIT 1"
                (kind, now) ::
                IO [(Int, Text, Maybe Int, Text, Text, Int)]
        case rows of
            [] -> pure Nothing
            (row : _) -> do
                Sqlite.execute
                    conn
                    "UPDATE jobs SET state = 'running', updated_at = ? WHERE id = ?"
                    (now, firstOfSix row)
                pure (Just (jobFromRow row))
  where
    firstOfSix (value, _, _, _, _, _) = value

{- | Claim any ready job (the legacy CLI/test surface); new workers use
'claimJobKind' so they only see their own jobs.
-}
claimJob :: Connection -> IO (Maybe Job)
claimJob conn = do
    pages <- mapM (claimJobKind conn) jobKinds
    pure (firstJust pages)
  where
    firstJust (Just job : _) = Just job
    firstJust (_ : rest) = firstJust rest
    firstJust [] = Nothing

completeJob :: Connection -> Int -> IO ()
completeJob conn jobId = do
    now <- epoch
    execute conn "UPDATE jobs SET state = 'done', updated_at = ? WHERE id = ?" (now, jobId)

-- | Finish a job with its JSON result.
completeJobResult :: Connection -> Int -> Value -> IO ()
completeJobResult conn jobId result = do
    now <- epoch
    execute
        conn
        "UPDATE jobs SET state = 'done', result = ?, last_error = '', updated_at = ? WHERE id = ?"
        (TE.decodeUtf8 (LBS.toStrict (encode result)), now, jobId)

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

-- | Fail without retrying (refused URL, missing provider key, webhook error).
failJobPermanent :: Connection -> Int -> Text -> IO ()
failJobPermanent conn jobId message = do
    now <- epoch
    execute
        conn
        "UPDATE jobs SET state = 'failed', attempts = attempts + 1, last_error = ?, updated_at = ? WHERE id = ?"
        (message, now, jobId)

-- | Mark a queued or running job cancelled.
cancelJob :: Connection -> Int -> IO ()
cancelJob conn jobId = do
    now <- epoch
    execute
        conn
        "UPDATE jobs SET state = 'cancelled', updated_at = ? WHERE id = ? AND state IN ('queued','running')"
        (now, jobId)

jobCancelRequested :: Connection -> Int -> IO Bool
jobCancelRequested conn jobId = do
    rows <- query conn "SELECT cancel_requested FROM jobs WHERE id = ?" (Only jobId) :: IO [Only Int]
    pure (case rows of [Only value] -> value /= 0; _ -> False)

-- | Read a job's execution fields regardless of state (tests and tooling).
getJob :: Connection -> Int -> IO (Maybe Job)
getJob conn jobId = do
    rows <-
        query
            conn
            "SELECT id, kind, bookmark_id, target, payload, attempts FROM jobs WHERE id = ?"
            (Only jobId) ::
            IO [(Int, Text, Maybe Int, Text, Text, Int)]
    pure (case rows of [row] -> Just (jobFromRow row); _ -> Nothing)

getJobView :: Connection -> Int -> IO (Maybe JobView)
getJobView conn jobId = do
    rows <-
        query
            conn
            "SELECT id, kind, state, attempts, result, last_error FROM jobs WHERE id = ?"
            (Only jobId) ::
            IO [(Int, Text, Text, Int, Text, Text)]
    pure (case rows of [row] -> Just (viewFromRow row); _ -> Nothing)
  where
    viewFromRow (jobId', kind, state, attempts, result, lastError) =
        JobView
            { jvId = jobId'
            , jvKind = kind
            , jvState = state
            , jvAttempts = attempts
            , jvResult = decodeResult result
            , jvError = if T.null lastError then Nothing else Just lastError
            }

resetRunningJobs :: Connection -> IO ()
resetRunningJobs conn =
    withImmediateTransaction conn $
        execute_ conn "UPDATE jobs SET state = 'queued', available_at = strftime('%s','now'), cancel_requested = 0 WHERE state = 'running'"

cleanupJobs :: Connection -> IO ()
cleanupJobs conn = do
    now <- epoch
    execute conn "DELETE FROM jobs WHERE state IN ('done','failed','cancelled') AND updated_at < ?" (Only (now - 7 * 86400))

jobStats :: Connection -> IO [(Text, Int)]
jobStats conn = do
    rows <- query_ conn "SELECT state, COUNT(*) FROM jobs GROUP BY state ORDER BY state" :: IO [(Text, Int)]
    pure rows

jobFromRow :: (Int, Text, Maybe Int, Text, Text, Int) -> Job
jobFromRow (jobId', kind, bookmarkId, target, payload, attempts) =
    Job
        { jobId = jobId'
        , jobKind = kind
        , jobBookmarkId = bookmarkId
        , jobTarget = target
        , jobPayload = payload
        , jobAttempts = attempts
        }

decodeResult :: Text -> Maybe Value
decodeResult raw
    | T.null raw = Nothing
    | otherwise = decode (LBS.fromStrict (TE.encodeUtf8 raw))
