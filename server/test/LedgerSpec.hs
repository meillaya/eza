{- | Native tests for the ledger page segmentation.

The Miso client renders 'Eza.Ledger.ledgerEntries', so these tests pin the
divider order the ledger shows and the row indexes the cursor and the
virtualized scroll depend on.
-}
module LedgerSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Eza.Ledger (LedgerEntry (..), ledgerEntries)
import Eza.Time (daysFromCivil)
import Eza.Types (BookmarkSummary (..))

spec :: Spec
spec = do
    describe "ledgerEntries" $ do
        it "groups rows into exactly one section per filed year" $ do
            let rows =
                    [ record 1 (stamp 2023)
                    , record 2 (stamp 2021)
                    , record 3 (stamp 2023)
                    , record 4 (stamp 2022)
                    , record 5 (stamp 2021)
                    ]
            yearSections (ledgerEntries [] rows)
                `shouldBe` [(2023, [1, 3]), (2021, [2, 5]), (2022, [4])]

        it "orders the sections by the year's first appearance" $ do
            let rows =
                    [ record 1 (stamp 2022)
                    , record 2 (stamp 2021)
                    , record 3 (stamp 2022)
                    , record 4 (stamp 2021)
                    ]
            map fst (yearSections (ledgerEntries [] rows)) `shouldBe` [2022, 2021]

        it "never moves an existing section when a page is appended" $ do
            let page1 = [record 1 (stamp 2023), record 2 (stamp 2024)]
                page2 = page1 ++ [record 3 (stamp 2022), record 4 (stamp 2023)]
            map fst (yearSections (ledgerEntries [] page1)) `shouldBe` [2023, 2024]
            map fst (yearSections (ledgerEntries [] page2)) `shouldBe` [2023, 2024, 2022]

        it "keeps each row's index in the loaded list" $ do
            let rows =
                    [ record 10 (stamp 2023)
                    , record 11 (stamp 2022)
                    , record 12 (stamp 2023)
                    ]
            [idx | LedgerRow idx _ <- ledgerEntries [] rows] `shouldBe` [0, 2, 1]

        it "does not invent a section for records with no save date" $ do
            let rows = [record 1 (stamp 2023), record 2 0, record 3 (stamp 2023)]
                entries = ledgerEntries [] rows
            map fst (yearSections entries) `shouldBe` [2023]
            [bsId bookmark | LedgerRow _ bookmark <- entries] `shouldBe` [1, 3]

        it "prints the per-year match count on the divider" $ do
            let rows = [record 1 (stamp 2023)]
            ledgerEntries [(2023, 7)] rows
                `shouldBe` [LedgerYear 2023 (Just 7), LedgerRow 0 (record 1 (stamp 2023))]

        it "leaves the count absent when the server sent none" $ do
            let rows = [record 1 (stamp 2023)]
            ledgerEntries [] rows
                `shouldBe` [LedgerYear 2023 Nothing, LedgerRow 0 (record 1 (stamp 2023))]

-- | @Jan 1 <year>@ in POSIX seconds, the filed date the ledger groups by.
stamp :: Int -> Int
stamp year = fromInteger (daysFromCivil (toInteger year) 1 1) * 86400

record :: Int -> Int -> BookmarkSummary
record bid createdAt =
    BookmarkSummary
        { bsId = bid
        , bsUrl = "https://example.com/" <> showText bid
        , bsTitle = "record " <> showText bid
        , bsDomain = "example.com"
        , bsCreatedAt = createdAt
        , bsAddedAt = createdAt
        , bsFaviconUrl = ""
        , bsTags = []
        , bsIsRead = False
        , bsIsDead = False
        , bsSnippet = Nothing
        }
  where
    showText :: Int -> Text
    showText = T.pack . show

{- | The ledger as @(year, row ids)@: the shape the dividers and rows paint,
with the row order preserved from the result list.
-}
yearSections :: [LedgerEntry] -> [(Int, [Int])]
yearSections [] = []
yearSections (LedgerYear year _ : rest) =
    let (rows, remaining) = span isRow rest
     in (year, [bsId bookmark | LedgerRow _ bookmark <- rows]) : yearSections remaining
yearSections (LedgerRow _ _ : rest) = yearSections rest

isRow :: LedgerEntry -> Bool
isRow LedgerRow{} = True
isRow LedgerYear{} = False
