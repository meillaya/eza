// Share-link UI smoke test: bookmark share dialog (include note + expiry),
// created URL + copy, public read-only page, existing links, revoke from the
// account section, revoked link 404, and the AI status banner.
//
// Run from the repo root in the dev shell:
//   EZA_BASE=http://localhost:8095 node tests/e2e/share-ui-smoke.mjs
import { chromium } from "@playwright/test";

const BASE = process.env.EZA_BASE || "http://localhost:8095";
const passed = [];
const failed = [];
function check(name, condition, detail) {
  if (condition) {
    passed.push(name);
    console.log("PASS " + name + (detail ? " — " + detail : ""));
  } else {
    failed.push(name + (detail ? " — " + detail : ""));
    console.log("FAIL " + name + (detail ? " — " + detail : ""));
  }
}

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
const page = await context.newPage();
const consoleErrors = [];
page.on("console", (message) => {
  if (message.type() === "error") consoleErrors.push(message.text());
});
page.on("pageerror", (error) => consoleErrors.push(String(error)));

const cdp = await context.newCDPSession(page);
await cdp.send("WebAuthn.enable", { enableUI: false });
await cdp.send("WebAuthn.addVirtualAuthenticator", {
  options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true },
});

const api = (path, options = {}) =>
  page.evaluate(
    async ({ path, options }) => {
      const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
      const headers = Object.assign({ "Content-Type": "application/json" }, options.headers || {});
      if ((options.method || "GET") !== "GET") headers["X-CSRF-Token"] = csrf;
      const response = await fetch(path, { ...options, headers });
      let body = null;
      try { body = await response.json(); } catch (_) {}
      return { status: response.status, body };
    },
    { path, options }
  );

try {
  await page.goto(BASE + "/setup", { waitUntil: "domcontentloaded" });
  await page.click("#passkey-setup");
  await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
  await page.click("#continue");
  await page.waitForSelector(".topbar", { timeout: 30000 });
  await page.waitForTimeout(1200);

  const listing = await api("/api/v1/bookmarks?limit=1&offset=0");
  const bookmark = (listing.body?.items || [])[0];
  check("bookmark available for sharing", Boolean(bookmark), JSON.stringify(bookmark || {}).slice(0, 120));
  if (!bookmark) throw new Error("no bookmarks");
  await page.goto(BASE + "/bookmark/" + bookmark.id, { waitUntil: "domcontentloaded" });
  await page.waitForSelector(".detail", { timeout: 20000 });
  await page.waitForTimeout(700);

  // Archive: the snapshot action is only exposed for local file snapshots.
  const detail = (await api("/api/v1/bookmarks/" + bookmark.id)).body || {};
  const snapshotButtons = await page.locator("button", { hasText: "View snapshot" }).count();
  check(
    "snapshot button matches snapshot availability",
    (detail.snapshot_kind === "file") === (snapshotButtons > 0),
    "kind=" + JSON.stringify(detail.snapshot_kind) + " buttons=" + snapshotButtons
  );
  if (snapshotButtons > 0) {
    await page.locator("button", { hasText: "View snapshot" }).first().click();
    await page.waitForSelector(".snapshot-frame", { timeout: 10000 });
    const frameSrc = await page.locator(".snapshot-frame").getAttribute("src");
    const frameSandbox = await page.locator(".snapshot-frame").getAttribute("sandbox");
    const snapshotResponse = await api("/api/v1/bookmarks/" + bookmark.id + "/snapshot");
    check("snapshot iframe is sandboxed", frameSrc === "/api/v1/bookmarks/" + bookmark.id + "/snapshot" && frameSandbox === "", String(frameSrc));
    check("snapshot endpoint serves html", snapshotResponse.status === 200, "status " + snapshotResponse.status);
    await page.locator('.modal-head button[title="Close snapshot"]').click();
    await page.waitForTimeout(300);
  }

  // Open share dialog.
  await page.getByRole("button", { name: "Share", exact: true }).click();
  await page.waitForSelector(".modal", { timeout: 10000 });
  check("share dialog opens", (await page.locator(".modal-head", { hasText: "Share this bookmark" }).count()) === 1);

  // Configure + create.
  await page.locator('.share-option input[type="checkbox"]').check();
  await page.selectOption(".modal select.select", "7");
  await page.getByRole("button", { name: "Create share link", exact: true }).click();
  await page.waitForSelector(".share-reveal", { timeout: 20000 });
  const shareUrl = (await page.locator(".share-reveal .token-secret").innerText()).trim();
  check("share url shown", shareUrl.startsWith("http") && shareUrl.includes("/s/"), shareUrl.slice(0, 60) + "…");
  const expiryDays = await page.evaluate(() => {
    const element = document.querySelector(".modal select.select");
    return element ? element.value : null;
  });
  check("expiry selection captured", expiryDays === "7", String(expiryDays));

  await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin: BASE });
  await page.getByRole("button", { name: "Copy link", exact: true }).click();
  await page.waitForTimeout(500);
  const clipboard = await page.evaluate(() => navigator.clipboard.readText().catch(() => ""));
  check("copy share link", clipboard === shareUrl, clipboard.slice(0, 40) + "…");

  // Server state.
  const sharesResponse = await api("/api/v1/share-links");
  const shares = sharesResponse.body?.shares || [];
  const created = shares.find((entry) => entry.scope === "bookmark" && entry.target_id === bookmark.id && !entry.revoked_at);
  const now = Math.floor(Date.now() / 1000);
  check("share link listed via api", Boolean(created), JSON.stringify(shares).slice(0, 160));
  check("share target and scope", created?.target_id === bookmark.id && created?.scope === "bookmark");
  check("include-note stored", created?.include_note === true, String(created?.include_note));
  check(
    "expiry is about 7 days",
    Boolean(created) && created.expires_at > now + 6 * 86400 && created.expires_at < now + 8 * 86400,
    created ? "expires in " + Math.round((created.expires_at - now) / 86400) + "d" : "missing"
  );

  // Existing links are listed in the dialog.
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.waitForSelector(".detail", { timeout: 20000 });
  await page.getByRole("button", { name: "Share", exact: true }).click();
  await page.waitForSelector(".share-row", { timeout: 10000 });
  check("existing link listed in dialog", (await page.locator(".share-row").count()) >= 1);

  // Public page works without a session.
  const publicContext = await browser.newContext();
  const publicPage = await publicContext.newPage();
  const publicResponse = await publicPage.goto(shareUrl, { waitUntil: "domcontentloaded" });
  const publicTitle = await publicPage.locator("h1").first().innerText().catch(() => "");
  check("public share page 200", publicResponse?.status() === 200, "status " + (publicResponse ? publicResponse.status() : "?"));
  check(
    "public page shows bookmark title",
    publicTitle.trim().length > 0 && (publicTitle.includes(bookmark.title) || bookmark.title.includes(publicTitle.trim())),
    publicTitle.slice(0, 60)
  );
  await publicContext.close();

  // Account section + revoke.
  await page.goto(BASE + "/account", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(".token-form", { timeout: 20000 });
  const sharesPanel = page.locator(".panel", { hasText: "Shares" }).first();
  check("account shares section present", (await sharesPanel.count()) === 1);
  await page.waitForTimeout(500);
  const accountShareRow = page.locator(".cred", { hasText: "Bookmark #" + bookmark.id }).first();
  check("account lists the bookmark share", (await accountShareRow.count()) >= 1);
  await accountShareRow.getByRole("button", { name: "Revoke", exact: true }).click();
  await page.waitForFunction(
    () => [...document.querySelectorAll(".toast")].some((toast) => /Share link revoked/.test(toast.textContent)),
    null,
    { timeout: 20000 }
  ).catch(() => {});
  await page.waitForTimeout(1000);
  const afterRevoke = await api("/api/v1/share-links");
  const revoked = (afterRevoke.body?.shares || []).find((entry) => entry.id === created?.id);
  check("share revoked on server", Boolean(revoked?.revoked_at), String(revoked?.revoked_at));

  // Revoked link is gone for the public.
  const revokedContext = await browser.newContext();
  const revokedPage = await revokedContext.newPage();
  const revokedResponse = await revokedPage.goto(shareUrl, { waitUntil: "domcontentloaded" });
  check("revoked share page 404", revokedResponse?.status() === 404, "status " + (revokedResponse ? revokedResponse.status() : "?"));
  await revokedContext.close();

  // AI status banner on the AI tags page.
  await page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(".topbar", { timeout: 20000 });
  await page.waitForTimeout(600);
  await page.locator(".scope", { hasText: /^AI tags$/ }).first().click();
  await page.waitForTimeout(1500);
  const bannerText = await page.locator(".banner").first().innerText().catch(() => "");
  check(
    "ai status banner shows provider/configured",
    /AI provider:/i.test(bannerText) && /(configured|not configured)/i.test(bannerText),
    bannerText.replace(/\n+/g, " ").slice(0, 100)
  );
} catch (error) {
  failed.push("unexpected error — " + (error && error.stack ? error.stack : String(error)));
} finally {
  await browser.close();
}

console.log("");
console.log("passed: " + passed.length + ", failed: " + failed.length);
if (consoleErrors.length) {
  console.log("console errors (" + consoleErrors.length + "):");
  for (const error of consoleErrors.slice(0, 10)) console.log("  " + error);
}
if (failed.length) {
  console.log("failures:");
  for (const failure of failed) console.log("  - " + failure);
  process.exit(1);
}
