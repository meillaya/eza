"""Automatic semantic re-tagging for large generic buckets.

The browser importer produces large flat tags like "imported", "tabs",
"archive", "imported sessions" — each holds thousands of bookmarks that
are otherwise unintelligible to browse. This module:

  1. Picks the largest tags (or a user-specified list).
  2. Samples a diverse set of bookmarks from each (stratified by domain).
  3. Asks an LLM to suggest 5-10 specific topic tags for the cluster.
  4. Applies those tags to every bookmark in the bucket.
  5. Optionally removes the original generic tag.

Providers:
  - "anthropic" — Anthropic Messages API (Claude)
  - "openai"    — OpenAI Chat Completions API
  - "openai-compatible" — any OpenAI-shaped endpoint (Ollama, vLLM, etc.)

Set the API key in the env var named by --api-key-env (defaults:
ANTHROPIC_API_KEY for anthropic, OPENAI_API_KEY for openai*).
"""

# allow: SIZE_OK — pre-existing CLI module (>250 LOC before todo 28); the
# todo-28 commit contract modifies this file in place (prompt vocabulary +
# per-bookmark suggestions), so the module grows rather than splitting.

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import random
import sys
import time
from collections.abc import Iterable
from urllib.parse import urlparse

import httpx

from . import db

log = logging.getLogger("bookmarks.auto_tag")

# Well-known tags we never want to surface or propose.
_DEFAULT_STOPWORDS = frozenset(
    {
        "imported",
        "tabs",
        "archive",
        "imported sessions",
        "bookmarks",
        "bookmarks bar",
        "other bookmarks",
        "mobile bookmarks",
        "favorites",
        "links",
        "misc",
        "saved",
        "stuff",
        "temp",
        "new folder",
        "useful",
        "important",
        "interesting",
        "various",
        "general",
    }
)

# Default model per provider. Override with --model.
DEFAULT_MODELS = {
    "anthropic": "claude-haiku-4-5",
    "openai": "gpt-4o-mini",
    "openai-compatible": "gpt-4o-mini",
}

# Taxonomy constraint (todo 28): the LLM's suggestions are drawn from a
# vocabulary of the user's top-K EXISTING tags instead of free-invented names
# (karakeep #1266 tag explosion; linkding PR #1232 vocabulary constraint;
# BERTopic seed_topic_list). 150 sits in the documented ~50-200 band: large
# enough to cover the corpus, small enough to stay inside the prompt budget.
DEFAULT_VOCAB_SIZE = 150


def build_tag_vocab(
    tags: Iterable[dict | str],
    *,
    stopwords: frozenset[str] = _DEFAULT_STOPWORDS,
    max_tags: int = DEFAULT_VOCAB_SIZE,
) -> list[str]:
    """The top-K most-used existing tags (stopwords excluded) — the vocabulary
    an LLM must draw its suggestions from.

    Input is either ``db.all_tags()`` rows (``{name, n}``) or plain tag names
    (count 0, alphabetical order). Entries are the canonical EXISTING names
    (lowercase, whitespace collapsed) so applying a suggestion never invents a
    spelling. K is ``max_tags`` — the prompt should never grow unbounded with
    the corpus.
    """
    by_name: dict[str, int] = {}
    for item in tags:
        if isinstance(item, dict):
            name = str(item.get("name", "")).strip().lower()
            count = int(item.get("n") or 0)
        else:
            name = str(item).strip().lower()
            count = 0
        if not name or name in stopwords:
            continue
        by_name[name] = max(by_name.get(name, 0), count)
    ranked = sorted(by_name.items(), key=lambda kv: (-kv[1], kv[0]))
    return [name for name, _ in ranked[:max_tags]]


# ---------------------------------------------------------------------------
# Sampling
# ---------------------------------------------------------------------------


def _stratified_sample(bookmarks: list[dict], k: int) -> list[dict]:
    """Pick up to `k` bookmarks, spreading picks across distinct domains.

    If a domain has many bookmarks, it gets at most ceil(k / distinct_domains)
    picks, ensuring diversity in what the LLM sees.
    """
    if len(bookmarks) <= k:
        return list(bookmarks)

    by_domain: dict[str, list[dict]] = {}
    for b in bookmarks:
        by_domain.setdefault(b.get("domain") or urlparse(b["url"]).netloc, []).append(b)

    domains = list(by_domain)
    random.shuffle(domains)
    per_domain = max(1, k // max(1, len(domains)))

    sample: list[dict] = []
    for d in domains:
        random.shuffle(by_domain[d])
        sample.extend(by_domain[d][:per_domain])
        if len(sample) >= k:
            break
    # Top up if we under-shot the budget
    if len(sample) < k:
        remaining = [b for b in bookmarks if b not in sample]
        random.shuffle(remaining)
        sample.extend(remaining[: k - len(sample)])
    return sample[:k]


# ---------------------------------------------------------------------------
# LLM client
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = """\
You are a librarian tagging clusters of web bookmarks. You will be shown a
sample of bookmarks that all currently share one generic tag like "imported"
or "tabs". Your job is to suggest 5-10 specific, useful topic tags that
would help the user find and browse these bookmarks later.

Strict rules:
- Output ONLY a JSON array of strings (e.g. ["rust-web", "machine-learning-papers"]).
- Tags must be lowercase. Multi-word tags use hyphens (e.g. "deep-learning").
- NEVER repeat the original generic tag name.
- Prefer specific topics over generic ones ("rust-web" beats "tech", "machine-learning-papers" beats "programming").
- Avoid stopwords like "imported", "tabs", "archive", "bookmarks", "favorites", "links", "misc", "saved".
- Each tag should be reusable: at least 5 of the bookmarks in the cluster would plausibly carry it.
- Aim for 5-10 tags total.
- DRAW EVERY SUGGESTION FROM THE PROVIDED EXISTING-TAG VOCABULARY: each tag MUST
  appear verbatim in the vocabulary list you are given. NEVER invent or spell
  differently a tag that is not in the vocabulary.
"""


def _format_user_message(
    tag_name: str,
    sample: list[dict],
    stopwords: frozenset[str],
    vocab: Iterable[str] | None = None,
) -> str:
    rows = []
    for i, b in enumerate(sample, start=1):
        title = (b.get("title") or "").strip().replace("\n", " ")[:120]
        url = b["url"]
        domain = b.get("domain") or urlparse(url).netloc
        rows.append(f"{i}. Title: {title}\n   URL: {url}\n   Domain: {domain}")
    msg = (
        f"Generic tag to replace: {tag_name!r}\n\n"
        f"Sample of {len(sample)} bookmarks in this cluster:\n\n"
        + "\n".join(rows)
        + "\n\nSuggest the topic tags now as a JSON array."
    )
    return _append_vocab(msg, vocab)


def _format_bookmark_message(bookmark: dict, vocab: Iterable[str] | None = None) -> str:
    """Single-bookmark suggestion prompt (todo 28): the review surface asks for
    per-bookmark candidates, so the LLM sees one bookmark at a time."""
    title = (bookmark.get("title") or "").strip().replace("\n", " ")[:120]
    url = bookmark["url"]
    domain = bookmark.get("domain") or urlparse(url).netloc
    msg = (
        "Suggest 3-6 specific topic tags for this single web bookmark.\n\n"
        f"Title: {title}\nURL: {url}\nDomain: {domain}\n\n"
        "Output ONLY a JSON array of strings."
    )
    return _append_vocab(msg, vocab)


def _append_vocab(msg: str, vocab: Iterable[str] | None) -> str:
    """Append the existing-tag vocabulary + constraint to a prompt when given."""
    if vocab is None:
        return msg
    vocab_list = sorted(set(vocab))
    if not vocab_list:
        return msg
    return (
        f"{msg}\n\nExisting tag vocabulary ({len(vocab_list)} tags) — every "
        "suggestion MUST be drawn from this list, verbatim:\n"
        + ", ".join(vocab_list)
    )


def _parse_tag_response(
    text: str, *, vocab: Iterable[str] | None = None
) -> list[str]:
    """Robustly extract a JSON array of strings from LLM output.

    When ``vocab`` (the existing-tag allowlist) is given, every returned tag
    must match an in-vocabulary name (compared on the hyphen-normalized form);
    out-of-vocabulary output is rejected, and matches are mapped back to the
    canonical EXISTING tag name so applying a suggestion never invents a
    spelling. Stopwords are always rejected, vocabulary or not.
    """
    text = text.strip()
    # Strip markdown fences if present
    if text.startswith("```"):
        # find first newline after opening fence
        nl = text.find("\n")
        if nl > 0:
            text = text[nl + 1 :]
        if text.endswith("```"):
            text = text[:-3]
        text = text.strip()
    # Find the first JSON array in the text
    start = text.find("[")
    end = text.rfind("]")
    if start == -1 or end == -1 or end <= start:
        log.warning("could not find JSON array in response: %r", text[:200])
        return []
    candidate = text[start : end + 1]
    try:
        parsed = json.loads(candidate)
    except json.JSONDecodeError as exc:
        log.warning("JSON parse failed: %s; raw=%r", exc, candidate[:200])
        return []
    if not isinstance(parsed, list):
        return []
    canonical: dict[str, str] | None = None
    if vocab is not None:
        canonical = {}
        for name in vocab:
            key = "-".join(name.strip().lower().split())
            if key:
                canonical.setdefault(key, name.strip().lower())
    out: list[str] = []
    for item in parsed:
        if not isinstance(item, str):
            continue
        normalized = item.strip().lower()
        if not normalized or normalized in _DEFAULT_STOPWORDS:
            continue
        # Collapse whitespace to hyphens for multi-word tags
        normalized = "-".join(normalized.split())
        if canonical is not None:
            mapped = canonical.get(normalized)
            if mapped is None:
                log.info("rejected out-of-vocabulary tag %r", normalized)
                continue
            normalized = mapped
        out.append(normalized)
    return out


async def call_llm(
    *,
    provider: str,
    model: str,
    api_key: str,
    base_url: str | None,
    prompt: str,
    max_tokens: int = 256,
    request_timeout: float = 60.0,
    client: httpx.AsyncClient | None = None,
) -> str:
    """Dispatch to the right provider and return the assistant text."""
    if provider == "anthropic":
        return await _call_anthropic(
            model=model,
            api_key=api_key,
            prompt=prompt,
            max_tokens=max_tokens,
            request_timeout=request_timeout,
            client=client,
        )
    if provider in {"openai", "openai-compatible"}:
        return await _call_openai(
            base_url=base_url,
            model=model,
            api_key=api_key,
            prompt=prompt,
            max_tokens=max_tokens,
            request_timeout=request_timeout,
            client=client,
        )
    raise ValueError(f"unknown provider: {provider!r}")


async def _call_anthropic(
    *,
    model: str,
    api_key: str,
    prompt: str,
    max_tokens: int,
    request_timeout: float,
    client: httpx.AsyncClient | None,
) -> str:
    own = client is None
    c = client or httpx.AsyncClient(timeout=request_timeout)
    try:
        resp = await c.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": api_key,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            json={
                "model": model,
                "max_tokens": max_tokens,
                "system": SYSTEM_PROMPT,
                "messages": [{"role": "user", "content": prompt}],
            },
        )
        resp.raise_for_status()
        data = resp.json()
        return "".join(
            block.get("text", "")
            for block in data.get("content", [])
            if block.get("type") == "text"
        )
    finally:
        if own:
            await c.aclose()


async def _call_openai(
    *,
    base_url: str | None,
    model: str,
    api_key: str,
    prompt: str,
    max_tokens: int,
    request_timeout: float,
    client: httpx.AsyncClient | None,
) -> str:
    base = (base_url or "https://api.openai.com").rstrip("/")
    own = client is None
    c = client or httpx.AsyncClient(timeout=request_timeout)
    try:
        resp = await c.post(
            f"{base}/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {api_key}",
                "content-type": "application/json",
            },
            json={
                "model": model,
                "max_tokens": max_tokens,
                "messages": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": prompt},
                ],
            },
        )
        resp.raise_for_status()
        data = resp.json()
        return data["choices"][0]["message"]["content"]
    finally:
        if own:
            await c.aclose()


async def suggest_tags(
    *,
    tag_name: str,
    bookmarks: list[dict],
    provider: str,
    model: str,
    api_key: str,
    base_url: str | None = None,
    sample_size: int = 30,
    stopwords: frozenset[str] = _DEFAULT_STOPWORDS,
    vocab: Iterable[str] | None = None,
    request_timeout: float = 60.0,
    client: httpx.AsyncClient | None = None,
) -> list[str]:
    """Sample the cluster and ask the LLM for tag suggestions.

    ``vocab`` (the existing-tag vocabulary from :func:`build_tag_vocab`)
    constrains both the prompt and the parsed result: the LLM is told to draw
    every suggestion from it and ``_parse_tag_response`` rejects anything that
    is not in it.
    """
    sample = _stratified_sample(bookmarks, sample_size)
    if not sample:
        return []
    user_msg = _format_user_message(tag_name, sample, stopwords, vocab=vocab)
    text = await call_llm(
        provider=provider,
        model=model,
        api_key=api_key,
        base_url=base_url,
        prompt=user_msg,
        request_timeout=request_timeout,
        client=client,
    )
    return _parse_tag_response(text, vocab=vocab)


async def suggest_bookmark_tags(
    *,
    bookmarks: list[dict],
    provider: str,
    model: str,
    api_key: str,
    base_url: str | None = None,
    stopwords: frozenset[str] = _DEFAULT_STOPWORDS,
    vocab: Iterable[str] | None = None,
    request_timeout: float = 60.0,
    client: httpx.AsyncClient | None = None,
) -> list[dict]:
    """Per-bookmark candidate tags (todo 28): one LLM call per bookmark in the
    given sample, each prompt constrained to ``vocab``.

    Returns ``[{bookmark_id, title, url, candidate_tags}]`` where
    ``candidate_tags`` is the allowlisted output — a bookmark whose LLM call
    failed or invented out-of-vocabulary tags simply yields an empty list (the
    UI shows nothing to apply for it). The caller owns sampling (the review
    route reuses ``_stratified_sample``); this function takes the sample
    verbatim.
    """
    results: list[dict] = []
    for b in bookmarks:
        user_msg = _format_bookmark_message(b, vocab)
        try:
            text = await call_llm(
                provider=provider,
                model=model,
                api_key=api_key,
                base_url=base_url,
                prompt=user_msg,
                request_timeout=request_timeout,
                client=client,
            )
        except (httpx.HTTPError, KeyError, ValueError) as exc:
            log.warning("LLM call failed for bookmark %s: %s", b.get("id"), exc)
            results.append(
                {
                    "bookmark_id": b["id"],
                    "title": (b.get("title") or "").strip(),
                    "url": b["url"],
                    "candidate_tags": [],
                }
            )
            continue
        results.append(
            {
                "bookmark_id": b["id"],
                "title": (b.get("title") or "").strip(),
                "url": b["url"],
                "candidate_tags": _parse_tag_response(text, vocab=vocab),
            }
        )
    return results


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------


def _resolve_api_key(provider: str, env_var: str | None) -> str:
    var = env_var
    if not var:
        var = "ANTHROPIC_API_KEY" if provider == "anthropic" else "OPENAI_API_KEY"
    key = os.environ.get(var, "")
    if not key:
        raise SystemExit(f"missing API key: set {var} in your environment or pass --api-key-env")
    return key


def _retag_one(
    *,
    tag_name: str,
    new_tags: list[str],
    bookmarks: list[dict],
    remove_generic: bool,
    dry_run: bool,
) -> dict:
    bookmark_ids = [b["id"] for b in bookmarks]
    result = {
        "tag": tag_name,
        "bookmarks_in_bucket": len(bookmarks),
        "added_tags": new_tags,
        "links_added": 0,
        "tag_removed": False,
        "dry_run": dry_run,
    }
    if dry_run:
        return result
    added = db.bulk_add_tags(bookmark_ids, new_tags)
    result["links_added"] = added
    if remove_generic:
        removed = db.remove_tag_from_bookmarks(bookmark_ids, tag_name)
        result["tag_removed"] = removed > 0
        result["links_removed"] = removed
    return result


async def auto_tag_buckets(
    *,
    targets: Iterable[str],
    min_count: int,
    provider: str,
    model: str,
    api_key: str,
    base_url: str | None,
    sample_size: int,
    remove_generic: bool,
    dry_run: bool,
    max_buckets: int | None,
) -> list[dict]:
    """Resolve which tags to retag, call the LLM per bucket, apply results."""
    target_list = [t.strip() for t in targets if t.strip()] if targets else []
    if target_list:
        buckets = [{"name": t, "n": -1} for t in target_list]
    else:
        buckets = db.generic_tag_candidates(min_count=min_count)
        if max_buckets is not None:
            buckets = buckets[:max_buckets]

    if not buckets:
        log.info("no buckets matched criteria (min_count=%d)", min_count)
        return []

    log.info("retagging %d bucket(s) with provider=%s model=%s", len(buckets), provider, model)
    results: list[dict] = []
    for b in buckets:
        tag_name = str(b["name"])
        log.info("--- bucket: %r (%s bookmark(s)) ---", tag_name, b.get("n", "?"))
        bookmarks = db.bookmarks_with_tag(tag_name)
        if not bookmarks:
            log.info("  empty bucket, skipping")
            continue
        # Taxonomy constraint (todo 28): the LLM draws every suggestion from
        # the user's existing top-K tags — never free-invented names. The
        # bucket's own generic tag is excluded so it can't be re-suggested.
        vocab = [
            t
            for t in build_tag_vocab(db.all_tags())
            if t != tag_name
        ]
        try:
            new_tags = await suggest_tags(
                tag_name=tag_name,
                bookmarks=bookmarks,
                provider=provider,
                model=model,
                api_key=api_key,
                base_url=base_url,
                sample_size=sample_size,
                vocab=vocab,
            )
        except (httpx.HTTPError, KeyError, ValueError) as exc:
            log.error("LLM call failed for %r: %s", tag_name, exc)
            results.append({"tag": tag_name, "error": str(exc)})
            continue

        if not new_tags:
            log.warning("  no tags suggested by LLM; skipping")
            results.append({"tag": tag_name, "added_tags": []})
            continue

        log.info("  suggested: %s", new_tags)
        result = _retag_one(
            tag_name=tag_name,
            new_tags=new_tags,
            bookmarks=bookmarks,
            remove_generic=remove_generic,
            dry_run=dry_run,
        )
        results.append(result)
    return results


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Re-tag large generic buckets using an LLM.",
    )
    g = parser.add_mutually_exclusive_group()
    g.add_argument(
        "--target",
        action="append",
        default=[],
        help="Specific tag name to retag. Repeatable. Default: auto-pick any tag "
        "with at least --threshold bookmarks.",
    )
    g.add_argument(
        "--all-above",
        type=int,
        metavar="N",
        help="Retag every tag applied to ≥ N bookmarks.",
    )
    parser.add_argument(
        "--threshold",
        type=int,
        default=500,
        help="Minimum bookmark count to consider a tag as a generic bucket "
        "(only used when --target is not given).",
    )
    parser.add_argument(
        "--max-buckets",
        type=int,
        default=None,
        help="Process at most N buckets (largest first).",
    )
    parser.add_argument(
        "--provider",
        choices=["anthropic", "openai", "openai-compatible"],
        default="anthropic",
    )
    parser.add_argument("--model", default=None, help=f"Default: {DEFAULT_MODELS}")
    parser.add_argument(
        "--api-key-env",
        default=None,
        help="Env var holding the API key. Default: ANTHROPIC_API_KEY for "
        "anthropic, OPENAI_API_KEY for openai*.",
    )
    parser.add_argument(
        "--base-url",
        default=None,
        help="Base URL for openai-compatible provider (Ollama, vLLM, etc.).",
    )
    parser.add_argument("--sample-size", type=int, default=30)
    parser.add_argument(
        "--remove-generic",
        action="store_true",
        help="Remove the original generic tag after applying new tags.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Don't write anything to the DB; just show what would happen.",
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    return parser.parse_args(list(argv))


def main(argv: Iterable[str] | None = None) -> int:
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    api_key = _resolve_api_key(args.provider, args.api_key_env)
    model = args.model or DEFAULT_MODELS[args.provider]

    targets = args.target or []
    if not targets and args.all_above is None:
        # No explicit targets and no --all-above: fall back to --threshold.
        bucket_min = args.threshold
    elif args.all_above is not None:
        bucket_min = args.all_above
    else:
        bucket_min = 0  # explicit targets always run regardless of count

    started = time.monotonic()
    results = asyncio.run(
        auto_tag_buckets(
            targets=targets,
            min_count=bucket_min,
            provider=args.provider,
            model=model,
            api_key=api_key,
            base_url=args.base_url,
            sample_size=args.sample_size,
            remove_generic=args.remove_generic,
            dry_run=args.dry_run,
            max_buckets=args.max_buckets,
        )
    )
    elapsed = time.monotonic() - started

    log.info("--- summary ---")
    for r in results:
        log.info("%s", json.dumps(r, ensure_ascii=False))
    log.info("done in %.1fs", elapsed)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
