module Eza.Web.Update where

import Miso (Effect ())

import Eza.Web.Model (Action (..), Model)

updateModel :: Action -> Effect () () Model Action
