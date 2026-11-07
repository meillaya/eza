{- | A small, dependency-free markdown renderer that produces miso views.

Notes live in markdown (see docs/UI.md).  Rendering to 'View' nodes instead
of DOM strings keeps the client CSP friendly and lets wikilinks render as
styled chips.  Supported: headings, paragraphs, bold/italic/inline code,
links, fenced code, blockquotes, ordered + unordered lists, hr, wikilinks.
-}
module Eza.Web.Markdown (
    renderMarkdown,
    renderInline,
    stripMarkdown,
) where

import Data.Char (isDigit)
import Data.Text (Text)
import qualified Data.Text as T

import Miso (MisoString, View, ms, text)
import qualified Miso.Html as H
import qualified Miso.Html.Property as HP

import qualified Eza.Wikilink as WL

-- | Render a markdown document to a list of block views.
renderMarkdown :: Text -> [View context props model action]
renderMarkdown = blocks . T.lines . T.replace "\r\n" "\n"

-- | Inline rendering for single-line snippets.
renderInline :: Text -> [View context props model action]
renderInline = inline

-- | Plain-text projection (used for aria labels / previews).
stripMarkdown :: Text -> Text
stripMarkdown = T.unwords . T.words . T.filter keep . T.replace "]]" " " . T.replace "[[" " "
  where
    keep c = c /= '*' && c /= '`' && c /= '#'

-- ------------------------------------------------------------------ blocks --

blocks :: [Text] -> [View context props model action]
blocks [] = []
blocks (line : rest)
    | T.null (T.strip line) = blocks rest
    | Just level <- headingLevel line = heading level (T.strip (T.drop level line)) : blocks rest
    | "```" `T.isPrefixOf` line =
        let (codeLines, remaining) = break (T.isPrefixOf "```") rest
            codeView =
                H.pre_
                    []
                    [H.code_ [] [text (mstr (T.intercalate "\n" codeLines))]]
         in codeView : blocks (drop 1 remaining)
    | isHr line = H.hr_ [] : blocks rest
    | ">" `T.isPrefixOf` T.stripStart line =
        let (quoted, remaining) = span (T.isPrefixOf ">" . T.stripStart) (line : rest)
            stripQuote = T.strip . T.drop 1 . T.stripStart
         in H.blockquote_ [] (blocks (map stripQuote quoted)) : blocks remaining
    | Just _ <- orderedItem line =
        let (items, remaining) = collectList orderedItem (line : rest)
         in H.ol_ [] (map listItem items) : blocks remaining
    | Just _ <- bulletItem line =
        let (items, remaining) = collectList bulletItem (line : rest)
         in H.ul_ [] (map listItem items) : blocks remaining
    | otherwise =
        let (para, remaining) = paragraph (line : rest)
         in H.p_ [] (inline (T.intercalate " " para)) : blocks remaining

listItem :: Text -> View context props model action
listItem t = H.li_ [] (inline t)

paragraph :: [Text] -> ([Text], [Text])
paragraph = go []
  where
    go acc [] = (reverse acc, [])
    go acc (l : ls)
        | T.null (T.strip l) = (reverse acc, ls)
        | isBlockStart l = (reverse acc, l : ls)
        | otherwise = go (T.strip l : acc) ls

isBlockStart :: Text -> Bool
isBlockStart l =
    isHr l
        || maybe False (const True) (headingLevel l)
        || "```" `T.isPrefixOf` l
        || ">" `T.isPrefixOf` T.stripStart l
        || maybe False (const True) (bulletItem l)
        || maybe False (const True) (orderedItem l)

collectList :: (Text -> Maybe Text) -> [Text] -> ([Text], [Text])
collectList itemParser = go []
  where
    go acc [] = (reverse acc, [])
    go acc (l : ls) = case itemParser l of
        Just content ->
            let (continuation, rest) =
                    span (\x -> not (T.null (T.strip x)) && itemParser x == Nothing && not (isBlockStart x)) ls
             in go ((content <> " " <> T.intercalate " " (map T.strip continuation)) : acc) rest
        Nothing -> (reverse acc, l : ls)

bulletItem :: Text -> Maybe Text
bulletItem l = case T.uncons (T.stripStart l) of
    Just ('-', rest) -> Just (T.strip rest)
    Just ('*', rest) | not ("*" `T.isPrefixOf` T.strip rest) -> Just (T.strip rest)
    Just ('+', rest) -> Just (T.strip rest)
    _ -> Nothing

orderedItem :: Text -> Maybe Text
orderedItem l =
    let s = T.stripStart l
        (digits, rest) = T.span isDigit s
     in if not (T.null digits)
            then case T.uncons rest of
                Just ('.', after) -> Just (T.strip after)
                _ -> Nothing
            else Nothing

headingLevel :: Text -> Maybe Int
headingLevel l =
    let s = T.stripStart l
        hashes = T.takeWhile (== '#') s
     in if T.null hashes || T.length hashes > 4
            then Nothing
            else case T.uncons (T.drop (T.length hashes) s) of
                Just (' ', _) -> Just (T.length hashes)
                _ -> Nothing

isHr :: Text -> Bool
isHr l =
    let s = T.strip l
     in T.length s >= 3
            && (T.all (== '-') s || T.all (== '*') s || T.all (== '_') s)

heading :: Int -> Text -> View context props model action
heading level title = case level of
    1 -> H.h1_ [] (inline title)
    2 -> H.h2_ [] (inline title)
    3 -> H.h3_ [] (inline title)
    _ -> H.h4_ [] (inline title)

-- ------------------------------------------------------------------ inline --

-- | Inline markdown scanner: bold, italic, inline code, links, wikilinks.
inline :: Text -> [View context props model action]
inline input
    | T.null input = []
    | Just (label, rest) <- wikilinkAt input = wikilinkView label : inline rest
    | Just ('`', rest) <- T.uncons input = codeView rest
    | "**" `T.isPrefixOf` input = boldView
    | "*" `T.isPrefixOf` input = emView
    | Just ('[', _) <- T.uncons input
    , Just (label, href, rest) <- linkAt input =
        linkView label href : inline rest
    | otherwise = text (mstr chunk) : inline rest'
  where
    (chunk, rest') = T.span plainChar input
    plainChar c = c /= '[' && c /= '`' && c /= '*'

    codeView rest =
        let (codeText, after) = T.breakOn "`" rest
         in if T.null after
                then [text (mstr input)]
                else H.code_ [] [text (mstr codeText)] : inline (T.drop 1 after)

    boldView =
        let (boldText, after) = T.breakOn "**" (T.drop 2 input)
         in if T.null after
                then [text (mstr input)]
                else H.strong_ [] (inline boldText) : inline (T.drop 2 after)

    emView =
        let (emText, after) = T.breakOn "*" (T.drop 1 input)
         in if T.null after
                then [text (mstr input)]
                else H.em_ [] (inline emText) : inline (T.drop 1 after)

wikilinkAt :: Text -> Maybe (Text, Text)
wikilinkAt t = case T.stripPrefix "[[" t of
    Nothing -> Nothing
    Just rest ->
        let (inner, after) = T.breakOn "]]" rest
         in if T.null after
                then Nothing
                else Just (wikilinkLabel inner, T.drop 2 after)

wikilinkLabel :: Text -> Text
wikilinkLabel inner = case T.breakOn "|" inner of
    (target, display)
        | T.null display -> T.strip target
        | otherwise -> T.strip (T.drop 1 display)

wikilinkView :: Text -> View context props model action
wikilinkView label =
    H.span_ [HP.class_ "wikilink", HP.title_ (mstr ("Wikilink: " <> label))] [text (mstr label)]

linkAt :: Text -> Maybe (Text, Text, Text)
linkAt t = case T.stripPrefix "[" t of
    Nothing -> Nothing
    Just rest ->
        let (label, afterLabel) = T.breakOn "]" rest
         in case T.stripPrefix "](" afterLabel of
                Nothing -> Nothing
                Just hrefStart ->
                    let (href, afterHref) = T.breakOn ")" hrefStart
                     in if T.null afterHref
                            then Nothing
                            else Just (label, href, T.drop 1 afterHref)

linkView :: Text -> Text -> View context props model action
linkView label href =
    H.a_
        [HP.href_ (mstr href), HP.rel_ "noopener noreferrer", HP.target_ "_blank"]
        (inline label)

{- | Keep the shared wikilink parser in the dependency graph: it documents the
grammar this renderer implements for note previews.
-}
_parsedWikilinks :: Text -> [WL.Wikilink]
_parsedWikilinks = WL.parseWikilinks

mstr :: Text -> MisoString
mstr = ms
