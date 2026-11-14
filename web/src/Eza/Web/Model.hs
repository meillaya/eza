{-# OPTIONS_GHC -Wno-orphans #-}

{- | The Miso boundary for the native client model.

The state and action types are defined in "Eza.Web.Logic.Model"; this module
re-exports them and adds the two things that need Miso: the URL/Router
instance and the `MisoString` view accessors the rendering layer still reads.
Remaining M2-B2b work: convert the view modules to the native `Text` accessors
and delete these wrappers.
-}
module Eza.Web.Model (
    module Logic,
    Route (..),
    LedgerEntry (..),
    isGraphRoute,
    routeOfUri,
    routeTitle,
    routeSubtitle,
    themeToMiso,
    themeOfMiso,
    mVersion,
    mOrigin,
    mWindowOrigin,
    mBlockingError,
    mQ,
    mError,
    mNotice,
    mStatsError,
    mSecurityUsername,
    mSecurityCurrent,
    mSecurityNew,
    mSecurityConfirm,
    mSecurityError,
    mSavedName,
    mTagPromptValue,
    mAddUrl,
    mAddTitle,
    mAddTags,
    mAddNote,
    mAddError,
    mPaletteQ,
    mDetailError,
    mEditTitle,
    mEditNote,
    mNewTag,
    mLinkQuery,
    mHighlightNote,
    mHighlightEditNote,
    mSharesError,
    mRulesError,
    mRuleName,
    mRulePattern,
    mRuleTags,
    mGraphFilter,
    mGraphLayoutSource,
    mViewsError,
    mGraphError,
    mDedupError,
    mConsolError,
    mTagDialogInput,
    mTagDialogError,
    mSuggestionNotice,
    mSuggestionError,
    mExtractDraft,
    mPruneError,
    mUndoError,
    mUndoPreviewError,
    mAccountError,
    mCredEdit,
    mTokensError,
    mWebhooksError,
    mWebhookName,
    mWebhookUrl,
    mWebhookFormError,
    mWebhookTestError,
    mWebhookDeliveriesError,
    mAdminUsersError,
    mUserName,
    mUserPassword,
    mUserFormError,
    mUserResetPassword,
    mUserActionError,
    mUserDeleteName,
    mTokenName,
    paletteEntries,
    formatStamp,
    formatStampUtc,
    formatFiled,
    formatProseDate,
    sortLabel,
    wireVersionMismatchMessage,
    accountTabSlug,
    accountTabFromSlug,
) where

import Data.Bifunctor (second)
import Data.Text (Text)

import Eza.Ledger (LedgerEntry (..))
import Miso hiding (View)
import Miso.Router (Router (..), Token (..), routes, toPath, toQueryParam)

import Eza.Web.Logic.Model as Logic hiding (
    accountTabFromSlug,
    accountTabSlug,
    formatFiled,
    formatProseDate,
    formatStamp,
    formatStampUtc,
    mAccountError,
    mAddError,
    mAddNote,
    mAddTags,
    mAddTitle,
    mAddUrl,
    mAdminUsersError,
    mBlockingError,
    mConsolError,
    mCredEdit,
    mDedupError,
    mDetailError,
    mEditNote,
    mEditTitle,
    mError,
    mExtractDraft,
    mGraphError,
    mGraphFilter,
    mGraphLayoutSource,
    mHighlightEditNote,
    mHighlightNote,
    mLinkQuery,
    mNewTag,
    mNotice,
    mOrigin,
    mPaletteQ,
    mPruneError,
    mQ,
    mRuleName,
    mRulePattern,
    mRuleTags,
    mRulesError,
    mSavedName,
    mSecurityConfirm,
    mSecurityCurrent,
    mSecurityError,
    mSecurityNew,
    mSecurityUsername,
    mSharesError,
    mStatsError,
    mSuggestionError,
    mSuggestionNotice,
    mTagDialogError,
    mTagDialogInput,
    mTagPromptValue,
    mTokenName,
    mTokensError,
    mUndoError,
    mUndoPreviewError,
    mUserActionError,
    mUserDeleteName,
    mUserFormError,
    mUserName,
    mUserPassword,
    mUserResetPassword,
    mVersion,
    mViewsError,
    mWebhookDeliveriesError,
    mWebhookFormError,
    mWebhookName,
    mWebhookTestError,
    mWebhookUrl,
    mWebhooksError,
    mWindowOrigin,
    paletteEntries,
    sortLabel,
    wireVersionMismatchMessage,
 )
import qualified Eza.Web.Logic.Model as Native
import Eza.Web.Logic.Route (Route (..), isGraphRoute)
import qualified Eza.Web.Logic.Route as ClientRoute

{- | The route parser is not used: the client classifies URLs directly (and
falls back to 'NotFound' instead of failing), so the default is overridden.
The URL grammar itself lives in "Eza.Web.Logic.Route"; this instance only
bridges Miso's token type, which is why it stays on the client side.
-}
instance Router Route where
    fromRoute target =
        case ClientRoute.routeUriParts target of
            ([], query) -> IndexToken : queryTokens query
            (segments, query) -> map (toPath . ms) segments <> queryTokens query
      where
        queryTokens = map (\(key, value) -> toQueryParam (ms key) (ms value))
    toRoute input = Right (ClientRoute.routeOfUri (fromMisoString input))
    routeParser = routes []

-- | Classify a Miso URI at the browser boundary.
routeOfUri :: URI -> Route
routeOfUri uri = ClientRoute.routeOfUri (fromMisoString (prettyURI uri))

-- | The document title, wrapped for the Miso view layer.
routeTitle :: Route -> MisoString
routeTitle r = ms (ClientRoute.routeTitle r)

-- | The one-line subtitle, wrapped the same way as 'routeTitle'.
routeSubtitle :: Route -> MisoString
routeSubtitle r = ms (ClientRoute.routeSubtitle r)

themeToMiso :: Theme -> MisoString
themeToMiso = ms . Native.themeToText

themeOfMiso :: MisoString -> Theme
themeOfMiso = Native.themeOfText . fromMisoString

accountTabSlug :: AccountTab -> MisoString
accountTabSlug = ms . Native.accountTabSlug

accountTabFromSlug :: MisoString -> AccountTab
accountTabFromSlug = Native.accountTabFromSlug . fromMisoString

paletteEntries :: Model -> [(MisoString, MisoString, Action)]
paletteEntries model =
    [ (ms label, ms detail, action)
    | (label, detail, action) <- Native.paletteEntries model
    ]

formatStamp :: Int -> MisoString
formatStamp = ms . Native.formatStamp

formatStampUtc :: Int -> MisoString
formatStampUtc = ms . Native.formatStampUtc

formatFiled :: Int -> MisoString
formatFiled = ms . Native.formatFiled

formatProseDate :: Int -> MisoString
formatProseDate = ms . Native.formatProseDate

sortLabel :: Text -> MisoString
sortLabel = ms . Native.sortLabel

wireVersionMismatchMessage :: Int -> MisoString
wireVersionMismatchMessage = ms . Native.wireVersionMismatchMessage

mVersion :: Model -> MisoString
mVersion model = ms (Native.mVersion model)

mOrigin :: Model -> MisoString
mOrigin model = ms (Native.mOrigin model)

mWindowOrigin :: Model -> MisoString
mWindowOrigin model = ms (Native.mWindowOrigin model)

mBlockingError :: Model -> Maybe MisoString
mBlockingError model = fmap ms (Native.mBlockingError model)

mQ :: Model -> MisoString
mQ model = ms (Native.mQ model)

mError :: Model -> Maybe MisoString
mError model = fmap ms (Native.mError model)

mNotice :: Model -> Maybe MisoString
mNotice model = fmap ms (Native.mNotice model)

mStatsError :: Model -> Maybe MisoString
mStatsError model = fmap ms (Native.mStatsError model)

mSecurityUsername :: Model -> MisoString
mSecurityUsername model = ms (Native.mSecurityUsername model)

mSecurityCurrent :: Model -> MisoString
mSecurityCurrent model = ms (Native.mSecurityCurrent model)

mSecurityNew :: Model -> MisoString
mSecurityNew model = ms (Native.mSecurityNew model)

mSecurityConfirm :: Model -> MisoString
mSecurityConfirm model = ms (Native.mSecurityConfirm model)

mSecurityError :: Model -> Maybe MisoString
mSecurityError model = fmap ms (Native.mSecurityError model)

mSavedName :: Model -> MisoString
mSavedName model = ms (Native.mSavedName model)

mTagPromptValue :: Model -> MisoString
mTagPromptValue model = ms (Native.mTagPromptValue model)

mAddUrl :: Model -> MisoString
mAddUrl model = ms (Native.mAddUrl model)

mAddTitle :: Model -> MisoString
mAddTitle model = ms (Native.mAddTitle model)

mAddTags :: Model -> MisoString
mAddTags model = ms (Native.mAddTags model)

mAddNote :: Model -> MisoString
mAddNote model = ms (Native.mAddNote model)

mAddError :: Model -> Maybe MisoString
mAddError model = fmap ms (Native.mAddError model)

mPaletteQ :: Model -> MisoString
mPaletteQ model = ms (Native.mPaletteQ model)

mDetailError :: Model -> Maybe MisoString
mDetailError model = fmap ms (Native.mDetailError model)

mEditTitle :: Model -> MisoString
mEditTitle model = ms (Native.mEditTitle model)

mEditNote :: Model -> MisoString
mEditNote model = ms (Native.mEditNote model)

mNewTag :: Model -> MisoString
mNewTag model = ms (Native.mNewTag model)

mLinkQuery :: Model -> Maybe MisoString
mLinkQuery model = fmap ms (Native.mLinkQuery model)

mHighlightNote :: Model -> MisoString
mHighlightNote model = ms (Native.mHighlightNote model)

mHighlightEditNote :: Model -> MisoString
mHighlightEditNote model = ms (Native.mHighlightEditNote model)

mSharesError :: Model -> Maybe MisoString
mSharesError model = fmap ms (Native.mSharesError model)

mRulesError :: Model -> Maybe MisoString
mRulesError model = fmap ms (Native.mRulesError model)

mRuleName :: Model -> MisoString
mRuleName model = ms (Native.mRuleName model)

mRulePattern :: Model -> MisoString
mRulePattern model = ms (Native.mRulePattern model)

mRuleTags :: Model -> MisoString
mRuleTags model = ms (Native.mRuleTags model)

mGraphFilter :: Model -> MisoString
mGraphFilter model = ms (Native.mGraphFilter model)

mGraphLayoutSource :: Model -> MisoString
mGraphLayoutSource model = ms (Native.mGraphLayoutSource model)

mViewsError :: Model -> Maybe MisoString
mViewsError model = fmap ms (Native.mViewsError model)

mGraphError :: Model -> Maybe MisoString
mGraphError model = fmap ms (Native.mGraphError model)

mDedupError :: Model -> Maybe MisoString
mDedupError model = fmap ms (Native.mDedupError model)

mConsolError :: Model -> Maybe MisoString
mConsolError model = fmap ms (Native.mConsolError model)

mTagDialogInput :: Model -> MisoString
mTagDialogInput model = ms (Native.mTagDialogInput model)

mTagDialogError :: Model -> Maybe MisoString
mTagDialogError model = fmap ms (Native.mTagDialogError model)

mSuggestionNotice :: Model -> Maybe MisoString
mSuggestionNotice model = fmap ms (Native.mSuggestionNotice model)

mSuggestionError :: Model -> Maybe MisoString
mSuggestionError model = fmap ms (Native.mSuggestionError model)

mExtractDraft :: Model -> MisoString
mExtractDraft model = ms (Native.mExtractDraft model)

mPruneError :: Model -> Maybe MisoString
mPruneError model = fmap ms (Native.mPruneError model)

mUndoError :: Model -> Maybe MisoString
mUndoError model = fmap ms (Native.mUndoError model)

mUndoPreviewError :: Model -> Maybe MisoString
mUndoPreviewError model = fmap ms (Native.mUndoPreviewError model)

mAccountError :: Model -> Maybe MisoString
mAccountError model = fmap ms (Native.mAccountError model)

mCredEdit :: Model -> Maybe (Text, MisoString)
mCredEdit model = fmap (second ms) (Native.mCredEdit model)

mTokensError :: Model -> Maybe MisoString
mTokensError model = fmap ms (Native.mTokensError model)

mWebhooksError :: Model -> Maybe MisoString
mWebhooksError model = fmap ms (Native.mWebhooksError model)

mWebhookName :: Model -> MisoString
mWebhookName model = ms (Native.mWebhookName model)

mWebhookUrl :: Model -> MisoString
mWebhookUrl model = ms (Native.mWebhookUrl model)

mWebhookFormError :: Model -> Maybe MisoString
mWebhookFormError model = fmap ms (Native.mWebhookFormError model)

mWebhookTestError :: Model -> Maybe MisoString
mWebhookTestError model = fmap ms (Native.mWebhookTestError model)

mWebhookDeliveriesError :: Model -> Maybe MisoString
mWebhookDeliveriesError model = fmap ms (Native.mWebhookDeliveriesError model)

mAdminUsersError :: Model -> Maybe MisoString
mAdminUsersError model = fmap ms (Native.mAdminUsersError model)

mUserName :: Model -> MisoString
mUserName model = ms (Native.mUserName model)

mUserPassword :: Model -> MisoString
mUserPassword model = ms (Native.mUserPassword model)

mUserFormError :: Model -> Maybe MisoString
mUserFormError model = fmap ms (Native.mUserFormError model)

mUserResetPassword :: Model -> MisoString
mUserResetPassword model = ms (Native.mUserResetPassword model)

mUserActionError :: Model -> Maybe MisoString
mUserActionError model = fmap ms (Native.mUserActionError model)

mUserDeleteName :: Model -> MisoString
mUserDeleteName model = ms (Native.mUserDeleteName model)

mTokenName :: Model -> MisoString
mTokenName model = ms (Native.mTokenName model)
