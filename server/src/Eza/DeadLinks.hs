{-# LANGUAGE OverloadedStrings #-}

-- | Dead-link sweep.  Requests go through 'Eza.Fetch' so the private-address
-- guard, timeout, redirect limit, and user agent apply here too.  Only a
-- definitive HTTP answer changes @is_dead@: network errors, timeouts, rate
-- limiting, and 5xx responses are transient and leave the flag untouched.
module Eza.DeadLinks
  ( checkDead
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

-- | Outcome of one check.  'LinkUnknown' is a transient failure: the row's
-- @is_dead@ value is preserved.
data LinkState = LinkAlive | LinkDead | LinkUnknown
  deriving (Show, Eq)

-- | Bounded HEAD sweep.  A link is dead when the final response is a
-- definitive 4xx.  HEAD 403/405 gets a GET fallback (matching the old Python
-- behaviour).  Network and transient failures count as unchecked, not dead.
checkDead :: Connection -> Int -> Int -> Bool -> IO (Int, Int, Int)
checkDead conn limit olderThan includeDead = do
  now <- floor <$> getPOSIXTime
  let cutoff = now - max 0 olderThan
      lim = max 1 (min 500 limit)
  rows <-
    query
      conn
      "SELECT id,url FROM bookmarks WHERE (is_dead = 0 OR ? = 1) AND (last_checked_at IS NULL OR last_checked_at < ?) ORDER BY last_checked_at IS NOT NULL, last_checked_at LIMIT ?"
      ((if includeDead then 1 else 0) :: Int, cutoff, lim) :: IO [(Int, Text)]
  if null rows
    then pure (0, 0, 0)
    else do
      manager <- newTlsManager
      sem <- newQSem 16
      results <- mapConcurrently (checkOne manager sem) rows
      let checked = length results
          dead = length (filter (== LinkDead) results)
          alive = length (filter (== LinkAlive) results)
      withImmediateTransaction conn $
        mapM_ (recordResult conn now) (zip rows results)
      pure (checked, dead, alive)

recordResult :: Connection -> Int -> ((Int, Text), LinkState) -> IO ()
recordResult conn now ((bid, _), state) = case state of
  LinkAlive -> setDead 0
  LinkDead -> setDead 1
  LinkUnknown -> execute conn "UPDATE bookmarks SET last_checked_at = ? WHERE id = ?" (now, bid)
  where
    setDead dead =
      execute
        conn
        "UPDATE bookmarks SET is_dead = ?, last_checked_at = ? WHERE id = ?"
        ((dead :: Int), now, bid)

checkOne :: Manager -> QSem -> (Int, Text) -> IO LinkState
checkOne manager sem (_, url) =
  bracket_ (waitQSem sem) (signalQSem sem) $ do
    let base = anyOptions manager 8000 (64 * 1024) False
    headResult <- fetchUrl (base {foMethod = "HEAD"}) url
    case headResult of
      Right _ -> pure LinkAlive
      Left (FetchHttp code)
        | code `elem` [403, 405] -> do
            getResult <- fetchUrl (base {foMethod = "GET"}) url
            pure (classify getResult)
        | code >= 500 -> pure LinkUnknown
        | code `elem` [408, 425, 429] -> pure LinkUnknown
        | code >= 400 -> pure LinkDead
        | otherwise -> pure LinkUnknown
      Left _ -> pure LinkUnknown
  where
    classify result = case result of
      Right _ -> LinkAlive
      Left (FetchHttp code)
        | code >= 500 -> LinkUnknown
        | code `elem` [408, 425, 429] -> LinkUnknown
        | code >= 400 -> LinkDead
      Left _ -> LinkUnknown
