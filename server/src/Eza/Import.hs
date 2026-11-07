{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

-- | Netscape bookmarks.html parser and importer.
--
-- Browsers emit a narrow Netscape dialect: folders are <H3> followed by a
-- nested <DL>, links are <DT><A …>title</A>.  We keep the folder stack so
-- folder names become tags, with a noise filter for the timestamp/"New folder"
-- debris browser exports contain.
module Eza.Import
  ( ImportItem (..)
  , ParsedImport (..)
  , TagMode (..)
  , ImportOptions (..)
  , defaultImportOptions
  , parseNetscape
  , importParsed
  , decodeHtml
  ) where

import Control.Monad (foldM, forM, forM_)
import Data.Char (isAlphaNum, isDigit, isSpace)
import Data.Foldable (foldl')
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe, mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Text.HTML.TagSoup
import Text.Read (readMaybe)

import Eza.Types (ImportReport (..))
import Eza.Url (hostOf, isHttpUrl)

data TagMode = TagLeaf | TagDeepest | TagPath | TagNone
  deriving (Show, Eq)

data ImportOptions = ImportOptions
  { ioTagMode :: TagMode
  , ioSkinNoise :: Bool
  , ioMarkRead :: Bool
  }
  deriving (Show, Eq)

defaultImportOptions :: ImportOptions
defaultImportOptions = ImportOptions TagLeaf True False

data ImportItem = ImportItem
  { iiUrl :: Text
  , iiTitle :: Text
  , iiDomain :: Text
  , iiTags :: [Text]
  , iiCreatedAt :: Int
  }
  deriving (Show, Eq)

data ParsedImport = ParsedImport
  { piItems :: [ImportItem]
  , piFound :: Int
  , piHttp :: Int
  , piNonHttp :: Int
  , piDuplicates :: Int
  , piUntagged :: Int
  , piFoldersSkipped :: Int
  }
  deriving (Show, Eq)

-- ---------------------------------------------------------------------------
-- Decoding
-- ---------------------------------------------------------------------------

decodeHtml :: ByteString -> Text
decodeHtml raw0 =
  let raw = fromMaybe raw0 (BS.stripPrefix (BS.pack [0xEF, 0xBB, 0xBF]) raw0)
      prefix = BS.take 4096 raw
      lowerPrefix = T.toLower (TE.decodeUtf8With TEE.lenientDecode prefix)
      declared = declaredCharset lowerPrefix
   in case declared of
        Just cs
          | cs == "iso-8859-1" || cs == "latin1" || cs == "windows-1252" ->
              TE.decodeLatin1 raw
        _ -> case TE.decodeUtf8' raw of
          Right t -> t
          Left _ -> TE.decodeUtf8With TEE.lenientDecode raw

declaredCharset :: Text -> Maybe Text
declaredCharset lower =
  case T.breakOn "charset=" lower of
    (_, rest) | T.null rest -> Nothing
    (_, rest) ->
      let afterEq = T.drop 8 rest
          cleaned = T.takeWhile (\c -> isAlphaNum c || c == '_' || c == '-') afterEq
       in if T.null cleaned then Nothing else Just cleaned

-- ---------------------------------------------------------------------------
-- Parser
-- ---------------------------------------------------------------------------

data FolderInfo = FolderInfo
  { fiName :: Text
  , fiToolbar :: Bool
  , fiUnfiled :: Bool
  }

data PState = PState
  { psStack :: [Maybe Text]
  , psPending :: Maybe (Maybe Text)
  , psInH3 :: Bool
  , psH3Text :: Text
  , psH3Info :: Maybe FolderInfo
  , psInA :: Bool
  , psHref :: Text
  , psTitle :: Text
  , psAnchorTags :: [Text]
  , psCreated :: Maybe Int
  , psItems :: [ImportItem]
  , psSkipped :: Set Text
  , psFound :: Int
  , psHttp :: Int
  , psNonHttp :: Int
  }

parseNetscape :: ImportOptions -> ByteString -> ParsedImport
parseNetscape opts raw =
  let text = decodeHtml raw
      tags = parseTags text :: [Tag Text]
      st = foldl' (stepTag opts) initialState tags
      items = reverse (psItems st)
      (unique, dupes) = dedupe items
      untagged = length (filter (null . iiTags) unique)
   in ParsedImport
        { piItems = unique
        , piFound = psFound st
        , piHttp = psHttp st
        , piNonHttp = psNonHttp st
        , piDuplicates = dupes
        , piUntagged = untagged
        , piFoldersSkipped = Set.size (psSkipped st)
        }

initialState :: PState
initialState =
  PState
    { psStack = []
    , psPending = Nothing
    , psInH3 = False
    , psH3Text = ""
    , psH3Info = Nothing
    , psInA = False
    , psHref = ""
    , psTitle = ""
    , psAnchorTags = []
    , psCreated = Nothing
    , psItems = []
    , psSkipped = Set.empty
    , psFound = 0
    , psHttp = 0
    , psNonHttp = 0
    }

stepTag :: ImportOptions -> PState -> Tag Text -> PState
stepTag opts st = \case
  TagOpen name attrs
    | lname name == "h3" ->
        st {psInH3 = True, psH3Text = "", psH3Info = Just (folderInfo attrs)}
    | lname name == "dl" ->
        st
          { psStack = fromMaybe Nothing (psPending st) : psStack st
          , psPending = Nothing
          }
    | lname name == "a", not (psInA st) ->
        st
          { psInA = True
          , psHref = fromMaybe "" (lookupAttr "href" attrs)
          , psTitle = ""
          , psAnchorTags = parseTagsAttr (fromMaybe "" (lookupAttr "tags" attrs))
          , psCreated = parseAddDate (fromMaybe "" (lookupAttr "add_date" attrs))
          }
  TagClose name
    | lname name == "h3" ->
        let info0 = fromMaybe (FolderInfo "" False False) (psH3Info st)
            info = info0 {fiName = T.strip (psH3Text st)}
            (tag, skipped) = folderTag opts info
            skippedSet =
              if skipped
                then Set.insert (normalizeName (fiName info)) (psSkipped st)
                else psSkipped st
         in st
              { psInH3 = False
              , psH3Info = Nothing
              , psH3Text = ""
              , psPending = Just tag
              , psSkipped = skippedSet
              }
    | lname name == "dl" ->
        st {psStack = drop 1 (psStack st)}
    | lname name == "a", psInA st ->
        let href = T.strip (psHref st)
            title = cleanTitle (psTitle st)
            http = isHttpUrl href
            stackTags = folderStackTags (ioTagMode opts) (psStack st)
            tags = dedupeText (stackTags <> psAnchorTags st)
            created = fromMaybe 0 (psCreated st)
            item = ImportItem href title (hostOf href) tags created
            st' =
              st
                { psInA = False
                , psHref = ""
                , psTitle = ""
                , psAnchorTags = []
                , psCreated = Nothing
                , psFound = psFound st + 1
                }
         in if not http
              then st' {psNonHttp = psNonHttp st + 1}
              else
                st'
                  { psHttp = psHttp st + 1
                  , psItems = if T.null href then psItems st else item : psItems st
                  }
  TagText txt
    | psInA st -> st {psTitle = psTitle st <> txt}
    | psInH3 st -> st {psH3Text = psH3Text st <> txt}
  _ -> st
  where
    lname = T.toLower

folderInfo :: [(Text, Text)] -> FolderInfo
folderInfo attrs =
  FolderInfo
    { fiName = ""
    , fiToolbar = lowerBool (fromMaybe "" (lookupAttr "personal_toolbar_folder" attrs))
    , fiUnfiled = lowerBool (fromMaybe "" (lookupAttr "unfiled_bookmarks_folder" attrs))
    }

lowerBool :: Text -> Bool
lowerBool v = T.toLower (T.strip v) == "true"

folderTag :: ImportOptions -> FolderInfo -> (Maybe Text, Bool)
folderTag opts info
  | fiToolbar info = (Just "toolbar", False)
  | fiUnfiled info = (Just "unfiled", False)
  | otherwise =
      let n = normalizeName (fiName info)
       in if T.null n
            then (Nothing, False)
            else
              if ioSkinNoise opts && isNoiseFolder n
                then (Nothing, True)
                else (Just n, False)

folderStackTags :: TagMode -> [Maybe Text] -> [Text]
folderStackTags mode stack =
  let meaningful = catMaybes stack
   in case mode of
        TagNone -> []
        TagLeaf -> meaningful
        TagDeepest -> maybe [] (: []) (lastMaybe meaningful)
        TagPath ->
          let build [] = []
              build xs = T.intercalate "/" xs : build (init xs)
           in reverse (build meaningful)

lastMaybe :: [a] -> Maybe a
lastMaybe [] = Nothing
lastMaybe xs = Just (last xs)

-- ---------------------------------------------------------------------------
-- Attribute parsing
-- ---------------------------------------------------------------------------

lookupAttr :: Text -> [(Text, Text)] -> Maybe Text
lookupAttr key attrs = lookup (T.toLower key) [(T.toLower k, v) | (k, v) <- attrs]

parseAddDate :: Text -> Maybe Int
parseAddDate raw =
  let digits = T.takeWhile isDigit (T.strip raw)
   in if T.null digits then Nothing else readMaybe (T.unpack digits)

parseTagsAttr :: Text -> [Text]
parseTagsAttr raw =
  [ n
  | t <- T.splitOn "," raw
  , let n = normalizeName t
  , not (T.null n)
  ]

cleanTitle :: Text -> Text
cleanTitle = T.unwords . T.words . T.strip

-- ---------------------------------------------------------------------------
-- Tag normalization / noise
-- ---------------------------------------------------------------------------

normalizeName :: Text -> Text
normalizeName = T.unwords . T.words . T.toLower . T.strip

isNoiseFolder :: Text -> Bool
isNoiseFolder raw =
  let n = normalizeName raw
      ws = T.words n
   in T.null n
        || n `Set.member` noiseFolders
        || "new folder" `T.isPrefixOf` n
        || T.all isSymbolish n
        || containsIsoDate n
        || (hasMonth ws && hasYear ws)

noiseFolders :: Set Text
noiseFolders =
  Set.fromList
    [ "/"
    , "1"
    , "new folder"
    , "new folder 1"
    , "temp"
    , "temp 2"
    , "bookmarks bar"
    ]

isSymbolish :: Char -> Bool
isSymbolish c = isDigit c || isSpace c || c `elem` ("-/:._" :: String)

monthPrefixes :: [Text]
monthPrefixes =
  [ "jan", "feb", "mar", "apr", "may", "jun"
  , "jul", "aug", "sep", "oct", "nov", "dec"
  ]

hasMonth :: [Text] -> Bool
hasMonth ws = any (\w -> any (\m -> m `T.isPrefixOf` w) monthPrefixes) ws

hasYear :: [Text] -> Bool
hasYear ws = any (\w -> T.length (T.takeWhile isDigit w) == 4) ws

containsIsoDate :: Text -> Bool
containsIsoDate t =
  any isIsoWord (T.words (T.map replaceNonDate t))
  where
    replaceNonDate c
      | isDigit c = c
      | c == '-' || c == '/' || c == '.' = c
      | otherwise = ' '
    isIsoWord w =
      case T.split (\c -> c == '-' || c == '/' || c == '.') w of
        (a : b : c : _) ->
          T.length a == 4
            && T.all isDigit a
            && not (T.null b)
            && T.all isDigit b
            && not (T.null c)
            && T.all isDigit c
        _ -> False

-- ---------------------------------------------------------------------------
-- Dedupe
-- ---------------------------------------------------------------------------

dedupe :: [ImportItem] -> ([ImportItem], Int)
dedupe items =
  let m = foldl' insertItem Map.empty items
   in (Map.elems m, length items - Map.size m)
  where
    insertItem acc item =
      Map.alter
        ( \case
            Nothing -> Just item
            Just old ->
              Just
                old
                  { iiTitle = if T.null (iiTitle old) then iiTitle item else iiTitle old
                  , iiTags = dedupeText (iiTags old <> iiTags item)
                  , iiCreatedAt = minNonZero (iiCreatedAt old) (iiCreatedAt item)
                  }
        )
        (iiUrl item)
        acc

minNonZero :: Int -> Int -> Int
minNonZero 0 b = b
minNonZero a 0 = a
minNonZero a b = min a b

dedupeText :: [Text] -> [Text]
dedupeText = reverse . fst . foldl' step ([], Set.empty)
  where
    step (acc, seen) t =
      let n = normalizeName t
       in if T.null n || Set.member n seen then (acc, seen) else (n : acc, Set.insert n seen)

-- ---------------------------------------------------------------------------
-- Database import
-- ---------------------------------------------------------------------------

importParsed :: Connection -> ImportOptions -> ParsedImport -> IO ImportReport
importParsed conn opts parsed = do
  start <- getPOSIXTime
  now <- floor <$> getPOSIXTime
  (inserted, existing, tagsCreated, tagLinks) <-
    withImmediateTransaction conn $ do
      let allTagNames = Set.toList (Set.fromList (concatMap iiTags (piItems parsed)))
      tagsCreated <- sum <$> mapM (insertTag conn now) allTagNames
      tagIds <- tagIdMap conn
      let step (nIns, nExisting, nLinks) item = do
            let isRead = if ioMarkRead opts then (1 :: Int) else 0
            execute
              conn
              "INSERT INTO bookmarks (url,title,domain,source,created_at,added_at,updated_at,is_read) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(url) DO NOTHING"
              (iiUrl item, iiTitle item, iiDomain item, "netscape" :: Text, iiCreatedAt item, now, now, isRead)
            changed <- changes conn
            bid <-
              if changed > 0
                then fromIntegral <$> lastInsertRowId conn
                else do
                  rows <- query conn "SELECT id FROM bookmarks WHERE url = ?" (Only (iiUrl item)) :: IO [Only Int]
                  pure (case rows of [Only i] -> i; _ -> 0)
            links <- if bid == 0 then pure 0 else addLinks conn bid (iiTags item) tagIds
            pure
              ( nIns + if changed > 0 then 1 else 0
              , nExisting + if changed > 0 then 0 else 1
              , nLinks + links
              )
      (nIns, nExisting, nLinks) <- foldM step (0, 0, 0) (piItems parsed)
      pure (nIns, nExisting, tagsCreated, nLinks)
  execute_ conn "ANALYZE"
  execute_ conn "PRAGMA optimize"
  end <- getPOSIXTime
  pure
    ImportReport
      { irFound = piFound parsed
      , irHttpAnchors = piHttp parsed
      , irUniqueUrls = length (piItems parsed)
      , irInserted = inserted
      , irExisting = existing
      , irDuplicateAnchors = piDuplicates parsed
      , irSkippedNonHttp = piNonHttp parsed
      , irTagsCreated = tagsCreated
      , irTagLinksAdded = tagLinks
      , irFoldersSkipped = piFoldersSkipped parsed
      , irUntagged = piUntagged parsed
      , irElapsedMs = floor ((end - start) * 1000)
      }

insertTag :: Connection -> Int -> Text -> IO Int
insertTag conn now name = do
  execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)" (name, now)
  changes conn

addLinks :: Connection -> Int -> [Text] -> Map.Map Text Int -> IO Int
addLinks conn bid tags tagIds =
  sum <$> forM (mapMaybe (\t -> (bid,) <$> Map.lookup t tagIds) tags) (\(b, tid) -> do
    execute conn "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?, ?)" (b, tid)
    changes conn)

tagIdMap :: Connection -> IO (Map.Map Text Int)
tagIdMap conn = do
  rows <- query_ conn "SELECT id, name FROM tags" :: IO [(Int, Text)]
  pure (Map.fromList [(name, i) | (i, name) <- rows])
