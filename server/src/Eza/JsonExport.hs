{-# LANGUAGE OverloadedStrings #-}

module Eza.JsonExport (
    exportJson,
    importJson,
    JsonImportReport (..),
) where

import Control.Monad (forM, forM_)
import Data.Aeson
import Data.Aeson.Types (Parser, parseMaybe)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.SQLite.Simple
import GHC.Generics (Generic)

import Eza.Url (dedupeLookupUrls, hostOf, normalizeUrl)

data JsonImportReport = JsonImportReport
    { jrBookmarks :: Int
    , jrHighlights :: Int
    , jrSkipped :: Int
    }
    deriving (Show, Eq, Generic)

instance ToJSON JsonImportReport where
    toJSON report =
        object
            [ "bookmarks" .= jrBookmarks report
            , "highlights" .= jrHighlights report
            , "skipped" .= jrSkipped report
            ]

exportJson :: Connection -> IO Value
exportJson conn = do
    now <- (floor <$> getPOSIXTime) :: IO Int
    bookmarks <- query_ conn "SELECT id,url,title,description,domain,note_body,extracted_text,is_read,created_at,added_at FROM bookmarks ORDER BY id" :: IO [(Int, Text, Text, Text, Text, Text, Text, Int, Int, Int)]
    tagRows <- query_ conn "SELECT bookmark_id, t.name FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id ORDER BY t.name" :: IO [(Int, Text)]
    highlights <- query_ conn "SELECT id,bookmark_id,quote,start_offset,end_offset,note,color,created_at FROM highlights ORDER BY id" :: IO [(Int, Int, Text, Int, Int, Text, Text, Int)]
    searches <- query_ conn "SELECT id,name,q,tags_json,created_at FROM saved_searches ORDER BY id" :: IO [(Int, Text, Text, Text, Int)]
    rules <- query_ conn "SELECT id,name,enabled,field,pattern,add_tags,mark_read,created_at FROM rules ORDER BY id" :: IO [(Int, Text, Int, Text, Text, Text, Int, Int)]
    let tagsFor bid = [name | (bookmarkId, name) <- tagRows, bookmarkId == bid]
        bookmarkValue (bid, url, title, description, domain, note, extracted, isRead, created, added) =
            object
                [ "id" .= bid
                , "url" .= url
                , "title" .= title
                , "description" .= description
                , "domain" .= domain
                , "note_body" .= note
                , "extracted_text" .= extracted
                , "is_read" .= (isRead /= 0)
                , "created_at" .= created
                , "added_at" .= added
                , "tags" .= tagsFor bid
                ]
        highlightValue (hid, bid, quote, start, end, note, color, created) =
            object ["id" .= hid, "bookmark_id" .= bid, "quote" .= quote, "start_offset" .= start, "end_offset" .= end, "note" .= note, "color" .= color, "created_at" .= created]
        searchValue (sid, name, q, tags, created) = object ["id" .= sid, "name" .= name, "q" .= q, "tags" .= tags, "created_at" .= created]
        ruleValue (rid, name, enabled, ruleFieldName, rulePattern, tags, markRead, created) = object ["id" .= rid, "name" .= name, "enabled" .= (enabled /= 0), "field" .= ruleFieldName, "pattern" .= rulePattern, "add_tags" .= tags, "mark_read" .= (markRead /= 0), "created_at" .= created]
    pure
        ( object
            [ "format" .= ("eza-json" :: Text)
            , "version" .= (1 :: Int)
            , "exported_at" .= now
            , "bookmarks" .= map bookmarkValue bookmarks
            , "highlights" .= map highlightValue highlights
            , "saved_searches" .= map searchValue searches
            , "rules" .= map ruleValue rules
            ]
        )

data ImportedBookmark = ImportedBookmark
    { ibOldId :: Maybe Int
    , ibUrl :: Text
    , ibTitle :: Text
    , ibDescription :: Text
    , ibNote :: Text
    , ibExtracted :: Text
    , ibRead :: Bool
    , ibDead :: Bool
    , ibCreated :: Int
    , ibAdded :: Int
    , ibAuthor :: Text
    , ibSitename :: Text
    , ibPublished :: Maybe Int
    , ibLanguage :: Text
    , ibImage :: Text
    , ibFinal :: Text
    , ibOpenCount :: Int
    , ibLastOpened :: Maybe Int
    , ibReading :: Int
    , ibAiSummary :: Text
    , ibTags :: [Text]
    }
    deriving (Show, Eq)

importJson :: Connection -> Value -> IO (Either Text JsonImportReport)
importJson conn value =
    case parseMaybe
        ( withObject "eza-json" $ \o -> do
            format <- o .:? "format" .!= ("" :: Text)
            bookmarks <- o .:? "bookmarks" .!= []
            highlights <- o .:? "highlights" .!= []
            searches <- o .:? "saved_searches" .!= []
            rules <- o .:? "rules" .!= []
            pure (format, bookmarks :: [Value], highlights :: [Value], searches :: [Value], rules :: [Value])
        )
        value of
        Nothing -> pure (Left "invalid eza JSON document")
        Just (format, bookmarks, highlights, searches, rules)
            | format /= "eza-json" -> pure (Left "document is not an eza JSON export")
            | otherwise -> do
                now <- (floor <$> getPOSIXTime) :: IO Int
                imported <- forM bookmarks (importBookmark now)
                let idPairs = [(old, new) | Right (Just old, new) <- imported]
                    bookmarkMap = Map.fromList idPairs
                    bad = length [() | Left _ <- imported]
                importedHighlights <- forM highlights (importHighlight now bookmarkMap)
                importedSearches <- forM searches (importSavedSearch now)
                importedRules <- forM rules (importRule now)
                let highlightCount = length [() | Right _ <- importedHighlights]
                    skipped =
                        bad
                            + length [() | Left _ <- importedHighlights]
                            + length [() | Left _ <- importedSearches]
                            + length [() | Left _ <- importedRules]
                pure
                    ( Right
                        ( JsonImportReport
                            (length [() | Right _ <- imported])
                            highlightCount
                            skipped
                        )
                    )
  where
    importBookmark :: Int -> Value -> IO (Either Text (Maybe Int, Int))
    importBookmark now raw =
        case parseMaybe parseBookmark raw of
            Nothing -> pure (Left "invalid bookmark")
            Just bookmark -> do
                let url = normalizeUrl (ibUrl bookmark)
                    created = if ibCreated bookmark > 0 then ibCreated bookmark else ibAdded bookmark
                    added = if ibAdded bookmark > 0 then ibAdded bookmark else now
                let candidates = dedupeLookupUrls (ibUrl bookmark)
                    marks = T.intercalate "," (replicate (length candidates) "?")
                existing <- query conn (Query ("SELECT id FROM bookmarks WHERE url IN (" <> marks <> ") ORDER BY id LIMIT 1")) candidates :: IO [Only Int]
                case existing of
                    (Only bid : _) -> do
                        fillMissing conn bid bookmark
                        mergeTags conn bid (ibTags bookmark) now
                        pure (Right (ibOldId bookmark, bid))
                    [] -> do
                        bid <-
                            withImmediateTransaction conn $ do
                                executeNamed
                                    conn
                                    "INSERT INTO bookmarks (url,title,description,domain,note_body,extracted_text,is_read,is_dead,created_at,added_at,updated_at,source,author,sitename,published_at,language,image_url,final_url,open_count,last_opened_at,reading_time_minutes,ai_summary) VALUES (:url,:title,:description,:domain,:note,:extracted,:read,:dead,:created,:added,:updated,:source,:author,:sitename,:published,:language,:image,:final,:open_count,:last_opened,:reading,:ai_summary)"
                                    [ ":url" := url
                                    , ":title" := ibTitle bookmark
                                    , ":description" := ibDescription bookmark
                                    , ":domain" := hostOf url
                                    , ":note" := ibNote bookmark
                                    , ":extracted" := ibExtracted bookmark
                                    , ":read" := (if ibRead bookmark then 1 else 0 :: Int)
                                    , ":dead" := (if ibDead bookmark then 1 else 0 :: Int)
                                    , ":created" := created
                                    , ":added" := added
                                    , ":updated" := now
                                    , ":source" := ("json" :: Text)
                                    , ":author" := ibAuthor bookmark
                                    , ":sitename" := ibSitename bookmark
                                    , ":published" := ibPublished bookmark
                                    , ":language" := ibLanguage bookmark
                                    , ":image" := ibImage bookmark
                                    , ":final" := ibFinal bookmark
                                    , ":open_count" := ibOpenCount bookmark
                                    , ":last_opened" := ibLastOpened bookmark
                                    , ":reading" := max 0 (ibReading bookmark)
                                    , ":ai_summary" := ibAiSummary bookmark
                                    ]
                                newId <- (fromIntegral <$> lastInsertRowId conn) :: IO Int
                                forM_ (dedupeTags (ibTags bookmark)) $ \tag -> do
                                    execute conn "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)" (tag, now)
                                    idRows <- query conn "SELECT id FROM tags WHERE name = ?" (Only tag) :: IO [Only Int]
                                    case idRows of
                                        (Only tid : _) -> execute conn "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?, ?)" (newId, tid)
                                        _ -> pure ()
                                pure newId
                        pure (Right (ibOldId bookmark, bid))
    fillMissing connection bid bookmark =
        executeNamed
            connection
            "UPDATE bookmarks SET description = CASE WHEN trim(description) = '' THEN :description ELSE description END, extracted_text = CASE WHEN trim(extracted_text) = '' THEN :extracted ELSE extracted_text END, author = CASE WHEN trim(author) = '' THEN :author ELSE author END, sitename = CASE WHEN trim(sitename) = '' THEN :sitename ELSE sitename END, language = CASE WHEN trim(language) = '' THEN :language ELSE language END, image_url = CASE WHEN trim(image_url) = '' THEN :image ELSE image_url END, final_url = CASE WHEN trim(final_url) = '' THEN :final ELSE final_url END WHERE id = :id"
            [ ":description" := ibDescription bookmark
            , ":extracted" := ibExtracted bookmark
            , ":author" := ibAuthor bookmark
            , ":sitename" := ibSitename bookmark
            , ":language" := ibLanguage bookmark
            , ":image" := ibImage bookmark
            , ":final" := ibFinal bookmark
            , ":id" := bid
            ]
    mergeTags connection bid tags now = do
        withImmediateTransaction connection $ do
            forM_ (dedupeTags tags) $ \tag -> do
                execute connection "INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)" (tag, now)
                idRows <- query connection "SELECT id FROM tags WHERE name = ?" (Only tag) :: IO [Only Int]
                case idRows of
                    (Only tid : _) -> execute connection "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) VALUES (?, ?)" (bid, tid)
                    _ -> pure ()
    importHighlight :: Int -> Map.Map Int Int -> Value -> IO (Either Text ())
    importHighlight now bookmarkMap raw =
        case parseMaybe parseHighlight raw of
            Nothing -> pure (Left "invalid highlight")
            Just (oldBid, quote, start, end, note, color, created) ->
                case Map.lookup oldBid bookmarkMap of
                    Nothing -> pure (Left "highlight target missing")
                    Just bid -> do
                        duplicate <- query conn "SELECT 1 FROM highlights WHERE bookmark_id = ? AND start_offset = ? AND end_offset = ? AND quote = ?" (bid, start, end, quote) :: IO [Only Int]
                        if not (null duplicate)
                            then pure (Right ())
                            else do
                                withImmediateTransaction conn $
                                    executeNamed
                                        conn
                                        "INSERT INTO highlights (bookmark_id,quote,prefix,suffix,start_offset,end_offset,note,color,created_at,updated_at) VALUES (:bid,:quote,:prefix,:suffix,:start,:end,:note,:color,:created,:updated)"
                                        [ ":bid" := bid
                                        , ":quote" := quote
                                        , ":prefix" := ("" :: Text)
                                        , ":suffix" := ("" :: Text)
                                        , ":start" := start
                                        , ":end" := end
                                        , ":note" := note
                                        , ":color" := color
                                        , ":created" := (if created > 0 then created else now)
                                        , ":updated" := now
                                        ]
                                pure (Right ())
    importSavedSearch :: Int -> Value -> IO (Either Text ())
    importSavedSearch now raw =
        case parseMaybe parseSearch raw of
            Nothing -> pure (Left "invalid saved search")
            Just (name, q, tags, created) -> do
                let clean = T.strip name
                if T.null clean
                    then pure (Left "saved search name is required")
                    else do
                        duplicate <- query conn "SELECT 1 FROM saved_searches WHERE name = ? AND q = ?" (clean, q) :: IO [Only Int]
                        if not (null duplicate)
                            then pure (Right ())
                            else do
                                let tagsJson = TE.decodeUtf8 (LBS.toStrict (encode (dedupeTags tags)))
                                withImmediateTransaction conn $
                                    execute
                                        conn
                                        "INSERT INTO saved_searches (name,q,tags_json,created_at) VALUES (?,?,?,?)"
                                        (clean, q, tagsJson, (if created > 0 then created else now))
                                pure (Right ())
    importRule :: Int -> Value -> IO (Either Text ())
    importRule now raw =
        case parseMaybe parseRule raw of
            Nothing -> pure (Left "invalid rule")
            Just (name, enabled, ruleFieldName, rulePattern, tags, markRead) -> do
                let cleanName = T.strip name
                    cleanPattern = T.strip rulePattern
                    safeField = if T.toLower (T.strip ruleFieldName) `elem` ["url", "domain", "title"] then T.toLower (T.strip ruleFieldName) else "url"
                if T.null cleanName || T.null cleanPattern
                    then pure (Left "rule name and pattern are required")
                    else do
                        duplicate <- query conn "SELECT 1 FROM rules WHERE name = ? AND pattern = ?" (cleanName, cleanPattern) :: IO [Only Int]
                        if not (null duplicate)
                            then pure (Right ())
                            else do
                                let tagJson = TE.decodeUtf8 (LBS.toStrict (encode (dedupeTags tags)))
                                withImmediateTransaction conn $
                                    execute
                                        conn
                                        "INSERT INTO rules (name,enabled,field,pattern,add_tags,mark_read,created_at) VALUES (?,?,?,?,?,?,?)"
                                        (cleanName, (if enabled then 1 else 0) :: Int, safeField, cleanPattern, tagJson, (if markRead then 1 else 0) :: Int, now)
                                pure (Right ())
    parseBookmark = withObject "bookmark" $ \o -> do
        url <- o .: "url"
        title <- o .:? "title" .!= ""
        description <- o .:? "description" .!= ""
        note <- o .:? "note_body" .!= ""
        extracted <- o .:? "extracted_text" .!= ""
        isRead <- o .:? "is_read" .!= False
        dead <- o .:? "is_dead" .!= False
        created <- o .:? "created_at" .!= 0
        added <- o .:? "added_at" .!= 0
        author <- o .:? "author" .!= ""
        sitename <- o .:? "sitename" .!= ""
        published <- o .:? "published_at"
        language <- o .:? "language" .!= ""
        image <- o .:? "image_url" .!= ""
        final <- o .:? "final_url" .!= ""
        openCount <- o .:? "open_count" .!= 0
        lastOpened <- o .:? "last_opened_at"
        reading <- o .:? "reading_time_minutes" .!= 0
        aiSummary <- o .:? "ai_summary" .!= ""
        tags <- o .:? "tags" .!= []
        oldId <- o .:? "id"
        pure
            ImportedBookmark
                { ibOldId = oldId
                , ibUrl = url
                , ibTitle = title
                , ibDescription = description
                , ibNote = note
                , ibExtracted = extracted
                , ibRead = isRead
                , ibDead = dead
                , ibCreated = created
                , ibAdded = added
                , ibAuthor = author
                , ibSitename = sitename
                , ibPublished = published
                , ibLanguage = language
                , ibImage = image
                , ibFinal = final
                , ibOpenCount = openCount
                , ibLastOpened = lastOpened
                , ibReading = reading
                , ibAiSummary = aiSummary
                , ibTags = tags
                }
    parseHighlight = withObject "highlight" $ \o -> do
        bid <- o .: "bookmark_id" :: Parser Int
        quote <- o .: "quote" :: Parser Text
        start <- o .: "start_offset" :: Parser Int
        end <- o .: "end_offset" :: Parser Int
        note <- o .:? "note" .!= ("" :: Text)
        color <- o .:? "color" .!= ("yellow" :: Text)
        created <- o .:? "created_at" .!= (0 :: Int)
        pure (bid, quote, start, end, note, color, created)
    parseSearch = withObject "saved_search" $ \o -> do
        name <- o .: "name" :: Parser Text
        q <- o .:? "q" .!= ("" :: Text)
        tags <- o .:? "tags" .!= []
        created <- o .:? "created_at" .!= (0 :: Int)
        pure (name, q, tags :: [Text], created)
    parseRule = withObject "rule" $ \o -> do
        name <- o .: "name"
        enabled <- o .:? "enabled" .!= True
        ruleFieldName <- o .:? "field" .!= "url"
        rulePattern <- o .: "pattern"
        tags <- o .:? "add_tags" .!= []
        markRead <- o .:? "mark_read" .!= False
        pure (name, enabled, ruleFieldName, rulePattern, tags :: [Text], markRead)

dedupeTags :: [Text] -> [Text]
dedupeTags = go []
  where
    go seen [] = reverse seen
    go seen (tag : rest) =
        let clean = T.toLower (T.strip tag)
         in if T.null clean || clean `elem` seen then go seen rest else go (clean : seen) rest
