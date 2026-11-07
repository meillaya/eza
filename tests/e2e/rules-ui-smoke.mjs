// Rules UI smoke test: list/empty state, dry run (match + no match), create,
// validation, enable/disable, delete, and rules actually applying on save.
//
// Run from the repo root in the dev shell:
//   EZA_BASE=http://localhost:8095 node tests/e2e/rules-ui-smoke.mjs
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

const rules = async () => (await api("/api/v1/rules")).body?.rules || [];
const waitToast = async (pattern) => {
  await page.waitForFunction(
    (source) => [...document.querySelectorAll(".toast")].some((toast) => new RegExp(source).test(toast.textContent)),
    pattern,
    { timeout: 20000 }
  ).catch(() => {});
};

try {
  await page.goto(BASE + "/setup", { waitUntil: "domcontentloaded" });
  await page.click("#passkey-setup");
  await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
  await page.click("#continue");
  await page.waitForSelector(".topbar", { timeout: 30000 });
  await page.waitForTimeout(1200);
  await page.goto(BASE + "/account", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(".rule-form", { timeout: 20000 });
  await page.waitForTimeout(600);

  check("rules panel present", (await page.locator("text=Rules").count()) > 0);
  check("rules empty state", (await page.locator("text=No rules yet.").count()) > 0);

  // Use the hostname of an existing bookmark so the dry run always has a match.
  let sampleUrl = (await api("/api/v1/bookmarks?limit=1&offset=0")).body?.items?.[0]?.url || "";
  if (!sampleUrl) {
    const seeded = await api("/api/v1/bookmarks", { method: "POST", body: JSON.stringify({ url: "https://dry-run.example/seed", title: "Dry run seed" }) });
    sampleUrl = (await api("/api/v1/bookmarks/" + seeded.body.id)).body?.url || "";
  }
  const sampleHost = await page.evaluate((url) => new URL(url).hostname, sampleUrl);
  check("sample hostname for dry run", Boolean(sampleHost), sampleHost);

  // Dry run with matches (domain substring match on an existing bookmark).
  await page.selectOption(".rule-form select", "domain");
  await page.fill("#rule-pattern", sampleHost);
  await page.getByRole("button", { name: "Dry run", exact: true }).click();
  await page.waitForSelector(".rule-result", { timeout: 20000 });
  const dryRunText = (await page.locator(".rule-result").innerText()).trim();
  const dryRunMatches = Number((dryRunText.match(/(\d+) matching/) || [])[1] || 0);
  check("dry run reports matches", dryRunMatches > 0, dryRunText + " (pattern " + sampleHost + ")");

  // Dry run with no matches.
  await page.fill("#rule-pattern", "zzz-no-match-zzz");
  await page.getByRole("button", { name: "Dry run", exact: true }).click();
  await page.waitForFunction(
    () => {
      const element = document.querySelector(".rule-result");
      return Boolean(element && /Dry run: 0 matching/.test(element.textContent));
    },
    null,
    { timeout: 20000 }
  ).catch(() => {});
  check("dry run reports zero matches", /Dry run: 0 matching/.test(await page.locator(".rule-result").innerText()));

  // Create a rule.
  await page.fill("#rule-name", "E2E domain rule");
  await page.selectOption(".rule-form select", "domain");
  const ruleDomain = "rule-smoke-" + Date.now() + ".example";
  await page.fill("#rule-pattern", ruleDomain);
  await page.fill("#rule-tags", "rule-a, rule-b");
  await page.locator('.rule-form input[type="checkbox"]').check();
  await page.getByRole("button", { name: "Create rule", exact: true }).click();
  await waitToast("created");
  await page.waitForSelector(".rules-table tbody tr", { timeout: 20000 });
  const createdRules = await rules();
  const created = createdRules.find((rule) => rule.name === "E2E domain rule");
  check("rule created via ui", Boolean(created), JSON.stringify(createdRules).slice(0, 180));
  check(
    "rule fields stored",
    created?.field === "domain" && created?.pattern === ruleDomain && created?.enabled === true && created?.mark_read === true,
    JSON.stringify({ field: created?.field, pattern: created?.pattern, enabled: created?.enabled, mark_read: created?.mark_read })
  );
  check(
    "rule tags stored",
    JSON.stringify(created?.add_tags || []) === JSON.stringify(["rule-a", "rule-b"]),
    JSON.stringify(created?.add_tags)
  );
  check("rule listed in the table", (await page.locator(".rules-table tbody tr", { hasText: "E2E domain rule" }).count()) === 1);

  // Rules actually apply on save.
  const bookmarkUrl = "https://" + ruleDomain + "/saved";
  const added = await api("/api/v1/bookmarks", { method: "POST", body: JSON.stringify({ url: bookmarkUrl, title: "Rule smoke" }) });
  const addedId = added.body?.id;
  const addedDetail = addedId ? await api("/api/v1/bookmarks/" + addedId) : { body: {} };
  const tags = addedDetail.body?.tags || [];
  check("rule applies tags on save", tags.includes("rule-a") && tags.includes("rule-b") && addedDetail.body?.is_read === true, JSON.stringify({ tags, is_read: addedDetail.body?.is_read }));

  // Validation: empty name/pattern is rejected client-side.
  const countBeforeValidation = (await rules()).length;
  await page.fill("#rule-name", "");
  await page.fill("#rule-pattern", "");
  await page.getByRole("button", { name: "Create rule", exact: true }).click();
  await page.waitForTimeout(600);
  check("create validates required fields", (await rules()).length === countBeforeValidation);

  // Disable then re-enable.
  const row = page.locator(".rules-table tbody tr", { hasText: "E2E domain rule" });
  await row.getByRole("button", { name: "Disable", exact: true }).click();
  await page.waitForTimeout(1400);
  let current = (await rules()).find((rule) => rule.id === created?.id);
  check("rule disabled via ui", current?.enabled === false, String(current?.enabled));
  const disabledRow = page.locator(".rules-table tbody tr.is-disabled", { hasText: "E2E domain rule" });
  check("disabled rule styled in table", (await disabledRow.count()) === 1);
  await disabledRow.getByRole("button", { name: "Enable", exact: true }).click();
  await page.waitForTimeout(1400);
  current = (await rules()).find((rule) => rule.id === created?.id);
  check("rule re-enabled via ui", current?.enabled === true, String(current?.enabled));

  // Delete.
  await page.locator('.rules-table button[title="Delete rule"]').first().click();
  await waitToast("Rule deleted");
  await page.waitForTimeout(900);
  check("rule deleted", (await rules()).length === countBeforeValidation - 1, "remaining " + (await rules()).length);
  check("empty state returns after delete", (await page.locator("text=No rules yet.").count()) === 1);
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
