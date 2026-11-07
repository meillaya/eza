"""Tag consolidation (todo 27).

Contract under test:

- ``consolidation_candidates`` — returns case-duplicate pairs (Music/music),
  fuzzy WRatio >= 85 pairs (webdev/web-dev), junk-tag candidates (reusing
  ``auto_tag``'s stopwords plus pure-noise heuristics), and tag-proliferation
  stats (tags applied to <= 3 bookmarks). Purely advisory — it NEVER merges or
  deletes, so a read leaves the DB byte-identical.
- ``merge_tags(from, to)`` — rewrites ``bookmark_tags`` from -> to (deduping
  via the composite PK), then deletes the now-empty from-tag row. Merging to a
  NONEXISTENT tag creates it (defined behavior — a rename-by-merge never loses
  data). ``from == to`` and a nonexistent ``from`` are rejected.
- ``rename_tag`` — non-empty name validation; a rename onto an existing tag
  name is rejected.
- ``delete_tag`` — ONLY an empty tag (no ``bookmark_tags`` rows) can be
  deleted; a non-empty tag is rejected 400, a missing tag 404.
- API — ``GET /api/tags/consolidation-candidates`` (authed, no exemption),
  ``POST /api/tags/merge``, ``POST /api/tags/{id}`` rename,
  ``DELETE /api/tags/{id}``; CSRF + 401 matrix.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app import auth, db, tag_cleanup
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


def _make_tag(name: str, n: int = 1) -> int:
    """Create a tag row with the EXACT name plus ``n`` bookmarks carrying it.

    ``db.insert_bookmark`` lowercases tags, so exact-case fixtures (Music) must
    insert the tag row and its links directly.
    """
    conn = db.get_conn()
    conn.execute("INSERT OR IGNORE INTO tags(name) VALUES (?)", (name,))
    tag_id = conn.execute("SELECT id FROM tags WHERE name = ?", (name,)).fetchone()["id"]
    for i in range(n):
        bid = db.insert_bookmark(url=f"https://t.example/{name}-{i}", title=f"t {name} {i}")
        conn.execute(
            "INSERT OR IGNORE INTO bookmark_tags(bookmark_id, tag_id) VALUES (?, ?)",
            (bid, tag_id),
        )
    return tag_id


def _tag_names() -> set[str]:
    return {r["name"] for r in db.get_conn().execute("SELECT name FROM tags").fetchall()}


# ---------------------------------------------------------------------------
# consolidation_candidates — detection
# ---------------------------------------------------------------------------


def test_case_pairs_detected(fresh_db):
    _make_tag("Music", 1)
    _make_tag("music", 2)
    cands = tag_cleanup.consolidation_candidates()
    assert cands["case_pairs"] == [
        {"from": "Music", "to": "music", "from_count": 1, "to_count": 2}
    ]


def test_fuzzy_pairs_detected(fresh_db):
    _make_tag("web-dev", 1)
    _make_tag("webdev", 3)
    cands = tag_cleanup.consolidation_candidates()
    assert len(cands["fuzzy_pairs"]) == 1
    pair = cands["fuzzy_pairs"][0]
    assert pair["from"] == "web-dev"
    assert pair["to"] == "webdev"  # merge smaller into the bigger bucket
    assert pair["score"] >= 85
    assert pair["from_count"] == 1
    assert pair["to_count"] == 3


def test_fuzzy_rejects_unrelated_tags(fresh_db):
    _make_tag("rust", 1)
    _make_tag("pricing", 1)
    assert tag_cleanup.consolidation_candidates()["fuzzy_pairs"] == []


def test_case_pairs_not_duplicated_in_fuzzy(fresh_db):
    _make_tag("Music", 1)
    _make_tag("music", 2)
    cands = tag_cleanup.consolidation_candidates()
    assert len(cands["case_pairs"]) == 1
    assert cands["fuzzy_pairs"] == []


def test_junk_tags_reuse_auto_tag_stopwords(fresh_db):
    _make_tag("imported", 5)
    _make_tag("tabs", 3)
    _make_tag("music", 2)
    junk = {j["name"] for j in tag_cleanup.consolidation_candidates()["junk_tags"]}
    assert {"imported", "tabs"} <= junk
    assert "music" not in junk


def test_junk_tags_heuristic_rules(fresh_db):
    _make_tag("12345", 2)   # all digits
    _make_tag("x", 1)       # single character
    _make_tag("temp 2", 4)  # first word is the "temp" stopword
    junk = {j["name"] for j in tag_cleanup.consolidation_candidates()["junk_tags"]}
    assert {"12345", "x", "temp 2"} <= junk


def test_proliferation_stats(fresh_db):
    _make_tag("big", 10)
    _make_tag("mid", 3)
    _make_tag("small", 2)
    _make_tag("tiny", 1)
    prol = tag_cleanup.consolidation_candidates()["proliferation"]
    assert prol == {"count": 4, "tags_on_le_3": 3}


def test_candidates_are_read_only(fresh_db):
    _make_tag("Music", 1)
    _make_tag("music", 2)
    before = _tag_names()
    tag_cleanup.consolidation_candidates()
    assert _tag_names() == before


# ---------------------------------------------------------------------------
# merge_tags
# ---------------------------------------------------------------------------


def test_merge_rewrites_and_deletes_from_tag(fresh_db):
    _make_tag("Music", 2)
    _make_tag("music", 1)
    result = tag_cleanup.merge_tags("Music", "music")
    assert result == {"from": "Music", "to": "music", "bookmarks_affected": 2, "tag_created": False}
    conn = db.get_conn()
    # Acceptance: zero bookmarks left on the exact "Music" tag (the helper
    # bookmarks_with_tag lowercases, so check the exact name via SQL), and no
    # orphan tag rows.
    assert conn.execute("SELECT 1 FROM tags WHERE name = 'Music'").fetchone() is None
    assert (
        conn.execute(
            "SELECT COUNT(*) AS n FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id "
            "WHERE t.name = 'Music'"
        ).fetchone()["n"]
        == 0
    )
    assert len(db.bookmarks_with_tag("music")) == 3
    assert _tag_names() == {"music"}


def test_merge_to_nonexistent_tag_creates_it(fresh_db):
    _make_tag("Music", 2)
    result = tag_cleanup.merge_tags("Music", "music")
    assert result["tag_created"] is True
    assert result["bookmarks_affected"] == 2
    assert len(db.bookmarks_with_tag("music")) == 2  # no data lost
    assert _tag_names() == {"music"}


def test_merge_dedupes_bookmark_carrying_both_tags(fresh_db):
    bid = db.insert_bookmark(url="https://x.example/", title="x")
    conn = db.get_conn()
    for name in ("Music", "music"):
        conn.execute("INSERT OR IGNORE INTO tags(name) VALUES (?)", (name,))
        tag_id = conn.execute("SELECT id FROM tags WHERE name = ?", (name,)).fetchone()["id"]
        conn.execute(
            "INSERT OR IGNORE INTO bookmark_tags(bookmark_id, tag_id) VALUES (?, ?)",
            (bid, tag_id),
        )
    tag_cleanup.merge_tags("Music", "music")
    links = conn.execute(
        "SELECT COUNT(*) AS n FROM bookmark_tags WHERE bookmark_id = ?", (bid,)
    ).fetchone()["n"]
    assert links == 1
    assert db.get_tags_for_bookmark(bid) == ["music"]


def test_merge_same_name_rejected(fresh_db):
    _make_tag("music", 2)
    with pytest.raises(tag_cleanup.TagCleanupError):
        tag_cleanup.merge_tags("music", "music")


def test_merge_nonexistent_from_rejected(fresh_db):
    _make_tag("music", 1)
    with pytest.raises(tag_cleanup.TagCleanupError):
        tag_cleanup.merge_tags("nope", "music")


def test_merge_empty_names_rejected(fresh_db):
    _make_tag("music", 1)
    with pytest.raises(tag_cleanup.TagCleanupError):
        tag_cleanup.merge_tags("", "music")
    with pytest.raises(tag_cleanup.TagCleanupError):
        tag_cleanup.merge_tags("music", "  ")


# ---------------------------------------------------------------------------
# rename_tag
# ---------------------------------------------------------------------------


def test_rename_tag(fresh_db):
    tag_id = _make_tag("music", 2)
    result = tag_cleanup.rename_tag(tag_id, "songs")
    assert result == {"id": tag_id, "name": "songs"}
    assert len(db.bookmarks_with_tag("songs")) == 2


def test_rename_empty_name_rejected(fresh_db):
    tag_id = _make_tag("music", 1)
    with pytest.raises(tag_cleanup.TagCleanupError):
        tag_cleanup.rename_tag(tag_id, "   ")


def test_rename_onto_existing_name_rejected(fresh_db):
    _make_tag("music", 1)
    tag_id = _make_tag("rock", 1)
    with pytest.raises(tag_cleanup.TagCleanupError):
        tag_cleanup.rename_tag(tag_id, "music")


def test_rename_nonexistent_tag_not_found(fresh_db):
    with pytest.raises(tag_cleanup.TagNotFoundError):
        tag_cleanup.rename_tag(9999, "x")


# ---------------------------------------------------------------------------
# delete_tag
# ---------------------------------------------------------------------------


def test_delete_empty_tag(fresh_db):
    conn = db.get_conn()
    conn.execute("INSERT INTO tags(name) VALUES ('orphan')")
    tag_id = conn.execute("SELECT id FROM tags WHERE name = 'orphan'").fetchone()["id"]
    assert tag_cleanup.delete_tag(tag_id) == {"ok": True, "id": tag_id}
    assert conn.execute("SELECT 1 FROM tags WHERE id = ?", (tag_id,)).fetchone() is None


def test_delete_nonempty_tag_rejected(fresh_db):
    tag_id = _make_tag("music", 2)
    with pytest.raises(tag_cleanup.TagCleanupError):
        tag_cleanup.delete_tag(tag_id)
    assert db.get_conn().execute("SELECT 1 FROM tags WHERE id = ?", (tag_id,)).fetchone() is not None


def test_delete_nonexistent_tag_not_found(fresh_db):
    with pytest.raises(tag_cleanup.TagNotFoundError):
        tag_cleanup.delete_tag(9999)


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------


def test_candidates_requires_auth(fresh_db):
    with TestClient(app) as client:
        resp = client.get("/api/tags/consolidation-candidates")
    assert resp.status_code == 401


def test_candidates_api_shape(fresh_db):
    _make_tag("Music", 1)
    _make_tag("music", 2)
    client = _authed_client()
    with client:
        resp = client.get("/api/tags/consolidation-candidates")
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert set(body.keys()) == {"case_pairs", "fuzzy_pairs", "junk_tags", "proliferation"}
    assert set(body["proliferation"].keys()) == {"count", "tags_on_le_3"}
    assert len(body["case_pairs"]) == 1


def test_merge_api_happy_path(fresh_db):
    _make_tag("Music", 2)
    _make_tag("music", 1)
    client = _authed_client()
    with client:
        resp = client.post(
            "/api/tags/merge",
            headers={"X-CSRF-Token": client.cookies.get("csrf_token")},
            json={"from": "Music", "to": "music"},
        )
    assert resp.status_code == 200, resp.text
    assert resp.json() == {
        "from": "Music",
        "to": "music",
        "bookmarks_affected": 2,
        "tag_created": False,
    }
    conn = db.get_conn()
    assert conn.execute("SELECT 1 FROM tags WHERE name = 'Music'").fetchone() is None
    assert len(db.bookmarks_with_tag("music")) == 3


def test_merge_api_creates_tag_on_nonexistent_to(fresh_db):
    _make_tag("Music", 2)
    client = _authed_client()
    with client:
        resp = client.post(
            "/api/tags/merge",
            headers={"X-CSRF-Token": client.cookies.get("csrf_token")},
            json={"from": "Music", "to": "music"},
        )
    assert resp.status_code == 200, resp.text
    assert resp.json()["tag_created"] is True
    assert len(db.bookmarks_with_tag("music")) == 2


def test_merge_api_invalid_body_400(fresh_db):
    _make_tag("music", 1)
    client = _authed_client()
    with client:
        resp = client.post(
            "/api/tags/merge",
            headers={"X-CSRF-Token": client.cookies.get("csrf_token")},
            json={"from": "nope", "to": "music"},
        )
    assert resp.status_code == 400


def test_merge_api_missing_csrf_403(fresh_db):
    _make_tag("music", 1)
    client = _authed_client()
    with client:
        resp = client.post("/api/tags/merge", json={"from": "music", "to": "music"})
    assert resp.status_code == 403


def test_merge_api_unauthed_401(fresh_db):
    with TestClient(app) as client:
        resp = client.post("/api/tags/merge", json={"from": "a", "to": "b"})
    assert resp.status_code == 401


def test_rename_api(fresh_db):
    tag_id = _make_tag("music", 1)
    client = _authed_client()
    with client:
        resp = client.post(
            f"/api/tags/{tag_id}",
            headers={"X-CSRF-Token": client.cookies.get("csrf_token")},
            json={"name": "songs"},
        )
    assert resp.status_code == 200, resp.text
    assert resp.json() == {"id": tag_id, "name": "songs"}
    assert "songs" in _tag_names()


def test_rename_api_empty_name_400(fresh_db):
    tag_id = _make_tag("music", 1)
    client = _authed_client()
    with client:
        resp = client.post(
            f"/api/tags/{tag_id}",
            headers={"X-CSRF-Token": client.cookies.get("csrf_token")},
            json={"name": "  "},
        )
    assert resp.status_code == 400


def test_delete_api_empty_tag(fresh_db):
    conn = db.get_conn()
    conn.execute("INSERT INTO tags(name) VALUES ('orphan')")
    tag_id = conn.execute("SELECT id FROM tags WHERE name = 'orphan'").fetchone()["id"]
    client = _authed_client()
    with client:
        resp = client.delete(
            f"/api/tags/{tag_id}",
            headers={"X-CSRF-Token": client.cookies.get("csrf_token")},
        )
    assert resp.status_code == 200, resp.text
    assert conn.execute("SELECT 1 FROM tags WHERE id = ?", (tag_id,)).fetchone() is None


def test_delete_api_nonempty_tag_400(fresh_db):
    tag_id = _make_tag("music", 2)
    client = _authed_client()
    with client:
        resp = client.delete(
            f"/api/tags/{tag_id}",
            headers={"X-CSRF-Token": client.cookies.get("csrf_token")},
        )
    assert resp.status_code == 400


def test_delete_api_missing_csrf_403(fresh_db):
    tag_id = _make_tag("music", 1)
    client = _authed_client()
    with client:
        resp = client.delete(f"/api/tags/{tag_id}")
    assert resp.status_code == 403


def test_tags_cleanup_page_requires_auth(fresh_db):
    with TestClient(app) as client:
        resp = client.get("/tags-cleanup")
    assert resp.status_code == 401


def test_tags_cleanup_page_renders(fresh_db):
    client = _authed_client()
    with client:
        resp = client.get("/tags-cleanup")
    assert resp.status_code == 200
    assert "Clean up tags" in resp.text
