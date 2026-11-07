import { chromium } from "@playwright/test";
const BASE = process.env.EZA_BASE || "http://localhost:8091";
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(String(e)));
const cdp = await context.newCDPSession(page);
await cdp.send("WebAuthn.enable", { enableUI: false });
await cdp.send("WebAuthn.addVirtualAuthenticator", { options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true } });
await page.goto(BASE + "/setup", { waitUntil: "networkidle" });
await page.click("#passkey-setup");
await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
for (const path of ["/graph", "/inbox", "/bookmark/1", "/tags/ai", "/account"]) {
  const resp = await page.goto(BASE + path, { waitUntil: "networkidle" });
  await page.waitForTimeout(800);
  const search = await page.locator("#search-input").count();
  const err = await page.locator("#boot-error").isVisible().catch(() => false);
  console.log(path, "http", resp?.status(), "search", search, "bootError", err);
}
const suggestions = await page.evaluate(async () => {
  const r = await fetch("/api/v1/tags/imported/suggestions");
  return { status: r.status, body: await r.json() };
});
console.log("suggestions:", suggestions.status, JSON.stringify(suggestions.body).slice(0, 200));
console.log("pageerrors:", errors.slice(0, 5));
await browser.close();
