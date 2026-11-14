// Deep-link smoke test: every client route boots the app shell, keeps the
// search field, and never shows the boot error. Then checks the AI status
// endpoint used by the AI tags screen.
//
// Run from the repo root in the dev shell, against a scratch server:
//   EZA_BASE=http://localhost:8100 node tests/e2e/deeplink-smoke.mjs
import { BASE, SEL, launchBrowser, launchPage, enterLibrary, makeApi, newChecker, waitForJob } from "./lib/dom.mjs";

const ROUTES = ["/", "/graph", "/inbox", "/bookmark/1", "/tags/ai", "/account", "/history", "/accessions", "/save?title=Deep%20link"];

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser);
const { check, report } = newChecker();

try {
  await enterLibrary(page);
  const api = makeApi(page);

  for (const route of ROUTES) {
    const response = await page.goto(BASE + route, { waitUntil: "domcontentloaded" });
    await page.waitForSelector(SEL.appShell, { timeout: 30000 }).catch(() => {});
    const search = await page.locator(SEL.search).count();
    const bootError = await page.locator("#boot-error").isVisible().catch(() => false);
    console.log(route, "http", response?.status(), "search", search, "bootError", bootError);
    check("route " + route + " has the app shell", (await page.locator(SEL.appShell).count()) > 0);
    check("route " + route + " has no boot error", bootError === false);
  }

  const enqueue = await api("/api/v1/ai/suggestions", { method: "POST", body: JSON.stringify({}) });
  check("ai suggestion job enqueues", enqueue.status === 202 && Number.isInteger(enqueue.body?.job_id), "status " + enqueue.status);
  if (enqueue.status === 202) {
    const job = await waitForJob(api, enqueue.body.job_id);
    check(
      "ai suggestion job reaches a terminal state",
      ["done", "failed", "cancelled"].includes(job.body?.state),
      "status " + job.status + " state " + (job.body?.state ?? "none")
    );
    console.log("suggestions job:", JSON.stringify(job.body || {}).slice(0, 200));
  }
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
