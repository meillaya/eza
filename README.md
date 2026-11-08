<div align="center">

<h1 align="center">eza</h1>

<p align="center">A self-hosted library for the links one person saves: one SQLite file, a full-text index, and a catalogue printed for the browser.</p>

<p>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/meillaya/eza?style=flat-square&amp;label=license" alt="License"></a>
  <a href="https://www.haskell.org"><img src="https://img.shields.io/badge/Haskell-9.10-5e5086?style=flat-square&amp;logo=haskell&amp;logoColor=white" alt="Haskell"></a>
  <a href="https://haskell-miso.org"><img src="https://img.shields.io/badge/client-Miso%20%2B%20WASM-8a2b20?style=flat-square" alt="Miso and WebAssembly"></a>
  <a href="https://sqlite.org/fts5.html"><img src="https://img.shields.io/badge/storage-SQLite%20FTS5-003b57?style=flat-square&amp;logo=sqlite&amp;logoColor=white" alt="SQLite FTS5"></a>
</p>

<img src="docs/screenshots/library.png" alt="The ledger: a search line, provenance figures, year dividers and five column rows" width="100%">

</div>

eza keeps bookmarks in SQLite and serves a searchable library from one Haskell
process. The reference database holds 8,988 bookmarks across 4,283 sources,
filed on 543 days between 2022 and 2026. Search runs on FTS5, the client is
Miso compiled to WebAssembly, and one username and password open the library.

The interface reads as a catalogue: a ledger of numbered accessions, a printed
record page for reading and notes, and an index page that counts the archive.
`/accessions` lays the whole library out by year and source from data the
server already computes.

---

## What you get

| Area | What it does |
|---|---|
| **Search** | `tag:`, `is:unread`, `is:dead`, `link:`, and `-term` operators over FTS5. Results order by bm25, then save date. |
| **Ledger** | Year dividers, a provenance line, source and tag facets, a field drawer, bulk selection, and keyboard movement on `j` and `k`. |
| **Record** | Extracted reading copy, highlights with notes, markdown notes with `[[wikilinks]]`, backlinks, and a sandboxed snapshot viewer. |
| **Accessions** | The archive as an index: one mark per filing day, sources ranked with leader dots, and an honest long tail. |
| **Upkeep** | Duplicate groups, tag consolidation, dead-link sweeps, and prune, each with an undo snapshot. |
| **Capture** | A Chromium MV3 clipper with Defuddle, a JSON-lines extraction sidecar, a bookmarklet, a PWA share target, quick-save and clip APIs, cached favicons, background extraction, and Netscape import. |
| **Sharing** | Signed read-only pages for a record or a saved search, plus Atom feeds. |
| **Access** | Argon2id password sign-in with login rate limiting, recovery codes, optional passkey second factors, CSRF and origin checks, and hashed API tokens with read, write, and capture scopes. |
| **Ownership** | One SQLite file in WAL mode, online backups, a Docker image, a NixOS module, and Kubernetes manifests. |

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

Open <http://localhost:8000>. A fresh database offers `/setup`, where one
username and password claim the library. The recovery codes shown once at setup
are the way back in if the password is forgotten.

The password is stored as an Argon2id hash and never in plaintext. Login
attempts are limited (`EZA_LOGIN_MAX_ATTEMPTS`, `EZA_LOGIN_LOCKOUT_SECONDS`),
session lifetime is `EZA_SESSION_TTL_SECONDS`, and public auth POSTs check the
request `Origin`. The Argon2id cost defaults to 64 MiB, three passes, and two
lanes; `EZA_ARGON2_MEMORY_KIB`, `EZA_ARGON2_ITERATIONS`, and
`EZA_ARGON2_PARALLELISM` override it.

A library claimed before the password release keeps signing in with its
passkey. `/login` offers the passkey until a password is set; after that the
passkey is a legacy credential and `/api/auth/options` returns 403. To set or
reset the password from the host, run `eza-bookmarks set-password`. It prompts
twice with the terminal echo off, so the password never appears in argv or a
shell history.

For a host other than localhost, set `PUBLIC_ORIGIN` before claiming the
library. A legacy passkey is bound to `PUBLIC_ORIGIN` and `EZA_RP_ID` at
registration time, so changing the origin later requires recovery.

The same binary runs the import and the maintenance commands:

```bash
eza-bookmarks init
eza-bookmarks import bookmarks_14_08_2026.html > dist/import.json
eza-bookmarks verify
eza-bookmarks backup
eza-bookmarks export > bookmarks.html
eza-bookmarks export --json > eza-backup.json
eza-bookmarks enrich --all
eza-bookmarks check-dead --limit 200
eza-bookmarks set-password --reset-sessions
```

The import is idempotent: a second run reports `inserted=0`. The 2026-08-14
export contains 9,457 anchors; the importer skips 4 non-http anchors, collapses
548 anchors that normalize to the same URL, and writes 8,905 bookmarks, 74
tags, and 9,016 tag links in one transaction with the default leaf tag mode.
The historical 8,988-row reference database predates normalized deduplication,
so its counts are not directly comparable.

---

## How it fits together

One Warp and WAI process serves the client assets, the auth pages, the share
pages, and `/api/v1`. Every API request passes a deny-by-default route table.
Unsafe methods also require the `X-CSRF-Token` header. The single account signs
in with a username and password; the server stores only the Argon2id hash and
the SHA-256 hash of each session token. SQLite runs in WAL mode
with FTS5 triggers over the title, description, URL, note body, and extracted
text. The CLI opens the same database file for import, export, verification,
and backup.

<div align="center">

<img src="docs/figures/architecture.png" alt="Architecture: one process, one SQLite file" width="100%">

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
EZA_DATA_DIR=$PWD/data EZA_DB=$PWD/data/eza.db \
  cabal run eza-bookmarks -- bench --iterations 20
```

The method and raw output are in [docs/performance.md](docs/performance.md).

---

## Documentation

| Document | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Request path, import math, search model, storage invariants |
| [docs/API.md](docs/API.md) | Auth, library, tags, maintenance, account, and DTO reference |
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
| `Esc` | Close the palette, drawer, or dialog |
| `Cmd+S`, `Ctrl+S` | Save the note on the record page |

The hint under the search line is a `⇧K` button. `Sign out` lives at the end of
the section links, in the mobile bar, on every account tab, and in the palette;
an unsaved note asks for confirmation first.

---

<div align="center">
<sub>Apache-2.0 · Built with Haskell, Miso, SQLite, and Nix</sub>
</div>
