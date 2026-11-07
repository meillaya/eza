# Performance notes

Measured on the imported 2026-08-14 export (8,988 bookmarks, 75 tags,
21,316 bookmark-tag rows) with the native GHC 9.10 build:

```
$ eza-bookmarks bench --iterations 20
iterations: 20
all: total=0.671238 avg_ms=0.38 p95_ms=0.67
fts-rust: total=0.855758 avg_ms=0.58 p95_ms=0.86
fts-github: total=1.189957 avg_ms=1.1 p95_ms=1.19
tag-imported: total=11.18985 avg_ms=10.36 p95_ms=12.15
tag-imported-books: total=9.375713 avg_ms=9.29 p95_ms=9.52
```

The tag queries are the slowest because they materialize the filtered id set
before ranking; they are still comfortably under the 30 ms p95 target at 10k.
FTS queries are sub-2 ms.

Import of the full export takes ~2.5-3.0 s (single transaction, 9k rows +
21k tag links) on this machine. A second import is idempotent and inserts 0.

Planned optimizations:

- FTS + tag filters: join the FTS rowid set against the tag subquery instead of
  using `id IN (…)`, and measure with `EXPLAIN QUERY PLAN`.
- Bulk import: `withStatement`/prepared inserts (currently each row is an
  `INSERT` plus a `SELECT id` for existing URLs).
- 100k synthetic benchmark to keep the 100 ms search budget honest.

Client budgets: keep the WASM bundle under ~2.5 MB gzipped; the virtualized
grid renders at most ~100 cards regardless of library size.
