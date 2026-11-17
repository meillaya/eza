// Pure status helpers for the toolbar saved-page indicator.
//
// Everything here is deterministic and free of WebExtension APIs so the Node
// test suite can exercise the URL policy, tooltip strings, badge model, title
// truncation, and the bounded lookup cache without a browser.

/** Tooltip for an eligible page that is not known to be saved. */
export const BASE_TITLE = 'eza — add bookmark';

/** Tooltip for a page the extension cannot read or bookmark. */
export const RESTRICTED_TITLE = 'eza — this page cannot be bookmarked';

/** Prefix of the tooltip for a page that is in the library. */
export const SAVED_TITLE_PREFIX = 'eza — in your library';

/** Badge shown for a saved page. */
export const SAVED_BADGE_TEXT = '✓';
export const SAVED_BADGE_COLOR = '#1f6f43';

/** Badge shown briefly after a failed add action. */
export const ERROR_BADGE_TEXT = '!';
export const ERROR_BADGE_COLOR = '#8a2b20';

/** Lookup results are kept in memory for at most this long. */
export const CACHE_TTL_MS = 60000;

/** Longest saved title used in a tooltip before it is truncated. */
export const MAX_TITLE_LENGTH = 72;

const TRUNCATION_SUFFIX = '…';

/**
 * Classify a URL for the bookmarking UI.
 *
 * Only absolute http(s) URLs with a host are eligible. Browser-internal and
 * local schemes are reported as restricted rather than invalid so the popup
 * can explain why the page cannot be added.
 * @param {unknown} rawUrl
 * @returns {{eligible: boolean, restricted: boolean, reason: string, protocol: string}}
 */
export function classifyPageUrl(rawUrl) {
  if (typeof rawUrl !== 'string' || !rawUrl.trim()) {
    return { eligible: false, restricted: true, reason: 'missing_url', protocol: '' };
  }
  let parsed;
  try {
    parsed = new URL(rawUrl.trim());
  } catch {
    return { eligible: false, restricted: true, reason: 'invalid_url', protocol: '' };
  }
  const protocol = parsed.protocol.toLowerCase();
  if (protocol !== 'http:' && protocol !== 'https:') {
    return { eligible: false, restricted: true, reason: 'protocol', protocol };
  }
  if (!parsed.hostname) {
    return { eligible: false, restricted: true, reason: 'missing_host', protocol };
  }
  return { eligible: true, restricted: false, reason: '', protocol };
}

/**
 * @param {unknown} rawUrl
 * @returns {boolean}
 */
export function isBookmarkableUrl(rawUrl) {
  return classifyPageUrl(rawUrl).eligible;
}

/** @returns {string} */
export function baseTooltip() {
  return BASE_TITLE;
}

/** @returns {string} */
export function restrictedTooltip() {
  return RESTRICTED_TITLE;
}

/**
 * Tooltip for a page that is in the library.
 * @param {unknown} title
 * @returns {string}
 */
export function savedTooltip(title) {
  const clean = truncateTitle(title);
  return clean ? SAVED_TITLE_PREFIX + ': ' + clean : SAVED_TITLE_PREFIX;
}

/**
 * Collapse whitespace and shorten a title for a tooltip.
 * @param {unknown} title
 * @param {number} [maxLength]
 * @returns {string}
 */
export function truncateTitle(title, maxLength = MAX_TITLE_LENGTH) {
  const clean = String(title == null ? '' : title)
    .replace(/\s+/g, ' ')
    .trim();
  const limit = Number.isFinite(maxLength) && maxLength > 1 ? Math.floor(maxLength) : MAX_TITLE_LENGTH;
  if (clean.length <= limit) return clean;
  return clean.slice(0, limit - TRUNCATION_SUFFIX.length) + TRUNCATION_SUFFIX;
}

/**
 * Badge model for one page state.
 *
 * `saved` shows a check on the library green, `error` an exclamation mark on
 * the error red, and every other state clears the badge.
 * @param {unknown} state
 * @returns {{text: string, color: string | null}}
 */
export function badgeForState(state) {
  if (state === 'saved') return { text: SAVED_BADGE_TEXT, color: SAVED_BADGE_COLOR };
  if (state === 'error') return { text: ERROR_BADGE_TEXT, color: ERROR_BADGE_COLOR };
  return { text: '', color: null };
}

/**
 * A small insertion-ordered cache with a TTL and a hard entry cap.
 *
 * The background worker uses it for lookup outcomes: a saved page does not
 * trigger a capture-read request every time the tab is activated, and the
 * cache is bounded so a long browsing session cannot grow it without limit.
 * @param {{ttlMs?: number, maxEntries?: number, now?: () => number}} [options]
 * @returns {{
 *   readonly ttlMs: number,
 *   readonly maxEntries: number,
 *   get: (key: string) => unknown,
 *   set: (key: string, value: unknown) => void,
 *   delete: (key: string) => boolean,
 *   clear: () => void,
 *   prune: () => void,
 *   size: () => number,
 * }}
 */
export function createStatusCache(options = {}) {
  const ttlMs = Number.isFinite(options.ttlMs) && options.ttlMs > 0 ? Math.floor(options.ttlMs) : CACHE_TTL_MS;
  const maxEntries =
    Number.isFinite(options.maxEntries) && options.maxEntries >= 1 ? Math.floor(options.maxEntries) : 128;
  const now = typeof options.now === 'function' ? options.now : Date.now;
  /** @type {Map<string, {value: unknown, expiresAt: number}>} */
  const entries = new Map();

  function prune() {
    const timestamp = now();
    for (const [key, entry] of entries) {
      if (!entry || entry.expiresAt <= timestamp) entries.delete(key);
    }
    while (entries.size > maxEntries) {
      const oldest = entries.keys().next();
      if (oldest.done) break;
      entries.delete(oldest.value);
    }
  }

  return {
    ttlMs,
    maxEntries,
    /** @param {string} key */
    get(key) {
      if (typeof key !== 'string' || !key) return undefined;
      const entry = entries.get(key);
      if (!entry) return undefined;
      if (entry.expiresAt <= now()) {
        entries.delete(key);
        return undefined;
      }
      return entry.value;
    },
    /** @param {string} key @param {unknown} value */
    set(key, value) {
      if (typeof key !== 'string' || !key) return;
      if (entries.has(key)) entries.delete(key);
      entries.set(key, { value, expiresAt: now() + ttlMs });
      prune();
    },
    /** @param {string} key */
    delete(key) {
      return entries.delete(key);
    },
    clear() {
      entries.clear();
    },
    prune,
    size() {
      prune();
      return entries.size;
    },
  };
}
