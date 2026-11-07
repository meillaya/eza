"""Dead-link review + age-pruning suggestions (bookmarks-kb todo 30).

SCHEMA-CHECK OUTCOME: ``open_count`` and ``last_opened_at`` ALREADY EXIST in
the ``bookmarks`` base schema (app/db.py ``_SCHEMA``; ``record_open`` has
always bumped them). NO migration is needed — the never-opened criterion runs
against the existing columns and the live DB (user_version 6, counts
8950/98/18019) is untouched.

Contract under test:

- ``POST /api/check-dead/run`` reuses ``check_dead.check_dead``'s sweep (the
  same HEAD-check + ranged-GET fallback the CLI runs), bounded by a ``limit``
  body param defaulting to the CLI's 10_000. Returns ``{checked, dead, alive}``;
  a dead URL ends up flagged ``is_dead = 1``.
- ``GET /api/search?is_dead=1`` is the review view: mirrors todo 29's
  ``is_read`` param threading through ``_search_sql`` / ``list_bookmarks`` /
  ``count_bookmarks``, plus the symmetric ``is:dead`` operator.
- ``GET /api/prune/candidates`` — bookmarks OLDER THAN N days (default 365)
  that were NEVER opened (``open_count = 0 AND last_opened_at IS NULL``).
  Excludes recently-opened (any ``open_count > 0`` or ``last_opened_at`` set)
  and young rows.
- ``POST /api/prune/apply {ids}`` — user-confirmed: deletes ONLY the listed
  ids in ONE transaction, writing the full pre-delete state to
  ``undo_snapshots`` FIRST (reuse of the todo-26 snapshot payload shape so a
  prune is as reversible as a merge). Empty ids -> 400 (QA-pinned). Never
  automatic: nothing prunes without an explicit apply.
- auth: every new route sits behind the global middleware (401 unauth), every
  mutation is CSRF-checked (403 without X-CSRF-Token).
"""

from __future__ import annotations

import json
import time
from typing import ClassVar

from fastapi.testclient import TestClient

from app import auth, check_dead, db
from app.main import app

_DAY = 86400


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


def _bookmark(*, url: str, title: str = "") -> int:
    return db.insert_bookmark(url=url, title=title)


def _set_created_at(bookmark_id: int, created_at: int) -> None:
    """Pin a bookmark's created_at so age-based tests are deterministic."""
    with db.transaction() as conn:
        conn.execute(
            "UPDATE bookmarks SET created_at = ? WHERE id = ?",
            (created_at, bookmark_id),
        )


def _is_dead(bookmark_id: int) -> int:
    bookmark = db.get_bookmark(bookmark_id)
    assert bookmark is not None
    return bookmark["is_dead"]


class _FakeDeadResponse:
    """A HEAD/GET response that always looks dead (404)."""

    status_code = 404
    headers: ClassVar[dict] = {}


class _FakeDeadClient:
    """AsyncClient stand-in: every request comes back 404, so the real sweep
    logic (HEAD check -> status >= 400 -> dead) runs without touching the
    network."""

    async def head(self, url: str) -> _FakeDeadResponse:
        return _FakeDeadResponse()

    async def get(self, url: str, headers: dict | None = None) -> _FakeDeadResponse:
        return _FakeDeadResponse()

    async def __aenter__(self) -> _FakeDeadClient:
        return self

    async def __aexit__(self, exc_type, exc, tb) -> None:
        return None


def _mock_network(monkeypatch) -> None:
    """Point check_dead's httpx.AsyncClient at the fake (reverted after the
    test, so no real URLs are ever hit)."""
    monkeypatch.setattr(check_dead.httpx, "AsyncClient", lambda **_kw: _FakeDeadClient())


# ---------------------------------------------------------------------------
# Schema check: open_count / last_opened_at already exist (no m0007 needed)
# ---------------------------------------------------------------------------


def test_fresh_db_has_never_opened_columns(fresh_db):
    columns = {
        row["name"] for row in fresh_db.get_conn().execute("PRAGMA table_info(bookmarks)")
    }
    assert "open_count" in columns
    assert "last_opened_at" in columns


# ---------------------------------------------------------------------------
# Dead-link sweep: POST /api/check-dead/run (bounded), review view is_dead=1
# ---------------------------------------------------------------------------


def test_check_dead_run_marks_dead_and_review_view_surfaces_it(fresh_db, monkeypatch):
    """Acceptance: run sweep on a fixture with a dead URL -> is_dead=1, then
    GET /api/search?is_dead=1 surfaces it, and per-row delete works."""
    _mock_network(monkeypatch)
    bid = _bookmark(url="https://dead.example/", title="Dead link")
    client, csrf = _authed_client()

    with client:
        resp = client.post("/api/check-dead/run", json={}, headers={"X-CSRF-Token": csrf})
    assert resp.status_code == 200, resp.text
    assert resp.json() == {"checked": 1, "dead": 1, "alive": 0}
    assert _is_dead(bid) == 1

    with client:
        review = client.get("/api/search", params={"is_dead": 1})
    assert review.status_code == 200
    assert [item["id"] for item in review.json()["items"]] == [bid]
    assert review.json()["total"] == 1

    # Delete works from the review view.
    with client:
        deleted = client.delete(f"/api/bookmarks/{bid}", headers={"X-CSRF-Token": csrf})
    assert deleted.status_code == 200, deleted.text
    assert db.get_bookmark(bid) is None
    with client:
        after = client.get("/api/search", params={"is_dead": 1})
    assert after.json()["total"] == 0


def test_check_dead_run_is_bounded_by_limit(fresh_db, monkeypatch):
    _mock_network(monkeypatch)
    for i in range(3):
        _bookmark(url=f"https://dead.example/{i}")
    client, csrf = _authed_client()

    with client:
        resp = client.post(
            "/api/check-dead/run", json={"limit": 2}, headers={"X-CSRF-Token": csrf}
        )
    assert resp.status_code == 200, resp.text
    assert resp.json() == {"checked": 2, "dead": 2, "alive": 0}


def test_check_dead_run_invalid_limit_returns_400(fresh_db):
    client, csrf = _authed_client()
    with client:
        resp = client.post(
            "/api/check-dead/run", json={"limit": 0}, headers={"X-CSRF-Token": csrf}
        )
    assert resp.status_code == 400


def test_check_dead_run_requires_auth_and_csrf(fresh_db):
    with TestClient(app) as client:
        unauth = client.post("/api/check-dead/run", json={})
    assert unauth.status_code == 401

    client2, _ = _authed_client()
    with client2:
        no_csrf = client2.post("/api/check-dead/run", json={})
    assert no_csrf.status_code == 403


# ---------------------------------------------------------------------------
# is_dead review filter: param threaded like todo 29's is_read, plus is:dead
# ---------------------------------------------------------------------------


def test_is_dead_param_filters(fresh_db):
    dead = _bookmark(url="https://dead.example/", title="D")
    live = _bookmark(url="https://live.example/", title="L")
    db.mark_checked(dead, is_dead=True)
    db.mark_checked(live, is_dead=False)

    assert [item["id"] for item in db.list_bookmarks(is_dead=1)] == [dead]
    assert [item["id"] for item in db.list_bookmarks(is_dead=0)] == [live]
    assert db.count_bookmarks(is_dead=1) == 1
    assert db.count_bookmarks(is_dead=0) == 1


def test_is_dead_operator_matches_param(fresh_db):
    dead = _bookmark(url="https://dead.example/", title="D")
    _bookmark(url="https://live.example/", title="L")
    db.mark_checked(dead, is_dead=True)

    assert db.list_bookmarks(q="is:dead") == db.list_bookmarks(is_dead=1)
    assert db.count_bookmarks(q="is:dead") == 1


# ---------------------------------------------------------------------------
# Prune candidates: older than N days AND never opened
# ---------------------------------------------------------------------------


def test_prune_candidates_excludes_recently_opened(fresh_db):
    """Acceptance: prune candidates excludes recently-opened. A candidate is
    old (created > 365d ago) AND never opened (open_count=0, last_opened_at
    NULL)."""
    now = int(time.time())
    old_never_opened = _bookmark(url="https://old-never.example/", title="Old, never opened")
    old_opened = _bookmark(url="https://old-opened.example/", title="Old, opened once")
    young_never_opened = _bookmark(url="https://young-never.example/", title="Young")
    _set_created_at(old_never_opened, now - 400 * _DAY)
    _set_created_at(old_opened, now - 400 * _DAY)
    _set_created_at(young_never_opened, now - 10 * _DAY)
    db.record_open(old_opened)  # open_count=1, last_opened_at set

    candidates = db.prune_candidates()

    assert [c["id"] for c in candidates] == [old_never_opened]


def test_prune_candidates_boundary_is_older_than_n_days(fresh_db):
    now = int(time.time())
    just_over = _bookmark(url="https://over.example/", title="Just over")
    just_under = _bookmark(url="https://under.example/", title="Just under")
    recent = _bookmark(url="https://recent.example/", title="Recent")
    _set_created_at(just_over, now - 365 * _DAY - 60)  # strictly older than 365d
    _set_created_at(just_under, now - 365 * _DAY + 60)  # younger than 365d
    _set_created_at(recent, now - 10 * _DAY)

    assert [c["id"] for c in db.prune_candidates()] == [just_over]
    # N is configurable: at a 30-day window BOTH 365-day rows qualify, the
    # 10-day-old one does not.
    assert [c["id"] for c in db.prune_candidates(older_than_days=30)] == [
        just_over,
        just_under,
    ]


def test_prune_candidates_returns_expected_fields(fresh_db):
    now = int(time.time())
    bid = _bookmark(url="https://cand.example/", title="Candidate")
    _set_created_at(bid, now - 400 * _DAY)

    (candidate,) = db.prune_candidates()

    assert candidate["id"] == bid
    assert candidate["title"] == "Candidate"
    assert candidate["url"] == "https://cand.example/"
    assert candidate["created_at"] == now - 400 * _DAY
    assert candidate["open_count"] == 0
    assert candidate["last_opened_at"] is None


def test_prune_candidates_api_requires_auth(fresh_db):
    with TestClient(app) as client:
        resp = client.get("/api/prune/candidates")
    assert resp.status_code == 401


def test_prune_candidates_api_shape(fresh_db):
    now = int(time.time())
    bid = _bookmark(url="https://cand.example/", title="Candidate")
    _set_created_at(bid, now - 400 * _DAY)
    client, _ = _authed_client()

    with client:
        resp = client.get("/api/prune/candidates")
    assert resp.status_code == 200
    body = resp.json()
    assert body["older_than_days"] == 365
    assert [c["id"] for c in body["candidates"]] == [bid]


# ---------------------------------------------------------------------------
# Prune apply: delete ONLY the listed ids, ONE transaction, undo snapshot first
# ---------------------------------------------------------------------------


def test_prune_apply_removes_only_listed_ids(fresh_db):
    """Acceptance: apply removes only listed ids — the unlisted candidate and
    the recently-opened row both survive."""
    now = int(time.time())
    a = _bookmark(url="https://a.example/", title="A")
    b = _bookmark(url="https://b.example/", title="B")
    c = _bookmark(url="https://c.example/", title="C")
    for bid in (a, b, c):
        _set_created_at(bid, now - 400 * _DAY)

    result = db.prune_apply([a, b])

    assert result["deleted"] == [a, b]
    assert db.get_bookmark(a) is None
    assert db.get_bookmark(b) is None
    assert db.get_bookmark(c) is not None  # unlisted id untouched


def test_prune_apply_writes_undo_snapshot_before_deleting(fresh_db):
    now = int(time.time())
    bid = db.insert_bookmark(url="https://undo.example/", title="Undo me", tags=["x", "y"])
    _set_created_at(bid, now - 400 * _DAY)

    result = db.prune_apply([bid])

    assert isinstance(result["snapshot_id"], int)
    rows = db.get_conn().execute(
        "SELECT payload_json FROM undo_snapshots WHERE id = ?", (result["snapshot_id"],)
    ).fetchall()
    assert len(rows) == 1
    payload = json.loads(rows[0]["payload_json"])
    assert payload["op"] == "prune"
    (snapshot,) = payload["pruned"]
    assert snapshot["row"]["id"] == bid
    assert snapshot["row"]["url"] == "https://undo.example/"
    assert snapshot["row"]["title"] == "Undo me"
    assert snapshot["tags"] == ["x", "y"]
    assert snapshot["row"]["created_at"] == now - 400 * _DAY


def test_prune_apply_empty_ids_rejected(fresh_db):
    import pytest

    with pytest.raises(db.PruneError, match="empty"):
        db.prune_apply([])
    assert db.get_conn().execute("SELECT COUNT(*) AS n FROM undo_snapshots").fetchone()["n"] == 0


def test_prune_apply_api_empty_ids_returns_400(fresh_db):
    """QA-pinned: prune apply with empty ids -> 400, nothing deleted."""
    client, csrf = _authed_client()
    with client:
        resp = client.post(
            "/api/prune/apply", json={"ids": []}, headers={"X-CSRF-Token": csrf}
        )
    assert resp.status_code == 400


def test_prune_apply_api_removes_only_listed_ids(fresh_db):
    now = int(time.time())
    a = _bookmark(url="https://a.example/", title="A")
    b = _bookmark(url="https://b.example/", title="B")
    for bid in (a, b):
        _set_created_at(bid, now - 400 * _DAY)
    client, csrf = _authed_client()

    with client:
        resp = client.post(
            "/api/prune/apply", json={"ids": [a]}, headers={"X-CSRF-Token": csrf}
        )
    assert resp.status_code == 200, resp.text
    assert resp.json()["deleted"] == [a]
    assert db.get_bookmark(a) is None
    assert db.get_bookmark(b) is not None


def test_prune_apply_requires_auth_and_csrf(fresh_db):
    with TestClient(app) as client:
        unauth = client.post("/api/prune/apply", json={"ids": [1]})
    assert unauth.status_code == 401

    client2, _ = _authed_client()
    with client2:
        no_csrf = client2.post("/api/prune/apply", json={"ids": [1]})
    assert no_csrf.status_code == 403


def test_prune_apply_invalid_body_returns_400(fresh_db):
    client, csrf = _authed_client()
    for body in ({"ids": "nope"}, {"ids": [1, "two"]}, {}):
        with client:
            resp = client.post(
                "/api/prune/apply", json=body, headers={"X-CSRF-Token": csrf}
            )
        assert resp.status_code == 400, body


# ---------------------------------------------------------------------------
# Maintenance page route
# ---------------------------------------------------------------------------


def test_maintenance_page_requires_auth(fresh_db):
    with TestClient(app) as client:
        resp = client.get("/maintenance", headers={"Accept": "text/html"})
    assert resp.status_code == 401
    assert "text/html" in resp.headers["content-type"]


def test_maintenance_page_renders_when_authed(fresh_db):
    client, _ = _authed_client()
    with client:
        resp = client.get("/maintenance")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "check-dead" in resp.text
    assert "prune-candidates" in resp.text
