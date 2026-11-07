"""Tests for the backup helper + CLI (app/backup.py).

The acceptance for todo 37 is a backup that passes ``PRAGMA integrity_check``
and restores to equal row counts, plus a corrupt source failing loudly with a
non-zero exit. These tests pin the helper logic; scripts/backup.sh (the cron
path) mirrors the same operations and is verified by the live acceptance run.
"""

from __future__ import annotations

import os
import shutil
import sqlite3
import time
from pathlib import Path

import pytest

from app import db
from app.backup import (
    BackupError,
    backup_database,
    main,
    offsite_copy,
    prune_backups,
    restore_counts,
    run_backup,
    verify_backup,
)

_RESTORED_SHAPE = {"bookmarks": 3, "tags": 2, "bookmark_tags": 3, "links": 0}


def _seed() -> None:
    """Three bookmarks, two tags (rust/web), three bookmark_tags, no links."""
    db.insert_bookmark(url="https://a.example/", title="Alpha", tags=["rust"])
    db.insert_bookmark(url="https://b.example/", title="Beta", tags=["rust", "web"])
    db.insert_bookmark(url="https://c.example/", title="Gamma")


def _latest_backup(backup_dir: Path) -> Path:
    matches = sorted(backup_dir.glob("bookmarks-*.db"))
    assert matches, "no backup file was created"
    return matches[-1]


def test_backup_database_creates_valid_named_snapshot(fresh_db, tmp_path):
    _seed()
    source = db.DB_PATH
    backup_dir = tmp_path / "backups"

    backup = backup_database(source, backup_dir)

    assert backup.is_file()
    assert backup.parent == backup_dir
    assert backup.name.startswith("bookmarks-")
    assert backup.name.endswith(".db")
    verify_backup(backup)  # must not raise
    assert restore_counts(backup) == restore_counts(source)


def test_backup_uses_online_api_capturing_uncheckpointed_wal_rows(fresh_db, tmp_path):
    """A raw copy of bookmarks.db alone loses rows still in the -wal file;
    the online .backup API captures them."""
    conn = db.get_conn()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")  # flush schema to the main file
    _seed()  # these rows now live only in bookmarks.db-wal
    source = db.DB_PATH
    backup_dir = tmp_path / "backups"

    backup = backup_database(source, backup_dir)

    # A db-only raw copy (no -wal) sees zero bookmarks; the online backup sees all.
    naive = tmp_path / "naive.db"
    shutil.copy2(source, naive)
    assert restore_counts(naive)["bookmarks"] == 0
    assert restore_counts(backup) == _RESTORED_SHAPE
    assert restore_counts(backup) == restore_counts(source)


def test_prune_backups_removes_older_than_keep_days(tmp_path):
    backup_dir = tmp_path / "backups"
    backup_dir.mkdir()
    old = backup_dir / "bookmarks-2026-01-01-00:00:00.db"
    fresh = backup_dir / "bookmarks-2026-08-13-00:00:00.db"
    old.write_bytes(b"x")
    fresh.write_bytes(b"x")
    now = time.time()
    os.utime(old, (now - 30 * 86400, now - 30 * 86400))  # 30 days old
    os.utime(fresh, (now - 3600, now - 3600))  # 1 hour old
    (backup_dir / "notes.txt").write_text("not a backup")

    removed = prune_backups(backup_dir, keep_days=14)

    assert removed == [old]
    assert not old.exists()
    assert fresh.exists()
    assert (backup_dir / "notes.txt").exists()  # non-backup files are untouched


def test_prune_backups_keeps_oldest_when_kept_within_keep_days(tmp_path):
    backup_dir = tmp_path / "backups"
    backup_dir.mkdir()
    boundary = backup_dir / "bookmarks-2026-08-01-00:00:00.db"
    boundary.write_bytes(b"x")
    now = time.time()
    os.utime(boundary, (now - 12 * 86400, now - 12 * 86400))  # 12 days: kept

    assert prune_backups(backup_dir, keep_days=14) == []
    assert boundary.exists()


def test_offsite_copy_copies_finished_backup(tmp_path):
    backup_dir = tmp_path / "backups"
    backup_dir.mkdir()
    backup = backup_dir / "bookmarks-2026-08-13-00:00:00.db"
    backup.write_bytes(b"payload")
    offbox = tmp_path / "offbox"

    offsite_copy(backup, offbox)

    assert (offbox / backup.name).read_bytes() == b"payload"


def test_verify_backup_raises_on_corrupt_copy(tmp_path):
    corrupt = tmp_path / "corrupt.db"
    corrupt.write_bytes(b"\x00" * 4096 + b"garbage not a sqlite database")

    with pytest.raises(BackupError):
        verify_backup(corrupt)


def test_run_backup_fails_loudly_on_corrupt_source(tmp_path):
    source = tmp_path / "corrupt.db"
    source.write_bytes(b"this is not a sqlite database at all")
    backup_dir = tmp_path / "backups"

    with pytest.raises((BackupError, sqlite3.DatabaseError)):
        run_backup(source=source, backup_dir=backup_dir)
    assert list(backup_dir.glob("*.db")) == []  # no partial backup left in rotation


def test_run_backup_restores_to_equal_counts_with_offsite(fresh_db, tmp_path):
    _seed()
    backup_dir = tmp_path / "backups"
    offbox = tmp_path / "offbox"

    result = run_backup(source=db.DB_PATH, backup_dir=backup_dir, offbox=offbox)

    backup = Path(result["backup"])
    assert backup.is_file()
    assert result["counts"] == _RESTORED_SHAPE
    assert (offbox / backup.name).is_file()


def test_main_creates_backup_and_returns_zero(fresh_db, tmp_path):
    _seed()
    backup_dir = tmp_path / "backups"

    rc = main(["--db", str(db.DB_PATH), "--backup-dir", str(backup_dir)])

    assert rc == 0
    backup = _latest_backup(backup_dir)
    verify_backup(backup)
    assert restore_counts(backup) == _RESTORED_SHAPE


def test_main_exits_nonzero_on_corrupt_source(tmp_path):
    source = tmp_path / "corrupt.db"
    source.write_bytes(b"not a database")
    backup_dir = tmp_path / "backups"

    rc = main(["--db", str(source), "--backup-dir", str(backup_dir)])

    assert rc == 1
    assert list(backup_dir.glob("*.db")) == []
