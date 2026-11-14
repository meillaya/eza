module Main (main) where

import Test.Hspec

import ApiSpec (apiSpec)
import PuritySpec (puritySpec)
import RouteSpec (routeSpec)

main :: IO ()
main = hspec $ do
    routeSpec
    apiSpec
    puritySpec
