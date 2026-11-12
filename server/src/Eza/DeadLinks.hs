{-# LANGUAGE OverloadedStrings #-}

{- | Dead-link sweep.  Requests go through 'Eza.Fetch' so the private-address
guard, timeout, redirect limit, and user agent apply here too.  Only a
definitive HTTP answer changes @is_dead@: network errors, timeouts, rate
limiting, and 5xx responses are transient and leave the flag untouched.
-}
module Eza.DeadLinks (
    checkDead,
    LinkState (..),
    classifyHttp,
) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.QSem
import Control.Exception (bracket_)
import Data.Text (Text)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import Network.HTTP.Client (Manager)
import Network.HTTP.Client.TLS (newTlsManager)

import Eza.Fetch

{- | Outcome of one check.  'LinkUnknown' is a transient/blocked answer: the
row's @is_dead@ value is preserved.  Only a GET-confirmed 404 or 410 is
definitive enough to mark a link dead.
-}
data LinkState = LinkAlive | LinkDead | LinkUnknown
    deriving (Show, Eq)

{- | A definitive dead status. A 401/403/405/407/429/451 is an access or
rate-limit answer, not proof that the page is gone.
-}
classifyHttp :: Int -> LinkState
classifyHttp code
    | code == 404 || code == 410 = LinkDead
    | code >= 200 && code < 300 = LinkAlive
    | otherwise = LinkUnknown

{- | Bounded HEAD sweep. HEAD 4xx is confirmed with GET; only a GET-confirmed
404/410 changes @is_dead@. Already-dead rows are checked first when
@includeDead@ is set, so an explicit recheck repairs old false positives before
the unchecked tail. The shared executor keeps at most 16 requests in flight.
-}
checkDead :: Connection -> Int -> Int -> Bool -> IO (Int, Int, Int, Int)
checkDead conn limit olderThan includeDead = do
    now <- floor <$> getPOSIXTime
    let cutoff = now - max 0 olderThan
        lim = max 1 (min 500 limit)
        include = if includeDead then (1 :: Int) else 0
    rows <-
        query
            conn
            "SELECT id,url FROM bookmarks WHERE (is_dead = 0 OR ? = 1) AND (last_checked_at IS NULL OR last_checked_at < ?) AND NOT EXISTS (SELECT 1 FROM bookmark_dead_overrides o WHERE o.bookmark_id = bookmarks.id) ORDER BY CASE WHEN ? = 1 AND is_dead = 1 THEN 0 ELSE 1 END, last_checked_at IS NOT NULL, last_checked_at LIMIT ?"
            (include, cutoff, include, lim) ::
            IO [(Int, Text)]
    if null rows
        then do
            total <- totalDead conn
            pure (0, 0, 0, total)
        else do
            manager <- newTlsManager
            sem <- newQSem 16
            results <- mapConcurrently (checkOne manager sem) rows
            let checked = length results
                newlyDead = length (filter (== LinkDead) results)
                alive = length (filter (== LinkAlive) results)
            withImmediateTransaction conn $
                mapM_ (recordResult conn now) (zip rows results)
            total <- totalDead conn
            pure (checked, newlyDead, alive, total)

totalDead :: Connection -> IO Int
totalDead conn = do
    rows <- query_ conn "SELECT COUNT(*) FROM bookmarks WHERE is_dead = 1" :: IO [Only Int]
    pure (case rows of [Only n] -> n; _ -> 0)

recordResult :: Connection -> Int -> ((Int, Text), LinkState) -> IO ()
recordResult conn now ((bid, _), state) = case state of
    LinkAlive -> setDead 0
    LinkDead -> setDead 1
    LinkUnknown -> execute conn "UPDATE bookmarks SET last_checked_at = ? WHERE id = ?" (now, bid)
  where
    setDead dead =
        execute
            conn
            "UPDATE bookmarks SET is_dead = ?, last_checked_at = ? WHERE id = ? AND NOT EXISTS (SELECT 1 FROM bookmark_dead_overrides o WHERE o.bookmark_id = bookmarks.id)"
            ((dead :: Int), now, bid)

checkOne :: Manager -> QSem -> (Int, Text) -> IO LinkState
checkOne manager sem (_, url) =
    bracket_ (waitQSem sem) (signalQSem sem) $ do
        let base = anyOptions manager 8000 (64 * 1024) False
        headResult <- fetchUrl (base{foMethod = "HEAD"}) url
        case headResult of
            Right _ -> pure LinkAlive
            Left (FetchHttp code)
                | code >= 400 && code < 500 && code `notElem` [408, 425, 429] -> do
                    getResult <- fetchUrl (base{foMethod = "GET"}) url
                    pure (classifyResult getResult)
                | otherwise -> pure LinkUnknown
            Left _ -> pure LinkUnknown
  where
    classifyResult result = case result of
        Right _ -> LinkAlive
        Left (FetchHttp code) -> classifyHttp code
        Left _ -> LinkUnknown
