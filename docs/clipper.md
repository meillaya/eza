# Browser clipper and extraction sidecar

eza has a cross-browser extension, the eza clipper, for Chrome and Firefox. It
adds the current page as a bookmark, shows whether that page is already in the
library, and can attach a reading capture when the user asks for one. The
server can also use a Node/Defuddle sidecar for pages that arrive without text.

## Browser extension (Chrome and Firefox)

One source tree builds two Manifest V3 packages:

- **Chrome**: `background.service_worker` with a module service worker,
  `minimum_chrome_version` 116;
- **Firefox 140+**: `background.scripts` event page with a module script and
  `browser_specific_settings` (add-on id, `strict_min_version` and the Firefox
  data-collection declaration).

The Chrome build is listed in the
[Chrome Web Store](https://chromewebstore.google.com/detail/eza-clipper/hdbgombaclbiolmememmjciigpfepghp).
Firefox is not published yet.

Build both packages:

```bash
bash scripts/build-extension.sh
# extension/dist/chrome, extension/dist/firefox
# extension/dist/eza-clipper-<version>-chrome.zip
# extension/dist/eza-clipper-<version>-firefox.zip
```

`extension/build.mjs` selects the manifest and output directory per target;
`--target chrome|firefox|all`, `--out DIR` and `--with-defuddle` are the build
switches. The plain build needs only Node and has no runtime dependencies,
content scripts, remote code or bundled extractor. The optional
`--with-defuddle` build bundles Defuddle into a local `vendor/` directory for
higher-quality extraction and is not part of the store packages; the server's
enrichment path remains the fallback either way.

Load locally:

- Chrome/Edge: `chrome://extensions` → developer mode → **Load unpacked** →
  `extension/dist/chrome` (or the source `extension/` for the Chrome manifest).
- Firefox: `about:debugging#/runtime/this-firefox` → **Load Temporary Add-on**
  → `extension/dist/firefox/manifest.json`.

Store submission and listing copy are in
[extension/store/README.md](../extension/store/README.md); the privacy policy is
[docs/extension-privacy.md](extension-privacy.md).

The browser-free extension suite (`cd extension && npm test`) covers the
manifests, build output, lookup requests, status helpers and the background
message flows against a fake WebExtension namespace. The repository's
`tests/e2e/extension-popup-smoke.mjs` renders the popup and options pages in the
plain headless Chromium shell with a fake API. The real Chrome extension smoke
is opt-in because some Chromium builds cannot side-load extensions headlessly;
Firefox is covered by the manual checklist in the extension README.

## Configure

Open the extension options and set:

- **server URL**: e.g. `http://localhost:8000` or the public https origin;
- **capture token**: an API token created in Account → Tokens with the
  `capture` scope;
- **default template**: the template used by **Add page text**; the built-in
  default applies when unset.

The options page tests `GET /api/v1/whoami` and probes the saved-page lookup,
then asks the browser for access to only the configured server origin. A
**check pages in the background** toggle (default on) controls whether the
active-page indicator sends its lookup; turning it off leaves the on-demand
popup check and the add actions working.

The token lives in extension-local storage (`storage.local`), never in sync
storage. It is sent only in the `Authorization: Bearer` header, never in a URL
or a log. The extension sends `credentials: 'omit'` and never relies on eza
session cookies.

## Saved-page status and actions

On every normal page the background reads the active tab's URL (via the
browser's `tabs` permission) and asks the server:

```http
GET /api/v1/bookmarks/lookup?url=<encodeURIComponent(pageUrl)>
Authorization: Bearer eza_pat_...
X-Eza-Client: eza-clipper/<version>
```

The response is the normalized URL and the bookmark summary, or `null` for a
page that is not saved. Lookup results stay in memory for at most 60 seconds
and are coalesced, so tab switches do not produce a request per keystroke. The
toolbar icon shows a small green check and the tooltip "in your library:
<title>" when the page is saved; an unsaved page has no badge and the tooltip
"add bookmark". Lookup failure (offline, old server without the route, revoked
token) clears the badge and leaves the base tooltip; it does not block adding.

The actions are:

- **Add bookmark** in the popup, the `Add bookmark to eza` context menu entry,
  and `Ctrl+Shift+Y` (`Command` on macOS) — `POST /api/v1/quick-save` with the
  page URL, title and tags, then a status refresh. A duplicate URL returns the
  existing record rather than creating another one.
- **Add page text** / **Add selection** — the popup button, the matching
  context-menu entries, and `Ctrl+Shift+U` extract the readable page or the
  selected passage and send `POST /api/v1/clip` with an idempotency key. Page
  text is read only after this explicit action.
- **Open in eza** — opens `${serverUrl}/bookmark/{id}` for the saved record;
  **Open eza** opens the library root.

`GET /api/v1/bookmarks/lookup` is exact-URL and returns only the bookmark
summary (id, title, URL, domain, tags, read/dead flags, created/added times and
favicon). It never returns `note_body`, `extracted_text` or captures. The
normalized lookup covers `www.`, `http`/`https`, trailing slashes, fragments and
known tracking parameters, matching the same deduplication key the save paths
use.

The token scope is intentionally narrow: `capture` may call `whoami`, read
clip templates, call the saved-page lookup, `POST /api/v1/clip`,
`/clip/preview`, and `/quick-save`. Template writes and every other bookmark
read need a browser session or a `write` token.

## Permissions and Firefox data collection

| Permission | Why |
| --- | --- |
| `tabs` | Read the active tab's URL/title for the saved-page indicator. The extension does not enumerate or retain other tabs. |
| `activeTab` | Read the current page only after the user clicks the extension, uses its menu, or presses a shortcut. |
| `scripting` | Inject the extractor for an explicit page-text or selection action. |
| `storage` | Keep the server address, token and defaults in this browser profile. |
| `contextMenus` | The add actions in the page context menu. |
| Optional host access | Ask only for the configured server origin at runtime; there is no static `<all_urls>`. |

Firefox declares `browser_specific_settings.gecko.data_collection_permissions`:
required `browsingActivity` and `bookmarksInfo`, optional `websiteContent`. The
first page-text action requests the optional `websiteContent` consent from a
user gesture; declining it disables page text but not Add bookmark. The full
policy is [extension-privacy.md](extension-privacy.md).

## CORS and origins

The capture family (clip, clip preview, clip templates, whoami, quick-save and
bookmark lookup) sends `OPTIONS` preflight before the auth guard and answers
with `Access-Control-Allow-Origin` for allowed extension origins. Set
`EZA_CLIP_ORIGINS` to a comma-separated exact allowlist when a stable extension
id is used; `chrome-extension://`, `moz-extension://`, and
`safari-web-extension://` origins are also accepted for bearer capture
requests. Do not set `Access-Control-Allow-Credentials`.

## Quick-save and lookup API

```
GET  /api/v1/bookmarks/lookup?url=<encoded URL>   -> 200 {url, bookmark|null}
POST /api/v1/quick-save                          -> 200/201 {id, existing}
```

`quick-save` takes `{"url","title","tags"}`, normalizes the URL, returns the
existing record with `200 {"id","existing":true}` on a duplicate, or inserts a
minimal row, queues enrichment and returns `201 {"id","existing":false}`. The
lookup route requires `url`; it returns `400 bad_request` for a missing,
non-http(s) or over-long URL, `401` without a valid token, and the problem JSON
shape otherwise. Both routes accept a `capture` or `write` token.

## Capture API

```
POST /api/v1/clip
Authorization: Bearer eza_pat_...
Idempotency-Key: <uuid>
Content-Type: application/json
```

Only `url` is required. The payload carries optional `title`,
`content_markdown`, `content_text`, `content_html`, `selection`, `tags`,
`template_id`, `source`, `client`, `captured_at`, and a `metadata` object
(author, site, published, description, language, image, favicon, canonical_url,
extractor, extractor_version, word_count, parse_time_ms). The request hash
ignores timing fields, so an extension retry with the same key returns the
stored result (`replayed: true`) instead of filing twice. A different payload
with the same key returns `409 idempotency_conflict`. The extension persists
one key (and the payload fingerprint it belongs to) per logical save in
`storage.session` and reuses it for its retry loop, so a network retry replays
instead of filing a second capture.

`saveClip` normalizes the URL, inserts or finds the bookmark, attaches a
capture row, applies templates and deterministic save rules, and writes the
rendered Markdown to the note. It fills only empty metadata on an existing
bookmark and never overwrites a note. When the clip contains text the
bookmark is marked extracted; when it does not, the caller queues enrichment.

`POST /api/v1/clip/preview` returns the rendered title, Markdown, tags,
template id/name, and an existing bookmark id without writing.

## Extraction sidecar

The server keeps the in-process Haskell extractor as the default. Set:

```bash
EZA_DEFUDDLE_CMD="node /path/to/eza/sidecar/src/main.mjs"
```

and `Eza.Enrich` sends static pages through the sidecar before falling back to
`Eza.Extract`. The sidecar is a JSON-lines process: one request line in, one
response line out, no network, no state. It is optional; a bare server binary
works without Node.

Install and check it:

```bash
cd sidecar
npm ci
npm run check
npm test
```

The sidecar protocol, limits (5 MiB HTML cap enforced while reading the request
line, 15 s timeout, restart-safe) and response fields are documented in
[sidecar/README.md](../sidecar/README.md). An overlong line answers
`payload_too_large` and the stream resynchronises at the next newline; stdin
backpressure keeps a flood from buffering unbounded input.

## Templates

Clip templates are data, not code. A template is a name, title template,
Markdown body template, default tags, and URL glob/regex triggers. Supported
variables are `title`, `url`, `canonical_url`, `domain`, `site`, `author`,
`published`, `description`, `image`, `language`, `content`, `content_text`,
`selection`, `date`, and `words`; filters include `trim`, `lower`, `upper`,
`truncate:N`, `default:V`, `date:FORMAT`, `first_paragraph`. Invalid variables,
filters, and unsupported regex constructs are rejected with field-specific
errors. The built-in template is read-only.

Manage templates with a browser session:

```
GET    /api/v1/clip-templates
GET    /api/v1/clip-templates/{id}
POST   /api/v1/clip-templates
PATCH  /api/v1/clip-templates/{id}
DELETE /api/v1/clip-templates/{id}
```

The server exposes `captures` through the bookmark's capture table; the API
shape and schema are documented in `Eza.Clip` and `Eza.ClipTemplates`.
