// Options page: server address, capture token, default template, and the
// connection test. The token field starts empty; leaving it empty on save
// keeps the stored token, so the page never hands the secret back to the DOM.

import {
  ensureHostPermission,
  isConfigured,
  loadConfig,
  normalizeServerUrl,
  originPattern,
  saveConfig,
} from './src/config.js';
import { listTemplates, whoami, ApiError } from './src/api.js';

const els = {
  serverUrl: document.getElementById('server-url'),
  token: document.getElementById('token'),
  tokenState: document.getElementById('token-state'),
  template: document.getElementById('default-template'),
  status: document.getElementById('status'),
  save: document.getElementById('save'),
  test: document.getElementById('test'),
  grant: document.getElementById('grant'),
};

const state = {
  config: null,
  templatesLoaded: false,
};

async function main() {
  state.config = await loadConfig();
  els.serverUrl.value = state.config.serverUrl || '';
  els.token.value = '';
  updateTokenState();
  await refreshPermissionState();
  await loadTemplateOptions();
  els.serverUrl.addEventListener('change', () => void refreshPermissionState());
}

function setStatus(message, kind) {
  els.status.textContent = message;
  els.status.className = kind || '';
}

function updateTokenState() {
  if (state.config.captureToken) {
    els.tokenState.textContent = 'A capture token is stored. Leave the field empty to keep it.';
  } else {
    els.tokenState.textContent = 'No token stored yet.';
  }
}

async function refreshPermissionState() {
  const normalized = normalizeServerUrl(els.serverUrl.value);
  if (!normalized.ok) {
    els.grant.textContent = 'Grant access';
    return;
  }
  const pattern = originPattern(normalized.value);
  let granted = false;
  try {
    granted = await chrome.permissions.contains({ origins: [pattern] });
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
  state.config = await saveConfig({
    serverUrl: form.serverUrl,
    captureToken: form.captureToken,
    templateId: Number.parseInt(els.template.value, 10) || 0,
    templateName:
      (Array.from(els.template.options).find((option) => option.selected) || {}).textContent ||
      'Default',
  });
  els.token.value = '';
  els.serverUrl.value = state.config.serverUrl;
  updateTokenState();
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
    if (ok) {
      setStatus('Saved.', 'ok');
    }
  } catch (error) {
    setStatus(messageOf(error), 'err');
  } finally {
    els.save.disabled = false;
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
    const saved = await persist();
    if (!saved) return;
    if (permission) await permission;
    const result = await whoami(state.config);
    const scopes = Array.isArray(result.scopes) ? result.scopes.join(', ') : '';
    setStatus(
      'Connected as ' +
        (result.username || 'the account') +
        (scopes ? ' — token scopes: ' + scopes : '') +
        '.',
      'ok',
    );
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
      setStatus(result.error || 'Chrome refused the permission request.', 'err');
      return;
    }
    if (result.granted) {
      setStatus('Access granted for ' + normalized.origin + '.', 'ok');
    } else {
      setStatus('Access was not granted. Saving will fail until the origin is allowed.', 'err');
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
    const wanted = Array.from(els.template.options).some((option) => option.value === current)
      ? current
      : '0';
    els.template.value = wanted;
  } catch {
    // Templates need a working token and route; the page still saves the rest.
  }
}

/** @param {unknown} error @returns {string} */
function messageOf(error) {
  if (error instanceof Error) return error.message;
  return String(error);
}

els.save.addEventListener('click', () => void save());
els.test.addEventListener('click', () => void testConnection());
els.grant.addEventListener('click', grantAccess);
els.template.addEventListener('change', () => void persist());

void main();
