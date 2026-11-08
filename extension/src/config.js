// Configuration storage for the clipper.
//
// The capture token lives in chrome.storage.local (never sync, never the URL,
// never a log line). Configuration is validated here so every caller gets the
// same answer about what "configured" means.

export const CONFIG_KEY = 'ezaClipper.config';
export const CONFIG_SCHEMA = 1;

export const DEFAULT_CONFIG = Object.freeze({
  schema: CONFIG_SCHEMA,
  serverUrl: '',
  captureToken: '',
  templateId: 0,
  templateName: 'Default',
});

/**
 * Read the stored configuration, merged over the defaults. Never throws when
 * storage is empty or holds an older shape.
 * @returns {Promise<typeof DEFAULT_CONFIG>}
 */
export async function loadConfig() {
  const stored = await chrome.storage.local.get(CONFIG_KEY);
  const value = stored && stored[CONFIG_KEY];
  if (!value || typeof value !== 'object') return { ...DEFAULT_CONFIG };
  return {
    ...DEFAULT_CONFIG,
    ...value,
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
  await chrome.storage.local.set({ [CONFIG_KEY]: next });
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
 * Origin pattern for chrome.permissions.request/contains.
 * @param {string} serverUrl
 * @returns {string | null}
 */
export function originPattern(serverUrl) {
  const normalized = normalizeServerUrl(serverUrl);
  if (!normalized.ok) return null;
  return normalized.origin + '/*';
}

/**
 * Ask Chrome for access to the configured server origin. Must be called from a
 * user gesture (the options page buttons do).
 * @param {string} serverUrl
 * @returns {Promise<{ok: boolean, granted?: boolean, error?: string}>}
 */
export async function ensureHostPermission(serverUrl) {
  const pattern = originPattern(serverUrl);
  if (!pattern) return { ok: false, error: 'Configure a valid server address first' };
  try {
    // Call request first: it must happen inside the click gesture, and Chrome
    // resolves immediately without a prompt when the origin is already
    // granted. Awaiting contains() first can lose the gesture.
    const granted = await chrome.permissions.request({ origins: [pattern] });
    return { ok: true, granted };
  } catch (error) {
    return { ok: false, error: messageOf(error) };
  }
}

/**
 * Describe a configuration to the UI without exposing the token.
 * @param {typeof DEFAULT_CONFIG} config
 * @returns {{serverUrl: string, hasToken: boolean, templateId: number, templateName: string}}
 */
export function describeConfig(config) {
  return {
    serverUrl: config.serverUrl,
    hasToken: Boolean(config.captureToken),
    templateId: config.templateId,
    templateName: config.templateName,
  };
}

/** @param {unknown} error @returns {string} */
function messageOf(error) {
  if (error instanceof Error) return error.message;
  return String(error);
}
