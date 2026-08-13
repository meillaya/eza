"""Tests for the Netscape HTML exporter (todo 31).

The exporter writes a Chromium-compatible bookmarks.html:

- the canonical header, byte-for-byte what Chromium's
  ``bookmark_html_writer.cc`` writes (DOCTYPE NETSCAPE-Bookmark-file-1, the
  generated-file comment, META charset, TITLE/H1, ``<DL><p>``), with ``\r\n``
  line endings everywhere;
- ``ADD_DATE``/``LAST_MODIFIED`` as unix seconds, and the ``ICON`` data URL
  when a favicon exists;
- a ``PERSONAL_TOOLBAR_FOLDER`` folder for the configured toolbar tag;
- Chromium's "Other bucket" flattening: every non-toolbar bookmark is written
  one level up (directly under the root ``<DL>``) — exactly how Chromium
  writes the descendants of "Other bookmarks" / "Mobile bookmarks";
- notes excluded by default; only ``with_notes=True`` adds them (as ``<DD>``
  descriptions);
- non-http(s) URLs skipped.

Round-trip contract: the exported file must import back cleanly through the
EXISTING importer (``api_import``) with the URL set — and for titles, the
exact text — preserved.
"""

from __future__ import annotations

import io

import pytest
from fastapi import UploadFile
from fastapi.testclient import TestClient

from app import auth, db, exporter
from app.main import api_import, app

# A tiny 1x1 transparent PNG, base64 — the favicon fixture.
_PNG_DATA_URL = (
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"
    "AAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
)

_CANONICAL_FIRST_LINES = [
    "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
    "<!-- This is an automatically generated file.",
    "     It will be read and overwritten.",
    "     DO NOT EDIT! -->",
    '<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">',
    "<TITLE>Bookmarks</TITLE>",
    "<H1>Bookmarks</H1>",
    "<DL><p>",
]


def _authed_client() -> TestClient:
    """A TestClient preloaded with a normal-scope session + csrf cookies."""
    sid = auth.create_session(scope="normal")
    csrf = db.get_conn().execute(
        "SELECT csrf_token FROM sessions WHERE id = ?", (sid,)
    ).fetchone()["csrf_token"]
    client = TestClient(app)
    client.cookies.set(auth.SESSION_COOKIE_NAME, sid)
    client.cookies.set("csrf_token", csrf)
    return client


async def _reimport(content: str, monkeypatch: pytest.MonkeyPatch, tmp_path) -> dict[str, str]:
    """Import ``content`` into a brand-new temp DB; return {url: title}."""
    p2 = tmp_path / "reimport.db"
    monkeypatch.setattr(db, "DB_PATH", p2)
    monkeypatch.setattr(db, "_conn", None)
    db.get_conn()
    file = UploadFile(filename="rt.html", file=io.BytesIO(content.encode("utf-8")))
    await api_import(file)
    return {b["url"]: b["title"] for b in db.list_bookmarks(limit=1000)}


# ---------------------------------------------------------------------------
# Header + line endings
# ---------------------------------------------------------------------------


def test_header_exact_first_lines_and_crlf(fresh_db):
    content = exporter.export_bookmarks()
    lines = content.splitlines()
    assert lines[:8] == _CANONICAL_FIRST_LINES
    # Every newline is \r\n (no bare \n anywhere).
    assert "\n" not in content.replace("\r\n", "")
    assert content.endswith("</DL><p>\r\n")


# ---------------------------------------------------------------------------
# Bookmark lines: attributes + escaping
# ---------------------------------------------------------------------------


def test_bookmark_line_attributes_and_favicon(fresh_db):
    db.insert_bookmark(url="https://attr.example/", title="Attr", favicon_url=_PNG_DATA_URL)
    content = exporter.export_bookmarks()
    line = next(ln for ln in content.splitlines() if "https://attr.example/" in ln)
    assert line.startswith('    <DT><A HREF="https://attr.example/"')
    assert ' ADD_DATE="' in line
    assert f' ICON="{_PNG_DATA_URL}">Attr</A>' in line


@pytest.mark.asyncio
async def test_title_escaping_survives_round_trip(fresh_db, monkeypatch, tmp_path):
    title = 'A & B "quoted" <tag> \'single\''
    db.insert_bookmark(url="https://esc.example/", title=title)
    content = exporter.export_bookmarks()
    assert "A &amp; B &quot;quoted&quot; &lt;tag&gt; &#39;single&#39;</A>" in content
    imported = await _reimport(content, monkeypatch, tmp_path)
    assert imported["https://esc.example/"] == title


def test_no_title_uses_url_as_title(fresh_db):
    db.insert_bookmark(url="https://untitled.example/", title="")
    content = exporter.export_bookmarks()
    assert '>https://untitled.example/</A>' in content


def test_skips_non_http_urls(fresh_db):
    db.insert_bookmark(url="https://valid.example/", title="V")
    db.insert_bookmark(url="javascript:alert(1)", title="JS")
    db.insert_bookmark(url="file:///etc/passwd", title="FILE")
    content = exporter.export_bookmarks()
    assert "https://valid.example/" in content
    assert "javascript:alert(1)" not in content
    assert "file:///etc/passwd" not in content


# ---------------------------------------------------------------------------
# Toolbar folder + Other-bucket flattening (Chromium behavior)
# ---------------------------------------------------------------------------


def test_toolbar_tag_becomes_personal_toolbar_folder(fresh_db):
    db.insert_bookmark(url="https://toolbar.example/", title="Toolbar", tags=["toolbar"])
    db.insert_bookmark(url="https://plain.example/", title="Plain")
    content = exporter.export_bookmarks(toolbar_tag="toolbar")
    assert 'PERSONAL_TOOLBAR_FOLDER="true"' in content
    toolbar_idx = content.index('PERSONAL_TOOLBAR_FOLDER="true"')
    toolbar_close = content.index("</DL><p>", toolbar_idx)
    block = content[toolbar_idx:toolbar_close]
    assert "https://toolbar.example/" in block
    assert "https://plain.example/" not in block
    # The plain bookmark is flattened one level up — after the toolbar
    # folder's </DL><p>, directly under the root DL, no H3 wrapper.
    after = content[toolbar_close + len("</DL><p>") :]
    assert "https://plain.example/" in after


def test_other_bucket_children_written_one_level_up(fresh_db):
    db.insert_bookmark(url="https://toolbar.example/", title="Toolbar", tags=["toolbar"])
    db.insert_bookmark(url="https://other.example/", title="Other", tags=["other"])
    db.insert_bookmark(url="https://mobile.example/", title="Mobile", tags=["mobile"])
    db.insert_bookmark(url="https://untagged.example/", title="Untagged")
    content = exporter.export_bookmarks(toolbar_tag="toolbar")
    toolbar_idx = content.index('PERSONAL_TOOLBAR_FOLDER="true"')
    after = content[content.index("</DL><p>", toolbar_idx) + len("</DL><p>") :]
    # The other/mobile/untagged bookmarks are written one level up: as direct
    # <DT><A> children of the root DL, never wrapped in an H3 folder.
    for url in ("https://other.example/", "https://mobile.example/", "https://untagged.example/"):
        assert f'<DT><A HREF="{url}"' in after
    assert "<DT><H3" not in after


# ---------------------------------------------------------------------------
# Notes: excluded by default, <DD> descriptions with --with-notes
# ---------------------------------------------------------------------------


def test_notes_excluded_by_default(fresh_db):
    bm_id = db.insert_bookmark(url="https://note.example/", title="Note")
    db.update_bookmark(bm_id, note_body="secret private note")
    content = exporter.export_bookmarks()
    assert "secret private note" not in content
    content2 = exporter.export_bookmarks(with_notes=True)
    assert "<DD>secret private note</DD>" in content2


def test_note_content_escaped_with_with_notes(fresh_db):
    bm_id = db.insert_bookmark(url="https://note2.example/", title="Note2")
    db.update_bookmark(bm_id, note_body='see "x" & <y>')
    content = exporter.export_bookmarks(with_notes=True)
    assert "<DD>see &quot;x&quot; &amp; &lt;y&gt;</DD>" in content


# ---------------------------------------------------------------------------
# Round trip through the existing importer
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_round_trip_url_set_preserved(fresh_db, monkeypatch, tmp_path):
    urls = {
        "https://rt.example/a": "Alpha & beta \"quoted\"",
        "https://rt.example/b": "",
        "https://rt.example/c": "C",
    }
    for url, title in urls.items():
        db.insert_bookmark(url=url, title=title)
    content = exporter.export_bookmarks(with_notes=True)
    imported = await _reimport(content, monkeypatch, tmp_path)
    assert set(imported) == set(urls)
    # The empty-title bookmark re-imports as the URL (importer-side fallback
    # keeps the URL set intact).
    assert "https://rt.example/c" in imported


# ---------------------------------------------------------------------------
# HTTP route: GET /api/export
# ---------------------------------------------------------------------------


def test_export_route_requires_auth(fresh_db):
    client = TestClient(app)
    resp = client.get("/api/export")
    assert resp.status_code == 401


def test_export_route_headers_and_content(fresh_db):
    db.insert_bookmark(url="https://route.example/", title="Route")
    client = _authed_client()
    resp = client.get("/api/export")
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "text/html; charset=utf-8"
    assert resp.headers["content-disposition"] == 'attachment; filename="bookmarks.html"'
    assert resp.text.startswith("<!DOCTYPE NETSCAPE-Bookmark-file-1>")
    assert "https://route.example/" in resp.text
