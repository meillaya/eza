import { chromium } from "@playwright/test";

const BASE = process.env.EZA_BASE || "http://localhost:8083";

async function installAuthenticator(context, page) {
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.enable", { enableUI: false });
  const { authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2",
      transport: "internal",
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true,
    },
  });
  return { cdp, authenticatorId };
}

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();
const errors = [];
page.on("console", (msg) => { if (msg.type() === "error") errors.push(msg.text()); });
page.on("pageerror", (err) => errors.push(String(err)));

await installAuthenticator(context, page);

await page.goto(BASE + "/setup", { waitUntil: "networkidle" });
console.log("setup page title:", await page.title());
await page.fill("#username", process.env.EZA_TEST_USER || "e2e");
await page.fill("#password", process.env.EZA_TEST_PASSWORD || "e2e-password-123");
await page.fill("#confirm-password", process.env.EZA_TEST_PASSWORD || "e2e-password-123");
await page.click("#password-setup");
await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
const codes = (await page.locator("#codes").textContent()).trim().split("\n").filter(Boolean);
console.log("recovery codes:", codes.length, codes[0] ? "non-empty" : "EMPTY");

const boot = await page.evaluate(async () => {
  const r = await fetch("/api/v1/boot");
  return { status: r.status, body: await r.json() };
});
console.log("boot after setup:", boot.status, "items:", boot.body?.initial?.items?.length, "total:", boot.body?.initial?.total);

const account = await page.evaluate(async () => {
  const r = await fetch("/api/v1/account");
  return { status: r.status, body: await r.json() };
});
console.log("account:", account.status, JSON.stringify(account.body).slice(0, 300));

// Logout, then log back in with the same virtual authenticator.
const logout = await page.evaluate(async () => {
  const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
  const r = await fetch("/api/auth/logout", { method: "POST", headers: { "X-CSRF-Token": csrf } });
  return r.status;
});
console.log("logout:", logout);
await page.goto(BASE + "/login", { waitUntil: "networkidle" });
await page.fill("#username", process.env.EZA_TEST_USER || "e2e");
await page.fill("#password", process.env.EZA_TEST_PASSWORD || "e2e-password-123");
await page.click("#password-login");
await page.waitForFunction(async () => {
  try {
    const r = await fetch("/api/v1/boot");
    return r.status === 200;
  } catch { return false; }
}, null, { timeout: 30000 });
console.log("login restored session: true");

console.log("console errors:", errors.slice(0, 5));
await browser.close();
