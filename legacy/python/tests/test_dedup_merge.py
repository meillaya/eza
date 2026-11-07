"""Dedup merge + undo (todo 26).

Contract under test:

- ``merge_bookmarks(keep_id, merge_ids)`` — a user-confirmed, undo-able merge
  inside one ``BEGIN IMMEDIATE`` transaction:
  * tags from every merge row are unioned onto keep (order-preserving dedupe —
    a tag already on keep is never duplicated);
  * if keep has no note, the first merge row's note is adopted; if BOTH keep
    and a merge row have notes, KEEP wins and the discarded note is stored
    inside the snapshot payload (NOTE-COLLISION RULE);
  * links rows mentioning merge rows are re-pointed to keep (self-links after
    re-pointing are dropped, collisions deduped);
  * the merge rows are deleted;
  * a full pre-merge state is written to ``undo_snapshots`` so undo restores
    everything.
  Merging across different normalized domains is rejected; empty ``merge_ids``
  is rejected. Nothing merges without an explicit call.
- ``undo_merge()`` — pops the LATEST snapshot and restores the merged rows
  (bookmarks + tags + notes + links), including the discarded note.
- ``POST /api/dedup/merge`` / ``DELETE /api/dedup/undo`` — authed, CSRF-checked
  mutations; the API maps MergeError -> 400 and UndoError -> 404 (an empty
  undo stack is 404: there is no snapshot resource to consume).
"""

from __future__ import annotations

import json

import pytest
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


def _bookmark_row(bookmark_id: int) -> dict:
    return dict(
        db.get_conn().execute("SELECT * FROM bookmarks WHERE id = ?", (bookmark_id,)).fetchone()
    )


def _tags(bookmark_id: int) -> list[str]:
    return db.get_tags_for_bookmark(bookmark_id)


def _link_rows() -> list[dict]:
    return [
        dict(r)
        for r in db.get_conn()
        .execute("SELECT source_id, target_id, target_title, display_text, line_number FROM links ORDER BY id")
        .fetchall()
    ]


def _snapshot_payloads() -> list[dict]:
    rows = db.get_conn().execute(
        "SELECT payload_json FROM undo_snapshots ORDER BY id"
    ).fetchall()
    return [json.loads(r["payload_json"]) for r in rows]


def _seed_merge_pair(conn=None) -> tuple[int, int]:
    """Two URL-normalized-duplicate candidates on the same domain.

    keep carries tags ``a``/``b`` and its own note; merge carries tag ``c``
    (sharing ``b``) and a DIFFERENT note — the exact collision the
    NOTE-COLLISION RULE governs.
    """
    keep = db.insert_bookmark(url="https://example.com/dup", title="Same Page", tags=["a", "b"])
    db.update_bookmark(keep, note_body="keep's note")
    merge = db.insert_bookmark(
        url="https://example.com/dup?utm_source=x", title="Same Page", tags=["b", "c"]
    )
    db.update_bookmark(merge, note_body="merge's note")
    return keep, merge


# ---------------------------------------------------------------------------
# Migration: m0005 lands the DB on version 5; m0006 appends saved_searches
# ---------------------------------------------------------------------------


def test_fresh_db_has_undo_snapshots_table_at_version_6(fresh_db):
    conn = fresh_db.get_conn()
    assert conn.execute("PRAGMA user_version").fetchone()[0] == 6
    tables = {
        row["name"] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
    }
    assert "undo_snapshots" in tables
    columns = {
        row["name"] for row in conn.execute("PRAGMA table_info(undo_snapshots)")
    }
    assert {"id", "payload_json", "created_at"} <= columns


# ---------------------------------------------------------------------------
# merge_bookmarks — direct unit tests
# ---------------------------------------------------------------------------


def test_merge_combines_tags_and_keeps_note_on_collision(fresh_db):
    keep, merge = _seed_merge_pair()

    result = dedup.merge_bookmarks(keep, [merge])

    assert result == {"snapshot_id": 1, "kept": keep, "merged": [merge]}
    assert _tags(keep) == ["a", "b", "c"]  # combined, deduped
    assert _bookmark_row(keep)["note_body"] == "keep's note"  # KEEP wins
    assert db.get_bookmark(merge) is None  # merge row gone

    # The discarded note is captured in the snapshot payload.
    payloads = _snapshot_payloads()
    assert len(payloads) == 1
    payload = payloads[0]
    assert payload["keep_id"] == keep
    assert payload["merge_ids"] == [merge]
    assert payload["merged"][0]["row"]["note_body"] == "merge's note"


def test_merge_adopts_merge_note_when_keep_has_none(fresh_db):
    keep = db.insert_bookmark(url="https://example.com/dup", title="Same Page", tags=["x"])
    merge = db.insert_bookmark(url="https://example.com/dup?utm_source=x", title="Same Page")
    db.update_bookmark(merge, note_body="the only note")

    dedup.merge_bookmarks(keep, [merge])

    assert _bookmark_row(keep)["note_body"] == "the only note"
    assert _tags(keep) == ["x"]


def test_merge_keeps_keep_tags_when_merge_has_none(fresh_db):
    keep = db.insert_bookmark(url="https://example.com/dup", title="Same Page", tags=["a"])
    merge = db.insert_bookmark(url="https://example.com/dup?utm_source=x", title="Same Page")
    db.update_bookmark(merge, note_body="note")

    dedup.merge_bookmarks(keep, [merge])

    assert _tags(keep) == ["a"]
    assert _bookmark_row(keep)["note_body"] == "note"


def test_merge_repoints_links_and_dedupes(fresh_db):
    keep = db.insert_bookmark(url="https://example.com/k", title="Keep Page")
    merge = db.insert_bookmark(url="https://example.com/k?utm_source=x", title="Keep Page")
    other = db.insert_bookmark(url="https://example.com/o", title="Other Page")
    db.update_bookmark(keep, note_body="see [[Other Page]]")          # (keep -> other)
    db.update_bookmark(merge, note_body="see [[Other Page]]")         # (merge -> other) — collides with keep's after re-point
    db.update_bookmark(other, note_body="points at [[Keep Page]]")    # (other -> merge) -> re-pointed to keep

    dedup.merge_bookmarks(keep, [merge])

    links = _link_rows()
    assert [row["source_id"] for row in links] == [keep, other]
    assert [row["target_id"] for row in links] == [other, keep]
    # No self-link (keep -> keep from the merge->keep repoint would be dropped).
    assert all(row["source_id"] != row["target_id"] for row in links)


def test_merge_multi_row_fold_with_one_note_adopted(fresh_db):
    keep = db.insert_bookmark(url="https://example.com/dup", title="Same Page")
    merge1 = db.insert_bookmark(url="https://example.com/dup?utm_source=x", title="Same Page")
    db.update_bookmark(merge1, note_body="first merge note")
    merge2 = db.insert_bookmark(url="https://example.com/dup?utm_source=y", title="Same Page")
    db.update_bookmark(merge2, note_body="second merge note")

    result = dedup.merge_bookmarks(keep, [merge1, merge2])

    assert result["merged"] == [merge1, merge2]
    assert _bookmark_row(keep)["note_body"] == "first merge note"  # lowest-id merge note wins
    assert db.get_bookmark(merge1) is None
    assert db.get_bookmark(merge2) is None
    payload = _snapshot_payloads()[0]
    assert {m["row"]["note_body"] for m in payload["merged"]} == {
        "first merge note",
        "second merge note",
    }


# ---------------------------------------------------------------------------
# merge_bookmarks — rejection guards
# ---------------------------------------------------------------------------


def test_merge_empty_merge_ids_rejected(fresh_db):
    keep = db.insert_bookmark(url="https://example.com/dup", title="Same Page")
    with pytest.raises(dedup.MergeError, match="empty"):
        dedup.merge_bookmarks(keep, [])
    assert len(_snapshot_payloads()) == 0


def test_merge_rejects_keep_inside_merge_ids(fresh_db):
    keep = db.insert_bookmark(url="https://example.com/dup", title="Same Page")
    with pytest.raises(dedup.MergeError, match="into itself"):
        dedup.merge_bookmarks(keep, [keep])


def test_merge_rejects_missing_keep(fresh_db):
    with pytest.raises(dedup.MergeError, match="does not exist"):
        dedup.merge_bookmarks(999, [1])


def test_merge_rejects_missing_merge_row(fresh_db):
    keep = db.insert_bookmark(url="https://example.com/dup", title="Same Page")
    with pytest.raises(dedup.MergeError, match="does not exist"):
        dedup.merge_bookmarks(keep, [999])


def test_merge_rejects_different_domains(fresh_db):
    keep = db.insert_bookmark(url="https://example.com/a", title="Same Page")
    merge = db.insert_bookmark(url="https://other.com/a", title="Same Page")
    with pytest.raises(dedup.MergeError, match="different domains"):
        dedup.merge_bookmarks(keep, [merge])
    assert db.get_bookmark(keep) is not None
    assert db.get_bookmark(merge) is not None
    assert len(_snapshot_payloads()) == 0


def test_merge_domain_guard_uses_normalized_domain(fresh_db):
    # www./non-www hosts normalize to the same domain — the merge is allowed.
    keep = db.insert_bookmark(url="https://www.example.com/dup", title="Same Page")
    merge = db.insert_bookmark(url="https://example.com/dup", title="Same Page")
    dedup.merge_bookmarks(keep, [merge])
    assert db.get_bookmark(merge) is None


# ---------------------------------------------------------------------------
# undo_merge — direct round trip
# ---------------------------------------------------------------------------


def test_undo_restores_everything_including_discarded_note(fresh_db):
    keep, merge = _seed_merge_pair()
    dedup.merge_bookmarks(keep, [merge])

    result = dedup.undo_merge()

    assert result["kept"] == keep
    assert result["restored"] == [merge]
    # Keep row back to its original state.
    assert _bookmark_row(keep)["note_body"] == "keep's note"
    assert _tags(keep) == ["a", "b"]
    # The merged row is back with its own note (the discarded one) + tags.
    restored = _bookmark_row(merge)
    assert restored["note_body"] == "merge's note"
    assert restored["url"] == "https://example.com/dup?utm_source=x"
    assert _tags(merge) == ["b", "c"]
    # The snapshot was consumed.
    assert len(_snapshot_payloads()) == 0


def test_undo_restores_links(fresh_db):
    keep = db.insert_bookmark(url="https://example.com/k", title="Keep Page")
    merge = db.insert_bookmark(url="https://example.com/k?utm_source=x", title="Keep Page")
    other = db.insert_bookmark(url="https://example.com/o", title="Other Page")
    db.update_bookmark(keep, note_body="see [[Other Page]]")
    db.update_bookmark(merge, note_body="see [[Other Page]]")
    db.update_bookmark(other, note_body="points at [[Keep Page]]")
    before = _link_rows()

    dedup.merge_bookmarks(keep, [merge])
    assert _link_rows() != before  # links were re-pointed
    dedup.undo_merge()

    assert _link_rows() == before  # every link row is restored exactly


def test_undo_restores_multiple_merged_rows(fresh_db):
    keep = db.insert_bookmark(url="https://example.com/dup", title="Same Page", tags=["a"])
    merge1 = db.insert_bookmark(url="https://example.com/dup?utm_source=x", title="Same Page")
    db.update_bookmark(merge1, note_body="note one")
    merge2 = db.insert_bookmark(url="https://example.com/dup?utm_source=y", title="Same Page")
    db.update_bookmark(merge2, note_body="note two")

    dedup.merge_bookmarks(keep, [merge1, merge2])
    dedup.undo_merge()

    assert _bookmark_row(merge1)["note_body"] == "note one"
    assert _bookmark_row(merge2)["note_body"] == "note two"
    assert _tags(keep) == ["a"]
    assert len(_snapshot_payloads()) == 0


def test_undo_empty_stack_raises_undo_error(fresh_db):
    with pytest.raises(dedup.UndoError):
        dedup.undo_merge()


# ---------------------------------------------------------------------------
# API — merge / undo over TestClient
# ---------------------------------------------------------------------------


def test_api_merge_requires_auth(fresh_db):
    with TestClient(app) as client:
        resp = client.post(
            "/api/dedup/merge", json={"keep_id": 1, "merge_ids": [2]}
        )
    assert resp.status_code == 401


def test_api_merge_happy_path_and_undo_round_trip(fresh_db):
    """Acceptance: merge two candidates where BOTH have notes -> keep row has
    combined tags + keep's note (discarded note captured), merge rows gone,
    undo restores everything including the discarded note."""
    keep, merge = _seed_merge_pair()
    client = _authed_client()
    with client:
        resp = client.post(
            "/api/dedup/merge",
            json={"keep_id": keep, "merge_ids": [merge]},
            headers={"X-CSRF-Token": client.cookies.get("csrf_token")},
        )

        assert resp.status_code == 200, resp.text
        assert resp.json() == {"snapshot_id": 1, "kept": keep, "merged": [merge]}
        assert _tags(keep) == ["a", "b", "c"]
        assert _bookmark_row(keep)["note_body"] == "keep's note"
        assert db.get_bookmark(merge) is None
        assert _snapshot_payloads()[0]["merged"][0]["row"]["note_body"] == "merge's note"

        undo = client.delete(
            "/api/dedup/undo", headers={"X-CSRF-Token": client.cookies.get("csrf_token")}
        )
        assert undo.status_code == 200, undo.text
        assert undo.json() == {"snapshot_id": 1, "kept": keep, "restored": [merge]}
        assert _bookmark_row(keep)["note_body"] == "keep's note"
        assert _bookmark_row(merge)["note_body"] == "merge's note"
        assert _tags(merge) == ["b", "c"]
        assert len(_snapshot_payloads()) == 0


def test_api_merge_empty_merge_ids_returns_400(fresh_db):
    keep = db.insert_bookmark(url="https://example.com/dup", title="Same Page")
    client = _authed_client()
    with client:
        resp = client.post(
            "/api/dedup/merge",
            json={"keep_id": keep, "merge_ids": []},
            headers={"X-CSRF-Token": client.cookies.get("csrf_token")},
        )
    assert resp.status_code == 400


def test_api_merge_cross_domain_returns_400(fresh_db):
    keep = db.insert_bookmark(url="https://example.com/a", title="Same Page")
    merge = db.insert_bookmark(url="https://other.com/a", title="Same Page")
    client = _authed_client()
    with client:
        resp = client.post(
            "/api/dedup/merge",
            json={"keep_id": keep, "merge_ids": [merge]},
            headers={"X-CSRF-Token": client.cookies.get("csrf_token")},
        )
    assert resp.status_code == 400
    assert db.get_bookmark(merge) is not None  # nothing was merged


def test_api_merge_invalid_body_returns_400(fresh_db):
    client = _authed_client()
    with client:
        resp = client.post(
            "/api/dedup/merge",
            json={"keep_id": "not-an-int", "merge_ids": [1]},
            headers={"X-CSRF-Token": client.cookies.get("csrf_token")},
        )
    assert resp.status_code == 400


def test_api_merge_requires_csrf(fresh_db):
    keep = db.insert_bookmark(url="https://example.com/dup", title="Same Page")
    client = _authed_client()
    with client:
        resp = client.post(
            "/api/dedup/merge",
            json={"keep_id": keep, "merge_ids": [keep + 1]},
            headers={"X-CSRF-Token": "wrong"},
        )
    assert resp.status_code == 403


def test_api_undo_empty_stack_returns_404(fresh_db):
    client = _authed_client()
    with client:
        resp = client.delete(
            "/api/dedup/undo", headers={"X-CSRF-Token": client.cookies.get("csrf_token")}
        )
    assert resp.status_code == 404
