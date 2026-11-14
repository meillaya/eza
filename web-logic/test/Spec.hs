module Main (main) where

import Test.Hspec

import ApiSpec (apiSpec)
import HelperSpec (helperSpec)
import JobSpec (jobSpec)
import LedgerSpec (ledgerSpec)
import ModelSpec (modelSpec)
import PolishSpec (polishSpec)
import PuritySpec (puritySpec)
import RouteSpec (routeSpec)
import UpdateSpec (updateSpec)
import ViewSpec (viewSpec)

main :: IO ()
main = hspec $ do
    routeSpec
    apiSpec
    ledgerSpec
    modelSpec
    polishSpec
    updateSpec
    jobSpec
    viewSpec
    helperSpec
    puritySpec
