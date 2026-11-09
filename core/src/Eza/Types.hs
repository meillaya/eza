{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Shared DTOs exchanged between the Haskell server and the Miso client.
module Eza.Types (
    BookmarkSummary (..),
    BookmarkDetail (..),
    TagStat (..),
    SearchPage (..),
    SavedSearch (..),
    LibraryStats (..),
    Backlink (..),
    Backlinks (..),
    GraphTag (..),
    GraphRecord (..),
    GraphLink (..),
    GraphData (..),
    ImportReport (..),
    CredentialInfo (..),
    Highlight (..),
    DedupGroup (..),
    DedupCounts (..),
    DedupReport (..),
    DedupMergeAllReport (..),
) where

import Data.Aeson (FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON, object, withObject, (.:), (.:?), (.!=), (.=))
import Data.Text (Text)
import GHC.Generics (Generic)

import Eza.Json (jsonOptions)

data BookmarkSummary = BookmarkSummary
    { bsId :: Int
    , bsUrl :: Text
    , bsTitle :: Text
    , bsDomain :: Text
    , bsCreatedAt :: Int
    , bsAddedAt :: Int
    , bsFaviconUrl :: Text
    , bsTags :: [Text]
    , bsIsRead :: Bool
    , bsIsDead :: Bool
    , bsSnippet :: Maybe Text
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON BookmarkSummary where
    toJSON = genericToJSON (jsonOptions "bs")
instance FromJSON BookmarkSummary where
    parseJSON = genericParseJSON (jsonOptions "bs")

data BookmarkDetail = BookmarkDetail
    { bdId :: Int
    , bdUrl :: Text
    , bdTitle :: Text
    , bdDomain :: Text
    , bdCreatedAt :: Int
    , bdAddedAt :: Int
    , bdFaviconUrl :: Text
    , bdTags :: [Text]
    , bdIsRead :: Bool
    , bdIsDead :: Bool
    , bdSnippet :: Maybe Text
    , bdNoteBody :: Text
    , bdExtractedText :: Text
    , bdAuthor :: Text
    , bdSitename :: Text
    , bdPublishedAt :: Maybe Int
    , bdLanguage :: Text
    , bdImageUrl :: Text
    , bdFinalUrl :: Text
    , bdSnapshotPath :: Text
    , bdSnapshotKind :: Text
    , bdLastOpenedAt :: Maybe Int
    , bdLastCheckedAt :: Maybe Int
    , bdEnrichState :: Text
    , bdEnrichError :: Text
    , bdReadingTimeMinutes :: Int
    , bdLinks :: [Backlink]
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON BookmarkDetail where
    toJSON = genericToJSON (jsonOptions "bd")
instance FromJSON BookmarkDetail where
    parseJSON = genericParseJSON (jsonOptions "bd")

data TagStat = TagStat
    { tsName :: Text
    , tsCount :: Int
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON TagStat where
    toJSON = genericToJSON (jsonOptions "ts")
instance FromJSON TagStat where
    parseJSON = genericParseJSON (jsonOptions "ts")

data SearchPage = SearchPage
    { spItems :: [BookmarkSummary]
    , spTotal :: Int
    , spOffset :: Int
    , spLimit :: Int
    , spHasMore :: Bool
    , spYearCounts :: [(Int, Int)]
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON SearchPage where
    toJSON = genericToJSON (jsonOptions "sp")
instance FromJSON SearchPage where
    parseJSON = genericParseJSON (jsonOptions "sp")

data SavedSearch = SavedSearch
    { ssId :: Int
    , ssName :: Text
    , ssQ :: Text
    , ssTags :: [Text]
    , ssCreatedAt :: Int
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON SavedSearch where
    toJSON = genericToJSON (jsonOptions "ss")
instance FromJSON SavedSearch where
    parseJSON = genericParseJSON (jsonOptions "ss")

{- | Whole library figures the interface needs on first paint: totals, filing
history for the accessions page and the honest never-run counters.
-}
data LibraryStats = LibraryStats
    { lsTotal :: Int
    , lsTags :: Int
    , lsTagLinks :: Int
    , lsSources :: Int
    , lsTopSources :: [(Text, Int)]
    , lsSourcesOnce :: Int
    , lsFirstDay :: Text
    , lsLastDay :: Text
    , lsDays :: Int
    , lsYears :: [(Int, Int)]
    , lsFilingDays :: [(Text, Int)]
    , lsUnread :: Int
    , lsDead :: Int
    , lsQueued :: Int
    , lsFaviconBytes :: Int
    , lsHighlights :: Int
    , lsShares :: Int
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON LibraryStats where
    toJSON = genericToJSON (jsonOptions "ls")
instance FromJSON LibraryStats where
    parseJSON = genericParseJSON (jsonOptions "ls")

data Backlink = Backlink
    { blSourceId :: Int
    , blSourceTitle :: Text
    , blSnippet :: Text
    , blLine :: Maybe Int
    , blResolved :: Bool
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON Backlink where
    toJSON = genericToJSON (jsonOptions "bl")
instance FromJSON Backlink where
    parseJSON = genericParseJSON (jsonOptions "bl")

data Backlinks = Backlinks
    { bksLinked :: [Backlink]
    , bksUnlinked :: [Backlink]
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON Backlinks where
    toJSON = genericToJSON (jsonOptions "bks")
instance FromJSON Backlinks where
    parseJSON = genericParseJSON (jsonOptions "bks")

{- | One tag node in the whole-library graph. @gtCount@ is the number of
records that carry the tag, as stored in @bookmark_tags@.
-}
data GraphTag = GraphTag
    { gtName :: Text
    , gtCount :: Int
    }
    deriving stock (Show, Eq)

-- | Compact wire encoding: @[name,count]@.
instance ToJSON GraphTag where
    toJSON tag = toJSON (gtName tag, gtCount tag)
instance FromJSON GraphTag where
    parseJSON value = do
        (name, count) <- parseJSON value
        pure (GraphTag name count)

{- | One record node in the whole-library graph. @grTags@ holds indexes into
'gdTags', not tag names, so the payload does not repeat a name twenty-one
thousand times. The title falls back to the domain when the record has none.
-}
data GraphRecord = GraphRecord
    { grId :: Int
    , grTitle :: Text
    , grDomain :: Text
    , grCreatedAt :: Int
    , grIsRead :: Bool
    , grIsDead :: Bool
    , grTags :: [Int]
    }
    deriving stock (Show, Eq)

-- | Compact wire encoding: @[id,title,domain,created_at,is_read,is_dead,tags]@.
instance ToJSON GraphRecord where
    toJSON record =
        toJSON
            ( grId record
            , grTitle record
            , grDomain record
            , grCreatedAt record
            , grIsRead record
            , grIsDead record
            , grTags record
            )
instance FromJSON GraphRecord where
    parseJSON value = do
        (recordId, title, domain, createdAt, isRead, isDead, tags) <- parseJSON value
        pure (GraphRecord recordId title domain createdAt isRead isDead tags)

-- | One resolved wikilink between two record nodes.
data GraphLink = GraphLink
    { glSource :: Int
    , glTarget :: Int
    }
    deriving stock (Show, Eq)

-- | Compact wire encoding: @[source,target]@.
instance ToJSON GraphLink where
    toJSON link = toJSON (glSource link, glTarget link)
instance FromJSON GraphLink where
    parseJSON value = do
        (source, target) <- parseJSON value
        pure (GraphLink source target)

{- | The whole library as one graph: every record, every tag, and the resolved
wikilinks between records. Tag membership is expressed by 'grTags'; the only
two relationship types are that membership and 'gdLinks'.
-}
data GraphData = GraphData
    { gdTags :: [GraphTag]
    , gdRecords :: [GraphRecord]
    , gdLinks :: [GraphLink]
    , gdRevision :: Text
    -- ^ Cheap aggregate fingerprint of the library. Clients only compare it;
    -- they never parse it.
    }
    deriving stock (Show, Eq)

instance ToJSON GraphData where
    toJSON graph =
        object
            [ "tags" .= gdTags graph
            , "records" .= gdRecords graph
            , "links" .= gdLinks graph
            , "revision" .= gdRevision graph
            ]
instance FromJSON GraphData where
    parseJSON = withObject "GraphData" $ \o ->
        GraphData
            <$> o .: "tags"
            <*> o .: "records"
            <*> o .: "links"
            <*> o .:? "revision" .!= ""

data ImportReport = ImportReport
    { irFound :: Int
    , irHttpAnchors :: Int
    , irUniqueUrls :: Int
    , irInserted :: Int
    , irExisting :: Int
    , irDuplicateAnchors :: Int
    , irSkippedNonHttp :: Int
    , irTagsCreated :: Int
    , irTagLinksAdded :: Int
    , irFoldersSkipped :: Int
    , irUntagged :: Int
    , irElapsedMs :: Int
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON ImportReport where
    toJSON = genericToJSON (jsonOptions "ir")
instance FromJSON ImportReport where
    parseJSON = genericParseJSON (jsonOptions "ir")

data Highlight = Highlight
    { hId :: Int
    , hBookmarkId :: Int
    , hQuote :: Text
    , hStartOffset :: Int
    , hEndOffset :: Int
    , hNote :: Text
    , hColor :: Text
    , hCreatedAt :: Int
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON Highlight where
    toJSON = genericToJSON (jsonOptions "h")
instance FromJSON Highlight where
    parseJSON = genericParseJSON (jsonOptions "h")

data CredentialInfo = CredentialInfo
    { ciId :: Text
    , ciNickname :: Text
    , ciCreatedAt :: Int
    , ciLastUsedAt :: Maybe Int
    , ciBackupEligible :: Bool
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON CredentialInfo where
    toJSON = genericToJSON (jsonOptions "ci")
instance FromJSON CredentialInfo where
    parseJSON = genericParseJSON (jsonOptions "ci")

{- | One duplicate-candidate group. @dgKind@ is @\"url\"@ when every member
shares the canonical URL key, or @\"title\"@ for the advisory same-title
groups. Items are sorted by record id, so the first item is the default keeper.
-}
data DedupGroup = DedupGroup
    { dgKey :: Text
    , dgKind :: Text
    , dgItems :: [BookmarkSummary]
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON DedupGroup where
    toJSON = genericToJSON (jsonOptions "dg")
instance FromJSON DedupGroup where
    parseJSON = genericParseJSON (jsonOptions "dg")

-- | Whole-library duplicate totals: exact counts for the duplicates view and
-- its "merge all" confirmation.
data DedupCounts = DedupCounts
    { dcUrlGroups :: Int
    , dcUrlRecords :: Int
    , dcTitleGroups :: Int
    , dcTitleRecords :: Int
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON DedupCounts where
    toJSON = genericToJSON (jsonOptions "dc")
instance FromJSON DedupCounts where
    parseJSON = genericParseJSON (jsonOptions "dc")

-- | One page of duplicate candidates, split into safe same-URL groups and
-- advisory same-title groups, plus exact totals for the whole library.
data DedupReport = DedupReport
    { drCounts :: DedupCounts
    , drUrlGroups :: [DedupGroup]
    , drTitleGroups :: [DedupGroup]
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON DedupReport where
    toJSON = genericToJSON (jsonOptions "dr")
instance FromJSON DedupReport where
    parseJSON = genericParseJSON (jsonOptions "dr")

-- | Result of the confirmed one-shot URL-duplicate merge.
data DedupMergeAllReport = DedupMergeAllReport
    { dmGroups :: Int
    , dmRecords :: Int
    , dmAffected :: Int
    , dmSnapshotId :: Int
    , dmElapsedMs :: Int
    }
    deriving stock (Show, Eq, Generic)

instance ToJSON DedupMergeAllReport where
    toJSON = genericToJSON (jsonOptions "dm")
instance FromJSON DedupMergeAllReport where
    parseJSON = genericParseJSON (jsonOptions "dm")
