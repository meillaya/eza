"""Migration 4 — links.target_title for unresolved wikilinks.

Version 3's ``links`` table records only resolved edges (``target_id`` set,
``target_title`` absent). A wikilink like ``[[missing page]]`` that resolves to
no bookmark must still be recorded — with a NULL ``target_id`` and the raw
``[[target]]`` text in a ``target_title`` column — so the backlinks UI can
show "referenced but not created" and so re-saving the note after the target
bookmark is created can upgrade the row in place.

This migration adds ``target_title TEXT DEFAULT ''`` to the existing ``links``
table. Existing rows (all resolved, from todo 14) keep the default; nothing is
backfilled. The ``UNIQUE(source_id, target_id, line_number)`` constraint treats
NULLs as distinct, so application-level dedupe for unresolved links keys on
``(None, target_title, line_number)`` — see ``app/links.py``.

Every statement runs as an individual ``conn.execute()`` — never
``executescript``, which implicitly COMMITs the runner's transaction and would
break the per-step atomicity guarantee.
"""

from __future__ import annotations

import sqlite3


def migrate(conn: sqlite3.Connection) -> None:
    """Add ``links.target_title``. The runner wraps this in a transaction and
    stamps ``PRAGMA user_version = 4``, so it applies exactly once per DB."""
    columns = {row["name"] for row in conn.execute("PRAGMA table_info(links)")}
    if "target_title" in columns:
        # Already applied (guards a direct re-run; the runner never re-invokes
        # a stamped step, so this is belt-and-braces only).
        return
    conn.execute("ALTER TABLE links ADD COLUMN target_title TEXT DEFAULT ''")
