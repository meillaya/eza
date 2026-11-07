{-# LANGUAGE OverloadedStrings #-}

-- | Small pure URL helpers shared by the server and client.
module Eza.Url
  ( isHttpUrl
  , hostOf
  , domainOf
  ) where

import Data.Char (isAlphaNum)
import Data.Text (Text)
import qualified Data.Text as T

isHttpUrl :: Text -> Bool
isHttpUrl t =
  let l = T.toLower (T.strip t)
   in "http://" `T.isPrefixOf` l || "https://" `T.isPrefixOf` l

-- | Host component without userinfo, port, or path.
hostOf :: Text -> Text
hostOf url =
  let afterScheme = T.drop 1 (T.dropWhile (/= ':') url)
      afterSlashes = T.dropWhile (== '/') afterScheme
      authority = T.takeWhile (\c -> c /= '/' && c /= '?' && c /= '#') afterSlashes
      noUser = case T.breakOnEnd "@" authority of
        ("", _) -> authority
        (_, h) -> h
      host = T.takeWhile (\c -> c /= ':' && c /= '[' && c /= ']') noUser
   in T.toLower host

-- | Host with a leading @www.@ stripped, used for grouping/display.
domainOf :: Text -> Text
domainOf h =
  let l = T.toLower (T.strip h)
   in maybe l id (T.stripPrefix "www." l)

-- | Keep this module warning-free on GHC versions where the helpers are used
-- only by other packages.
_unused :: Char -> Bool
_unused = isAlphaNum
