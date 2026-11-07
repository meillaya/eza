"""Tests for the auto-tagger: sampling, response parsing, DB helpers."""

from __future__ import annotations

import json

import httpx
import pytest

from app import auto_tag, db

# ---------------------------------------------------------------------------
# Sampling
# ---------------------------------------------------------------------------


def test_stratified_sample_respects_size():
    bookmarks = [
        {"id": i, "url": f"https://d{i // 3}.example/{i}", "domain": f"d{i // 3}.example"}
        for i in range(30)
    ]
    # 10 domains (0-2 → d0, 3-5 → d1, ...). Sample 12 → at least one per domain.
    sample = auto_tag._stratified_sample(bookmarks, 12)
    assert len(sample) == 12
    domains = {b["domain"] for b in sample}
    # At least 8 distinct domains represented
    assert len(domains) >= 8


def test_stratified_sample_short_input():
    bookmarks = [
        {"id": i, "url": f"https://x.example/{i}", "domain": "x.example"} for i in range(5)
    ]
    sample = auto_tag._stratified_sample(bookmarks, 30)
    assert len(sample) == 5


# ---------------------------------------------------------------------------
# Response parsing
# ---------------------------------------------------------------------------


def test_parse_tag_response_clean():
    tags = auto_tag._parse_tag_response('["rust-web", "machine-learning", "devops"]')
    assert tags == ["rust-web", "machine-learning", "devops"]


def test_parse_tag_response_markdown_fence():
    raw = '```json\n["a", "b"]\n```'
    assert auto_tag._parse_tag_response(raw) == ["a", "b"]


def test_parse_tag_response_filters_stopwords():
    raw = json.dumps(["imported", "tabs", "useful", "real-tag"])
    assert auto_tag._parse_tag_response(raw) == ["real-tag"]


def test_parse_tag_response_normalizes_spaces():
    raw = json.dumps(["Machine Learning", "  rust  web  "])
    assert auto_tag._parse_tag_response(raw) == ["machine-learning", "rust-web"]


def test_parse_tag_response_handles_garbage():
    assert auto_tag._parse_tag_response("no json here") == []
    assert auto_tag._parse_tag_response("not an array but a string") == []


# ---------------------------------------------------------------------------
# LLM client — mocked httpx
# ---------------------------------------------------------------------------

ANTHROPIC_RESPONSE = {
    "content": [{"type": "text", "text": '["rust-web", "machine-learning", "python"]'}]
}

OPENAI_RESPONSE = {"choices": [{"message": {"content": '["rust-web", "machine-learning"]'}}]}


def _make_mock_transport(responses: list[httpx.Response]) -> httpx.MockTransport:
    """Build a mock transport that returns responses in order."""
    iter_resp = iter(responses)

    def handler(request: httpx.Request) -> httpx.Response:
        try:
            return next(iter_resp)
        except StopIteration:
            return httpx.Response(500, text="no more mock responses")

    return httpx.MockTransport(handler)


@pytest.mark.asyncio
async def test_call_anthropic_parses_response():
    mock = _make_mock_transport(
        [
            httpx.Response(200, json=ANTHROPIC_RESPONSE),
        ]
    )
    async with httpx.AsyncClient(transport=mock) as client:
        text = await auto_tag.call_llm(
            provider="anthropic",
            model="claude-haiku-4-5",
            api_key="sk-test",
            base_url=None,
            prompt="hello",
            client=client,
        )
    assert text == ANTHROPIC_RESPONSE["content"][0]["text"]


@pytest.mark.asyncio
async def test_call_openai_parses_response():
    mock = _make_mock_transport([httpx.Response(200, json=OPENAI_RESPONSE)])
    async with httpx.AsyncClient(transport=mock) as client:
        text = await auto_tag.call_llm(
            provider="openai",
            model="gpt-4o-mini",
            api_key="sk-test",
            base_url=None,
            prompt="hello",
            client=client,
        )
    assert "rust-web" in text


@pytest.mark.asyncio
async def test_call_openai_compatible_uses_base_url():
    mock = _make_mock_transport([httpx.Response(200, json=OPENAI_RESPONSE)])
    async with httpx.AsyncClient(transport=mock) as client:
        text = await auto_tag.call_llm(
            provider="openai-compatible",
            model="llama3",
            api_key="ignored",
            base_url="http://localhost:11434",
            prompt="hello",
            client=client,
        )
    assert "rust-web" in text


@pytest.mark.asyncio
async def test_suggest_tags_end_to_end_with_mock():
    mock = _make_mock_transport(
        [
            httpx.Response(200, json=ANTHROPIC_RESPONSE),
        ]
    )
    async with httpx.AsyncClient(transport=mock) as client:
        bookmarks = [
            {"id": 1, "url": "https://a.example/", "title": "A", "domain": "a.example"},
            {"id": 2, "url": "https://b.example/", "title": "B", "domain": "b.example"},
        ]
        tags = await auto_tag.suggest_tags(
            tag_name="imported",
            bookmarks=bookmarks,
            provider="anthropic",
            model="claude-haiku-4-5",
            api_key="sk-test",
            client=client,
            sample_size=2,
        )
    assert tags == ["rust-web", "machine-learning", "python"]


# ---------------------------------------------------------------------------
# DB tag helpers
# ---------------------------------------------------------------------------


def test_bulk_add_tags_creates_links(fresh_db):
    bids = [db.insert_bookmark(url=f"https://x.example/{i}") for i in range(3)]
    added = db.bulk_add_tags(bids, ["alpha", "beta"])
    assert added == 6  # 3 bookmarks * 2 tags
    for bid in bids:
        assert set(db.get_tags_for_bookmark(bid)) == {"alpha", "beta"}


def test_bulk_add_tags_is_idempotent(fresh_db):
    bid = db.insert_bookmark(url="https://x.example/")
    db.bulk_add_tags([bid], ["alpha"])
    added_again = db.bulk_add_tags([bid], ["alpha"])
    assert added_again == 0
    assert db.get_tags_for_bookmark(bid) == ["alpha"]


def test_remove_tag_from_bookmarks(fresh_db):
    bids = [db.insert_bookmark(url=f"https://x.example/{i}") for i in range(3)]
    db.bulk_add_tags(bids, ["alpha", "beta"])
    removed = db.remove_tag_from_bookmarks(bids, "alpha")
    assert removed == 3
    for bid in bids:
        assert db.get_tags_for_bookmark(bid) == ["beta"]


def test_bookmarks_with_tag(fresh_db):
    db.insert_bookmark(url="https://a.example/", tags=["x"])
    db.insert_bookmark(url="https://b.example/", tags=["x", "y"])
    db.insert_bookmark(url="https://c.example/", tags=["z"])
    urls = {b["url"] for b in db.bookmarks_with_tag("x")}
    assert urls == {"https://a.example/", "https://b.example/"}


def test_generic_tag_candidates(fresh_db):
    db.insert_bookmark(url="https://a/", tags=["popular"])
    db.insert_bookmark(url="https://b/", tags=["popular"])
    db.insert_bookmark(url="https://c/", tags=["popular"])
    db.insert_bookmark(url="https://d/", tags=["rare"])
    candidates = {t["name"]: t["n"] for t in db.generic_tag_candidates(min_count=2)}
    assert candidates == {"popular": 3}
