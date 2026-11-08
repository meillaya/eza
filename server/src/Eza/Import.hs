{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

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

import Control.Monad (forM)
import Data.Aeson (encode)
import Data.Char (isAlphaNum, isDigit, isSpace)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe)
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
import Eza.Url (dedupeKey, hostOf, isHttpUrl, normalizeUrl)

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
  , iiDescription :: Text
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
  , psDd :: Maybe Text
  , psDdApplies :: Bool
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
    , psDd = Nothing
    , psDdApplies = False
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
        (finishDd st)
          { psInH3 = True
          , psH3Text = ""
          , psH3Info = Just (folderInfo attrs)
          , psDdApplies = False
          }
    | lname name == "dl" ->
        (finishDd st)
          { psStack = fromMaybe Nothing (psPending st) : psStack st
          , psPending = Nothing
          , psDdApplies = False
          }
    | lname name == "dd" -> st {psDd = Just ""}
    | lname name == "dt" -> finishDd st
    | lname name == "a", not (psInA st) ->
        (finishDd st)
          { psInA = True
          , psHref = fromMaybe "" (lookupAttr "href" attrs)
          , psTitle = ""
          , psAnchorTags = parseTagsAttr (fromMaybe "" (lookupAttr "tags" attrs))
          , psCreated = parseAddDate (fromMaybe "" (lookupAttr "add_date" attrs))
          , psDdApplies = False
          }
  TagClose name
    | lname name == "dd" -> finishDd st
    | lname name == "h3" ->
        let info0 = fromMaybe (FolderInfo "" False False) (psH3Info st)
            info = info0 {fiName = T.strip (psH3Text st)}
            (tag, skipped) = folderTag opts info (length (psStack st))
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
              , psDdApplies = False
              }
    | lname name == "dl" ->
        (finishDd st) {psStack = drop 1 (psStack st)}
    | lname name == "a", psInA st ->
        let rawHref = T.strip (psHref st)
            href = normalizeImportedUrl rawHref
            title = cleanTitle (psTitle st)
            http = isHttpUrl href
            stackTags = folderStackTags (ioTagMode opts) (psStack st)
            tags = dedupeText (stackTags <> psAnchorTags st)
            created = fromMaybe 0 (psCreated st)
            item = ImportItem href title "" (hostOf href) tags created
            st' =
              st
                { psInA = False
                , psHref = ""
                , psTitle = ""
                , psAnchorTags = []
                , psCreated = Nothing
                , psDdApplies = http
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
    | Just current <- psDd st, psDdApplies st -> st {psDd = Just (current <> txt)}
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

-- | Map a folder to its tag.  @depth@ is 1 for a folder directly under the
-- export root.  Wrapper folders such as @imported@ are only noise at the
-- root: deeper folders with the same name are real user folders.
folderTag :: ImportOptions -> FolderInfo -> Int -> (Maybe Text, Bool)
folderTag opts info depth
  | fiToolbar info = (Just "toolbar", False)
  | fiUnfiled info = (Just "unfiled", False)
  | otherwise =
      let n = normalizeName (fiName info)
       in if T.null n
            then (Nothing, False)
            else
              if ioSkinNoise opts && isNoiseFolderAtDepth depth n
                then (Nothing, True)
                else (Just n, False)

isNoiseFolderAtDepth :: Int -> Text -> Bool
isNoiseFolderAtDepth depth name = isNoiseFolder name || (depth <= 1 && Set.member name rootNoiseFolders)

-- | Finish a pending @<DD>@ description and attach it to the most recent
-- link.  Folder descriptions are ignored so a folder never inherits the
-- description of the bookmark before it.
finishDd :: PState -> PState
finishDd st = case psDd st of
  Nothing -> st
  Just raw ->
    let st' = st {psDd = Nothing}
        description = cleanTitle raw
     in if psDdApplies st && not (T.null description)
          then st' {psItems = applyDescription description (psItems st'), psDdApplies = False}
          else st' {psDdApplies = False}

applyDescription :: Text -> [ImportItem] -> [ImportItem]
applyDescription description items = case items of
  [] -> []
  (item : rest)
    | T.null (iiDescription item) -> item {iiDescription = description} : rest
    | otherwise -> items

-- | Normalize imported URLs so the dedupe key matches manual saves and a
-- second run (or a re-save) conflicts with existing rows.
normalizeImportedUrl :: Text -> Text
normalizeImportedUrl raw =
  let normalized = normalizeUrl raw
   in if isHttpUrl normalized && not (T.null normalized) then normalized else raw

folderStackTags :: TagMode -> [Maybe Text] -> [Text]
folderStackTags mode stack =
  let meaningful = reverse (catMaybes stack)
   in case mode of
        TagNone -> []
        TagLeaf -> maybe [] (: []) (lastMaybe meaningful)
        TagDeepest -> case meaningful of
          [] -> []
          parts -> [T.intercalate "/" parts]
        TagPath -> meaningful

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

-- | Wrapper folders that only count as noise at the top level of an export.
-- Deeper folders with these names are real user folders and stay as tags.
rootNoiseFolders :: Set Text
rootNoiseFolders =
  Set.fromList
    [ "imported"
    , "tabs"
    , "imported sessions"
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

-- | Collapse anchors that address the same page under the shared canonical
-- key (see 'Eza.Url.dedupeKey'). The earliest usable title and description
-- win, tag sets are unioned, the earliest date is kept, and an https address
-- replaces an http one so the stored record points at the better scheme.
dedupe :: [ImportItem] -> ([ImportItem], Int)
dedupe items =
  let m = foldl' insertItem Map.empty items
   in (Map.elems m, length items - Map.size m)
  where
    insertItem acc item =
      Map.alter (mergeItem item) (dedupeKey (iiUrl item)) acc

    mergeItem item Nothing = Just item
    mergeItem item (Just old) =
      Just
        old
          { iiUrl = preferredUrl old item
          , iiTitle = if T.null (iiTitle old) then iiTitle item else iiTitle old
          , iiDescription = if T.null (iiDescription old) then iiDescription item else iiDescription old
          , iiTags = dedupeText (iiTags old <> iiTags item)
          , iiCreatedAt = minNonZero (iiCreatedAt old) (iiCreatedAt item)
          }

-- | The imported address kept for a collapsed anchor: https replaces http,
-- otherwise the first address wins.
preferredUrl :: ImportItem -> ImportItem -> Text
preferredUrl old new
  | "http://" `T.isPrefixOf` iiUrl old && "https://" `T.isPrefixOf` iiUrl new = iiUrl new
  | otherwise = iiUrl old

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

{- | Import one parsed file.

De-duplication happens before a row is written. The parser has already
collapsed anchors that share a canonical key; here the key is also checked
against every existing bookmark, so a re-import, an overlapping export, or an
http/https copy of an already-filed page never creates a second row. Matched
records get the imported tags unioned on, empty metadata filled in, and a
stored URL upgraded when the imported address is clearly better (https for
http, or a normalised form for a legacy URL).

New rows are inserted in chunks with one prepared statement per chunk and the
tag links are flushed with a single @executeMany@, which keeps a 9k-anchor
import in the sub-second range. One @import_runs@ row records the run.
-}
importParsed :: Connection -> ImportOptions -> ParsedImport -> IO ImportReport
importParsed conn opts parsed = do
  start <- getPOSIXTime
  now <- floor <$> getPOSIXTime
  (inserted, existing, tagsCreated, tagLinks) <-
    withImmediateTransaction conn $ do
      existingRows <- query_ conn "SELECT id, url FROM bookmarks" :: IO [(Int, Text)]
      let byKey = foldl' addExisting Map.empty existingRows
          initial = ClassifyState byKey (Set.fromList (map snd existingRows)) [] [] []
          classified = foldl' classifyItem initial (piItems parsed)
      mapM_
        (\(bid, url) -> execute conn "UPDATE bookmarks SET url = ?, updated_at = ? WHERE id = ?" (url, now, bid))
        (csHeal classified)
      let allTagNames = Set.toList (Set.fromList (concatMap iiTags (piItems parsed)))
      tagsCreated <- sum <$> mapM (insertTag conn now) allTagNames
      tagIds <- tagIdMap conn
      [Only linksBefore] <- query_ conn "SELECT COUNT(*) FROM bookmark_tags" :: IO [Only Int]
      (nInserted, nRaced, insertedTargets) <- insertNewItems conn opts now (reverse (csNew classified))
      let matchedTargets = [(bid, iiTags item) | (bid, item) <- csMatched classified]
          targets = matchedTargets <> insertedTargets
          pairs =
            [ (bid, tagId)
            | (bid, names) <- targets
            , name <- names
            , Just tagId <- [Map.lookup name tagIds]
            ]
      executeMany conn "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?, ?)" pairs
      [Only linksAfter] <- query_ conn "SELECT COUNT(*) FROM bookmark_tags" :: IO [Only Int]
      pure (nInserted, length (csMatched classified) + nRaced, tagsCreated, linksAfter - linksBefore)
  execute_ conn "ANALYZE"
  execute_ conn "PRAGMA optimize"
  end <- getPOSIXTime
  let report =
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
  recordImportRun conn now (floor end) report
  pure report

-- | State carried while deciding, per item, whether it joins an existing
-- record or becomes a new one.
data ClassifyState = ClassifyState
  { csByKey :: Map.Map Text (Int, Text)
  , csUsedUrls :: Set Text
  , csHeal :: [(Int, Text)]
  , csMatched :: [(Int, ImportItem)]
  , csNew :: [ImportItem]
  }

-- | Fold one stored row into the canonical-key map. When legacy rows share a
-- key (old imports could keep fragments), prefer the cleanest https address
-- and then the lowest id as the keeper.
addExisting :: Map.Map Text (Int, Text) -> (Int, Text) -> Map.Map Text (Int, Text)
addExisting m (bid, url) = Map.insertWith better (dedupeKey url) (bid, url) m
  where
    better new@(newId, newUrl) old@(oldId, oldUrl)
      | urlRank newUrl > urlRank oldUrl = new
      | urlRank newUrl < urlRank oldUrl = old
      | newId < oldId = new
      | otherwise = old
    urlRank :: Text -> (Int, Int)
    urlRank candidate =
      ( if "https://" `T.isPrefixOf` candidate then 1 else 0
      , if candidate == normalizeUrl candidate then 1 else 0
      )

classifyItem :: ClassifyState -> ImportItem -> ClassifyState
classifyItem st item =
  case Map.lookup key (csByKey st) of
    Nothing -> st {csNew = item : csNew st}
    Just (bid, stored)
      | shouldHeal stored desired && not (Set.member desired (csUsedUrls st)) ->
          st
            { csByKey = Map.insert key (bid, desired) (csByKey st)
            , csUsedUrls = Set.insert desired (csUsedUrls st)
            , csHeal = (bid, desired) : csHeal st
            , csMatched = (bid, item) : csMatched st
            }
      | otherwise -> st {csMatched = (bid, item) : csMatched st}
  where
    key = dedupeKey (iiUrl item)
    desired = iiUrl item

-- | A matched record's stored URL is replaced only for a clear improvement:
-- https over http, or a normalised form replacing a legacy URL (a fragment or
-- tracking parameter the current importer would strip). Anything else is left
-- alone so a re-import cannot churn stable addresses.
shouldHeal :: Text -> Text -> Bool
shouldHeal stored desired =
  stored /= desired
    && isHttpUrl desired
    && ( ("https://" `T.isPrefixOf` desired && "http://" `T.isPrefixOf` stored)
           || normalizeUrl stored /= stored
       )

-- | Insert new items one prepared statement per chunk and return the row ids
-- (with their tags) for tag linking. A conflict that appeared after the
-- preload is counted as an existing record rather than an insert.
insertNewItems :: Connection -> ImportOptions -> Int -> [ImportItem] -> IO (Int, Int, [(Int, [Text])])
insertNewItems conn opts now items = go 0 0 [] (chunksOf 200 items)
  where
    go nInserted nRaced targets [] = pure (nInserted, nRaced, reverse targets)
    go nInserted nRaced targets (chunk : rest) = do
      executeMany conn insertSql (map (rowFor opts now) chunk)
      rows <-
        query
          conn
          (Query ("SELECT id, url FROM bookmarks WHERE url IN (" <> marksFor chunk <> ")"))
          (map iiUrl chunk) ::
          IO [(Int, Text)]
      let idsByUrl = Map.fromList [(url, bid) | (bid, url) <- rows]
          found = [(bid, iiTags item) | item <- chunk, Just bid <- [Map.lookup (iiUrl item) idsByUrl]]
      missing <-
        forM
          [ item
          | item <- chunk
          , Map.notMember (iiUrl item) idsByUrl
          ]
          $ \item -> do
            racedRows <- query conn "SELECT id FROM bookmarks WHERE url = ?" (Only (iiUrl item)) :: IO [Only Int]
            pure $ case racedRows of
              (Only bid : _) -> Just (bid, iiTags item)
              [] -> Nothing
      let raced = catMaybes missing
      go
        (nInserted + length found)
        (nRaced + (length chunk - length found))
        (reverse found <> raced <> targets)
        rest

insertSql :: Query
insertSql =
  "INSERT INTO bookmarks (url,title,description,domain,source,created_at,added_at,updated_at,is_read) VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(url) DO NOTHING"

rowFor :: ImportOptions -> Int -> ImportItem -> (Text, Text, Text, Text, Text, Int, Int, Int, Int)
rowFor opts now item =
  ( iiUrl item
  , iiTitle item
  , iiDescription item
  , iiDomain item
  , "netscape"
  , iiCreatedAt item
  , now
  , now
  , if ioMarkRead opts then 1 else 0
  )

marksFor :: [ImportItem] -> Text
marksFor chunk = T.intercalate "," (replicate (length chunk) "?")

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = take n xs : chunksOf n (drop n xs)

recordImportRun :: Connection -> Int -> Int -> ImportReport -> IO ()
recordImportRun conn started finished report = do
  let payload = TE.decodeUtf8 (LBS.toStrict (encode report))
  execute
    conn
    "INSERT INTO import_runs (source, started_at, finished_at, report_json) VALUES (?,?,?,?)"
    ("netscape" :: Text, started, finished, payload)

insertTag :: Connection -> Int -> Text -> IO Int
insertTag conn now name = do
  execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)" (name, now)
  changes conn

tagIdMap :: Connection -> IO (Map.Map Text Int)
tagIdMap conn = do
  rows <- query_ conn "SELECT id, name FROM tags" :: IO [(Int, Text)]
  pure (Map.fromList [(name, i) | (i, name) <- rows])
