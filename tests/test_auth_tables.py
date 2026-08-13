"""Tests for migration v2 — the WebAuthn / session / recovery auth tables.

Version 2 (``m0002_auth_tables``) creates the five tables the passwordless
auth flow needs: ``users`` (single fixed row ``id = 1`` plus ``setup_claimed``),
``passkey_credentials``, ``webauthn_challenges``, ``sessions`` (with the
``scope`` column required for the recovery scoped-session) and
``recovery_codes``. These tests pin the schema (column names, types, NOT NULL,
defaults, uniqueness) and the runner behaviour around the new step
(v1 -> v2 ordering, idempotency).
"""

from __future__ import annotations

import sqlite3

import pytest

from app import db, migrations

AUTH_NAME = (
    migrations.MIGRATIONS[1][0]
    if len(migrations.MIGRATIONS) > 1
    else "m0002_auth_tables"
)

AUTH_TABLES = {
    "users",
    "passkey_credentials",
    "webauthn_challenges",
    "sessions",
    "recovery_codes",
}

KB_SCHEMA_NAME = (
    migrations.MIGRATIONS[2][0]
    if len(migrations.MIGRATIONS) > 2
    else "m0003_kb_schema"
)

LINKS_NAME = (
    migrations.MIGRATIONS[3][0]
    if len(migrations.MIGRATIONS) > 3
    else "m0004_links_target_title"
)

SNAPSHOTS_NAME = (
    migrations.MIGRATIONS[4][0]
    if len(migrations.MIGRATIONS) > 4
    else "m0005_undo_snapshots"
)

# The live-like pre-v2 schema: last_checked_at exists, user_version not stamped.
_LEGACY_SCHEMA = """
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


def _open(path) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def _version(conn: sqlite3.Connection) -> int:
    row = conn.execute("PRAGMA user_version").fetchone()
    return int(row[0]) if row is not None else 0


def _table_names(conn: sqlite3.Connection) -> set[str]:
    rows = conn.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table'"
    ).fetchall()
    return {row["name"] for row in rows}


def _cols(conn: sqlite3.Connection, table: str) -> dict[str, tuple[str, int, str | None]]:
    """name -> (type, notnull, default) from PRAGMA table_info."""
    return {
        row["name"]: (row["type"], row["notnull"], row["dflt_value"])
        for row in conn.execute(f"PRAGMA table_info({table})")
    }


# ---------------------------------------------------------------------------
# Registration + fresh-DB landing
# ---------------------------------------------------------------------------


def test_m0002_is_registered_as_version_2():
    """The auth migration is the second step in the ordered chain."""
    assert AUTH_NAME == "m0002_auth_tables"
    assert migrations.MIGRATIONS[1][0] == "m0002_auth_tables"


def test_fresh_db_lands_on_latest_version_with_all_auth_tables(fresh_db):
    """A fresh DB runs every step and ends up with the five auth tables."""
    conn = fresh_db.get_conn()
    assert _version(conn) == 5
    assert _table_names(conn) >= AUTH_TABLES


# ---------------------------------------------------------------------------
# users
# ---------------------------------------------------------------------------


def test_users_schema_and_fixed_row(fresh_db):
    """users has exactly id + setup_claimed, and the fixed id=1 row exists."""
    conn = fresh_db.get_conn()
    assert _cols(conn, "users") == {
        "id": ("INTEGER", 0, None),
        "setup_claimed": ("INTEGER", 1, "0"),
    }
    row = conn.execute("SELECT id, setup_claimed FROM users").fetchone()
    assert row["id"] == 1
    assert row["setup_claimed"] == 0
    assert conn.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 1


# ---------------------------------------------------------------------------
# passkey_credentials
# ---------------------------------------------------------------------------


def test_passkey_credentials_schema(fresh_db):
    """passkey_credentials carries the full WebAuthn credential record."""
    conn = fresh_db.get_conn()
    assert _cols(conn, "passkey_credentials") == {
        "credential_id": ("BLOB", 1, None),
        "public_key": ("BLOB", 1, None),
        "cose_alg": ("INTEGER", 1, None),
        "sign_count": ("INTEGER", 1, "0"),
        "aaguid": ("BLOB", 0, None),
        "transports": ("TEXT", 1, "'[]'"),
        "backup_eligible": ("INTEGER", 1, "0"),
        "backup_state": ("INTEGER", 1, "0"),
        "user_handle": ("BLOB", 0, None),
        "nickname": ("TEXT", 1, "''"),
        "created_at": ("INTEGER", 1, None),
        "last_used_at": ("INTEGER", 0, None),
    }


def test_credential_id_is_unique(fresh_db):
    """credential_id is enforced UNIQUE structurally and behaviourally."""
    conn = fresh_db.get_conn()
    indexes = conn.execute("PRAGMA index_list(passkey_credentials)").fetchall()
    assert any(
        row["name"].startswith("sqlite_autoindex_passkey_credentials") and row["unique"]
        for row in indexes
    )

    insert = """
        INSERT INTO passkey_credentials (
            credential_id, public_key, cose_alg, sign_count, aaguid,
            transports, backup_eligible, backup_state, user_handle,
            nickname, created_at, last_used_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """
    row = (b"\x01cred", b"\xa1pub", -7, 0, b"\x00" * 16, "[]", 0, 0, b"\x01", "yubi", 1, None)
    conn.execute(insert, row)
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(insert, row)


# ---------------------------------------------------------------------------
# webauthn_challenges
# ---------------------------------------------------------------------------


def test_webauthn_challenges_schema(fresh_db):
    """Challenges store the challenge blob, a purpose tag and an expiry."""
    conn = fresh_db.get_conn()
    assert _cols(conn, "webauthn_challenges") == {
        "challenge": ("BLOB", 0, None),
        "purpose": ("TEXT", 1, None),
        "expires_at": ("INTEGER", 1, None),
    }


# ---------------------------------------------------------------------------
# sessions
# ---------------------------------------------------------------------------


def test_sessions_schema(fresh_db):
    """sessions carries csrf_token plus the scope column (default 'normal')."""
    conn = fresh_db.get_conn()
    assert _cols(conn, "sessions") == {
        "id": ("TEXT", 0, None),
        "csrf_token": ("TEXT", 1, None),
        "scope": ("TEXT", 1, "'normal'"),
        "created_at": ("INTEGER", 1, None),
        "expires_at": ("INTEGER", 1, None),
    }


def test_sessions_scope_defaults_to_normal(fresh_db):
    """An insert without scope lands on the 'normal' scope value."""
    conn = fresh_db.get_conn()
    conn.execute(
        "INSERT INTO sessions (id, csrf_token, created_at, expires_at) "
        "VALUES (?, ?, ?, ?)",
        ("s1", "tok", 1, 2),
    )
    assert conn.execute("SELECT scope FROM sessions WHERE id = 's1'").fetchone()["scope"] == "normal"


# ---------------------------------------------------------------------------
# recovery_codes
# ---------------------------------------------------------------------------


def test_recovery_codes_schema(fresh_db):
    """recovery_codes stores a hashed code plus its redemption state."""
    conn = fresh_db.get_conn()
    assert _cols(conn, "recovery_codes") == {
        "code_hash": ("TEXT", 1, None),
        "used": ("INTEGER", 1, "0"),
        "created_at": ("INTEGER", 1, None),
        "redeemed_at": ("INTEGER", 0, None),
    }


def test_recovery_code_hash_is_unique(fresh_db):
    """code_hash is enforced UNIQUE structurally and behaviourally."""
    conn = fresh_db.get_conn()
    indexes = conn.execute("PRAGMA index_list(recovery_codes)").fetchall()
    assert any(
        row["name"].startswith("sqlite_autoindex_recovery_codes") and row["unique"]
        for row in indexes
    )

    conn.execute(
        "INSERT INTO recovery_codes (code_hash, created_at) VALUES (?, ?)",
        ("hashed-abc", 1),
    )
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            "INSERT INTO recovery_codes (code_hash, created_at) VALUES (?, ?)",
            ("hashed-abc", 1),
        )


# ---------------------------------------------------------------------------
# Runner behaviour: idempotency + v1 -> v2 ordering
# ---------------------------------------------------------------------------


def test_migration_is_idempotent(db_path):
    """Running the runner twice applies nothing the second time and keeps the
    latest version (5)."""
    conn = _open(db_path)
    conn.executescript(_LEGACY_SCHEMA)

    first = db.run_migrations(conn)
    assert first == [migrations.MIGRATIONS[0][0], AUTH_NAME, KB_SCHEMA_NAME, LINKS_NAME, SNAPSHOTS_NAME]
    assert _version(conn) == 5

    second = db.run_migrations(conn)
    assert second == []
    assert _version(conn) == 5
    assert _table_names(conn) >= AUTH_TABLES
    conn.close()


def test_v2_applies_after_v1_on_legacy_stamped_db(db_path):
    """A DB already stamped at v1 runs the v2..v5 steps — v1 never re-runs."""
    conn = _open(db_path)
    conn.executescript(_LEGACY_SCHEMA)
    conn.execute("PRAGMA user_version = 1")
    assert _version(conn) == 1

    applied = db.run_migrations(conn)

    assert applied == [AUTH_NAME, KB_SCHEMA_NAME, LINKS_NAME, SNAPSHOTS_NAME]
    assert _version(conn) == 5
    assert _table_names(conn) >= AUTH_TABLES
    assert "last_checked_at" in {
        row["name"] for row in conn.execute("PRAGMA table_info(bookmarks)")
    }
    conn.close()
