"""Tests for the versioned migration runner (PRAGMA user_version + detect-and-stamp).

The runner lives in :func:`app.db.run_migrations` and drives the ordered
migration modules exposed by :data:`app.migrations.MIGRATIONS`. Version 1 is
the legacy detect-and-stamp baseline: an unversioned database (user_version 0)
is probed and either upgraded or simply stamped, never re-running work the
live schema already had done.
"""

from __future__ import annotations

import sqlite3

import pytest

from app import db, migrations

# The pre-versioning schema as it existed before ``last_checked_at`` existed.
_LEGACY_SCHEMA = """
CREATE TABLE bookmarks (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    url            TEXT    NOT NULL UNIQUE,
    title          TEXT    NOT NULL DEFAULT '',
    description    TEXT    NOT NULL DEFAULT '',
    favicon_url    TEXT    NOT NULL DEFAULT '',
    domain         TEXT    NOT NULL DEFAULT '',
    created_at     INTEGER NOT NULL,
    last_opened_at INTEGER,
    open_count     INTEGER NOT NULL DEFAULT 0,
    is_dead        INTEGER NOT NULL DEFAULT 0
);
"""

# The schema of the *current* live database: the legacy probe already ran, so
# the column and its index exist but user_version was never stamped.
_LEGACY_SCHEMA_WITH_CHECK = """
CREATE TABLE bookmarks (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    url              TEXT    NOT NULL UNIQUE,
    title            TEXT    NOT NULL DEFAULT '',
    description      TEXT    NOT NULL DEFAULT '',
    favicon_url      TEXT    NOT NULL DEFAULT '',
    domain           TEXT    NOT NULL DEFAULT '',
    created_at       INTEGER NOT NULL,
    last_opened_at   INTEGER,
    last_checked_at  INTEGER,
    open_count       INTEGER NOT NULL DEFAULT 0,
    is_dead          INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_bookmarks_checked ON bookmarks(last_checked_at);
"""

BASELINE_NAME = migrations.MIGRATIONS[0][0] if migrations.MIGRATIONS else "m0001_baseline_last_checked"


def _open(path) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def _version(conn: sqlite3.Connection) -> int:
    row = conn.execute("PRAGMA user_version").fetchone()
    return int(row[0]) if row is not None else 0


def _column_names(conn: sqlite3.Connection) -> set[str]:
    return {row["name"] for row in conn.execute("PRAGMA table_info(bookmarks)")}


def _index_names(conn: sqlite3.Connection) -> set[str]:
    return {row["name"] for row in conn.execute("PRAGMA index_list(bookmarks)")}


# ---------------------------------------------------------------------------
# Detect-and-stamp baseline (version 1)
# ---------------------------------------------------------------------------


def test_legacy_db_without_column_is_detected_and_upgraded(db_path):
    """A truly legacy DB (no last_checked_at, user_version 0) is upgraded in
    the baseline step and stamped to version 1."""
    conn = _open(db_path)
    conn.executescript(_LEGACY_SCHEMA)
    assert _version(conn) == 0
    assert "last_checked_at" not in _column_names(conn)

    applied = db.run_migrations(conn)

    assert applied == [BASELINE_NAME]
    assert _version(conn) == 1
    assert "last_checked_at" in _column_names(conn)
    assert "idx_bookmarks_checked" in _index_names(conn)
    conn.close()


def test_legacy_db_with_column_is_stamped_without_ddl(db_path):
    """A DB that already has last_checked_at + index (like the live DB) is
    detected as the baseline: it is stamped to 1 with zero DDL changes."""
    conn = _open(db_path)
    conn.executescript(_LEGACY_SCHEMA_WITH_CHECK)
    assert _version(conn) == 0
    columns_before = _column_names(conn)
    indexes_before = _index_names(conn)

    applied = db.run_migrations(conn)

    assert applied == [BASELINE_NAME]
    assert _version(conn) == 1
    assert _column_names(conn) == columns_before
    assert _index_names(conn) == indexes_before
    conn.close()


def test_fresh_db_gets_stamped_to_version_1(fresh_db):
    """A freshly initialized DB goes through the same runner and lands on
    user_version 1 (the baseline column comes from _SCHEMA, so no DDL runs)."""
    assert _version(fresh_db.get_conn()) == 1
    assert "last_checked_at" in _column_names(fresh_db.get_conn())


# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------


def test_runner_is_idempotent(db_path):
    """Running the runner twice applies zero migrations the second time."""
    conn = _open(db_path)
    conn.executescript(_LEGACY_SCHEMA_WITH_CHECK)

    first = db.run_migrations(conn)
    assert len(first) == len(migrations.MIGRATIONS)
    assert _version(conn) == 1

    second = db.run_migrations(conn)
    assert second == []
    assert _version(conn) == 1
    conn.close()


# ---------------------------------------------------------------------------
# Transaction rollback
# ---------------------------------------------------------------------------


def test_failed_migration_rolls_back_ddl_and_stamp(db_path, monkeypatch):
    """A broken step aborts its whole transaction: the partial DDL and the
    version stamp are both rolled back and the error propagates."""
    db.get_conn()  # baseline applied -> version 1
    conn = db.get_conn()
    assert _version(conn) == 1

    def broken(_: sqlite3.Connection) -> None:
        conn.execute("ALTER TABLE bookmarks ADD COLUMN boom_col INTEGER")
        raise RuntimeError("boom")

    monkeypatch.setattr(
        migrations,
        "MIGRATIONS",
        [("m0000_noop", lambda c: None), ("m0001_broken", broken)],
    )

    with pytest.raises(RuntimeError, match="boom"):
        db.run_migrations(conn)

    assert "boom_col" not in _column_names(conn)
    assert _version(conn) == 1
    # The connection is left usable after the rollback.
    assert conn.execute("SELECT COUNT(*) FROM bookmarks").fetchone()[0] == 0
    conn.close()


# ---------------------------------------------------------------------------
# Future-migration ordering (v2 runs only after v1)
# ---------------------------------------------------------------------------


def test_v2_runs_after_v1_in_order(db_path, monkeypatch):
    """From user_version 0 both steps run, v1 fully committed (stamped) before
    v2 starts; the DB lands on version 2."""
    seen: list[int] = []

    def fake_v2(conn_: sqlite3.Connection) -> None:
        seen.append(_version(conn_))
        conn_.execute("CREATE TABLE v2_probe (x INTEGER)")

    monkeypatch.setattr(migrations, "MIGRATIONS", [*migrations.MIGRATIONS, ("m0002_fake", fake_v2)])

    db.get_conn()
    conn = db.get_conn()

    assert _version(conn) == 2
    assert seen == [1]  # v1 was committed before v2's transaction opened
    tables = {
        row["name"]
        for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    assert "v2_probe" in tables
    conn.close()


def test_v2_is_only_pending_on_stamped_db(db_path, monkeypatch):
    """A DB already stamped at version 1 only runs the v2 step — the baseline
    is never re-applied."""
    conn = _open(db_path)
    conn.executescript(_LEGACY_SCHEMA_WITH_CHECK)
    conn.execute("PRAGMA user_version = 1")
    assert _version(conn) == 1

    ran: list[str] = []

    def fake_v2(conn_: sqlite3.Connection) -> None:
        ran.append("v2")

    monkeypatch.setattr(migrations, "MIGRATIONS", [(BASELINE_NAME, lambda c: ran.append("v1")), ("m0002_fake", fake_v2)])

    applied = db.run_migrations(conn)

    assert applied == ["m0002_fake"]
    assert ran == ["v2"]
    assert _version(conn) == 2
    conn.close()
