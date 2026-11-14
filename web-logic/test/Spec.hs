module Main (main) where

import Test.Hspec

import ApiSpec (apiSpec)
import HelperSpec (helperSpec)
import LedgerSpec (ledgerSpec)
import ModelSpec (modelSpec)
import PuritySpec (puritySpec)
import RouteSpec (routeSpec)
import UpdateSpec (updateSpec)

main :: IO ()
main = hspec $ do
    routeSpec
    apiSpec
    ledgerSpec
    modelSpec
    updateSpec
    helperSpec
    puritySpec
