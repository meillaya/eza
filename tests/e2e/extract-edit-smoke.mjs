// Extracted-text editor smoke test: a record's reading copy can be corrected,
// the save updates the stored text, FTS and reading time, the manual state
// survives a reload, and cancel leaves the stored copy alone.
//
// Run from the repo root in the dev shell, against a scratch server:
//   EZA_BASE=http://localhost:8100 node tests/e2e/extract-edit-smoke.mjs
import { BASE, SEL, launchBrowser, launchPage, enterLibrary, makeApi, newChecker } from "./lib/dom.mjs";

const EDITED = "Edited extraction smoke. This sentence is deliberately different from the seeded copy.\n\nQuokka is now searchable in the reading copy.";

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser);
const { check, report } = newChecker();
const api = makeApi(page);

try {
  await enterLibrary(page);
  const pageResult = await api("/api/v1/bookmarks?limit=1");
  const bookmark = pageResult.body?.items?.[0];
  check("a record is available", Number.isInteger(bookmark?.id), JSON.stringify(pageResult.body).slice(0, 160));
  const target = bookmark.id;

  await page.goto(BASE + "/bookmark/" + target, { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.record, { timeout: 30000 });
  await page.waitForSelector(SEL.extractEdit, { timeout: 20000 });
  await page.locator(SEL.extractEdit).click();
  await page.waitForSelector(SEL.extractEditor, { timeout: 10000 });
  await page.fill("#extract-text-editor", EDITED);
  await page.locator(SEL.extractSave).click();
  await page.waitForSelector(SEL.extractEditor, { state: "detached", timeout: 20000 });

  const detail = await api("/api/v1/bookmarks/" + target);
  check("save persists the edited text", detail.body?.extracted_text === EDITED, JSON.stringify(detail.body).slice(0, 160));
  check("save marks the copy manual", detail.body?.enrich_state === "manual", String(detail.body?.enrich_state));
  check("save recomputes reading time", Number(detail.body?.reading_time_minutes) >= 0, String(detail.body?.reading_time_minutes));

  const search = await api("/api/v1/bookmarks?q=quokka&limit=5");
  check("the edited text is searchable", (search.body?.items || []).some((item) => item.id === target), JSON.stringify(search.body?.total));

  await page.reload({ waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.record, { timeout: 30000 });
  const readerText = await page.locator(SEL.readerText).innerText();
  check("the edited text survives a reload", readerText.includes("Quokka is now searchable"), readerText.slice(0, 100));

  await page.locator(SEL.extractEdit).click();
  await page.waitForSelector(SEL.extractEditor, { timeout: 10000 });
  await page.fill("#extract-text-editor", "discard me");
  await page.locator(SEL.extractCancel).click();
  await page.waitForSelector(SEL.extractEditor, { state: "detached", timeout: 10000 });
  const afterCancel = await api("/api/v1/bookmarks/" + target);
  check("cancel keeps the stored copy", afterCancel.body?.extracted_text === EDITED, JSON.stringify(afterCancel.body?.extracted_text).slice(0, 120));
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
