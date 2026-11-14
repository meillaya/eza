{- | Native contract tests for the shared wire DTOs. These run under the
server's native GHC (the client is WASM-only), so a codec change that would
silently drift the client fails here instead.
-}
module Main (main) where

import Test.Hspec

import ContractSpec (contractTests)

main :: IO ()
main = hspec contractTests
