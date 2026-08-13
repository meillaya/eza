"""Tests for migration v3 — KB schema: notes/links/extraction columns + FTS rebuild.

Version 3 (``m0003_kb_schema``) adds ten columns to ``bookmarks``
(``note_body``, ``extracted_text``, ``author``, ``sitename``, ``published_at``,
``language``, ``image_url``, ``final_url``, ``snapshot_path``, ``is_read``),
creates the ``links`` table with indexes on ``source_id``/``target_id``, and
rebuilds ``bookmarks_fts`` as an external-content FTS5 index over five
columns (``title``, ``description``, ``url``, ``note_body``,
``extracted_text``).

Two of the new columns — ``final_url`` (todo 25 dedup backfill) and
``snapshot_path`` (todo 16 snapshot writes) — are deliberately NOT FTS
columns. The rebuilt ``bookmarks_au`` trigger's ``WHEN`` guard must compare
only the five indexed columns, otherwise those later backfills rewrite every
FTS row and the todo-5 write-amplification fix regresses. These tests pin
that exclusion.
"""

from __future__ import annotations

import sqlite3

import pytest

from app import db, migrations

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

KB_COLUMNS = {
    "note_body",
    "extracted_text",
    "author",
    "sitename",
    "published_at",
    "language",
    "image_url",
    "final_url",
    "snapshot_path",
    "is_read",
}

FTS_COLUMNS = ("title", "description", "url", "note_body", "extracted_text")


def _version(conn: sqlite3.Connection) -> int:
    row = conn.execute("PRAGMA user_version").fetchone()
    return int(row[0]) if row is not None else 0


def _column_names(conn: sqlite3.Connection) -> set[str]:
    return {row["name"] for row in conn.execute("PRAGMA table_info(bookmarks)")}


def _fts_sql(conn: sqlite3.Connection) -> str:
    row = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='bookmarks_fts'"
    ).fetchone()
    assert row is not None, "bookmarks_fts virtual table missing"
    return row["sql"]


def _au_trigger_sql(conn: sqlite3.Connection) -> str:
    row = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='bookmarks_au'"
    ).fetchone()
    assert row is not None, "bookmarks_au trigger missing"
    return row["sql"]


def _fts_count(conn: sqlite3.Connection) -> int:
    return conn.execute("SELECT count(*) FROM bookmarks_fts").fetchone()[0]


def _make_v2_db(db_path) -> sqlite3.Connection:
    """Build a genuine v2 database (schema + user_version 2, no v3 applied)."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.executescript(db._SCHEMA)
    conn.execute("PRAGMA user_version = 1")
    full = list(migrations.MIGRATIONS)
    try:
        migrations.MIGRATIONS = full[:2]
        db.run_migrations(conn)
    finally:
        migrations.MIGRATIONS = full
    return conn


# ---------------------------------------------------------------------------
# Fresh DB reaches v3
# ---------------------------------------------------------------------------


def test_fresh_db_reaches_latest_version_with_kb_columns(fresh_db):
    """A freshly initialized DB lands on the latest user_version with all ten
    columns (v3 adds them; v4 then adds links.target_title)."""
    conn = fresh_db.get_conn()
    assert _version(conn) == 4
    assert _column_names(conn) >= KB_COLUMNS


def test_fresh_db_has_links_table_and_indexes(fresh_db):
    """The links table and its source/target indexes exist after v3."""
    conn = fresh_db.get_conn()
    tables = {
        row["name"] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
    }
    assert "links" in tables
    indexes = {
        row["name"] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='index'")
    }
    assert "idx_links_source" in indexes
    assert "idx_links_target" in indexes


# ---------------------------------------------------------------------------
# FTS rebuild: external-content over exactly the five indexed columns
# ---------------------------------------------------------------------------


def test_fts_rebuilt_external_content_over_five_columns(fresh_db):
    """The rebuilt bookmarks_fts is external-content over the five columns.

    The rebuilt index must keep the exact external-content shape db.py relies
    on (content='bookmarks', content_rowid='id') and must NOT index final_url
    or snapshot_path.
    """
    sql = _fts_sql(fresh_db.get_conn())
    assert "USING fts5" in sql
    assert "content='bookmarks'" in sql
    assert "content_rowid='id'" in sql
    for col in FTS_COLUMNS:
        assert col in sql
    assert "final_url" not in sql
    assert "snapshot_path" not in sql


def test_fts_rebuild_keeps_all_rows(fresh_db):
    """After the rebuild the index holds one row per bookmark."""
    conn = fresh_db.get_conn()
    bid = db.insert_bookmark(url="https://rebuild.example/", title="Rebuild", description="d")
    assert _fts_count(conn) == 1
    rows = conn.execute(
        "SELECT rowid FROM bookmarks_fts WHERE bookmarks_fts MATCH 'rebuild'"
    ).fetchall()
    assert [r[0] for r in rows] == [bid]


def test_note_body_search_works_after_rebuild(fresh_db):
    """FTS search over the new note_body column works post-rebuild."""
    conn = fresh_db.get_conn()
    bid = db.insert_bookmark(url="https://note.example/", title="Note", description="")
    conn.execute("UPDATE bookmarks SET note_body = ? WHERE id = ?", ("deep wisdom about socks", bid))
    rows = conn.execute(
        "SELECT rowid FROM bookmarks_fts WHERE bookmarks_fts MATCH 'socks'"
    ).fetchall()
    assert [r[0] for r in rows] == [bid]


# ---------------------------------------------------------------------------
# AU trigger: WHEN guard scoped to the five FTS columns
# ---------------------------------------------------------------------------


def test_au_trigger_has_when_guard_over_five_fts_columns(fresh_db):
    """The rebuilt AU trigger carries the todo-5 guard over the five indexed
    columns and explicitly excludes final_url / snapshot_path."""
    sql = _au_trigger_sql(fresh_db.get_conn())
    assert "WHEN" in sql
    for col in FTS_COLUMNS:
        assert f"old.{col} IS NOT new.{col}" in sql
    assert "final_url" not in sql
    assert "snapshot_path" not in sql


def test_non_fts_updates_do_not_touch_fts_after_rebuild(fresh_db):
    """open_count, final_url (todo 25 backfill) and snapshot_path (todo 16
    snapshot writes) updates must leave the FTS index untouched."""
    conn = fresh_db.get_conn()
    bid = db.insert_bookmark(url="https://guard.example/", title="Guard", description="d")
    before = _fts_count(conn)

    conn.execute("UPDATE bookmarks SET open_count = open_count + 1 WHERE id = ?", (bid,))
    assert _fts_count(conn) == before

    conn.execute("UPDATE bookmarks SET final_url = ? WHERE id = ?", ("https://final.example/x", bid))
    assert _fts_count(conn) == before

    conn.execute("UPDATE bookmarks SET snapshot_path = ? WHERE id = ?", ("/data/snaps/x.html", bid))
    assert _fts_count(conn) == before

    assert conn.execute("SELECT final_url FROM bookmarks WHERE id = ?", (bid,)).fetchone()[0] == "https://final.example/x"
    assert conn.execute("SELECT snapshot_path FROM bookmarks WHERE id = ?", (bid,)).fetchone()[0] == "/data/snaps/x.html"


def test_indexed_update_still_syncs_fts_after_rebuild(fresh_db):
    """A note_body update (an indexed column) still rewrites the FTS index."""
    conn = fresh_db.get_conn()
    bid = db.insert_bookmark(url="https://sync.example/", title="Old", description="")
    conn.execute("UPDATE bookmarks SET note_body = ? WHERE id = ?", ("needle in haystack", bid))
    assert _fts_count(conn) == 1
    rows = conn.execute(
        "SELECT rowid FROM bookmarks_fts WHERE bookmarks_fts MATCH 'needle'"
    ).fetchall()
    assert [r[0] for r in rows] == [bid]


# ---------------------------------------------------------------------------
# Links table behaviour
# ---------------------------------------------------------------------------


def test_links_unique_and_cascade(fresh_db):
    """UNIQUE(source_id, target_id, line_number) enforced; deleting a bookmark
    cascades to its link rows."""
    conn = fresh_db.get_conn()
    a = db.insert_bookmark(url="https://a.example/", title="A")
    b = db.insert_bookmark(url="https://b.example/", title="B")
    conn.execute(
        "INSERT INTO links (source_id, target_id, display_text, line_number) VALUES (?, ?, ?, ?)",
        (a, b, "B", 1),
    )
    with pytest.raises(sqlite3.IntegrityError):
        conn.execute(
            "INSERT INTO links (source_id, target_id, display_text, line_number) VALUES (?, ?, ?, ?)",
            (a, b, "B dup", 1),
        )
    # Same pair at a different line number is allowed by the UNIQUE constraint.
    conn.execute(
        "INSERT INTO links (source_id, target_id, display_text, line_number) VALUES (?, ?, ?, ?)",
        (a, b, "B again", 2),
    )
    assert conn.execute("SELECT count(*) FROM links").fetchone()[0] == 2

    db.delete_bookmark(a)
    assert conn.execute("SELECT count(*) FROM links").fetchone()[0] == 0


# ---------------------------------------------------------------------------
# v2 -> v3 on a real database (runner path), preserving data
# ---------------------------------------------------------------------------


def test_v2_db_reaches_latest_version_via_runner_preserving_data(db_path):
    """A genuine v2 database (the live-DB shape) migrates through the app
    runner to the latest version (4) with its rows intact and integrity ok."""
    conn = _make_v2_db(db_path)
    assert _version(conn) == 2
    conn.execute(
        "INSERT INTO bookmarks (url, title, domain, created_at) VALUES (?, ?, ?, ?)",
        ("https://keep.example/", "Keep Me", "keep.example", 111),
    )
    conn.execute("INSERT INTO tags (name) VALUES ('kept')")
    conn.execute("INSERT INTO bookmark_tags (bookmark_id, tag_id) VALUES (1, 1)")
    conn.commit()
    conn.close()

    db.get_conn()  # production init path: _SCHEMA no-op + pending v3+v4 migrations
    conn = db.get_conn()
    assert _version(conn) == 4
    assert conn.execute("SELECT title FROM bookmarks WHERE id = 1").fetchone()[0] == "Keep Me"
    assert conn.execute("SELECT COUNT(*) FROM bookmarks").fetchone()[0] == 1
    assert conn.execute("SELECT COUNT(*) FROM tags").fetchone()[0] == 1
    assert conn.execute("SELECT COUNT(*) FROM bookmark_tags").fetchone()[0] == 1
    assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"


def test_v2_db_via_run_migrations(db_path):
    """Applying the full migration list to a v2 DB lands on the latest version."""
    conn = _make_v2_db(db_path)
    applied = db.run_migrations(conn)
    assert applied == [KB_SCHEMA_NAME, LINKS_NAME]
    assert _version(conn) == 4
    assert _column_names(conn) >= KB_COLUMNS
    assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    conn.close()


# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------


def test_latest_runner_rerun_is_noop(fresh_db):
    """Re-running the runner on the latest DB applies nothing and keeps v4."""
    conn = fresh_db.get_conn()
    assert _version(conn) == 4
    assert db.run_migrations(conn) == []
    assert _version(conn) == 4
