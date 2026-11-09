# Screenshots

The screenshots come from the real server and the built WASM client, against a
scratch copy of the live library (9,226 entries, 4,521 sources, 79 tags, filed
since 2022.08.07). They are not mockups and no record is invented for the
pictures. The detail and share shots use a real record with real extracted text
and the note and marks the capture script adds; the note is visible on the share
page. The figure counts change as the library grows, so a new set can show
different numbers.

The set is sixteen PNGs at 1440 pixels wide with a device pixel ratio of 2, in
eight light and dark pairs. Every shot is 1440x900 except the cropped accessions
pair (1440x561). Every screen is captured twice with the application's own
theme switch (the nav control on application screens, `window.EzaTheme.set` on
the server-rendered pages), so the dark files show the reading-room theme as
the application renders it, not a CSS override. The accessions pair is cropped
above the ranked-source list so private sources do not appear in the public
image:

| File | Screen |
|---|---|
| `library.png`, `library-dark.png` | the ledger under a real `tag:literature` query, masthead counting the whole library |
| `detail.png`, `detail-dark.png` | bookmark 18311, its reading spread and its marks |
| `accessions.png`, `accessions-dark.png` | the printed index figures and filing days, without source names |
| `palette.png`, `palette-dark.png` | the command palette over that filtered ledger |
| `graph.png`, `graph-dark.png` | the local wikilink graph around the record the note links to (1,151 records in view) |
| `views.png`, `views-dark.png` | the views page: views are data, with import, export, duplicate and delete |
| `share.png`, `share-dark.png` | a server-rendered read-only share page for bookmark 18311, note included |
| `login.png`, `login-dark.png` | the password sign-in card, no session |

## Capture a new set

1. Initialise a clean capture database (a fresh import keeps the provenance
   line exact) and start a scratch server on it. Run these commands from
   `devenv shell`:

   ```
   EZA_DATA_DIR=.eza-scratch-shots EZA_DB=.eza-scratch-shots/eza.db \
     cabal run eza-bookmarks -- init
   EZA_DATA_DIR=.eza-scratch-shots EZA_DB=.eza-scratch-shots/eza.db \
   EZA_STATIC_DIR=static EZA_BIND=127.0.0.1:8100 \
   PUBLIC_ORIGIN=http://localhost:8100 EZA_RP_ID=localhost \
   cabal run eza-bookmarks -- serve
   ```

2. Run the tracked capture script against it from the same shell:

   ```
   EZA_BASE=http://localhost:8100 EZA_DB=.eza-scratch-shots/users/1/eza.db \
   EZA_TEST_USER=design EZA_TEST_PASSWORD=design-pass-123 \
   EZA_SHOT_QUERY="tag:literature" EZA_FEATURE_ID=18311 \
   EZA_SEED_IMPORT=/path/to/bookmarks_14_08_2026.html \
     node tests/e2e/capture-screenshots.mjs
   ```

   The script signs in (or claims the instance when no password exists yet),
   imports the export when `EZA_SEED_IMPORT` points at one, then writes the
   eight light and dark pairs into `docs/screenshots/`. It captures every
   screen on the same page state in both themes, using the real theme control.
   Set `CHROME_PATH` when the installed Playwright browser build differs from
   the one the installed Playwright package expects.

   The checked-in set was captured from a scratch copy of the live library
   instead of a fresh import. Back up the databases with `eza-bookmarks
   backup` (or `sqlite3 SRC ".backup DEST"`), point the copied control row at
   the copied library, set a known password with `eza-bookmarks users
   reset-password <name> --password-stdin`, then run the script with
   `EZA_SEED_IMPORT=0` and `EZA_TEST_USER`/`EZA_TEST_PASSWORD` for that
   account. The checked-in run used the same tracked script with those
   environment values, so the committed PNGs and the script describe the same
   procedure. The figures in the pictures are the live library figures either
   way.

   The committed ledger shots use `EZA_SHOT_QUERY="tag:literature"`: the
   newest rows are forum and video saves, so a query gives a representative
   slice while the masthead still counts the whole library.
   The export itself is private and is not checked in; point
   `EZA_SEED_IMPORT` at it, or let the script fall back to the demo set.

3. Look at the sixteen PNGs before committing them.

   `EZA_FEATURE_ID` selects the record used for the detail and share shots and
   the focus of the graph shot. The checked-in set uses `18311`, "What's the
   Point If We Can't Have Fun?" from The Baffler, a real essay with clean
   extracted text. Enrich the chosen record first if a fresh scratch database
   has no extracted text:

   ```
   EZA_DATA_DIR=.eza-scratch-shots cabal run eza-bookmarks -- \
     enrich --user <account> --id 18311
   ```

## What the script seeds

The script claims a scratch account with a username and password when the
instance is unclaimed, or signs into the account named by `EZA_TEST_USER` and
`EZA_TEST_PASSWORD`. It then POSTs a local `bookmarks.html` export as multipart
form data to `/api/v1/import`. When the export is missing or
`EZA_SEED_IMPORT=0` is set it keeps the library already on the server, and only
falls back to a 14-bookmark demo set when that library has fewer than 14
entries.

The detail shot uses the record named by `EZA_FEATURE_ID` and its real
enrichment output. It waits for extraction, then adds a note and up to three
highlights through the public API so the reading window shows marks. Existing
highlights are left alone, so a re-run does not duplicate them. The note links
to a real record found by a library search, and the graph shot focuses that
same record, so the detail and graph pairs tell one story. The share shot is
captured in both themes from the same server-rendered page.
An explicit `EZA_SEED_READER=1` enables the old fixture-seeding escape hatch
for a demo only; it is off by default and must not be used for the checked-in
reference screenshots. `EZA_SHOT_QUERY` narrows the ledger shots to a query if
a representative slice is wanted.

`EZA_SEED_IMPORT` points the import at another export file, and
`EZA_SEED_IMPORT=0` keeps the library already on the server.
`EZA_SHOT_DIR` changes the output directory.
