"""Tag consolidation engine (todo 27).

Three advisory candidate signals plus user-confirmed mutations:

1. **Case duplicates** — tag names that differ only by case ("Music"/"music").
   The all-lowercase variant (when present) is the merge target; otherwise the
   more-populated tag wins.
2. **Fuzzy pairs** — RapidFuzz ``WRatio`` >= 85 on tag names (mirroring
   ``dedup.FUZZY_TITLE_THRESHOLD``). The merge target is the tag applied to
   more bookmarks — the conservative "merge the smaller into the bigger"
   direction. Pairs that differ only by case are excluded (signal 1 owns
   them).
3. **Junk tags** — names in ``auto_tag``'s stopword set (REUSED, never
   duplicated) plus pure-noise heuristics: all-digits, single-character, or a
   first word that is a stopword ("temp 2" -> "temp").

Tag-proliferation stats report the total tag count and how many tags sit on
<= 3 bookmarks (the long-tail the linkwarden research flagged: ~84% of tags on
<= 3 links).

The candidate engine is strictly read-only. Mutations are explicit user
actions only — ``merge_tags`` (rewrite ``bookmark_tags`` from -> to, delete the
now-empty from row; merging to a NONEXISTENT tag creates it, so no data is ever
lost), ``rename_tag`` (non-empty, collision-checked), and ``delete_tag`` (an
empty tag only — a non-empty tag must be merged or unlinked first). There is
no background/automatic merge anywhere.

Module choice: a dedicated module rather than growing ``app/db.py`` (already
~1270 LOC) — the same split ``app/dedup.py`` established for the dedup engine.
"""

from __future__ import annotations

import re
import sqlite3
from collections.abc import Sequence
from typing import TypedDict

from rapidfuzz import fuzz

from . import auto_tag, db

FUZZY_TAG_THRESHOLD = 85.0

# auto_tag's stopword set is the single source of truth for "never useful"
# tags — import, never duplicate (a duplicate would silently drift apart).
_STOPWORDS = auto_tag._DEFAULT_STOPWORDS

_DIGITS_RE = re.compile(r"^\d+$")


class TagCleanupError(Exception):
    """A tag-consolidation request the server rejects (client error -> 400)."""


class TagNotFoundError(TagCleanupError):
    """A tag id that does not exist (-> 404)."""


class _Tag(TypedDict):
    """One tag row with its bookmark count."""

    id: int
    name: str
    n: int


# Callable-form TypedDicts: the API contract keys include the reserved word
# ``from``, which the class syntax cannot spell as an attribute name.
_CasePair = TypedDict("_CasePair", {"from": str, "to": str, "from_count": int, "to_count": int})
_FuzzyPair = TypedDict(
    "_FuzzyPair",
    {"from": str, "to": str, "score": int, "from_count": int, "to_count": int},
)


class _JunkTag(TypedDict):
    """A junk-tag candidate with the id the UI needs for rename/delete."""

    id: int
    name: str
    n: int


def _all_tags(conn: sqlite3.Connection) -> list[_Tag]:
    """Every tag row with its bookmark count, ordered by name."""
    rows = conn.execute(
        """
        SELECT t.id, t.name, COUNT(bt.bookmark_id) AS n
          FROM tags t
          LEFT JOIN bookmark_tags bt ON bt.tag_id = t.id
         GROUP BY t.id
         ORDER BY t.name
        """
    ).fetchall()
    return [{"id": r["id"], "name": r["name"], "n": r["n"]} for r in rows]


def _case_pairs(tags: Sequence[_Tag]) -> list[_CasePair]:
    """Case-duplicate pairs: tags whose names differ only by case.

    The merge target is the all-lowercase variant when present (the canonical
    spelling the rest of the app writes); otherwise the more-populated tag.
    """
    by_lower: dict[str, list[_Tag]] = {}
    for t in tags:
        by_lower.setdefault(t["name"].lower(), []).append(t)
    pairs: list[_CasePair] = []
    for bucket in by_lower.values():
        if len(bucket) < 2:
            continue
        canonical = next((t for t in bucket if t["name"] == t["name"].lower()), None)
        if canonical is None:
            canonical = max(bucket, key=lambda t: (t["n"], t["name"]))
        for t in bucket:
            if t["name"] != canonical["name"]:
                pairs.append(
                    {
                        "from": t["name"],
                        "to": canonical["name"],
                        "from_count": t["n"],
                        "to_count": canonical["n"],
                    }
                )
    pairs.sort(key=lambda p: (p["from"].lower(), p["from"]))
    return pairs


def _fuzzy_pairs(tags: Sequence[_Tag]) -> list[_FuzzyPair]:
    """WRatio >= 85 tag-name pairs, excluding pure case duplicates.

    ``to`` is the more-populated tag (tie-break: lexicographically smaller),
    so an applied merge folds the smaller bucket into the bigger one.
    """
    pairs: list[_FuzzyPair] = []
    for i in range(len(tags)):
        a = tags[i]
        for b in tags[i + 1 :]:
            if a["name"].lower() == b["name"].lower():
                continue  # case pair — signal 1 owns it
            score = fuzz.WRatio(a["name"], b["name"])
            if score < FUZZY_TAG_THRESHOLD:
                continue
            frm, to = a, b
            if a["n"] > b["n"] or (a["n"] == b["n"] and a["name"] < b["name"]):
                frm, to = b, a
            pairs.append(
                {
                    "from": frm["name"],
                    "to": to["name"],
                    "score": round(score),
                    "from_count": frm["n"],
                    "to_count": to["n"],
                }
            )
    pairs.sort(key=lambda p: (-p["score"], p["from"], p["to"]))
    return pairs


def _is_junk_name(name: str) -> bool:
    """Junk-tag classification: auto_tag stopwords + pure-noise heuristics."""
    if name in _STOPWORDS:
        return True
    if _DIGITS_RE.match(name):
        return True
    if len(name) == 1:
        return True
    return name.split()[0] in _STOPWORDS


def _junk_tags(tags: Sequence[_Tag]) -> list[_JunkTag]:
    """Junk-tag candidates (name + id + count), most-populated first."""
    junk: list[_JunkTag] = [
        {"id": t["id"], "name": t["name"], "n": t["n"]} for t in tags if _is_junk_name(t["name"])
    ]
    junk.sort(key=lambda j: (-j["n"], j["name"]))
    return junk


def _proliferation(tags: Sequence[_Tag]) -> dict:
    """Tag-proliferation stats: total count + tags sitting on <= 3 bookmarks."""
    return {"count": len(tags), "tags_on_le_3": sum(1 for t in tags if t["n"] <= 3)}


def consolidation_candidates(conn: sqlite3.Connection | None = None) -> dict:
    """Return every tag-consolidation signal in one read-only pass.

    Shape: ``{"case_pairs": [{from, to, from_count, to_count}],
    "fuzzy_pairs": [{from, to, score, from_count, to_count}],
    "junk_tags": [{id, name, n}], "proliferation": {count, tags_on_le_3}}``.

    Strictly advisory — nothing is merged, renamed or deleted here; every
    mutation goes through the explicit ``merge_tags``/``rename_tag``/
    ``delete_tag`` entry points. ``conn`` defaults to the module reader
    connection; pass a copy connection to inspect a snapshot.
    """
    conn = conn or db.get_conn()
    tags = _all_tags(conn)
    return {
        "case_pairs": _case_pairs(tags),
        "fuzzy_pairs": _fuzzy_pairs(tags),
        "junk_tags": _junk_tags(tags),
        "proliferation": _proliferation(tags),
    }


def merge_tags(from_name: str, to_name: str) -> dict:
    """Merge tag ``from_name`` into ``to_name`` — one explicit transaction.

    Rewrites every ``bookmark_tags`` link from the from-tag onto the to-tag
    (deduping via the composite primary key), then deletes the now-empty
    from-tag row. Merging to a tag that does not exist CREATES it — defined
    behavior, so a rename-by-merge never loses data. ``from == to``, empty
    names and a nonexistent ``from`` are rejected with :class:`TagCleanupError`
    (client error -> 400). Returns ``{"from", "to", "bookmarks_affected",
    "tag_created"}``. Never called automatically — explicit user action only.
    """
    frm = from_name.strip()
    to = to_name.strip()
    if not frm or not to:
        raise TagCleanupError("from and to must be non-empty tag names")
    if frm == to:
        raise TagCleanupError("cannot merge a tag into itself")
    with db.transaction() as conn:
        from_row = conn.execute("SELECT id FROM tags WHERE name = ?", (frm,)).fetchone()
        if from_row is None:
            raise TagCleanupError(f"tag {frm!r} does not exist")
        from_id = from_row["id"]
        to_row = conn.execute("SELECT id FROM tags WHERE name = ?", (to,)).fetchone()
        if to_row is None:
            conn.execute("INSERT INTO tags(name) VALUES (?)", (to,))
            to_id = conn.execute("SELECT id FROM tags WHERE name = ?", (to,)).fetchone()["id"]
            created = True
        else:
            to_id = to_row["id"]
            created = False
        # INSERT OR IGNORE dedupes against existing to-tag links via the
        # (bookmark_id, tag_id) primary key.
        cur = conn.execute(
            "INSERT OR IGNORE INTO bookmark_tags (bookmark_id, tag_id) "
            "SELECT bookmark_id, ? FROM bookmark_tags WHERE tag_id = ?",
            (to_id, from_id),
        )
        affected = cur.rowcount
        conn.execute("DELETE FROM bookmark_tags WHERE tag_id = ?", (from_id,))
        conn.execute("DELETE FROM tags WHERE id = ?", (from_id,))
    return {"from": frm, "to": to, "bookmarks_affected": affected, "tag_created": created}


def rename_tag(tag_id: int, new_name: str) -> dict:
    """Rename a tag (non-empty name; collision with an existing name rejected).

    A nonexistent tag raises :class:`TagNotFoundError` (-> 404); an empty or
    colliding name raises :class:`TagCleanupError` (-> 400). Returns
    ``{"id", "name"}``.
    """
    name = new_name.strip()
    if not name:
        raise TagCleanupError("tag name must not be empty")
    with db.transaction() as conn:
        row = conn.execute("SELECT id FROM tags WHERE id = ?", (tag_id,)).fetchone()
        if row is None:
            raise TagNotFoundError(f"tag {tag_id} does not exist")
        if conn.execute(
            "SELECT 1 FROM tags WHERE name = ? AND id != ?", (name, tag_id)
        ).fetchone():
            raise TagCleanupError(f"tag {name!r} already exists")
        conn.execute("UPDATE tags SET name = ? WHERE id = ?", (name, tag_id))
    return {"id": tag_id, "name": name}


def delete_tag(tag_id: int) -> dict:
    """Delete a tag row — ONLY when it is empty (no ``bookmark_tags`` rows).

    A non-empty tag raises :class:`TagCleanupError` -> 400 (documented: merge
    or unlink it first — silently dropping live links would lose data); a
    nonexistent tag raises :class:`TagNotFoundError` -> 404. Returns
    ``{"ok": True, "id": tag_id}``.
    """
    with db.transaction() as conn:
        row = conn.execute("SELECT id FROM tags WHERE id = ?", (tag_id,)).fetchone()
        if row is None:
            raise TagNotFoundError(f"tag {tag_id} does not exist")
        n = conn.execute(
            "SELECT COUNT(*) AS n FROM bookmark_tags WHERE tag_id = ?", (tag_id,)
        ).fetchone()["n"]
        if n > 0:
            raise TagCleanupError(
                f"tag {tag_id} is not empty ({n} bookmark(s)); merge or unlink it first"
            )
        conn.execute("DELETE FROM tags WHERE id = ?", (tag_id,))
    return {"ok": True, "id": tag_id}
