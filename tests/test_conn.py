"""Connection-model + concurrency tests for app.db.

Covers the per-thread reader connections, the ``_connect()`` pragma asserts,
the ``BEGIN IMMEDIATE`` transaction with bounded SQLITE_BUSY retry, the
migration-runs-exactly-once guarantee, and ``run_db`` event-loop safety.
"""

from __future__ import annotations

import sqlite3
import threading
import time
from collections.abc import Callable

import pytest

from app import db

_N_THREADS = 8
_OPS_PER_THREAD = 200


# ---------------------------------------------------------------------------
# _connect() pragma asserts
# ---------------------------------------------------------------------------


def test_connect_applies_and_asserts_all_pragmas(db_path):
    """_connect() applies every pragma and the readbacks match the requests."""
    conn = db._connect()
    try:
        assert conn.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
        assert int(conn.execute("PRAGMA synchronous").fetchone()[0]) == 1  # NORMAL
        assert int(conn.execute("PRAGMA temp_store").fetchone()[0]) == 2  # MEMORY
        assert int(conn.execute("PRAGMA foreign_keys").fetchone()[0]) == 1  # ON
        assert int(conn.execute("PRAGMA busy_timeout").fetchone()[0]) == 5000
    finally:
        conn.close()


def test_connect_refuses_cross_thread_use(fresh_db):
    """check_same_thread stays True: the driver blocks cross-thread use."""
    conn = fresh_db.get_conn()
    errors: list[Exception] = []

    def misuse() -> None:
        try:
            conn.execute("SELECT 1")
        except Exception as exc:  # sqlite3.ProgrammingError expected
            errors.append(exc)

    t = threading.Thread(target=misuse)
    t.start()
    t.join(10)
    assert len(errors) == 1
    assert isinstance(errors[0], sqlite3.ProgrammingError)


# ---------------------------------------------------------------------------
# Per-thread reader connections
# ---------------------------------------------------------------------------


def test_get_conn_returns_per_thread_connections(fresh_db):
    """Each thread gets its own connection; they are all distinct."""
    main_conn = fresh_db.get_conn()
    seen: dict[int, int] = {}

    def worker() -> None:
        conn = fresh_db.get_conn()
        seen[id(conn)] = conn.execute("PRAGMA user_version").fetchone()[0]

    threads = [threading.Thread(target=worker) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(10)

    assert len(seen) == 4  # four distinct worker connections
    assert all(v == 4 for v in seen.values())  # migrations ran through v4
    assert id(main_conn) not in seen


def test_reset_connection_state_rebuilds(fresh_db):
    """_reset_connection_state() drops the cached connection; the next
    get_conn() returns a fresh, functional connection."""
    first = fresh_db.get_conn()
    first.execute("CREATE TABLE reset_probe (x INTEGER)")
    db._reset_connection_state()

    second = fresh_db.get_conn()
    assert second is not first
    # The DB file is untouched — only the cached connection was dropped.
    assert second.execute("SELECT name FROM sqlite_master WHERE name='reset_probe'").fetchone()


# ---------------------------------------------------------------------------
# Concurrency smoke test
# ---------------------------------------------------------------------------


def test_concurrency_smoke_8_threads_200_mixed_ops(db_path):
    """8 threads x 200 mixed reads/writes: no exceptions, correct final count."""
    db.get_conn()  # initialize schema before the race
    errors: list[BaseException] = []
    barrier = threading.Barrier(_N_THREADS)

    def worker(n: int) -> None:
        try:
            barrier.wait()
            for i in range(_OPS_PER_THREAD):
                if i % 2 == 0:
                    db.insert_bookmark(
                        url=f"https://t{n}.example/{i}",
                        title=f"T{n}-{i}",
                        tags=[f"tag-{n}"],
                    )
                elif i % 4 == 1:
                    db.count_bookmarks(q=f"tag-{n}")
                else:
                    db.list_bookmarks(tags=[f"tag-{n}"], limit=5)
        except BaseException as exc:  # collect, don't kill the other threads
            errors.append(exc)

    threads = [threading.Thread(target=worker, args=(n,)) for n in range(_N_THREADS)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(120)

    assert errors == []
    assert db.count_bookmarks() == (_N_THREADS * _OPS_PER_THREAD) // 2


# ---------------------------------------------------------------------------
# BEGIN IMMEDIATE contention + SQLITE_BUSY retry
# ---------------------------------------------------------------------------


def test_concurrent_begin_immediate_writers_no_busy_escape(db_path):
    """Two writers racing on transaction(): both commit, no SQLITE_BUSY leak."""
    db.get_conn()
    errors: list[BaseException] = []
    barrier = threading.Barrier(2)

    def writer(n: int) -> None:
        try:
            barrier.wait()
            for i in range(20):
                with db.transaction() as conn:
                    conn.execute(
                        "INSERT INTO bookmarks (url, title, created_at) VALUES (?, ?, ?)",
                        (f"https://w{n}.example/{i}", f"W{n}-{i}", int(time.time())),
                    )
        except BaseException as exc:
            errors.append(exc)

    threads = [threading.Thread(target=writer, args=(n,)) for n in (1, 2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(60)

    assert errors == []
    assert db.count_bookmarks() == 40


def test_transaction_retries_busy_then_succeeds(db_path, monkeypatch):
    """transaction() retries a BEGIN IMMEDIATE that fails with SQLITE_BUSY and
    then succeeds once the contention clears."""
    real_conn = db._connect()

    class _FlakyConn:
        """Wraps a real connection; BEGIN IMMEDIATE fails BUSY twice first."""

        def __init__(self, conn: sqlite3.Connection) -> None:
            self._conn = conn
            self._busy_left = 2

        def execute(self, sql: str, *args):
            if str(sql).strip().upper().startswith("BEGIN") and self._busy_left:
                self._busy_left -= 1
                raise sqlite3.OperationalError("database is locked")
            return self._conn.execute(sql, *args)

    monkeypatch.setattr(db, "get_conn", lambda: _FlakyConn(real_conn))
    monkeypatch.setattr(db, "_BUSY_BACKOFF_SECONDS", 0.0)

    with db.transaction() as conn:
        conn.execute("CREATE TABLE retry_probe (x INTEGER)")
        conn.execute("INSERT INTO retry_probe VALUES (1)")

    assert real_conn.execute("SELECT COUNT(*) FROM retry_probe").fetchone()[0] == 1
    real_conn.close()


def test_transaction_gives_up_after_retries(db_path, monkeypatch):
    """A writer that never gets the lock raises SQLITE_BUSY after retries."""
    real_conn = db._connect()

    class _AlwaysBusy:
        def execute(self, sql: str, *args):
            if str(sql).strip().upper().startswith("BEGIN"):
                raise sqlite3.OperationalError("database is locked")
            return real_conn.execute(sql, *args)

    monkeypatch.setattr(db, "get_conn", lambda: _AlwaysBusy())
    monkeypatch.setattr(db, "_BUSY_BACKOFF_SECONDS", 0.0)

    with pytest.raises(sqlite3.OperationalError, match="locked"), db.transaction():
        pass  # never reached: BEGIN IMMEDIATE can't acquire the lock
    real_conn.close()


# ---------------------------------------------------------------------------
# Migration runs exactly once
# ---------------------------------------------------------------------------


def test_migrations_run_exactly_once_on_racing_first_connect(db_path, monkeypatch):
    """Two threads racing their first get_conn() run migrations exactly once."""
    real_migrations = db.run_migrations
    calls: list[int] = []

    def spy(conn: sqlite3.Connection) -> list[str]:
        calls.append(1)
        return real_migrations(conn)

    monkeypatch.setattr(db, "run_migrations", spy)

    errors: list[BaseException] = []
    barrier = threading.Barrier(2)

    def worker() -> None:
        try:
            barrier.wait()
            db.get_conn()
        except BaseException as exc:
            errors.append(exc)

    threads = [threading.Thread(target=worker) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(10)

    assert errors == []
    assert calls == [1]  # exactly one schema + migration initialization
    assert db.get_conn().execute("PRAGMA user_version").fetchone()[0] == 4


# ---------------------------------------------------------------------------
# run_db: async-safe DB calls
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_run_db_executes_off_the_event_loop(monkeypatch):
    """run_db() routes the call through anyio.to_thread.run_sync."""
    calls: list[tuple[Callable[..., object], tuple]] = []
    real_run_sync = db.to_thread.run_sync

    def spy(fn: Callable[..., object], *args: object):
        calls.append((fn, args))
        return real_run_sync(fn, *args)

    monkeypatch.setattr(db.to_thread, "run_sync", spy)

    result = await db.run_db(lambda a, b: a + b, 2, 3)
    assert result == 5
    assert len(calls) == 1
    fn, args = calls[0]
    # run_db wraps args in a closure, so the callable handed to
    # to_thread.run_sync takes no arguments but computes the real result.
    assert fn() == 5
    assert args == ()


@pytest.mark.asyncio
async def test_run_db_real_db_roundtrip(fresh_db):
    """An async test can run DB work via run_db and get results back."""
    bid = await db.run_db(
        db.insert_bookmark, url="https://async.example/", title="Async", tags=["a"]
    )
    row = await db.run_db(db.get_bookmark, bid)
    assert row is not None
    assert row["title"] == "Async"
    assert await db.run_db(db.count_bookmarks) == 1
