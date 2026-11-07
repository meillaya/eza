import { chromium } from "@playwright/test";

const BASE = process.env.EZA_BASE || "http://localhost:8087";
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1360, height: 900 } });
const page = await context.newPage();
const errors = [];
page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
page.on("pageerror", (e) => errors.push(String(e)));

const cdp = await context.newCDPSession(page);
await cdp.send("WebAuthn.enable", { enableUI: false });
await cdp.send("WebAuthn.addVirtualAuthenticator", {
  options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true },
});

await page.goto(BASE + "/setup", { waitUntil: "networkidle" });
await page.click("#passkey-setup");
await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
await page.click("#continue");
await page.waitForTimeout(1500);
const bootSplash = await page.locator("#boot-splash").isVisible().catch(() => false);
const hasSearch = await page.locator("#search-input").count();
const bodyText = (await page.locator("body").innerText()).slice(0, 500);
console.log("url:", page.url(), "splash:", bootSplash, "search:", hasSearch);
console.log("body:", bodyText.replace(/\n+/g, " | ").slice(0, 400));
console.log("console errors:", errors.slice(0, 8));
await page.screenshot({ path: ".dsh-cache/ui-library.png", fullPage: false });

// Detail navigation from the first card if present.
const card = page.locator(".card, .bookmark-card, .grid a").first();
if (await card.count()) {
  await card.click();
  await page.waitForTimeout(1200);
  console.log("detail url:", page.url());
  await page.screenshot({ path: ".dsh-cache/ui-detail.png", fullPage: false });
}
await browser.close();
