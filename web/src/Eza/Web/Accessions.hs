{- | Accessions: the whole archive set as a printed index.

The page reads 'Eza.Types.LibraryStats' only. Every figure, mark and row is
cut from the library's own database: no sample data, no estimated numbers.
-}
module Eza.Web.Accessions (accessionsPage) where

import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Miso
import qualified Miso.CSS as C
import qualified Miso.Html as H
import qualified Miso.Html.Property as HP

import Eza.Types (LibraryStats (..))
import Eza.Web.Model

{- | The printed index page: archive figures, one mark per filing day per
year, sources ranked with leader dots, the long tail and a colophon.
-}
accessionsPage :: Model -> View () () Model Action
accessionsPage m =
    H.section_
        [ HP.class_ "accessions"
        , HP.data_ "testid" "accessions"
        , C.styleInline_ "display:flex;flex-direction:column;flex:1 1 auto;min-height:0"
        ]
        [ H.div_
            [HP.class_ "acc-scroll"]
            [ H.div_
                [HP.class_ "acc"]
                ( case mStats m of
                    Nothing -> notLoaded
                    Just stats -> indexView stats
                )
            ]
        ]

-- ---------------------------------------------------------------- states ---

{- | The figures arrive with the boot payload. Until they do, say so instead
of printing zeroes that would read as an empty library.
-}
notLoaded :: [View () () Model Action]
notLoaded =
    [ H.header_
        [HP.class_ "acc-head"]
        [ H.div_
            [HP.class_ "acc-head-left"]
            [ H.h1_ [HP.class_ "acc-title"] [text "Accessions by year"]
            , H.p_
                [HP.class_ "acc-lede"]
                [text "The whole library, set as an index: every year it grew, every source it came from, and every day it was used."]
            ]
        , figures Nothing
        ]
    , ruleLine
    , H.div_
        [HP.class_ "empty"]
        [ H.p_ [HP.class_ "empty-kicker meta"] [text "figures not loaded"]
        , H.h2_ [HP.class_ "empty-title display"] [text "The index is not set yet."]
        , H.p_
            [HP.class_ "empty-body"]
            [text "The archive figures arrive with the client's boot payload. Nothing is printed here until the library has answered."]
        , H.div_ [HP.class_ "empty-lines", HP.aria_ "hidden" "true"] (replicate 4 (H.i_ [] []))
        , H.p_
            [HP.class_ "empty-end meta"]
            [H.span_ [] [text "figures not loaded"], H.span_ [] [text "the catalogue is still opening"]]
        ]
    ]

indexView :: LibraryStats -> [View () () Model Action]
indexView stats =
    [ headView stats
    , ruleLine
    , filingDays stats
    , ruleLine
    , lower stats
    , foot stats
    ]

-- ------------------------------------------------------------------ head ---

headView :: LibraryStats -> View () () Model Action
headView stats =
    H.header_
        [HP.class_ "acc-head"]
        [ H.div_
            [HP.class_ "acc-head-left"]
            [ H.h1_ [HP.class_ "acc-title"] [text "Accessions by year"]
            , H.p_
                [HP.class_ "acc-lede"]
                [text "The whole library, set as an index: every year it grew, every source it came from, and every day it was used."]
            ]
        , figures (Just stats)
        ]

figures :: Maybe LibraryStats -> View () () Model Action
figures stats =
    H.dl_
        [HP.class_ "acc-figures"]
        [ figure "entries" (statOf lsTotal)
        , figure "sources" (statOf lsSources)
        , figure "filing days" (statOf lsDays)
        ]
  where
    statOf field = case stats of
        Nothing -> "not yet"
        Just s -> num (field s)

figure :: MisoString -> MisoString -> View () () Model Action
figure label value =
    H.div_ [] [H.dt_ [] [text label], H.dd_ [] [text value]]

-- ------------------------------------------------------------ filing days ---

filingDays :: LibraryStats -> View () () Model Action
filingDays stats =
    H.section_
        [HP.class_ "mc", HP.aria_ "label" "Filing days by year"]
        [ H.div_
            [HP.class_ "mc-head"]
            [ H.h2_ [HP.class_ "sc"] [text "Filing days"]
            , H.span_ [HP.class_ "mc-note meta"] [text "one mark per filing day"]
            , H.span_ [HP.class_ "mc-note meta"] [text "a taller mark, a fuller day"]
            ]
        , H.div_
            [HP.class_ "mc-axis"]
            [ H.div_ [HP.class_ "mc-axis-spacer"] []
            , H.div_ [HP.class_ "mc-axis-months"] monthLabels
            , H.div_ [HP.class_ "mc-axis-tail"] []
            ]
        , H.div_ [] (map (yearRow stats) (sortOn fst (lsYears stats)))
        ]

monthLabels :: [View () () Model Action]
monthLabels = zipWith monthLabel monthNames monthSpans
  where
    monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"] :: [MisoString]
    monthSpans = zip monthStarts monthEnds
    monthStarts = scanl (+) 0 monthLengths
    monthEnds = drop 1 (scanl (+) 0 monthLengths)
    monthLengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31] :: [Int]
    monthLabel name (start, end) =
        let middle = fromIntegral (start + end) / 2 / 365 * 100
         in H.span_ [C.style_ [C.left (C.pct middle)]] [text name]

yearRow :: LibraryStats -> (Int, Int) -> View () () Model Action
yearRow stats (year, entries) =
    H.div_
        [HP.class_ "mc-row"]
        [ H.span_ [HP.class_ "mc-year"] [text (ms (show year))]
        , H.div_
            [ HP.class_ "mc-track"
            , HP.aria_ "label" (ms (show (length marks) <> " filing days in " <> show year <> ", " <> show entries <> " entries"))
            ]
            (map markView marks)
        , H.span_ [HP.class_ "mc-n"] [text (num entries)]
        , H.span_ [HP.class_ "mc-d"] [text (ms (show (length marks) <> " days"))]
        ]
  where
    marks = yearMarks stats year

{- | Position and height of every filing-day mark in one year. Height grows
with the logarithm of the day's count, as in the printed plate.
-}
yearMarks :: LibraryStats -> Int -> [(Double, Int, Int)]
yearMarks stats year =
    [ (position, height, count)
    | (day, count) <- lsFilingDays stats
    , parsedYear day == Just year
    , let height = 6 + min 12 (round (logBase (10 :: Double) (fromIntegral (count + 1 :: Int) :: Double) * 6))
    , Just position <- [dayPosition day]
    ]

markView :: (Double, Int, Int) -> View () () Model Action
markView (position, height, count) =
    H.i_
        [ C.style_ [C.left (C.pct position), C.height (C.px height)]
        , HP.title_ (ms (show count <> if count == 1 then " entry" else " entries"))
        ]
        []

-- ---------------------------------------------------------------- lower ---

lower :: LibraryStats -> View () () Model Action
lower stats =
    H.div_
        [HP.class_ "acc-lower"]
        [ ranked stats
        , longTail stats
        ]

ranked :: LibraryStats -> View () () Model Action
ranked stats =
    H.section_
        [HP.class_ "acc-ranked"]
        [ H.div_
            [HP.class_ "sec-head"]
            [ H.h2_ [HP.class_ "sc"] [text "Sources, ranked"]
            , H.span_
                [HP.class_ "meta"]
                [text (ms ("top " <> show (min 16 (length sources)) <> " of " <> comma (lsSources stats)))]
            ]
        , H.ul_ [HP.class_ "rank-list"] (zipWith rankRow [1 :: Int ..] (take 16 sources))
        , rankNote sources
        ]
  where
    sources = lsTopSources stats

rankRow :: Int -> (Text, Int) -> View () () Model Action
rankRow index (domain, count) =
    H.li_
        []
        [ H.span_ [HP.class_ "rank-no"] [text (ms (pad2 index))]
        , H.span_ [HP.class_ "rank-name"] [text (ms (displayDomain domain))]
        , H.span_ [HP.class_ "lead", HP.aria_ "hidden" "true"] []
        , H.span_ [HP.class_ "rank-n"] [text (num count)]
        ]

{- | Two hostnames of one publication appear separately in the database. The
note is only printed when both are actually ranked, so it never claims more
than the data shows.
-}
rankNote :: [(Text, Int)] -> View () () Model Action
rankNote sources
    | youtubePair = H.p_ [HP.class_ "rank-note meta"] [text "youtube.com and m.youtube.com are one publication under two hostnames."]
    | otherwise = H.span_ [] []
  where
    names = map (displayDomain . fst) sources
    youtubePair = ("youtube.com" `elem` names) && ("m.youtube.com" `elem` names)

longTail :: LibraryStats -> View () () Model Action
longTail stats =
    H.section_
        [HP.class_ "acc-tail"]
        [ H.div_
            [HP.class_ "sec-head"]
            [ H.h2_ [HP.class_ "sc"] [text "The long tail"]
            , H.span_ [HP.class_ "meta"] [text "every source, counted"]
            ]
        , H.p_
            [HP.class_ "tail-fig"]
            [ H.span_ [HP.class_ "big"] [text (num (lsSourcesOnce stats))]
            , H.span_
                [HP.class_ "tail-fig-label"]
                [text (ms ("of " <> comma (lsSources stats) <> " sources are filed exactly once."))]
            ]
        , H.p_ [HP.class_ "tail-body"] [text (ms (habitSentence stats))]
        , H.ul_ [HP.class_ "tail-days"] (map busiestRow (busiestDays stats))
        , H.p_ [HP.class_ "tail-body"] [text (ms (typicalSentence stats))]
        ]

habitSentence :: LibraryStats -> String
habitSentence stats =
    "The rest are habits: "
        <> displayDomain topDomain
        <> " holds "
        <> comma topCount
        <> " entries, and the ten busiest sources hold "
        <> comma topTen
        <> "."
  where
    (topDomain, topCount) = fromMaybe ("", 0) (safeHead (lsTopSources stats))
    topTen = sum (map snd (take 10 (lsTopSources stats)))

typicalSentence :: LibraryStats -> String
typicalSentence stats =
    "A typical filing day holds "
        <> show median
        <> " "
        <> (if median == 1 then "entry" else "entries")
        <> "; "
        <> comma (lsDays stats)
        <> " of the "
        <> comma (spanDays stats)
        <> " days were used at all."
  where
    median = medianOf (map snd (lsFilingDays stats))

busiestDays :: LibraryStats -> [(Text, Int)]
busiestDays stats = take 3 (sortOn (negate . snd) (lsFilingDays stats))

busiestRow :: (Text, Int) -> View () () Model Action
busiestRow (day, count) =
    H.li_
        []
        [ H.span_ [HP.class_ "meta"] [text (dayStamp day)]
        , H.span_ [HP.class_ "lead", HP.aria_ "hidden" "true"] []
        , H.span_ [HP.class_ "mono"] [text (num count)]
        ]

-- ------------------------------------------------------------------ foot ---

foot :: LibraryStats -> View () () Model Action
foot stats =
    H.footer_
        [HP.class_ "acc-foot"]
        [ H.span_
            [HP.class_ "acc-colophon"]
            [ H.span_ [HP.class_ "meta"] [text "compiled from the library's own sqlite file"]
            , H.span_ [HP.class_ "meta"] [text (ms ("last accession " <> displayDay (lsLastDay stats)))]
            , H.span_
                [HP.class_ "meta"]
                [text (ms (displayDay (lsFirstDay stats) <> " to " <> displayDay (lsLastDay stats)))]
            ]
        , H.span_ [HP.class_ "acc-proof"] [text "eza"]
        ]

-- --------------------------------------------------------------- helpers ---

ruleLine :: View () () Model Action
ruleLine = H.div_ [HP.class_ "rule", HP.aria_ "hidden" "true"] []

-- | Split an ISO day (2025-09-24) into a year and a day of year.
parsedYear :: Text -> Maybe Int
parsedYear day = (\(y, _, _) -> y) <$> dateParts day

dateParts :: Text -> Maybe (Int, Int, Int)
dateParts day = case T.splitOn "-" day of
    [y, m, d] -> (,,) <$> intOf y <*> intOf m <*> intOf d
    _ -> Nothing
  where
    intOf value = case reads (T.unpack value) :: [(Int, String)] of
        [(number, "")] -> Just number
        _ -> Nothing

{- | Where a filing day sits in its year, as a percentage. Mid-day placement
keeps the first and last marks off the axis ends.
-}
dayPosition :: Text -> Maybe Double
dayPosition day = do
    (year, month, dayOfMonth) <- dateParts day
    let inYear = daysInYear year
        ordinal = dayOfYear month dayOfMonth
    pure ((fromIntegral ordinal - 0.5) / fromIntegral inYear * 100)

dayOfYear :: Int -> Int -> Int
dayOfYear month dayOfMonth = sum (take (month - 1) monthLengths) + dayOfMonth
  where
    monthLengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31] :: [Int]

daysInYear :: Int -> Int
daysInYear year
    | isLeap year = 366
    | otherwise = 365

isLeap :: Int -> Bool
isLeap year = (year `mod` 4 == 0 && year `mod` 100 /= 0) || year `mod` 400 == 0

-- | Inclusive span in days between the first and last accession day.
spanDays :: LibraryStats -> Int
spanDays stats =
    case (dateParts (lsFirstDay stats), dateParts (lsLastDay stats)) of
        (Just first, Just final) -> max 1 (dayNumber final - dayNumber first + 1)
        _ -> max 1 (lsDays stats)

-- | Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
dayNumber :: (Int, Int, Int) -> Int
dayNumber (year, month, dayOfMonth) = era * 146097 + dayOfEra - 719468
  where
    y = if month <= 2 then year - 1 else year
    era = (if y >= 0 then y else y - 399) `div` 400
    yoe = y - era * 400
    mp = if month > 2 then month - 3 else month + 9
    doy = (153 * mp + 2) `div` 5 + dayOfMonth - 1
    dayOfEra = yoe * 365 + yoe `div` 4 - yoe `div` 100 + doy

medianOf :: [Int] -> Int
medianOf [] = 0
medianOf values =
    case drop (length sorted `div` 2) sorted of
        (middle : _) -> middle
        [] -> 0
  where
    sorted = sortOn id values

safeHead :: [a] -> Maybe a
safeHead [] = Nothing
safeHead (x : _) = Just x

-- | 3,224 with thousands separators.
num :: Int -> MisoString
num = ms . comma

comma :: Int -> String
comma value = group (reverse (show (abs value))) []
  where
    group [] acc = if value < 0 then '-' : acc else acc
    group digits acc =
        let (chunk, rest) = splitAt 3 digits
         in case rest of
                [] -> reverse chunk ++ acc
                _ -> group rest (',' : reverse chunk ++ acc)

pad2 :: Int -> String
pad2 value
    | value < 10 = '0' : show value
    | otherwise = show value

-- | Drop the @www.@ prefix so one hostname ranks as itself.
displayDomain :: Text -> String
displayDomain domain = T.unpack (fromMaybe domain (T.stripPrefix "www." domain))

dayStamp :: Text -> MisoString
dayStamp = ms . displayDay

displayDay :: Text -> String
displayDay = T.unpack . T.replace "-" "."
