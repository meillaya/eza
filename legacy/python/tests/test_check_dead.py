"""Tests for the dead-link checker helpers."""

from __future__ import annotations

from app import db


def test_mark_checked_sets_flags(fresh_db):
    bid = db.insert_bookmark(url="https://x.example/")
    db.mark_checked(bid, is_dead=False)
    row = db.get_bookmark(bid)
    assert row is not None
    assert row["is_dead"] == 0
    assert row["last_checked_at"] is not None

    db.mark_checked(bid, is_dead=True)
    row = db.get_bookmark(bid)
    assert row is not None
    assert row["is_dead"] == 1


def test_unchecked_returns_unmarked_first(fresh_db):
    db.insert_bookmark(url="https://a.example/")
    b = db.insert_bookmark(url="https://b.example/")
    db.insert_bookmark(url="https://c.example/")

    # Mark b as already checked
    db.mark_checked(b, is_dead=False)

    # Default: should return a and c (unchecked)
    pending = {row["url"] for row in db.unchecked_bookmarks()}
    assert pending == {"https://a.example/", "https://c.example/"}

    # With older_than=0 and include_dead=False, b is excluded (it's now flagged live)
    pending = {row["url"] for row in db.unchecked_bookmarks(include_dead=False)}
    assert pending == {"https://a.example/", "https://c.example/"}
    # Mark b dead — should still be excluded by default since it has a timestamp
    db.mark_checked(b, is_dead=True)
    pending = {row["url"] for row in db.unchecked_bookmarks(include_dead=False)}
    assert "https://b.example/" not in pending


def test_unchecked_respects_limit_and_older_than(fresh_db):
    for i in range(5):
        db.insert_bookmark(url=f"https://x.example/{i}")

    # Limit caps results
    rows = db.unchecked_bookmarks(limit=3)
    assert len(rows) == 3

    # Mark one as checked just now
    db.mark_checked(1, is_dead=False)

    # older_than=0 means "stricter than the most recent check" → only the
    # unchecked rows should come back.
    rows = db.unchecked_bookmarks(older_than=0)
    assert len(rows) == 4
    assert all(r["id"] != 1 for r in rows)
