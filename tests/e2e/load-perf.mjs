// Cold/warm load profile (report-only by default, not part of the default e2e
// suite). It measures the user-visible path rather than the server benchmark:
//
//   EZA_BASE=http://localhost:8210 node tests/e2e/load-perf.mjs
//   EZA_PERF_ASSERT=1 ... same command ...   # exit non-zero on a budget miss
//
// A fresh browser context with the signed-in storage state has no service
// worker and no HTTP cache, so the first navigation is a real cold visit. The
// ledger is measured before the graph so the first-row budget pays the full
// WASM boot; the graph measurements then separate in-app navigation from a
// full reload.
import { BASE, SEL, launchBrowser, launchPage, enterLibrary } from "./lib/dom.mjs";

const ASSERT = process.env.EZA_PERF_ASSERT === "1";
const results = [];
let failed = false;

function record(name, value, unit, budget) {
  const over = budget !== null && value > budget;
  results.push({ name, value, unit, budget, over });
  const verdict = budget === null ? "" : !over ? " (within " + budget + unit + ")" : " (OVER " + budget + unit + ")";
  console.log(name + ": " + Math.round(value * 10) / 10 + unit + verdict);
  if (over && ASSERT) failed = true;
}

function fail(message) {
  failed = true;
  console.log("FUNCTIONAL FAIL " + message);
}

async function marksAndResources(page) {
  return page.evaluate(() => {
    const marks = {};
    for (const entry of performance.getEntriesByType("mark")) {
      if (entry.name.startsWith("eza:")) marks[entry.name] = Math.round(entry.startTime * 10) / 10;
    }
    const resources = performance
      .getEntriesByType("resource")
      .filter((entry) => /app\.wasm|\/api\/v1\/boot|\/api\/v1\/graph|\/sw\.js|\/assets\/pwa\.js/.test(entry.name))
      .map((entry) => ({
        name: new URL(entry.name).pathname,
        transferSize: entry.transferSize || 0,
        encodedBodySize: entry.encodedBodySize || 0,
        duration: Math.round(entry.duration * 10) / 10,
      }));
    const nav = performance.getEntriesByType("navigation")[0];
    return {
      marks,
      resources,
      navigation: nav
        ? {
            domContentLoaded: Math.round(nav.domContentLoadedEventEnd * 10) / 10,
            load: Math.round(nav.loadEventEnd * 10) / 10,
            transferSize: nav.transferSize || 0,
          }
        : null,
    };
  });
}

async function waitForRow(page) {
  await page.waitForSelector(SEL.row, { timeout: 60000 });
}

async function waitForPlate(page) {
  await page.waitForSelector('[data-testid="graph-status"]', { timeout: 60000 });
  const canvas = page.locator("canvas.g-canvas-el");
  await canvas.waitFor({ timeout: 60000 });
  await page.waitForTimeout(200);
}

const browser = await launchBrowser();
const first = await launchPage(browser, { serviceWorkers: "block" });
let storageState;
try {
  await enterLibrary(first.page);
  storageState = await first.context.storageState();
} finally {
  await first.context.close();
}

const cold = await browser.newContext({
  viewport: { width: 1440, height: 950 },
  storageState,
  serviceWorkers: "block",
});
const page = await cold.newPage();
const errors = [];
page.on("console", (message) => {
  if (message.type() === "error") errors.push(message.text());
});
page.on("pageerror", (error) => errors.push(String(error)));

try {
  const coldStart = Date.now();
  await page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
  await waitForRow(page);
  const coldLedgerMs = Date.now() - coldStart;
  record("cold first ledger row", coldLedgerMs, "ms", 1200);
  const coldMarks = await marksAndResources(page);
  console.log("cold ledger marks/resources:", JSON.stringify(coldMarks));

  const inAppStart = Date.now();
  await page.click(SEL.section("graph"));
  await page.waitForSelector(SEL.graph, { timeout: 60000 });
  await waitForPlate(page);
  record("cold graph (in-app)", Date.now() - inAppStart, "ms", 500);

  await page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
  await waitForRow(page);
  const warmStart = Date.now();
  await page.click(SEL.section("graph"));
  await page.waitForSelector(SEL.graph, { timeout: 60000 });
  await waitForPlate(page);
  record("warm graph return", Date.now() - warmStart, "ms", 400);

  // A fresh context with the same storage state has neither the service
  // worker nor the HTTP cache of the ledger context, so this is a genuine cold
  // graph reload.
  const reloadContext = await browser.newContext({
    viewport: { width: 1440, height: 950 },
    storageState,
    serviceWorkers: "block",
  });
  const reloadPage = await reloadContext.newPage();
  try {
    const reloadStart = Date.now();
    await reloadPage.goto(BASE + "/graph", { waitUntil: "domcontentloaded" });
    await waitForPlate(reloadPage);
    const reloadMs = Date.now() - reloadStart;
    record("cold graph (full reload)", reloadMs, "ms", 1500);
    const reloadMarks = await marksAndResources(reloadPage);
    console.log("cold graph marks/resources:", JSON.stringify(reloadMarks));
  } finally {
    await reloadContext.close();
  }

  // Measure service-worker install in a separate fresh context that allows
  // workers, from the first document mark rather than from a ready promise
  // that may already be resolved.
  const swContext = await browser.newContext({ viewport: { width: 1440, height: 950 }, storageState });
  const swPage = await swContext.newPage();
  let sw = null;
  try {
    await swPage.addInitScript(() => {
      window.__ezaSwStart = performance.now();
    });
    await swPage.goto(BASE + "/", { waitUntil: "domcontentloaded" });
    await waitForRow(swPage);
    sw = await swPage.evaluate(async () => {
      if (!("serviceWorker" in navigator)) return null;
      const ready = await Promise.race([
        navigator.serviceWorker.ready,
        new Promise((resolve) => setTimeout(() => resolve(null), 8000)),
      ]);
      const started = typeof window.__ezaSwStart === "number" ? window.__ezaSwStart : performance.now();
      return {
        ms: Math.round((performance.now() - started) * 10) / 10,
        active: Boolean(ready && ready.active),
        controller: Boolean(navigator.serviceWorker.controller),
      };
    });
  } finally {
    await swContext.close();
  }
  console.log("service worker:", JSON.stringify(sw));
  if (sw && sw.active) record("service worker ready after navigation", sw.ms, "ms", null);

  const wasm = (coldMarks.resources || []).find((entry) => entry.name.endsWith("/app.wasm"));
  if (wasm) record("app.wasm transfer (hard ceiling)", wasm.transferSize, "bytes", 2200000);
  const boot = (coldMarks.resources || []).find((entry) => entry.name === "/api/v1/boot");
  if (boot) record("boot response transfer", boot.transferSize, "bytes", null);

  console.log("");
  console.log(JSON.stringify({ results, serviceWorker: sw, consoleErrors: errors }, null, 2));
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
  await cold.close();
  await browser.close();
}
