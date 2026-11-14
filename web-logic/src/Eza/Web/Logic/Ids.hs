{- | Identities the native client reducers allocate themselves.

They live in their own module so that 'Eza.Web.Logic.Model' can hold request
and timer ids without importing the effect vocabulary, and so that a leaf
module (the ledger reducer) can allocate ids without pulling in the whole
update monad.
-}
module Eza.Web.Logic.Ids (
    RequestId (..),
    TimerId (..),
    nextRequestId,
    requestIsCurrent,
) where

{- | The identity of one in-flight request. Ids are allocated by the reducer
that issued the request and increase monotonically, so "newer" is just a
comparison.
-}
newtype RequestId = RequestId
    { unRequestId :: Int
    }
    deriving (Eq, Ord, Show)

-- | The identity of one scheduled timer. Allocated by the reducer.
newtype TimerId = TimerId
    { unTimerId :: Int
    }
    deriving (Eq, Ord, Show)

-- | The successor of a request id. Reducers allocate ids from their state.
nextRequestId :: RequestId -> RequestId
nextRequestId (RequestId n) = RequestId (n + 1)

{- | Does a response stamped with @stamped@ still answer the @current@ request?
The comparison lives here so every slice shares one staleness rule.
-}
requestIsCurrent :: RequestId -> RequestId -> Bool
requestIsCurrent current stamped = stamped == current
