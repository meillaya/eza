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


# ---------------------------------------------------------------------------
# Todo 18: full-content FTS search latency gate (ADDED to the todo-6 gate —
# the multi-tag gate above is untouched).
#
# Pinned methodology (same shape as todo 6, 20 runs instead of 3): the
# code-generated /api/search-equivalent FTS query, run via the sqlite3 CLI on
# a .backup copy of the live DB with `.timer on` and
# `PRAGMA wal_checkpoint(TRUNCATE);` first, 20 times, p95. The copy is
# backfilled to a representative level BEFORE measuring: the live DB currently
# has zero extracted content, so an unbackfilled gate would measure an empty
# corpus and trivially pass. Two backfill options were specified — the real
# `bookmarks-backfill-extract --limit 200` (network re-fetch, slow/flaky in
# CI) or synthetic note_body/extracted_text bodies on 200 rows; this gate uses
# the synthetic option for determinism (documented choice — the corpus, not
# its provenance, is what the latency must reflect).
# ---------------------------------------------------------------------------

FTS_QUERY = "rust"  # matches 100+ rows on the live DB via title/description/url
FTS_BACKFILL_ROWS = 200
GATE_FTS_SECONDS = 0.010

_SYNTHETIC_BODY = (
    "Representative extracted article body for the full-content search perf "
    "gate. Realistic long-form text covering rust programming, async web "
    "frameworks, sqlite full-text tuning, distributed systems, database "
    "internals and machine-learning infrastructure. "
) * 20


def _backfill_fts_corpus(db_copy: Path) -> int:
    """Ensure >= 200 rows carry extracted content on the copy; rebuild FTS.

    The ``bookmarks_au`` trigger already re-syncs the updated rows; the
    explicit ``rebuild`` additionally guarantees the index matches the
    content table. Returns the number of rows synthesized.
    """
    conn = sqlite3.connect(str(db_copy))
    try:
        populated = conn.execute(
            "SELECT COUNT(*) FROM bookmarks "
            "WHERE length(note_body) > 0 OR length(extracted_text) > 0"
        ).fetchone()[0]
        need = max(0, FTS_BACKFILL_ROWS - populated)
        if need:
            rows = conn.execute(
                "SELECT id FROM bookmarks "
                "WHERE length(note_body) = 0 AND length(extracted_text) = 0 "
                "LIMIT ?",
                (need,),
            ).fetchall()
            conn.executemany(
                "UPDATE bookmarks SET extracted_text = ? WHERE id = ?",
                [(_SYNTHETIC_BODY, r[0]) for r in rows],
            )
            conn.commit()
            conn.execute("INSERT INTO bookmarks_fts(bookmarks_fts) VALUES('rebuild')")
            conn.commit()
        return need
    finally:
        conn.close()


def _content_rows(db_copy: Path) -> int:
    conn = sqlite3.connect(str(db_copy))
    try:
        return conn.execute(
            "SELECT COUNT(*) FROM bookmarks "
            "WHERE length(note_body) > 0 OR length(extracted_text) > 0"
        ).fetchone()[0]
    finally:
        conn.close()


def _p95_cli_time(sql: str, db_copy: Path, *, runs: int = 20) -> tuple[list[float], float]:
    """Pinned methodology, 20 runs, p95 (todo 18 FTS search latency)."""
    script = (
        ".timer on\n"
        "PRAGMA temp_store=MEMORY;\n"
        "PRAGMA synchronous=NORMAL;\n"
        "PRAGMA wal_checkpoint(TRUNCATE);\n"
        + (sql + ";\n") * runs
    )
    out = _cli(script, db_copy)
    times = [float(m) for m in re.findall(r"Run Time: real (\d+\.\d+)", out)]
    assert len(times) >= runs, f"expected >= {runs} timed runs, got {len(times)}: {out!r}"
    times = times[-runs:]
    ordered = sorted(times)
    return times, ordered[int(len(ordered) * 0.95)]


def test_fts_search_p95_under_10ms(live_db_copy: Path) -> None:
    """Full-content FTS search on a backfilled copy must stay under 10ms p95.

    Mirrors the todo-6 pinned methodology but with 20 runs and a p95 gate
    instead of min-of-3. Measured AFTER the backfill so the enlarged
    five-column index is what the gate reflects.
    """
    _backfill_fts_corpus(live_db_copy)
    assert _content_rows(live_db_copy) >= FTS_BACKFILL_ROWS, (
        "FTS perf gate backfill did not populate the corpus"
    )
    sql, params = db._search_sql(q=FTS_QUERY, limit=60, offset=0)
    times, p95 = _p95_cli_time(_literalize(sql, params), live_db_copy)
    assert p95 < GATE_FTS_SECONDS, (
        f"FTS search p95 {p95 * 1000:.2f} ms over 20 runs "
        f"(pinned gate: < {GATE_FTS_SECONDS * 1000} ms); "
        f"runs: {[f'{t * 1000:.2f}' for t in times]}"
    )
