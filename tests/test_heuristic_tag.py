"""Tests for the heuristic domain matcher."""

from __future__ import annotations

import pytest

from app import db, heuristic_tag


@pytest.mark.parametrize(
    "url,expected",
    [
        # Code/dev
        ("https://github.com/anthropics/claude-code", "code"),
        ("https://gist.github.com/foo/bar", "code"),
        ("https://www.github.com/foo", "code"),
        ("https://crates.io/crates/serde", "code-rust"),
        ("https://docs.rust-lang.org/std/", "code-rust"),
        ("https://stackoverflow.com/questions/12345", "code-qa"),
        ("https://huggingface.co/datasets/foo", "code-ai"),
        ("https://user.github.io/blog", "code-pages"),
        # News
        ("https://www.nytimes.com/2026/01/article", "news"),
        ("https://theguardian.com/foo", "news"),
        # Research
        ("https://arxiv.org/abs/2401.00001", "research-papers"),
        ("https://scholar.google.com/citations?user=abc", "research-papers"),
        # Books
        ("https://literal.club/book/123", "books"),
        ("https://www.theparisreview.org/blog/2026/01/x", "books"),
        # Film / music
        ("https://letterboxd.com/film/foo", "film"),
        ("https://bandcamp.com/album/foo", "music"),
        # Social
        ("https://twitter.com/user/status/123", "social"),
        ("https://x.com/user", "social"),
        ("https://www.reddit.com/r/python", "social"),
        # Video / games / anime
        ("https://www.youtube.com/watch?v=abc", "video"),
        ("https://store.steampowered.com/app/123", "games"),
        ("https://myanimelist.net/anime/1", "anime"),
        # Adult bucket
        ("https://rule34video.com/play/123", "adult"),
        # Suffix/TLD rules
        ("https://cs.berkeley.edu/~foo/paper.pdf", "academic"),
        ("https://www.gov.uk/register-to-vote", "government"),
    ],
)
def test_match_domain(url: str, expected: str):
    assert heuristic_tag.match_domain(url) == expected


def test_match_domain_returns_none_for_unknown():
    assert heuristic_tag.match_domain("https://example.com/something") is None
    assert heuristic_tag.match_domain("https://this-domain-does-not-exist-12345.io/") is None


def test_match_domain_handles_url_without_host():
    assert heuristic_tag.match_domain("not a url") is None


def test_match_domain_handles_path_only_subdomains():
    # Subdomain of a known host should match the parent rule via suffix
    assert heuristic_tag.match_domain("https://api.github.com/repos") == "code"
    assert (
        heuristic_tag.match_domain("https://blog.cloudflare.com/x") == "tech"
        or heuristic_tag.match_domain("https://blog.cloudflare.com/x") is None
    )  # not in rules


# ---------------------------------------------------------------------------
# Orchestration tests (use the fresh_db fixture)
# ---------------------------------------------------------------------------


def test_heuristic_tag_buckets_targets_specific_tag(fresh_db):
    db.insert_bookmark(url="https://github.com/x", title="x")
    db.insert_bookmark(url="https://www.nytimes.com/article", title="y")
    db.insert_bookmark(url="https://unknown-domain-zzz.io/", title="z")
    for b in db.list_bookmarks():
        db.bulk_add_tags([b["id"]], ["fat"])

    results = heuristic_tag.heuristic_tag_buckets(
        targets=["fat"], min_count=0, remove_generic=False, dry_run=True
    )
    assert len(results) == 1
    r = results[0]
    assert r["tag"] == "fat"
    assert r["bookmarks_in_bucket"] == 3
    assert r["matched_count"] == 2
    assert set(r["added_tags"]) == {"code", "news"}
    assert r["breakdown"]["code"] == 1
    assert r["breakdown"]["news"] == 1


def test_heuristic_tag_buckets_only_tags_matched(fresh_db):
    """The heuristic should only tag bookmarks whose URL actually matched
    a rule. Unmatched bookmarks in the bucket keep only the generic tag."""
    bid_matched = db.insert_bookmark(url="https://github.com/x", title="x")
    bid_unmatched = db.insert_bookmark(url="https://unknown-domain-zzz.io/", title="z")
    db.bulk_add_tags([bid_matched, bid_unmatched], ["fat"])

    results = heuristic_tag.heuristic_tag_buckets(
        targets=["fat"], min_count=0, remove_generic=False, dry_run=False
    )
    assert results[0]["matched_count"] == 1
    # Matched bookmark got 'code' tag
    matched_tags = db.get_tags_for_bookmark(bid_matched)
    assert "code" in matched_tags
    assert "fat" in matched_tags
    # Unmatched bookmark kept only 'fat'
    unmatched_tags = db.get_tags_for_bookmark(bid_unmatched)
    assert unmatched_tags == ["fat"]


def test_heuristic_tag_buckets_remove_generic_only_matched(fresh_db):
    bid_matched = db.insert_bookmark(url="https://github.com/x", title="x")
    bid_unmatched = db.insert_bookmark(url="https://unknown-zzz.io/", title="z")
    db.bulk_add_tags([bid_matched, bid_unmatched], ["fat"])

    heuristic_tag.heuristic_tag_buckets(
        targets=["fat"], min_count=0, remove_generic=True, dry_run=False
    )
    # Matched: 'fat' removed, 'code' added
    matched_tags = db.get_tags_for_bookmark(bid_matched)
    assert "code" in matched_tags
    assert "fat" not in matched_tags
    # Unmatched: 'fat' preserved (so it's still findable)
    unmatched_tags = db.get_tags_for_bookmark(bid_unmatched)
    assert unmatched_tags == ["fat"]


def test_heuristic_tag_buckets_skips_empty(fresh_db):
    results = heuristic_tag.heuristic_tag_buckets(
        targets=["nonexistent-tag"], min_count=0, remove_generic=False, dry_run=True
    )
    assert results == []


def test_heuristic_tag_buckets_picks_by_threshold(fresh_db):
    # 3 distinct bookmarks all tagged "popular" (URLs must differ for unique ids)
    for i in range(3):
        bid = db.insert_bookmark(url=f"https://github.com/{i}")
        db.bulk_add_tags([bid], ["popular"])
    # 1 bookmark tagged "rare"
    bid = db.insert_bookmark(url="https://github.com/solo")
    db.bulk_add_tags([bid], ["rare"])

    results = heuristic_tag.heuristic_tag_buckets(
        targets=[], min_count=3, remove_generic=False, dry_run=True
    )
    bucket_names = {r["tag"] for r in results}
    assert "popular" in bucket_names
    assert "rare" not in bucket_names
