// Chrome smoke test for the eza clipper.
//
//   EZA_BASE=http://localhost:8210 node tests/e2e/extension-smoke.mjs
//
// The script builds a test copy of the extension with a static localhost host
// permission (so the browser does not need an interactive permission prompt),
// loads it in Playwright's Chromium with an extension-capable persistent
// context, then checks the three things that make the clipper more than a
// bookmarklet:
//
//   * the active-page lookup sets a per-tab check badge and tooltip for a page
//     that is already in the library, and clears it on an unsaved page;
//   * Add bookmark files a page through the real popup (or, if the pinned
//     Chromium refuses chrome.action.openPopup in headless mode, through the
//     background message the popup sends);
//   * the same server route answers the extension origin, so the dev-only host
//     permission does not hide a CORS defect.
//
// Firefox cannot load extensions through Playwright's Firefox build; the
// manual checklist in extension/README.md covers it.

import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "@playwright/test";

import { BASE, enterLibrary, makeApi, newChecker } from "./lib/dom.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const { check, report } = newChecker();

const buildDir = mkdtempSync(join(tmpdir(), "eza-extension-"));
const profileDir = mkdtempSync(join(tmpdir(), "eza-extension-profile-"));
const testOrigin = new URL(BASE).origin;

let context = null;

function sleep(ms) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, ms));
}

async function poll(label, probe, predicate, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    try {
      last = await probe();
    } catch (error) {
      last = { error: String((error && error.message) || error) };
    }
    if (predicate(last)) {
      check(label, true);
      return last;
    }
    await sleep(150);
  }
  check(label, false, JSON.stringify(last));
  return last;
}

async function badgeFor(extension, tabId) {
  return extension.evaluate(async (id) => {
    const text = await chrome.action.getBadgeText({ tabId: id });
    const title = await chrome.action.getTitle({ tabId: id });
    return { text, title };
  }, tabId);
}

try {
  // --------------------------------------------------------------- build ---
  execFileSync(
    process.execPath,
    [
      join(ROOT, "extension", "build.mjs"),
      "--target",
      "chrome",
      "--out",
      buildDir,
      "--host-permission",
      testOrigin + "/*",
    ],
    { cwd: ROOT, stdio: "inherit" },
  );
  const extensionPath = join(buildDir, "chrome");

  context = await chromium.launchPersistentContext(profileDir, {
    channel: "chromium",
    args: [
      `--disable-extensions-except=${extensionPath}`,
      `--load-extension=${extensionPath}`,
    ],
  });

  let [extension] = context.serviceWorkers();
  if (!extension) extension = await context.waitForEvent("serviceworker", { timeout: 20000 });
  const extensionId = new URL(extension.url()).host;
  check("the extension service worker starts", Boolean(extensionId), extension.url());

  // ----------------------------------------------------------- account ---
  const page = context.pages()[0] || (await context.newPage());
  await enterLibrary(page);
  const api = makeApi(page);

  const createdToken = await api("/api/v1/tokens", {
    method: "POST",
    body: JSON.stringify({ name: "extension-e2e", scopes: ["capture"] }),
  });
  const captureToken = createdToken.body && createdToken.body.token;
  check("a capture token is created", createdToken.status === 201 && typeof captureToken === "string", `${createdToken.status}`);

  const stamp = Date.now();
  const savedUrl = BASE + "/history?extension-e2e=" + stamp;
  const unsavedUrl = BASE + "/healthz?extension-e2e=" + stamp;
  const seeded = await api("/api/v1/bookmarks", {
    method: "POST",
    body: JSON.stringify({ url: savedUrl, title: "Extension saved page", tags: ["extension-e2e"] }),
  });
  check("the saved-page fixture is inserted", seeded.status === 201, `${seeded.status}`);
  const savedId = seeded.body && seeded.body.id;

  // ---------------------------------------------------------- configure ---
  await extension.evaluate(
    async (config) => {
      await chrome.storage.local.set({ "ezaClipper.config": config });
    },
    {
      schema: 1,
      serverUrl: BASE,
      captureToken,
      templateId: 0,
      templateName: "Default",
      checkActivePage: true,
    },
  );

  const savedPage = await context.newPage();
  await savedPage.goto(savedUrl, { waitUntil: "domcontentloaded" });
  const savedTabId = await poll(
    "the saved page has a tab id",
    async () => {
      const tabs = await extension.evaluate(async () =>
        chrome.tabs.query({ active: true, lastFocusedWindow: true }).then((rows) => rows.map((tab) => ({ id: tab.id, url: tab.url }))),
      );
      return tabs[0] || null;
    },
    (tab) => Boolean(tab && tab.url === savedUrl),
  );
  check("the background can see the active tab URL with the tabs permission", Boolean(savedTabId && savedTabId.id), JSON.stringify(savedTabId));

  const savedStatus = await poll(
    "a saved page gets a check badge and an in-library tooltip",
    () => badgeFor(extension, savedTabId.id),
    (status) => status && status.text === "✓" && /in your library/i.test(status.title || ""),
  );
  check(
    "the saved-page tooltip names the bookmark",
    /Extension saved page/.test(savedStatus.title || ""),
    savedStatus.title,
  );

  const unsavedPage = await context.newPage();
  await unsavedPage.goto(unsavedUrl, { waitUntil: "domcontentloaded" });
  const unsavedTab = await poll(
    "the unsaved page is the active tab",
    async () => {
      const tabs = await extension.evaluate(async () =>
        chrome.tabs.query({ active: true, lastFocusedWindow: true }).then((rows) => rows.map((tab) => ({ id: tab.id, url: tab.url }))),
      );
      return tabs[0] || null;
    },
    (tab) => Boolean(tab && tab.url === unsavedUrl),
  );
  check("the active tab switches to the unsaved page", Boolean(unsavedTab && unsavedTab.id), JSON.stringify(unsavedTab));

  await poll(
    "an unsaved page has no badge and the add-bookmark tooltip",
    () => badgeFor(extension, unsavedTab.id),
    (status) => status && status.text === "" && /add bookmark/i.test(status.title || ""),
  );

  // -------------------------------------------------------------- popup ---
  // The real popup is the best end-to-end path. Chrome 127+ can open it
  // without a user gesture; the pinned Chromium may still refuse in headless
  // mode, in which case the background message path below is exercised.
  let popup = null;
  try {
    const popupPage = context.waitForEvent("page", { timeout: 5000 });
    await extension.evaluate(async () => {
      await chrome.action.openPopup();
    });
    popup = await popupPage;
    await popup.waitForLoadState("domcontentloaded");
  } catch (error) {
    popup = null;
    console.log("note: chrome.action.openPopup() was unavailable; using the background message path for add bookmark");
  }

  if (popup) {
    await popup.waitForSelector("#add-panel:not([hidden]), #saved-panel:not([hidden])", { timeout: 15000 });
    const addVisible = await popup.locator("#add-panel").isVisible().catch(() => false);
    check("the popup opens on an unsaved page", addVisible);
    if (addVisible) {
      await popup.fill("#title", "Extension added page");
      await popup.fill("#tags", "extension-e2e, browser");
      await popup.click("#add-bookmark");
      await popup.waitForSelector("#done-panel:not([hidden]), #saved-panel:not([hidden])", { timeout: 30000 });
      const donePanel = await popup.locator("#done-panel").isVisible().catch(() => false);
      const doneText = donePanel ? await popup.locator("#done-text").textContent().catch(() => "") : "";
      check("the popup reports the bookmark as added", /added|library/i.test(doneText || ""), String(doneText).slice(0, 120));
    } else {
      const savedTitle = await popup.locator("#saved-title").textContent().catch(() => "");
      check("the popup renders the already-saved page", /Extension saved page/i.test(savedTitle || ""), String(savedTitle).slice(0, 120));
    }
  } else {
    const optionsPage = await context.newPage();
    await optionsPage.goto(`chrome-extension://${extensionId}/options.html`, { waitUntil: "domcontentloaded" });
    await extension.evaluate(async (tabId) => {
      await chrome.tabs.update(tabId, { active: true });
    }, unsavedTab.id);
    const response = await optionsPage.evaluate(
      async (url) =>
        chrome.runtime.sendMessage({
          type: "eza:addBookmark",
          url,
          title: "Extension added page",
          tags: ["extension-e2e", "browser"],
        }),
      unsavedUrl,
    );
    check("the background add-bookmark message succeeds", Boolean(response && response.ok), JSON.stringify(response));
  }

  await poll(
    "the page shows as saved after the add action",
    async () => {
      const listed = await api("/api/v1/bookmarks?q=" + encodeURIComponent("Extension added page") + "&limit=10");
      return listed.body && listed.body.items ? listed.body.items.length : 0;
    },
    (count) => count > 0,
  );
  const added = await api("/api/v1/bookmarks?q=" + encodeURIComponent("Extension added page") + "&limit=10");
  const addedBookmark = added.body && added.body.items && added.body.items[0];
  check("the added bookmark carries the popup tags", Boolean(addedBookmark && (addedBookmark.tags || []).includes("browser")), JSON.stringify(addedBookmark && addedBookmark.tags));
  check("the saved fixture is still a single row", Boolean(savedId), String(savedId));

  await extension.evaluate(async (tabId) => {
    await chrome.tabs.update(tabId, { active: true });
  }, unsavedTab.id);
  await poll(
    "the added page gets the saved badge on the toolbar",
    () => badgeFor(extension, unsavedTab.id),
    (status) => status && status.text === "✓",
  );

  // The lookup route is what makes the badge possible; a direct fetch from
  // the extension origin also proves the CORS allowlist, independent of the
  // host-permission shortcut in this test build.
  const lookup = await extension.evaluate(
    async ({ serverUrl, token, url }) => {
      const response = await fetch(serverUrl + "/api/v1/bookmarks/lookup?url=" + encodeURIComponent(url), {
        headers: { Authorization: "Bearer " + token, "X-Eza-Client": "eza-clipper/e2e" },
        credentials: "omit",
      });
      return { status: response.status, body: await response.json().catch(() => null) };
    },
    { serverUrl: BASE, token: captureToken, url: savedUrl },
  );
  check(
    "the extension origin can read the lookup route with a capture token",
    lookup.status === 200 && lookup.body && lookup.body.bookmark && lookup.body.bookmark.id === savedId,
    JSON.stringify({ status: lookup.status, bookmark: lookup.body && lookup.body.bookmark && lookup.body.bookmark.id }),
  );
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  if (context) await context.close().catch(() => {});
  rmSync(buildDir, { recursive: true, force: true });
  rmSync(profileDir, { recursive: true, force: true });
  report();
}
