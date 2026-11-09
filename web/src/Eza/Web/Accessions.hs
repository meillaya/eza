{- | Accessions: the archive by year, source and filing day.

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
import qualified Miso.Html.Event as HE
import qualified Miso.Html.Property as HP

import Eza.Types (LibraryStats (..))
import Eza.Web.Model

{- | The printed index page: archive figures, one mark per filing day per
year, sources ranked with leader dots, the long tail and a date span.
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
                    Just stats
                        | lsTotal stats <= 0 -> emptyIndex
                        | otherwise -> indexView m stats
                )
            ]
        ]

-- ---------------------------------------------------------------- states ---

{- | The figures arrive with the boot payload. Until they do, say so instead
of printing zeroes that would read as an empty library.
-}
notLoaded :: [View () () Model Action]
notLoaded =
    [ headShell []
    , H.div_
        [HP.class_ "empty"]
        [H.p_ [HP.class_ "empty-body"] [text "The figures have not loaded."]]
    ]

{- | A library with no records yet: there is no index to set, so the page says
that instead of printing an empty chart that looks like a result.
-}
emptyIndex :: [View () () Model Action]
emptyIndex =
    [ headShell []
    , H.div_
        [HP.class_ "empty"]
        [H.p_ [HP.class_ "empty-body"] [text "No records yet."]]
    ]

indexView :: Model -> LibraryStats -> [View () () Model Action]
indexView m stats =
    [ headView stats
    , filingDays m stats
    , lower stats
    , foot stats
    ]

-- ------------------------------------------------------------------ head ---

headShell :: [View () () Model Action] -> View () () Model Action
headShell extras =
    H.header_
        [HP.class_ "acc-head"]
        [ H.div_
            [HP.class_ "acc-head-left"]
            ([H.h1_ [HP.class_ "acc-title"] [text "Accessions by year"]] <> extras)
        ]

headView :: LibraryStats -> View () () Model Action
headView stats =
    H.header_
        [HP.class_ "acc-head"]
        [ H.div_
            [HP.class_ "acc-head-left"]
            [ H.h1_ [HP.class_ "acc-title"] [text "Accessions by year"]
            , H.p_
                [HP.class_ "acc-hint meta"]
                [text "A year, a filing day or a source opens the ledger filtered to it."]
            ]
        , figures stats
        ]

figures :: LibraryStats -> View () () Model Action
figures stats =
    H.dl_
        [HP.class_ "acc-figures"]
        [ figure "entries" (num (lsTotal stats))
        , figure "sources" (num (lsSources stats))
        , figure "filing days" (num (lsDays stats))
        ]

figure :: MisoString -> MisoString -> View () () Model Action
figure label value =
    H.div_ [] [H.dt_ [] [text label], H.dd_ [] [text value]]

-- ------------------------------------------------------------ filing days ---

filingDays :: Model -> LibraryStats -> View () () Model Action
filingDays m stats =
    H.section_
        [HP.class_ "mc", HP.aria_ "label" "Filing days by year"]
        [ H.div_
            [HP.class_ "mc-head"]
            [ H.h2_ [HP.class_ "sc"] [text "Filing days"]
            , H.span_ [HP.class_ "mc-note meta"] [text "one mark per filing day"]
            ]
        , H.div_
            [HP.class_ "mc-axis"]
            [ H.div_ [HP.class_ "mc-axis-spacer"] []
            , H.div_ [HP.class_ "mc-axis-months"] monthLabels
            , H.div_ [HP.class_ "mc-axis-tail"] []
            ]
        , H.div_ [] (map (yearRow m stats) (sortOn fst (lsYears stats)))
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

yearRow :: Model -> LibraryStats -> (Int, Int) -> View () () Model Action
yearRow m stats (year, entries) =
    H.div_
        [HP.class_ "mc-row"]
        [ yearButton
        , H.div_
            [ HP.class_ "mc-track"
            , HP.aria_ "label" (ms (show (length marks) <> " filing days in " <> show year <> ", " <> show entries <> " entries"))
            ]
            (map (markView m) marks)
        , H.span_ [HP.class_ "mc-n"] [text (num entries)]
        , H.span_ [HP.class_ "mc-d"] [text (ms (show (length marks) <> " days"))]
        ]
  where
    marks = yearMarks stats year
    yearText = show year
    yearButton =
        H.button_
            [ HP.class_ "mc-year"
            , HP.type_ "button"
            , HP.title_ (ms ("Open the ledger filtered to " <> yearText))
            , HP.aria_ "label" (ms (yearText <> ", " <> countPhrase entries))
            , HP.data_ "testid" "accessions-year"
            , HP.data_ "year" (ms yearText)
            , HE.onClick (FilterByQuery (T.pack ("year:" <> yearText)))
            ]
            [text (ms yearText)]

{- | Position and height of every filing-day mark in one year. Height grows
with the logarithm of the day's count, as in the printed plate.
-}
yearMarks :: LibraryStats -> Int -> [(Text, Double, Int, Int)]
yearMarks stats year =
    [ (day, position, height, count)
    | (day, count) <- lsFilingDays stats
    , parsedYear day == Just year
    , let height = 6 + min 12 (round (logBase (10 :: Double) (fromIntegral (count + 1 :: Int) :: Double) * 6))
    , Just position <- [dayPosition day]
    ]

{- | A filing-day mark. On a wide screen it is a pointer-only button that
opens the ledger on that day; below the mobile breakpoint the marks are
decorative and the year labels carry the taps.
-}
markView :: Model -> (Text, Double, Int, Int) -> View () () Model Action
markView m (day, position, height, count)
    | mWidth m < 768 =
        H.i_
            [ C.style_ [C.left (C.pct position), C.height (C.px height)]
            , HP.aria_ "hidden" "true"
            ]
            []
    | otherwise =
        H.button_
            [ HP.class_ "mc-mark"
            , HP.type_ "button"
            , HP.tabindex_ "-1"
            , C.style_ [C.left (C.pct position), C.height (C.px height)]
            , HP.title_ tip
            , HP.data_ "tip" tip
            , HP.data_ "testid" "accessions-day"
            , HP.data_ "day" (ms (T.unpack day))
            , HP.aria_ "label" tip
            , HE.onClick (FilterByQuery ("day:" <> day))
            ]
            []
  where
    tip = ms (displayDay day <> ", " <> countPhrase count)

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
        ]
  where
    sources = lsTopSources stats

rankRow :: Int -> (Text, Int) -> View () () Model Action
rankRow index (domain, count) =
    H.li_
        []
        [ H.button_
            [ HP.class_ "rank-hit"
            , HP.type_ "button"
            , HP.title_ (ms ("Open the ledger filtered to " <> source))
            , HP.aria_ "label" (ms (source <> ", " <> countPhrase count))
            , HP.data_ "testid" "accessions-source"
            , HP.data_ "source" (ms source)
            , HE.onClick (FilterByQuery (T.pack source))
            ]
            [ H.span_ [HP.class_ "rank-no"] [text (ms (pad2 index))]
            , H.span_ [HP.class_ "rank-name"] [text (ms source)]
            , H.span_ [HP.class_ "lead", HP.aria_ "hidden" "true"] []
            , H.span_ [HP.class_ "rank-n"] [text (num count)]
            ]
        ]
  where
    source = displayDomain domain

longTail :: LibraryStats -> View () () Model Action
longTail stats =
    H.section_
        [HP.class_ "acc-tail"]
        [ H.div_
            [HP.class_ "sec-head"]
            [H.h2_ [HP.class_ "sc"] [text "The long tail"]]
        , H.p_
            [HP.class_ "tail-fig"]
            [ H.span_ [HP.class_ "big"] [text (num (lsSourcesOnce stats))]
            , H.span_
                [HP.class_ "tail-fig-label"]
                [text (ms ("of " <> comma (lsSources stats) <> " sources are filed exactly once."))]
            ]
        , H.p_ [HP.class_ "tail-body"] [text (ms (habitSentence stats))]
        , H.p_ [HP.class_ "tail-label meta"] [text "busiest days"]
        , H.ul_ [HP.class_ "tail-days"] (map busiestRow (busiestDays stats))
        , H.p_ [HP.class_ "tail-body"] [text (ms (typicalSentence stats))]
        ]

habitSentence :: LibraryStats -> String
habitSentence stats =
    displayDomain topDomain
        <> " holds "
        <> comma topCount
        <> " entries; the ten busiest sources hold "
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
        <> " days have one."
  where
    median = medianOf (map snd (lsFilingDays stats))

busiestDays :: LibraryStats -> [(Text, Int)]
busiestDays stats = take 3 (sortOn (negate . snd) (lsFilingDays stats))

busiestRow :: (Text, Int) -> View () () Model Action
busiestRow (day, count) =
    H.li_
        []
        [ H.button_
            [ HP.class_ "tail-hit"
            , HP.type_ "button"
            , HP.title_ (ms ("Open the ledger filtered to " <> displayDay day))
            , HP.aria_ "label" (ms (displayDay day <> ", " <> countPhrase count))
            , HP.data_ "testid" "accessions-busiest"
            , HP.data_ "day" (ms (T.unpack day))
            , HE.onClick (FilterByQuery ("day:" <> day))
            ]
            [ H.span_ [HP.class_ "meta"] [text (dayStamp day)]
            , H.span_ [HP.class_ "lead", HP.aria_ "hidden" "true"] []
            , H.span_ [HP.class_ "mono"] [text (num count)]
            ]
        ]

-- ------------------------------------------------------------------ foot ---

foot :: LibraryStats -> View () () Model Action
foot stats =
    H.footer_
        [HP.class_ "acc-foot"]
        [ H.span_
            [HP.class_ "acc-colophon"]
            [H.span_ [HP.class_ "meta"] [text (ms (filedSpan (lsFirstDay stats) (lsLastDay stats)))]]
        ]

filedSpan :: Text -> Text -> String
filedSpan first last_
    | first == last_ = "filed " <> displayDay first
    | otherwise = "filed " <> displayDay first <> " to " <> displayDay last_

-- --------------------------------------------------------------- helpers ---

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

-- | "3 entries" for a control's accessible name.
countPhrase :: Int -> String
countPhrase count = comma count <> " " <> (if count == 1 then "entry" else "entries")

-- | Drop the @www.@ prefix so one hostname ranks as itself.
displayDomain :: Text -> String
displayDomain domain = T.unpack (fromMaybe domain (T.stripPrefix "www." domain))

dayStamp :: Text -> MisoString
dayStamp = ms . displayDay

displayDay :: Text -> String
displayDay = T.unpack . T.replace "-" "."
