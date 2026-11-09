// Graph smoke test: the whole-library /graph paints the canvas, counts the
// library, filters, zooms, toggles tags and opens records.
//
// The runner imports tests/fixtures/mini-bookmarks.html before this script:
// three records filed on 2023-11-14 UTC from example.com, tagged rust (A and
// B) and toolbar (A). The script adds one resolved and one unresolved wikilink
// to B through the API before it loads the page, so the payload under test has
// exactly one graph link.
//
// Run from the repo root in the dev shell, against a scratch server seeded
// with the mini fixture:
//   EZA_BASE=http://localhost:8100 node tests/e2e/graph-smoke.mjs
import { BASE, SEL, launchBrowser, launchPage, enterLibrary, makeApi, newChecker } from "./lib/dom.mjs";

const RECORDS = 3;
const FIT_PERCENT = 100;
const FOCUS_PERCENT = 260;

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser, { viewport: { width: 1440, height: 950 } });
const { check, report } = newChecker();
const api = makeApi(page);

// The plate is a canvas; the only portable proof that it painted is the
// number of non-transparent pixels in the backing store.
async function canvasHasPixels() {
  return page.evaluate((selector) => {
    const canvas = document.querySelector(selector);
    if (!canvas || !canvas.width || !canvas.height) return false;
    const context = canvas.getContext("2d");
    if (!context) return false;
    const data = context.getImageData(0, 0, canvas.width, canvas.height).data;
    let opaque = 0;
    for (let index = 3; index < data.length; index += 4) {
      if (data[index] !== 0) opaque += 1;
      if (opaque > 500) return true;
    }
    return false;
  }, SEL.graphCanvas);
}

async function waitForPlate() {
  await page.waitForSelector(SEL.graphStatus, { timeout: 30000 });
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (await canvasHasPixels()) return;
    await page.waitForTimeout(50);
  }
  throw new Error("the graph canvas stayed blank");
}

async function statusText() {
  return ((await page.locator(SEL.graphStatus).first().innerText()) || "").replace(/\s+/g, " ").trim();
}

async function waitForStatus(pattern) {
  return page
    .waitForFunction(
      ({ selector, source }) => new RegExp(source).test(document.querySelector(selector)?.textContent || ""),
      { selector: SEL.graphStatus, source: pattern.source },
      { timeout: 15000 }
    )
    .then(() => true)
    .catch(() => false);
}

async function waitForStatusGone(pattern) {
  return page
    .waitForFunction(
      ({ selector, source }) => !new RegExp(source).test(document.querySelector(selector)?.textContent || ""),
      { selector: SEL.graphStatus, source: pattern.source },
      { timeout: 15000 }
    )
    .then(() => true)
    .catch(() => false);
}

async function waitForResultCount(count) {
  return page
    .waitForFunction(
      ({ selector, count }) => document.querySelectorAll(selector).length === count,
      { selector: SEL.graphResult, count },
      { timeout: 15000 }
    )
    .then(() => true)
    .catch(() => false);
}

async function zoomPercent() {
  const text = (await page.locator(SEL.graphZoomValue).first().innerText()) || "";
  const match = text.match(/(\d+)/);
  return match ? Number(match[1]) : Number.NaN;
}

// The readout is relative to the fit scale, so a plain /graph opens at 100
// percent and a focus view sits at 2.6 times fit.
async function waitForZoom(operator, value) {
  return page
    .waitForFunction(
      ({ selector, operator, value }) => {
        const match = (document.querySelector(selector)?.textContent || "").match(/(\d+)/);
        if (!match) return false;
        const current = Number(match[1]);
        if (operator === ">") return current > value;
        if (operator === "<") return current < value;
        return current === value;
      },
      { selector: SEL.graphZoomValue, operator, value },
      { timeout: 15000 }
    )
    .then(() => true)
    .catch(() => false);
}

try {
  await enterLibrary(page);
  await page.waitForSelector(SEL.appShell, { timeout: 60000 });

  // ------------------------------------------------------ seed wikilinks ---
  const list = await api("/api/v1/bookmarks?limit=100");
  const items = list.body?.items || [];
  const byTitle = new Map(items.map((item) => [item.title, item]));
  const fixtureA = byTitle.get("A");
  const fixtureB = byTitle.get("B");
  check("the mini fixture is seeded", Boolean(fixtureA && fixtureB), list.status + " " + items.length + " items");
  if (!fixtureA || !fixtureB) {
    throw new Error("graph-smoke needs the mini fixture; run it through scripts/e2e.sh (EZA_E2E_SEED defaults to mini)");
  }
  const seeded = await api("/api/v1/bookmarks/" + fixtureB.id, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ note_body: "See [[A]] and [[Missing page]]." }),
  });
  check("the resolved wikilink saves", seeded.status === 200, String(seeded.status));

  const graph = await api("/api/v1/graph");
  const graphBody = graph.body || {};
  check(
    "the graph API answers with the compact payload",
    graph.status === 200 &&
      Array.isArray(graphBody.tags) &&
      Array.isArray(graphBody.records) &&
      Array.isArray(graphBody.links) &&
      !("nodes" in graphBody) &&
      !("edges" in graphBody),
    JSON.stringify({ status: graph.status, keys: Object.keys(graphBody) })
  );
  check(
    "the payload holds only the resolved wikilink",
    JSON.stringify(graphBody.links) === JSON.stringify([[fixtureB.id, fixtureA.id]]),
    JSON.stringify(graphBody.links)
  );

  // -------------------------------------------------------------- canvas ---
  await page.click(SEL.section("graph"));
  await page.waitForSelector(SEL.graph, { timeout: 30000 });
  await waitForPlate();
  check("the section link opens /graph", new URL(page.url()).pathname === "/graph", page.url());
  check(
    "the canvas sits inside the plate",
    (await page.locator(SEL.graphPlate + " " + SEL.graphCanvas).count()) === 1,
    String(await page.locator(SEL.graphCanvas).count())
  );
  const plateBox = await page.locator(SEL.graphCanvas).boundingBox();
  check("the canvas has a real plate size", Boolean(plateBox) && plateBox.width > 300 && plateBox.height > 200, JSON.stringify(plateBox));

  // --------------------------------------------------- status and lists ---
  const initialStatus = await statusText();
  check("the status counts the fixture records", new RegExp("\\b" + RECORDS + " records\\b").test(initialStatus), initialStatus);
  check("the status counts the fixture tags", /\b2 tags\b/.test(initialStatus), initialStatus);
  check("the status counts the resolved link", /\b1 link\b/.test(initialStatus), initialStatus);
  check("the aside lists the top tags as buttons", (await page.locator(SEL.graphTag).count()) === 2, String(await page.locator(SEL.graphTag).count()));
  check("the aside carries the preview card", (await page.locator(SEL.graphPreview).count()) === 1, String(await page.locator(SEL.graphPreview).count()));

  // -------------------------------------------------------------- filter ---
  await page.fill(SEL.graphFilter, "rust");
  await waitForStatus(/match the filter/);
  const filteredStatus = await statusText();
  check("the filter reports the matching records", /\b2 of 3 records match the filter\b/.test(filteredStatus), filteredStatus);
  await waitForResultCount(2);
  check("the results list narrows to the matches", (await page.locator(SEL.graphResult).count()) === 2, String(await page.locator(SEL.graphResult).count()));

  await page.fill(SEL.graphFilter, "zzz-no-match");
  await waitForStatus(/0 of 3 records match the filter/);
  check("a filter with no matches says zero", /\b0 of 3 records match the filter\b/.test(await statusText()), await statusText());
  await waitForResultCount(0);
  check("a filter with no matches leaves no results", (await page.locator(SEL.graphResult).count()) === 0, String(await page.locator(SEL.graphResult).count()));

  // ---------------------------------------------------------- keyboard ---
  await page.fill(SEL.graphFilter, "rust");
  await waitForStatus(/match the filter/);
  // The graph keys are scoped to the canvas, which is the route's tab stop.
  await page.locator(SEL.graphCanvas).focus();
  await page.keyboard.press("Escape");
  await page
    .waitForFunction((selector) => (document.querySelector(selector)?.value || "") === "", SEL.graphFilter, { timeout: 15000 })
    .catch(() => {});
  check("Esc clears the filter line", (await page.locator(SEL.graphFilter).inputValue()) === "");
  check("the status returns to the whole graph", await waitForStatusGone(/match the filter/), await statusText());

  // ---------------------------------------------------------------- zoom ---
  const fitPercent = await zoomPercent();
  check("the graph opens at the fit scale", fitPercent === FIT_PERCENT, String(fitPercent));
  await page.click(SEL.graphZoomIn);
  const zoomedIn = await waitForZoom(">", fitPercent);
  const zoomedInPercent = await zoomPercent();
  check("the zoom in button raises the percentage", zoomedIn && zoomedInPercent > fitPercent, String(zoomedInPercent));
  await page.click(SEL.graphZoomOut);
  const zoomedOut = await waitForZoom("<", zoomedInPercent);
  check("the zoom out button lowers the percentage", zoomedOut && (await zoomPercent()) < zoomedInPercent, String(await zoomPercent()));
  await page.click(SEL.graphFit);
  const refit = await waitForZoom("==", fitPercent);
  check("fit returns the graph to the fit scale", refit && (await zoomPercent()) === fitPercent, String(await zoomPercent()));

  // -------------------------------------------------------- tags toggle ---
  const tagsToggle = page.locator(SEL.graphTagsToggle).first();
  check("the tags toggle starts pressed", (await tagsToggle.getAttribute("aria-pressed")) === "true", String(await tagsToggle.getAttribute("aria-pressed")));
  await tagsToggle.click();
  await page
    .waitForFunction((selector) => document.querySelector(selector)?.getAttribute("aria-pressed") === "false", SEL.graphTagsToggle, { timeout: 15000 })
    .catch(() => {});
  check("the tags toggle reports the hidden tags", /tags hidden/i.test(await statusText()), await statusText());
  check("the tags toggle releases its pressed state", (await tagsToggle.getAttribute("aria-pressed")) === "false", String(await tagsToggle.getAttribute("aria-pressed")));
  await tagsToggle.click();
  await page
    .waitForFunction((selector) => document.querySelector(selector)?.getAttribute("aria-pressed") === "true", SEL.graphTagsToggle, { timeout: 15000 })
    .catch(() => {});
  check("the tags toggle returns to pressed", (await tagsToggle.getAttribute("aria-pressed")) === "true", String(await tagsToggle.getAttribute("aria-pressed")));

  // --------------------------------------------------- record from list ---
  await page.fill(SEL.graphFilter, "rust");
  await waitForStatus(/match the filter/);
  await waitForResultCount(2);
  const firstResult = page.locator(SEL.graphResult).first();
  check("the results list has a record to open", (await firstResult.count()) === 1);
  await firstResult.click();
  await page.waitForURL((url) => /\/bookmark\/\d+$/.test(url.pathname), { timeout: 20000 }).catch(() => {});
  const openedPath = new URL(page.url()).pathname;
  check("a result opens its record", /\/bookmark\/\d+$/.test(openedPath), page.url());
  const openedId = Number(openedPath.split("/").pop());
  check("the opened record is one of the matches", openedId === fixtureA.id || openedId === fixtureB.id, String(openedId));
  await page.waitForSelector(SEL.record, { timeout: 20000 }).catch(() => {});
  check("the record page renders", (await page.locator(SEL.record).count()) === 1);

  // ------------------------------------------------- record graph action ---
  const openedTitle = openedId === fixtureA.id ? "A" : "B";
  check("the record page carries the graph action", (await page.locator(SEL.openGraph).count()) === 1, String(await page.locator(SEL.openGraph).count()));
  if ((await page.locator(SEL.openGraph).count()) === 1) {
    await page.click(SEL.openGraph);
    await page.waitForSelector(SEL.graph, { timeout: 30000 }).catch(() => {});
    await waitForPlate().catch(() => {});
    check("a record's graph action opens /graph", new URL(page.url()).pathname === "/graph", page.url());
    const focused = await waitForZoom("==", FOCUS_PERCENT);
    check("the graph action focuses the record at 260 percent", focused && (await zoomPercent()) === FOCUS_PERCENT, String(await zoomPercent()));
    const preview = ((await page.locator(SEL.graphPreview).first().innerText()) || "").replace(/\s+/g, " ").trim();
    check("the focused record is named in the preview", preview.includes(openedTitle), preview);
  }

  // ------------------------------------------------- first-visit focus ---
  // The warm path above keeps the graph layout in the client. A full load on
  // a record URL starts a fresh client, so the record's graph action is the
  // first /graph visit: the cold focus path the warm test would hide.
  await page.goto(BASE + "/bookmark/" + fixtureA.id, { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.record, { timeout: 60000 });
  check("a full load boots straight on a record", (await page.locator(SEL.openGraph).count()) === 1, page.url());
  await page.click(SEL.openGraph);
  await page.waitForSelector(SEL.graphStatus, { timeout: 30000 }).catch(() => {});
  await waitForPlate().catch(() => {});
  check("the first graph visit opens from the record", new URL(page.url()).pathname === "/graph", page.url());
  const firstFocus = await waitForZoom("==", FOCUS_PERCENT);
  check("the first visit focuses the record at 260 percent", firstFocus && (await zoomPercent()) === FOCUS_PERCENT, String(await zoomPercent()));
  const firstPreview = ((await page.locator(SEL.graphPreview).first().innerText()) || "").replace(/\s+/g, " ").trim();
  check("the first visit pins the record preview", firstPreview.includes("A") && firstPreview.includes("example.com"), firstPreview);

  // ------------------------------------------------------- console noise ---
  check("no console errors", errors.length === 0, errors.slice(0, 3).join(" | ").slice(0, 400));
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
