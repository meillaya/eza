{-# LANGUAGE OverloadedStrings #-}

{- | Wikilink parsing shared by the server (link sync) and the Miso client
(note rendering).  Supports @[[target]]@ and @[[target|display]]@.
-}
module Eza.Wikilink (
    Wikilink (..),
    parseWikilinks,
) where

import Data.Text (Text)
import qualified Data.Text as T

data Wikilink = Wikilink
    { wlTarget :: Text
    , wlDisplay :: Maybe Text
    , wlOffset :: Int
    , wlLine :: Int
    }
    deriving (Show, Eq)

parseWikilinks :: Text -> [Wikilink]
parseWikilinks body = go 0 0 body
  where
    go _ _ t | T.null t = []
    go offset line t =
        case T.breakOn "[[" t of
            (before, rest)
                | T.null rest -> []
                | otherwise ->
                    let line' = line + T.count "\n" before
                        start = offset + T.length before
                        afterOpen = T.drop 2 rest
                     in case T.breakOn "]]" afterOpen of
                            (_, suffix) | T.null suffix -> []
                            (inner, suffix) ->
                                let consumed = T.length before + 2 + T.length inner + 2
                                    rest' = T.drop 2 suffix
                                    link = mkLink start line' inner
                                 in maybe id (:) link (go (offset + consumed) line' rest')

    mkLink start line inner =
        let (target, display) = T.breakOn "|" inner
            target' = T.strip target
            display' = T.strip (T.drop 1 display)
         in if T.null target'
                then Nothing
                else
                    Just
                        Wikilink
                            { wlTarget = target'
                            , wlDisplay = if T.null display' then Nothing else Just display'
                            , wlOffset = start
                            , wlLine = line + 1
                            }
