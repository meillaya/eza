"""CLI: export bookmarks as one Markdown file each (portability guardrail).

Notes live in SQLite (KB schema). This CLI is the escape hatch that keeps
them portable: one ``.md`` file per bookmark with YAML-ish frontmatter
(title, url, tags, created) + the note body + a links list (the bookmark's
wikilinks/backlinks from the ``links`` table), so the library can never be
locked into the database the way Pocket locked in its users.

    uv run bookmarks-export-notes ./export              # bookmarks with a note body
    uv run bookmarks-export-notes ./export --all       # every bookmark
    uv run bookmarks-export-notes ./export --include-extracted

Read-only: this module only ever SELECTs — it never modifies the database.
"""

from __future__ import annotations

import argparse
import logging
import re
import sqlite3
import sys
from collections import defaultdict
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

from . import db

log = logging.getLogger("bookmarks.export_notes")

_SLUG_MAX = 80


@dataclass(frozen=True, slots=True)
class BookmarkNote:
    """Everything the export renders for a single bookmark."""

    id: int
    title: str
    url: str
    created_at: int
    tags: tuple[str, ...]
    note_body: str
    extracted_text: str
    outgoing: tuple[tuple[str, str], ...]  # (title, url) — links this note points at
    backlinks: tuple[tuple[str, str], ...]  # (title, url) — links pointing at this note


def _select_notes(conn: sqlite3.Connection, *, all_notes: bool) -> list[sqlite3.Row]:
    """Return the bookmarks to export: only ones with a note body by default."""
    if all_notes:
        return conn.execute("SELECT * FROM bookmarks ORDER BY created_at DESC").fetchall()
    return conn.execute(
        "SELECT * FROM bookmarks WHERE TRIM(note_body) != '' ORDER BY created_at DESC"
    ).fetchall()


def _tags_by_bookmark(conn: sqlite3.Connection) -> dict[int, list[str]]:
    out: dict[int, list[str]] = defaultdict(list)
    for row in conn.execute(
        "SELECT bt.bookmark_id AS bookmark_id, t.name AS name"
        " FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id"
        " ORDER BY t.name"
    ):
        out[row["bookmark_id"]].append(row["name"])
    return out


def _links_by_bookmark(
    conn: sqlite3.Connection,
) -> tuple[dict[int, set[int]], dict[int, set[int]]]:
    """Map bookmark id → linked bookmark ids, both directions, deduplicated."""
    outgoing: dict[int, set[int]] = defaultdict(set)
    backlinks: dict[int, set[int]] = defaultdict(set)
    for row in conn.execute("SELECT source_id, target_id FROM links"):
        outgoing[row["source_id"]].add(row["target_id"])
        backlinks[row["target_id"]].add(row["source_id"])
    return outgoing, backlinks


def _bookmark_index(conn: sqlite3.Connection) -> dict[int, tuple[str, str]]:
    """id → (title, url) for every bookmark, to resolve link endpoints."""
    return {
        row["id"]: (row["title"], row["url"])
        for row in conn.execute("SELECT id, title, url FROM bookmarks")
    }


def _resolve_links(
    index: dict[int, tuple[str, str]], ids: Iterable[int]
) -> tuple[tuple[str, str], ...]:
    """Resolve bookmark ids to (title, url) pairs, sorted, orphans dropped."""
    return tuple(sorted(index[tid] for tid in ids if tid in index))


def _build_note(
    row: sqlite3.Row,
    tags_by_bookmark: dict[int, list[str]],
    outgoing: dict[int, set[int]],
    backlinks: dict[int, set[int]],
    index: dict[int, tuple[str, str]],
) -> BookmarkNote:
    bookmark_id = row["id"]
    return BookmarkNote(
        id=bookmark_id,
        title=row["title"],
        url=row["url"],
        created_at=row["created_at"],
        tags=tuple(tags_by_bookmark.get(bookmark_id, ())),
        note_body=row["note_body"],
        extracted_text=row["extracted_text"],
        outgoing=_resolve_links(index, outgoing.get(bookmark_id, ())),
        backlinks=_resolve_links(index, backlinks.get(bookmark_id, ())),
    )


def _yaml_quote(value: str) -> str:
    """Double-quote a value into a valid single-line YAML scalar."""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _yaml_safe(value: str) -> str:
    """Strip control characters so frontmatter scalars stay on one line."""
    return re.sub(r"[\x00-\x1f\x7f]", " ", value).strip()


def _slugify(title: str) -> str:
    """Derive a filesystem-safe slug from a title ('' → 'bookmark')."""
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:_SLUG_MAX]
    return slug or "bookmark"


def _render_frontmatter(note: BookmarkNote) -> str:
    lines = ["---"]
    lines.append(f"title: {_yaml_quote(_yaml_safe(note.title))}")
    lines.append(f"url: {_yaml_quote(_yaml_safe(note.url))}")
    lines.append(f"created: {note.created_at}")
    if note.tags:
        lines.append("tags:")
        lines.extend(f"  - {_yaml_quote(tag)}" for tag in note.tags)
    else:
        lines.append("tags: []")
    lines.append("---")
    return "\n".join(lines)


def _render_links(note: BookmarkNote) -> list[str]:
    lines: list[str] = []
    if note.outgoing:
        lines += ["## Links", "", "### Outgoing", ""]
        lines += [f"- [{title or url}]({url})" for title, url in note.outgoing]
        lines.append("")
    if note.backlinks:
        if not note.outgoing:
            lines += ["## Links", "", "### Backlinks", ""]
        else:
            lines += ["### Backlinks", ""]
        lines += [f"- [{title or url}]({url})" for title, url in note.backlinks]
        lines.append("")
    return lines


def _render_markdown(note: BookmarkNote, *, include_extracted: bool) -> str:
    parts = [_render_frontmatter(note), ""]
    if note.note_body:
        parts.append(note.note_body.rstrip())
        parts.append("")
    if include_extracted and note.extracted_text:
        parts += ["## Extracted Text", "", note.extracted_text.rstrip(), ""]
    parts.extend(_render_links(note))
    return "\n".join(parts).rstrip() + "\n"


def _write_markdown(note: BookmarkNote, out_path: Path, *, include_extracted: bool) -> None:
    """Render and write one bookmark's .md file."""
    out_path.write_text(_render_markdown(note, include_extracted=include_extracted), encoding="utf-8")


def export_notes(
    out_dir: Path,
    *,
    include_extracted: bool = False,
    all_notes: bool = False,
) -> int:
    """Write one .md per selected bookmark into ``out_dir``. Returns the count.

    Never writes to the database — every query here is a read.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    conn = db.get_conn()
    tags_by_bookmark = _tags_by_bookmark(conn)
    outgoing, backlinks = _links_by_bookmark(conn)
    index = _bookmark_index(conn)

    written = 0
    for row in _select_notes(conn, all_notes=all_notes):
        note = _build_note(row, tags_by_bookmark, outgoing, backlinks, index)
        out_path = out_dir / f"{note.id}-{_slugify(note.title)}.md"
        _write_markdown(note, out_path, include_extracted=include_extracted)
        written += 1
    return written


def _parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="bookmarks-export-notes",
        description="Export bookmarks as one Markdown file each (YAML frontmatter "
        "+ note body + links list). Read-only: never modifies the database.",
    )
    parser.add_argument("export_dir", help="directory to write the .md files into")
    parser.add_argument(
        "--all",
        action="store_true",
        help="export every bookmark (default: only bookmarks with a note body)",
    )
    parser.add_argument(
        "--include-extracted",
        action="store_true",
        help="also embed the extracted_text column in each .md file",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    return parser.parse_args(list(argv))


def main(argv: Iterable[str] | None = None) -> int:
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    count = export_notes(
        Path(args.export_dir),
        include_extracted=args.include_extracted,
        all_notes=args.all,
    )
    log.info("exported %d bookmark(s) to %s", count, args.export_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
