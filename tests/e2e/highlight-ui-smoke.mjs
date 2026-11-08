// Highlight UI smoke test: reader selection, quick highlight, note highlight,
// edit note and mark style, delete, drift resilience, keyboard dismiss.
//
// Run from the repo root in the dev shell, against a scratch server:
//   EZA_BASE=http://localhost:8100 node tests/e2e/highlight-ui-smoke.mjs
import { BASE, SEL, launchBrowser, launchPage, enterLibrary, makeApi, newChecker } from "./lib/dom.mjs";

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser, { viewport: { width: 1440, height: 1000 } });
const { check, report } = newChecker();
const api = makeApi(page);

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

async function openReader(id) {
  await page.goto(BASE + "/bookmark/" + id, { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });
  await page.waitForSelector(SEL.readerText, { timeout: 20000 });
  await page.waitForTimeout(500);
}

try {
  await enterLibrary(page);

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

  await openReader(target.id);
  check("reader renders extracted text", (await page.locator(SEL.readerText).innerText()).length > 120);

  // Selection opens the highlight toolbar.
  check("selection dispatched", await selectReaderRange(5, 45));
  await page.waitForSelector(SEL.highlightToolbar, { timeout: 10000 });
  check("selection opens highlight toolbar", (await page.locator(SEL.highlightToolbar).count()) === 1);

  // Quick highlight.
  await page.getByRole("button", { name: /highlight/i }).first().click();
  await page
    .waitForFunction(
      () => [...document.querySelectorAll('[data-testid="toast"]')].some((toast) => /highlight/i.test(toast.textContent)),
      null,
      { timeout: 20000 }
    )
    .catch(() => {});
  let saved = await highlights(target.id);
  check("quick highlight saved via api", saved.length === 1, JSON.stringify(saved).slice(0, 160));
  check(
    "highlight quote matches selection",
    saved.length === 1 && saved[0].quote === (target.extracted_text || "").substring(5, 45),
    saved[0]?.quote?.slice(0, 40)
  );
  await page.waitForTimeout(500);
  check("highlight mark rendered in reader", (await page.locator(SEL.readerMark).count()) >= 1);
  check("highlight listed below reader", (await page.locator(SEL.highlightRow).count()) === 1);

  // Persisted after reload.
  await openReader(target.id);
  check("highlight persists and renders after reload", (await page.locator(SEL.readerMark).count()) >= 1);

  // Note highlight through the toolbar.
  await selectReaderRange(60, 100);
  await page.waitForSelector(SEL.highlightToolbar, { timeout: 10000 });
  await page.getByRole("button", { name: /^note$/i }).first().click();
  await page.waitForSelector(SEL.highlightNote, { timeout: 10000 });
  await page.fill(SEL.highlightNote, "e2e note");
  await page.locator(SEL.dialogConfirm).click();
  await page.waitForTimeout(1600);
  saved = await highlights(target.id);
  check("note highlight saved", saved.length === 2 && saved.some((entry) => entry.note === "e2e note"), JSON.stringify(saved.map((entry) => entry.note)));

  // Edit note and mark style on the first row. The double mark stores blue.
  await page.locator(SEL.highlightRow).first().locator(SEL.highlightEdit).click();
  await page.waitForSelector(SEL.highlightEditNote, { timeout: 10000 });
  await page.fill(SEL.highlightEditNote, "edited note");
  await page.locator(SEL.highlightStyle("double")).click();
  await page.locator(SEL.dialogConfirm).click();
  await page.waitForTimeout(1600);
  saved = await highlights(target.id);
  const edited = saved.find((entry) => entry.note === "edited note");
  check("highlight note edited", Boolean(edited), JSON.stringify(saved.map((entry) => entry.note)));
  check("highlight mark style updated", edited?.color === "blue", String(edited?.color));

  // Drift resilience: an out-of-range highlight must not corrupt the reader.
  const beforeDrift = await highlights(target.id);
  await api("/api/v1/bookmarks/" + target.id + "/highlights", {
    method: "POST",
    body: JSON.stringify({ quote: "zzz-not-in-text", prefix: "", suffix: "", start_offset: 100000, end_offset: 100010, note: "", color: "yellow" }),
  });
  await openReader(target.id);
  check("drifted highlight skipped without breaking reader", (await page.locator(SEL.readerText).count()) === 1);
  check(
    "invalid range not rendered as a mark",
    (await page.locator(SEL.readerMark).count()) === beforeDrift.length,
    "marks=" + (await page.locator(SEL.readerMark).count()) + " valid=" + beforeDrift.length
  );

  // Delete the first highlight.
  const beforeDelete = (await highlights(target.id)).length;
  await page.locator(SEL.highlightRow).first().locator(SEL.highlightDelete).click();
  await page.waitForTimeout(1600);
  check("highlight deleted", (await highlights(target.id)).length === beforeDelete - 1);

  // Escape clears the selection toolbar.
  await selectReaderRange(10, 30);
  await page.waitForSelector(SEL.highlightToolbar, { timeout: 10000 });
  await page.keyboard.press("Escape");
  await page.waitForTimeout(500);
  check("escape dismisses highlight toolbar", (await page.locator(SEL.highlightToolbar).count()) === 0);
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
