# Importing browser bookmarks

The importer accepts the Netscape `bookmarks.html` dialect written by Firefox,
Chromium, Safari, and browser-extension exporters.

```bash
eza-bookmarks import netscape bookmarks_14_08_2026.html --report dist/import.json
```

## Reference acceptance (2026-08-14 export)

| Metric | Value |
|---|---|
| file size | 4,557,817 bytes |
| anchors | 9,457 |
| http(s) anchors | 9,453 |
| non-http anchors skipped | 4 (3 `chrome:`, 1 `chrome-extension:`) |
| duplicate anchors collapsed | 465 |
| unique http(s) URLs | **8,988** |
| tags | **75** |
| bookmark-tag links | **21,316** |
| untagged | **87** |
| folders skipped as noise | 56 |
| ADD_DATE range | 2022-08-07 … 2026-08-13 |

A second run reports `inserted=0`, `existing=8988`, `tag_links_added=0`.

## Rules

- Folder names become tags (lowercased, whitespace-collapsed).
- `PERSONAL_TOOLBAR_FOLDER` becomes `toolbar`; `UNFILED_BOOKMARKS_FOLDER`
  becomes `unfiled`.
- Noise folders are skipped by default: timestamp/date names,
  `New folder …`, `temp`, `temp 2`, `/`, `1`, and a non-toolbar
  `Bookmarks bar`. `--keep-noise` keeps them.
- `TAGS="a,b"` attributes are unioned with folder tags.
- Duplicate URLs within the file are collapsed: first non-empty title wins,
  tags are unioned, and the earliest `ADD_DATE` becomes `created_at`.
- `created_at` is the original save date; `added_at` is the import time.
- Imported rows are unread by default (`--mark-read` to change) and are not
  fetched/extracted automatically (use `enrich`/`extract` explicitly).

Tag modes: `leaf` (default), `deepest`, `path` (hierarchical), `none`.
