{-# LANGUAGE OverloadedStrings #-}

{- | Pure text helpers for the client's input fields and the reader: tag entry,
the PWA share-target text and the @[[wikilink@ completion popup.

These functions are Miso-free and take 'Text', so they are tested natively. The
Miso shell still stores 'Miso.MisoString' in its model until M2-B2 phase 2
moves the Model type; the one-line wrappers in @Eza.Web.Update.Common@ convert
at that boundary.
-}
module Eza.Web.Logic.Input (
    splitTags,
    parseTagInput,
    firstUrlIn,
    wikilinkQueryAt,
    completeWikilink,
) where

import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T

{- | Split a comma/semicolon separated tag input into lower-case, de-duplicated
tags. Both separators are accepted because the add dialog has always allowed
either.
-}
splitTags :: Text -> [Text]
splitTags raw =
    nub
        [ T.toLower tag
        | tag <- T.words (T.map replaceSep raw)
        , not (T.null tag)
        ]
  where
    replaceSep c = if c == ',' || c == ';' then ' ' else c

-- | Parse the one-tag input of the detail editor. An empty input is not a tag.
parseTagInput :: Text -> Maybe Text
parseTagInput raw =
    let tag = T.toLower (T.strip raw)
     in if T.null tag then Nothing else Just tag

-- | Pick the first http(s) URL out of the PWA share-target @text@ field.
firstUrlIn :: Text -> Maybe Text
firstUrlIn queryText =
    case filter isHttpWord (T.words queryText) of
        (url : _) -> Just (T.strip url)
        [] -> Nothing
  where
    isHttpWord word =
        "http://" `T.isPrefixOf` word || "https://" `T.isPrefixOf` word

{- | Detect an open @[[query@ immediately before the cursor. A closed link or a
line break ends the potential completion; a very long query is not a title
search.
-}
wikilinkQueryAt :: Text -> Int -> Maybe Text
wikilinkQueryAt body cursor =
    let before = T.take (max 0 cursor) body
        (prefix, suffix) = T.breakOnEnd "[[" before
     in if T.null prefix
            then Nothing
            else
                if "]]" `T.isInfixOf` suffix || T.any (== '\n') suffix
                    then Nothing
                    else
                        let query = suffix
                         in if T.length query > 80 then Nothing else Just query

{- | Replace the open @[[query@ with a completed wikilink, returning the new
body and the caret position after the inserted link.
-}
completeWikilink :: Text -> Int -> Text -> (Text, Int)
completeWikilink body cursor title =
    let before = T.take (max 0 cursor) body
        (prefix, _) = T.breakOnEnd "[[" before
        start = T.length prefix - 2
        (headPart, _) = T.splitAt (max 0 start) body
        inserted = headPart <> "[[" <> title <> "]] "
        remainder = T.drop cursor body
     in (inserted <> remainder, T.length inserted)
