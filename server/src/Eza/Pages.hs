{-# LANGUAGE OverloadedStrings #-}

{- | Small server-rendered auth pages. The authenticated app is the Miso
bundle; these pages run the password setup, sign-in, recovery, the legacy
passkey sign-in, and passkey registration for a logged-in account.

Every page loads one external script (@/assets/auth.js@); there is no inline
JavaScript. The recovery-codes block is shared by the fresh setup and the
recovery setup.
-}
module Eza.Pages (
    loginPage,
    passkeyLoginPage,
    setupPage,
    recoverySetupPage,
    recoverPage,
    addPasskeyPage,
) where

import Data.Text (Text)
import qualified Data.Text as T

{- | Shared head for the standalone auth and recovery pages. The frame rules
centre the printed card without the app shell; they move into the shell
stylesheet when it owns standalone pages.
-}
commonHead :: Text -> Text
commonHead title =
    T.unlines
        [ "<!doctype html>"
        , "<html lang=\"en\" data-theme=\"light\">"
        , "<head><meta charset=\"utf-8\">"
        , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        , "<meta name=\"color-scheme\" content=\"light dark\">"
        , "<meta name=\"theme-color\" content=\"#F2EDE3\">"
        , "<meta name=\"theme-color\" media=\"(prefers-color-scheme: dark)\" content=\"#10141F\">"
        , "<title>" <> title <> " | eza</title>"
        , "<link rel=\"stylesheet\" href=\"/assets/eza.css\">"
        , "<link rel=\"icon\" href=\"/favicon.svg\">"
        , "<script src=\"/assets/theme.js\"></script>"
        , "<script src=\"/assets/auth.js\" defer></script>"
        , "</head>"
        ]

authPage :: Text -> Text -> Text
authPage pageName body =
    T.unlines
        [ "<body class=\"auth-body\">"
        , "<main class=\"auth\" data-page=\"" <> pageName <> "\">"
        , "  <div class=\"auth-stage\">"
        , "    <div class=\"auth-card\">"
        , body
        , "    </div>"
        , "  </div>"
        , "</main>"
        , "</body></html>"
        ]

authBrand :: Text -> Text
authBrand href =
    T.unlines
        [ "      <div class=\"auth-brand\">"
        , "        <a class=\"auth-wordmark\" href=\"" <> href <> "\">eza</a>"
        , "      </div>"
        ]

authTitle :: Text -> Text
authTitle title = "      <h1 class=\"auth-title display\">" <> title <> "</h1>"

authSub :: Text -> Text
authSub sub = "      <p class=\"auth-sub\">" <> sub <> "</p>"

authError :: Text
authError = "      <p id=\"auth-error\" class=\"auth-error\" role=\"alert\"></p>"

authLinks :: [(Text, Text)] -> Text
authLinks links =
    T.unlines
        [ "      <div class=\"auth-links\">"
        , T.concat ["        <a href=\"" <> href <> "\">" <> label <> "</a>" | (href, label) <- links]
        , "      </div>"
        ]

field :: Text -> Text -> Text -> Text -> Text
field inputId label inputType autocomplete =
    T.unlines
        [ "        <label class=\"auth-form-label meta\" for=\"" <> inputId <> "\">" <> label <> "</label>"
        , "        <input id=\""
            <> inputId
            <> "\" class=\"input auth-form-input\" type=\""
            <> inputType
            <> "\" autocomplete=\""
            <> autocomplete
            <> "\" spellcheck=\"false\" required>"
        ]

escapeHtml :: Text -> Text
escapeHtml value =
    T.replace "\"" "&quot;" (T.replace ">" "&gt;" (T.replace "<" "&lt;" (T.replace "&" "&amp;" value)))

{- | The recovery codes are shown once, after a password setup. Ids match the
shared script.
-}
recoveryCodesSection :: Text
recoveryCodesSection =
    T.unlines
        [ "      <div id=\"recovery\" hidden>"
        , authTitle "Save these codes"
        , authSub "Each code works once."
        , "        <pre id=\"codes\" class=\"auth-codes\" aria-label=\"Recovery codes\"></pre>"
        , "        <div class=\"auth-code-actions\"><button id=\"copy-codes\" class=\"btn\" type=\"button\">copy codes</button></div>"
        , "        <button id=\"continue\" class=\"btn btn--strong auth-action\" type=\"button\">continue</button>"
        , "      </div>"
        ]

loginPage :: Text
loginPage =
    commonHead "Sign in"
        <> authPage
            "login"
            ( T.unlines
                [ authBrand "/login"
                , authTitle "Sign in"
                , "      <form id=\"auth-form\" class=\"auth-form\" novalidate>"
                , field "username" "username" "text" "username"
                , field "password" "password" "password" "current-password"
                , "        <button id=\"password-login\" class=\"btn btn--strong auth-action\" type=\"submit\">sign in</button>"
                , "      </form>"
                , authError
                , authLinks [("/recover", "recover with a code")]
                ]
            )

{- | Legacy installations claimed with a passkey: sign in with the passkey
until a password is set from the account page or the CLI.
-}
passkeyLoginPage :: Text
passkeyLoginPage =
    commonHead "Sign in"
        <> authPage
            "passkey-login"
            ( T.unlines
                [ authBrand "/login"
                , authTitle "Sign in"
                , authSub "This library was claimed with a passkey. Sign in, then set a password from the account page."
                , "      <button id=\"passkey-login\" class=\"btn btn--strong auth-action\" type=\"button\">sign in with your passkey</button>"
                , authError
                , authLinks [("/recover", "recover with a code")]
                ]
            )

setupPage :: Text
setupPage =
    commonHead "Claim this library"
        <> authPage
            "setup"
            ( T.unlines
                [ authBrand "/setup"
                , "      <div class=\"auth-create\">"
                , authTitle "Claim this library"
                , authSub "The first account is the admin; the password needs ten characters or more."
                , "      <form id=\"auth-form\" class=\"auth-form\" novalidate>"
                , field "username" "username" "text" "username"
                , field "password" "password" "password" "new-password"
                , field "confirm-password" "confirm password" "password" "new-password"
                , "        <button id=\"password-setup\" class=\"btn btn--strong auth-action\" type=\"submit\">claim the library</button>"
                , "      </form>"
                , "      </div>"
                , authError
                , recoveryCodesSection
                ]
            )

{- | A recovery code was redeemed: set a new password, then the old codes are
replaced by ten new ones.
-}
recoverySetupPage :: Text -> Text
recoverySetupPage username =
    commonHead "Choose a new password"
        <> authPage
            "recovery-setup"
            ( T.unlines
                [ authBrand "/setup"
                , "      <div class=\"auth-create\">"
                , authTitle "Choose a new password"
                , authSub "Saving replaces the remaining codes; the password needs ten characters or more."
                , "      <form id=\"auth-form\" class=\"auth-form\" novalidate>"
                , "        <label class=\"auth-form-label meta\" for=\"username\">username</label>"
                , "        <input id=\"username\" class=\"input auth-form-input\" type=\"text\" autocomplete=\"username\" spellcheck=\"false\" value=\""
                    <> escapeHtml username
                    <> "\" required>"
                , field "password" "new password" "password" "new-password"
                , field "confirm-password" "confirm new password" "password" "new-password"
                , "        <button id=\"password-setup\" class=\"btn btn--strong auth-action\" type=\"submit\">save the new password</button>"
                , "      </form>"
                , "      </div>"
                , authError
                , recoveryCodesSection
                ]
            )

recoverPage :: Text
recoverPage =
    commonHead "Recover access"
        <> authPage
            "recover"
            ( T.unlines
                [ authBrand "/recover"
                , authTitle "Recover access"
                , authSub "A code works once. The password and passkeys reset."
                , "      <div class=\"auth-form\">"
                , "        <label class=\"auth-form-label meta\" for=\"recover-username\">username</label>"
                , "        <input id=\"recover-username\" class=\"input auth-form-input\" type=\"text\" autocomplete=\"username\" spellcheck=\"false\" autocapitalize=\"none\">"
                , "      </div>"
                , "      <div class=\"auth-form\">"
                , "        <label class=\"auth-form-label meta\" for=\"recovery-code\">recovery code</label>"
                , "        <input id=\"recovery-code\" class=\"input auth-form-input\" type=\"text\" autocomplete=\"one-time-code\" spellcheck=\"false\" placeholder=\"xxxx-xxxx\">"
                , "      </div>"
                , "      <button id=\"redeem\" class=\"btn btn--strong auth-action\" type=\"button\">use the code</button>"
                , authError
                , authLinks [("/login", "back to sign in")]
                ]
            )

addPasskeyPage :: Text
addPasskeyPage =
    commonHead "Add a passkey"
        <> authPage
            "add-passkey"
            ( T.unlines
                [ authBrand "/account"
                , authTitle "Add a passkey"
                , authSub "A passkey is an optional second factor on this account."
                , "      <button id=\"passkey-add\" class=\"btn btn--strong auth-action\" type=\"button\">add this device</button>"
                , authError
                , authLinks [("/account", "back to account")]
                ]
            )
