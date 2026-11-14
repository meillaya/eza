module Main (main) where

import qualified Data.Text.IO as TIO
import Options.Applicative (execParser)

import Eza.Cli (CliCommand (..), PasswordSource (..), cliParserInfo, readHidden, runCli, runRoutesCommand)
import Eza.Config (loadConfig)

{- | The executable is a thin shell: the command surface, its parsers, and the
command runners live in "Eza.Cli" so the tests can drive them against a
temporary installation with stdin supplied the way a deployment script would.
The @routes@ command is answered from the compiled route table before the
configuration is loaded, so it works without a database or a data directory.
-}
main :: IO ()
main = do
    command <- execParser cliParserInfo
    case command of
        RoutesCmd withMarkdown -> runRoutesCommand withMarkdown
        _ -> do
            cfg <- loadConfig
            runCli cfg (PasswordSource{psReadHidden = readHidden, psReadStdinLine = TIO.getLine}) command
