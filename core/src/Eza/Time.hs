{-# LANGUAGE OverloadedStrings #-}

{- | UTC civil dates from POSIX seconds, shared by the graph view matcher and
tests. The library's @created_at@ values are UTC; the minimum Int spans
1970 to well past this century, but the conversion is total for any Int.
-}
module Eza.Time (
    utcYear,
    utcDay,
    utcYearDay,
    daysFromCivil,
) where

import Data.Text (Text)
import qualified Data.Text as T

-- | POSIX seconds to the UTC year.
utcYear :: Int -> Int
utcYear seconds = fromInteger year
  where
    (year, _, _) = civilFromDays (posixDays seconds)

-- | POSIX seconds to @YYYY-MM-DD@ in UTC.
utcDay :: Int -> Text
utcDay seconds = T.concat [pad 4 (show year), "-", pad 2 (show month), "-", pad 2 (show day)]
  where
    (year, month, day) = utcYearDay seconds

-- | POSIX seconds to (year, month, day) in UTC.
utcYearDay :: Int -> (Int, Int, Int)
utcYearDay seconds =
    let (year, month, day) = civilFromDays (posixDays seconds)
     in (fromInteger year, month, day)

posixDays :: Int -> Integer
posixDays seconds = floorDiv (toInteger seconds) 86400

{- | Floor division for negative POSIX values, so dates before 1970 stay
monotonic.
-}
floorDiv :: Integer -> Integer -> Integer
floorDiv a b = (a - modulo) `div` b
  where
    modulo = ((a `mod` b) + b) `mod` b

{- | Howard Hinnant's civil-from-days algorithm. Days are counted from
1970-01-01; the result is total and monotonic.
-}
civilFromDays :: Integer -> (Integer, Int, Int)
civilFromDays days =
    let z = days + 719468
        era = if z >= 0 then z `div` 146097 else (z - 146096) `div` 146097
        doe = z - era * 146097
        yoe = (doe - doe `div` 1460 + doe `div` 36524 - doe `div` 146096) `div` 365
        y = yoe + era * 400
        doy = doe - (365 * yoe + yoe `div` 4 - yoe `div` 100)
        mp = (5 * doy + 2) `div` 153
        d = doy - (153 * mp + 2) `div` 5 + 1
        m = mp + if mp < 10 then 3 else -9
        year = y + if m <= 2 then 1 else 0
     in (year, fromInteger m, fromInteger d)

-- | Inverse conversion, kept for round-trip tests.
daysFromCivil :: Integer -> Int -> Int -> Integer
daysFromCivil year month day =
    let y = year - if month <= 2 then 1 else 0
        era = if y >= 0 then y `div` 400 else (y - 399) `div` 400
        yoe = y - era * 400
        mp = if month > 2 then month - 3 else month + 9
        doy = (153 * mp + 2) `div` 5 + day - 1
        doe = yoe * 365 + yoe `div` 4 - yoe `div` 100 + toInteger doy
     in era * 146097 + doe - 719468

pad :: Int -> String -> Text
pad width value = T.pack (replicate (max 0 (width - length value)) '0' <> value)
