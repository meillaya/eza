{-# LANGUAGE OverloadedStrings #-}
module Eza.DeadLinks
  ( checkDead
  ) where

import Control.Concurrent.QSem
import Control.Concurrent.Async (mapConcurrently)
import Control.Exception (SomeException, try)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import Network.HTTP.Client
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)

-- | Bounded HEAD sweep.  A link is dead when the final response is >= 400 or
-- the host is unreachable.  HEAD 403/405 without a content-length gets a
-- ranged GET fallback (matching the old Python behaviour).
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
          dead = length (filter not results)
          alive = checked - dead
          now' = now
      withImmediateTransaction conn $
        mapM_ (\((bid, _), alive') ->
                  execute conn "UPDATE bookmarks SET is_dead = ?, last_checked_at = ? WHERE id = ?" ((if alive' then 0 else 1) :: Int, now', bid))
              (zip rows results)
      pure (checked, dead, alive)

checkOne :: Manager -> QSem -> (Int, Text) -> IO Bool
checkOne manager sem (_, url) = do
  waitQSem sem
  result <- try (do
    req <- parseRequest (T.unpack url)
    resp <- httpLbs req {method = "HEAD", responseTimeout = responseTimeoutMicro (8 * 1000000), redirectCount = 5, requestHeaders = [("User-Agent", "eza dead-link-checker")]} manager
    let code = statusCode (responseStatus resp)
    if code >= 400 && code `elem` [403, 405]
      then do
        req2 <- parseRequest (T.unpack url)
        resp2 <- httpLbs req2 {method = "GET", redirectCount = 5, responseTimeout = responseTimeoutMicro (8 * 1000000), requestHeaders = [("User-Agent", "eza dead-link-checker"), ("Range", "bytes=0-0")]} manager
        pure (statusCode (responseStatus resp2) < 400)
      else pure (code < 400)) :: IO (Either SomeException Bool)
  signalQSem sem
  pure (either (const False) id result)
