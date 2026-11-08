// Ledger navigation smoke test.
//
// The ledger is a virtual window: it renders a slice of the loaded rows at an
// offset computed from the model's scroll position. The browser mounts a fresh
// .ledger at scrollTop 0 when a route is entered, so the model offset has to be
// reset too. This test scrolls the ledger, opens a record, waits, comes back
// and checks the rows are visible before any scroll event arrives.
import { SEL, launchBrowser, launchPage, enterLibrary, newChecker } from "./lib/dom.mjs";

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser, { viewport: { width: 1360, height: 900 } });
const { check, report } = newChecker();
const sleep = (ms) => page.waitForTimeout(ms);

function netscapeHtml(count) {
  const lines = [
    "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
    "<TITLE>Bookmarks</TITLE>",
    "<H1>Bookmarks</H1>",
    "<DL><p>",
  ];
  for (let i = 0; i < count; i += 1) {
    lines.push(
      `    <DT><A HREF="https://nav.example/${i}" ADD_DATE="${1700000000 + i}">Navigation fixture ${String(i).padStart(3, "0")}</A>`
    );
  }
  lines.push("</DL><p>");
  return lines.join("\n");
}

const ledgerState = () =>
  page.evaluate(() => {
    const ledger = document.querySelector(".ledger");
    const rows = [...document.querySelectorAll('[data-testid="ledger-row"]')];
    const box = ledger ? ledger.getBoundingClientRect() : null;
    const visible = box
      ? rows.filter((row) => {
          const r = row.getBoundingClientRect();
          return r.bottom > box.top && r.top < box.bottom;
        }).length
      : 0;
    return {
      top: ledger ? Math.round(ledger.scrollTop) : null,
      height: ledger ? ledger.scrollHeight : null,
      rows: rows.length,
      visible,
      firstRowTop: rows.length ? Math.round(rows[0].getBoundingClientRect().top) : null,
      spacers: [...document.querySelectorAll(".ledger-vspace")].map((el) => Math.round(el.getBoundingClientRect().height)),
    };
  });

try {
  await enterLibrary(page);
  await page.waitForSelector(SEL.row, { timeout: 30000 });
  await sleep(800);

  // Seed a ledger long enough to scroll, then reload so the app boots on it.
  const imported = await page.evaluate(async (html) => {
    const csrf =
      document.cookie
        .split("; ")
        .find((cookie) => cookie.startsWith("eza_csrf="))
        ?.split("=")[1] || "";
    const form = new FormData();
    form.append("file", new File([html], "navigation.html", { type: "text/html" }));
    const response = await fetch("/api/v1/import", {
      method: "POST",
      body: form,
      headers: { Accept: "application/json", "X-CSRF-Token": csrf },
    });
    return response.status;
  }, netscapeHtml(200));
  check("bulk fixture imported", imported === 200, "status " + imported);
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.row, { timeout: 30000 });
  await sleep(900);

  // Leave the list at a deep position: the model's mScrollY is now non-zero.
  await page.evaluate(() => {
    const ledger = document.querySelector(".ledger");
    if (ledger) ledger.scrollTop = 1600;
  });
  await sleep(600);
  const scrolled = await ledgerState();
  check("the ledger scrolled before opening a record", scrolled.top > 500, "top " + scrolled.top);

  await page.locator('[data-testid="ledger-row"] .ledg-acc').first().click();
  await page.waitForSelector(".detail-back", { timeout: 20000 });
  await sleep(1500); // what the report described as "wait a couple of seconds"
  await page.locator(".detail-back").first().click();
  await page.waitForSelector(SEL.row, { timeout: 20000 });
  await sleep(1000);

  const returned = await ledgerState();
  check("returning to the ledger starts at the top", returned.top === 0, "top " + returned.top);
  check("the virtual window reset with the container", (returned.spacers[0] || 0) < 200, "spacers " + JSON.stringify(returned.spacers));
  check("rows are visible before any scroll", returned.visible > 0, "visible " + returned.visible + " of " + returned.rows);
  check("the first row is inside the viewport", returned.firstRowTop !== null && returned.firstRowTop < 900, "first row top " + returned.firstRowTop);

  // A wheel gesture still behaves.
  await page.mouse.move(700, 500);
  await page.mouse.wheel(0, 600);
  await sleep(500);
  const afterWheel = await ledgerState();
  check("the ledger still scrolls after the reset", afterWheel.top > 0, "top " + afterWheel.top);

  const parseErrors = errors.filter((error) => /parse error/i.test(error));
  check("no Miso parse errors in the console", parseErrors.length === 0, parseErrors.join(" | ").slice(0, 300));
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
