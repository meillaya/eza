# eza API contract (v1)

All JSON responses are UTF-8. Errors use:

```json
{"error":{"code":"not_found","message":"..."}}
```

Status codes: 400 validation, 401 unauthenticated, 403 CSRF/recovery-scope,
404 missing, 409 conflict, 413 too large, 429 rate limit, 500 internal.

## Currently implemented (M1)

- `GET /healthz` → `{"status":"ok","version":"0.1.0"}` or 503.
- `GET /api/v1/boot` →
  `{"version":"0.1.0","origin":"http://localhost:8080","tags":[TagStat],"saved_searches":[],"initial":SearchPage}`
- `GET /api/v1/bookmarks?q=&tags=a,b&is_read=&is_dead=&sort=created|added|opened&offset=0&limit=60`
  → `SearchPage`
- `POST /api/v1/bookmarks` body `{"url":"https://…","title":"…","tags":["a"]}`
  → 201 `{"id":123}`; 409 `{"error":{…}}` if the URL exists.
- `GET /api/v1/bookmarks/{id}` → `BookmarkDetail`; 404.
- `DELETE /api/v1/bookmarks/{id}` → 204.
- `GET /api/v1/tags` → `{"tags":[{"name":"imported","count":8790},…]}`
- `POST /api/v1/inbox/mark-all-above` body `{"above_id":123}` or `{}`
  → `{"updated":N}`.
- `PATCH /api/v1/bookmarks/{id}` body `{"title","note_body","is_read","tags"}`
  → 200 `{"ok":true}` (wikilinks are re-synced when `note_body` is supplied).
- `GET /api/v1/bookmarks/{id}/backlinks` → `{"linked":[Backlink],"unlinked":[Backlink]}`.
- `GET /api/v1/autocomplete?q=` → `{"items":[BookmarkSummary]}`.
- `GET /api/v1/graph?seed=&depth=` → `GraphData`.
- `GET/POST /api/v1/saved-searches`, `DELETE /api/v1/saved-searches/{id}`.
- `GET /api/v1/dedup/candidates` → `{"groups":[…]}`; `POST /api/v1/dedup/merge`.
- `GET /api/v1/tags/consolidation-candidates`, `POST /api/v1/tags/merge`,
  `POST /api/v1/tags/apply`, `POST/DELETE /api/v1/tags/{name}`.
- `GET /api/v1/maintenance/prune-candidates`, `POST /api/v1/maintenance/prune`,
  `POST /api/v1/maintenance/check-dead`, `POST /api/v1/undo`.
- `POST /api/v1/import` (multipart `file`), `GET /api/v1/export`.
- `POST /api/v1/bookmarks/{id}/open|enrich|extract|snapshot`.

## DTOs (snake_case JSON)

```
TagStat        {name: Text, count: Int}
BookmarkSummary{id,url,title,domain,created_at,added_at,favicon_url,
                tags:[Text],is_read:Bool,is_dead:Bool,snippet:Maybe Text}
SearchPage     {items:[BookmarkSummary],total,offset,limit,has_more}
BookmarkDetail {…summary fields except snippet…,
                note_body,extracted_text,author,sitename,published_at,
                language,image_url,final_url,snapshot_path,snapshot_kind,
                last_opened_at,last_checked_at,links:[Backlink]}
Backlink       {source_id,source_title,snippet,line:Maybe Int,resolved:Bool}
BootPayload    {version,origin,tags:[TagStat],saved_searches:[SavedSearch],initial:SearchPage}
```

`created_at` is the original save date (ADD_DATE on import); `added_at` is
when eza first saw the row. The default sort is `created_at DESC`.

## Planned authenticated routes (M2–M4)

```
POST   /api/auth/options | /api/auth/verify          passkey login
POST   /api/auth/logout
POST   /api/setup/options | /api/setup/verify        first-run / recovery re-enroll
POST   /api/recovery/redeem
GET    /api/v1/account                              {"credentials":[CredentialInfo],"recovery_codes_remaining":N}
POST   /api/v1/account/passkeys/options|verify      add a passkey
PATCH  /api/v1/account/passkeys/{id}
DELETE /api/v1/account/passkeys/{id}
POST   /api/v1/account/recovery/regenerate
POST   /api/v1/bookmarks/{id}/open
POST   /api/v1/bookmarks/{id}/enrich
POST   /api/v1/bookmarks/{id}/extract
POST   /api/v1/bookmarks/{id}/snapshot
GET    /api/v1/bookmarks/{id}/backlinks
GET    /api/v1/autocomplete?q=
POST   /api/v1/tags/apply | /api/v1/tags/merge
POST   /api/v1/tags/{id}   DELETE /api/v1/tags/{id}
GET    /api/v1/tags/consolidation-candidates
GET    /api/v1/tags/{tag}/suggestions
GET    /api/v1/graph?seed=&depth=
GET/POST /api/v1/saved-searches   DELETE /api/v1/saved-searches/{id}
GET    /api/v1/dedup/candidates    POST /api/v1/dedup/merge
POST   /api/v1/undo
POST   /api/v1/maintenance/check-dead
GET    /api/v1/maintenance/prune-candidates
POST   /api/v1/maintenance/prune
POST   /api/v1/import (multipart field "file")
GET    /api/v1/export
GET    /api/v1/export/notes
```

Unauthenticated HTML requests redirect to `/login`; API requests return 401.
Unsafe methods require `X-CSRF-Token` matching the `eza_csrf` cookie.
