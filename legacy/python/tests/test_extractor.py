"""Tests for todo 16 — trafilatura content extraction + full-page snapshots.

Three layers of the extraction pipeline are pinned here:

- ``app/extractor.py`` is a pure parser (zero network): canned HTML in, a
  metadata dict out, gated by ``is_probably_readerable`` and run through the
  fallback ladder.
- ``app/fetcher.py`` wires extraction into the background enrichment path: the
  task fetches the page HTML (network — mocked here) and stores the extracted
  fields via ``db.update_metadata``, never blocking the save response.
- ``app/snapshot.py`` runs the monolith binary as an on-demand subprocess
  (mocked here; the real binary must never run in tests) and falls back to a
  Wayback availability URL when monolith fails.
- ``app/backfill_extract.py`` re-fetches HTML for existing rows (mocked) and
  is resumable via a last-extracted marker file.
"""

from __future__ import annotations

import time
from datetime import UTC, datetime
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import auth, backfill_extract, db, fetcher
from app import snapshot as snapshot_mod
from app.extractor import _parse_date, extract_from_html
from app.main import app

ARTICLE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>The Definitive Guide to Rust Borrowing</title>
  <meta name="author" content="Alice Zhang">
  <meta property="article:published_time" content="2024-05-17T09:00:00Z">
  <meta property="og:site_name" content="Rust Weekly">
  <meta property="og:image" content="https://rustweekly.example/cover.png">
</head>
<body>
  <nav><a href="/">Home</a> <a href="/blog">Blog</a></nav>
  <article>
    <h1>The Definitive Guide to Rust Borrowing</h1>
    <p>Rust's borrow checker is the feature that makes memory safety without a
       garbage collector possible. It enforces that every value has exactly one
       owner at any given time.</p>
    <p>When you move a value, ownership transfers to the new binding. When you
       borrow, you get a reference without taking ownership.</p>
    <p>Lifetimes annotate how long references are valid. The compiler uses them
       to prove that no reference outlives the data it points to.</p>
    <p>This guide walks through all the common patterns: references, mutable
       borrows, slices, and the rules that govern them.</p>
  </article>
  <aside>Sponsored content about data science and other things that are not the
        article proper.</aside>
  <footer>Copyright Rust Weekly 2024.</footer>
</body>
</html>
"""

# A JS-shell / nav-heavy page that must NOT be treated as an article.
SHELL_PAGE = """<!DOCTYPE html>
<html><head><title>App</title></head><body>
<script>window.app = {}</script>
<div id="root">
  <nav><a>Home</a><a>About</a><a>Pricing</a><a>Docs</a><a>Blog</a><a>Contact</a>
       <a>Careers</a><a>Press</a></nav>
  <div><button>Sign up</button></div>
</div>
</body></html>
"""


def _auth_headers(client: TestClient) -> dict:
    """Open a normal-scoped session and set the cookies + CSRF header."""
    session_id, csrf = auth.create_login_session()
    client.cookies.set(auth.SESSION_COOKIE_NAME, session_id)
    client.cookies.set("csrf_token", csrf)
    return {"X-CSRF-Token": csrf}


def _wait_for_extraction(bookmark_id: int, *, deadline: float = 5.0) -> dict:
    """Poll the row until the background extraction task has written text."""
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        row = db.get_bookmark(bookmark_id)
        assert row is not None
        if row["extracted_text"]:
            return row
        time.sleep(0.02)
    raise AssertionError("background extraction did not populate the row in time")


# ---------------------------------------------------------------------------
# extract_from_html — pure parser, no network
# ---------------------------------------------------------------------------


def test_extract_from_html_returns_article_metadata():
    """A canned article fixture yields title/author/sitename/image/text/date."""
    meta = extract_from_html(ARTICLE)
    assert meta["title"] == "The Definitive Guide to Rust Borrowing"
    assert meta["author"] == "Alice Zhang"
    assert meta["sitename"] == "Rust Weekly"
    assert meta["image"] == "https://rustweekly.example/cover.png"
    assert "borrow checker" in meta["text"]
    assert "Rust's borrow checker" in meta["text"]
    assert meta["date"] == int(datetime(2024, 5, 17).timestamp())


def test_extract_from_html_gates_unreadable_pages():
    """Non-article pages (JS shell / nav-heavy) return empty fields — the
    is_probably_readerable gate stops nav-garbage from being stored."""
    meta = extract_from_html(SHELL_PAGE)
    assert meta["title"] == ""
    assert meta["author"] == ""
    assert meta["sitename"] == ""
    assert meta["text"] == ""
    assert meta["date"] is None


def test_extract_from_html_empty_input():
    assert extract_from_html("") == {
        "title": "",
        "author": "",
        "sitename": "",
        "date": None,
        "language": "",
        "image": "",
        "text": "",
    }


def test_parse_date_formats():
    assert _parse_date("2024-05-17") == int(datetime(2024, 5, 17).timestamp())
    assert _parse_date("2024-05-17T09:00:00Z") == int(
        datetime(2024, 5, 17, 9, 0, 0, tzinfo=UTC).timestamp()
    )
    assert _parse_date("") is None
    assert _parse_date("not a date") is None


# ---------------------------------------------------------------------------
# Background extraction task (network mocked)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_extract_task_fetches_and_updates_row(fresh_db, monkeypatch):
    """The background task fetches HTML (mocked) and stores the extracted
    article fields on the row via db.update_metadata."""
    bid = db.insert_bookmark(url="https://article.example/rust", title="Rust")

    async def fake_fetch_html(client, url):
        return ARTICLE

    monkeypatch.setattr(fetcher, "fetch_html", fake_fetch_html)
    await fetcher.extract(bid, "https://article.example/rust")

    row = db.get_bookmark(bid)
    assert row is not None
    assert "borrow checker" in row["extracted_text"]
    assert row["author"] == "Alice Zhang"
    assert row["sitename"] == "Rust Weekly"
    assert row["image_url"] == "https://rustweekly.example/cover.png"
    assert row["published_at"] == int(datetime(2024, 5, 17).timestamp())


@pytest.mark.asyncio
async def test_extract_task_non_html_keeps_columns_empty(fresh_db, monkeypatch):
    """A non-HTML / failed fetch leaves the extraction columns empty, without
    crashing the background task or the save path."""
    bid = db.insert_bookmark(url="https://pdf.example/file", title="PDF")

    async def fake_fetch_html(client, url):
        return None

    monkeypatch.setattr(fetcher, "fetch_html", fake_fetch_html)
    await fetcher.extract(bid, "https://pdf.example/file")  # must not raise

    row = db.get_bookmark(bid)
    assert row is not None
    assert row["extracted_text"] == ""
    assert row["author"] == ""
    assert row["sitename"] == ""


def test_update_metadata_partial_kwargs(fresh_db):
    """update_metadata only touches the columns it is given (sentinel-safe)."""
    bid = db.insert_bookmark(url="https://x.example/", title="X")
    db.update_metadata(bid, author="Alice", sitename="Example", extracted_text="body")
    row = db.get_bookmark(bid)
    assert row is not None
    assert row["author"] == "Alice"
    assert row["sitename"] == "Example"
    assert row["extracted_text"] == "body"
    assert row["title"] == "X"
    assert row["description"] == ""


# ---------------------------------------------------------------------------
# Save path: returns 200, extraction runs in the background afterwards
# ---------------------------------------------------------------------------


def test_save_bookmark_returns_200_and_background_extraction_populates_row(
    fresh_db, monkeypatch
):
    """POST /api/bookmarks answers 200 immediately; the fire-and-forget
    extraction task (fetch mocked) then fills the row's extraction columns."""
    async def fake_fetch_metadata(url):
        return {"title": "", "description": "", "favicon_url": "", "domain": "article.example"}

    async def fake_fetch_html(client, url):
        return ARTICLE

    monkeypatch.setattr(fetcher, "fetch_metadata", fake_fetch_metadata)
    monkeypatch.setattr(fetcher, "fetch_html", fake_fetch_html)

    with TestClient(app) as client:
        headers = _auth_headers(client)
        resp = client.post(
            "/api/bookmarks",
            data={"url": "https://article.example/rust"},
            headers=headers,
        )
        assert resp.status_code == 200, resp.text
        bid = resp.json()["id"]
        row = _wait_for_extraction(bid)
        assert "borrow checker" in row["extracted_text"]
        assert row["author"] == "Alice Zhang"
        assert row["sitename"] == "Rust Weekly"


def test_save_unreadable_page_still_returns_200(fresh_db, monkeypatch):
    """An unreadable page still yields a 200 save; extraction leaves the
    columns empty and never raises."""
    async def fake_fetch_metadata(url):
        return {"title": "", "description": "", "favicon_url": "", "domain": "shell.example"}

    async def fake_fetch_html(client, url):
        return SHELL_PAGE

    monkeypatch.setattr(fetcher, "fetch_metadata", fake_fetch_metadata)
    monkeypatch.setattr(fetcher, "fetch_html", fake_fetch_html)

    with TestClient(app) as client:
        headers = _auth_headers(client)
        resp = client.post(
            "/api/bookmarks",
            data={"url": "https://shell.example/app"},
            headers=headers,
        )
        assert resp.status_code == 200, resp.text
        bid = resp.json()["id"]
        end = time.monotonic() + 5.0
        while time.monotonic() < end:
            row = db.get_bookmark(bid)
            assert row is not None
            if row["extracted_text"] != "":
                break
            time.sleep(0.02)
        row = db.get_bookmark(bid)
        assert row is not None
        assert row["extracted_text"] == ""
        assert row["author"] == ""


# ---------------------------------------------------------------------------
# Snapshot endpoint — monolith subprocess mocked, never the real binary
# ---------------------------------------------------------------------------


def test_snapshot_endpoint_success_with_mocked_monolith(fresh_db, monkeypatch, tmp_path):
    """Monolith (mocked) produces a file → 200 with snapshot_path set and the
    file present in the data dir; the path is recorded on the row."""
    bid = db.insert_bookmark(url="https://article.example/rust", title="Rust")

    def fake_run_monolith(url, out_path, *, timeout, monolith):
        out_path.write_text("<!doctype html><html>snapshot</html>", encoding="utf-8")

    monkeypatch.setattr(snapshot_mod, "_run_monolith", fake_run_monolith)
    monkeypatch.setattr(
        snapshot_mod, "_default_snapshots_dir", lambda: tmp_path / "snapshots"
    )

    with TestClient(app) as client:
        headers = _auth_headers(client)
        resp = client.post(f"/api/bookmarks/{bid}/snapshot", headers=headers)

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["snapshot_path"]
    assert Path(body["snapshot_path"]).exists()
    assert body["wayback_url"] == ""
    row = db.get_bookmark(bid)
    assert row is not None
    assert row["snapshot_path"] == body["snapshot_path"]


def test_snapshot_endpoint_wayback_fallback_when_monolith_fails(
    fresh_db, monkeypatch, tmp_path
):
    """Monolith (mocked) fails → 200 with wayback_url populated and the
    Wayback availability URL recorded on the row as the fallback."""
    bid = db.insert_bookmark(url="https://article.example/rust", title="Rust")

    def fake_run_monolith(url, out_path, *, timeout, monolith):
        raise RuntimeError("monolith crashed")

    monkeypatch.setattr(snapshot_mod, "_run_monolith", fake_run_monolith)
    monkeypatch.setattr(
        snapshot_mod, "_default_snapshots_dir", lambda: tmp_path / "snapshots"
    )

    with TestClient(app) as client:
        headers = _auth_headers(client)
        resp = client.post(f"/api/bookmarks/{bid}/snapshot", headers=headers)

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["snapshot_path"] == ""
    assert body["wayback_url"] == "https://web.archive.org/web/2/https://article.example/rust"
    row = db.get_bookmark(bid)
    assert row is not None
    assert row["snapshot_path"] == body["wayback_url"]


def test_snapshot_endpoint_unknown_bookmark_404(fresh_db, monkeypatch, tmp_path):
    monkeypatch.setattr(
        snapshot_mod, "_default_snapshots_dir", lambda: tmp_path / "snapshots"
    )
    with TestClient(app) as client:
        headers = _auth_headers(client)
        resp = client.post("/api/bookmarks/99999/snapshot", headers=headers)
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Backfill CLI — re-fetches HTML (mocked), resumable via a marker
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_backfill_extract_resumes_via_marker(fresh_db, monkeypatch, tmp_path):
    """Two runs with the same --limit continue past the first batch: the marker
    file records the last processed id and the next run starts after it."""
    for i in range(25):
        db.insert_bookmark(url=f"https://article.example/{i}", title=f"T{i}")

    async def fake_fetch_html(client, url):
        return ARTICLE

    monkeypatch.setattr(backfill_extract, "_fetch_html", fake_fetch_html)
    marker = tmp_path / "bf.marker"

    first = await backfill_extract.backfill_extract(limit=10, marker_path=marker)
    assert first == {"extracted": 10, "skipped": 0, "marker": 10}
    for i in range(1, 11):
        row = db.get_bookmark(i)
        assert row is not None
        assert row["extracted_text"] != ""

    second = await backfill_extract.backfill_extract(limit=10, marker_path=marker)
    assert second == {"extracted": 10, "skipped": 0, "marker": 20}
    for i in range(11, 21):
        row = db.get_bookmark(i)
        assert row is not None
        assert row["extracted_text"] != ""

    # Rows beyond the second batch are untouched.
    for i in range(21, 26):
        row = db.get_bookmark(i)
        assert row is not None
        assert row["extracted_text"] == ""


@pytest.mark.asyncio
async def test_backfill_extract_marker_read_survives_restart(fresh_db, tmp_path):
    marker = tmp_path / "bf.marker"
    marker.write_text("7", encoding="utf-8")
    assert backfill_extract._read_marker(marker) == 7
    assert backfill_extract._read_marker(tmp_path / "missing") == 0
    assert backfill_extract._read_marker(tmp_path / "junk") == 0


@pytest.mark.asyncio
async def test_backfill_extract_failed_fetch_skips_without_crash(fresh_db, monkeypatch, tmp_path):
    db.insert_bookmark(url="https://dead.example/1", title="D1")
    db.insert_bookmark(url="https://article.example/2", title="T2")

    async def fake_fetch_html(client, url):
        if "dead" in url:
            return None
        return ARTICLE

    monkeypatch.setattr(backfill_extract, "_fetch_html", fake_fetch_html)
    result = await backfill_extract.backfill_extract(limit=10, marker_path=tmp_path / "bf.marker")
    assert result["extracted"] == 1
    assert result["skipped"] == 1
    assert result["marker"] == 2
