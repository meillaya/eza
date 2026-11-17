// Add-passkey smoke: claim a fresh account, register a passkey through
// /account/add-passkey with a CDP virtual authenticator, and prove the account
// reports one more credential and the page redirects back to /account. Every
// step asserts; a missing page, a failed ceremony, or a credential that is not
// persisted fails the suite instead of printing a log line.
import { launchBrowser, launchPage, newChecker } from "./lib/dom.mjs";

const BASE = process.env.EZA_BASE || "http://localhost:8092";
const USER = process.env.EZA_TEST_USER || "e2e";
const PASSWORD = process.env.EZA_TEST_PASSWORD || "e2e-password-123";

const { check, report } = newChecker();
const browser = await launchBrowser();
const { context, page, errors } = await launchPage(browser);

async function credentialCount() {
  return page.evaluate(async () => {
    const response = await fetch("/api/v1/account");
    if (!response.ok) return -1;
    const body = await response.json();
    return Array.isArray(body.credentials) ? body.credentials.length : -1;
  });
}

try {
  await page.goto(BASE + "/setup", { waitUntil: "networkidle" });
  await page.fill("#username", USER);
  await page.fill("#password", PASSWORD);
  await page.fill("#confirm-password", PASSWORD);
  await page.click("#password-setup");
  await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
  check("setup reaches the recovery panel", true);

  const before = await credentialCount();
  check("the fresh account has no passkeys", before === 0, String(before));

  await page.goto(BASE + "/account/add-passkey", { waitUntil: "networkidle" });
  check("the add-passkey page renders", (await page.title()).length > 0);
  const addButton = page.locator("#passkey-add");
  check("the add-passkey button is present", (await addButton.count()) === 1);

  await Promise.all([
    page.waitForURL((url) => url.pathname === "/account", { timeout: 30000 }),
    addButton.click(),
  ]);
  check("registration redirects back to the account page", true);
  await page.waitForLoadState("networkidle").catch(() => {});

  const after = await credentialCount();
  check("registration adds one passkey to the account", after === before + 1, `${before} -> ${after}`);

  const jsErrors = errors.filter((error) => !/Failed to load resource/.test(error));
  check("no page errors", jsErrors.length === 0, jsErrors.slice(0, 3).join(" | "));
} finally {
  await context.close();
  await browser.close();
  report(errors);
}
