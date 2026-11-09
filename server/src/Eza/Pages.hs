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
        , "<style>"
        , ".auth-card:has(#recovery:not([hidden])) .auth-create{display:none}"
        , "</style>"
        , "</head>"
        ]

authPage :: Text -> Text -> Text -> Text
authPage pageName foot body =
    T.unlines
        [ "<body class=\"auth-body\">"
        , "<main class=\"auth\" data-page=\"" <> pageName <> "\">"
        , "  <div class=\"auth-stage\">"
        , "    <div class=\"auth-card\">"
        , body
        , "    </div>"
        , "    <p class=\"auth-foot meta\">" <> foot <> "</p>"
        , "  </div>"
        , "</main>"
        , "</body></html>"
        ]

authBrand :: Text -> Text -> Text
authBrand href imprint =
    T.unlines
        [ "      <div class=\"auth-brand\">"
        , "        <a class=\"auth-wordmark\" href=\"" <> href <> "\">eza</a>"
        , "        <span class=\"auth-imprint meta\">" <> imprint <> "</span>"
        , "      </div>"
        , "      <div class=\"auth-rule\" aria-hidden=\"true\"></div>"
        ]

authTitle :: Text -> Text
authTitle title = "      <h1 class=\"auth-title display\">" <> title <> "</h1>"

authSub :: Text -> Text
authSub sub = "      <p class=\"auth-sub\">" <> sub <> "</p>"

authNote :: Text -> Text
authNote note = "      <p class=\"auth-note meta\">" <> note <> "</p>"

authError :: Text
authError = "      <p id=\"auth-error\" class=\"auth-error\" role=\"alert\"></p>"

footSep :: Text
footSep = "<span class=\"auth-foot-sep\" aria-hidden=\"true\"></span>"

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
        , authTitle "Recovery codes"
        , authSub "Ten single-use codes. Keep them somewhere that is not this computer: they are the way back in if you forget the password."
        , "        <pre id=\"codes\" class=\"auth-codes\" aria-label=\"Recovery codes\"></pre>"
        , "        <div class=\"auth-code-actions\"><button id=\"copy-codes\" class=\"btn\" type=\"button\">copy all ten</button></div>"
        , authNote "Each code can be used once. They are not shown again after this step."
        , "        <button id=\"continue\" class=\"btn btn--strong auth-action\" type=\"button\">continue to the ledger</button>"
        , "      </div>"
        ]

loginPage :: Text
loginPage =
    commonHead "Sign in"
        <> authPage
            "login"
            ("eza " <> footSep <> " a private catalogue " <> footSep <> " username and password")
            ( T.unlines
                [ authBrand "/login" "private catalogue"
                , "      <div class=\"auth-create\">"
                , authTitle "Sign in"
                , authSub "Sign in with your account's username and password. Each account opens its own library."
                , "      <form id=\"auth-form\" class=\"auth-form\" novalidate>"
                , field "username" "username" "text" "username"
                , field "password" "password" "password" "current-password"
                , "        <button id=\"password-login\" class=\"btn btn--strong auth-action\" type=\"submit\">sign in</button>"
                , "      </form>"
                , authNote "When passkey two-factor is on, the next step asks for your passkey."
                , "      </div>"
                , authError
                , "      <div class=\"auth-links\"><a href=\"/recover\">recover with a code</a></div>"
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
            ("eza " <> footSep <> " a private catalogue " <> footSep <> " legacy passkey")
            ( T.unlines
                [ authBrand "/login" "private catalogue"
                , authTitle "Sign in"
                , authSub "This library was claimed before passwords. Sign in with your passkey, then set a password from the account page."
                , "      <button id=\"passkey-login\" class=\"btn btn--strong auth-action\" type=\"button\">sign in with your passkey</button>"
                , authError
                , "      <div class=\"auth-links\"><a href=\"/recover\">recover with a code</a></div>"
                ]
            )

setupPage :: Text
setupPage =
    commonHead "Claim the library"
        <> authPage
            "setup"
            ("eza " <> footSep <> " a private catalogue " <> footSep <> " first claim")
            ( T.unlines
                [ authBrand "/setup" "first claim"
                , "      <div class=\"auth-create\">"
                , authTitle "Claim the library"
                , authSub "This copy of eza has not been claimed yet. Choose the admin username and password for the first account."
                , "      <form id=\"auth-form\" class=\"auth-form\" novalidate>"
                , field "username" "username" "text" "username"
                , field "password" "password" "password" "new-password"
                , field "confirm-password" "confirm password" "password" "new-password"
                , authNote "At least ten characters. The password is stored as an Argon2id hash."
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
            ("eza " <> footSep <> " a private catalogue " <> footSep <> " recovery")
            ( T.unlines
                [ authBrand "/setup" "recovery"
                , "      <div class=\"auth-create\">"
                , authTitle "Choose a new password"
                , authSub "The recovery code was accepted. Set a new password for this library; the old codes stop working when you continue."
                , "      <form id=\"auth-form\" class=\"auth-form\" novalidate>"
                , "        <label class=\"auth-form-label meta\" for=\"username\">username</label>"
                , "        <input id=\"username\" class=\"input auth-form-input\" type=\"text\" autocomplete=\"username\" spellcheck=\"false\" value=\""
                    <> escapeHtml username
                    <> "\" required>"
                , field "password" "new password" "password" "new-password"
                , field "confirm-password" "confirm new password" "password" "new-password"
                , authNote "At least ten characters. The password is stored as an Argon2id hash."
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
            ("eza " <> footSep <> " a private catalogue " <> footSep <> " recovery is local")
            ( T.unlines
                [ authBrand "/recover" "recovery"
                , authTitle "Recover access"
                , authSub "Enter one of the ten single-use codes you saved when the library was claimed. The code is spent when it is used, and the old password and passkeys stop working."
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
                , "      <div class=\"auth-links\"><a href=\"/login\">back to sign in</a></div>"
                ]
            )

addPasskeyPage :: Text
addPasskeyPage =
    commonHead "Add a passkey"
        <> authPage
            "add-passkey"
            ("eza " <> footSep <> " a private catalogue " <> footSep <> " optional second factor")
            ( T.unlines
                [ authBrand "/account" "another way in"
                , authTitle "Add a passkey"
                , authSub "A passkey lets this device sign in. With passkey two-factor on it is also the second step after the password."
                , authNote "The passkey prompt needs a secure origin: an https address or http://localhost."
                , "      <button id=\"passkey-add\" class=\"btn btn--strong auth-action\" type=\"button\">add this device</button>"
                , authError
                , "      <div class=\"auth-links\"><a href=\"/account\">back to account</a></div>"
                ]
            )
