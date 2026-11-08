// Prune and undo smoke test.
//
// The 365-day prune candidate list is empty on a fresh import (added_at is the
// import time), so when there are no candidates the script files one bookmark
// and prunes that row directly to exercise the same snapshot and undo path.
//
// Run from the repo root in the dev shell, against a fresh scratch server:
//   EZA_BASE=http://localhost:8100 node tests/e2e/prune-undo-smoke.mjs
import { BASE, launchBrowser, launchPage, enterLibrary, makeApi, newChecker } from "./lib/dom.mjs";

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser);
const { check, report } = newChecker();
const api = makeApi(page);

try {
  await enterLibrary(page);

  const candidates = await api("/api/v1/maintenance/prune-candidates");
  const items = candidates.body?.items || [];
  console.log("candidates:", candidates.status, items.length);
  check("prune candidates endpoint answers", candidates.status === 200, "status " + candidates.status);

  let target = items[0]?.id;
  if (!target) {
    const created = await api("/api/v1/bookmarks", {
      method: "POST",
      body: JSON.stringify({ url: "https://prune-undo.example/" + Date.now(), title: "Prune undo smoke" }),
    });
    target = created.body?.id;
    console.log("no 365-day candidates; seeded bookmark", target);
  }
  check("a row is available to prune", Number.isInteger(target) && target > 0, String(target));

  const prune = await api("/api/v1/maintenance/prune", {
    method: "POST",
    body: JSON.stringify({ ids: [target] }),
  });
  console.log("prune:", prune.status, JSON.stringify(prune.body).slice(0, 160));
  check("prune succeeds", prune.status === 200, "status " + prune.status);
  const gone = await api("/api/v1/bookmarks/" + target);
  check("pruned row is gone", gone.status === 404, "status " + gone.status);

  const undo = await api("/api/v1/undo", { method: "POST" });
  console.log("undo:", undo.status, JSON.stringify(undo.body).slice(0, 160));
  check("undo succeeds", undo.status === 200, "status " + undo.status);
  const back = await api("/api/v1/bookmarks/" + target);
  check("undo restores the row", back.status === 200, "status " + back.status + " title " + String(back.body?.title));
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
