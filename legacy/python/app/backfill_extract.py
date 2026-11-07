"""CLI: extract article content for existing bookmarks (resumable backfill).

Rows saved before todo 16 have no stored HTML, so this CLI re-fetches each
page itself (same httpx client semantics as :mod:`app.fetcher`) and runs the
parse-only extractor on the result. The parse step never touches the network —
only the fetch step does.

Resumability: a marker file next to the database (``<db>.extract-marker``)
records the last bookmark id processed; each run continues after it. Bounded
by ``--limit`` so an accidental full sweep cannot happen.

    uv run bookmarks-backfill-extract --limit 500
    uv run bookmarks-backfill-extract --limit 500 --marker /tmp/bf.marker
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys
from collections.abc import Iterable
from pathlib import Path

import httpx

from app import config, db
from app.extractor import extract_from_html
from app.fetcher import fetch_html

log = logging.getLogger("bookmarks.backfill_extract")

DEFAULT_LIMIT = 500
_READ_TIMEOUT = 10.0

_fetch_html = fetch_html  # seam: tests monkeypatch this name


def _default_marker() -> Path:
    return Path(str(config.BOOKMARKS_DB) + ".extract-marker")


def _read_marker(path: Path) -> int:
    try:
        return int(path.read_text(encoding="utf-8").strip())
    except (FileNotFoundError, ValueError):
        return 0


def _write_marker(path: Path, value: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(str(value), encoding="utf-8")


def _unprocessed(conn, after_id: int, limit: int) -> list[dict]:
    rows = conn.execute(
        "SELECT id, url FROM bookmarks WHERE id > ? ORDER BY id LIMIT ?",
        (after_id, limit),
    ).fetchall()
    return [dict(r) for r in rows]


async def backfill_extract(
    *, limit: int = DEFAULT_LIMIT, marker_path: Path | None = None
) -> dict:
    """Re-fetch + extract up to ``limit`` rows after the marker.

    Returns ``{"extracted": n, "skipped": n, "marker": last_id}``. The marker
    advances to the last id of the processed batch (even when a fetch fails),
    so the next run continues past it instead of re-processing the batch.
    """
    marker = marker_path or _default_marker()
    last_id = _read_marker(marker)
    rows = _unprocessed(db.get_conn(), last_id, limit)
    if not rows:
        return {"extracted": 0, "skipped": 0, "marker": last_id}

    timeout = httpx.Timeout(connect=3.0, read=_READ_TIMEOUT, write=3.0, pool=3.0)
    extracted = skipped = 0
    async with httpx.AsyncClient(
        timeout=timeout,
        follow_redirects=True,
        headers={"User-Agent": "bookmarks/0.1 (+https://github.com/local/bookmarks)"},
        http2=False,
    ) as client:
        for row in rows:
            html = await _fetch_html(client, row["url"])
            if html is None:
                skipped += 1
                continue
            meta = extract_from_html(html)
            db.update_metadata(
                row["id"],
                author=meta["author"],
                sitename=meta["sitename"],
                published_at=meta["date"],
                language=meta["language"],
                image_url=meta["image"],
                extracted_text=meta["text"],
            )
            extracted += 1

    new_marker = rows[-1]["id"]
    _write_marker(marker, new_marker)
    log.info(
        "backfill: %d extracted, %d skipped, marker now %d",
        extracted,
        skipped,
        new_marker,
    )
    return {"extracted": extracted, "skipped": skipped, "marker": new_marker}


def _parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="bookmarks-backfill-extract",
        description="Extract article content for existing bookmarks "
        "(re-fetches page HTML; resumable via a marker file).",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=DEFAULT_LIMIT,
        help="max rows to process per run",
    )
    parser.add_argument(
        "--marker",
        type=Path,
        default=None,
        help="override the marker file path",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    return parser.parse_args(list(argv))


def main(argv: Iterable[str] | None = None) -> int:
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    result = asyncio.run(backfill_extract(limit=args.limit, marker_path=args.marker))
    log.info("done: %s", result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
