// Node tests for the pure status helpers used by the toolbar indicator.
//
//   node test/status.mjs
//
// Covers the URL policy, tooltip strings, badge model, title truncation, and
// the bounded 60-second lookup cache. No browser, no server, no dependencies.

import {
  BASE_TITLE,
  CACHE_TTL_MS,
  ERROR_BADGE_COLOR,
  ERROR_BADGE_TEXT,
  MAX_TITLE_LENGTH,
  RESTRICTED_TITLE,
  SAVED_BADGE_COLOR,
  SAVED_BADGE_TEXT,
  SAVED_TITLE_PREFIX,
  badgeForState,
  baseTooltip,
  classifyPageUrl,
  createStatusCache,
  isBookmarkableUrl,
  restrictedTooltip,
  savedTooltip,
  truncateTitle,
} from '../src/status.js';

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

// ---------------------------------------------------------------- tooltips

check('base tooltip', baseTooltip(), 'eza — add bookmark');
check('restricted tooltip', restrictedTooltip(), 'eza — this page cannot be bookmarked');
check('saved tooltip names the bookmark', savedTooltip('The Quiet Ledger'), 'eza — in your library: The Quiet Ledger');
check('saved tooltip without a title', savedTooltip(''), 'eza — in your library');
check('saved tooltip collapses whitespace', savedTooltip('  The\n Quiet   Ledger '), 'eza — in your library: The Quiet Ledger');
check('tooltip constants are the documented strings', [BASE_TITLE, RESTRICTED_TITLE, SAVED_TITLE_PREFIX], [
  'eza — add bookmark',
  'eza — this page cannot be bookmarked',
  'eza — in your library',
]);

// ------------------------------------------------------------ title truncation

check('short title unchanged', truncateTitle('Short title'), 'Short title');
check('blank title is empty', truncateTitle(null), '');
const longTitle = 'A'.repeat(MAX_TITLE_LENGTH + 40);
const truncated = truncateTitle(longTitle);
checkTruthy('long title is truncated to the limit', truncated.length === MAX_TITLE_LENGTH);
checkTruthy('truncated title ends with an ellipsis', truncated.endsWith('…'));
checkTruthy('custom truncation limit is honoured', truncateTitle('abcdef', 4) === 'abc…');

// --------------------------------------------------------------- URL policy

const eligible = [
  'https://example.press/ledger/the-quiet-ledger',
  'http://localhost:8000/bookmark/3',
  'https://example.press/a?q=one#frag',
];
for (const url of eligible) {
  check('eligible URL: ' + url, classifyPageUrl(url).eligible, true);
  check('bookmarkable URL: ' + url, isBookmarkableUrl(url), true);
}

const restricted = [
  'chrome://settings',
  'chrome-extension://abcdefghijklmnop/popup.html',
  'moz-extension://1234-5678/popup.html',
  'edge://extensions',
  'about:blank',
  'file:///tmp/article.html',
  'data:text/html,hello',
  'blob:https://example.press/1234',
  'devtools://devtools/bundled/inspector.html',
  'view-source:https://example.press/',
  'ftp://example.press/file',
  'javascript:alert(1)',
  'mailto:someone@example.com',
  '',
  'not a url',
  'https://',
];
for (const url of restricted) {
  const result = classifyPageUrl(url);
  check('restricted URL: ' + url, result.eligible, false);
  check('restricted URL reason: ' + url, result.restricted, true);
  check('not bookmarkable: ' + url, isBookmarkableUrl(url), false);
}
check('https origin without a path is eligible', classifyPageUrl('https://example.press').eligible, true);
check('a URL normalized to an http host is eligible', classifyPageUrl('http:///path').eligible, true);
check('whitespace-only URL is restricted', classifyPageUrl('   ').restricted, true);
check('non-string URL is restricted', classifyPageUrl(null).restricted, true);
check('classify keeps the protocol', classifyPageUrl('chrome://settings').protocol, 'chrome:');

// ---------------------------------------------------------------- badge model

check('saved badge', badgeForState('saved'), { text: '✓', color: '#1f6f43' });
check('error badge', badgeForState('error'), { text: '!', color: '#8a2b20' });
for (const state of ['add', 'loading', 'setup', 'disabled', 'restricted', 'saved?', undefined, null]) {
  check('badge clears for ' + String(state), badgeForState(state), { text: '', color: null });
}
check('saved constants', [SAVED_BADGE_TEXT, SAVED_BADGE_COLOR], ['✓', '#1f6f43']);
check('error constants', [ERROR_BADGE_TEXT, ERROR_BADGE_COLOR], ['!', '#8a2b20']);

// --------------------------------------------------------------- status cache

check('cache TTL is 60 seconds', CACHE_TTL_MS, 60000);
{
  let now = 1000;
  const cache = createStatusCache({ ttlMs: 1000, maxEntries: 2, now: () => now });
  cache.set('a', { kind: 'saved' });
  check('cache returns a fresh value', cache.get('a'), { kind: 'saved' });
  now += 999;
  check('cache returns a value just before expiry', cache.get('a'), { kind: 'saved' });
  now += 2;
  check('cache expires after the TTL', cache.get('a'), undefined);
  check('expired entries are pruned', cache.size(), 0);
}
{
  let now = 0;
  const cache = createStatusCache({ ttlMs: 60000, maxEntries: 2, now: () => now });
  cache.set('a', 1);
  cache.set('b', 2);
  cache.set('c', 3);
  check('cache is bounded', cache.size(), 2);
  check('cache evicts the oldest entry', cache.get('a'), undefined);
  check('cache keeps newer entries', [cache.get('b'), cache.get('c')], [2, 3]);
  cache.set('b', 20);
  cache.set('d', 4);
  check('re-setting an entry refreshes its order', cache.get('c'), undefined);
  check('re-set value survives', cache.get('b'), 20);
  check('delete removes one entry', cache.delete('b'), true);
  check('deleting an absent entry is false', cache.delete('missing'), false);
  cache.clear();
  check('clear empties the cache', cache.size(), 0);
  cache.set('x', 1);
  now += 60000;
  cache.prune();
  check('prune removes expired entries', cache.size(), 0);
  cache.set('', 1);
  check('empty keys are ignored', cache.get(''), undefined);
  check('unset keys are undefined', cache.get('nope'), undefined);
}
check('an impossible TTL falls back to 60 seconds', createStatusCache({ ttlMs: 0 }).ttlMs, CACHE_TTL_MS);
check('an impossible size falls back to the default cap', createStatusCache({ maxEntries: 0 }).maxEntries, 128);

if (failures > 0) {
  console.error(`\n${failures} status check(s) failed`);
  process.exit(1);
}
console.log('\nall status checks passed');
