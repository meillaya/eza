"""Migration 1 — detect-and-stamp the legacy baseline.

Before versioning existed, ``app/db._run_migrations`` probed the ``bookmarks``
table for ``last_checked_at`` and added the column plus an index when they
were missing. The live database already has both (the probe ran long ago) but
was never stamped: ``PRAGMA user_version`` is still 0.

This step is therefore detection-driven: it re-runs the legacy add-column
logic only for truly legacy databases and is a pure no-op for the live schema.
Either way the runner stamps ``PRAGMA user_version = 1``.
"""

from __future__ import annotations

import sqlite3


def migrate(conn: sqlite3.Connection) -> None:
    """Bring a pre-versioning DB up to the v1 baseline schema (no-op if the
    legacy probe already did the work)."""
    columns = {row["name"] for row in conn.execute("PRAGMA table_info(bookmarks)")}
    if "last_checked_at" not in columns:
        conn.execute("ALTER TABLE bookmarks ADD COLUMN last_checked_at INTEGER")
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_bookmarks_checked ON bookmarks(last_checked_at)"
        )
