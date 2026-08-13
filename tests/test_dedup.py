"""Dedup candidate engine (todo 25).

Contract under test:

- ``normalize_url`` — lowercase host, strip ``www.``, strip trailing ``/``,
  strip ``#fragment``; drop ``utm_*``/``fbclid``/``gclid`` query params; keep
  meaningful params; sort remaining params. www./non-www and utm-only
  differences must normalize to the same string.
- Fuzzy title threshold — RapidFuzz ``WRatio`` ≥ 85 groups similar titles;
  unrelated titles stay below and are never grouped.
- ``find_candidates`` — bookmarks whose normalized URLs are identical OR whose
  titles fuzzy-match within the same normalized domain form candidate groups
  of shape ``{canonical, members, count}``. Cross-domain same-title rows are
  NOT grouped. Read-only: never merges, never deletes.
- ``GET /api/dedup/candidates`` — authed (401 without a session), returns the
  groups payload.
- Redirect-final recording — ``fetch_final_url`` follows redirects (mirroring
  ``check_dead``'s HEAD + ranged-GET fallback), ``record_final_url`` writes
  the final URL into the ``final_url`` column (todo 14), and
  ``backfill_final_urls`` processes a bounded, marker-resumable batch.
"""

from __future__ import annotations

import httpx
from fastapi.testclient import TestClient

from app import auth, db, dedup
from app.main import app


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


def _redirect_handler(request: httpx.Request) -> httpx.Response:
    """MockTransport: /old* → 301 to /new*, /new* → 200, anything else → 404."""
    path = request.url.path
    if path.startswith("/old"):
        return httpx.Response(301, headers={"Location": path.replace("/old", "/new", 1)})
    if path.startswith("/new"):
        return httpx.Response(200)
    return httpx.Response(404)


# ---------------------------------------------------------------------------
# normalize_url — pure function unit tests
# ---------------------------------------------------------------------------


def test_normalize_lowercases_host():
    assert dedup.normalize_url("https://EXAMPLE.com/foo") == "https://example.com/foo"


def test_normalize_strips_www():
    assert dedup.normalize_url("https://www.example.com/foo") == "https://example.com/foo"


def test_normalize_strips_trailing_slash():
    assert dedup.normalize_url("https://example.com/foo/") == "https://example.com/foo"
    assert dedup.normalize_url("https://example.com/") == "https://example.com"


def test_normalize_strips_fragment():
    assert dedup.normalize_url("https://example.com/foo#section") == "https://example.com/foo"


def test_normalize_drops_utm_params():
    assert (
        dedup.normalize_url("https://example.com/foo?utm_source=x&utm_medium=y")
        == "https://example.com/foo"
    )


def test_normalize_drops_fbclid_and_gclid():
    assert (
        dedup.normalize_url("https://example.com/foo?fbclid=abc&gclid=xyz")
        == "https://example.com/foo"
    )


def test_normalize_keeps_meaningful_params_and_sorts():
    assert (
        dedup.normalize_url("https://example.com/foo?q=rust&id=42")
        == "https://example.com/foo?id=42&q=rust"
    )


def test_normalize_www_and_nonwww_equivalent():
    assert dedup.normalize_url("https://www.example.com/foo") == dedup.normalize_url(
        "https://example.com/foo"
    )


def test_normalize_utm_only_difference_equivalent():
    assert dedup.normalize_url("https://example.com/foo?utm_source=x") == dedup.normalize_url(
        "https://example.com/foo"
    )


# ---------------------------------------------------------------------------
# Fuzzy title threshold
# ---------------------------------------------------------------------------


def test_fuzzy_threshold_groups_similar_titles():
    assert dedup.titles_match("The Complete Guide to Docker", "Complete Guide to Docker")


def test_fuzzy_threshold_rejects_unrelated_titles():
    assert not dedup.titles_match("Getting started with SQLite", "Pricing")


# ---------------------------------------------------------------------------
# find_candidates grouping
# ---------------------------------------------------------------------------


def test_utm_variants_grouped(fresh_db):
    a = db.insert_bookmark(url="https://example.com/foo?utm_source=news", title="Foo Post")
    b = db.insert_bookmark(url="https://example.com/foo", title="Bar Post")
    groups = dedup.find_candidates()["groups"]

    assert len(groups) == 1
    group = groups[0]
    assert group["count"] == 2
    # Canonical is the lowest-id (tie-break on equal created_at) member.
    assert group["canonical"] == {"id": a, "title": "Foo Post", "url": "https://example.com/foo?utm_source=news"}
    assert [m["id"] for m in group["members"]] == [b]
    assert all(m["reason"] == "url" for m in group["members"])


def test_www_and_nonwww_grouped(fresh_db):
    db.insert_bookmark(url="https://www.example.com/foo", title="Foo Page")
    db.insert_bookmark(url="https://example.com/foo", title="Foo Page")
    groups = dedup.find_candidates()["groups"]

    assert len(groups) == 1
    assert groups[0]["count"] == 2


def test_unrelated_same_domain_not_grouped(fresh_db):
    db.insert_bookmark(url="https://example.com/a", title="The Complete Guide to Docker")
    db.insert_bookmark(url="https://example.com/b", title="Getting started with SQLite")
    db.insert_bookmark(url="https://example.com/c", title="Pricing")
    assert dedup.find_candidates()["groups"] == []


def test_title_fuzzy_grouped_within_same_domain(fresh_db):
    db.insert_bookmark(url="https://example.com/1", title="The Complete Guide to Docker")
    db.insert_bookmark(url="https://example.com/2", title="Complete Guide to Docker")
    groups = dedup.find_candidates()["groups"]

    assert len(groups) == 1
    assert groups[0]["count"] == 2
    assert {m["reason"] for m in groups[0]["members"]} == {"title"}


def test_same_title_different_domain_not_grouped(fresh_db):
    db.insert_bookmark(url="https://example.com/a", title="The Complete Guide to Docker")
    db.insert_bookmark(url="https://other.com/a", title="The Complete Guide to Docker")
    assert dedup.find_candidates()["groups"] == []


def test_canonical_is_best_row_and_members_sorted(fresh_db):
    # Oldest-created row (created_at pinned lower) becomes the canonical.
    a = db.insert_bookmark(url="https://example.com/foo", title="Foo")
    b = db.insert_bookmark(url="https://example.com/foo?utm_source=x", title="Foo")
    db.get_conn().execute("UPDATE bookmarks SET created_at = 1000 WHERE id = ?", (a,))

    groups = dedup.find_candidates()["groups"]
    assert len(groups) == 1
    group = groups[0]
    assert group["canonical"] == {"id": a, "title": "Foo", "url": "https://example.com/foo"}
    assert [m["id"] for m in group["members"]] == [b]


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------


def test_candidates_requires_auth(fresh_db):
    with TestClient(app) as client:
        resp = client.get("/api/dedup/candidates")
    assert resp.status_code == 401


def test_candidates_api_shape(fresh_db):
    db.insert_bookmark(url="https://example.com/foo?utm_source=x", title="Foo")
    db.insert_bookmark(url="https://example.com/foo", title="Foo")
    client = _authed_client()
    with client:
        resp = client.get("/api/dedup/candidates")

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert set(body.keys()) == {"groups"}
    group = body["groups"][0]
    assert set(group.keys()) == {"canonical", "members", "count"}
    assert set(group["canonical"].keys()) == {"id", "title", "url"}
    assert set(group["members"][0].keys()) == {"id", "title", "url", "reason"}
    assert group["count"] == 2


# ---------------------------------------------------------------------------
# Redirect-final recording
# ---------------------------------------------------------------------------


async def test_fetch_final_url_follows_redirects():
    transport = httpx.MockTransport(_redirect_handler)
    async with httpx.AsyncClient(transport=transport, follow_redirects=True) as client:
        assert await dedup.fetch_final_url(client, "https://x.test/old") == "https://x.test/new"


async def test_fetch_final_url_returns_none_for_dead():
    transport = httpx.MockTransport(_redirect_handler)
    async with httpx.AsyncClient(transport=transport, follow_redirects=True) as client:
        assert await dedup.fetch_final_url(client, "https://x.test/gone") is None


async def test_record_final_url_populates_column(fresh_db):
    bid = db.insert_bookmark(url="https://x.test/old", title="Redirecting")
    transport = httpx.MockTransport(_redirect_handler)
    async with httpx.AsyncClient(transport=transport, follow_redirects=True) as client:
        final = await dedup.record_final_url(client, bid, "https://x.test/old")

    assert final == "https://x.test/new"
    row = db.get_bookmark(bid)
    assert row is not None
    assert row["final_url"] == "https://x.test/new"


async def test_backfill_is_bounded_and_marker_resumable(fresh_db, tmp_path):
    ids = [db.insert_bookmark(url=f"https://x.test/old{i}", title=f"T{i}") for i in range(5)]
    marker = tmp_path / "finalurl.marker"
    transport = httpx.MockTransport(_redirect_handler)

    first = await dedup.backfill_final_urls(limit=2, marker_path=marker, transport=transport)
    assert first["checked"] == 2
    assert first["updated"] == 2
    assert first["marker"] == ids[1]

    second = await dedup.backfill_final_urls(limit=2, marker_path=marker, transport=transport)
    assert second["checked"] == 2
    assert second["updated"] == 2
    assert second["marker"] == ids[3]

    third = await dedup.backfill_final_urls(limit=2, marker_path=marker, transport=transport)
    assert third["checked"] == 1
    assert third["updated"] == 1
    assert third["marker"] == ids[4]

    finals = {
        row["url"]: row["final_url"]
        for row in db.get_conn().execute(
            "SELECT url, final_url FROM bookmarks"
        ).fetchall()
    }
    assert finals == {
        f"https://x.test/old{i}": f"https://x.test/new{i}" for i in range(5)
    }
