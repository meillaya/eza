# Changelog

All notable changes to eza are recorded here. The container image and the Nix
outputs are the installable artifacts; both are built from the same revision.

## Unreleased

### Browser extension

- The clipper is now one Chrome and Firefox extension. `extension/build.mjs`
  writes a Chrome MV3 service-worker manifest and a Firefox MV3 event-page
  manifest with `browser_specific_settings`, and packages both store ZIPs; the
  plain build has no runtime dependencies, no remote code and no content
  scripts.
- The toolbar icon shows a small check and a "in your library" tooltip when the
  active page is already saved. It is backed by the new capture-read
  `GET /api/v1/bookmarks/lookup` route, which returns only the bookmark summary
  for the exact normalized URL.
- The popup is an **Add bookmark** action (`POST /api/v1/quick-save`) with
  editable title and tags, an **Open in eza** link, and an optional **Add page
  text** capture that runs only on request. The options page adds a
  saved-page check toggle, a lookup-aware connection test and a token-creation
  link.
- The browser extension has app icons (16/32/48/128), store listing and
  permission-justification docs, a privacy policy, and CI/release ZIP
  artifacts. Firefox declares its data collection and asks for page-content
  consent at runtime. The Chrome build is listed in the
  [Chrome Web Store](https://chromewebstore.google.com/detail/eza-clipper/hdbgombaclbiolmememmjciigpfepghp).
- The in-app add action is renamed from "File a record" to **Add bookmark**
  across the dialog, `/save` page, mobile action, command palette and
  bookmarklet copy. The archive's "filing days" language is unchanged.

### Client polish

- The record tag row aligns the tag pills and the **+ tag** field on one
  baseline, and the add field uses a subtle dashed outline instead of the
  browser's input frame.
- The command palette lists commands, saved searches and actions only. It no
  longer mixes recent records into the slip, so the list stays scannable;
  record lookup stays on the search line and the ledger.
- The graph filter and saved graph-view queries use the shared search grammar:
  `tag:`, `year:`, `day:`, `is:unread`, `is:dead` and `-term` behave like the
  ledger instead of silently matching nothing.
- The prune "click again to confirm" arm is cleared by any selection change, so
  the second click can only confirm the set the user armed.
- The single-record delete dialog no longer claims the action cannot be undone;
  it matches the journaled undo and the bulk dialog.
- Webhook create, view save and the bulk actions are busy-guarded, so a double
  click does not send a duplicate write.
- Toast placement and the focus rings on the search line, palette and note
  editor are restored (an undefined CSS variable and later `outline: 0` rules).
- Webhook test failures are visible per webhook (the failure carries the
  webhook id and clears on retry/success; an abandoned test reports
  "cancelled").
- An AI provider status failure shows an inline error with a retry action
  instead of leaving a stale or empty status.
- The snapshot viewer has a "snapshot unavailable" state with retry and a
  "capture a snapshot" action (reusing the existing job); a "capture again"
  action covers missing or expired files that a sandboxed iframe cannot
  detect.
- Share revoke and suggestion apply are busy-guarded, so repeated clicks do
  not send duplicate requests.
- Removed never-constructed `OpenToggled`/`ApiUnauthorized` actions and the
  write-only highlights-loading/snapshot-job fields.
- A failed saved-search background refresh keeps the previous list and raises
  one toast until a successful refresh.
- Every non-journaled destructive action now asks first: view delete, rule
  delete, webhook delete, API-token revoke, passkey delete and recovery-code
  regeneration share one top-most confirmation layer.
- The undo preview is request-scoped, so a cancelled or superseded inspection
  cannot re-open itself or undo a different snapshot than the one shown.
- Webhook-test and AI-suggestion busy state is per row; the AI status failure
  shows one explanation and one retry control; the account forms submit through
  their reducers, so Enter no longer reloads the page.
- Runtime OS theme changes reach the client model and canvas, and both
  `theme-color` metas are kept in step; the install button sits above the mobile
  tab bar; `/save` falls back to the offline shell instead of the network-error
  page; `Esc` always closes the top-most layer (dirty guard first); highlighted
  passages in the reader open their editor.
- Returning to a record with unsaved note edits no longer refetches over them;
  a boot payload that fails to decode shows the protocol-mismatch page instead
  of a generic error; saved-search apply clears stale tag facets; the pending
  search debounce is cancelled on navigation; nine never-constructed actions
  were removed.
- The account panel shows the temporary password and the rotated recovery codes
  after an admin password reset (they are returned once), and the export panel
  gained a Markdown notes download.

### Server

- The egress worker claims one job per iteration. It used to claim one job per
  kind and run only the first, leaving the other kinds `running` forever; the
  stuck job then replied to dedupe and a process restart was the only recovery.
- `EZA_LOG_LEVEL=debug` no longer selects the wai-extra detailed logger, which
  printed request bodies and parameters (plaintext passwords, recovery codes)
  into stdout. Debug and info both log one access line without bodies.
- Password login folds the username case like the control-database lookup, so
  a mixed-case sign-in no longer fails and counts toward the lockout.
- The clipper's quick-save route is part of the clip CORS family, and clip
  error/413 responses carry the CORS headers the preflight promises.
- Worker catch-all handlers rethrow asynchronous cancellation, so disabling an
  account or shutting down with a job in flight cannot hang the supervisor.
- The JSON export writes saved-search tags and rule add-tags as arrays (legacy
  string documents still import), so a portable backup no longer silently
  drops every saved search and rule.
- Dedupe merge keeps the earliest non-zero filing date; an undated duplicate no
  longer zeroes the keeper's `created_at`.
- Egress jobs retry transient failures with the bounded backoff, stale
  `running` jobs are requeued after a crash or long stall, finished jobs are
  pruned on a timer, and a new `POST /api/v1/jobs/{id}/cancel` sets the
  cooperative cancel flag for a queued/running job.
- A recovery session reaches only setup, logout and the account summary; a
  completed recovery setup revokes every session (single use); the first-setup
  claim is atomic, so concurrent first requests create exactly one admin.
- Disabled and deleted accounts release their user slots, so `EZA_MAX_USERS`
  counts live slots instead of historical accounts; the last admin delete and
  the admin password reset are atomic, and a reset rotates the recovery codes
  and returns them once.
- Public share pages use the manifest-hashed asset URLs, stable `/favicon.svg`
  and `/theme.js` revalidate instead of being cached immutably, `GET
  /api/v1/export/notes` serves the Markdown notes document instead of 501, and
  `EZA_SHARE_TTL_DAYS` is clamped to 1-365 with a startup warning.
- `HEAD` mirrors `GET`, `OPTIONS` answers with `Allow` on every known path, and
  known non-API paths with the wrong method return 405 with `Allow`.
- The backup stamp-directory retry is bounded, and a partial `restore --user`
  keeps uncaptured accounts and carries current accounts instead of deleting or
  relinking control rows silently.
- The portable JSON import is atomic for bookmarks, highlights, captures,
  saved searches and rules, enqueues enrichment for inserted records, validates
  every imported URL against the http(s) policy, and reports honest
  inserted/existing/skipped counts; undo no longer wedges when a clip template
  was deleted before the capture row is restored.
- Response DTOs decode strictly (a missing or renamed field fails instead of
  defaulting), while create bodies keep their documented defaults; `isHttpUrl`
  rejects empty, dot-only or credential hosts and whitespace.

### Repository

- `AGENTS.md` is tracked again: the project knowledge base is part of the
  checkout and validated by `scripts/check-docs.sh`.
- The docs/CI gates now catch what they claim: `check-docs.sh` checks local
  images and links (new `check-doc-links.py`), `check-notices.sh` covers the
  `hackagePkgWith` pins (20 instead of 18), `check-specs.sh` validates every
  `spec/bad` fixture including `bad-slug.json`, and CI lint includes
  `web-logic`.
- Docs follow 0.4: the webhook-test 202 job flow, healthz examples, compose
  provenance/data layout, release-image dispatch (builds the release tag and
  checks the commit), and the command-palette description.
- The add-passkey e2e script now asserts page render and the credential count
  instead of exiting 0 without checks.
- The webhook/view JSON Schemas now describe the documents the server stores and
  exports (ids, timestamps, nullable `local_depth`, webhook delivery fields) as
  well as the create payloads; stored-wrapper fixtures and boundary counter-
  examples are validated by `scripts/check-specs.sh`, and the webhook URL
  pattern matches the stricter runtime policy.
- `docs/performance.md` separates the historical pre-0.4 benchmark run from the
  current 0.4 account-library path and bundle numbers; the docs/figures removal
  left no dangling references.
- CI gained a manual/weekly `nixos-vm` job (the module VM test needs KVM, so it
  is not on every pull request), and the release-image workflow already builds
  and verifies the release tag.
- The e2e suite covers the new confirmation layer for view/rule deletion and
  token revocation (cancel then confirm).
- The generated architecture/import/search figures and the README wordmark
  generators were removed from the repository; the README uses a plain text
  wordmark and the architecture page relies on its prose. `docs/figures` is no
  longer part of the tree.

## 0.4.0.0

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
