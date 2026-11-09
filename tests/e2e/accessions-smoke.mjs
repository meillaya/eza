// Accessions smoke test: the printed index opens the ledger filtered to the
// year, filing day and source it prints.
//
// The mini fixture (tests/fixtures/mini-bookmarks.html) holds three records,
// all filed on 2023-11-14 UTC from example.com, so every figure on the page is
// 3 and every click can be checked against its own printed count.
//
// Run from the repo root in the dev shell, against a scratch server seeded
// with the mini fixture:
//   EZA_BASE=http://localhost:8100 node tests/e2e/accessions-smoke.mjs
import { BASE, SEL, launchBrowser, launchPage, enterLibrary, newChecker } from "./lib/dom.mjs";

const YEAR = "2023";
const DAY = "2023-11-14";
const DAY_STAMP = "2023.11.14";
const SOURCE = "example.com";
const TOTAL = "3";

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser, { viewport: { width: 1360, height: 900 } });
const { check, report } = newChecker();
// The page can be reached from any list route through the section link, which
// also exercises the client navigation instead of a full reload.
async function openAccessions() {
  if ((await page.locator(SEL.accessions).count()) === 0) {
    await page.click('[data-testid="section-accessions"]');
  }
  await page.waitForSelector('[data-testid="accessions-year"]', { timeout: 20000 });
}

async function onLedger() {
  await page.waitForURL((url) => new URL(url).pathname === "/", { timeout: 15000 });
  await page.waitForSelector(SEL.search, { timeout: 15000 });
}

async function waitForTotal(expected) {
  await page.waitForFunction(
    (total) => {
      const node = document.querySelector('[data-testid="result-count-live"] .result-count');
      return node && node.textContent.trim() === total;
    },
    expected,
    { timeout: 20000 }
  );
}

async function total() {
  return (await page.locator('[data-testid="result-count-live"] .result-count').innerText()).trim();
}

async function query() {
  return (await page.locator(SEL.search).inputValue()).trim();
}

// The chip row is a sequence of buttons; flatten it so the operator and its
// value read as one token regardless of the span split in the DOM.
async function chips() {
  const chips = page.locator(".chips .chip");
  const count = await chips.count();
  const parts = [];
  for (let i = 0; i < count; i += 1) {
    parts.push((await chips.nth(i).innerText()).replace(/\s+/g, ""));
  }
  return parts.join("|");
}

async function rowCount() {
  return page.locator(SEL.row).count();
}

function figureFor(selector, className) {
  return page.evaluate(
    ({ selector, className }) => {
      const button = document.querySelector(selector);
      const row = button && (button.closest("li") || button.closest(".mc-row"));
      const node = row && row.querySelector("." + className);
      return node ? node.textContent.trim() : "";
    },
    { selector, className }
  );
}

try {
  await enterLibrary(page);
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });

  // --------------------------------------------------------- year label ---
  await openAccessions();
  const year = page.locator(`[data-testid="accessions-year"][data-year="${YEAR}"]`);
  check("the year label is a button with data-year", (await year.count()) === 1);
  check("the year label names its count", ((await year.getAttribute("aria-label")) || "").includes("3 entries"));
  const yearFigure = await figureFor(`[data-testid="accessions-year"][data-year="${YEAR}"]`, "mc-n");
  check("the year row prints the same figure", yearFigure === TOTAL, yearFigure);

  await year.click();
  await onLedger();
  await waitForTotal(TOTAL);
  check("the year click opens /", new URL(page.url()).pathname === "/");
  check("the year click sets a year query", (await query()) === "year:" + YEAR, await query());
  check("the year click shows a year chip", (await chips()).includes("year:" + YEAR), await chips());
  check("the year click total matches the printed year figure", (await total()) === yearFigure, await total());
  check("the year click lists the year's records", (await rowCount()) === 3, String(await rowCount()));

  // ------------------------------------------------------------ day mark ---
  await openAccessions();
  await page.waitForSelector('[data-testid="accessions-day"]', { timeout: 20000 });
  const mark = page.locator(`[data-testid="accessions-day"][data-day="${DAY}"]`);
  check("the filing day is a mark button with data-day", (await mark.count()) === 1);
  check("the mark is pointer only", (await mark.getAttribute("tabindex")) === "-1");
  const markTitle = (await mark.getAttribute("title")) || "";
  check("the mark title shows the day and the count", markTitle.includes(DAY_STAMP) && markTitle.includes("3 entries"), markTitle);
  check("the mark carries the same tip for the page", ((await mark.getAttribute("data-tip")) || "") === markTitle);
  check("the mark names its count", ((await mark.getAttribute("aria-label")) || "").includes("3 entries"));

  await mark.click();
  await onLedger();
  await waitForTotal(TOTAL);
  check("the day click sets a day query", (await query()) === "day:" + DAY, await query());
  check("the day click shows a day chip", (await chips()).includes("day:" + DAY), await chips());
  check("the day click total is the mark count", (await total()) === TOTAL, await total());
  check("the day click lists the day's records", (await rowCount()) === 3, String(await rowCount()));

  // -------------------------------------------------------- source row ----
  await openAccessions();
  const source = page.locator(`[data-testid="accessions-source"][data-source="${SOURCE}"]`);
  check("the ranked source is a row button with data-source", (await source.count()) === 1);
  check("the source row names its count", ((await source.getAttribute("aria-label")) || "").includes("3 entries"));
  const sourceFigure = await figureFor(`[data-testid="accessions-source"][data-source="${SOURCE}"]`, "rank-n");
  check("the source row prints the same figure", sourceFigure === TOTAL, sourceFigure);

  await source.click();
  await onLedger();
  await waitForTotal(TOTAL);
  check("the source click queries the plain domain", (await query()) === SOURCE, await query());
  check("the source click total matches the printed source figure", (await total()) === sourceFigure, await total());
  check("the source click lists the source's records", (await rowCount()) === 3, String(await rowCount()));

  // ------------------------------------------------------- busiest day ----
  await openAccessions();
  const busiest = page.locator(`[data-testid="accessions-busiest"][data-day="${DAY}"]`);
  check("the busiest day row is a button with data-day", (await busiest.count()) === 1);
  check("the busiest row names its count", ((await busiest.getAttribute("aria-label")) || "").includes("3 entries"));
  const busiestFigure = await figureFor(`[data-testid="accessions-busiest"][data-day="${DAY}"]`, "mono");
  check("the busiest row prints the same figure", busiestFigure === TOTAL, busiestFigure);

  await busiest.click();
  await onLedger();
  await waitForTotal(TOTAL);
  check("the busiest click queries that day", (await query()) === "day:" + DAY, await query());
  check("the busiest click total matches the printed day figure", (await total()) === busiestFigure, await total());

  // ------------------------------------------------------- keyboard use ---
  await openAccessions();
  const focusableYear = page.locator(`[data-testid="accessions-year"][data-year="${YEAR}"]`);
  await focusableYear.focus();
  check("the year label takes keyboard focus", await focusableYear.evaluate((node) => node === document.activeElement));
  await page.keyboard.press("Enter");
  await onLedger();
  await waitForTotal(TOTAL);
  check("Enter on the year label opens the filtered ledger", (await query()) === "year:" + YEAR, await query());
  check("the keyboard total matches the printed year figure", (await total()) === TOTAL, await total());

  // ------------------------------------------------------------ mobile ---
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(BASE + "/accessions", { waitUntil: "domcontentloaded" });
  await page.waitForSelector('[data-testid="accessions-year"]', { timeout: 30000 });
  await page.waitForFunction(() => document.querySelectorAll('[data-testid="accessions-day"]').length === 0, null, {
    timeout: 20000,
  });
  check("under 768px the day marks are not buttons", (await page.locator(".mc-track button").count()) === 0);
  check("under 768px the marks are decorative", (await page.locator(".mc-track i").count()) > 0);
  const targets = [
    ["year label", '[data-testid="accessions-year"]'],
    ["source row", '[data-testid="accessions-source"]'],
    ["busiest row", '[data-testid="accessions-busiest"]'],
  ];
  for (const [label, selector] of targets) {
    const box = await page.locator(selector).first().boundingBox();
    check("under 768px the " + label + " is a 44px target", Boolean(box) && box.height >= 44, JSON.stringify(box));
  }

  // ------------------------------------------------------ console noise ---
  check("no console errors", errors.length === 0, errors.slice(0, 3).join(" | ").slice(0, 400));
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
