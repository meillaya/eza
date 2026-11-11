// eza Defuddle sidecar: JSON lines in, JSON lines out.
//
// Protocol (one JSON object per line on stdin, exactly one response per
// request on stdout, stdout carries nothing else):
//
//   request  { "id": "any string or number", "html": "<html>…",
//              "url": "https://example.com/page",
//              "contentType": "text/html; charset=utf-8",  // optional
//              "charset": "utf-8" }                         // optional
//   success  { "id": …, "ok": true, "extractor": "defuddle",
//              "version": "0.19.6", "sidecar_version": "0.1.0", "schema": 1,
//              "title", "author", "published", "site", "description",
//              "language", "image", "favicon", "content_markdown",
//              "content_text", "word_count", "parse_time_ms" }
//   failure  { "id": …, "ok": false,
//              "error": { "code": "bad_json" | "bad_request" |
//                         "payload_too_large" | "unsupported_content_type" |
//                         "timeout" | "worker_crashed" |
//                         "extract_failed", "message": "…" } }
//
// Properties the server relies on:
//   * No network. Extraction runs with useAsync:false and a rejecting fetch.
//   * 15 s timeout (EZA_SIDECAR_TIMEOUT_MS overrides). A hung page terminates
//     the worker thread and the next request gets a fresh one.
//   * 5 MiB HTML cap. The reader buffers at most MAX_LINE_BYTES (~7 MiB: the
//     JSON encoding overhead on top of the 5 MiB HTML) for the line being read.
//     A longer line is rejected with payload_too_large and skipped to the next
//     newline without being buffered, so one huge request cannot exhaust
//     memory.
//   * Backpressure instead of an unbounded queue: stdin is read chunk by chunk
//     and an extraction is awaited before the next line is accepted, so a fast
//     writer fills the OS pipe, not the sidecar heap. Requests are processed
//     strictly in order, one at a time, and every input line gets exactly one
//     response line. There is no `busy` response: the previous queue counter
//     was unreachable behind a serialized read loop.
//   * Restart safe: malformed input, overlong lines, worker crashes, and
//     timeouts produce an error line rather than killing the process. A parent
//     may kill and restart the process at any time; no state is persisted.
//   * Nothing is written to stdout except response lines.

import { readFileSync } from 'node:fs';
import { Worker } from 'node:worker_threads';

const SIDECAR_VERSION = readSidecarVersion();
const PINNED_DEFUDDLE_VERSION = readPinnedDefuddleVersion();

const MAX_HTML_BYTES = 5 * 1024 * 1024;
// Registry/variant metadata rides in the same JSON line as the HTML; 2 MiB is
// generous for the protocol fields and bounds the read buffer at ~7 MiB.
const MAX_LINE_BYTES = MAX_HTML_BYTES + 2 * 1024 * 1024;
const DEFAULT_TIMEOUT_MS = 15000;
const TIMEOUT_MS = readBoundedInt(process.env.EZA_SIDECAR_TIMEOUT_MS, DEFAULT_TIMEOUT_MS, 1000, 120000);
const NEWLINE = 0x0a;
const CARRIAGE_RETURN = 0x0d;

/** @type {Worker | null} */
let worker = null;
/** @type {{resolve: (value: any) => void, timer: NodeJS.Timeout} | null} */
let pending = null;
let stopping = false;

process.stderr.write(
  `eza sidecar ${SIDECAR_VERSION} ready (defuddle ${PINNED_DEFUDDLE_VERSION}, timeout ${TIMEOUT_MS} ms, cap ${MAX_HTML_BYTES} bytes)\n`,
);

/**
 * Start one worker thread and install listeners that only react while it is
 * still the current worker. A terminated worker cannot settle a newer request.
 * @returns {Worker}
 */
function startWorker() {
  const instance = new Worker(new URL('./worker.mjs', import.meta.url));
  instance.on('message', (message) => {
    if (worker !== instance) return;
    settlePending(message);
  });
  instance.on('error', (error) => {
    if (worker !== instance) return;
    worker = null;
    failPending('worker_crashed', `extraction worker failed: ${messageOf(error)}`);
  });
  instance.on('exit', (code) => {
    if (worker !== instance) return;
    worker = null;
    if (!stopping) {
      failPending('worker_crashed', `extraction worker exited with code ${code}`);
    }
  });
  return instance;
}

function ensureWorker() {
  if (!worker) worker = startWorker();
  return worker;
}

/** @param {any} result */
function settlePending(result) {
  const current = pending;
  pending = null;
  if (!current) return;
  clearTimeout(current.timer);
  current.resolve(result);
}

/**
 * @param {string} code
 * @param {string} message
 */
function failPending(code, message) {
  const current = pending;
  pending = null;
  if (!current) return;
  clearTimeout(current.timer);
  current.resolve({ id: null, ok: false, error: { code, message } });
}

/**
 * Post one validated job to the worker and resolve with its result, or with a
 * timeout error if the worker does not answer in time.
 * @param {any} request
 * @returns {Promise<any>}
 */
function dispatch(request) {
  return new Promise((resolve) => {
    let instance;
    try {
      instance = ensureWorker();
      const timer = setTimeout(() => {
        if (worker === instance) {
          worker = null;
          instance.terminate().catch(() => {});
        }
        const current = pending;
        pending = null;
        if (current) {
          clearTimeout(current.timer);
          current.resolve({
            id: request.id,
            ok: false,
            error: {
              code: 'timeout',
              message: `extraction did not finish within ${TIMEOUT_MS} ms`,
            },
          });
        } else {
          resolve({
            id: request.id,
            ok: false,
            error: {
              code: 'timeout',
              message: `extraction did not finish within ${TIMEOUT_MS} ms`,
            },
          });
        }
      }, TIMEOUT_MS);
      pending = { resolve, timer };
      instance.postMessage({
        id: request.id,
        html: request.html,
        url: request.url,
        contentType: request.contentType,
        charset: request.charset,
      });
    } catch (error) {
      pending = null;
      resolve({
        id: request.id,
        ok: false,
        error: { code: 'worker_crashed', message: messageOf(error) },
      });
    }
  });
}

/**
 * Validate one protocol line and produce the response object.
 * @param {string} line
 * @returns {Promise<any>}
 */
async function handleLine(line) {
  const trimmed = line.trim();
  if (!trimmed) return null;

  let request;
  try {
    request = JSON.parse(trimmed);
  } catch (error) {
    return errorResponse(null, 'bad_json', `request is not valid JSON: ${messageOf(error)}`);
  }

  const validated = validateRequest(request);
  if (!validated.ok) return errorResponse(validated.id, validated.code, validated.message);

  try {
    const result = await dispatch(validated.request);
    return normalizeResult(result, validated.id);
  } catch (error) {
    return errorResponse(validated.id, 'extract_failed', messageOf(error));
  }
}

/**
 * Split a byte stream into protocol lines without buffering more than
 * MAX_LINE_BYTES for the line being read.
 *
 * Reading is pull-based (`for await`), so while an extraction runs no further
 * chunks are read: the kernel pipe fills and the writer blocks. That is the
 * sidecar's real backpressure. An overlong line is reported once as
 * `{ tooLarge: true }`; the rest of it is discarded up to its newline and the
 * next line is parsed normally.
 * @param {AsyncIterable<Buffer>} stream
 * @returns {AsyncGenerator<{ line: string } | { tooLarge: true }>}
 */
async function* readLines(stream) {
  let parts = [];
  let size = 0;
  let discarding = false;
  const reset = () => {
    parts = [];
    size = 0;
  };

  for await (const chunk of stream) {
    let offset = 0;
    while (offset < chunk.length) {
      const newline = chunk.indexOf(NEWLINE, offset);
      const end = newline === -1 ? chunk.length : newline;
      const segment = chunk.subarray(offset, end);

      if (!discarding) {
        if (size + segment.length > MAX_LINE_BYTES) {
          // Drop everything buffered for this line and swallow the rest of it.
          discarding = true;
          reset();
          yield { tooLarge: true };
        } else if (segment.length > 0) {
          parts.push(segment);
          size += segment.length;
        }
      }

      if (newline === -1) {
        offset = chunk.length;
      } else {
        if (discarding) {
          discarding = false;
          reset();
        } else if (size > 0) {
          const bytes = Buffer.concat(parts, size);
          reset();
          yield { line: decodeLine(bytes) };
        }
        offset = newline + 1;
      }
    }
  }

  // EOF without a trailing newline is still a request line.
  if (!discarding && size > 0) {
    yield { line: decodeLine(Buffer.concat(parts, size)) };
  }
}

/**
 * Decode one line as UTF-8, dropping the optional CR of a CRLF terminator.
 * @param {Buffer} bytes
 * @returns {string}
 */
function decodeLine(bytes) {
  let end = bytes.length;
  while (end > 0 && bytes[end - 1] === CARRIAGE_RETURN) end -= 1;
  return bytes.subarray(0, end).toString('utf8');
}

/**
 * @param {any} request
 * @returns {{ok: true, request: any} | {ok: false, id: any, code: string, message: string}}
 */
function validateRequest(request) {
  if (!request || typeof request !== 'object' || Array.isArray(request)) {
    return { ok: false, id: null, code: 'bad_request', message: 'request must be a JSON object' };
  }
  const id = request.id;
  if (typeof id !== 'string' && typeof id !== 'number') {
    return { ok: false, id: null, code: 'bad_request', message: 'request.id must be a string or number' };
  }
  if (typeof request.html !== 'string' || request.html.length === 0) {
    return { ok: false, id, code: 'bad_request', message: 'request.html must be a non-empty string' };
  }
  if (Buffer.byteLength(request.html, 'utf8') > MAX_HTML_BYTES) {
    return {
      ok: false,
      id,
      code: 'payload_too_large',
      message: `request.html must be at most ${MAX_HTML_BYTES} bytes`,
    };
  }
  if (typeof request.url !== 'string' || !isHttpUrl(request.url)) {
    return { ok: false, id, code: 'bad_request', message: 'request.url must be an http(s) URL' };
  }
  if (request.contentType !== undefined && typeof request.contentType !== 'string') {
    return { ok: false, id, code: 'bad_request', message: 'request.contentType must be a string when present' };
  }
  if (request.charset !== undefined && typeof request.charset !== 'string') {
    return { ok: false, id, code: 'bad_request', message: 'request.charset must be a string when present' };
  }
  if ((request.contentType || '').length > 200 || (request.charset || '').length > 64) {
    return { ok: false, id, code: 'bad_request', message: 'request metadata is too long' };
  }
  return { ok: true, request };
}

/**
 * Guarantee the response shape even if the worker returns something odd.
 * @param {any} result
 * @param {any} id
 * @returns {any}
 */
function normalizeResult(result, id) {
  if (!result || typeof result !== 'object' || Array.isArray(result)) {
    return errorResponse(id, 'extract_failed', 'the extraction worker returned no result');
  }
  const withId = { ...result, id: result.id ?? id };
  if (withId.ok === true) return withId;
  if (withId.error && typeof withId.error === 'object') return { ...withId, ok: false };
  return errorResponse(withId.id ?? id, 'extract_failed', 'the extraction worker returned an invalid result');
}

/**
 * @param {any} id
 * @param {string} code
 * @param {string} message
 * @returns {any}
 */
function errorResponse(id, code, message) {
  return { id, ok: false, error: { code, message } };
}

/**
 * Write one line to stdout, waiting for the stream to drain so a throttled
 * parent cannot make the response queue grow without bound.
 * @param {string} line
 * @returns {Promise<void>}
 */
function writeLine(line) {
  return new Promise((resolve) => {
    let flushed = false;
    try {
      flushed = process.stdout.write(line + '\n');
    } catch {
      resolve();
      return;
    }
    if (flushed) {
      resolve();
      return;
    }
    process.stdout.once('drain', resolve);
  });
}

/** @param {any} response @returns {Promise<void>} */
async function respond(response) {
  if (response) await writeLine(JSON.stringify(response));
}

async function main() {
  for await (const item of readLines(process.stdin)) {
    if (item.tooLarge) {
      await respond(
        errorResponse(
          null,
          'payload_too_large',
          `a request line may be at most ${MAX_LINE_BYTES} bytes (${MAX_HTML_BYTES} bytes of HTML plus protocol overhead)`,
        ),
      );
      continue;
    }
    try {
      await respond(await handleLine(item.line));
    } catch (error) {
      await respond(errorResponse(null, 'extract_failed', messageOf(error)));
    }
  }

  await shutdown(0);
}

/**
 * @param {number} code
 */
async function shutdown(code) {
  if (stopping) return;
  stopping = true;
  const current = worker;
  worker = null;
  if (current) {
    try {
      await current.terminate();
    } catch {
      // The worker is already gone; nothing left to clean up.
    }
  }
  process.exit(code);
}

/** @param {unknown} error @returns {string} */
function messageOf(error) {
  if (error instanceof Error) return error.message;
  return String(error);
}

/** @param {string} value @returns {boolean} */
function isHttpUrl(value) {
  return /^https?:\/\//i.test(value.trim());
}

/**
 * @param {string | undefined} raw
 * @param {number} fallback
 * @param {number} minimum
 * @param {number} maximum
 * @returns {number}
 */
function readBoundedInt(raw, fallback, minimum, maximum) {
  if (raw === undefined || raw === '') return fallback;
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(maximum, Math.max(minimum, parsed));
}

/** @returns {string} */
function readSidecarVersion() {
  try {
    const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
    return typeof pkg.version === 'string' ? pkg.version : 'unknown';
  } catch {
    return 'unknown';
  }
}

/** @returns {string} */
function readPinnedDefuddleVersion() {
  try {
    const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
    const dependencies = pkg.dependencies || {};
    return typeof dependencies.defuddle === 'string' ? dependencies.defuddle : 'unknown';
  } catch {
    return 'unknown';
  }
}

process.on('SIGTERM', () => {
  if (stopping) return;
  stopping = true;
  process.exit(0);
});
process.on('SIGINT', () => {
  if (stopping) return;
  stopping = true;
  process.exit(0);
});
process.on('uncaughtException', (error) => {
  process.stderr.write(`eza sidecar uncaught exception: ${messageOf(error)}\n`);
  process.exit(1);
});
process.on('unhandledRejection', (error) => {
  process.stderr.write(`eza sidecar unhandled rejection: ${messageOf(error)}\n`);
  process.exit(1);
});

main().catch((error) => {
  process.stderr.write(`eza sidecar fatal error: ${messageOf(error)}\n`);
  process.exit(1);
});
