"""Netscape bookmarks.html exporter (todo 31) — Chromium-compatible writer.

Renders the whole library as a single ``bookmarks.html`` in the Netscape
bookmark-file format, byte-compatible with what Chromium's
``bookmark_html_writer.cc`` produces so the file imports cleanly back into
Chrome/Firefox/Edge/Safari AND back into this app's existing importer.

Layout mirrors Chromium exactly:

- The canonical header (DOCTYPE + generated-file comment + META charset +
  TITLE/H1 + ``<DL><p>``), every line ``\r\n``-terminated.
- One folder carries ``PERSONAL_TOOLBAR_FOLDER="true"``: the bookmarks tagged
  with the configured toolbar tag (``EXPORT_TOOLBAR_TAG`` env,
  default ``toolbar``).
- Every OTHER bookmark is the "Other bucket": its children are written one
  level up — as direct ``<DT><A>`` children of the root ``<DL>``, never
  wrapped in an ``<H3>`` folder. That is precisely Chromium's
  ``bookmark_html_writer.cc`` behavior for the "Other bookmarks" / "Mobile
  bookmarks" folders (see the comment in ``Writer::DoWrite``).

Attributes follow Chromium: ``ADD_DATE``/``LAST_MODIFIED`` are unix seconds;
``ICON`` is emitted when the stored favicon is a base64 data URL or an
http(s) URL. Beyond Chromium, every tag is written as a ``TAGS="a,b"``
attribute (comma-joined, sorted) so tags survive an export→import round trip
through this app's own importer; foreign browsers that ignore ``TAGS`` are
unaffected. Escaping is Chromium's two-tier scheme: attribute values escape
only ``"`` -> ``&quot;``; content (titles, notes) uses EscapeForHTML
(``& < > " '``). A bookmark with an empty title falls back to its URL.

Notes are NEVER exported unless ``with_notes`` is set — the secret/note
columns stay out of the file by default. When enabled, ``note_body`` is
written as a ``<DD>`` description line after its bookmark (the standard
Netscape note slot Firefox uses for descriptions). Non-http(s) URLs are
skipped entirely — the export never carries ``javascript:``/``file:``/…
links.

Read-only: this module only ever SELECTs — it never modifies the database.
"""

from __future__ import annotations

import argparse
import logging
import re
import sqlite3
import sys
import time
from collections import defaultdict
from collections.abc import Iterable, Sequence
from pathlib import Path

from . import config, db

log = logging.getLogger("bookmarks.exporter")

# Canonical file header — byte-for-byte what Chromium's bookmark_html_writer.cc
# writes (kHeader in chrome/browser/bookmarks/bookmark_html_writer.cc), \r\n
# line endings included.
_HEADER = (
    "<!DOCTYPE NETSCAPE-Bookmark-file-1>\r\n"
    "<!-- This is an automatically generated file.\r\n"
    "     It will be read and overwritten.\r\n"
    "     DO NOT EDIT! -->\r\n"
    '<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">\r\n'
    "<TITLE>Bookmarks</TITLE>\r\n"
    "<H1>Bookmarks</H1>\r\n"
    "<DL><p>\r\n"
)
_NEWLINE = "\r\n"
_FOLDER_START = '<DT><H3 ADD_DATE="'
_LAST_MODIFIED = '" LAST_MODIFIED="'
_TOOLBAR_ATTR = '" PERSONAL_TOOLBAR_FOLDER="true">'
_FOLDER_ATTR_END = '">'
_FOLDER_END = "</H3>"
_FOLDER_CHILDREN = "<DL><p>"
_FOLDER_CHILDREN_END = "</DL><p>"
_BOOKMARK_START = '<DT><A HREF="'
_ADD_DATE = '" ADD_DATE="'
_TAGS = '" TAGS="'
_ICON = '" ICON="'
_BOOKMARK_ATTR_END = '">'
_BOOKMARK_END = "</A>"
_INDENT = "    "  # kIndentSize in Chromium

_HTTP_URL = re.compile(r"^https?://", re.IGNORECASE)
_FAVICON_URL = re.compile(r"^(?:data:|https?://)", re.IGNORECASE)

# Chromium's EscapeForHTML (base/strings/escape.cc) — the content escape set.
_ESCAPE_CONTENT = str.maketrans(
    {
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
    }
)


def _escape_attribute(value: str) -> str:
    """Escape an attribute value: only ``"`` -> ``&quot;`` (ATTRIBUTE_VALUE)."""
    return value.replace('"', "&quot;")


def _escape_content(value: str) -> str:
    """Escape content text the way Chromium's EscapeForHTML does (CONTENT)."""
    return value.translate(_ESCAPE_CONTENT)


def _tags_by_bookmark(conn: sqlite3.Connection) -> dict[int, list[str]]:
    """Map bookmark id -> sorted tag names (one query, no N+1)."""
    out: dict[int, list[str]] = defaultdict(list)
    for row in conn.execute(
        "SELECT bt.bookmark_id AS bookmark_id, t.name AS name"
        " FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id"
        " ORDER BY t.name"
    ):
        out[row["bookmark_id"]].append(row["name"])
    return out


def _bookmark_line(
    url: str,
    created_at: int,
    favicon_url: str,
    title: str,
    note_body: str,
    *,
    with_notes: bool,
    tags: Sequence[str] = (),
) -> str:
    """One ``<DT><A …>title</A>`` line (plus the optional ``<DD>`` note).

    ``tags`` are written as a ``TAGS="a,b"`` attribute (comma-joined, sorted
    by the caller). The importer reads it back, so tags survive an
    export→import round trip; foreign browsers simply ignore the attribute.
    The toolbar tag rides BOTH the attribute and the toolbar folder — the
    importer dedupes the duplicate link, so the tag set is unchanged.
    """
    line = (
        _BOOKMARK_START
        + _escape_attribute(url)
        + _ADD_DATE
        + str(created_at)
    )
    if tags:
        line += _TAGS + _escape_attribute(",".join(tags))
    if favicon_url and _FAVICON_URL.match(favicon_url):
        line += _ICON + _escape_attribute(favicon_url)
    line += _BOOKMARK_ATTR_END + _escape_content(title or url) + _BOOKMARK_END
    if with_notes and note_body:
        line += _NEWLINE + _INDENT + "<DD>" + _escape_content(note_body) + "</DD>"
    return line


def export_bookmarks(
    *,
    with_notes: bool = False,
    toolbar_tag: str | None = None,
    now: int | None = None,
) -> str:
    """Render the full bookmarks.html for the current DB; returns the content.

    ``toolbar_tag`` selects the tag whose bookmarks land in the
    ``PERSONAL_TOOLBAR_FOLDER`` folder (default: ``config.EXPORT_TOOLBAR_TAG``).
    ``now`` pins the folder timestamps for deterministic tests (defaults to
    the current time). ``with_notes`` adds ``note_body`` as ``<DD>``
    descriptions. Non-http(s) URLs are skipped. Read-only.
    """
    toolbar = (toolbar_tag or config.EXPORT_TOOLBAR_TAG).strip().lower()
    now = int(time.time()) if now is None else now
    conn = db.get_conn()
    tags_by_id = _tags_by_bookmark(conn)
    rows = conn.execute(
        "SELECT id, url, title, favicon_url, created_at, note_body"
        " FROM bookmarks ORDER BY created_at ASC, id ASC"
    ).fetchall()

    bookmarks = [
        row
        for row in rows
        if _HTTP_URL.match(row["url"])
    ]
    toolbar_rows = [r for r in bookmarks if toolbar in tags_by_id.get(r["id"], ())]
    other_rows = [r for r in bookmarks if toolbar not in tags_by_id.get(r["id"], ())]

    parts: list[str] = [_HEADER]
    if toolbar_rows:
        parts.append(
            f"{_INDENT}{_FOLDER_START}{now}{_LAST_MODIFIED}{now}{_TOOLBAR_ATTR}"
            f"Bookmarks bar{_FOLDER_END}"
        )
        parts.append(f"{_INDENT}{_FOLDER_CHILDREN}")
        for row in toolbar_rows:
            parts.append(
                f"{_INDENT}{_INDENT}{_bookmark_line(row['url'], row['created_at'], row['favicon_url'], row['title'], row['note_body'], with_notes=with_notes, tags=tags_by_id.get(row['id'], ()))}"
            )
        parts.append(f"{_INDENT}{_FOLDER_CHILDREN_END}")
    # Other bucket — Chromium flattens these one level up: direct <DT><A>
    # children of the root DL, no H3 wrapper.
    for row in other_rows:
        parts.append(
            f"{_INDENT}{_bookmark_line(row['url'], row['created_at'], row['favicon_url'], row['title'], row['note_body'], with_notes=with_notes, tags=tags_by_id.get(row['id'], ()))}"
        )
    parts.append(_FOLDER_CHILDREN_END)
    return _NEWLINE.join(parts) + _NEWLINE


def _parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="bookmarks-export",
        description="Export bookmarks as a Chromium-compatible Netscape bookmarks.html "
        "(canonical header, \\r\\n line endings, PERSONAL_TOOLBAR_FOLDER for the "
        "toolbar tag, Other-bucket flattening). Read-only: never modifies the database.",
    )
    parser.add_argument(
        "out_path",
        nargs="?",
        help="file to write (default: stdout)",
    )
    parser.add_argument(
        "--with-notes",
        action="store_true",
        help="include note_body in the export (as <DD> descriptions); notes are "
        "excluded by default",
    )
    parser.add_argument(
        "--toolbar-tag",
        default=None,
        help="tag whose bookmarks land in the PERSONAL_TOOLBAR_FOLDER folder "
        "(default: EXPORT_TOOLBAR_TAG env or 'toolbar')",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    return parser.parse_args(list(argv))


def main(argv: Iterable[str] | None = None) -> int:
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    content = export_bookmarks(
        with_notes=args.with_notes,
        toolbar_tag=args.toolbar_tag,
    )
    if args.out_path:
        Path(args.out_path).write_text(content, encoding="utf-8", newline="")
        log.info("wrote bookmarks.html (%d bytes) to %s", len(content), args.out_path)
    else:
        sys.stdout.write(content)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
