"""Inbox / read-later queue + saved-search collections (bookmarks-kb todo 29).

Pins the plan's QA contract:

- the ``saved_searches`` table lands via migration m0006 (the runner's 1-based
  index -> user_version 6) with columns id/name/q/tags_json/created_at;
- is_read lifecycle: PATCH /api/bookmarks/{id} with ``is_read`` flips a
  bookmark, and search ``is:unread`` then excludes it (the operator path stays
  working alongside the explicit ``is_read`` query param);
- the queue view: GET /api/search?is_read=0 returns ONLY unread bookmarks,
  default-sorted ``created_at DESC`` (the 2-bucket inbox-vs-library model);
- "mark all above": a cursor-boundary bulk op — unread bookmarks with
  ``id > above_id`` (the ones ABOVE the cursor in the created_at-DESC queue)
  flip to read in one transaction; no cursor marks every unread row;
- saved searches: POST/GET/DELETE /api/saved-searches round-trip a
  ``{name, q, tags}`` collection; a saved search whose tag no longer exists
  still renders 200 with an empty result set (never a 500);
- auth: every new route sits behind the global middleware (401 unauth) and
  every mutation is CSRF-checked (403 without X-CSRF-Token).
"""

from __future__ import annotations

from fastapi.testclient import TestClient

from app import auth, db, migrations
from app.main import app


def _authed_client() -> tuple[TestClient, str]:
    """A TestClient with a normal session + csrf cookie, like the other suites."""
    sid = auth.create_session(scope="normal")
    csrf = db.get_conn().execute(
        "SELECT csrf_token FROM sessions WHERE id = ?", (sid,)
    ).fetchone()["csrf_token"]
    client = TestClient(app)
    client.cookies.set(auth.SESSION_COOKIE_NAME, sid)
    client.cookies.set("csrf_token", csrf)
    return client, csrf


def _bookmark(*, url: str, title: str = "", is_read: bool | None = None) -> int:
    """Insert a bookmark directly, optionally setting its read state."""
    bid = db.insert_bookmark(url=url, title=title)
    if is_read is not None:
        db.update_bookmark(bid, is_read=is_read)
    return bid


def _set_created_at(bookmark_id: int, created_at: int) -> None:
    """Pin a bookmark's created_at so ordering tests are deterministic."""
    with db.transaction() as conn:
        conn.execute(
            "UPDATE bookmarks SET created_at = ? WHERE id = ?",
            (created_at, bookmark_id),
        )


def _is_read(bookmark_id: int) -> int:
    """The bookmark's read flag, narrowed out of get_bookmark's optionality."""
    bookmark = db.get_bookmark(bookmark_id)
    assert bookmark is not None
    return bookmark["is_read"]


# ---------------------------------------------------------------------------
# Migration m0006: saved_searches table + user_version 6
# ---------------------------------------------------------------------------


def test_fresh_db_is_version_six_with_saved_searches_table(fresh_db):
    assert fresh_db.get_conn().execute("PRAGMA user_version").fetchone()[0] == 6
    tables = {
        row["name"]
        for row in fresh_db.get_conn().execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        )
    }
    assert "saved_searches" in tables
    columns = {
        row["name"]
        for row in fresh_db.get_conn().execute("PRAGMA table_info(saved_searches)")
    }
    assert columns == {"id", "name", "q", "tags_json", "created_at"}


def test_saved_searches_migration_is_the_appended_last_step():
    names = [name for name, _ in migrations.MIGRATIONS]
    assert names[-1] == "m0006_saved_searches"
    assert len(names) == 6


# ---------------------------------------------------------------------------
# is_read lifecycle (the acceptance path): PATCH -> is:unread excludes it
# ---------------------------------------------------------------------------


def test_mark_unread_to_read_then_is_unread_excludes_it(fresh_db):
    bid = _bookmark(url="https://inbox.example/", title="Inbox item")
    client, csrf = _authed_client()

    with client:
        unread = client.get("/api/search", params={"q": "is:unread"})
    assert unread.status_code == 200
    assert bid in {item["id"] for item in unread.json()["items"]}

    with client:
        resp = client.patch(
            f"/api/bookmarks/{bid}",
            json={"is_read": 1},
            headers={"X-CSRF-Token": csrf},
        )
    assert resp.status_code == 200, resp.text

    with client:
        after = client.get("/api/search", params={"q": "is:unread"})
    assert after.status_code == 200
    assert bid not in {item["id"] for item in after.json()["items"]}


def test_is_read_param_matches_operator_semantics(fresh_db):
    read = _bookmark(url="https://a.example/", title="A", is_read=True)
    unread = _bookmark(url="https://b.example/", title="B", is_read=False)
    default = _bookmark(url="https://c.example/", title="C")  # is_read defaults 0

    assert db.list_bookmarks(q="is:unread") == db.list_bookmarks(is_read=0)
    assert {item["id"] for item in db.list_bookmarks(is_read=0)} == {unread, default}
    assert [item["id"] for item in db.list_bookmarks(is_read=1)] == [read]
    # Both filters compose with a term.
    assert [item["id"] for item in db.list_bookmarks(is_read=0, q="B")] == [unread]


# ---------------------------------------------------------------------------
# Queue view: GET /api/search?is_read=0, default sort created_at DESC
# ---------------------------------------------------------------------------


def test_queue_view_returns_only_unread_sorted_created_at_desc(fresh_db):
    newest = _bookmark(url="https://new.example/", title="Newest")
    middle = _bookmark(url="https://mid.example/", title="Middle")
    oldest = _bookmark(url="https://old.example/", title="Oldest")
    _set_created_at(newest, 3000)
    _set_created_at(middle, 2000)
    _set_created_at(oldest, 1000)
    _bookmark(url="https://read.example/", title="Already read", is_read=True)

    client, _ = _authed_client()
    with client:
        resp = client.get("/api/search", params={"is_read": 0})
    assert resp.status_code == 200
    body = resp.json()
    assert [item["id"] for item in body["items"]] == [newest, middle, oldest]
    assert body["total"] == 3


# ---------------------------------------------------------------------------
# "Mark all above" bulk op — cursor boundary semantics
# ---------------------------------------------------------------------------


def test_mark_all_above_flips_only_unread_above_the_cursor(fresh_db):
    # ids are issued in insertion order: 1,2,3,4.
    low = _bookmark(url="https://low.example/", title="Low")
    cursor = _bookmark(url="https://cursor.example/", title="Cursor")
    above1 = _bookmark(url="https://above1.example/", title="Above 1")
    above2 = _bookmark(url="https://above2.example/", title="Above 2")
    _bookmark(url="https://already-read.example/", title="Read", is_read=True)

    updated = db.mark_all_above(above_id=cursor)

    assert updated == 2
    assert _is_read(low) == 0
    assert _is_read(cursor) == 0  # the cursor itself stays unread
    assert _is_read(above1) == 1
    assert _is_read(above2) == 1


def test_mark_all_above_without_cursor_flips_every_unread(fresh_db):
    a = _bookmark(url="https://a.example/", title="A")
    b = _bookmark(url="https://b.example/", title="B")
    _bookmark(url="https://read.example/", title="Read", is_read=True)

    updated = db.mark_all_above()

    assert updated == 2
    assert _is_read(a) == 1
    assert _is_read(b) == 1


def test_mark_all_above_requires_csrf(fresh_db):
    client, _ = _authed_client()
    with client:
        resp = client.post("/api/bookmarks/mark-all-above", json={"above_id": 1})
    assert resp.status_code == 403
    assert resp.json() == {"detail": "CSRF token mismatch"}


def test_mark_all_above_api_route(fresh_db):
    _bookmark(url="https://a.example/", title="A")
    cursor = _bookmark(url="https://cursor.example/", title="Cursor")
    above = _bookmark(url="https://above.example/", title="Above")

    client, csrf = _authed_client()
    with client:
        resp = client.post(
            "/api/bookmarks/mark-all-above",
            json={"above_id": cursor},
            headers={"X-CSRF-Token": csrf},
        )
    assert resp.status_code == 200, resp.text
    assert resp.json() == {"updated": 1}
    assert _is_read(above) == 1
    assert _is_read(cursor) == 0


# ---------------------------------------------------------------------------
# Saved searches: POST/GET/DELETE + persistence shape
# ---------------------------------------------------------------------------


def test_create_and_list_saved_search(fresh_db):
    client, csrf = _authed_client()
    with client:
        created = client.post(
            "/api/saved-searches",
            json={"name": "Rust reads", "q": "rust", "tags": ["dev", "reference"]},
            headers={"X-CSRF-Token": csrf},
        )
    assert created.status_code == 200, created.text
    saved_id = created.json()["id"]
    assert isinstance(saved_id, int)

    with client:
        listing = client.get("/api/saved-searches")
    assert listing.status_code == 200
    items = listing.json()["saved_searches"]
    assert len(items) == 1
    saved = items[0]
    assert saved["id"] == saved_id
    assert saved["name"] == "Rust reads"
    assert saved["q"] == "rust"
    assert saved["tags"] == ["dev", "reference"]
    assert isinstance(saved["created_at"], int)


def test_saved_search_defaults_q_and_tags(fresh_db):
    client, csrf = _authed_client()
    with client:
        created = client.post(
            "/api/saved-searches",
            json={"name": "Everything"},
            headers={"X-CSRF-Token": csrf},
        )
    assert created.status_code == 200, created.text
    with client:
        listing = client.get("/api/saved-searches").json()["saved_searches"]
    assert listing[0]["q"] == ""
    assert listing[0]["tags"] == []


def test_saved_search_requires_name(fresh_db):
    client, csrf = _authed_client()
    for body in ({}, {"name": "", "q": "x"}, {"name": 42, "q": "x"}):
        with client:
            resp = client.post(
                "/api/saved-searches", json=body, headers={"X-CSRF-Token": csrf}
            )
        assert resp.status_code == 400, body


def test_delete_saved_search(fresh_db):
    client, csrf = _authed_client()
    with client:
        created = client.post(
            "/api/saved-searches",
            json={"name": "Temp", "q": "temp"},
            headers={"X-CSRF-Token": csrf},
        ).json()
    saved_id = created["id"]

    with client:
        deleted = client.delete(
            f"/api/saved-searches/{saved_id}", headers={"X-CSRF-Token": csrf}
        )
    assert deleted.status_code == 200, deleted.text

    with client:
        listing = client.get("/api/saved-searches").json()["saved_searches"]
    assert listing == []


def test_delete_unknown_saved_search_returns_404(fresh_db):
    client, csrf = _authed_client()
    with client:
        resp = client.delete(
            "/api/saved-searches/999", headers={"X-CSRF-Token": csrf}
        )
    assert resp.status_code == 404


def test_saved_search_with_deleted_tag_returns_200_empty(fresh_db):
    """QA-pinned: a saved search whose tag no longer exists must apply as an
    EMPTY result set with 200 — never a 500."""
    client, csrf = _authed_client()
    with client:
        created = client.post(
            "/api/saved-searches",
            json={"name": "Ghost", "q": "", "tags": ["ghost-tag"]},
            headers={"X-CSRF-Token": csrf},
        )
    assert created.status_code == 200, created.text
    saved = client.get("/api/saved-searches").json()["saved_searches"][0]

    # Applying the saved search = GET /api/search with its q + tags.
    with client:
        resp = client.get(
            "/api/search",
            params={"q": saved["q"], "tags": ",".join(saved["tags"])},
        )
    assert resp.status_code == 200
    assert resp.json()["total"] == 0
    assert resp.json()["items"] == []


def test_saved_searches_require_auth_and_csrf(fresh_db):
    client = TestClient(app)
    with client:
        unauth = client.get("/api/saved-searches")
    assert unauth.status_code == 401

    client2, _ = _authed_client()
    with client2:
        no_csrf = client2.post("/api/saved-searches", json={"name": "X", "q": "x"})
    assert no_csrf.status_code == 403


# ---------------------------------------------------------------------------
# Inbox page route
# ---------------------------------------------------------------------------


def test_inbox_page_requires_auth(fresh_db):
    client = TestClient(app)
    with client:
        resp = client.get("/inbox", headers={"Accept": "text/html"})
    assert resp.status_code == 401
    assert "text/html" in resp.headers["content-type"]


def test_inbox_page_renders_when_authed(fresh_db):
    _bookmark(url="https://inbox.example/", title="Queue item")
    client, _ = _authed_client()
    with client:
        resp = client.get("/inbox")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "mark-all-above" in resp.text
    assert "saved-searches" in resp.text
