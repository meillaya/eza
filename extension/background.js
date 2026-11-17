// MV3 background worker: the saved-page status indicator, context menus,
// keyboard commands, extraction dispatch, and the popup's action bridge.
//
// Status model
// ------------
// The toolbar title and badge describe the active tab. The worker computes a
// PageStatus object for the tab and sends the same object to the popup, so the
// popup never reads page content to paint itself:
//
//   { tabId, url, title, state, tooltip, badge: {text, color},
//     bookmark: BookmarkSummary|null, error: {code,message,status}|null,
//     lookupSupported, eligible, restricted, configured, checkActivePage,
//     serverUrl, pageText: {supported,granted,reason},
//     canAddBookmark, canAddPageText }
//
// `state` is one of: "loading", "setup", "disabled", "restricted",
// "no-permission", "add", "saved", "error".
//
// Message API (runtime.onMessage, all responses are plain objects):
//   {type:"eza:pageStatus", force?, tabId?}
//       -> {ok:true, status: PageStatus} | {ok:false, error}
//   {type:"eza:addBookmark", url?, title?, tags?, tabId?}
//       -> {ok:true, created, existing, id, message, bookmark, status}
//        | {ok:false, error, status}
//   {type:"eza:addPage", url?, title?, tags?, selectionOnly?, tabId?}
//       -> {ok:true, result, message, bookmark, status}
//        | {ok:false, error, status}
//   {type:"eza:extract", selectionOnly?, tabId?}
//       -> {ok:true, payload, extractor, note} | {ok:false, error}
//
// Security notes:
//   * The capture token is read from extension-local storage and sent only as
//     an Authorization header; it is never placed in a URL, a log line, a
//     message, or a page.
//   * Page text is extracted only inside an explicit add action. Opening the
//     popup or refreshing the toolbar status never reads the page body.
//   * Extraction is read-only: the extractor clones the document and never
//     mutates the page.
//   * One Idempotency-Key per logical save. The key (and the exact payload
//     that first used it) is persisted in session storage keyed by the server
//     URL + stable payload hash, so a retry after a network failure, a double
//     click, or the popup's "Try again" replays the server result instead of
//     filing a second capture.
//   * Server responses are untrusted data: only known fields are read and
//     error text is shown with textContent, never as HTML.

import { getApi } from './src/browser.js';
import { CONFIG_KEY, hasHostPermission, isConfigured, loadConfig } from './src/config.js';
import {
  ApiError,
  lookupBookmark,
  newIdempotencyKey,
  payloadFingerprint,
  quickSaveBookmark,
  saveClipWithRetry,
} from './src/api.js';
import {
  BASE_TITLE,
  CACHE_TTL_MS,
  ERROR_BADGE_COLOR,
  ERROR_BADGE_TEXT,
  badgeForState,
  baseTooltip,
  classifyPageUrl,
  createStatusCache,
  restrictedTooltip,
  savedTooltip,
} from './src/status.js';
import {
  PAGE_TEXT_DENIED_REASON,
  getPageTextCapability,
  pageTextAllowed,
  requestPageTextConsent,
} from './src/consent.js';
import { extractPage } from './src/extract.js';
import { CLIENT } from './src/version.js';

const api = getApi();

const MENU_BOOKMARK = 'eza-add-bookmark';
const MENU_PAGE_TEXT = 'eza-add-page-text';
const MENU_SELECTION = 'eza-add-selection';
const CONTEXT_MENUS = [
  { id: MENU_BOOKMARK, title: 'Add bookmark to eza', contexts: ['page'] },
  { id: MENU_PAGE_TEXT, title: 'Add page text to eza', contexts: ['page'] },
  { id: MENU_SELECTION, title: 'Add selection to eza', contexts: ['selection'] },
];
const LAST_RUN_KEY = 'ezaClipper.lastRun';
// Persisted idempotency records: slot = payloadFingerprint, value = { key,
// payload, expiresAt }. Session storage is cleared when the browser closes,
// which is exactly the window in which a retry can replay.
const IDEMPOTENCY_STORE_KEY = 'ezaClipper.idempotency';
const IDEMPOTENCY_TTL_MS = 10 * 60 * 1000;
const IDEMPOTENCY_MAX_ENTRIES = 32;
const REFRESH_DEBOUNCE_MS = 400;
const ERROR_BADGE_MS = 5000;
const LOOKUP_AUTH_COOLDOWN_MS = 60000;

const RESTRICTED_MESSAGE =
  'This page cannot be added to eza. Browser-internal pages, extension pages, file pages, and local data pages cannot be read by extensions; open a normal http(s) page.';

// 60-second in-memory lookup cache: one key per (server, exact page URL).
const lookupCache = createStatusCache({ ttlMs: CACHE_TTL_MS, maxEntries: 200 });
/** @type {Map<string, Promise<object>>} in-flight lookups, coalesced by key */
const inFlightLookups = new Map();
/** @type {Map<number, object>} last PageStatus per tab */
const statusByTab = new Map();
/** @type {Map<number, ReturnType<typeof setTimeout>>} */
const refreshTimers = new Map();
/** @type {Map<number, ReturnType<typeof setTimeout>>} */
const badgeTimers = new Map();
/** @type {Map<string, Promise<{result: object}>>} in-flight saves by fingerprint */
const inFlightSaves = new Map();

let lookupUnsupported = false;
/** @type {{outcome: object, until: number} | null} */
let authFailure = null;
/** @type {object | null} */
let pageTextCapabilityCache = null;

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

api.runtime.onInstalled.addListener(() => {
  void createContextMenus().catch(() => {});
  void refreshActiveTab({ force: true }).catch(() => {});
});

api.runtime.onStartup.addListener(() => {
  void createContextMenus().catch(() => {});
  void refreshActiveTab({ force: true }).catch(() => {});
});

async function createContextMenus() {
  // removeAll must finish before create, or the newly created items are
  // removed. Chrome signals completion through the callback and returns
  // undefined; Firefox returns a Promise. Support both without ever hanging
  // menu creation if a browser invokes neither form.
  const removed = new Promise((resolve) => {
    const done = () => resolve();
    try {
      const maybe = api.contextMenus.removeAll(() => {
        void api.runtime.lastError;
        done();
      });
      if (maybe && typeof maybe.then === 'function') maybe.then(done, done);
    } catch {
      try {
        const maybe = api.contextMenus.removeAll();
        if (maybe && typeof maybe.then === 'function') maybe.then(done, done);
        else done();
      } catch {
        done();
      }
    }
  });
  await Promise.race([removed, new Promise((resolve) => setTimeout(resolve, 1000))]);
  for (const menu of CONTEXT_MENUS) {
    try {
      api.contextMenus.create(menu, () => {
        void api.runtime.lastError;
      });
    } catch {
      // A duplicate menu id from a raced create is harmless.
    }
  }
}

api.contextMenus.onClicked.addListener((info) => {
  if (!info || typeof info.menuItemId !== 'string') return;
  void runUserAction(async (tab) => {
    if (info.menuItemId === MENU_BOOKMARK) await addBookmark({ tab });
    else if (info.menuItemId === MENU_PAGE_TEXT) await addPageText({ tab, selectionOnly: false });
    else if (info.menuItemId === MENU_SELECTION) await addPageText({ tab, selectionOnly: true });
  });
});

api.commands.onCommand.addListener((command) => {
  if (command === 'add-bookmark') {
    void runUserAction(async (tab) => addBookmark({ tab }));
  } else if (command === 'add-selection') {
    void runUserAction(async (tab) => addPageText({ tab, selectionOnly: true }));
  }
});

api.tabs.onActivated.addListener((activeInfo) => {
  if (!activeInfo || typeof activeInfo.tabId !== 'number') return;
  scheduleRefresh(activeInfo.tabId);
});

api.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (!changeInfo || !tab || !tab.active) return;
  if (!changeInfo.url && !changeInfo.title && changeInfo.status !== 'complete') return;
  scheduleRefresh(tabId, { force: Boolean(changeInfo.url) });
});

api.tabs.onRemoved.addListener((tabId) => {
  forgetTab(tabId);
});

api.storage.onChanged.addListener((changes, areaName) => {
  if (areaName !== 'local' || !changes || !changes[CONFIG_KEY]) return;
  invalidateStatusCaches();
  void refreshActiveTab({ force: true }).catch(() => {});
});

api.permissions.onAdded.addListener(() => {
  invalidateStatusCaches();
  void refreshActiveTab({ force: true }).catch(() => {});
});

api.permissions.onRemoved.addListener(() => {
  invalidateStatusCaches();
  void refreshActiveTab({ force: true }).catch(() => {});
});

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  handleMessage(message, sender)
    .then((response) => {
      try {
        sendResponse(response);
      } catch {
        // The sender went away; nothing to report.
      }
    })
    .catch((error) => {
      try {
        sendResponse({ ok: false, error: publicErrorObject(error) });
      } catch {
        // The sender went away; nothing to report.
      }
    });
  // Keep the response channel open for the async handlers above.
  return true;
});

/**
 * @param {any} message
 * @param {any} sender
 * @returns {Promise<object>}
 */
async function handleMessage(message, sender) {
  if (!message || typeof message !== 'object' || typeof message.type !== 'string') {
    return { ok: false, error: { code: 'bad_request', message: 'The message needs an object with a type.' } };
  }
  switch (message.type) {
    case 'eza:pageStatus':
      return handlePageStatus(message);
    case 'eza:addBookmark':
      return handleAddBookmark(message);
    case 'eza:addPage':
      return handleAddPage(message);
    case 'eza:extract':
      return handleExtract(message);
    default:
      return { ok: false, error: { code: 'unknown_message', message: 'Unknown message type: ' + message.type } };
  }
}

/** @param {any} message @returns {Promise<object>} */
async function handlePageStatus(message) {
  try {
    const tab = await resolveTargetTab(message.tabId);
    // The popup (or the E2E driver) asks on demand: an explicit page-status
    // request checks even when the background tab indicator is disabled.
    const status = await computeStatus(tab, { force: Boolean(message.force), interactive: true });
    await applyTabStatus(tab && tab.id, status);
    return { ok: true, status };
  } catch (error) {
    return { ok: false, error: publicErrorObject(error) };
  }
}

/** @param {any} message @returns {Promise<object>} */
async function handleAddBookmark(message) {
  let tab = null;
  try {
    tab = await resolveTargetTab(message.tabId);
    const url = typeof message.url === 'string' && message.url.trim() ? message.url.trim() : (tab.url || '');
    const result = await addBookmark({ tab, url, title: message.title, tags: message.tags });
    return { ok: true, ...result };
  } catch (error) {
    return {
      ok: false,
      error: publicErrorObject(error),
      status: statusForTab(tab),
    };
  }
}

/** @param {any} message @returns {Promise<object>} */
async function handleAddPage(message) {
  let tab = null;
  try {
    tab = await resolveTargetTab(message.tabId);
    const result = await addPageText({
      tab,
      selectionOnly: Boolean(message.selectionOnly),
      title: message.title,
      tags: message.tags,
    });
    return { ok: true, ...result };
  } catch (error) {
    return {
      ok: false,
      error: publicErrorObject(error),
      status: statusForTab(tab),
    };
  }
}

/** @param {any} message @returns {Promise<object>} */
async function handleExtract(message) {
  try {
    const tab = await resolveTargetTab(message.tabId);
    const extraction = await extractTab(tab, Boolean(message.selectionOnly));
    return { ok: true, payload: extraction.payload, extractor: extraction.extractor, note: extraction.note };
  } catch (error) {
    return { ok: false, error: publicErrorObject(error) };
  }
}

// ---------------------------------------------------------------------------
// Page status
// ---------------------------------------------------------------------------

/**
 * Refresh the active tab's toolbar status. Used by lifecycle and storage
 * events; a failure is cosmetic and is swallowed by the caller.
 * @param {{force?: boolean}} [options]
 * @returns {Promise<object | null>}
 */
async function refreshActiveTab(options = {}) {
  let tab = null;
  try {
    tab = await queryActiveTab();
  } catch {
    return null;
  }
  return refreshTab(tab, options);
}

/**
 * @param {any} tabOrId
 * @param {{force?: boolean}} [options]
 * @returns {Promise<object | null>}
 */
async function refreshTab(tabOrId, options = {}) {
  let tab = null;
  try {
    tab = typeof tabOrId === 'number' ? await getTab(tabOrId) : tabOrId;
  } catch {
    return null;
  }
  if (!tab) return null;
  let status;
  try {
    status = await computeStatus(tab, { force: Boolean(options.force) });
  } catch {
    return null;
  }
  await applyTabStatus(tab.id, status);
  return status;
}

/**
 * Build the PageStatus for one tab. This is the single place that decides the
 * toolbar title, badge, tooltip, and the popup's state; it never reads page
 * content (only the lookup route and the tab's URL/title).
 * @param {any} tab
 * @param {{force?: boolean, interactive?: boolean}} [options]
 * @returns {Promise<object>}
 */
async function computeStatus(tab, options = {}) {
  const config = await loadConfig();
  const capability = await pageTextCapability();
  const status = baseStatus(tab, config, capability);
  const page = classifyPageUrl(status.url);
  status.eligible = page.eligible;
  status.restricted = page.restricted;
  status.canAddBookmark = Boolean(status.configured && page.eligible);
  status.canAddPageText = Boolean(status.configured && page.eligible && pageTextAllowed(capability));

  if (!config.checkActivePage && !options.interactive) {
    // The user turned the background saved-page check off; adding and the
    // on-demand popup check still work.
    status.state = 'disabled';
    status.tooltip = baseTooltip();
    status.badge = badgeForState('add');
    return status;
  }
  if (!status.configured) {
    status.state = 'setup';
    status.tooltip = BASE_TITLE;
    status.badge = badgeForState('add');
    status.canAddBookmark = false;
    status.canAddPageText = false;
    return status;
  }
  if (!page.eligible) {
    status.state = 'restricted';
    status.tooltip = restrictedTooltip();
    status.badge = badgeForState('restricted');
    status.error = { code: 'restricted', message: RESTRICTED_MESSAGE, status: 0 };
    status.canAddBookmark = false;
    status.canAddPageText = false;
    return status;
  }
  if (!(await hasHostPermission(config.serverUrl))) {
    status.state = 'no-permission';
    status.error = {
      code: 'no_permission',
      message:
        'This extension has no access to ' + config.serverUrl + '. Open the options page and use Grant access.',
      status: 0,
    };
    status.canAddBookmark = false;
    status.canAddPageText = false;
    return status;
  }
  const outcome = await lookupOutcome(config, status.url, { force: Boolean(options.force) });
  applyLookupOutcome(status, outcome);
  return status;
}

/**
 * @param {any} tab
 * @param {typeof import('./src/config.js').DEFAULT_CONFIG} config
 * @param {any} capability
 * @returns {object}
 */
function baseStatus(tab, config, capability) {
  const tabId = tab && typeof tab.id === 'number' ? tab.id : null;
  return {
    tabId,
    url: tab && typeof tab.url === 'string' ? tab.url : '',
    title: tab && typeof tab.title === 'string' ? tab.title : '',
    state: 'add',
    tooltip: baseTooltip(),
    badge: badgeForState('add'),
    bookmark: null,
    error: null,
    lookupSupported: !lookupUnsupported,
    eligible: false,
    restricted: false,
    configured: isConfigured(config),
    checkActivePage: config.checkActivePage !== false,
    serverUrl: config.serverUrl || '',
    pageText: {
      supported: Boolean(capability && capability.supported),
      granted: pageTextAllowed(capability),
      reason: (capability && capability.reason) || '',
    },
    canAddBookmark: false,
    canAddPageText: false,
  };
}

/**
 * @param {object} status
 * @param {object} outcome
 */
function applyLookupOutcome(status, outcome) {
  status.badge = badgeForState('add');
  status.tooltip = baseTooltip();
  status.bookmark = null;
  status.error = null;
  if (outcome.kind === 'saved') {
    const bookmark = outcome.bookmark;
    status.state = 'saved';
    status.bookmark = bookmark;
    status.tooltip = savedTooltip((bookmark && bookmark.title) || status.title);
    status.badge = badgeForState('saved');
    return;
  }
  if (outcome.kind === 'unsupported') {
    // An older server without the lookup route: the toolbar simply shows no
    // saved state and Adding still works.
    status.state = 'add';
    status.lookupSupported = false;
    return;
  }
  if (outcome.kind === 'absent') {
    status.state = 'add';
    return;
  }
  status.state = 'error';
  status.error = outcome.error;
  const blocking = outcome.error && (outcome.error.status === 401 || outcome.error.status === 403);
  status.canAddBookmark = !blocking;
  status.canAddPageText = !blocking && pageTextAllowed(status.pageText);
}

/**
 * Look up one exact page URL, coalescing concurrent requests and caching the
 * outcome for CACHE_TTL_MS. Token/scope errors are cached too, so a broken
 * token does not trigger one request per tab activation.
 * @param {typeof import('./src/config.js').DEFAULT_CONFIG} config
 * @param {string} url
 * @param {{force?: boolean}} [options]
 * @returns {Promise<object>} outcome: {kind:"saved"|"absent"|"unsupported"|"error", ...}
 */
async function lookupOutcome(config, url, options = {}) {
  const key = String(config.serverUrl || '') + '\n' + String(url || '');
  const now = Date.now();
  if (authFailure && authFailure.until > now) return authFailure.outcome;
  if (lookupUnsupported) return { kind: 'unsupported' };
  if (!options.force) {
    const cached = lookupCache.get(key);
    if (cached) return cached;
  }
  const pending = inFlightLookups.get(key);
  if (pending) return pending;
  const attempt = (async () => {
    try {
      const payload = await lookupBookmark(config, url);
      const bookmark = payload && payload.bookmark && typeof payload.bookmark === 'object' ? payload.bookmark : null;
      return bookmark ? { kind: 'saved', bookmark } : { kind: 'absent' };
    } catch (error) {
      return lookupFailureOutcome(error);
    }
  })()
    .then((outcome) => {
      lookupCache.set(key, outcome);
      if (outcome.kind === 'unsupported') lookupUnsupported = true;
      if (outcome.kind === 'error' && (outcome.error.status === 401 || outcome.error.status === 403)) {
        authFailure = { outcome, until: Date.now() + LOOKUP_AUTH_COOLDOWN_MS };
      }
      return outcome;
    })
    .finally(() => {
      inFlightLookups.delete(key);
    });
  inFlightLookups.set(key, attempt);
  return attempt;
}

/**
 * @param {unknown} error
 * @returns {object}
 */
function lookupFailureOutcome(error) {
  if (error instanceof ApiError) {
    if (error.status === 404) return { kind: 'unsupported' };
    // A URL the server rejects is simply "not saved" for the badge.
    if (error.status === 400) return { kind: 'absent' };
    return {
      kind: 'error',
      error: {
        code: error.code || 'http_' + (error.status || 0),
        message: error.message,
        status: error.status || 0,
      },
    };
  }
  return { kind: 'error', error: { code: 'network', message: messageOf(error), status: 0 } };
}

/**
 * @param {any} tab
 * @param {typeof import('./src/config.js').DEFAULT_CONFIG} config
 * @param {any} capability
 * @param {{url: string, title: string, tags: string[], bookmarkId: number, lookupSupported: boolean}} saved
 * @returns {object}
 */
function synthesizedSavedStatus(tab, config, capability, saved) {
  const status = baseStatus(tab, config, capability);
  status.state = 'saved';
  status.eligible = true;
  status.restricted = false;
  status.bookmark = {
    id: saved.bookmarkId,
    url: saved.url,
    title: saved.title || status.title,
    domain: domainOf(saved.url),
    created_at: 0,
    added_at: 0,
    favicon_url: '',
    tags: normalizeTags(saved.tags),
    is_read: false,
    is_dead: false,
    snippet: null,
  };
  status.tooltip = savedTooltip(status.bookmark.title || status.title);
  status.badge = badgeForState('saved');
  status.lookupSupported = Boolean(saved.lookupSupported);
  status.canAddBookmark = true;
  status.canAddPageText = pageTextAllowed(capability);
  return status;
}

/**
 * After a successful save, refresh the active tab and make sure a server that
 * cannot answer the lookup still shows the page as saved.
 * @param {{tab: any, url: string, title: string, tags: string[], bookmarkId: number}} saved
 * @returns {Promise<object | null>}
 */
async function statusAfterSave(saved) {
  const config = await loadConfig();
  const capability = await pageTextCapability();
  lookupCache.clear();
  authFailure = null;
  const tab = saved.tab;
  const tabId = tab && typeof tab.id === 'number' ? tab.id : null;
  if (tabId === null) return null;
  let status = null;
  try {
    status = await computeStatus(tab, { force: true, interactive: true });
  } catch {
    status = null;
  }
  if (samePageUrl(tab.url, saved.url) && (!status || status.state !== 'saved')) {
    status = synthesizedSavedStatus(tab, config, capability, {
      url: saved.url,
      title: saved.title,
      tags: saved.tags,
      bookmarkId: saved.bookmarkId,
      lookupSupported: status ? status.lookupSupported : !lookupUnsupported,
    });
  }
  if (status) await applyTabStatus(tabId, status);
  return status;
}

// ---------------------------------------------------------------------------
// Add bookmark (quick-save; no page extraction)
// ---------------------------------------------------------------------------

/**
 * Add a bookmark without reading the page body.
 * @param {{tab: any, url?: string, title?: unknown, tags?: unknown}} options
 * @returns {Promise<{created: boolean, existing: boolean, id: number, bookmark: object | null, message: string, status: object | null}>}
 */
async function addBookmark(options) {
  const tab = options.tab || (await queryActiveTab());
  const config = await loadConfig();
  requireConfigured(config);
  const url = String(options.url || (tab && tab.url) || '').trim();
  const page = classifyPageUrl(url);
  if (!page.eligible) throw new ClipperError(RESTRICTED_MESSAGE, 'restricted');
  await requireHostPermission(config);
  const title =
    typeof options.title === 'string' && options.title.trim()
      ? options.title.trim()
      : String((tab && tab.title) || '').trim();
  const tags = normalizeTags(options.tags);
  let payload;
  try {
    payload = await quickSaveBookmark(config, { url, title, tags });
  } catch (error) {
    await flashActionError(tab && tab.id, error);
    throw error;
  }
  const bookmarkId = payload && Number.isFinite(payload.id) ? payload.id : 0;
  const existing = Boolean(payload && payload.existing);
  const message = existing ? 'Already in your library' : 'Bookmark added';
  const status = await statusAfterSave({ tab, url, title, tags, bookmarkId });
  await recordLastRun({
    ok: true,
    kind: 'bookmark',
    message,
    bookmark_id: bookmarkId,
    existing,
  });
  return {
    created: !existing,
    existing,
    id: bookmarkId,
    bookmark: (status && status.bookmark) || null,
    message,
    status,
  };
}

// ---------------------------------------------------------------------------
// Add page text (clip; extraction only on an explicit action)
// ---------------------------------------------------------------------------

/**
 * Extract the active page (or its selection) and send it through
 * POST /api/v1/clip with one idempotency key.
 * @param {{tab: any, selectionOnly?: boolean, title?: unknown, tags?: unknown}} options
 * @returns {Promise<{result: object, message: string, bookmark: object | null, status: object | null}>}
 */
async function addPageText(options) {
  const tab = options.tab || (await queryActiveTab());
  const config = await loadConfig();
  requireConfigured(config);
  const page = classifyPageUrl(tab && tab.url);
  if (!page.eligible) throw new ClipperError(RESTRICTED_MESSAGE, 'restricted');
  await requireHostPermission(config);
  const capability = await ensurePageTextConsent();
  if (capability.supported && !capability.granted) {
    throw new ClipperError(capability.reason || PAGE_TEXT_DENIED_REASON, 'page_text_consent');
  }
  let extraction;
  try {
    extraction = await extractTab(tab, Boolean(options.selectionOnly));
  } catch (error) {
    await flashActionError(tab && tab.id, error);
    throw error;
  }
  const payload = extraction.payload;
  if (typeof options.title === 'string' && options.title.trim()) payload.title = options.title.trim();
  const tags = normalizeTags(options.tags);
  if (tags.length) payload.tags = tags;
  payload.source = 'extension';
  payload.client = CLIENT;
  payload.captured_at = Math.floor(Date.now() / 1000);
  if (!payload.template_id && Number.isFinite(config.templateId) && config.templateId > 0) {
    payload.template_id = config.templateId;
  }
  if (payload.template_id === 0 || payload.template_id === null) delete payload.template_id;
  let result;
  try {
    ({ result } = await saveWithIdempotency(config, payload));
  } catch (error) {
    await flashActionError(tab && tab.id, error);
    throw error;
  }
  const bookmarkId = Number(result && result.bookmark_id) || 0;
  const message = result && result.replayed
    ? 'Page text already added'
    : result && result.bookmark_created
      ? 'Page text added'
      : 'Page text added to the existing bookmark';
  const status = await statusAfterSave({
    tab,
    url: String(payload.url || tab.url || '').trim(),
    title: String(payload.title || ''),
    tags,
    bookmarkId,
  });
  await recordLastRun({
    ok: true,
    kind: 'page-text',
    message,
    bookmark_id: bookmarkId,
    capture_id: Number(result && result.capture_id) || 0,
  });
  return { result, message, bookmark: (status && status.bookmark) || null, status };
}

/**
 * Run a context-menu or keyboard action, reporting failures on the toolbar.
 * @param {(tab: any) => Promise<unknown>} action
 */
async function runUserAction(action) {
  let tab = null;
  try {
    tab = await queryActiveTab();
  } catch {
    tab = null;
  }
  try {
    await action(tab);
  } catch (error) {
    await flashActionError(tab && tab.id, error);
  }
}

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

/**
 * Extract a tab with the optional Defuddle bundle when it exists, else with
 * the built-in minimal extractor.
 * @param {any} tab
 * @param {boolean} selectionOnly
 * @returns {Promise<{payload: object, extractor: string, note?: string}>}
 */
async function extractTab(tab, selectionOnly) {
  const tabId = tab && tab.id;
  const tabUrl = (tab && tab.url) || '';
  if (typeof tabId !== 'number') throw new ClipperError('No active tab is available.', 'no_tab');
  if (!classifyPageUrl(tabUrl).eligible) throw new ClipperError(RESTRICTED_MESSAGE, 'restricted');
  let payload = null;
  let note = '';
  let extractor = 'minimal-dom';
  try {
    payload = await extractWithDefuddle(tabId);
    if (payload) extractor = 'defuddle';
  } catch {
    note = 'Defuddle extraction failed; used the built-in extractor.';
  }
  if (!payload) {
    const [injection] = await api.scripting.executeScript({
      target: { tabId },
      func: extractPage,
    });
    payload = injection && injection.result;
  }
  if (!payload || typeof payload !== 'object') {
    throw new ClipperError('The page did not return any extractable content.');
  }
  if (selectionOnly && !String(payload.selection || '').trim()) {
    throw new ClipperError('Select some text on the page first, then add the selection.');
  }
  payload.client = CLIENT;
  payload.source = 'extension';
  return { payload, extractor, note };
}

/**
 * Try the optional Defuddle bundle. Returns null when the bundle is absent or
 * the page was not extractable; the caller then falls back to the minimal DOM
 * extractor.
 * @param {number} tabId
 * @returns {Promise<object | null>}
 */
async function extractWithDefuddle(tabId) {
  const bundleUrl = api.runtime.getURL('vendor/defuddle-page.js');
  let available = false;
  try {
    const probe = await fetch(bundleUrl, { cache: 'no-store' });
    available = probe.ok;
  } catch {
    available = false;
  }
  if (!available) return null;
  await api.scripting.executeScript({
    target: { tabId },
    world: 'MAIN',
    files: ['vendor/defuddle-page.js'],
  });
  const results = await api.scripting.executeScript({
    target: { tabId },
    world: 'MAIN',
    func: async () => {
      try {
        const promise = window.__ezaClipperDefuddle;
        if (!promise) return { ok: false, error: 'the extraction bundle did not start' };
        return await promise;
      } catch (error) {
        return { ok: false, error: String((error && error.message) || error) };
      }
    },
  });
  const value = results && results[0] && results[0].result;
  if (!value || value.ok === false || !value.content_markdown) return null;
  return value;
}

// ---------------------------------------------------------------------------
// Saving (one Idempotency-Key per logical save)
// ---------------------------------------------------------------------------

/** @returns {any} */
function idempotencyStore() {
  // Session storage is the right lifetime for a retry window; fall back to
  // local storage on a build that predates it (both are extension-private).
  return api.storage.session || api.storage.local;
}

/**
 * Read the unexpired idempotency records and the one for this fingerprint.
 * @param {string} fingerprint
 * @returns {Promise<{entries: Record<string, any>, record: any | null}>}
 */
async function readIdempotencyRecords(fingerprint) {
  let raw = null;
  try {
    const stored = await idempotencyStore().get(IDEMPOTENCY_STORE_KEY);
    raw = stored && stored[IDEMPOTENCY_STORE_KEY];
  } catch {
    raw = null;
  }
  const entries = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  const now = Date.now();
  const live = {};
  let record = null;
  for (const [slot, value] of Object.entries(entries)) {
    if (!value || typeof value !== 'object' || !Number.isFinite(value.expiresAt) || value.expiresAt <= now) continue;
    live[slot] = value;
    if (slot === fingerprint) record = value;
  }
  return { entries: live, record };
}

/**
 * Persist one record, prune expired ones and cap the total. Best effort: a
 * storage failure must not block the save.
 * @param {string} fingerprint
 * @param {Record<string, any>} entries already-pruned records
 * @param {{key: string, payload: object}} record
 */
async function writeIdempotencyRecord(fingerprint, entries, record) {
  const next = { ...entries, [fingerprint]: { ...record, expiresAt: Date.now() + IDEMPOTENCY_TTL_MS } };
  const slots = Object.keys(next);
  if (slots.length > IDEMPOTENCY_MAX_ENTRIES) {
    slots.sort((a, b) => (next[a].expiresAt || 0) - (next[b].expiresAt || 0));
    for (const slot of slots.slice(0, slots.length - IDEMPOTENCY_MAX_ENTRIES)) delete next[slot];
  }
  try {
    await idempotencyStore().set({ [IDEMPOTENCY_STORE_KEY]: next });
  } catch {
    // The in-flight map still reuses the key for concurrent attempts.
  }
}

/** @param {string} fingerprint */
async function forgetIdempotencyRecord(fingerprint) {
  try {
    const { entries } = await readIdempotencyRecords(fingerprint);
    if (!entries[fingerprint]) return;
    delete entries[fingerprint];
    await idempotencyStore().set({ [IDEMPOTENCY_STORE_KEY]: entries });
  } catch {
    // Best effort: the record expires on its own.
  }
}

/**
 * Send one logical save, reusing the persisted key (and the exact payload that
 * first used it) so a retry replays the server's stored result. Concurrent
 * callers for the same fingerprint share one request.
 * @param {object} config
 * @param {object} payload
 * @returns {Promise<{result: object}>}
 */
async function saveWithIdempotency(config, payload) {
  const fingerprint = await payloadFingerprint(config, payload);
  const pending = inFlightSaves.get(fingerprint);
  if (pending) return pending;
  const attempt = saveOnce(config, payload, fingerprint).finally(() => inFlightSaves.delete(fingerprint));
  inFlightSaves.set(fingerprint, attempt);
  return attempt;
}

/**
 * @param {object} config
 * @param {object} payload
 * @param {string} fingerprint
 * @returns {Promise<{result: object}>}
 */
async function saveOnce(config, payload, fingerprint) {
  const { entries, record } = await readIdempotencyRecords(fingerprint);
  const key = record && typeof record.key === 'string' && record.key ? record.key : newIdempotencyKey();
  // Replay needs the server's request hash to match, so reuse the exact
  // payload from the first attempt when there is one.
  const requestPayload = record && record.payload && typeof record.payload === 'object' ? record.payload : payload;
  // Persist before sending: a crash after the server committed the write still
  // leaves the key for the next click.
  await writeIdempotencyRecord(fingerprint, entries, { key, payload: requestPayload });
  try {
    const result = await saveClipWithRetry(config, requestPayload, key);
    await writeIdempotencyRecord(fingerprint, entries, { key, payload: requestPayload });
    return { result };
  } catch (error) {
    if (error instanceof ApiError && error.status === 409) {
      // Same key, different request: drop the stale record so the user's retry
      // can start from a fresh key instead of hitting the conflict forever.
      await forgetIdempotencyRecord(fingerprint);
      throw new ClipperError(
        'A previous save under this idempotency key used a different payload. Try again to save a fresh capture.',
        'idempotency_conflict',
      );
    }
    throw error;
  }
}

// ---------------------------------------------------------------------------
// Toolbar feedback
// ---------------------------------------------------------------------------

/**
 * Store the last action result for the options page and debugging. Not a
 * secret; the token never enters it.
 * @param {object} record
 */
async function recordLastRun(record) {
  try {
    await api.storage.local.set({ [LAST_RUN_KEY]: { ...record, at: Date.now() } });
  } catch {
    // Storage failures must not mask the action result.
  }
}

/**
 * @param {number | null} tabId
 * @param {object | null} status
 */
async function applyTabStatus(tabId, status) {
  if (typeof tabId !== 'number' || !status) return;
  statusByTab.set(tabId, status);
  const badge = status.badge || badgeForState('add');
  try {
    await api.action.setBadgeText({ tabId, text: badge.text || '' });
  } catch {
    // Cosmetic.
  }
  if (badge.color) {
    try {
      await api.action.setBadgeBackgroundColor({ tabId, color: badge.color });
    } catch {
      // Cosmetic.
    }
  }
  try {
    await api.action.setTitle({ tabId, title: status.tooltip || BASE_TITLE });
  } catch {
    // Cosmetic.
  }
}

/**
 * Show the error badge for ERROR_BADGE_MS, then restore the page's real state.
 * @param {number | null} tabId
 * @param {unknown} error
 */
async function flashActionError(tabId, error) {
  const message = publicErrorMessage(error);
  await recordLastRun({ ok: false, message });
  if (typeof tabId !== 'number') return;
  try {
    await api.action.setBadgeBackgroundColor({ tabId, color: ERROR_BADGE_COLOR });
    await api.action.setBadgeText({ tabId, text: ERROR_BADGE_TEXT });
    await api.action.setTitle({ tabId, title: message });
  } catch {
    // Cosmetic.
  }
  const existing = badgeTimers.get(tabId);
  if (existing) clearTimeout(existing);
  const timer = setTimeout(() => {
    badgeTimers.delete(tabId);
    const status = statusByTab.get(tabId);
    if (status) {
      void applyTabStatus(tabId, status);
    } else {
      try {
        Promise.resolve(api.action.setBadgeText({ tabId, text: '' })).catch(() => {});
      } catch {
        // Cosmetic.
      }
    }
  }, ERROR_BADGE_MS);
  badgeTimers.set(tabId, timer);
}

// ---------------------------------------------------------------------------
// Refresh scheduling
// ---------------------------------------------------------------------------

/**
 * @param {number} tabId
 * @param {{force?: boolean}} [options]
 */
function scheduleRefresh(tabId, options = {}) {
  if (typeof tabId !== 'number') return;
  const existing = refreshTimers.get(tabId);
  if (existing) clearTimeout(existing);
  const timer = setTimeout(() => {
    refreshTimers.delete(tabId);
    void refreshTab(tabId, options).catch(() => {});
  }, REFRESH_DEBOUNCE_MS);
  refreshTimers.set(tabId, timer);
}

/** @param {number} tabId */
function forgetTab(tabId) {
  statusByTab.delete(tabId);
  const refreshTimer = refreshTimers.get(tabId);
  if (refreshTimer) clearTimeout(refreshTimer);
  refreshTimers.delete(tabId);
  const badgeTimer = badgeTimers.get(tabId);
  if (badgeTimer) clearTimeout(badgeTimer);
  badgeTimers.delete(tabId);
}

function invalidateStatusCaches() {
  lookupCache.clear();
  authFailure = null;
  lookupUnsupported = false;
  pageTextCapabilityCache = null;
  statusByTab.clear();
}

// ---------------------------------------------------------------------------
// Configuration, capabilities, and tabs
// ---------------------------------------------------------------------------

/**
 * @returns {Promise<any>}
 */
async function queryActiveTab() {
  let tabs = await api.tabs.query({ active: true, lastFocusedWindow: true });
  if (!tabs || !tabs.length) tabs = await api.tabs.query({ active: true });
  const tab = tabs && tabs[0];
  if (!tab) throw new ClipperError('No active tab is available.', 'no_tab');
  return tab;
}

/**
 * @param {number} tabId
 * @returns {Promise<any>}
 */
async function getTab(tabId) {
  try {
    return await api.tabs.get(tabId);
  } catch {
    throw new ClipperError('That tab is no longer open.', 'no_tab');
  }
}

/**
 * @param {unknown} tabId
 * @returns {Promise<any>}
 */
async function resolveTargetTab(tabId) {
  if (Number.isFinite(tabId)) return getTab(Number(tabId));
  return queryActiveTab();
}

/**
 * @param {typeof import('./src/config.js').DEFAULT_CONFIG} config
 */
function requireConfigured(config) {
  if (!isConfigured(config)) {
    throw new ClipperError(
      'Set the eza server address and a capture token in the extension options first.',
      'not_configured',
    );
  }
}

/**
 * @param {typeof import('./src/config.js').DEFAULT_CONFIG} config
 */
async function requireHostPermission(config) {
  if (await hasHostPermission(config.serverUrl)) return;
  throw new ClipperError(
    'This extension has no access to ' + config.serverUrl + '. Open the options page and use Grant access.',
    'no_permission',
  );
}

/** @returns {Promise<any>} */
async function pageTextCapability() {
  if (pageTextCapabilityCache) return pageTextCapabilityCache;
  const capability = await getPageTextCapability();
  pageTextCapabilityCache = capability;
  return capability;
}

/**
 * Best effort prompt for the optional Firefox page-text permission. From a
 * context menu or command this may run without a usable gesture, in which
 * case the caller reports the reason instead of capturing.
 * @returns {Promise<any>}
 */
async function ensurePageTextConsent() {
  const capability = await pageTextCapability();
  if (!capability.supported || capability.granted) return capability;
  // The background worker has no reliable user gesture here; best effort only.
  const requested = await requestPageTextConsent();
  pageTextCapabilityCache = requested;
  return requested;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/**
 * @param {unknown} tags
 * @returns {string[]}
 */
function normalizeTags(tags) {
  const list = Array.isArray(tags) ? tags : typeof tags === 'string' ? tags.split(',') : [];
  const seen = new Set();
  const out = [];
  for (const raw of list) {
    const tag = String(raw == null ? '' : raw).trim();
    if (!tag) continue;
    const key = tag.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(tag);
    if (out.length >= 100) break;
  }
  return out;
}

/**
 * @param {unknown} left
 * @param {unknown} right
 * @returns {boolean}
 */
function samePageUrl(left, right) {
  const a = String(left || '');
  const b = String(right || '');
  if (!a || !b) return false;
  try {
    const x = new URL(a);
    const y = new URL(b);
    x.hash = '';
    y.hash = '';
    return x.href === y.href;
  } catch {
    return a === b;
  }
}

/** @param {string} rawUrl @returns {string} */
function domainOf(rawUrl) {
  try {
    return new URL(rawUrl).hostname.replace(/^www\./i, '');
  } catch {
    return '';
  }
}

/** @param {any} tab @returns {object | null} */
function statusForTab(tab) {
  if (!tab || typeof tab.id !== 'number') return null;
  return statusByTab.get(tab.id) || null;
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/** A user-facing clipper failure. */
class ClipperError extends Error {
  /**
   * @param {string} message
   * @param {string} [code]
   */
  constructor(message, code = 'clipper_error') {
    super(message);
    this.name = 'ClipperError';
    this.code = code;
  }
}

/** @param {unknown} error @returns {string} */
function publicErrorMessage(error) {
  if (error instanceof ApiError) return error.message;
  if (error instanceof ClipperError) return error.message;
  if (error instanceof Error) return error.message;
  return String(error);
}

/**
 * @param {unknown} error
 * @returns {{code: string, message: string, status?: number}}
 */
function publicErrorObject(error) {
  if (error instanceof ApiError) {
    return { code: error.code || 'api_error', message: error.message, status: error.status || 0 };
  }
  if (error instanceof ClipperError) {
    return { code: error.code || 'clipper_error', message: error.message };
  }
  if (error instanceof Error) return { code: 'error', message: error.message };
  return { code: 'error', message: String(error) };
}

/** @param {unknown} error @returns {string} */
function messageOf(error) {
  if (error instanceof Error) return error.message;
  return String(error);
}
