# API reference

The server returns JSON for every `/api/*` route. HTML pages for setup,
login, and recovery are separate routes. All JSON is UTF-8.

## Conventions

- Authenticated routes accept the `eza_session` cookie or an
  `Authorization: Bearer eza_pat_...` API token.
- Cookie requests with unsafe methods (`POST`, `PATCH`, `DELETE`) require
  `X-CSRF-Token` to match the `eza_csrf` cookie. Bearer requests do not use
  CSRF.
- Tokens have `read`, `write`, and `capture` scopes. Account and token
  management routes require a browser session.
- An unauthenticated API request returns 401.
- An HTML request without a session redirects to `/login`.
- Errors use `{"error":{"code":"...","message":"..."}}`.
- Query parameters are optional unless the entry says otherwise.

## Status codes

| Code | Meaning |
|---|---|
| 200 | Request completed |
| 201 | Row created |
| 204 | Request completed with no body |
| 400 | Validation error |
| 401 | No session |
| 403 | CSRF failure or a route outside the recovery scope |
| 404 | Row or route missing |
| 409 | URL or tag conflict |
| 410 | Share link revoked or expired |
| 413 | Request body too large |
| 429 | Rate limit |
| 500 | Internal error |

## Auth

```
POST   /api/auth/options
POST   /api/auth/verify
POST   /api/auth/logout
POST   /api/setup/options
POST   /api/setup/verify
POST   /api/recovery/redeem
```

`POST /api/auth/options` returns WebAuthn request options for a registered
credential. `POST /api/auth/verify` takes the assertion and sets the session
and CSRF cookies. `POST /api/auth/logout` clears both cookies.

`POST /api/setup/options` and `POST /api/setup/verify` create the first
passkey and return the ten recovery codes. The setup routes refuse to run after
a passkey exists unless a recovery session is active.

`POST /api/recovery/redeem` takes `{"code":"..."}` and starts a recovery
session. The session may call only `/setup*` and `/api/setup/*`.

## Library

```
GET    /healthz
GET    /api/v1/boot
GET    /api/v1/bookmarks
POST   /api/v1/bookmarks
POST   /api/v1/quick-save
POST   /api/v1/bookmarks/bulk
GET    /api/v1/stats
GET    /api/v1/favicons/{domain}
GET    /api/v1/bookmarks/{id}
PATCH  /api/v1/bookmarks/{id}
DELETE /api/v1/bookmarks/{id}
```

`GET /api/v1/bookmarks` accepts these query parameters:

| Name | Default | Meaning |
|---|---|---|
| `q` | empty | Search text and operators |
| `tags` | empty | Comma-separated tag names, all required |
| `is_read` | unset | `0` for unread, `1` for read |
| `is_dead` | unset | `0` for live, `1` for dead |
| `sort` | `created` | `created`, `added`, or `opened` |
| `offset` | 0 | Row offset |
| `limit` | 60 | Page size, capped at 200 |

The route returns a `SearchPage`. `POST /api/v1/bookmarks` takes
`{"url","title","tags"}` and returns 201 `{"id":N}`. It returns 409 when the
normalized URL already exists.

`POST /api/v1/quick-save` takes `{"url","title","tags"}`, normalizes the URL,
returns 200 with `{"id","existing":true}` for a duplicate, or inserts a
minimal row, queues enrichment, and returns 201 `{"id","existing":false}`.
The route accepts a capture or write token.

`POST /api/v1/bookmarks/bulk` takes `{"action","ids","tags","confirm"}` for
`add_tags`, `remove_tags`, `mark_read`, `mark_unread`, or `delete`. It
accepts at most 10,000 ids, writes an undo snapshot first, and returns
`{"updated","snapshot_id"}`. Delete requires `"confirm":true`.

`GET /api/v1/bookmarks/{id}` returns a `BookmarkDetail`, including
`enrich_state`, `enrich_error`, and `reading_time_minutes`. `PATCH` accepts
any of `title`, `note_body`, `is_read`, and `tags`, and returns
`{"ok":true}`. When `note_body` is present, the server rebuilds the
`[[wikilink]]` rows for that bookmark.

## Tags, searches, and navigation

```
GET    /api/v1/tags
GET    /api/v1/tags/{tag}/suggestions
GET    /api/v1/tags/consolidation-candidates
POST   /api/v1/tags/apply
POST   /api/v1/tags/merge
POST   /api/v1/tags/{tag}/rename
DELETE /api/v1/tags/{tag}
GET    /api/v1/autocomplete?q=
GET    /api/v1/bookmarks/{id}/backlinks
GET    /api/v1/graph?seed=&depth=
GET    /api/v1/saved-searches
POST   /api/v1/saved-searches
DELETE /api/v1/saved-searches/{id}
```

`GET /api/v1/tags` returns `{"tags":[TagStat]}`, ordered by count. The
rename and delete routes require an empty tag for deletion.

`GET /api/v1/tags/{tag}/suggestions` returns AI tag suggestions. When no
provider key is configured it returns 200 with `configured: false`, an empty
list, and a notice.

`GET /api/v1/autocomplete?q=` returns `{"items":[BookmarkSummary]}`.
`GET /api/v1/bookmarks/{id}/backlinks` returns linked and unlinked mentions.

`GET /api/v1/graph` accepts `seed` (bookmark id), `depth` (1 or 2), and
the same search filters as the library. It returns `GraphData`.

## Maintenance

```
GET    /api/v1/maintenance/prune-candidates
POST   /api/v1/maintenance/prune
POST   /api/v1/maintenance/check-dead
POST   /api/v1/undo
GET    /api/v1/dedup/candidates
POST   /api/v1/dedup/merge
POST   /api/v1/bookmarks/{id}/open
POST   /api/v1/bookmarks/{id}/enrich
POST   /api/v1/bookmarks/{id}/extract
POST   /api/v1/bookmarks/{id}/snapshot
POST   /api/v1/import
POST   /api/v1/import/json
GET    /api/v1/export?format=json
GET    /api/v1/export
```

`POST /api/v1/maintenance/prune` takes `{"ids":[N]}` and writes an undo
snapshot before deleting. `POST /api/v1/undo` restores the most recent
snapshot and returns `{"restored":N}`.

`POST /api/v1/import` accepts a multipart body with one `file` field in the
Netscape format. It returns an `ImportReport`. `POST /api/v1/import/json`
takes a versioned eza JSON document.

`GET /api/v1/export` returns Netscape HTML. Add `?format=json` for a JSON
document with bookmarks, tags, highlights, saved searches, and rules.

`GET /api/v1/stats` returns library counts: `bookmarks`, `tags`,
`bookmark_tags`, `links`, `sources`, `top_sources`, `sources_once`, `first_day`,
`last_day`, `days`, `years`, `filing_days`, `unread`, `dead`, `highlights`,
`shares`, `jobs_pending`, and `favicon_bytes`. `years` is a list of
`[year, count]` pairs, newest first. `filing_days` is a list of
`[date, count]` pairs, oldest first. `top_sources` ranks the 24 busiest
domains as `[domain, count]` pairs. `sources_once` counts domains that hold
exactly one bookmark. `GET /api/v1/boot` returns the same figures under
`stats`.

## Highlights and shares

```
GET    /api/v1/bookmarks/{id}/highlights
POST   /api/v1/bookmarks/{id}/highlights
PATCH  /api/v1/bookmarks/{id}/highlights/{highlightId}
DELETE /api/v1/bookmarks/{id}/highlights/{highlightId}
GET    /api/v1/share-links
POST   /api/v1/share-links
DELETE /api/v1/share-links/{id}
GET    /api/v1/rules
POST   /api/v1/rules
POST   /api/v1/rules/test
PATCH  /api/v1/rules/{id}
DELETE /api/v1/rules/{id}
GET    /s/{token}
GET    /s/{token}.xml
GET    /api/v1/bookmarks/{id}/snapshot
```

A highlight body contains `quote`, `prefix`, `suffix`, `start_offset`,
`end_offset`, `note`, and `color`. A share body contains `scope`
(`bookmark` or `saved_search`), `target_id`, `include_note`, and
`expires_in_days`. The create response returns the public URL once.

`GET /s/{token}` is a public, read-only page and sends `X-Robots-Tag: noindex`
and `Cache-Control: private, no-store`. A readable link returns 200 with the
shared record, the keeper's note when the link includes it, and the expiry
date. A token that matches no row returns 404. A revoked or expired link
returns 410 with a page that says so. A saved-search share also exposes
`/s/{token}.xml` as an Atom feed. The snapshot route returns the local
monolith file inside a sandboxed CSP.

Rules take `name`, `enabled`, `field` (`url`, `domain`, or `title`),
`pattern`, `add_tags`, and `mark_read`. They run inside the save
transaction. `POST /api/v1/rules/test` returns matching bookmark ids without
changing anything.

## Account and tokens

```
GET    /api/v1/tokens
POST   /api/v1/tokens
DELETE /api/v1/tokens/{id}
GET    /api/v1/account
POST   /api/v1/account/passkeys/options
POST   /api/v1/account/passkeys/verify
PATCH  /api/v1/account/passkeys/{id}
DELETE /api/v1/account/passkeys/{id}
POST   /api/v1/account/recovery/regenerate
```

`GET /api/v1/account` returns
`{"credentials":[CredentialInfo],"recovery_codes_remaining":N,"sessions":[SessionInfo]}`.
`SessionInfo` carries timestamps and a `current` flag for the requesting
session. Session ids and hashes are never exposed.
`POST /api/v1/account/recovery/regenerate` invalidates the unused codes and
returns ten new codes. `POST /api/v1/tokens` takes
`{"name","scopes":["read","write","capture"]}` and returns the raw token once
plus its metadata. Tokens are stored by hash and revoke immediately.

## DTOs

```
TagStat         {name: Text, count: Int}
BookmarkSummary {id, url, title, domain, created_at, added_at, favicon_url,
                 tags: [Text], is_read: Bool, is_dead: Bool, snippet: Maybe Text}
SearchPage      {items: [BookmarkSummary], total, offset, limit, has_more,
                 year_counts: [[Int, Int]]}
BootPayload     {version, origin, tags: [TagStat], saved_searches,
                 initial: SearchPage, stats: LibraryStats}
LibraryStats    {total, tags, tag_links, sources,
                 top_sources: [[Text, Int]], sources_once, first_day, last_day,
                 days, years: [[Int, Int]], filing_days: [[Text, Int]],
                 unread, dead, queued, favicon_bytes, highlights, shares}
SessionInfo     {created_at: Int, last_seen_at: Maybe Int, expires_at: Int,
                 current: Bool}
BookmarkDetail  {summary fields except snippet, note_body, extracted_text,
                 author, sitename, published_at, language, image_url,
                 final_url, snapshot_path, snapshot_kind, last_opened_at,
                 last_checked_at, links: [Backlink]}
Backlink        {source_id, source_title, snippet, line: Maybe Int,
                 resolved: Bool}
CredentialInfo  {id: Text, nickname: Text, created_at: Int,
                 last_used_at: Maybe Int}
ImportReport    {found, http_anchors, unique_urls, inserted, existing,
                 duplicate_anchors, skipped_non_http, tags_created,
                 tag_links_added, folders_skipped, untagged, elapsed_ms}
```

`created_at` is the original save date from `ADD_DATE` on import.
`added_at` is when eza first saw the row. The default sort is
`created_at DESC`.
