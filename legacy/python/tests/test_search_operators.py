"""Search operators and full-content FTS matching (bookmarks-kb todo 18).

Covers the plan's QA contract:

- a term found only in ``note_body`` returns that bookmark with a snippet;
- ``tag:name`` composes AND with a free-text ``q`` (and with the ``tags``
  API parameter);
- ``is:unread`` returns only unread bookmarks;
- ``link:target`` returns bookmarks whose note links target the named
  bookmark;
- ``-term`` negation works where FTS5 supports it (including standalone);
- malformed operators (``tag:``/``is:``/``link:`` with empty values) are
  treated as empty filters, never a 500;
- the API response shape (items/total/offset/limit) is preserved.

The pre-existing tests/test_db.py search cases stay untouched; this file only
adds the operator surface on top of them.
"""

from __future__ import annotations

from fastapi.testclient import TestClient

from app import auth, db
from app.main import app


def _bookmark(*, url: str, title: str = "", tags: tuple[str, ...] = (), note: str = "", is_read: bool | None = None) -> int:
    bid = db.insert_bookmark(url=url, title=title, tags=tags)
    updates: dict[str, object] = {}
    if note:
        updates["note_body"] = note
    if is_read is not None:
        updates["is_read"] = is_read
    if updates:
        db.update_bookmark(bid, **updates)
    return bid


def test_term_only_in_note_returns_bookmark_with_snippet(fresh_db):
    _bookmark(url="https://a.example/", title="Python docs")
    bid = _bookmark(
        url="https://b.example/",
        title="Async article",
        note="Deep dive: the rust ownership model and borrowing rules.",
    )

    results = db.list_bookmarks(q="rust")

    assert [r["id"] for r in results] == [bid]
    assert "rust" in results[0]["snippet"].lower()


def test_snippet_comes_from_earliest_field(fresh_db):
    bid = _bookmark(
        url="https://a.example/",
        title="The rust programming language",
        note="Long note text that mentions rust deep inside the body.",
    )

    results = db.list_bookmarks(q="rust")

    assert results[0]["id"] == bid
    # Earliest match is in the title -> the snippet comes from the title.
    assert "programming" in results[0]["snippet"]
    assert "note text" not in results[0]["snippet"]


def test_tag_operator_composes_with_q(fresh_db):
    _bookmark(url="https://a.example/rust", title="Rust guide", tags=("rust",))
    _bookmark(url="https://b.example/py", title="Python guide", tags=("python",))
    _bookmark(url="https://c.example/rust-extra", title="Rust extra", tags=("rust",))

    results = db.list_bookmarks(q="tag:rust guide")

    assert {r["url"] for r in results} == {"https://a.example/rust"}


def test_tag_operator_alone_matches_all_tagged(fresh_db):
    _bookmark(url="https://a.example/rust", title="Rust guide", tags=("rust",))
    _bookmark(url="https://b.example/py", title="Python guide", tags=("python",))
    _bookmark(url="https://c.example/rust-extra", title="Rust extra", tags=("rust",))

    results = db.list_bookmarks(q="tag:rust")

    assert {r["url"] for r in results} == {"https://a.example/rust", "https://c.example/rust-extra"}


def test_tag_operator_ands_with_tags_param(fresh_db):
    _bookmark(url="https://a.example/", title="A", tags=("rust", "programming"))
    _bookmark(url="https://b.example/", title="B", tags=("rust",))
    _bookmark(url="https://c.example/", title="C", tags=("programming",))

    results = db.list_bookmarks(q="tag:rust", tags=["programming"])

    assert {r["url"] for r in results} == {"https://a.example/"}


def test_is_unread_operator(fresh_db):
    read = _bookmark(url="https://a.example/", title="Read one", is_read=True)
    unread = _bookmark(url="https://b.example/", title="Unread one", is_read=False)
    default = _bookmark(url="https://c.example/", title="Default one")

    results = db.list_bookmarks(q="is:unread")

    ids = {r["id"] for r in results}
    assert read not in ids
    assert {unread, default} <= ids  # is_read defaults to 0 = unread


def test_is_unread_composes_with_fts(fresh_db):
    _bookmark(url="https://a.example/", title="Rust read", is_read=True)
    unread = _bookmark(url="https://b.example/", title="Rust unread", is_read=False)

    results = db.list_bookmarks(q="is:unread rust")

    assert [r["id"] for r in results] == [unread]


def test_link_operator_returns_linked_sources(fresh_db):
    _bookmark(url="https://target.example/", title="Obsidian Setup")
    source = _bookmark(
        url="https://src.example/",
        title="Vault notes",
        note="See [[Obsidian Setup]] for the vault layout.",
    )
    _bookmark(url="https://other.example/", title="Other")

    results = db.list_bookmarks(q="link:obsidian")

    assert [r["id"] for r in results] == [source]


def test_link_operator_unknown_target_is_empty(fresh_db):
    _bookmark(url="https://a.example/", title="A")

    assert db.list_bookmarks(q="link:does-not-exist") == []


def test_negation_excludes_matching_rows(fresh_db):
    _bookmark(url="https://a.example/", title="Rust async book")
    _bookmark(url="https://b.example/", title="Rust sync book")
    _bookmark(url="https://c.example/", title="Python async book")

    results = db.list_bookmarks(q="rust -async")

    assert {r["url"] for r in results} == {"https://b.example/"}
    assert db.count_bookmarks(q="rust -async") == 1


def test_negation_alone(fresh_db):
    _bookmark(url="https://a.example/", title="Rust async book")
    _bookmark(url="https://b.example/", title="Rust sync book")
    _bookmark(url="https://c.example/", title="Python async book")

    results = db.list_bookmarks(q="-async")

    assert {r["url"] for r in results} == {"https://b.example/"}


def test_count_reflects_operators(fresh_db):
    _bookmark(url="https://a.example/", title="Rust guide", tags=("rust",))
    _bookmark(url="https://b.example/", title="Rust book", tags=("rust",))

    results = db.list_bookmarks(q="is:unread tag:rust")

    assert db.count_bookmarks(q="is:unread tag:rust") == len(results) == 2


def test_malformed_operators_are_empty_filters(fresh_db):
    _bookmark(url="https://a.example/", title="A")
    _bookmark(url="https://b.example/", title="B")
    all_urls = {"https://a.example/", "https://b.example/"}

    assert {r["url"] for r in db.list_bookmarks(q="tag:")} == all_urls
    assert {r["url"] for r in db.list_bookmarks(q="is:")} == all_urls
    assert {r["url"] for r in db.list_bookmarks(q="link:")} == all_urls
    assert db.count_bookmarks(q="tag:") == 2


def test_unknown_tag_operator_returns_empty(fresh_db):
    _bookmark(url="https://a.example/", title="A")

    assert db.list_bookmarks(q="tag:rust") == []


def test_api_search_surfaces_operators_and_snippet(fresh_db):
    bid = _bookmark(
        url="https://api-note.example/",
        title="API search target",
        note="only this note mentions the word snorkel for fts testing",
    )
    _bookmark(url="https://other.example/", title="Plain card")
    sid = auth.create_session(scope="normal")
    csrf = db.get_conn().execute(
        "SELECT csrf_token FROM sessions WHERE id = ?", (sid,)
    ).fetchone()["csrf_token"]
    client = TestClient(app)
    client.cookies.set(auth.SESSION_COOKIE_NAME, sid)
    client.cookies.set("csrf_token", csrf)

    with client:
        resp = client.get("/api/search", params={"q": "snorkel"})

    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 1
    assert body["items"][0]["id"] == bid
    assert "snorkel" in body["items"][0]["snippet"]
    assert {"items", "total", "offset", "limit"} <= body.keys()
