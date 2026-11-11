// First-run auth smoke: claim the install with a password, capture the ten
// recovery codes, verify the authenticated boot/account reads, then log out and
// back in and prove the session is restored. Every step asserts.
import { launchBrowser, launchPage, newChecker } from "./lib/dom.mjs";

const BASE = process.env.EZA_BASE || "http://localhost:8083";
const USER = process.env.EZA_TEST_USER || "e2e";
const PASSWORD = process.env.EZA_TEST_PASSWORD || "e2e-password-123";

const { check, report } = newChecker();
const browser = await launchBrowser();
const { context, page, errors } = await launchPage(browser);

try {
  await page.goto(BASE + "/setup", { waitUntil: "networkidle" });
  check("the setup page renders", (await page.title()).length > 0);

  await page.fill("#username", USER);
  await page.fill("#password", PASSWORD);
  await page.fill("#confirm-password", PASSWORD);
  await page.click("#password-setup");
  await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
  check("setup reaches the recovery panel", true);

  const codes = (await page.locator("#codes").textContent()).trim().split("\n").filter(Boolean);
  check("setup shows ten recovery codes", codes.length === 10, String(codes.length));
  check("recovery codes are non-empty", codes.every((code) => code.trim().length > 0));

  const boot = await page.evaluate(async () => {
    const r = await fetch("/api/v1/boot");
    return { status: r.status, body: await r.json() };
  });
  check("boot answers 200 after setup", boot.status === 200, String(boot.status));
  check("boot carries the initial page", Array.isArray(boot.body?.initial?.items) && Number.isInteger(boot.body?.initial?.total));

  const account = await page.evaluate(async () => {
    const r = await fetch("/api/v1/account");
    return { status: r.status, body: await r.json() };
  });
  check("account answers 200", account.status === 200, String(account.status));
  check("account names the signed-in user", account.body?.username === USER, String(account.body?.username));

  const logout = await page.evaluate(async () => {
    const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
    const r = await fetch("/api/auth/logout", { method: "POST", headers: { "X-CSRF-Token": csrf } });
    return r.status;
  });
  check("logout answers 200/204", logout === 200 || logout === 204, String(logout));

  await page.goto(BASE + "/login", { waitUntil: "networkidle" });
  await page.fill("#username", USER);
  await page.fill("#password", PASSWORD);
  await Promise.all([
    page.waitForURL((url) => !url.pathname.startsWith("/login"), { timeout: 30000 }).catch(() => {}),
    page.click("#password-login"),
  ]);
  await page.waitForLoadState("networkidle").catch(() => {});
  await page.waitForFunction(
    async () => {
      try {
        const r = await fetch("/api/v1/boot");
        return r.status === 200;
      } catch {
        return false;
      }
    },
    null,
    { timeout: 30000 },
  );
  check("login restores the session", true);

  const afterLogin = await page.evaluate(async () => {
    const r = await fetch("/api/v1/account");
    return { status: r.status, body: await r.json() };
  });
  check("the restored session can read the account", afterLogin.status === 200 && afterLogin.body?.username === USER);
  const jsErrors = errors.filter((error) => !/Failed to load resource/.test(error));
  check("no page errors", jsErrors.length === 0, jsErrors.slice(0, 3).join(" | "));
} finally {
  await context.close();
  await browser.close();
  report(errors);
}
