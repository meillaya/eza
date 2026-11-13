// First-run smoke test for the published container image. It claims the empty
// installation through /setup and exercises the same browser journey a new user
// sees, without relying on the e2e harness's scratch server.
//
//   EZA_BASE=http://127.0.0.1:18080 node tests/e2e/docker-first-run.mjs
//
// scripts/docker-smoke.sh runs this when EZA_DOCKER_BROWSER=1.
import { BASE, SEL, launchBrowser, launchPage, enterLibrary, makeApi, newChecker } from "./lib/dom.mjs";

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser);
const { check, report } = newChecker();

try {
  await enterLibrary(page);
  check("first-run setup reaches the app shell", (await page.locator(SEL.appShell).count()) === 1);

  const api = makeApi(page);
  const created = await api("/api/v1/bookmarks", {
    method: "POST",
    body: JSON.stringify({
      url: "https://docker-first-run.example/" + Date.now(),
      title: "Container first run",
    }),
  });
  check("first account can create a record", created.status === 201 && Number.isInteger(created.body?.id), JSON.stringify(created.body));

  const detail = await api("/api/v1/bookmarks/" + created.body.id);
  check("record reads back through the API", detail.status === 200 && detail.body?.title === "Container first run", JSON.stringify(detail.body?.title));

  await page.reload({ waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });
  check("session survives a reload", (await page.locator(SEL.appShell).count()) === 1);
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
