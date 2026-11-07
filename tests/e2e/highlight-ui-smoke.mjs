// Highlight UI smoke test: reader selection, create quick highlight, note
// highlight, edit note/colour, delete, drift resilience, keyboard dismiss.
//
// Run from the repo root in the dev shell:
//   EZA_BASE=http://localhost:8095 node tests/e2e/highlight-ui-smoke.mjs
import { chromium } from "@playwright/test";

const BASE = process.env.EZA_BASE || "http://localhost:8095";
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
const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
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

const highlights = async (id) => (await api("/api/v1/bookmarks/" + id + "/highlights")).body?.highlights || [];

// Select [start, end) characters inside #reader-text and dispatch mouseup so
// the Miso handler runs.
const selectReaderRange = (start, end) =>
  page.evaluate(
    ({ start, end }) => {
      const container = document.getElementById("reader-text");
      if (!container) return false;
      const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT);
      let node = null;
      let pos = 0;
      let startNode = null;
      let startOffset = 0;
      let endNode = null;
      let endOffset = 0;
      while ((node = walker.nextNode())) {
        const length = node.textContent.length;
        if (startNode === null && start <= pos + length) {
          startNode = node;
          startOffset = start - pos;
        }
        if (endNode === null && end <= pos + length) {
          endNode = node;
          endOffset = end - pos;
          break;
        }
        pos += length;
      }
      if (!startNode || !endNode) return false;
      const range = document.createRange();
      range.setStart(startNode, startOffset);
      range.setEnd(endNode, endOffset);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      container.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
      return true;
    },
    { start, end }
  );

try {
  await page.goto(BASE + "/setup", { waitUntil: "domcontentloaded" });
  await page.click("#passkey-setup");
  await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
  await page.click("#continue");
  await page.waitForSelector(".topbar", { timeout: 30000 });
  await page.waitForTimeout(1200);

  // Find a bookmark with extracted reader text (fall back to enrichment).
  const listing = await api("/api/v1/bookmarks?limit=40&offset=0");
  let target = null;
  for (const item of listing.body?.items || []) {
    const detail = await api("/api/v1/bookmarks/" + item.id);
    if (detail.status === 200 && (detail.body?.extracted_text || "").trim().length > 120) {
      target = detail.body;
      break;
    }
  }
  if (!target) {
    for (const item of (listing.body?.items || []).slice(0, 3)) {
      await api("/api/v1/bookmarks/" + item.id + "/extract", { method: "POST", body: "{}" });
      for (let attempt = 0; attempt < 10; attempt++) {
        await page.waitForTimeout(1000);
        const detail = await api("/api/v1/bookmarks/" + item.id);
        if (detail.status === 200 && (detail.body?.extracted_text || "").trim().length > 120) {
          target = detail.body;
          break;
        }
      }
      if (target) break;
    }
  }
  check("found bookmark with extracted text", Boolean(target), target ? "bookmark #" + target.id : "none");
  if (!target) throw new Error("no bookmark with extracted text; seed extracted_text or enable enrichment");

  await page.goto(BASE + "/bookmark/" + target.id, { waitUntil: "domcontentloaded" });
  await page.waitForSelector("#reader-text", { timeout: 20000 });
  await page.waitForTimeout(600);
  check("reader renders extracted text", (await page.locator("#reader-text").innerText()).length > 120);

  // Select a range -> toolbar.
  check("selection dispatched", await selectReaderRange(5, 45));
  await page.waitForSelector(".highlight-toolbar", { timeout: 10000 });
  check("selection opens highlight toolbar", (await page.locator(".highlight-toolbar").count()) === 1);

  // Quick highlight.
  await page.getByRole("button", { name: "Highlight", exact: true }).click();
  await page.waitForFunction(
    () => [...document.querySelectorAll(".toast")].some((toast) => /Highlight saved/.test(toast.textContent)),
    null,
    { timeout: 20000 }
  ).catch(() => {});
  let saved = await highlights(target.id);
  check("quick highlight saved via api", saved.length === 1, JSON.stringify(saved).slice(0, 160));
  check(
    "highlight quote matches selection",
    saved.length === 1 && saved[0].quote === (target.extracted_text || "").substring(5, 45),
    saved[0]?.quote?.slice(0, 40)
  );
  await page.waitForTimeout(500);
  check("highlight span rendered in reader", (await page.locator("#reader-text span.hl").count()) >= 1);
  check("highlight listed below reader", (await page.locator(".highlight-row").count()) === 1);

  // Persisted after reload.
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.waitForSelector("#reader-text", { timeout: 20000 });
  await page.waitForTimeout(900);
  check("highlight persists and renders after reload", (await page.locator("#reader-text span.hl").count()) >= 1);

  // Note highlight through the toolbar.
  await selectReaderRange(60, 100);
  await page.waitForSelector(".highlight-toolbar", { timeout: 10000 });
  await page.getByRole("button", { name: "Note", exact: true }).click();
  await page.waitForSelector("#highlight-note", { timeout: 10000 });
  await page.fill("#highlight-note", "e2e note");
  await page.getByRole("button", { name: "Save highlight", exact: true }).click();
  await page.waitForTimeout(1600);
  saved = await highlights(target.id);
  check("note highlight saved", saved.length === 2 && saved.some((h) => h.note === "e2e note"), JSON.stringify(saved.map((h) => h.note)));

  // Edit note + colour on the first row.
  await page.locator('.highlight-row button[title="Edit highlight"]').first().click();
  await page.waitForSelector("#highlight-edit-note", { timeout: 10000 });
  await page.fill("#highlight-edit-note", "edited note");
  await page.locator('.color-swatch[title="Set purple colour"]').click();
  await page.getByRole("button", { name: "Save changes", exact: true }).click();
  await page.waitForTimeout(1600);
  saved = await highlights(target.id);
  const edited = saved.find((h) => h.note === "edited note");
  check("highlight note edited", Boolean(edited), JSON.stringify(saved.map((h) => h.note)));
  check("highlight colour updated", edited?.color === "purple", String(edited?.color));

  // Drift resilience: an out-of-range highlight must not corrupt the reader.
  const beforeDrift = await highlights(target.id);
  await api("/api/v1/bookmarks/" + target.id + "/highlights", {
    method: "POST",
    body: JSON.stringify({ quote: "zzz-not-in-text", prefix: "", suffix: "", start_offset: 100000, end_offset: 100010, note: "", color: "yellow" }),
  });
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.waitForSelector("#reader-text", { timeout: 20000 });
  await page.waitForTimeout(900);
  check("drifted highlight skipped without breaking reader", (await page.locator("#reader-text").count()) === 1);
  check(
    "invalid range not rendered as span",
    (await page.locator("#reader-text span.hl").count()) === beforeDrift.length,
    "spans=" + (await page.locator("#reader-text span.hl").count()) + " valid=" + beforeDrift.length
  );

  // Delete the first highlight.
  const beforeDelete = (await highlights(target.id)).length;
  await page.locator('.highlight-row button[title="Delete highlight"]').first().click();
  await page.waitForTimeout(1600);
  check("highlight deleted", (await highlights(target.id)).length === beforeDelete - 1);

  // Keyboard: Escape clears the selection toolbar.
  await selectReaderRange(10, 30);
  await page.waitForSelector(".highlight-toolbar", { timeout: 10000 });
  await page.keyboard.press("Escape");
  await page.waitForTimeout(500);
  check("escape dismisses highlight toolbar", (await page.locator(".highlight-toolbar").count()) === 0);
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
