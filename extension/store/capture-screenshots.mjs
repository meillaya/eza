// Capture the three Chrome Web Store screenshots.
//
//   node extension/store/capture-screenshots.mjs
//
// Requirements: Node, the repository @playwright/test dependency, and
// ImageMagick (`magick` on PATH, or set MAGICK=...). The screenshots are
// written to extension/store/screenshots/ at 1280x800, 24-bit RGB PNG (no
// alpha), which is the Chrome Web Store's preferred screenshot shape. The
// popup and options pages are the real built pages; the surrounding browser
// frame and example article are illustrative. The fake API keeps the demo
// account, token, and request data out of the screenshot.
//
// ImageMagick is used only to downscale the 2x screenshot and strip alpha.
// If it is unavailable, install it or take the screenshots manually with the
// same states.
import { chromium } from "/mnt/970/eza/node_modules/@playwright/test/index.mjs";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const OUT = join(ROOT, "extension/store/screenshots");
mkdirSync(OUT, { recursive: true });
const MAGICK = process.env.MAGICK || "magick";
const buildDir = mkdtempSync(join(tmpdir(), "eza-store-shots-"));
execFileSync(process.execPath, [join(ROOT, "extension/build.mjs"), "--target", "chrome", "--out", buildDir], {
  cwd: ROOT,
  stdio: "inherit",
});
const root = join(buildDir, "chrome");
const MIME = { ".css": "text/css", ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".png": "image/png", ".svg": "image/svg+xml", ".json": "application/json" };

const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url || "/", "http://127.0.0.1");
    const rel = decodeURIComponent(url.pathname).replace(/^\/+/, "") || "popup.html";
    const target = resolve(root, normalize(rel));
    if (!target.startsWith(root + "/") && target !== root) throw new Error("forbidden");
    response.writeHead(200, { "Content-Type": MIME[extname(target)] || "application/octet-stream" });
    response.end(await readFile(target));
  } catch {
    response.writeHead(404).end("not found");
  }
});
await new Promise((ready) => server.listen(0, "127.0.0.1", ready));
const origin = "http://127.0.0.1:" + server.address().port;

const pageUrl = "https://example.com/the-quiet-ledger";
const savedBookmark = {
  id: 42,
  url: pageUrl,
  title: "The Quiet Ledger",
  domain: "example.com",
  created_at: 1762549200,
  added_at: 1762549200,
  favicon_url: "",
  tags: ["reading", "later"],
  is_read: false,
  is_dead: false,
};

const statuses = {
  add: {
    tabId: 1,
    url: pageUrl,
    title: "The Quiet Ledger",
    state: "add",
    tooltip: "eza — add bookmark",
    badge: { text: "", color: null },
    bookmark: null,
    error: null,
    lookupSupported: true,
    eligible: true,
    restricted: false,
    configured: true,
    checkActivePage: true,
    serverUrl: "https://eza.example.com",
    pageText: { supported: false, granted: true, reason: "" },
    canAddBookmark: true,
    canAddPageText: true,
  },
  saved: {
    tabId: 1,
    url: pageUrl,
    title: "The Quiet Ledger",
    state: "saved",
    tooltip: "eza — in your library: The Quiet Ledger",
    badge: { text: "✓", color: "#1f6f43" },
    bookmark: savedBookmark,
    error: null,
    lookupSupported: true,
    eligible: true,
    restricted: false,
    configured: true,
    checkActivePage: true,
    serverUrl: "https://eza.example.com",
    pageText: { supported: false, granted: true, reason: "" },
    canAddBookmark: true,
    canAddPageText: true,
  },
};

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 2 });

async function installFakeApi(page) {
  await page.addInitScript(
    ({ statuses, pageUrl }) => {
      const params = new URLSearchParams(window.location.search);
      const mode = params.get("mode") || "add";
      const status = statuses[mode] || statuses.add;
      const calls = [];
      const record = (entry) => calls.push(entry);
      window.__ezaStoreCalls = calls;

      const json = (code, body) => ({
        ok: code >= 200 && code < 300,
        status: code,
        headers: { get: () => null },
        text: async () => JSON.stringify(body),
      });
      const realFetch = globalThis.fetch;
      globalThis.fetch = async (input, init) => {
        const url = String(input);
        if (url.includes("/api/v1/whoami")) {
          return json(200, { username: "demo", scopes: ["capture"], token_name: "store-demo" });
        }
        if (url.includes("/api/v1/bookmarks/lookup")) {
          return json(200, { url: "https://example.com/", bookmark: null });
        }
        if (url.includes("/api/v1/clip-templates")) {
          return json(200, { templates: [], builtin: null });
        }
        return realFetch(input, init);
      };

      globalThis.chrome = {
        runtime: {
          sendMessage: async (message) => {
            record({ type: "message", message });
            if (!message || message.type === "eza:pageStatus") return { ok: true, status };
            if (message.type === "eza:addBookmark") {
              return { ok: true, created: true, existing: false, id: 42, message: "Bookmark added", bookmark: statuses.saved.bookmark, status: statuses.saved };
            }
            return { ok: false, error: { code: "unknown_message" } };
          },
          openOptionsPage: async () => record({ type: "options" }),
          lastError: null,
        },
        tabs: { create: async (options) => { record({ type: "tabs.create", options }); return { id: 2 }; } },
        permissions: {
          getAll: async () => ({ permissions: [], origins: [] }),
          contains: async () => true,
          request: async () => true,
        },
        storage: { local: { get: async () => ({}), set: async () => undefined } },
      };
    },
    { statuses, pageUrl },
  );
}

async function popupHeight(mode) {
  const page = await context.newPage();
  await page.setViewportSize({ width: 420, height: 900 });
  await installFakeApi(page);
  await page.goto(origin + "/popup.html?mode=" + mode, { waitUntil: "domcontentloaded" });
  await page.waitForSelector(mode === "saved" ? "#saved-panel:not([hidden])" : "#add-panel:not([hidden])", { timeout: 10000 });
  const box = await page.locator("main").boundingBox();
  await page.close();
  return Math.ceil(box.height);
}

function browserShot({ mode, height, badge }) {
  const iconSrc = "http://127.0.0.1:" + server.address().port + "/icons/icon-32.png";
  return `<!doctype html><html><head><meta charset="utf-8"><style>
    :root { color-scheme: light; }
    * { box-sizing: border-box; }
    html, body { margin: 0; height: 100%; }
    body {
      width: 1280px; height: 800px; overflow: hidden;
      background:
        radial-gradient(1100px 600px at 20% 0%, #faf6ed 0%, transparent 60%),
        linear-gradient(160deg, #efe8db 0%, #e5dccc 100%);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: #1a2340;
      display: flex; align-items: center; justify-content: center;
    }
    .browser {
      width: 1180px; height: 700px; border-radius: 14px; overflow: hidden;
      background: #f6f2ea; border: 1px solid #d5cbb8;
      box-shadow: 0 30px 70px rgba(51, 40, 24, .18), 0 2px 0 rgba(255,255,255,.7) inset;
    }
    .chrome {
      height: 54px; background: #e9e1d3; border-bottom: 1px solid #d5cbb8;
      display: flex; align-items: center; gap: 12px; padding: 0 16px;
    }
    .dots { display: flex; gap: 7px; }
    .dot { width: 11px; height: 11px; border-radius: 50%; background: #c9bca7; }
    .nav { display: flex; gap: 8px; color: #8a8172; font-size: 14px; letter-spacing: .02em; }
    .address {
      flex: 1; height: 30px; border-radius: 15px; border: 1px solid #d5cbb8;
      background: #f6f2ea; color: #6e675c; display: flex; align-items: center;
      padding: 0 13px; font-family: "IBM Plex Mono", ui-monospace, monospace; font-size: 12px;
    }
    .ext { width: 34px; height: 34px; position: relative; flex: none; }
    .ext img { width: 30px; height: 30px; border-radius: 6px; display: block; margin: 2px; }
    .badge {
      position: absolute; right: -2px; bottom: -2px; min-width: 15px; height: 15px;
      border-radius: 4px; background: #1f6f43; color: #fffdf8; border: 1px solid #f6f2ea;
      font-size: 10px; font-weight: 700; line-height: 13px; text-align: center; padding: 0 2px;
    }
    .page { display: flex; gap: 40px; padding: 34px 44px; height: calc(100% - 54px); }
    .article { flex: 1; min-width: 0; padding-top: 6px; }
    .kicker { font-family: ui-monospace, monospace; font-size: 12px; letter-spacing: .16em; text-transform: uppercase; color: #8a2b20; }
    h1 { font-family: "Iowan Old Style", "Palatino Linotype", Georgia, serif; font-weight: 500; font-size: 54px; line-height: 1.02; letter-spacing: -.03em; margin: 14px 0 14px; }
    .byline { font-family: ui-monospace, monospace; font-size: 12px; letter-spacing: .04em; color: #6e675c; margin-bottom: 26px; }
    p { font-family: Georgia, "Times New Roman", serif; font-size: 17px; line-height: 1.62; color: #3f3a31; margin: 0 0 18px; max-width: 560px; }
    .rule { height: 1px; background: #d5cbb8; margin: 22px 0; width: 560px; }
    .popup { width: 360px; flex: none; align-self: flex-start; margin-top: 2px; border-radius: 9px; overflow: hidden; border: 1px solid rgba(26,35,64,.28); box-shadow: 0 24px 55px rgba(27, 22, 14, .28), 0 3px 10px rgba(27,22,14,.12); background: #f6f2ea; }
    iframe { width: 360px; height: ${height}px; border: 0; display: block; background: #f6f2ea; }
    .caption { position: absolute; left: 54px; bottom: 34px; font-family: ui-monospace, monospace; font-size: 12px; letter-spacing: .08em; color: #6e675c; }
  </style></head><body>
    <div class="browser">
      <div class="chrome">
        <div class="dots"><i class="dot"></i><i class="dot"></i><i class="dot"></i></div>
        <div class="nav">‹ ›</div>
        <div class="address">${pageUrl}</div>
        <div class="ext"><img src="${iconSrc}" alt="">${badge ? '<span class="badge">✓</span>' : ""}</div>
      </div>
      <div class="page">
        <div class="article">
          <div class="kicker">Essay · reading</div>
          <h1>The Quiet Ledger</h1>
          <div class="byline">Mara Ellery · 12 min read</div>
          <p>A library is not a list of places. It is the argument you make to your future self about what was worth keeping.</p>
          <p>Some pages are worth returning to for the sentence alone. Others are worth keeping because of the way they make the rest of the week look different.</p>
          <div class="rule"></div>
          <p>The quiet ones are usually the ones that stay.</p>
        </div>
        <div class="popup"><iframe src="${origin}/popup.html?mode=${mode}"></iframe></div>
      </div>
    </div>
  </body></html>`;
}

async function shot(name, html) {
  const page = await context.newPage();
  await page.setViewportSize({ width: 1280, height: 800 });
  await installFakeApi(page);
  await page.setContent(html, { waitUntil: "load" });
  await page.waitForTimeout(800);
  const raw = join(buildDir, name + "-raw.png");
  await page.screenshot({ path: raw });
  await page.close();
  execFileSync(MAGICK, [raw, "-resize", "1280x800!", "-alpha", "off", "-type", "TrueColor", "-depth", "8", "PNG24:" + join(OUT, name + ".png")]);
}

await shot("01-add-bookmark", browserShot({ mode: "add", height: await popupHeight("add"), badge: false }));
await shot("02-already-saved", browserShot({ mode: "saved", height: await popupHeight("saved"), badge: true }));

// Options screenshot: the real options page, centred as a card on the same
// paper backdrop. Fake the API so the connection test looks connected.
{
  const page = await context.newPage();
  await page.setViewportSize({ width: 1280, height: 800 });
  await installFakeApi(page);
  await page.goto(origin + "/options.html", { waitUntil: "domcontentloaded" });
  await page.waitForSelector("#server-url", { timeout: 10000 });
  await page.fill("#server-url", "https://eza.example.com");
  await page.fill("#token", "eza_pat_example_capture_token");
  await page.click("#save");
  await page.waitForFunction(() => document.querySelector("#status")?.textContent === "Saved.", null, { timeout: 10000 });
  await page.click("#test");
  await page.waitForFunction(() => /Connected as demo/.test(document.querySelector("#status")?.textContent || ""), null, { timeout: 10000 });
  await page.addStyleTag({ content: `
    :root { color-scheme: light; }
    body.options { background: radial-gradient(1100px 600px at 20% 0%, #faf6ed 0%, transparent 60%), linear-gradient(160deg, #efe8db 0%, #e5dccc 100%); }
    body.options main { width: 610px; margin: 28px auto; padding: 30px 30px 34px; background: #f6f2ea; border: 1px solid #d5cbb8; border-radius: 14px; box-shadow: 0 30px 70px rgba(51,40,24,.18); }
    body.options header { margin-bottom: 18px; }
  `});
  await page.waitForTimeout(300);
  const raw = join(buildDir, "03-options-raw.png");
  await page.screenshot({ path: raw });
  await page.close();
  execFileSync(MAGICK, [raw, "-resize", "1280x800!", "-alpha", "off", "-type", "TrueColor", "-depth", "8", "PNG24:" + join(OUT, "03-options.png")]);
}

await browser.close();
await new Promise((done) => server.close(done));
rmSync(buildDir, { recursive: true, force: true });
console.log("wrote", ["01-add-bookmark.png", "02-already-saved.png", "03-options.png"].map((f) => join(OUT, f)).join("\n"));
