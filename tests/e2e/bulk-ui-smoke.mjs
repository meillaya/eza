// Bulk selection UI smoke test: checkboxes, shift-range, floating action bar,
// add/remove tags, mark read/unread, delete confirmation, undo, select-all.
//
// Run from the repo root in the dev shell:
//   EZA_BASE=http://localhost:8093 node tests/e2e/bulk-ui-smoke.mjs
import { chromium } from "@playwright/test";

const BASE = process.env.EZA_BASE || "http://localhost:8093";
const passed = [];
const failed = [];
function check(name, condition, detail) {
  if (condition) {
    passed.push(name);
    console.log("PASS " + name + (detail ? " — " + detail : ""));
  } else {
    failed.push(name + (detail ? " — " + detail : ""));
    console.log("FAIL " + name + (detail ? " — " + detail : ""));
  }
}

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1440, height: 950 } });
const page = await context.newPage();
const consoleErrors = [];
page.on("console", (message) => {
  if (message.type() === "error") consoleErrors.push(message.text());
});
page.on("pageerror", (error) => consoleErrors.push(String(error)));

const cdp = await context.newCDPSession(page);
await cdp.send("WebAuthn.enable", { enableUI: false });
await cdp.send("WebAuthn.addVirtualAuthenticator", {
  options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true },
});

const api = (path, options = {}) =>
  page.evaluate(
    async ({ path, options }) => {
      const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
      const headers = Object.assign({ "Content-Type": "application/json" }, options.headers || {});
      if ((options.method || "GET") !== "GET") headers["X-CSRF-Token"] = csrf;
      const response = await fetch(path, { ...options, headers });
      let body = null;
      try { body = await response.json(); } catch (_) {}
      return { status: response.status, body };
    },
    { path, options }
  );

const selectedText = async () => (await page.locator(".selection-count").textContent().catch(() => "")) || "";
const waitSelection = async (count) => {
  await page.waitForFunction(
    (expected) => {
      const element = document.querySelector(".selection-count");
      return Boolean(element && element.textContent.includes(String(expected) + " selected"));
    },
    count,
    { timeout: 20000 }
  );
};
const clickCardCheckbox = async (id, modifiers = []) => {
  await page.locator('input.card-select[data-id="' + id + '"]').click({ modifiers });
};

try {
  await page.goto(BASE + "/setup", { waitUntil: "domcontentloaded" });
  await page.click("#passkey-setup");
  await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
  await page.click("#continue");
  await page.waitForSelector(".topbar", { timeout: 30000 });
  await page.waitForTimeout(1400);
  check("library loaded", (await page.locator(".card").count()) > 0);

  // Pick known ids from the API (order matches the grid's default sort).
  const page1 = await api("/api/v1/bookmarks?limit=5&offset=0");
  const ids = (page1.body?.items || []).map((item) => item.id);
  check("api returned ids", ids.length >= 3, JSON.stringify(ids));
  check("one checkbox per card", (await page.locator("input.card-select").count()) > 0);

  // Single selection.
  await clickCardCheckbox(ids[0]);
  await waitSelection(1);
  check("bar appears after one selection", (await page.locator(".selection-bar").count()) === 1);
  check("single selection count", (await selectedText()).includes("1 selected"));

  // Shift-click range: first -> third selects three.
  await clickCardCheckbox(ids[2], ["Shift"]);
  await waitSelection(3);
  const checkedCount = await page.locator("input.card-select:checked").count();
  check("shift-click range selects 3", checkedCount === 3, String(checkedCount));

  // Add tag to the selection.
  await page.getByRole("button", { name: "Add tag", exact: true }).click();
  await page.waitForSelector("#bulk-tag-input", { timeout: 10000 });
  await page.fill("#bulk-tag-input", "bulk-smoke");
  await page.locator(".modal-foot").getByRole("button", { name: "Apply", exact: true }).click();
  await page.waitForFunction(
    () => [...document.querySelectorAll(".toast")].some((toast) => /Updated 3 bookmarks/.test(toast.textContent)),
    null,
    { timeout: 20000 }
  ).catch(() => {});
  const addToasts = await page.evaluate(() => [...document.querySelectorAll(".toast")].map((t) => t.textContent.trim()));
  check("add tag toast", addToasts.some((text) => text.includes("Updated 3 bookmarks")), JSON.stringify(addToasts));
  check("selection cleared after bulk", (await page.locator(".selection-bar").count()) === 0);

  const tagged = [];
  for (const id of ids.slice(0, 3)) {
    const detail = await api("/api/v1/bookmarks/" + id);
    tagged.push((detail.body?.tags || []).includes("bulk-smoke"));
  }
  check("all three bookmarks tagged", tagged.every(Boolean), JSON.stringify(tagged));

  // Mark unread on two bookmarks.
  await clickCardCheckbox(ids[0]);
  await clickCardCheckbox(ids[1]);
  await waitSelection(2);
  await page.getByRole("button", { name: "Mark unread", exact: true }).click();
  await page.waitForTimeout(1500);
  const reads = [];
  for (const id of ids.slice(0, 2)) {
    const detail = await api("/api/v1/bookmarks/" + id);
    reads.push(detail.body?.is_read);
  }
  check("mark unread applied", reads.every((wasRead) => wasRead === false), JSON.stringify(reads));

  // Delete with confirmation + undo from the bar.
  const doomed = ids[3] ?? ids[2];
  await clickCardCheckbox(doomed);
  await waitSelection(1);
  await page.getByRole("button", { name: "Delete", exact: true }).click();
  await page.waitForSelector(".modal", { timeout: 10000 });
  const confirmText = await page.locator(".modal-body").first().innerText();
  check("delete asks for confirmation", /snapshot is kept/i.test(confirmText), confirmText.replace(/\n+/g, " ").slice(0, 80));
  await page.getByRole("button", { name: "Delete bookmarks", exact: true }).click();
  await page.waitForTimeout(1600);
  const deleted = await api("/api/v1/bookmarks/" + doomed);
  check("bookmark deleted", deleted.status === 404, "status " + deleted.status);

  await clickCardCheckbox(ids[0]);
  await waitSelection(1);
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await page.waitForFunction(
    () => [...document.querySelectorAll(".toast")].some((toast) => /Restored/.test(toast.textContent)),
    null,
    { timeout: 20000 }
  ).catch(() => {});
  await page.waitForTimeout(600);
  const restored = await api("/api/v1/bookmarks/" + doomed);
  check("undo restores deleted bookmark", restored.status === 200, "status " + restored.status);

  // Select all matching (small query) then clear.
  await page.getByRole("button", { name: "Clear selection" }).click().catch(() => {});
  await page.fill("#search-input", "playstation");
  await page.waitForTimeout(1500);
  const matches = await api("/api/v1/bookmarks?q=playstation&limit=200&offset=0");
  const matchCount = matches.body?.total ?? 0;
  await page.getByRole("button", { name: "Select all matching", exact: true }).first().click();
  await page.waitForFunction(
    () => {
      const element = document.querySelector(".selection-count");
      return Boolean(element && /\d+ selected/.test(element.textContent));
    },
    null,
    { timeout: 30000 }
  ).catch(() => {});
  const allText = await selectedText();
  check(
    "select all matching selects the full result set",
    matchCount > 0 && allText.includes(String(matchCount) + " selected"),
    allText + " (api total " + matchCount + ")"
  );
  await page.getByRole("button", { name: "Clear selection" }).click();
  await page.waitForTimeout(300);
  check("clear selection hides the bar", (await page.locator(".selection-bar").count()) === 0);

  // Keyboard: focus a checkbox and toggle with Space.
  await page.fill("#search-input", "");
  await page.waitForTimeout(1400);
  await page.locator("input.card-select").first().focus();
  await page.keyboard.press("Space");
  await page.waitForTimeout(400);
  check("keyboard space toggles selection", (await page.locator(".selection-bar").count()) === 1);
  await page.keyboard.press("Escape");
  await page.waitForTimeout(300);
  check("escape clears selection", (await page.locator(".selection-bar").count()) === 0);
} catch (error) {
  failed.push("unexpected error — " + (error && error.stack ? error.stack : String(error)));
} finally {
  await browser.close();
}

console.log("");
console.log("passed: " + passed.length + ", failed: " + failed.length);
if (consoleErrors.length) {
  console.log("console errors (" + consoleErrors.length + "):");
  for (const error of consoleErrors.slice(0, 10)) console.log("  " + error);
}
if (failed.length) {
  console.log("failures:");
  for (const failure of failed) console.log("  - " + failure);
  process.exit(1);
}
