// UI smoke test: boot, one main landmark, search box, ledger rows, record
// navigation, and a failed delete that must keep the record on screen.
//
// Run from the repo root in the dev shell, against a scratch server:
//   EZA_BASE=http://localhost:8100 node tests/e2e/ui-smoke.mjs
import { BASE, SEL, launchBrowser, launchPage, enterLibrary } from "./lib/dom.mjs";

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser, { viewport: { width: 1360, height: 900 } });
let failures = 0;

function check(name, ok, detail = "") {
  console.log((ok ? "PASS " : "FAIL ") + name + (detail ? " - " + detail : ""));
  if (!ok) failures += 1;
}

async function mainCount() {
  return page.evaluate(() => document.querySelectorAll("main").length);
}

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

  // ------------------------------------------------------- main landmark ---
  check("the ledger has one main landmark", (await mainCount()) === 1, "main=" + (await mainCount()));
  await page.goto(BASE + "/inbox", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });
  await page.waitForTimeout(800);
  check("the inbox has one main landmark", (await mainCount()) === 1, "main=" + (await mainCount()));
  await page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.row, { timeout: 30000 }).catch(() => {});
  await page.waitForTimeout(600);

  // ------------------------------------------------ source facet search ---
  const sourceLink = page.locator(".facets .facet a").first();
  if (await sourceLink.count()) {
    const sourceDomain = (await sourceLink.locator(".name").innerText()).trim();
    await sourceLink.click();
    await page.waitForTimeout(1400);
    const queryAfterSource = await page.locator(SEL.search).inputValue();
    const sourceRows = await page.locator(SEL.row).count();
    const emptyShown = (await page.locator(".empty-title").count()) > 0;
    check(
      "a source facet writes its domain into the search query",
      queryAfterSource.includes(sourceDomain),
      "q=" + queryAfterSource + " source=" + sourceDomain
    );
    check("a source facet returns that source's records", sourceRows > 0 && !emptyShown, "rows=" + sourceRows);
    await page.fill(SEL.search, "");
    await page.waitForTimeout(1400);
  }

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
    check("the record has one main landmark", (await mainCount()) === 1, "main=" + (await mainCount()));
    await page.screenshot({ path: ".dsh-cache/ui-detail.png", fullPage: false });

    // ------------------------------------------ failed delete keeps record ---
    // A failed DELETE used to leave the page on the "record unavailable" state
    // even though the record still existed on the server.
    let deleteRequests = 0;
    await page.route("**/api/v1/bookmarks/" + bookmarkId, async (route) => {
      if (route.request().method() !== "DELETE") {
        await route.continue();
        return;
      }
      deleteRequests += 1;
      await route.fulfill({
        status: 500,
        contentType: "application/json",
        body: JSON.stringify({ error: { code: "internal", message: "forced delete failure" } }),
      });
    });
    await page.getByRole("button", { name: "delete", exact: true }).click();
    await page.waitForSelector('[data-testid="dialog-delete"]', { timeout: 20000 });
    await page.locator('[data-testid="dialog-confirm"]').click();
    await page.waitForTimeout(1500);
    const stillOnRecord = (await page.locator(SEL.record).count()) === 1;
    const toastText = ((await page.locator(SEL.toast).allInnerTexts().catch(() => [])) || []).join(" ");
    const stillThere = await page.evaluate(async (id) => {
      const response = await fetch("/api/v1/bookmarks/" + id, { credentials: "same-origin" });
      return response.status;
    }, bookmarkId);
    check("the failed delete is requested", deleteRequests === 1, "requests=" + deleteRequests);
    check("a failed delete keeps the record on screen", stillOnRecord, "records=" + (await page.locator(SEL.record).count()));
    check("a failed delete surfaces the server message", /forced delete failure/.test(toastText), toastText.slice(0, 120));
    check("the record still exists on the server", stillThere === 200, "status=" + stillThere);
    await page.unroute("**/api/v1/bookmarks/" + bookmarkId);
  }

  const unexpected = errors.filter((entry) => !/status of 500/.test(entry));
  check("no unexpected console errors", unexpected.length === 0, unexpected.slice(0, 3).join(" | ").slice(0, 300));
  if (failures) process.exitCode = 1;
} finally {
  await browser.close();
}
