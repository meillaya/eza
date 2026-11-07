"""FTS trigger write-amplification regression tests.

``bookmarks_au`` (AFTER UPDATE) rewrites the FTS index on every UPDATE by
default. A ``WHEN`` guard limits that rewrite to updates that actually touch
an indexed column (title / description / url). These tests pin down:

- the guard exists in the schema (a temp DB built from ``_SCHEMA``),
- non-indexed updates (open_count, last_opened_at, is_dead, ...) do NOT fire
  the AU trigger — verified with a side-effect-instrumented copy of the real
  trigger — and therefore do not change the FTS row count,
- indexed updates still fire and keep the FTS index in sync,
- INSERT/DELETE sync behaviour is unchanged.
"""

from __future__ import annotations

import sqlite3

from app import db


def _fts_count(conn: sqlite3.Connection) -> int:
    """Number of entries in the FTS index (external-content virtual table)."""
    return conn.execute("SELECT count(*) FROM bookmarks_fts").fetchone()[0]


def _au_trigger_sql(conn: sqlite3.Connection) -> str:
    row = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='bookmarks_au'"
    ).fetchone()
    assert row is not None, "bookmarks_au trigger missing from schema"
    return row["sql"]


def test_schema_au_trigger_has_when_guard(fresh_db):
    """The stored AU trigger from _SCHEMA must carry the write-amplification guard."""
    sql = _au_trigger_sql(fresh_db.get_conn())
    assert "WHEN" in sql
    assert "old.title IS NOT new.title" in sql
    assert "old.description IS NOT new.description" in sql
    assert "old.url IS NOT new.url" in sql


def test_open_count_update_does_not_change_fts_row_count(fresh_db):
    """A pure open_count bump must leave the FTS index untouched."""
    conn = fresh_db.get_conn()
    bid = db.insert_bookmark(url="https://count.example/", title="Count", description="d")
    assert _fts_count(conn) == 1
    conn.execute("UPDATE bookmarks SET open_count = open_count + 1 WHERE id = ?", (bid,))
    assert _fts_count(conn) == 1


def test_record_open_does_not_touch_fts(fresh_db):
    """The app-level record_open() path (open_count + last_opened_at) skips FTS."""
    conn = fresh_db.get_conn()
    bid = db.insert_bookmark(url="https://open.example/", title="Open", description="d")
    before = _fts_count(conn)
    db.record_open(bid)
    assert _fts_count(conn) == before


def test_au_guard_skips_non_indexed_updates(fresh_db):
    """Prove the guard fires the trigger ONLY for indexed-column changes.

    Rebuilds the real (stored) AU trigger with a firing side-effect so we can
    observe exactly which updates invoke it. Because the instrumented trigger
    is derived from the live _SCHEMA text, removing the guard from _SCHEMA
    breaks this test as well.
    """
    conn = fresh_db.get_conn()
    bid = db.insert_bookmark(url="https://guard.example/", title="Alpha", description="d")

    conn.execute("CREATE TABLE au_fired(n INTEGER NOT NULL DEFAULT 0)")
    side_effect = (
        "INSERT INTO au_fired(n) VALUES ((SELECT COUNT(*) + 1 FROM au_fired));\n"
    )
    instrumented = _au_trigger_sql(conn).replace("BEGIN\n", "BEGIN\n" + side_effect, 1)
    assert instrumented != _au_trigger_sql(conn), "side effect not injected"
    conn.execute("DROP TRIGGER bookmarks_au")
    conn.execute(instrumented)

    # Non-indexed columns: guard says no, trigger must not fire at all.
    conn.execute(
        "UPDATE bookmarks SET open_count = open_count + 1, last_opened_at = unixepoch() "
        "WHERE id = ?",
        (bid,),
    )
    assert conn.execute("SELECT count(*) FROM au_fired").fetchone()[0] == 0
    assert _fts_count(conn) == 1

    # Indexed column change: guard says yes, trigger fires and FTS stays in sync.
    conn.execute("UPDATE bookmarks SET title = 'Beta' WHERE id = ?", (bid,))
    assert conn.execute("SELECT count(*) FROM au_fired").fetchone()[0] == 1
    assert _fts_count(conn) == 1
    rows = conn.execute(
        "SELECT rowid FROM bookmarks_fts WHERE bookmarks_fts MATCH 'Beta'"
    ).fetchall()
    assert [r[0] for r in rows] == [bid]
    assert (
        conn.execute(
            "SELECT count(*) FROM bookmarks_fts WHERE bookmarks_fts MATCH 'Alpha'"
        ).fetchone()[0]
        == 0
    )


def test_title_update_still_syncs_fts(fresh_db):
    """Updating an indexed column still rewrites the FTS index correctly."""
    conn = fresh_db.get_conn()
    bid = db.insert_bookmark(url="https://sync.example/", title="OldTitle", description="d")
    conn.execute("UPDATE bookmarks SET title = ? WHERE id = ?", ("NewTitle", bid))
    # delete+insert keeps the index balanced: exactly one row per bookmark.
    assert _fts_count(conn) == 1
    rows = conn.execute(
        "SELECT rowid FROM bookmarks_fts WHERE bookmarks_fts MATCH 'NewTitle'"
    ).fetchall()
    assert [r[0] for r in rows] == [bid]
    assert (
        conn.execute(
            "SELECT count(*) FROM bookmarks_fts WHERE bookmarks_fts MATCH 'OldTitle'"
        ).fetchone()[0]
        == 0
    )


def test_insert_and_delete_fts_sync_unchanged(fresh_db):
    """INSERT/DELETE triggers are untouched by the AU guard."""
    conn = fresh_db.get_conn()
    bid = db.insert_bookmark(url="https://iodelete.example/", title="IoDel", description="d")
    assert _fts_count(conn) == 1
    assert db.delete_bookmark(bid) is True
    assert _fts_count(conn) == 0
