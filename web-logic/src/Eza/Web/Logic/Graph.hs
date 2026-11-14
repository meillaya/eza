{- | The graph state types the client model owns.

The rendering and layout math stays in "Eza.Web.Graph" because it talks to the
canvas; these values travel between the model and that painter, so they are
plain native data.
-}
module Eza.Web.Logic.Graph (
    GraphView (..),
    initialGraphView,
    GraphMatches (..),
    emptyMatches,
    GraphDrag (..),
) where

import qualified Data.IntSet as IS

data GraphView = GraphView
    { gvWidth :: Double
    , gvHeight :: Double
    , gvDpr :: Double
    , gvScale :: Double
    , gvPan :: (Double, Double)
    , gvFit :: Double
    }
    deriving (Eq, Show)

initialGraphView :: GraphView
initialGraphView = GraphView 920 480 1 1 (0, 0) 1

data GraphMatches = GraphMatches
    { gmActive :: Bool
    , gmIds :: IS.IntSet
    , gmTop :: [Int]
    , gmCount :: Int
    , gmTags :: IS.IntSet
    }
    deriving (Eq, Show)

emptyMatches :: GraphMatches
emptyMatches = GraphMatches False IS.empty [] 0 IS.empty

data GraphDrag = GraphDrag
    { gdStart :: (Double, Double)
    , gdLast :: (Double, Double)
    , gdMoved :: Bool
    }
    deriving (Eq, Show)
