"""Wikilink parsing and backlinks (linked + unlinked mentions).

Parsing: ``[[target]]`` and ``[[target|display]]`` are extracted from a
bookmark's ``note_body`` with :data:`WIKILINK_RE` (an Aristos-style
single-line wikilink regex). Target resolution order is pinned by the plan:

1. exact title match on ``bookmarks.title``;
2. case-insensitive substring of title OR url (the "alias" fallback — there is
   no aliases column, so "alias matching" means title/URL substring matching);
3. no match → recorded with ``target_id NULL`` and the raw target text in the
   ``target_title`` column (added by the v4 migration), so re-saving the note
   after the target bookmark is created can upgrade the row in place.

Link sync: ``sync_links`` re-syncs a bookmark's rows from its current note on
every save (delete + insert inside the caller's transaction) — the note is the
source of truth, so re-saving an unchanged note is a no-op and removing a
wikilink drops its row. Two wikilinks on the same line resolving to the same
target collapse into one row. ``UNIQUE(source_id, target_id, line_number)``
treats NULLs as distinct, so unresolved rows are deduped here in application
logic by ``(None, target_title, line_number)``.

Backlinks: ``get_backlinks`` returns linked mentions (``links`` rows where
``target_id`` = the bookmark) and unlinked mentions (FTS5 phrase match of the
target's title across OTHER note_bodies, excluding self and excluding sources
that already link to the target — the link-it affordance is only offered where
it would actually create a link). Both lists carry the link-it payload
(``source_id`` + ``line_number``) and a context snippet.

Parsing and link writes are local SQL (no I/O), so ``save_note`` runs
synchronously inside the save handler without blocking it on anything but the
DB transaction.
"""

from __future__ import annotations

import re
import sqlite3
from dataclasses import dataclass

from app import db

# Aristos-style wikilink regex: [[target]] or [[target|display]], single line,
# target/display must not contain brackets, pipes or newlines.
WIKILINK_RE = re.compile(r"\[\[([^\[\]|\n]+?)(?:\|([^\[\]\n]*))?\]\]")

# Window either side of a match inside a snippet; the result is ~120 chars.
_SNIPPET_RADIUS = 60

# Same sanitizer as app/db.py:fts_query — anything that isn't a word/hyphen/
# space is dropped so a title can't break out of the FTS5 phrase syntax.
_FTS_SANITIZE = re.compile(r"[^\w\s-]+", re.UNICODE)


@dataclass(frozen=True, slots=True)
class Wikilink:
    """One parsed wikilink: the target text, the optional display part (the
    wikilink's own alias — stored in ``links.display_text``), and the 1-based
    line of the note the link appeared on."""

    target: str
    display: str | None
    line_number: int


def parse_wikilinks(note_body: str) -> list[Wikilink]:
    """Return every wikilink in ``note_body`` in occurrence order.

    Line numbers are 1-based. ``[[target|]]`` (empty display) is treated as
    ``[[target]]``; malformed links like ``[[|display]]`` are skipped.
    """
    links_: list[Wikilink] = []
    line_number = 1
    for match in WIKILINK_RE.finditer(note_body):
        line_number = note_body.count("\n", 0, match.start()) + 1
        target = match.group(1).strip()
        display = match.group(2)
        display = display.strip() if display is not None and display.strip() else None
        if not target:
            continue
        links_.append(Wikilink(target=target, display=display, line_number=line_number))
    return links_


def resolve_target(conn: sqlite3.Connection, target: str) -> tuple[int | None, str]:
    """Resolve a wikilink ``target`` to a bookmark id.

    Order: exact ``title`` match, then case-insensitive substring of title or
    url, then no match. Always returns the raw target text as the second
    element — the caller decides whether to record it as ``target_title``.
    """
    row = conn.execute("SELECT id FROM bookmarks WHERE title = ? LIMIT 1", (target,)).fetchone()
    if row is not None:
        return row["id"], target
    needle = f"%{target}%"
    row = conn.execute(
        "SELECT id FROM bookmarks WHERE title LIKE ? COLLATE NOCASE "
        "OR url LIKE ? COLLATE NOCASE ORDER BY id LIMIT 1",
        (needle, needle),
    ).fetchone()
    if row is not None:
        return row["id"], target
    return None, target


def sync_links(conn: sqlite3.Connection, source_id: int, note_body: str) -> None:
    """Re-sync ``source_id``'s links rows from its current ``note_body``.

    Callers must already hold a write transaction. Existing rows are replaced
    by the freshly parsed set, so this is idempotent per note state and drops
    rows for wikilinks that were removed.
    """
    conn.execute("DELETE FROM links WHERE source_id = ?", (source_id,))
    seen: set[tuple[int | None, str, int]] = set()
    for link in parse_wikilinks(note_body):
        target_id, raw_target = resolve_target(conn, link.target)
        target_title = "" if target_id is not None else raw_target
        key = (target_id, target_title, link.line_number)
        if key in seen:
            continue
        seen.add(key)
        display = link.display if link.display is not None else link.target
        conn.execute(
            "INSERT INTO links (source_id, target_id, target_title, display_text, line_number)"
            " VALUES (?, ?, ?, ?, ?)",
            (source_id, target_id, target_title, display, link.line_number),
        )


def save_note(bookmark_id: int, note_body: str) -> bool:
    """Update a bookmark's ``note_body`` and re-sync its links atomically.

    Returns False when the bookmark does not exist. All work is local SQL on
    the worker thread (no I/O), so the save handler never blocks on parsing.
    """
    with db.transaction() as conn:
        cur = conn.execute(
            "UPDATE bookmarks SET note_body = ? WHERE id = ?", (note_body, bookmark_id)
        )
        if cur.rowcount == 0:
            return False
        sync_links(conn, bookmark_id, note_body)
    return True


def get_backlinks(bookmark_id: int) -> dict | None:
    """Return linked + unlinked mentions of ``bookmark_id``.

    Returns None when the bookmark does not exist. ``linked`` rows carry
    ``source_id``/``source_title``/``display_text``/``line_number``/``snippet``;
    ``unlinked`` rows carry ``source_id``/``source_title``/``line_number``/
    ``snippet``. In both lists ``source_id`` + ``line_number`` are the link-it
    payload the UI needs to rewrite the mention into a wikilink.
    """
    conn = db.get_conn()
    target_row = conn.execute(
        "SELECT title FROM bookmarks WHERE id = ?", (bookmark_id,)
    ).fetchone()
    if target_row is None:
        return None

    linked: list[dict] = []
    rows = conn.execute(
        """
        SELECT l.source_id, b.title AS source_title, l.display_text, l.line_number, b.note_body
          FROM links l
          JOIN bookmarks b ON b.id = l.source_id
         WHERE l.target_id = ?
         ORDER BY l.source_id, l.line_number
        """,
        (bookmark_id,),
    ).fetchall()
    for r in rows:
        linked.append(
            {
                "source_id": r["source_id"],
                "source_title": r["source_title"],
                "display_text": r["display_text"],
                "line_number": r["line_number"],
                "snippet": _snippet_for_line(r["note_body"], r["line_number"]),
            }
        )

    unlinked: list[dict] = []
    phrase = _phrase_for(target_row["title"])
    if phrase is not None:
        rows = conn.execute(
            """
            SELECT b.id AS source_id, b.title AS source_title, b.note_body
              FROM bookmarks b
              JOIN bookmarks_fts f ON f.rowid = b.id
             WHERE b.id != ?
               AND bookmarks_fts MATCH ?
               AND b.id NOT IN (SELECT source_id FROM links WHERE target_id = ?)
             ORDER BY b.id
            """,
            (bookmark_id, f'note_body: "{phrase}"', bookmark_id),
        ).fetchall()
        for r in rows:
            unlinked.append(
                {
                    "source_id": r["source_id"],
                    "source_title": r["source_title"],
                    "line_number": _line_of(r["note_body"], target_row["title"]),
                    "snippet": _snippet(r["note_body"], target_row["title"]),
                }
            )

    return {"linked": linked, "unlinked": unlinked}


# ---------------------------------------------------------------------------
# Snippet helpers
# ---------------------------------------------------------------------------


def _phrase_for(title: str) -> str | None:
    """An FTS5 phrase from a title, or None when the title has no tokens."""
    cleaned = _FTS_SANITIZE.sub(" ", title).strip()
    tokens = [t for t in cleaned.split() if t]
    if not tokens:
        return None
    return " ".join(tokens)


def _snippet(text: str, needle: str) -> str:
    """A ~120-char window around the first case-insensitive ``needle``."""
    idx = text.lower().find(needle.lower())
    if idx < 0:
        idx = 0
    return _window(text, idx, len(needle))


def _snippet_for_line(note_body: str, line_number: int) -> str:
    """A snippet from the note's ``line_number``-th line around its wikilink."""
    lines = note_body.split("\n")
    line = lines[line_number - 1] if 1 <= line_number <= len(lines) else note_body
    match = WIKILINK_RE.search(line)
    if match is None:
        return _window(line, 0, len(line) or 1)
    return _window(line, match.start(), len(match.group(0)))


def _window(text: str, start: int, length: int) -> str:
    """Clip ``[start, start+length)`` to a ±``_SNIPPET_RADIUS`` window."""
    begin = max(0, start - _SNIPPET_RADIUS)
    end = min(len(text), start + length + _SNIPPET_RADIUS)
    prefix = "..." if begin > 0 else ""
    suffix = "..." if end < len(text) else ""
    return f"{prefix}{text[begin:end]}{suffix}"


def _line_of(note_body: str, needle: str) -> int:
    """1-based line number of the first case-insensitive ``needle`` occurrence."""
    idx = note_body.lower().find(needle.lower())
    if idx < 0:
        return 1
    return note_body.count("\n", 0, idx) + 1
