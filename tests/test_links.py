"""Tests for app/links.py — wikilink parsing, link sync, backlinks API.

Todo 15: parse ``[[target]]`` / ``[[target|display]]`` wikilinks from
``note_body`` on save, upsert ``links`` rows (exact-title match first, then
case-insensitive title/URL substring, then unresolved → ``target_title`` with
NULL ``target_id``), and serve ``GET /api/bookmarks/{id}/backlinks`` with
linked + unlinked (FTS5 phrase) mentions plus the link-it payload (source id +
line). The v4 migration adds ``links.target_title``.
"""

from __future__ import annotations

import sqlite3

from fastapi.testclient import TestClient

from app import auth, db, links, migrations
from app.main import app

LINKS_NAME = (
    migrations.MIGRATIONS[3][0]
    if len(migrations.MIGRATIONS) > 3
    else "m0004_links_target_title"
)


def _insert_bookmark(url: str, title: str = "") -> int:
    return db.insert_bookmark(url=url, title=title)


def _links_rows() -> list[sqlite3.Row]:
    return db.get_conn().execute(
        "SELECT source_id, target_id, target_title, display_text, line_number "
        "FROM links ORDER BY line_number"
    ).fetchall()


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
# Wikilink parsing
# ---------------------------------------------------------------------------


def test_parse_wikilinks_basic_and_line_one():
    assert links.parse_wikilinks("see [[Rust Book]] here") == [
        links.Wikilink(target="Rust Book", display=None, line_number=1)
    ]


def test_parse_wikilinks_display_part():
    assert links.parse_wikilinks("[[Rust Book|the async guide]]") == [
        links.Wikilink(target="Rust Book", display="the async guide", line_number=1)
    ]


def test_parse_wikilinks_multiple_links_and_line_numbers():
    note = "first line [[A]]\nsecond [[B|bee]] and [[C]]"
    assert links.parse_wikilinks(note) == [
        links.Wikilink(target="A", display=None, line_number=1),
        links.Wikilink(target="B", display="bee", line_number=2),
        links.Wikilink(target="C", display=None, line_number=2),
    ]


def test_parse_wikilinks_none():
    assert links.parse_wikilinks("no links here") == []


def test_parse_wikilinks_empty_display_means_plain_target():
    assert links.parse_wikilinks("[[A|]]") == [
        links.Wikilink(target="A", display=None, line_number=1)
    ]


def test_parse_wikilinks_strips_surrounding_whitespace():
    assert links.parse_wikilinks("[[  Rust Book  ]]") == [
        links.Wikilink(target="Rust Book", display=None, line_number=1)
    ]


# ---------------------------------------------------------------------------
# Target resolution order
# ---------------------------------------------------------------------------


def test_resolve_exact_title_wins_over_substring(fresh_db):
    exact = _insert_bookmark("https://exact.example/", title="Rust Guide")
    _insert_bookmark("https://sub.example/", title="Rust Guide Book")
    target_id, _ = links.resolve_target(db.get_conn(), "Rust Guide")
    assert target_id == exact


def test_resolve_case_insensitive_substring_of_title(fresh_db):
    bid = _insert_bookmark("https://ci.example/", title="Async Programming")
    target_id, _ = links.resolve_target(db.get_conn(), "async program")
    assert target_id == bid


def test_resolve_case_insensitive_substring_of_url(fresh_db):
    bid = _insert_bookmark("https://example.com/rust-notes", title="Notes")
    target_id, _ = links.resolve_target(db.get_conn(), "RUST-NOTES")
    assert target_id == bid


def test_resolve_no_match_returns_none_and_raw_target(fresh_db):
    assert links.resolve_target(db.get_conn(), "missing page") == (None, "missing page")


# ---------------------------------------------------------------------------
# Link sync (parse-on-save)
# ---------------------------------------------------------------------------


def test_sync_links_creates_resolved_and_unresolved_rows(fresh_db):
    a = _insert_bookmark("https://a.example/", title="Alpha")
    b = _insert_bookmark("https://b.example/", title="Beta")
    links.sync_links(db.get_conn(), b, "see [[Alpha]] and [[Missing Thing]]")

    rows = _links_rows()
    assert len(rows) == 2
    resolved, unresolved = rows
    assert (resolved["source_id"], resolved["target_id"]) == (b, a)
    assert resolved["target_title"] == ""
    assert resolved["display_text"] == "Alpha"
    assert resolved["line_number"] == 1
    assert unresolved["target_id"] is None
    assert unresolved["target_title"] == "Missing Thing"


def test_sync_links_display_text_uses_display_part(fresh_db):
    a = _insert_bookmark("https://a.example/", title="Alpha")
    b = _insert_bookmark("https://b.example/", title="Beta")
    links.sync_links(db.get_conn(), b, "see [[Alpha|the alpha doc]]")

    rows = _links_rows()
    assert len(rows) == 1
    assert rows[0]["display_text"] == "the alpha doc"
    assert rows[0]["target_id"] == a


def test_sync_links_resync_is_idempotent_and_drops_stale_rows(fresh_db):
    _insert_bookmark("https://a.example/", title="Alpha")
    b = _insert_bookmark("https://b.example/", title="Beta")
    conn = db.get_conn()

    links.sync_links(conn, b, "see [[Alpha]]")
    links.sync_links(conn, b, "see [[Alpha]]")
    assert len(_links_rows()) == 1  # re-saving the same note is a no-op

    links.sync_links(conn, b, "no links now")
    assert len(_links_rows()) == 0  # removing the wikilink drops its row


def test_sync_links_dedupes_same_target_on_same_line(fresh_db):
    _insert_bookmark("https://a.example/", title="Alpha")
    b = _insert_bookmark("https://b.example/", title="Beta")
    links.sync_links(db.get_conn(), b, "[[Alpha]] and again [[Alpha]]")

    rows = _links_rows()
    assert len(rows) == 1  # UNIQUE(source, target, line) — collapsed in-app


def test_sync_links_dedupes_unresolved_targets_by_title(fresh_db):
    b = _insert_bookmark("https://b.example/", title="Beta")
    links.sync_links(db.get_conn(), b, "[[Missing Thing]] twice [[Missing Thing]]")

    rows = _links_rows()
    assert len(rows) == 1
    assert rows[0]["target_id"] is None
    assert rows[0]["target_title"] == "Missing Thing"


def test_sync_links_broken_target_does_not_crash(fresh_db):
    b = _insert_bookmark("https://b.example/", title="Beta")
    links.sync_links(db.get_conn(), b, "broken [[No Such Bookmark At All]] here")

    rows = _links_rows()
    assert len(rows) == 1
    assert rows[0]["target_id"] is None
    assert rows[0]["target_title"] == "No Such Bookmark At All"


# ---------------------------------------------------------------------------
# save_note: note write + parse-on-save in one transaction
# ---------------------------------------------------------------------------


def test_save_note_updates_note_and_syncs_links(fresh_db):
    a = _insert_bookmark("https://a.example/", title="Alpha")
    b = _insert_bookmark("https://b.example/", title="Beta")
    assert links.save_note(b, "read [[Alpha]] today") is True

    conn = db.get_conn()
    assert (
        conn.execute("SELECT note_body FROM bookmarks WHERE id = ?", (b,)).fetchone()[0]
        == "read [[Alpha]] today"
    )
    rows = _links_rows()
    assert len(rows) == 1
    assert rows[0]["target_id"] == a


def test_save_note_missing_bookmark_returns_false(fresh_db):
    assert links.save_note(9999, "x") is False


# ---------------------------------------------------------------------------
# Backlinks query (module level)
# ---------------------------------------------------------------------------


def test_get_backlinks_linked_and_unlinked(fresh_db):
    a = _insert_bookmark("https://a.example/", title="Alpha Topic")
    b = _insert_bookmark("https://b.example/", title="Beta")
    c = _insert_bookmark("https://c.example/", title="Gamma")
    links.save_note(b, "I read [[Alpha Topic]] yesterday")
    links.save_note(c, "The alpha topic essay was great prose")

    result = links.get_backlinks(a)
    assert result is not None
    assert [m["source_id"] for m in result["linked"]] == [b]
    assert [m["source_id"] for m in result["unlinked"]] == [c]


def test_unlinked_excludes_sources_that_already_link(fresh_db):
    a = _insert_bookmark("https://a.example/", title="Alpha")
    b = _insert_bookmark("https://b.example/", title="Beta")
    # The note has the wikilink AND the title in prose — B is linked, so the
    # phrase match must NOT surface it again as an unlinked mention.
    links.save_note(b, "[[Alpha]] and the alpha guide rocks")

    result = links.get_backlinks(a)
    assert result is not None
    assert [m["source_id"] for m in result["linked"]] == [b]
    assert result["unlinked"] == []


def test_get_backlinks_self_is_excluded_from_unlinked(fresh_db):
    a = _insert_bookmark("https://a.example/", title="Alpha")
    links.save_note(a, "my own alpha notes about alpha things")

    result = links.get_backlinks(a)
    assert result is not None
    assert result["linked"] == []
    assert result["unlinked"] == []


def test_get_backlinks_empty_title_skips_unlinked_query(fresh_db):
    a = _insert_bookmark("https://a.example/", title="")
    b = _insert_bookmark("https://b.example/", title="Beta")
    links.save_note(b, "some note")

    result = links.get_backlinks(a)
    assert result is not None
    assert result["linked"] == []
    assert result["unlinked"] == []


def test_get_backlinks_missing_bookmark_is_none(fresh_db):
    assert links.get_backlinks(999999) is None


# ---------------------------------------------------------------------------
# Backlinks API
# ---------------------------------------------------------------------------


def test_backlinks_route_requires_auth(fresh_db):
    a = _insert_bookmark("https://a.example/", title="Alpha")
    with TestClient(app) as client:
        resp = client.get(f"/api/bookmarks/{a}/backlinks")
    assert resp.status_code == 401


def test_backlinks_route_acceptance_fixture(fresh_db):
    """3 bookmarks A, B, C: B's note has [[A]], C's note mentions A's title in
    prose → backlinks(A) returns B as linked and C as unlinked mention."""
    a = _insert_bookmark("https://a.example/", title="Alpha")
    b = _insert_bookmark("https://b.example/", title="Beta")
    c = _insert_bookmark("https://c.example/", title="Gamma")
    client, csrf = _authed_client()
    with client:
        resp = client.patch(
            f"/api/bookmarks/{b}",
            json={"note_body": "see [[Alpha]]"},
            headers={"X-CSRF-Token": csrf},
        )
        assert resp.status_code == 200, resp.text
        resp = client.patch(
            f"/api/bookmarks/{c}",
            json={"note_body": "The alpha notes changed my mind"},
            headers={"X-CSRF-Token": csrf},
        )
        assert resp.status_code == 200, resp.text
        resp = client.get(f"/api/bookmarks/{a}/backlinks")

    assert resp.status_code == 200
    body = resp.json()
    assert [m["source_id"] for m in body["linked"]] == [b]
    assert [m["source_id"] for m in body["unlinked"]] == [c]

    linked = body["linked"][0]
    assert linked["source_id"] == b
    assert linked["source_title"] == "Beta"
    assert linked["display_text"] == "Alpha"
    assert linked["line_number"] == 1
    assert "Alpha" in linked["snippet"]

    unlinked = body["unlinked"][0]
    assert unlinked["source_id"] == c
    assert unlinked["source_title"] == "Gamma"
    assert unlinked["line_number"] == 1
    assert "alpha" in unlinked["snippet"].lower()


def test_backlinks_route_404_for_missing_bookmark(fresh_db):
    client, _ = _authed_client()
    with client:
        resp = client.get("/api/bookmarks/999999/backlinks")
    assert resp.status_code == 404


def test_patch_note_requires_csrf(fresh_db):
    b = _insert_bookmark("https://b.example/", title="Beta")
    client, _ = _authed_client()
    with client:
        resp = client.patch(f"/api/bookmarks/{b}", json={"note_body": "x"})
    assert resp.status_code == 403  # CSRF token missing


def test_patch_note_rejects_non_string_note_body(fresh_db):
    b = _insert_bookmark("https://b.example/", title="Beta")
    client, csrf = _authed_client()
    with client:
        resp = client.patch(
            f"/api/bookmarks/{b}",
            json={"note_body": 42},
            headers={"X-CSRF-Token": csrf},
        )
    assert resp.status_code == 400


def test_patch_note_missing_bookmark_404(fresh_db):
    client, csrf = _authed_client()
    with client:
        resp = client.patch(
            "/api/bookmarks/999999",
            json={"note_body": "x"},
            headers={"X-CSRF-Token": csrf},
        )
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# FK cascade + v4 migration
# ---------------------------------------------------------------------------


def test_delete_bookmark_cascades_links(fresh_db):
    conn = db.get_conn()
    a = _insert_bookmark("https://a.example/", title="Alpha")
    b = _insert_bookmark("https://b.example/", title="Beta")
    links.save_note(b, "[[Alpha]]")
    assert conn.execute("SELECT count(*) FROM links").fetchone()[0] == 1

    db.delete_bookmark(a)  # deleting the TARGET cascades the row
    assert conn.execute("SELECT count(*) FROM links").fetchone()[0] == 0

    c = _insert_bookmark("https://c.example/", title="Gamma")
    _insert_bookmark("https://d.example/", title="Delta")
    links.save_note(c, "[[Delta]]")
    assert conn.execute("SELECT count(*) FROM links").fetchone()[0] == 1
    db.delete_bookmark(c)  # deleting the SOURCE cascades the row
    assert conn.execute("SELECT count(*) FROM links").fetchone()[0] == 0


def test_v4_adds_target_title_to_links(fresh_db):
    cols = {row["name"] for row in db.get_conn().execute("PRAGMA table_info(links)")}
    assert "target_title" in cols


def test_v3_db_reaches_v4_via_runner_preserving_links(db_path):
    """A genuine v3 database migrates through the runner to v4: the column
    appears, existing resolved rows keep target_title = ''."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.executescript(db._SCHEMA)
    conn.execute("PRAGMA user_version = 1")
    full = list(migrations.MIGRATIONS)
    try:
        migrations.MIGRATIONS = full[:3]
        db.run_migrations(conn)
    finally:
        migrations.MIGRATIONS = full
    assert conn.execute("PRAGMA user_version").fetchone()[0] == 3
    conn.execute(
        "INSERT INTO bookmarks (url, title, domain, created_at) "
        "VALUES ('https://a.example/', 'Alpha', 'a.example', 1)"
    )
    conn.execute(
        "INSERT INTO links (source_id, target_id, display_text, line_number) VALUES (1, 1, 'Alpha', 1)"
    )
    conn.commit()
    conn.close()

    db.get_conn()  # production init path: _SCHEMA no-op + pending v4+v5 migrations
    conn = db.get_conn()
    assert conn.execute("PRAGMA user_version").fetchone()[0] == 5
    cols = {r["name"] for r in conn.execute("PRAGMA table_info(links)")}
    assert "target_title" in cols
    row = conn.execute("SELECT source_id, target_id, target_title FROM links").fetchone()
    assert (row["source_id"], row["target_id"], row["target_title"]) == (1, 1, "")
    assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
