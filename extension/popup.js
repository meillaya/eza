// Popup: show the active page's saved state, then add the bookmark or the page
// text on an explicit click.
//
// The popup never extracts the page while opening and never reads the stored
// token: it talks to the background worker through the message API and paints
// the PageStatus it receives. Page text is extracted only after the user picks
// "Add page text" / "Add selection", optionally asking for Firefox's
// website-content consent first.

import { getApi } from './src/browser.js';
import { bookmarkUrl, ensureHostPermission } from './src/config.js';
import { PAGE_TEXT_DENIED_REASON, requestPageTextConsent } from './src/consent.js';
import { EXTENSION_VERSION } from './src/version.js';

const api = getApi();

const PANELS = ['loading', 'setup', 'add', 'saved', 'done', 'error'];

const els = {
  loading: document.getElementById('loading-panel'),
  setup: document.getElementById('setup-panel'),
  add: document.getElementById('add-panel'),
  saved: document.getElementById('saved-panel'),
  done: document.getElementById('done-panel'),
  error: document.getElementById('error-panel'),
  version: document.getElementById('version'),
  pageUrl: document.getElementById('page-url'),
  title: document.getElementById('title'),
  tags: document.getElementById('tags'),
  lookupNote: document.getElementById('lookup-note'),
  permissionNote: document.getElementById('permission-note'),
  pageTextNote: document.getElementById('page-text-note'),
  addBookmark: document.getElementById('add-bookmark'),
  addPageText: document.getElementById('add-page-text'),
  grantAccess: document.getElementById('grant-access'),
  addStatus: document.getElementById('add-status'),
  savedTitle: document.getElementById('saved-title'),
  savedUrl: document.getElementById('saved-url'),
  savedTags: document.getElementById('saved-tags'),
  savedRead: document.getElementById('saved-read'),
  savedPageTextNote: document.getElementById('page-text-note-saved'),
  openInEza: document.getElementById('open-in-eza'),
  savedAddPageText: document.getElementById('saved-add-page-text'),
  savedStatus: document.getElementById('saved-status'),
  doneText: document.getElementById('done-text'),
  doneOpenLibrary: document.getElementById('done-open-library'),
  doneAgain: document.getElementById('done-again'),
  errorText: document.getElementById('error-text'),
  retry: document.getElementById('retry'),
  errorOpenOptions: document.getElementById('error-open-options'),
};

const state = {
  status: null,
  busy: false,
  lastServerUrl: '',
  lastBookmarkId: 0,
};

const OPEN_IN_EZA_TEXT = 'Open in eza';

function show(panel) {
  for (const key of PANELS) {
    if (!els[key]) continue;
    els[key].hidden = key !== panel;
  }
}

function messageOf(error) {
  if (error instanceof Error) return error.message;
  return String(error);
}

/**
 * Send one message to the background worker. A worker that is starting up or
 * unavailable must become a visible error, not an unhandled rejection.
 * @param {object} message
 * @returns {Promise<object>}
 */
async function send(message) {
  try {
    const response = await api.runtime.sendMessage(message);
    if (!response || typeof response !== 'object') {
      return { ok: false, error: { code: 'no_response', message: 'The background worker did not answer.' } };
    }
    return response;
  } catch (error) {
    return {
      ok: false,
      error: { code: 'background_unavailable', message: 'The background worker is not available. Reload the extension and try again: ' + messageOf(error) },
    };
  }
}

function setStatus(element, message, kind) {
  if (!element) return;
  element.textContent = message || '';
  element.className = 'status' + (kind ? ' ' + kind : '');
}

function setBusy(busy) {
  state.busy = busy;
  for (const button of [els.addBookmark, els.addPageText, els.savedAddPageText]) {
    if (button) button.disabled = busy;
  }
}

async function main() {
  show('loading');
  state.status = null;
  const response = await send({ type: 'eza:pageStatus' });
  if (!response.ok) {
    showError((response.error && response.error.message) || 'The page status could not be read.', true);
    return;
  }
  renderStatus(response.status || { state: 'error', error: { message: 'The page status is missing.' } });
}

function renderStatus(status) {
  state.status = status;
  state.lastServerUrl = status.serverUrl || '';
  if (status.state === 'saved') {
    renderSaved(status);
    show('saved');
    return;
  }
  if (status.state === 'setup') {
    show('setup');
    return;
  }
  if (status.state === 'restricted') {
    showError(status.error && status.error.message ? status.error.message : 'This page cannot be added to eza.', false);
    return;
  }
  if (status.state === 'error') {
    showError(status.error && status.error.message ? status.error.message : 'The saved-page check failed.', true);
    return;
  }
  renderAdd(status);
  show('add');
}

function renderAdd(status) {
  els.pageUrl.textContent = status.url || '';
  els.title.value = status.title || '';
  els.tags.value = '';
  setStatus(els.addStatus, '', '');
  const canAddBookmark = Boolean(status.configured) && status.state !== 'no-permission';
  els.addBookmark.disabled = !canAddBookmark;
  // Keep the page-text button clickable when Firefox still needs consent: the
  // click is the user gesture that can open the permission prompt.
  els.addPageText.disabled = !canAddBookmark;
  els.grantAccess.hidden = status.state !== 'no-permission';
  els.permissionNote.hidden = status.state !== 'no-permission';
  els.permissionNote.textContent = status.state === 'no-permission' && status.error ? status.error.message : '';
  const note = pageTextNote(status);
  els.pageTextNote.hidden = !note;
  els.pageTextNote.textContent = note;
  if (status.state === 'disabled') {
    els.lookupNote.hidden = false;
    els.lookupNote.textContent = 'Saved-page checks are turned off in Options.';
  } else if (status.lookupSupported === false) {
    els.lookupNote.hidden = false;
    els.lookupNote.textContent = 'This server does not support the saved-page check yet. Adding still works.';
  } else {
    els.lookupNote.hidden = true;
    els.lookupNote.textContent = '';
  }
}

function renderSaved(status) {
  const bookmark = status.bookmark || {};
  state.lastBookmarkId = Number(bookmark.id) || 0;
  els.savedTitle.textContent = bookmark.title || status.title || 'Saved page';
  els.savedUrl.textContent = bookmark.url || status.url || '';
  const tags = Array.isArray(bookmark.tags) ? bookmark.tags.filter(Boolean) : [];
  els.savedTags.textContent = tags.length ? tags.join(', ') : 'No tags';
  els.savedRead.textContent = bookmark.is_read ? 'Read' : 'Unread';
  els.savedAddPageText.disabled = !status.configured;
  const note = pageTextNote(status);
  els.savedPageTextNote.hidden = !note;
  els.savedPageTextNote.textContent = note;
  setStatus(els.savedStatus, '', '');
  els.openInEza.textContent = OPEN_IN_EZA_TEXT;
}

/** @param {object} status @returns {string} */
function pageTextNote(status) {
  if (!status.pageText) return '';
  if (!status.pageText.supported) return '';
  if (status.pageText.granted) return '';
  return status.pageText.reason || '';
}

async function addBookmark() {
  if (state.busy || !state.status) return;
  const status = state.status;
  if (!status.canAddBookmark) return;
  setBusy(true);
  setStatus(els.addStatus, 'Adding bookmark…', '');
  try {
    const response = await send({
      type: 'eza:addBookmark',
      url: status.url,
      title: els.title.value,
      tags: splitTags(els.tags.value),
    });
    if (!response.ok) {
      setBusy(false);
      showError((response.error && response.error.message) || 'The bookmark could not be added.', true);
      return;
    }
    renderDone(response.message || 'Bookmark added', response.status, response.id);
  } finally {
    setBusy(false);
  }
}

async function addPageText(fromSaved) {
  if (state.busy || !state.status) return;
  const status = state.status;
  const capability = await ensurePageTextConsent(status);
  if (capability.supported && !capability.granted) {
    showError(capability.reason || PAGE_TEXT_DENIED_REASON, false);
    return;
  }
  setBusy(true);
  const statusElement = fromSaved ? els.savedStatus : els.addStatus;
  setStatus(statusElement, 'Reading the page…', '');
  try {
    const message = {
      type: 'eza:addPage',
      url: status.url,
      title: fromSaved ? '' : els.title.value,
      tags: fromSaved ? [] : splitTags(els.tags.value),
      selectionOnly: false,
    };
    const response = await send(message);
    if (!response.ok) {
      setBusy(false);
      showError((response.error && response.error.message) || 'The page text could not be added.', true);
      return;
    }
    const bookmarkId = Number(response.bookmark && response.bookmark.id) || 0;
    renderDone(response.message || 'Page text added', response.status, bookmarkId);
  } finally {
    setBusy(false);
  }
}

/**
 * Ask for Firefox's optional website-content permission when the status says
 * it is needed. No await happens before the permission request, so the click
 * gesture is still active for the prompt.
 * @param {object} status
 * @returns {Promise<object>}
 */
async function ensurePageTextConsent(status) {
  const pageText = status.pageText || {};
  if (!pageText.supported || pageText.granted) return pageText;
  const capability = await requestPageTextConsent();
  return capability;
}

function renderDone(message, status, bookmarkId) {
  state.lastServerUrl = (status && status.serverUrl) || state.lastServerUrl;
  state.lastBookmarkId = Number(bookmarkId) || (status && status.bookmark && Number(status.bookmark.id)) || 0;
  els.doneText.textContent = message;
  els.doneOpenLibrary.textContent = state.lastBookmarkId > 0 ? 'Open in eza' : 'Open eza';
  show('done');
}

function showError(message, retryable) {
  els.errorText.textContent = message;
  els.retry.hidden = !retryable;
  show('error');
  if (retryable) els.retry.focus();
}

/** @param {string} raw @returns {string[]} */
function splitTags(raw) {
  return String(raw || '')
    .split(',')
    .map((tag) => tag.trim())
    .filter(Boolean);
}

function openOptions() {
  try {
    Promise.resolve(api.runtime.openOptionsPage()).catch(() => {});
  } catch {
    // The browser will ignore an unavailable options page.
  }
}

function openInLibrary(bookmarkId) {
  if (!state.lastServerUrl) return;
  const url = bookmarkUrl(state.lastServerUrl, bookmarkId || 0);
  try {
    Promise.resolve(api.tabs.create({ url })).catch(() => {});
  } catch {
    // Cosmetic: the tab request failed.
  }
}

async function grantAccess() {
  const serverUrl = (state.status && state.status.serverUrl) || state.lastServerUrl;
  if (!serverUrl) {
    showError('Set your eza server address in Options first.', true);
    return;
  }
  const result = await ensureHostPermission(serverUrl);
  if (!result.ok || !result.granted) {
    showError(result.error || 'The browser did not grant access to ' + serverUrl + '.', true);
    return;
  }
  await main();
}

function bind() {
  els.version.textContent = 'v' + EXTENSION_VERSION;
  document.getElementById('open-options').addEventListener('click', openOptions);
  document.getElementById('setup-open-options').addEventListener('click', openOptions);
  els.errorOpenOptions.addEventListener('click', openOptions);
  els.retry.addEventListener('click', () => void main());
  els.addBookmark.addEventListener('click', () => void addBookmark());
  els.addPageText.addEventListener('click', () => void addPageText(false));
  els.savedAddPageText.addEventListener('click', () => void addPageText(true));
  els.grantAccess.addEventListener('click', () => void grantAccess());
  els.openInEza.addEventListener('click', () => openInLibrary(state.lastBookmarkId));
  els.doneOpenLibrary.addEventListener('click', () => openInLibrary(state.lastBookmarkId));
  els.doneAgain.addEventListener('click', () => window.close());
}

bind();
void main();
