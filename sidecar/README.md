# eza extraction sidecar

A small Node 22 worker that turns saved-page HTML into clean Markdown and
plain text with [Defuddle](https://github.com/kepano/defuddle). The eza server
spawns it, one process per extraction, when `EZA_DEFUDDLE_CMD` is configured;
it extracts pages that the user clipped in the browser extension or that the
importer saved without text. It is deliberately boring: one JSON object per
line in, one JSON object per line out, no network, no state, no database.

The server calls this process from `Eza.Sidecar`, through `Eza.Enrich`, and
falls back to the in-process Haskell extractor on any error. This document is
the protocol the server implements.

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
an unsupported content type, a non-http URL, the 5 MiB HTML cap, an overlong
protocol line (rejected and resynchronised), `text/plain`, and a final healthy
request that proves the worker survived every error.

## Protocol

One JSON object per line on stdin, exactly one JSON response line on stdout.
Nothing else is ever written to stdout; diagnostics go to stderr. Requests are
processed strictly in order (one extraction at a time). The reader applies
backpressure: while an extraction runs it does not read stdin, so a fast writer
fills the OS pipe instead of the sidecar heap. There is no request queue and no
`busy` response. A single line is buffered up to ~7 MiB (5 MiB of HTML plus
protocol overhead); a longer line is rejected with `payload_too_large` and
skipped to the next newline without being buffered.

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
| `payload_too_large` | HTML over 5 MiB, or a line over ~7 MiB (the rest of that line is skipped; the next line is processed normally). |
| `unsupported_content_type` | The content type is neither HTML-family nor `text/plain`. |
| `timeout` | Extraction exceeded the timeout; the worker thread was terminated. The next request gets a fresh worker. |
| `worker_crashed` | The worker thread crashed or exited unexpectedly. The next request gets a fresh worker. |
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
- **5 MiB HTML cap enforced while reading.** The line reader stops buffering a
  line at ~7 MiB, returns `payload_too_large`, discards the rest of that line
  and continues with the next one; the whole line is never accumulated in
  memory. The 5 MiB `html` field check then runs on any line that fits.
- **Backpressure, not a queue.** Reads are pull-based and pause while an
  extraction is in flight, so a faster-than-extraction writer blocks on the
  pipe. The old `busy`/`MAX_QUEUED_REQUESTS` path is gone because reads were
  serialized and the counter could never exceed one.
- **Restart safe.** Malformed JSON, an overlong line, an unsupported page, a
  timeout, or a worker crash produces an error line and the process stays
  alive.
- **Boilerplate removal.** Hidden elements, low-scoring blocks, small images,
  exact/partial ad selectors, and content patterns are all removed by Defuddle
  (`removeHiddenElements`, `removeLowScoring`, `removeSmallImages`, …).
- **Separate Markdown.** `content` stays HTML and `contentMarkdown` carries
  Markdown (`separateMarkdown: true`); the worker derives `content_text` from
  the HTML with linkedom and uses `turndown` only if Defuddle returns HTML but
  no Markdown.

## How the server calls it

`Eza.Enrich` runs one sidecar extraction per page fetch when
`EZA_DEFUDDLE_CMD` is set. `Eza.Sidecar` executes the configured command
through `sh -c`, writes one JSON request line to stdin, and reads one response
line from stdout under a 20-second outer timeout. Any failure — missing
command, timeout, non-zero exit, malformed response, or empty text — falls back
to the in-process Haskell extractor, so the sidecar never blocks enrichment.
The server ignores stderr and never logs the HTML body.

The sidecar's own `EZA_SIDECAR_TIMEOUT_MS` is a backstop; the server's outer
timeout is the bound that protects a worker.

## License

The sidecar code is Apache-2.0, the same license as the rest of eza. Its
dependencies keep their own licenses:

- `defuddle` — MIT ([kepano/defuddle](https://github.com/kepano/defuddle))
- `linkedom` — ISC ([WebReflection/linkedom](https://github.com/WebReflection/linkedom))
- `turndown` — MIT ([mixmark-io/turndown](https://github.com/mixmark-io/turndown))
