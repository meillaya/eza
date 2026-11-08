// Rules UI smoke test: account section, empty state, dry run (match and no
// match), create, validation, enable/disable, delete, and rules applying on
// save.
//
// Run from the repo root in the dev shell, against a scratch server:
//   EZA_BASE=http://localhost:8100 node tests/e2e/rules-ui-smoke.mjs
import { BASE, SEL, launchBrowser, launchPage, enterLibrary, makeApi, newChecker } from "./lib/dom.mjs";

const browser = await launchBrowser();
const { page, errors } = await launchPage(browser, { viewport: { width: 1440, height: 1000 } });
const { check, report } = newChecker();
const api = makeApi(page);

async function rules() {
  return (await api("/api/v1/rules")).body?.rules || [];
}

async function openRules() {
  await page.goto(BASE + "/account", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });
  await page.click(SEL.accountTab("rules"));
  await page.waitForSelector(SEL.accountPanel("rules"), { timeout: 20000 });
  await page.waitForTimeout(400);
}

async function showForm() {
  if ((await page.locator(SEL.ruleName).count()) === 0) {
    await page.getByRole("button", { name: /create a rule|new rule/i }).first().click();
    await page.waitForTimeout(300);
  }
  await page.waitForSelector(SEL.ruleName, { timeout: 20000 });
}

async function waitToast(pattern) {
  await page
    .waitForFunction(
      (source) => [...document.querySelectorAll('[data-testid="toast"]')].some((toast) => new RegExp(source).test(toast.textContent)),
      pattern,
      { timeout: 20000 }
    )
    .catch(() => {});
}

try {
  await enterLibrary(page);
  await openRules();

  check("rules panel present", (await page.locator(SEL.accountPanel("rules")).count()) === 1);
  check("rules empty state", (await page.getByText(/no rules yet/i).count()) > 0);

  // Use the hostname of an existing bookmark so the dry run always matches.
  let sampleUrl = (await api("/api/v1/bookmarks?limit=1&offset=0")).body?.items?.[0]?.url || "";
  if (!sampleUrl) {
    const seeded = await api("/api/v1/bookmarks", {
      method: "POST",
      body: JSON.stringify({ url: "https://dry-run.example/seed", title: "Dry run seed" }),
    });
    sampleUrl = (await api("/api/v1/bookmarks/" + seeded.body.id)).body?.url || "";
  }
  const sampleHost = await page.evaluate((url) => new URL(url).hostname, sampleUrl);
  check("sample hostname for dry run", Boolean(sampleHost), sampleHost);

  await showForm();
  await page.selectOption("#rule-field", "domain");
  await page.fill(SEL.rulePattern, sampleHost);
  await page.locator(SEL.ruleDryRun).click();
  await page.waitForSelector(SEL.ruleResult, { timeout: 20000 });
  await page
    .waitForFunction(
      () => {
        const element = document.querySelector('[data-testid="rule-result"]');
        return Boolean(element && !/no run yet/i.test(element.textContent) && /\d/.test(element.textContent));
      },
      null,
      { timeout: 20000 }
    )
    .catch(() => {});
  const dryRunText = (await page.locator(SEL.ruleResult).innerText()).trim();
  const dryRunMatches = Number((dryRunText.match(/(\d+)/) || [])[1] || 0);
  check("dry run reports matches", dryRunMatches > 0, dryRunText.replace(/\n+/g, " ") + " (pattern " + sampleHost + ")");

  // Dry run with no matches.
  await page.fill(SEL.rulePattern, "zzz-no-match-zzz");
  await page.locator(SEL.ruleDryRun).click();
  await page
    .waitForFunction(
      () => {
        const element = document.querySelector('[data-testid="rule-result"]');
        return Boolean(element && /\b0\b/.test(element.textContent));
      },
      null,
      { timeout: 20000 }
    )
    .catch(() => {});
  const zeroText = (await page.locator(SEL.ruleResult).innerText()).trim();
  check("dry run reports zero matches", /(^|\D)0(\D|$)/.test(zeroText), zeroText.replace(/\n+/g, " ").slice(0, 80));

  // Create a rule.
  const ruleDomain = "rule-smoke-" + Date.now() + ".example";
  await page.fill(SEL.ruleName, "E2E domain rule");
  await page.selectOption("#rule-field", "domain");
  await page.fill(SEL.rulePattern, ruleDomain);
  await page.fill(SEL.ruleTags, "rule-a, rule-b");
  const markRead = page.locator(SEL.ruleMarkRead);
  const hasMarkRead = (await markRead.count()) > 0;
  if (hasMarkRead) await markRead.evaluate((element) => element.click());
  await page.locator(SEL.ruleCreate).click();
  await waitToast("created");
  await page.waitForSelector(SEL.rulesTable, { timeout: 20000 }).catch(() => {});
  let created = null;
  for (let attempt = 0; attempt < 12; attempt++) {
    await page.waitForTimeout(400);
    created = (await rules()).find((rule) => rule.name === "E2E domain rule");
    if (created) break;
  }
  check("rule created via ui", Boolean(created), JSON.stringify(await rules()).slice(0, 180));
  check(
    "rule fields stored",
    created?.field === "domain" && created?.pattern === ruleDomain && created?.enabled === true,
    JSON.stringify({ field: created?.field, pattern: created?.pattern, enabled: created?.enabled })
  );
  if (hasMarkRead) check("rule mark-read stored", created?.mark_read === true, String(created?.mark_read));
  check(
    "rule tags stored",
    JSON.stringify(created?.add_tags || []) === JSON.stringify(["rule-a", "rule-b"]),
    JSON.stringify(created?.add_tags)
  );
  const listed = page.locator(SEL.ruleRow, { hasText: "E2E domain rule" });
  check("rule listed in the panel", (await listed.count()) === 1);

  // Rules actually apply on save.
  const bookmarkUrl = "https://" + ruleDomain + "/saved";
  const added = await api("/api/v1/bookmarks", {
    method: "POST",
    body: JSON.stringify({ url: bookmarkUrl, title: "Rule smoke" }),
  });
  const addedId = added.body?.id;
  const addedDetail = addedId ? await api("/api/v1/bookmarks/" + addedId) : { body: {} };
  const tags = addedDetail.body?.tags || [];
  check("rule applies tags on save", tags.includes("rule-a") && tags.includes("rule-b"), JSON.stringify(tags));

  // Validation: an empty pattern is not accepted.
  const countBeforeValidation = (await rules()).length;
  await page.fill(SEL.ruleName, "");
  await page.fill(SEL.rulePattern, "");
  await page.locator(SEL.ruleCreate).click();
  await page.waitForTimeout(700);
  check("create validates required fields", (await rules()).length === countBeforeValidation);

  // Disable then re-enable.
  await page.fill(SEL.ruleName, "E2E domain rule");
  await page.fill(SEL.rulePattern, ruleDomain);
  await listed.locator(SEL.ruleToggle).click();
  let current = null;
  for (let attempt = 0; attempt < 12; attempt++) {
    await page.waitForTimeout(400);
    current = (await rules()).find((rule) => rule.id === created?.id);
    if (current?.enabled === false) break;
  }
  check("rule disabled via ui", current?.enabled === false, String(current?.enabled));
  await listed.locator(SEL.ruleToggle).click();
  for (let attempt = 0; attempt < 12; attempt++) {
    await page.waitForTimeout(400);
    current = (await rules()).find((rule) => rule.id === created?.id);
    if (current?.enabled === true) break;
  }
  check("rule re-enabled via ui", current?.enabled === true, String(current?.enabled));

  // Delete.
  await listed.locator(SEL.ruleDelete).click();
  await waitToast("deleted");
  for (let attempt = 0; attempt < 12; attempt++) {
    await page.waitForTimeout(400);
    if ((await rules()).length === countBeforeValidation - 1) break;
  }
  check("rule deleted", (await rules()).length === countBeforeValidation - 1, "remaining " + (await rules()).length);
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
