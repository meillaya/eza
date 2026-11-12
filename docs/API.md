# API reference

The server returns JSON for every `/api/*` route. HTML pages for setup,
login, and recovery are separate routes. All JSON is UTF-8.

Since M3 one instance serves several accounts. The control database
(`EZA_CONTROL_DB`, default `$EZA_DATA_DIR/control.db`) holds identity and each
account's library is a separate SQLite file under `EZA_USERS_DIR` (default
`$EZA_DATA_DIR/users/<id>/eza.db`). A request's session cookie, pending cookie,
share token, or API token carries the owning account id in its prefix; the
server resolves that id through the control database before it hashes the
token. See [architecture.md](architecture.md) for the data layout.

## Conventions

- Authenticated routes accept the `eza_session` cookie or an
  `Authorization: Bearer eza_pat_u<id>_...` API token. Cookies and share links
  use the `u<id>_<random>` form. Treat every token as opaque: the prefix picks
  the account database, and a rewritten prefix fails the hash check.
- Cookie requests with unsafe methods (`POST`, `PATCH`, `DELETE`) require
  `X-CSRF-Token` to match the `eza_csrf` cookie. Bearer requests do not use
  CSRF.
- Tokens have `read`, `write`, and `capture` scopes. Account and token
  management routes require a browser session.
- An unauthenticated API request returns 401.
- An HTML request without a session redirects to `/login`.
- The public auth POSTs check the request `Origin`: a browser must send an
  origin that matches `PUBLIC_ORIGIN` or an `EZA_ALLOWED_ORIGINS` extra, and a
  `Sec-Fetch-Site: cross-site` request is rejected. A missing `Origin` is
  accepted only for non-browser clients.
- Public auth POSTs accept at most `EZA_AUTH_BODY_LIMIT_BYTES` bytes of JSON
  (8192 by default) and return 413 above it.
- Errors use `{"error":{"code":"...","message":"..."}}`.
- Query parameters are optional unless the entry says otherwise.

## Status codes

| Code | Meaning |
|---|---|
| 200 | Request completed |
| 201 | Row created |
| 204 | Request completed with no body |
| 400 | Validation error |
| 401 | No session, a failed username/password login, or an expired pending two-factor sign-in |
| 403 | CSRF, origin, session-scope, recovery-scope, or admin-role failure; retired passkey ceremony |
| 404 | Row or route missing; unknown account |
| 409 | URL, tag, last-credential, last-admin, self-disable, or username conflict; two-factor precondition |
| 410 | Share link revoked or expired; passkey setup retired |
| 413 | Request body too large |
| 429 | Rate limited; read `Retry-After` |
| 500 | Internal error |

## Auth

An account is a username plus an Argon2id password hash in that account's own
`app_state`, and passkeys are optional second factors scoped to the same
database. Accounts live in the control database: `id`, `username` (unique,
case-insensitive), `role` (`admin` or `member`), database path, WebAuthn user
handle, `disabled_at`, `last_login_at`. A disabled account cannot sign in and
its live sessions stop resolving.

Startup migration: if the control database has no rows and the legacy
`EZA_DB` file exists with a claimed account, that file is registered as user 1
with the admin role, in place, with no copy or move. An unclaimed legacy file
is left alone. Otherwise the first `POST /api/setup/password` claims a fresh
account in `$EZA_DATA_DIR/users/<id>/eza.db`.

Passkeys that predate schema v6 are legacy credentials: they sign in only while
the account's database has no password. Recovery clears both the password and
the passkeys. Each account gets its own WebAuthn user handle from the control
row, so two passkeys on one server are never registered under a shared user
id.

```
POST   /api/auth/login
POST   /api/auth/passkey/options
POST   /api/auth/passkey/verify
POST   /api/auth/options
POST   /api/auth/verify
POST   /api/auth/logout
POST   /api/setup/password
POST   /api/recovery/redeem
```

`POST /api/auth/login` takes `{"username":"...","password":"..."}`. The
username resolves the control row, then the password is verified against that
account's database. An unknown or disabled username pays a dummy Argon2 hash
and returns the same generic 401 as a wrong password; attempts are also capped
per client host and username. After `EZA_LOGIN_MAX_ATTEMPTS` failures the
account locks for `EZA_LOGIN_LOCKOUT_SECONDS` and the endpoint returns 429 with
`Retry-After`; those counters live in that account's `app_state` and survive a
restart.

A success returns `{"requires_2fa":false,"redirect":"/"}` and sets the session
and CSRF cookies. Session lifetime is `EZA_SESSION_TTL_SECONDS`.

When passkey two-factor is on and at least one passkey is registered, the
password alone returns `{"requires_2fa":true}`: the server creates no normal
session and sets only a short-lived HttpOnly `eza_pending` cookie, five
minutes. The browser finishes the sign-in with two requests that both read
that cookie:

1. `POST /api/auth/passkey/options` returns WebAuthn assertion options whose
   challenge is scoped to the second factor.
2. `POST /api/auth/passkey/verify` takes the assertion and returns
   `{"requires_2fa":false,"redirect":"/"}` with the session and CSRF cookies;
   the pending session is deleted. A missing or expired pending cookie returns
   401 `pending_required`.

The pending cookie is not a session for any other route. It cannot call
`/api/v1` or any page behind the session guard; only the two passkey requests
above use it.

`POST /api/setup/password` takes `{"username":"...","password":"...","confirm":"..."}`
and is available on a fresh control database and during a recovery setup. With
no accounts it creates the first account (admin) and its database; with a
recovery session it finishes that session's account. Either way it marks the
database claimed, replaces the recovery codes with ten new ones, returns
`{"codes":[...],"redirect":"/"}`, and signs the browser in. It leaves passkey
two-factor off. `POST /api/setup/options` and `/api/setup/verify` are retired
and return 410.

`POST /api/auth/options` and `POST /api/auth/verify` are the legacy passkey
ceremony. They work only while the database has passkeys and no password, and
return 403 once a password exists or a recovery session is active. A successful
assertion sets the session and CSRF cookies.

`POST /api/auth/logout` clears the session, CSRF, and pending cookies.

`POST /api/recovery/redeem` takes `{"username":"...","code":"..."}`. The
username resolves the control row; an unknown account and a used code share
the same 400 `bad_code`. It is rate limited by client host. Redemption spends the code, deletes every passkey, clears the
password and the two-factor flag, revokes every other session, and starts a
ten-minute recovery session. The session may call only `POST
/api/setup/password`, `POST /api/auth/logout`, and `GET /api/v1/account`;
completing the setup writes a new password and rotates the remaining codes
out.

The password pages are `GET /login`, `GET /setup`, and `GET /recover`.
`GET /login` renders the password form (or the legacy passkey form when that
account predates passwords), or redirects to `/setup` while
the control database has no accounts. `GET /setup` renders the claim form, or
the recovery form pre-filled with the session account's username while a
recovery session is active.
`GET /account/add-passkey` is the passkey registration page for a signed-in
session.

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

`q` accepts the operators `tag:name`, `is:unread`, `is:dead`,
`link:target`, `-term`, `year:YYYY`, and `day:YYYY-MM-DD`. Free-text terms
match the FTS index (title, description, URL, note body, extracted text, and
source domain) and, as a fallback, source tag names, so `rust` can return
records filed under the `rust` tag even when no indexed field contains the
word. A negated term excludes the same tag-name fallback, so `-rust` also
hides records that match only through the tag. Rows that matched the text
index come before rows that matched only
through the tag-name fallback; inside each group the `sort` order applies, so
a searched ledger sorts exactly like an unsearched one. Because the domain is
indexed, a query such as
`www.reddit.com` returns the records filed from that source even when their
saved URLs omit the `www.` prefix; the ledger's source facets write exactly
this query. Date filters use UTC and match the original save
date (`created_at`); rows with no save date (`created_at` = 0) never match. A
filter ANDs with the other operators and the `tags`, `is_read`, and
`is_dead` columns, and `year_counts` reflects it.

A row whose stored save date is outside the range eza represents (or whose
import value looked like milliseconds) is normalised at the storage boundary:
the importer reports the count as `timestamps_normalised` and the list/stats
queries never fail on a bad row.

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

`GET /api/v1/favicons/{domain}` serves the cached icon bytes for one source
domain. Icons are stored per domain, not per bookmark: the background
`EZA_FAVICON_BACKFILL` loop fills one icon for a domain and applies it to every
record on that domain with one update, so a site with hundreds of links costs
one request. It tries the conventional icon paths first and parses the
homepage once only if they all miss. A body is stored only when it is a
complete PNG/JPEG/WebP or a complete-entry ICO (multi-entry ICOs are cropped);
incomplete, truncated, SVG, and failure-placeholder bodies are never served.
A domain with no cached icon redirects to the static fallback;
checksum-busted `?v=` links are used by the ledger rows. Bookmark rows only
ever point at this local route; absolute remote icon URLs are ignored and
cleared by the v15 repair.

`GET /api/v1/bookmarks/{id}` returns a `BookmarkDetail`, including
`enrich_state`, `enrich_error`, `reading_time_minutes`, and `manual_alive`.
`PATCH` accepts any of `title`, `note_body`, `is_read`, `tags`, and
`extracted_text`, and returns `{"ok":true,"highlights_removed":N}`. When
`note_body` is present, the server rebuilds the `[[wikilink]]` rows for that
bookmark. When `extracted_text` is present, the server recomputes the reading
time, marks the extraction as manual (`enrich_state = "manual"`) so background
enrichment does not replace it, and re-anchors highlights against the new text;
highlights whose quote no longer appears are removed and counted.

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
GET    /api/v1/graph
GET    /api/v1/graph/layout?preset=compact|standard|airy
GET    /api/v1/views
POST   /api/v1/views
GET    /api/v1/views/{slug}
PATCH  /api/v1/views/{slug}
DELETE /api/v1/views/{slug}
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

`GET /api/v1/graph` takes no parameters and returns the whole library as
`GraphData`; it is read only. The wire format is compact arrays, not objects:

- `tags` is `[[name, count]]`, ordered by record count descending, then name.
- `records` is
  `[[id, title, domain, created_at, is_read, is_dead, [tagIndex]]]`, ordered by
  id. A record with an empty title carries its domain in the title slot. The
  tag indexes point into `tags` and ascend within a record, so a tag name is
  sent once rather than once per member record. `is_dead` feeds the graph
  matcher and colour groups; the client paints the same shape.
- `links` is `[[source_id, target_id]]`, sorted and de-duplicated. Only
  resolved wikilinks are included: both endpoints are records in the payload,
  so an unresolved target never appears.
- `revision` is an opaque fingerprint built from the record count, the newest
  `updated_at`, the tag count, the tag-link count and the resolved link count.
  It changes when the library changes; clients only compare it, never parse
  it. A response without it decodes as an empty string.

The graph is whole-library, not a seed neighbourhood: every record and every
tag is in the response. Pan, zoom, and filtering happen in the browser.

`GET /api/v1/graph/layout?preset=compact|standard|airy` returns the
server-computed node positions for one layout preset, so the client can hydrate
a layout instead of running the deterministic builder itself. The default
preset is `standard`; an unknown preset is a 400. The payload is:

```
{"schema": 1,
 "revision": Text,
 "preset": "compact" | "standard" | "airy",
 "tags": [[x, y], ...],
 "records": [[x, y], ...],
 "bounds": [minx, miny, maxx, maxy]}
```

`tags` positions are keyed by tag index (the same order as `GraphData.tags`),
`records` positions by record id. Every coordinate is quantized to 1/100 world
unit. `revision` is the revision the positions were built from, so a client
only hydrates when it matches the graph payload it already holds. The server
caches the payload per database and revision, so only the first request for a
preset computes and encodes it.

Views are stored documents. `GET /api/v1/views` returns `{"views":[View]}`,
default first, then graph before ledger, then slug. `POST /api/v1/views` takes
a `ViewInput` and returns 201 with the created view. `GET
/api/v1/views/{slug}` returns one view or 404. `PATCH /api/v1/views/{slug}`
accepts any of `name`, `slug`, `definition`, and `is_default`, and returns the
updated view. `DELETE /api/v1/views/{slug}` returns 204.

Rules:

- names are required and capped at 80 characters; the server derives a slug
  from the name unless the input carries one, appends `-2`, `-3`, ... on a
  collision, and caps a slug at 48 characters;
- at most 64 views exist per installation, above that a create returns 409
  `view_limit`;
- `is_default` is unique per kind. Setting it on one view clears it on the
  other views of that kind in the same transaction; the boot payload always
  carries the default graph view because every opened database seeds one when
  none exists;
- deleting the current default promotes the lowest-id remaining view of that
  kind; deleting the last graph view seeds the default graph view again;
- every stored view object carries `"schema":1` at the wrapper level; an
  unknown schema is rejected. The graph and ledger definition objects carry no
  schema of their own, so a definition is
  `{"query":...,"tags_shown":...,"label_mode":...,"layout_preset":...,"local_depth":...,"color_groups":[...]}`
  for a graph view and `{"query":...,"sort":...}` for a ledger view;
- invalid names, definitions, or slugs return 400 with
  `{"error":{"code":"bad_request","message":...}}`.

## Maintenance

```
GET    /api/v1/maintenance/prune-candidates
POST   /api/v1/maintenance/prune
POST   /api/v1/maintenance/check-dead
GET    /api/v1/undo?limit=5
GET    /api/v1/undo/{id}
POST   /api/v1/undo
GET    /api/v1/dedup/candidates?url_offset=0&url_limit=60&title_offset=0&title_limit=40
POST   /api/v1/dedup/merge
POST   /api/v1/dedup/merge-all
POST   /api/v1/bookmarks/{id}/open
POST   /api/v1/bookmarks/{id}/enrich
POST   /api/v1/bookmarks/{id}/extract
POST   /api/v1/bookmarks/{id}/mark-alive
POST   /api/v1/bookmarks/{id}/recheck-link
POST   /api/v1/bookmarks/{id}/snapshot
POST   /api/v1/import
POST   /api/v1/import/json
GET    /api/v1/export?format=json
GET    /api/v1/export
```

`POST /api/v1/maintenance/prune` takes `{"ids":[N]}` and writes an undo
snapshot before deleting. `POST /api/v1/maintenance/check-dead` accepts
`{"limit","older_than","include_dead"}` and returns
`{"checked","dead","alive","total_dead"}`; `dead` is the number newly marked in
this run, `total_dead` is the library total, and `include_dead:true` rechecks
records already marked dead before the unchecked tail, so an explicit sweep can
repair a 403 false positive. Only a GET-confirmed 404 or 410 marks a link dead;
401/403/405/407/429/451, 5xx, and network/timeout answers leave the flag alone.

Undo is a stack. `GET /api/v1/undo?limit=5` returns the newest usable
snapshots as `{"entries":[UndoEntry]}`, newest first; only the first entry has
`can_undo:true`. `GET /api/v1/undo/{id}` returns an `UndoPreview` with up to
100 record/tag samples and `truncated`. `POST /api/v1/undo` takes an optional
`{"snapshot_id":N}`; without one it restores the newest usable snapshot for
compatibility, and with one it returns `409 undo_out_of_order` unless that
snapshot is the newest usable one. A successful undo returns
`{"restored","skipped","snapshot_id","op"}` and removes the snapshot.

`POST /bookmarks/{id}/mark-alive` records a user override, keeps
`is_dead = 0`, and excludes the record from later sweeps until
`POST /bookmarks/{id}/recheck-link` clears the override. The override is
restored by undo and follows a merge to the keeper.

`GET /api/v1/dedup/candidates` pages the duplicate report. `url_limit`
(default 60) and `title_limit` (default 40) are clamped to 1-200 and both
offsets default to 0. The response is
`{"counts":{url_groups,url_records,title_groups,title_records},"url_groups":[{"key","kind":"url","items":[BookmarkSummary]}],"title_groups":[{"key","kind":"title","items":[...]}]}`.
`counts` always covers the whole library, so the interface never sums loaded
groups. Items are ordered by record id, so the first item is the deterministic
keeper. URL groups are safe duplicates: the shared canonical key ignores the
http/https scheme, a leading `www.`, default ports, fragments, tracking
parameters, and a trailing slash, while a non-default port stays significant.
Title groups are advisory (same normalised title on one source, different
pages); bulk merging never touches them.

`POST /api/v1/dedup/merge` merges one group: `{"keep_id":N,"merge_ids":[N]}`.
Every absorbed row's tags, notes, highlights and wikilinks are folded onto the
keeper, and a `merge` undo snapshot is written first. It returns
`{"merged":N,"snapshot_id":N}` so the interface can preview and undo exactly
that merge.

`POST /api/v1/dedup/merge-all` requires `{"confirm":true}`. It recomputes every
canonical-URL duplicate group, merges them all in one transaction behind one
`merge_all` undo snapshot, and returns
`{"groups":N,"records":N,"affected":N,"snapshot_id":N,"elapsed_ms":N}`. A
keeper prefers the https address of its page. Title matches are excluded by
design. The command-line equivalent is
`eza-bookmarks dedupe --all --dry-run` and `eza-bookmarks dedupe --all --yes`.

`POST /api/v1/import` accepts either a multipart body with one `file` field in
the Netscape format (or an eza JSON export) or an `application/json` body with
a versioned eza JSON document. Both are bounded by `EZA_IMPORT_MAX_BYTES`
(the JSON body path uses the import cap, not `EZA_MAX_BODY_BYTES`) and answer
with an `ImportReport` shape (the JSON path adds `json_report` with per-kind
counts, including `timestamps_normalised`); `POST /api/v1/import/json`
is the dedicated JSON-only route. Rows are de-duplicated against the library
by the canonical URL key before anything is inserted, so a re-run, an
overlapping export, or an http/https copy of a filed page merges tags onto the
existing record instead of creating a second row. Newly inserted rows are
queued for background extraction.

`GET /api/v1/export` returns Netscape HTML. Add `?format=json` for version 2
of the portable JSON document: bookmarks (with their enrichment fields),
highlights including prefix/suffix anchors, captures, saved searches, rules,
views, and clip templates. Webhook subscription secrets are deliberately not
exported. The version 1 document is still accepted by the importer.

`GET /api/v1/stats` returns library counts: `bookmarks`, `tags`,
`bookmark_tags`, `links`, `sources`, `top_sources`, `sources_once`, `first_day`,
`last_day`, `days`, `years`, `filing_days`, `unread`, `dead`, `highlights`,
`shares`, `jobs_pending`, and `favicon_bytes`. `years` is a list of
`[year, count]` pairs, newest first. `filing_days` is a list of
`[date, count]` pairs, oldest first. `top_sources` ranks the 24 busiest
domains as `[domain, count]` pairs. `sources_once` counts domains that hold
exactly one bookmark. `GET /api/v1/boot` returns the same figures under
`stats`, plus the saved `views`.

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
POST   /api/v1/account/2fa
POST   /api/v1/account/passkeys/options
POST   /api/v1/account/passkeys/verify
PATCH  /api/v1/account/passkeys/{id}
DELETE /api/v1/account/passkeys/{id}
POST   /api/v1/account/recovery/regenerate
```

`GET /api/v1/account` returns
`{"username":Text,"role":"admin"|"member","has_password":Bool,"require_passkey":Bool,"account_configured":Bool,"credentials":[CredentialInfo],"recovery_codes_remaining":N,"sessions":[SessionInfo]}`.
The first five fields describe the signed-in account; `role` comes from the
control database and `require_passkey` reports whether optional passkey
two-factor is on. `SessionInfo` carries timestamps and
a `current` flag for the requesting session. Session ids and hashes are never
exposed, and pending two-factor sessions never appear in the list.

`POST /api/v1/account/2fa` takes
`{"required":Bool,"current_password":Text}` and returns the same account
document as `GET /api/v1/account`, including `role`. Enabling needs the correct current password
and at least one registered passkey, otherwise the endpoint returns 409 with
`passkey_required`. Disabling needs the current password. Changing the password
does not change the two-factor flag; recovery does clear it.

`POST /api/v1/account/password` takes
`{"current_password":Text?,"new_password":Text,"confirm":Text}`. The current
password is required once one exists; a legacy passkey session may set the
first password without it. The new password is at least ten characters, other
browser sessions are revoked, and the response is `{"ok":true}`.

`POST /api/v1/account/username` takes
`{"current_password":Text?,"username":Text}` and renames the account.
`POST /api/v1/account/sessions/revoke-others` revokes every session except the
requesting one and returns `{"revoked":N}`.

A signed-in session can register a passkey at any time.
`POST /api/v1/account/passkeys/options` returns registration options and
`POST /api/v1/account/passkeys/verify` stores the credential; both require a
browser session. An existing credential can be renamed or deleted.
`DELETE /api/v1/account/passkeys/{id}` may remove every passkey while
two-factor is off. With two-factor on it refuses to remove the last one with
409 `last_credential`; turn two-factor off first. A legacy passkey-only
account also refuses to remove its last credential.

`POST /api/v1/account/recovery/regenerate` invalidates the unused codes and
returns ten new codes. `POST /api/v1/tokens` takes
`{"name","scopes":["read","write","capture"]}` and returns the raw token once
plus its metadata. The raw token is `eza_pat_u<id>_<random>`: the prefix binds
it to the issuing account, so it can only be validated against that account's
database. Tokens are stored by hash and revoke immediately.

## Administration

Session-only, admin role only. A member session gets 403 `session_scope`; a
bearer token never reaches these routes (403 `session_required`). Responses
never contain a database path.

```
GET   /api/v1/admin/users
POST  /api/v1/admin/users
PATCH /api/v1/admin/users/{id}
POST  /api/v1/admin/users/{id}/password
DELETE /api/v1/admin/users/{id}
```

`GET /api/v1/admin/users` returns `{"users":[UserView]}` ordered by id.

`POST /api/v1/admin/users` takes `UserCreateInput`
(`{"username","password","role":"admin"|"member"}`) and returns 201 with
`UserCreateResult` (`{"user":UserView,"recovery_codes":[Text]}`). The server
allocates the control id, creates and migrates `users/<id>/eza.db`, finishes
the password setup, and prints the recovery codes exactly once. On failure the
partial account row and database are removed. Duplicate usernames return 409
`username_taken`; a weak password returns 400 `weak_password`.

`PATCH /api/v1/admin/users/{id}` takes `{"enabled":Bool}` and/or
`{"role":"admin"|"member"}` and returns the updated `UserView`. Disabling an
account revokes its sessions and stops its background workers. The server
refuses to disable the caller's own account (409 `self_disable`) and refuses to
disable, demote, or delete the last enabled admin (409 `last_admin`).

`POST /api/v1/admin/users/{id}/password` takes `{"password":Text}` (at least
ten characters), sets a temporary password, clears that account's optional
passkey second factor, revokes every session of that account, and returns
`{"ok":true}`. This is the break-glass path for a user who lost their device;
it does not read the library, but it can hand the account to the caller. The
target should be told out of band.

`DELETE /api/v1/admin/users/{id}` takes `{"confirm":true,"delete_db":Bool}`
and returns `{"ok":true}`. The control row is always removed; the library
database and snapshots are removed only when `delete_db` is true. The server
refuses the caller's own account (409 `self_disable`) and the last enabled
admin (409 `last_admin`).

## Extensions and webhooks

```
GET    /api/v1/webhooks
POST   /api/v1/webhooks
GET    /api/v1/webhooks/{id}
PATCH  /api/v1/webhooks/{id}
DELETE /api/v1/webhooks/{id}
POST   /api/v1/webhooks/{id}/test
GET    /api/v1/webhooks/{id}/deliveries?limit=20
```

Webhook management is session-only: a bearer token, including a `write` token,
is rejected with 403 `session_required`. At most 16 subscriptions exist per
database. `GET /api/v1/webhooks` returns `{"webhooks":[Webhook]}`;
`POST /api/v1/webhooks` takes a `WebhookInput` and returns 201 with
`{"webhook":Webhook,"secret":Text}`. The secret is 64 lowercase hex characters
and is shown only on create. `GET`, `PATCH`, and `DELETE
/api/v1/webhooks/{id}` read, update, and remove one subscription; `PATCH`
takes a `WebhookInput` and returns the updated `Webhook`. `POST
/api/v1/webhooks/{id}/test` posts one synthetic `bookmark.updated` event to
that subscription and returns `{"ok":Bool,"status":Maybe Int,"error":Text}`.
`GET /api/v1/webhooks/{id}/deliveries` returns the most recent deliveries as
`{"deliveries":[DeliveryView]}`, newest first; `limit` defaults to 20 and is
clamped to 1-100.

A subscription receives one signed HTTP POST per matching event. The request
carries these headers:

| Header | Value |
|---|---|
| `X-Eza-Event` | event type, for example `bookmark.created` |
| `X-Eza-Delivery` | delivery id |
| `X-Eza-Timestamp` | POSIX seconds at send time |
| `X-Eza-Signature` | `sha256=` plus lowercase hex HMAC-SHA256 of `timestamp + "." + body`, keyed with the subscription secret |
| `Content-Type` | `application/json` |

The body is an `EventEnvelope`:

```
{"id": "evt-123", "type": "bookmark.created", "occurred_at": 1700000000,
 "data": {...}}
```

The v1 event catalog:

- `bookmark.created`, `bookmark.updated`, `bookmark.deleted` carry
  `{"id","url","title","domain","is_read","is_dead","tags":[Text]}`. The
  deleted payload is captured before the row is removed.
- `clip.created` carries `{"capture_id","bookmark_id"}`.
- Imports do not emit per-row events; the v1 catalog has no
  `import.completed`.

Writes append their event row in the same transaction, so an event exists if
and only if the write committed, and a no-op patch or an idempotent clip replay
records nothing. A background worker fans the outbox out once per matching
enabled subscription (the persistent cursor plus a UNIQUE guard make that
idempotent) and posts each delivery with exponential backoff: five attempts
with a 30 second base (30, 60, 120, 240 seconds), then the delivery is marked
`failed` and the subscription is disabled. Redirects are not followed, the
target must pass the same private-network guard as other outbound fetches, the
request body is capped at 64 KiB, and response bodies are discarded. Delivery
states are `queued`, `delivering`, `delivered`, and `failed`. Events and
finished deliveries older than 30 days are purged.

## Browser clipper

```
GET    /api/v1/whoami
POST   /api/v1/clip
POST   /api/v1/clip/preview
GET    /api/v1/clip-templates
GET    /api/v1/clip-templates/{id}
POST   /api/v1/clip-templates
PATCH  /api/v1/clip-templates/{id}
DELETE /api/v1/clip-templates/{id}
```

`POST /api/v1/clip` accepts a clip from the browser extension with
`Authorization: Bearer` (scope `capture` or `write`) and an optional
`Idempotency-Key`. The body is a `ClipRequest`; only `url` is required. It
returns a `SaveClipResult` with `capture_id`, `bookmark_id`,
`bookmark_created`, `replayed`, rendered `markdown`, tags, template id/name,
and `needs_enrichment`. A replay with the same key and request hash returns
200 with `replayed:true`; the same key with a different payload is 409
`idempotency_conflict`. `POST /api/v1/clip/preview` renders the template
without writing. `GET /api/v1/whoami` returns the authenticated username
(cookie session) or token name/scopes (bearer). Capture tokens may only read
templates and call whoami/clip; template writes need a browser session.

The clipper CORS preflight runs before the auth guard. Allowed origins come
from `EZA_CLIP_ORIGINS`, the public origin/allowed origins, and
`chrome-extension://`, `moz-extension://`, or `safari-web-extension://`
origins. The clip body limit is 8 MiB; content field limits are enforced by
`validateClip`. See [clipper.md](clipper.md) for the extension, sidecar, and
template model.

## DTOs

```
TagStat         {name: Text, count: Int}
BookmarkSummary {id, url, title, domain, created_at, added_at, favicon_url,
                 tags: [Text], is_read: Bool, is_dead: Bool, snippet: Maybe Text}
SearchPage      {items: [BookmarkSummary], total, offset, limit, has_more,
                 year_counts: [[Int, Int]]}
BootPayload     {version, origin, tags: [TagStat], saved_searches,
                 initial: SearchPage, stats: LibraryStats, views: [View]}
LibraryStats    {total, tags, tag_links, sources,
                 top_sources: [[Text, Int]], sources_once, first_day, last_day,
                 days, years: [[Int, Int]], filing_days: [[Text, Int]],
                 unread, dead, queued, favicon_bytes, highlights, shares}
SessionInfo     {created_at: Int, last_seen_at: Maybe Int, expires_at: Int,
                 current: Bool}
BookmarkDetail  {summary fields except snippet, note_body, extracted_text,
                 author, sitename, published_at, language, image_url,
                 final_url, snapshot_path, snapshot_kind, last_opened_at,
                 last_checked_at, manual_alive: Bool, links: [Backlink]}
UndoBookmarkRef {id, title, url, domain}
UndoEntry       {id, op, created_at, row_count, bookmark_count, tag_count,
                 highlight_count, capture_count, link_count, can_undo,
                 legacy, bookmarks: [UndoBookmarkRef], tags: [Text]}
UndoPreview     {entry: UndoEntry, bookmarks: [UndoBookmarkRef],
                 tags: [Text], truncated: Bool}
UndoResult      {restored, skipped, snapshot_id, op}
Backlink        {source_id, source_title, snippet, line: Maybe Int,
                 resolved: Bool}
GraphData       {tags: [[Text, Int]],
                 records: [[Int, Text, Text, Int, Bool, Bool, [Int]]],
                 links: [[Int, Int]], revision: Text}
GraphLayout     {schema: 1, revision: Text, preset: Text,
                 tags: [[Double, Double]], records: [[Double, Double]],
                 bounds: [Double, Double, Double, Double]}
View            {schema: 1, id, slug, name, kind: "graph"|"ledger",
                 is_default, definition: ViewDefinition, created_at,
                 updated_at}
ViewInput       {name, kind, definition, slug: Maybe Text}
ViewDefinition  graph: {query: Text, tags_shown: Bool,
                 label_mode: "auto"|"tags"|"none",
                 layout_preset: "compact"|"standard"|"airy",
                 local_depth: Maybe Int, color_groups: [ColorGroup]}
                ledger: {query: Text, sort: "created"|"added"|"opened"}
ColorGroup      {name, query, color: "#rrggbb", enabled: Bool}
CredentialInfo  {id: Text, nickname: Text, created_at: Int,
                 last_used_at: Maybe Int}
ImportReport    {found, http_anchors, unique_urls, inserted, existing,
                 duplicate_anchors, skipped_non_http, tags_created,
                 tag_links_added, folders_skipped, untagged, elapsed_ms}
Webhook         {id, name, url, events: [Text], enabled: Bool, created_at,
                 last_status: Maybe Int, last_attempt_at: Maybe Int,
                 last_error: Text, fail_streak: Int}
WebhookInput    {name, url, events: [Text], enabled: Bool}
DeliveryView    {id, event: Text, state: Text, attempts: Int,
                 last_error: Text, created_at: Int}
EventEnvelope   {id: Text, type: Text, occurred_at: Int, data: Value}
UserView        {id, username, role: "admin"|"member", created_at,
                 disabled_at: Maybe Int, last_login_at: Maybe Int}
UserCreateInput {username, password, role: "admin"|"member"}
UserCreateResult{user: UserView, recovery_codes: [Text]}
```

`created_at` is the original save date from `ADD_DATE` on import.
`added_at` is when eza first saw the row. The default sort is
`created_at DESC`.
