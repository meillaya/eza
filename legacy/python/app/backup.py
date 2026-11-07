"""CLI: online SQLite backup with integrity check, pruning, offsite copy.

The daily backup pipeline referenced by the Railway runbook (todo 36). Uses
the sqlite3 ONLINE BACKUP API (``Connection.backup``; ``.backup`` in the CLI)
— a consistent point-in-time snapshot that is safe against a concurrent
writer. NEVER a raw ``cp`` of ``bookmarks.db`` and NEVER ``bookmarks.db-wal``
on its own: that is the inconsistent-copy failure the online API exists to
prevent. The source is opened read-only, so the backup never runs under an
open write transaction, and the finished copy is verified with
``PRAGMA integrity_check`` and a restore-equal-counts check before it is kept.

    uv run bookmarks-backup                          # defaults from env
    uv run bookmarks-backup --db data/bookmarks.db --backup-dir /tmp/bk
    uv run bookmarks-backup --keep-days 30

This console script is the alternative to ``scripts/backup.sh`` — the
dependency-free shell pipeline that systemd timer / cron / Railway cron
actually run; this module mirrors its operations and is what the test suite
covers.
"""

from __future__ import annotations

import argparse
import logging
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterable
from pathlib import Path

from app import config

log = logging.getLogger("bookmarks.backup")

DEFAULT_KEEP_DAYS = 14
_DAY_SECONDS = 86400

# The row-count comparison for the "restore to equal counts" acceptance.
# bookmark_tags is the join table; links is the wikilink edge table.
_RESTORE_TABLES = ("bookmarks", "tags", "bookmark_tags", "links")


class BackupError(Exception):
    """The backup produced no valid, restorable copy — fail loudly."""


def _backup_filename(now: float) -> str:
    """``bookmarks-YYYY-MM-DD-HH:MM:SS.db`` — matches scripts/backup.sh's
    ``bookmarks-$(date +%F-%T).db`` so both pipelines prune the same glob."""
    return f"bookmarks-{time.strftime('%F-%T', time.localtime(now))}.db"


def _online_backup(source: Path, dest: Path) -> None:
    """The sqlite3 online backup API: ``source`` -> ``dest``.

    ``source`` is opened read-only, so no write transaction is ever held; the
    copy is a consistent point-in-time snapshot even while the app is writing,
    and the -wal/-shm files are never touched directly.
    """
    src = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
    try:
        dst = sqlite3.connect(dest)
        try:
            src.backup(dst)
            # The copy inherits WAL mode from the source; convert it to DELETE
            # so the artifact is self-contained (no -wal/-shm sidecars that a
            # later read-only open would recreate and pruning would never remove).
            dst.execute("PRAGMA journal_mode = DELETE")
        finally:
            dst.close()
    finally:
        src.close()


def backup_database(source: Path, backup_dir: Path) -> Path:
    """Online .backup of ``source`` into ``backup_dir``; returns the new file.

    A failed backup is removed immediately so a partial file never enters the
    rotation.
    """
    backup_dir.mkdir(parents=True, exist_ok=True)
    dest = backup_dir / _backup_filename(time.time())
    try:
        _online_backup(source, dest)
    except Exception:
        dest.unlink(missing_ok=True)
        raise
    return dest


def verify_backup(backup: Path) -> None:
    """``PRAGMA integrity_check`` on the finished copy.

    Raises :class:`BackupError` unless the result is exactly ``ok`` — the QA
    contract that a corrupt copy fails loudly and is never kept.
    """
    conn = sqlite3.connect(f"file:{backup}?mode=ro", uri=True)
    try:
        try:
            row = conn.execute("PRAGMA integrity_check").fetchone()
        except sqlite3.DatabaseError as exc:
            raise BackupError(f"cannot open backup {backup}: {exc}") from exc
    finally:
        conn.close()
    result = row[0] if row is not None else ""
    if result != "ok":
        raise BackupError(f"integrity_check on {backup}: {result!r}")


def prune_backups(backup_dir: Path, *, keep_days: int = DEFAULT_KEEP_DAYS) -> list[Path]:
    """Delete finished backups older than ``keep_days`` (mtime-based).

    Only ``bookmarks-*.db`` files are candidates — never the live DB and never
    unrelated files in the directory. Returns the removed paths.
    """
    cutoff = time.time() - keep_days * _DAY_SECONDS
    removed: list[Path] = []
    for candidate in sorted(backup_dir.glob("bookmarks-*.db")):
        if candidate.stat().st_mtime < cutoff:
            candidate.unlink()
            removed.append(candidate)
    return removed


def offsite_copy(backup: Path, dest: str | Path) -> None:
    """Copy the finished backup to ``BACKUP_OFFBOX_DEST``.

    Plain directory copy by default: point it at a local directory, a
    bind-mounted S3 bucket (s3fs), or an rclone mount. A destination in rclone
    remote syntax (``remote:path`` — contains ``:``, no leading ``/``) is
    copied with ``rclone copy`` when rclone is installed and fails loudly
    otherwise.
    """
    raw = str(dest)
    if ":" in raw and not raw.startswith("/"):
        if shutil.which("rclone") is None:
            raise BackupError(
                f"BACKUP_OFFBOX_DEST {raw!r} looks like an rclone remote "
                "but rclone is not installed"
            )
        subprocess.run(["rclone", "copy", str(backup), raw], check=True)
        return
    dest_dir = Path(raw)
    dest_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(backup, dest_dir / backup.name)


def restore_counts(db_path: Path) -> dict[str, int]:
    """Row counts of the four data tables in ``db_path`` (read-only).

    The "restore to equal counts" acceptance compares these between the backup
    and the live database.
    """
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        return {
            table: conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            for table in _RESTORE_TABLES
        }
    finally:
        conn.close()


def _restore_into_temp(backup: Path) -> dict[str, int]:
    """Restore ``backup`` into a temp path (online API) and return its counts."""
    with tempfile.TemporaryDirectory() as td:
        restored = Path(td) / "restored.db"
        _online_backup(backup, restored)
        return restore_counts(restored)


def run_backup(
    *,
    source: Path,
    backup_dir: Path,
    keep_days: int = DEFAULT_KEEP_DAYS,
    offbox: str | Path | None = None,
) -> dict:
    """The full backup pipeline: backup -> verify -> restore-verify -> offsite -> prune.

    Returns ``{"backup": <path>, "counts": {...}, "pruned": [...]}`` where
    ``counts`` is the restored-copy row count, proven equal to the source's.
    Raises :class:`BackupError` / sqlite3 / OSError on any failure — the QA
    contract is "fail loudly, exit non-zero". An invalid backup is removed so
    it never enters rotation; a valid backup whose offsite copy fails is kept
    (only the copy failed, not the backup).
    """
    backup = backup_database(source, backup_dir)
    try:
        verify_backup(backup)
        source_counts = restore_counts(source)
        restored = _restore_into_temp(backup)
        if restored != source_counts:
            raise BackupError(
                f"restore mismatch: backup {restored} vs source {source_counts}"
            )
    except Exception:
        backup.unlink(missing_ok=True)
        raise
    if offbox is not None:
        offsite_copy(backup, offbox)
    pruned = prune_backups(backup_dir, keep_days=keep_days)
    return {
        "backup": str(backup),
        "counts": restored,
        "pruned": [str(p) for p in pruned],
    }


def _parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="bookmarks-backup",
        description="Online SQLite backup with integrity check, restore-equal-counts "
        "verification, 14-day pruning and an optional offsite copy "
        "(BACKUP_OFFBOX_DEST).",
    )
    parser.add_argument(
        "--db",
        type=Path,
        default=config.BOOKMARKS_DB,
        help="live database to back up (default: $BOOKMARKS_DB)",
    )
    parser.add_argument(
        "--backup-dir",
        type=Path,
        default=config.BACKUP_DIR,
        help="directory for finished backups (default: $BACKUP_DIR)",
    )
    parser.add_argument(
        "--keep-days",
        type=int,
        default=DEFAULT_KEEP_DAYS,
        help="prune backups older than this many days (default: 14)",
    )
    parser.add_argument(
        "--offbox",
        default=config.BACKUP_OFFBOX_DEST,
        help="offsite destination (default: $BACKUP_OFFBOX_DEST)",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    return parser.parse_args(list(argv))


def main(argv: Iterable[str] | None = None) -> int:
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    try:
        result = run_backup(
            source=args.db,
            backup_dir=args.backup_dir,
            keep_days=args.keep_days,
            offbox=args.offbox,
        )
    except (BackupError, sqlite3.DatabaseError, OSError) as exc:
        log.error("backup failed: %s", exc)
        return 1
    log.info(
        "backup complete: %s (restored counts %s)",
        result["backup"],
        result["counts"],
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
