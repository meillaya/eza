"""Dead-link checker.

HEAD-checks each bookmark and updates `is_dead` and `last_checked_at`.
Run from the CLI:

    uv run python -m app.check_dead                     # full sweep
    uv run python -m app.check_dead --limit 500        # cap the batch
    uv run python -m app.check_dead --older-than 86400 # only re-check >1d stale
    uv run python -m app.check_dead --include-dead     # re-check rows already flagged

Concurrency is bounded by an asyncio semaphore so we don't flood hosts.
A check is "dead" when the response is 4xx/5xx, or the host is unreachable.
3xx redirects are followed (httpx default).
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys
import time
from collections.abc import Iterable

import httpx

from . import db

log = logging.getLogger("bookmarks.check_dead")

DEFAULT_CONCURRENCY = 32
DEFAULT_TIMEOUT = 8.0


async def _check_one(
    client: httpx.AsyncClient,
    bookmark_id: int,
    url: str,
    sem: asyncio.Semaphore,
) -> bool:
    """Return True if the link is alive. Always updates the DB row."""
    is_alive = True
    try:
        async with sem:
            resp = await client.head(url)
        if resp.status_code >= 400:
            is_alive = False
        # Some servers reject HEAD; fall back to a ranged GET.
        elif resp.status_code in (405, 403) and "content-length" not in resp.headers:
            async with sem:
                get_resp = await client.get(url, headers={"Range": "bytes=0-0"})
            if get_resp.status_code >= 400:
                is_alive = False
    except (httpx.HTTPError, TimeoutError) as exc:
        log.debug("HEAD %s failed: %s", url, exc)
        is_alive = False

    db.mark_checked(bookmark_id, is_dead=not is_alive)
    return is_alive


async def check_dead(
    *,
    limit: int = 10_000,
    older_than: int = 0,
    include_dead: bool = True,
    concurrency: int = DEFAULT_CONCURRENCY,
    request_timeout: float = DEFAULT_TIMEOUT,
) -> dict:
    """Run a dead-link sweep. Returns {"checked": n, "dead": n, "alive": n}."""
    pending = db.unchecked_bookmarks(limit=limit, older_than=older_than, include_dead=include_dead)
    if not pending:
        log.info("no bookmarks need checking")
        return {"checked": 0, "dead": 0, "alive": 0}

    log.info("checking %d bookmark(s) at concurrency=%d", len(pending), concurrency)
    sem = asyncio.Semaphore(concurrency)
    timeout_obj = httpx.Timeout(
        connect=request_timeout,
        read=request_timeout,
        write=request_timeout,
        pool=request_timeout,
    )

    async with httpx.AsyncClient(
        timeout=timeout_obj,
        follow_redirects=True,
        headers={"User-Agent": "bookmarks/0.1 dead-link-checker"},
        http2=False,
    ) as client:
        results = await asyncio.gather(
            *(_check_one(client, b["id"], b["url"], sem) for b in pending),
            return_exceptions=False,
        )

    dead = sum(1 for alive in results if not alive)
    alive = sum(1 for alive in results if alive)
    log.info("done: checked=%d, alive=%d, dead=%d", len(results), alive, dead)
    return {"checked": len(results), "dead": dead, "alive": alive}


def _parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Check bookmarks for dead links.")
    parser.add_argument("--limit", type=int, default=10_000, help="Max bookmarks to check")
    parser.add_argument(
        "--older-than",
        type=int,
        default=0,
        help="Only re-check bookmarks not checked within this many seconds "
        "(0 = never checked only)",
    )
    parser.add_argument(
        "--concurrency",
        type=int,
        default=DEFAULT_CONCURRENCY,
        help="Max parallel HEAD requests",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT,
        help="Per-request timeout (s)",
    )
    parser.add_argument(
        "--include-dead",
        action="store_true",
        help="Re-check rows already flagged dead (default: only check live + unchecked)",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="Debug logging")
    return parser.parse_args(list(argv))


def main(argv: Iterable[str] | None = None) -> int:
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    started = time.monotonic()
    result = asyncio.run(
        check_dead(
            limit=args.limit,
            older_than=args.older_than,
            include_dead=args.include_dead,
            concurrency=args.concurrency,
            request_timeout=args.timeout,
        )
    )
    elapsed = time.monotonic() - started
    rate = result["checked"] / elapsed if elapsed > 0 else 0
    log.info(
        "summary: checked=%d alive=%d dead=%d in %.1fs (%.1f checks/s)",
        result["checked"],
        result["alive"],
        result["dead"],
        elapsed,
        rate,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
