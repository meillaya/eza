<div align="center">

<h1 align="center">eza</h1>

<p align="center">A self-hosted library for the links you save: one server, a private library per account, a full-text index, and a catalogue printed for the browser.</p>

<p>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/meillaya/eza?style=flat-square&amp;label=license" alt="License"></a>
  <a href="https://www.haskell.org"><img src="https://img.shields.io/badge/Haskell-9.10-5e5086?style=flat-square&amp;logo=haskell&amp;logoColor=white" alt="Haskell"></a>
  <a href="https://haskell-miso.org"><img src="https://img.shields.io/badge/client-Miso%20%2B%20WASM-8a2b20?style=flat-square" alt="Miso and WebAssembly"></a>
  <a href="https://sqlite.org/fts5.html"><img src="https://img.shields.io/badge/storage-SQLite%20FTS5-003b57?style=flat-square&amp;logo=sqlite&amp;logoColor=white" alt="SQLite FTS5"></a>
</p>

<img src="docs/screenshots/library.png" alt="The ledger: a search line, provenance figures, year dividers and five column rows" width="100%">

</div>

eza keeps bookmarks in SQLite and serves searchable private libraries from one
Haskell process. A control database holds the account list, and every account
has its own SQLite library, username, password, optional passkeys and API
tokens. The reference library holds 8,988 bookmarks across 4,283 sources, filed
on 543 days between 2022 and 2026. Search runs on FTS5 and the client is Miso
compiled to WebAssembly.

The interface reads as a catalogue: a ledger of numbered accessions, a printed
record page for reading and notes, and an index page that counts the archive.
`/accessions` lays the whole library out by year and source from data the
server already computes.

---

## What you get

| Area | What it does |
|---|---|
| **Search** | `tag:`, `is:unread`, `is:dead`, `link:`, `year:`, `day:`, and `-term` operators over FTS5. The date operators use the UTC filing date. Results order by bm25, then save date. |
| **Ledger** | Year dividers, a provenance line, source and tag facets, a field drawer, bulk selection, and keyboard movement on `j` and `k`. |
| **Record** | Extracted reading copy, highlights with notes, markdown notes with `[[wikilinks]]`, backlinks, and a sandboxed snapshot viewer. |
| **Accessions** | The archive as an index: one mark per filing day, sources ranked with leader dots, and an honest long tail. A year, day or source opens the ledger filtered with `year:2025`, `day:2025-11-03`, or the source domain. |
| **Graph** | The whole library on one canvas: records, tags, resolved wikilinks and tag memberships, with pan, zoom, fit, a hover preview, a text filter, and a tags toggle. |
| **Upkeep** | Duplicate groups, tag consolidation, dead-link sweeps, and prune, each with an undo snapshot. |
| **Capture** | A Chromium MV3 clipper with Defuddle, a JSON-lines extraction sidecar, a bookmarklet, a PWA share target, quick-save and clip APIs, cached favicons, background extraction, and Netscape import. |
| **Sharing** | Signed read-only pages for a record or a saved search, plus Atom feeds. |
| **Access** | One private library per account with Argon2id password sign-in, login rate limiting, recovery codes, optional passkey second factors, admin and member roles, CSRF and origin checks, and hashed API tokens with read, write, and capture scopes. |
| **Ownership** | A control database and one SQLite library per account in WAL mode, online backups, a Docker image, a NixOS module, and Kubernetes manifests. |

<div align="center">

<img src="docs/screenshots/detail.png" alt="A record: the reading spread with marked passages beside the catalogue record card" width="100%">

<sub>A record keeps the reading copy, its marks, the note, and the filing facts together.</sub>

</div>

---

## Quick start

You need Nix and devenv.

```bash
devenv shell
bash scripts/build-web.sh
cabal run eza-bookmarks -- serve
```

Open <http://localhost:8000>. A fresh installation offers `/setup`, where the
first account claims the server with a username and password. That account is
an admin and receives ten recovery codes once; they are the way back in if the
password is forgotten. The admin adds the other accounts under Account > users,
or from the host by piping one password line into
`eza-bookmarks users add --username NAME --role member --password-stdin`.

Each account's password is stored as an Argon2id hash in that account's own
database and never in plaintext. Login attempts are limited per account and
client host (`EZA_LOGIN_MAX_ATTEMPTS`, `EZA_LOGIN_LOCKOUT_SECONDS`), session
lifetime is `EZA_SESSION_TTL_SECONDS`, and public auth POSTs check the request
`Origin`. The Argon2id cost defaults to 64 MiB, three passes, and two lanes;
`EZA_ARGON2_MEMORY_KIB`, `EZA_ARGON2_ITERATIONS`, and
`EZA_ARGON2_PARALLELISM` override it.

An account claimed before the password release keeps signing in with its
passkey. `/login` offers the passkey until a password is set; after that the
passkey is a legacy credential and `/api/auth/options` returns 403. On first
start, a claimed legacy `EZA_DB` file is registered as the first account in
place; an unclaimed file is left alone. An admin can set a temporary password
for another account under Account > users, or from the host with
`eza-bookmarks users reset-password NAME --password-stdin`.
`eza-bookmarks set-password --user NAME --reset-sessions` prompts twice with
the terminal echo off and targets one account's library.

For a host other than localhost, set `PUBLIC_ORIGIN` before claiming the first
account. Every passkey is bound to `PUBLIC_ORIGIN` and `EZA_RP_ID` at
registration time, so changing the origin later requires recovery.

The same binary runs the import and the maintenance commands:

```bash
eza-bookmarks init
printf '%s\n' "$EZA_USER_PASSWORD" | eza-bookmarks users add --username river --role member --password-stdin
eza-bookmarks users list
eza-bookmarks import bookmarks_14_08_2026.html --user river > dist/import.json
eza-bookmarks verify --user river
eza-bookmarks backup
eza-bookmarks export --user river > bookmarks.html
eza-bookmarks export --json --user river > eza-backup.json
eza-bookmarks enrich --all --user river
eza-bookmarks check-dead --limit 200 --user river
eza-bookmarks users disable river
```

The import is idempotent: a second run reports `inserted=0`, and `--user`
picks one account's library (a single-account installation falls back to its
only enabled account). The 2026-08-14
export contains 9,457 anchors; the importer skips 4 non-http anchors, collapses
548 anchors that normalize to the same URL, and writes 8,905 bookmarks, 74
tags, and 9,016 tag links in one transaction with the default leaf tag mode.
The historical 8,988-row reference database predates normalized deduplication,
so its counts are not directly comparable.

---

## How it fits together

One Warp and WAI process serves the client assets, the auth pages, the share
pages, and `/api/v1`. Accounts live in a control database that holds identity
only: username, role, database path, WebAuthn handle and login bookkeeping.
Each account's library is a separate SQLite file under `EZA_USERS_DIR`, so a
request resolves its account from the session cookie, pending cookie, share
token or API token prefix before it reads anything. Every API request passes a
deny-by-default route table, and unsafe methods also require the
`X-CSRF-Token` header. The server stores only Argon2id password hashes and
SHA-256 hashes of session and API tokens. SQLite runs in WAL mode with FTS5
triggers over the title, description, URL, note body, and extracted text. The
CLI opens the control database and, with `--user`, one account's library for
import, export, verification, backup, and repair.

<div align="center">

<img src="docs/figures/architecture.png" alt="Architecture: one process, one control database, one library per account" width="100%">

</div>

The interface is one stylesheet and one design document. Type, colour, spacing,
and components live in `static/eza.css`; the decisions are recorded in
[docs/UI.md](docs/UI.md).

---

## Performance

Measured on an AMD Ryzen 7 5700X with GHC 9.10.3 and `-O1`, against the
8,988-row database:

| Query | p95 |
|---|---|
| `all` | 3.99 ms |
| `fts-rust` | 0.85 ms |
| `fts-github` | 1.53 ms |
| `tag-imported` | 13.86 ms |
| `tag-imported-books` | 12.04 ms |

The ledger needs per year counts, so the page query also groups the filtered
rows by year in the same pass that produces the total. Search stays below
2 ms at p95; the slowest measured query is a tag filter over 8,790 records.
Run the same benchmark:

```bash
EZA_DATA_DIR=$PWD/data \
  cabal run eza-bookmarks -- bench --iterations 20 --user NAME
```

The method and raw output are in [docs/performance.md](docs/performance.md).

---

## Documentation

| Document | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Multi-user data layout, request path, import math, search model, storage invariants |
| [docs/API.md](docs/API.md) | Auth, accounts and roles, library, tags, maintenance, account, and DTO reference |
| [docs/extensions.md](docs/extensions.md) | Declarative views, signed webhooks, and the extension contract |
| [docs/UI.md](docs/UI.md) | Tokens, type, layout, screens, keyboard, accessibility, voice |
| [docs/import.md](docs/import.md) | Netscape import rules and the reference result |
| [docs/clipper.md](docs/clipper.md) | Browser extension, clip API, extraction sidecar, and templates |
| [docs/performance.md](docs/performance.md) | Benchmark method, raw output, and limits |
| [docs/figures](docs/figures/README.md) | Excalidraw sources, generator, and render script |

Deployment guides sit beside them: [NixOS](docs/deployment-nixos.md),
[Docker and Compose](docs/deployment-docker.md),
[Kubernetes](docs/deployment-k8s.md), [Tailscale](docs/tailscale.md), and
[SecretSpec](docs/secrets.md).

## Keyboard shortcuts

| Key | Action |
|---|---|
| `/` | Focus the search line |
| `Shift+K`, `Cmd+K`, `Ctrl+K` | Open the command palette from any screen (`Ctrl/Cmd+K` works while the search line has focus) |
| `j`, `k` | Move the ledger cursor; bare `k` opens the palette away from the ledger and inbox |
| `Enter` | Open the record under the cursor |
| `+`, `-` | Zoom the graph in and out |
| `0`, `f` | Fit the whole graph in the canvas |
| Arrow keys | Pan the graph |
| `Esc` | Close the palette, drawer, or dialog; on the graph, clear the filter and selection |
| `Cmd+S`, `Ctrl+S` | Save the note on the record page |

The hint under the search line is a `⇧K` button. `Sign out` lives at the end of
the section links, in the mobile bar, on every account tab, and in the palette;
an unsaved note asks for confirmation first.

---

<div align="center">
<sub>Apache-2.0 · Built with Haskell, Miso, SQLite, and Nix · <a href="THIRD-PARTY-NOTICES.md">Third-party notices</a></sub>
</div>
