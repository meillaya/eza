"""Tests for the markdown notes export CLI (app/export_notes.py)."""

from __future__ import annotations

from pathlib import Path

from app import db
from app.export_notes import export_notes, main


def _seed_note(bookmark_id: int, note_body: str, extracted_text: str = "") -> None:
    db.get_conn().execute(
        "UPDATE bookmarks SET note_body = ?, extracted_text = ? WHERE id = ?",
        (note_body, extracted_text, bookmark_id),
    )


def _add_link(source_id: int, target_id: int) -> None:
    db.get_conn().execute(
        "INSERT INTO links (source_id, target_id, display_text, line_number)"
        " VALUES (?, ?, '', 1)",
        (source_id, target_id),
    )


def _unquote(value: str) -> str:
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    return value


def _parse_frontmatter(raw: str) -> tuple[dict, str]:
    """Split a rendered .md into (frontmatter dict, body)."""
    header, sep, body = raw.partition("\n---\n")
    assert sep, "missing closing frontmatter delimiter"
    assert header.startswith("---\n"), "missing opening frontmatter delimiter"
    fm: dict = {}
    tags: list[str] | None = None
    for line in header[4:].splitlines():
        if line.startswith("  - "):
            assert tags is not None, "list item outside tags"
            tags.append(_unquote(line[4:]))
            continue
        key, _, value = line.partition(": ")
        key = key.rstrip(":")
        if key == "tags":
            tags = []
            fm[key] = tags
            if value == "[]":
                continue
            if value:
                tags.append(_unquote(value))
        else:
            fm[key] = _unquote(value)
    return fm, body


def _md_files(out: Path) -> list[str]:
    return sorted(p.name for p in out.glob("*.md"))


def test_export_writes_one_md_per_note(fresh_db, tmp_path):
    a = db.insert_bookmark(url="https://a.example/", title="Alpha Note", tags=["rust", "web"])
    b = db.insert_bookmark(url="https://b.example/", title="Beta Note")
    c = db.insert_bookmark(url="https://c.example/", title="No Note")
    _seed_note(a, "First **markdown** body.\n\n- list item", extracted_text="SECRET EXTRACTED")
    _seed_note(b, "Second note body.")

    out = tmp_path / "out"
    count = export_notes(out)

    assert count == 2
    assert _md_files(out) == [f"{a}-alpha-note.md", f"{b}-beta-note.md"]
    assert f"{c}-no-note.md" not in _md_files(out)  # no note body → skipped by default

    raw = (out / f"{a}-alpha-note.md").read_text(encoding="utf-8")
    fm, body = _parse_frontmatter(raw)
    row = db.get_bookmark(a)
    assert row is not None
    created = row["created_at"]
    assert fm["title"] == "Alpha Note"
    assert fm["url"] == "https://a.example/"
    assert int(fm["created"]) == created
    assert fm["tags"] == ["rust", "web"]
    assert "First **markdown** body." in body
    assert "- list item" in body
    assert "SECRET EXTRACTED" not in raw  # extracted_text is off by default

    raw_b = (out / f"{b}-beta-note.md").read_text(encoding="utf-8")
    fm_b, body_b = _parse_frontmatter(raw_b)
    assert fm_b["tags"] == []
    assert body_b.strip() == "Second note body."


def test_export_empty_db_writes_nothing(fresh_db, tmp_path):
    out = tmp_path / "out"
    count = export_notes(out)
    assert count == 0
    assert out.is_dir()
    assert list(out.glob("*.md")) == []


def test_export_all_includes_bookmarks_without_notes(fresh_db, tmp_path):
    a = db.insert_bookmark(url="https://a.example/", title="Alpha Note")
    _seed_note(a, "body")
    b = db.insert_bookmark(url="https://b.example/", title="No Note")

    out = tmp_path / "out"
    count = export_notes(out, all_notes=True)

    assert count == 2
    assert _md_files(out) == [f"{a}-alpha-note.md", f"{b}-no-note.md"]
    fm_b, _ = _parse_frontmatter((out / f"{b}-no-note.md").read_text(encoding="utf-8"))
    assert fm_b["title"] == "No Note"


def test_include_extracted_adds_extracted_text(fresh_db, tmp_path):
    a = db.insert_bookmark(url="https://a.example/", title="Alpha Note")
    _seed_note(a, "body", extracted_text="Full article text.")

    out = tmp_path / "out"
    count = export_notes(out, include_extracted=True)

    assert count == 1
    raw = (out / f"{a}-alpha-note.md").read_text(encoding="utf-8")
    assert "## Extracted Text" in raw
    assert "Full article text." in raw


def test_export_includes_links_list(fresh_db, tmp_path):
    a = db.insert_bookmark(url="https://a.example/", title="Alpha Note")
    b = db.insert_bookmark(url="https://b.example/", title="Beta Note")
    _seed_note(a, "links to [[Beta Note]]")
    _seed_note(b, "note body")
    _add_link(source_id=a, target_id=b)

    out = tmp_path / "out"
    count = export_notes(out)

    assert count == 2
    raw_a = (out / f"{a}-alpha-note.md").read_text(encoding="utf-8")
    assert "## Links" in raw_a
    assert "### Outgoing" in raw_a
    assert "- [Beta Note](https://b.example/)" in raw_a

    raw_b = (out / f"{b}-beta-note.md").read_text(encoding="utf-8")
    assert "### Backlinks" in raw_b
    assert "- [Alpha Note](https://a.example/)" in raw_b


def test_filename_slug_is_safe(fresh_db, tmp_path):
    a = db.insert_bookmark(url="https://a.example/", title="Rust & Web / C++ Notes?!")
    _seed_note(a, "body")

    out = tmp_path / "out"
    assert export_notes(out) == 1
    assert _md_files(out) == [f"{a}-rust-web-c-notes.md"]


def test_export_uses_id_when_title_empty(fresh_db, tmp_path):
    a = db.insert_bookmark(url="https://a.example/")
    _seed_note(a, "body")

    out = tmp_path / "out"
    assert export_notes(out) == 1
    assert list(out.glob("*.md")) == [out / f"{a}-bookmark.md"]


def test_export_does_not_modify_db(fresh_db, tmp_path):
    a = db.insert_bookmark(url="https://a.example/", title="Alpha Note", tags=["rust"])
    b = db.insert_bookmark(url="https://b.example/", title="Beta Note")
    _seed_note(a, "body")
    _add_link(a, b)

    conn = db.get_conn()
    before_bookmarks = conn.execute("SELECT COUNT(*) FROM bookmarks").fetchone()[0]
    before_links = conn.execute("SELECT COUNT(*) FROM links").fetchone()[0]
    before_note = conn.execute("SELECT note_body FROM bookmarks WHERE id = ?", (a,)).fetchone()[0]
    before_version = conn.execute("PRAGMA user_version").fetchone()[0]

    export_notes(tmp_path / "out")

    assert conn.execute("SELECT COUNT(*) FROM bookmarks").fetchone()[0] == before_bookmarks
    assert conn.execute("SELECT COUNT(*) FROM links").fetchone()[0] == before_links
    assert (
        conn.execute("SELECT note_body FROM bookmarks WHERE id = ?", (a,)).fetchone()[0]
        == before_note
    )
    assert conn.execute("PRAGMA user_version").fetchone()[0] == before_version


def test_main_exports_via_argv(fresh_db, tmp_path):
    a = db.insert_bookmark(url="https://a.example/", title="Alpha Note")
    _seed_note(a, "body")

    out = tmp_path / "out"
    assert main([str(out)]) == 0
    assert (out / f"{a}-alpha-note.md").exists()
