// Ledger navigation smoke test.
//
// The ledger is a virtual window: it renders a slice of the loaded rows at an
// offset computed from the model's scroll position. Opening a record unmounts
// the scroller, so returning has to (a) never paint blank rows and (b) restore
// the previous offset once enough pages are loaded again. This seeds a deep
// ledger, leaves it at 4000px, opens a record, waits, comes back and checks the
// rows are visible and the offset is restored.
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
      client: ledger ? ledger.clientHeight : null,
      rows: rows.length,
      visible,
      spacers: [...document.querySelectorAll(".ledger-vspace")].map((el) => Math.round(el.getBoundingClientRect().height)),
    };
  });

async function loadPages(count) {
  for (let i = 0; i < count; i += 1) {
    await page.evaluate(() => {
      const ledger = document.querySelector(".ledger");
      if (ledger) ledger.scrollTop = ledger.scrollHeight;
    });
    await sleep(500);
  }
}

try {
  await enterLibrary(page);
  await page.waitForSelector(SEL.row, { timeout: 30000 });
  await sleep(800);

  // Seed a ledger long enough to restore a deep offset, then reload so the app
  // boots on it.
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
  }, netscapeHtml(400));
  check("bulk fixture imported", imported === 200, "status " + imported);
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.row, { timeout: 30000 });
  await sleep(900);
  await loadPages(4);

  // Leave the list at a deep offset. Clicking through the DOM avoids the
  // browser scrolling the target row into view before navigation.
  await page.evaluate(() => {
    const ledger = document.querySelector(".ledger");
    if (ledger) ledger.scrollTop = 4000;
  });
  await sleep(600);
  const clicked = await page.evaluate(() => {
    const ledger = document.querySelector(".ledger");
    const box = ledger.getBoundingClientRect();
    const row = [...document.querySelectorAll('[data-testid="ledger-row"]')].find((candidate) => {
      const r = candidate.getBoundingClientRect();
      return r.top > box.top + 120 && r.bottom < box.bottom - 60;
    });
    if (!row) return null;
    const top = Math.round(ledger.scrollTop);
    const acc = row.querySelector(".ledg-acc");
    if (!acc) return null;
    acc.click();
    return { id: row.getAttribute("data-bookmark-id"), top };
  });
  check("opened a record from a deep ledger position", clicked !== null, "clicked " + JSON.stringify(clicked));
  const savedTop = clicked ? clicked.top : 0;
  check("the ledger was deep before opening", savedTop >= 3500, "top " + savedTop);

  await page.waitForSelector(".detail-back", { timeout: 20000 });
  await sleep(1500); // the reported "wait a couple of seconds"
  await page.locator(".detail-back").first().click();
  await page.waitForSelector(SEL.row, { timeout: 20000 });

  // The restore loads pages until the old offset is reachable.
  let returned = await ledgerState();
  for (let i = 0; i < 40; i += 1) {
    if (returned.top !== null && Math.abs(returned.top - savedTop) <= 4 && returned.visible > 0) break;
    await sleep(200);
    returned = await ledgerState();
  }
  check("rows are visible before any scroll", returned.visible > 0, "visible " + returned.visible + " of " + returned.rows);
  check("the previous scroll position is restored", Math.abs(returned.top - savedTop) <= 4, "top " + returned.top + " expected " + savedTop);
  const topSpacer = returned.spacers[0] || 0;
  check(
    "the window offset matches the restored position",
    topSpacer <= savedTop + 50 && topSpacer >= savedTop - 600,
    "spacer " + topSpacer + " for top " + returned.top
  );

  // A wheel gesture still behaves.
  const beforeWheel = returned.top === null ? 0 : returned.top;
  await page.mouse.move(700, 500);
  await page.mouse.wheel(0, 300);
  await sleep(500);
  const afterWheel = await ledgerState();
  check("the ledger still scrolls after the restore", afterWheel.top > beforeWheel, "top " + afterWheel.top);

  const parseErrors = errors.filter((error) => /parse error/i.test(error));
  check("no Miso parse errors in the console", parseErrors.length === 0, parseErrors.join(" | ").slice(0, 300));
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
