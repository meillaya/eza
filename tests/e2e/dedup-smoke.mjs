// Duplicates page smoke test.
//
// The page has to show exact whole-library counts, page the two sections
// independently, bound what it renders, and merge only after an explicit
// confirmation. The fixture is inserted straight into the scratch server's
// SQLite file before the first navigation, because the save and import paths
// de-duplicate now: URL-variant rows can no longer be created through the API.
//
// Run from the repo root in the dev shell (scripts/e2e.sh seeds the database
// path for us). For a manual run set EZA_DEDUP_DB to the scratch eza.db:
//   EZA_BASE=http://localhost:8100 EZA_DEDUP_DB=/tmp/eza/eza.db node tests/e2e/dedup-smoke.mjs
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";

import { SEL, launchBrowser, launchPage, enterLibrary, makeApi, newChecker } from "./lib/dom.mjs";

const URL_GROUPS = 61;
const TITLE_GROUPS = 45;

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser, { viewport: { width: 1360, height: 900 } });
const { check, report } = newChecker();
const api = makeApi(page);

const sleep = (ms) => page.waitForTimeout(ms);

async function waitForCount(locator, expected, timeout = 15000) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    const count = await locator.count();
    if (count === expected) return count;
    await sleep(120);
  }
  return locator.count();
}

function buildSeedSql() {
  const rows = [];
  let stamp = 1700000100;
  for (let i = 0; i < URL_GROUPS; i += 1) {
    const domain = `d-${i}.example`;
    rows.push(
      `('http://www.${domain}/page/','URL duplicate fixture ${i}','${domain}',${stamp},${stamp},${stamp})`
    );
    rows.push(
      `('https://${domain}/page','URL duplicate fixture ${i}','${domain}',${stamp + 1},${stamp + 1},${stamp + 1})`
    );
    stamp += 10;
  }
  for (let i = 0; i < TITLE_GROUPS; i += 1) {
    const domain = `t-${i}.example`;
    rows.push(
      `('https://${domain}/one','Shared fixture title ${i}','${domain}',${stamp},${stamp},${stamp})`
    );
    rows.push(
      `('https://${domain}/two','Shared fixture title ${i}','${domain}',${stamp + 1},${stamp + 1},${stamp + 1})`
    );
    stamp += 10;
  }
  return [
    "BEGIN;",
    "INSERT INTO bookmarks (url,title,domain,created_at,added_at,updated_at) VALUES",
    rows.join(",\n") + ";",
    "COMMIT;",
  ].join("\n");
}

function seedDuplicates() {
  const explicit = process.env.EZA_DEDUP_DB;
  const candidates = [
    explicit,
    path.resolve(".dsh-cache/e2e-run/dedup-smoke/eza.db"),
  ].filter(Boolean);
  const db = candidates.find((candidate) => existsSync(candidate));
  if (!db) {
    return {
      ok: false,
      reason:
        "no scratch database found (looked for .dsh-cache/e2e-run/dedup-smoke/eza.db); set EZA_DEDUP_DB for a manual run",
    };
  }
  const sql = buildSeedSql();
  let lastError = "";
  for (let attempt = 0; attempt < 6; attempt += 1) {
    try {
      execFileSync("sqlite3", [db], { input: sql, stdio: ["pipe", "pipe", "pipe"] });
      return { ok: true, db };
    } catch (error) {
      lastError = String((error && error.message) || error);
      const until = Date.now() + 250;
      while (Date.now() < until) {
        /* wait for the server's WAL write to finish */
      }
    }
  }
  return { ok: false, reason: lastError };
}

try {
  const seeded = seedDuplicates();
  check("duplicate fixture inserted into the scratch database", seeded.ok, seeded.reason || seeded.db);
  if (!seeded.ok) throw new Error("dedup fixture missing: " + seeded.reason);

  await enterLibrary(page);
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });
  await sleep(600);

  // The server's own report is the source of truth for counts and ids.
  const candidates = await api("/api/v1/dedup/candidates?url_limit=200&title_limit=200");
  check("duplicate candidates endpoint answers", candidates.status === 200, "status " + candidates.status);
  const counts = candidates.body?.counts || {};
  const urlGroups = candidates.body?.url_groups || [];
  const titleGroups = candidates.body?.title_groups || [];
  console.log("counts:", JSON.stringify(counts), "url groups:", urlGroups.length, "title groups:", titleGroups.length);
  check("seeded same-URL groups are detected", counts.url_groups === URL_GROUPS, "url_groups " + counts.url_groups);
  check(
    "seeded title groups are detected",
    Number.isInteger(counts.title_groups) && counts.title_groups >= TITLE_GROUPS,
    "title_groups " + counts.title_groups
  );
  check("same-URL records are counted exactly", counts.url_records === URL_GROUPS * 2, "url_records " + counts.url_records);
  check(
    "title records are counted exactly",
    Number.isInteger(counts.title_records) && counts.title_records >= TITLE_GROUPS * 2,
    "title_records " + counts.title_records
  );

  const firstUrlGroup = urlGroups[0];
  const firstTitleGroup = titleGroups[0];
  check("candidate groups carry summaries", (firstUrlGroup?.items?.length || 0) >= 2, "first url group items");
  check("title groups are labelled advisory", firstTitleGroup?.kind === "title", String(firstTitleGroup?.kind));

  // ------------------------------------------------ the page -----------------
  await page.click(SEL.section("dedup"));
  await page.waitForURL("**/dedup", { timeout: 15000 }).catch(() => {});
  await page.waitForSelector('[data-testid="dedup-url-section"]', { timeout: 30000 });
  await sleep(600);

  const urlGroupNodes = page.locator('[data-testid="dedup-url-groups"] [data-testid="dedup-group"]');
  const titleGroupNodes = page.locator('[data-testid="dedup-title-groups"] [data-testid="dedup-group"]');
  const urlSectionText = (await page.locator('[data-testid="dedup-url-section"]').innerText()).toLowerCase();
  const titleSectionText = (await page.locator('[data-testid="dedup-title-section"]').innerText()).toLowerCase();

  check("URL section shows the exact library count", urlSectionText.includes(String(counts.url_groups)), urlSectionText.slice(0, 180));
  check("URL section shows the exact record count", urlSectionText.includes(String(counts.url_records)), urlSectionText.slice(0, 180));
  check("title section is a review list", titleSectionText.includes("review only"), titleSectionText.slice(0, 180));
  check("title section shows its exact count", titleSectionText.includes(String(counts.title_groups)), titleSectionText.slice(0, 180));
  check("first URL page renders 60 groups", (await urlGroupNodes.count()) === 60, "groups " + (await urlGroupNodes.count()));
  check("first title page renders 40 groups", (await titleGroupNodes.count()) === 40, "groups " + (await titleGroupNodes.count()));
  check("the page does not render every candidate group at once", (await urlGroupNodes.count()) < URL_GROUPS, "url groups in DOM");

  const mergeAllButton = page.locator('[data-testid="dedup-merge-all"]');
  const mergeAllLabel = (await mergeAllButton.innerText()).toLowerCase();
  check(
    "merge all names the URL group count",
    mergeAllLabel.includes(String(counts.url_groups)) && mergeAllLabel.includes("url"),
    mergeAllLabel
  );

  // ------------------------------------------------ show more ---------------
  await page.click('[data-testid="dedup-more-url"]');
  const urlAfterMore = await waitForCount(urlGroupNodes, URL_GROUPS);
  check("show more appends the next URL page", urlAfterMore === URL_GROUPS, "groups " + urlAfterMore);
  check("the URL show-more button disappears at the end", (await page.locator('[data-testid="dedup-more-url"]').count()) === 0);

  await page.click('[data-testid="dedup-more-title"]');
  const titleAfterMore = await waitForCount(titleGroupNodes, counts.title_groups);
  check("show more appends the next title page", titleAfterMore === counts.title_groups, "groups " + titleAfterMore);
  check("the title show-more button disappears at the end", (await page.locator('[data-testid="dedup-more-title"]').count()) === 0);

  // ------------------------------------------------ cancel sends nothing ----
  let mergeAllRequests = 0;
  const countMergeAll = (request) => {
    if (request.method() === "POST" && request.url().includes("/api/v1/dedup/merge-all")) mergeAllRequests += 1;
  };
  page.on("request", countMergeAll);

  await mergeAllButton.click();
  await page.waitForSelector('[data-testid="dialog-dedup-merge-all"]', { timeout: 15000 });
  const dialogText = (await page.locator('[data-testid="dialog-dedup-merge-all"]').innerText()).toLowerCase();
  check("the merge-all dialog shows the exact group count", dialogText.includes(String(counts.url_groups)), dialogText.slice(0, 200));
  check("the merge-all dialog states the keeper policy", dialogText.includes("oldest"), dialogText.slice(0, 240));
  check("the merge-all dialog excludes title matches", dialogText.includes("title"), dialogText.slice(0, 240));
  check("the merge-all dialog states the undo snapshot", dialogText.includes("undo snapshot"), dialogText.slice(0, 240));
  await page.click('[data-testid="dialog-cancel"]');
  await sleep(300);
  check("cancel closes the merge-all dialog", (await page.locator('[data-testid="dialog-dedup-merge-all"]').count()) === 0);
  check("cancel sends no merge-all request", mergeAllRequests === 0, "requests " + mergeAllRequests);
  check("cancel leaves both sections as they were", (await urlGroupNodes.count()) === URL_GROUPS, "url groups in DOM");

  // ------------------------------------------------ confirm merge all -------
  const mergeResponsePromise = page.waitForResponse(
    (response) => response.url().includes("/api/v1/dedup/merge-all") && response.request().method() === "POST",
    { timeout: 30000 }
  );
  await mergeAllButton.click();
  await page.waitForSelector('[data-testid="dialog-dedup-merge-all"]', { timeout: 15000 });
  await page.click('[data-testid="dialog-confirm"]');
  const mergeResponse = await mergeResponsePromise;
  const mergeReport = await mergeResponse.json().catch(() => null);
  console.log("merge-all:", mergeResponse.status(), JSON.stringify(mergeReport));
  check("merge all answers 200", mergeResponse.status() === 200, "status " + mergeResponse.status());
  check("one report covers every URL group", mergeReport?.groups === counts.url_groups, "groups " + mergeReport?.groups);
  check("one report covers every URL record", mergeReport?.records === counts.url_records, "records " + mergeReport?.records);
  check("one report covers every affected record", mergeReport?.affected === counts.url_records, "affected " + mergeReport?.affected);
  check("the merge writes one undo snapshot", Number.isInteger(mergeReport?.snapshot_id) && mergeReport.snapshot_id > 0, "snapshot " + mergeReport?.snapshot_id);

  await page.waitForSelector('[data-testid="dedup-merge-all-after"]', { timeout: 15000 });
  await sleep(500);
  const afterText = (await page.locator('[data-testid="dedup-url-section"]').innerText()).toLowerCase();
  check("no same-URL groups remain after the merge", (await urlGroupNodes.count()) === 0, "groups " + (await urlGroupNodes.count()));
  check("the title matches were not bulk merged", (await titleGroupNodes.count()) === counts.title_groups, "title groups " + (await titleGroupNodes.count()));
  check("the banner names the snapshot", (await page.locator('[data-testid="dedup-merge-all-after"]').innerText()).toLowerCase().includes("snapshot"), afterText.slice(0, 160));

  const keeperId = firstUrlGroup.items[0].id;
  const absorbedId = firstUrlGroup.items[1].id;
  const absorbedAfter = await api("/api/v1/bookmarks/" + absorbedId);
  check("an absorbed duplicate is gone", absorbedAfter.status === 404, "status " + absorbedAfter.status);
  const keeperAfter = await api("/api/v1/bookmarks/" + keeperId);
  check("the keeper is still there", keeperAfter.status === 200, "status " + keeperAfter.status);
  check(
    "the keeper address was upgraded to https",
    String(keeperAfter.body?.url || "").startsWith("https://"),
    String(keeperAfter.body?.url)
  );

  const titleKeeper = firstTitleGroup.items[0].id;
  const titleAbsorbed = firstTitleGroup.items[1].id;
  check(
    "title-only records survive the bulk merge",
    (await api("/api/v1/bookmarks/" + titleKeeper)).status === 200 &&
      (await api("/api/v1/bookmarks/" + titleAbsorbed)).status === 200,
    "both title-group records present"
  );

  // ------------------------------------------------ undo --------------------
  const undoPromise = page.waitForResponse(
    (response) => response.url().includes("/api/v1/undo") && response.request().method() === "POST",
    { timeout: 30000 }
  );
  await page.click('[data-testid="dedup-undo"]');
  const undoResponse = await undoPromise;
  check("the dedup undo answers 200", undoResponse.status() === 200, "status " + undoResponse.status());

  const restored = await waitForCount(urlGroupNodes, 60);
  check("undo restores the same-URL groups", restored === 60, "groups " + restored);
  const absorbedRestored = await api("/api/v1/bookmarks/" + absorbedId);
  check("undo restores the absorbed duplicate", absorbedRestored.status === 200, "status " + absorbedRestored.status);

  page.off("request", countMergeAll);
  const parseErrors = errors.filter((error) => /parse error/i.test(error));
  check("no Miso parse errors in the console", parseErrors.length === 0, parseErrors.join(" | ").slice(0, 300));
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
