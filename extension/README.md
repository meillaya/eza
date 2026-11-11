# eza clipper (Chromium MV3 extension)

Save the current page, or just the selected text, to your eza library. The
clipper extracts the readable article and its metadata in the browser, then
`POST`s a typed clip payload to `/api/v1/clip` with a capture token.

There is no build step to try it: load `extension/` unpacked. A build step
copies that same tree into `dist/` and optionally adds a bundled Defuddle
extractor for higher-quality extraction. The extension is not published in a
browser store yet, so loading it unpacked is the only install path.

## Install (load unpacked)

1. Open `chrome://extensions` (or `edge://extensions`) and turn on **Developer
   mode**.
2. Press **Load unpacked** and choose one of:
   - `extension/` for the no-build version, which uses the built-in DOM
     extractor and has no dependencies;
   - `extension/dist/` after building it, for the Defuddle-backed extraction.
     From the repository root:

     ```bash
     bash scripts/build-extension.sh --with-defuddle
     ```
3. Pin the extension so the toolbar button stays visible.

The extension needs Chromium/Chrome 116 or newer (Edge follows the same
manifest). It is Manifest V3, has no remote code, and makes no network request
except to the eza server you configure.

### Optional Defuddle bundle

With `--with-defuddle` the build bundles `dist/vendor/defuddle-page.js` and
writes `dist/vendor/THIRD-PARTY-NOTICES.txt`, which carries Defuddle's MIT
license text. The plain build copies only the extension's own files.

```bash
# from the repository root
bash scripts/build-extension.sh                 # copy build, no Defuddle
bash scripts/build-extension.sh --with-defuddle # bundle Defuddle
cd extension && npm test                        # manifest, syntax, security checks
```

With the bundle, the clipper runs Defuddle (`0.19.6`) in the page's main world
on a cloned document. Without it, the built-in extractor handles the page. The
popup notes when it fell back. Pages whose CSP blocks main-world scripts also
fall back automatically.

## Configure

1. In eza, open **Account → api tokens**, create a token named e.g. `Browser
   clipper`, and tick the **capture** scope. Copy the raw token once; the
   server never shows it again.
2. Open the extension's **Options** page.
3. Enter the server address (`https://eza.example.com`; a missing scheme
   becomes `https://`). Click **Grant access** so Chrome asks for permission
   to contact just that origin.
4. Paste the capture token and press **Save**.
5. Press **Test connection**. It calls `GET /api/v1/whoami` and shows the
   account name and token scopes. A 404 means the server build does not expose
   the capture API yet.

The token is stored in `chrome.storage.local` for this profile only. The
options page never renders a stored token back into the page; leaving the field
empty keeps the existing token. The token is sent only in the
`Authorization: Bearer` header, never in a URL, never to a content script, and
never logged.

Only the capture token is needed. No cookies are used; requests are sent with
`credentials: 'omit'` and one `Idempotency-Key` per logical save. The key (and
the exact payload that first used it) is persisted in `chrome.storage.session`
keyed by server URL + stable payload hash, and reused for retries — a network
failure, timeout, 429, or 5xx is retried by `saveClipWithRetry` with the same
key, and the popup's **Try again** / a second click within ten minutes sends the
same recorded request, so the server replays (`replayed: true`) instead of
filing a second capture.

## Use

- **Popup**: click the toolbar button, edit the title, add comma-separated
  tags, choose a template, and save. The popup shows success (new bookmark or
  attached to an existing one), an idempotent "already saved" state, and the
  server's error message for failures.
- **Context menu**: right-click → **Save to eza**, or select text and use
  **Save selection to eza**.
- **Keyboard**: `Ctrl+Shift+Y` saves the page, `Ctrl+Shift+U` saves the
  selection (`Command` on macOS). Rebind at `chrome://extensions/shortcuts`.
  Context-menu and keyboard saves show a toolbar badge: `OK` on success, `!`
  on failure.

Selection saves send the full page content plus `selection`; the server
template decides how the selected passage appears (the built-in default appends
it after the body).

## Server contract

The extension expects these routes (see `server/src/Eza/Clip.hs` for the typed
payload, errors, and schema):

```
GET  /api/v1/whoami                 connection test: {username, scopes, token_name}
GET  /api/v1/clip-templates         {templates:[ClipTemplate], builtin:ClipTemplate}
POST /api/v1/clip                   SaveClipResult; 200 on idempotent replay
POST /api/v1/clip/preview           rendered note without saving (optional here)
```

It sends:

```http
POST /api/v1/clip
Authorization: Bearer eza_pat_...
Idempotency-Key: <uuid>
Content-Type: application/json
X-Eza-Client: eza-clipper/0.1.0
```

```json
{
  "url": "https://example.com/article",
  "title": "The Quiet Ledger",
  "content_markdown": "# …",
  "content_text": "…",
  "content_html": "<article>…</article>",
  "selection": "selected passage",
  "tags": ["reading"],
  "template_id": 3,
  "source": "extension",
  "client": "eza-clipper/0.1.0",
  "captured_at": 1762549200,
  "metadata": {
    "author": "…", "site": "…", "published": "2024-03-01T10:00:00Z",
    "description": "…", "language": "en",
    "image": "https://…", "favicon": "https://…",
    "canonical_url": "https://…",
    "extractor": "defuddle", "extractor_version": "0.19.6",
    "word_count": 118, "parse_time_ms": 84
  }
}
```

A retry of the same save reuses the same `Idempotency-Key` *and* the same
recorded payload, so the server answers `200` with `replayed: true` instead of
inserting a duplicate capture. `saveClipWithRetry` retries a network
error/timeout, a 429 (honouring `Retry-After`) and 5xx responses up to three
attempts with the same key; no other error is retried. A `409
idempotency_conflict` means the stored key was reused for a different payload;
the background worker drops the stale record and the popup surfaces the error,
so a further attempt starts from a fresh key.

Because extension requests carry `Origin: chrome-extension://<id>`, the server
must allow extension origins for bearer-token requests (or the token request
will fail with 403). A bearer token has no ambient cookie authority, so
allowing `chrome-extension://…` on that path does not weaken CSRF protection.
The options page test connection will show the 403 if this is missing.

## Permissions

| Permission | Why |
| --- | --- |
| `activeTab` | Read the page only when the user clicks the button, uses the menu, or presses the shortcut. |
| `scripting` | Inject the extractor into that tab. |
| `storage` | Keep the server address, token, and default template in this profile. |
| `contextMenus` | The right-click **Save** entries. |
| `optional_host_permissions` (`http(s)://*/*`) | Ask for access to the one configured server origin at runtime; no static host permission. |

There are no content scripts and no `<all_urls>` permission. The two keyboard
shortcuts are declared under the manifest's `commands` key rather than
requested as a permission; rebind them at `chrome://extensions/shortcuts`.

## Security notes

- The capture token is stored once and only read by the background worker and
  the options page. It is passed to the API module in memory.
- Extraction clones the DOM and never mutates the page. The Defuddle path runs
  with `useAsync: false` and a rejecting `fetch`, so no extractor can call a
  third-party API.
- The popup and options pages never log anything; errors are shown as text.
- Server responses are treated as untrusted: only known fields are read, and
  error text is displayed as text (`textContent`), never as HTML.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| "no access to …" | Options → **Grant access**, then save again. |
| 401 | Token was revoked or mistyped. Create a new capture token and save it. |
| 403 | Token lacks the `capture` scope, or the server does not allow `chrome-extension://` origins for bearer requests. |
| 404 on test | The server build predates the clip API; update eza. |
| "This page cannot be clipped" | Chrome internal pages (`chrome://`, Web Store) cannot be read by extensions. |
| Defuddle note in popup | The optional bundle is absent or the page CSP blocked it; the built-in extractor was used. |

## Development

```
extension/
  manifest.json        MV3 manifest
  background.js        service worker: menus, commands, extraction, save
  popup.html/popup.js  the toolbar popup
  options.html/options.js
  ui.css               shared styling for both pages
  src/config.js        storage, URL normalization, host permission
  src/api.js           fetch wrapper, error mapping, idempotency keys
  src/extract.js       self-contained in-page DOM extractor (fallback)
  src/defuddle-page.js entry for the optional Defuddle bundle
  src/version.js       client and pinned Defuddle versions
  build.mjs            copy/bundle build
  test/check.mjs       manifest + syntax + security checks (no dependencies)
```

`npm test` needs no browser. To check the extraction paths in a browser
against the extractor fixture:

```bash
# from the repository root
bash scripts/build-extension.sh --with-defuddle
# load extension/dist/ unpacked, open sidecar/test/fixtures/article.html over http(s),
# click the toolbar button, confirm the Title/Template/Save flow.
```

`node --check` covers every JavaScript file through `npm test`. The root script
`scripts/build-extension.sh` installs the dependencies when `node_modules` is
missing and passes its arguments to `build.mjs` (`--with-defuddle`, `--out`).

## License

Apache-2.0 for this extension, the same license as eza. The checked-in source
ships no third-party code. Building with `--with-defuddle` bundles Defuddle
(`defuddle` 0.19.6, MIT); the build writes Defuddle's license text to
`dist/vendor/THIRD-PARTY-NOTICES.txt`, and the repository-level
[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) records the version.
