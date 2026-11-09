// Capture the screenshots used by the README and docs/UI.md.
//
// The app is the real server plus the built WASM client: no mockups. The
// script creates the scratch password account, then seeds the library from
// the Netscape export in the repo root with a multipart POST to
// /api/v1/import. Set EZA_SEED_IMPORT to a different
// export path, or EZA_SEED_IMPORT=0 to fall back to the 14-bookmark demo seed.
//
// The detail shot uses the real enrichment output. A legacy fallback can seed
// a fixture directly into SQLite, but it is off by default: set
// EZA_SEED_READER=1 only when capturing a deliberately seeded demo, never for
// the checked-in reference screenshots.
//
// Run from the repo root in the dev shell, against a scratch server:
//   EZA_BASE=http://localhost:8100 EZA_DB=.eza-scratch/eza.db \
//     node tests/e2e/capture-screenshots.mjs
import { chromium } from "@playwright/test";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, isAbsolute, join, resolve } from "node:path";
import { tmpdir } from "node:os";

const BASE = process.env.EZA_BASE || "http://localhost:8100";
const OUT = process.env.EZA_SHOT_DIR || "docs/screenshots";
const IMPORT_PATH = process.env.EZA_SEED_IMPORT || "bookmarks_14_08_2026.html";
const IMPORT_ENABLED = !["0", "false", "no"].includes(String(process.env.EZA_SEED_IMPORT || "").toLowerCase());
const READER_PATH = process.env.EZA_READER_HTML || "tests/e2e/fixtures/reader.html";
const DB_PATH = process.env.EZA_DB || ".eza-scratch/eza.db";
const SEED_READER = ["1", "true", "yes"].includes(String(process.env.EZA_SEED_READER || "").toLowerCase());
const FEATURE_ID = Number(process.env.EZA_FEATURE_ID || 8226);
const VIEWPORT = { width: 1440, height: 900 };
const DPR = 2;

// The original demo library, kept as the fallback when the export is absent.
const DEMO_BOOKMARKS = [
  ["Learn You a Haskell for Great Good", "http://learnyouahaskell.com", ["haskell", "books"]],
  ["The Rust Programming Language", "https://doc.rust-lang.org/book/", ["rust", "books"]],
  ["NixOS Manual", "https://nixos.org/manual/nixos/stable/", ["nix", "reference"]],
  ["SQLite FTS5 Extension", "https://sqlite.org/fts5.html", ["sqlite", "reference"]],
  ["Miso: Haskell frontend framework", "https://haskell-miso.org", ["haskell", "web"]],
  ["Designing Data-Intensive Applications", "https://dataintensive.net", ["books", "databases"]],
  ["Excalidraw", "https://excalidraw.com", ["design", "tools"]],
  ["Tailscale", "https://tailscale.com", ["networking", "tools"]],
  ["WebAuthn Guide", "https://webauthn.guide", ["security", "web"]],
  ["The Architecture of Open Source Applications", "https://aosabook.org", ["books", "architecture"]],
  ["Haskell Language", "https://haskell.org", ["haskell"]],
  ["Nix flakes", "https://nixos.wiki/wiki/Flakes", ["nix"]],
  ["SQLite WAL mode", "https://sqlite.org/wal.html", ["sqlite", "reference"]],
  ["Command palette pattern", "https://www.nngroup.com/articles/command-palettes/", ["design", "web"]],
];

const SEL = {
  appShell: '[data-testid="app-shell"]',
  ledgerRow: '[data-testid="ledger-row"]',
  record: '[data-testid="record"]',
  accessions: '[data-testid="accessions"]',
  palette: '[data-testid="palette"]',
  paletteInput: "#palette-input",
  themeToggle: '[data-testid="theme-toggle"]',
  readerText: "#reader-text",
  readerMark: '[data-testid="reader-mark"]',
  highlightRow: '[data-testid="highlight-row"]',
  sharePage: '[data-testid="share-page"]',
  passwordLogin: "#password-login",
};

mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({
  viewport: VIEWPORT,
  deviceScaleFactor: DPR,
  colorScheme: "light",
  reducedMotion: "reduce",
});
const page = await context.newPage();
const pageErrors = [];
page.on("pageerror", (error) => pageErrors.push(String(error)));
page.on("console", (message) => {
  if (message.type() === "error") pageErrors.push(message.text());
});

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

async function cookieValue(name) {
  const cookies = await context.cookies(BASE);
  return cookies.find((entry) => entry.name === name)?.value || "";
}

// API calls run inside the page so they use the same session cookie and
// CSRF token as the client.
async function pageFetch(path, method = "GET", body = undefined) {
  const result = await page.evaluate(
    async ({ path, method, body }) => {
      const csrf =
        document.cookie
          .split("; ")
          .find((item) => item.startsWith("eza_csrf="))
          ?.split("=")[1] || "";
      const headers = { "Content-Type": "application/json" };
      if (csrf) headers["X-CSRF-Token"] = csrf;
      const response = await fetch(path, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      return { status: response.status, text: await response.text() };
    },
    { path, method, body }
  );
  let parsed = null;
  try {
    parsed = JSON.parse(result.text);
  } catch (_) {
    parsed = result.text.slice(0, 240);
  }
  return { status: result.status, body: parsed };
}

async function postJson(path, body, method = "POST") {
  return pageFetch(path, method, body);
}

async function getJson(path) {
  return pageFetch(path, "GET");
}

async function settle(milliseconds = 400) {
  await page.waitForTimeout(milliseconds);
  await page.evaluate(() => document.fonts.ready);
}

async function shot(name, clip) {
  await settle();
  await page.screenshot({ path: join(OUT, name + ".png"), ...(clip ? { clip } : {}) });
  console.log("captured " + join(OUT, name + ".png"));
}

async function enterLibrary() {
  await page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
  if (page.url().includes("/setup")) {
    await page.fill("#username", process.env.EZA_TEST_USER || "e2e");
await page.fill("#password", process.env.EZA_TEST_PASSWORD || "e2e-password-123");
await page.fill("#confirm-password", process.env.EZA_TEST_PASSWORD || "e2e-password-123");
await page.click("#password-setup");
    await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
    await page.click("#continue");
  } else if (page.url().includes("/login")) {
    await page.fill("#username", process.env.EZA_TEST_USER || "e2e");
    await page.fill("#password", process.env.EZA_TEST_PASSWORD || "e2e-password-123");
    await page.click("#password-login");
  }
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });
}

async function importExport() {
  const file = isAbsolute(IMPORT_PATH) ? IMPORT_PATH : resolve(IMPORT_PATH);
  if (!IMPORT_ENABLED || !existsSync(file)) return false;
  const buffer = readFileSync(file);
  const csrf = await cookieValue("eza_csrf");
  const response = await context.request.post(BASE + "/api/v1/import", {
    multipart: {
      file: { name: basename(file), mimeType: "text/html", buffer },
    },
    headers: { "X-CSRF-Token": csrf },
    timeout: 180000,
    failOnStatusCode: false,
  });
  const text = await response.text();
  let report = null;
  try {
    report = JSON.parse(text);
  } catch (_) {
    report = text.slice(0, 200);
  }
  console.log("import", response.status(), JSON.stringify(report).slice(0, 240));
  return response.ok();
}

async function seedDemo() {
  for (const [title, url, tags] of DEMO_BOOKMARKS) {
    const response = await postJson("/api/v1/bookmarks", { url, title, tags });
    if (response.status !== 201) {
      console.log("demo seed failed", response.status, url);
      return;
    }
  }
  const listing = await getJson("/api/v1/bookmarks?limit=2&offset=0");
  const items = listing.body?.items || [];
  if (items.length >= 2) {
    await postJson("/api/v1/bookmarks/" + items[0].id, {
      note_body:
        "A gentle introduction to Haskell. The examples build from recursion to monads, and the exercises are short enough to finish in one sitting.\n\nSee [[The Rust Programming Language]] for a systems contrast.",
    });
    await postJson("/api/v1/bookmarks/" + items[1].id, {
      note_body: "Ownership and borrowing compared with [[Learn You a Haskell for Great Good]].",
    });
  }
}

async function librarySize() {
  const boot = await getJson("/api/v1/boot");
  return boot.body?.initial?.total ?? 0;
}

// Read the real captured article used by the design package and turn it into
// clean reading text (the library extractor output for long pages is noisy).
function readerText() {
  const file = isAbsolute(READER_PATH) ? READER_PATH : resolve(READER_PATH);
  if (!existsSync(file)) return null;
  const html = readFileSync(file, "utf8");
  const article = (html.split(/<article[^>]*>/i)[1] || html).split(/<\/article>/i)[0];
  const chunks = [...article.matchAll(/<p[^>]*>([\s\S]*?)<\/p>/gi)].map((match) => match[1]);
  const clean = (value) =>
    value
      .replace(/<[^>]+>/g, " ")
      .replace(/&nbsp;/g, " ")
      .replace(/&amp;/g, "&")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&quot;/g, '"')
      .replace(/&#39;|&rsquo;/g, "'")
      .replace(/&lsquo;/g, "'")
      .replace(/&ldquo;/g, '"')
      .replace(/&rdquo;/g, '"')
      .replace(/&mdash;/g, "-")
      .replace(/&ndash;/g, "-")
      .replace(/\s+/g, " ")
      .trim();
  const paragraphs = chunks.map(clean).filter((text) => text.length > 90);
  if (!paragraphs.length) return null;
  const selected = paragraphs.slice(0, 60);
  return {
    text: selected.join("\n\n"),
    words: selected.join(" ").split(/\s+/).length,
  };
}

function sqlString(value) {
  return "'" + String(value).replace(/'/g, "''") + "'";
}

function seedReaderRecord(text, minutes) {
  const db = isAbsolute(DB_PATH) ? DB_PATH : resolve(DB_PATH);
  if (!existsSync(db)) return false;
  const temp = join(tmpdir(), "eza-reader-" + process.pid + ".txt");
  writeFileSync(temp, text, "utf8");
  try {
    execFileSync("sqlite3", [
      db,
      "update bookmarks set " +
        "extracted_text = cast(readfile(" + sqlString(temp) + ") as text), " +
        "reading_time_minutes = " + Number(minutes) + ", " +
        "author = " + sqlString("Karl Zylinski") + ", " +
        "sitename = " + sqlString("zylinski.se") + ", " +
        "enrich_state = 'ok' " +
        "where id = " + FEATURE_ID + ";",
    ]);
    return true;
  } catch (error) {
    console.log("reader seed skipped:", String(error).slice(0, 120));
    return false;
  }
}

const JUNK = /(function\s*\(|window\.|document\.|@media|\{--|static\/chunks|\{"@context|@font-face)/;

async function cleanExtractedText(detail) {
  const text = detail?.extracted_text || "";
  const paragraphs = text.split(/\n\n+/).filter((part) => part.trim());
  return text.length > 800 && paragraphs.length >= 3 && !JUNK.test(text.slice(0, 3000));
}

// The ledger shots use the literature shelf by default: a full-library
// screenshot can surface private or explicit records that have no place in the
// public README. EZA_SHOT_QUERY can still narrow or widen the slice.
const LIBRARY_QUERY = process.env.EZA_SHOT_QUERY || "tag:literature";

async function showLedger() {
  await page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });
  await page.waitForSelector(SEL.ledgerRow, { timeout: 30000 });
  if (LIBRARY_QUERY) {
    await page.fill("#search-input", LIBRARY_QUERY);
    await page
      .waitForFunction(
        () => {
          const count = document.querySelector(".ledg-countgroup");
          const rows = document.querySelectorAll('[data-testid="ledger-row"]').length;
          return Boolean(count && /in all/.test(count.textContent) && rows > 0);
        },
        null,
        { timeout: 20000 }
      )
      .catch(() => {});
    await page.waitForTimeout(900);
  }
}

async function ensureReaderText() {
  let detail = (await getJson("/api/v1/bookmarks/" + FEATURE_ID)).body || {};
  if (await cleanExtractedText(detail)) return detail;

  // Try the real extractor first.
  const enrich = await postJson("/api/v1/bookmarks/" + FEATURE_ID + "/enrich", {});
  if (enrich.status === 200) {
    for (let attempt = 0; attempt < 8; attempt++) {
      await page.waitForTimeout(1500);
      detail = (await getJson("/api/v1/bookmarks/" + FEATURE_ID)).body || {};
      if (await cleanExtractedText(detail)) return detail;
    }
  }

  if (SEED_READER) {
    const reader = readerText();
    if (reader && seedReaderRecord(reader.text, Math.max(1, Math.round(reader.words / 238)))) {
      console.log("seeded the reader text from " + READER_PATH);
      return (await getJson("/api/v1/bookmarks/" + FEATURE_ID)).body || {};
    }
  }
  return detail;
}

// Three readable passages: one sentence each, inside the seeded paragraphs.
function highlightRanges(text) {
  const paragraphs = [];
  let cursor = 0;
  for (const part of text.split("\n\n")) {
    paragraphs.push({ start: cursor, text: part });
    cursor += part.length + 2;
  }
  const ranges = [];
  const wanted = [1, 3, 5, 2, 4, 6];
  for (const index of wanted) {
    const paragraph = paragraphs[index];
    if (!paragraph) continue;
    const sentence = paragraph.text.match(/[A-Z][^.!?]{80,220}[.!?]/);
    if (!sentence) continue;
    const quote = sentence[0].trim();
    const inner = paragraph.text.indexOf(quote);
    if (inner < 0) continue;
    const start = paragraph.start + inner;
    ranges.push({
      quote,
      start,
      end: start + quote.length,
      prefix: text.slice(Math.max(0, start - 40), start),
      suffix: text.slice(start + quote.length, start + quote.length + 40),
    });
    if (ranges.length === 3) break;
  }
  return ranges;
}

async function prepareFeature() {
  const detail = await ensureReaderText();
  if (!detail?.extracted_text) {
    console.log("no readable text for record " + FEATURE_ID + "; using the record as stored");
    return;
  }

  // A real wikilink to another record, so the note renders like the design.
  const listing = await getJson("/api/v1/bookmarks?q=" + encodeURIComponent("case of blackness") + "&limit=10&offset=0");
  const linked = (listing.body?.items || []).find(
    (item) => item.title && !/[\[\]|]/.test(item.title) && item.title.length <= 72
  );
  const linkTitle = linked?.title || "The Case of Blackness";
  const noteBody =
    "Filed while re-reading. The argument returns to [[".concat(linkTitle, "]] more than once, ") +
    "and the catalogue record is the better place to keep the thread.";
  const patch = await postJson("/api/v1/bookmarks/" + FEATURE_ID, { note_body: noteBody }, "PATCH");
  if (patch.status !== 200) console.log("note patch", patch.status);

  // Two or three real highlights through the API, in the three mark styles.
  const existing = await getJson("/api/v1/bookmarks/" + FEATURE_ID + "/highlights");
  const highlights = existing.body?.highlights || [];
  if (highlights.length === 0) {
    const ranges = highlightRanges(detail.extracted_text);
    const styles = ["yellow", "green", "blue"];
    const notes = ["", "The clearest statement of the problem.", ""];
    for (let i = 0; i < ranges.length; i++) {
      const range = ranges[i];
      const response = await postJson("/api/v1/bookmarks/" + FEATURE_ID + "/highlights", {
        quote: range.quote,
        prefix: range.prefix,
        suffix: range.suffix,
        start_offset: range.start,
        end_offset: range.end,
        note: notes[i % notes.length],
        color: styles[i % styles.length],
      });
      console.log("highlight", i + 1, response.status, range.quote.slice(0, 48) + "...");
    }
  }
}

try {
  await enterLibrary();

  const before = await librarySize();
  const seeded = await importExport();
  if (seeded) {
    console.log("seeding the README set from the real export (" + before + " entries before)");
  } else if (before < DEMO_BOOKMARKS.length) {
    console.log("no export found, seeding the 14-bookmark demo set");
    await seedDemo();
    await page.reload({ waitUntil: "domcontentloaded" });
    await page.waitForSelector(SEL.appShell, { timeout: 30000 });
  } else {
    console.log("using the library already on the server (" + before + " entries)");
  }

  // library.png: the ledger with a representative real query.
  await showLedger();
  await shot("library");

  // detail.png: the record with the reading spread, its note and its marks.
  await prepareFeature();
  await page.goto(BASE + "/bookmark/" + FEATURE_ID, { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });
  await page.waitForSelector(SEL.record, { timeout: 30000 });
  await page.waitForSelector(SEL.readerText, { timeout: 20000 });
  await page
    .waitForFunction(
      (selector) => document.querySelectorAll(selector).length >= 3,
      SEL.readerMark,
      { timeout: 20000 }
    )
    .catch(() => {});
  await shot("detail");

  // accessions.png: the printed index route.
  await page.goto(BASE + "/accessions", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.accessions, { timeout: 30000 });
  // Keep the public index shot above the ranked-source list: that list can
  // contain private saves that have no place in a public repository.
  const filing = await page.locator(".accessions .mc").boundingBox();
  const accessionsHeight = filing
    ? Math.max(560, Math.min(900, Math.floor(filing.y + filing.height + 24)))
    : 700;
  await shot("accessions", { x: 0, y: 0, width: VIEWPORT.width, height: accessionsHeight });

  // palette.png: the command palette over the same ledger.
  await showLedger();
  await page.evaluate(() => document.activeElement && document.activeElement.blur());
  await page.keyboard.press("Shift+K");
  await page.waitForSelector(SEL.paletteInput, { timeout: 10000 });
  await page.waitForSelector(SEL.palette, { timeout: 10000 });
  await shot("palette");
  await page.keyboard.press("Escape");

  // dark.png: the reading-room theme, switched with the real control.
  await page.locator(SEL.themeToggle).click();
  await page.waitForFunction(() => document.documentElement.getAttribute("data-theme") === "dark", null, { timeout: 10000 });
  await shot("dark");

  // share.png: a server-rendered read-only share page for the featured record.
  // The share page is rendered by the server but inherits the stored theme;
  // return to paper so the public page is shown in the default theme.
  await page.evaluate(() => {
    try {
      window.localStorage.setItem("eza-theme", "light");
    } catch (_) {}
  });
  const shareResponse = await postJson("/api/v1/share-links", {
    scope: "bookmark",
    target_id: FEATURE_ID,
    include_note: true,
    expires_in_days: 30,
  });
  const share = shareResponse.body || {};
  const rawPath = share.url || (share.token ? "/s/" + share.token : null);
  const shareUrl = rawPath ? (/^https?:/.test(rawPath) ? rawPath : BASE + rawPath) : null;
  if (!shareUrl) throw new Error("could not create a share link: " + JSON.stringify(share).slice(0, 200));
  await page.goto(shareUrl, { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.sharePage, { timeout: 30000 });
  await shot("share");

  // login.png: the sign-in card, in a context with no session cookie.
  const anonymous = await browser.newContext({
    viewport: VIEWPORT,
    deviceScaleFactor: DPR,
    colorScheme: "light",
    reducedMotion: "reduce",
  });
  const loginPage = await anonymous.newPage();
  await loginPage.goto(BASE + "/login", { waitUntil: "domcontentloaded" });
  await loginPage.waitForSelector(SEL.passwordLogin, { timeout: 30000 });
  await loginPage.evaluate(() => document.fonts.ready);
  await loginPage.waitForTimeout(400);
  await loginPage.screenshot({ path: join(OUT, "login.png") });
  console.log("captured " + join(OUT, "login.png"));
  await anonymous.close();

  if (pageErrors.length) {
    console.log("page errors (" + pageErrors.length + "):");
    for (const error of pageErrors.slice(0, 8)) console.log("  " + error);
    process.exitCode = 1;
  } else {
    console.log("captured 7 screenshots in " + OUT);
  }
} finally {
  await browser.close();
}
