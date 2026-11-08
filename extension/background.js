// MV3 service worker: context menus, keyboard commands, extraction dispatch,
// and the popup's save/extract bridge.
//
// Security notes:
//   * The capture token is read from chrome.storage.local and sent only as an
//     Authorization header; it is never placed in a URL, a log line, or a
//     message to a content script.
//   * Extraction is read-only. The Defuddle bundle clones the document and the
//     minimal extractor never writes to the page.
//   * Idempotency-Key is generated once per logical save so a retry after a
//     network failure cannot duplicate the bookmark.

import { isConfigured, loadConfig, originPattern } from './src/config.js';
import { ApiError, newIdempotencyKey, saveClip } from './src/api.js';
import { extractPage } from './src/extract.js';
import { CLIENT } from './src/version.js';

const MENU_PAGE = 'eza-save-page';
const MENU_SELECTION = 'eza-save-selection';
const LAST_RUN_KEY = 'ezaClipper.lastRun';
const RESTRICTED_PROTOCOLS = ['chrome:', 'chrome-extension:', 'edge:', 'about:', 'devtools:', 'view-source:', 'file:'];

chrome.runtime.onInstalled.addListener(() => {
  createContextMenus();
});

chrome.runtime.onStartup.addListener(() => {
  createContextMenus();
});

function createContextMenus() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create(
      {
        id: MENU_PAGE,
        title: 'Save to eza',
        contexts: ['page', 'selection'],
      },
      () => void chrome.runtime.lastError,
    );
    chrome.contextMenus.create(
      {
        id: MENU_SELECTION,
        title: 'Save selection to eza',
        contexts: ['selection'],
      },
      () => void chrome.runtime.lastError,
    );
  });
}

chrome.contextMenus.onClicked.addListener((info) => {
  const selectionOnly = info.menuItemId === MENU_SELECTION;
  void saveActiveTab(selectionOnly).catch((error) => showFailure(error));
});

chrome.commands.onCommand.addListener((command) => {
  if (command !== 'save-page' && command !== 'save-selection') return;
  void saveActiveTab(command === 'save-selection').catch((error) => showFailure(error));
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || typeof message !== 'object') return false;
  const type = message.type;
  if (type === 'eza:extract') {
    extractActiveTab(Boolean(message.selectionOnly))
      .then((result) => sendResponse({ ok: true, ...result }))
      .catch((error) => sendResponse({ ok: false, error: publicError(error) }));
    return true;
  }
  if (type === 'eza:save') {
    saveRequest(message.payload)
      .then((result) => sendResponse({ ok: true, ...result }))
      .catch((error) => sendResponse({ ok: false, error: publicError(error), status: error instanceof ApiError ? error.status : 0 }));
    return true;
  }
  if (type === 'eza:save-active') {
    saveActiveTab(Boolean(message.selectionOnly))
      .then((result) => sendResponse({ ok: true, ...result }))
      .catch((error) => sendResponse({ ok: false, error: publicError(error) }));
    return true;
  }
  return false;
});

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

/**
 * Extract the active tab with Defuddle when the optional bundle exists, else
 * with the built-in minimal extractor.
 * @param {boolean} selectionOnly
 * @returns {Promise<{payload: object, extractor: string, note?: string}>}
 */
async function extractActiveTab(selectionOnly) {
  const tab = await activeTab();
  return extractTab(tab, selectionOnly);
}

/**
 * @param {chrome.tabs.Tab} tab
 * @param {boolean} selectionOnly
 * @returns {Promise<{payload: object, extractor: string, note?: string}>}
 */
async function extractTab(tab, selectionOnly) {
  const tabId = tab.id;
  const tabUrl = tab.url || '';
  if (typeof tabId !== 'number') throw new ClipperError('No active tab is available.');
  if (!tabUrl || isRestrictedUrl(tabUrl)) {
    throw new ClipperError('This page cannot be clipped in a browser context. Open a normal http(s) page.');
  }
  const config = await loadConfig();
  let payload = null;
  let note = '';
  let extractor = 'minimal-dom';
  try {
    payload = await extractWithDefuddle(tabId);
    if (payload) {
      extractor = 'defuddle';
    }
  } catch (error) {
    note = 'Defuddle extraction failed; used the built-in extractor.';
  }
  if (!payload) {
    const [injection] = await chrome.scripting.executeScript({
      target: { tabId },
      func: extractPage,
    });
    payload = injection && injection.result;
  }
  if (!payload || typeof payload !== 'object') {
    throw new ClipperError('The page did not return any extractable content.');
  }
  if (selectionOnly && !String(payload.selection || '').trim()) {
    throw new ClipperError('Select some text on the page first, then save the selection.');
  }
  payload.client = CLIENT;
  payload.source = 'extension';
  if (!payload.template_id && config.templateId > 0) payload.template_id = config.templateId;
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
  const bundleUrl = chrome.runtime.getURL('vendor/defuddle-page.js');
  let available = false;
  try {
    const probe = await fetch(bundleUrl, { cache: 'no-store' });
    available = probe.ok;
  } catch {
    available = false;
  }
  if (!available) return null;
  await chrome.scripting.executeScript({
    target: { tabId },
    world: 'MAIN',
    files: ['vendor/defuddle-page.js'],
  });
  const results = await chrome.scripting.executeScript({
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

/** @param {string} url @returns {boolean} */
function isRestrictedUrl(url) {
  const lowered = String(url).toLowerCase();
  return RESTRICTED_PROTOCOLS.some((protocol) => lowered.startsWith(protocol));
}

// ---------------------------------------------------------------------------
// Saving
// ---------------------------------------------------------------------------

/**
 * Extract and immediately save the active tab (context menu/keyboard).
 * @param {boolean} selectionOnly
 */
async function saveActiveTab(selectionOnly) {
  const { payload } = await extractActiveTab(selectionOnly);
  return saveRequest(payload);
}

/**
 * @param {object} payload
 * @returns {Promise<{result: object, status: number}>}
 */
async function saveRequest(payload) {
  const config = await loadConfig();
  if (!isConfigured(config)) {
    throw new ClipperError('Set the eza server address and a capture token in the extension options first.');
  }
  if (payload.selection === undefined) payload.selection = '';
  if (!payload.source) payload.source = 'extension';
  if (!payload.client) payload.client = CLIENT;
  if (!Number.isFinite(payload.captured_at)) payload.captured_at = Math.floor(Date.now() / 1000);
  if (payload.template_id === null || payload.template_id === 0) delete payload.template_id;
  const allowed = await hasOriginPermission(config.serverUrl);
  if (!allowed) {
    throw new ClipperError(
      'This extension has no access to ' + config.serverUrl + '. Open the extension options and use Grant access.',
    );
  }
  const key = newIdempotencyKey();
  const result = await saveClip(config, payload, key);
  const record = {
    at: Date.now(),
    ok: true,
    title: result.title || payload.title || '',
    bookmarkId: result.bookmark_id || 0,
    captureId: result.capture_id || 0,
    replayed: Boolean(result.replayed),
    created: Boolean(result.bookmark_created),
    message: result.replayed
      ? 'Already saved (idempotent replay).'
      : result.bookmark_created
        ? 'Saved as a new bookmark.'
        : 'Added to the existing bookmark.',
  };
  await chrome.storage.local.set({ [LAST_RUN_KEY]: record });
  await showSuccess(record);
  return { result, record };
}

/**
 * @param {string} serverUrl
 * @returns {Promise<boolean>}
 */
async function hasOriginPermission(serverUrl) {
  try {
    const pattern = originPattern(serverUrl);
    if (!pattern) return false;
    return await chrome.permissions.contains({ origins: [pattern] });
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Feedback
// ---------------------------------------------------------------------------

/** @param {{message: string}} record */
async function showSuccess(record) {
  await setBadge(record.replayed ? 'OK' : 'OK', '#1f6f43');
  void chrome.action.setTitle({ title: record.message });
  clearBadgeLater();
}

/** @param {unknown} error */
async function showFailure(error) {
  const message = publicError(error);
  try {
    await chrome.storage.local.set({
      [LAST_RUN_KEY]: { at: Date.now(), ok: false, message },
    });
  } catch {
    // Storage failures must not mask the original error.
  }
  await setBadge('!', '#8a2b20');
  void chrome.action.setTitle({ title: message });
  clearBadgeLater();
}

/** @param {string} text @param {string} color */
async function setBadge(text, color) {
  try {
    await chrome.action.setBadgeBackgroundColor({ color });
    await chrome.action.setBadgeText({ text });
  } catch {
    // Badge failures are cosmetic.
  }
}

let badgeTimer = null;

function clearBadgeLater() {
  if (badgeTimer) clearTimeout(badgeTimer);
  badgeTimer = setTimeout(() => {
    badgeTimer = null;
    void chrome.action.setBadgeText({ text: '' });
  }, 5000);
}

// ---------------------------------------------------------------------------
// Errors and tabs
// ---------------------------------------------------------------------------

/** A user-facing clipper failure. */
class ClipperError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ClipperError';
  }
}

/** @param {unknown} error @returns {string} */
function publicError(error) {
  if (error instanceof ApiError) return error.message;
  if (error instanceof ClipperError) return error.message;
  if (error instanceof Error) return error.message;
  return String(error);
}

/** @returns {Promise<chrome.tabs.Tab>} */
async function activeTab() {
  const tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  const tab = tabs && tabs[0];
  if (!tab) throw new ClipperError('No active tab is available.');
  return tab;
}
