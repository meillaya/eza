{-# LANGUAGE OverloadedStrings #-}

-- | Small pure URL helpers shared by the server and client.
module Eza.Url
  ( isHttpUrl
  , hostOf
  , domainOf
  , normalizeUrl
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

-- | Normalize a bookmark URL for deduplication. Lowercase the scheme and
-- host, remove the default port, strip a fragment, and drop a trailing slash
-- on a non-root path. Query strings are left untouched.
normalizeUrl :: Text -> Text
normalizeUrl raw =
  let stripped = T.strip raw
      (input, _) = T.breakOn "#" stripped
      (scheme, rest) = T.breakOn "://" input
   in if T.null rest
        then input
        else
          let s = T.toLower scheme
              after = T.drop 3 rest
              (authority, pathAndQuery) = T.breakOn "/" after
              (authorityNoFragment, _) = T.breakOn "#" authority
              authority' = stripDefaultPort s (T.toLower authorityNoFragment)
              (pathPart, queryPart) = T.breakOn "?" pathAndQuery
              path' = dropTrailingSlash pathPart
           in s <> "://" <> authority' <> path' <> queryPart
  where
    dropTrailingSlash p
      | p == "/" = ""
      | T.length p > 1 = T.dropWhileEnd (== '/') p
      | otherwise = p
    stripDefaultPort scheme authority
      | scheme == "http" = maybe authority id (T.stripSuffix ":80" authority)
      | scheme == "https" = maybe authority id (T.stripSuffix ":443" authority)
      | otherwise = authority
