# Import browser bookmarks

The importer reads two formats: the Netscape `bookmarks.html` export that
Firefox, Chromium, Safari, and browser-extension exporters write, and the
versioned eza JSON export written by `eza-bookmarks export --json` (or the
Account > About download links).

## Before you start

- Claim the first account at `/setup` (or create one with
  `eza-bookmarks users add`) before importing. An import into an installation
  with no accounts fails; 0.4 never falls back to the pre-0.4 flat `EZA_DB`
  file, so back that file up and import its HTML export instead.
- `eza-bookmarks init` is optional and only initialises the control schema.
- The server can stay running: the importer opens the same SQLite file and the
  one writer serialises the transaction with web requests. Stop the server only
  for a very large import if you want to keep latency predictable.
- Save the source file outside `EZA_DATA_DIR`; the importer reads it once.

## Run the import

```bash
eza-bookmarks import bookmarks.html > dist/import.json
```

The command exits 0 after the transaction commits. The report file contains the
same `ImportReport` JSON that the API returns. Run `eza-bookmarks verify` to
compare `bookmarks` and `bookmarks_fts`; it exits non-zero when the counts
differ.

For a portable archive, import an eza JSON export instead (CLI or the Account
> import panel, which accepts `.html` and `.json`):

```bash
eza-bookmarks import --json eza-export.json --user river > dist/import.json
```

The JSON format carries bookmarks, highlights (including their prefix/suffix
anchors), captures, saved searches, rules, views, and clip templates; webhook
secret rows are deliberately not exported. Version 1 exports are still
accepted.

A second run reports `inserted=0`, `existing=8905`, and
`tag_links_added=0`. The importer matches rows by a canonical key: the scheme
(http/https), a leading `www.`, default ports, fragments, tracking parameters,
and a trailing slash do not make a different source. The parser first collapses
same-key anchors inside the file, then `importParsed` checks the key against
every existing bookmark *before* it writes anything. A matched record gets the
imported tags unioned on, empty title/description fields filled in, and its
stored URL upgraded when the imported address is clearly better (https for
http, or a normalised form replacing a legacy URL). The same key is used by the
JSON API, quick-save and the browser clipper, so a page cannot be filed twice
through different capture paths. Each run also appends one `import_runs` row
with the report.

## Cleaning an existing library

Libraries imported before the canonical key existed (or from several
overlapping exports) can hold thousands of same-page records. The importer
never merges those automatically; the duplicates view and the CLI do it
explicitly:

```bash
eza-bookmarks dedupe --all --dry-run   # print exact group/record counts
eza-bookmarks dedupe --all --yes       # merge, one undo snapshot
```

The bulk merge covers same-URL duplicates only (http/https, `www.`, fragments,
tracking parameters, trailing slashes). Same-title matches on one source stay
review-only because different pages can share a title. One `merge_all` undo
snapshot covers the whole operation, so a single undo from Maintenance restores
every keeper and absorbed row with its tags, highlights and wikilinks. Stop the
server while it runs, as with a large import.

## Reference result

The 2026-08-14 export, imported with the default `leaf` tag mode, produces:

| Metric | Value |
|---|---|
| file size | 4,557,817 bytes |
| anchors | 9,457 |
| http(s) anchors | 9,453 |
| non-http anchors skipped | 4 |
| duplicate anchors collapsed | 548 |
| unique http(s) URLs | 8,905 |
| tags | 74 |
| bookmark-tag links | 9,016 |
| untagged bookmarks | 238 |
| folders skipped as noise | 57 |
| `ADD_DATE` range | 2022-08-07 to 2026-08-13 |

The tag counts depend on the selected mode. `path` produces more tag links;
`none` produces none. The historical 8,988-row reference database was imported
before normalized deduplication and before the leaf-only folder rule, so its
tag links (21,316) are not comparable with a fresh import.

## Conversion rules

Folder names become tags. The importer lowercases each tag and collapses
whitespace. `PERSONAL_TOOLBAR_FOLDER` becomes `toolbar`, and
`UNFILED_BOOKMARKS_FOLDER` becomes `unfiled`.

The default tag mode is `leaf`. A bookmark under `Dev/Haskell/Web` receives
`web`. Use `--tag-mode deepest` for the full folder path as one tag, `path`
for each ancestor path as a separate tag, or `none` to skip folder tags.

Noise folders are skipped by default: timestamp and date names, `New folder`
names, `temp`, `temp 2`, `/`, `1`, and a non-toolbar `Bookmarks bar`. The
wrapper names `imported`, `tabs`, and `imported sessions` are skipped only at
the top of the export, so the wrapper does not become a tag but a useful
folder nested below it remains. Pass `--keep-noise` to keep them.

The `TAGS="a,b"` attribute is unioned with the folder tags. A `<DD>`
description is imported into `description` when present. Duplicate URLs are
collapsed after normalization: the first non-empty title wins, the tag sets
are unioned, and the earliest `ADD_DATE` becomes `created_at`.

Imported rows are unread by default. Pass `--mark-read` to mark them read.
Newly inserted rows are queued for the background extraction worker, so titles,
metadata and the reading copy fill in without another command. If the worker is
disabled (`EZA_ENRICH_WORKERS=0`), run `eza-bookmarks enrich --all` (or
`enrich --limit N` for a first batch) when the server is stopped. Matched rows
that already existed keep their enrichment state.
