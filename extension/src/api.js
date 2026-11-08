// Thin wrapper around the eza capture API.
//
// Rules that matter:
//   * The capture token travels only in the Authorization header.
//   * Requests use credentials: 'omit'; the extension never relies on cookies.
//   * Idempotency-Key is generated once per save and reused on retry.
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
