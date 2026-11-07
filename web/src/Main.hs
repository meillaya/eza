-- | Entry point for the eza Miso/WebAssembly client.
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Miso

import Eza.Web.Model (Action (..), Model, initialModel)
import Eza.Web.Update (subscriptions, updateModel)
import Eza.Web.View (viewModel)

main :: IO ()
main = startApp allEvents app

#ifdef WASM
foreign export javascript "hs_start" main :: IO ()
#endif

-- | Globally delegated events: the default set plus keyboard events for the
-- command palette, Ctrl/Cmd+S, and the global shortcuts.
allEvents :: Events
allEvents = defaultEvents <> keyboardEvents

app :: App Model Action
app =
  (component initialModel updateModel viewModel)
    { mount = Just Mounted
    , subs = subscriptions
    , mountPoint = Just "app"
    }
