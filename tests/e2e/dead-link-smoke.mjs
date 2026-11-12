// Dead-link manual override smoke test: a record marked dead by the sweep can
// be kept alive from its page, sweeps skip it while the override exists, and
// returning to automatic checks clears the override.
//
// Run from the repo root in the dev shell, against a scratch server:
//   EZA_BASE=http://localhost:8100 node tests/e2e/dead-link-smoke.mjs
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";

import { BASE, SEL, launchBrowser, launchPage, enterLibrary, makeApi, newChecker } from "./lib/dom.mjs";

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser);
const { check, report } = newChecker();
const api = makeApi(page);

function scratchDb() {
  const explicit = process.env.EZA_DEDUP_DB;
  const fallback = path.resolve(".dsh-cache/e2e-run/dead-link-smoke/eza.db");
  return [explicit, fallback].filter(Boolean).find((candidate) => existsSync(candidate));
}

try {
  await enterLibrary(page);
  const pageResult = await api("/api/v1/bookmarks?limit=1");
  const bookmark = pageResult.body?.items?.[0];
  check("a record is available", Number.isInteger(bookmark?.id), JSON.stringify(pageResult.body).slice(0, 160));
  const target = bookmark.id;

  const db = scratchDb();
  check("scratch database is available", Boolean(db), String(db || "missing"));
  if (db) {
    execFileSync("sqlite3", [db, "UPDATE bookmarks SET is_dead = 1, last_checked_at = strftime('%s','now') WHERE id = " + Number(target) + ";"]);
  }

  const marked = await api("/api/v1/bookmarks/" + target);
  check("record is marked dead in the database", marked.body?.is_dead === true, JSON.stringify(marked.body).slice(0, 120));

  await page.goto(BASE + "/bookmark/" + target, { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.record, { timeout: 30000 });
  await page.waitForSelector(SEL.deadBanner, { timeout: 20000 });
  await page.locator(SEL.markNotDead).click();
  await page.waitForSelector(SEL.deadBanner, { state: "detached", timeout: 20000 });
  await page.waitForSelector(SEL.manualAlive, { timeout: 10000 });

  const kept = await api("/api/v1/bookmarks/" + target);
  check("manual override clears the dead flag", kept.body?.is_dead === false, JSON.stringify(kept.body).slice(0, 120));
  check("manual override is recorded", kept.body?.manual_alive === true, JSON.stringify(kept.body).slice(0, 120));

  await page.locator(SEL.recheckLink).click();
  await page.waitForSelector(SEL.manualAlive, { state: "detached", timeout: 20000 });
  const rechecked = await api("/api/v1/bookmarks/" + target);
  check("recheck clears the manual override", rechecked.body?.manual_alive === false, JSON.stringify(rechecked.body).slice(0, 120));
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
