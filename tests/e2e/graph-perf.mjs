// Graph performance check (report-only, not part of the default e2e suite).
//
// Measures the whole-library /graph against a scratch server with a synthetic
// library sized by EZA_PERF_RECORDS (default 9000, close to the reference
// library's 8,838 records). Run it against a disposable server the way
// scripts/e2e.sh runs one, or point EZA_BASE at a staging instance:
//
//   EZA_PERF_RECORDS=9000 EZA_BASE=http://localhost:8210 node tests/e2e/graph-perf.mjs
//
// The script prints the measurements and a budget verdict. It exits non-zero
// only for functional failures; timing is reported so variance on a busy
// machine does not turn into a false red.
import { BASE, SEL, launchBrowser, launchPage, enterLibrary, makeApi } from "./lib/dom.mjs";

const RECORDS = Number(process.env.EZA_PERF_RECORDS || 9000);
const GRAPH = '[data-testid="graph"]';
const STATUS = '[data-testid="graph-status"]';
const CANVAS = "canvas.g-canvas-el";
const FILTER = "#graph-filter";
const TAGS_TOGGLE = '[data-testid="graph-tags-toggle"]';
const ZOOM_IN = '[data-testid="graph-zoom-in"]';
const ZOOM_VALUE = '[data-testid="graph-zoom-value"]';

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser, { viewport: { width: 1440, height: 950 } });
const results = [];
let failed = false;

function record(name, value, unit, budget) {
  results.push({ name, value, unit, budget });
  const verdict = budget === null ? "" : value <= budget ? " (within " + budget + unit + ")" : " (OVER " + budget + unit + ")";
  console.log(name + ": " + Math.round(value * 10) / 10 + unit + verdict);
}

function fail(message) {
  failed = true;
  console.log("FUNCTIONAL FAIL " + message);
}

async function canvasHasPixels() {
  return page.evaluate((selector) => {
    const canvas = document.querySelector(selector);
    if (!canvas || !canvas.width || !canvas.height) return false;
    const ctx = canvas.getContext("2d");
    if (!ctx) return false;
    const data = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
    let opaque = 0;
    for (let i = 3; i < data.length; i += 4) {
      if (data[i] !== 0) opaque += 1;
      if (opaque > 500) return true;
    }
    return false;
  }, CANVAS);
}

async function waitForPlate() {
  await page.waitForSelector(STATUS, { timeout: 60000 });
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    if (await canvasHasPixels()) return;
    await page.waitForTimeout(50);
  }
  throw new Error("canvas stayed blank");
}

async function framesDuring(work) {
  await page.evaluate(() => {
    window.__ezaPerfFrames = [];
    window.__ezaPerfLast = performance.now();
    window.__ezaPerfOn = true;
    const tick = (now) => {
      if (!window.__ezaPerfOn) return;
      window.__ezaPerfFrames.push(now - window.__ezaPerfLast);
      window.__ezaPerfLast = now;
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
  await work();
  return page.evaluate(() => {
    window.__ezaPerfOn = false;
    const values = window.__ezaPerfFrames.slice(1).sort((a, b) => a - b);
    if (!values.length) return { count: 0, p50: 0, p95: 0, max: 0 };
    const at = (p) => values[Math.min(values.length - 1, Math.floor(values.length * p))];
    return { count: values.length, p50: at(0.5), p95: at(0.95), max: values[values.length - 1] };
  });
}

function netscape(count) {
  const folders = ["books", "reading", "tabs", "archive", "dev", "films", "paper", "audio", "art", "linux", "nix", "music"];
  const lines = ["<!DOCTYPE NETSCAPE-Bookmark-file-1>", "<TITLE>Perf</TITLE>", "<H1>Perf</H1>", "<DL><p>"];
  for (const folder of folders) {
    lines.push('    <DT><H3>' + folder + "</H3>", "    <DL><p>");
    for (let i = 0; i < count; i += folders.length) {
      const index = i + folders.indexOf(folder);
      lines.push(
        '        <DT><A HREF="https://perf.example/' + index + '" ADD_DATE="' + (1600000000 + index * 900) + '">Perf record ' + index + " " + folder + "</A>"
      );
    }
    lines.push("    </DL><p>");
  }
  lines.push("</DL><p>");
  return lines.join("\n");
}

try {
  await enterLibrary(page);
  await page.waitForSelector(SEL.appShell, { timeout: 60000 });

  const api = makeApi(page);
  const before = await api("/api/v1/boot");
  if ((before.body?.initial?.total || 0) < RECORDS) {
    console.log("seeding " + RECORDS + " records");
    const status = await page.evaluate(async (html) => {
      const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
      const form = new FormData();
      form.append("file", new File([html], "perf.html", { type: "text/html" }));
      const response = await fetch("/api/v1/import", {
        method: "POST",
        body: form,
        headers: { Accept: "application/json", "X-CSRF-Token": csrf },
      });
      return response.status;
    }, netscape(RECORDS));
    if (status !== 200) fail("synthetic import returned " + status);
  }

  // Server side of the request, measured in the page before the app asks for it.
  const apiTiming = await page.evaluate(async () => {
    const started = performance.now();
    const response = await fetch("/api/v1/graph", { credentials: "same-origin" });
    const text = await response.text();
    return { ms: performance.now() - started, bytes: text.length, status: response.status };
  });
  console.log("graph api:", JSON.stringify(apiTiming));
  record("graph api", apiTiming.ms, "ms", 400);

  // In-app navigation is the everyday path: boot from / and click the section.
  await page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.row, { timeout: 60000 });
  const spaStart = Date.now();
  await page.click(SEL.section("graph"));
  await page.waitForSelector(GRAPH, { timeout: 60000 });
  await waitForPlate();
  record("cold plate (in-app)", Date.now() - spaStart, "ms", 1500);

  // A full reload is the worst case: WASM boot, then the graph request.
  const coldStart = Date.now();
  await page.goto(BASE + "/graph", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(GRAPH, { timeout: 60000 });
  await waitForPlate();
  record("cold plate (full reload)", Date.now() - coldStart, "ms", 3000);

  await page.waitForTimeout(300);
  const statusText = await page.locator(STATUS).innerText();
  console.log("status:", statusText.replace(/\s+/g, " ").slice(0, 200));

  const box = await page.locator(CANVAS).boundingBox();
  if (!box) fail("no canvas box");
  else {
    const cx = box.x + box.width / 2;
    const cy = box.y + box.height / 2;
    await page.mouse.move(cx, cy);

    const dragFrames = await framesDuring(async () => {
      await page.mouse.down();
      for (let i = 1; i <= 90; i += 1) {
        await page.mouse.move(cx + Math.sin(i / 9) * 140, cy + Math.cos(i / 11) * 90);
      }
      await page.mouse.up();
    });
    record("drag frames p50", dragFrames.p50, "ms", 16.7);
    record("drag frames p95", dragFrames.p95, "ms", 33);
    console.log("drag frames:", JSON.stringify(dragFrames));

    const wheelFrames = await framesDuring(async () => {
      for (let i = 0; i < 12; i += 1) {
        await page.mouse.wheel(0, i < 6 ? -240 : 240);
        await page.waitForTimeout(30);
      }
    });
    record("wheel frames p95", wheelFrames.p95, "ms", 33);
  }

  await page.locator(ZOOM_IN).first().click().catch(() => fail("zoom in button missing"));
  const zoomText = await page.locator(ZOOM_VALUE).first().innerText().catch(() => "");
  console.log("zoom value:", zoomText);

  const filterStart = Date.now();
  await page.fill(FILTER, "books");
  await page.waitForFunction(
    () => {
      const status = document.querySelector('[data-testid="graph-status"]');
      return status && /match|match(es)?/i.test(status.textContent || "");
    },
    { timeout: 5000 }
  ).catch(() => {});
  record("filter apply", Date.now() - filterStart, "ms", 400);
  await page.fill(FILTER, "");

  const toggleStart = Date.now();
  await page.locator(TAGS_TOGGLE).first().click();
  await page.waitForFunction(
    () => document.querySelector('[data-testid="graph-tags-toggle"]')?.getAttribute("aria-pressed") === "false",
    { timeout: 5000 }
  ).catch(() => fail("tags toggle did not settle"));
  record("tags toggle", Date.now() - toggleStart, "ms", 200);

  // Warm return is an in-app round trip: keep the component state, leave for
  // the ledger and come back. A full reload is measured separately above.
  await page.click(SEL.section("ledger"));
  await page.waitForSelector(SEL.row, { timeout: 60000 });
  const warmStart = Date.now();
  await page.click(SEL.section("graph"));
  await page.waitForSelector(STATUS, { timeout: 60000 });
  await waitForPlate();
  record("warm return plate (in-app)", Date.now() - warmStart, "ms", 400);

  console.log("");
  console.log(JSON.stringify({ records: RECORDS, results }, null, 2));
  const consoleErrors = errors.filter((error) => !error.includes("401"));
  if (consoleErrors.length) {
    console.log("console errors:");
    for (const error of consoleErrors.slice(0, 10)) console.log("  " + error);
    failed = true;
  }
  if (failed) process.exitCode = 1;
} catch (error) {
  console.error("FUNCTIONAL FAIL", error && error.stack ? error.stack : error);
  process.exitCode = 1;
} finally {
  await browser.close();
}
