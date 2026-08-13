"""Migration 5 — undo_snapshots for the confirm-and-undo dedup merge.

Todo 26's merge is the explicit carve-out from "no destructive changes":
merges only happen on explicit user action and every merge is undo-able. This
table is the undo ledger — one row per executed merge, carrying the FULL
pre-merge state of the affected bookmarks (rows, tags, notes, links, and the
discarded note when a note collision occurred) as JSON. ``DELETE
/api/dedup/undo`` pops the latest row and restores that state, so a mistaken
merge is never permanent.

Columns:

- ``id`` — snapshot id (AUTOINCREMENT; the undo endpoint consumes the highest
  id, i.e. the latest merge).
- ``payload_json`` — the serialized pre-merge state (see ``app/dedup.py``).
- ``created_at`` — epoch seconds of the merge.

Every statement runs as an individual ``conn.execute()`` — never
``executescript``, which implicitly COMMITs the runner's transaction and would
break the per-step atomicity guarantee.
"""

from __future__ import annotations

import sqlite3


def migrate(conn: sqlite3.Connection) -> None:
    """Create ``undo_snapshots``. The runner wraps this in a transaction and
    stamps ``PRAGMA user_version = 5``, so it applies exactly once per DB."""
    tables = {
        row["name"]
        for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    if "undo_snapshots" in tables:
        # Already applied (guards a direct re-run; the runner never re-invokes
        # a stamped step, so this is belt-and-braces only).
        return
    conn.execute(
        """
        CREATE TABLE undo_snapshots (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            payload_json TEXT    NOT NULL,
            created_at   INTEGER NOT NULL
        )
        """
    )
