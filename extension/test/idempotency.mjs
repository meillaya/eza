// Node test for the clipper's idempotency contract. Runs with plain Node and a
// stubbed fetch (no browser, no server):
//
//   node test/idempotency.mjs
//
// It asserts the properties the popup/background rely on:
//   * saveClipWithRetry retries a transient network failure with the SAME
//     Idempotency-Key (that is what makes the server replay instead of filing
//     a second capture);
//   * two saves with the same key see the server's replayed:true response;
//   * final errors (4xx that are not 429) are not retried;
//   * the stable payload/fingerprint ignores the timing fields the server's
//     request hash ignores, so a re-extracted retry keeps the same slot;
//   * the capture token only appears in the Authorization header, never in the
//     URL.
//
// The token here is a dummy value; it is not a real eza token and never leaves
// this process.

import { ApiError, payloadFingerprint, saveClip, saveClipWithRetry, stablePayload } from '../src/api.js';

const config = {
  schema: 1,
  serverUrl: 'https://eza.test',
  captureToken: 'eza_pat_test_capture_token',
  templateId: 0,
  templateName: 'Default',
};

const basePayload = {
  url: 'https://example.press/ledger/the-quiet-ledger',
  title: 'The Quiet Ledger',
  selection: '',
  tags: ['reading'],
  source: 'extension',
  client: 'eza-clipper/0.1.0',
  content_markdown: '# The Quiet Ledger',
  content_text: 'The Quiet Ledger',
  captured_at: 1762549200,
};

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

/** @param {object} body @param {{status?: number, retryAfter?: string}} [options] */
function jsonResponse(body, options = {}) {
  const status = options.status || 200;
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: {
      get: (name) => (String(name).toLowerCase() === 'retry-after' && options.retryAfter ? options.retryAfter : null),
    },
    text: async () => JSON.stringify(body),
  };
}

const originalFetch = globalThis.fetch;

try {
  // 1. A transient failure is retried with the same key.
  {
    const calls = [];
    let attempt = 0;
    globalThis.fetch = async (url, init) => {
      calls.push({ url: String(url), headers: init.headers });
      attempt += 1;
      if (attempt === 1) throw new TypeError('simulated network drop');
      return jsonResponse({ capture_id: 7, bookmark_id: 3, bookmark_created: true, replayed: false });
    };
    const result = await saveClipWithRetry(config, basePayload, 'key-network-retry', {
      attempts: 3,
      baseDelayMs: 1,
    });
    check('retry: save eventually succeeds', result.bookmark_id, 3);
    check('retry: two attempts were made', calls.length, 2);
    check('retry: same Idempotency-Key on both attempts', calls[1].headers['Idempotency-Key'], calls[0].headers['Idempotency-Key']);
    check('retry: key is the caller key', calls[0].headers['Idempotency-Key'], 'key-network-retry');
    checkTruthy('retry: URL is the clip endpoint', calls[0].url === 'https://eza.test/api/v1/clip');
    checkTruthy('retry: token is only in the Authorization header', calls[0].headers.Authorization === 'Bearer ' + config.captureToken);
    checkTruthy('retry: token is not in the URL', !calls.some((call) => call.url.includes(config.captureToken)));
  }

  // 2. Two saves with the same key: the second one is a server replay.
  {
    const seen = new Set();
    globalThis.fetch = async (url, init) => {
      const key = init.headers['Idempotency-Key'];
      if (seen.has(key)) {
        return jsonResponse({ capture_id: 7, bookmark_id: 3, replayed: true });
      }
      seen.add(key);
      return jsonResponse({ capture_id: 7, bookmark_id: 3, bookmark_created: true, replayed: false });
    };
    const first = await saveClip(config, basePayload, 'key-replay');
    const second = await saveClip(config, basePayload, 'key-replay');
    check('replay: first save is not a replay', first.replayed, false);
    check('replay: second save with the same key replays', second.replayed, true);
  }

  // 3. A final 4xx (not 429) is not retried.
  {
    let calls = 0;
    globalThis.fetch = async () => {
      calls += 1;
      return jsonResponse({ error: { code: 'bad_request', message: 'url is invalid' } }, { status: 400 });
    };
    let error = null;
    try {
      await saveClipWithRetry(config, basePayload, 'key-final', { attempts: 3, baseDelayMs: 1 });
    } catch (caught) {
      error = caught;
    }
    checkTruthy('final error: throws an ApiError', error instanceof ApiError);
    check('final error: status surfaces', error ? error.status : 0, 400);
    check('final error: not retried', calls, 1);
  }

  // 4. A 429 with Retry-After is retried (bounded by the options).
  {
    let calls = 0;
    globalThis.fetch = async () => {
      calls += 1;
      if (calls === 1) {
        return jsonResponse({ error: { code: 'rate_limited', message: 'slow down' } }, { status: 429, retryAfter: '0' });
      }
      return jsonResponse({ capture_id: 1, bookmark_id: 1, replayed: false });
    };
    const result = await saveClipWithRetry(config, basePayload, 'key-429', { attempts: 2, baseDelayMs: 1 });
    check('429: retried and succeeded', calls, 2);
    check('429: result returned', Boolean(result.capture_id), true);
  }

  // 5. Retry-stable payload and storage slot.
  {
    const retried = { ...basePayload, captured_at: 1762549999, parse_time_ms: 42, word_count: 9 };
    check('stable payload: timing fields ignored', stablePayload(basePayload), stablePayload(retried));
    const fp1 = await payloadFingerprint(config, basePayload);
    const fp2 = await payloadFingerprint(config, retried);
    check('fingerprint: stable across retries', fp1, fp2);
    const other = await payloadFingerprint(config, { ...basePayload, title: 'Different title' });
    checkTruthy('fingerprint: differs for a different payload', fp1 !== other);
    const otherServer = await payloadFingerprint({ ...config, serverUrl: 'https://other.test' }, basePayload);
    checkTruthy('fingerprint: scoped to the server', fp1 !== otherServer);
    checkTruthy('fingerprint: usable as a storage slot name', /^[0-9a-f]{64}$/.test(fp1));
  }
} catch (error) {
  failures += 1;
  console.error(`not ok - ${error instanceof Error ? error.stack : error}`);
} finally {
  globalThis.fetch = originalFetch;
}

if (failures > 0) {
  console.error(`\n${failures} idempotency check(s) failed`);
  process.exit(1);
}
console.log('\nall idempotency checks passed');
