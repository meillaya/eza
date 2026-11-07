{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | WebAuthn relying-party operations, sessions, recovery codes, and
-- passkey management.
module Eza.Auth
  ( AuthConfig (..)
  , AuthError (..)
  , Session (..)
  , NewSession (..)
  , RegistrationOutcome (..)
  , CredentialView (..)
  , countCredentials
  , setupClaimed
  , hasRecoverySession
  , setupAllowed
  , registrationOptions
  , authenticationOptions
  , addPasskeyOptions
  , verifyRegistration
  , verifyLogin
  , verifyAddPasskey
  , createSession
  , getSession
  , deleteSession
  , deleteSessionHash
  , issueRecoveryCodes
  , redeemRecoveryCode
  , regenerateRecoveryCodes
  , listCredentials
  , recoveryCodesRemaining
  , renameCredential
  , deleteCredential
  , decodeCredentialId
  , cleanupExpired
  , sessionCookieName
  , csrfCookieName
  , hashToken
  ) where

import Control.Monad (forM, forM_, unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64.URL as B64
import qualified Data.ByteString.Lazy as LBS
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import qualified Data.Validation as V
import Database.SQLite.Simple
import GHC.Generics (Generic)
import Time.System (dateCurrent)

import qualified Crypto.WebAuthn as WA

data AuthConfig = AuthConfig
  { acOrigin :: Text
  , acRpId :: Text
  , acRpName :: Text
  }
  deriving (Show, Eq)

data AuthError = AuthError
  { aeStatus :: Int
  , aeCode :: Text
  , aeMessage :: Text
  }
  deriving (Show, Eq)

data Session = Session
  { sessId :: Text
  , sessCsrf :: Text
  , sessScope :: Text
  , sessExpiresAt :: Int
  }
  deriving (Show, Eq)

data NewSession = NewSession
  { nsToken :: Text
  , nsCsrf :: Text
  , nsScope :: Text
  }
  deriving (Show, Eq)

data CredentialView = CredentialView
  { cvId :: Text
  , cvNickname :: Text
  , cvCreatedAt :: Int
  , cvLastUsedAt :: Maybe Int
  , cvBackupEligible :: Bool
  }
  deriving (Show, Eq, Generic)

instance ToJSON CredentialView where
  toJSON cv =
    object
      [ "id" .= cvId cv
      , "nickname" .= cvNickname cv
      , "created_at" .= cvCreatedAt cv
      , "last_used_at" .= cvLastUsedAt cv
      , "backup_eligible" .= cvBackupEligible cv
      ]

data RegistrationOutcome = RegistrationOutcome
  { roCodes :: Maybe [Text]
  , roSession :: Maybe NewSession
  }

sessionCookieName, csrfCookieName :: Text
sessionCookieName = "eza_session"
csrfCookieName = "eza_csrf"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

authError :: Int -> Text -> Text -> AuthError
authError = AuthError

epoch :: IO Int
epoch = floor <$> getPOSIXTime

randomToken :: Int -> IO Text
randomToken n = TE.decodeUtf8 . B64.encodeUnpadded <$> getRandomBytes n

hashToken :: Text -> Text
hashToken raw = T.pack (show (hash (TE.encodeUtf8 raw) :: Digest SHA256))

base64Id :: BS.ByteString -> Text
base64Id = TE.decodeUtf8 . B64.encodeUnpadded

decodeCredentialId :: Text -> Maybe BS.ByteString
decodeCredentialId t =
  case B64.decodeUnpadded (TE.encodeUtf8 t) of
    Left _ -> Nothing
    Right bs -> Just bs

-- ---------------------------------------------------------------------------
-- Setup / credential counts
-- ---------------------------------------------------------------------------

countCredentials :: Connection -> IO Int
countCredentials conn = do
  [Only n] <- query_ conn "SELECT COUNT(*) FROM passkey_credentials" :: IO [Only Int]
  pure n

setupClaimed :: Connection -> IO Bool
setupClaimed conn = do
  rows <- query_ conn "SELECT setup_claimed FROM app_state WHERE id = 1" :: IO [Only Int]
  pure (case rows of [Only n] -> n /= 0; _ -> False)

hasRecoverySession :: Connection -> IO Bool
hasRecoverySession conn = do
  now <- epoch
  rows <- query conn "SELECT 1 FROM sessions WHERE scope = 'recovery' AND expires_at > ?" (Only now) :: IO [Only Int]
  pure (not (null rows))

setupAllowed :: Connection -> IO Bool
setupAllowed conn = do
  n <- countCredentials conn
  claimed <- setupClaimed conn
  rec <- hasRecoverySession conn
  pure (n == 0 && (not claimed || rec))

-- ---------------------------------------------------------------------------
-- Challenges
-- ---------------------------------------------------------------------------

storeChallenge :: Connection -> Text -> BS.ByteString -> IO ()
storeChallenge conn purpose challenge = do
  now <- epoch
  withImmediateTransaction conn $ do
    execute conn "DELETE FROM webauthn_challenges WHERE purpose = ?" (Only purpose)
    execute
      conn
      "INSERT INTO webauthn_challenges (challenge, purpose, created_at, expires_at) VALUES (?,?,?,?)"
      (challenge, purpose, now, now + 300)

consumeChallenge :: Connection -> Text -> IO (Maybe BS.ByteString)
consumeChallenge conn purpose = do
  now <- epoch
  rows <-
    query
      conn
      "SELECT challenge, expires_at FROM webauthn_challenges WHERE purpose = ? ORDER BY created_at DESC LIMIT 1"
      (Only purpose) :: IO [(BS.ByteString, Int)]
  case rows of
    [] -> pure Nothing
    ((challenge, expires) : _) -> do
      withImmediateTransaction conn $ execute conn "DELETE FROM webauthn_challenges WHERE challenge = ?" (Only challenge)
      pure (if expires > now then Just challenge else Nothing)

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

registrationOptionsFor :: AuthConfig -> BS.ByteString -> [WA.CredentialDescriptor] -> WA.CredentialOptions 'WA.Registration
registrationOptionsFor ac challenge exclude =
  WA.CredentialOptionsRegistration
    { WA.corRp =
        WA.CredentialRpEntity
          { WA.creId = Just (WA.RpId (acRpId ac))
          , WA.creName = WA.RelyingPartyName (acRpName ac)
          }
    , WA.corUser =
        WA.CredentialUserEntity
          { WA.cueId = WA.UserHandle "\x01"
          , WA.cueDisplayName = WA.UserAccountDisplayName "eza"
          , WA.cueName = WA.UserAccountName "eza"
          }
    , WA.corChallenge = WA.Challenge challenge
    , WA.corPubKeyCredParams =
        [ WA.CredentialParameters
            { WA.cpTyp = WA.CredentialTypePublicKey
            , WA.cpAlg = WA.CoseAlgorithmES256
            }
        , WA.CredentialParameters
            { WA.cpTyp = WA.CredentialTypePublicKey
            , WA.cpAlg = WA.CoseAlgorithmRS256
            }
        ]
    , WA.corTimeout = Just (WA.Timeout 60000)
    , WA.corExcludeCredentials = exclude
    , WA.corAuthenticatorSelection =
        Just
          WA.AuthenticatorSelectionCriteria
            { WA.ascAuthenticatorAttachment = Nothing
            , WA.ascResidentKey = WA.ResidentKeyRequirementRequired
            , WA.ascUserVerification = WA.UserVerificationRequirementRequired
            }
    , WA.corHints = []
    , WA.corAttestation = WA.AttestationConveyancePreferenceNone
    , WA.corExtensions = Nothing
    }

authenticationOptionsFor :: AuthConfig -> BS.ByteString -> WA.CredentialOptions 'WA.Authentication
authenticationOptionsFor ac challenge =
  WA.CredentialOptionsAuthentication
    { WA.coaRpId = Just (WA.RpId (acRpId ac))
    , WA.coaTimeout = Just (WA.Timeout 60000)
    , WA.coaChallenge = WA.Challenge challenge
    , WA.coaAllowCredentials = []
    , WA.coaUserVerification = WA.UserVerificationRequirementRequired
    , WA.coaHints = []
    , WA.coaExtensions = Nothing
    }

registrationOptions :: Connection -> AuthConfig -> Bool -> IO (Either AuthError Value)
registrationOptions conn ac forSetup = do
  allowed <- if forSetup then setupAllowed conn else pure True
  if not allowed
    then pure (Left (authError 403 "setup_unavailable" "setup is not available"))
    else do
      challenge <- getRandomBytes 32
      storeChallenge conn "registration" challenge
      excludes <- if forSetup then pure [] else existingDescriptors conn
      let opts = registrationOptionsFor ac challenge excludes
      pure (Right (toJSON (WA.wjEncodeCredentialOptionsRegistration opts)))

existingDescriptors :: Connection -> IO [WA.CredentialDescriptor]
existingDescriptors conn = do
  rows <- query_ conn "SELECT credential_id FROM passkey_credentials" :: IO [Only BS.ByteString]
  pure
    [ WA.CredentialDescriptor
        { WA.cdTyp = WA.CredentialTypePublicKey
        , WA.cdId = WA.CredentialId cid
        , WA.cdTransports = Just []
        }
    | Only cid <- rows
    ]

authenticationOptions :: Connection -> AuthConfig -> IO (Either AuthError Value)
authenticationOptions conn ac = do
  n <- countCredentials conn
  if n == 0
    then pure (Left (authError 400 "no_credentials" "no passkeys are registered"))
    else do
      challenge <- getRandomBytes 32
      storeChallenge conn "authentication" challenge
      let opts = authenticationOptionsFor ac challenge
      pure (Right (toJSON (WA.wjEncodeCredentialOptionsAuthentication opts)))

addPasskeyOptions :: Connection -> AuthConfig -> IO (Either AuthError Value)
addPasskeyOptions conn ac = registrationOptions conn ac False

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------

rpHash :: AuthConfig -> WA.RpIdHash
rpHash ac = WA.RpIdHash (hash (TE.encodeUtf8 (acRpId ac)))

verifyRegistration :: Connection -> AuthConfig -> Bool -> Value -> IO (Either AuthError RegistrationOutcome)
verifyRegistration conn ac forSetup body =
  case fromJSON body :: Result WA.WJCredentialRegistration of
    Error _ -> pure (Left (authError 400 "bad_request" "malformed registration response"))
    Success wjCredential ->
      case WA.wjDecodeCredentialRegistration wjCredential of
        Left _ -> pure (Left (authError 400 "bad_request" "malformed registration response"))
        Right cred -> do
          mChallenge <- consumeChallenge conn "registration"
          case mChallenge of
            Nothing -> pure (Left (authError 400 "challenge" "challenge is unknown, expired, or already used"))
            Just challenge -> do
              now <- dateCurrent
              let options = registrationOptionsFor ac challenge []
                  origin = WA.Origin (acOrigin ac)
              case WA.verifyRegistrationResponse (origin :| []) (rpHash ac) mempty now options cred of
                V.Failure _ -> pure (Left (authError 400 "verification" "registration response failed verification"))
                V.Success result -> do
                  storeCredential conn (WA.rrEntry result)
                  if forSetup
                    then do
                      setSetupClaimed conn
                      codes <- issueRecoveryCodes conn
                      sess <- createSession conn "normal" (30 * 24 * 3600)
                      pure (Right (RegistrationOutcome (Just codes) (Just sess)))
                    else pure (Right (RegistrationOutcome Nothing Nothing))

storeCredential :: Connection -> WA.CredentialEntry -> IO ()
storeCredential conn entry = do
  now <- epoch
  let cid = WA.unCredentialId (WA.ceCredentialId entry)
      pk = WA.unPublicKeyBytes (WA.cePublicKeyBytes entry)
      sign = fromIntegral (WA.unSignatureCounter (WA.ceSignCounter entry)) :: Int
      uh = WA.unUserHandle (WA.ceUserHandle entry)
  withImmediateTransaction conn $
    executeNamed
      conn
      "INSERT OR REPLACE INTO passkey_credentials (credential_id,user_handle,public_key,sign_count,transports,backup_eligible,backup_state,aaguid,nickname,created_at,last_used_at) VALUES (:cid,:uh,:pk,:sign,:transports,:be,:bs,:aaguid,:nick,:created,:used)"
      [ ":cid" := cid
      , ":uh" := uh
      , ":pk" := pk
      , ":sign" := sign
      , ":transports" := ("[]" :: Text)
      , ":be" := (0 :: Int)
      , ":bs" := (0 :: Int)
      , ":aaguid" := BS.empty
      , ":nick" := ("" :: Text)
      , ":created" := now
      , ":used" := now
      ]

setSetupClaimed :: Connection -> IO ()
setSetupClaimed conn =
  withImmediateTransaction conn $ execute_ conn "UPDATE app_state SET setup_claimed = 1 WHERE id = 1"

verifyLogin :: Connection -> AuthConfig -> Value -> IO (Either AuthError NewSession)
verifyLogin conn ac body =
  case fromJSON body :: Result WA.WJCredentialAuthentication of
    Error _ -> pure (Left (authError 400 "bad_request" "malformed authentication response"))
    Success wjCredential ->
      case WA.wjDecodeCredentialAuthentication wjCredential of
        Left _ -> pure (Left (authError 400 "bad_request" "malformed authentication response"))
        Right cred -> do
          mChallenge <- consumeChallenge conn "authentication"
          case mChallenge of
            Nothing -> pure (Left (authError 400 "challenge" "challenge is unknown, expired, or already used"))
            Just challenge -> do
              mEntry <- loadEntry conn (WA.unCredentialId (WA.cIdentifier cred))
              case mEntry of
                Nothing -> pure (Left (authError 401 "unknown_credential" "unknown credential"))
                Just entry -> do
                  now <- dateCurrent
                  let options = authenticationOptionsFor ac challenge
                      origin = WA.Origin (acOrigin ac)
                  case WA.verifyAuthenticationResponse (origin :| []) (rpHash ac) (Just (WA.ceUserHandle entry)) entry options cred of
                    V.Failure _ -> pure (Left (authError 401 "login_failed" "authentication failed"))
                    V.Success (WA.AuthenticationResult counter) -> do
                      recordCredentialUse conn (WA.unCredentialId (WA.ceCredentialId entry)) counter
                      Right <$> createSession conn "normal" (30 * 24 * 3600)

verifyAddPasskey :: Connection -> AuthConfig -> Value -> IO (Either AuthError ())
verifyAddPasskey conn ac body = do
  result <- verifyRegistration conn ac False body
  pure (() <$ result)

recordCredentialUse :: Connection -> BS.ByteString -> WA.SignatureCounterResult -> IO ()
recordCredentialUse conn cid counter = do
  now <- epoch
  case counter of
    WA.SignatureCounterUpdated (WA.SignatureCounter n) -> do
      withImmediateTransaction conn $ do
        execute conn "UPDATE passkey_credentials SET last_used_at = ?, sign_count = ? WHERE credential_id = ?" (now, fromIntegral n :: Int, cid)
    _ ->
      withImmediateTransaction conn $
        execute conn "UPDATE passkey_credentials SET last_used_at = ? WHERE credential_id = ?" (now, cid)

loadEntry :: Connection -> BS.ByteString -> IO (Maybe WA.CredentialEntry)
loadEntry conn cid = do
  rows <-
    query
      conn
      "SELECT credential_id,user_handle,public_key,sign_count,transports FROM passkey_credentials WHERE credential_id = ?"
      (Only cid) :: IO [(BS.ByteString, BS.ByteString, BS.ByteString, Int, Text)]
  case rows of
    [] -> pure Nothing
    ((cid', uh, pk, sign, _transportsText) : _) -> do
      pure
        ( Just
            WA.CredentialEntry
              { WA.ceCredentialId = WA.CredentialId cid'
              , WA.ceUserHandle = WA.UserHandle uh
              , WA.cePublicKeyBytes = WA.PublicKeyBytes pk
              , WA.ceSignCounter = WA.SignatureCounter (fromIntegral sign)
              , WA.ceTransports = []
              }
        )

-- ---------------------------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------------------------

createSession :: Connection -> Text -> Int -> IO NewSession
createSession conn scope ttl = do
  token <- randomToken 32
  csrf <- randomToken 32
  now <- epoch
  withImmediateTransaction conn $
    execute
      conn
      "INSERT INTO sessions (id,csrf_hash,scope,created_at,expires_at,last_seen_at) VALUES (?,?,?,?,?,?)"
      (hashToken token, hashToken csrf, scope, now, now + ttl, now)
  pure (NewSession token csrf scope)

getSession :: Connection -> Text -> IO (Maybe Session)
getSession conn rawToken
  | T.null rawToken = pure Nothing
  | otherwise = do
      now <- epoch
      rows <-
        query
          conn
          "SELECT csrf_hash,scope,expires_at FROM sessions WHERE id = ?"
          (Only (hashToken rawToken)) :: IO [(Text, Text, Int)]
      case rows of
        [] -> pure Nothing
        ((csrfHash, scope, expires) : _)
          | expires <= now -> pure Nothing
          | otherwise -> do
              withImmediateTransaction conn $
                execute conn "UPDATE sessions SET last_seen_at = ? WHERE id = ?" (now, hashToken rawToken)
              pure (Just (Session (hashToken rawToken) csrfHash scope expires))

deleteSession :: Connection -> Text -> IO ()
deleteSession conn rawToken =
  withImmediateTransaction conn $
    execute conn "DELETE FROM sessions WHERE id = ?" (Only (hashToken rawToken))

deleteSessionHash :: Connection -> Text -> IO ()
deleteSessionHash conn sessionHash =
  withImmediateTransaction conn $
    execute conn "DELETE FROM sessions WHERE id = ?" (Only sessionHash)

-- ---------------------------------------------------------------------------
-- Recovery codes
-- ---------------------------------------------------------------------------

issueRecoveryCodes :: Connection -> IO [Text]
issueRecoveryCodes conn = do
  now <- epoch
  codes <- mapM (const (randomToken 16)) [1 .. 10 :: Int]
  withImmediateTransaction conn $
    forM_ codes $ \code ->
      execute
        conn
        "INSERT INTO recovery_codes (code_hash, used, created_at) VALUES (?, 0, ?)"
        (hashToken code, now)
  pure codes

regenerateRecoveryCodes :: Connection -> IO [Text]
regenerateRecoveryCodes conn = do
  withImmediateTransaction conn $ execute_ conn "DELETE FROM recovery_codes"
  issueRecoveryCodes conn

redeemRecoveryCode :: Connection -> Text -> IO (Either AuthError NewSession)
redeemRecoveryCode conn code = do
  rows <-
    query
      conn
      "SELECT 1 FROM recovery_codes WHERE code_hash = ? AND used = 0"
      (Only (hashToken code)) :: IO [Only Int]
  if null rows
    then pure (Left (authError 400 "bad_code" "unknown or already-used recovery code"))
    else do
      sess <- createSession conn "recovery" (10 * 60)
      now <- epoch
      withImmediateTransaction conn $ do
        execute_ conn "DELETE FROM passkey_credentials"
        execute conn "DELETE FROM sessions WHERE id != ?" (Only (hashToken (nsToken sess)))
        execute
          conn
          "UPDATE recovery_codes SET used = 1, redeemed_at = ? WHERE code_hash = ?"
          (now, hashToken code)
      pure (Right sess)

-- ---------------------------------------------------------------------------
-- Account
-- ---------------------------------------------------------------------------

listCredentials :: Connection -> IO [CredentialView]
listCredentials conn = do
  rows <-
    query_
      conn
      "SELECT credential_id,nickname,created_at,last_used_at,backup_eligible FROM passkey_credentials ORDER BY created_at ASC" :: IO [(BS.ByteString, Text, Int, Maybe Int, Int)]
  pure
    [ CredentialView (base64Id cid) nick created lastUsed (be /= 0)
    | (cid, nick, created, lastUsed, be) <- rows
    ]

recoveryCodesRemaining :: Connection -> IO Int
recoveryCodesRemaining conn = do
  [Only n] <- query_ conn "SELECT COUNT(*) FROM recovery_codes WHERE used = 0" :: IO [Only Int]
  pure n

renameCredential :: Connection -> BS.ByteString -> Text -> IO Bool
renameCredential conn cid nick = do
  n <- withImmediateTransaction conn $ do
    execute conn "UPDATE passkey_credentials SET nickname = ? WHERE credential_id = ?" (nick, cid)
    changes conn
  pure (n > 0)

deleteCredential :: Connection -> BS.ByteString -> IO (Either AuthError ())
deleteCredential conn cid = do
  n <- countCredentials conn
  if n <= 1
    then pure (Left (authError 409 "last_credential" "cannot revoke the last passkey; use a recovery code to re-enroll"))
    else do
      changed <- withImmediateTransaction conn $ do
        execute conn "DELETE FROM passkey_credentials WHERE credential_id = ?" (Only cid)
        changes conn
      pure (if changed > 0 then Right () else Left (authError 404 "not_found" "unknown passkey"))

-- ---------------------------------------------------------------------------
-- Housekeeping
-- ---------------------------------------------------------------------------

cleanupExpired :: Connection -> IO ()
cleanupExpired conn = do
  now <- epoch
  withImmediateTransaction conn $ do
    execute conn "DELETE FROM webauthn_challenges WHERE expires_at <= ?" (Only now)
    execute conn "DELETE FROM sessions WHERE expires_at <= ?" (Only now)

