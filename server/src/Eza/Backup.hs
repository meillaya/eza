{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Eza.Backup
  ( runBackup
  ) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime, posixSecondsToUTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Database.SQLite.Simple
import System.Directory (copyFile, createDirectoryIfMissing, getModificationTime, listDirectory, removeFile)
import System.Environment (lookupEnv)
import System.FilePath (takeFileName, (</>))

import Eza.Config (Config (..))

runBackup :: Config -> IO (Either Text FilePath)
runBackup cfg = do
  createDirectoryIfMissing True (cfgBackupDir cfg)
  now <- getPOSIXTime
  let stamp = formatTime defaultTimeLocale "%Y%m%d-%H%M%S" (posixSecondsToUTCTime now)
      dest = cfgBackupDir cfg </> ("eza-" <> stamp <> ".db")
  conn <- open (cfgDbPath cfg)
  result <- try (execute conn "VACUUM INTO ?" (Only (T.pack dest))) :: IO (Either SomeException ())
  close conn
  case result of
    Left e -> pure (Left (T.pack (show e)))
    Right () -> do
      verified <- verify dest
      if not verified
        then removeFile dest >> pure (Left "integrity check failed on the backup")
        else do
          offsite <- lookupEnv "EZA_BACKUP_OFFSITE"
          case offsite of
            Nothing -> pure ()
            Just dir -> do
              createDirectoryIfMissing True dir
              copyFile dest (dir </> takeFileName dest)
          prune (cfgBackupDir cfg) 14
          pure (Right dest)

verify :: FilePath -> IO Bool
verify path = do
  result <- try $ do
    conn <- open path
    rows <- query_ conn "PRAGMA integrity_check" :: IO [Only Text]
    close conn
    pure (case rows of [Only "ok"] -> True; _ -> False)
  pure (either (const False) id (result :: Either SomeException Bool))

prune :: FilePath -> Int -> IO ()
prune dir keepDays = do
  now <- getCurrentTime
  entries <- listDirectory dir
  forM_ entries $ \name ->
    if "eza-" `T.isPrefixOf` T.pack name && ".db" `T.isSuffixOf` T.pack name
      then do
        let path = dir </> name
        mtime <- getModificationTime path
        if diffUTCTime now mtime > fromIntegral (max 1 keepDays) * 86400
          then removeFile path
          else pure ()
      else pure ()
