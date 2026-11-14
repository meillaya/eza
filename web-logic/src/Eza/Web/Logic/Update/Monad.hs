{- | The pure update monad and its handler environment.

An update is a function from the current 'Model' to a new 'Model' plus the
'Eza.Web.Logic.Effect.Effect' values the shell must interpret. Group reducers
write their state transitions in this monad, so a group looks like the old
Miso update code but names no browser operation: every external step is an
'emit'.

The dispatcher is carried in 'Env' rather than imported by the group modules,
which keeps the group modules free of a cycle with the top-level dispatcher
(the old shell used @Update.hs-boot@ for this) and lets a native test drive one
group without the others.
-}
module Eza.Web.Logic.Update.Monad (
    Update,
    Env (..),
    runUpdate,
    dispatch,
    askEnv,
    get,
    put,
    putModel,
    modify,
    emit,
) where

import Eza.Web.Logic.Effect (Effect)
import Eza.Web.Logic.Model (Action, Model)

-- | A pure update: read and write the model, and append shell effects.
newtype Update a = Update
    { runUpdate :: Env -> Model -> (a, Model, [Effect])
    }

{- | The handlers a group reducer may dispatch to by action. The top-level
dispatcher installs itself here, so 'dispatch' can run a nested update
synchronously (its effects are appended in place, in order).
-}
data Env = Env
    { envDispatch :: Action -> Update ()
    }

instance Functor Update where
    fmap f (Update run) = Update $ \env model ->
        let (a, model', effects) = run env model
         in (f a, model', effects)

instance Applicative Update where
    pure a = Update $ \_ model -> (a, model, [])
    Update runF <*> Update runA = Update $ \env model ->
        let (f, model1, effects1) = runF env model
            (a, model2, effects2) = runA env model1
         in (f a, model2, effects1 <> effects2)

instance Monad Update where
    Update runA >>= next = Update $ \env model ->
        let (a, model1, effects1) = runA env model
            (b, model2, effects2) = runUpdate (next a) env model1
         in (b, model2, effects1 <> effects2)

-- | The environment of the update being interpreted.
askEnv :: Update Env
askEnv = Update $ \env model -> (env, model, [])

{- | Run another action's update through the top-level dispatcher, in place.
The nested effects are appended at the current position, so the browser sees
the same order the Miso update function used to produce.
-}
dispatch :: Action -> Update ()
dispatch action = do
    env <- askEnv
    envDispatch env action

-- | The current model.
get :: Update Model
get = Update $ \_ model -> (model, model, [])

-- | Replace the model.
put :: Model -> Update ()
put model = Update $ \_ _ -> ((), model, [])

-- | Apply a function to the model.
putModel :: (Model -> Model) -> Update ()
putModel f = Update $ \_ model -> ((), f model, [])

-- | Monadic record update.
modify :: (Model -> Model) -> Update ()
modify = putModel

-- | Ask the shell to perform one effect after the update completes.
emit :: Effect -> Update ()
emit effect = Update $ \_ model -> ((), model, [effect])
