// Thin wrapper around the eza capture API.
//
// Rules that matter:
//   * The capture token travels only in the Authorization header.
//   * Requests use credentials: 'omit'; the extension never relies on cookies.
//   * One Idempotency-Key per logical save. saveClipWithRetry retries a
//     network failure/timeout/429/5xx with the same key, so the server replays
//     its stored result instead of filing a duplicate capture.
//   * No request or response body is ever logged, and no error message includes
//     the token.

import { apiUrl, isConfigured } from './config.js';
import { CLIENT } from './version.js';

/** A failed API call with the server's error code when there is one. */
export class ApiError extends Error {
  /**
   * @param {string} message
   * @param {{code?: string, status?: number, retryAfter?: number}} [details]
   */
  constructor(message, details = {}) {
    super(message);
    this.name = 'ApiError';
    this.code = details.code || 'unknown';
    this.status = details.status || 0;
    this.retryAfter = details.retryAfter;
  }
}

/**
 * GET /api/v1/whoami — the connection test on the options page.
 * @param {import('./config.js').DEFAULT_CONFIG} config
 * @returns {Promise<{username: string, scopes: string[], token_name: string}>}
 */
export async function whoami(config) {
  return request(config, '/api/v1/whoami', { method: 'GET' });
}

/**
 * GET /api/v1/clip-templates. Returns an empty list when the server predates
 * the route, so the popup can still save with the built-in template.
 * @param {import('./config.js').DEFAULT_CONFIG} config
 * @returns {Promise<{templates: Array<object>, builtin: object | null, supported: boolean}>}
 */
export async function listTemplates(config) {
  try {
    const payload = await request(config, '/api/v1/clip-templates', { method: 'GET' });
    return {
      templates: Array.isArray(payload.templates) ? payload.templates : [],
      builtin: payload.builtin || null,
      supported: true,
    };
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) {
      return { templates: [], builtin: null, supported: false };
    }
    throw error;
  }
}

/**
 * POST /api/v1/clip with an idempotency key.
 * @param {import('./config.js').DEFAULT_CONFIG} config
 * @param {object} payload ClipRequest JSON
 * @param {string} idempotencyKey
 * @returns {Promise<object>} SaveClipResult
 */
export async function saveClip(config, payload, idempotencyKey) {
  if (typeof idempotencyKey !== 'string' || !idempotencyKey) {
    throw new ApiError('The clipper could not create an Idempotency-Key', { code: 'client_error' });
  }
  return request(config, '/api/v1/clip', {
    method: 'POST',
    body: payload,
    idempotencyKey,
  });
}

// Retryable failures: a network error or timeout (the request may have reached
// the server), a 429 (honouring Retry-After) and the 5xx family. Validation,
// auth, and 409 idempotency_conflict are final; retrying them cannot help.
const RETRYABLE_API_CODES = new Set(['timeout', 'network']);
const RETRYABLE_HTTP_STATUS = new Set([408, 425, 429, 500, 502, 503, 504]);
const DEFAULT_RETRY_ATTEMPTS = 3;
const DEFAULT_RETRY_BASE_MS = 500;
const MAX_RETRY_DELAY_MS = 10000;

/**
 * POST /api/v1/clip with one idempotency key and a small retry loop.
 *
 * Every attempt sends the same key and payload, so a retry after a timeout or
 * a dropped response makes the server replay the stored result
 * (`replayed: true`) instead of inserting a second capture. The caller is
 * expected to persist the key for cross-invocation retries (see background.js).
 * @param {import('./config.js').DEFAULT_CONFIG} config
 * @param {object} payload ClipRequest JSON
 * @param {string} idempotencyKey
 * @param {{attempts?: number, baseDelayMs?: number}} [options]
 * @returns {Promise<object>} SaveClipResult
 */
export async function saveClipWithRetry(config, payload, idempotencyKey, options = {}) {
  const attempts =
    Number.isFinite(options.attempts) && options.attempts > 0
      ? Math.min(10, Math.floor(options.attempts))
      : DEFAULT_RETRY_ATTEMPTS;
  const baseDelayMs =
    Number.isFinite(options.baseDelayMs) && options.baseDelayMs >= 0
      ? Math.floor(options.baseDelayMs)
      : DEFAULT_RETRY_BASE_MS;
  let lastError = null;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await saveClip(config, payload, idempotencyKey);
    } catch (error) {
      lastError = error;
      if (!isRetryable(error) || attempt >= attempts) throw error;
      await sleep(retryDelayMs(error, baseDelayMs, attempt));
    }
  }
  throw lastError || new ApiError('The clip could not be saved.', { code: 'unknown' });
}

/** @param {unknown} error @returns {boolean} */
function isRetryable(error) {
  if (!(error instanceof ApiError)) return false;
  if (RETRYABLE_API_CODES.has(error.code)) return true;
  return RETRYABLE_HTTP_STATUS.has(error.status);
}

/**
 * @param {ApiError} error
 * @param {number} baseDelayMs
 * @param {number} attempt
 * @returns {number}
 */
function retryDelayMs(error, baseDelayMs, attempt) {
  const serverHintMs =
    Number.isFinite(error.retryAfter) && error.retryAfter > 0 ? Math.min(error.retryAfter * 1000, MAX_RETRY_DELAY_MS) : 0;
  const exponential = baseDelayMs * 2 ** (attempt - 1);
  const jitter = Math.floor(Math.random() * Math.max(1, Math.floor(baseDelayMs / 2)));
  return Math.min(MAX_RETRY_DELAY_MS, Math.max(serverHintMs, exponential) + jitter);
}

/** @param {number} ms @returns {Promise<void>} */
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Canonical, retry-stable representation of a clip payload: the timing fields
 * that differ between a failed attempt and its retry are dropped. Those are
 * also the fields the server's request hash ignores (captured_at, word_count,
 * parse_time_ms), so reusing the key across a retry still hits the stored
 * result rather than 409 idempotency_conflict.
 * @param {object} payload
 * @returns {string}
 */
export function stablePayload(payload) {
  const copy = { ...payload };
  delete copy.captured_at;
  delete copy.word_count;
  delete copy.parse_time_ms;
  return JSON.stringify(Object.keys(copy).sort().map((key) => [key, copy[key]]));
}

/**
 * Storage-slot name for one logical save: the server URL plus the stable
 * payload. It is not a secret and not a substitute for the server's request
 * hash; it only names the persisted idempotency record so a retry (a second
 * popup click, a re-extracted page) reuses the same key and payload.
 * @param {import('./config.js').DEFAULT_CONFIG} config
 * @param {object} payload
 * @returns {Promise<string>}
 */
export async function payloadFingerprint(config, payload) {
  const material = 'eza-clip-v1\n' + String(config.serverUrl || '') + '\n' + stablePayload(payload);
  const bytes = new TextEncoder().encode(material);
  try {
    if (globalThis.crypto && globalThis.crypto.subtle && typeof globalThis.crypto.subtle.digest === 'function') {
      const digest = await globalThis.crypto.subtle.digest('SHA-256', bytes);
      return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
    }
  } catch {
    // Fall through to the non-cryptographic slot name.
  }
  let hash = 0x811c9dc5;
  for (const byte of bytes) {
    hash ^= byte;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return 'fnv-' + hash.toString(16).padStart(8, '0');
}

/**
 * POST /api/v1/clip/preview. Used by the popup to show the rendered note.
 * @param {import('./config.js').DEFAULT_CONFIG} config
 * @param {object} payload
 * @returns {Promise<object>}
 */
export async function previewClip(config, payload) {
  return request(config, '/api/v1/clip/preview', { method: 'POST', body: payload });
}

/**
 * @param {import('./config.js').DEFAULT_CONFIG} config
 * @param {string} path
 * @param {{method?: string, body?: object, idempotencyKey?: string, timeoutMs?: number}} options
 * @returns {Promise<any>}
 */
async function request(config, path, options = {}) {
  if (!isConfigured(config)) {
    throw new ApiError('Set the eza server address and a capture token in the extension options first.', {
      code: 'not_configured',
    });
  }
  const url = apiUrl(config.serverUrl, path);
  const method = options.method || 'GET';
  const headers = {
    Accept: 'application/json',
    Authorization: 'Bearer ' + config.captureToken,
    'X-Eza-Client': CLIENT,
  };
  let body;
  if (options.body !== undefined) {
    headers['Content-Type'] = 'application/json';
    body = JSON.stringify(options.body);
  }
  if (options.idempotencyKey) {
    headers['Idempotency-Key'] = options.idempotencyKey;
  }

  const controller = new AbortController();
  const timeoutMs = options.timeoutMs || 30000;
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let response;
  try {
    response = await fetch(url, {
      method,
      headers,
      body,
      credentials: 'omit',
      cache: 'no-store',
      redirect: 'follow',
      signal: controller.signal,
    });
  } catch (error) {
    if (controller.signal.aborted) {
      throw new ApiError('The eza server did not answer in time.', { code: 'timeout' });
    }
    throw new ApiError(connectionMessage(config), { code: 'network' });
  } finally {
    clearTimeout(timer);
  }

  const raw = await response.text();
  let payload = null;
  if (raw) {
    try {
      payload = JSON.parse(raw);
    } catch {
      payload = null;
    }
  }

  if (!response.ok) {
    const serverError = payload && payload.error && typeof payload.error === 'object' ? payload.error : {};
    const retryAfter = Number.parseInt(response.headers.get('Retry-After') || '', 10);
    throw new ApiError(
      typeof serverError.message === 'string' && serverError.message
        ? serverError.message
        : httpMessage(response.status),
      {
        code: typeof serverError.code === 'string' ? serverError.code : 'http_' + response.status,
        status: response.status,
        retryAfter: Number.isFinite(retryAfter) ? retryAfter : undefined,
      },
    );
  }
  return payload === null ? {} : payload;
}

/**
 * @param {import('./config.js').DEFAULT_CONFIG} config
 * @returns {string}
 */
function connectionMessage(config) {
  return (
    'Could not reach ' +
    config.serverUrl +
    '. Check the address, that the server is running, and that this extension has access to the origin ' +
    '(Options → Grant access).'
  );
}

/** @param {number} status @returns {string} */
function httpMessage(status) {
  switch (status) {
    case 400:
      return 'The server rejected the clip payload.';
    case 401:
      return 'The capture token is not valid. Create a new token with the capture scope.';
    case 403:
      return 'The token does not have the capture scope, or the server rejected the extension origin.';
    case 404:
      return 'The server does not expose this route. Update eza to a build with clipping.';
    case 409:
      return 'The server reports a conflict (the URL or idempotency key already exists).';
    case 413:
      return 'The clipped content is too large for the server.';
    case 429:
      return 'The server is rate limiting requests. Try again shortly.';
    case 500:
    case 502:
    case 503:
      return 'The eza server hit an internal error.';
    default:
      return 'The eza server answered HTTP ' + status + '.';
  }
}

/**
 * Generate a UUID-shaped idempotency key. crypto.randomUUID is available in
 * the MV3 service worker; the fallback keeps older builds working.
 * @returns {string}
 */
export function newIdempotencyKey() {
  try {
    if (globalThis.crypto && typeof globalThis.crypto.randomUUID === 'function') {
      return globalThis.crypto.randomUUID();
    }
  } catch {
    // Fall through to the manual key.
  }
  const random = () => Math.floor(Math.random() * 0x100000000).toString(16).padStart(8, '0');
  return random() + '-' + random() + '-' + random() + '-' + random();
}
