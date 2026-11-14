{- | The client's transport and interface error type.

'Eza.Web.Api' turns a failed request, a non-2xx status, or a response body the
client cannot read into an 'ApiError'; the update function decides whether it
becomes a toast, an inline panel message, or a sign-in redirect. This is a
client wrapper, not a wire DTO: the server's one error body shape is
'Eza.Problem'.
-}
module Eza.Web.Logic.Error (
    ApiError (..),
    mkApiError,
) where

import Data.Text (Text)
import qualified Data.Text as T

{- | A failed API call. @aeStatus@ is @Nothing@ for a network or decode
failure, and the HTTP status otherwise.
-}
data ApiError = ApiError
    { aeStatus :: Maybe Int
    , aeMessage :: Text
    }
    deriving (Eq, Show)

{- | Build an 'ApiError' from the response status and any server message. A
non-JSON body has no message, so the status alone picks the fallback text; an
empty body on a success path never reaches here.
-}
mkApiError :: Maybe Int -> Maybe Text -> ApiError
mkApiError status msg =
    ApiError status $ case msg of
        Just m | not (T.null (T.strip m)) -> m
        _ -> case status of
            Just 401 -> "Your session expired. Sign in again to continue."
            Just 403 -> "Not allowed (CSRF token missing or stale)."
            Just 404 -> "This endpoint is not available yet (planned route)."
            Just 409 -> "Conflict: the server refused the change."
            Just 413 -> "That file is too large."
            Just 429 -> "Rate limited: try again in a moment."
            Just n -> "Request failed (HTTP " <> T.pack (show n) <> ")."
            Nothing -> "Network error: the server did not answer."
