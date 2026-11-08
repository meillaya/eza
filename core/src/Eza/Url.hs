{-# LANGUAGE OverloadedStrings #-}

-- | Small pure URL helpers shared by the server and client.
module Eza.Url
  ( isHttpUrl
  , hostOf
  , domainOf
  , normalizeUrl
  , dedupeKey
  , dedupeLookupUrls
  ) where

import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T

isHttpUrl :: Text -> Bool
isHttpUrl t =
  let l = T.toLower (T.strip t)
   in "http://" `T.isPrefixOf` l || "https://" `T.isPrefixOf` l

-- | Host component without userinfo, port, or path.  IPv6 literals keep
-- their address without the surrounding brackets.
hostOf :: Text -> Text
hostOf url =
  let afterScheme = T.drop 1 (T.dropWhile (/= ':') url)
      afterSlashes = T.dropWhile (== '/') afterScheme
      authority = T.takeWhile (\c -> c /= '/' && c /= '?' && c /= '#') afterSlashes
      noUser = case T.breakOnEnd "@" authority of
        ("", _) -> authority
        (_, h) -> h
      host
        | "[" `T.isPrefixOf` noUser = T.takeWhile (/= ']') (T.drop 1 noUser)
        | otherwise = T.takeWhile (/= ':') noUser
   in T.toLower host

-- | Host with a leading @www.@ stripped, used for grouping/display.
domainOf :: Text -> Text
domainOf h =
  let l = T.toLower (T.strip h)
   in maybe l id (T.stripPrefix "www." l)

-- | The canonical de-duplication key shared by the importer, the save paths
-- and the duplicates view: 'normalizeUrl' with the http(s) scheme removed, so
-- the same page saved over http and https is one record. Non-HTTP values are
-- compared by their normalized text. A non-default port stays part of the
-- key, because it can address a different service on the same host.
dedupeKey :: Text -> Text
dedupeKey raw =
  let normalized = normalizeUrl raw
   in case T.stripPrefix "http://" normalized of
        Just rest -> rest
        Nothing -> case T.stripPrefix "https://" normalized of
          Just rest -> rest
          Nothing -> normalized

-- | The exact stored-URL candidates that can carry @dedupeKey raw@. Stored
-- URLs keep a scheme, so the canonical lookup is an indexed @IN@ query on
-- these values (plus the normalised form for non-HTTP values).
dedupeLookupUrls :: Text -> [Text]
dedupeLookupUrls raw =
  let normalized = normalizeUrl raw
   in if isHttpUrl normalized
        then
          let key = dedupeKey normalized
           in nub [normalized, "http://" <> key, "https://" <> key]
        else [normalized]

-- | Normalize a URL for deduplication: lowercase the scheme and host, strip
-- a leading @www.@, remove the default port, drop the fragment, remove
-- tracking query parameters, and trim a trailing slash on a non-root path.
-- Userinfo keeps its original case; other path and query components are left
-- untouched.
normalizeUrl :: Text -> Text
normalizeUrl raw =
  let stripped = T.strip raw
      withoutFragment = T.takeWhile (/= '#') stripped
      (scheme, rest) = T.breakOn "://" withoutFragment
   in if T.null rest
        then withoutFragment
        else
          let loweredScheme = T.toLower scheme
              afterScheme = T.drop 3 rest
              (authority, suffix) = T.break (\c -> c == '/' || c == '?') afterScheme
              (pathPart, queryPart) = T.breakOn "?" suffix
              query = cleanQuery (T.drop 1 queryPart)
           in loweredScheme
                <> "://"
                <> normalizeAuthority loweredScheme authority
                <> dropTrailingSlash pathPart
                <> query
  where
    dropTrailingSlash p
      | p == "/" = ""
      | T.length p > 1 = T.dropWhileEnd (== '/') p
      | otherwise = p

-- | Lowercase the host, strip one leading @www.@, and remove a default port.
-- The userinfo part is preserved as written.
normalizeAuthority :: Text -> Text -> Text
normalizeAuthority scheme authority =
  let (userinfo, hostPort) = case T.breakOnEnd "@" authority of
        ("", _) -> ("", authority)
        (prefix, suffix) -> (prefix, suffix)
      loweredHost = T.toLower hostPort
      normalizedHost = stripWww (stripDefaultPort scheme loweredHost)
   in userinfo <> normalizedHost

stripDefaultPort :: Text -> Text -> Text
stripDefaultPort scheme hostPort
  | scheme == "http" = maybe hostPort id (T.stripSuffix ":80" hostPort)
  | scheme == "https" = maybe hostPort id (T.stripSuffix ":443" hostPort)
  | otherwise = hostPort

stripWww :: Text -> Text
stripWww host = maybe host id (T.stripPrefix "www." host)

-- | Drop known click-tracking query parameters.  Everything else is kept in
-- the original order.
cleanQuery :: Text -> Text
cleanQuery query
  | T.null query = ""
  | otherwise =
      let kept = filter (not . isTrackingParam . parameterKey) (T.splitOn "&" query)
       in if null kept then "" else "?" <> T.intercalate "&" kept

parameterKey :: Text -> Text
parameterKey parameter = T.toLower (T.strip (T.takeWhile (/= '=') parameter))

isTrackingParam :: Text -> Bool
isTrackingParam key =
  T.null key
    || "utm_" `T.isPrefixOf` key
    || key `elem` trackingParameters

-- | Common click-tracking keys.  Percent-encoded keys are ignored; the
-- comparison is on the literal name.
trackingParameters :: [Text]
trackingParameters =
  [ "fbclid"
  , "gclid"
  , "gclsrc"
  , "dclid"
  , "gbraid"
  , "wbraid"
  , "msclkid"
  , "twclid"
  , "ttclid"
  , "yclid"
  , "igshid"
  , "igsh"
  , "li_fat_id"
  , "mc_cid"
  , "mc_eid"
  , "mkt_tok"
  , "s_cid"
  , "vero_id"
  , "oly_anon_id"
  , "oly_enc_id"
  , "rb_clickid"
  , "_hsenc"
  , "_hsmi"
  , "hsctatracking"
  , "ref_src"
  , "ref_url"
  , "spm"
  , "scm"
  , "s_kwcid"
  , "ef_id"
  ]
