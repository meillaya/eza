"""Bookmark detail + note editing (todo 17).

Covers the acceptance contract:

- ``GET /api/bookmarks/{id}`` returns the full record plus ``note_body``,
  ``extracted_text``, a ``backlinks`` summary (linked + unlinked, reusing
  ``links.get_backlinks``) and the ``tags`` list.
- ``PATCH /api/bookmarks/{id}`` (the route todo 15 introduced as a note-save
  path, extended here) accepts ``note_body``, ``title``, ``tags`` and
  ``is_read`` in any combination, applied atomically. The ``tags`` list is
  authoritative (tags removed from the list are unlinked); an empty title is
  rejected 400 with no write side effects.
- ``GET /bookmark/{id}`` renders the detail page; the reader section embeds
  the stored ``extracted_text`` when present (a minimal reader display, not a
  Pocket-style reading app).
"""

from __future__ import annotations

from fastapi.testclient import TestClient

from app import auth, db, links
from app.main import app


def _insert_bookmark(url: str, title: str = "", **kwargs) -> int:
    return db.insert_bookmark(url=url, title=title, **kwargs)


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


# ---------------------------------------------------------------------------
# GET /api/bookmarks/{id} — detail fetch
# ---------------------------------------------------------------------------


def test_detail_get_returns_note_body(fresh_db):
    bid = _insert_bookmark("https://note.example/", title="Note Me")
    client, _ = _authed_client()
    with client:
        resp = client.patch(
            f"/api/bookmarks/{bid}",
            json={"note_body": "my note about things"},
            headers={"X-CSRF-Token": _csrf(client)},
        )
        assert resp.status_code == 200, resp.text
        resp = client.get(f"/api/bookmarks/{bid}")

    assert resp.status_code == 200
    body = resp.json()
    assert body["id"] == bid
    assert body["note_body"] == "my note about things"


def test_detail_get_returns_extracted_text_and_tags(fresh_db):
    bid = _insert_bookmark("https://extract.example/", title="Extracted", tags=["rust", "web"])
    db.update_metadata(bid, extracted_text="The full article text about async rust.")
    client, _ = _authed_client()
    with client:
        resp = client.get(f"/api/bookmarks/{bid}")

    assert resp.status_code == 200
    body = resp.json()
    assert body["extracted_text"] == "The full article text about async rust."
    assert body["tags"] == ["rust", "web"]


def test_detail_get_returns_backlinks_summary(fresh_db):
    a = _insert_bookmark("https://a.example/", title="Alpha Topic")
    b = _insert_bookmark("https://b.example/", title="Beta")
    links.save_note(b, "I read [[Alpha Topic]] yesterday")
    client, _ = _authed_client()
    with client:
        resp = client.get(f"/api/bookmarks/{a}")

    assert resp.status_code == 200
    body = resp.json()
    assert [m["source_id"] for m in body["backlinks"]["linked"]] == [b]
    assert body["backlinks"]["unlinked"] == []


def test_detail_get_requires_auth(fresh_db):
    _insert_bookmark("https://auth.example/")
    with TestClient(app) as client:
        resp = client.get("/api/bookmarks/1")
    assert resp.status_code == 401


def test_detail_get_404_for_missing_bookmark(fresh_db):
    client, _ = _authed_client()
    with client:
        resp = client.get("/api/bookmarks/999999")
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# PATCH /api/bookmarks/{id} — extended edit (title/tags/is_read/note_body)
# ---------------------------------------------------------------------------


def _csrf(client: TestClient) -> str:
    return client.cookies.get("csrf_token")


def test_patch_updates_note_title_tags_is_read_atomically(fresh_db):
    bid = _insert_bookmark("https://edit.example/", title="Old Title", tags=["old"])
    client, _ = _authed_client()
    with client:
        resp = client.patch(
            f"/api/bookmarks/{bid}",
            json={
                "note_body": "edited note",
                "title": "New Title",
                "tags": ["rust", "web"],
                "is_read": 1,
            },
            headers={"X-CSRF-Token": _csrf(client)},
        )
        assert resp.status_code == 200, resp.text
        resp = client.get(f"/api/bookmarks/{bid}")

    assert resp.status_code == 200
    body = resp.json()
    assert body["note_body"] == "edited note"
    assert body["title"] == "New Title"
    assert body["tags"] == ["rust", "web"]
    assert body["is_read"] == 1


def test_patch_tags_list_is_authoritative(fresh_db):
    """Tags passed to PATCH replace the full set — tags dropped from the list
    are unlinked from the bookmark."""
    bid = _insert_bookmark("https://tags.example/", tags=["keep", "drop"])
    client, _ = _authed_client()
    with client:
        resp = client.patch(
            f"/api/bookmarks/{bid}",
            json={"tags": ["keep"]},
            headers={"X-CSRF-Token": _csrf(client)},
        )
        assert resp.status_code == 200, resp.text
        resp = client.get(f"/api/bookmarks/{bid}")

    assert resp.json()["tags"] == ["keep"]


def test_patch_note_still_syncs_wikilinks(fresh_db):
    """The todo-15 note path is preserved: saving a note with [[wikilinks]]
    still writes links rows."""
    _insert_bookmark("https://a.example/", title="Alpha")
    b = _insert_bookmark("https://b.example/", title="Beta")
    client, _ = _authed_client()
    with client:
        resp = client.patch(
            f"/api/bookmarks/{b}",
            json={"note_body": "see [[Alpha]]"},
            headers={"X-CSRF-Token": _csrf(client)},
        )
        assert resp.status_code == 200, resp.text

    assert db.get_conn().execute("SELECT count(*) FROM links").fetchone()[0] == 1


def test_patch_is_read_accepts_bool(fresh_db):
    bid = _insert_bookmark("https://read.example/")
    client, _ = _authed_client()
    with client:
        resp = client.patch(
            f"/api/bookmarks/{bid}",
            json={"is_read": True},
            headers={"X-CSRF-Token": _csrf(client)},
        )
        assert resp.status_code == 200, resp.text
        resp = client.get(f"/api/bookmarks/{bid}")

    assert resp.json()["is_read"] == 1


def test_patch_empty_title_rejected_400_without_side_effects(fresh_db):
    """Empty/whitespace-only title -> 400, and NOTHING else in the payload is
    written (existing data untouched by a failed update)."""
    bid = _insert_bookmark("https://guard.example/", title="Keep Me")
    client, _ = _authed_client()
    with client:
        resp = client.patch(
            f"/api/bookmarks/{bid}",
            json={"title": "   ", "note_body": "must not persist"},
            headers={"X-CSRF-Token": _csrf(client)},
        )
        assert resp.status_code == 400
        resp = client.get(f"/api/bookmarks/{bid}")

    body = resp.json()
    assert body["title"] == "Keep Me"
    assert body["note_body"] == ""


def test_patch_rejects_bad_field_types(fresh_db):
    bid = _insert_bookmark("https://types.example/", title="Types")
    client, _ = _authed_client()
    cases = [
        {"note_body": 42},
        {"title": 42},
        {"tags": "not-a-list"},
        {"tags": ["ok", 7]},
        {"is_read": 2},
        {"is_read": "yes"},
    ]
    for payload in cases:
        with client:
            resp = client.patch(
                f"/api/bookmarks/{bid}",
                json=payload,
                headers={"X-CSRF-Token": _csrf(client)},
            )
        assert resp.status_code == 400, f"{payload} -> {resp.status_code}"


def test_patch_empty_payload_rejected(fresh_db):
    bid = _insert_bookmark("https://noop.example/", title="Noop")
    client, _ = _authed_client()
    with client:
        resp = client.patch(
            f"/api/bookmarks/{bid}",
            json={},
            headers={"X-CSRF-Token": _csrf(client)},
        )
    assert resp.status_code == 400


def test_patch_404_for_missing_bookmark(fresh_db):
    client, _ = _authed_client()
    with client:
        resp = client.patch(
            "/api/bookmarks/999999",
            json={"title": "Ghost"},
            headers={"X-CSRF-Token": _csrf(client)},
        )
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Detail page — GET /bookmark/{id} HTML reader view
# ---------------------------------------------------------------------------


def test_detail_page_renders_extracted_text(fresh_db):
    bid = _insert_bookmark("https://reader.example/", title="Reader")
    db.update_metadata(bid, extracted_text="The stored article body is shown here.")
    client, _ = _authed_client()
    with client:
        resp = client.get(f"/bookmark/{bid}", headers={"Accept": "text/html"})

    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "The stored article body is shown here." in resp.text


def test_detail_page_renders_reader_container_without_extraction(fresh_db):
    """The reader section exists even with no extracted_text (an empty-state
    message), so the page shape is stable."""
    bid = _insert_bookmark("https://empty.example/", title="Empty")
    client, _ = _authed_client()
    with client:
        resp = client.get(f"/bookmark/{bid}", headers={"Accept": "text/html"})

    assert resp.status_code == 200
    assert 'id="reader"' in resp.text


def test_detail_page_escapes_extracted_text(fresh_db):
    """Stored extraction is rendered as text, never as HTML."""
    bid = _insert_bookmark("https://xss.example/", title="XSS")
    db.update_metadata(bid, extracted_text='<script>alert("pwned")</script>')
    client, _ = _authed_client()
    with client:
        resp = client.get(f"/bookmark/{bid}", headers={"Accept": "text/html"})

    assert resp.status_code == 200
    assert "<script>alert" not in resp.text


def test_detail_page_404_for_missing_bookmark(fresh_db):
    client, _ = _authed_client()
    with client:
        resp = client.get("/bookmark/999999", headers={"Accept": "text/html"})
    assert resp.status_code == 404
