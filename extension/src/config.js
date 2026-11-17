// Configuration storage for the clipper.
//
// The capture token lives in the extension-local storage area (never sync,
// never a page, never a URL, never a log line). Configuration is validated
// here so every caller gets the same answer about what "configured" means.
//
// This module is imported by the Node test suite, so it must not touch the
// WebExtension namespace at load time: getApi() is called inside the
// functions.

import { getApi } from './browser.js';

export const CONFIG_KEY = 'ezaClipper.config';
export const CONFIG_SCHEMA = 1;

export const DEFAULT_CONFIG = Object.freeze({
  schema: CONFIG_SCHEMA,
  serverUrl: '',
  captureToken: '',
  templateId: 0,
  templateName: 'Default',
  // Refresh the toolbar saved-page indicator for the active tab.
  checkActivePage: true,
});

/**
 * Read the stored configuration, merged over the defaults. Never throws when
 * storage is empty or holds an older shape.
 * @returns {Promise<typeof DEFAULT_CONFIG>}
 */
export async function loadConfig() {
  const stored = await getApi().storage.local.get(CONFIG_KEY);
  const value = stored && stored[CONFIG_KEY];
  if (!value || typeof value !== 'object') return { ...DEFAULT_CONFIG };
  return {
    ...DEFAULT_CONFIG,
    ...value,
    checkActivePage: value.checkActivePage !== false,
    schema: CONFIG_SCHEMA,
  };
}

/**
 * Persist only the fields the clipper owns. The token is stored as given; it
 * is never trimmed into a URL or copied anywhere else.
 * @param {Partial<typeof DEFAULT_CONFIG>} patch
 * @returns {Promise<typeof DEFAULT_CONFIG>}
 */
export async function saveConfig(patch) {
  const current = await loadConfig();
  const next = { ...current, ...patch, schema: CONFIG_SCHEMA };
  await getApi().storage.local.set({ [CONFIG_KEY]: next });
  return next;
}

/**
 * True when a server and a token are present.
 * @param {typeof DEFAULT_CONFIG} config
 * @returns {boolean}
 */
export function isConfigured(config) {
  return Boolean(config && config.serverUrl && config.captureToken);
}

/**
 * Normalize what a user typed into a server base URL.
 *
 * Accepts "eza.example.com", "https://eza.example.com/", or
 * "http://localhost:8000". A missing scheme becomes https. Returns a result
 * object instead of throwing so the options page can show the reason.
 * @param {unknown} raw
 * @returns {{ok: true, value: string, origin: string} | {ok: false, error: string}}
 */
export function normalizeServerUrl(raw) {
  if (typeof raw !== 'string' || !raw.trim()) {
    return { ok: false, error: 'A server address is required, for example https://eza.example.com' };
  }
  let value = raw.trim();
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(value)) {
    value = 'https://' + value;
  }
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    return { ok: false, error: 'That does not look like a URL. Try https://eza.example.com' };
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return { ok: false, error: 'The server address must be http or https' };
  }
  if (!parsed.hostname) {
    return { ok: false, error: 'The server address needs a host name' };
  }
  parsed.hash = '';
  parsed.search = '';
  const pathname = parsed.pathname === '/' ? '' : parsed.pathname.replace(/\/+$/, '');
  const normalized = parsed.origin + pathname;
  return { ok: true, value: normalized, origin: parsed.origin };
}

/**
 * Join the configured base URL and an API path. Path starts with a slash.
 * @param {string} serverUrl
 * @param {string} path
 * @returns {string}
 */
export function apiUrl(serverUrl, path) {
  const base = String(serverUrl || '').replace(/\/+$/, '');
  return base + path;
}

/**
 * URL of one bookmark in the web client.
 * @param {string} serverUrl
 * @param {number} bookmarkId
 * @returns {string}
 */
export function bookmarkUrl(serverUrl, bookmarkId) {
  const base = String(serverUrl || '').replace(/\/+$/, '');
  const id = Number(bookmarkId);
  return Number.isFinite(id) && id > 0 ? base + '/bookmark/' + Math.floor(id) : base + '/';
}

/**
 * URL of the account page in the web client.
 * @param {string} serverUrl
 * @returns {string}
 */
export function accountUrl(serverUrl) {
  return apiUrl(serverUrl, '/account');
}

/**
 * Origin pattern for permissions.request/contains.
 * @param {string} serverUrl
 * @returns {string | null}
 */
export function originPattern(serverUrl) {
  const normalized = normalizeServerUrl(serverUrl);
  if (!normalized.ok) return null;
  return normalized.origin + '/*';
}

/**
 * Ask the browser for access to the configured server origin. Must be called
 * from a user gesture (the popup and options buttons do).
 * @param {string} serverUrl
 * @returns {Promise<{ok: boolean, granted?: boolean, error?: string}>}
 */
export async function ensureHostPermission(serverUrl) {
  const pattern = originPattern(serverUrl);
  if (!pattern) return { ok: false, error: 'Configure a valid server address first' };
  try {
    // Call request first: it must happen inside the click gesture, and the
    // browser resolves immediately without a prompt when the origin is
    // already granted. Awaiting contains() first can lose the gesture.
    const granted = await getApi().permissions.request({ origins: [pattern] });
    return { ok: true, granted: Boolean(granted) };
  } catch (error) {
    return { ok: false, error: messageOf(error) };
  }
}

/**
 * True when the extension may contact the configured server origin.
 * @param {string} serverUrl
 * @returns {Promise<boolean>}
 */
export async function hasHostPermission(serverUrl) {
  const pattern = originPattern(serverUrl);
  if (!pattern) return false;
  try {
    return Boolean(await getApi().permissions.contains({ origins: [pattern] }));
  } catch {
    return false;
  }
}

/**
 * Describe a configuration to the UI without exposing the token.
 * @param {typeof DEFAULT_CONFIG} config
 * @returns {{serverUrl: string, hasToken: boolean, templateId: number, templateName: string, checkActivePage: boolean}}
 */
export function describeConfig(config) {
  return {
    serverUrl: config.serverUrl,
    hasToken: Boolean(config.captureToken),
    templateId: config.templateId,
    templateName: config.templateName,
    checkActivePage: config.checkActivePage !== false,
  };
}

/** @param {unknown} error @returns {string} */
function messageOf(error) {
  if (error instanceof Error) return error.message;
  return String(error);
}
