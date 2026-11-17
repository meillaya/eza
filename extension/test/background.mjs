// Browser-free tests for the extension background worker.
//
//   node test/background.mjs
//
// background.js has no exports: it reads the WebExtension namespace and
// registers listeners at import time. This test installs a fake namespace on
// globalThis, imports a fresh copy of the module with a cache-busting query
// string, then drives the registered runtime.onMessage listener exactly as the
// popup does. A fake fetch plays the eza server (lookup, quick-save, clip with
// replay), and the fake action API records per-tab badge/title calls.
//
// Covered: saved/absent/old-server/401-revoked page status and its badge and
// tooltip; add-bookmark over quick-save (created and existing); add-page over
// clip with one Idempotency-Key per logical save and replay; the Firefox
// `browser` namespace (including the promise-style contextMenus removal and
// the optional websiteContent consent request); the unknown-message error; and
// the invariant that the capture token never appears in a URL or a response.
//
// The token here is a dummy value; it is not a real eza token and never leaves
// this process.

import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { CLIENT } from '../src/version.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const backgroundModuleUrl = pathToFileURL(join(root, 'background.js')).href;
const browserModuleUrl = pathToFileURL(join(root, 'src', 'browser.js')).href;

const TOKEN = 'eza_pat_u1_test_background_token';
const CONFIG_KEY = 'ezaClipper.config';
const SAVED_URL = 'https://example.press/ledger/the-quiet-ledger?ref=home#top';
const UNSAVED_URL = 'https://example.press/other-page';
const ARTICLE_URL = 'https://example.press/article/the-quiet-ledger';
const SAVED_BOOKMARK = {
  id: 42,
  url: SAVED_URL,
  title: 'The Quiet Ledger',
  domain: 'example.press',
  created_at: 1762549200,
  added_at: 1762549200,
  favicon_url: '',
  tags: ['reading'],
  is_read: false,
  is_dead: false,
  snippet: null,
};

const originalFetch = globalThis.fetch;
const originalChrome = globalThis.chrome;
const originalBrowser = globalThis.browser;

let failures = 0;
let importCounter = 0;

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

/** @param {number} [ms] @returns {Promise<void>} */
function tick(ms = 0) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Wait for an asynchronous side effect (a listener handler has no return value
 * to await).
 * @param {string} label
 * @param {() => unknown} probe
 * @param {number} [timeoutMs]
 */
async function waitFor(label, probe, timeoutMs = 2000) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    try {
      last = await probe();
    } catch (error) {
      last = { error: error instanceof Error ? error.message : String(error) };
    }
    if (last) return last;
    await tick(20);
  }
  throw new Error('timed out waiting for ' + label + '; last=' + JSON.stringify(last));
}

/** @param {object} body @param {number} [status] */
function jsonResponse(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: () => null },
    text: async () => JSON.stringify(body),
  };
}

/**
 * A fake WebExtension namespace. `kind` picks the host API style: Chrome
 * invokes contextMenus callbacks and returns undefined, Firefox returns
 * promises and ignores the callback (which is exactly the cross-browser case
 * createContextMenus has to handle).
 * @param {{kind?: string, tabs?: object[], bookmarks?: object[], checkActivePage?: boolean, websiteContentGranted?: boolean, hostPermission?: boolean}} [options]
 */
function createFakeExtension(options = {}) {
  const kind = options.kind === 'firefox' ? 'firefox' : 'chrome';
  const listeners = {};
  const calls = {
    action: [],
    menus: [],
    scripting: [],
    permissionsRequests: [],
    contextMenusRemoveAll: 0,
    storageWrites: [],
  };
  const tabs = (options.tabs || [
    { id: 1, url: SAVED_URL, title: 'The Quiet Ledger', active: true },
  ]).map((tab) => ({ ...tab }));
  const storedLocal = {
    [CONFIG_KEY]: {
      schema: 1,
      serverUrl: options.serverUrl || 'https://eza.test',
      captureToken: TOKEN,
      templateId: 0,
      templateName: 'Default',
      checkActivePage: options.checkActivePage !== false,
    },
  };
  const storedSession = {};

  /** @param {object} store */
  const storageArea = (store) => ({
    get: async (keys) => {
      if (typeof keys === 'string') return keys in store ? { [keys]: store[keys] } : {};
      if (Array.isArray(keys)) {
        const out = {};
        for (const key of keys) if (key in store) out[key] = store[key];
        return out;
      }
      return { ...store };
    },
    set: async (values) => {
      calls.storageWrites.push(values);
      Object.assign(store, values);
    },
  });

  const activeTab = () => tabs.find((tab) => tab.active) || tabs[0];

  /** @returns {object} */
  function extractionPayload() {
    const tab = activeTab() || { url: ARTICLE_URL, title: 'Extracted title' };
    return {
      url: tab.url,
      title: 'Extracted title',
      content_markdown: '# Extracted title\n\nbody text',
      content_text: 'Extracted title body text',
      content_html: '<p>body text</p>',
      selection: '',
      tags: [],
      template_id: null,
      source: 'extension',
      client: CLIENT,
      captured_at: 1762549200,
      metadata: { extractor: 'fake-dom', extractor_version: '1', word_count: 4, parse_time_ms: 1 },
    };
  }

  /** @param {string} name */
  const event = (name) => ({
    addListener: (fn) => {
      listeners[name] = fn;
    },
  });

  const api = {
    runtime: {
      lastError: undefined,
      getURL: (path) => 'chrome-extension://fake-extension/' + path,
      onInstalled: event('installed'),
      onStartup: event('startup'),
      onMessage: event('message'),
    },
    commands: { onCommand: event('command') },
    contextMenus: {
      onClicked: event('menuClicked'),
      removeAll: (callback) => {
        calls.contextMenusRemoveAll += 1;
        if (kind === 'firefox') {
          // Firefox returns a Promise for removeAll; the callback form is not
          // what the browser namespace guarantees.
          return Promise.resolve();
        }
        if (typeof callback === 'function') callback();
        return undefined;
      },
      create: (properties, callback) => {
        calls.menus.push({ ...properties });
        if (kind !== 'firefox' && typeof callback === 'function') callback();
        return properties.id;
      },
    },
    tabs: {
      onActivated: event('tabActivated'),
      onUpdated: event('tabUpdated'),
      onRemoved: event('tabRemoved'),
      query: async (queryInfo = {}) => {
        const rows = queryInfo.active ? tabs.filter((tab) => tab.active) : tabs;
        return rows.slice(0, 1).map((tab) => ({ ...tab }));
      },
      get: async (tabId) => {
        const tab = tabs.find((entry) => entry.id === tabId);
        if (!tab) throw new Error('no tab ' + tabId);
        return { ...tab };
      },
    },
    storage: {
      local: storageArea(storedLocal),
      session: storageArea(storedSession),
      onChanged: event('storageChanged'),
    },
    permissions: {
      onAdded: event('permissionsAdded'),
      onRemoved: event('permissionsRemoved'),
      getAll: async () => {
        if (kind !== 'firefox') return { permissions: [], origins: [] };
        const dataCollection = ['browsingActivity', 'bookmarksInfo'];
        if (options.websiteContentGranted !== false) dataCollection.push('websiteContent');
        return { permissions: [], origins: [], data_collection: dataCollection };
      },
      contains: async () => options.hostPermission !== false,
      request: async (request) => {
        calls.permissionsRequests.push(JSON.parse(JSON.stringify(request)));
        return true;
      },
    },
    action: {
      setBadgeText: async (details) => {
        calls.action.push({ method: 'setBadgeText', details: { ...details } });
      },
      setBadgeBackgroundColor: async (details) => {
        calls.action.push({ method: 'setBadgeBackgroundColor', details: { ...details } });
      },
      setTitle: async (details) => {
        calls.action.push({ method: 'setTitle', details: { ...details } });
      },
    },
    scripting: {
      executeScript: async (details) => {
        calls.scripting.push({
          target: details.target,
          world: details.world,
          files: details.files,
          hasFunc: typeof details.func === 'function',
        });
        return [{ result: extractionPayload() }];
      },
    },
  };

  return {
    kind,
    api,
    listeners,
    calls,
    tabs,
    setActiveTab(tabId) {
      for (const tab of tabs) tab.active = tab.id === tabId;
    },
    addTab(tab) {
      tabs.push({ ...tab, active: false });
    },
    activeTab,
    /** @param {number} tabId */
    badgeFor(tabId) {
      const calls_ = calls.action.filter((call) => call.details.tabId === tabId);
      const last = (method) => {
        const matches = calls_.filter((call) => call.method === method);
        return matches.length ? matches[matches.length - 1].details : null;
      };
      const text = last('setBadgeText');
      const color = last('setBadgeBackgroundColor');
      const title = last('setTitle');
      return {
        text: text ? text.text : undefined,
        color: color ? color.color : undefined,
        title: title ? title.title : undefined,
      };
    },
    menuTitles() {
      return calls.menus.map((menu) => menu.title);
    },
  };
}

/**
 * A fake eza server behind globalThis.fetch. It records every request and
 * answers lookup, quick-save, clip, and whoami with the real response shapes.
 * `lookupMode` forces the old-server 404 or a revoked-token 401.
 */
function createFakeServer(options = {}) {
  const requests = [];
  const bookmarks = new Map();
  for (const bookmark of options.bookmarks || []) bookmarks.set(bookmark.url, bookmark);
  const clips = new Map();
  let lookupMode = options.lookupMode || 'auto';

  /** @param {string} url */
  function pathOf(url) {
    try {
      return new URL(url).pathname;
    } catch {
      return '';
    }
  }

  const fetchHandler = async (input, init = {}) => {
    const url = String(input);
    const headers = { ...(init.headers || {}) };
    requests.push({
      url,
      path: pathOf(url),
      method: init.method || 'GET',
      headers,
      body: init.body,
      credentials: init.credentials,
    });
    const path = pathOf(url);
    if (path === '/vendor/defuddle-page.js') return jsonResponse({}, 404);
    if (path === '/api/v1/bookmarks/lookup') {
      if (lookupMode === '404') return jsonResponse({ error: { code: 'not_found', message: 'no lookup route' } }, 404);
      if (lookupMode === '401') {
        return jsonResponse({ error: { code: 'unauthorized', message: 'the capture token is not valid' } }, 401);
      }
      const parsed = new URL(url);
      const pageUrl = parsed.searchParams.get('url');
      return jsonResponse({ url: pageUrl, bookmark: bookmarks.get(pageUrl) || null });
    }
    if (path === '/api/v1/quick-save') {
      const body = JSON.parse(init.body || '{}');
      const existing = bookmarks.has(body.url);
      const id = existing ? bookmarks.get(body.url).id : 100 + bookmarks.size;
      if (!existing) {
        bookmarks.set(body.url, {
          id,
          url: body.url,
          title: body.title || '',
          domain: 'example.press',
          created_at: 1762549200,
          added_at: 1762549200,
          favicon_url: '',
          tags: Array.isArray(body.tags) ? body.tags : [],
          is_read: false,
          is_dead: false,
          snippet: null,
        });
      }
      return jsonResponse({ id, existing }, existing ? 200 : 201);
    }
    if (path === '/api/v1/clip') {
      const key = headers['Idempotency-Key'];
      if (key && clips.has(key)) return jsonResponse({ ...clips.get(key), replayed: true });
      const body = JSON.parse(init.body || '{}');
      const result = {
        capture_id: 50 + clips.size,
        bookmark_id: 100 + bookmarks.size,
        bookmark_created: true,
        replayed: false,
        title: body.title || '',
        tags: Array.isArray(body.tags) ? body.tags : [],
        needs_enrichment: false,
        template_id: 0,
        template_name: '',
        rendered_markdown: '',
      };
      if (key) clips.set(key, { ...result });
      return jsonResponse(result, 201);
    }
    if (path === '/api/v1/whoami') {
      return jsonResponse({ username: 'tester', scopes: ['capture'], token_name: 'background-test' });
    }
    return jsonResponse({ error: { code: 'not_found', message: 'no route' } }, 404);
  };

  return {
    requests,
    bookmarks,
    clips,
    fetchHandler,
    /** @param {string} mode */
    setLookupMode(mode) {
      lookupMode = mode;
    },
    /** @param {string} path */
    requestsFor(path) {
      return requests.filter((request) => request.path === path);
    },
  };
}

/**
 * Install a fake namespace and import a fresh copy of background.js so its
 * load-time listener registration binds to this fake.
 * @param {ReturnType<typeof createFakeExtension>} fake
 */
async function loadBackground(fake) {
  delete globalThis.chrome;
  delete globalThis.browser;
  if (fake.kind === 'firefox') globalThis.browser = fake.api;
  else globalThis.chrome = fake.api;
  importCounter += 1;
  await import(backgroundModuleUrl + '?background-test=' + importCounter);
  return fake;
}

/**
 * Send one message to the registered worker listener and resolve with the
 * sendResponse payload.
 * @param {ReturnType<typeof createFakeExtension>} fake
 * @param {object} message
 */
function send(fake, message) {
  return new Promise((resolve, reject) => {
    if (typeof fake.listeners.message !== 'function') {
      reject(new Error('background did not register runtime.onMessage'));
      return;
    }
    const timer = setTimeout(() => reject(new Error('timed out waiting for a response to ' + message.type)), 3000);
    let kept = false;
    try {
      kept = fake.listeners.message(message, { id: 'fake-extension' }, (response) => {
        clearTimeout(timer);
        resolve(response);
      });
    } catch (error) {
      clearTimeout(timer);
      reject(error);
      return;
    }
    if (kept !== true) {
      clearTimeout(timer);
      reject(new Error('background.onMessage did not keep the response channel open for ' + message.type));
    }
  });
}

/**
 * Install one fake server as globalThis.fetch for a scenario.
 * @param {ReturnType<typeof createFakeServer>} server
 */
function installServer(server) {
  globalThis.fetch = server.fetchHandler;
  return server;
}

/** @param {object} response @returns {string[]} */
function requestUrls(server) {
  return server.requests.map((request) => request.url);
}

/** @param {string} token @param {object} server */
function assertTokenNeverInUrls(token, server) {
  checkTruthy('the token never appears in a request URL', !requestUrls(server).some((url) => url.includes(token)));
}

async function run() {
  // ---------------------------------------------------------------- browser
  // browser.js must prefer the promise-style browser namespace, and fall back
  // to the chrome namespace when only that exists.
  {
    const { getApi } = await import(browserModuleUrl);
    const chromeFake = createFakeExtension({ kind: 'chrome' });
    const browserFake = createFakeExtension({ kind: 'firefox' });
    globalThis.chrome = chromeFake.api;
    globalThis.browser = browserFake.api;
    checkTruthy('browser.js prefers the browser namespace when both exist', getApi() === browserFake.api);
    delete globalThis.browser;
    checkTruthy('browser.js falls back to chrome when browser is absent', getApi() === chromeFake.api);
    delete globalThis.chrome;
  }

  // ------------------------------------------------ page status (Chrome NS)
  console.log('\n# page status over the chrome namespace');
  {
    const fake = createFakeExtension();
    const server = installServer(createFakeServer({ bookmarks: [SAVED_BOOKMARK] }));
    await loadBackground(fake);

    const saved = await send(fake, { type: 'eza:pageStatus' });
    check('saved page: ok', saved.ok, true);
    check('saved page: state', saved.ok && saved.status.state, 'saved');
    check('saved page: bookmark id', saved.ok && saved.status.bookmark && saved.status.bookmark.id, 42);
    check('saved page: tooltip names the library', /in your library/i.test(saved.status.tooltip), true);
    check('saved page: tooltip names the bookmark', saved.status.tooltip.includes('The Quiet Ledger'), true);
    check('saved page: lookup requested once', server.requestsFor('/api/v1/bookmarks/lookup').length, 1);
    check(
      'saved page: lookup URL encodes the page URL',
      server.requestsFor('/api/v1/bookmarks/lookup')[0].url,
      'https://eza.test/api/v1/bookmarks/lookup?url=' + encodeURIComponent(SAVED_URL),
    );
    check(
      'saved page: token in the Authorization header',
      server.requestsFor('/api/v1/bookmarks/lookup')[0].headers.Authorization,
      'Bearer ' + TOKEN,
    );
    check('saved page: credentials omitted', server.requestsFor('/api/v1/bookmarks/lookup')[0].credentials, 'omit');
    const savedBadge = fake.badgeFor(1);
    check('saved page: check badge text', savedBadge.text, '✓');
    check('saved page: check badge colour', savedBadge.color, '#1f6f43');
    check('saved page: title tooltip', /in your library/i.test(savedBadge.title || ''), true);

    // An unsaved page clears the badge and uses the base tooltip.
    fake.addTab({ id: 2, url: UNSAVED_URL, title: 'Another page' });
    fake.setActiveTab(2);
    const absent = await send(fake, { type: 'eza:pageStatus' });
    check('unsaved page: state', absent.ok && absent.status.state, 'add');
    check('unsaved page: no bookmark', absent.ok && absent.status.bookmark, null);
    check('unsaved page: base tooltip', absent.ok && absent.status.tooltip, 'eza — add bookmark');
    const absentBadge = fake.badgeFor(2);
    check('unsaved page: badge cleared', absentBadge.text, '');
    check('unsaved page: base title', absentBadge.title, 'eza — add bookmark');

    // A second status for the same URL is served from the 60-second cache.
    const lookupsBefore = server.requestsFor('/api/v1/bookmarks/lookup').length;
    const cached = await send(fake, { type: 'eza:pageStatus' });
    check('cached status: still unsaved', cached.ok && cached.status.state, 'add');
    check(
      'cached status: no extra lookup',
      server.requestsFor('/api/v1/bookmarks/lookup').length,
      lookupsBefore,
    );
    assertTokenNeverInUrls(TOKEN, server);
  }

  // ------------------------------- page status: old server and token errors
  console.log('\n# page status failure states');
  {
    const fake = createFakeExtension();
    const server = installServer(createFakeServer({ lookupMode: '404' }));
    await loadBackground(fake);
    const old = await send(fake, { type: 'eza:pageStatus', force: true });
    check('old server: state stays add', old.ok && old.status.state, 'add');
    check('old server: lookup marked unsupported', old.ok && old.status.lookupSupported, false);
    check('old server: badge cleared', fake.badgeFor(1).text, '');
    check('old server: one lookup', server.requestsFor('/api/v1/bookmarks/lookup').length, 1);
    fake.addTab({ id: 2, url: UNSAVED_URL, title: 'Another page' });
    fake.setActiveTab(2);
    const oldAgain = await send(fake, { type: 'eza:pageStatus', force: true });
    check('old server: second page still add', oldAgain.ok && oldAgain.status.state, 'add');
    check(
      'old server: unsupported lookup is not retried',
      server.requestsFor('/api/v1/bookmarks/lookup').length,
      1,
    );
  }
  {
    const fake = createFakeExtension();
    const server = installServer(createFakeServer({ lookupMode: '401' }));
    await loadBackground(fake);
    const revoked = await send(fake, { type: 'eza:pageStatus', force: true });
    check('revoked token: state is error', revoked.ok && revoked.status.state, 'error');
    check('revoked token: auth error surfaced', revoked.status && revoked.status.error && revoked.status.error.status, 401);
    check('revoked token: badge cleared', fake.badgeFor(1).text, '');
    check('revoked token: one lookup', server.requestsFor('/api/v1/bookmarks/lookup').length, 1);
    fake.addTab({ id: 2, url: UNSAVED_URL, title: 'Another page' });
    fake.setActiveTab(2);
    const revokedAgain = await send(fake, { type: 'eza:pageStatus', force: true });
    check('revoked token: second page also error', revokedAgain.ok && revokedAgain.status.state, 'error');
    check(
      'revoked token: cooldown avoids repeated lookups',
      server.requestsFor('/api/v1/bookmarks/lookup').length,
      1,
    );
    assertTokenNeverInUrls(TOKEN, server);
  }

  // ------------------------------------------------------ add bookmark flow
  console.log('\n# add bookmark over quick-save');
  {
    const fake = createFakeExtension({
      tabs: [{ id: 3, url: 'https://example.press/new-page', title: 'New Page', active: true }],
    });
    const server = installServer(createFakeServer());
    await loadBackground(fake);
    const created = await send(fake, {
      type: 'eza:addBookmark',
      url: 'https://example.press/new-page',
      title: 'New Page',
      tags: ['browser', 'reading'],
    });
    check('add bookmark: ok', created.ok, true);
    check('add bookmark: created', created.ok && created.created, true);
    check('add bookmark: existing', created.ok && created.existing, false);
    check('add bookmark: id returned', created.ok && Number.isInteger(created.id), true);
    check('add bookmark: message', created.ok && created.message, 'Bookmark added');
    check('add bookmark: status saved', created.ok && created.status && created.status.state, 'saved');
    const quickSaves = server.requestsFor('/api/v1/quick-save');
    check('add bookmark: one quick-save request', quickSaves.length, 1);
    check('add bookmark: POST', quickSaves[0].method, 'POST');
    check('add bookmark: request body', JSON.parse(quickSaves[0].body), {
      url: 'https://example.press/new-page',
      title: 'New Page',
      tags: ['browser', 'reading'],
    });
    check('add bookmark: token header', quickSaves[0].headers.Authorization, 'Bearer ' + TOKEN);
    check('add bookmark: credentials omitted', quickSaves[0].credentials, 'omit');
    check('add bookmark: saved badge', fake.badgeFor(3).text, '✓');
    check('add bookmark: saved tooltip', /in your library/i.test(fake.badgeFor(3).title || ''), true);
    checkTruthy(
      'add bookmark: status refreshed with a lookup',
      server.requestsFor('/api/v1/bookmarks/lookup').length >= 1,
    );
    checkTruthy(
      'add bookmark: response never contains the token',
      !JSON.stringify(created).includes(TOKEN),
    );

    const existing = await send(fake, {
      type: 'eza:addBookmark',
      url: 'https://example.press/new-page',
      title: 'New Page',
      tags: ['browser'],
    });
    check('add bookmark again: ok', existing.ok, true);
    check('add bookmark again: not created', existing.ok && existing.created, false);
    check('add bookmark again: existing', existing.ok && existing.existing, true);
    check('add bookmark again: message', existing.ok && existing.message, 'Already in your library');
    check('add bookmark again: second quick-save', server.requestsFor('/api/v1/quick-save').length, 2);
    assertTokenNeverInUrls(TOKEN, server);
  }

  // --------------------------------------------------------- add page flow
  console.log('\n# add page text over clip');
  {
    const fake = createFakeExtension({
      tabs: [{ id: 4, url: ARTICLE_URL, title: 'Article', active: true }],
    });
    const server = installServer(createFakeServer());
    await loadBackground(fake);
    const first = await send(fake, { type: 'eza:addPage', title: 'Article', tags: ['reading'] });
    check('add page: ok', first.ok, true);
    check('add page: capture id', first.ok && first.result && Number.isInteger(first.result.capture_id), true);
    check('add page: message', first.ok && first.message, 'Page text added');
    check('add page: extraction used scripting', fake.calls.scripting.length >= 1 && fake.calls.scripting[0].hasFunc, true);
    check('add page: no Firefox consent prompt on Chrome', fake.calls.permissionsRequests.length, 0);
    const clips = server.requestsFor('/api/v1/clip');
    check('add page: one clip request', clips.length, 1);
    const key = clips[0].headers['Idempotency-Key'];
    checkTruthy('add page: Idempotency-Key is a non-empty string', typeof key === 'string' && key.length > 0);
    check('add page: token header', clips[0].headers.Authorization, 'Bearer ' + TOKEN);
    const clipBody = JSON.parse(clips[0].body);
    check('add page: clip url', clipBody.url, ARTICLE_URL);
    check('add page: confirmed title', clipBody.title, 'Article');
    check('add page: tags', clipBody.tags, ['reading']);
    check('add page: client version', clipBody.client, CLIENT);
    checkTruthy('add page: readable content included', typeof clipBody.content_markdown === 'string' && clipBody.content_markdown.length > 0);
    checkTruthy('add page: token never in the clip body', !clips[0].body.includes(TOKEN));
    check('add page: saved badge after save', fake.badgeFor(4).text, '✓');
    checkTruthy(
      'add page: response never contains the token',
      !JSON.stringify(first).includes(TOKEN),
    );

    const replay = await send(fake, { type: 'eza:addPage', title: 'Article', tags: ['reading'] });
    check('add page replay: ok', replay.ok, true);
    check('add page replay: message', replay.ok && replay.message, 'Page text already added');
    const clipsAgain = server.requestsFor('/api/v1/clip');
    check('add page replay: second request', clipsAgain.length, 2);
    check(
      'add page replay: same Idempotency-Key',
      clipsAgain[1].headers['Idempotency-Key'],
      key,
    );
    check('add page replay: server filed one capture', server.clips.size, 1);
    assertTokenNeverInUrls(TOKEN, server);
  }

  // --------------------------------------------------- unknown message type
  console.log('\n# message errors');
  {
    const fake = createFakeExtension();
    const server = installServer(createFakeServer({ bookmarks: [SAVED_BOOKMARK] }));
    await loadBackground(fake);
    const unknown = await send(fake, { type: 'eza:notAThing' });
    check('unknown message: response is refused', unknown.ok, false);
    check('unknown message: code', unknown.error && unknown.error.code, 'unknown_message');
    const malformed = await send(fake, {});
    check('missing type: response is refused', malformed.ok, false);
    check('missing type: code', malformed.error && malformed.error.code, 'bad_request');
    checkTruthy('unknown-message response never contains the token', !JSON.stringify(unknown).includes(TOKEN));
    assertTokenNeverInUrls(TOKEN, server);
  }

  // ------------------------------------------------- Firefox browser namespace
  console.log('\n# firefox browser namespace, menus, commands and consent');
  {
    const fake = createFakeExtension({
      kind: 'firefox',
      websiteContentGranted: false,
      tabs: [{ id: 5, url: 'https://example.press/firefox-page', title: 'Firefox page', active: true }],
    });
    const server = installServer(createFakeServer({ bookmarks: [SAVED_BOOKMARK] }));
    await loadBackground(fake);
    const status = await send(fake, { type: 'eza:pageStatus' });
    check('firefox: status works over browser namespace', status.ok, true);
    check('firefox: page text reports optional permission pending', status.ok && status.status.pageText.supported, true);
    check('firefox: page text not granted yet', status.ok && status.status.pageText.granted, false);

    // createContextMenus must cope with the promise-style removeAll.
    fake.listeners.installed();
    const menus = await waitFor('context menus created', () => (fake.calls.menus.length === 3 ? fake.calls.menus : null));
    check('firefox: three context menus created', menus.map((menu) => menu.title), [
      'Add bookmark to eza',
      'Add page text to eza',
      'Add selection to eza',
    ]);
    check('firefox: menu creation did not need the callback', fake.calls.contextMenusRemoveAll, 1);

    // The keyboard command goes through the same add path.
    fake.listeners.command('add-bookmark');
    await waitFor('command quick-save', () =>
      server.requestsFor('/api/v1/quick-save').length >= 1 ? true : null,
    );
    check('firefox: add-bookmark command saves the page', server.requestsFor('/api/v1/quick-save').length, 1);

    // Page text asks for the optional websiteContent consent first.
    const page = await send(fake, { type: 'eza:addPage' });
    check('firefox: page text after consent ok', page.ok, true);
    check(
      'firefox: consent request uses data_collection',
      fake.calls.permissionsRequests[0],
      { data_collection: ['websiteContent'] },
    );
    check('firefox: clip sent after consent', server.requestsFor('/api/v1/clip').length, 1);
    assertTokenNeverInUrls(TOKEN, server);
  }

  // --------------------------------------------- background checks disabled
  console.log('\n# background checks toggle');
  {
    const fake = createFakeExtension({
      checkActivePage: false,
      tabs: [{ id: 6, url: SAVED_URL, title: 'The Quiet Ledger', active: true }],
    });
    const server = installServer(createFakeServer({ bookmarks: [SAVED_BOOKMARK] }));
    await loadBackground(fake);
    const onDemand = await send(fake, { type: 'eza:pageStatus' });
    check('checks off: popup status still checks on demand', onDemand.ok && onDemand.status.state, 'saved');
    check('checks off: one lookup for the popup', server.requestsFor('/api/v1/bookmarks/lookup').length, 1);
  }
}

try {
  await run();
} catch (error) {
  failures += 1;
  console.error(`not ok - background test crashed\n${error instanceof Error ? error.stack : error}`);
} finally {
  globalThis.fetch = originalFetch;
  if (originalChrome === undefined) delete globalThis.chrome;
  else globalThis.chrome = originalChrome;
  if (originalBrowser === undefined) delete globalThis.browser;
  else globalThis.browser = originalBrowser;
}

if (failures > 0) {
  console.error(`\n${failures} background check(s) failed`);
  process.exit(1);
}
console.log('\nall background checks passed');
