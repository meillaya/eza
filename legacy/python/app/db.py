"""SQLite + FTS5 layer for the bookmark store.

The schema is intentionally minimal:
  - one flat `bookmarks` table
  - a many-to-many `tags` setup
  - an external-content FTS5 virtual table on (title, description, url,
    note_body, extracted_text) — the todo-14 rebuild

WAL mode + synchronous=NORMAL gives us fast reads with safe-enough durability
for a personal tool. FTS5 with porter stemming gives ranked, sub-millisecond
search across 10k+ rows.

Connection model (concurrency-safe):
  - Every thread owns its reader connection via ``threading.local()``.
    ``check_same_thread`` stays at its default (True), so the driver refuses
    cross-thread use instead of silently racing.
  - Writes use ``BEGIN IMMEDIATE``: the write reservation is taken up front so
    a read-then-write flow can never die with a BUSY_SNAPSHOT upgrade error.
    ``transaction()`` additionally retries SQLITE_BUSY a bounded number of
    times (cross-process CLI contention).
  - Async handlers / background tasks must reach sqlite3 through
    :func:`run_db`, which offloads the call to a worker thread via
    ``anyio.to_thread`` so the event loop is never blocked.
"""

# allow: SIZE_OK — pre-existing monolithic DB layer (all SQL helpers in one
# module, >250 LOC before todo 23). Splitting it would stage new modules
# outside each todo's commit contract; the todos-17..23 commits grow it in
# place. graph_neighborhood() (todo 23) is self-contained below.

from __future__ import annotations

import json
import re
import sqlite3
import threading
import time
from collections.abc import Callable, Iterable, Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, TypeGuard, TypeVar
from urllib.parse import urlparse

from anyio import to_thread

from app import config, migrations

DB_PATH = config.BOOKMARKS_DB

_SCHEMA = """
CREATE TABLE IF NOT EXISTS bookmarks (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    url              TEXT    NOT NULL UNIQUE,
    title            TEXT    NOT NULL DEFAULT '',
    description      TEXT    NOT NULL DEFAULT '',
    favicon_url      TEXT    NOT NULL DEFAULT '',
    domain           TEXT    NOT NULL DEFAULT '',
    created_at       INTEGER NOT NULL,
    last_opened_at   INTEGER,
    last_checked_at  INTEGER,
    open_count       INTEGER NOT NULL DEFAULT 0,
    is_dead          INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_bookmarks_created ON bookmarks(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bookmarks_domain  ON bookmarks(domain);

CREATE VIRTUAL TABLE IF NOT EXISTS bookmarks_fts USING fts5(
    title,
    description,
    url,
    content='bookmarks',
    content_rowid='id',
    tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS bookmarks_ai AFTER INSERT ON bookmarks BEGIN
  INSERT INTO bookmarks_fts(rowid, title, description, url)
  VALUES (new.id, new.title, new.description, new.url);
END;
CREATE TRIGGER IF NOT EXISTS bookmarks_ad AFTER DELETE ON bookmarks BEGIN
  INSERT INTO bookmarks_fts(bookmarks_fts, rowid, title, description, url)
  VALUES('delete', old.id, old.title, old.description, old.url);
END;
CREATE TRIGGER IF NOT EXISTS bookmarks_au AFTER UPDATE ON bookmarks
WHEN old.title IS NOT new.title OR old.description IS NOT new.description
  OR old.url IS NOT new.url
BEGIN
  INSERT INTO bookmarks_fts(bookmarks_fts, rowid, title, description, url)
  VALUES('delete', old.id, old.title, old.description, old.url);
  INSERT INTO bookmarks_fts(rowid, title, description, url)
  VALUES (new.id, new.title, new.description, new.url);
END;

CREATE TABLE IF NOT EXISTS tags (
    id   INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT    NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS bookmark_tags (
    bookmark_id INTEGER NOT NULL REFERENCES bookmarks(id) ON DELETE CASCADE,
    tag_id      INTEGER NOT NULL REFERENCES tags(id)      ON DELETE CASCADE,
    PRIMARY KEY (bookmark_id, tag_id)
);
CREATE INDEX IF NOT EXISTS idx_bookmark_tags_tag ON bookmark_tags(tag_id);
"""

_PRAGMAS = [
    "PRAGMA journal_mode = WAL",
    "PRAGMA synchronous = NORMAL",
    "PRAGMA temp_store = MEMORY",
    "PRAGMA foreign_keys = ON",
    "PRAGMA busy_timeout = 5000",
]

# Bounded SQLITE_BUSY retry used by transaction() for cross-process
# contention (a CLI writing while the web server holds the write lock).
_BUSY_RETRIES = 3
_BUSY_BACKOFF_SECONDS = 0.05

T = TypeVar("T")


class _ConnState:
    """One generation of per-thread reader connections for a DB file.

    A fresh state is created whenever ``DB_PATH`` changes or the module-level
    ``_conn`` is reset (tests). Each state owns its own ``threading.local()``,
    so every thread lazily builds — and exclusively owns — its sqlite3
    connection. Dropping the state (and thus its thread-local) lets the old
    connections be garbage-collected and closed.
    """

    __slots__ = ("local", "path")

    def __init__(self, path: Path) -> None:
        self.path = path
        self.local = threading.local()


# Kept as a module-level name so tests can reset it (conftest sets
# ``db._conn = None`` to isolate each test against a fresh temp DB).
_conn: _ConnState | None = None
_migration_lock = threading.Lock()


def _assert_pragmas(conn: sqlite3.Connection) -> None:
    """Fail loudly if any pragma did not stick.

    Most of these can silently fall back (e.g. ``journal_mode`` on a
    filesystem without WAL support), so we read them back rather than trusting
    the SET statement.
    """
    mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
    assert str(mode).lower() == "wal", f"journal_mode is {mode!r}, expected 'wal'"
    synchronous = conn.execute("PRAGMA synchronous").fetchone()[0]
    assert int(synchronous) == 1, f"synchronous is {synchronous!r}, expected NORMAL(1)"
    temp_store = conn.execute("PRAGMA temp_store").fetchone()[0]
    assert int(temp_store) == 2, f"temp_store is {temp_store!r}, expected MEMORY(2)"
    foreign_keys = conn.execute("PRAGMA foreign_keys").fetchone()[0]
    assert int(foreign_keys) == 1, f"foreign_keys is {foreign_keys!r}, expected ON(1)"
    busy_timeout = conn.execute("PRAGMA busy_timeout").fetchone()[0]
    assert int(busy_timeout) == 5000, f"busy_timeout is {busy_timeout!r}, expected 5000"


def _connect() -> sqlite3.Connection:
    """Open a connection to ``DB_PATH`` with every pragma applied and asserted.

    ``check_same_thread`` is left at its default (True): each connection is
    owned by exactly one thread, so the driver refuses cross-thread use
    instead of racing silently. ``isolation_level=None`` keeps us in autocommit
    mode; transactions are managed explicitly (see :func:`transaction`).
    """
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH), isolation_level=None)
    try:
        conn.row_factory = sqlite3.Row
        for pragma in _PRAGMAS:
            conn.execute(pragma)
        _assert_pragmas(conn)
    except Exception:
        conn.close()
        raise
    return conn


def _migrate_once() -> None:
    """Apply the base schema and pending migrations exactly once per DB file.

    Runs on a short-lived connection while holding ``_migration_lock``. The
    ``IF NOT EXISTS`` DDL and the transactional ``user_version`` stamp make
    this safe even across processes racing on a fresh database.
    """
    conn = _connect()
    try:
        conn.executescript(_SCHEMA)
        run_migrations(conn)
    finally:
        conn.close()


def _ensure_state() -> _ConnState:
    """Return the connection state for the current ``DB_PATH``.

    Rebuilds it (running the one-time schema + migration init) under
    ``_migration_lock`` when ``DB_PATH`` changed or the state was reset.
    """
    global _conn
    state = _conn
    if state is not None and state.path == DB_PATH:
        return state
    with _migration_lock:
        state = _conn
        if state is not None and state.path == DB_PATH:
            return state
        _migrate_once()
        fresh = _ConnState(DB_PATH)
        _conn = fresh
        return fresh


def get_conn() -> sqlite3.Connection:
    """Return the calling thread's reader connection, creating it on first use.

    Each thread gets its own connection (``check_same_thread=True``), so the
    driver enforces single-thread ownership. The first connection ever opened
    initializes the schema and runs pending migrations exactly once.
    """
    state = _ensure_state()
    conn = getattr(state.local, "conn", None)
    if conn is None:
        conn = _connect()
        state.local.conn = conn
    return conn


def _reset_connection_state() -> None:
    """Drop every cached connection so the next get_conn() reconnects.

    Tests point ``DB_PATH`` at a fresh file and call this (or set ``_conn``
    to None) to isolate each test database.
    """
    global _conn
    with _migration_lock:
        _conn = None


def _is_busy(exc: BaseException) -> bool:
    """True when the exception is a SQLITE_BUSY contention failure."""
    code = getattr(exc, "sqlite_errorcode", None)
    if code is not None:
        return code == sqlite3.SQLITE_BUSY
    return isinstance(exc, sqlite3.OperationalError) and "locked" in str(exc).lower()


async def run_db(fn: Callable[..., T], *args: Any, **kwargs: Any) -> T:
    """Run a synchronous DB call on a worker thread — never the event loop.

    Async handlers and background tasks must reach sqlite3 through this
    helper so the event loop is never blocked by a query. Returns the
    function's result when awaited.
    """
    return await to_thread.run_sync(lambda: fn(*args, **kwargs))


def run_migrations(conn: sqlite3.Connection) -> list[str]:
    """Apply every pending migration, each in its own transaction.

    The schema version is tracked in ``PRAGMA user_version``. Each registered
    migration step (see :mod:`app.migrations`) runs inside a single
    ``BEGIN IMMEDIATE`` transaction together with its version stamp, so a
    failed step rolls back both its schema changes and the stamp. Returns the
    names of the migrations applied (empty when the DB is already current).
    """
    conn.row_factory = sqlite3.Row  # migration modules rely on named access
    row = conn.execute("PRAGMA user_version").fetchone()
    current = int(row[0]) if row is not None else 0
    applied: list[str] = []
    for version, (name, fn) in enumerate(migrations.MIGRATIONS, start=1):
        if version <= current:
            continue
        conn.execute("BEGIN IMMEDIATE")
        try:
            fn(conn)
            conn.execute(f"PRAGMA user_version = {version}")
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise
        applied.append(name)
    return applied


@contextmanager
def transaction() -> Iterator[sqlite3.Connection]:
    """Explicit transaction wrapper: ``BEGIN IMMEDIATE`` + bounded busy retry.

    ``BEGIN IMMEDIATE`` takes the write reservation up front, so a handler
    that reads and then writes can never die with a BUSY_SNAPSHOT upgrade
    error. When another writer — another thread, or a CLI process — holds the
    lock, we retry the whole transaction up to ``_BUSY_RETRIES`` times with a
    short backoff. Commits on success, rolls back on error.
    """
    conn = get_conn()
    for attempt in range(_BUSY_RETRIES):
        try:
            conn.execute("BEGIN IMMEDIATE")
        except sqlite3.OperationalError as exc:
            if not _is_busy(exc) or attempt == _BUSY_RETRIES - 1:
                raise
            time.sleep(_BUSY_BACKOFF_SECONDS)
            continue
        try:
            yield conn
        except Exception:
            conn.execute("ROLLBACK")
            raise
        else:
            conn.execute("COMMIT")
            return
    raise RuntimeError("unreachable: transaction retry loop exhausted")


# ---------------------------------------------------------------------------
# Query helpers
# ---------------------------------------------------------------------------

_FTS_SANITIZE = re.compile(r"[^\w\s-]+", re.UNICODE)


def fts_query(user_input: str) -> str | None:
    """Turn a user-typed search string into a safe FTS5 MATCH expression.

    Each token is converted to a prefix match (token*) and ANDed together, so
    "rust web" matches "rust web framework" and "rustlang websocket". Anything
    that isn't a word/hyphen/space is dropped, so users can't break out of the
    query syntax.
    """
    cleaned = _FTS_SANITIZE.sub(" ", user_input).strip()
    if not cleaned:
        return None
    tokens = [t for t in cleaned.split() if t]
    if not tokens:
        return None
    return " AND ".join(f'"{t}"*' for t in tokens)


@dataclass(frozen=True, slots=True)
class _ParsedQuery:
    """A search string split into its structured parts (todo 18 operators).

    ``q`` is the ONLY place the operators live — the q/tags/offset/limit API
    shape is untouched. Plain tokens become the FTS5 MATCH expression;
    ``-term`` becomes an FTS5-backed NOT-IN filter; ``tag:name`` merges into
    the tag filter; ``is:unread`` restricts to unread rows; ``is:dead`` (todo
    30) restricts to dead-link rows; ``link:target`` restricts to bookmarks
    whose note links resolve to the named bookmark. Malformed operators
    (``tag:`` with no value, unknown ``is:*`` values) are dropped — parsing
    never raises and never filters.
    """

    fts_expr: str | None
    terms: tuple[str, ...]
    tags: tuple[str, ...]
    is_unread: bool
    is_dead: bool
    link_targets: tuple[str, ...]
    negated: tuple[str, ...]


_TAG_PREFIX = "tag:"
_LINK_PREFIX = "link:"
_IS_UNREAD = "is:unread"
_IS_DEAD = "is:dead"


def _sanitize_token(token: str) -> str:
    """Drop every non word/hyphen character from a single search token."""
    return _FTS_SANITIZE.sub(" ", token).strip()


def _fts_expr(plain: Sequence[str]) -> str | None:
    """FTS5 MATCH expression from the plain (non-operator) tokens."""
    cleaned = _FTS_SANITIZE.sub(" ", " ".join(plain)).strip()
    tokens = [t for t in cleaned.split() if t]
    if not tokens:
        return None
    return " AND ".join(f'"{t}"*' for t in tokens)


def _parse_operators(user_input: str) -> _ParsedQuery:
    """Split a search string into FTS terms, tag filters and flags.

    Tokens are classified independently: ``tag:value`` (lowercased, empty
    value dropped), ``is:unread`` / ``is:dead`` (any other ``is:*`` dropped),
    ``link:value`` (empty value dropped), ``-term`` (FTS5-backed negation),
    and everything else as a plain FTS term.
    """
    tags: list[str] = []
    link_targets: list[str] = []
    plain: list[str] = []
    negated: list[str] = []
    is_unread = False
    is_dead = False
    for token in user_input.split():
        if token.startswith(_TAG_PREFIX):
            value = token[len(_TAG_PREFIX) :].strip().lower()
            if value:
                tags.append(value)
            continue
        if token.startswith(_LINK_PREFIX):
            value = token[len(_LINK_PREFIX) :].strip()
            if value:
                link_targets.append(value)
            continue
        if token.startswith("is:"):
            if token == _IS_UNREAD:
                is_unread = True
            elif token == _IS_DEAD:
                is_dead = True
            continue
        if token.startswith("-") and len(token) > 1:
            term = token[1:].strip()
            if term:
                negated.append(term)
            continue
        plain.append(token)
    return _ParsedQuery(
        fts_expr=_fts_expr(plain),
        terms=tuple(filter(None, (_sanitize_token(t) for t in plain))),
        tags=tuple(tags),
        is_unread=is_unread,
        is_dead=is_dead,
        link_targets=tuple(link_targets),
        negated=tuple(filter(None, (_sanitize_token(t) for t in negated))),
    )


# ---------------------------------------------------------------------------
# Snippets (todo 18): a ~120-char window from the best-matching FTS field
# ---------------------------------------------------------------------------

_SNIPPET_FIELDS = ("title", "description", "url", "note_body", "extracted_text")
_SNIPPET_LENGTH = 120
_SNIPPET_LEAD = 40


def _build_snippet(row: dict, terms: Sequence[str]) -> str:
    """A ~120-char window around the earliest query-term match.

    Scans the five FTS fields in order and keeps the one whose earliest
    case-insensitive term occurrence comes first (the "best/earliest" match).
    Returns "" when no term appears literally — porter stemming may still have
    matched an inflected form, leaving no literal window to anchor on.
    """
    best_index: int | None = None
    best_text: str | None = None
    for field in _SNIPPET_FIELDS:
        text = row.get(field)
        if not text:
            continue
        text = " ".join(text.split())
        index = _earliest_match(text, terms)
        if index is not None and (best_index is None or index < best_index):
            best_index, best_text = index, text
    if best_text is None or best_index is None:
        return ""
    start = max(0, best_index - _SNIPPET_LEAD)
    end = min(len(best_text), start + _SNIPPET_LENGTH)
    prefix = "..." if start > 0 else ""
    suffix = "..." if end < len(best_text) else ""
    return f"{prefix}{best_text[start:end]}{suffix}"


def _earliest_match(text: str, terms: Sequence[str]) -> int | None:
    """The earliest case-insensitive index of any term, or None."""
    lowered = text.lower()
    best: int | None = None
    for term in terms:
        index = lowered.find(term.lower())
        if index >= 0 and (best is None or index < best):
            best = index
    return best


def _row_to_dict(row: sqlite3.Row) -> dict:
    return dict(row)


def _tag_filter_subquery(tags: Sequence[str]) -> str:
    """Build the ``b.id IN (…)`` multi-tag AND filter fragment.

    Index-driven replacement for the old correlated
    ``(SELECT COUNT(DISTINCT …) FROM bookmark_tags … WHERE … = b.id …) = N``
    subquery, which was O(rows x tags): each tag name resolves through the
    unique ``tags.name`` index, then ``idx_bookmark_tags_tag`` enumerates the
    candidate bookmarks. ``GROUP BY bookmark_id`` +
    ``HAVING COUNT(DISTINCT bt.tag_id) = N`` preserves exact AND semantics —
    a bookmark must carry every requested tag — without multiplying rows.
    """
    placeholders = ",".join("?" for _ in tags)
    return (
        "b.id IN (SELECT bookmark_id FROM bookmark_tags bt "
        "JOIN tags t ON t.id = bt.tag_id "
        f"WHERE t.name IN ({placeholders}) "
        "GROUP BY bookmark_id "
        f"HAVING COUNT(DISTINCT bt.tag_id) = {len(tags)})"
    )


def _merged_tags(parsed: _ParsedQuery | None, tags: Sequence[str]) -> list[str]:
    """The tag: operators from q merged with the tags API parameter (ANDed).

    Order-preserving dedupe: a duplicate tag (``tag:rust`` plus a ``rust``
    entry in the tags parameter) must not inflate the HAVING count.
    """
    merged: list[str] = []
    if parsed is not None:
        merged.extend(parsed.tags)
    merged.extend(tags)
    return list(dict.fromkeys(merged))


_LINK_TARGET_SUBQUERY = (
    "EXISTS (SELECT 1 FROM links l WHERE l.source_id = b.id AND l.target_id IN "
    "(SELECT id FROM bookmarks WHERE title = ? OR title LIKE ? COLLATE NOCASE "
    "OR url LIKE ? COLLATE NOCASE))"
)


def _search_sql(
    *,
    q: str | None = None,
    tags: Sequence[str] = (),
    is_read: int | None = None,
    is_dead: int | None = None,
    limit: int = 60,
    offset: int = 0,
    count: bool = False,
) -> tuple[str, list]:
    """Build the parameterized search statement and its params.

    FTS + tags keeps the FTS match as the driving join: the match set is
    materialized first and ``CROSS JOIN`` pins it ahead of ``bookmarks`` so
    the optimizer cannot reorder the tag filter ahead of it (which degrades
    the plan from ~2 ms to ~700 ms of per-candidate FTS scans). The tag
    filter then applies as a second join + ``GROUP BY b.id``/``HAVING``.

    With ``count=True`` the grouped result is wrapped so ``COUNT(*)`` counts
    distinct bookmarks rather than (bookmark x tag) rows.

    Operators parsed out of ``q`` become WHERE fragments appended to every
    branch: ``tag:`` merges into ``tags`` (AND), while ``is:unread``,
    ``is:dead``, ``link:target`` and ``-term`` are plain filter conditions
    whose params follow the driving clause's params in SQL order. The explicit
    ``is_read`` keyword (the todo-29 inbox queue view) and ``is_dead`` keyword
    (the todo-30 dead-link review view) are two more plain filter conditions
    that compose with the ``is:unread`` / ``is:dead`` operators — all four
    stay working together.
    """
    parsed = _parse_operators(q) if q else None
    fts = parsed.fts_expr if parsed is not None else None
    merged_tags = _merged_tags(parsed, tags)

    where_fragments: list[str] = []
    where_params: list = []
    if parsed is not None:
        if parsed.is_unread:
            where_fragments.append("b.is_read = 0")
        if parsed.is_dead:
            where_fragments.append("b.is_dead = 1")
        for target in parsed.link_targets:
            where_fragments.append(_LINK_TARGET_SUBQUERY)
            where_params.extend([target, f"%{target}%", f"%{target}%"])
        for negated in parsed.negated:
            where_fragments.append(
                "b.id NOT IN (SELECT rowid FROM bookmarks_fts WHERE bookmarks_fts MATCH ?)"
            )
            where_params.append(f'"{negated}"*')
    if is_read is not None:
        where_fragments.append("b.is_read = ?")
        where_params.append(is_read)
    if is_dead is not None:
        where_fragments.append("b.is_dead = ?")
        where_params.append(is_dead)

    params: list = []
    if fts and merged_tags:
        fts_cols = "rowid" if count else "rowid, rank"
        from_clause = (
            f"(SELECT {fts_cols} FROM bookmarks_fts WHERE bookmarks_fts MATCH ?) f "
            "CROSS JOIN bookmarks b ON b.id = f.rowid"
        )
        params.append(fts)
        placeholders = ",".join("?" for _ in merged_tags)
        join = (
            " JOIN bookmark_tags bt ON bt.bookmark_id = b.id "
            " JOIN tags t ON t.id = bt.tag_id "
        )
        tag_where = f"t.name IN ({placeholders})"
        params.extend(merged_tags)
        params.extend(where_params)
        where = " AND ".join([tag_where, *where_fragments])
        group_having = f" GROUP BY b.id HAVING COUNT(DISTINCT bt.tag_id) = {len(merged_tags)} "
    elif fts:
        from_clause = "bookmarks b"
        join = " JOIN bookmarks_fts f ON f.rowid = b.id "
        where = "bookmarks_fts MATCH ?"
        params.append(fts)
        params.extend(where_params)
        if where_fragments:
            where = f"{where} AND " + " AND ".join(where_fragments)
        group_having = ""
    else:
        from_clause = "bookmarks b"
        join = ""
        if merged_tags:
            where_fragments.insert(0, _tag_filter_subquery(merged_tags))
            params.extend(merged_tags)
        params.extend(where_params)
        where = " AND ".join(where_fragments)
        group_having = ""

    where_sql = f" WHERE {where}" if where else ""
    if count:
        if fts and merged_tags:
            sql = (
                "SELECT COUNT(*) AS n FROM (SELECT b.id FROM "
                f"{from_clause}{join}{where_sql}{group_having})"
            )
        else:
            sql = f"SELECT COUNT(*) AS n FROM {from_clause}{join}{where_sql}"
    else:
        order = " ORDER BY f.rank, b.created_at DESC " if fts else " ORDER BY b.created_at DESC "
        sql = (
            f"SELECT b.* FROM {from_clause}{join}{where_sql}{group_having}{order}"
            " LIMIT ? OFFSET ?"
        )
        params.extend([limit, offset])
    return sql, params


def list_bookmarks(
    *,
    q: str | None = None,
    tags: Sequence[str] = (),
    is_read: int | None = None,
    is_dead: int | None = None,
    limit: int = 60,
    offset: int = 0,
) -> list[dict]:
    """Return a page of bookmarks, optionally filtered by FTS query and tags.

    When ``q`` carries plain search terms each result gains a ``snippet``: a
    ~120-char window around the best/earliest match across the five FTS
    fields (title/description/url/note_body/extracted_text). Operators in
    ``q`` (tag:/is:unread/is:dead/link:/-term) are applied by ``_search_sql``,
    and the explicit ``is_read`` (todo-29 inbox) / ``is_dead`` (todo-30
    dead-link review) filters compose with them.
    """
    conn = get_conn()
    sql, params = _search_sql(
        q=q, tags=tags, is_read=is_read, is_dead=is_dead, limit=limit, offset=offset
    )
    rows = conn.execute(sql, params).fetchall()
    items = [_row_to_dict(r) for r in rows]
    if q:
        parsed = _parse_operators(q)
        if parsed.terms:
            for item in items:
                item["snippet"] = _build_snippet(item, parsed.terms)
    return items


def count_bookmarks(
    *,
    q: str | None = None,
    tags: Sequence[str] = (),
    is_read: int | None = None,
    is_dead: int | None = None,
) -> int:
    conn = get_conn()
    sql, params = _search_sql(q=q, tags=tags, is_read=is_read, is_dead=is_dead, count=True)
    return conn.execute(sql, params).fetchone()["n"]


def get_bookmark(bookmark_id: int) -> dict | None:
    conn = get_conn()
    row = conn.execute("SELECT * FROM bookmarks WHERE id = ?", (bookmark_id,)).fetchone()
    if row is None:
        return None
    d = _row_to_dict(row)
    d["tags"] = get_tags_for_bookmark(bookmark_id)
    return d


# ---------------------------------------------------------------------------
# Neighborhood graph (todo 23): BFS over the links table, bounded by hops.
# ---------------------------------------------------------------------------

# Hard cap on the number of nodes a single neighborhood may contain. A depth-2
# neighborhood on a pathological hub must never grow past this: beyond the cap
# the BFS truncates deterministically (seed first, then neighbors in BFS
# discovery order), keeping both the API payload and the Cytoscape render
# bounded no matter how large the corpus is. 500 sits comfortably under the
# ~1k-node threshold where Cytoscape.js starts to lag (wave-1 digests, LiACS
# 2019: "Cytoscape.js beats d3-force SVG past ~1k nodes").
_GRAPH_MAX_NODES = 500


def graph_neighborhood(seed_id: int, depth: int = 1) -> dict | None:
    """BFS neighborhood of ``seed_id`` over the ``links`` table.

    Returns None when the seed bookmark does not exist. Otherwise returns
    ``{"nodes": [...], "edges": [...]}`` where:

    - ``nodes`` — the seed plus every bookmark within ``depth`` hops, with
      links traversed in BOTH directions (an edge A→B makes each endpoint a
      neighbor of the other). Each node is
      ``{id, title, url, tags, is_read, indegree}``.
    - ``edges`` — the directed links between the returned nodes ONLY, in
      source→target (wikilink) direction: when A's note contains ``[[B]]`` the
      edge is ``{source: A, target: B}``. An edge whose endpoints fall outside
      the neighborhood is never included.

    The neighborhood is bounded by construction: at depth 1 the node set is
    the seed plus its direct neighbors; at depth 2 it grows by exactly one
    more hop; ``_GRAPH_MAX_NODES`` caps the total. An isolated seed yields a
    single-node graph with an empty edge list. ``indegree`` is the count of
    incoming links across the WHOLE corpus (how many bookmarks point at this
    node) — the global importance signal the graph UI maps to node size.
    """
    conn = get_conn()
    if conn.execute("SELECT 1 FROM bookmarks WHERE id = ?", (seed_id,)).fetchone() is None:
        return None

    # BFS. ``node_ids`` keeps discovery order (seed first, then hop-1 by
    # bookmark id, then hop-2) so cap truncation below is deterministic.
    node_ids: list[int] = [seed_id]
    known: set[int] = {seed_id}
    edge_pairs: set[tuple[int, int]] = set()
    frontier: list[int] = [seed_id]

    for _ in range(depth):
        marks = ",".join("?" for _ in frontier)
        rows = conn.execute(
            f"""
            SELECT source_id, target_id FROM links
             WHERE (source_id IN ({marks}) OR target_id IN ({marks}))
               AND source_id IS NOT NULL AND target_id IS NOT NULL
            """,
            (*frontier, *frontier),
        ).fetchall()
        next_frontier: list[int] = []
        for row in rows:
            src, tgt = row["source_id"], row["target_id"]
            edge_pairs.add((src, tgt))
            for nid in (src, tgt):
                if nid not in known:
                    known.add(nid)
                    next_frontier.append(nid)
        frontier = next_frontier
        node_ids.extend(frontier)

    # Cap: keep discovery order, drop the overflow, and discard every edge
    # with a truncated endpoint so the graph stays internally consistent.
    if len(node_ids) > _GRAPH_MAX_NODES:
        kept = set(node_ids[:_GRAPH_MAX_NODES])
        node_ids = node_ids[:_GRAPH_MAX_NODES]
        edge_pairs = {(s, t) for (s, t) in edge_pairs if s in kept and t in kept}

    # Bookmark details, tags and global indegree for the node set — three
    # parameterized queries, all index-driven (id IN (…), idx_links_target).
    marks = ",".join("?" for _ in node_ids)
    rows = conn.execute(
        f"SELECT id, title, url, is_read FROM bookmarks WHERE id IN ({marks})", node_ids
    ).fetchall()
    by_id = {r["id"]: dict(r) for r in rows}

    tags: dict[int, list[str]] = {nid: [] for nid in node_ids}
    for r in conn.execute(
        f"""
        SELECT bt.bookmark_id, t.name FROM bookmark_tags bt
        JOIN tags t ON t.id = bt.tag_id
        WHERE bt.bookmark_id IN ({marks})
        ORDER BY bt.bookmark_id, t.name
        """,
        node_ids,
    ).fetchall():
        tags[r["bookmark_id"]].append(r["name"])

    indegree = {r["target_id"]: r["n"] for r in conn.execute(
        f"SELECT target_id, COUNT(*) AS n FROM links WHERE target_id IN ({marks}) GROUP BY target_id",
        node_ids,
    ).fetchall()}

    nodes = []
    for nid in node_ids:
        b = by_id[nid]
        nodes.append(
            {
                "id": nid,
                "title": b["title"],
                "url": b["url"],
                "tags": tags.get(nid, []),
                "is_read": b["is_read"],
                "indegree": indegree.get(nid, 0),
            }
        )
    edges = [
        {"source": s, "target": t}
        for (s, t) in sorted(edge_pairs)
        if s in by_id and t in by_id
    ]
    return {"nodes": nodes, "edges": edges}


def autocomplete(q: str, *, limit: int = 10) -> list[dict]:
    """Wikilink autocomplete (todo 20): prefix+substring over title/url.

    Case-insensitive ``LIKE`` matching (COLLATE NOCASE) over both ``title``
    and ``url`` — the "alias" behavior, since no aliases schema exists. A
    title starting with the query ranks ahead of a title that merely contains
    it. Empty/blank ``q`` returns ``[]`` (the typeahead dropdown just opens
    without results). Returns ``{id, title, url}`` items, at most ``limit``.
    """
    query = q.strip()
    if not query:
        return []
    pattern = f"%{query}%"
    prefix = f"{query}%"
    rows = get_conn().execute(
        """
        SELECT id, title, url FROM bookmarks
        WHERE title LIKE ? COLLATE NOCASE OR url LIKE ? COLLATE NOCASE
        ORDER BY
            CASE WHEN title LIKE ? COLLATE NOCASE THEN 0 ELSE 1 END,
            title COLLATE NOCASE
        LIMIT ?
        """,
        (pattern, pattern, prefix, limit),
    ).fetchall()
    return [_row_to_dict(r) for r in rows]


def insert_bookmark(
    *,
    url: str,
    title: str = "",
    description: str = "",
    favicon_url: str = "",
    domain: str = "",
    tags: Iterable[str] = (),
) -> int:
    """Insert a bookmark. Returns the new row id. URL must be unique.

    If `domain` is empty, it's derived from the URL.
    """
    if not domain:
        domain = urlparse(url).netloc
    now = int(time.time())
    with transaction() as conn:
        cur = conn.execute(
            """
            INSERT INTO bookmarks (url, title, description, favicon_url, domain, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(url) DO UPDATE SET
                title       = excluded.title,
                description = excluded.description,
                favicon_url = excluded.favicon_url,
                domain      = excluded.domain
            RETURNING id
            """,
            (url, title, description, favicon_url, domain, now),
        )
        row = cur.fetchone()
        bookmark_id = row[0]

        for tag in tags:
            tag = tag.strip().lower()
            if not tag:
                continue
            conn.execute("INSERT OR IGNORE INTO tags(name) VALUES (?)", (tag,))
            tag_id = conn.execute("SELECT id FROM tags WHERE name = ?", (tag,)).fetchone()[0]
            conn.execute(
                "INSERT OR IGNORE INTO bookmark_tags(bookmark_id, tag_id) VALUES (?, ?)",
                (bookmark_id, tag_id),
            )
    return bookmark_id


def bulk_insert_bookmarks(
    items: Iterable[dict],
    *,
    enrich_callback=None,
) -> int:
    """Insert many bookmarks in a single transaction. Much faster than
    calling insert_bookmark() in a loop (~100x for thousands of rows).

    Each item is a dict with keys: url, title, domain, tags (list of names).
    Returns the number of rows touched.

    enrich_callback(url) → coroutine: called for each NEW (non-duplicate) URL
    so the caller can schedule metadata fetching. Pass None to skip.
    """
    items = list(items)
    if not items:
        return 0
    now = int(time.time())
    touched = 0

    with transaction() as conn:
        # Pre-create all unique tags so we can map name→id in one pass.
        all_tags: set[str] = set()
        for it in items:
            for tag in it.get("tags", []):
                t = tag.strip().lower()
                if t:
                    all_tags.add(t)
        conn.executemany(
            "INSERT OR IGNORE INTO tags(name) VALUES (?)",
            ((t,) for t in all_tags),
        )
        tag_id_by_name = {
            row["name"]: row["id"] for row in conn.execute("SELECT id, name FROM tags").fetchall()
        }

        for it in items:
            url = it["url"]
            title = it.get("title", "")
            domain = it.get("domain", "")
            tag_names = [t.strip().lower() for t in it.get("tags", []) if t.strip()]

            cur = conn.execute(
                """
                INSERT INTO bookmarks (url, title, domain, created_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(url) DO UPDATE SET
                    title  = excluded.title,
                    domain = excluded.domain
                RETURNING id
                """,
                (url, title, domain, now),
            )
            bookmark_id = cur.fetchone()[0]
            touched += 1

            for tag_name in tag_names:
                tag_id = tag_id_by_name.get(tag_name)
                if tag_id is None:
                    continue
                conn.execute(
                    "INSERT OR IGNORE INTO bookmark_tags(bookmark_id, tag_id) VALUES (?, ?)",
                    (bookmark_id, tag_id),
                )

    # Schedule enrichment for newly inserted rows after the transaction
    # has committed. We can't know here which rows were new vs. duplicates,
    # but the fetcher handles existing titles gracefully.
    if enrich_callback is not None:
        for it in items:
            enrich_callback(it["url"])

    return touched


def delete_bookmark(bookmark_id: int) -> bool:
    with transaction() as conn:
        cur = conn.execute("DELETE FROM bookmarks WHERE id = ?", (bookmark_id,))
        return cur.rowcount > 0


def record_open(bookmark_id: int) -> None:
    """Bump the open count and last_opened_at timestamp."""
    now = int(time.time())
    get_conn().execute(
        "UPDATE bookmarks SET open_count = open_count + 1, last_opened_at = ? WHERE id = ?",
        (now, bookmark_id),
    )


def mark_checked(bookmark_id: int, *, is_dead: bool) -> None:
    """Update the liveness status of a bookmark after a HEAD check."""
    now = int(time.time())
    get_conn().execute(
        "UPDATE bookmarks SET is_dead = ?, last_checked_at = ? WHERE id = ?",
        (1 if is_dead else 0, now, bookmark_id),
    )


def unchecked_bookmarks(
    *,
    limit: int = 1000,
    older_than: int = 0,
    include_dead: bool = True,
) -> list[dict]:
    """Return bookmarks that haven't been checked in `older_than` seconds.

    `older_than=0` means "never checked". Useful for incremental sweeps.
    """
    conn = get_conn()
    cutoff = int(time.time()) - older_than
    if include_dead:
        sql = (
            "SELECT id, url FROM bookmarks "
            "WHERE last_checked_at IS NULL OR last_checked_at < ? "
            "ORDER BY last_checked_at ASC "
            "LIMIT ?"
        )
    else:
        sql = (
            "SELECT id, url FROM bookmarks "
            "WHERE is_dead = 0 AND (last_checked_at IS NULL OR last_checked_at < ?) "
            "ORDER BY last_checked_at ASC "
            "LIMIT ?"
        )
    rows = conn.execute(sql, (cutoff, limit)).fetchall()
    return [_row_to_dict(r) for r in rows]


# Sentinel for update_metadata: a parameter left at this default is not
# written — the column keeps its current value. Distinguishes "don't touch"
# from an explicit '' or NULL.
_UNSET = object()


def update_metadata(
    bookmark_id: int,
    *,
    title: object = _UNSET,
    description: object = _UNSET,
    favicon_url: object = _UNSET,
    domain: object = _UNSET,
    author: object = _UNSET,
    sitename: object = _UNSET,
    published_at: object = _UNSET,
    language: object = _UNSET,
    image_url: object = _UNSET,
    extracted_text: object = _UNSET,
) -> None:
    """Update a bookmark's metadata columns, touching only the ones given.

    Legacy callers pass ``title/description/favicon_url/domain``; the todo-16
    extraction paths (background enrichment task, backfill CLI) pass the
    article fields ``author/sitename/published_at/language/image_url/
    extracted_text``. The SET clause is built from the supplied keywords, so a
    partial update never clobbers the columns the caller did not mention.
    """
    sets: list[str] = []
    params: list[object] = []
    for column, value in (
        ("title", title),
        ("description", description),
        ("favicon_url", favicon_url),
        ("domain", domain),
        ("author", author),
        ("sitename", sitename),
        ("published_at", published_at),
        ("language", language),
        ("image_url", image_url),
        ("extracted_text", extracted_text),
    ):
        if value is not _UNSET:
            sets.append(f"{column} = ?")
            params.append(value)
    if not sets:
        return
    params.append(bookmark_id)
    get_conn().execute(
        f"UPDATE bookmarks SET {', '.join(sets)} WHERE id = ?", params
    )


def _is_str_list(value: object) -> TypeGuard[list[str]]:
    """Narrow an arbitrary value to a list of strings (boundary check)."""
    if not isinstance(value, list):
        return False
    return all(isinstance(v, str) for v in value)


def _set_bookmark_tags(conn: sqlite3.Connection, bookmark_id: int, tag_names: Sequence[str]) -> None:
    """Replace a bookmark's tags with exactly the given names.

    The caller's transaction owns the write. The provided list is
    authoritative: rows are deleted first, then each tag is upserted into
    ``tags`` and linked — a tag dropped from the list is unlinked. Same
    name-normalization (strip + lowercase, empty names skipped) as
    ``insert_bookmark``.
    """
    conn.execute("DELETE FROM bookmark_tags WHERE bookmark_id = ?", (bookmark_id,))
    for name in tag_names:
        name = name.strip().lower()
        if not name:
            continue
        conn.execute("INSERT OR IGNORE INTO tags(name) VALUES (?)", (name,))
        tag_id = conn.execute("SELECT id FROM tags WHERE name = ?", (name,)).fetchone()[0]
        conn.execute(
            "INSERT OR IGNORE INTO bookmark_tags(bookmark_id, tag_id) VALUES (?, ?)",
            (bookmark_id, tag_id),
        )


def update_bookmark(
    bookmark_id: int,
    *,
    note_body: object = _UNSET,
    title: object = _UNSET,
    tags: object = _UNSET,
    is_read: object = _UNSET,
) -> bool:
    """Partially update a bookmark (todo 17: note_body/title/tags/is_read).

    Sentinel-based like ``update_metadata``: a parameter left at ``_UNSET`` is
    not written. Every supplied field is applied in ONE ``BEGIN IMMEDIATE``
    transaction, so a multi-field PATCH is atomic. ``note_body`` re-syncs the
    ``links`` table (``links.sync_links`` — the same parse-on-save behavior as
    ``links.save_note``), and ``tags`` replaces the bookmark's full tag set.
    Returns False when the bookmark does not exist.
    """
    from app import links  # function-level: app.links imports app.db (cycle)

    sets: list[str] = []
    params: list[object] = []
    if note_body is not _UNSET:
        sets.append("note_body = ?")
        params.append(note_body)
    if title is not _UNSET:
        sets.append("title = ?")
        params.append(title)
    if is_read is not _UNSET:
        sets.append("is_read = ?")
        params.append(1 if is_read else 0)
    with transaction() as conn:
        if conn.execute("SELECT 1 FROM bookmarks WHERE id = ?", (bookmark_id,)).fetchone() is None:
            return False
        if sets:
            conn.execute(
                f"UPDATE bookmarks SET {', '.join(sets)} WHERE id = ?", [*params, bookmark_id]
            )
        if tags is not _UNSET:
            assert _is_str_list(tags)  # route-validated boundary; narrows object
            _set_bookmark_tags(conn, bookmark_id, tags)
        if note_body is not _UNSET:
            assert isinstance(note_body, str)  # route-validated boundary; narrows object
            links.sync_links(conn, bookmark_id, note_body)
    return True


# ---------------------------------------------------------------------------
# Inbox / saved-search helpers (todo 29). Saved searches are virtual
# collections — a name plus a stored search — never a folders hierarchy.
# ---------------------------------------------------------------------------


def create_saved_search(*, name: str, q: str = "", tags: Sequence[str] = ()) -> int:
    """Persist a named saved search and return its new id.

    ``q`` (the search string, possibly carrying ``is:unread``/``tag:``/``link:``
    operators) and ``tags`` (the explicit tag filter, serialized to
    ``tags_json``) are stored separately so the collections rail can apply
    either filter on its own. Blank tag names are dropped before storage.
    """
    now = int(time.time())
    tags_json = json.dumps([t for t in tags if t.strip()])
    with transaction() as conn:
        cur = conn.execute(
            "INSERT INTO saved_searches (name, q, tags_json, created_at) "
            "VALUES (?, ?, ?, ?) RETURNING id",
            (name.strip(), q, tags_json, now),
        )
        row = cur.fetchone()
        saved_id = int(row[0])
    return saved_id


def list_saved_searches() -> list[dict]:
    """Every saved search, newest first, with ``tags`` parsed back from
    ``tags_json`` so callers never touch the serialized form. A hand-edited /
    corrupt ``tags_json`` degrades to an empty tag list rather than a 500."""
    rows = get_conn().execute(
        "SELECT id, name, q, tags_json, created_at FROM saved_searches "
        "ORDER BY created_at DESC, id DESC"
    ).fetchall()
    items: list[dict] = []
    for row in rows:
        item = _row_to_dict(row)
        try:
            item["tags"] = json.loads(item.pop("tags_json"))
        except (TypeError, ValueError):
            item["tags"] = []
        items.append(item)
    return items


def delete_saved_search(saved_search_id: int) -> bool:
    """Delete a saved search. Returns False when the id does not exist."""
    with transaction() as conn:
        cur = conn.execute("DELETE FROM saved_searches WHERE id = ?", (saved_search_id,))
        return cur.rowcount > 0


def mark_all_above(above_id: int | None = None) -> int:
    """Mark unread bookmarks as read in ONE transaction (todo 29).

    Boundary semantics: "above" is a bookmark-id cursor. In the inbox view
    (sorted ``created_at DESC``, ids issued in insertion order) an item sits
    ABOVE another exactly when its id is higher, so ``above_id`` = the id of
    the last/oldest visible row means "everything newer than what I am
    looking at". The cursor row itself and everything below it stay unread.
    ``above_id=None`` marks every unread row. Returns the number flipped.
    """
    with transaction() as conn:
        if above_id is None:
            cur = conn.execute("UPDATE bookmarks SET is_read = 1 WHERE is_read = 0")
        else:
            cur = conn.execute(
                "UPDATE bookmarks SET is_read = 1 WHERE is_read = 0 AND id > ?",
                (above_id,),
            )
        return cur.rowcount


# ---------------------------------------------------------------------------
# Age-pruning suggestions (todo 30). Candidates are OLDER THAN N days
# (default 365) AND never opened (open_count = 0 AND last_opened_at IS NULL).
# The ``bookmarks`` base schema has always carried open_count/last_opened_at
# (record_open bumps both), so no migration was needed. Purely advisory:
# prune_apply() only ever runs on the user's explicit id list.
# ---------------------------------------------------------------------------

DEFAULT_PRUNE_AGE_DAYS = 365
_DAY_SECONDS = 86400


class PruneError(Exception):
    """A prune request the server rejects (client error -> HTTP 400)."""


def _row_snapshot(conn: sqlite3.Connection, row: sqlite3.Row) -> dict:
    """The full pre-delete state of one pruned bookmark: its complete row plus
    tags — the same payload shape dedup._bookmark_snapshot uses, so an undo
    could restore the row verbatim and re-link its tags."""
    tags = [
        r["name"]
        for r in conn.execute(
            "SELECT t.name FROM tags t JOIN bookmark_tags bt ON bt.tag_id = t.id "
            "WHERE bt.bookmark_id = ? ORDER BY t.name",
            (row["id"],),
        ).fetchall()
    ]
    return {"row": dict(row), "tags": tags}


def prune_candidates(*, older_than_days: int = DEFAULT_PRUNE_AGE_DAYS) -> list[dict]:
    """Bookmarks old enough and never opened — the age-pruning candidate list.

    A candidate satisfies BOTH criteria: ``created_at`` is strictly older than
    ``now - older_than_days`` days AND it was never opened
    (``open_count = 0 AND last_opened_at IS NULL``). Any open (``open_count >
    0`` or a set ``last_opened_at``) or any young row is excluded, so a
    recently-opened bookmark can never appear here. Returned oldest-first with
    ``{id, title, url, created_at, open_count, last_opened_at}``. Read-only —
    nothing is deleted.
    """
    cutoff = int(time.time()) - older_than_days * _DAY_SECONDS
    rows = get_conn().execute(
        "SELECT id, title, url, created_at, open_count, last_opened_at "
        "FROM bookmarks "
        "WHERE open_count = 0 AND last_opened_at IS NULL AND created_at < ? "
        "ORDER BY created_at ASC",
        (cutoff,),
    ).fetchall()
    return [_row_to_dict(r) for r in rows]


def prune_apply(ids: Sequence[int]) -> dict:
    """Delete EXACTLY the listed bookmark ids — user-confirmed, undo-able.

    Explicit user action only; this function is never called automatically. In
    a single ``BEGIN IMMEDIATE`` transaction it (a) reads the FULL pre-delete
    state of the listed rows (row + tags) and writes it to ``undo_snapshots``
    FIRST (the same payload shape as ``dedup.merge_bookmarks``, so a prune is
    as reversible as a merge), then (b) deletes ONLY those ids — ``bookmark_tags``
    and ``links`` rows cascade. Unlisted ids are never touched. Empty ``ids``
    raises :class:`PruneError` (mapped to 400). Returns
    ``{"snapshot_id", "deleted"}`` with the ids actually removed.
    """
    ids = sorted({int(i) for i in ids})
    if not ids:
        raise PruneError("ids must not be empty")
    with transaction() as conn:
        marks = ",".join("?" for _ in ids)
        rows = conn.execute(
            f"SELECT * FROM bookmarks WHERE id IN ({marks}) ORDER BY id", ids
        ).fetchall()
        # Snapshot FIRST so a failed delete can never orphan the ledger.
        payload = {"op": "prune", "pruned": [_row_snapshot(conn, row) for row in rows]}
        cur = conn.execute(
            "INSERT INTO undo_snapshots (payload_json, created_at) VALUES (?, ?)",
            (json.dumps(payload), int(time.time())),
        )
        snapshot_id = cur.lastrowid
        conn.execute(f"DELETE FROM bookmarks WHERE id IN ({marks})", ids)
    return {"snapshot_id": snapshot_id, "deleted": [r["id"] for r in rows]}


# ---------------------------------------------------------------------------
# Tag helpers
# ---------------------------------------------------------------------------


def get_tags_for_bookmark(bookmark_id: int) -> list[str]:
    rows = (
        get_conn()
        .execute(
            """
        SELECT t.name FROM tags t
        JOIN bookmark_tags bt ON bt.tag_id = t.id
        WHERE bt.bookmark_id = ?
        ORDER BY t.name
        """,
            (bookmark_id,),
        )
        .fetchall()
    )
    return [r["name"] for r in rows]


def all_tags() -> list[dict]:
    """Return every tag with its bookmark count, ordered by count desc."""
    rows = (
        get_conn()
        .execute(
            """
        SELECT t.name, COUNT(bt.bookmark_id) AS n
          FROM tags t
          LEFT JOIN bookmark_tags bt ON bt.tag_id = t.id
         GROUP BY t.id
         ORDER BY n DESC, t.name ASC
        """,
        )
        .fetchall()
    )
    return [_row_to_dict(r) for r in rows]


def bulk_add_tags(bookmark_ids: Iterable[int], tag_names: Iterable[str]) -> int:
    """Add tags to many bookmarks in one transaction. Creates tag rows on
    demand. Returns the number of (bookmark, tag) link rows newly inserted.
    """
    ids = list({int(i) for i in bookmark_ids})
    tag_list = [t.strip().lower() for t in tag_names if t.strip()]
    if not ids or not tag_list:
        return 0

    with transaction() as conn:
        conn.executemany(
            "INSERT OR IGNORE INTO tags(name) VALUES (?)",
            ((t,) for t in tag_list),
        )
        tag_id_by_name = {
            row["name"]: row["id"] for row in conn.execute("SELECT id, name FROM tags").fetchall()
        }
        pairs = [(bid, tag_id_by_name[t]) for bid in ids for t in tag_list if t in tag_id_by_name]
        # Count pre-existing rows so we can return the new-insertion count.
        before = conn.execute("SELECT COUNT(*) AS n FROM bookmark_tags").fetchone()["n"]
        conn.executemany(
            "INSERT OR IGNORE INTO bookmark_tags(bookmark_id, tag_id) VALUES (?, ?)",
            pairs,
        )
        after = conn.execute("SELECT COUNT(*) AS n FROM bookmark_tags").fetchone()["n"]
    return after - before


def bulk_add_tag_pairs(pairs: Iterable[tuple[int, str]]) -> int:
    """Insert (bookmark_id, tag_name) pairs precisely. Each pair becomes
    one (bookmark, tag) link row. Creates tag rows on demand. Returns the
    number of newly-inserted link rows.

    Use this when the pairing is data-driven (e.g. heuristic matches) and
    you don't want the cartesian product of (bookmarks x tags).
    """
    norm: list[tuple[int, str]] = [
        (int(bid), tn.strip().lower()) for bid, tn in pairs if tn and tn.strip()
    ]
    if not norm:
        return 0
    # Dedupe in-Python before hitting the DB.
    norm = list({(b, t) for b, t in norm})

    with transaction() as conn:
        unique_tag_names = {t for _, t in norm}
        conn.executemany(
            "INSERT OR IGNORE INTO tags(name) VALUES (?)",
            ((t,) for t in unique_tag_names),
        )
        tag_id_by_name = {
            row["name"]: row["id"] for row in conn.execute("SELECT id, name FROM tags").fetchall()
        }
        resolved = [(bid, tag_id_by_name[t]) for bid, t in norm if t in tag_id_by_name]
        before = conn.execute("SELECT COUNT(*) AS n FROM bookmark_tags").fetchone()["n"]
        conn.executemany(
            "INSERT OR IGNORE INTO bookmark_tags(bookmark_id, tag_id) VALUES (?, ?)",
            resolved,
        )
        after = conn.execute("SELECT COUNT(*) AS n FROM bookmark_tags").fetchone()["n"]
    return after - before


def remove_tag_from_bookmarks(bookmark_ids: Iterable[int], tag_name: str) -> int:
    """Remove a tag from all listed bookmarks. Returns the number of
    bookmark_tags rows deleted. The tag row itself is left in place."""
    tag = tag_name.strip().lower()
    if not tag:
        return 0
    ids = list(set(int(i) for i in bookmark_ids))
    if not ids:
        return 0
    placeholders = ",".join("?" for _ in ids)
    cur = get_conn().execute(
        f"DELETE FROM bookmark_tags "
        f"WHERE tag_id = (SELECT id FROM tags WHERE name = ?) "
        f"AND bookmark_id IN ({placeholders})",
        (tag, *ids),
    )
    return cur.rowcount


def bookmarks_with_tag(tag_name: str, *, limit: int = 100_000) -> list[dict]:
    """Return every bookmark that has the given tag."""
    conn = get_conn()
    rows = conn.execute(
        """
        SELECT b.* FROM bookmarks b
        JOIN bookmark_tags bt ON bt.bookmark_id = b.id
        JOIN tags t ON t.id = bt.tag_id
        WHERE t.name = ?
        ORDER BY b.created_at DESC
        LIMIT ?
        """,
        (tag_name.strip().lower(), limit),
    ).fetchall()
    return [_row_to_dict(r) for r in rows]


def generic_tag_candidates(*, min_count: int) -> list[dict]:
    """Return tags applied to ≥ min_count bookmarks. These are the buckets
    that benefit most from semantic re-tagging."""
    rows = (
        get_conn()
        .execute(
            """
        SELECT t.name, COUNT(bt.bookmark_id) AS n
          FROM tags t
          JOIN bookmark_tags bt ON bt.tag_id = t.id
         GROUP BY t.id
        HAVING n >= ?
         ORDER BY n DESC
        """,
            (min_count,),
        )
        .fetchall()
    )
    return [_row_to_dict(r) for r in rows]
