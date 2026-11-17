// Options page: server address, capture token, default template, saved-page
// check toggle, connection test, origin permission, and the Firefox page-text
// consent. The token field starts empty; leaving it empty on save keeps the
// stored token, so the page never hands the secret back to the DOM.

import { getApi } from './src/browser.js';
import {
  accountUrl,
  ensureHostPermission,
  isConfigured,
  loadConfig,
  normalizeServerUrl,
  originPattern,
  saveConfig,
} from './src/config.js';
import { ApiError, listTemplates, lookupBookmark, whoami } from './src/api.js';
import { getPageTextCapability, requestPageTextConsent } from './src/consent.js';
import { EXTENSION_VERSION } from './src/version.js';

const api = getApi();

// A URL that is never saved; the lookup probe only verifies that the server
// exposes the capture-read route and accepts the token.
const LOOKUP_PROBE_URL = 'https://example.com/';

const els = {
  version: document.getElementById('version'),
  serverUrl: document.getElementById('server-url'),
  token: document.getElementById('token'),
  tokenState: document.getElementById('token-state'),
  template: document.getElementById('default-template'),
  checkActivePage: document.getElementById('check-active-page'),
  accountLine: document.getElementById('account-line'),
  accountLink: document.getElementById('account-link'),
  status: document.getElementById('status'),
  save: document.getElementById('save'),
  test: document.getElementById('test'),
  grant: document.getElementById('grant'),
  pageTextSection: document.getElementById('page-text-section'),
  pageTextNote: document.getElementById('page-text-note'),
  pageTextState: document.getElementById('page-text-state'),
  pageTextGrant: document.getElementById('page-text-grant'),
};

const state = {
  config: null,
  templatesLoaded: false,
  pageText: null,
};

async function main() {
  els.version.textContent = 'v' + EXTENSION_VERSION;
  state.config = await loadConfig();
  els.serverUrl.value = state.config.serverUrl || '';
  els.token.value = '';
  els.checkActivePage.checked = state.config.checkActivePage !== false;
  updateTokenState();
  updateAccountLink();
  await refreshPermissionState();
  await loadTemplateOptions();
  await refreshPageTextCapability();
  els.serverUrl.addEventListener('change', () => {
    updateAccountLink();
    void refreshPermissionState();
  });
  els.save.addEventListener('click', () => void save());
  els.test.addEventListener('click', () => void testConnection());
  els.grant.addEventListener('click', grantAccess);
  els.template.addEventListener('change', () => void persist());
  els.checkActivePage.addEventListener('change', () => void persistCheckActivePage());
  els.pageTextGrant.addEventListener('click', () => void grantPageText());
}

function setStatus(message, kind) {
  els.status.textContent = message || '';
  els.status.className = 'status' + (kind ? ' ' + kind : '');
}

function updateTokenState() {
  if (state.config && state.config.captureToken) {
    els.tokenState.textContent = 'A capture token is stored. Leave the field empty to keep it.';
  } else {
    els.tokenState.textContent = 'No token stored yet.';
  }
}

function updateAccountLink() {
  const normalized = normalizeServerUrl(els.serverUrl.value);
  if (!normalized.ok) {
    els.accountLine.hidden = true;
    els.accountLink.removeAttribute('href');
    return;
  }
  els.accountLine.hidden = false;
  els.accountLink.hidden = false;
  els.accountLink.href = accountUrl(normalized.value);
}

async function refreshPermissionState() {
  const normalized = normalizeServerUrl(els.serverUrl.value);
  if (!normalized.ok) {
    els.grant.textContent = 'Grant access';
    els.grant.disabled = false;
    return;
  }
  const pattern = originPattern(normalized.value);
  let granted = false;
  try {
    granted = await api.permissions.contains({ origins: [pattern] });
  } catch {
    granted = false;
  }
  els.grant.textContent = granted ? 'Access granted' : 'Grant access';
  els.grant.disabled = granted;
}

/** Normalize the form and keep the stored token when the field is empty. */
async function readForm() {
  const normalized = normalizeServerUrl(els.serverUrl.value);
  if (!normalized.ok) {
    setStatus(normalized.error, 'err');
    return null;
  }
  const typedToken = els.token.value.trim();
  if (!typedToken && !state.config.captureToken) {
    setStatus('A capture token is required. Create one in eza under Account → Tokens.', 'err');
    return null;
  }
  if (typedToken && /\s/.test(typedToken)) {
    setStatus('The token must not contain whitespace.', 'err');
    return null;
  }
  return {
    serverUrl: normalized.value,
    origin: normalized.origin,
    captureToken: typedToken || state.config.captureToken,
  };
}

async function persist() {
  const form = await readForm();
  if (!form) return false;
  const selected = els.template.options[els.template.selectedIndex];
  state.config = await saveConfig({
    serverUrl: form.serverUrl,
    captureToken: form.captureToken,
    templateId: Number.parseInt(els.template.value, 10) || 0,
    templateName: (selected && selected.textContent) || 'Default',
    checkActivePage: els.checkActivePage.checked,
  });
  els.token.value = '';
  els.serverUrl.value = state.config.serverUrl;
  updateTokenState();
  updateAccountLink();
  await refreshPermissionState();
  await loadTemplateOptions();
  return true;
}

async function save() {
  els.save.disabled = true;
  // Start the permission request while the click is still a user gesture.
  const typed = normalizeServerUrl(els.serverUrl.value);
  const permission = typed.ok ? ensureHostPermission(typed.value) : null;
  try {
    const ok = await persist();
    if (permission) await permission;
    if (ok) setStatus('Saved.', 'ok');
  } catch (error) {
    setStatus(messageOf(error), 'err');
  } finally {
    els.save.disabled = false;
  }
}

async function persistCheckActivePage() {
  try {
    state.config = await saveConfig({ checkActivePage: els.checkActivePage.checked });
    setStatus(
      els.checkActivePage.checked
        ? 'Saved-page checks are on.'
        : 'Saved-page checks are off; adding still works.',
      'ok',
    );
  } catch (error) {
    setStatus(messageOf(error), 'err');
  }
}

async function testConnection() {
  els.test.disabled = true;
  setStatus('Testing connection…', '');
  // Kick the permission request off in the click gesture.
  const typed = normalizeServerUrl(els.serverUrl.value);
  const permission = typed.ok ? ensureHostPermission(typed.value) : null;
  try {
    const form = await readForm();
    if (!form) return;
    if (!(await persist())) return;
    if (permission) await permission;
    const account = await whoami(state.config);
    const scopes = Array.isArray(account.scopes) ? account.scopes.join(', ') : '';
    let message =
      'Connected as ' + (account.username || 'the account') + (scopes ? ' — token scopes: ' + scopes : '') + '.';
    message += await lookupProbeMessage(state.config);
    setStatus(message, 'ok');
    await loadTemplateOptions(true);
  } catch (error) {
    if (error instanceof ApiError) {
      if (error.status === 401) {
        setStatus('The token was rejected (401). Create a new capture token and save it.', 'err');
      } else if (error.status === 403) {
        setStatus(
          'The token is valid but lacks the capture scope, or the server rejected the extension origin (403).',
          'err',
        );
      } else if (error.status === 404) {
        setStatus('This eza server does not expose /api/v1/whoami yet. Update eza.', 'err');
      } else {
        setStatus(error.message, 'err');
      }
    } else {
      setStatus(messageOf(error), 'err');
    }
  } finally {
    els.test.disabled = false;
  }
}

/**
 * Probe GET /api/v1/bookmarks/lookup with a URL that is never saved. A 404
 * means an older server; the extension still adds bookmarks but cannot show
 * saved status.
 * @param {object} config
 * @returns {Promise<string>}
 */
async function lookupProbeMessage(config) {
  try {
    await lookupBookmark(config, LOOKUP_PROBE_URL);
    return ' Saved-page check is available.';
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) {
      return ' This server does not expose the saved-page check yet; update eza to see saved status (adding bookmarks works).';
    }
    if (error instanceof ApiError && (error.status === 401 || error.status === 403)) {
      return ' The saved-page check was rejected (HTTP ' + error.status + ').';
    }
    return ' The saved-page check could not be reached: ' + (error instanceof Error ? error.message : String(error));
  }
}

function grantAccess() {
  setStatus('', '');
  void (async () => {
    const normalized = normalizeServerUrl(els.serverUrl.value);
    if (!normalized.ok) {
      setStatus(normalized.error, 'err');
      return;
    }
    const result = await ensureHostPermission(normalized.value);
    if (!result.ok) {
      setStatus(result.error || 'The browser refused the permission request.', 'err');
      return;
    }
    if (result.granted) {
      setStatus('Access granted for ' + normalized.origin + '.', 'ok');
    } else {
      setStatus('Access was not granted. Adding will fail until the origin is allowed.', 'err');
    }
    await refreshPermissionState();
  })();
}

async function loadTemplateOptions(force) {
  if (!isConfigured(state.config)) return;
  if (state.templatesLoaded && !force) return;
  try {
    const result = await listTemplates(state.config);
    state.templatesLoaded = true;
    const current = String(state.config.templateId || 0);
    els.template.replaceChildren();
    const builtin = document.createElement('option');
    builtin.value = '0';
    builtin.textContent = (result.builtin && result.builtin.name) || 'Default';
    els.template.appendChild(builtin);
    for (const template of result.templates) {
      const option = document.createElement('option');
      option.value = String(template.id);
      option.textContent = template.enabled === false ? template.name + ' (disabled)' : template.name;
      els.template.appendChild(option);
    }
    const wanted = Array.from(els.template.options).some((option) => option.value === current) ? current : '0';
    els.template.value = wanted;
  } catch {
    // Templates need a working token and route; the page still saves the rest.
  }
}

// ---------------------------------------------------------------------------
// Firefox data-collection consent for page text
// ---------------------------------------------------------------------------

async function refreshPageTextCapability() {
  let capability;
  try {
    capability = await getPageTextCapability();
  } catch {
    capability = { supported: false, granted: true, reason: '' };
  }
  state.pageText = capability;
  els.pageTextSection.hidden = !capability.supported;
  if (!capability.supported) return;
  els.pageTextNote.textContent =
    'Firefox asks separately before page text is read and sent to your server. Add bookmark never needs this permission.';
  renderPageTextState(capability);
}

/** @param {{granted: boolean, reason: string}} capability */
function renderPageTextState(capability) {
  if (capability.granted) {
    els.pageTextState.textContent = 'Page text is allowed.';
    els.pageTextGrant.hidden = true;
  } else {
    els.pageTextState.textContent = capability.reason || 'Page text is not allowed yet.';
    els.pageTextGrant.hidden = false;
  }
}

/** @returns {Promise<void>} */
async function grantPageText() {
  // The permission request must be the first await in the click handler.
  const capability = await requestPageTextConsent();
  state.pageText = capability;
  renderPageTextState(capability);
  setStatus(
    capability.granted
      ? 'Page text is allowed.'
      : capability.reason || 'Page text permission was not granted; Add bookmark still works.',
    capability.granted ? 'ok' : 'err',
  );
}

/** @param {unknown} error @returns {string} */
function messageOf(error) {
  if (error instanceof Error) return error.message;
  return String(error);
}

void main();
