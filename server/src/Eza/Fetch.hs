{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Outbound HTTP with a size cap, a timeout, and a private-network guard.
-- The guard resolves the host on every hop and rejects loopback, link-local,
-- private, documentation, and multicast addresses unless the caller opts in.
module Eza.Fetch
  ( FetchOptions (..)
  , FetchPage (..)
  , FetchError (..)
  , fetchUrl
  ) where

import Control.Exception (SomeException, try)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as LBS
import Data.Char (toLower)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word32)
import Network.HTTP.Client
import Network.HTTP.Client (HttpException)
import Network.HTTP.Types.Header (hContentType, hLocation, hUserAgent)
import Network.HTTP.Types.Status (statusCode)
import Network.Socket
import Network.URI (parseURI, relativeTo, uriScheme)

data FetchOptions = FetchOptions
  { foManager :: Manager
  , foTimeoutMs :: Int
  , foMaxBytes :: Int
  , foAllowPrivate :: Bool
  }

data FetchPage = FetchPage
  { fpFinalUrl :: Text
  , fpStatus :: Int
  , fpContentType :: Text
  , fpBody :: BS.ByteString
  }
  deriving (Show, Eq)

data FetchError
  = FetchInvalidUrl Text
  | FetchBlocked Text
  | FetchTooLarge
  | FetchRedirect
  | FetchHttp Int
  | FetchNetwork Text
  deriving (Show, Eq)

fetchUrl :: FetchOptions -> Text -> IO (Either FetchError FetchPage)
fetchUrl opts rawUrl
  | T.null (T.strip rawUrl) = pure (Left (FetchInvalidUrl rawUrl))
  | otherwise = go (0 :: Int) (T.strip rawUrl)
  where
    go hops url
      | hops > 4 = pure (Left FetchRedirect)
      | otherwise =
          case parseURI (T.unpack url) of
            Nothing -> pure (Left (FetchInvalidUrl url))
            Just uri
              | scheme /= "http" && scheme /= "https" -> pure (Left (FetchInvalidUrl url))
              | otherwise -> do
                  requestResult <- try (parseRequest (T.unpack url))
                  case requestResult of
                    Left (err :: SomeException) -> pure (Left (FetchInvalidUrl (T.pack (show err))))
                    Right request -> do
                      let hostName = TE.decodeUtf8 (host request)
                      allowed <- assertPublicHost opts hostName
                      case allowed of
                        Left err -> pure (Left err)
                        Right () -> do
                          responseResult <- try (httpLbs (request {redirectCount = 0, responseTimeout = responseTimeoutMicro (foTimeoutMs opts * 1000), requestHeaders = mergeHeaders request}) (foManager opts))
                          case responseResult of
                            Left (err :: HttpException) -> pure (Left (FetchNetwork (T.pack (show err))))
                            Right response ->
                              let code = statusCode (responseStatus response)
                                  headers = responseHeaders response
                               in if code >= 300 && code < 400
                                    then case lookup hLocation headers of
                                      Nothing -> pure (Left (FetchHttp code))
                                      Just location -> case resolve url (TE.decodeUtf8 location) of
                                        Nothing -> pure (Left (FetchInvalidUrl (TE.decodeUtf8 location)))
                                        Just next -> go (hops + 1) next
                                    else if code >= 400
                                      then pure (Left (FetchHttp code))
                                      else do
                                        let body = LBS.toStrict (LBS.take (fromIntegral (foMaxBytes opts)) (responseBody response))
                                            contentType = maybe "" TE.decodeUtf8 (lookup hContentType headers)
                                        pure (Right (FetchPage url code contentType body))
              where
                scheme = map toLower (takeWhile (/= ':') (uriScheme uri))

    mergeHeaders request =
      (hUserAgent, "eza-bookmarks")
        : (hContentType, "text/html,application/xhtml+xml,image/*;q=0.8,*/*;q=0.5")
        : filter (\(name, _) -> name /= hUserAgent && name /= hContentType) (requestHeaders request)

    resolve base reference =
      case parseURI (T.unpack reference) of
        Just uri
          | uriScheme uri /= "" -> Just (T.pack (show uri))
        _ -> case parseURI (T.unpack base) of
          Just baseUri -> case parseURI (T.unpack reference) of
            Just resolved -> Just (T.pack (show (resolved `relativeTo` baseUri)))
            Nothing -> Nothing
          Nothing -> Nothing

assertPublicHost :: FetchOptions -> Text -> IO (Either FetchError ())
assertPublicHost opts host
  | foAllowPrivate opts = pure (Right ())
  | T.null host = pure (Left (FetchInvalidUrl host))
  | otherwise = do
      result <- try (getAddrInfo (Just defaultHints {addrSocketType = Stream}) (Just (T.unpack host)) Nothing)
      case result of
        Left (err :: SomeException) -> pure (Left (FetchNetwork (T.pack (show err))))
        Right [] -> pure (Left (FetchNetwork ("no address for " <> host)))
        Right addresses ->
          pure $ case find (isPrivateAddress . addrAddress) addresses of
            Just _ -> Left (FetchBlocked ("refusing private address for " <> host))
            Nothing -> Right ()

isPrivateAddress :: SockAddr -> Bool
isPrivateAddress address = case address of
  SockAddrInet _ hostAddress -> not (publicV4 hostAddress)
  SockAddrInet6 _ _ hostAddress _ -> not (publicV6 hostAddress)
  _ -> True

publicV4 :: Word32 -> Bool
publicV4 address =
  not
    ( address <= 0xffffff
        || address .&. 0xff000000 == 0x0a000000
        || address .&. 0xff000000 == 0x7f000000
        || address .&. 0xffff0000 == 0xa9fe0000
        || address .&. 0xfff00000 == 0xac100000
        || address .&. 0xffff0000 == 0xc0a80000
        || address .&. 0xffff0000 == 0xc6120000
        || address .&. 0xffffff00 == 0xc0000000
        || address .&. 0xffffff00 == 0xc0000200
        || address .&. 0xfffe0000 == 0xc6120000
        || address .&. 0xffffff00 == 0xc6336400
        || address .&. 0xffffff00 == 0xcb007100
        || address .&. 0xf0000000 == 0xe0000000
        || address .&. 0xf0000000 == 0xf0000000
    )

publicV6 :: HostAddress6 -> Bool
publicV6 (a, b, c, d) =
  not
    ( (a, b, c, d) == (0, 0, 0, 0)
        || (a, b, c, d) == (0, 0, 0, 1)
        || (a, b, c) == (0, 0, 0xffff)
        || a .&. 0xfe000000 == 0xfc000000
        || a .&. 0xffc00000 == 0xfe800000
        || a .&. 0xff000000 == 0xff000000
        || a == 0x20010db8
    )
