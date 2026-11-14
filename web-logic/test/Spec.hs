module Main (main) where

import Test.Hspec

import ApiSpec (apiSpec)
import LedgerSpec (ledgerSpec)
import PuritySpec (puritySpec)
import RouteSpec (routeSpec)

main :: IO ()
main = hspec $ do
    routeSpec
    apiSpec
    ledgerSpec
    puritySpec
