{- | The one build version of the server. This is deliberately a single literal
in one module: `scripts/version.sh` compares it with flake.nix and every Cabal
package, so a release bump that forgets it fails the version gate. Never
hardcode a version string anywhere else.
-}
module Eza.Version (ezaVersionText) where

import Data.Text (Text)

ezaVersionText :: Text
ezaVersionText = "0.4.0.0"
