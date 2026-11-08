# Screenshots

The screenshots come from the real server and the built WASM client. The
library is the 2026-08-14 Netscape export (9,457 anchors, 8,988 records,
4,283 sources), imported through the public API; it is not a mockup and no
record is invented for the pictures.

The set is seven PNGs at 1440x900 with a device pixel ratio of 2:

| File | Screen |
|---|---|
| `library.png` | the ledger under a real `tag:literature` query, masthead counting the whole library |
| `detail.png` | a bookmark record, its reading spread and its marks |
| `accessions.png` | the printed index of the archive |
| `palette.png` | the command palette over that filtered ledger |
| `dark.png` | the same ledger in the reading-room theme |
| `share.png` | a server-rendered read-only share page |
| `login.png` | the passkey sign-in card, no session |

## Capture a new set

1. Initialise a clean capture database (a fresh import keeps the provenance
   line exact) and start a scratch server on it:

   ```
   source .devenv/shell-env.sh
   EZA_DATA_DIR=.eza-scratch-shots EZA_DB=.eza-scratch-shots/eza.db \
     cabal run eza-bookmarks -- init
   EZA_DATA_DIR=.eza-scratch-shots EZA_DB=.eza-scratch-shots/eza.db \
   EZA_STATIC_DIR=static EZA_BIND=127.0.0.1:8100 \
   PUBLIC_ORIGIN=http://localhost:8100 EZA_RP_ID=localhost \
   cabal run eza-bookmarks -- serve
   ```

2. Run the capture script against it, pointing at the same SQLite file:

   ```
   EZA_BASE=http://localhost:8100 EZA_DB=.eza-scratch-shots/eza.db \
   EZA_SHOT_QUERY="tag:literature" \
     node tests/e2e/capture-screenshots.mjs
   ```

   The committed ledger shots use `EZA_SHOT_QUERY="tag:literature"`: the
   newest rows in the real export are forum and video saves, so a query gives
   a representative slice while the masthead still counts 8,988 entries.

3. Look at the seven PNGs before committing them.

## What the script seeds

The script claims the instance with a virtual WebAuthn authenticator and then
POSTs `bookmarks_14_08_2026.html` as multipart form data to
`/api/v1/import`. When the export is missing it falls back to a 14-bookmark
demo set.

The detail shot uses record `EA-08987` ("Dynamic Arrays in Arenas") and the
real enrichment output. It waits for extraction, then adds a note and three
highlights through the public API so the reading spread shows the design's
marks. An explicit `EZA_SEED_READER=1` enables the old fixture-seeding escape
hatch for a demo only; it is off by default and must not be used for the
checked-in reference screenshots. `EZA_SHOT_QUERY` narrows the ledger shots to
a query if a representative slice is wanted.

`EZA_SEED_IMPORT` points the import at another export file, and
`EZA_SEED_IMPORT=0` keeps the demo set even when the export is present.
`EZA_SHOT_DIR` changes the output directory.
