"""Async title + favicon fetcher.

Runs in the background after a bookmark is inserted so the read path is never
blocked on the network. Failures are swallowed — a bookmark with no title
is still a bookmark.
"""

from __future__ import annotations

import asyncio
import logging
from urllib.parse import urljoin, urlparse

import httpx
from selectolax.parser import HTMLParser

from . import db, extractor

log = logging.getLogger(__name__)

# Single shared client; connection pooling makes repeat fetches cheap.
_client: httpx.AsyncClient | None = None

# Strong references to in-flight background tasks so they aren't garbage-
# collected mid-flight. Tasks self-remove when they complete.
_background_tasks: set[asyncio.Task] = set()


def _get_client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(
            timeout=httpx.Timeout(connect=3.0, read=5.0, write=3.0, pool=3.0),
            follow_redirects=True,
            headers={"User-Agent": "bookmarks/0.1 (+https://github.com/local/bookmarks)"},
            http2=False,
        )
    return _client


async def fetch_metadata(url: str) -> dict:
    """Fetch title, description, favicon for a URL. Returns empty fields on failure."""
    empty = {"title": "", "description": "", "favicon_url": "", "domain": urlparse(url).netloc}
    try:
        client = _get_client()
        resp = await client.get(url)
        resp.raise_for_status()
    except (TimeoutError, httpx.HTTPError) as exc:
        log.debug("metadata fetch failed for %s: %s", url, exc)
        return empty

    content_type = resp.headers.get("content-type", "")
    if "html" not in content_type.lower():
        return {**empty, "domain": urlparse(url).netloc}

    html = HTMLParser(resp.text)
    title = ""
    title_node = html.css_first("title")
    if title_node is not None:
        title = (title_node.text() or "").strip()

    description = ""
    meta_desc = html.css_first('meta[name="description"]')
    if meta_desc is not None:
        content = meta_desc.attributes.get("content")
        if content:
            description = content.strip()
    if not description:
        og_desc = html.css_first('meta[property="og:description"]')
        if og_desc is not None:
            content = og_desc.attributes.get("content")
            if content:
                description = content.strip()

    # Favicon: <link rel="icon"> → /favicon.ico as fallback
    favicon_url = ""
    for rel in ("icon", "shortcut icon", "apple-touch-icon"):
        link = html.css_first(f'link[rel="{rel}"]')
        if link and link.attributes.get("href"):
            favicon_url = urljoin(str(resp.url), link.attributes["href"])
            break
    if not favicon_url:
        favicon_url = urljoin(str(resp.url), "/favicon.ico")

    return {
        "title": title,
        "description": description,
        "favicon_url": favicon_url,
        "domain": urlparse(str(resp.url)).netloc,
    }


async def enrich(bookmark_id: int, url: str) -> None:
    """Fetch metadata and update the row. Runs as a background task."""
    try:
        meta = await fetch_metadata(url)
        db.update_metadata(
            bookmark_id,
            title=meta["title"],
            description=meta["description"],
            favicon_url=meta["favicon_url"],
            domain=meta["domain"],
        )
    except Exception:
        log.exception("enrich failed for bookmark %s", bookmark_id)


def schedule_enrich(bookmark_id: int, url: str) -> None:
    """Fire-and-forget: kick off enrichment without blocking the response."""
    task = asyncio.create_task(enrich(bookmark_id, url))
    _background_tasks.add(task)
    task.add_done_callback(_background_tasks.discard)


async def fetch_html(client: httpx.AsyncClient, url: str) -> str | None:
    """Fetch a URL and return its HTML text; None on error or non-HTML body.

    Shared by the background extraction task and the backfill CLI so both use
    identical client semantics.
    """
    try:
        resp = await client.get(url)
        resp.raise_for_status()
    except (TimeoutError, httpx.HTTPError) as exc:
        log.debug("html fetch failed for %s: %s", url, exc)
        return None
    if "html" not in resp.headers.get("content-type", "").lower():
        return None
    return resp.text


async def extract(bookmark_id: int, url: str) -> None:
    """Fetch a page's HTML and store the extracted article fields.

    Runs as a fire-and-forget background task AFTER the bookmark is saved so
    the save response is never blocked. The fetch hits the network; the
    parsing itself (extract_from_html) is network-free.
    """
    try:
        html = await fetch_html(_get_client(), url)
        if html is None:
            return
        meta = extractor.extract_from_html(html)
        db.update_metadata(
            bookmark_id,
            author=meta["author"],
            sitename=meta["sitename"],
            published_at=meta["date"],
            language=meta["language"],
            image_url=meta["image"],
            extracted_text=meta["text"],
        )
    except Exception:
        log.exception("extraction failed for bookmark %s", bookmark_id)


def schedule_extract(bookmark_id: int, url: str) -> None:
    """Fire-and-forget: extract article content without blocking the response."""
    task = asyncio.create_task(extract(bookmark_id, url))
    _background_tasks.add(task)
    task.add_done_callback(_background_tasks.discard)


async def extract_for_url(url: str) -> None:
    """Resolve a URL to its bookmark row, then extract. Used by the importer."""
    row = db.get_conn().execute(
        "SELECT id FROM bookmarks WHERE url = ?", (url,)
    ).fetchone()
    if row is None:
        return
    await extract(int(row["id"]), url)


def schedule_extract_for_url(url: str) -> None:
    """Fire-and-forget extraction for a URL (importer path: no id yet)."""
    task = asyncio.create_task(extract_for_url(url))
    _background_tasks.add(task)
    task.add_done_callback(_background_tasks.discard)


async def aclose() -> None:
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None
