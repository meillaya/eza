// Keyboard, boot reuse, and virtualized-ledger smoke test.
//
// Covers the JavaScript keyboard bridge (pwa.js -> "eza-key" -> Miso), the
// global shortcuts on every screen, the one-request first load through the
// boot payload, and the bounded DOM of the virtualized ledger.
//
// Run from the repo root in the dev shell, against a fresh scratch server:
//   EZA_BASE=http://localhost:8100 node tests/e2e/keyboard-smoke.mjs
import { BASE, SEL, launchBrowser, launchPage, enterLibrary, newChecker } from "./lib/dom.mjs";

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser, { viewport: { width: 1360, height: 900 } });
const { check, report } = newChecker();

// Count API traffic from the very first navigation: the first load must take
// its ledger from /boot and issue no separate /bookmarks list request.
const traffic = { boot: 0, bookmarks: 0 };
page.on("request", (request) => {
  let path = "";
  try {
    path = new URL(request.url()).pathname;
  } catch (_) {
    return;
  }
  if (path === "/api/v1/boot") traffic.boot += 1;
  if (path === "/api/v1/bookmarks") traffic.bookmarks += 1;
});

const sleep = (ms) => page.waitForTimeout(ms);

async function blurFocus() {
  await page.evaluate(() => {
    if (document.activeElement && typeof document.activeElement.blur === "function") {
      document.activeElement.blur();
    }
  });
  await sleep(80);
}

async function activeElementId() {
  return page.evaluate(() => (document.activeElement && document.activeElement.id) || "");
}

async function currentRowId() {
  return page.evaluate(() => {
    const row = document.querySelector('[data-testid="ledger-row"][aria-current="true"]');
    return row ? row.getAttribute("data-bookmark-id") : null;
  });
}

async function paletteOpen() {
  return page.locator(SEL.palette).isVisible().catch(() => false);
}

async function drawerOpen() {
  return page.locator(SEL.drawer).isVisible().catch(() => false);
}

function netscapeHtml(count) {
  const lines = [
    "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
    '<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">',
    "<TITLE>Bookmarks</TITLE>",
    "<H1>Bookmarks</H1>",
    "<DL><p>",
  ];
  for (let i = 0; i < count; i += 1) {
    lines.push(
      `    <DT><A HREF="https://bulk.example/${i}" ADD_DATE="${1700000000 + i}">Bulk keyboard fixture ${String(i).padStart(3, "0")}</A>`
    );
  }
  lines.push("</DL><p>");
  return lines.join("\n");
}

try {
  await enterLibrary(page);
  await page.waitForSelector(SEL.row, { timeout: 30000 });
  // Let the boot request settle before counting.
  await sleep(800);

  // ------------------------------------------------ boot payload reuse ----
  check("first load requests /api/v1/boot once", traffic.boot === 1, "boot=" + traffic.boot);
  check(
    "first load issues no separate ledger fetch",
    traffic.bookmarks === 0,
    "bookmarks=" + traffic.bookmarks
  );

  // ------------------------------------------------ seed a deep ledger -----
  const imported = await page.evaluate(async (html) => {
    const csrf =
      document.cookie
        .split("; ")
        .find((cookie) => cookie.startsWith("eza_csrf="))
        ?.split("=")[1] || "";
    const form = new FormData();
    form.append("file", new File([html], "bulk-keyboard.html", { type: "text/html" }));
    const response = await fetch("/api/v1/import", {
      method: "POST",
      body: form,
      headers: { Accept: "application/json", "X-CSRF-Token": csrf },
    });
    const text = await response.text();
    let body = null;
    try {
      body = JSON.parse(text);
    } catch (_) {
      body = text.slice(0, 200);
    }
    return { status: response.status, body };
  }, netscapeHtml(180));
  check("bulk fixture imported", imported.status === 200, "status " + imported.status);
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.row, { timeout: 30000 });
  await sleep(800);

  // ------------------------------------------------ virtualization --------
  const ledgerMetrics = () =>
    page.evaluate(() => {
      const ledger = document.querySelector(".ledger");
      return {
        scrollHeight: ledger ? ledger.scrollHeight : 0,
        rows: document.querySelectorAll('[data-testid="ledger-row"]').length,
      };
    });

  const firstWindow = await ledgerMetrics();
  check("ledger renders rows", firstWindow.rows > 0, "rows=" + firstWindow.rows);
  check(
    "first ledger window is bounded",
    firstWindow.rows <= 60,
    "rows=" + firstWindow.rows + " scrollHeight=" + firstWindow.scrollHeight
  );

  // Scroll to the end several times so loadMore appends pages; a virtualized
  // ledger keeps the DOM window bounded while the scroll height grows.
  for (let round = 0; round < 4; round += 1) {
    await page.evaluate(() => {
      const ledger = document.querySelector(".ledger");
      if (ledger) ledger.scrollTop = ledger.scrollHeight;
    });
    await sleep(700);
  }
  const deepWindow = await ledgerMetrics();
  check(
    "scrolling to the end loads more rows",
    deepWindow.scrollHeight > firstWindow.scrollHeight + 1500,
    "before=" + firstWindow.scrollHeight + " after=" + deepWindow.scrollHeight
  );
  check(
    "virtualized ledger keeps a bounded DOM",
    deepWindow.rows > 0 && deepWindow.rows <= 60,
    "rows=" + deepWindow.rows + " scrollHeight=" + deepWindow.scrollHeight
  );

  // ------------------------------------------------ j / k cursor ----------
  await blurFocus();
  await page.keyboard.press("j");
  await sleep(350);
  const firstId = await currentRowId();
  check("j opens the field drawer on the first row", firstId !== null && (await drawerOpen()));
  await page.keyboard.press("j");
  await sleep(350);
  const secondId = await currentRowId();
  check("j moves the ledger cursor down", secondId !== null && secondId !== firstId, String(secondId));
  await page.keyboard.press("k");
  await sleep(350);
  const backId = await currentRowId();
  check("k moves the ledger cursor back up", backId === firstId, String(backId));

  await page.keyboard.press("Escape");
  await sleep(300);
  check("Escape closes the drawer", !(await drawerOpen()));
  check("Escape leaves the palette closed", !(await paletteOpen()));

  // ------------------------------------------------ slash focuses search --
  await blurFocus();
  await page.keyboard.press("/");
  await sleep(400);
  check("/ focuses the search line outside inputs", (await activeElementId()) === "search-input");

  // ----------------------------------------- command mods in the search ----
  await page.keyboard.press("Control+k");
  await sleep(400);
  check("Ctrl+K opens the palette while the search line has focus", await paletteOpen());
  await page.keyboard.press("Escape");
  await sleep(300);
  check("Escape closes the palette", !(await paletteOpen()));

  // ------------------------------------------------ Shift+K on /dedup -----
  await page.click(SEL.section("dedup"));
  await page.waitForURL("**/dedup", { timeout: 15000 }).catch(() => {});
  await sleep(500);
  await blurFocus();
  await page.keyboard.press("Shift+K");
  await sleep(400);
  check("Shift+K opens the palette on /dedup", await paletteOpen());
  await page.keyboard.press("Escape");
  await sleep(300);

  // ------------------------------------------------ bare k off ledger -----
  await blurFocus();
  await page.keyboard.press("k");
  await sleep(400);
  check("bare k opens the palette off the ledger", await paletteOpen());
  await page.keyboard.press("Escape");
  await sleep(300);

  // ------------------------------------------------ Shift+K on /account ---
  await page.click(SEL.section("account"));
  await page.waitForURL("**/account", { timeout: 15000 }).catch(() => {});
  await sleep(500);
  await blurFocus();
  await page.keyboard.press("Shift+K");
  await sleep(400);
  check("Shift+K opens the palette on /account", await paletteOpen());
  await page.keyboard.press("Escape");
  await sleep(300);
  await blurFocus();
  await page.keyboard.press("k");
  await sleep(400);
  check("bare k opens the palette on /account", await paletteOpen());
  await page.keyboard.press("Escape");
  await sleep(300);

  // ------------------------------------------------ record page -----------
  await page.click(SEL.section("ledger"));
  await page.waitForSelector(SEL.row, { timeout: 20000 });
  await sleep(500);
  const recordId = await page.locator(SEL.row).first().getAttribute("data-bookmark-id");
  await page.goto(BASE + "/bookmark/" + recordId, { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.record, { timeout: 30000 });
  await sleep(500);

  await blurFocus();
  await page.keyboard.press("Shift+K");
  await sleep(400);
  check("Shift+K opens the palette on a record page", await paletteOpen());
  await page.keyboard.press("Escape");
  await sleep(300);

  // The palette hint in the search line is a real button, not a label.
  const paletteHint = page.locator('[data-testid="palette-open"]');
  check("the search line has a palette button", (await paletteHint.count()) === 1);
  await paletteHint.click();
  await sleep(300);
  check("the palette hint opens the palette", await paletteOpen());
  await page.keyboard.press("Escape");
  await sleep(300);

  // Ctrl+S saves the record note; the editor may hold focus.
  await page.click("#note-editor");
  await page.keyboard.type(" keyboard smoke note");
  await page.keyboard.press("Control+s");
  await page.waitForSelector(SEL.toast, { timeout: 15000 });
  const toastText = (await page.locator(SEL.toast).first().innerText()).toLowerCase();
  check("Ctrl+S saves the note on a record page", toastText.includes("saved"), toastText);
  check("Ctrl+S does not open the palette", !(await paletteOpen()));

  // Shift+K while the note has focus must type, not open the palette.
  await page.click("#note-editor");
  await page.keyboard.press("Shift+K");
  await sleep(250);
  check("Shift+K in the note editor keeps typing", !(await paletteOpen()));

  // ------------------------------------------------ console errors --------
  const parseErrors = errors.filter((error) => /parse error/i.test(error));
  check("no Miso parse errors in the console", parseErrors.length === 0, parseErrors.join(" | ").slice(0, 300));
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
