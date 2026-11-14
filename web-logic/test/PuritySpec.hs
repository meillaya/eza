{-# LANGUAGE OverloadedStrings #-}

{- | The package must stay free of the browser toolchain: the native build is
what makes the client logic testable, and a @miso@ or JSFFI import would make
this package WASM-only again. The check reads the package sources directly, so
it also covers modules that no test happens to import.
-}
module PuritySpec (puritySpec) where

import Control.Monad (filterM, forM)
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import Test.Hspec

import Eza.Web.Logic.Route (Route (..), routeToUri)

puritySpec :: Spec
puritySpec = describe "web-logic package purity" $ do
    it "imports no Miso, JSFFI or browser module" $ do
        root <- findSourceRoot
        files <- haskellFiles root
        files `shouldSatisfy` (not . null)
        violations <- fmap concat (forM files (forbiddenImports root))
        violations `shouldBe` []

    it "renders a route without a browser toolchain" $
        routeToUri (Bookmark 1) `shouldBe` "/bookmark/1"

{- | Forbidden module names on an import line. Comments may mention Miso; the
dependency is what matters.
-}
forbiddenImports :: FilePath -> FilePath -> IO [String]
forbiddenImports root file = do
    content <- readFile file
    let violations =
            [ relative <> ":" <> show lineNumber <> ": " <> line
            | (lineNumber, line) <- zip [1 :: Int ..] (lines content)
            , isImportLine line
            , any (`isInfixOf` line) forbidden
            ]
    pure violations
  where
    relative = drop (length root + 1) file
    forbidden = ["miso", "Miso", "JSFFI", "GHC.Wasm", "Javascript"]

isImportLine :: String -> Bool
isImportLine line = "import" `isPrefixOf` dropWhile isSpace line

{- | The test binary runs with the package root as its working directory when
cabal invokes it; the other candidates keep @runghc@ from the repository
root working too.
-}
findSourceRoot :: IO FilePath
findSourceRoot = do
    candidates <- filterM doesDirectoryExist ["src", "../web-logic/src", "web-logic/src"]
    case candidates of
        (root : _) -> pure root
        [] -> pure "src"

haskellFiles :: FilePath -> IO [FilePath]
haskellFiles directory = do
    entries <- listDirectory directory
    fmap concat $
        forM entries $ \entry -> do
            let path = directory </> entry
            isDirectory <- doesDirectoryExist path
            if isDirectory
                then haskellFiles path
                else pure [path | takeExtension path == ".hs"]
