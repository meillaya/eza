# eza

eza stores bookmarks in SQLite and serves a searchable library from one
Haskell process. It is built for one person with thousands of links. The
reference database holds 8,988 bookmarks, 75 tags, and 21,316 tag links.

The client is Miso compiled to WebAssembly. The server owns the database,
WebAuthn passkeys, import and export, and the JSON API. There is no separate
database service.

## Run it

You need Nix and devenv.

```bash
devenv shell
bash scripts/build-web.sh
cabal run eza-bookmarks -- serve
```

Open <http://localhost:8080>. The first page is `/setup`: register a passkey
and save the ten recovery codes. This working copy contains `data/eza.db` with
the 2026-08-14 import and no registered passkey, so setup runs on the first
boot.

For a host other than localhost, set `PUBLIC_ORIGIN` and `EZA_RP_ID` before
you register a passkey. The origin is part of the credential, so changing it
later requires recovery or a new setup.

The same binary runs the import and maintenance commands:

```bash
eza-bookmarks import netscape bookmarks_14_08_2026.html --report dist/import.json
eza-bookmarks verify
eza-bookmarks backup
eza-bookmarks check-dead --limit 200
```

To build a database from scratch, run `eza-bookmarks init` before the import.
The import is idempotent: a second run reports `inserted=0`.

## How it fits together

One Warp/WAI process serves the client assets, the auth pages, and
`/api/v1`. Every API request passes a deny-by-default route table. Unsafe
methods also require the `X-CSRF-Token` header. SQLite runs in WAL mode with
FTS5 triggers over the title, description, URL, note body, and extracted text.
The CLI opens the same database file for import, export, verification, and
backup.

![Architecture: one process, one SQLite file](docs/figures/architecture.png)

The server owns the database, so the client never opens SQLite. The browser
sends JSON, the server writes through one connection, and the WAL checkpoint
keeps the file self-contained. The backup and snapshot commands read the live
database without stopping the server.

## Importing the reference export

The 2026-08-14 export contains 9,457 anchors. The importer skips 4 non-http
anchors, collapses 465 duplicate anchors, and writes 8,988 bookmarks, 75 tags,
and 21,316 tag links in one transaction. A second import writes nothing.

![Import: 9,457 anchors collapse to 8,988 rows](docs/figures/import.png)

Folder names become tags. `TAGS="a,b"` attributes are unioned with the folder
tags. The earliest `ADD_DATE` becomes `created_at`, and the import time
becomes `added_at`. Noise folders are skipped by default; `--keep-noise`
keeps them. See [docs/import.md](docs/import.md) for the counts and options.

## Search

Search parses `tag:`, `is:unread`, `is:dead`, `link:`, and `-term`, then
sends the remaining terms to FTS5. Tag filters run as an `AND` subquery over
`bookmark_tags`. Results order by `bm25(bookmarks_fts)`, then by
`created_at DESC`.

![Search: query parsing, FTS, tag filters, and rank](docs/figures/search.png)

The storage model and the equations are in
[docs/architecture.md](docs/architecture.md).

## Measured performance

On an AMD Ryzen 7 5700X with GHC 9.10.3 and `-O1`, against the 8,988-row
database, FTS queries had a p95 of 0.67 to 1.19 ms, and tag-filtered queries
had a p95 of 9.5 to 12.2 ms. Run the same benchmark with:

```bash
EZA_DATA_DIR=$PWD/data EZA_DB=$PWD/data/eza.db \
  cabal run eza-bookmarks -- bench --iterations 20
```

The method and raw output are in [docs/performance.md](docs/performance.md).
The import takes about 2.5 to 3.0 seconds on the same host.

## Deploy

The deployment flake builds the server, the NixOS module, and a local Docker
image. The Docker image runs as uid 10001, keeps state under `/data`, and uses
`eza-bookmarks healthcheck` for its health check. The Kubernetes manifests run
one replica with a ReadWriteOnce volume, because SQLite has one writer.

![Deployment: one binary across NixOS, Docker, and Kubernetes](docs/figures/deployment.png)

- [NixOS module and systemd unit](docs/deployment-nixos.md)
- [Docker image and compose](docs/deployment-docker.md)
- [Kubernetes manifests](docs/deployment-k8s.md)
- [Tailscale Serve and HTTPS](docs/tailscale.md)
- [SecretSpec and API keys](docs/secrets.md)

The flake has no devShell. Use `devenv.nix` for development and the flake for
deployment outputs. The release web-asset path expects a published
`eza-web-<version>.tar.gz` and its SRI hash; the local targets
(`.#eza-web-local`, `.#docker-local`) use `./static` and need no release
asset.

## Repository

| Path | Contents |
|---|---|
| `core/` | Shared types, JSON codecs, search parser, wikilinks |
| `server/` | Warp server, SQLite, WebAuthn, importer, CLI, tests |
| `web/` | Miso client |
| `static/` | CSS, auth pages, WASI loader, built WASM |
| `nix/` | NixOS module and vendored Cabal revisions |
| `deploy/` | Compose file and Kubernetes manifests |
| `docs/` | API, architecture, deployment, import, performance, figures |
| `tests/` | Fixtures and Playwright smoke tests |

## Tests

```bash
devenv shell -- cabal test all
EZA_IMPORT_FIXTURE=$PWD/bookmarks_14_08_2026.html \
  devenv shell -- cabal test all
devenv shell -- bash scripts/build-web.sh
devenv shell -- node tests/e2e/auth-smoke.mjs
devenv shell -- node tests/e2e/api-smoke.mjs
```

The Playwright scripts expect a server on the URL they print. Set
`EZA_BASE` to point them at another port.

## License

The project is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
