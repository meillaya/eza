{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Part of the client update function; see "Eza.Web.Update".
module Eza.Web.Logic.Update.Account (
    handle,
    setSecurityError,
) where

import Control.Monad
import Data.Maybe (fromMaybe)
import qualified Data.Text as T

import Data.Text (Text)
import Eza.Account
import Eza.Rule
import Eza.User
import Eza.Web.Logic.Browser
import Eza.Web.Logic.Error
import Eza.Web.Logic.Job (JobKind (..))
import Eza.Web.Logic.Model
import Eza.Web.Logic.Requests
import Eza.Web.Logic.Update.Common
import Eza.Web.Logic.Update.Monad (Update, dispatch, get)
import Eza.Web.Logic.Update.ViewDefs (isUserEnabled, upsertUser, upsertWebhook)
import Eza.Webhook

setSecurityError :: Text -> Update ()
setSecurityError message =
    putModel (\m -> m{gAccount = (gAccount m){acSecurityBusy = False, acSecurityError = Just message}})

-- \| EA-00417: the accession form used by the dedup toast and dialog.

handle :: Action -> Update ()
handle = \case
    AccountTabSelected tab -> do
        putModel (\m -> m{gAccount = (gAccount m){acAccountTab = tab}})
        selectAccountTab (accountTabSlug tab)
        when (tab == AccountWebhooks) $ do
            m <- get
            when (null (mWebhooks m) && not (mWebhooksLoading m)) $ do
                putModel (\x -> x{gWebhooks = (gWebhooks x){wkWebhooksLoading = True, wkWebhooksError = Nothing}})
                fetchWebhooks WebhooksLoaded WebhooksFailed
        when (tab == AccountUsers) $ do
            m <- get
            when (null (mAdminUsers m) && not (mAdminUsersLoading m)) $ do
                putModel (\x -> x{gAccount = (gAccount x){acAdminUsersLoading = True, acAdminUsersError = Nothing}})
                fetchAdminUsers AdminUsersLoaded AdminUsersFailed
    -- library ---------------------------------------------------------------
    AccountLoaded info -> do
        putModel
            ( \m ->
                m
                    { gAccount =
                        (gAccount m)
                            { acAccount = Just info
                            , acAccountLoading = False
                            , acAccountError = Nothing
                            , acSessions = aiSessions info
                            , acSecurityUsername =
                                if T.null (T.strip ((mSecurityUsername m)))
                                    then (aiUsername info)
                                    else mSecurityUsername m
                            , acSecurity2faWanted = aiRequirePasskey info
                            , acAdminUsersLoading = null (mAdminUsers m)
                            }
                    }
            )
        m0 <- get
        when (mAdminUsersLoading m0) (fetchAdminUsers AdminUsersLoaded AdminUsersFailed)
    AccountFailed err -> do
        putModel (\m -> m{gAccount = (gAccount m){acAccountLoading = False, acAccountError = Just ((aeMessage err))}})
        handleApiError err
    RecoveryRegenerate -> regenerateRecovery RecoveryLoaded AccountFailed
    RecoveryLoaded codes -> do
        putModel (\m -> m{gAccount = (gAccount m){acRecoveryCodes = codes}})
        notify "New recovery codes. Store them now." ToastOk
    CredentialRenamed credentialId nickname -> do
        renameCredential credentialId nickname (ToastAdd "Passkey renamed" ToastOk) CredentialOpFailed
    CredentialDeleted credentialId -> deleteCredential credentialId (CredentialRemoved credentialId) CredentialOpFailed
    CredentialRemoved _ -> do
        notify "Passkey deleted" ToastOk
        fetchAccount AccountLoaded AccountFailed
    CredentialOpFailed err -> handleApiError err
    CredentialEditStart credentialId -> putModel (\m -> m{gAccount = (gAccount m){acCredEdit = Just (credentialId, "")}})
    CredentialNameInput nickname -> putModel (\m -> m{gAccount = (gAccount m){acCredEdit = fmap (\(cid, _) -> (cid, nickname)) (mCredEdit m)}})
    CredentialEditSave -> do
        m <- get
        case mCredEdit m of
            Nothing -> pure ()
            Just (credentialId, nickname) -> do
                putModel (\x -> x{gAccount = (gAccount x){acCredEdit = Nothing}})
                renameCredential credentialId nickname AccountReload CredentialOpFailed
    CredentialEditCancel -> putModel (\m -> m{gAccount = (gAccount m){acCredEdit = Nothing}})
    SecurityUsernameInput value -> putModel (\m -> m{gAccount = (gAccount m){acSecurityUsername = value, acSecurityError = Nothing}})
    SecurityCurrentPasswordInput value -> putModel (\m -> m{gAccount = (gAccount m){acSecurityCurrent = value, acSecurityError = Nothing}})
    SecurityNewPasswordInput value -> putModel (\m -> m{gAccount = (gAccount m){acSecurityNew = value, acSecurityError = Nothing}})
    SecurityConfirmPasswordInput value -> putModel (\m -> m{gAccount = (gAccount m){acSecurityConfirm = value, acSecurityError = Nothing}})
    Security2faWantedToggled wanted ->
        putModel (\m -> m{gAccount = (gAccount m){acSecurity2faWanted = wanted, acSecurityError = Nothing}})
    SecurityUsernameSave -> do
        m <- get
        case mAccount m of
            Nothing -> setSecurityError "The account has not loaded yet."
            Just account ->
                let wanted = T.strip ((mSecurityUsername m))
                    current = (mSecurityCurrent m)
                 in if T.null wanted
                        then setSecurityError "Enter the username."
                        else
                            if aiHasPassword account && T.null (T.strip current)
                                then setSecurityError "Enter the current password to rename the account."
                                else do
                                    putModel (\x -> x{gAccount = (gAccount x){acSecurityBusy = True, acSecurityError = Nothing}})
                                    patchUsername
                                        (if aiHasPassword account then Just current else Nothing)
                                        wanted
                                        (SecuritySaved "Username saved")
                                        SecurityFailed
    SecurityPasswordSave -> do
        m <- get
        case mAccount m of
            Nothing -> setSecurityError "The account has not loaded yet."
            Just account ->
                let current = (mSecurityCurrent m)
                    wanted = (mSecurityNew m)
                    repeated = (mSecurityConfirm m)
                 in if T.length wanted < 10
                        then setSecurityError "The new password must be at least ten characters."
                        else
                            if wanted /= repeated
                                then setSecurityError "The two new passwords do not match."
                                else
                                    if aiHasPassword account && T.null current
                                        then setSecurityError "Enter the current password."
                                        else do
                                            putModel (\x -> x{gAccount = (gAccount x){acSecurityBusy = True, acSecurityError = Nothing}})
                                            changePassword
                                                (if aiHasPassword account then Just current else Nothing)
                                                wanted
                                                repeated
                                                (SecuritySaved "Password changed")
                                                SecurityFailed
    Security2faSave -> do
        m <- get
        case mAccount m of
            Nothing -> setSecurityError "The account has not loaded yet."
            Just account
                | aiRequirePasskey account == mSecurity2faWanted m ->
                    setSecurityError "The passkey requirement is already in that state."
                | mSecurity2faWanted m && null (aiCredentials account) ->
                    setSecurityError "Add a passkey before requiring one for sign-in."
                | aiHasPassword account
                , T.null (T.strip ((mSecurityCurrent m))) ->
                    setSecurityError "Enter the current password."
                | otherwise -> do
                    putModel (\x -> x{gAccount = (gAccount x){acSecurityBusy = True, acSecurityError = Nothing}})
                    setPasskeyRequirement
                        (mSecurity2faWanted m)
                        ( if aiHasPassword account
                            then Just ((mSecurityCurrent m))
                            else Nothing
                        )
                        (SecuritySaved "Sign-in requirement saved")
                        SecurityFailed
    SecuritySaved message -> do
        putModel
            ( \m ->
                m{gAccount = (gAccount m){acSecurityBusy = False, acSecurityCurrent = "", acSecurityNew = "", acSecurityConfirm = "", acSecurityUsername = "", acSecurityError = Nothing}}
            )
        notify message ToastOk
        fetchAccount AccountLoaded AccountFailed
    SecurityFailed err -> do
        putModel (\m -> m{gAccount = (gAccount m){acSecurityBusy = False, acSecurityError = Just ((aeMessage err))}})
        when (aeStatus err == Just 401) (handleApiError err)
    SessionsRevokeOthers -> do
        putModel (\m -> m{gAccount = (gAccount m){acAccountLoading = True}})
        revokeOtherSessions SessionsRevoked SessionsRevokeFailed
    SessionsRevoked revoked -> do
        putModel (\m -> m{gAccount = (gAccount m){acAccountLoading = False}})
        notify
            ( T.pack
                ( "Revoked "
                    <> show revoked
                    <> (if revoked == 1 then " other session" else " other sessions")
                )
            )
            ToastOk
        fetchAccount AccountLoaded AccountFailed
    SessionsRevokeFailed err -> do
        putModel (\m -> m{gAccount = (gAccount m){acAccountLoading = False}})
        handleApiError err
    AccountReload -> fetchAccount AccountLoaded AccountFailed
    -- Signing out is a write, but an unsaved note would be lost silently, so
    -- the dirty editor asks first; a clean screen signs out immediately.
    LogoutRequest -> do
        m <- get
        if hasUnsaved m
            then putModel (\x -> x{gShell = (gShell x){sfConfirmLogout = True}})
            else dispatch Logout
    LogoutCancel -> putModel (\m -> m{gShell = (gShell m){sfConfirmLogout = False}})
    Logout -> logout LoggedOut (\err -> ApiErrorRaised err)
    LoggedOut -> redirect "/login"
    -- selection / bulk -----------------------------------------------------
    TokensLoaded tokens ->
        putModel (\m -> m{gAccount = (gAccount m){acTokens = tokens, acTokensLoading = False, acTokensError = Nothing}})
    TokensFailed err -> do
        putModel (\m -> m{gAccount = (gAccount m){acTokensLoading = False, acTokensError = Just ((aeMessage err))}})
        handleApiError err
    TokenNameInput value -> putModel (\m -> m{gAccount = (gAccount m){acTokenName = value}})
    TokenScopeToggled scope ->
        putModel
            ( \m ->
                m
                    { gAccount =
                        (gAccount m)
                            { acTokenScopes =
                                if scope `elem` mTokenScopes m
                                    then filter (/= scope) (mTokenScopes m)
                                    else mTokenScopes m ++ [scope]
                            }
                    }
            )
    TokenCreate -> do
        m <- get
        let name = T.strip ((mTokenName m))
        if T.null name
            then notify "Give the token a name" ToastInfo
            else
                if null (mTokenScopes m)
                    then notify "Pick at least one scope" ToastInfo
                    else do
                        putModel (\x -> x{gAccount = (gAccount x){acTokenBusy = True}})
                        createApiToken name (mTokenScopes m) TokenCreated TokenCreateFailed
    TokenCreated raw info -> do
        putModel
            ( \m ->
                m{gAccount = (gAccount m){acTokens = info : filter ((/= tvId info) . tvId) (mTokens m), acTokenName = "", acTokenBusy = False, acTokenSecret = Just (raw, info)}}
            )
        notify "Token created. Copy it now; it is shown once." ToastOk
    TokenCreateFailed err -> do
        putModel (\m -> m{gAccount = (gAccount m){acTokenBusy = False}})
        handleApiError err
    TokenRevoke tokenId -> revokeApiToken tokenId TokenRevoked TokenCreateFailed
    TokenRevoked -> do
        notify "Token revoked" ToastOk
        fetchTokens TokensLoaded TokensFailed
    TokenRevealDismiss -> putModel (\m -> m{gAccount = (gAccount m){acTokenSecret = Nothing}})
    TokenCopied raw -> copyText raw "Token copied" "Copy failed. Select the text instead"
    -- admin users ----------------------------------------------------------
    AdminUsersLoaded users ->
        putModel
            ( \m ->
                m{gAccount = (gAccount m){acAdminUsers = users, acAdminUsersAllowed = True, acAdminUsersLoading = False, acAdminUsersError = Nothing}}
            )
    AdminUsersFailed err -> do
        putModel
            ( \m ->
                m{gAccount = (gAccount m){acAdminUsersLoading = False, acAdminUsersAllowed = False, acAdminUsersError = if mAccountTab m == AccountUsers then Just ((aeMessage err)) else Nothing}}
            )
        when (aeStatus err == Just 401) (handleApiError err)
    UserNameInput value -> putModel (\m -> m{gAccount = (gAccount m){acUserName = value, acUserFormError = Nothing}})
    UserPasswordInput value -> putModel (\m -> m{gAccount = (gAccount m){acUserPassword = value, acUserFormError = Nothing}})
    UserRoleSelected role -> putModel (\m -> m{gAccount = (gAccount m){acUserRole = role}})
    UserCreate -> do
        m <- get
        let input =
                UserCreateInput
                    { uciUsername = T.strip ((mUserName m))
                    , uciPassword = (mUserPassword m)
                    , uciRole = mUserRole m
                    }
        putModel (\x -> x{gAccount = (gAccount x){acUserBusy = True, acUserFormError = Nothing}})
        createAdminUser input UserCreated UserCreateFailed
    UserCreated result -> do
        notify "User created. Copy the recovery codes now." ToastOk
        putModel
            ( \m ->
                m{gAccount = (gAccount m){acAdminUsers = upsertUser (ucrUser result) (mAdminUsers m), acAdminUsersLoading = False, acAdminUsersError = Nothing, acUserBusy = False, acUserFormError = Nothing, acUserName = "", acUserPassword = "", acUserRole = RoleMember, acUserRecovery = Just (uvUsername (ucrUser result), ucrRecoveryCodes result)}}
            )
    UserCreateFailed err -> do
        putModel (\m -> m{gAccount = (gAccount m){acUserBusy = False, acUserFormError = Just ((aeMessage err))}})
        when (aeStatus err == Just 401) (handleApiError err)
    UserToggleEnabled user ->
        patchAdminUser
            (uvId user)
            (Just (not (isUserEnabled user)))
            Nothing
            UserUpdated
            UserUpdateFailed
    UserRoleChange user ->
        patchAdminUser
            (uvId user)
            Nothing
            (Just (if uvRole user == RoleAdmin then RoleMember else RoleAdmin))
            UserUpdated
            UserUpdateFailed
    UserUpdated user -> do
        notify "User updated" ToastOk
        putModel
            ( \m ->
                m{gAccount = (gAccount m){acAdminUsers = upsertUser user (mAdminUsers m), acUserActionError = Nothing}}
            )
    UserUpdateFailed err ->
        putModel (\m -> m{gAccount = (gAccount m){acUserActionError = Just ((aeMessage err))}})
    UserResetOpen userId ->
        putModel (\m -> m{gAccount = (gAccount m){acUserReset = Just userId, acUserResetPassword = "", acUserActionError = Nothing}})
    UserResetPasswordInput value -> putModel (\m -> m{gAccount = (gAccount m){acUserResetPassword = value}})
    UserResetSubmit -> do
        m <- get
        case mUserReset m of
            Nothing -> pure ()
            Just userId ->
                let password = (mUserResetPassword m)
                 in if T.null (T.strip password)
                        then putModel (\x -> x{gAccount = (gAccount x){acUserActionError = Just "a temporary password is required"}})
                        else resetAdminPassword userId password (UserResetDone userId password) UserResetFailed
    UserResetDone userId password -> do
        notify "Temporary password set. The user's sessions were revoked." ToastOk
        putModel
            ( \m ->
                let username = case [uvUsername user | user <- mAdminUsers m, uvId user == userId] of
                        (name : _) -> name
                        [] -> T.pack (show userId)
                 in m{gAccount = (gAccount m){acUserReset = Nothing, acUserResetPassword = "", acUserResetShown = Just (username, password), acUserActionError = Nothing}}
            )
    UserResetCancel -> putModel (\m -> m{gAccount = (gAccount m){acUserReset = Nothing, acUserResetPassword = "", acUserActionError = Nothing}})
    UserResetFailed err ->
        putModel (\m -> m{gAccount = (gAccount m){acUserActionError = Just ((aeMessage err))}})
    UserRecoveryCopied raw -> copyText raw "Recovery codes copied" "Copy failed. Select the text instead"
    UserRecoveryDismiss -> putModel (\m -> m{gAccount = (gAccount m){acUserRecovery = Nothing}})
    UserResetShownDismiss -> putModel (\m -> m{gAccount = (gAccount m){acUserResetShown = Nothing}})
    UserDeleteOpen user ->
        putModel
            ( \m ->
                m{gAccount = (gAccount m){acUserDelete = Just user, acUserDeleteName = "", acUserDeleteLibrary = False, acUserDeleteBusy = False, acUserActionError = Nothing}}
            )
    UserDeleteCancel ->
        putModel
            ( \m ->
                m{gAccount = (gAccount m){acUserDelete = Nothing, acUserDeleteName = "", acUserDeleteLibrary = False, acUserDeleteBusy = False}}
            )
    UserDeleteNameInput value -> putModel (\m -> m{gAccount = (gAccount m){acUserDeleteName = value}})
    UserDeleteLibraryToggled -> putModel (\m -> m{gAccount = (gAccount m){acUserDeleteLibrary = not (mUserDeleteLibrary m)}})
    UserDeleteSubmit -> do
        m <- get
        case mUserDelete m of
            Just user
                | T.strip ((mUserDeleteName m)) == uvUsername user -> do
                    putModel (\x -> x{gAccount = (gAccount x){acUserDeleteBusy = True, acUserActionError = Nothing}})
                    deleteAdminUser (uvId user) (mUserDeleteLibrary m) (UserDeleted (uvId user)) UserDeleteFailed
                | otherwise ->
                    putModel (\x -> x{gAccount = (gAccount x){acUserActionError = Just "type the account name to confirm"}})
            Nothing -> pure ()
    UserDeleted userId -> do
        notify "Account deleted" ToastOk
        putModel
            ( \m ->
                m{gAccount = (gAccount m){acUserDelete = Nothing, acUserDeleteName = "", acUserDeleteLibrary = False, acUserDeleteBusy = False, acUserActionError = Nothing, acAdminUsers = [user | user <- mAdminUsers m, uvId user /= userId]}}
            )
        fetchAdminUsers AdminUsersLoaded AdminUsersFailed
    UserDeleteFailed err ->
        putModel (\m -> m{gAccount = (gAccount m){acUserDeleteBusy = False, acUserActionError = Just ((aeMessage err))}})
    -- webhooks -------------------------------------------------------------
    WebhooksLoaded webhooks ->
        putModel (\m -> m{gWebhooks = (gWebhooks m){wkWebhooks = webhooks, wkWebhooksLoading = False, wkWebhooksError = Nothing}})
    WebhooksFailed err -> do
        putModel (\m -> m{gWebhooks = (gWebhooks m){wkWebhooksLoading = False, wkWebhooksError = Just ((aeMessage err))}})
        handleApiError err
    WebhookNameInput value -> putModel (\m -> m{gWebhooks = (gWebhooks m){wkWebhookName = value}})
    WebhookUrlInput value -> putModel (\m -> m{gWebhooks = (gWebhooks m){wkWebhookUrl = value}})
    WebhookEventToggled eventType ->
        putModel
            ( \m ->
                m
                    { gWebhooks =
                        (gWebhooks m)
                            { wkWebhookEvents =
                                if eventType `elem` mWebhookEvents m
                                    then filter (/= eventType) (mWebhookEvents m)
                                    else mWebhookEvents m ++ [eventType]
                            , wkWebhookFormError = Nothing
                            }
                    }
            )
    WebhookEnabledToggled -> putModel (\m -> m{gWebhooks = (gWebhooks m){wkWebhookEnabled = not (mWebhookEnabled m)}})
    WebhookCreate -> do
        m <- get
        let input =
                WebhookInput
                    { wiName = T.strip ((mWebhookName m))
                    , wiUrl = T.strip ((mWebhookUrl m))
                    , wiEvents = mWebhookEvents m
                    , wiEnabled = mWebhookEnabled m
                    }
        putModel (\x -> x{gWebhooks = (gWebhooks x){wkWebhookBusy = True, wkWebhookFormError = Nothing}})
        createWebhook input (\(webhook, secret) -> WebhookCreated webhook secret) WebhookCreateFailed
    WebhookCreated webhook secret -> do
        notify "Webhook created. Copy the signing secret now." ToastOk
        putModel
            ( \m ->
                m{gWebhooks = (gWebhooks m){wkWebhooks = upsertWebhook webhook (mWebhooks m), wkWebhooksLoading = False, wkWebhooksError = Nothing, wkWebhookBusy = False, wkWebhookFormError = Nothing, wkWebhookSecret = Just secret, wkWebhookName = "", wkWebhookUrl = "", wkWebhookEvents = [], wkWebhookEnabled = True}}
            )
    WebhookCreateFailed err -> do
        putModel
            ( \m ->
                m{gWebhooks = (gWebhooks m){wkWebhookBusy = False, wkWebhookFormError = Just ((aeMessage err))}}
            )
        when (aeStatus err == Just 401) (handleApiError err)
    WebhookToggle webhook ->
        updateWebhook
            (whId webhook)
            ( WebhookInput
                (whName webhook)
                (whUrl webhook)
                (whEvents webhook)
                (not (whEnabled webhook))
            )
            WebhookToggled
            WebhookToggleFailed
    WebhookToggled webhook -> do
        notify "Webhook updated" ToastOk
        putModel (\m -> m{gWebhooks = (gWebhooks m){wkWebhooks = upsertWebhook webhook (mWebhooks m)}})
    WebhookToggleFailed err -> handleApiError err
    WebhookTestRequest webhookId -> do
        putModel
            ( \m ->
                m{gWebhooks = (gWebhooks m){wkWebhookTest = Nothing, wkWebhookTestError = Nothing, wkWebhookTestBusy = True}}
            )
        createWebhookTestJob
            webhookId
            (WebhookTestJobQueued webhookId)
            (\err -> WebhookTestJobFailed webhookId (Just (aeMessage err)))
    WebhookTestJobQueued webhookId jobId -> dispatch (JobStarted (WebhookTestJob webhookId) jobId)
    WebhookTestJobDone webhookId result -> do
        putModel (\m -> m{gWebhooks = (gWebhooks m){wkWebhookTestBusy = False}})
        case result of
            Nothing ->
                putModel (\m -> m{gWebhooks = (gWebhooks m){wkWebhookTestError = Just "The webhook test returned no result."}})
            Just value -> case decodeWebhookTestJobResult value of
                Left err -> putModel (\m -> m{gWebhooks = (gWebhooks m){wkWebhookTestError = Just (aeMessage err)}})
                Right report ->
                    putModel
                        ( \m ->
                            m
                                { gWebhooks =
                                    (gWebhooks m)
                                        { wkWebhookTest =
                                            Just
                                                ( webhookId
                                                , WebhookTest
                                                    (wtjrOk report)
                                                    (Just (wtjrStatus report))
                                                    (fromMaybe "" (wtjrError report))
                                                )
                                        , wkWebhookTestError = Nothing
                                        }
                                }
                        )
    WebhookTestJobFailed _ message ->
        putModel
            ( \m ->
                m{gWebhooks = (gWebhooks m){wkWebhookTestBusy = False, wkWebhookTest = Nothing, wkWebhookTestError = Just (fromMaybe "The webhook test failed." message)}}
            )
    WebhookTestJobAbandoned _ ->
        putModel (\m -> m{gWebhooks = (gWebhooks m){wkWebhookTestBusy = False, wkWebhookTestError = Nothing}})
    WebhookDelete webhookId ->
        deleteWebhook webhookId (WebhookDeleted webhookId) WebhookDeleteFailed
    WebhookDeleted webhookId -> do
        notify "Webhook deleted" ToastOk
        putModel
            ( \m ->
                m
                    { gWebhooks =
                        (gWebhooks m)
                            { wkWebhooks = filter ((/= webhookId) . whId) (mWebhooks m)
                            , wkWebhookDeliveries = case mWebhookDeliveries m of
                                Just (showId, _) | showId == webhookId -> Nothing
                                other -> other
                            , wkWebhookTest = case mWebhookTest m of
                                Just (showId, _) | showId == webhookId -> Nothing
                                other -> other
                            }
                    }
            )
    WebhookDeleteFailed err -> handleApiError err
    WebhookSecretDismiss -> putModel (\m -> m{gWebhooks = (gWebhooks m){wkWebhookSecret = Nothing}})
    WebhookSecretCopied raw -> copyText raw "Webhook secret copied" "Copy failed. Select the text instead"
    WebhookDeliveriesOpen webhookId -> do
        putModel (\m -> m{gWebhooks = (gWebhooks m){wkWebhookDeliveriesError = Nothing}})
        fetchWebhookDeliveries webhookId (WebhookDeliveriesLoaded webhookId) (WebhookDeliveriesFailed webhookId)
    WebhookDeliveriesLoaded webhookId deliveries ->
        putModel (\m -> m{gWebhooks = (gWebhooks m){wkWebhookDeliveries = Just (webhookId, deliveries), wkWebhookDeliveriesError = Nothing}})
    WebhookDeliveriesFailed _webhookId err ->
        putModel (\m -> m{gWebhooks = (gWebhooks m){wkWebhookDeliveries = Nothing, wkWebhookDeliveriesError = Just ((aeMessage err))}})
    -- highlights -----------------------------------------------------------
    RulesLoaded rules ->
        putModel (\m -> m{gRules = (gRules m){ruRules = rules, ruRulesLoading = False, ruRulesError = Nothing}})
    RulesFailed err -> do
        putModel (\m -> m{gRules = (gRules m){ruRulesLoading = False, ruRulesError = Just ((aeMessage err))}})
        handleApiError err
    RuleNameInput value -> putModel (\m -> m{gRules = (gRules m){ruRuleName = value}})
    RuleFieldSelected field -> putModel (\m -> m{gRules = (gRules m){ruRuleField = field}})
    RulePatternInput value -> putModel (\m -> m{gRules = (gRules m){ruRulePattern = value}})
    RuleTagsInput value -> putModel (\m -> m{gRules = (gRules m){ruRuleTags = value}})
    RuleMarkReadToggled -> putModel (\m -> m{gRules = (gRules m){ruRuleMarkRead = not (mRuleMarkRead m)}})
    RuleCreate -> do
        m <- get
        let name = T.strip ((mRuleName m))
            patternText = T.strip ((mRulePattern m))
        if T.null name || T.null patternText
            then notify "Rule name and pattern are required" ToastInfo
            else do
                putModel (\x -> x{gRules = (gRules x){ruRuleBusy = True}})
                createRule
                    name
                    True
                    (mRuleField m)
                    patternText
                    (splitTags (mRuleTags m))
                    (mRuleMarkRead m)
                    RuleCreated
                    RuleCreateFailed
    RuleCreated rule -> do
        putModel
            ( \m ->
                m{gRules = (gRules m){ruRules = mRules m ++ [rule], ruRuleName = "", ruRulePattern = "", ruRuleTags = "", ruRuleMarkRead = False, ruRuleBusy = False, ruRuleDryRun = Nothing}}
            )
        notify (("Rule “" <> ruleName rule <> "” created")) ToastOk
    RuleCreateFailed err -> do
        putModel (\m -> m{gRules = (gRules m){ruRuleBusy = False}})
        handleApiError err
    RuleToggleEnabled rule -> patchRule (ruleId rule) rule{ruleEnabled = not (ruleEnabled rule)} (RuleToggled rule{ruleEnabled = not (ruleEnabled rule)}) RuleFailed
    RuleToggled updated ->
        putModel
            ( \m ->
                m{gRules = (gRules m){ruRules = map (\rule -> if ruleId rule == ruleId updated then updated else rule) (mRules m)}}
            )
    RuleDelete ruleIdToDelete -> deleteRule ruleIdToDelete (RuleDeleted ruleIdToDelete) RuleFailed
    RuleDeleted ruleIdToDelete -> do
        putModel (\m -> m{gRules = (gRules m){ruRules = filter (\rule -> ruleId rule /= ruleIdToDelete) (mRules m)}})
        notify "Rule deleted" ToastOk
    RuleFailed err -> handleApiError err
    RuleDryRun -> do
        m <- get
        let patternText = T.strip ((mRulePattern m))
        if T.null patternText
            then notify "Enter a pattern to dry-run" ToastInfo
            else do
                putModel (\x -> x{gRules = (gRules x){ruRuleBusy = True, ruRuleDryRun = Nothing}})
                testRule (mRuleField m) patternText RuleDryRunResult RuleDryRunFailed
    RuleDryRunResult matches ids -> do
        putModel (\m -> m{gRules = (gRules m){ruRuleBusy = False, ruRuleDryRun = Just (matches, ids)}})
        notify (T.pack (show matches <> " bookmark(s) would match")) ToastOk
    RuleDryRunFailed err -> do
        putModel (\m -> m{gRules = (gRules m){ruRuleBusy = False}})
        handleApiError err
    -- toasts ---------------------------------------------------------------
    _ -> pure ()
