"""Taxonomy-constrained AI tagging (todo 28).

Contract under test:

- ``build_tag_vocab`` — the top-K most-used existing tags (stopwords excluded)
  that the LLM is allowed to suggest from. Input is either ``db.all_tags()``
  rows ({name, n}) or plain tag names.
- Prompt — ``_format_user_message`` / ``_format_bookmark_message`` embed the
  existing-tag vocabulary and require suggestions be drawn from it; the
  mocked-LLM test captures the request body and asserts the vocabulary is in
  the prompt.
- ``_parse_tag_response`` — extended with a vocab allowlist: output outside
  the vocabulary is rejected/filtered; an in-vocab match is mapped to the
  canonical existing tag name (never an invented spelling); stopwords are
  rejected even when present in the vocab.
- ``suggest_bookmark_tags`` — per-bookmark candidate tags, allowlisted.
- API — ``GET /api/tags/{tag}/suggestions`` (per-bookmark candidates via the
  existing stratified sampling, authed, no exemption) and
  ``POST /api/tags/apply {bookmark_ids, tags}`` (bulk_add_tags, authed +
  CSRF). Applied tags are never stopwords.
"""

from __future__ import annotations

import json
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from app import auto_tag, db
from app.main import app


def _authed_client() -> TestClient:
    """A TestClient preloaded with a normal-scope session + csrf cookies."""
    from app import auth

    sid = auth.create_session(scope="normal")
    csrf = db.get_conn().execute(
        "SELECT csrf_token FROM sessions WHERE id = ?", (sid,)
    ).fetchone()["csrf_token"]
    client = TestClient(app)
    client.cookies.set(auth.SESSION_COOKIE_NAME, sid)
    client.cookies.set("csrf_token", csrf)
    return client


def _seed(fresh_db) -> list[int]:
    """Two bookmarks on a generic "imported" bucket carrying vocab tags."""
    a = db.insert_bookmark(
        url="https://a.example/", title="Rust blog A", tags=["imported", "rust-web"]
    )
    b = db.insert_bookmark(
        url="https://b.example/", title="Python notes B", tags=["imported", "python"]
    )
    return [a, b]


# ---------------------------------------------------------------------------
# build_tag_vocab
# ---------------------------------------------------------------------------


def test_build_tag_vocab_most_used_first(fresh_db):
    db.insert_bookmark(url="https://a/", tags=["rust"])
    db.insert_bookmark(url="https://b/", tags=["rust"])
    db.insert_bookmark(url="https://c/", tags=["rust"])
    db.insert_bookmark(url="https://d/", tags=["python"])
    vocab = auto_tag.build_tag_vocab(db.all_tags())
    assert vocab[0] == "rust"
    assert "rust" in vocab and "python" in vocab


def test_build_tag_vocab_excludes_stopwords():
    rows = [
        {"name": "imported", "n": 100},
        {"name": "tabs", "n": 90},
        {"name": "rust", "n": 10},
        {"name": "python", "n": 5},
    ]
    vocab = auto_tag.build_tag_vocab(rows)
    assert "imported" not in vocab
    assert "tabs" not in vocab
    assert vocab == ["rust", "python"]


def test_build_tag_vocab_caps_at_max_tags():
    rows = [{"name": f"t{i}", "n": i} for i in range(30)]
    vocab = auto_tag.build_tag_vocab(rows, max_tags=5)
    assert len(vocab) == 5
    assert vocab[0] == "t29"  # most-used first


def test_build_tag_vocab_accepts_plain_names():
    vocab = auto_tag.build_tag_vocab(["Rust", "  Python ", "imported"])
    assert vocab == ["python", "rust"]  # count 0 ties sort alphabetically


# ---------------------------------------------------------------------------
# Prompt — vocabulary must be embedded and required
# ---------------------------------------------------------------------------


def _bm(bookmark_id: int) -> dict:
    return {
        "id": bookmark_id,
        "title": "Title",
        "url": f"https://x.example/{bookmark_id}",
        "domain": "x.example",
    }


def test_format_user_message_includes_vocabulary():
    msg = auto_tag._format_user_message(
        "imported",
        [_bm(1)],
        auto_tag._DEFAULT_STOPWORDS,
        vocab=["rust-web", "python"],
    )
    assert "rust-web" in msg
    assert "python" in msg
    assert "vocabulary" in msg.lower()


def test_format_bookmark_message_includes_vocabulary():
    msg = auto_tag._format_bookmark_message(_bm(1), vocab=["rust-web"])
    assert "rust-web" in msg
    assert "vocabulary" in msg.lower()


@pytest.mark.asyncio
async def test_suggest_tags_sends_vocab_in_prompt():
    captured: dict[str, Any] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["body"] = json.loads(request.content)
        return httpx.Response(
            200,
            json={"content": [{"type": "text", "text": '["rust-web"]'}]},
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        tags = await auto_tag.suggest_tags(
            tag_name="imported",
            bookmarks=[_bm(1)],
            provider="anthropic",
            model="claude-haiku-4-5",
            api_key="sk-test",
            client=client,
            sample_size=1,
            vocab=["rust-web", "python"],
        )
    assert tags == ["rust-web"]
    user_msg = captured["body"]["messages"][0]["content"]
    assert "rust-web" in user_msg
    assert "python" in user_msg


# ---------------------------------------------------------------------------
# _parse_tag_response — vocab allowlist
# ---------------------------------------------------------------------------


def test_parse_tag_response_allowlist_happy():
    tags = auto_tag._parse_tag_response(
        '["rust-web", "machine-learning"]',
        vocab=["rust-web", "machine-learning", "python"],
    )
    assert tags == ["rust-web", "machine-learning"]


def test_parse_tag_response_rejects_out_of_vocab():
    tags = auto_tag._parse_tag_response(
        '["rust-web", "invented-tag"]', vocab=["rust-web", "python"]
    )
    assert tags == ["rust-web"]


def test_parse_tag_response_vocab_maps_to_canonical_name():
    # The existing tag is "deep learning"; the LLM hyphenates it. The allowlist
    # returns the CANONICAL existing name so applying never invents "deep-learning".
    tags = auto_tag._parse_tag_response(
        '["deep-learning"]', vocab=["deep learning", "rust"]
    )
    assert tags == ["deep learning"]


def test_parse_tag_response_stopwords_rejected_even_in_vocab():
    tags = auto_tag._parse_tag_response('["imported", "rust"]', vocab=["imported", "rust"])
    assert tags == ["rust"]


def test_parse_tag_response_no_vocab_keeps_old_behavior():
    tags = auto_tag._parse_tag_response('["rust-web", "imported"]')
    assert tags == ["rust-web"]  # out-of-vocab allowed, stopwords still filtered


# ---------------------------------------------------------------------------
# suggest_bookmark_tags — per-bookmark candidate tags
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_suggest_bookmark_tags_filters_out_of_vocab(monkeypatch):
    async def fake_call_llm(**kwargs) -> str:
        return '["rust-web", "invented"]'

    monkeypatch.setattr(auto_tag, "call_llm", fake_call_llm)
    results = await auto_tag.suggest_bookmark_tags(
        bookmarks=[_bm(1)],
        provider="anthropic",
        model="claude-haiku-4-5",
        api_key="sk-test",
        vocab=["rust-web"],
    )
    assert results == [
        {
            "bookmark_id": 1,
            "title": "Title",
            "url": "https://x.example/1",
            "candidate_tags": ["rust-web"],
        }
    ]


# ---------------------------------------------------------------------------
# API — suggestions + apply
# ---------------------------------------------------------------------------


def test_suggestions_requires_auth(fresh_db):
    _seed(fresh_db)
    with TestClient(app) as client:
        resp = client.get("/api/tags/imported/suggestions")
    assert resp.status_code == 401


def test_suggestions_unknown_tag_404(fresh_db, monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    client = _authed_client()
    with client:
        resp = client.get("/api/tags/no-such-tag/suggestions")
    assert resp.status_code == 404


def test_suggestions_no_api_key_400(fresh_db, monkeypatch):
    _seed(fresh_db)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    client = _authed_client()
    with client:
        resp = client.get("/api/tags/imported/suggestions")
    assert resp.status_code == 400


def test_suggestions_flow_with_mocked_llm(fresh_db, monkeypatch):
    _seed(fresh_db)
    captured: dict[str, str] = {}

    async def fake_call_llm(**kwargs) -> str:
        captured["prompt"] = kwargs["prompt"]
        return '["rust-web", "python"]'

    monkeypatch.setattr(auto_tag, "call_llm", fake_call_llm)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    client = _authed_client()
    with client:
        resp = client.get("/api/tags/imported/suggestions?sample_size=5")
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert len(body["suggestions"]) == 2
    for s in body["suggestions"]:
        assert set(s.keys()) == {"bookmark_id", "title", "url", "candidate_tags"}
        assert s["candidate_tags"] == ["rust-web", "python"]
    # The vocabulary is embedded in the prompt the LLM sees.
    assert "rust-web" in captured["prompt"]
    assert "python" in captured["prompt"]
    # QA happy path: approve → apply → tags land on the bookmarks.
    ids = [s["bookmark_id"] for s in body["suggestions"]]
    apply = client.post(
        "/api/tags/apply",
        headers={"X-CSRF-Token": client.cookies.get("csrf_token")},
        json={"bookmark_ids": ids, "tags": ["rust-web", "python"]},
    )
    assert apply.status_code == 200, apply.text
    assert apply.json()["added"] == 2  # one new link per bookmark
    for bid in ids:
        assert {"rust-web", "python"} <= set(db.get_tags_for_bookmark(bid))


def test_suggestions_filter_out_of_vocab(fresh_db, monkeypatch):
    """QA failure path: the mock LLM invents tags — the UI has nothing to apply."""
    _seed(fresh_db)

    async def fake_call_llm(**kwargs) -> str:
        return '["invented-tag", "also-new"]'

    monkeypatch.setattr(auto_tag, "call_llm", fake_call_llm)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    client = _authed_client()
    with client:
        resp = client.get("/api/tags/imported/suggestions?sample_size=5")
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["suggestions"]
    assert all(s["candidate_tags"] == [] for s in body["suggestions"])


def test_apply_requires_auth(fresh_db):
    with TestClient(app) as client:
        resp = client.post("/api/tags/apply", json={"bookmark_ids": [1], "tags": ["x"]})
    assert resp.status_code == 401


def test_apply_missing_csrf_403(fresh_db):
    _seed(fresh_db)
    client = _authed_client()
    with client:
        resp = client.post(
            "/api/tags/apply", json={"bookmark_ids": [1], "tags": ["rust-web"]}
        )
    assert resp.status_code == 403


def test_apply_happy_path(fresh_db):
    _seed(fresh_db)
    client = _authed_client()
    with client:
        resp = client.post(
            "/api/tags/apply",
            headers={"X-CSRF-Token": client.cookies.get("csrf_token")},
            json={"bookmark_ids": [1, 2], "tags": ["rust-web", "python"]},
        )
    assert resp.status_code == 200, resp.text
    assert resp.json() == {"ok": True, "added": 2, "filtered": 0}
    assert "rust-web" in db.get_tags_for_bookmark(1)
    assert "python" in db.get_tags_for_bookmark(2)


def test_apply_filters_stopwords(fresh_db):
    """Applied tags are never stopwords — even when a client sends them."""
    a = db.insert_bookmark(url="https://c.example/", title="C", tags=["rust-web"])
    b = db.insert_bookmark(url="https://d.example/", title="D", tags=["python"])
    client = _authed_client()
    with client:
        resp = client.post(
            "/api/tags/apply",
            headers={"X-CSRF-Token": client.cookies.get("csrf_token")},
            json={"bookmark_ids": [a, b], "tags": ["rust-web", "imported"]},
        )
    assert resp.status_code == 200, resp.text
    assert resp.json() == {"ok": True, "added": 1, "filtered": 1}
    assert "imported" not in db.get_tags_for_bookmark(a)
    assert "rust-web" in db.get_tags_for_bookmark(a)


def test_apply_invalid_body_400(fresh_db):
    client = _authed_client()
    with client:
        for payload in (
            {"bookmark_ids": [1]},
            {"bookmark_ids": ["x"], "tags": ["rust"]},
            {"bookmark_ids": [1], "tags": "rust"},
            {"bookmark_ids": [], "tags": ["rust"]},
            {"bookmark_ids": [1], "tags": []},
        ):
            resp = client.post(
                "/api/tags/apply",
                headers={"X-CSRF-Token": client.cookies.get("csrf_token")},
                json=payload,
            )
            assert resp.status_code == 400, payload


# ---------------------------------------------------------------------------
# UI page
# ---------------------------------------------------------------------------


def test_tags_suggestions_page_requires_auth(fresh_db):
    with TestClient(app) as client:
        resp = client.get("/tags-suggestions")
    assert resp.status_code == 401


def test_tags_suggestions_page_renders(fresh_db):
    client = _authed_client()
    with client:
        resp = client.get("/tags-suggestions")
    assert resp.status_code == 200
    assert "AI tagging" in resp.text
