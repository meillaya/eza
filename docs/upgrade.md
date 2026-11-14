# Upgrading to 0.4

0.4 keeps every shipped feature, the SQLite data model, the HTTP surface's
success payloads and the WebAuthn scope, but it is a **one-way** upgrade:

- The new binary migrates the control database and each account library on
  first start.
- The old binary refuses the migrated databases ("schema is newer than this
  binary"). Rolling back means restoring the backup you took before the
  upgrade, not starting the old binary against the new data.
- Legacy undo history is ephemeral and is not carried across the journal
  migration; the library rows themselves are untouched.
- The Kubernetes manifests, the rclone offsite backup option and the Tailscale
  Serve front end were removed. Docker/Compose, the NixOS module and Caddy
  remain supported; move an existing deployment to one of those before
  upgrading if it relied on a removed branch.

## Schema and version map

| Release | Control schema | Library schema | Notes |
|---|---|---|---|
| 0.3.x | 1 | 15 | flat sessions/tokens, per-feature undo tables |
| 0.4.x | 2 | 18 | checksummed migrations, journal, async jobs |

`eza-bookmarks version` prints the binary version and
`eza-bookmarks verify` prints the schema version of the control database and
each account library.

## Before you start

1. Stop the server (and the backup timer if you enabled one).
2. Take a backup with the **old** binary:
   `eza-bookmarks backup`. It writes a stamp directory with `control.db`,
   `manifest.json` and every account library (`users/<id>/eza.db`); page
   snapshots are not part of a stamp.
3. Copy the stamp off the host (for example `docker cp`, `rsync`, or the
   volume snapshot facility of your provider). The upgrade writes a
   pre-migration backup per library automatically, but a full stamp is the
   rollback path.
4. Keep `PUBLIC_ORIGIN` and `EZA_RP_ID` unchanged. Passkeys are bound to them;
   changing either requires recovery.

## Docker / Compose

```bash
# with the old container still running: take the stamp
docker exec eza eza-bookmarks backup

# copy the stamp off the host
docker cp eza:/data/backups/<stamp> /backup/

# replace the image (same volume, same PUBLIC_ORIGIN / EZA_RP_ID)
docker compose pull eza
docker compose up -d eza

# first start migrated the data; check it
docker exec eza eza-bookmarks verify
```

The Compose file keeps the named `eza-data` volume; do not recreate it. If you
run the container with `--read-only --tmpfs /tmp`, keep those flags: the
migration needs write access to the volume only.

## NixOS module

```bash
# as the eza user: take the stamp before switching the generation
sudo -u eza eza-bookmarks backup

# switch to the new flake revision
sudo nixos-rebuild switch --flake .#host

# the unit migrated the data on start
sudo -u eza eza-bookmarks verify
curl -fsS http://127.0.0.1:8080/healthz
```

`services.eza.backup.enable = true` keeps the daily stamp timer. The timer is
not the upgrade backup: take one explicitly before the switch.

## Source / devenv

```bash
# with the old checkout running
devenv shell -- eza-bookmarks backup   # or ./result/bin/eza-bookmarks backup

git fetch --tags && git checkout v0.4.0.0
devenv shell -- build
devenv shell -- eza-bookmarks verify
devenv shell -- dev
```

Set `EZA_DATA_DIR` and `EZA_STATIC_DIR` exactly as the old process used them.

## What the migration does

- Control database v1 -> v2: adds `schema_meta` and records the checksum of
  the control migrations. Accounts, roles, database paths and WebAuthn handles
  are preserved.
- Each account library v15 -> v18:
  - v16 adds `schema_meta` and backfills checksums for the migrations that were
    already applied, without re-running them.
  - v17 creates `journal`/`journal_rows`, records before-images in future
    writes and drops the legacy `undo_*` tables. The old undo history is not
    carried over.
  - v18 extends `jobs` with the payload/result columns for asynchronous egress;
    running jobs are reset to queued on start and resume.
- A `VACUUM INTO` pre-migration backup is written for every migrated library
  (next to the database and under `EZA_BACKUP_DIR` when set). Keep it until
  `verify` passes and spot checks of the UI look right.

Migrations run once and are checksummed: editing, renaming or reordering a
shipped migration makes the binary refuse the database. Upgrade forward, never
patch the schema by hand.

## Verifying the upgrade

```bash
eza-bookmarks verify
```

It checks, for the control database and every account library:

- the schema version against the plan and the sha256 history in `schema_meta`;
- the SQLite integrity check;
- the FTS index integrity and the row counts.

Then check the UI: sign in, open a record, run a search, open the undo history
(the journal starts empty, so the first destructive action creates the first
entry), and trigger one async job (snapshot, dead-link check, AI suggestion or
webhook test) and wait for the job to finish. `eza-bookmarks backup` after the
upgrade should produce a new stamp with the current schema.

## Rolling back

The old binary cannot open a migrated database, so rollback is a restore:

1. Stop the server.
2. Restore the stamp from before the upgrade with the old binary:
   `eza-bookmarks restore <stamp> --yes` (it backs up the current installation
   first and rewrites the control paths).
3. Start the old binary against the restored data.

Never copy a live SQLite database with `cp`; the stamp/restore path uses
`VACUUM INTO` and validates the stamp.

## Troubleshooting

| Symptom | Meaning / action |
|---|---|
| `schema is newer than this binary` | You started an older binary against migrated data. Roll forward or restore the pre-upgrade stamp; do not edit `schema_meta`. |
| `schema checksum mismatch` | A shipped migration was edited or the database was modified by hand. Deploy the matching release or restore the backup. |
| `/healthz` returns 503 after upgrade | Check ownership/permissions of the data directory and the server log. A failed migration leaves the previous schema version in place (each migration is a transaction) and refuses to serve. |
| Login works but a passkey fails | `PUBLIC_ORIGIN`/`EZA_RP_ID` changed, or the browser origin is not the same HTTPS origin. Restore them and use recovery if needed. |
| An async action seems to do nothing | The action now enqueues a job; check the job state (`GET /api/v1/jobs/<id>`) and the server log for the worker error. A failed job reports its error in the job record. |
