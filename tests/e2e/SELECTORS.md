# End-to-end selector map (Direction B)

The production client is Miso markup written against the catalogue design,
styled by `static/eza.css`. The scripts in this directory run against a scratch server with
`node tests/e2e/<script>.mjs` and `EZA_BASE` pointing at it.

Stable hooks are `data-testid` attributes added by the view owners; ids that the
server-rendered pages keep are used directly. Shared selectors live in
[`lib/dom.mjs`](lib/dom.mjs) so a rename is a one-line change.

## Shell (every route)

| Hook | Element |
|---|---|
| `[data-testid="app-shell"]` | booted app root; stays mounted offline |
| `[data-testid="mast"]` | masthead |
| `[data-testid="sections"]` | running-head section nav |
| `[data-testid="section-<name>"]` | section link: ledger, inbox, graph, dedup, tags, ai-tags, maintenance, accessions, account |
| `#search-input` | query line input |
| `[data-testid="theme-toggle"]` | paper/night switch, toggles `data-theme` |
| `[data-testid="palette"]`, `#palette-input`, `[data-testid="palette-row"]` | command palette; opens on Cmd/Ctrl+K, Shift+K, or the `⇧K` hint button |
| `[data-testid="palette-open"]` | the `⇧K` hint under the search line |
| `[data-testid="section-sign-out"]`, `[data-testid="m-nav-sign-out"]`, `[data-testid="account-sign-out"]` | sign-out controls in the running head, mobile bar, and account head |
| `[data-testid="dialog-logout"]` | sign-out confirmation when a note is unsaved |
| `[data-testid="toast"]` | toast; the `.toast` class stays for styling |
| `.offline-banner` | offline/status banner |
| `.install-fab` | PWA install button, created by `static/pwa.js` |

## Ledger

| Hook | Element |
|---|---|
| `[data-testid="ledger-row"]` | one row; carries `data-bookmark-id` |
| `[data-testid="ledger-row-title"]` | row title |
| `[data-testid="ledger-row-select"]` | selection control, `role="checkbox"` |
| `[data-testid="selection-bar"]` / `[data-testid="selection-count"]` | bulk bar and count, text `N selected` |
| `[data-testid="selection-stop"]` | stops a running "select all matching" paging run and keeps the pages collected so far |
| `[data-testid="drawer"]` | field card |
| `[data-testid="dialog"]`, `[data-testid="dialog-body"]` | dialog overlay and body |
| `[data-testid="dialog-confirm"]` / `[data-testid="dialog-cancel"]` | dialog actions |
| `[data-testid="dialog-bulk-tag"]`, `#bulk-tag-input` | add/remove tag dialog |
| `[data-testid="dialog-bulk-delete"]` | delete confirmation |
| `[data-testid="dialog-add"]`, `#add-url`, `#add-title`, `#add-tags` | file-a-record dialog |
| `#save-url`, `#save-title`, `#save-tags` | quick-save page fields |

Each ledger row has a tick control in the accession column; it is revealed on
row hover or keyboard focus, and the column reserves its width so it never
clips at the left edge of the page. Selection bar actions are text buttons: `select page`, `select all matching`,
`add tag`, `remove tag`, `mark read`, `mark unread`, `delete`, `clear`; the
first two stay available after a first pick so a selection can be extended to
the whole filtered result set. The ledger foot shows `select page` and
`select all matching` while nothing is selected, with a visible gap between
the two controls. The Direction B ledger does not implement Shift-click range
selection or an in-ledger undo button; `bulk-ui-smoke.mjs` documents both as
non-mapping steps and undo stays covered by `prune-undo-smoke.mjs` (the
legacy print-only `undo-smoke.mjs` is excluded from the suite, see
`scripts/e2e.sh`).

## Bookmark record

| Hook | Element |
|---|---|
| `[data-testid="record"]` | record root; carries `data-bookmark-id` |
| `#reader-text` | reading column text |
| `[data-testid="reader-mark"]` | a rendered highlight mark |
| `[data-testid="highlight-toolbar"]` | selection toolbar |
| `[data-testid="highlight-row"]`, `[data-testid="highlight-edit"]`, `[data-testid="highlight-delete"]` | highlight list rows and actions |
| `#highlight-note`, `#highlight-edit-note` | note inputs |
| `[data-testid="highlight-style-solid|dashed|double"]` | mark style; stores `yellow`, `green`, `blue` |
| `[data-testid="dialog-share"]`, `[data-testid="share-create"]`, `[data-testid="share-reveal"]`, `[data-testid="share-url"]`, `[data-testid="share-copy"]`, `[data-testid="share-include-note"]`, `#share-expiry`, `[data-testid="share-row"]`, `[data-testid="share-revoke"]` | share dialog |
| `[data-testid="snapshot-open"]`, `[data-testid="snapshot-frame"]`, `[data-testid="snapshot-close"]` | snapshot viewer; the frame keeps `src` and `sandbox` |
| `[data-testid="dialog-guard"]`, `[data-testid="dialog-tag"]`, `[data-testid="dialog-delete"]` | record dialogs |

## Account

| Hook | Element |
|---|---|
| `[data-testid="account-tab-<name>"]` | section buttons: passkeys, recovery, sessions, tokens, webhooks, users, shares, rules, import, capture, appearance, about (webhooks and users are separate ids: `webhooks-tab`, `account-users-tab`) |
| `[data-testid="account-panel-<name>"]` | the active section |
| `#token-name`, `[data-testid="token-scope-read|write|capture"]`, `[data-testid="token-create"]` | token form |
| `[data-testid="token-reveal"]`, `[data-testid="token-secret"]`, `[data-testid="token-row"]`, `[data-testid="token-revoke"]`, `[data-testid="token-empty"]` | token reveal and list |
| `#rule-name`, `#rule-field`, `#rule-pattern`, `#rule-tags`, `[data-testid="rule-mark-read"]` | rule form fields |
| `[data-testid="rule-result"]`, `[data-testid="rule-create"]`, `[data-testid="rule-dry-run"]` | dry run and create |
| `[data-testid="rules-table"]`, `[data-testid="rule-row"]` (`data-enabled`), `[data-testid="rule-toggle"]`, `[data-testid="rule-delete"]` | rule list |
| `[data-testid="share-link-row"]`, `[data-testid="share-link-revoke"]` | account share links |
| `[data-testid="capture-box"]` | bookmarklet/PWA capture block; the snippet is `.account-snippet code` |
| `[data-testid="users-table"]`, `[data-testid="user-row"]` | admin account list and one account row |
| `[data-testid="user-name"]`, `[data-testid="user-password"]`, `[data-testid="user-role"]`, `[data-testid="user-create"]`, `[data-testid="user-form-error"]` | add-user form fields, submit and its inline error |
| `[data-testid="user-disable"]` / `[data-testid="user-enable"]`, `[data-testid="user-reset-open"]` | row actions: disable or enable the account, open the temporary-password form |
| `[data-testid="user-reset-password"]`, `[data-testid="user-reset-submit"]`, `[data-testid="user-reset-shown"]` | temporary-password form and its shown-once result |
| `[data-testid="user-recovery-codes"]`, `[data-testid="user-action-error"]` | recovery codes shown once after a create and the admin action error |


## Panels and server pages

| Hook | Element |
|---|---|
| `#/accessions` + `[data-testid="accessions"]` | accessions index |
| `[data-testid="accessions-year"]` (`data-year`), `[data-testid="accessions-day"]` (`data-day`) | year label and filing-day marks; both open the ledger filtered |
| `[data-testid="accessions-source"]` (`data-source`), `[data-testid="accessions-busiest"]` (`data-day`) | ranked source row and busiest-day row; both open the ledger filtered |
| `#/tags/ai` + `[data-testid="ai-banner"]` | AI tags and its provider banner |
| `[data-testid="share-page"]` / `[data-testid="share-unavailable"]` | server-rendered public share page and its invalid/revoked state |
| `[data-testid="dedup-url-section"]`, `[data-testid="dedup-title-section"]` | duplicates page: same-URL groups and advisory same-title groups |
| `[data-testid="dedup-merge-all"]`, `[data-testid="dialog-dedup-merge-all"]`, `[data-testid="dedup-merge-all-after"]` | confirmed one-shot merge, its dialog, and the after-merge banner |
| `[data-testid="dedup-more-url"]`, `[data-testid="dedup-more-title"]` | independent "show more" for each duplicates section |
| `#auth-form`, `#username`, `#password`, `#confirm-password`, `#password-login`, `#password-setup`, `#recovery`, `#codes`, `#copy-codes`, `#continue`, `#recovery-code`, `#redeem`, `#auth-error`, legacy `#passkey-login`, `#passkey-add` | auth pages |
| `#boot-splash`, `#boot-error` | shell boot states |

## Graph

| Hook | Element |
|---|---|
| `/graph` + `[data-testid="graph"]` | whole-library graph page root |
| `#graph-filter` | text filter input |
| `.g-plate` / `canvas.g-canvas-el` | canvas plate and its 2D canvas |
| `[data-testid="graph-status"]` | status line; counts the records, tags and wikilinks, and reads `N of TOTAL records match the filter` while a filter is set (`tags hidden` is appended while the tags toggle is off) |
| `[data-testid="graph-results"]`, `[data-testid="graph-result"]` | accessible results list and one item per matching record |
| `[data-testid="graph-aside"]`, `[data-testid="graph-tag"]` | aside and its top-tag buttons |
| `[data-testid="graph-preview"]` | hover preview card |
| `[data-testid="graph-zoom-in"]`, `[data-testid="graph-zoom-out"]`, `[data-testid="graph-fit"]`, `[data-testid="graph-zoom-value"]` | zoom controls and the percent readout |
| `[data-testid="graph-tags-toggle"]` | tags toggle; `aria-pressed` is `true` while tag nodes show |
| `[data-testid="graph-root"]` | root record title while the local neighbourhood is active |
| `[data-testid="graph-label-count"]` | label budget readout in the status line |
| `[data-testid="graph-legend"]` | colour-group legend: swatch, name, matched-record count and per-group on/off button |
| `[data-testid="graph-preset"]`, `[data-testid="graph-preset-compact"]`, `[data-testid="graph-preset-standard"]`, `[data-testid="graph-preset-airy"]` | layout preset segmented control and its three buttons; each button carries `aria-pressed` |
| `[data-testid="graph-local-toggle"]`, `[data-testid="graph-scope-whole"]`, `[data-testid="graph-local-depth"]`, `[data-testid="graph-depth-1|2|3"]` | local scope switch, whole-scope button, depth group and its three depth buttons |
| `[data-testid="graph-settings"]` | graph settings container (scope, depth, preset, save/save-as, tags, zoom) |
| `[data-testid="graph-group-edit"]`, `[data-testid="graph-group-editor"]` | open the colour-group editor and the editor itself |
| `[data-testid="graph-group-add"]`, `[data-testid="graph-group-row"]` | add a colour group and one editor row; `.g-group-name`, `.g-group-query`, `.g-group-color` are the three inputs inside a row |
| legend row classes | `.g-legend-row` is a legend row with `.g-swatch`, `.g-legend-name` and `.g-legend-count` |
| `[data-testid="view-save-graph"]`, `[data-testid="view-save-as"]` | save the current graph state to the active view and open the save-as dialog |
| `[data-testid="open-graph"]` | graph action on a record page |

Clicking a record node opens the record, clicking a tag node opens the ledger
filtered by `tag:<name>` (the aside top-tag buttons do the same), and clicking
the empty plate clears the selection. The canvas is a pointer surface; the
results list and the top-tag buttons are the accessible path.

## Views

| Hook | Element |
|---|---|
| `/views` + `[data-testid="views-page"]` | views manager page root |
| `[data-testid="view-row"]` | one stored view row; `[data-testid="view-default-badge"]` marks the default view of its kind |
| `[data-testid="view-open"]`, `[data-testid="view-default"]`, `[data-testid="view-delete"]` | row actions: open, set as default, delete |
| `[data-testid="view-rename"]`, `[data-testid="view-duplicate"]`, `[data-testid="view-export"]` | row actions: rename, duplicate, export JSON |
| `[data-testid="view-create"]`, `[data-testid="view-import"]` | create a view and open the import dialog |
| `[data-testid="view-save-dialog"]`, `[data-testid="view-name-input"]`, `[data-testid="view-save-submit"]`, `[data-testid="view-save-cancel"]` | save-as/create dialog, name field, submit and cancel |
| `[data-testid="view-import-dialog"]`, `[data-testid="view-import-text"]`, `[data-testid="view-import-submit"]` | import dialog, JSON textarea and submit |
| `[data-testid="view-export-dialog"]`, `[data-testid="view-export-text"]`, `[data-testid="view-export-close"]` | export dialog, JSON textarea and close |
| `[data-testid="view-save-current"]` | ledger rail action that opens save-as with a ledger definition |

## Multi-user

Every harness run now starts from a fresh control database and one claimed
admin account (`EZA_TEST_USER`) with the mini fixture imported. The auth pages
keep their ids: `#username`, `#password`, `#password-login`, `#password-setup`,
`#auth-error`, `#recover-username`, `#recovery-code`, `#redeem`. Scripts that
need a second account sign it in with `enterLibraryAs(page, username, password)`
and the admin users panel above. The auth-smoke script is the first-run case:
it starts from an empty control database and claims the first account through
`/setup`.

## Routes

`/`, `/inbox`, `/bookmark/<id>`, `/graph`,
`/graph?focus=<id>&depth=<1-3>&local=1`, `/views`, `/views/<slug>`, `/dedup`,
`/tags`, `/tags/ai`, `/maintenance`, `/accessions`, `/account`,
`/save?title&text&url`, `/login`, `/setup`, `/recover`,
`/account/add-passkey`, `/s/<token>`.

## Capture

`capture-screenshots.mjs` claims the instance through the setup form when it is
empty, or signs in with `EZA_TEST_USER` and `EZA_TEST_PASSWORD`, registers a
virtual WebAuthn authenticator, POSTs
`bookmarks_14_08_2026.html` as multipart form data to `/api/v1/import`, and
writes eight light and dark pairs into `docs/screenshots/`: `library`, `detail`,
`accessions`, `palette`, `graph`, `views`, `share` and `login`, each as
`NAME.png` and `NAME-dark.png` at 1440 pixels wide and dpr 2 (all 1440x900
except the cropped accessions pair). See
[docs/screenshots/README.md](../../docs/screenshots/README.md).
