#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bookmarks daily backup — systemd timer / cron / Railway cron
#
# Online SQLite .backup of the live DB into BACKUP_DIR, PRAGMA integrity_check
# on the copy, pruning of backups older than 14 days, and an optional offsite
# copy to BACKUP_OFFBOX_DEST.
#
# ENV:
#   BOOKMARKS_DB        live database (default: <repo>/data/bookmarks.db)
#   BACKUP_DIR          backup directory (default: <db dir>/backups)
#   BACKUP_OFFBOX_DEST  optional offsite destination:
#                         - a directory path (local dir, bind-mounted S3
#                           bucket via s3fs, or an rclone mount) -> plain `cp`
#                         - an rclone remote like `bucket:bookmarks`
#                           (rclone must be installed) -> `rclone copy`
#   BACKUP_KEEP_DAYS    retention in days (default: 14)
#
# MECHANISM: `sqlite3 <db> ".backup <dest>"` is the sqlite3 ONLINE BACKUP API
# (sqlite.org/backup.html) — a consistent point-in-time snapshot that is safe
# against a concurrent writer, so we NEVER raw-copy bookmarks.db and NEVER copy
# bookmarks.db-wal alone (that produces the inconsistent-copy failure .backup
# exists to prevent). The sqlite3 CLI process holds no write transaction, so
# .backup never runs under an open write lock. A corrupt copy fails loudly
# (exit non-zero) and is removed rather than kept in rotation.
#
# USAGE:
#   scripts/backup.sh                   backup + integrity check + prune + offsite
#   scripts/backup.sh verify [FILE]     restore FILE into a temp path and compare
#                                       row counts against the live DB (exit
#                                       non-zero on mismatch)
# ---------------------------------------------------------------------------
set -euo pipefail

KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BOOKMARKS_DB="${BOOKMARKS_DB:-$REPO_ROOT/data/bookmarks.db}"
BACKUP_DIR="${BACKUP_DIR:-$(dirname "$BOOKMARKS_DB")/backups}"

copy_offsite() {
  local file="$1"
  local dest="$BACKUP_OFFBOX_DEST"
  if [[ "$dest" == *:* && "$dest" != /* ]]; then
    if ! command -v rclone >/dev/null 2>&1; then
      echo "ERROR: BACKUP_OFFBOX_DEST=$dest looks like an rclone remote but rclone is not installed" >&2
      exit 1
    fi
    echo "offsite: rclone copy $file -> $dest"
    rclone copy "$file" "$dest"
  else
    echo "offsite: cp $file -> $dest/"
    mkdir -p "$dest"
    cp "$file" "$dest/"
  fi
}

backup() {
  mkdir -p "$BACKUP_DIR"
  local backup_file="$BACKUP_DIR/bookmarks-$(date +%F-%T).db"

  echo "backing up $BOOKMARKS_DB -> $backup_file"
  # Online backup API — safe against a concurrent writer, never a raw copy.
  if ! sqlite3 "$BOOKMARKS_DB" ".backup '$backup_file'"; then
    echo "ERROR: backup of $BOOKMARKS_DB failed" >&2
    rm -f "$backup_file"  # never leave a partial file in rotation
    exit 1
  fi

  # Fail loudly on a corrupt copy and don't leave it in rotation. Note the
  # sqlite3 CLI prints `.backup` failures but still exits 0 when backup_step
  # fails mid-way, so the integrity check is the real gate here — its output
  # (stderr included) is captured, and a non-"ok" result exits 1.
  local integrity
  integrity="$(sqlite3 "$backup_file" "PRAGMA integrity_check;" 2>&1 || true)"
  if [ "$integrity" != "ok" ]; then
    echo "ERROR: integrity_check failed on $backup_file: $integrity" >&2
    rm -f "$backup_file"
    exit 1
  fi
  echo "integrity_check: ok"

  # Prune backups older than KEEP_DAYS days (mtime based).
  find "$BACKUP_DIR" -name 'bookmarks-*.db' -mtime +"$KEEP_DAYS" -delete

  # Optional offsite copy.
  if [ -n "${BACKUP_OFFBOX_DEST:-}" ]; then
    copy_offsite "$backup_file"
  fi

  echo "backup complete: $backup_file"
}

verify() {
  local backup_file="${1:-}"
  if [ -z "$backup_file" ]; then
    echo "usage: scripts/backup.sh verify <backup.db>" >&2
    exit 2
  fi
  [ -f "$backup_file" ] || { echo "ERROR: $backup_file not found" >&2; exit 1; }

  # Restore the backup into a temp path via the online API, then compare row
  # counts against the live DB — the "restore to equal counts" acceptance.
  local tmp_restore
  tmp_restore="$(mktemp)"
  trap 'rm -f "${tmp_restore:-}"' EXIT
  sqlite3 "$backup_file" ".backup '$tmp_restore'"

  local ok=1
  local t from_backup from_live
  for t in bookmarks tags bookmark_tags links; do
    from_backup="$(sqlite3 "$tmp_restore" "SELECT COUNT(*) FROM $t;")"
    from_live="$(sqlite3 "$BOOKMARKS_DB" "SELECT COUNT(*) FROM $t;")"
    if [ "$from_backup" != "$from_live" ]; then
      echo "MISMATCH $t: backup=$from_backup live=$from_live" >&2
      ok=0
    else
      echo "ok $t: $from_backup"
    fi
  done
  rm -f "$tmp_restore"
  trap - EXIT
  [ "$ok" -eq 1 ] || exit 1
}

case "${1:-}" in
  verify) shift; verify "$@" ;;
  *) backup ;;
esac
