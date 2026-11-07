{-# LANGUAGE OverloadedStrings #-}

-- | Small server-rendered auth pages.  The authenticated app is the Miso
-- bundle; these pages only run the WebAuthn ceremonies.
module Eza.Pages
  ( loginPage
  , setupPage
  , recoverPage
  , addPasskeyPage
  ) where

import Data.Text (Text)
import qualified Data.Text as T

commonHead :: Text -> Text -> Text
commonHead title extra =
  T.unlines
    [ "<!doctype html>"
    , "<html lang=\"en\"><head><meta charset=\"utf-8\">"
    , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    , "<title>" <> title <> " — eza</title>"
    , "<link rel=\"stylesheet\" href=\"/assets/eza.css\">"
    , "<link rel=\"icon\" href=\"/favicon.svg\">"
    , "<script src=\"/assets/theme.js\"></script>"
    , extra
    , "</head><body class=\"auth-body\">"
    ]

footer :: Text
footer = "</body></html>"

loginPage :: Text
loginPage =
  commonHead "Sign in" ""
    <> T.unlines
      [ "<main class=\"auth-card\" data-page=\"login\">"
      , "  <div class=\"auth-mark\">eza</div>"
      , "  <h1>Welcome back</h1>"
      , "  <p class=\"auth-sub\">Your third brain. Sign in with a passkey.</p>"
      , "  <button id=\"passkey-login\" class=\"btn primary auth-action\" type=\"button\">Sign in with passkey</button>"
      , "  <p id=\"auth-error\" class=\"auth-error\" role=\"alert\"></p>"
      , "  <div class=\"auth-links\"><a href=\"/recover\">Use a recovery code</a><a href=\"/setup\">Set up a passkey</a></div>"
      , "</main>"
      , "<script src=\"/assets/auth.js\" defer></script>"
      ]
    <> footer

setupPage :: Text
setupPage =
  commonHead "Set up" ""
    <> T.unlines
      [ "<main class=\"auth-card\" data-page=\"setup\">"
      , "  <div class=\"auth-mark\">eza</div>"
      , "  <h1>Set up eza</h1>"
      , "  <p class=\"auth-sub\">Create a passkey. It stays on this device and replaces a password.</p>"
      , "  <button id=\"passkey-setup\" class=\"btn primary auth-action\" type=\"button\">Create a passkey</button>"
      , "  <p id=\"auth-error\" class=\"auth-error\" role=\"alert\"></p>"
      , "  <section id=\"recovery\" class=\"auth-recovery\" hidden>"
      , "    <h2>Save your recovery codes</h2>"
      , "    <p>These ten one-time codes are shown only once. Use one if you lose your passkey.</p>"
      , "    <pre id=\"codes\" class=\"codes\"></pre>"
      , "    <div class=\"auth-actions\"><button id=\"copy-codes\" class=\"btn\" type=\"button\">Copy codes</button><button id=\"continue\" class=\"btn primary\" type=\"button\">I saved them — continue</button></div>"
      , "  </section>"
      , "  <div class=\"auth-links\"><a href=\"/login\">Back to sign in</a></div>"
      , "</main>"
      , "<script src=\"/assets/auth.js\" defer></script>"
      ]
    <> footer

addPasskeyPage :: Text
addPasskeyPage =
  commonHead "Add passkey" ""
    <> T.unlines
      [ "<main class=\"auth-card\" data-page=\"add-passkey\">"
      , "  <div class=\"auth-mark\">eza</div>"
      , "  <h1>Add a passkey</h1>"
      , "  <p class=\"auth-sub\">Register another passkey for this account (another device or security key).</p>"
      , "  <button id=\"passkey-add\" class=\"btn primary auth-action\" type=\"button\">Create a passkey</button>"
      , "  <p id=\"auth-error\" class=\"auth-error\" role=\"alert\"></p>"
      , "  <div class=\"auth-links\"><a href=\"/account\">Back to account</a></div>"
      , "</main>"
      , "<script src=\"/assets/auth.js\" defer></script>"
      ]
    <> footer

recoverPage :: Text
recoverPage =
  commonHead "Recover" ""
    <> T.unlines
      [ "<main class=\"auth-card\" data-page=\"recover\">"
      , "  <div class=\"auth-mark\">eza</div>"
      , "  <h1>Recover access</h1>"
      , "  <p class=\"auth-sub\">Enter one of the one-time recovery codes you saved. You will then create a new passkey.</p>"
      , "  <label class=\"auth-label\">Recovery code"
      , "    <input id=\"recovery-code\" class=\"auth-input\" autocomplete=\"one-time-code\" spellcheck=\"false\">"
      , "  </label>"
      , "  <button id=\"redeem\" class=\"btn primary auth-action\" type=\"button\">Use recovery code</button>"
      , "  <p id=\"auth-error\" class=\"auth-error\" role=\"alert\"></p>"
      , "  <div class=\"auth-links\"><a href=\"/login\">Back to sign in</a></div>"
      , "</main>"
      , "<script src=\"/assets/auth.js\" defer></script>"
      ]
    <> footer
