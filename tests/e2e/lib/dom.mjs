// Shared selectors and helpers for the Direction B end-to-end scripts.
//
// The production views are Miso markup built from the catalogue design. The
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

  accountUsersTab: '[data-testid="account-users-tab"]',
  accountWebhooksTab: '[data-testid="webhooks-tab"]',
  usersTable: '[data-testid="users-table"]',
  userRow: '[data-testid="user-row"]',
  userName: '[data-testid="user-name"]',
  userPassword: '[data-testid="user-password"]',
  userRole: '[data-testid="user-role"]',
  userCreate: '[data-testid="user-create"]',
  userFormError: '[data-testid="user-form-error"]',
  userActionError: '[data-testid="user-action-error"]',
  userRecoveryCodes: '[data-testid="user-recovery-codes"]',
  userDisable: '[data-testid="user-disable"]',
  userEnable: '[data-testid="user-enable"]',
  userResetOpen: '[data-testid="user-reset-open"]',
  userResetPassword: '[data-testid="user-reset-password"]',
  userResetSubmit: '[data-testid="user-reset-submit"]',
  userResetShown: '[data-testid="user-reset-shown"]',

  addUrl: "#add-url",
  addTitle: "#add-title",
  addTags: "#add-tags",
  saveUrl: "#save-url",
  saveTitle: "#save-title",
  saveTags: "#save-tags",
  accessions: '[data-testid="accessions"]',
  accessionsYear: (year) => `[data-testid="accessions-year"][data-year="${year}"]`,
  accessionsYears: '[data-testid="accessions-year"]',
  accessionsDay: (day) => `[data-testid="accessions-day"][data-day="${day}"]`,
  accessionsDays: '[data-testid="accessions-day"]',
  accessionsSource: (source) => `[data-testid="accessions-source"][data-source="${source}"]`,
  accessionsSources: '[data-testid="accessions-source"]',
  accessionsBusiest: (day) => `[data-testid="accessions-busiest"][data-day="${day}"]`,
  accessionsBusiestRows: '[data-testid="accessions-busiest"]',
  aiBanner: '[data-testid="ai-banner"]',

  graph: '[data-testid="graph"]',
  graphFilter: "#graph-filter",
  graphPlate: ".g-plate",
  graphCanvas: "canvas.g-canvas-el",
  graphStatus: '[data-testid="graph-status"]',
  graphStatusMain: '[data-testid="graph-status-main"]',
  graphResults: '[data-testid="graph-results"]',
  graphResult: '[data-testid="graph-result"]',
  graphAside: '[data-testid="graph-aside"]',
  graphPreview: '[data-testid="graph-preview"]',
  graphZoomIn: '[data-testid="graph-zoom-in"]',
  graphZoomOut: '[data-testid="graph-zoom-out"]',
  graphFit: '[data-testid="graph-fit"]',
  graphZoomValue: '[data-testid="graph-zoom-value"]',
  graphTagsToggle: '[data-testid="graph-tags-toggle"]',
  graphTag: '[data-testid="graph-tag"]',
  graphRoot: '[data-testid="graph-root"]',
  graphLabelCount: '[data-testid="graph-label-count"]',
  graphLegend: '[data-testid="graph-legend"]',
  graphPreset: '[data-testid="graph-preset"]',
  graphPresetCompact: '[data-testid="graph-preset-compact"]',
  graphPresetStandard: '[data-testid="graph-preset-standard"]',
  graphPresetAiry: '[data-testid="graph-preset-airy"]',
  graphLocalToggle: '[data-testid="graph-local-toggle"]',
  graphLocalDepth: '[data-testid="graph-local-depth"]',
  graphScopeWhole: '[data-testid="graph-scope-whole"]',
  graphDepth: (depth) => `[data-testid="graph-depth-${depth}"]`,
  graphSettings: '[data-testid="graph-settings"]',
  graphGroupEdit: '[data-testid="graph-group-edit"]',
  graphGroupEditor: '[data-testid="graph-group-editor"]',
  graphGroupRow: '[data-testid="graph-group-row"]',
  graphGroupAdd: '[data-testid="graph-group-add"]',
  graphGroupName: ".g-group-name",
  graphGroupQuery: ".g-group-query",
  graphGroupColor: ".g-group-color",
  graphGroupsSave: '[data-testid="view-groups-save"]',
  graphGroupsCancel: '[data-testid="view-groups-cancel"]',
  openGraph: '[data-testid="open-graph"]',

  viewsPage: '[data-testid="views-page"]',
  viewRow: '[data-testid="view-row"]',
  viewOpen: '[data-testid="view-open"]',
  viewDefault: '[data-testid="view-default"]',
  viewDefaultBadge: '[data-testid="view-default-badge"]',
  viewDelete: '[data-testid="view-delete"]',
  viewCreate: '[data-testid="view-create"]',
  viewImport: '[data-testid="view-import"]',
  viewRename: '[data-testid="view-rename"]',
  viewDuplicate: '[data-testid="view-duplicate"]',
  viewExport: '[data-testid="view-export"]',
  viewExportDialog: '[data-testid="view-export-dialog"]',
  viewExportText: '[data-testid="view-export-text"]',
  viewExportClose: '[data-testid="view-export-close"]',
  viewImportDialog: '[data-testid="view-import-dialog"]',
  viewImportText: '[data-testid="view-import-text"]',
  viewImportSubmit: '[data-testid="view-import-submit"]',
  viewSaveDialog: '[data-testid="view-save-dialog"]',
  viewNameInput: '[data-testid="view-name-input"]',
  viewSaveSubmit: '[data-testid="view-save-submit"]',
  viewSaveCancel: '[data-testid="view-save-cancel"]',
  viewSaveGraph: '[data-testid="view-save-graph"]',
  viewSaveAs: '[data-testid="view-save-as"]',
  viewSaveCurrent: '[data-testid="view-save-current"]',
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

// Claim the first account on a fresh installation or sign in to an existing
// one. Leaves the ledger mounted and returns when the app shell has painted.
export async function enterLibraryAs(page, username, password) {
  await page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
  if (page.url().includes("/setup")) {
    await page.fill("#username", username);
    await page.fill("#password", password);
    await page.fill("#confirm-password", password);
    await page.click("#password-setup");
    await page.waitForSelector("#recovery:not([hidden])", { timeout: 60000 });
    await page.click("#continue");
  } else if (page.url().includes("/login")) {
    if (await page.locator("#password-login").count()) {
      await page.fill("#username", username);
      await page.fill("#password", password);
      await page.click("#password-login");
    } else {
      await page.click("#passkey-login");
    }
  }
  await page.waitForSelector(SEL.appShell, { timeout: 60000 });
}

// Sign in as the harness account, with the first-run setup fallback kept for
// scripts that claim a fresh installation.
export async function enterLibrary(page) {
  return enterLibraryAs(page, TEST_USER, TEST_PASSWORD);
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
