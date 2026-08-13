"""Perf regression test for the multi-tag AND filter (bookmarks-kb todo 6).

Pinned methodology (see .omo/plans/bookmarks-kb.md todo 6): measure the exact
SQL the code generates against a ``.backup`` snapshot of the live DB, using
the ``sqlite3`` CLI with ``.timer on``, ``PRAGMA wal_checkpoint(TRUNCATE)``
first to flush the WAL, 3 runs, take the minimum. Assert the minimum is under
the 5 ms gate.

Why the CLI rather than ``db.list_bookmarks()`` (both were offered as
options): the pinned methodology is explicitly the CLI, and the CLI isolates
the query engine (no Python/connection overhead), so the measured number is
the SQL statement the app runs. The statement is built by the code itself via
``db._search_sql``, so it is exactly what ``list_bookmarks`` executes.

The live DB (``data/bookmarks.db``) is gitignored, so in a fresh CI checkout
this module skips; when the real data is present it acts as the perf gate.
"""

from __future__ import annotations

import re
import shutil
import sqlite3
import subprocess
from pathlib import Path

import pytest

from app import db

LIVE_DB = Path(__file__).resolve().parent.parent / "data" / "bookmarks.db"

# A real 3-tag combination on the live DB (53 bookmarks carry all three).
# If the data ever stops containing it, the timing gate still holds (0-row
# result, same index-driven plan); the semantics test skips instead of flaking.
PERF_TAGS = ["code-ai", "huggingface", "machine learning/ai"]

# Pinned gate: minimum-of-3 CLI runs must stay under 5 ms (was ~7-15 ms for
# the correlated-subquery shape it replaces).
GATE_SECONDS = 0.005

pytestmark = pytest.mark.skipif(
    not LIVE_DB.exists() or shutil.which("sqlite3") is None,
    reason="perf gate needs the live DB (data/ is gitignored) and the sqlite3 CLI",
)


def _literalize(sql: str, params: list) -> str:
    """Replace ``?`` placeholders with SQL-quoted literals for the CLI."""
    quote = sqlite3.connect(":memory:")
    try:
        literals = [quote.execute("SELECT quote(?)", (p,)).fetchone()[0] for p in params]
    finally:
        quote.close()
    it = iter(literals)
    return re.sub(r"\?", lambda _: next(it), sql)


def _cli(sql: str, db_copy: Path, *, timeout: int = 60) -> str:
    """Run ``sql`` through the sqlite3 CLI (stdin) and return stdout."""
    proc = subprocess.run(
        ["sqlite3", "-noheader", str(db_copy)],
        input=sql,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    assert proc.returncode == 0, f"sqlite3 failed: {proc.stderr}"
    return proc.stdout


def _min_cli_time(sql: str, db_copy: Path) -> float:
    """Pinned methodology: app pragmas + WAL checkpoint, 3 runs, take the min."""
    script = (
        ".timer on\n"
        "PRAGMA temp_store=MEMORY;\n"
        "PRAGMA synchronous=NORMAL;\n"
        "PRAGMA wal_checkpoint(TRUNCATE);\n"
        + (sql + ";\n") * 3
    )
    out = _cli(script, db_copy)
    runs = [float(m) for m in re.findall(r"Run Time: real (\d+\.\d+)", out)]
    assert len(runs) >= 3, f"expected >= 3 timed runs, got {len(runs)}: {out!r}"
    return min(runs[-3:])


def _combo_matches(db_copy: Path) -> int:
    sql = (
        "SELECT COUNT(*) FROM ("
        " SELECT bookmark_id FROM bookmark_tags bt JOIN tags t ON t.id = bt.tag_id "
        " WHERE t.name IN (?,?,?) GROUP BY bookmark_id "
        " HAVING COUNT(DISTINCT bt.tag_id) = 3);"
    )
    rows = _cli(_literalize(sql, PERF_TAGS), db_copy).splitlines()
    return int(rows[0]) if rows else 0


@pytest.fixture()
def live_db_copy(tmp_path: Path) -> Path:
    """A consistent ``.backup`` snapshot of the live DB (read-only source)."""
    copy = tmp_path / "live-copy.db"
    src = sqlite3.connect(f"file:{LIVE_DB}?mode=ro", uri=True)
    try:
        dst = sqlite3.connect(str(copy))
        try:
            src.backup(dst)
        finally:
            dst.close()
    finally:
        src.close()
    return copy


def test_three_tag_query_under_5ms(live_db_copy: Path) -> None:
    """The code-generated 3-tag query must stay under the 5 ms pinned gate."""
    sql, params = db._search_sql(tags=PERF_TAGS, limit=60, offset=0)
    best = _min_cli_time(_literalize(sql, params), live_db_copy)
    assert best < GATE_SECONDS, (
        f"3-tag query took {best * 1000:.2f} ms (pinned gate: < {GATE_SECONDS * 1000} ms)"
    )


def test_three_tag_query_plan_is_index_driven(live_db_copy: Path) -> None:
    """The rewrite must drive ``idx_bookmark_tags_tag``, never scan all rows."""
    sql, params = db._search_sql(tags=PERF_TAGS, limit=60, offset=0)
    plan = _cli("EXPLAIN QUERY PLAN " + _literalize(sql, params), live_db_copy)
    assert "idx_bookmark_tags_tag" in plan, f"expected the tag index to drive the lookup:\n{plan}"
    assert "idx_bookmarks_created" not in plan, f"unexpected created_at scan:\n{plan}"


def test_three_tag_query_matches_old_semantics(live_db_copy: Path) -> None:
    """New query returns exactly the ids the old correlated subquery returned."""
    if _combo_matches(live_db_copy) == 0:
        pytest.skip(f"live DB no longer contains {PERF_TAGS!r}; nothing to compare")
    sql, params = db._search_sql(tags=PERF_TAGS, limit=100_000, offset=0)
    new_ids = {line.split("|")[0] for line in _cli(_literalize(sql, params), live_db_copy).splitlines()}
    placeholders = ",".join("?" for _ in PERF_TAGS)
    old_sql = (
        "SELECT b.id FROM bookmarks b WHERE "
        "(SELECT COUNT(DISTINCT t2.name) FROM bookmark_tags bt2 "
        "JOIN tags t2 ON t2.id = bt2.tag_id "
        f"WHERE bt2.bookmark_id = b.id AND t2.name IN ({placeholders})) = {len(PERF_TAGS)} "
        "ORDER BY b.id;"
    )
    old_ids = {line.strip() for line in _cli(_literalize(old_sql, PERF_TAGS), live_db_copy).splitlines()}
    assert new_ids == old_ids, "rewritten 3-tag query changed the result set"
    assert len(new_ids) > 0
