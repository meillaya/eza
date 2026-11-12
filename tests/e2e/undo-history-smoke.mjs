// Undo history smoke test: the maintenance page lists recent snapshots, the
// preview names the exact action, and only the newest usable snapshot can be
// applied. The prune API creates a real side snapshot; the page must read it
// back through GET /api/v1/undo and preview it through GET /api/v1/undo/{id}.
//
// Run from the repo root in the dev shell, against a scratch server:
//   EZA_BASE=http://localhost:8100 node tests/e2e/undo-history-smoke.mjs
import { BASE, SEL, launchBrowser, launchPage, enterLibrary, makeApi, newChecker } from "./lib/dom.mjs";

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser);
const { check, report } = newChecker();
const api = makeApi(page);

try {
  await enterLibrary(page);

  const created = await api("/api/v1/bookmarks", {
    method: "POST",
    body: JSON.stringify({ url: "https://undo-history.example/" + Date.now(), title: "Undo history smoke" }),
  });
  check("seed record created", [200, 201].includes(created.status) && Number.isInteger(created.body?.id), JSON.stringify(created.body));
  const target = created.body?.id;

  const prune = await api("/api/v1/maintenance/prune", {
    method: "POST",
    body: JSON.stringify({ ids: [target] }),
  });
  check("prune creates a snapshot", prune.status === 200 && prune.body?.pruned === 1, JSON.stringify(prune.body));

  const entries = await api("/api/v1/undo?limit=5");
  console.log("undo entries:", entries.status, JSON.stringify(entries.body).slice(0, 260));
  check("undo list answers", entries.status === 200, "status " + entries.status);
  const list = entries.body?.entries || [];
  check("undo list has the prune", list.length >= 1 && list[0].op, JSON.stringify(list.slice(0, 2)));
  check("newest snapshot is usable", list[0]?.can_undo === true, JSON.stringify(list[0] || {}));

  await page.goto(BASE + "/maintenance", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });
  await page.waitForSelector(SEL.undoEntry, { timeout: 20000 });
  const visibleEntries = await page.locator(SEL.undoEntry).count();
  check("maintenance renders the undo history", visibleEntries >= 1, "entries=" + visibleEntries);

  const snapshotId = await page.locator(SEL.undoEntry).first().getAttribute("data-snapshot-id");
  check("entry carries its snapshot id", Boolean(snapshotId), String(snapshotId));

  await page.locator(SEL.undoInspect).first().click();
  await page.waitForSelector(SEL.undoPreview, { timeout: 10000 });
  // The preview dialog renders in a loading state while GET /undo/{id} is in
  // flight; wait for the confirmation control before reading its copy.
  await page.waitForSelector(SEL.undoConfirm, { timeout: 10000 });
  await page.waitForFunction(
    () => {
      const dialog = document.querySelector('[data-testid="undo-preview"]');
      return dialog && !/Reading the snapshot/i.test(dialog.innerText);
    },
    null,
    { timeout: 10000 }
  );
  const previewText = (await page.locator(SEL.undoPreview).innerText()).replace(/\s+/g, " ");
  check("preview names the action", /prune/i.test(previewText), previewText.slice(0, 180));
  check("preview offers confirm", (await page.locator(SEL.undoConfirm).count()) === 1);

  await page.locator(SEL.undoConfirm).click();
  await page.waitForSelector(SEL.undoPreview, { state: "detached", timeout: 20000 }).catch(() => {});
  const restored = await api("/api/v1/bookmarks/" + target);
  check("confirm restores the pruned record", restored.status === 200, "status " + restored.status);

  const after = await api("/api/v1/undo?limit=5");
  const afterList = after.body?.entries || [];
  check("the used snapshot leaves the undoable stack", afterList.every((entry) => entry.id !== Number(snapshotId)), JSON.stringify(afterList.map((entry) => entry.id)));
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
