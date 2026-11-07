"""Full-page single-file HTML snapshots via the monolith binary.

On-demand only: the POST /api/bookmarks/{id}/snapshot route and the
``bookmarks-snapshot`` CLI run ``monolith <url> -o <out>`` as a subprocess
against the bookmark's URL and record the resulting single-file HTML path in
``bookmarks.snapshot_path`` (a column created by the v3 KB migration — this
module only consumes it).

The subprocess runs OUTSIDE any write transaction (todo-4 rule: no network /
process I/O inside BEGIN IMMEDIATE): :func:`capture_snapshot` runs monolith
first and only then opens a short transaction to record the result. When
monolith is missing, crashes, produces no file, or exceeds the 30s bound, the
Wayback availability URL is recorded as a fallback so the page stays
recoverable.
"""

from __future__ import annotations

import argparse
import logging
import subprocess
import sys
from collections.abc import Iterable
from pathlib import Path

from app import config, db

log = logging.getLogger("bookmarks.snapshot")

MONOLITH_TIMEOUT_SECONDS = 30
_WAYBACK_URL_TEMPLATE = "https://web.archive.org/web/2/{url}"


def _default_snapshots_dir() -> Path:
    """Snapshots live next to the database, under ``snapshots/``."""
    return Path(str(config.BOOKMARKS_DB)).parent / "snapshots"


def _wayback_url(url: str) -> str:
    """A Wayback availability-style URL for the page (no network needed)."""
    return _WAYBACK_URL_TEMPLATE.format(url=url)


def _run_monolith(url: str, out_path: Path, *, timeout: int, monolith: str) -> None:
    """Run the monolith binary; raise on non-zero exit, timeout, or empty output."""
    proc = subprocess.run(
        [monolith, "-o", str(out_path), url],
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    if proc.returncode != 0:
        stderr = (proc.stderr or b"").decode(errors="replace")[:200]
        raise RuntimeError(f"monolith exited {proc.returncode}: {stderr}")
    if not out_path.exists() or out_path.stat().st_size == 0:
        raise RuntimeError("monolith produced no output file")


def _store_snapshot_path(bookmark_id: int, value: str) -> None:
    with db.transaction() as conn:
        conn.execute(
            "UPDATE bookmarks SET snapshot_path = ? WHERE id = ?",
            (value, bookmark_id),
        )


def capture_snapshot(
    bookmark_id: int,
    url: str,
    *,
    snapshots_dir: Path | None = None,
    timeout: int = MONOLITH_TIMEOUT_SECONDS,
    monolith: str = "monolith",
) -> dict[str, str]:
    """Capture a single-file snapshot of ``url`` for ``bookmark_id``.

    Returns ``{"snapshot_path": str, "wayback_url": str}``. On success the
    local single-file HTML path is recorded in ``snapshot_path``; when
    monolith fails the Wayback availability URL is recorded instead. The
    subprocess runs before any DB write (never inside BEGIN IMMEDIATE).
    """
    snapshots_dir = snapshots_dir or _default_snapshots_dir()
    out_path = snapshots_dir / f"{bookmark_id}.html"
    try:
        snapshots_dir.mkdir(parents=True, exist_ok=True)
        _run_monolith(url, out_path, timeout=timeout, monolith=monolith)
    except (OSError, subprocess.TimeoutExpired, RuntimeError) as exc:
        log.warning("monolith snapshot failed for bookmark %s: %s", bookmark_id, exc)
        out_path = None

    if out_path is not None:
        _store_snapshot_path(bookmark_id, str(out_path))
        return {"snapshot_path": str(out_path), "wayback_url": ""}

    wayback = _wayback_url(url)
    _store_snapshot_path(bookmark_id, wayback)
    return {"snapshot_path": "", "wayback_url": wayback}


def snapshot_bookmark(bookmark_id: int) -> dict[str, str] | None:
    """Snapshot a bookmark by id; None when no such bookmark exists."""
    row = db.get_conn().execute(
        "SELECT id, url FROM bookmarks WHERE id = ?", (bookmark_id,)
    ).fetchone()
    if row is None:
        return None
    return capture_snapshot(int(row["id"]), str(row["url"]))


def _parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="bookmarks-snapshot",
        description="Capture a full-page single-file HTML snapshot of a "
        "bookmark with the monolith binary (Wayback URL fallback).",
    )
    parser.add_argument("bookmark_id", type=int, help="bookmark id to snapshot")
    parser.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    return parser.parse_args(list(argv))


def main(argv: Iterable[str] | None = None) -> int:
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    result = snapshot_bookmark(args.bookmark_id)
    if result is None:
        print(f"bookmark {args.bookmark_id} not found", file=sys.stderr)
        return 1
    print(f"snapshot_path={result['snapshot_path']}")
    print(f"wayback_url={result['wayback_url']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
