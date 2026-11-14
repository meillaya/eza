{-# LANGUAGE OverloadedStrings #-}

{- | The one HTTP transport of the client: it performs the browser fetch for a
native 'ClientRequest' and delivers the raw body back to the reducer's
continuation. It owns the cookie/CSRF plumbing, the browser network call and
the error-envelope decoding; the URL and HTTP method come from the native
request table and the typed decoding belongs to "Eza.Web.Logic.Requests".

Reducers never see this module. They emit 'ApiRequest' values and the
interpreter hands them here.
-}
module Eza.Web.Transport (
    performRequest,
    uploadImport,
    performFetch,
) where

import Data.Aeson (Value (..))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (stripPrefix)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

import Miso
import qualified Miso.JSON as MJ

import Eza.Web.Logic.Api (ClientRequest, requestMethod, requestPath)
import Eza.Web.Logic.Error (ApiError (..), mkApiError)
import Eza.Web.Logic.Requests (ImportResponse)
import qualified Eza.Web.Logic.Requests as Requests

-- --------------------------------------------------------------- requests ---

csrfToken :: IO MisoString
csrfToken = do
    cookie <- fromJSVal =<< (jsg "document" ! "cookie")
    pure $ case (cookie :: Maybe MisoString) of
        Nothing -> ""
        Just raw -> ms (findCookie "eza_csrf" (fromMisoString raw))

findCookie :: String -> String -> String
findCookie name raw =
    fromMaybe "" $
        case [v | part <- splitSemi raw, Just v <- [stripPrefix (name ++ "=") (trim part)]] of
            (v : _) -> Just v
            [] -> Nothing

splitSemi :: String -> [String]
splitSemi s = case break (== ';') s of
    (a, []) -> [a]
    (a, _ : rest) -> a : splitSemi rest

trim :: String -> String
trim = dropWhile isSpaceEnd . reverse . dropWhile isSpaceEnd . reverse

isSpaceEnd :: Char -> Bool
isSpaceEnd c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

{- | One raw HTTP exchange as the browser reports it. @rfStatus@ is @0@ when
the request never reached the server; @rfError@ then carries the transport
message.
-}
data RawResponse = RawResponse
    { rfStatus :: Int
    , rfText :: Text
    , rfError :: Maybe Text
    }

rawResponse :: Int -> MisoString -> MisoString -> RawResponse
rawResponse status body transportError =
    RawResponse
        { rfStatus = status
        , rfText = fromMisoString body
        , rfError =
            let message = fromMisoString transportError
             in if T.null (T.strip message) then Nothing else Just message
        }

requestHeaders :: [(MisoString, MisoString)] -> MisoString -> [(MisoString, MisoString)]
requestHeaders extra token =
    [ ("Accept", "application/json")
    , ("Content-Type", "application/json")
    ]
        ++ (if T.null (fromMisoString token) then [] else [("X-CSRF-Token", token)])
        ++ extra

{- | Map a raw exchange onto the API contract: transport failure, non-2xx
(envelope message preserved), then a strict JSON parse of a non-empty body.
An empty success body is @Null@: deletes and 204 answers have nothing to read.
-}
rawOutcome :: Text -> RawResponse -> Either ApiError Value
rawOutcome endpoint raw = case (rfStatus raw, rfError raw) of
    (0, Just message) ->
        Left (mkApiError Nothing (Just message))
    (status, _)
        | status < 200 || status >= 300 -> Left (statusError status raw)
        | T.null (T.strip (rfText raw)) -> Right Null
        | otherwise ->
            case A.eitherDecodeStrict' (TE.encodeUtf8 (rfText raw)) :: Either String Value of
                Right value -> Right value
                Left err -> Left (bodyError endpoint (T.pack err))

bodyError :: Text -> Text -> ApiError
bodyError endpoint detail =
    mkApiError
        Nothing
        (Just ("The response from " <> describeEndpoint endpoint <> " could not be read: " <> detail))

describeEndpoint :: Text -> Text
describeEndpoint endpoint
    | T.null label = "the server"
    | otherwise = label
  where
    label = T.strip endpoint

statusError :: Int -> RawResponse -> ApiError
statusError status raw = mkApiError (Just status) (serverMessage (rfText raw))

serverMessage :: Text -> Maybe Text
serverMessage body
    | T.null trimmed = Nothing
    | "{" `T.isPrefixOf` trimmed =
        case A.eitherDecodeStrict' (TE.encodeUtf8 trimmed) :: Either String Value of
            Right value -> firstText [["error", "message"], ["message"], ["error", "code"]] value
            Left _ -> Nothing
    | "<" `T.isPrefixOf` trimmed = Nothing
    | otherwise = Just (T.take 300 trimmed)
  where
    trimmed = T.strip body

firstText :: [[Text]] -> Value -> Maybe Text
firstText paths value = firstJust (map (`textAtPath` value) paths)

firstJust :: [Maybe a] -> Maybe a
firstJust [] = Nothing
firstJust (Just value : _) = Just value
firstJust (Nothing : rest) = firstJust rest

textAtPath :: [Text] -> Value -> Maybe Text
textAtPath [] value = case value of
    A.String message | not (T.null (T.strip message)) -> Just (T.strip message)
    _ -> Nothing
textAtPath (key : rest) value = case value of
    A.Object fields -> textAtPath rest =<< KM.lookup (K.fromText key) fields
    _ -> Nothing

-- --------------------------------------------------------------- transport ---

{- | Fire one request from a native request record. The continuation receives
the transport outcome, already narrowed to the API contract.
-}
performRequest ::
    ClientRequest ->
    Maybe Value ->
    (Either ApiError Value -> action) ->
    Effect () () model action
performRequest request requestBody onResult =
    withSink $ \sink -> do
        token <- csrfToken
        encodedBody <- traverse (toJSVal . MJ.encode) requestBody
        let endpoint = requestPath request
            report raw = sink (onResult (rawOutcome endpoint raw))
        finish <- asyncCallback3 $ \statusValue textValue errorValue -> do
            statusNumber <- fromJSVal statusValue :: IO (Maybe Double)
            body <- fromMaybe "" <$> (fromJSVal textValue :: IO (Maybe MisoString))
            transportError <- fromMaybe "" <$> (fromJSVal errorValue :: IO (Maybe MisoString))
            let status = maybe 0 round statusNumber
            report (rawResponse status body transportError)
        net <- jsg ("EzaNet" :: MisoString)
        urlValue <- toJSVal (ms (requestPath request))
        methodValue <- toJSVal (ms (requestMethod request))
        bodyValue <- toJSVal encodedBody
        headersValue <- toJSVal (M.fromList (requestHeaders [] token))
        _ <- net # ("fetch" :: MisoString) $ (urlValue, methodValue, bodyValue, headersValue, finish)
        pure ()

{- | A GET read decoded through the shared request surface. The ledger slice
still emits 'Fetch' and this is how the interpreter runs it.
-}
performFetch ::
    ClientRequest ->
    (Either ApiError Value -> action) ->
    Effect () () model action
performFetch request = performRequest request Nothing

{- | Upload the chosen import file (multipart FormData lives in pwa.js). The
endpoint label still comes from the shared request table.
-}
uploadImport ::
    (ImportResponse -> action) ->
    (ApiError -> action) ->
    Effect () () model action
uploadImport onOk onErr = withSink $ \sink -> do
    token <- csrfToken
    finish <- asyncCallback3 $ \statusValue textValue errorValue -> do
        statusNumber <- fromJSVal statusValue :: IO (Maybe Double)
        body <- fromMaybe "" <$> (fromJSVal textValue :: IO (Maybe MisoString))
        transportError <- fromMaybe "" <$> (fromJSVal errorValue :: IO (Maybe MisoString))
        let status = maybe 0 round statusNumber
            endpoint = requestPath Requests.submitImportRequest
        sink $ case rawOutcome endpoint (rawResponse status body transportError) of
            Left err -> onErr err
            Right value -> either onErr onOk (Requests.decodeResponseAt endpoint value)
    net <- jsg ("EzaNet" :: MisoString)
    inputId <- toJSVal ("import-file" :: MisoString)
    tokenValue <- toJSVal token
    _ <- net # ("upload" :: MisoString) $ (inputId, tokenValue, finish)
    pure ()
