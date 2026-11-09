{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Entry point for the eza Miso/WebAssembly client.
module Main (main) where

import qualified Data.Map.Strict as M
import Miso

import Eza.Web.Model (Action (..), Model, initialModel)
import Eza.Web.Update (subscriptions, updateModel)
import Eza.Web.View (viewModel)

main :: IO ()
main = startApp allEvents app

#ifdef WASM
foreign export javascript "hs_start" main :: IO ()
#endif

{- | Globally delegated events: the default set plus keyboard events for the
command palette, Ctrl/Cmd+S, and the global shortcuts, and the pointer and
wheel events the graph canvas binds. @pointerEvents@ does not carry
@pointermove@, so it is added here with the wheel.
-}
allEvents :: Events
allEvents =
    defaultEvents
        <> keyboardEvents
        <> mouseEvents
        <> pointerEvents
        <> M.fromList
            [ ("pointermove", BUBBLE)
            , ("wheel", BUBBLE)
            ]

app :: App Model Action
app =
    (component initialModel updateModel viewModel)
        { mount = Just Mounted
        , subs = subscriptions
        , mountPoint = Just "app"
        }
