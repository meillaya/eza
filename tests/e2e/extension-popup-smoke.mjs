// Popup/options DOM smoke for the eza clipper.
//
// This runs in the plain headless Chromium shell (which cannot load a real
// extension) and serves the built popup over local HTTP with a fake
// WebExtension namespace injected before the module scripts run. It proves the
// popup's panel switching and add/open actions against the real popup.js and
// popup.html, without depending on a browser build that supports extension
// side-loading. The background status/add logic has its own Node suite, and
// the real Chrome extension smoke is opt-in (see extension/README.md).

import { chromium } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { newChecker } from "./lib/dom.mjs";

const ROOT = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const { check, report } = newChecker();

const MIME = {
  ".css": "text/css",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json",
  ".png": "image/png",
  ".svg": "image/svg+xml",
};

const testStatus = {
  add: {
    tabId: 1,
    url: "https://example.com/article",
    title: "Example article",
    state: "add",
    tooltip: "eza — add bookmark",
    badge: { text: "", color: null },
    bookmark: null,
    error: null,
    lookupSupported: true,
    eligible: true,
    restricted: false,
    configured: true,
    checkActivePage: true,
    serverUrl: "https://eza.test",
    pageText: { supported: false, granted: true, reason: "" },
    canAddBookmark: true,
    canAddPageText: true,
  },
  saved: {
    tabId: 1,
    url: "https://example.com/saved",
    title: "Saved article",
    state: "saved",
    tooltip: "eza — in your library: Saved article",
    badge: { text: "✓", color: "#1f6f43" },
    bookmark: {
      id: 42,
      url: "https://example.com/saved",
      title: "Saved article",
      domain: "example.com",
      created_at: 1762549200,
      added_at: 1762549200,
      favicon_url: "",
      tags: ["reading", "later"],
      is_read: false,
      is_dead: false,
    },
    error: null,
    lookupSupported: true,
    eligible: true,
    restricted: false,
    configured: true,
    checkActivePage: true,
    serverUrl: "https://eza.test",
    pageText: { supported: false, granted: true, reason: "" },
    canAddBookmark: true,
    canAddPageText: true,
  },
  setup: {
    tabId: 1,
    url: "https://example.com/article",
    title: "Example article",
    state: "setup",
    tooltip: "eza — add bookmark",
    badge: { text: "", color: null },
    bookmark: null,
    error: null,
    lookupSupported: true,
    eligible: true,
    restricted: false,
    configured: false,
    checkActivePage: true,
    serverUrl: "",
    pageText: { supported: false, granted: true, reason: "" },
    canAddBookmark: false,
    canAddPageText: false,
  },
  restricted: {
    tabId: 1,
    url: "chrome://settings",
    title: "Settings",
    state: "restricted",
    tooltip: "eza — this page cannot be bookmarked",
    badge: { text: "", color: null },
    bookmark: null,
    error: { code: "restricted", message: "This page cannot be added to eza.", status: 0 },
    lookupSupported: true,
    eligible: false,
    restricted: true,
    configured: true,
    checkActivePage: true,
    serverUrl: "https://eza.test",
    pageText: { supported: false, granted: true, reason: "" },
    canAddBookmark: false,
    canAddPageText: false,
  },
  error: {
    tabId: 1,
    url: "https://example.com/article",
    title: "Example article",
    state: "error",
    tooltip: "eza — add bookmark",
    badge: { text: "", color: null },
    bookmark: null,
    error: { code: "network", message: "The eza server did not answer.", status: 0 },
    lookupSupported: true,
    eligible: true,
    restricted: false,
    configured: true,
    checkActivePage: true,
    serverUrl: "https://eza.test",
    pageText: { supported: false, granted: true, reason: "" },
    canAddBookmark: false,
    canAddPageText: false,
  },
};

/** @param {string} root */
async function serveStatic(root) {
  const server = createServer(async (request, response) => {
    try {
      const url = new URL(request.url || "/", "http://127.0.0.1");
      const relative = decodeURIComponent(url.pathname).replace(/^\/+/, "") || "popup.html";
      const target = resolve(root, normalize(relative));
      if (!target.startsWith(root + "/") && target !== root) {
        response.writeHead(403).end("forbidden");
        return;
      }
      const body = await readFile(target);
      response.writeHead(200, { "Content-Type": MIME[extname(target)] || "application/octet-stream" });
      response.end(body);
    } catch {
      response.writeHead(404).end("not found");
    }
  });
  await new Promise((ready) => server.listen(0, "127.0.0.1", ready));
  const address = server.address();
  return { server, origin: "http://127.0.0.1:" + address.port };
}

/** @param {import('@playwright/test').Page} page */
async function installFakeApi(page) {
  await page.addInitScript((statuses) => {
    const params = new URLSearchParams(window.location.search);
    const mode = params.get("mode") || "add";
    const status = statuses[mode] || statuses.add;
    window.__ezaPopupCalls = [];
    window.__ezaPopupMode = mode;

    const record = (entry) => window.__ezaPopupCalls.push(entry);
    const send = async (message) => {
      record({ type: "message", message });
      if (!message || typeof message !== "object") return { ok: false, error: { code: "bad_request" } };
      if (message.type === "eza:pageStatus") return { ok: true, status };
      if (message.type === "eza:addBookmark") {
        return {
          ok: true,
          created: true,
          existing: false,
          id: 42,
          message: "Bookmark added",
          bookmark: statuses.saved.bookmark,
          status: statuses.saved,
        };
      }
      if (message.type === "eza:addPage") {
        return { ok: false, error: { code: "page_text_consent", message: "Page text is disabled in this test." } };
      }
      return { ok: false, error: { code: "unknown_message", message: "unknown" } };
    };

    globalThis.chrome = {
      runtime: {
        sendMessage: send,
        openOptionsPage: async () => record({ type: "options" }),
        lastError: null,
      },
      tabs: {
        create: async (options) => {
          record({ type: "tabs.create", options });
          return { id: 2 };
        },
      },
      permissions: {
        getAll: async () => ({ permissions: [], origins: [] }),
        contains: async () => true,
        request: async () => true,
      },
      storage: {
        local: {
          get: async () => ({}),
          set: async () => undefined,
        },
      },
    };

    // The options page uses the same API module; answer its connection-test
    // calls without a real server.
    const json = (status, body) => ({
      ok: status >= 200 && status < 300,
      status,
      headers: { get: () => null },
      text: async () => JSON.stringify(body),
    });
    const realFetch = globalThis.fetch;
    globalThis.fetch = async (input, init) => {
      const url = String(input);
      if (url.includes("/api/v1/whoami")) {
        return json(200, { username: "e2e", scopes: ["capture"], token_name: "test" });
      }
      if (url.includes("/api/v1/bookmarks/lookup")) {
        return json(200, { url: "https://example.com/", bookmark: null });
      }
      if (url.includes("/api/v1/clip-templates")) {
        return json(200, { templates: [], builtin: null });
      }
      return realFetch(input, init);
    };
  }, testStatus);
}

async function main() {
  const outDir = mkdtempSync(join(tmpdir(), "eza-popup-"));
  execFileSync(process.execPath, [join(ROOT, "extension", "build.mjs"), "--target", "chrome", "--out", outDir], {
    cwd: ROOT,
    stdio: "inherit",
  });
  const { server, origin } = await serveStatic(join(outDir, "chrome"));
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 420, height: 720 } });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  page.on("console", (message) => {
    if (message.type() === "error") errors.push(message.text());
  });
  await installFakeApi(page);

  try {
    // Unsaved page: the add panel, the values, and the add action.
    await page.goto(origin + "/popup.html?mode=add", { waitUntil: "domcontentloaded" });
    await page.waitForSelector("#add-panel:not([hidden])", { timeout: 10000 });
    check("the add panel is shown for an unsaved page", await page.locator("#add-panel").isVisible());
    check("the page title is prefilled", (await page.inputValue("#title")) === "Example article");
    check("the page address is shown", (await page.textContent("#page-url")) === "https://example.com/article");
    check("the version is rendered", (await page.textContent("#version")) === "v0.2.0");
    await page.fill("#title", "Edited title");
    await page.fill("#tags", "reading, later");
    await page.click("#add-bookmark");
    await page.waitForSelector("#done-panel:not([hidden])", { timeout: 10000 });
    check("adding a bookmark shows the done panel", await page.locator("#done-panel").isVisible());
    check("the done text says Bookmark added", (await page.textContent("#done-text")) === "Bookmark added");
    const calls = await page.evaluate(() => window.__ezaPopupCalls);
    const addMessage = calls.find((entry) => entry.type === "message" && entry.message.type === "eza:addBookmark");
    check(
      "the popup sends the edited title and tags to the background",
      Boolean(addMessage) &&
        addMessage.message.title === "Edited title" &&
        JSON.stringify(addMessage.message.tags) === JSON.stringify(["reading", "later"]),
      JSON.stringify(addMessage && addMessage.message),
    );
    await page.click("#done-open-library");
    const openCall = (await page.evaluate(() => window.__ezaPopupCalls)).find((entry) => entry.type === "tabs.create");
    check(
      "Open in eza opens the saved bookmark route",
      Boolean(openCall) && openCall.options.url === "https://eza.test/bookmark/42",
      JSON.stringify(openCall && openCall.options),
    );

    // Saved page: title, tags, read state, and the saved action.
    await page.goto(origin + "/popup.html?mode=saved", { waitUntil: "domcontentloaded" });
    await page.waitForSelector("#saved-panel:not([hidden])", { timeout: 10000 });
    check("the saved panel is shown for a saved page", await page.locator("#saved-panel").isVisible());
    check("the saved title is rendered", (await page.textContent("#saved-title")) === "Saved article");
    check("the saved tags are rendered", (await page.textContent("#saved-tags")) === "reading, later");
    check("the read state is rendered", (await page.textContent("#saved-read")) === "Unread");
    await page.click("#open-in-eza");
    const savedOpen = (await page.evaluate(() => window.__ezaPopupCalls)).find((entry) => entry.type === "tabs.create");
    check(
      "the saved panel opens the existing bookmark",
      Boolean(savedOpen) && savedOpen.options.url === "https://eza.test/bookmark/42",
      JSON.stringify(savedOpen && savedOpen.options),
    );

    // Setup, restricted, and error states.
    await page.goto(origin + "/popup.html?mode=setup", { waitUntil: "domcontentloaded" });
    await page.waitForSelector("#setup-panel:not([hidden])", { timeout: 10000 });
    check("the setup panel is shown when unconfigured", await page.locator("#setup-panel").isVisible());

    await page.goto(origin + "/popup.html?mode=restricted", { waitUntil: "domcontentloaded" });
    await page.waitForSelector("#error-panel:not([hidden])", { timeout: 10000 });
    check("a restricted page shows the error panel", await page.locator("#error-panel").isVisible());
    check(
      "the restricted message is rendered",
      (await page.textContent("#error-text")) === "This page cannot be added to eza.",
      await page.textContent("#error-text"),
    );

    await page.goto(origin + "/popup.html?mode=error", { waitUntil: "domcontentloaded" });
    await page.waitForSelector("#error-panel:not([hidden])", { timeout: 10000 });
    check("a lookup error shows the error panel", await page.locator("#error-panel").isVisible());
    check("the error message is rendered", (await page.textContent("#error-text")) === "The eza server did not answer.");

    // Options: save the configuration, then exercise the real connection-test
    // path against the fake whoami/lookup responses.
    await page.goto(origin + "/options.html", { waitUntil: "domcontentloaded" });
    await page.waitForSelector("#server-url", { timeout: 10000 });
    check("the options page renders with the app icon", (await page.getAttribute("#app-icon", "src")) === "icons/icon-48.png");
    check("the options version is rendered", (await page.textContent("#version")) === "v0.2.0");
    check("the background-check toggle is on by default", await page.isChecked("#check-active-page"));
    await page.fill("#server-url", "https://eza.test");
    await page.fill("#token", "eza_pat_test_capture");
    await page.click("#save");
    await page.waitForFunction(() => document.querySelector("#status")?.textContent === "Saved.", null, { timeout: 10000 });
    check("the options page saves the server and token", (await page.textContent("#status")) === "Saved.");
    await page.click("#test");
    await page.waitForFunction(() => /Connected as e2e/.test(document.querySelector("#status")?.textContent || ""), null, { timeout: 10000 });
    check(
      "the connection test reports the account and the lookup probe",
      /Connected as e2e/.test(await page.textContent("#status")),
      await page.textContent("#status"),
    );

    check("the popup does not raise an uncaught error", errors.length === 0, errors.join(" | ").slice(0, 200));
  } finally {
    await context.close();
    await browser.close();
    await new Promise((done) => server.close(done));
    rmSync(outDir, { recursive: true, force: true });
  }
}

main()
  .catch((error) => check("unexpected error", false, String(error && error.stack ? error.stack : error)))
  .finally(() => report());
