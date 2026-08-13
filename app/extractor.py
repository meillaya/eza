"""Article content extraction — trafilatura, parse-only.

This module NEVER touches the network. Callers (the background enrichment
task in :mod:`app.fetcher` and the backfill CLI in :mod:`app.backfill_extract`)
fetch the page HTML and hand it to :func:`extract_from_html`, which runs
trafilatura's extraction ladder:

1. ``bare_extraction`` with default settings (+ metadata)
2. ``bare_extraction(..., fast=False, favor_recall=True)`` — slower, recall-first
3. ``baseline`` / ``html2txt`` — plain-text fallback (metadata unavailable)

The ladder is gated by ``is_probably_readerable``: pages that do not look like
articles (JS shells, nav-heavy listings) return empty fields instead of
storing nav-garbage as extracted text.
"""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Any

from trafilatura import bare_extraction, baseline, html2txt, load_html
from trafilatura.readability_lxml import is_probably_readerable

log = logging.getLogger("bookmarks.extractor")

_EMPTY: dict[str, Any] = {
    "title": "",
    "author": "",
    "sitename": "",
    "date": None,
    "language": "",
    "image": "",
    "text": "",
}

# Fallback formats for dates trafilatura leaves in non-ISO shapes.
_DATE_FORMATS = ("%d %B %Y", "%B %d, %Y", "%Y-%m-%d %H:%M:%S")


def _parse_date(value: str | None) -> int | None:
    """Parse a trafilatura date string into a unix epoch, or None."""
    if not value:
        return None
    text = value.strip()
    if not text:
        return None
    try:
        return int(datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp())
    except ValueError:
        pass
    for fmt in _DATE_FORMATS:
        try:
            return int(datetime.strptime(text, fmt).timestamp())
        except ValueError:
            continue
    return None


def _document_to_dict(doc: Any) -> dict[str, Any]:
    """Convert a trafilatura Document into the extraction dict shape."""
    return {
        "title": (doc.title or "").strip(),
        "author": (doc.author or "").strip(),
        "sitename": (doc.sitename or "").strip(),
        "date": _parse_date(doc.date),
        "language": (doc.language or "").strip(),
        "image": (doc.image or "").strip(),
        "text": (doc.text or "").strip(),
    }


def _bare(html: str, **kwargs: Any) -> Any | None:
    """``bare_extraction`` that never raises; None when extraction fails."""
    try:
        return bare_extraction(html, with_metadata=True, **kwargs)
    except Exception:
        log.debug("bare_extraction failed", exc_info=True)
        return None


def _fallback_text(html: str) -> str:
    """baseline() then html2txt() as the last rung of the ladder."""
    try:
        _, text, _ = baseline(html)
        if text and text.strip():
            return text.strip()
    except Exception:
        pass
    try:
        return html2txt(html).strip()
    except Exception:
        return ""


def extract_from_html(html: str) -> dict[str, Any]:
    """Extract article metadata + text from a single HTML document.

    Returns ``{title, author, sitename, date, language, image, text}`` where
    ``date`` is a unix epoch (int) or None and every other field is a stripped
    string (``''`` when unknown). Gated by readability: non-article pages
    return empty fields. Pure parsing — never performs network I/O.
    """
    tree = load_html(html)
    if tree is None or not is_probably_readerable(tree):
        return dict(_EMPTY)

    doc = _bare(html)
    if doc is None or not (doc.text or "").strip():
        doc = _bare(html, fast=False, favor_recall=True)
    if doc is None or not (doc.text or "").strip():
        return {**_EMPTY, "text": _fallback_text(html)}
    return _document_to_dict(doc)
