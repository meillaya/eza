// UI smoke test: boot, search box, ledger rows, and record navigation.
//
// Run from the repo root in the dev shell, against a scratch server:
//   EZA_BASE=http://localhost:8100 node tests/e2e/ui-smoke.mjs
import { BASE, SEL, launchBrowser, launchPage, enterLibrary } from "./lib/dom.mjs";

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser, { viewport: { width: 1360, height: 900 } });

try {
  await enterLibrary(page);
  await page.waitForSelector(SEL.row, { timeout: 30000 }).catch(() => {});
  await page.waitForTimeout(600);

  const bootSplash = await page.locator("#boot-splash").isVisible().catch(() => false);
  const hasSearch = await page.locator(SEL.search).count();
  const rowCount = await page.locator(SEL.row).count();
  const bodyText = (await page.locator("body").innerText()).slice(0, 500);
  console.log("url:", page.url(), "splash:", bootSplash, "search:", hasSearch, "rows:", rowCount);
  console.log("body:", bodyText.replace(/\n+/g, " | ").slice(0, 400));
  console.log("console errors:", errors.slice(0, 8));

  await page.screenshot({ path: ".dsh-cache/ui-library.png", fullPage: false });

  // A row click opens the field drawer; the record page is its own route.
  if (rowCount > 0) {
    const firstRow = page.locator(SEL.row).first();
    const bookmarkId = await firstRow.getAttribute("data-bookmark-id");
    await firstRow.click();
    await page.waitForSelector(SEL.drawer, { timeout: 20000 });
    console.log("drawer cursor:", await firstRow.getAttribute("aria-current"));
    await page.screenshot({ path: ".dsh-cache/ui-drawer.png", fullPage: false });
    await page.goto(BASE + "/bookmark/" + bookmarkId, { waitUntil: "domcontentloaded" });
    await page.waitForSelector(SEL.record, { timeout: 20000 });
    console.log("detail url:", page.url());
    await page.screenshot({ path: ".dsh-cache/ui-detail.png", fullPage: false });
  }

  if (errors.length) process.exitCode = 1;
} finally {
  await browser.close();
}
