// Popup: read the page, let the user adjust the note, then POST /api/v1/clip.

import { isConfigured, loadConfig } from './src/config.js';
import { listTemplates } from './src/api.js';

const state = {
  config: null,
  extraction: null,
  templates: [],
  builtin: null,
  saving: false,
};

const els = {
  loading: document.getElementById('loading-panel'),
  setup: document.getElementById('setup-panel'),
  clip: document.getElementById('clip-panel'),
  done: document.getElementById('done-panel'),
  error: document.getElementById('error-panel'),
  title: document.getElementById('title'),
  tags: document.getElementById('tags'),
  template: document.getElementById('template'),
  pageUrl: document.getElementById('page-url'),
  selectionRow: document.getElementById('selection-row'),
  includeSelection: document.getElementById('include-selection'),
  extractorNote: document.getElementById('extractor-note'),
  save: document.getElementById('save'),
  status: document.getElementById('clip-status'),
  doneText: document.getElementById('done-text'),
  errorText: document.getElementById('error-text'),
};

function show(panel) {
  for (const key of ['loading', 'setup', 'clip', 'done', 'error']) {
    els[key].hidden = key !== panel;
  }
}

function setStatus(message, kind) {
  els.status.textContent = message;
  els.status.className = kind || '';
}

async function main() {
  els.loading.hidden = false;
  els.setup.hidden = true;
  els.clip.hidden = true;
  els.done.hidden = true;
  els.error.hidden = true;

  document.getElementById('open-options').addEventListener('click', openOptions);
  document.getElementById('setup-open-options').addEventListener('click', openOptions);
  document.getElementById('error-open-options').addEventListener('click', openOptions);
  document.getElementById('retry').addEventListener('click', () => void main());
  document.getElementById('done-again').addEventListener('click', () => void main());
  document.getElementById('open-library').addEventListener('click', () => {
    if (state.config && state.config.serverUrl) {
      void chrome.tabs.create({ url: state.config.serverUrl });
      window.close();
    }
  });
  els.save.addEventListener('click', () => void save());

  state.config = await loadConfig();
  if (!isConfigured(state.config)) {
    show('setup');
    return;
  }

  let response;
  try {
    response = await chrome.runtime.sendMessage({ type: 'eza:extract' });
  } catch (error) {
    showError('The background worker is not available. Reload the extension and try again.');
    return;
  }
  if (!response || !response.ok) {
    showError((response && response.error) || 'The page could not be read.');
    return;
  }

  state.extraction = response.payload;
  if (response.note) {
    els.extractorNote.textContent = response.note;
    els.extractorNote.hidden = false;
  } else {
    els.extractorNote.hidden = true;
  }
  renderExtraction();
  await loadTemplateChoices();
  show('clip');
  els.title.focus();
  els.title.select();
}

function renderExtraction() {
  const payload = state.extraction || {};
  els.title.value = payload.title || '';
  els.tags.value = '';
  els.pageUrl.textContent = payload.url || '';
  const selection = String(payload.selection || '').trim();
  els.selectionRow.hidden = !selection;
  els.includeSelection.checked = Boolean(selection);
}

async function loadTemplateChoices() {
  els.template.replaceChildren();
  const builtinOption = document.createElement('option');
  builtinOption.value = '0';
  builtinOption.textContent = 'Default';
  els.template.appendChild(builtinOption);
  try {
    const result = await listTemplates(state.config);
    state.templates = result.templates;
    state.builtin = result.builtin;
    for (const template of result.templates) {
      const option = document.createElement('option');
      option.value = String(template.id);
      option.textContent = template.enabled === false ? template.name + ' (disabled)' : template.name;
      els.template.appendChild(option);
    }
    if (result.builtin && result.builtin.name && result.builtin.name !== 'Default') {
      builtinOption.textContent = result.builtin.name;
    }
  } catch {
    // A missing template route is fine; the default still works.
  }
  const wanted = String(state.config.templateId || 0);
  const available = Array.from(els.template.options).some((option) => option.value === wanted);
  els.template.value = available ? wanted : '0';
}

async function save() {
  if (state.saving) return;
  state.saving = true;
  els.save.disabled = true;
  setStatus('Saving…', '');
  try {
    const tags = els.tags.value
      .split(',')
      .map((tag) => tag.trim())
      .filter(Boolean);
    const templateId = Number.parseInt(els.template.value, 10);
    const payload = {
      ...state.extraction,
      title: els.title.value.trim(),
      tags,
      selection: els.includeSelection.checked ? state.extraction.selection || '' : '',
      template_id: Number.isFinite(templateId) && templateId > 0 ? templateId : undefined,
      source: 'extension',
    };
    if (payload.template_id === undefined) delete payload.template_id;
    const response = await chrome.runtime.sendMessage({ type: 'eza:save', payload });
    if (!response || !response.ok) {
      setStatus((response && response.error) || 'The clip could not be saved.', 'err');
      return;
    }
    const record = response.record || {};
    const message = record.message || 'Saved.';
    const bookmarkId = record.bookmarkId || (response.result && response.result.bookmark_id) || 0;
    els.doneText.textContent = bookmarkId
      ? message + ' Bookmark #' + bookmarkId + '.'
      : message;
    show('done');
  } catch (error) {
    setStatus(String((error && error.message) || error), 'err');
  } finally {
    state.saving = false;
    els.save.disabled = false;
  }
}

function showError(message) {
  els.errorText.textContent = message;
  show('error');
}

function openOptions() {
  void chrome.runtime.openOptionsPage();
}

void main();
