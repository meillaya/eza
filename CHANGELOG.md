# Changelog

All notable changes to eza are recorded here. The container image and the Nix
outputs are the installable artifacts; both are built from the same revision.

## 0.4.0.0 (unreleased)

The 0.4 line is the architecture program: the same feature set, a typed
server/client boundary, one error representation, checksummed migrations, a
journal instead of per-feature undo tables, asynchronous egress jobs, and a
smaller deployment surface. It is a **one-way** upgrade from 0.3.

### Architecture

- `Eza.Routes` is the single route truth (method, path template,
  authorization class, capability); the server parses a request once and
  dispatches to `Eza.Api.*`, and `Eza.Authz` is derived from the same table.
  Unknown API paths are JSON 404 and a known path with a wrong method is JSON
  405 with `Allow`.
- Every JSON error body is core `Eza.Problem` (`{"error":{"code","message"}}`);
  uncaught exceptions become JSON 500 and SQLite busy/locked becomes JSON 503.
- `Eza.Library` owns the writer, read-only pool, layout cache and workers;
  authentication validates on the read pool and only touches activity
  timestamps at most once a minute.
- The client state, routes, request algebra and all reducers moved to the
  native `eza-web-logic` package; `web` is the Miso shell (views, effects,
  interpreter). The client decodes strictly, carries `wire_version` in the
  boot payload and refuses to paint on a mismatch.
- The web bundle is content-addressed with one `asset-manifest.json`; the
  shell, auth pages and service worker all read it. The WASM client is built
  inside Nix from pinned sources.

### Data

- Schema v16 adds `schema_meta` with a sha256 checksum per migration; a
  checksum or version mismatch refuses to open the database, and an older
  binary refuses a newer schema. `eza-bookmarks verify` checks the control
  schema and every account library as well as the FTS index.
- Schema v17 replaces the eight undo side tables and the legacy JSON undo
  payload with `journal`/`journal_rows`: before-images are recorded in the
  write transaction, the journal keeps the newest 100 changes, and an undo
  restores newest-first with URL-conflict refusal and an FTS rebuild.
- Schema v18 adds the async job payload/result columns used by the egress
  workers; the legacy undo history is not migrated (it is ephemeral).

### CLI and probes

- `eza-bookmarks version`, the boot payload version and `/healthz` now report
  the release version (checked against the Cabal/flake version by
  `scripts/version.sh`) instead of a hardcoded 0.1.0. The container image
  puts `eza-bookmarks` on `PATH`, so `docker exec <container> eza-bookmarks …`
  works as documented; `docker load` tags the local image
  `localhost/eza:<version>`.

### API

- `POST /api/v1/bookmarks/{id}/snapshot`, `POST /api/v1/maintenance/check-dead`,
  `POST /api/v1/ai/suggestions` and `POST /api/v1/webhooks/{id}/test` now
  enqueue a durable job and return 202 with a job id; the side-effecting GET
  forms are removed.
- `GET /api/v1/jobs/{id}` returns the job state, attempts, result and error for
  the caller's own library. Network and subprocess work no longer runs in a
  request handler.
- Undo DTOs keep their wire shapes.

### Deployment

- Removed the Kubernetes manifests and docs, the rclone offsite backup option
  and the Tailscale Serve front end. Docker/Compose, the NixOS module and Caddy
  remain supported.
- One-way upgrade: back up, stop the old instance, start the new binary once
  (it migrates control v1 to v2 and each library to the current schema), then
  run `eza-bookmarks verify`. See [docs/upgrade.md](docs/upgrade.md).

## 0.2.0.0

- Initial public release: Warp server, Miso/WASM client, per-account SQLite
  libraries, FTS5 search, passkeys, sharing, import/export, graph, views,
  webhooks, favicons, captures and the browser clipper.
