// Bulk selection UI smoke test: ledger selection, the floating action bar,
// add tags, mark unread, delete confirmation, select-all-matching, and the
// keyboard Space toggle.
//
// Production note: the Direction B ledger does not implement Shift-click
// range selection or an in-ledger undo button. Those two old steps are
// documented here as no longer mapping to a production feature; undo is
// exercised by undo-smoke and prune-undo-smoke through the API.
//
// Run from the repo root in the dev shell, against a scratch server:
//   EZA_BASE=http://localhost:8100 node tests/e2e/bulk-ui-smoke.mjs
import { BASE, SEL, launchBrowser, launchPage, enterLibrary, makeApi, newChecker } from "./lib/dom.mjs";

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser, { viewport: { width: 1440, height: 950 } });
const { check, report } = newChecker();
const api = makeApi(page);

const selectedText = async () => (await page.locator(SEL.selectionCount).textContent().catch(() => "")) || "";
const waitSelection = async (count) => {
  await page.waitForFunction(
    ({ selector, expected }) => {
      const element = document.querySelector(selector);
      return Boolean(element && element.textContent.includes(String(expected) + " selected"));
    },
    { selector: SEL.selectionCount, expected: count },
    { timeout: 20000 }
  );
};
const selectRow = async (id) => {
  await page.locator(SEL.rowById(id)).hover();
  await page.locator(SEL.rowSelectFor(id)).click();
};
const waitToast = async (pattern) => {
  await page
    .waitForFunction(
      (source) => [...document.querySelectorAll('[data-testid="toast"]')].some((toast) => new RegExp(source).test(toast.textContent)),
      pattern,
      { timeout: 20000 }
    )
    .catch(() => {});
};

try {
  await enterLibrary(page);
  await page.waitForSelector(SEL.row, { timeout: 30000 });
  await page.waitForTimeout(600);
  check("library loaded", (await page.locator(SEL.row).count()) > 0);

  // Known ids from the API; the ledger's default sort is filed, newest first.
  const page1 = await api("/api/v1/bookmarks?limit=5&offset=0");
  const ids = (page1.body?.items || []).map((item) => item.id);
  check("api returned ids", ids.length >= 3, JSON.stringify(ids));
  check("one select control per row", (await page.locator(SEL.rowSelect).count()) > 0);

  // The two ledger-foot selection actions must read as separate controls, not
  // run together as "select pageselect all matching".
  const footGap = await page.evaluate(() => {
    const buttons = Array.from(document.querySelectorAll(".ledg-foot-act"));
    const pageButton = buttons.find((button) => /^select page$/i.test(button.textContent.trim()));
    const allButton = buttons.find((button) => /^select all matching$/i.test(button.textContent.trim()));
    if (!pageButton || !allButton) return null;
    const pageRect = pageButton.getBoundingClientRect();
    const allRect = allButton.getBoundingClientRect();
    return Math.round(allRect.left - pageRect.right);
  });
  check("ledger foot selection actions are visually separated", footGap !== null && footGap >= 8, "gap=" + footGap);

  // The row selection control must be reachable on hover: it used to overflow
  // the accession column and render clipped off the left edge of the page
  // until a selection already existed.
  await page.locator(SEL.row).first().hover();
  await page.waitForTimeout(250);
  const tickBox = await page.locator(SEL.rowSelect).first().boundingBox();
  check(
    "row selection control is fully in frame on hover",
    tickBox !== null && tickBox.x >= 0 && tickBox.width >= 10 && tickBox.height >= 10,
    JSON.stringify(tickBox)
  );

  // Single selection.
  await selectRow(ids[0]);
  await waitSelection(1);
  check("bar appears after one selection", (await page.locator(SEL.selectionBar).count()) === 1);
  check("single selection count", (await selectedText()).includes("1 selected"));

  // Shift-click range selection is not part of the Direction B ledger.
  console.log("SKIP shift-click range: not implemented in the production ledger");

  // Add a tag to three rows.
  await selectRow(ids[1]);
  await selectRow(ids[2]);
  await waitSelection(3);
  check("three rows selected", (await selectedText()).includes("3 selected"));

  await page.getByRole("button", { name: /^add tag$/i }).click();
  await page.waitForSelector('[data-testid="dialog-bulk-tag"]', { timeout: 10000 });
  await page.waitForSelector(SEL.bulkTagInput, { timeout: 10000 });
  await page.fill(SEL.bulkTagInput, "bulk-smoke");
  await page.locator(SEL.dialogConfirm).click();
  await waitToast("Updated 3 bookmarks");
  const addToasts = await page.evaluate(() =>
    [...document.querySelectorAll('[data-testid="toast"]')].map((toast) => toast.textContent.trim())
  );
  check("add tag toast", addToasts.some((text) => /Updated 3 bookmarks/.test(text)), JSON.stringify(addToasts));
  check("selection cleared after bulk", (await page.locator(SEL.selectionBar).count()) === 0);

  const tagged = [];
  for (const id of ids.slice(0, 3)) {
    const detail = await api("/api/v1/bookmarks/" + id);
    tagged.push((detail.body?.tags || []).includes("bulk-smoke"));
  }
  check("all three bookmarks tagged", tagged.every(Boolean), JSON.stringify(tagged));

  // Mark unread on two bookmarks.
  await selectRow(ids[0]);
  await selectRow(ids[1]);
  await waitSelection(2);
  await page.getByRole("button", { name: /^mark unread$/i }).click();
  await page.waitForTimeout(1500);
  const reads = [];
  for (const id of ids.slice(0, 2)) {
    const detail = await api("/api/v1/bookmarks/" + id);
    reads.push(detail.body?.is_read);
  }
  check("mark unread applied", reads.every((wasRead) => wasRead === false), JSON.stringify(reads));

  // Delete with confirmation.
  const doomed = ids[3] ?? ids[2];
  await selectRow(doomed);
  await waitSelection(1);
  await page.getByRole("button", { name: /^delete$/i }).click();
  await page.waitForSelector('[data-testid="dialog-bulk-delete"]', { timeout: 10000 });
  const confirmText = await page.locator(SEL.dialogBody).first().innerText();
  check("delete asks for confirmation", /snapshot/i.test(confirmText), confirmText.replace(/\n+/g, " ").slice(0, 80));
  await page.locator(SEL.dialogConfirm).click();
  await page.waitForTimeout(1600);
  const deleted = await api("/api/v1/bookmarks/" + doomed);
  check("bookmark deleted", deleted.status === 404, "status " + deleted.status);

  // In-ledger undo is not part of the Direction B ledger; the API undo is
  // covered by undo-smoke and prune-undo-smoke.
  console.log("SKIP bulk undo button: not implemented in the production ledger");

  // Select all matching, then clear.
  await page.fill(SEL.search, "example");
  await page.waitForTimeout(1500);
  const matches = await api("/api/v1/bookmarks?q=example&limit=200&offset=0");
  const matchCount = matches.body?.total ?? 0;
  await page.getByRole("button", { name: /^select all matching$/i }).first().click();
  await page
    .waitForFunction(
      (selector) => {
        const element = document.querySelector(selector);
        return Boolean(element && /\d+ selected/.test(element.textContent));
      },
      SEL.selectionCount,
      { timeout: 30000 }
    )
    .catch(() => {});
  const allText = await selectedText();
  check(
    "select all matching selects the full result set",
    matchCount > 0 && allText.includes(String(matchCount) + " selected"),
    allText + " (api total " + matchCount + ")"
  );
  await page.getByRole("button", { name: /^clear$/i }).click();
  await page.waitForTimeout(400);
  check("clear hides the bar", (await page.locator(SEL.selectionBar).count()) === 0);

  // The bulk bar keeps the select controls reachable after a first pick: a
  // user who has started selecting must still be able to extend to all
  // matching records without clearing and starting over.
  await page.locator(SEL.row).first().hover();
  await page.locator(SEL.rowSelect).first().click();
  await waitSelection(1);
  const bulkSelectPage = page.locator(SEL.selectionBar).getByRole("button", { name: /^select page$/i });
  const bulkSelectAll = page.locator(SEL.selectionBar).getByRole("button", { name: /^select all matching$/i });
  check("bulk bar offers select page", (await bulkSelectPage.count()) === 1, "buttons=" + (await bulkSelectPage.count()));
  check("bulk bar offers select all matching", (await bulkSelectAll.count()) === 1, "buttons=" + (await bulkSelectAll.count()));
  await bulkSelectAll.click();
  await page
    .waitForFunction(
      ({ selector, expected }) => {
        const element = document.querySelector(selector);
        return Boolean(element && element.textContent.includes(String(expected) + " selected"));
      },
      { selector: SEL.selectionCount, expected: matchCount },
      { timeout: 30000 }
    )
    .catch(() => {});
  const bulkAllText = await selectedText();
  check(
    "bulk bar select all matching selects the full result set",
    matchCount > 0 && bulkAllText.includes(String(matchCount) + " selected"),
    bulkAllText + " (api total " + matchCount + ")"
  );
  await page.getByRole("button", { name: /^clear$/i }).click();
  await page.waitForTimeout(400);

  // Keyboard: focus a row select control and toggle it with Space.
  await page.fill(SEL.search, "");
  await page.waitForTimeout(1400);
  await page.locator(SEL.row).first().hover();
  await page.locator(SEL.rowSelect).first().focus();
  await page.keyboard.press("Space");
  await page.waitForTimeout(400);
  check("keyboard space toggles selection", (await page.locator(SEL.selectionBar).count()) === 1);
  await page.getByRole("button", { name: /^clear$/i }).click();
  await page.waitForTimeout(300);
  check("clear after keyboard selection", (await page.locator(SEL.selectionBar).count()) === 0);

  // The open field card must not cover the bulk bar: its actions used to run
  // under the 320px drawer, leaving "clear" unreachable.
  await page.locator(SEL.row).first().hover();
  await page.locator(SEL.rowSelect).first().click();
  await waitSelection(1);
  await page.locator(SEL.row).first().locator(".c-src").click();
  await page.waitForSelector(SEL.drawer, { timeout: 10000 });
  await page.waitForTimeout(400);
  const drawerClearance = await page.evaluate(() => {
    const drawer = document.querySelector('[data-testid="drawer"]');
    const acts = [...document.querySelectorAll('[data-testid="selection-bar"] .ledg-act')];
    if (!drawer || acts.length === 0) return null;
    const drawerLeft = drawer.getBoundingClientRect().left;
    return Math.max(...acts.map((act) => Math.round(act.getBoundingClientRect().right - drawerLeft)));
  });
  check(
    "bulk bar actions stay clear of the open drawer",
    drawerClearance !== null && drawerClearance <= 0,
    "max action-to-drawer overlap=" + drawerClearance
  );
  await page.getByRole("button", { name: /^clear$/i }).click();
  await page.waitForTimeout(500);
  check("clear works while the drawer is open", (await page.locator(SEL.selectionBar).count()) === 0);
  // With the selection gone the ledger foot is back, and it must be clear of
  // the still-open drawer too.
  const footClearance = await page.evaluate(() => {
    const drawer = document.querySelector('[data-testid="drawer"]');
    const acts = [...document.querySelectorAll('.ledger-foot .ledg-foot-act')];
    if (!drawer || acts.length === 0) return null;
    const drawerLeft = drawer.getBoundingClientRect().left;
    return Math.max(...acts.map((act) => Math.round(act.getBoundingClientRect().right - drawerLeft)));
  });
  check("ledger foot actions stay clear of the open drawer", footClearance !== null && footClearance <= 0, "max overlap=" + footClearance);
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
