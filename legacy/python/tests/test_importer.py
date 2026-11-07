"""Tests for the Netscape bookmark importer walker.

These are the regression tests for the two bugs that caused the original
walker to drop ~all of a real 9k-bookmark import:

  1. selectolax's `.iter()` is NOT recursive — it yields direct children.
     Using it on the top <DL> only sees the top-level folders.
  2. `css_first('a')` on a <DT> reaches into the nested <DL>, so folder
     DTs get misclassified as links and never recurse.

Both bugs must stay fixed.
"""

from __future__ import annotations

import io
import time

import pytest
from fastapi import UploadFile
from selectolax.parser import HTMLParser

from app import config, db, exporter
from app.main import _looks_like_timestamp_folder, api_import

SIMPLE = """\
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<DL><p>
    <DT><H3>Bookmarks bar</H3>
    <DL><p>
        <DT><A HREF="https://example.com/a">A</A>
        <DT><A HREF="https://example.com/b">B</A>
        <DT><H3>Dev</H3>
        <DL><p>
            <DT><A HREF="https://example.com/rust">Rust</A>
            <DT><A HREF="https://example.com/go">Go</A>
        </DL><p>
    </DL><p>
</DL><p>
"""


@pytest.mark.asyncio
async def test_simple_import(fresh_db):
    """Walks the nested DL structure and inserts every link."""
    import io

    from fastapi import UploadFile

    file = UploadFile(filename="x.html", file=io.BytesIO(SIMPLE.encode()))
    result = await api_import(file)
    assert result["inserted"] == 4
    assert result["found"] == 4

    urls = {b["url"] for b in db.list_bookmarks(limit=10)}
    assert urls == {
        "https://example.com/a",
        "https://example.com/b",
        "https://example.com/rust",
        "https://example.com/go",
    }

    # Inner folder name becomes a tag
    r = db.list_bookmarks(tags=["dev"])
    assert len(r) == 2

    # Top-level browser folder "Bookmarks bar" is recursed into but NOT a tag
    for u in ("https://example.com/a", "https://example.com/b"):
        b = db.get_bookmark(next(b["id"] for b in db.list_bookmarks() if b["url"] == u))
        assert b is not None
        assert b["tags"] == []


@pytest.mark.asyncio
async def test_skips_non_http_urls(fresh_db):
    """chrome://, javascript:, chrome-extension:// should be filtered."""
    import io

    from fastapi import UploadFile

    html = """\
<DL><p>
    <DT><A HREF="https://valid.example/">V</A>
    <DT><A HREF="chrome://bookmarks/">C</A>
    <DT><A HREF="javascript:alert(1)">JS</A>
    <DT><A HREF="chrome-extension://abc/page.html">CE</A>
</DL><p>
"""
    file = UploadFile(filename="x.html", file=io.BytesIO(html.encode()))
    result = await api_import(file)
    assert result["inserted"] == 1


@pytest.mark.asyncio
async def test_timestamp_folder_names_dropped_as_tags(fresh_db):
    """Session-manager exports with timestamp folder names should still be
    recursed into (their URLs are real bookmarks) but the timestamp itself
    should NOT become a tag."""
    import io

    from fastapi import UploadFile

    html = """\
<DL><p>
    <DT><H3>new folder – 18 apr 2025 14:06:10 GMT-04:00</H3>
    <DL><p>
        <DT><A HREF="https://a.example/">A</A>
        <DT><A HREF="https://b.example/">B</A>
    </DL><p>
    <DT><H3>Reading</H3>
    <DL><p>
        <DT><A HREF="https://c.example/">C</A>
    </DL><p>
</DL><p>
"""
    file = UploadFile(filename="x.html", file=io.BytesIO(html.encode()))
    result = await api_import(file)
    assert result["inserted"] == 3

    # Timestamp folder did NOT become a tag
    assert db.list_bookmarks(tags=["new folder – 18 apr 2025 14:06:10 gmt-04:00"]) == []
    # But its URLs are in the DB
    urls = {b["url"] for b in db.list_bookmarks(limit=10)}
    assert "https://a.example/" in urls
    assert "https://b.example/" in urls

    # The genuinely useful folder name DID become a tag
    assert len(db.list_bookmarks(tags=["reading"])) == 1


def test_looks_like_timestamp_folder():
    assert _looks_like_timestamp_folder("new folder – 18 apr 2025 14:06:10 GMT-04:00")
    assert _looks_like_timestamp_folder("nov 7, 2024 3:56:44 am est")
    assert _looks_like_timestamp_folder("2025-01-29 10:35:11")
    assert _looks_like_timestamp_folder("Apr 18, 2025")
    assert not _looks_like_timestamp_folder("Reading list")
    assert not _looks_like_timestamp_folder("Dev")
    assert not _looks_like_timestamp_folder("~/projects")


def test_walker_classifies_by_direct_children_only():
    """Regression: a folder DT contains H3 + nested DL with A links. The
    walker must look at the DT's DIRECT children, not css('a'), otherwise
    it treats the folder DT as a link and never recurses.
    """
    html = HTMLParser(SIMPLE)
    top = html.css_first("dl")
    assert top is not None

    # Top-level iter is NOT recursive: only direct children are seen.
    direct_children = [c for c in top.iter() if c is not top]
    assert len(direct_children) == 2  # the <p> and one outer <DT>
    assert direct_children[1].tag == "dt"

    # The outer DT contains H3 + nested DL. Its DIRECT children:
    dt_kids = [c.tag for c in direct_children[1].iter() if c is not direct_children[1]]
    assert "h3" in dt_kids
    assert "dl" in dt_kids
    # The nested A's are NOT direct children of this outer DT — they're
    # inside the nested DL. This is what makes css('a') on the outer DT
    # wrong.


# ---------------------------------------------------------------------------
# Task-32 hardening: TAGS attribute, META charset, HR separators,
# toolbar/unfiled folder mapping, ADD_DATE default, uppercase schemes,
# line-split tags. Existing cases above are untouched.
# ---------------------------------------------------------------------------


def _bookmark_by_url(url: str) -> dict:
    row = next(b for b in db.list_bookmarks(limit=100) if b["url"] == url)
    book = db.get_bookmark(row["id"])
    assert book is not None
    return book


@pytest.mark.asyncio
async def test_tags_attribute_creates_tags_in_addition_to_folder_tags(fresh_db):
    """TAGS="a,b" on an <A> becomes tags ON TOP OF the folder-derived tags."""
    html = """\
<DL><p>
    <DT><H3>Dev</H3>
    <DL><p>
        <DT><A HREF="https://example.com/tagged" TAGS="rust,web">Tagged</A>
    </DL><p>
</DL><p>
"""
    file = UploadFile(filename="x.html", file=io.BytesIO(html.encode()))
    result = await api_import(file)
    assert result["inserted"] == 1

    b = _bookmark_by_url("https://example.com/tagged")
    assert set(b["tags"]) == {"dev", "rust", "web"}


@pytest.mark.asyncio
async def test_charset_iso8859_1_file_decodes(fresh_db):
    """A file declaring <meta charset="iso-8859-1"> decodes with that charset."""
    html = '<meta charset="iso-8859-1">\n<DL><p>\n    <DT><A HREF="https://example.com/cafe">café</A>\n</DL><p>\n'
    file = UploadFile(filename="x.html", file=io.BytesIO(html.encode("iso-8859-1")))
    result = await api_import(file)
    assert result["inserted"] == 1

    b = _bookmark_by_url("https://example.com/cafe")
    assert b["title"] == "café"


@pytest.mark.asyncio
async def test_utf8_fallback_when_no_meta_charset(fresh_db):
    """No <META charset> declaration → UTF-8 is the fallback."""
    html = '<DL><p>\n    <DT><A HREF="https://example.com/utf8">naïve</A>\n</DL><p>\n'
    file = UploadFile(filename="x.html", file=io.BytesIO(html.encode("utf-8")))
    result = await api_import(file)
    assert result["inserted"] == 1

    b = _bookmark_by_url("https://example.com/utf8")
    assert b["title"] == "naïve"


@pytest.mark.asyncio
async def test_charset_windows1252_honors_meta_declaration(fresh_db):
    """The declared META charset drives the decode (a latin-1 fallback would
    garble the 0x80-0x9F range used by Windows-1252 curly quotes)."""
    html = '<meta charset="windows-1252">\n<DL><p>\n    <DT><A HREF="https://example.com/q">“quoted”</A>\n</DL><p>\n'
    file = UploadFile(filename="x.html", file=io.BytesIO(html.encode("windows-1252")))
    result = await api_import(file)
    assert result["inserted"] == 1

    b = _bookmark_by_url("https://example.com/q")
    assert b["title"] == "“quoted”"


@pytest.mark.asyncio
async def test_skips_hr_separators(fresh_db):
    """<HR> separators (bare and inside <DT>) import nothing and crash nothing."""
    html = """\
<DL><p>
    <DT><A HREF="https://example.com/one">One</A>
    <HR>
    <DT><A HREF="https://example.com/two">Two</A>
    <DT><HR>
    <DT><A HREF="https://example.com/three">Three</A>
</DL><p>
"""
    file = UploadFile(filename="x.html", file=io.BytesIO(html.encode()))
    result = await api_import(file)
    assert result["inserted"] == 3
    assert result["found"] == 3


@pytest.mark.asyncio
async def test_personal_toolbar_folder_bookmarks_get_toolbar_tags(fresh_db):
    """PERSONAL_TOOLBAR_FOLDER="true" → bookmarks get the configured toolbar
    tag instead of being dropped or tagged with the generic folder name."""
    html = """\
<DL><p>
    <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
    <DL><p>
        <DT><A HREF="https://example.com/tool">Tool</A>
    </DL><p>
</DL><p>
"""
    file = UploadFile(filename="x.html", file=io.BytesIO(html.encode()))
    result = await api_import(file)
    assert result["inserted"] == 1

    b = _bookmark_by_url("https://example.com/tool")
    assert b["tags"] == [config.IMPORT_TOOLBAR_TAG]
    assert config.IMPORT_TOOLBAR_TAG == "toolbar"


@pytest.mark.asyncio
async def test_unfiled_bookmarks_folder_bookmarks_get_unfiled_tags(fresh_db):
    """UNFILED_BOOKMARKS_FOLDER="true" → bookmarks get the configured unfiled
    tag instead of being dropped."""
    html = """\
<DL><p>
    <DT><H3 UNFILED_BOOKMARKS_FOLDER="true">Other bookmarks</H3>
    <DL><p>
        <DT><A HREF="https://example.com/uf">Uf</A>
    </DL><p>
</DL><p>
"""
    file = UploadFile(filename="x.html", file=io.BytesIO(html.encode()))
    result = await api_import(file)
    assert result["inserted"] == 1

    b = _bookmark_by_url("https://example.com/uf")
    assert b["tags"] == [config.IMPORT_UNFILED_TAG]
    assert config.IMPORT_UNFILED_TAG == "unfiled"


@pytest.mark.asyncio
async def test_add_date_missing_defaults_to_now(fresh_db):
    """A bookmark with no ADD_DATE still imports and gets a fresh created_at."""
    html = """\
<DL><p>
    <DT><A HREF="https://example.com/with" ADD_DATE="1234567890">With</A>
    <DT><A HREF="https://example.com/without">Without</A>
</DL><p>
"""
    file = UploadFile(filename="x.html", file=io.BytesIO(html.encode()))
    result = await api_import(file)
    assert result["inserted"] == 2

    before = int(time.time())
    b = _bookmark_by_url("https://example.com/without")
    assert isinstance(b["created_at"], int)
    assert b["created_at"] > 0
    assert b["created_at"] <= before
    assert b["created_at"] > before - 300


@pytest.mark.asyncio
async def test_uppercase_http_href_accepted(fresh_db):
    """HTTPS:// / HTTP:// (uppercase schemes) are accepted, not dropped."""
    html = """\
<DL><p>
    <DT><A HREF="HTTPS://EXAMPLE.COM">U</A>
    <DT><A HREF="HTTP://EXAMPLE.ORG">V</A>
</DL><p>
"""
    file = UploadFile(filename="x.html", file=io.BytesIO(html.encode()))
    result = await api_import(file)
    assert result["inserted"] == 2

    urls = {b["url"] for b in db.list_bookmarks(limit=10)}
    assert "HTTPS://EXAMPLE.COM" in urls
    assert "HTTP://EXAMPLE.ORG" in urls


@pytest.mark.asyncio
async def test_line_split_tags_tolerated(fresh_db):
    """A TAGS value split across lines (Chromium's line-based output) parses
    into both tags and does not lose the bookmark."""
    html = """\
<DL><p>
    <DT><A HREF="https://example.com/split" TAGS="alpha,
beta">Split</A>
</DL><p>
"""
    file = UploadFile(filename="x.html", file=io.BytesIO(html.encode()))
    result = await api_import(file)
    assert result["inserted"] == 1

    b = _bookmark_by_url("https://example.com/split")
    assert set(b["tags"]) == {"alpha", "beta"}


# ---------------------------------------------------------------------------
# Task-33 round-trip: dedup + TAGS-exported rows (existing cases above are
# untouched)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_duplicate_urls_deduped_on_import(fresh_db):
    """UNIQUE on url: a file with duplicate URLs yields one row per distinct
    URL (assert count), and re-importing the same file does not grow it."""
    html = """\
<DL><p>
    <DT><A HREF="https://example.com/dup">Dup1</A>
    <DT><A HREF="https://example.com/dup">Dup2</A>
    <DT><A HREF="https://example.com/uniq">U</A>
</DL><p>
"""
    file = UploadFile(filename="x.html", file=io.BytesIO(html.encode()))
    result = await api_import(file)
    assert result["found"] == 3  # both dup lines are seen...
    assert db.count_bookmarks() == 2  # ...but collapse to one row each

    rows = db.get_conn().execute(
        "SELECT url, COUNT(*) AS n FROM bookmarks GROUP BY url"
    ).fetchall()
    assert {r["url"]: r["n"] for r in rows} == {
        "https://example.com/dup": 1,
        "https://example.com/uniq": 1,
    }

    # Re-importing the same file is idempotent: still 2 rows.
    file2 = UploadFile(filename="x.html", file=io.BytesIO(html.encode()))
    await api_import(file2)
    assert db.count_bookmarks() == 2


@pytest.mark.asyncio
async def test_tags_exported_rows_round_trip(fresh_db, monkeypatch, tmp_path):
    """A TAGS-carrying Netscape file (the exact shape the exporter writes)
    round-trips through the app: import → export → re-import keeps every tag,
    including the toolbar-folder tag."""
    html = """\
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<DL><p>
    <DT><H3 ADD_DATE="1700000000" LAST_MODIFIED="1700000000" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
    <DL><p>
        <DT><A HREF="https://example.com/t1" ADD_DATE="1700000000" TAGS="dev,toolbar">T1</A>
    </DL><p>
    <DT><A HREF="https://example.com/t2" ADD_DATE="1700000000" TAGS="python,rust">T2</A>
    <DT><A HREF="https://example.com/t3" ADD_DATE="1700000000" TAGS="toolbar">T3</A>
</DL><p>
"""
    file = UploadFile(filename="x.html", file=io.BytesIO(html.encode()))
    result = await api_import(file)
    assert result["inserted"] == 3

    content = exporter.export_bookmarks()
    p2 = tmp_path / "reimport.db"
    monkeypatch.setattr(db, "DB_PATH", p2)
    monkeypatch.setattr(db, "_conn", None)
    db.get_conn()
    file2 = UploadFile(filename="rt.html", file=io.BytesIO(content.encode("utf-8")))
    await api_import(file2)

    def tags_of(url: str) -> set[str]:
        row = db.get_conn().execute(
            "SELECT id FROM bookmarks WHERE url = ?", (url,)
        ).fetchone()
        assert row is not None
        return set(db.get_tags_for_bookmark(row["id"]))

    assert tags_of("https://example.com/t1") == {"dev", "toolbar"}
    assert tags_of("https://example.com/t2") == {"python", "rust"}
    assert tags_of("https://example.com/t3") == {"toolbar"}
