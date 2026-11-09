{-# LANGUAGE OverloadedStrings #-}

module Eza.JsonExport (
    exportJson,
    importJson,
    JsonImportReport (..),
) where

import Control.Monad (forM, forM_, void, when)
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

import Eza.ClipTemplates (ClipTemplate (..), createTemplate, listTemplates)
import Eza.Url (dedupeLookupUrls, hostOf, normalizeUrl)
import Eza.View (View (..), ViewDefinition, ViewInput (..), ViewKind (..), decodeViewDefinition, parseViewKind, viewKindText)
import Eza.Views (ViewPatch (..), createView, listViews, updateView)

data JsonImportReport = JsonImportReport
    { jrBookmarks :: Int
    , jrHighlights :: Int
    , jrCaptures :: Int
    , jrViews :: Int
    , jrTemplates :: Int
    , jrSkipped :: Int
    }
    deriving (Show, Eq, Generic)

instance ToJSON JsonImportReport where
    toJSON report =
        object
            [ "bookmarks" .= jrBookmarks report
            , "highlights" .= jrHighlights report
            , "captures" .= jrCaptures report
            , "views" .= jrViews report
            , "clip_templates" .= jrTemplates report
            , "skipped" .= jrSkipped report
            ]

data ExportBookmark = ExportBookmark
    { ebId :: Int
    , ebUrl :: Text
    , ebTitle :: Text
    , ebDescription :: Text
    , ebDomain :: Text
    , ebNote :: Text
    , ebExtracted :: Text
    , ebRead :: Int
    , ebDead :: Int
    , ebCreated :: Int
    , ebAdded :: Int
    , ebAuthor :: Text
    , ebSitename :: Text
    , ebPublished :: Maybe Int
    , ebLanguage :: Text
    , ebImage :: Text
    , ebFinal :: Text
    , ebOpenCount :: Int
    , ebLastOpened :: Maybe Int
    , ebReading :: Int
    , ebAiSummary :: Text
    }

instance FromRow ExportBookmark where
    fromRow =
        ExportBookmark
            <$> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field

data ExportHighlight = ExportHighlight
    { ehId :: Int
    , ehBookmarkId :: Int
    , ehQuote :: Text
    , ehPrefix :: Text
    , ehSuffix :: Text
    , ehStart :: Int
    , ehEnd :: Int
    , ehNote :: Text
    , ehColor :: Text
    , ehCreated :: Int
    , ehUpdated :: Int
    }

instance FromRow ExportHighlight where
    fromRow =
        ExportHighlight
            <$> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field

data ExportCapture = ExportCapture
    { ecId :: Int
    , ecBookmarkId :: Int
    , ecUrl :: Text
    , ecCanonicalUrl :: Text
    , ecTitle :: Text
    , ecAuthor :: Text
    , ecSite :: Text
    , ecDescription :: Text
    , ecPublished :: Text
    , ecLanguage :: Text
    , ecImage :: Text
    , ecFavicon :: Text
    , ecContentMarkdown :: Text
    , ecRenderedMarkdown :: Text
    , ecContentText :: Text
    , ecContentHtml :: Text
    , ecSelection :: Text
    , ecTags :: Text
    , ecTemplateName :: Text
    , ecSource :: Text
    , ecClient :: Text
    , ecExtractor :: Text
    , ecExtractorVersion :: Text
    , ecMetadata :: Text
    , ecWordCount :: Int
    , ecParseTimeMs :: Int
    , ecCapturedAt :: Int
    , ecCreatedAt :: Int
    }

instance FromRow ExportCapture where
    fromRow =
        ExportCapture
            <$> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field

exportJson :: Connection -> IO Value
exportJson conn = do
    now <- (floor <$> getPOSIXTime) :: IO Int
    bookmarks <-
        query_
            conn
            "SELECT id,url,title,description,domain,note_body,extracted_text,is_read,is_dead,created_at,added_at,author,sitename,published_at,language,image_url,final_url,open_count,last_opened_at,reading_time_minutes,ai_summary FROM bookmarks ORDER BY id" ::
            IO [ExportBookmark]
    tagRows <- query_ conn "SELECT bookmark_id, t.name FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id ORDER BY t.name" :: IO [(Int, Text)]
    highlights <-
        query_
            conn
            "SELECT id,bookmark_id,quote,prefix,suffix,start_offset,end_offset,note,color,created_at,updated_at FROM highlights ORDER BY id" ::
            IO [ExportHighlight]
    searches <- query_ conn "SELECT id,name,q,tags_json,created_at FROM saved_searches ORDER BY id" :: IO [(Int, Text, Text, Text, Int)]
    rules <- query_ conn "SELECT id,name,enabled,field,pattern,add_tags,mark_read,created_at FROM rules ORDER BY id" :: IO [(Int, Text, Int, Text, Text, Text, Int, Int)]
    captures <-
        query_
            conn
            "SELECT id,bookmark_id,url,canonical_url,title,author,site,description,published,language,image_url,favicon_url,content_markdown,rendered_markdown,content_text,content_html,selection,tags,template_name,source,client,extractor,extractor_version,metadata_json,word_count,parse_time_ms,captured_at,created_at FROM captures ORDER BY id" ::
            IO [ExportCapture]
    views <- listViews conn
    templates <- listTemplates conn
    let tagsFor bid = [name | (bookmarkId, name) <- tagRows, bookmarkId == bid]
        bookmarkValue b =
            object
                [ "id" .= ebId b
                , "url" .= ebUrl b
                , "title" .= ebTitle b
                , "description" .= ebDescription b
                , "domain" .= ebDomain b
                , "note_body" .= ebNote b
                , "extracted_text" .= ebExtracted b
                , "is_read" .= (ebRead b /= 0)
                , "is_dead" .= (ebDead b /= 0)
                , "created_at" .= ebCreated b
                , "added_at" .= ebAdded b
                , "author" .= ebAuthor b
                , "sitename" .= ebSitename b
                , "published_at" .= ebPublished b
                , "language" .= ebLanguage b
                , "image_url" .= ebImage b
                , "final_url" .= ebFinal b
                , "open_count" .= ebOpenCount b
                , "last_opened_at" .= ebLastOpened b
                , "reading_time_minutes" .= ebReading b
                , "ai_summary" .= ebAiSummary b
                , "tags" .= tagsFor (ebId b)
                ]
        highlightValue h =
            object
                [ "id" .= ehId h
                , "bookmark_id" .= ehBookmarkId h
                , "quote" .= ehQuote h
                , "prefix" .= ehPrefix h
                , "suffix" .= ehSuffix h
                , "start_offset" .= ehStart h
                , "end_offset" .= ehEnd h
                , "note" .= ehNote h
                , "color" .= ehColor h
                , "created_at" .= ehCreated h
                , "updated_at" .= ehUpdated h
                ]
        captureValue c =
            object
                [ "bookmark_id" .= ecBookmarkId c
                , "url" .= ecUrl c
                , "canonical_url" .= ecCanonicalUrl c
                , "title" .= ecTitle c
                , "author" .= ecAuthor c
                , "site" .= ecSite c
                , "description" .= ecDescription c
                , "published" .= ecPublished c
                , "language" .= ecLanguage c
                , "image_url" .= ecImage c
                , "favicon_url" .= ecFavicon c
                , "content_markdown" .= ecContentMarkdown c
                , "rendered_markdown" .= ecRenderedMarkdown c
                , "content_text" .= ecContentText c
                , "content_html" .= ecContentHtml c
                , "selection" .= ecSelection c
                , "tags" .= ecTags c
                , "template_name" .= ecTemplateName c
                , "source" .= ecSource c
                , "client" .= ecClient c
                , "extractor" .= ecExtractor c
                , "extractor_version" .= ecExtractorVersion c
                , "metadata" .= ecMetadata c
                , "id" .= ecId c
                , "word_count" .= ecWordCount c
                , "parse_time_ms" .= ecParseTimeMs c
                , "captured_at" .= ecCapturedAt c
                , "created_at" .= ecCreatedAt c
                ]
        searchValue (sid, name, q, tags, created) = object ["id" .= sid, "name" .= name, "q" .= q, "tags" .= tags, "created_at" .= created]
        ruleValue (rid, name, enabled, ruleFieldName, rulePattern, tags, markRead, created) = object ["id" .= rid, "name" .= name, "enabled" .= (enabled /= 0), "field" .= ruleFieldName, "pattern" .= rulePattern, "add_tags" .= tags, "mark_read" .= (markRead /= 0), "created_at" .= created]
    pure
        ( object
            [ "format" .= ("eza-json" :: Text)
            , "version" .= (2 :: Int)
            , "exported_at" .= now
            , "bookmarks" .= map bookmarkValue bookmarks
            , "highlights" .= map highlightValue highlights
            , "saved_searches" .= map searchValue searches
            , "rules" .= map ruleValue rules
            , "captures" .= map captureValue captures
            , "views" .= views
            , "clip_templates" .= templates
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

data ImportedCapture = ImportedCapture
    { icOldBid :: Int
    , icUrl :: Text
    , icCanonicalUrl :: Text
    , icTitle :: Text
    , icAuthor :: Text
    , icSite :: Text
    , icDescription :: Text
    , icPublished :: Text
    , icLanguage :: Text
    , icImage :: Text
    , icFavicon :: Text
    , icContentMarkdown :: Text
    , icRenderedMarkdown :: Text
    , icContentText :: Text
    , icContentHtml :: Text
    , icSelection :: Text
    , icTags :: Text
    , icTemplateName :: Text
    , icSource :: Text
    , icClient :: Text
    , icExtractor :: Text
    , icExtractorVersion :: Text
    , icMetadata :: Text
    , icWordCount :: Int
    , icParseTimeMs :: Int
    , icCapturedAt :: Int
    , icCreatedAt :: Int
    }
    deriving (Show, Eq)

data ImportedView = ImportedView
    { ivName :: Text
    , ivKind :: ViewKind
    , ivSlug :: Text
    , ivDefinition :: ViewDefinition
    , ivDefault :: Bool
    }
    deriving (Show, Eq)

importJson :: Connection -> Value -> IO (Either Text JsonImportReport)
importJson conn value =
    case parseMaybe
        ( withObject "eza-json" $ \o -> do
            format <- o .:? "format" .!= ("" :: Text)
            version <- o .:? "version" .!= (1 :: Int)
            bookmarks <- o .:? "bookmarks" .!= []
            highlights <- o .:? "highlights" .!= []
            searches <- o .:? "saved_searches" .!= []
            rules <- o .:? "rules" .!= []
            captures <- o .:? "captures" .!= []
            views <- o .:? "views" .!= []
            templates <- o .:? "clip_templates" .!= []
            pure
                ( format
                , version
                , bookmarks :: [Value]
                , highlights :: [Value]
                , searches :: [Value]
                , rules :: [Value]
                , captures :: [Value]
                , views :: [Value]
                , templates :: [Value]
                )
        )
        value of
        Nothing -> pure (Left "invalid eza JSON document")
        Just (format, version, bookmarks, highlights, searches, rules, captures, views, templates)
            | format /= "eza-json" -> pure (Left "document is not an eza JSON export")
            | version < 1 || version > 2 -> pure (Left ("unsupported eza JSON export version: " <> T.pack (show version)))
            | otherwise -> do
                now <- (floor <$> getPOSIXTime) :: IO Int
                imported <- forM bookmarks (importBookmark now)
                let idPairs = [(old, new) | Right (Just old, new) <- imported]
                    bookmarkMap = Map.fromList idPairs
                    bad = length [() | Left _ <- imported]
                importedHighlights <- forM highlights (importHighlight now bookmarkMap)
                importedSearches <- forM searches (importSavedSearch now)
                importedRules <- forM rules (importRule now)
                importedCaptures <- forM captures (importCapture now bookmarkMap)
                importedViews <- importViews views
                importedTemplates <- forM templates importTemplate
                let countRight results = length [() | Right _ <- results]
                    skipped =
                        bad
                            + length [() | Left _ <- importedHighlights]
                            + length [() | Left _ <- importedSearches]
                            + length [() | Left _ <- importedRules]
                            + length [() | Left _ <- importedCaptures]
                            + length [() | Left _ <- importedViews]
                            + length [() | Left _ <- importedTemplates]
                pure
                    ( Right
                        ( JsonImportReport
                            (countRight imported)
                            (countRight importedHighlights)
                            (countRight importedCaptures)
                            (countRight importedViews)
                            (countRight importedTemplates)
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
            Just (oldBid, quote, prefix, suffix, start, end, note, color, created) ->
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
                                        , ":prefix" := prefix
                                        , ":suffix" := suffix
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
    importCapture :: Int -> Map.Map Int Int -> Value -> IO (Either Text ())
    importCapture now bookmarkMap raw =
        case parseMaybe parseCapture raw of
            Nothing -> pure (Left "invalid capture")
            Just capture ->
                case Map.lookup (icOldBid capture) bookmarkMap of
                    Nothing -> pure (Left "capture target missing")
                    Just bid -> do
                        duplicate <-
                            query
                                conn
                                "SELECT 1 FROM captures WHERE bookmark_id = ? AND captured_at = ? AND url = ?"
                                (bid, icCapturedAt capture, icUrl capture) ::
                                IO [Only Int]
                        if not (null duplicate)
                            then pure (Right ())
                            else do
                                withImmediateTransaction conn $
                                    executeNamed
                                        conn
                                        "INSERT INTO captures (bookmark_id,url,canonical_url,title,author,site,description,published,language,image_url,favicon_url,content_markdown,rendered_markdown,content_text,content_html,selection,tags,template_name,source,client,idempotency_key,request_hash,extractor,extractor_version,metadata_json,word_count,parse_time_ms,captured_at,created_at) VALUES (:bid,:url,:canonical,:title,:author,:site,:description,:published,:language,:image,:favicon,:markdown,:rendered,:text,:html,:selection,:tags,:template_name,:source,:client,'','',:extractor,:extractor_version,:metadata,:word_count,:parse_time_ms,:captured_at,:created_at)"
                                        [ ":bid" := bid
                                        , ":url" := icUrl capture
                                        , ":canonical" := icCanonicalUrl capture
                                        , ":title" := icTitle capture
                                        , ":author" := icAuthor capture
                                        , ":site" := icSite capture
                                        , ":description" := icDescription capture
                                        , ":published" := icPublished capture
                                        , ":language" := icLanguage capture
                                        , ":image" := icImage capture
                                        , ":favicon" := icFavicon capture
                                        , ":markdown" := icContentMarkdown capture
                                        , ":rendered" := icRenderedMarkdown capture
                                        , ":text" := icContentText capture
                                        , ":html" := icContentHtml capture
                                        , ":selection" := icSelection capture
                                        , ":tags" := jsonTextOr "[]" (icTags capture)
                                        , ":template_name" := icTemplateName capture
                                        , ":source" := icSource capture
                                        , ":client" := icClient capture
                                        , ":extractor" := icExtractor capture
                                        , ":extractor_version" := icExtractorVersion capture
                                        , ":metadata" := jsonTextOr "{}" (icMetadata capture)
                                        , ":word_count" := icWordCount capture
                                        , ":parse_time_ms" := icParseTimeMs capture
                                        , ":captured_at" := (if icCapturedAt capture > 0 then icCapturedAt capture else now)
                                        , ":created_at" := (if icCreatedAt capture > 0 then icCreatedAt capture else now)
                                        ]
                                pure (Right ())

    importViews :: [Value] -> IO [Either Text ()]
    importViews values = forM values $ \raw ->
        case parseMaybe parseView raw of
            Nothing -> pure (Left "invalid view")
            Just view -> do
                slugTaken <- query conn "SELECT 1 FROM views WHERE slug = ?" (Only (ivSlug view)) :: IO [Only Int]
                nameTaken <-
                    query
                        conn
                        "SELECT 1 FROM views WHERE name = ? AND kind = ?"
                        (ivName view, viewKindText (ivKind view)) ::
                        IO [Only Int]
                if not (null slugTaken) || not (null nameTaken)
                    then pure (Right ())
                    else do
                        result <- createView conn (ViewInput (ivName view) (ivKind view) (ivDefinition view) (Just (ivSlug view)))
                        case result of
                            Left _ -> pure (Left "view rejected")
                            Right created -> do
                                when (ivDefault view) $
                                    void (updateView conn (vSlug created) (ViewPatch Nothing Nothing Nothing (Just True)))
                                pure (Right ())

    importTemplate :: Value -> IO (Either Text ())
    importTemplate raw =
        case fromJSON raw of
            Error _ -> pure (Left "invalid clip template")
            Success (template :: ClipTemplate) -> do
                let name = T.strip (ctName template)
                if T.null name
                    then pure (Left "clip template name is required")
                    else do
                        duplicate <- query conn "SELECT 1 FROM clip_templates WHERE name = ?" (Only name) :: IO [Only Int]
                        if not (null duplicate)
                            then pure (Right ())
                            else do
                                result <- createTemplate conn template{ctId = 0, ctBuiltin = False}
                                pure (either (const (Left "clip template rejected")) (const (Right ())) result)

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
        prefix <- o .:? "prefix" .!= ("" :: Text)
        suffix <- o .:? "suffix" .!= ("" :: Text)
        start <- o .: "start_offset" :: Parser Int
        end <- o .: "end_offset" :: Parser Int
        note <- o .:? "note" .!= ("" :: Text)
        color <- o .:? "color" .!= ("yellow" :: Text)
        created <- o .:? "created_at" .!= (0 :: Int)
        pure (bid, quote, prefix, suffix, start, end, note, color, created)
    parseCapture = withObject "capture" $ \o ->
        ImportedCapture
            <$> o .: "bookmark_id"
            <*> o .:? "url" .!= ""
            <*> o .:? "canonical_url" .!= ""
            <*> o .:? "title" .!= ""
            <*> o .:? "author" .!= ""
            <*> o .:? "site" .!= ""
            <*> o .:? "description" .!= ""
            <*> o .:? "published" .!= ""
            <*> o .:? "language" .!= ""
            <*> o .:? "image_url" .!= ""
            <*> o .:? "favicon_url" .!= ""
            <*> o .:? "content_markdown" .!= ""
            <*> o .:? "rendered_markdown" .!= ""
            <*> o .:? "content_text" .!= ""
            <*> o .:? "content_html" .!= ""
            <*> o .:? "selection" .!= ""
            <*> o .:? "tags" .!= "[]"
            <*> o .:? "template_name" .!= ""
            <*> o .:? "source" .!= ""
            <*> o .:? "client" .!= ""
            <*> o .:? "extractor" .!= ""
            <*> o .:? "extractor_version" .!= ""
            <*> o .:? "metadata" .!= "{}"
            <*> o .:? "word_count" .!= (0 :: Int)
            <*> o .:? "parse_time_ms" .!= (0 :: Int)
            <*> o .:? "captured_at" .!= (0 :: Int)
            <*> o .:? "created_at" .!= (0 :: Int)
    parseView = withObject "view" $ \o -> do
        slug <- o .:? "slug" .!= ""
        name <- o .: "name" :: Parser Text
        kindText <- o .: "kind" :: Parser Text
        definition <- o .: "definition" :: Parser Value
        isDefault <- o .:? "is_default" .!= False
        kind <- case parseViewKind kindText of
            Nothing -> fail "unknown view kind"
            Just parsedKind -> pure parsedKind
        decoded <- case decodeViewDefinition kind definition of
            Left message -> fail (T.unpack message)
            Right parsedDefinition -> pure parsedDefinition
        pure (ImportedView name kind slug decoded isDefault)
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

{- | Keep a free-form JSON column valid: an imported text blob is re-encoded
from its parsed value, and malformed input falls back to the column default so
the capture/template still imports instead of poisoning the row.
-}
jsonTextOr :: Text -> Text -> Text
jsonTextOr fallback raw =
    case decode (LBS.fromStrict (TE.encodeUtf8 raw)) :: Maybe Value of
        Just value -> TE.decodeUtf8 (LBS.toStrict (encode value))
        Nothing -> fallback
