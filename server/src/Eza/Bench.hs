{-# LANGUAGE OverloadedStrings #-}
module Eza.Bench
  ( runBench
  ) where

import Control.Monad (forM, forM_)
import Data.List (sort)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple (Connection)

import Eza.Bookmarks
import Eza.Types (SearchPage (..))

runBench :: Connection -> Int -> IO ()
runBench conn iterations = do
  let n = max 1 iterations
      queries =
        [ ("all", defaultListQuery)
        , ("fts-rust", defaultListQuery {lqQ = "rust"})
        , ("fts-github", defaultListQuery {lqQ = "github"})
        , ("tag-imported", defaultListQuery {lqTags = ["imported"]})
        , ("tag-imported-books", defaultListQuery {lqTags = ["imported", "books"]})
        ]
  putStrLn ("iterations: " <> show n)
  forM_ queries $ \(name, q) -> do
    times <- forM [1 .. n] $ \_ -> do
      start <- getPOSIXTime
      page <- listBookmarks conn q
      end <- getPOSIXTime
      pure (realToFrac ((end - start) * 1000) :: Double, spTotal page)
    let sorted = sort (map fst times)
        total = fst (head times)
        index = min (length sorted - 1) (floor (fromIntegral (length sorted) * 0.95 :: Double))
        p95 = sorted !! max 0 index
        avg = sum sorted / fromIntegral (length sorted)
    putStrLn
      ( T.unpack name
          <> ": total=" <> show total
          <> " avg_ms=" <> show (round2 avg)
          <> " p95_ms=" <> show (round2 p95)
      )
  where
    round2 x = fromIntegral (round (x * 100) :: Int) / 100
