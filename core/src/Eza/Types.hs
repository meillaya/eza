{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Shared DTOs exchanged between the Haskell server and the Miso client.
module Eza.Types
  ( BookmarkSummary (..)
  , BookmarkDetail (..)
  , TagStat (..)
  , SearchPage (..)
  , SavedSearch (..)
  , BootPayload (..)
  , Backlink (..)
  , Backlinks (..)
  , GraphNode (..)
  , GraphEdge (..)
  , GraphData (..)
  , ImportReport (..)
  , CredentialInfo (..)
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON)
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

data BootPayload = BootPayload
  { bpVersion :: Text
  , bpOrigin :: Text
  , bpTags :: [TagStat]
  , bpSavedSearches :: [SavedSearch]
  , bpInitial :: SearchPage
  }
  deriving stock (Show, Eq, Generic)

instance ToJSON BootPayload where
  toJSON = genericToJSON (jsonOptions "bp")
instance FromJSON BootPayload where
  parseJSON = genericParseJSON (jsonOptions "bp")

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

data GraphNode = GraphNode
  { gnId :: Int
  , gnTitle :: Text
  , gnUrl :: Text
  , gnTags :: [Text]
  , gnIsRead :: Bool
  , gnIndegree :: Int
  }
  deriving stock (Show, Eq, Generic)

instance ToJSON GraphNode where
  toJSON = genericToJSON (jsonOptions "gn")
instance FromJSON GraphNode where
  parseJSON = genericParseJSON (jsonOptions "gn")

data GraphEdge = GraphEdge
  { geSource :: Int
  , geTarget :: Int
  }
  deriving stock (Show, Eq, Generic)

instance ToJSON GraphEdge where
  toJSON = genericToJSON (jsonOptions "ge")
instance FromJSON GraphEdge where
  parseJSON = genericParseJSON (jsonOptions "ge")

data GraphData = GraphData
  { gdNodes :: [GraphNode]
  , gdEdges :: [GraphEdge]
  }
  deriving stock (Show, Eq, Generic)

instance ToJSON GraphData where
  toJSON = genericToJSON (jsonOptions "gd")
instance FromJSON GraphData where
  parseJSON = genericParseJSON (jsonOptions "gd")

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
