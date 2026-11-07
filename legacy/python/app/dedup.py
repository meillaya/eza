"""Duplicate-candidate detection engine (todo 25).

Three independent signals feed candidate groups:

1. **URL normalization** — :func:`normalize_url` lowercases the host, strips
   a leading ``www.``, strips a trailing ``/`` and any ``#fragment``, drops
   tracking params (``utm_*``, ``fbclid``, ``gclid``), keeps every other
   query param, and sorts the survivors. Two bookmarks whose normalized URLs
   are identical are candidates regardless of title.
2. **Redirect-final recording** — :func:`fetch_final_url` follows redirects
   (mirroring ``check_dead``'s HEAD-then-ranged-GET semantics) and returns the
   final URL. :func:`record_final_url` / :func:`backfill_final_urls` populate
   the todo-14 ``final_url`` column (empty string = no known redirect). The
   candidates grouping uses ``final_url or url`` as the effective URL, so two
   bookmarks that both redirect to the same page group even when their stored
   URLs differ.
3. **Fuzzy title** — RapidFuzz ``WRatio`` ≥ 85 (:data:`FUZZY_TITLE_THRESHOLD`)
   groups bookmarks within the same normalized domain.

The candidate engine is strictly read-only: it produces candidate groups,
never merges, never deletes. Todo 26 adds the user-confirmed, undo-able merge
(:func:`merge_bookmarks` / :func:`undo_merge`) — the one explicit carve-out
from "no destructive changes": it never runs without explicit user action,
rejects cross-domain merges, and writes every pre-merge state to
``undo_snapshots`` so a merge is always reversible.

The backfill CLI is deliberately bounded (``--limit``) and marker-resumable,
the same shape as ``bookmarks-backfill-extract``:

    uv run python -m app.dedup --limit 500
    uv run python -m app.dedup --limit 500 --marker /tmp/finalurl.marker
"""

# allow: SIZE_OK — pre-existing monolithic dedup module (>250 LOC before todo
# 26, single coherent engine: URL normalize + fuzzy grouping + redirect-final
# backfill + merge/undo). Splitting would stage new modules outside each todo's
# commit contract (app/dedup.py only); the todo-26 merge section is
# self-contained below.

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sqlite3
import sys
import time
from collections.abc import Iterable
from pathlib import Path
from typing import TypedDict
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

import httpx
from rapidfuzz import fuzz

from . import config, db

log = logging.getLogger("bookmarks.dedup")

FUZZY_TITLE_THRESHOLD = 85.0

# Query params that are pure tracking noise — dropped by normalize_url.
_TRACKING_PARAM_NAMES = frozenset({"fbclid", "gclid"})

DEFAULT_BACKFILL_LIMIT = 500
_READ_TIMEOUT = 8.0

_USER_AGENT = "bookmarks/0.1 dedup-backfill (+https://github.com/local/bookmarks)"


# ---------------------------------------------------------------------------
# URL normalization
# ---------------------------------------------------------------------------


def _is_tracking_param(name: str) -> bool:
    """True for utm_* params and the two social-trackers we always drop."""
    lowered = name.lower()
    return lowered.startswith("utm_") or lowered in _TRACKING_PARAM_NAMES


def _normalize_query(query: str) -> str:
    """Drop tracking params, sort the rest by (key, value)."""
    kept = [
        (k, v)
        for k, v in parse_qsl(query, keep_blank_values=True)
        if not _is_tracking_param(k)
    ]
    kept.sort()
    return urlencode(kept)


def normalize_url(url: str) -> str:
    """Canonical form of a URL for dedup comparison.

    Lowercases the host, strips a leading ``www.``, strips a trailing ``/``,
    drops the ``#fragment``, drops tracking params (``utm_*``/``fbclid``/
    ``gclid``), keeps every other query param and sorts them. Ports are kept.
    Non-http(s) URLs (and anything urlsplit can't host-parse) are returned
    unchanged — there is nothing canonical to derive.
    """
    parts = urlsplit(url)
    if parts.scheme.lower() not in ("http", "https"):
        return url
    host = (parts.hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    netloc = host
    if parts.port is not None:
        netloc = f"{host}:{parts.port}"
    path = parts.path.rstrip("/")
    query = _normalize_query(parts.query)
    return urlunsplit((parts.scheme.lower(), netloc, path, query, ""))


def normalized_domain(url: str) -> str:
    """The www-stripped, lowercased host of ``url`` (no scheme/path/query)."""
    return urlsplit(normalize_url(url)).netloc


# ---------------------------------------------------------------------------
# Fuzzy title matching
# ---------------------------------------------------------------------------


def titles_match(a: str, b: str) -> bool:
    """True when RapidFuzz WRatio(a, b) >= FUZZY_TITLE_THRESHOLD.

    WRatio mixes ratio/partial/token scorers, so word-order and suffix
    differences ("The Complete Guide to Docker" vs "Complete Guide to Docker")
    score high while unrelated titles stay far below the threshold.
    """
    return fuzz.WRatio(a, b) >= FUZZY_TITLE_THRESHOLD


# ---------------------------------------------------------------------------
# Candidate groups
# ---------------------------------------------------------------------------


class _UnionFind:
    """Union-find over bookmark indices (path compression + union by rank)."""

    __slots__ = ("parent", "rank")

    def __init__(self, n: int) -> None:
        self.parent = list(range(n))
        self.rank = [0] * n

    def find(self, x: int) -> int:
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union(self, a: int, b: int) -> None:
        ra, rb = self.find(a), self.find(b)
        if ra == rb:
            return
        if self.rank[ra] < self.rank[rb]:
            ra, rb = rb, ra
        self.parent[rb] = ra
        if self.rank[ra] == self.rank[rb]:
            self.rank[ra] += 1


def _member_reason(
    member: _BookmarkRow,
    canonical: _BookmarkRow,
    norm_member: str,
    norm_canonical: str,
) -> str:
    """Why ``member`` sits in the canonical's group: "url" when the normalized
    URLs are identical, "title" when the titles fuzzy-match, else "related"
    (a transitive link through another member)."""
    if norm_member == norm_canonical:
        return "url"
    if member["title"] and canonical["title"] and titles_match(
        member["title"], canonical["title"]
    ):
        return "title"
    return "related"


class _BookmarkRow(TypedDict):
    """The bookmark columns find_candidates reads from the DB."""

    id: int
    url: str
    title: str
    final_url: str
    created_at: int


class _Member(TypedDict):
    id: int
    title: str
    url: str
    reason: str


class _Canonical(TypedDict):
    id: int
    title: str
    url: str


class _Group(TypedDict):
    canonical: _Canonical
    members: list[_Member]
    count: int


def find_candidates(conn: sqlite3.Connection | None = None) -> dict[str, list[_Group]]:
    """Return ``{"groups": [...]}`` of duplicate-candidate bookmarks.

    A group is a connected component of bookmarks where each pair is linked by
    an identical normalized URL OR by a title WRatio ≥ 85 within the same
    normalized domain. The canonical ("best") row is the oldest-created one
    (tie-break: lowest id) — the conservative original a user would keep.
    Members carry ``{id, title, url, reason}`` and ``count`` is the total
    group size (canonical + members). Groups are sorted by count desc, then
    canonical url, then canonical id. Read-only: no merges, no deletes.

    ``conn`` defaults to the module reader connection; pass a copy connection
    to inspect a snapshot.
    """
    conn = conn or db.get_conn()
    rows: list[_BookmarkRow] = [
        {
            "id": r["id"],
            "url": r["url"],
            "title": r["title"],
            "final_url": r["final_url"],
            "created_at": r["created_at"],
        }
        for r in conn.execute(
            "SELECT id, url, title, final_url, created_at FROM bookmarks ORDER BY id"
        ).fetchall()
    ]
    n = len(rows)
    norms = [normalize_url(r["final_url"] or r["url"]) for r in rows]
    domains = [urlsplit(norm).netloc for norm in norms]

    uf = _UnionFind(n)

    # 1. Identical normalized URLs → one component per bucket.
    by_norm: dict[str, list[int]] = {}
    for i, norm in enumerate(norms):
        by_norm.setdefault(norm, []).append(i)
    for bucket in by_norm.values():
        first = bucket[0]
        for other in bucket[1:]:
            uf.union(first, other)

    # 2. Fuzzy title within the same normalized domain.
    by_domain: dict[str, list[int]] = {}
    for i, dom in enumerate(domains):
        if dom:
            by_domain.setdefault(dom, []).append(i)
    for bucket in by_domain.values():
        if len(bucket) < 2:
            continue
        for a_pos in range(len(bucket)):
            i = bucket[a_pos]
            if not rows[i]["title"]:
                continue
            for b_pos in range(a_pos + 1, len(bucket)):
                j = bucket[b_pos]
                if norms[i] == norms[j]:
                    continue  # already url-grouped
                if not rows[j]["title"]:
                    continue
                if titles_match(rows[i]["title"], rows[j]["title"]):
                    uf.union(i, j)

    # 3. Assemble components of size >= 2.
    components: dict[int, list[int]] = {}
    for i in range(n):
        components.setdefault(uf.find(i), []).append(i)

    groups: list[_Group] = []
    for members in components.values():
        if len(members) < 2:
            continue
        canonical_i = min(members, key=lambda i: (rows[i]["created_at"], i))
        canonical = rows[canonical_i]
        out_members: list[_Member] = []
        for m in sorted(m for m in members if m != canonical_i):
            row = rows[m]
            out_members.append(
                {
                    "id": row["id"],
                    "title": row["title"],
                    "url": row["url"],
                    "reason": _member_reason(row, canonical, norms[m], norms[canonical_i]),
                }
            )
        groups.append(
            {
                "canonical": {
                    "id": canonical["id"],
                    "title": canonical["title"],
                    "url": canonical["url"],
                },
                "members": out_members,
                "count": len(members),
            }
        )

    groups.sort(key=lambda g: (-g["count"], g["canonical"]["url"], g["canonical"]["id"]))
    return {"groups": groups}


# ---------------------------------------------------------------------------
# Confirm-and-undo merge (todo 26)
#
# The one explicit carve-out from "no destructive changes": a merge only ever
# runs on explicit user action, is guarded against cross-domain mixes, and
# writes the FULL pre-merge state to undo_snapshots so undo restores it.
# ---------------------------------------------------------------------------


class MergeError(Exception):
    """A merge request the server rejects (client error -> HTTP 400)."""


class UndoError(Exception):
    """An undo request that has no snapshot to consume (-> HTTP 404)."""


def _set_tags(conn: sqlite3.Connection, bookmark_id: int, tag_names: Iterable[str]) -> None:
    """Replace a bookmark's tag links with exactly the given names.

    Mirrors ``db._set_bookmark_tags`` (same name-normalization, ``tags`` rows
    upserted on demand) but lives here so the merge/undo transaction owns its
    writes without reaching into db's private helpers. Callers must already
    hold a write transaction.
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


def _bookmark_snapshot(conn: sqlite3.Connection, row: sqlite3.Row) -> dict:
    """The full pre-merge state of one bookmark: its complete row + tags.

    ``note_body`` lives inside ``row``, so a discarded note (the
    NOTE-COLLISION RULE) is captured here and undo restores it verbatim.
    """
    tags = [
        r["name"]
        for r in conn.execute(
            "SELECT t.name FROM tags t JOIN bookmark_tags bt ON bt.tag_id = t.id "
            "WHERE bt.bookmark_id = ? ORDER BY t.name",
            (row["id"],),
        ).fetchall()
    ]
    return {"row": dict(row), "tags": tags}


def _repoint_links(
    conn: sqlite3.Connection, keep_id: int, merge_ids: list[int]
) -> None:
    """Re-point every ``links`` row mentioning a merge row onto ``keep_id``.

    The affected set is every row whose source OR target is a group member.
    Each row is re-mapped source/target onto ``keep_id`` where it names a merge
    row; rows that would become self-links (a merge row linking to the keep,
    or the keep linking to a merge row) are dropped; rows that would collide
    on ``UNIQUE(source_id, target_id, line_number)`` are deduped in
    deterministic (row-id) order. The affected rows are then deleted and the
    survivors re-inserted with ``INSERT OR IGNORE`` so any survivor that still
    collides with a group-external row is silently dropped rather than raised.
    """
    group = [keep_id, *merge_ids]
    marks = ",".join("?" for _ in group)
    rows = [
        dict(r)
        for r in conn.execute(
            "SELECT id, source_id, target_id, target_title, display_text, line_number "
            f"FROM links WHERE source_id IN ({marks}) OR target_id IN ({marks})",
            (*group, *group),
        ).fetchall()
    ]
    merge_set = set(merge_ids)
    survivors: list[tuple[int, int | None, str, str | None, int | None]] = []
    seen: set[tuple[int, int | None, int | None]] = set()
    for row in sorted(rows, key=lambda r: r["id"]):
        new_source = keep_id if row["source_id"] in merge_set else row["source_id"]
        new_target = keep_id if row["target_id"] in merge_set else row["target_id"]
        if new_source == new_target:
            continue  # would become a self-link: drop
        target_title = (
            "" if new_target is not None and new_target != row["target_id"] else row["target_title"]
        )
        key = (new_source, new_target, row["line_number"])
        if key in seen:
            continue
        seen.add(key)
        survivors.append(
            (new_source, new_target, target_title, row["display_text"], row["line_number"])
        )
    if rows:
        id_marks = ",".join("?" for _ in rows)
        conn.execute(
            f"DELETE FROM links WHERE id IN ({id_marks})", [r["id"] for r in rows]
        )
    conn.executemany(
        "INSERT OR IGNORE INTO links "
        "(source_id, target_id, target_title, display_text, line_number)"
        " VALUES (?, ?, ?, ?, ?)",
        survivors,
    )


def merge_bookmarks(keep_id: int, merge_ids: Iterable[int]) -> dict:
    """Merge ``merge_ids`` into ``keep_id`` — one user-confirmed transaction.

    Explicit user action only; this function is never called automatically. In
    a single ``BEGIN IMMEDIATE`` transaction it: (a) unions the merge rows'
    tags onto keep (deduped), (b) adopts a merge note only when keep has none —
    on a collision KEEP wins and the discarded note lives inside the snapshot
    payload, (c) re-points ``links`` rows onto keep, (d) deletes the merge
    rows, and (e) writes the full pre-merge state to ``undo_snapshots`` for
    :func:`undo_merge`. Empty ``merge_ids`` and any cross-domain merge
    (normalized-domain equality) are rejected. Returns
    ``{"snapshot_id", "kept", "merged"}``.
    """
    ids = sorted({int(i) for i in merge_ids})
    if not ids:
        raise MergeError("merge_ids must not be empty")
    if keep_id in ids:
        raise MergeError("keep_id cannot be merged into itself")
    with db.transaction() as conn:
        keep_row = conn.execute("SELECT * FROM bookmarks WHERE id = ?", (keep_id,)).fetchone()
        if keep_row is None:
            raise MergeError(f"keep bookmark {keep_id} does not exist")
        merge_rows: list[sqlite3.Row] = []
        for mid in ids:
            row = conn.execute("SELECT * FROM bookmarks WHERE id = ?", (mid,)).fetchone()
            if row is None:
                raise MergeError(f"merge bookmark {mid} does not exist")
            merge_rows.append(row)
        keep_domain = normalized_domain(keep_row["url"])
        for row in merge_rows:
            if normalized_domain(row["url"]) != keep_domain:
                raise MergeError("cannot merge bookmarks from different domains")

        # Full pre-merge state for the undo ledger, written BEFORE any change
        # so a failed merge can never orphan a snapshot.
        keep_snapshot = _bookmark_snapshot(conn, keep_row)
        merged_snapshots = [_bookmark_snapshot(conn, row) for row in merge_rows]
        group = [keep_id, *ids]
        marks = ",".join("?" for _ in group)
        links = [
            dict(r)
            for r in conn.execute(
                "SELECT source_id, target_id, target_title, display_text, line_number "
                f"FROM links WHERE source_id IN ({marks}) OR target_id IN ({marks}) "
                "ORDER BY id",
                (*group, *group),
            ).fetchall()
        ]
        payload = {
            "keep_id": keep_id,
            "merge_ids": ids,
            "keep": keep_snapshot,
            "merged": merged_snapshots,
            "links": links,
        }
        cur = conn.execute(
            "INSERT INTO undo_snapshots (payload_json, created_at) VALUES (?, ?)",
            (json.dumps(payload), int(time.time())),
        )
        snapshot_id = cur.lastrowid

        union = sorted(set(keep_snapshot["tags"]).union(*(m["tags"] for m in merged_snapshots)))
        _set_tags(conn, keep_id, union)

        # NOTE-COLLISION RULE: keep wins — a merge note is adopted only when
        # keep has none. Discarded notes live in the snapshot payload.
        if not (keep_row["note_body"] or "").strip():
            for snapshot in merged_snapshots:
                note = snapshot["row"]["note_body"] or ""
                if note.strip():
                    conn.execute(
                        "UPDATE bookmarks SET note_body = ? WHERE id = ?", (note, keep_id)
                    )
                    break

        _repoint_links(conn, keep_id, ids)
        id_marks = ",".join("?" for _ in ids)
        conn.execute(f"DELETE FROM bookmarks WHERE id IN ({id_marks})", ids)
    return {"snapshot_id": snapshot_id, "kept": keep_id, "merged": ids}


def undo_merge(snapshot_id: int | None = None) -> dict:
    """Pop the latest undo snapshot and restore the merged state.

    Restores keep's pre-merge note/tags, re-inserts every merged bookmark with
    its original row/tags/note (the discarded note included), restores the
    full pre-merge ``links`` neighborhood, then consumes the snapshot. With no
    snapshot available (or a nonexistent ``snapshot_id``) raises
    :class:`UndoError`, which the API maps to 404. Returns
    ``{"snapshot_id", "kept", "restored"}``.
    """
    with db.transaction() as conn:
        if snapshot_id is None:
            snap = conn.execute(
                "SELECT id, payload_json FROM undo_snapshots ORDER BY id DESC LIMIT 1"
            ).fetchone()
        else:
            snap = conn.execute(
                "SELECT id, payload_json FROM undo_snapshots WHERE id = ?", (snapshot_id,)
            ).fetchone()
        if snap is None:
            raise UndoError("No merge to undo")
        payload = json.loads(snap["payload_json"])
        keep_id = payload["keep_id"]
        merge_ids = payload["merge_ids"]
        if conn.execute("SELECT 1 FROM bookmarks WHERE id = ?", (keep_id,)).fetchone() is None:
            raise UndoError("keep bookmark is gone; cannot undo")

        # Bookmarks first (their links/tags reference them via FKs), then the
        # mutable state, then the links neighborhood.
        for snapshot in payload["merged"]:
            row = snapshot["row"]
            columns = list(row.keys())
            column_list = ",".join(columns)
            placeholders = ",".join("?" for _ in columns)
            conn.execute(
                f"INSERT INTO bookmarks ({column_list}) VALUES ({placeholders})",
                [row[column] for column in columns],
            )
            _set_tags(conn, row["id"], snapshot["tags"])

        keep_snapshot = payload["keep"]
        conn.execute(
            "UPDATE bookmarks SET note_body = ? WHERE id = ?",
            (keep_snapshot["row"]["note_body"], keep_id),
        )
        _set_tags(conn, keep_id, keep_snapshot["tags"])

        # Restore the pre-merge links neighborhood: delete the current set for
        # the whole group, then re-insert the snapshot's original rows.
        group = [keep_id, *merge_ids]
        marks = ",".join("?" for _ in group)
        conn.execute(
            f"DELETE FROM links WHERE source_id IN ({marks}) OR target_id IN ({marks})",
            (*group, *group),
        )
        for link in payload["links"]:
            conn.execute(
                "INSERT OR IGNORE INTO links "
                "(source_id, target_id, target_title, display_text, line_number)"
                " VALUES (?, ?, ?, ?, ?)",
                (
                    link["source_id"],
                    link["target_id"],
                    link["target_title"],
                    link["display_text"],
                    link["line_number"],
                ),
            )

        conn.execute("DELETE FROM undo_snapshots WHERE id = ?", (snap["id"],))
    return {"snapshot_id": snap["id"], "kept": keep_id, "restored": merge_ids}


# ---------------------------------------------------------------------------
# Redirect-final recording (mirrors check_dead's fetch semantics)
# ---------------------------------------------------------------------------


async def fetch_final_url(
    client: httpx.AsyncClient, url: str
) -> str | None:
    """Follow redirects and return the final URL, or None when dead.

    Mirrors ``check_dead._check_one``: HEAD first (httpx follows redirects
    when the client has ``follow_redirects=True``), falling back to a ranged
    GET on 405/403 (servers that reject HEAD). Returns ``str(resp.url)`` — the
    post-redirect URL — or None on 4xx/5xx/timeout/unreachable.
    """
    try:
        resp = await client.head(url)
        if resp.status_code >= 400:
            return None
        if resp.status_code in (405, 403) and "content-length" not in resp.headers:
            get_resp = await client.get(url, headers={"Range": "bytes=0-0"})
            if get_resp.status_code >= 400:
                return None
            return str(get_resp.url)
        return str(resp.url)
    except (httpx.HTTPError, TimeoutError):
        return None


async def record_final_url(
    client: httpx.AsyncClient, bookmark_id: int, url: str
) -> str | None:
    """Follow redirects for one bookmark and record the redirect-final URL.

    Writes the todo-14 ``final_url`` column ONLY when a real redirect exists
    (final != stored url) — a row that doesn't redirect keeps ``final_url``
    empty. Returns the recorded final URL, or None when dead or non-redirecting.
    """
    final = await fetch_final_url(client, url)
    if final is not None and final != url:
        db.get_conn().execute(
            "UPDATE bookmarks SET final_url = ? WHERE id = ?", (final, bookmark_id)
        )
        return final
    return None


def _default_marker() -> Path:
    return Path(str(config.BOOKMARKS_DB) + ".finalurl-marker")


def _read_marker(path: Path) -> int:
    try:
        return int(path.read_text(encoding="utf-8").strip())
    except (FileNotFoundError, ValueError):
        return 0


def _write_marker(path: Path, value: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(str(value), encoding="utf-8")


def _unprocessed(conn: sqlite3.Connection, after_id: int, limit: int) -> list[dict]:
    rows = conn.execute(
        "SELECT id, url FROM bookmarks WHERE final_url = '' AND id > ? ORDER BY id LIMIT ?",
        (after_id, limit),
    ).fetchall()
    return [dict(r) for r in rows]


async def backfill_final_urls(
    *,
    limit: int = DEFAULT_BACKFILL_LIMIT,
    marker_path: Path | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
) -> dict:
    """Backfill ``final_url`` for up to ``limit`` rows after the marker.

    Bounded by ``limit`` (never a full sweep by accident) and resumable via a
    marker file (``<db>.finalurl-marker``) exactly like
    ``bookmarks-backfill-extract``. Only rows with an empty ``final_url`` are
    picked, so interrupted runs are safe to resume. Returns
    ``{"checked": n, "updated": n, "marker": last_id}``. ``transport`` is a
    test seam (httpx MockTransport) and defaults to a real network client.
    """
    marker = marker_path or _default_marker()
    last_id = _read_marker(marker)
    rows = _unprocessed(db.get_conn(), last_id, limit)
    if not rows:
        return {"checked": 0, "updated": 0, "marker": last_id}

    timeout = httpx.Timeout(connect=3.0, read=_READ_TIMEOUT, write=3.0, pool=3.0)
    client_kwargs: dict = {
        "timeout": timeout,
        "follow_redirects": True,
        "headers": {"User-Agent": _USER_AGENT},
        "http2": False,
    }
    if transport is not None:
        client_kwargs["transport"] = transport

    updated = 0
    async with httpx.AsyncClient(**client_kwargs) as client:
        for row in rows:
            final = await fetch_final_url(client, row["url"])
            if final is not None and final != row["url"]:
                db.get_conn().execute(
                    "UPDATE bookmarks SET final_url = ? WHERE id = ?",
                    (final, row["id"]),
                )
                updated += 1

    new_marker = rows[-1]["id"]
    _write_marker(marker, new_marker)
    log.info("dedup backfill: %d checked, %d redirected, marker now %d", len(rows), updated, new_marker)
    return {"checked": len(rows), "updated": updated, "marker": new_marker}


def _parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python -m app.dedup",
        description="Backfill redirect-final URLs into final_url (bounded, "
        "marker-resumable). Never touches the live DB unless pointed at it.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=DEFAULT_BACKFILL_LIMIT,
        help="max rows to process per run (default %(default)s)",
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
    result = asyncio.run(
        backfill_final_urls(limit=args.limit, marker_path=args.marker)
    )
    log.info("done: %s", result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
