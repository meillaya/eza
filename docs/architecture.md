# Architecture

eza runs one Haskell process, serves one WebAssembly client, and stores each
account's rows in its own SQLite file behind a shared control database. This
document explains the data layout, the request path, the import math, the
search model, and the deployment shape.

## One process, one control file, one library per account

A Warp/WAI process owns the HTTP surface. It serves `/assets/*` from
`EZA_STATIC_DIR`, renders the login/setup/recovery pages, and answers
`/api/v1/*` for every account.

Data lives in two shapes under `EZA_DATA_DIR`:

```
control.db                     accounts: username, role, db_path, handle, state
users/<id>/eza.db              one account's library (the full schema)
users/<id>/snapshots/          that account's captured pages
backups/<stamp>/control.db          a backup run's control database
backups/<stamp>/manifest.json       accounts captured by that run
backups/<stamp>/users/<id>/eza.db   a backup run's library files
```

`control.db` (`EZA_CONTROL_DB`) holds identity only: a row per account with a
unique case-insensitive username, an `admin`/`member` role, the path to the
account's library, a per-account WebAuthn user handle, and timestamps for
creation, disablement, and last login. `users/<id>/eza.db` (`EZA_USERS_DIR`)
holds everything else. Requests open library databases lazily: a per-account
slot owns one write connection behind an `MVar`, a small read-only pool for
GET/HEAD, and a graph layout cache, with the number of open slots capped by
`EZA_MAX_USERS`.

Every API route passes the table in `Eza.Server`. The table is deny-by-default
and `Eza.Authz` is the single classification and scope matrix, so a new route
without a guard returns 401 and admin routes accept only admin browser
sessions. Unsafe methods also require the `X-CSRF-Token` header. Session,
pending, share, and API tokens carry the owning account id in their prefix
(`u<id>_...`, `eza_pat_u<id>_...`); the guard resolves that id through the
control database and then verifies the token hash in that account's library,
so a rewritten prefix fails. A token without a prefix is accepted only while
exactly one enabled account exists, which keeps pre-M3 sessions working after
the startup migration. The control database is never a content path: handlers
only ever see the signed-in account's connection.

Login resolves the username through the control database. An unknown or
disabled username pays a dummy Argon2 hash and returns the same generic 401 as
a wrong password, and attempts are capped per client host and username. Each
account stores its Argon2id password hash and only the SHA-256 hash of each
session token, and its own login counters in `app_state`. A password account
can register passkeys and enable a second factor; a password login then
returns a short-lived pending session and requires a WebAuthn assertion before
a normal session is created. Pending scopes cannot reach `/api/v1`. Recovery
requires a username and clears that account's password, passkeys, and flag.

Startup migration: when the control database has no rows and `EZA_DB` exists
with a claimed account, that file is registered as user 1 with the admin role
in place, with no copy or move; removing `control.db` rolls the registration
back. An unclaimed legacy file is left alone. Otherwise the first
`/setup` claims a fresh account under `users/<id>/`.

Background work is per account. Opening an account database starts its
enrichment claimers, webhook delivery worker (each database has its own
outbox and cursor), and one favicon backfill loop. The favicon loop works
per source domain, not per bookmark: cached domains are applied with one
`UPDATE bookmarks SET favicon_url = ... WHERE domain = ?`, and a domain with
no cached icon costs at most a few conventional icon fetches, so a site with
500 links costs one lookup. Domains with the most unfilled bookmarks go first,
icon bodies are size-capped and sniffed, and three failures park a domain.
`EZA_ENRICH_WORKERS` is a process-wide semaphore shared by both loops;
`EZA_FAVICON_BACKFILL=0` disables the icon loop. A disabled account's workers
stop on the next supervisor tick. Expired sessions are swept when a database
opens and once a day after.

![Architecture: one process, one control database, one library per account](figures/architecture.png)

The CLI commands (`import`, `export`, `enrich`, `verify`, `backup`,
`check-dead`, `set-password`) accept `--user <name|id>`; without it they use
the only enabled account (a control database with no rows falls back to the
legacy `EZA_DB` path). `eza-bookmarks users list|add|enable|disable|reset-password|delete`
manages accounts, `init` creates the control schema, and `set-password`
prompts twice with the terminal echo off, so the password never reaches argv.
`backup` copies the control database and every account library (disabled
accounts included; page snapshots are not part of a stamp) into one verified
stamp directory. `restore STAMP --yes`, run with the server stopped, validates
the stamp, backs up the current installation, copies each library to its
control row's path, and rewrites those paths when the data root moved; old
flat stamps (`users/<id>.db`) are accepted. SQLite serializes the writers per
file, so a running server and a one-off CLI command do not corrupt a library
database.

## Import math

The reference export contains `A = 9457` anchors. The importer keeps the
http(s) subset `H = 9453`, skips `N = 4` non-http anchors, and collapses
`D = 548` anchors that normalize to the same URL. The unique bookmark count is

```
U = H - D = 9453 - 548 = 8905
```

The tag links come from the folder stack and the `TAGS` attribute. For each
bookmark `b`, let `T_b` be its tag set. With the default leaf mode the stored
link count is

```
L = sum over b of |T_b| = 9016
```

The importer writes the rows, tags, and links in one transaction. A second run
matches all 8,905 URLs and inserts zero rows. The tag counts are mode-dependent;
the historical 8,988-row reference database was imported before normalized
deduplication and before the leaf-only rule, so its 21,316 links are not
directly comparable.

![Import: 9,457 anchors collapse to 8,905 rows](figures/import.png)

Two timestamps matter. `created_at` is the earliest `ADD_DATE` for the URL,
which preserves when the bookmark was saved. `added_at` records when eza first
saw the row, and the prune view uses it.

## Capture and extraction

The browser extension extracts the current page with Defuddle and sends a
typed `ClipRequest` to `POST /api/v1/clip`. The server normalizes the URL,
inserts or finds the bookmark, writes a `captures` row, applies clip templates
and save rules, and stores the rendered Markdown as the note. Capture tokens
are scoped to whoami/clip/template reads; template writes need a session.
Idempotency keys make extension retries safe.

The in-process TagSoup extractor remains the default for background
enrichment. When `EZA_DEFUDDLE_CMD` is set, `Eza.Enrich` first sends the page
through the JSON-lines Node/Defuddle sidecar and falls back to the Haskell
extractor on any error. The sidecar has no network access and a 5 MiB/15 s
limit. Schema v7 adds the lossless undo side tables; v8 adds `captures` and
`clip_templates`; v12 extends the side snapshot to `captures`, so undoing a
delete, prune, or merge brings the clipped content back too. The restore path
re-enables `recursive_triggers` and rebuilds the FTS index, so an undo cannot
leave stale terms behind.

## Search model

The parser in `Eza.SearchQuery` splits a query into a text part and a set of
filters. Free-text terms match the FTS index and, as a fallback, tag names, so
`rust` finds records filed under the `rust` tag even when no indexed field
contains the word; FTS hits rank first:

```
tag:<name>       exact tag filter
is:unread        is_read = 0
is:dead          is_dead = 1
link:<url>       outgoing wikilink target
-term            excluded term
```

For the text terms `t_1 ... t_k`, the server builds an FTS5 prefix expression:

```
match = "t_1"* AND ... AND "t_k"*
```

Each `tag:` filter adds a predicate over the join table. With `m` tag
filters, the predicate is

```
COUNT(DISTINCT bookmark_tags.tag_id) = m
```

The result order is

```
ORDER BY bm25(bookmarks_fts), bookmarks.created_at DESC
```

FTS5 computes `bm25` over the five indexed columns. The server then opens a
snippet window around the first matching term and returns at most the requested
page size.

![Search: query parsing, FTS, tag filters, and rank](figures/search.png)

The measured p95 on the 14,582-row scratch copy (the dataset used by
[performance.md](performance.md)) is 0.92 to 2.00 ms for FTS queries and 11.15
to 13.34 ms for tag-filtered queries on an AMD Ryzen 7 5700X with GHC 9.10.3
and `-O1`. The 8,988-row historical reference database predates the current
import rules and is not the benchmark dataset.

## Storage invariants

SQLite runs with WAL, foreign keys, and a five-second busy timeout. The schema
creates FTS5 with the `porter unicode61` tokenizer and keeps it in sync with
insert, update, and delete triggers.

The triggers compare only `title`, `description`, `url`, `note_body`, and
`extracted_text`. Updating `is_read` or `last_opened_at` does not rewrite the
index.

Destructive actions write an undo snapshot first. The snapshot stores the full
`bookmarks` row, the tag names for the affected rows, highlights, wikilinks,
and (v12) the clipped `captures` rows. `POST /api/v1/undo`
restores the most recent snapshot and deletes the snapshot row. The UI asks for
confirmation before merge or prune, and the API applies one snapshot at a time.

## Serving and caching

Static files are served from `EZA_STATIC_DIR`: pages at `/`, a fixed entry at
`/assets/app/index.js`, the WASM bundle, the stylesheet, and the fonts. Every
static response carries an ETag and `Cache-Control: no-cache`, so a browser
revalidates after a rebuild and gets a 304 when the file did not change. The
client shell is sent with `no-store`: the HTML always comes from the server.

`/sw.js` is generated per request with the build id that
`scripts/build-web.sh` writes to `static/app/build-id`. A rebuild therefore
installs a new service worker; the worker claims the open pages, and each tab
reloads once into the new build. A port that is already taken reports the
origin that is probably answering instead of a raw socket error.

## Deployment shape

All deployment targets run the same `eza-bookmarks` binary. The NixOS module
wraps it in a hardened systemd unit with `StateDirectory=eza`, a
SecretSpec-wrapped `ExecStart`, a `/healthz` probe, and a daily backup timer.
The Docker image runs as uid 10001 with `/data` as the state volume. The
Kubernetes manifests use one replica, a `Recreate` strategy, and a
`ReadWriteOnce` `PersistentVolumeClaim`.

![Deployment: one binary across NixOS, Docker, and Kubernetes](figures/deployment.png)

Tailscale Serve or Caddy terminates HTTPS in front of the process. Set
`PUBLIC_ORIGIN` to the public hostname before claiming the library. A legacy
passkey is bound to `PUBLIC_ORIGIN` and `EZA_RP_ID` at registration time, so
keep both stable while a passkey is still in use.

## What the design leaves out

SQLite has one writer per file and the control database adds one more writer,
so the deployment uses one replica. A second pod would contend for the same
file locks. Account creation, role changes, enable/disable, and temporary
passwords are available to an admin in the web client's Account > users tab,
through the admin API, and from the `users` CLI. Backup and restore remain
operator actions; the web client has no backup screen.

The client reads all data through the API: lists, detail views, and search
results come from the server. This keeps one data model.

The 2026-08-14 export seeded the new schema.
