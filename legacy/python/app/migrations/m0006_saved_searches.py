"""Migration 6 — saved_searches for the inbox / read-later collections.

Todo 29's saved searches are virtual collections: each row stores a named
search over the existing search surface (a ``q`` string that may carry the
``is:unread``/``tag:``/``link:`` operators plus an explicit ``tags`` list),
NOT a folders hierarchy. The left rail renders these as clickable filters —
the search endpoint does the actual work, so a saved search whose tag was
later deleted simply yields an empty result set (never a 500).

Columns:

- ``id`` — saved-search id (AUTOINCREMENT).
- ``name`` — display name shown in the collections rail.
- ``q`` — the search string (may be empty = no free-text filter).
- ``tags_json`` — JSON array of tag names (may be empty).
- ``created_at`` — epoch seconds of creation.

Every statement runs as an individual ``conn.execute()`` — never
``executescript``, which implicitly COMMITs the runner's transaction and would
break the per-step atomicity guarantee.
"""

from __future__ import annotations

import sqlite3


def migrate(conn: sqlite3.Connection) -> None:
    """Create ``saved_searches``. The runner wraps this in a transaction and
    stamps ``PRAGMA user_version = 6``, so it applies exactly once per DB."""
    tables = {
        row["name"]
        for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    if "saved_searches" in tables:
        # Already applied (guards a direct re-run; the runner never re-invokes
        # a stamped step, so this is belt-and-braces only).
        return
    conn.execute(
        """
        CREATE TABLE saved_searches (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            name       TEXT    NOT NULL,
            q          TEXT    NOT NULL DEFAULT '',
            tags_json  TEXT    NOT NULL DEFAULT '[]',
            created_at INTEGER NOT NULL
        )
        """
    )
