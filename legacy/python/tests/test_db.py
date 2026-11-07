"""Tests for the SQLite + FTS5 layer."""

from __future__ import annotations

from app import db


def test_schema_initializes(fresh_db):
    """get_conn() creates tables and FTS5 virtual table without error."""
    conn = fresh_db.get_conn()
    tables = {
        row["name"]
        for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type IN ('table','view','trigger')"
        )
    }
    assert "bookmarks" in tables
    assert "bookmarks_fts" in tables
    assert "tags" in tables
    assert "bookmark_tags" in tables


def test_fts_query_sanitization():
    """User input is stripped of FTS5 special chars and prefix-matched."""
    assert db.fts_query("hello world") == '"hello"* AND "world"*'
    assert db.fts_query("hello, world!") == '"hello"* AND "world"*'
    assert db.fts_query("   ") is None
    assert db.fts_query('foo"bar') == '"foo"* AND "bar"*'


def test_insert_and_fts_search(fresh_db):
    db.insert_bookmark(
        url="https://example.com/rust-book", title="The Rust Book", tags=["rust", "programming"]
    )
    db.insert_bookmark(url="https://example.com/py-book", title="Python Cookbook", tags=["python"])

    results = db.list_bookmarks(q="rust")
    assert len(results) == 1
    assert "example.com" in results[0]["domain"]

    # Prefix matching: "cook" should find "Cookbook"
    results = db.list_bookmarks(q="cook")
    assert len(results) == 1

    # URL substring search via FTS5 also works (URLs are tokenized)
    results = db.list_bookmarks(q="rust-book")
    assert len(results) == 1


def test_tag_filter_and_semantics(fresh_db):
    db.insert_bookmark(url="https://a.example/", title="A", tags=["rust", "programming"])
    db.insert_bookmark(url="https://b.example/", title="B", tags=["python", "programming"])
    db.insert_bookmark(url="https://c.example/", title="C", tags=["design"])

    assert len(db.list_bookmarks(tags=["rust"])) == 1
    assert len(db.list_bookmarks(tags=["programming"])) == 2

    # AND semantics: both tags required
    assert len(db.list_bookmarks(tags=["rust", "programming"])) == 1
    assert len(db.list_bookmarks(tags=["python", "programming"])) == 1
    assert len(db.list_bookmarks(tags=["rust", "design"])) == 0


def test_count_matches_list(fresh_db):
    db.insert_bookmark(url="https://a.example/", tags=["x"])
    db.insert_bookmark(url="https://b.example/", tags=["y"])
    db.insert_bookmark(url="https://c.example/", tags=["y"])

    assert db.count_bookmarks() == 3
    assert db.count_bookmarks(tags=["y"]) == 2
    assert db.count_bookmarks(q="a.example") == 1


def test_fts_and_tag_combine(fresh_db):
    db.insert_bookmark(url="https://a.example/rust", title="Rust guide", tags=["rust"])
    db.insert_bookmark(url="https://b.example/py", title="Python guide", tags=["python"])
    db.insert_bookmark(
        url="https://c.example/rust-book", title="Rust advanced", tags=["rust", "book"]
    )

    results = db.list_bookmarks(q="guide", tags=["rust"])
    assert {r["url"] for r in results} == {"https://a.example/rust"}


def test_duplicate_url_upserts(fresh_db):
    bid1 = db.insert_bookmark(url="https://x.example/", title="First", tags=["a"])
    bid2 = db.insert_bookmark(url="https://x.example/", title="Updated", tags=["b"])
    assert bid1 == bid2
    row = db.get_bookmark(bid1)
    assert row is not None
    assert row["title"] == "Updated"
    assert set(row["tags"]) == {"a", "b"}


def test_delete_cascades_tags(fresh_db):
    bid = db.insert_bookmark(url="https://x.example/", tags=["only-this"])
    assert db.delete_bookmark(bid) is True
    assert db.get_bookmark(bid) is None
    # Tag row is left behind (orphaned) but bookmark_tags link is gone.
    assert db.list_bookmarks(tags=["only-this"]) == []


def test_pagination(fresh_db):
    for i in range(5):
        db.insert_bookmark(url=f"https://x.example/{i}", title=f"T{i}")
    page1 = db.list_bookmarks(limit=2, offset=0)
    page2 = db.list_bookmarks(limit=2, offset=2)
    page3 = db.list_bookmarks(limit=2, offset=4)
    assert len(page1) == 2
    assert len(page2) == 2
    assert len(page3) == 1
    assert {b["url"] for b in page1 + page2 + page3} == {f"https://x.example/{i}" for i in range(5)}


def test_all_tags_counts(fresh_db):
    db.insert_bookmark(url="https://a/", tags=["rust", "programming"])
    db.insert_bookmark(url="https://b/", tags=["rust", "web"])
    db.insert_bookmark(url="https://c/", tags=["rust"])
    tags = {t["name"]: t["n"] for t in db.all_tags()}
    assert tags == {"rust": 3, "programming": 1, "web": 1}
