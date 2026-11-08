# Browser clipper and extraction sidecar

eza can accept a page from a browser extension. The extension extracts the
current DOM with [Defuddle](https://github.com/kepano/defuddle), sends it to
`POST /api/v1/clip`, and the server stores a bookmark plus a capture row. The
server can also use a Node/Defuddle sidecar for pages that arrive without text.

## Extension (Chromium MV3)

Build the optional Defuddle bundle and load the unpacked extension:

```bash
cd extension
npm ci
npm run build:defuddle   # writes dist/ and vendor/defuddle-page.js
```

Open `chrome://extensions`, enable developer mode, choose **Load unpacked**,
and select `extension/dist`. Open the extension options and set:

- **server URL**: e.g. `http://localhost:8000` or the public https origin;
- **capture token**: an API token created in Account > API tokens with the
  `capture` scope;
- **default template**: optional id or name; blank uses trigger/default.

The options page tests `GET /api/v1/whoami` and requests host permission for
the configured origin. The token lives in `chrome.storage.local`; it is sent
only in the `Authorization: Bearer` header, never in a URL or log. Capture
menu entries: **Save to eza** and **Save selection to eza**. The built-in DOM
extractor is the fallback when the Defuddle bundle is not built.

The token scope is intentionally narrow: `capture` may call `whoami`, read
clip templates, `POST /api/v1/clip`, `/clip/preview`, and `/quick-save`.
Template writes and every bookmark read need a browser session or a `write`
token.

## CORS and origins

The clip endpoints send `OPTIONS` preflight before the auth guard and answer
with `Access-Control-Allow-Origin` for allowed extension origins. Set
`EZA_CLIP_ORIGINS` to a comma-separated exact allowlist when a stable extension
id is used; `chrome-extension://`, `moz-extension://`, and
`safari-web-extension://` origins are also accepted for bearer capture
requests. Do not set `Access-Control-Allow-Credentials`.

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
with the same key returns `409 idempotency_conflict`.

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

The sidecar protocol, limits (5 MiB HTML, 15 s timeout, restart-safe) and
response fields are documented in [sidecar/README.md](../sidecar/README.md).

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
