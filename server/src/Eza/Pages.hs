{-# LANGUAGE OverloadedStrings #-}

{- | Small server-rendered auth pages. The authenticated app is the Miso
bundle; these pages only run the WebAuthn ceremonies.
-}
module Eza.Pages (
    loginPage,
    setupPage,
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

loginPage :: Text
loginPage =
    commonHead "Sign in"
        <> authPage
            "login"
            ("eza " <> footSep <> " a private catalogue " <> footSep <> " passkeys only")
            ( T.unlines
                [ authBrand "/login" "private catalogue"
                , authTitle "Sign in"
                , authSub "The library opens with a passkey. There is no password to remember or leak."
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
                , authSub "This copy of eza has not been claimed yet. Create a passkey for this device and the catalogue is yours."
                , "        <button id=\"passkey-setup\" class=\"btn btn--strong auth-action\" type=\"button\">create a passkey</button>"
                , authNote "The passkey lives in this device's keychain or a security key. It never leaves the device."
                , "      </div>"
                , authError
                , "      <div id=\"recovery\" hidden>"
                , authTitle "Recovery codes"
                , authSub "Ten single-use codes. Keep them somewhere that is not this computer: they are the way back in if the passkey is lost."
                , "        <pre id=\"codes\" class=\"auth-codes\" aria-label=\"Recovery codes\"></pre>"
                , "        <div class=\"auth-code-actions\"><button id=\"copy-codes\" class=\"btn\" type=\"button\">copy all ten</button></div>"
                , authNote "Each code can be used once. They are not shown again after this step."
                , "        <button id=\"continue\" class=\"btn btn--strong auth-action\" type=\"button\">continue to the ledger</button>"
                , "      </div>"
                , "      <div class=\"auth-links\"><a href=\"/login\">back to sign in</a></div>"
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
                , authSub "Enter one of the ten single-use codes you saved when the library was claimed. The code is spent when it is used."
                , "      <div class=\"auth-form\">"
                , "        <label class=\"auth-form-label meta\" for=\"recovery-code\">recovery code</label>"
                , "        <input id=\"recovery-code\" class=\"input auth-form-input\" type=\"text\" autocomplete=\"one-time-code\" spellcheck=\"false\" placeholder=\"xxxx-xxxx\">"
                , "      </div>"
                , "      <button id=\"redeem\" class=\"btn btn--strong auth-action\" type=\"button\">use the code</button>"
                , authError
                , "      <div class=\"auth-links\"><a href=\"/login\">back to the passkey</a></div>"
                ]
            )

addPasskeyPage :: Text
addPasskeyPage =
    commonHead "Add another device"
        <> authPage
            "add-passkey"
            ("eza " <> footSep <> " a private catalogue " <> footSep <> " passkeys are local to each device")
            ( T.unlines
                [ authBrand "/account" "another device"
                , authTitle "Add another device"
                , authSub "A passkey belongs to one device. Add one here so the library also opens on this machine. You will be asked to confirm with a passkey you already have."
                , "      <button id=\"passkey-add\" class=\"btn btn--strong auth-action\" type=\"button\">add this device</button>"
                , authError
                , "      <div class=\"auth-links\"><a href=\"/account\">back to account</a></div>"
                ]
            )
