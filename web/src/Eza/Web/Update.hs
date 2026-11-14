{- | The MVU adapter: run the native pure update, store the returned model and
interpret the effects it asked for.

All state transitions and the decision of which effect to run live in
@eza-web-logic@ ("Eza.Web.Logic.Update"); this module is the thin Miso glue.
The old per-route-group update modules, the recursive dispatcher and
@Update.hs-boot@ are gone: the native dispatcher is total and acyclic.
-}
module Eza.Web.Update (
    updateModel,
    subscriptions,
) where

import Miso (Effect (), get, put)

import Eza.Web.Interpreter (interpretEffects, subscriptions)
import Eza.Web.Logic.Model (Action, Model)
import qualified Eza.Web.Logic.Update as Logic

updateModel :: Action -> Effect () () Model Action
updateModel action = do
    model <- get
    let (model', effects) = Logic.update model action
    put model'
    interpretEffects effects
