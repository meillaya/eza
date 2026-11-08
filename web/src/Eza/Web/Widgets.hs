{-# LANGUAGE OverloadedStrings #-}

{- | The few helpers every view shares. Layout and components live in
static/eza.css; views use its class names directly.
-}
module Eza.Web.Widgets (
    formatCount,
    disabledAttr,
    checkedAttr,
) where

import Miso
import qualified Miso.Html.Property as HP

import Eza.Web.Model (Action, Model)

-- | Group digits: 8988 becomes 8,988.
formatCount :: Int -> MisoString
formatCount n
    | n < 0 = ms ('-' : grouped (negate n))
    | otherwise = ms (grouped n)
  where
    grouped :: Int -> String
    grouped value = go (show value)
    go :: String -> String
    go digits
        | length digits <= 3 = digits
        | otherwise =
            let (prefix, lastThree) = splitAt (length digits - 3) digits
             in go prefix <> "," <> lastThree

{- | Boolean attributes are plain 'Attribute' values; build the list
conditionally instead of applying them like a setter.
-}
disabledAttr :: Bool -> [Attribute Model Action]
disabledAttr True = [HP.disabled_]
disabledAttr False = []

checkedAttr :: Bool -> [Attribute Model Action]
checkedAttr value = [HP.checked_ value]
