// Capture-token smoke: create a capture-scoped token, use it with the clip API,
// confirm the scope walls, and prove the token cannot read the account token
// list. Every step asserts a status; the one-time secret is checked.
import { launchBrowser, launchPage, newChecker } from "./lib/dom.mjs";

const BASE = process.env.EZA_BASE || "http://localhost:8107";
const USER = process.env.EZA_TEST_USER || "e2e";
const PASSWORD = process.env.EZA_TEST_PASSWORD || "e2e-password-123";

const { check, report } = newChecker();
const browser = await launchBrowser();
const { context, page, errors } = await launchPage(browser);

try {
  await page.goto(BASE + "/setup", { waitUntil: "networkidle" });
  await page.fill("#username", USER);
  await page.fill("#password", PASSWORD);
  await page.fill("#confirm-password", PASSWORD);
  await page.click("#password-setup");
  await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });

  const result = await page.evaluate(async () => {
    const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
    const create = await fetch("/api/v1/tokens", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf },
      body: JSON.stringify({ name: "extension", scopes: ["capture"] }),
    });
    const created = await create.json();
    const save = await fetch("/api/v1/quick-save", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + created.token },
      body: JSON.stringify({ url: "https://www.haskell.org/ghcup/" }),
    });
    const saved = await save.json();
    const whoami = await fetch("/api/v1/whoami", { headers: { Authorization: "Bearer " + created.token } });
    const whoamiBody = await whoami.json();
    const list = await fetch("/api/v1/tokens", { headers: { Authorization: "Bearer " + created.token } });
    const write = await fetch("/api/v1/bookmarks", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + created.token },
      body: JSON.stringify({ url: "https://example.com/capture-scope-write" }),
    });
    const templates = await fetch("/api/v1/clip-templates", { headers: { Authorization: "Bearer " + created.token } });
    return {
      createStatus: create.status,
      token: created.token,
      tokenInfo: created.token_info,
      saveStatus: save.status,
      saved,
      whoamiStatus: whoami.status,
      whoamiBody,
      listStatus: list.status,
      writeStatus: write.status,
      templatesStatus: templates.status,
    };
  });

  check("creating a capture token answers 201", result.createStatus === 201, String(result.createStatus));
  check("the token secret is returned once", typeof result.token === "string" && result.token.startsWith("eza_pat_"));
  check("the token records the capture scope", JSON.stringify(result.tokenInfo?.scopes) === JSON.stringify(["capture"]), JSON.stringify(result.tokenInfo?.scopes));
  check("quick-save with the capture token answers 200/201", result.saveStatus === 200 || result.saveStatus === 201, String(result.saveStatus));
  check("quick-save returns an existing/new id", Number.isInteger(result.saved?.id), JSON.stringify(result.saved));
  check("whoami accepts the capture token", result.whoamiStatus === 200, String(result.whoamiStatus));
  check("whoami reports the capture scope", JSON.stringify(result.whoamiBody?.scopes) === JSON.stringify(["capture"]), JSON.stringify(result.whoamiBody?.scopes));
  check("clip-templates read is allowed for a capture token", result.templatesStatus === 200, String(result.templatesStatus));
  check("the token list is session-only (capture token refused)", result.listStatus === 403, String(result.listStatus));
  check("ordinary bookmark writes are refused for a capture token", result.writeStatus === 403, String(result.writeStatus));
  const jsErrors = errors.filter((error) => !/Failed to load resource/.test(error));
  check("no page errors", jsErrors.length === 0, jsErrors.slice(0, 3).join(" | "));
} finally {
  await context.close();
  await browser.close();
  report(errors);
}
