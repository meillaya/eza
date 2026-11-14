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
    putModel (\m -> m{mSecurityBusy = False, mSecurityError = Just message})

-- \| EA-00417: the accession form used by the dedup toast and dialog.

handle :: Action -> Update ()
handle = \case
    AccountTabSelected tab -> do
        putModel (\m -> m{mAccountTab = tab})
        selectAccountTab (accountTabSlug tab)
        when (tab == AccountWebhooks) $ do
            m <- get
            when (null (mWebhooks m) && not (mWebhooksLoading m)) $ do
                putModel (\x -> x{mWebhooksLoading = True, mWebhooksError = Nothing})
                fetchWebhooks WebhooksLoaded WebhooksFailed
        when (tab == AccountUsers) $ do
            m <- get
            when (null (mAdminUsers m) && not (mAdminUsersLoading m)) $ do
                putModel (\x -> x{mAdminUsersLoading = True, mAdminUsersError = Nothing})
                fetchAdminUsers AdminUsersLoaded AdminUsersFailed
    -- library ---------------------------------------------------------------
    AccountLoaded info -> do
        putModel
            ( \m ->
                m
                    { mAccount = Just info
                    , mAccountLoading = False
                    , mAccountError = Nothing
                    , mSessions = aiSessions info
                    , mSecurityUsername =
                        if T.null (T.strip ((mSecurityUsername m)))
                            then (aiUsername info)
                            else mSecurityUsername m
                    , mSecurity2faWanted = aiRequirePasskey info
                    , mAdminUsersLoading = null (mAdminUsers m)
                    }
            )
        m0 <- get
        when (mAdminUsersLoading m0) (fetchAdminUsers AdminUsersLoaded AdminUsersFailed)
    AccountFailed err -> do
        putModel (\m -> m{mAccountLoading = False, mAccountError = Just ((aeMessage err))})
        handleApiError err
    RecoveryRegenerate -> regenerateRecovery RecoveryLoaded AccountFailed
    RecoveryLoaded codes -> do
        putModel (\m -> m{mRecoveryCodes = codes})
        notify "New recovery codes. Store them now." ToastOk
    CredentialRenamed credentialId nickname -> do
        renameCredential credentialId nickname (ToastAdd "Passkey renamed" ToastOk) CredentialOpFailed
    CredentialDeleted credentialId -> deleteCredential credentialId (CredentialRemoved credentialId) CredentialOpFailed
    CredentialRemoved _ -> do
        notify "Passkey deleted" ToastOk
        fetchAccount AccountLoaded AccountFailed
    CredentialOpFailed err -> handleApiError err
    CredentialEditStart credentialId -> putModel (\m -> m{mCredEdit = Just (credentialId, "")})
    CredentialNameInput nickname -> putModel (\m -> m{mCredEdit = fmap (\(cid, _) -> (cid, nickname)) (mCredEdit m)})
    CredentialEditSave -> do
        m <- get
        case mCredEdit m of
            Nothing -> pure ()
            Just (credentialId, nickname) -> do
                putModel (\x -> x{mCredEdit = Nothing})
                renameCredential credentialId nickname AccountReload CredentialOpFailed
    CredentialEditCancel -> putModel (\m -> m{mCredEdit = Nothing})
    SecurityUsernameInput value -> putModel (\m -> m{mSecurityUsername = value, mSecurityError = Nothing})
    SecurityCurrentPasswordInput value -> putModel (\m -> m{mSecurityCurrent = value, mSecurityError = Nothing})
    SecurityNewPasswordInput value -> putModel (\m -> m{mSecurityNew = value, mSecurityError = Nothing})
    SecurityConfirmPasswordInput value -> putModel (\m -> m{mSecurityConfirm = value, mSecurityError = Nothing})
    Security2faWantedToggled wanted ->
        putModel (\m -> m{mSecurity2faWanted = wanted, mSecurityError = Nothing})
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
                                    putModel (\x -> x{mSecurityBusy = True, mSecurityError = Nothing})
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
                                            putModel (\x -> x{mSecurityBusy = True, mSecurityError = Nothing})
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
                    putModel (\x -> x{mSecurityBusy = True, mSecurityError = Nothing})
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
                m
                    { mSecurityBusy = False
                    , mSecurityCurrent = ""
                    , mSecurityNew = ""
                    , mSecurityConfirm = ""
                    , mSecurityUsername = ""
                    , mSecurityError = Nothing
                    }
            )
        notify message ToastOk
        fetchAccount AccountLoaded AccountFailed
    SecurityFailed err -> do
        putModel (\m -> m{mSecurityBusy = False, mSecurityError = Just ((aeMessage err))})
        when (aeStatus err == Just 401) (handleApiError err)
    SessionsRevokeOthers -> do
        putModel (\m -> m{mAccountLoading = True})
        revokeOtherSessions SessionsRevoked SessionsRevokeFailed
    SessionsRevoked revoked -> do
        putModel (\m -> m{mAccountLoading = False})
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
        putModel (\m -> m{mAccountLoading = False})
        handleApiError err
    AccountReload -> fetchAccount AccountLoaded AccountFailed
    -- Signing out is a write, but an unsaved note would be lost silently, so
    -- the dirty editor asks first; a clean screen signs out immediately.
    LogoutRequest -> do
        m <- get
        if hasUnsaved m
            then putModel (\x -> x{mConfirmLogout = True})
            else dispatch Logout
    LogoutCancel -> putModel (\m -> m{mConfirmLogout = False})
    Logout -> logout LoggedOut (\err -> ApiErrorRaised err)
    LoggedOut -> redirect "/login"
    -- selection / bulk -----------------------------------------------------
    TokensLoaded tokens ->
        putModel (\m -> m{mTokens = tokens, mTokensLoading = False, mTokensError = Nothing})
    TokensFailed err -> do
        putModel (\m -> m{mTokensLoading = False, mTokensError = Just ((aeMessage err))})
        handleApiError err
    TokenNameInput value -> putModel (\m -> m{mTokenName = value})
    TokenScopeToggled scope ->
        putModel
            ( \m ->
                m
                    { mTokenScopes =
                        if scope `elem` mTokenScopes m
                            then filter (/= scope) (mTokenScopes m)
                            else mTokenScopes m ++ [scope]
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
                        putModel (\x -> x{mTokenBusy = True})
                        createApiToken name (mTokenScopes m) TokenCreated TokenCreateFailed
    TokenCreated raw info -> do
        putModel
            ( \m ->
                m
                    { mTokens = info : filter ((/= tvId info) . tvId) (mTokens m)
                    , mTokenName = ""
                    , mTokenBusy = False
                    , mTokenSecret = Just (raw, info)
                    }
            )
        notify "Token created. Copy it now; it is shown once." ToastOk
    TokenCreateFailed err -> do
        putModel (\m -> m{mTokenBusy = False})
        handleApiError err
    TokenRevoke tokenId -> revokeApiToken tokenId TokenRevoked TokenCreateFailed
    TokenRevoked -> do
        notify "Token revoked" ToastOk
        fetchTokens TokensLoaded TokensFailed
    TokenRevealDismiss -> putModel (\m -> m{mTokenSecret = Nothing})
    TokenCopied raw -> copyText raw "Token copied" "Copy failed. Select the text instead"
    -- admin users ----------------------------------------------------------
    AdminUsersLoaded users ->
        putModel
            ( \m ->
                m
                    { mAdminUsers = users
                    , mAdminUsersAllowed = True
                    , mAdminUsersLoading = False
                    , mAdminUsersError = Nothing
                    }
            )
    AdminUsersFailed err -> do
        putModel
            ( \m ->
                m
                    { mAdminUsersLoading = False
                    , mAdminUsersAllowed = False
                    , mAdminUsersError = if mAccountTab m == AccountUsers then Just ((aeMessage err)) else Nothing
                    }
            )
        when (aeStatus err == Just 401) (handleApiError err)
    UserNameInput value -> putModel (\m -> m{mUserName = value, mUserFormError = Nothing})
    UserPasswordInput value -> putModel (\m -> m{mUserPassword = value, mUserFormError = Nothing})
    UserRoleSelected role -> putModel (\m -> m{mUserRole = role})
    UserCreate -> do
        m <- get
        let input =
                UserCreateInput
                    { uciUsername = T.strip ((mUserName m))
                    , uciPassword = (mUserPassword m)
                    , uciRole = mUserRole m
                    }
        putModel (\x -> x{mUserBusy = True, mUserFormError = Nothing})
        createAdminUser input UserCreated UserCreateFailed
    UserCreated result -> do
        notify "User created. Copy the recovery codes now." ToastOk
        putModel
            ( \m ->
                m
                    { mAdminUsers = upsertUser (ucrUser result) (mAdminUsers m)
                    , mAdminUsersLoading = False
                    , mAdminUsersError = Nothing
                    , mUserBusy = False
                    , mUserFormError = Nothing
                    , mUserName = ""
                    , mUserPassword = ""
                    , mUserRole = RoleMember
                    , mUserRecovery = Just (uvUsername (ucrUser result), ucrRecoveryCodes result)
                    }
            )
    UserCreateFailed err -> do
        putModel (\m -> m{mUserBusy = False, mUserFormError = Just ((aeMessage err))})
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
                m
                    { mAdminUsers = upsertUser user (mAdminUsers m)
                    , mUserActionError = Nothing
                    }
            )
    UserUpdateFailed err ->
        putModel (\m -> m{mUserActionError = Just ((aeMessage err))})
    UserResetOpen userId ->
        putModel (\m -> m{mUserReset = Just userId, mUserResetPassword = "", mUserActionError = Nothing})
    UserResetPasswordInput value -> putModel (\m -> m{mUserResetPassword = value})
    UserResetSubmit -> do
        m <- get
        case mUserReset m of
            Nothing -> pure ()
            Just userId ->
                let password = (mUserResetPassword m)
                 in if T.null (T.strip password)
                        then putModel (\x -> x{mUserActionError = Just "a temporary password is required"})
                        else resetAdminPassword userId password (UserResetDone userId password) UserResetFailed
    UserResetDone userId password -> do
        notify "Temporary password set. The user's sessions were revoked." ToastOk
        putModel
            ( \m ->
                let username = case [uvUsername user | user <- mAdminUsers m, uvId user == userId] of
                        (name : _) -> name
                        [] -> T.pack (show userId)
                 in m
                        { mUserReset = Nothing
                        , mUserResetPassword = ""
                        , mUserResetShown = Just (username, password)
                        , mUserActionError = Nothing
                        }
            )
    UserResetCancel -> putModel (\m -> m{mUserReset = Nothing, mUserResetPassword = "", mUserActionError = Nothing})
    UserResetFailed err ->
        putModel (\m -> m{mUserActionError = Just ((aeMessage err))})
    UserRecoveryCopied raw -> copyText raw "Recovery codes copied" "Copy failed. Select the text instead"
    UserRecoveryDismiss -> putModel (\m -> m{mUserRecovery = Nothing})
    UserResetShownDismiss -> putModel (\m -> m{mUserResetShown = Nothing})
    UserDeleteOpen user ->
        putModel
            ( \m ->
                m
                    { mUserDelete = Just user
                    , mUserDeleteName = ""
                    , mUserDeleteLibrary = False
                    , mUserDeleteBusy = False
                    , mUserActionError = Nothing
                    }
            )
    UserDeleteCancel ->
        putModel
            ( \m ->
                m
                    { mUserDelete = Nothing
                    , mUserDeleteName = ""
                    , mUserDeleteLibrary = False
                    , mUserDeleteBusy = False
                    }
            )
    UserDeleteNameInput value -> putModel (\m -> m{mUserDeleteName = value})
    UserDeleteLibraryToggled -> putModel (\m -> m{mUserDeleteLibrary = not (mUserDeleteLibrary m)})
    UserDeleteSubmit -> do
        m <- get
        case mUserDelete m of
            Just user
                | T.strip ((mUserDeleteName m)) == uvUsername user -> do
                    putModel (\x -> x{mUserDeleteBusy = True, mUserActionError = Nothing})
                    deleteAdminUser (uvId user) (mUserDeleteLibrary m) (UserDeleted (uvId user)) UserDeleteFailed
                | otherwise ->
                    putModel (\x -> x{mUserActionError = Just "type the account name to confirm"})
            Nothing -> pure ()
    UserDeleted userId -> do
        notify "Account deleted" ToastOk
        putModel
            ( \m ->
                m
                    { mUserDelete = Nothing
                    , mUserDeleteName = ""
                    , mUserDeleteLibrary = False
                    , mUserDeleteBusy = False
                    , mUserActionError = Nothing
                    , mAdminUsers = [user | user <- mAdminUsers m, uvId user /= userId]
                    }
            )
        fetchAdminUsers AdminUsersLoaded AdminUsersFailed
    UserDeleteFailed err ->
        putModel (\m -> m{mUserDeleteBusy = False, mUserActionError = Just ((aeMessage err))})
    -- webhooks -------------------------------------------------------------
    WebhooksLoaded webhooks ->
        putModel (\m -> m{mWebhooks = webhooks, mWebhooksLoading = False, mWebhooksError = Nothing})
    WebhooksFailed err -> do
        putModel (\m -> m{mWebhooksLoading = False, mWebhooksError = Just ((aeMessage err))})
        handleApiError err
    WebhookNameInput value -> putModel (\m -> m{mWebhookName = value})
    WebhookUrlInput value -> putModel (\m -> m{mWebhookUrl = value})
    WebhookEventToggled eventType ->
        putModel
            ( \m ->
                m
                    { mWebhookEvents =
                        if eventType `elem` mWebhookEvents m
                            then filter (/= eventType) (mWebhookEvents m)
                            else mWebhookEvents m ++ [eventType]
                    , mWebhookFormError = Nothing
                    }
            )
    WebhookEnabledToggled -> putModel (\m -> m{mWebhookEnabled = not (mWebhookEnabled m)})
    WebhookCreate -> do
        m <- get
        let input =
                WebhookInput
                    { wiName = T.strip ((mWebhookName m))
                    , wiUrl = T.strip ((mWebhookUrl m))
                    , wiEvents = mWebhookEvents m
                    , wiEnabled = mWebhookEnabled m
                    }
        putModel (\x -> x{mWebhookBusy = True, mWebhookFormError = Nothing})
        createWebhook input (\(webhook, secret) -> WebhookCreated webhook secret) WebhookCreateFailed
    WebhookCreated webhook secret -> do
        notify "Webhook created. Copy the signing secret now." ToastOk
        putModel
            ( \m ->
                m
                    { mWebhooks = upsertWebhook webhook (mWebhooks m)
                    , mWebhooksLoading = False
                    , mWebhooksError = Nothing
                    , mWebhookBusy = False
                    , mWebhookFormError = Nothing
                    , mWebhookSecret = Just secret
                    , mWebhookName = ""
                    , mWebhookUrl = ""
                    , mWebhookEvents = []
                    , mWebhookEnabled = True
                    }
            )
    WebhookCreateFailed err -> do
        putModel
            ( \m ->
                m
                    { mWebhookBusy = False
                    , mWebhookFormError = Just ((aeMessage err))
                    }
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
        putModel (\m -> m{mWebhooks = upsertWebhook webhook (mWebhooks m)})
    WebhookToggleFailed err -> handleApiError err
    WebhookTestRequest webhookId -> do
        putModel
            ( \m ->
                m
                    { mWebhookTest = Nothing
                    , mWebhookTestError = Nothing
                    , mWebhookTestBusy = True
                    }
            )
        createWebhookTestJob
            webhookId
            (WebhookTestJobQueued webhookId)
            (\err -> WebhookTestJobFailed webhookId (Just (aeMessage err)))
    WebhookTestJobQueued webhookId jobId -> dispatch (JobStarted (WebhookTestJob webhookId) jobId)
    WebhookTestJobDone webhookId result -> do
        putModel (\m -> m{mWebhookTestBusy = False})
        case result of
            Nothing ->
                putModel (\m -> m{mWebhookTestError = Just "The webhook test returned no result."})
            Just value -> case decodeWebhookTestJobResult value of
                Left err -> putModel (\m -> m{mWebhookTestError = Just (aeMessage err)})
                Right report ->
                    putModel
                        ( \m ->
                            m
                                { mWebhookTest =
                                    Just
                                        ( webhookId
                                        , WebhookTest
                                            (wtjrOk report)
                                            (Just (wtjrStatus report))
                                            (fromMaybe "" (wtjrError report))
                                        )
                                , mWebhookTestError = Nothing
                                }
                        )
    WebhookTestJobFailed _ message ->
        putModel
            ( \m ->
                m
                    { mWebhookTestBusy = False
                    , mWebhookTest = Nothing
                    , mWebhookTestError = Just (fromMaybe "The webhook test failed." message)
                    }
            )
    WebhookTestJobAbandoned _ ->
        putModel (\m -> m{mWebhookTestBusy = False, mWebhookTestError = Nothing})
    WebhookDelete webhookId ->
        deleteWebhook webhookId (WebhookDeleted webhookId) WebhookDeleteFailed
    WebhookDeleted webhookId -> do
        notify "Webhook deleted" ToastOk
        putModel
            ( \m ->
                m
                    { mWebhooks = filter ((/= webhookId) . whId) (mWebhooks m)
                    , mWebhookDeliveries = case mWebhookDeliveries m of
                        Just (showId, _) | showId == webhookId -> Nothing
                        other -> other
                    , mWebhookTest = case mWebhookTest m of
                        Just (showId, _) | showId == webhookId -> Nothing
                        other -> other
                    }
            )
    WebhookDeleteFailed err -> handleApiError err
    WebhookSecretDismiss -> putModel (\m -> m{mWebhookSecret = Nothing})
    WebhookSecretCopied raw -> copyText raw "Webhook secret copied" "Copy failed. Select the text instead"
    WebhookDeliveriesOpen webhookId -> do
        putModel (\m -> m{mWebhookDeliveriesError = Nothing})
        fetchWebhookDeliveries webhookId (WebhookDeliveriesLoaded webhookId) (WebhookDeliveriesFailed webhookId)
    WebhookDeliveriesLoaded webhookId deliveries ->
        putModel (\m -> m{mWebhookDeliveries = Just (webhookId, deliveries), mWebhookDeliveriesError = Nothing})
    WebhookDeliveriesFailed _webhookId err ->
        putModel (\m -> m{mWebhookDeliveries = Nothing, mWebhookDeliveriesError = Just ((aeMessage err))})
    -- highlights -----------------------------------------------------------
    RulesLoaded rules ->
        putModel (\m -> m{mRules = rules, mRulesLoading = False, mRulesError = Nothing})
    RulesFailed err -> do
        putModel (\m -> m{mRulesLoading = False, mRulesError = Just ((aeMessage err))})
        handleApiError err
    RuleNameInput value -> putModel (\m -> m{mRuleName = value})
    RuleFieldSelected field -> putModel (\m -> m{mRuleField = field})
    RulePatternInput value -> putModel (\m -> m{mRulePattern = value})
    RuleTagsInput value -> putModel (\m -> m{mRuleTags = value})
    RuleMarkReadToggled -> putModel (\m -> m{mRuleMarkRead = not (mRuleMarkRead m)})
    RuleCreate -> do
        m <- get
        let name = T.strip ((mRuleName m))
            patternText = T.strip ((mRulePattern m))
        if T.null name || T.null patternText
            then notify "Rule name and pattern are required" ToastInfo
            else do
                putModel (\x -> x{mRuleBusy = True})
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
                m
                    { mRules = mRules m ++ [rule]
                    , mRuleName = ""
                    , mRulePattern = ""
                    , mRuleTags = ""
                    , mRuleMarkRead = False
                    , mRuleBusy = False
                    , mRuleDryRun = Nothing
                    }
            )
        notify (("Rule “" <> ruleName rule <> "” created")) ToastOk
    RuleCreateFailed err -> do
        putModel (\m -> m{mRuleBusy = False})
        handleApiError err
    RuleToggleEnabled rule -> patchRule (ruleId rule) rule{ruleEnabled = not (ruleEnabled rule)} (RuleToggled rule{ruleEnabled = not (ruleEnabled rule)}) RuleFailed
    RuleToggled updated ->
        putModel
            ( \m ->
                m
                    { mRules = map (\rule -> if ruleId rule == ruleId updated then updated else rule) (mRules m)
                    }
            )
    RuleDelete ruleIdToDelete -> deleteRule ruleIdToDelete (RuleDeleted ruleIdToDelete) RuleFailed
    RuleDeleted ruleIdToDelete -> do
        putModel (\m -> m{mRules = filter (\rule -> ruleId rule /= ruleIdToDelete) (mRules m)})
        notify "Rule deleted" ToastOk
    RuleFailed err -> handleApiError err
    RuleDryRun -> do
        m <- get
        let patternText = T.strip ((mRulePattern m))
        if T.null patternText
            then notify "Enter a pattern to dry-run" ToastInfo
            else do
                putModel (\x -> x{mRuleBusy = True, mRuleDryRun = Nothing})
                testRule (mRuleField m) patternText RuleDryRunResult RuleDryRunFailed
    RuleDryRunResult matches ids -> do
        putModel (\m -> m{mRuleBusy = False, mRuleDryRun = Just (matches, ids)})
        notify (T.pack (show matches <> " bookmark(s) would match")) ToastOk
    RuleDryRunFailed err -> do
        putModel (\m -> m{mRuleBusy = False})
        handleApiError err
    -- toasts ---------------------------------------------------------------
    _ -> pure ()
