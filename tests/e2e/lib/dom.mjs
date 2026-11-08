// Shared selectors and helpers for the Direction B end-to-end scripts.
//
// The production views are Miso markup built from design/b-catalogue. The
// stable hooks are the data-testid names in SEL; ids that the server pages
// keep (#search-input, auth ids) are used directly. If a view renames a hook,
// update it here once instead of in every script.
import { chromium } from "@playwright/test";

export const BASE = process.env.EZA_BASE || "http://localhost:8100";

export const SEL = {
  appShell: '[data-testid="app-shell"]',
  mast: '[data-testid="mast"]',
  sections: '[data-testid="sections"]',
  section: (name) => `[data-testid="section-${name}"]`,
  search: "#search-input",
  palette: '[data-testid="palette"]',
  paletteInput: "#palette-input",
  paletteRow: '[data-testid="palette-row"]',
  themeToggle: '[data-testid="theme-toggle"]',
  toast: '[data-testid="toast"]',
  offlineBanner: ".offline-banner",
  installFab: ".install-fab",

  ledger: '[data-testid="ledger"], .ledger-wrap',
  row: '[data-testid="ledger-row"]',
  rowById: (id) => `[data-testid="ledger-row"][data-bookmark-id="${id}"]`,
  rowTitle: '[data-testid="ledger-row-title"]',
  rowSelect: '[data-testid="ledger-row-select"]',
  rowSelectFor: (id) => `[data-testid="ledger-row"][data-bookmark-id="${id}"] [data-testid="ledger-row-select"]`,
  selectionBar: '[data-testid="selection-bar"]',
  selectionCount: '[data-testid="selection-count"]',
  drawer: '[data-testid="drawer"]',

  dialog: '[data-testid="dialog"]',
  dialogBody: '[data-testid="dialog-body"]',
  dialogConfirm: '[data-testid="dialog-confirm"]',
  dialogCancel: '[data-testid="dialog-cancel"]',
  bulkTagInput: '#bulk-tag-input',

  record: '[data-testid="record"]',
  readerText: "#reader-text",
  readerMark: '[data-testid="reader-mark"]',
  highlightToolbar: '[data-testid="highlight-toolbar"]',
  highlightRow: '[data-testid="highlight-row"]',
  highlightEdit: '[data-testid="highlight-edit"]',
  highlightDelete: '[data-testid="highlight-delete"]',
  highlightNote: "#highlight-note",
  highlightEditNote: "#highlight-edit-note",
  highlightStyle: (name) => `[data-testid="highlight-style-${name}"]`,
  snapshotOpen: '[data-testid="snapshot-open"]',
  snapshotFrame: '[data-testid="snapshot-frame"]',
  snapshotClose: '[data-testid="snapshot-close"]',

  shareDialog: '[data-testid="dialog-share"]',
  shareCreate: '[data-testid="share-create"]',
  shareReveal: '[data-testid="share-reveal"]',
  shareUrl: '[data-testid="share-url"]',
  shareCopy: '[data-testid="share-copy"]',
  shareIncludeNote: '[data-testid="share-include-note"]',
  shareExpiry: "#share-expiry",
  shareRow: '[data-testid="share-row"]',
  shareRevoke: '[data-testid="share-revoke"]',
  sharePage: '[data-testid="share-page"]',
  shareUnavailable: '[data-testid="share-unavailable"]',

  accountTab: (name) => `[data-testid="account-tab-${name}"]`,
  accountPanel: (name) => `[data-testid="account-panel-${name}"]`,
  tokenName: "#token-name",
  tokenScope: (name) => `[data-testid="token-scope-${name}"]`,
  tokenCreate: '[data-testid="token-create"]',
  tokenReveal: '[data-testid="token-reveal"]',
  tokenSecret: '[data-testid="token-secret"]',
  tokenRow: '[data-testid="token-row"]',
  tokenRevoke: '[data-testid="token-revoke"]',
  tokenEmpty: '[data-testid="token-empty"]',
  ruleName: "#rule-name",
  rulePattern: "#rule-pattern",
  ruleTags: "#rule-tags",
  ruleMarkRead: '[data-testid="rule-mark-read"]',
  ruleDryRun: '[data-testid="rule-dry-run"]',
  ruleResult: '[data-testid="rule-result"]',
  rulesTable: '[data-testid="rules-table"]',
  ruleRow: '[data-testid="rule-row"]',
  ruleToggle: '[data-testid="rule-toggle"]',
  ruleDelete: '[data-testid="rule-delete"]',
  ruleCreate: '[data-testid="rule-create"]',
  shareLinkRow: '[data-testid="share-link-row"]',
  shareLinkRevoke: '[data-testid="share-link-revoke"]',
  captureBox: '[data-testid="capture-box"]',

  addUrl: "#add-url",
  addTitle: "#add-title",
  addTags: "#add-tags",
  saveUrl: "#save-url",
  saveTitle: "#save-title",
  saveTags: "#save-tags",
  accessions: '[data-testid="accessions"]',
  aiBanner: '[data-testid="ai-banner"]',
};

// Attach a virtual WebAuthn authenticator so passkey ceremonies complete
// without a real platform authenticator.
export async function enableWebAuthn(context, page) {
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.enable", { enableUI: false });
  await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2",
      transport: "internal",
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true,
    },
  });
  return cdp;
}

const TEST_USER = process.env.EZA_TEST_USER || "e2e";
const TEST_PASSWORD = process.env.EZA_TEST_PASSWORD || "e2e-password-123";

// First-run setup (or login when the scratch database is already claimed).
// Leaves the ledger mounted and returns when the app shell has painted.
export async function enterLibrary(page) {
  await page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
  if (page.url().includes("/setup")) {
    await page.fill("#username", TEST_USER);
    await page.fill("#password", TEST_PASSWORD);
    await page.fill("#confirm-password", TEST_PASSWORD);
    await page.click("#password-setup");
    await page.waitForSelector("#recovery:not([hidden])", { timeout: 60000 });
    await page.click("#continue");
  } else if (page.url().includes("/login")) {
    if (await page.locator("#password-login").count()) {
      await page.fill("#username", TEST_USER);
      await page.fill("#password", TEST_PASSWORD);
      await page.click("#password-login");
    } else {
      await page.click("#passkey-login");
    }
  }
  await page.waitForSelector(SEL.appShell, { timeout: 60000 });
}

// Cookie-authenticated JSON API call from inside the page, mirroring the
// scripts' original helper: CSRF header for unsafe methods.
export function makeApi(page) {
  return (path, options = {}) =>
    page.evaluate(
      async ({ path, options }) => {
        const csrf =
          document.cookie
            .split("; ")
            .find((c) => c.startsWith("eza_csrf="))
            ?.split("=")[1] || "";
        const headers = { "Content-Type": "application/json", ...(options.headers || {}) };
        if ((options.method || "GET") !== "GET") headers["X-CSRF-Token"] = csrf;
        const response = await fetch(path, { ...options, headers });
        let body = null;
        try {
          body = await response.json();
        } catch (_) {
          body = null;
        }
        return { status: response.status, body };
      },
      { path, options }
    );
}

export function attachErrors(page) {
  const errors = [];
  page.on("console", (message) => {
    if (message.type() === "error") errors.push(message.text());
  });
  page.on("pageerror", (error) => errors.push(String(error)));
  return errors;
}

export function newChecker() {
  const passed = [];
  const failed = [];
  function check(name, condition, detail) {
    const line = detail ? name + " - " + detail : name;
    if (condition) {
      passed.push(name);
      console.log("PASS " + line);
    } else {
      failed.push(line);
      console.log("FAIL " + line);
    }
    return Boolean(condition);
  }
  function report(consoleErrors = []) {
    console.log("");
    console.log("passed: " + passed.length + ", failed: " + failed.length);
    if (consoleErrors.length) {
      console.log("console errors (" + consoleErrors.length + "):");
      for (const error of consoleErrors.slice(0, 10)) console.log("  " + error);
    }
    if (failed.length) {
      console.log("failures:");
      for (const failure of failed) console.log("  - " + failure);
      process.exitCode = 1;
    }
  }
  return { check, report, passed, failed };
}

// One page, one context and one virtual authenticator: the common preamble.
export async function launchPage(browser, options = {}) {
  const context = await browser.newContext({
    viewport: { width: 1440, height: 950 },
    ...options,
  });
  const page = await context.newPage();
  const errors = attachErrors(page);
  await enableWebAuthn(context, page);
  return { context, page, errors };
}

export async function launchBrowser() {
  return chromium.launch({ headless: true });
}
