// Node tests for the status-lookup and quick-save API calls. Runs with plain
// Node and a stubbed fetch (no browser, no server):
//
//   node test/lookup.mjs
//
// It asserts the contract the background worker relies on:
//   * GET /api/v1/bookmarks/lookup sends exactly one query value, `url`,
//     encoded with encodeURIComponent, and never retries;
//   * the capture token is only ever an Authorization header, never in a URL;
//   * requests use credentials: 'omit' and carry X-Eza-Client;
//   * a 404/401/500/network failure surfaces as an ApiError with the status;
//   * POST /api/v1/quick-save sends {url,title,tags} as JSON and returns
//     {id, existing}.
//
// The token here is a dummy value; it is not a real eza token and never leaves
// this process.

import {
  ApiError,
  LOOKUP_PATH,
  LOOKUP_TIMEOUT_MS,
  QUICK_SAVE_PATH,
  lookupBookmark,
  quickSaveBookmark,
} from '../src/api.js';
import { CLIENT } from '../src/version.js';

const config = {
  schema: 1,
  serverUrl: 'https://eza.test',
  captureToken: 'eza_pat_u1_test_capture_token',
  templateId: 0,
  templateName: 'Default',
  checkActivePage: true,
};

const PAGE_URL = 'https://example.press/ledger/the quiet ledger?ref=a&b=1#section-2';

let failures = 0;

/** @param {string} name @param {unknown} actual @param {unknown} expected */
function check(name, actual, expected) {
  const pass = JSON.stringify(actual) === JSON.stringify(expected);
  if (!pass) {
    failures += 1;
    console.error(`not ok - ${name}\n  expected: ${JSON.stringify(expected)}\n  actual:   ${JSON.stringify(actual)}`);
  } else {
    console.log(`ok - ${name}`);
  }
}

/** @param {string} name @param {boolean} condition */
function checkTruthy(name, condition) {
  if (!condition) {
    failures += 1;
    console.error(`not ok - ${name}`);
  } else {
    console.log(`ok - ${name}`);
  }
}

/** @param {object} body @param {{status?: number}} [options] */
function jsonResponse(body, options = {}) {
  const status = options.status || 200;
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: {
      get: () => null,
    },
    text: async () => JSON.stringify(body),
  };
}

/** @param {unknown} error @returns {string} */
function tokenInUrl(call) {
  return String(call.url).includes(config.captureToken);
}

const originalFetch = globalThis.fetch;

try {
  // 1. The lookup encodes the page URL as one query value and sends the token
  // only in the Authorization header.
  {
    const calls = [];
    globalThis.fetch = async (url, init) => {
      calls.push({ url: String(url), init });
      return jsonResponse({ url: 'https://example.press/ledger/the-quiet-ledger', bookmark: null });
    };
    const result = await lookupBookmark(config, PAGE_URL);
    check('lookup: one request', calls.length, 1);
    const expectedUrl = 'https://eza.test' + LOOKUP_PATH + '?url=' + encodeURIComponent(PAGE_URL);
    check('lookup: URL is the lookup route with one encoded value', calls[0].url, expectedUrl);
    check('lookup: the page URL is encoded', calls[0].url.includes('?url=https%3A%2F%2Fexample.press%2F'), true);
    check('lookup: method is GET', calls[0].init.method, 'GET');
    check('lookup: bearer token header', calls[0].init.headers.Authorization, 'Bearer ' + config.captureToken);
    check('lookup: client header', calls[0].init.headers['X-Eza-Client'], CLIENT);
    check('lookup: no cookie credentials', calls[0].init.credentials, 'omit');
    checkTruthy('lookup: token is not in the URL', !tokenInUrl(calls[0]));
    check('lookup: no bookmark is null', result.bookmark, null);
  }

  // 2. A saved page returns the BookmarkSummary untouched.
  {
    const bookmark = {
      id: 7,
      url: 'https://example.press/ledger/the-quiet-ledger',
      title: 'The Quiet Ledger',
      domain: 'example.press',
      created_at: 1762549200,
      added_at: 1762549200,
      favicon_url: '',
      tags: ['reading'],
      is_read: false,
      is_dead: false,
    };
    globalThis.fetch = async () => jsonResponse({ url: bookmark.url, bookmark });
    const result = await lookupBookmark(config, PAGE_URL);
    check('lookup: saved bookmark is returned', result.bookmark, bookmark);
    check('lookup: normalized URL is returned', result.url, bookmark.url);
  }

  // 3. A 404 (older server) is a single request and an ApiError the background
  // worker maps to "lookup unsupported".
  {
    let calls = 0;
    globalThis.fetch = async () => {
      calls += 1;
      return jsonResponse({ error: { code: 'not_found', message: 'not found' } }, { status: 404 });
    };
    let error = null;
    try {
      await lookupBookmark(config, PAGE_URL);
    } catch (caught) {
      error = caught;
    }
    check('lookup 404: throws an ApiError', error instanceof ApiError, true);
    check('lookup 404: status surfaces', error ? error.status : 0, 404);
    check('lookup 404: not retried', calls, 1);
  }

  // 4. A 500 is not retried either: the status indicator never hammers the
  // server.
  {
    let calls = 0;
    globalThis.fetch = async () => {
      calls += 1;
      return jsonResponse({ error: { code: 'server_error', message: 'boom' } }, { status: 500 });
    };
    let error = null;
    try {
      await lookupBookmark(config, PAGE_URL);
    } catch (caught) {
      error = caught;
    }
    check('lookup 500: throws an ApiError', error instanceof ApiError, true);
    check('lookup 500: status surfaces', error ? error.status : 0, 500);
    check('lookup 500: one request only', calls, 1);
  }

  // 5. A network failure becomes a network ApiError.
  {
    let calls = 0;
    globalThis.fetch = async () => {
      calls += 1;
      throw new TypeError('simulated network drop');
    };
    let error = null;
    try {
      await lookupBookmark(config, PAGE_URL);
    } catch (caught) {
      error = caught;
    }
    check('lookup network: ApiError', error instanceof ApiError, true);
    check('lookup network: code', error ? error.code : '', 'network');
    check('lookup network: one attempt', calls, 1);
  }

  // 6. The lookup timeout is bounded and maps to code "timeout".
  {
    globalThis.fetch = async (url, init) =>
      new Promise((resolve, reject) => {
        init.signal.addEventListener('abort', () => {
          const abort = new Error('aborted');
          abort.name = 'AbortError';
          reject(abort);
        });
      });
    let error = null;
    try {
      await lookupBookmark(config, PAGE_URL, { timeoutMs: 10 });
    } catch (caught) {
      error = caught;
    }
    check('lookup timeout: ApiError', error instanceof ApiError, true);
    check('lookup timeout: code', error ? error.code : '', 'timeout');
  }

  // 7. An empty URL is a client error and never reaches the network.
  {
    let calls = 0;
    globalThis.fetch = async () => {
      calls += 1;
      return jsonResponse({});
    };
    let error = null;
    try {
      await lookupBookmark(config, '   ');
    } catch (caught) {
      error = caught;
    }
    check('lookup empty URL: ApiError', error instanceof ApiError, true);
    check('lookup empty URL: code', error ? error.code : '', 'client_error');
    check('lookup empty URL: no request', calls, 0);
  }

  // 8. Quick-save sends the confirmed title and tags as JSON and reports
  // whether the URL already existed.
  {
    const calls = [];
    globalThis.fetch = async (url, init) => {
      calls.push({ url: String(url), init });
      return jsonResponse({ id: 11, existing: false }, { status: 201 });
    };
    const result = await quickSaveBookmark(config, {
      url: '  https://example.press/ledger/the-quiet-ledger  ',
      title: '  The Quiet Ledger  ',
      tags: [' reading ', 'reading', '', 'design'],
    });
    check('quick-save: one request', calls.length, 1);
    check('quick-save: URL is the quick-save route', calls[0].url, 'https://eza.test' + QUICK_SAVE_PATH);
    check('quick-save: method is POST', calls[0].init.method, 'POST');
    check('quick-save: JSON content type', calls[0].init.headers['Content-Type'], 'application/json');
    const body = JSON.parse(calls[0].init.body);
    check('quick-save: trims the URL', body.url, 'https://example.press/ledger/the-quiet-ledger');
    check('quick-save: trims the title', body.title, 'The Quiet Ledger');
    check('quick-save: de-duplicates tags', body.tags, ['reading', 'design']);
    check('quick-save: bearer token header', calls[0].init.headers.Authorization, 'Bearer ' + config.captureToken);
    check('quick-save: no cookie credentials', calls[0].init.credentials, 'omit');
    checkTruthy('quick-save: token is not in the URL', !tokenInUrl(calls[0]));
    check('quick-save: existing flag is returned', result.existing, false);
    check('quick-save: id is returned', result.id, 11);
  }

  // 9. A quick-save failure surfaces the server status without a retry.
  {
    let calls = 0;
    globalThis.fetch = async () => {
      calls += 1;
      return jsonResponse({ error: { code: 'unauthorized', message: 'token is not valid' } }, { status: 401 });
    };
    let error = null;
    try {
      await quickSaveBookmark(config, { url: 'https://example.press/x' });
    } catch (caught) {
      error = caught;
    }
    check('quick-save 401: ApiError', error instanceof ApiError, true);
    check('quick-save 401: status', error ? error.status : 0, 401);
    check('quick-save 401: not retried', calls, 1);
  }

  // 10. Constants documented for the background worker.
  check('lookup path', LOOKUP_PATH, '/api/v1/bookmarks/lookup');
  check('lookup timeout is 5 seconds', LOOKUP_TIMEOUT_MS, 5000);
} catch (error) {
  failures += 1;
  console.error(`not ok - ${error instanceof Error ? error.stack : error}`);
} finally {
  globalThis.fetch = originalFetch;
}

if (failures > 0) {
  console.error(`\n${failures} lookup check(s) failed`);
  process.exit(1);
}
console.log('\nall lookup checks passed');
