# Import browser bookmarks

The importer reads the Netscape `bookmarks.html` format that Firefox,
Chromium, Safari, and browser-extension exporters write.

## Before you start

- Initialise the database with `eza-bookmarks init`, or let the server create
  it on first start.
- Keep the server stopped while a large import runs. The importer opens the
  same SQLite file, and one writer keeps the transaction simple.
- Save the source file outside `EZA_DATA_DIR`; the importer reads it once.

## Run the import

```bash
eza-bookmarks import netscape bookmarks_14_08_2026.html \
  --report dist/import.json
```

The command exits 0 after the transaction commits. The report file contains the
same `ImportReport` JSON that the API returns. Run `eza-bookmarks verify` to
compare `bookmarks` and `bookmarks_fts`; it exits non-zero when the counts
differ.

A second run reports `inserted=0`, `existing=8988`, and
`tag_links_added=0`. The importer matches rows by normalized URL.

## Reference result

The 2026-08-14 export produced this result:

| Metric | Value |
|---|---|
| file size | 4,557,817 bytes |
| anchors | 9,457 |
| http(s) anchors | 9,453 |
| non-http anchors skipped | 4 |
| duplicate anchors collapsed | 465 |
| unique http(s) URLs | 8,988 |
| tags | 75 |
| bookmark-tag links | 21,316 |
| untagged bookmarks | 87 |
| folders skipped as noise | 56 |
| `ADD_DATE` range | 2022-08-07 to 2026-08-13 |

## Conversion rules

Folder names become tags. The importer lowercases each tag and collapses
whitespace. `PERSONAL_TOOLBAR_FOLDER` becomes `toolbar`, and
`UNFILED_BOOKMARKS_FOLDER` becomes `unfiled`.

The default tag mode is `leaf`. A bookmark under `Dev/Haskell/Web` receives
`web`. Use `--tag-mode deepest` for the full folder path, `path` for the
path segments as separate tags, or `none` to skip folder tags.

Noise folders are skipped by default: timestamp and date names, `New folder`
names, `temp`, `temp 2`, `/`, `1`, and a non-toolbar `Bookmarks bar`.
Pass `--keep-noise` to keep them.

The `TAGS="a,b"` attribute is unioned with the folder tags. Duplicate URLs
are collapsed: the first non-empty title wins, the tag sets are unioned, and
the earliest `ADD_DATE` becomes `created_at`.

Imported rows are unread by default. Pass `--mark-read` to mark them read.
The importer does not fetch pages or run extraction; use `enrich` or
`extract` after the import when you want that text.
