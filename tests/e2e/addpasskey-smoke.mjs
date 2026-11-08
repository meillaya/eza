import { chromium } from "@playwright/test";
const BASE = process.env.EZA_BASE || "http://localhost:8092";
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();
const cdp = await context.newCDPSession(page);
await cdp.send("WebAuthn.enable", { enableUI: false });
await cdp.send("WebAuthn.addVirtualAuthenticator", { options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true } });
await page.goto(BASE + "/setup", { waitUntil: "networkidle" });
await page.fill("#username", process.env.EZA_TEST_USER || "e2e");
await page.fill("#password", process.env.EZA_TEST_PASSWORD || "e2e-password-123");
await page.fill("#confirm-password", process.env.EZA_TEST_PASSWORD || "e2e-password-123");
await page.click("#password-setup");
await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
const before = await page.evaluate(async () => (await (await fetch("/api/v1/account")).json()).credentials.length);
await page.goto(BASE + "/account/add-passkey", { waitUntil: "networkidle" });
const addButton = await page.locator("#passkey-add").count();
console.log("add page title:", await page.title(), "button:", addButton, "url:", page.url());
if (addButton === 0) {
  // Password accounts retire passkey-first setup. Legacy passkey enrollment is
  // covered by the auth unit tests, not this browser path.
  console.log("passkey enrollment retired for password accounts");
  await browser.close();
  process.exit(0);
}
await page.click("#passkey-add");
await page.waitForTimeout(3000);
console.log("error:", await page.locator("#auth-error").innerText().catch(() => "?"));
console.log("url:", page.url());
await page.screenshot({ path: ".dsh-cache/addpasskey.png" });
try { await page.waitForURL("**/account", { timeout: 5000 }); } catch (_) {}
const after = await page.evaluate(async () => (await (await fetch("/api/v1/account")).json()).credentials.length);
console.log("passkeys before/after:", before, after);
await browser.close();
