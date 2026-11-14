module Eza.Web.Update where

import Miso (Effect ())

import Eza.Web.Logic.Model (Action (..), Model)

updateModel :: Action -> Effect () () Model Action
