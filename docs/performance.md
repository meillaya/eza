# Performance

The benchmark measures the query layer against the reference database. It
opens `data/eza.db`, runs each query 20 times, and reports the average and p95
in milliseconds.

## Method

- CPU: AMD Ryzen 7 5700X, 8 cores and 16 threads
- Memory: 62 GiB
- Compiler: GHC 9.10.3, `-O1`
- Database: 8,988 bookmarks, 75 tags, 21,316 tag links, FTS5 enabled
- Command: `eza-bookmarks bench --iterations 20`
- Date: 2026-11-07

The benchmark source is [`server/src/Eza/Bench.hs`](../server/src/Eza/Bench.hs).
The database came from `bookmarks_14_08_2026.html`.

## Result

```
$ eza-bookmarks bench --iterations 20
iterations: 20
all: total=3.985609 avg_ms=2.96 p95_ms=3.99
fts-rust: total=0.849919 avg_ms=0.65 p95_ms=0.85
fts-github: total=1.532899 avg_ms=1.43 p95_ms=1.53
tag-imported: total=13.855065 avg_ms=13.34 p95_ms=13.86
tag-imported-books: total=9.596496 avg_ms=9.91 p95_ms=12.04
```

FTS queries stay below 1.6 ms at p95. Tag queries stay below 14 ms at p95.
The tag query materializes the filtered id set before ranking, which is the
larger cost.

Every list response now carries per year counts for the ledger. The query
groups the filtered rows by year and derives the total from the same scan, so a
page costs two scans instead of three. That work is what raises the `all` row
from the sub-millisecond range it held before the counts existed; the absolute
cost is under 4 ms at p95.

The import of the full export runs in about 2.5 to 3.0 seconds on the same
host. It writes 8,988 rows, 75 tags, and 21,316 links in one transaction.

## Limits

These numbers cover a library of 8,988 rows. The target for 10,000 rows is a
p95 below 30 ms for filtered searches, and the measured numbers remain below
that target. A 100,000-row run has not been measured.

## Next measurements

- A 100,000-row synthetic database to measure the 100 ms search budget.
- A join between the FTS rowid set and the tag subquery, measured with
  `EXPLAIN QUERY PLAN`, to replace the current `id IN (...)` path.
- Prepared bulk inserts in the importer to cut the import below 2 s.
- WASM bundle size and first interaction on a mid-range laptop; the current
  bundle is 3.4 MB raw and 0.9 MB gzipped.
