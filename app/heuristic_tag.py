"""Heuristic domain-based tagger.

For each bookmark in a "fat" bucket (e.g. "imported"), look up the URL's
domain in a hand-tuned rules table and apply the resulting tag. No API
key, no model, no network calls — just a fast lookup.

The rules table is intentionally broad: a short URL like
`https://github.com/foo/bar` becomes "code", `https://arxiv.org/abs/...`
becomes "research-papers", etc. Anything not matched is left alone.

Tunables:
  - Add `DOMAIN_RULES` entries below — they win in priority order
    (longest / most specific match first).
  - Add `SUFFIX_RULES` for TLD-style matches like ".edu" → "academic".
"""

from __future__ import annotations

import argparse
import logging
import sys
import time
from collections.abc import Iterable
from urllib.parse import urlparse

from . import db

log = logging.getLogger("bookmarks.heuristic_tag")

# ---------------------------------------------------------------------------
# Domain rules
#
# Each entry is (host_pattern, tag). Patterns are matched as either:
#   - exact host (e.g. "github.com" matches "github.com", "www.github.com")
#   - host suffix (e.g. "github.com" matches "gist.github.com")
#
# Order matters: more specific patterns must come first so they win over
# broader matches.
# ---------------------------------------------------------------------------

DOMAIN_RULES: tuple[tuple[str, str], ...] = (
    # --- Code/dev (specific subdomains first) ---
    ("gist.github.com", "code"),
    ("raw.githubusercontent.com", "code"),
    ("docs.python.org", "code-python"),
    ("docs.rust-lang.org", "code-rust"),
    ("doc.rust-lang.org", "code-rust"),
    ("play.rust-lang.org", "code-rust"),
    ("crates.io", "code-rust"),
    ("godoc.org", "code"),
    ("pkg.go.dev", "code"),
    ("npmjs.com", "code"),
    ("pypi.org", "code-python"),
    ("hackage.haskell.org", "code"),
    ("leetcode.com", "code-practice"),
    ("hackerrank.com", "code-practice"),
    ("exercism.org", "code-practice"),
    ("codepen.io", "code"),
    ("replit.com", "code"),
    ("codesandbox.io", "code"),
    ("stackblitz.com", "code"),
    ("devdocs.io", "code-docs"),
    ("dev.to", "code"),
    ("huggingface.co", "code-ai"),
    ("exa.ai", "code-ai"),
    ("kaggle.com", "code-ai"),
    ("paperswithcode.com", "research-papers"),
    ("stackoverflow.com", "code-qa"),
    ("stackexchange.com", "code-qa"),
    ("superuser.com", "code-qa"),
    ("serverfault.com", "code-qa"),
    ("github.io", "code-pages"),
    ("github.com", "code"),
    ("gitlab.com", "code"),
    ("bitbucket.org", "code"),
    ("codeberg.org", "code"),
    ("sr.ht", "code"),
    ("gitea.com", "code"),
    ("sourcehut.org", "code"),
    ("git.sr.ht", "code"),
    ("notion.so", "notes"),
    ("obsidian.md", "notes"),
    ("hackernoon.com", "tech-writing"),
    # --- News ---
    ("nytimes.com", "news"),
    ("theguardian.com", "news"),
    ("bbc.com", "news"),
    ("bbc.co.uk", "news"),
    ("washingtonpost.com", "news"),
    ("wsj.com", "news"),
    ("latimes.com", "news"),
    ("economist.com", "news"),
    ("bloomberg.com", "news"),
    ("ft.com", "news"),
    ("reuters.com", "news"),
    ("apnews.com", "news"),
    ("ap.org", "news"),
    ("cnn.com", "news"),
    ("npr.org", "news"),
    ("theintercept.com", "news"),
    ("vice.com", "news"),
    ("vox.com", "news"),
    ("politico.com", "news"),
    ("thehill.com", "news"),
    ("foreignaffairs.com", "news"),
    ("axios.com", "news"),
    ("motherjones.com", "news"),
    ("thenation.com", "news"),
    ("jacobinmag.com", "news"),
    ("newrepublic.com", "news"),
    ("prospect.org", "news"),
    # --- Tech media ---
    ("theverge.com", "tech"),
    ("arstechnica.com", "tech"),
    ("techcrunch.com", "tech"),
    ("wired.com", "tech"),
    ("news.ycombinator.com", "tech"),
    ("theregister.com", "tech"),
    ("zdnet.com", "tech"),
    ("cnet.com", "tech"),
    ("engadget.com", "tech"),
    ("macrumors.com", "tech"),
    ("9to5mac.com", "tech"),
    ("9to5google.com", "tech"),
    ("arstechnica.co.uk", "tech"),
    ("tomshardware.com", "tech"),
    ("anandtech.com", "tech"),
    ("simonwillison.net", "tech"),
    ("lwn.net", "tech"),
    ("search.brave.com", "tech"),
    ("duckduckgo.com", "tech"),
    ("mozilla.org", "tech"),
    # --- Research / academic ---
    ("arxiv.org", "research-papers"),
    ("scholar.google.com", "research-papers"),
    ("pubmed.ncbi.nlm.nih.gov", "research-papers"),
    ("semanticscholar.org", "research-papers"),
    ("openreview.net", "research-papers"),
    ("researchgate.net", "research-papers"),
    ("jstor.org", "research-papers"),
    ("nature.com", "research-papers"),
    ("science.org", "research-papers"),
    ("sciencedirect.com", "research-papers"),
    ("acm.org", "research-papers"),
    ("ieee.org", "research-papers"),
    ("tandfonline.com", "research-papers"),
    ("brill.com", "research-papers"),
    ("cambridge.org", "research-papers"),
    ("oxfordacademic.com", "research-papers"),
    ("springer.com", "research-papers"),
    ("wiley.com", "research-papers"),
    ("link.springer.com", "research-papers"),
    ("ncbi.nlm.nih.gov", "research-papers"),
    ("biorxiv.org", "research-papers"),
    ("medrxiv.org", "research-papers"),
    # --- Books (literary / publishing / library) ---
    ("goodreads.com", "books"),
    ("literal.club", "books"),
    ("bookshop.org", "books"),
    ("librarything.com", "books"),
    ("openlibrary.org", "books"),
    ("lareviewofbooks.org", "books"),
    ("theparisreview.org", "books"),
    ("lrb.co.uk", "books"),
    ("bookforum.com", "books"),
    ("nybooks.com", "books"),
    ("tls.co.uk", "books"),
    ("versobooks.com", "books"),
    ("haymarketbooks.org", "books"),
    ("dukeupress.edu", "books"),
    ("e-flux.com", "books-arts"),
    ("newleftreview.org", "books"),
    ("clereviewofbooks.com", "books"),
    ("socratesonthebeach.com", "books"),
    ("palimas.org", "books"),
    ("biblioklept.org", "books"),
    ("roughghosts.com", "books"),
    ("memoryoftheworld.org", "books"),
    ("library.memoryoftheworld.org", "books"),
    ("storygraph.com", "books"),
    ("thestorygraph.com", "books"),
    # --- Film ---
    ("letterboxd.com", "film"),
    ("imdb.com", "film"),
    ("rottentomatoes.com", "film"),
    ("mubi.com", "film"),
    ("themoviedb.org", "film"),
    ("vulture.com", "film"),
    ("indiewire.com", "film"),
    # --- Music ---
    ("bandcamp.com", "music"),
    ("soundcloud.com", "music"),
    ("spotify.com", "music"),
    ("pitchfork.com", "music"),
    ("genius.com", "music"),
    ("discogs.com", "music"),
    ("rateyourmusic.com", "music"),
    # --- Design ---
    ("dribbble.com", "design"),
    ("behance.net", "design"),
    ("are.na", "design"),
    ("figma.com", "design"),
    ("awwwards.com", "design"),
    ("typewolf.com", "design"),
    ("fonts.google.com", "design"),
    ("thenounproject.com", "design"),
    # --- Reference ---
    ("wikipedia.org", "reference"),
    ("wolframalpha.com", "reference"),
    ("britannica.com", "reference"),
    ("archive.org", "archive"),
    ("web.archive.org", "archive"),
    # --- Social ---
    ("twitter.com", "social"),
    ("x.com", "social"),
    ("reddit.com", "social"),
    ("old.reddit.com", "social"),
    ("threads.net", "social"),
    ("instagram.com", "social"),
    ("bsky.app", "social"),
    ("mastodon.social", "social"),
    ("tumblr.com", "social"),
    ("linkedin.com", "social"),
    ("linktr.ee", "social"),
    # --- Shopping ---
    ("amazon.com", "shopping"),
    ("amazon.co.uk", "shopping"),
    ("ebay.com", "shopping"),
    ("etsy.com", "shopping"),
    # --- Video ---
    ("youtube.com", "video"),
    ("youtu.be", "video"),
    ("vimeo.com", "video"),
    ("tiktok.com", "video"),
    ("twitch.tv", "video"),
    # --- Games ---
    ("store.steampowered.com", "games"),
    ("steamcommunity.com", "games"),
    ("gog.com", "games"),
    ("humblebundle.com", "games"),
    ("itch.io", "games"),
    ("nexusmods.com", "games"),
    ("overframe.gg", "games"),
    ("cs.rin.ru", "games"),
    # --- Anime / visual novels ---
    ("9anime.to", "anime"),
    ("myanimelist.net", "anime"),
    ("anilist.co", "anime"),
    ("f95zone.to", "games"),
    # --- Adult (lumped so it doesn't pollute other categories) ---
    ("rule34video.com", "adult"),
    ("rule34video.party", "adult"),
    ("missav123.com", "missav"),  # sub-bucket; treat as adult
    ("missav.com", "adult"),
    # --- Cloud storage / docs ---
    ("drive.google.com", "cloud-storage"),
    ("docs.google.com", "docs"),
    ("dropbox.com", "cloud-storage"),
    ("mega.nz", "cloud-storage"),
    # --- Writing / publishing ---
    ("medium.com", "writing"),
    ("substack.com", "writing"),
    ("ghost.org", "writing"),
    # --- Tools / misc ---
    ("search.brave.com", "tech"),
    ("chromewebstore.google.com", "tools"),
    # --- Marxism / theory (saw marxists.org in data) ---
    ("marxists.org", "marxism"),
)


# TLD-style suffix rules — checked against the registered domain.
SUFFIX_RULES: tuple[tuple[str, str], ...] = (
    (".edu", "academic"),
    (".ac.uk", "academic"),
    (".ac.jp", "academic"),
    (".gov", "government"),
    (".gov.uk", "government"),
    (".go.jp", "government"),
    (".github.io", "code-pages"),
)


# ---------------------------------------------------------------------------
# Matcher
# ---------------------------------------------------------------------------


def _strip_www(host: str) -> str:
    return host[4:] if host.startswith("www.") else host


def _registered_domain(host: str) -> str:
    """Best-effort registered-domain extraction (last two labels)."""
    parts = host.split(".")
    if len(parts) <= 2:
        return host
    # Handle common 2-part TLDs (.co.uk, .ac.uk, .com.au, ...)
    sld_two = {
        "co.uk",
        "ac.uk",
        "co.jp",
        "ac.jp",
        "go.uk",
        "go.jp",
        "com.au",
        "co.nz",
        "co.in",
        "co.kr",
    }
    last_two = ".".join(parts[-2:])
    last_three = ".".join(parts[-3:])
    if len(parts) >= 3 and last_two in sld_two:
        # e.g. bbc.co.uk → bbc.co.uk
        return last_three if ".".join(parts[-3:]).endswith(last_two) else last_two
    return last_two


def match_domain(url: str) -> str | None:
    """Return a heuristic tag for `url`, or None if no rule matches."""
    host = _strip_www(urlparse(url).netloc.lower())
    if not host:
        return None

    # 1. Exact match (incl. specific subdomains like docs.google.com)
    for pattern, tag in DOMAIN_RULES:
        if host == pattern:
            return tag

    # 2. Suffix match against the full host (catches subdomains)
    for pattern, tag in DOMAIN_RULES:
        if host.endswith("." + pattern):
            return tag

    # 3. TLD / SLD-based rules (e.g. ".edu" → "academic", ".gov.uk" → "government")
    for pattern, tag in SUFFIX_RULES:
        if host.endswith(pattern):
            return tag
        # Bare-domain match: e.g. "gov.uk" (after www strip) vs ".gov.uk"
        if host == pattern.lstrip("."):
            return tag

    return None


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------


def _apply_matches(
    *,
    by_tag: dict[str, list[dict]],
    dry_run: bool,
) -> int:
    """Insert one (bookmark, tag) row per matched bookmark — the heuristic
    is precise per-bookmark, so we tag only what we know fits.

    Returns the number of new link rows inserted.
    """
    if dry_run:
        return sum(len(v) for v in by_tag.values())
    # Build the (bookmark_id, tag_name) pairs.
    pairs: list[tuple[int, str]] = [
        (b["id"], t) for t, bookmarks in by_tag.items() for b in bookmarks
    ]
    return db.bulk_add_tag_pairs(pairs)


def _remove_generic_from_matched(
    *,
    tag_name: str,
    by_tag: dict[str, list[dict]],
    dry_run: bool,
) -> int:
    """Remove the generic tag from every matched bookmark only — leave the
    unmatched ones holding the generic tag so they're still findable."""
    if dry_run:
        return sum(len(v) for v in by_tag.values())
    ids = [b["id"] for bookmarks in by_tag.values() for b in bookmarks]
    return db.remove_tag_from_bookmarks(ids, tag_name)


def heuristic_tag_buckets(
    *,
    targets: Iterable[str],
    min_count: int,
    remove_generic: bool,
    dry_run: bool,
) -> list[dict]:
    target_list = [t.strip() for t in targets if t.strip()] if targets else []
    if target_list:
        buckets = [{"name": t, "n": -1} for t in target_list]
    else:
        buckets = db.generic_tag_candidates(min_count=min_count)

    if not buckets:
        log.info("no buckets matched criteria (min_count=%d)", min_count)
        return []

    log.info("processing %d bucket(s)", len(buckets))
    results: list[dict] = []
    for b in buckets:
        tag_name = str(b["name"])
        bookmarks = db.bookmarks_with_tag(tag_name)
        if not bookmarks:
            log.info("  %r: empty, skipping", tag_name)
            continue

        # Bucket bookmarks by their heuristic tag, drop unmatched.
        by_tag: dict[str, list[dict]] = {}
        for bm in bookmarks:
            ht = match_domain(bm["url"])
            if ht:
                by_tag.setdefault(ht, []).append(bm)

        matched_count = sum(len(v) for v in by_tag.values())
        unmatched_count = len(bookmarks) - matched_count
        log.info(
            "  %r: %d bookmark(s) → matched %d across %d tag(s) (%d unmatched)",
            tag_name,
            len(bookmarks),
            matched_count,
            len(by_tag),
            unmatched_count,
        )

        if not by_tag:
            results.append(
                {
                    "tag": tag_name,
                    "bookmarks_in_bucket": len(bookmarks),
                    "matched": 0,
                    "added_tags": [],
                    "dry_run": dry_run,
                }
            )
            continue

        links_added = _apply_matches(by_tag=by_tag, dry_run=dry_run)
        result = {
            "tag": tag_name,
            "bookmarks_in_bucket": len(bookmarks),
            "matched_count": matched_count,
            "added_tags": sorted(by_tag),
            "links_added": links_added,
            "dry_run": dry_run,
        }
        if remove_generic:
            removed = _remove_generic_from_matched(
                tag_name=tag_name, by_tag=by_tag, dry_run=dry_run
            )
            result["removed_generic"] = True
            result["links_removed"] = removed
        result["breakdown"] = {
            t: len(v) for t, v in sorted(by_tag.items(), key=lambda kv: -len(kv[1]))
        }
        results.append(result)
    return results


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Apply domain-based heuristic tags to bookmarks in fat buckets.",
    )
    g = parser.add_mutually_exclusive_group()
    g.add_argument(
        "--target",
        action="append",
        default=[],
        help="Specific tag to process. Repeatable. Default: any tag with ≥ --threshold bookmarks.",
    )
    g.add_argument("--all-above", type=int, metavar="N", help="Process tags with ≥ N bookmarks.")
    parser.add_argument("--threshold", type=int, default=500)
    parser.add_argument("--remove-generic", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("-v", "--verbose", action="store_true")
    return parser.parse_args(list(argv))


def main(argv: Iterable[str] | None = None) -> int:
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    targets = args.target or []
    if not targets and args.all_above is None:
        bucket_min = args.threshold
    elif args.all_above is not None:
        bucket_min = args.all_above
    else:
        bucket_min = 0

    started = time.monotonic()
    results = heuristic_tag_buckets(
        targets=targets,
        min_count=bucket_min,
        remove_generic=args.remove_generic,
        dry_run=args.dry_run,
    )
    elapsed = time.monotonic() - started

    log.info("--- summary ---")
    for r in results:
        log.info("%s", r)
    log.info("done in %.2fs", elapsed)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
