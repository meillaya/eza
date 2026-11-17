# eza clipper (Chrome and Firefox)

The browser companion for [eza](../README.md), the self-hosted bookmark
catalogue. It adds the current page to your eza library, and its toolbar icon
shows whether the page is already saved.

- **Add bookmark** files the page address with an optional title and tags. It
  sends no page content.
- **Add page text** saves the readable article as a reading copy.
- **Add selection** saves the page with the selected passage.
- The toolbar badge shows **✓** when the page is in your library (the tooltip
  names the saved bookmark) and is empty otherwise.
- The extension talks only to the eza server address you configure. There is
  no developer service, no analytics, and no third-party network call.

One source tree builds both browser packages: the Chrome manifest uses an MV3
service worker, and the Firefox package overlays `manifest.firefox.json` with
an MV3 event page and `browser_specific_settings`. The plain build is the store
build. Version 0.2.0 adds the saved-page indicator over the previous clip-only
clipper.

## Requirements

- Chrome, Chromium, or Edge 116 or newer for the Chrome package.
- Firefox 140 or newer for the Firefox package (MV3 event page plus data
  collection permissions).

## Build

Node 18 or newer is required; the plain build has no npm dependencies.

```bash
cd extension
npm test          # static checks + both build targets in a temporary directory
npm run build     # writes the packages under extension/dist
```

Outputs:

```
extension/dist/chrome/                              load-unpacked Chrome build
extension/dist/firefox/                             load-unpacked Firefox build
extension/dist/eza-clipper-<version>-chrome.zip     Chrome Web Store upload
extension/dist/eza-clipper-<version>-firefox.zip    Firefox Add-ons upload
```

Targeted builds and the repository script:

```bash
npm run build:chrome
npm run build:firefox
npm run build:defuddle    # optional local Defuddle extractor bundle

# from the repository root
bash scripts/build-extension.sh
bash scripts/build-extension.sh --target firefox
bash scripts/build-extension.sh --out extension/dist
bash scripts/build-extension.sh --with-defuddle
```

The plain build is deterministic: it copies plain files, never bundles
third-party code, and writes a reproducible ZIP with the manifest at the
archive root. The store packages must stay under 300 KiB unpacked and 150 KiB
zipped; both are roughly a sixth of that. `--with-defuddle` is a power-user
build for better extraction on difficult pages. It bundles Defuddle (MIT) into
`vendor/` and must not be uploaded to either store. The Clipper does not use
the optional bundle to read pages unless you explicitly add page text.

### Install for development

Chrome:

1. Open `chrome://extensions` and turn on **Developer mode**.
2. **Load unpacked** → choose `extension/dist/chrome` (or `extension/` after a
   plain build has generated the manifests; the prebuilt directory is simpler).
3. Pin the extension so the toolbar icon stays visible.

Firefox:

1. Open `about:debugging#/runtime/this-firefox`.
2. **Load Temporary Add-on…** → choose `extension/dist/firefox/manifest.json`.
3. The temporary add-on is removed when Firefox closes; install the signed
   package from AMO for a persistent install.

## Configure

1. In eza, open **Account → Tokens**, create a token (for example
   `Browser clipper`), and tick the **capture** scope. Copy the raw token once.
2. Open the extension **Options** page.
3. Enter the server address (`https://eza.example.com`, or
   `http://localhost:8000`; a missing scheme becomes `https://`).
4. Paste the capture token and press **Save**. Leaving the field empty keeps
   the stored token, so the page never renders it back.
5. Press **Grant access** so the browser asks for the one server origin. Then
   press **Test connection**: it calls `GET /api/v1/whoami` and probes
   `GET /api/v1/bookmarks/lookup`. A 404 on the lookup probe means an older
   server; adding bookmarks still works, the saved-page badge stays empty.
6. Optional: choose the default clip template, and turn **Check the active
   page for saved status** off if you do not want the background tab indicator
   to contact the server when tabs change. The popup still checks the page on
   demand when you open it, and the add actions work either way.

The capture token is stored in this browser profile's extension storage. It is
sent only in the `Authorization: Bearer` header, never in a URL, never to a
page, and never logged. Requests use `credentials: 'omit'`; clip saves carry
one `Idempotency-Key` per logical save so a retry replays instead of filing a
second capture. The optional origin permission is the only host access the
extension ever has.

## Toolbar status

The background worker checks the active tab's exact URL with
`GET /api/v1/bookmarks/lookup?url=<encodeURIComponent(page URL)>` and keeps the
result in memory for at most 60 seconds. A saved page shows the **✓** badge,
the page title in the tooltip, and the saved bookmark's title/tags/read state in
the popup.

| State | Toolbar | Popup |
| --- | --- | --- |
| loading | cleared | `Checking this page…` |
| not configured | cleared | setup panel with **Open options** |
| restricted page (browser-internal, `file:`, `data:`, extension pages) | cleared | error panel (`This page cannot be added to eza.`) |
| no host permission for the server origin | cleared | add panel with **Grant access** |
| saved page | **✓** (`#1f6f43`), tooltip `eza — in your library: <title>` | **In your library**, title, tags, read state, **Open in eza** |
| unsaved page | cleared, tooltip `eza — add bookmark` | add panel with title/tags |
| lookup error / rejected token | cleared | error panel with **Try again** and **Options** |
| failed add action | **!** (`#8a2b20`) for 5 seconds, then back to the page state | error panel with the reason |
| older server without the lookup route | cleared; no saved state | add panel with a note; adding works |
| background checks turned off in Options | cleared on tab changes | opening the popup still checks the page on demand |

Opening the popup never reads the page body. It asks the background worker for
the status object and paints it; page text is extracted only when you choose
**Add page text** or **Add selection**.

## Actions

- **Popup**: on an unsaved page, edit the title and comma-separated tags, then
  **Add bookmark** or **Add page text**. On a saved page, open the bookmark in
  eza or add page text to it. Success shows `Bookmark added` or
  `Already in your library`; failures show the server message and **Try again**.
- **Context menu**: **Add bookmark to eza**, **Add page text to eza**, and
  **Add selection to eza**.
- **Keyboard**: `Ctrl+Shift+Y` adds the page, `Ctrl+Shift+U` adds the selection
  (`Command` on macOS). Rebind on the browser's extension shortcuts page.

Adding a bookmark posts only `{url, title, tags}` to `POST /api/v1/quick-save`;
an existing bookmark keeps its own title and tags and is reported as
`Already in your library`. Adding page text uses the clip pipeline
(`POST /api/v1/clip`) with the extracted readable content and the selection.
The context-menu and keyboard actions report failures on the toolbar badge.

## Server contract

The extension is a capture client. It expects these routes (see
[`docs/clipper.md`](../docs/clipper.md) and [`docs/API.md`](../docs/API.md)):

```text
GET  /api/v1/whoami                 connection test: {username, scopes, token_name}
GET  /api/v1/bookmarks/lookup       ?url=<encoded page URL>
                                    -> {url, bookmark: BookmarkSummary | null}
GET  /api/v1/clip-templates         {templates, builtin}
POST /api/v1/quick-save             {"url","title","tags"} -> {id, existing}
POST /api/v1/clip                   SaveClipResult (Idempotency-Key)
POST /api/v1/clip/preview           rendered note without saving
```

Every request carries `Authorization: Bearer <capture token>`,
`X-Eza-Client: eza-clipper/0.2.0`, and `credentials: 'omit'`. The browser sends
an extension origin (`chrome-extension://…` or `moz-extension://…`), so the
server must allow extension origins for the bearer capture routes
(`EZA_CLIP_ORIGINS`, or the built-in extension-origin allowance) and answer the
CORS preflight before the auth guard. A 404 from the lookup route is treated as
an older server and never retried on that connection.

`GET /api/v1/bookmarks/lookup` is a capture-read: it answers one exact
normalized URL with a bookmark summary and never returns notes, extracted text,
or captures. The lookup must not be confused with a bookmark-id route.

## Permissions

| Permission | Why |
| --- | --- |
| `tabs` | Read the active tab's address and title for the saved-page indicator. The extension does not enumerate or retain other tabs. |
| `activeTab` | Read the current page only after you click the extension, use its context menu, or press its shortcut. |
| `scripting` | Extract the readable text or selected passage after one of those actions. No content script runs at page load. |
| `storage` | Keep the server address, capture token, and defaults in this profile. |
| `contextMenus` | The three page context-menu entries. |
| optional host access (`http://*/*`, `https://*/*`) | Asked for the one configured server origin at runtime. There is no static host permission in the store build. |

There are no content scripts and no `<all_urls>` permission. The keyboard
shortcuts are declared in the manifest's `commands` key, not requested as a
permission.

## Firefox data collection and consent

The Firefox manifest declares the browser's data collection permissions in
`browser_specific_settings.gecko.data_collection_permissions`:

| Category | Kind | What it covers |
| --- | --- | --- |
| `browsingActivity` | required | the active page address used by the saved-page indicator and add actions |
| `bookmarksInfo` | required | the title, address, and tags of a bookmark you add |
| `websiteContent` | optional | the readable page text or selected text you explicitly choose to capture |

Firefox asks for the optional `websiteContent` permission the first time you
choose **Add page text** (from the popup, where the click is the user gesture)
or press **Allow page text** in Options. Declining leaves **Add bookmark**
working; page text stays disabled and the popup explains why. The background
worker re-checks `permissions.getAll().data_collection` before every capture, so
revoking the permission in the browser's extension settings takes effect
immediately. Firefox shows the required data collection on install and on
update if it changes.

The store listing must declare the same categories: required **Browsing
activity** and **Bookmarks**, optional **Website content**. See
[`store/README.md`](store/README.md) for the listing copy and submission
checklist, and [`docs/extension-privacy.md`](../docs/extension-privacy.md) for
the privacy policy.

## Privacy and security

- The token is stored in extension-local storage and read only by the
  background worker and the options page.
- No request or response body is logged; errors are shown as text.
- The lookup cache is in memory only, holds at most 200 entries, and expires
  after 60 seconds; it is never written to storage.
- Server responses are untrusted: only known fields are read, and text is
  rendered with `textContent`, never `innerHTML`.
- Extraction clones the document and never mutates the page. The optional
  Defuddle bundle runs locally with `useAsync: false` and a rejecting `fetch`,
  so an extractor cannot reach a third-party API.
- There is no remote code, no `eval`, and no dynamic import of remote modules.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `This page cannot be added to eza` | Browser-internal, extension, `file:`, and `data:` pages cannot be read by extensions. Open a normal http(s) page. |
| `no access to …` / **Grant access** shown | Options → **Grant access**, then retry. |
| Toolbar badge stays empty on saved pages | Older eza server: run **Test connection** in Options; update eza to a build with the lookup route. |
| 401 | The token was revoked or mistyped. Create a new capture token and save it. |
| 403 | The token lacks the `capture` scope, or the server rejects extension origins for bearer requests. |
| 404 on **Test connection** | The server build predates the clip API; update eza. |
| Firefox shows no page-text button / page text disabled | Allow the optional **Website content** permission from the popup or Options. Add bookmark is unaffected. |
| **Add page text** fails with a CSP or extractor error | The page's CSP blocked the extractor; the built-in extractor is used when possible. Try a readable article page. |
| Two bookmarks from a retried save | A retry of one logical save reuses its `Idempotency-Key`, so it replays. A fresh edit of the title/tags is a new save. |

## Manual Firefox checklist

Run this after loading `extension/dist/firefox/manifest.json` as a temporary
add-on against a test eza server:

1. Open Options; set the server address and a capture token; press **Grant
   access**; press **Test connection** and confirm the account and lookup probe
   succeed.
2. Load an article page over http(s). The toolbar tooltip reads `eza — add
   bookmark` and the badge is empty. Open the popup: it shows the page title and
   address without reading the page body.
3. Press **Add bookmark**; the popup shows `Bookmark added`, the badge becomes
   **✓** and the tooltip names the page. Reopen the popup: it shows **In your
   library** with the title, tags, and read state.
4. Press **Add bookmark** again for the same page from the context menu; it
   reports `Already in your library` and does not create a duplicate.
5. Open a page that is not in the library, right-click → **Add selection to
   eza** after selecting text. Firefox should ask for the optional Website
   content permission; grant it, and confirm the page text is added.
6. With another new page, deny the Website content prompt. Confirm **Add
   bookmark** still works and that page text stays disabled with the
   explanation shown.
7. Restart Firefox (the temporary add-on is removed) and re-add it; confirm the
   saved-page badge works on a page saved in step 3.
8. Open a `about:` or `file:` page and confirm the popup shows the restricted
   message and the badge is cleared.

For Chrome, repeat steps 1-4 with `extension/dist/chrome`; there is no data
collection prompt, and **Add page text** works after the host permission is
granted.

## Development

```
extension/
  manifest.json          Chrome MV3 manifest (source of the generated manifests)
  manifest.firefox.json  Firefox overlay: event page + browser_specific_settings
  background.js          service worker / event page: status, menus, messages, saves
  popup.html/popup.js    the toolbar popup
  options.html/options.js
  ui.css                 shared styling for both pages
  build.mjs              target-aware plain build, deterministic ZIP, optional Defuddle
  src/browser.js         the only module that touches the WebExtension namespace
  src/status.js          URL policy, tooltips, badge model, bounded lookup cache
  src/config.js          storage, URL normalization, host permission
  src/api.js             lookup, quick-save, clip, error mapping, idempotency keys
  src/consent.js         Firefox data collection detection and consent
  src/extract.js         self-contained in-page DOM extractor (fallback)
  src/defuddle-page.js   entry for the optional Defuddle bundle
  src/version.js         extension and pinned Defuddle versions
  test/check.mjs         manifest, source, icon, security, and full-build checks
  test/status.mjs        pure status-helper tests
  test/lookup.mjs        lookup and quick-save request tests
  test/background.mjs    background status/add/message flows with a fake API
  test/idempotency.mjs   clip idempotency contract tests
```

`npm test` needs no browser and builds both targets in a temporary directory.
The message contract used by the popup (and by the opt-in repository Playwright
smoke test) is documented at the top of `background.js`: `eza:pageStatus`,
`eza:addBookmark`, `eza:addPage`, and the compatibility `eza:extract`, all
answered with plain `{ok, ...}` objects. The stable popup panel ids are
`loading-panel`, `setup-panel`, `add-panel`, `saved-panel`, `done-panel`, and
`error-panel`.

### Browser smoke test

`tests/e2e/extension-smoke.mjs` is an opt-in Chrome smoke test. It builds a
test copy of the extension with a local host permission, loads it through
Playwright, and checks the per-tab badge/tooltip and the popup add flow. It is
deliberately outside the CI suite: the Nix/Playwright Chromium in this
development shell crashes at browser launch, and branded Google Chrome 137+
ignores `--load-extension`. Run it where a Chromium build still supports
side-loading:

```bash
EZA_E2E_SCRIPTS=extension-smoke.mjs bash scripts/e2e.sh
```

The Node `test/background.mjs` suite covers the same status/add logic without a
browser, and the Haskell `LookupSpec`/`OriginGuardSpec` cover the server route
and CORS. Use the manual Firefox checklist above for the browser-level checks.

After changing anything that the extension sends, update
`browser_specific_settings.gecko.data_collection_permissions`,
[`docs/extension-privacy.md`](../docs/extension-privacy.md), and
[`store/README.md`](store/README.md) together.

## License

Apache-2.0 for this extension, the same license as eza. The plain build ships
no third-party code. Building with `--with-defuddle` bundles Defuddle
(`defuddle` 0.19.6, MIT); the build writes Defuddle's license text to
`vendor/THIRD-PARTY-NOTICES.txt`, and the repository-level
[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) records the version.
