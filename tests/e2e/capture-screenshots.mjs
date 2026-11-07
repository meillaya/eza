import { chromium } from "@playwright/test";

const BASE = process.env.EZA_BASE || "http://localhost:8100";
const OUT = process.env.EZA_SHOT_DIR || "docs/screenshots";
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  deviceScaleFactor: 2,
  colorScheme: "light",
  reducedMotion: "reduce",
});
const page = await context.newPage();
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

await page.goto(BASE + "/setup", { waitUntil: "networkidle" });
await page.click("#passkey-setup");
await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
await page.click("#continue");
await page.waitForSelector("#search-input", { timeout: 30000 });

async function api(path, options = {}) {
  return page.evaluate(async ({ path, options }) => {
    const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
    const headers = { ...(options.headers || {}) };
    if (options.method && options.method !== "GET") headers["X-CSRF-Token"] = csrf;
    const response = await fetch(path, { ...options, headers });
    const text = await response.text();
    let body = null;
    try { body = JSON.parse(text); } catch { body = text.slice(0, 120); }
    return { status: response.status, body };
  }, { path, options });
}

const bookmarks = [
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

const ids = [];
for (const [title, url, tags] of bookmarks) {
  const result = await api("/api/v1/bookmarks", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ url, title, tags }),
  });
  if (result.status !== 201) throw new Error("create failed: " + JSON.stringify(result));
  ids.push(result.body.id);
}

await api("/api/v1/bookmarks/" + ids[0], {
  method: "PATCH",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    note_body:
      "A gentle introduction to Haskell. The examples build from recursion to monads, and the exercises are short enough to finish in one sitting.\n\nSee [[The Rust Programming Language]] for a systems contrast.",
  }),
});
await api("/api/v1/bookmarks/" + ids[1], {
  method: "PATCH",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    note_body: "Ownership and borrowing compared with [[Learn You a Haskell for Great Good]].",
  }),
});

await page.goto(BASE + "/", { waitUntil: "networkidle" });
await page.waitForSelector(".card", { timeout: 30000 });
await page.waitForTimeout(800);
await page.screenshot({ path: OUT + "/library.png" });

await page.locator(".card-title", { hasText: "Learn You a Haskell" }).first().click();
await page.waitForTimeout(800);
await page.screenshot({ path: OUT + "/detail.png" });

await page.goto(BASE + "/", { waitUntil: "networkidle" });
await page.waitForSelector("#search-input", { timeout: 30000 });
await page.keyboard.press("k");
await page.waitForSelector("#palette-input", { timeout: 10000 });
await page.waitForTimeout(300);
await page.screenshot({ path: OUT + "/palette.png" });
await page.keyboard.press("Escape");

await page.getByTitle("Toggle theme").click();
await page.waitForTimeout(500);
await page.screenshot({ path: OUT + "/dark.png" });

console.log("captured", ids.length, "bookmarks");
await browser.close();
