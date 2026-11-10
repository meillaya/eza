# Performance

The benchmark measures the read paths against a live-size copy of the library.
Every case is one or more reads; the benchmark never writes and never migrates
the database it opens.

## Method

- CPU: AMD Ryzen 7 5700X, 8 cores and 16 threads
- Memory: 62 GiB
- Compiler: GHC 9.10.3, `-O1`
- Database: 14,582 bookmarks, 76 tags, 27,843 tag links, FTS5 enabled, 8.7 MB
- Command: `eza-bookmarks bench --iterations 20`
- Date: 2026-11-08

The benchmark source is [`server/src/Eza/Bench.hs`](../server/src/Eza/Bench.hs).
The database is a scratch copy (`sqlite3 .backup`) of the owner's library; the
first open migrated it from schema v8 to v9 (115 ms including the verified
pre-migration backup and four index builds). The live database is untouched.

## Result

```
iterations: 20
all: total_ms=19.52 avg_ms=0.98 p50_ms=0.85 p95_ms=1.39 p99_ms=1.8 rows=60 bytes=17316
fts-rust: total_ms=15.19 avg_ms=0.76 p50_ms=0.73 p95_ms=0.92 p99_ms=1.0 rows=60 bytes=21659
fts-github: total_ms=36.17 avg_ms=1.81 p50_ms=1.76 p95_ms=2.0 p99_ms=2.35 rows=60 bytes=20786
tag-imported: total_ms=262.43 avg_ms=13.12 p50_ms=13.06 p95_ms=13.34 p99_ms=13.62 rows=60 bytes=18164
tag-imported-books: total_ms=200.8 avg_ms=10.04 p50_ms=9.74 p95_ms=11.15 p99_ms=11.81 rows=60 bytes=20966
all-page2: total_ms=5.14 avg_ms=0.26 p50_ms=0.24 p95_ms=0.33 p99_ms=0.49 rows=60 bytes=17471
boot-components: total_ms=275.36 avg_ms=13.77 p50_ms=13.53 p95_ms=15.36 p99_ms=18.66 rows=136 bytes=30064
library-stats: total_ms=164.31 avg_ms=8.22 p50_ms=7.92 p95_ms=10.48 p99_ms=10.91 rows=0 bytes=10293
all-tags: total_ms=87.07 avg_ms=4.35 p50_ms=4.3 p95_ms=4.55 p99_ms=4.58 rows=76 bytes=2455
autocomplete: total_ms=54.54 avg_ms=2.73 p50_ms=2.67 p95_ms=2.87 p99_ms=3.44 rows=10 bytes=2623
sort-opened: total_ms=16.11 avg_ms=0.81 p50_ms=0.78 p95_ms=0.99 p99_ms=1.12 rows=60 bytes=16279
unread-filter: total_ms=90.4 avg_ms=4.52 p50_ms=4.4 p95_ms=4.98 p99_ms=5.62 rows=60 bytes=17290
dedup-grouping: total_ms=361.63 avg_ms=18.08 p50_ms=14.31 p95_ms=33.01 p99_ms=55.64 rows=11290 bytes=1855247
dedup-candidates: total_ms=1046.14 avg_ms=52.31 p50_ms=51.21 p95_ms=62.52 p99_ms=67.21 rows=219 bytes=73271
```

What the cases measure:

- `all` and `all-page2`: one ledger page (list query plus its tag query) at
  offset 0 and 60. Year counts are part of the first page only; later pages
  derive the total from one count.
- `fts-rust`, `fts-github`: the FTS5 `MATCH` join, with the requested sort
  (the rank only separates text hits from tag-name fallback matches).
- `tag-imported`, `tag-imported-books`: the tag filter, still the most
  expensive list shape because the filtered id set is materialised before the
  year-count scan.
- `boot-components`: everything one boot request reads (list page, tags,
  library stats). The client now consumes the `bpInitial` page from this
  payload, so a cold load makes exactly one API request.
- `library-stats`: the 17-field `LibraryStats` from three statements. It was
  15.4 ms average with the previous one-query-per-figure implementation.
- `sort-opened`: the `last_opened_at` index path; the old `COALESCE(...)`
  expression could not use an index and cost about 10.4 ms.
- `dedup-grouping` and `dedup-candidates`: the whole-library canonical-URL
  grouping (11,290 records in groups before the cleanup below) and the first
  page of the duplicates view (60 URL + 40 title groups). The page fetch is
  bounded; counts come from the same grouping pass. After the cleanup the
  grouping drops to 11.1 ms average because 5,677 duplicate rows are gone.

## Graph

The `graph` case issues the four reads behind `GET /api/v1/graph`: tag counts,
every record, the tag memberships, and the resolved wikilinks. One payload is
about 950 KB of raw JSON, which the gzip middleware compresses like the other
JSON responses.

This run used the reference database `data/eza.db` (8,838 records, 77 tags,
21,848 tag links, 1 resolved wikilink) with
`eza-bookmarks bench --iterations 10`:

```
graph: total_ms=204.14 avg_ms=20.41 p50_ms=17.97 p95_ms=34.42 p99_ms=34.42 rows=8915 bytes=949888
```

`rows` counts the 8,838 records plus the 77 tags. Pan, zoom, and filtering
happen in the browser; the endpoint takes no parameters. The graph is a
read-only, whole-library request, so it is heavier than a ledger page and is
issued once per graph visit.

The cases above were measured on the 14,582-row scratch copy, not on this
8,838-record reference library, so the graph figures are not directly
comparable with that table.

The client side was profiled in headless Chromium at 1440x950 (dpr 1)
against a verified scratch copy of the reference library: 8,838 records, 77
tags, 21,848 tag memberships and 1 resolved wikilink. The profiling script is
ad-hoc; the committed `tests/e2e/graph-perf.mjs` measures a synthetic
9,000-record library, so the two do not produce identical numbers.

The first renderer drew visible primitives on every frame once the zoom passed
three times the fit scale. On the reference library that path cost 107.8 ms per
frame at 3.05x zoom (frame p95 133.5 ms) and 33.6 ms per frame at 7.45x, which
is the lag the whole-library plate showed when zoomed.

The current renderer keeps a cached whole-library bitmap for motion and builds
a screen-resolution detail plate after the view settles, at most 1,000
primitives per animation frame. The detail plate and the labels are not redrawn
per primitive while the reader drags or zooms, the settle work is split across
frames, and the old per-frame vector path is gone:

```
drag frames p50 / p95 / max, fit:            16.7 / 16.8 / 16.8 ms
drag frames p50 / p95 / max, 3.05x zoom:     16.7 / 16.8 / 33.4 ms
drag frames p50 / p95 / max, 7.45x zoom:     16.7 / 16.7 / 16.8 ms
detail plate completion after a stop:        about 31 frames at 3.05x
hover, 7.45x zoom:                     no frame above the 20 ms script pacing
filter apply:                                223 ms
tags toggle:                                 328 ms
cold plate, in-app:                        2,847 ms
cold plate, full reload:                   2,812 ms
```

The rare 33 ms frame is one detail chunk landing heavily while the plate
sharpens after the gesture; it is not part of the continuous pan or zoom path.
Filtering rebuilds no plate, only the accent overlay. The tags toggle rebuilds
the world bitmap once. Labels, hover emphasis and selection stay live overlays,
so they remain crisp at every scale.

Cold load is unchanged from the earlier harness runs: decoding the payload and
building the deterministic layout dominate, and the settled 1,500 ms budget for
the in-app cold plate is still missed on this library. The plate skeleton is
shown while that work runs. The full reload is within its separate 3,000 ms
budget.

### Layout endpoint

M1 moves the deterministic layout to the server:
`GET /api/v1/graph/layout?preset=compact|standard|airy` returns one preset's
node positions quantized to 1/100 world unit, and the client hydrates them
instead of rebuilding the layout when the layout revision matches its graph
payload. On the reference `data/eza.db` (8,838 records, 77 tags) the layout work
behind one preset, which is the build, the quantization and the JSON encoding,
averages 22.1 ms (p50 19.4 ms, p95 37.7 ms). Over HTTP a first request for one
preset takes 128-143 ms, which covers the session check, the graph read, the
layout build and the gzip. A cache hit takes 20-22 ms. The cache holds at most
three entries, one per preset for the current revision, so a repeat request at
the same revision reuses the positions and a library change invalidates all
three.

The graph payload is 1,002,873 bytes on this run; the earlier 949,888-byte
measurement predates the `is_dead` field on every record and the `revision`
field. The client compares that revision with the layout revision and falls
back to its local deterministic builder when they differ or when the request
fails.

## Import and duplicate cleanup

Both were measured on the scratch copy of the 14,582-row library.

The 2026-08-14 export (4,557,817 bytes, 9,457 anchors) imports in 2.4-2.5 s
wall time, of which about 2 s is parsing the HTML and 0.4 s is the write path.
The public reference result is unchanged: 8,905 rows, 74 tags, 9,016 links, 548
collapsed anchors. A second run takes 1.9 s and reports `inserted=0`,
`existing=8905`, `tag_links_added=0` - it matches by the canonical URL key
before writing and merely unions tags. The importer now inserts in chunks of
200 with one prepared statement per chunk and flushes every tag link once with
`executeMany`; it also appends an `import_runs` row.

`eza-bookmarks dedupe --all --yes` merged the library's 5,613 canonical-URL
groups (11,290 records) in 2.31 s, writing one 11,290-row `merge_all` undo
snapshot. A second run reports `groups=0` and writes no snapshot. The library
keeps 8,905 records and the advisory same-title groups (120 groups, 301
records) stay review-only.

Post-cleanup, on the 8,905-row copy: `all` 0.77/1.20 ms average/p95,
`boot-components` 9.86/11.49, `library-stats` 5.78/6.42,
`dedup-candidates` 42.62/45.91.

## Assets and HTTP

- `static/app/app.wasm` is 6,686,546 bytes raw and 1,540,229 bytes gzipped
  (4.3x). The server serves `<file>.gz` sidecars with `Content-Encoding: gzip`,
  `Vary: Accept-Encoding`, and the sidecar's ETag/304; `scripts/build-web.sh`
  writes sidecars for the WASM, CSS, shell, and loader JavaScript.
- Dynamic JSON/HTML responses are gzipped above 512 bytes by the WAI middleware
  (the setup page and boot payload drop to a fraction of their JSON size).
- The WASM loader fetches the precompressed asset; the service worker install
  revalidates the copy the page already fetched (a cheap 304 instead of a
  second full download). The client uses the boot payload instead of issuing a
  second list request; the ledger renders only the visible window plus
  overscan; scroll events are coalesced per animation frame.
- `libraryStats` runs three statements instead of sixteen, the boot payload is
  unchanged in shape, and a read-only connection pool serves GET/HEAD requests
  so a bulk merge or import does not stall browsing.

## Targets and limits

| Case | Target (p95) | Measured (p95) |
|---|---|---|
| ledger page, default | < 4 ms | 1.39 ms |
| ledger page, tag-filtered | < 15 ms | 13.34 ms |
| FTS search | < 3 ms | 2.35 ms |
| boot reads (list + tags + stats) | < 20 ms | 15.36 ms |
| library stats | < 11 ms | 10.48 ms |
| duplicates first page (60 + 40 groups) | < 150 ms | 62.52 ms |
| bulk merge, 11,290 records | seconds, one snapshot | 2.31 s, one snapshot |
| import 9,457 anchors | < 2.5 s | 2.4-2.5 s |
| WASM over the wire | <= 1.6 MB | 1.54 MB |

The tag-filtered list remains the slowest page shape because the filtered id
set is materialised before the year-count scan; the absolute cost is 13 ms and
is a candidate for a materialised tag/year set in a later change. Parsing is
now the dominant cost of an import (about 2 s of the 2.4 s); a streaming
Netscape parser is the next step. A 100,000-row run has not been measured; the
duplicate grouping is O(n log n) over a light scan and the first-page response
is constant-size, but boot and stats scaling past 14.5k should be measured
before claiming a 100k budget.
