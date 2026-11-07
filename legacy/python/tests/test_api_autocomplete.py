"""GET /api/autocomplete (todo 20) — the wikilink autocomplete endpoint.

Contract (not built by any other todo):

- Authed by the GLOBAL require_auth middleware (no exemption) — a request
  without a session is 401.
- ``q`` matches bookmark titles AND urls, case-insensitively, as a prefix or
  a substring (the "alias" behavior — there is deliberately no aliases
  schema). Prefix matches on the title rank ahead of substring matches.
- The response is a list of ``{id, title, url}`` items capped at 10.
- Empty/blank ``q`` returns ``[]`` — never a crash.
"""

from __future__ import annotations

from fastapi.testclient import TestClient

from app import auth, db
from app.main import app


def _insert(url: str, title: str = "") -> int:
    return db.insert_bookmark(url=url, title=title)


def _authed_client() -> tuple[TestClient, str]:
    """A TestClient preloaded with a normal-scope session + csrf cookies."""
    sid = auth.create_session(scope="normal")
    csrf = db.get_conn().execute(
        "SELECT csrf_token FROM sessions WHERE id = ?", (sid,)
    ).fetchone()["csrf_token"]
    client = TestClient(app)
    client.cookies.set(auth.SESSION_COOKIE_NAME, sid)
    client.cookies.set("csrf_token", csrf)
    return client, csrf


def test_autocomplete_matches_title_prefix_and_substring_case_insensitive(fresh_db):
    _insert("https://alpha.example/", title="Rust Async Runtime")
    _insert("https://beta.example/", title="async patterns in rust")
    _insert("https://unrelated.example/", title="Gardening")
    client, _ = _authed_client()
    with client:
        resp = client.get("/api/autocomplete", params={"q": "RUST"})

    assert resp.status_code == 200
    items = resp.json()
    # Prefix match ("Rust…") ranks before substring match ("…rust").
    assert [i["title"] for i in items] == [
        "Rust Async Runtime",
        "async patterns in rust",
    ]
    for item in items:
        assert set(item.keys()) == {"id", "title", "url"}


def test_autocomplete_matches_url_substring(fresh_db):
    _insert("https://docs.rust-lang.org/book/", title="The Book")
    client, _ = _authed_client()
    with client:
        resp = client.get("/api/autocomplete", params={"q": "rust-lang"})

    assert resp.status_code == 200
    items = resp.json()
    assert [i["url"] for i in items] == ["https://docs.rust-lang.org/book/"]
    assert items[0]["id"] > 0
    assert items[0]["title"] == "The Book"


def test_autocomplete_limits_to_10(fresh_db):
    for i in range(15):
        _insert(f"https://item{i}.example/", title=f"Shared Name {i}")
    client, _ = _authed_client()
    with client:
        resp = client.get("/api/autocomplete", params={"q": "Shared"})

    assert resp.status_code == 200
    assert len(resp.json()) == 10


def test_autocomplete_empty_q_returns_empty_list(fresh_db):
    _insert("https://any.example/", title="Anything")
    client, _ = _authed_client()
    with client:
        for q in ("", "   "):
            resp = client.get("/api/autocomplete", params={"q": q})
            assert resp.status_code == 200, resp.text
            assert resp.json() == []


def test_autocomplete_no_match_returns_empty_list(fresh_db):
    _insert("https://x.example/", title="Only One")
    client, _ = _authed_client()
    with client:
        resp = client.get("/api/autocomplete", params={"q": "zzz-no-such-thing"})

    assert resp.status_code == 200
    assert resp.json() == []


def test_autocomplete_requires_auth(fresh_db):
    _insert("https://secret.example/", title="Secret")
    with TestClient(app) as client:
        resp = client.get("/api/autocomplete", params={"q": "Secret"})

    assert resp.status_code == 401
