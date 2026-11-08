{-# LANGUAGE OverloadedStrings #-}

-- | Signed read-only share links and Atom feeds.
module Eza.Shares (
    ShareView (..),
    ShareRecord (..),
    ShareUnavailable (..),
    ShareState (..),
    createShare,
    listShares,
    revokeShare,
    resolveShare,
    resolveShareState,
    shareBookmarkPage,
    shareSearchPage,
    shareUnavailablePage,
    shareSearchFeed,
) where

import Crypto.Hash (Digest, SHA256, hash)
import qualified Crypto.Random as Random
import Data.Aeson
import qualified Data.ByteString.Base64.URL as B64
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock.POSIX (getPOSIXTime, posixSecondsToUTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Database.SQLite.Simple
import GHC.Generics (Generic)

import Eza.Types (BookmarkDetail (..), BookmarkSummary (..), SavedSearch (..), SearchPage (..))

data ShareView = ShareView
    { svId :: Int
    , svPrefix :: Text
    , svScope :: Text
    , svTargetId :: Int
    , svIncludeNote :: Bool
    , svCreatedAt :: Int
    , svExpiresAt :: Int
    , svRevokedAt :: Maybe Int
    , svLastAccessedAt :: Maybe Int
    }
    deriving (Show, Eq, Generic)

instance ToJSON ShareView where
    toJSON sv =
        object
            [ "id" .= svId sv
            , "prefix" .= svPrefix sv
            , "scope" .= svScope sv
            , "target_id" .= svTargetId sv
            , "include_note" .= svIncludeNote sv
            , "created_at" .= svCreatedAt sv
            , "expires_at" .= svExpiresAt sv
            , "revoked_at" .= svRevokedAt sv
            , "last_accessed_at" .= svLastAccessedAt sv
            ]

data ShareRecord = ShareRecord
    { srId :: Int
    , srScope :: Text
    , srTargetId :: Int
    , srIncludeNote :: Bool
    , srCreatedAt :: Int
    , srExpiresAt :: Int
    }
    deriving (Show, Eq)

{- | Why a share link cannot be read. The server picks 404 for an unknown
token and 410 for a link that existed and was revoked or has expired.
-}
data ShareUnavailable
    = ShareInvalid
    | ShareRevoked
    | ShareExpired Int
    deriving (Show, Eq)

data ShareState
    = ShareReadable ShareRecord
    | ShareGone ShareUnavailable
    deriving (Show, Eq)

epoch :: IO Int
epoch = floor <$> getPOSIXTime

hashToken :: Text -> Text
hashToken raw = T.pack (show (hash (TE.encodeUtf8 raw) :: Digest SHA256))

createShare :: Connection -> Text -> Int -> Bool -> Int -> IO (Either Text (Int, Text))
createShare conn scope targetId includeNote days
    | scope `notElem` ["bookmark", "saved_search"] = pure (Left "unknown share scope")
    | days < 1 || days > 365 = pure (Left "expiry must be between 1 and 365 days")
    | otherwise = do
        target <- case scope of
            "bookmark" -> query conn "SELECT 1 FROM bookmarks WHERE id = ?" (Only targetId) :: IO [Only Int]
            _ -> query conn "SELECT 1 FROM saved_searches WHERE id = ?" (Only targetId) :: IO [Only Int]
        if null target
            then pure (Left "share target not found")
            else do
                rawBytes <- Random.getRandomBytes 32
                let raw = TE.decodeUtf8 (B64.encodeUnpadded rawBytes)
                now <- epoch
                withImmediateTransaction conn $
                    execute
                        conn
                        "INSERT INTO share_links (token_hash, token_prefix, scope, target_id, include_note, created_at, expires_at) VALUES (?,?,?,?,?,?,?)"
                        (hashToken raw, T.take 12 raw, scope, targetId, if includeNote then 1 else 0 :: Int, now, now + days * 86400)
                sid <- fromIntegral <$> lastInsertRowId conn
                pure (Right (sid, raw))

listShares :: Connection -> IO [ShareView]
listShares conn = do
    rows <-
        query_
            conn
            "SELECT id, token_prefix, scope, target_id, include_note, created_at, expires_at, revoked_at, last_accessed_at FROM share_links ORDER BY id DESC" ::
            IO [(Int, Text, Text, Int, Int, Int, Int, Maybe Int, Maybe Int)]
    pure
        [ ShareView sid prefix scope target (include /= 0) created expires revoked lastUsed
        | (sid, prefix, scope, target, include, created, expires, revoked, lastUsed) <- rows
        ]

revokeShare :: Connection -> Int -> IO Bool
revokeShare conn shareId = do
    now <- epoch
    withImmediateTransaction conn $ do
        execute conn "UPDATE share_links SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL" (now, shareId)
        changed <- changes conn
        pure (changed > 0)

resolveShare :: Connection -> Text -> IO (Maybe ShareRecord)
resolveShare conn raw = do
    now <- epoch
    rows <-
        query
            conn
            "SELECT id, scope, target_id, include_note, created_at, expires_at FROM share_links WHERE token_hash = ? AND revoked_at IS NULL AND expires_at > ?"
            (hashToken raw, now) ::
            IO [(Int, Text, Int, Int, Int, Int)]
    case rows of
        [] -> pure Nothing
        [(sid, scope, target, include, created, expires)] -> do
            withImmediateTransaction conn $
                execute conn "UPDATE share_links SET last_accessed_at = ? WHERE id = ?" (now, sid)
            pure (Just (ShareRecord sid scope target (include /= 0) created expires))
        _ -> pure Nothing

{- | Resolve a token for a page request and say why it is gone when it is.
The lookup runs before the read filter so a revoked link can be reported
as revoked instead of pretending the token never existed.
-}
resolveShareState :: Connection -> Text -> IO ShareState
resolveShareState conn raw = do
    now <- epoch
    rows <-
        query
            conn
            "SELECT id, scope, target_id, include_note, created_at, expires_at, revoked_at FROM share_links WHERE token_hash = ?"
            (Only (hashToken raw)) ::
            IO [(Int, Text, Int, Int, Int, Int, Maybe Int)]
    case rows of
        [] -> pure (ShareGone ShareInvalid)
        ((sid, scope, target, include, created, expires, revoked) : _)
            | Just _ <- revoked -> pure (ShareGone ShareRevoked)
            | expires <= now -> pure (ShareGone (ShareExpired expires))
            | otherwise -> do
                withImmediateTransaction conn $
                    execute conn "UPDATE share_links SET last_accessed_at = ? WHERE id = ?" (now, sid)
                pure (ShareReadable (ShareRecord sid scope target (include /= 0) created expires))

-- ---------------------------------------------------------------------------
-- Public pages
-- ---------------------------------------------------------------------------

shareBookmarkPage :: ShareRecord -> BookmarkDetail -> Text
shareBookmarkPage record bookmark =
    shareDocument
        (bdTitle bookmark)
        ( T.unlines
            [ shareStageOpen
            , "  <article class=\"share-page\" data-testid=\"share-page\">"
            , shareTop
            , "    <div class=\"rule\" aria-hidden=\"true\"></div>"
            , "    <p class=\"share-kicker sc\">shared record</p>"
            , "    <p class=\"share-acc mono\">" <> accessionNo (bdId bookmark) <> "</p>"
            , "    <h1 class=\"share-title\">" <> escape (bdTitle bookmark) <> "</h1>"
            , "    <p class=\"share-src\">" <> escape (bdDomain bookmark) <> sep <> "filed " <> dateDot (bdCreatedAt bookmark) <> "</p>"
            , if srIncludeNote record then shareNote (bdNoteBody bookmark) else ""
            , shareTags (bdTags bookmark)
            , "    <a class=\"share-open\" href=\"" <> escape (bdUrl bookmark) <> "\" rel=\"noopener noreferrer\">read the page</a>"
            , shareMeta record
            , "    <p class=\"share-colophon\">" <> colophon <> "</p>"
            , "  </article>"
            , quoteStageNote
            , shareStageClose
            ]
        )

shareSearchPage :: ShareRecord -> SavedSearch -> SearchPage -> Text
shareSearchPage record saved page =
    shareDocument
        (ssName saved)
        ( T.unlines
            [ shareStageOpen
            , "  <article class=\"share-page\" data-testid=\"share-page\">"
            , shareTop
            , "    <div class=\"rule\" aria-hidden=\"true\"></div>"
            , "    <p class=\"share-kicker sc\">shared search</p>"
            , "    <h1 class=\"share-title\">" <> escape (ssName saved) <> "</h1>"
            , "    <p class=\"share-src\"><span class=\"mono\">" <> escape (searchText saved) <> "</span>" <> sep <> "<span>" <> countText (spTotal page) <> " entries</span></p>"
            , "    <ol class=\"share-results\">"
            , T.concat (map shareResult (spItems page))
            , "    </ol>"
            , "    <p class=\"share-more meta\">" <> resultSummary page <> "</p>"
            , "    <p class=\"share-open share-open--quiet\">This saved search is shared from eza. The keeper chooses the query; the entries stay theirs.</p>"
            , shareMeta record
            , "    <p class=\"share-colophon\">" <> colophon <> "</p>"
            , "  </article>"
            , quoteStageNote
            , shareStageClose
            ]
        )

shareUnavailablePage :: ShareUnavailable -> Text
shareUnavailablePage unavailable =
    shareDocument
        heading
        ( T.unlines
            [ shareStageOpen
            , "  <article class=\"share-page\" data-testid=\"share-unavailable\">"
            , shareTop
            , "    <div class=\"rule\" aria-hidden=\"true\"></div>"
            , "    <p class=\"share-kicker sc\">share link</p>"
            , "    <h1 class=\"share-title\">" <> heading <> "</h1>"
            , "    <p class=\"share-note\"><span>" <> note <> "</span></p>"
            , "    <p class=\"share-more meta\">" <> more <> "</p>"
            , "    <p class=\"share-colophon\">" <> colophon <> "</p>"
            , "  </article>"
            , quoteStageNote
            , shareStageClose
            ]
        )
  where
    (heading, note, more) = case unavailable of
        ShareRevoked ->
            ( "This link was revoked."
            , "Its keeper has revoked it. Ask them for a new link if the record should still be readable."
            , "Nothing on this page is public once a link is revoked."
            )
        ShareExpired expires ->
            ( "This link has expired."
            , "Share links carry an expiry date. This one ended on <span class=\"mono\">" <> dateDot expires <> "</span>."
            , "The keeper can make a new link from the account page."
            )
        ShareInvalid ->
            ( "This link does not exist."
            , "No share link matches this address. It may have been mistyped, or it may never have been made."
            , "Share links are made from the account page."
            )

shareSearchFeed :: SavedSearch -> SearchPage -> Text
shareSearchFeed saved page =
    T.unlines
        [ "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        , "<feed xmlns=\"http://www.w3.org/2005/Atom\">"
        , "<title>" <> xmlEscape (ssName saved) <> "</title>"
        , "<id>urn:eza:saved-search:" <> T.pack (show (ssId saved)) <> "</id>"
        , "<updated>" <> atomTime (ssCreatedAt saved) <> "</updated>"
        , "<link href=\"/\" rel=\"alternate\"/>"
        , T.concat
            [ "<entry><title>"
                <> xmlEscape (bsTitle bookmark)
                <> "</title><id>urn:eza:bookmark:"
                <> T.pack (show (bsId bookmark))
                <> "</id><link href=\""
                <> xmlEscape (bsUrl bookmark)
                <> "\"/><updated>"
                <> atomTime (bsCreatedAt bookmark)
                <> "</updated></entry>"
            | bookmark <- spItems page
            ]
        , "</feed>"
        ]

-- ---------------------------------------------------------------------------
-- Fragments shared by the public pages
-- ---------------------------------------------------------------------------

shareDocument :: Text -> Text -> Text
shareDocument title body =
    T.unlines
        [ "<!doctype html>"
        , "<html lang=\"en\" data-theme=\"light\">"
        , "<head><meta charset=\"utf-8\">"
        , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        , "<meta name=\"robots\" content=\"noindex,nofollow\">"
        , "<meta name=\"color-scheme\" content=\"light dark\">"
        , "<meta name=\"theme-color\" content=\"#F2EDE3\">"
        , "<meta name=\"theme-color\" media=\"(prefers-color-scheme: dark)\" content=\"#10141F\">"
        , "<title>" <> escape title <> " | eza</title>"
        , "<link rel=\"stylesheet\" href=\"/assets/eza.css\">"
        , "<link rel=\"icon\" href=\"/favicon.svg\">"
        , "<script src=\"/assets/theme.js\"></script>"
        , "</head><body class=\"share-body\"><main class=\"share\">"
        , body
        , "</main></body></html>"
        ]

shareStageOpen :: Text
shareStageOpen = "<div class=\"share-stage\">"

shareStageClose :: Text
shareStageClose = "</div>"

shareTop :: Text
shareTop =
    T.unlines
        [ "    <div class=\"share-top\">"
        , "      <a class=\"share-word\" href=\"/login\">eza</a>"
        , "      <span class=\"share-readonly meta\">read only</span>"
        , "    </div>"
        ]

shareMeta :: ShareRecord -> Text
shareMeta record =
    T.unlines
        [ "    <dl class=\"share-meta\">"
        , "      <div><dt>shared</dt><dd>" <> dateDot (srCreatedAt record) <> "</dd></div>"
        , "      <div><dt>expires</dt><dd>" <> dateDot (srExpiresAt record) <> "</dd></div>"
        , "    </dl>"
        ]

shareNote :: Text -> Text
shareNote body
    | T.null (T.strip body) = ""
    | otherwise =
        "    <div class=\"share-note\"><p class=\"share-note-label sc\">note</p>"
            <> T.concat ["<p>" <> escape paragraph <> "</p>" | paragraph <- paragraphs]
            <> "</div>"
  where
    paragraphs = filter (not . T.null) (map (T.unwords . T.words) (T.splitOn "\n\n" (T.replace "\r\n" "\n" body)))

shareTags :: [Text] -> Text
shareTags [] = ""
shareTags tags =
    "    <ul class=\"share-tags\">"
        <> T.concat ["<li><span class=\"tagpill\">" <> escape tag <> "</span></li>" | tag <- tags]
        <> "</ul>"

shareResult :: BookmarkSummary -> Text
shareResult bookmark =
    T.unlines
        [ "      <li class=\"share-result\">"
        , "        <span class=\"share-result-acc mono\">" <> accessionNo (bsId bookmark) <> "</span>"
        , "        <span class=\"share-result-body\">"
        , "          <span class=\"share-result-title\">" <> escape (bsTitle bookmark) <> "</span>"
        , "          <span class=\"share-result-meta meta\">" <> escape (bsDomain bookmark) <> sep <> "filed " <> dateDot (bsCreatedAt bookmark) <> "</span>"
        , "        </span>"
        , "      </li>"
        ]

resultSummary :: SearchPage -> Text
resultSummary page
    | shown >= total = "All " <> countText total <> " entries from the keeper's catalogue."
    | otherwise = "Showing " <> countText shown <> " of " <> countText total <> " entries from the keeper's catalogue."
  where
    shown = length (spItems page)
    total = spTotal page

searchText :: SavedSearch -> Text
searchText saved = T.strip (T.unwords ([ssQ saved] <> ["tag:" <> tag | tag <- ssTags saved]))

quoteStageNote :: Text
quoteStageNote = "  <p class=\"share-stage-note meta\">a share page is served without the app; the keeper's data is never listed or synced here.</p>"

colophon :: Text
colophon =
    "shared from eza "
        <> sep
        <> " a private bookmark library "
        <> sep
        <> " this page is read-only"

sep :: Text
sep = "<span class=\"account-sep\" aria-hidden=\"true\"></span>"

accessionNo :: Int -> Text
accessionNo bid = "EA-" <> T.justifyRight 5 '0' (T.pack (show bid))

dateDot :: Int -> Text
dateDot seconds = T.pack (formatTime defaultTimeLocale "%Y.%m.%d" (posixSecondsToUTCTime (fromIntegral seconds)))

countText :: Int -> Text
countText = T.pack . reverse . go . reverse . show
  where
    go (a : b : c : rest) = a : b : c : (if null rest then [] else ',' : go rest)
    go short = short

escape :: Text -> Text
escape value =
    T.replace ">" "&gt;" (T.replace "<" "&lt;" (T.replace "&" "&amp;" (T.replace "\"" "&quot;" value)))

xmlEscape :: Text -> Text
xmlEscape = escape

atomTime :: Int -> Text
atomTime seconds = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (posixSecondsToUTCTime (fromIntegral seconds)))
