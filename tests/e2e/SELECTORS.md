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
| `[data-testid="palette"]`, `#palette-input`, `[data-testid="palette-row"]` | command palette; opens on Cmd/Ctrl+K or Shift+K |
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
| `[data-testid="drawer"]` | field card |
| `[data-testid="dialog"]`, `[data-testid="dialog-body"]` | dialog overlay and body |
| `[data-testid="dialog-confirm"]` / `[data-testid="dialog-cancel"]` | dialog actions |
| `[data-testid="dialog-bulk-tag"]`, `#bulk-tag-input` | add/remove tag dialog |
| `[data-testid="dialog-bulk-delete"]` | delete confirmation |
| `[data-testid="dialog-add"]`, `#add-url`, `#add-title`, `#add-tags` | file-a-record dialog |
| `#save-url`, `#save-title`, `#save-tags` | quick-save page fields |

Selection bar actions are text buttons: `add tag`, `remove tag`, `mark read`,
`mark unread`, `delete`, `clear`. The ledger foot has `select page` and
`select all matching`. The Direction B ledger does not implement Shift-click
range selection or an in-ledger undo button; `bulk-ui-smoke.mjs` documents both
as non-mapping steps and undo stays covered by `undo-smoke.mjs` and
`prune-undo-smoke.mjs`.

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
| `[data-testid="account-tab-<name>"]` | section buttons: passkeys, recovery, sessions, tokens, shares, rules, import, capture, appearance, about |
| `[data-testid="account-panel-<name>"]` | the active section |
| `#token-name`, `[data-testid="token-scope-read|write|capture"]`, `[data-testid="token-create"]` | token form |
| `[data-testid="token-reveal"]`, `[data-testid="token-secret"]`, `[data-testid="token-row"]`, `[data-testid="token-revoke"]`, `[data-testid="token-empty"]` | token reveal and list |
| `#rule-name`, `#rule-field`, `#rule-pattern`, `#rule-tags`, `[data-testid="rule-mark-read"]` | rule form fields |
| `[data-testid="rule-result"]`, `[data-testid="rule-create"]`, `[data-testid="rule-dry-run"]` | dry run and create |
| `[data-testid="rules-table"]`, `[data-testid="rule-row"]` (`data-enabled`), `[data-testid="rule-toggle"]`, `[data-testid="rule-delete"]` | rule list |
| `[data-testid="share-link-row"]`, `[data-testid="share-link-revoke"]` | account share links |
| `[data-testid="capture-box"]` | bookmarklet/PWA capture block; the snippet is `.account-snippet code` |

## Panels and server pages

| Hook | Element |
|---|---|
| `#/accessions` + `[data-testid="accessions"]` | accessions index |
| `#/tags/ai` + `[data-testid="ai-banner"]` | AI tags and its provider banner |
| `[data-testid="share-page"]` / `[data-testid="share-unavailable"]` | server-rendered public share page and its invalid/revoked state |
| `#passkey-login`, `#passkey-setup`, `#recovery`, `#codes`, `#copy-codes`, `#continue`, `#recovery-code`, `#redeem`, `#auth-error`, `#passkey-add` | auth pages |
| `#boot-splash`, `#boot-error` | shell boot states |

## Routes

`/`, `/inbox`, `/bookmark/<id>`, `/graph`, `/dedup`, `/tags`, `/tags/ai`,
`/maintenance`, `/accessions`, `/account`, `/save?title&text&url`,
`/login`, `/setup`, `/recover`, `/account/add-passkey`, `/s/<token>`.

## Capture

`capture-screenshots.mjs` claims the instance with a virtual WebAuthn
authenticator, POSTs `bookmarks_14_08_2026.html` as multipart form data to
`/api/v1/import`, and writes `library.png`, `detail.png`, `accessions.png`,
`palette.png`, `dark.png`, `share.png` and `login.png` at 1440x900 dpr 2 into
`docs/screenshots/`. See [docs/screenshots/README.md](../../docs/screenshots/README.md).
