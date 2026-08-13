"""Migration 3 — KB schema: notes, links, extraction columns + FTS rebuild.

Extends ``bookmarks`` with the columns the knowledge-base wave needs and
rebuilds the external-content FTS5 index over the new free-text columns.

Added to ``bookmarks`` (ten columns):

- ``note_body`` / ``extracted_text`` — Markdown note and full-content
  extraction; both FTS-indexed in the rebuilt index.
- ``author`` / ``sitename`` / ``published_at`` / ``language`` / ``image_url`` —
  article metadata produced by the trafilatura extraction (todo 16).
- ``final_url`` — redirect-final URL for dedup (todo 25 backfills existing
  rows). Deliberately NOT an FTS column: backfilling it must not rewrite the
  index, so it stays out of the ``bookmarks_au`` WHEN guard.
- ``snapshot_path`` — single-file HTML snapshot path, written by todo 16.
  Also deliberately NOT an FTS column, for the same write-amplification reason.
- ``is_read`` — read-later flag.

New ``links`` table models wikilink edges between bookmarks (source -> target).
``UNIQUE(source_id, target_id, line_number)`` lets the same pair be linked
from several line numbers without duplicates; both columns are indexed.

The FTS rebuild follows the external-content recipe: the versioned drop of the
old virtual table (never ALTERing an FTS5 table in place) plus its three sync
triggers, a fresh ``CREATE VIRTUAL TABLE`` over the five indexed columns with
the SAME ``content='bookmarks'`` / ``content_rowid='id'`` /
``tokenize='porter unicode61'`` shape ``app/db.py`` relies on, the triggers
recreated with the todo-5 ``WHEN`` guard scoped to exactly those five columns,
and ``INSERT INTO bookmarks_fts(bookmarks_fts) VALUES('rebuild')`` to backfill
every row from the content table.

The guard MUST compare only the FTS-indexed columns. ``final_url`` and
``snapshot_path`` are excluded on purpose: todo 25's final_url backfill and
todo 16's snapshot writes must not rewrite the whole index.

Every statement runs as an individual ``conn.execute()`` — never
``executescript``, which implicitly COMMITs the runner's transaction and would
break the per-step atomicity guarantee.
"""

from __future__ import annotations

import sqlite3

# The five columns the rebuilt index covers — and the ONLY columns the
# bookmarks_au WHEN guard may compare.
_FTS_COLUMNS = "title, description, url, note_body, extracted_text"

_KB_COLUMN_ALTERS = [
    "ALTER TABLE bookmarks ADD COLUMN note_body TEXT DEFAULT ''",
    "ALTER TABLE bookmarks ADD COLUMN extracted_text TEXT DEFAULT ''",
    "ALTER TABLE bookmarks ADD COLUMN author TEXT DEFAULT ''",
    "ALTER TABLE bookmarks ADD COLUMN sitename TEXT DEFAULT ''",
    "ALTER TABLE bookmarks ADD COLUMN published_at INTEGER",
    "ALTER TABLE bookmarks ADD COLUMN language TEXT DEFAULT ''",
    "ALTER TABLE bookmarks ADD COLUMN image_url TEXT DEFAULT ''",
    "ALTER TABLE bookmarks ADD COLUMN final_url TEXT DEFAULT ''",
    "ALTER TABLE bookmarks ADD COLUMN snapshot_path TEXT DEFAULT ''",
    "ALTER TABLE bookmarks ADD COLUMN is_read INTEGER NOT NULL DEFAULT 0",
]


def migrate(conn: sqlite3.Connection) -> None:
    """Apply the v3 KB schema. The runner wraps this in a transaction and
    stamps ``PRAGMA user_version = 3``, so it applies exactly once per DB."""
    columns = {row["name"] for row in conn.execute("PRAGMA table_info(bookmarks)")}
    if "is_read" in columns:
        # Already applied (guards a direct re-run; the runner never re-invokes
        # a stamped step, so this is belt-and-braces only).
        return

    for ddl in _KB_COLUMN_ALTERS:
        conn.execute(ddl)

    conn.execute(
        """
        CREATE TABLE links (
            id           INTEGER PRIMARY KEY,
            source_id    INTEGER REFERENCES bookmarks(id) ON DELETE CASCADE,
            target_id    INTEGER REFERENCES bookmarks(id) ON DELETE CASCADE,
            display_text TEXT,
            line_number  INTEGER,
            UNIQUE(source_id, target_id, line_number)
        )
        """
    )
    conn.execute("CREATE INDEX idx_links_source ON links(source_id)")
    conn.execute("CREATE INDEX idx_links_target ON links(target_id)")

    # FTS rebuild: versioned drop+recreate (never ALTER the FTS5 table in
    # place). Drop the sync triggers first — DROP TABLE does not cascade.
    conn.execute("DROP TRIGGER IF EXISTS bookmarks_ai")
    conn.execute("DROP TRIGGER IF EXISTS bookmarks_ad")
    conn.execute("DROP TRIGGER IF EXISTS bookmarks_au")
    conn.execute("DROP TABLE IF EXISTS bookmarks_fts")

    conn.execute(
        """
        CREATE VIRTUAL TABLE bookmarks_fts USING fts5(
            title,
            description,
            url,
            note_body,
            extracted_text,
            content='bookmarks',
            content_rowid='id',
            tokenize='porter unicode61'
        )
        """
    )
    conn.execute(
        """
        CREATE TRIGGER bookmarks_ai AFTER INSERT ON bookmarks BEGIN
          INSERT INTO bookmarks_fts(rowid, title, description, url, note_body, extracted_text)
          VALUES (new.id, new.title, new.description, new.url, new.note_body, new.extracted_text);
        END
        """
    )
    conn.execute(
        """
        CREATE TRIGGER bookmarks_ad AFTER DELETE ON bookmarks BEGIN
          INSERT INTO bookmarks_fts(bookmarks_fts, rowid, title, description, url, note_body, extracted_text)
          VALUES('delete', old.id, old.title, old.description, old.url, old.note_body, old.extracted_text);
        END
        """
    )
    guard = " OR ".join(f"old.{col} IS NOT new.{col}" for col in _FTS_COLUMNS.split(", "))
    conn.execute(
        f"""
        CREATE TRIGGER bookmarks_au AFTER UPDATE ON bookmarks
        WHEN {guard}
        BEGIN
          INSERT INTO bookmarks_fts(bookmarks_fts, rowid, title, description, url, note_body, extracted_text)
          VALUES('delete', old.id, old.title, old.description, old.url, old.note_body, old.extracted_text);
          INSERT INTO bookmarks_fts(rowid, title, description, url, note_body, extracted_text)
          VALUES (new.id, new.title, new.description, new.url, new.note_body, new.extracted_text);
        END
        """
    )

    # Backfill the rebuilt index from the content table.
    conn.execute("INSERT INTO bookmarks_fts(bookmarks_fts) VALUES('rebuild')")
