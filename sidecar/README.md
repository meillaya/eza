# eza extraction sidecar

A small Node 22 worker that turns saved-page HTML into clean Markdown and
plain text with [Defuddle](https://github.com/kepano/defuddle). The eza server
may spawn it to extract pages that the user clipped in the browser extension
or that the importer saved without text. It is deliberately boring: one JSON
object per line in, one JSON object per line out, no network, no state, no
database.

The Haskell modules `Eza.Clip` and `Eza.ClipTemplates` do not call this
process. The Lead wires the process call in `Eza.Server`/`Eza.Enrich`; this
document is the protocol those callers need.

## Requirements

- Node 22 or newer (`node --version`).
- `npm ci` (or `npm install`) once, for the pinned dependencies:
  `defuddle@0.19.6`, `linkedom@0.18.15`, `turndown@7.2.5`.
- No network access is needed at extraction time. The package install needs a
  registry once.

## Commands

```bash
cd sidecar
npm ci                # reproducible install from package-lock.json
npm run check         # node --check on every entry point
npm test              # spawn the sidecar, run the fixture and error cases
npm start             # run the worker on stdin/stdout
```

`npm test` is the acceptance check. It covers a real fixture, malformed JSON,
an unsupported content type, a non-http URL, the 5 MiB cap, `text/plain`, and a
final healthy request that proves the worker survived every error.

## Protocol

One JSON object per line on stdin, exactly one JSON response line on stdout.
Nothing else is ever written to stdout; diagnostics go to stderr. Requests are
processed strictly in order (one extraction at a time).

### Request

```json
{
  "id": "8b1f…",
  "html": "<!doctype html>…",
  "url": "https://example.com/article",
  "contentType": "text/html; charset=utf-8",
  "charset": "utf-8"
}
```

| Field | Required | Notes |
| --- | --- | --- |
| `id` | yes | String or number, echoed on the response. The caller correlates timeouts with it. |
| `html` | yes | The page HTML **already decoded to UTF-8**. At most 5 MiB (`5 * 1024 * 1024` bytes). |
| `url` | yes | The page URL; must start with `http://` or `https://`. Used for relative URL resolution, not fetched. |
| `contentType` | no | Defaults to `text/html`. `text/html` and `application/xhtml+xml` are extracted as HTML; `text/plain` is wrapped in a `<pre>`; anything else is rejected. |
| `charset` | no | Accepted for protocol compatibility and length-validated. The caller does the byte-to-UTF-8 decoding, so the value is metadata only. |

### Response — success

```json
{
  "id": "8b1f…",
  "ok": true,
  "extractor": "defuddle",
  "version": "0.19.6",
  "sidecar_version": "0.1.0",
  "schema": 1,
  "title": "The Quiet Ledger",
  "author": "Ada Lovelace",
  "published": "2024-03-01T10:00:00Z",
  "site": "The Example Press",
  "description": "…",
  "language": "en",
  "image": "https://example.com/images/cover.jpg",
  "favicon": "https://example.com/favicon.ico",
  "content_markdown": "# The Quiet Ledger\n\n…",
  "content_text": "The Quiet Ledger\n\nBy Ada Lovelace\n\n…",
  "word_count": 118,
  "parse_time_ms": 84
}
```

`schema` is the result-schema version (`1`). `version` is the installed
Defuddle version; `sidecar_version` is this package's version. All string
fields may be `""` when the page does not declare them. `published` is
whatever ISO-8601-ish string Defuddle found (not normalized to a timestamp).
`image` and `favicon` are absolute `http(s)` URLs or `""`; `favicon` falls
back to `origin + "/favicon.ico"`. `content_markdown` and `content_text` are
capped at 500,000 characters each.

### Response — failure

```json
{ "id": "8b1f…", "ok": false, "error": { "code": "timeout", "message": "extraction did not finish within 15000 ms" } }
```

| Code | Meaning |
| --- | --- |
| `bad_json` | The line was not valid JSON. `id` is `null`. |
| `bad_request` | Missing/typed-wrong `id`, `html`, `url`, `contentType`, or `charset`; non-http URL. |
| `payload_too_large` | HTML over 5 MiB (or a line over ~7 MiB). |
| `unsupported_content_type` | The content type is neither HTML-family nor `text/plain`. |
| `timeout` | Extraction exceeded the timeout; the worker thread was terminated. The next request gets a fresh worker. |
| `worker_crashed` | The worker thread crashed or exited unexpectedly. The next request gets a fresh worker. |
| `busy` | More than 64 requests were already queued. |
| `extract_failed` | Defuddle threw while parsing the page. |

A parent process may kill and restart the sidecar at any time; it keeps no
state between requests.

## Guarantees

- **No network.** Defuddle runs with `useAsync: false` plus a `fetch` override
  that rejects, so an extractor that tries to fetch a remote API fails instead
  of reaching the network. Nothing else in the sidecar opens a socket.
- **15 s timeout.** The main thread owns a worker thread and terminates it if
  an extraction does not answer in time, then serves the next request from a
  fresh worker. Override with `EZA_SIDECAR_TIMEOUT_MS` (1000–120000).
- **5 MiB HTML cap.** A larger request is rejected before Defuddle sees it.
- **Restart safe.** Malformed JSON, an unsupported page, a timeout, or a worker
  crash produces an error line and the process stays alive.
- **Boilerplate removal.** Hidden elements, low-scoring blocks, small images,
  exact/partial ad selectors, and content patterns are all removed by Defuddle
  (`removeHiddenElements`, `removeLowScoring`, `removeSmallImages`, …).
- **Separate Markdown.** `content` stays HTML and `contentMarkdown` carries
  Markdown (`separateMarkdown: true`); the worker derives `content_text` from
  the HTML with linkedom and uses `turndown` only if Defuddle returns HTML but
  no Markdown.

## Wiring from Haskell

Suggested shape for the caller (Lead owns this code; it is not in `Eza.Clip`):

1. One long-lived process per server (`createProcess`, `std_in = CreatePipe`,
   `std_out = CreatePipe`, `std_err = Inherit`), restarted lazily if it exits.
2. Write one JSON object per line (aeson `encode` + `\n`) with a fresh
   `id` (e.g. the bookmark id plus an attempt counter).
3. Read exactly one line, decode it, and drop/respawn the process on timeout
   (use `System.Timeout.timeout` around the read). The sidecar's own timeout
   is a backstop; the caller still needs an outer bound so a wedged pipe cannot
   block a worker thread.
4. Log stderr only. Never log the HTML body.

## License

The sidecar code is Apache-2.0, the same license as the rest of eza. Its
dependencies keep their own licenses:

- `defuddle` — MIT ([kepano/defuddle](https://github.com/kepano/defuddle))
- `linkedom` — ISC ([WebReflection/linkedom](https://github.com/WebReflection/linkedom))
- `turndown` — MIT ([mixmark-io/turndown](https://github.com/mixmark-io/turndown))
