{-# LANGUAGE OverloadedStrings #-}

{- | Pure matcher for graph color groups and graph filters.

The search parser is shared with the ledger. The graph has only the record
fields it carries on the wire (title, domain, tag names, filed date, read and
dead flags), so the matcher evaluates exactly those; @link:@ is rejected by
the view validator because the graph payload has no target URLs.

A record matches when every plain term appears in its title, domain, or one of
its tag names, no excluded term appears there, every @tag:@ filter names one of
its tags, the flags agree, and the filed date agrees. Malformed operators are
dropped by the parser, matching the ledger's behaviour.
-}
module Eza.GraphMatch
    ( RecordContext (..)
    , TagContext (..)
    , recordContext
    , matchesRecord
    , matchesTag
    , matchesQueryRecord
    , ColorAssignment (..)
    , assignGroupColors
    ) where

import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as M
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T

import Eza.SearchQuery
import Eza.Time (utcDay, utcYear)
import Eza.Types (GraphData (..), GraphRecord (..), GraphTag (..))
import Eza.View (ColorGroup (..))

-- | The fields a graph record exposes to a matcher.
data RecordContext = RecordContext
    { rcTitle :: Text
    , rcDomain :: Text
    , rcTags :: [Text]
    , rcCreatedAt :: Int
    , rcIsRead :: Bool
    , rcIsDead :: Bool
    }
    deriving (Show, Eq)

-- | The fields a graph tag exposes to a matcher.
newtype TagContext = TagContext
    { tcName :: Text
    }
    deriving (Show, Eq)

-- | Build a record context from the compact graph payload and its tag table.
recordContext :: GraphData -> GraphRecord -> RecordContext
recordContext graph record =
    RecordContext
        { rcTitle = grTitle record
        , rcDomain = grDomain record
        , rcTags =
            [ gtName tag
            | index <- grTags record
            , Just tag <- [indexTag index]
            ]
        , rcCreatedAt = grCreatedAt record
        , rcIsRead = grIsRead record
        , rcIsDead = grIsDead record
        }
  where
    tags = gdTags graph
    indexTag index
        | index >= 0 && index < length tags = Just (tags !! index)
        | otherwise = Nothing

-- | Whether a record satisfies every part of a parsed query.
matchesRecord :: SearchQuery -> RecordContext -> Bool
matchesRecord query context =
    null (sqLinkTargets query)
        && textFieldMatches
        && tagFiltersMatch
        && flagFiltersMatch
        && dateFiltersMatch
  where
    haystack =
        T.toLower
            ( T.intercalate
                " "
                (rcTitle context : rcDomain context : rcTags context)
            )
    plainTerms = map T.toLower (sqTerms query)
    negatedTerms = map T.toLower (sqNegated query)
    textFieldMatches =
        all (`T.isInfixOf` haystack) plainTerms
            && not (any (`T.isInfixOf` haystack) negatedTerms)
    lowerTags = map T.toLower (rcTags context)
    tagFiltersMatch =
        all (\tag -> T.toLower (T.strip tag) `elem` lowerTags) (sqTags query)
    flagFiltersMatch =
        (not (sqIsUnread query) || not (rcIsRead context))
            && (not (sqIsDead query) || rcIsDead context)
    dateFiltersMatch =
        ( case sqYear query of
            Nothing -> True
            Just year -> rcCreatedAt context > 0 && utcYear (rcCreatedAt context) == year
        )
            && ( case sqDay query of
                    Nothing -> True
                    Just day -> rcCreatedAt context > 0 && utcDay (rcCreatedAt context) == day
               )

-- | Convenience form for callers that already hold a 'GraphData' and record.
matchesQueryRecord :: SearchQuery -> GraphData -> GraphRecord -> Bool
matchesQueryRecord query graph = matchesRecord query . recordContext graph

-- | A tag matches a query's text and @tag:@ parts. Boolean, link and date
-- filters cannot describe a tag, so a query that uses them does not colour
-- tag nodes.
matchesTag :: SearchQuery -> TagContext -> Bool
matchesTag query context =
    null (sqLinkTargets query)
        && not (sqIsUnread query)
        && not (sqIsDead query)
        && isNothing (sqYear query)
        && isNothing (sqDay query)
        && plainMatches
        && tagFilterMatches
  where
    name = T.toLower (tcName context)
    plainMatches =
        all (\term -> T.toLower term `T.isInfixOf` name) (sqTerms query)
            && not (any (\term -> T.toLower term `T.isInfixOf` name) (sqNegated query))
    tagFilterMatches =
        all (\tag -> T.toLower (T.strip tag) == name) (sqTags query)


-- ------------------------------------------------------------- colouring ---

-- | The result of applying ordered colour groups to a graph. Record colours
-- are keyed by bookmark id; tag colours are keyed by tag name. A node with no
-- entry keeps the theme's default colour.
data ColorAssignment = ColorAssignment
    { caRecordColors :: IM.IntMap Text
    , caTagColors :: M.Map Text Text
    }
    deriving (Show, Eq)

{- | Apply enabled colour groups in order; the first matching group wins. The
queries are parsed once, then evaluated against every record and tag. Views
limit the number of groups, so this stays a linear pass per group.
-}
assignGroupColors :: [ColorGroup] -> GraphData -> ColorAssignment
assignGroupColors groups graph =
    ColorAssignment
        { caRecordColors =
            IM.fromList
                [ (grId record, cgColor group)
                | record <- gdRecords graph
                , Just group <- [firstRecordGroup record]
                ]
        , caTagColors =
            M.fromList
                [ (gtName tag, cgColor group)
                | tag <- gdTags graph
                , Just group <- [firstTagGroup tag]
                ]
        }
  where
    active =
        [ (group, parseSearchQuery (cgQuery group))
        | group <- groups
        , cgEnabled group
        ]
    firstRecordGroup record =
        firstJust
            [ (group, parsed)
            | (group, parsed) <- active
            , matchesQueryRecord parsed graph record
            ]
    firstTagGroup tag =
        firstJust
            [ (group, parsed)
            | (group, parsed) <- active
            , matchesTag parsed (TagContext (gtName tag))
            ]
    firstJust [] = Nothing
    firstJust ((group, _) : _) = Just group
