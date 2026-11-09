# Screenshots

The screenshots come from the real server and the built WASM client, against a
scratch copy of the live library (9,236 records, 4,470 sources, filed since
2022.08.07); it is not a mockup and no record is invented for the pictures. The
detail and share shots use a real record with real extracted text, a note and
three marks.

The set is seven PNGs at 1440x900 with a device pixel ratio of 2; the accessions
shot is cropped above the ranked-source list so private sources do not appear in
the public image:

| File | Screen |
|---|---|
| `library.png` | the ledger under a real `tag:literature` query, masthead counting the whole library |
| `detail.png` | a bookmark record, its reading spread and its marks |
| `accessions.png` | the printed index figures and filing days, without source names |
| `palette.png` | the command palette over that filtered ledger |
| `dark.png` | the same ledger in the reading-room theme |
| `share.png` | a server-rendered read-only share page |
| `login.png` | the password sign-in card, no session |

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

2. Run the capture script against it from the same shell, pointing at the same
   SQLite file:

   ```
   EZA_BASE=http://localhost:8100 EZA_DB=.eza-scratch-shots/users/1/eza.db \
   EZA_SHOT_QUERY="tag:literature" EZA_FEATURE_ID=8226 \
   EZA_SEED_IMPORT=/path/to/bookmarks_14_08_2026.html \
     node tests/e2e/capture-screenshots.mjs
   ```

   The committed ledger shots use `EZA_SHOT_QUERY="tag:literature"`: the
   newest rows in the real export are forum and video saves, so a query gives
   a representative slice while the masthead still counts 8,905 entries.
   The export itself is private and is not checked in; point
   `EZA_SEED_IMPORT` at it, or let the script fall back to the demo set.

3. Look at the seven PNGs before committing them.

   `EZA_FEATURE_ID` selects the record used for the detail and share shots;
   the default `8226` is "McCaffery Collection at Spineless Books—Authorized"
   in this export, a real literary essay with clean extracted text. Enrich it
   first if a fresh scratch database has no extracted text:

   ```
   EZA_DATA_DIR=.eza-scratch-shots cabal run eza-bookmarks -- \
     enrich --user e2e --id 8226
   ```

## What the script seeds

The script creates the scratch account with a username and password, then
POSTs a local `bookmarks.html` export as multipart form data to
`/api/v1/import`. When the export is missing it falls back to a 14-bookmark
demo set.

The detail shot uses record `EA-08226` ("McCaffery Collection at Spineless
Books—Authorized") and its real enrichment output. It waits for extraction,
then adds a note and three highlights through the public API so the reading
spread shows the design's marks. An explicit `EZA_SEED_READER=1` enables the old fixture-seeding escape
hatch for a demo only; it is off by default and must not be used for the
checked-in reference screenshots. `EZA_SHOT_QUERY` narrows the ledger shots to
a query if a representative slice is wanted.

`EZA_SEED_IMPORT` points the import at another export file, and
`EZA_SEED_IMPORT=0` keeps the demo set even when the export is present.
`EZA_SHOT_DIR` changes the output directory.
