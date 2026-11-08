// PWA smoke test: manifest, service worker, share_target, offline banner,
// bookmarklet copy, and the share_target landing route.
//
// Run from the repo root in the dev shell, against a scratch server:
//   EZA_BASE=http://localhost:8100 node tests/e2e/pwa-smoke.mjs
import { BASE, SEL, launchBrowser, launchPage, enterLibrary, newChecker } from "./lib/dom.mjs";

const { check, report } = newChecker();

// ---------------------------------------------------------------- static ---
const manifestResponse = await fetch(BASE + "/manifest.webmanifest");
const manifestText = await manifestResponse.text();
let manifest = null;
try {
  manifest = JSON.parse(manifestText);
} catch (error) {
  manifest = null;
}
check("manifest 200", manifestResponse.status === 200, "status " + manifestResponse.status);
const manifestType = manifestResponse.headers.get("content-type") || "";
check(
  "manifest content-type",
  manifestType.includes("manifest+json") || manifestType.includes("application/json"),
  manifestType
);
check("manifest parses", manifest !== null);
check("manifest name/short_name", Boolean(manifest?.name && manifest?.short_name));
check("manifest start_url and scope", manifest?.start_url === "/" && manifest?.scope === "/");
check("manifest display standalone", manifest?.display === "standalone");
check(
  "manifest theme/background",
  Boolean(manifest?.theme_color && manifest?.background_color),
  (manifest?.theme_color || "?") + " / " + (manifest?.background_color || "?")
);
const icons = Array.isArray(manifest?.icons) ? manifest.icons : [];
const icon192 = icons.find((icon) => icon.sizes === "192x192");
const icon512 = icons.find((icon) => icon.sizes === "512x512");
check("manifest has 192/512 icons", Boolean(icon192 && icon512));
for (const icon of [icon192, icon512].filter(Boolean)) {
  const iconResponse = await fetch(BASE + icon.src);
  const iconType = iconResponse.headers.get("content-type") || "";
  check(
    "icon " + icon.sizes,
    iconResponse.status === 200 && iconType.includes("image/png"),
    icon.src + " " + iconResponse.status + " " + iconType
  );
}
const shareTarget = manifest?.share_target || {};
check(
  "manifest share_target",
  shareTarget.action === "/save" &&
    shareTarget.method === "GET" &&
    shareTarget.params?.title === "title" &&
    shareTarget.params?.text === "text" &&
    shareTarget.params?.url === "url",
  JSON.stringify(shareTarget)
);

const swResponse = await fetch(BASE + "/sw.js");
const swText = await swResponse.text();
const swType = swResponse.headers.get("content-type") || "";
check("service worker 200", swResponse.status === 200, "status " + swResponse.status);
check(
  "service worker Service-Worker-Allowed",
  swResponse.headers.get("service-worker-allowed") === "/",
  String(swResponse.headers.get("service-worker-allowed"))
);
check("service worker javascript content-type", swType.includes("javascript"), swType);
check("service worker versioned shell cache", /eza-app-shell-v\d+/.test(swText), (swText.match(/eza-app-shell-v\d+/) || [])[0]);
check(
  "service worker never caches API/auth",
  ["/api/", "/save", "/login", "/setup", "/recover"].every((path) => swText.includes(path))
);

// ---------------------------------------------------------------- browser ---
const browser = await launchBrowser();
const { context, page, errors } = await launchPage(browser, { viewport: { width: 1360, height: 900 } });

try {
  await enterLibrary(page);
  await page.waitForTimeout(800);

  const manifestLink = await page.evaluate(() => {
    const link = document.querySelector('link[rel="manifest"]');
    return link ? link.getAttribute("href") : null;
  });
  check("document links manifest", manifestLink === "/manifest.webmanifest", String(manifestLink));

  const registration = await page.evaluate(async () => {
    try {
      const ready = await Promise.race([
        navigator.serviceWorker.ready,
        new Promise((resolve) => setTimeout(() => resolve(null), 8000)),
      ]);
      if (!ready) return null;
      return {
        scope: ready.scope,
        active: Boolean(ready.active),
        scriptURL: ready.active ? ready.active.scriptURL : null,
      };
    } catch (error) {
      return { error: String(error) };
    }
  });
  check("service worker registered", Boolean(registration && registration.active), JSON.stringify(registration));
  check(
    "service worker scope is /",
    Boolean(registration?.scope && new URL(registration.scope).pathname === "/"),
    String(registration?.scope)
  );

  // The app-shell cache must never contain API/auth/share-target responses.
  const cachedPaths = await page.evaluate(async () => {
    const paths = [];
    for (const name of await caches.keys()) {
      const cache = await caches.open(name);
      for (const request of await cache.keys()) {
        paths.push(new URL(request.url).pathname);
      }
    }
    return paths;
  });
  const forbidden = cachedPaths.filter(
    (pathname) =>
      pathname.startsWith("/api/") ||
      pathname === "/save" ||
      pathname.startsWith("/save/") ||
      pathname === "/login" ||
      pathname.startsWith("/login/") ||
      pathname === "/setup" ||
      pathname.startsWith("/setup/") ||
      pathname === "/recover" ||
      pathname.startsWith("/recover/")
  );
  check(
    "app-shell cache excludes api/auth/save",
    cachedPaths.length > 0 && forbidden.length === 0,
    cachedPaths.length + " entries, forbidden: " + JSON.stringify(forbidden)
  );

  // Offline banner appears when the browser goes offline and clears online.
  await context.setOffline(true);
  await page.waitForTimeout(900);
  const offlineVisible = await page.locator(SEL.offlineBanner).count();
  const offlineText = offlineVisible ? (await page.locator(SEL.offlineBanner).first().innerText()).trim() : "";
  check("offline banner appears", offlineVisible > 0);
  check("offline banner copy", /unreachable|paused|offline/i.test(offlineText), offlineText.replace(/\n+/g, " ").slice(0, 90));

  // An offline reload must still boot the app from the service-worker shell.
  await page.reload({ waitUntil: "domcontentloaded" }).catch(() => {});
  await page.waitForTimeout(3500);
  const offlineShell = await page.locator(SEL.appShell).count();
  check("offline reload serves app shell", offlineShell > 0);

  await context.setOffline(false);
  await page.reload({ waitUntil: "domcontentloaded" }).catch(() => {});
  await page.waitForSelector(SEL.appShell, { timeout: 30000 }).catch(() => {});
  await page.waitForTimeout(800);
  const offlineCleared = await page.locator(SEL.offlineBanner).count();
  check("offline banner clears online", offlineCleared === 0);

  // Install button is gated on beforeinstallprompt.
  const installBefore = await page.locator(SEL.installFab).count();
  await page.evaluate(() => {
    const event = new Event("beforeinstallprompt", { cancelable: true });
    window.dispatchEvent(event);
  });
  await page.waitForTimeout(200);
  const installAfter = await page.locator(SEL.installFab).count();
  check("no install button before prompt", installBefore === 0);
  check("install button after beforeinstallprompt", installAfter === 1);

  // Bookmarklet on the account capture section.
  await page.goto(BASE + "/account", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });
  await page.click(SEL.accountTab("capture"));
  await page.waitForSelector(SEL.captureBox, { timeout: 20000 });
  const bookmarklet = await page.evaluate(() => {
    const code = document.querySelector('[data-testid="capture-box"] .account-snippet code');
    return code ? code.textContent.trim() : null;
  });
  check(
    "bookmarklet snippet present",
    Boolean(bookmarklet && (bookmarklet.startsWith("javascript:") || /location\.href/.test(bookmarklet))),
    bookmarklet ? bookmarklet.slice(0, 48) + "..." : "missing"
  );

  await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin: BASE });
  await page.locator(SEL.captureBox).getByRole("button", { name: /^copy$/i }).first().click();
  await page.waitForTimeout(400);
  const clipboard = await page.evaluate(() => navigator.clipboard.readText().catch(() => ""));
  check("copy bookmarklet writes clipboard", clipboard.length > 0 && /javascript:|location\.href/.test(clipboard), clipboard.slice(0, 40) + "...");

  // share_target landing route: a share carrying a URL is captured through
  // the idempotent quick-save endpoint, then the app lands on the library.
  const sharedUrl = "https://example.com/pwa-share-smoke-" + Date.now();
  await page.goto(
    BASE + "/save?url=" + encodeURIComponent(sharedUrl) + "&title=" + encodeURIComponent("PWA share smoke"),
    { waitUntil: "domcontentloaded" }
  );
  await page.waitForSelector(SEL.appShell, { timeout: 25000 });
  await page
    .waitForFunction(
      () => [...document.querySelectorAll('[data-testid="toast"]')].some((toast) => /Saved to eza|Already in your library/.test(toast.textContent)),
      null,
      { timeout: 20000 }
    )
    .catch(() => {});
  const shareState = await page.evaluate(() => ({
    path: window.location.pathname,
    toasts: [...document.querySelectorAll('[data-testid="toast"]')].map((toast) => toast.textContent.trim()),
  }));
  check("share target routes to library", shareState.path === "/", shareState.path);
  check(
    "share target quick-saves url",
    shareState.toasts.some((text) => /Saved to eza|Already in your library/.test(text)),
    JSON.stringify(shareState.toasts)
  );

  // Sharing the same URL again is idempotent.
  await page.goto(
    BASE + "/save?url=" + encodeURIComponent(sharedUrl) + "&title=" + encodeURIComponent("PWA share smoke"),
    { waitUntil: "domcontentloaded" }
  );
  await page.waitForSelector(SEL.appShell, { timeout: 25000 });
  await page.waitForTimeout(1800);
  const repeatToasts = await page.evaluate(() =>
    [...document.querySelectorAll('[data-testid="toast"]')].map((toast) => toast.textContent.trim())
  );
  check(
    "share target is idempotent",
    repeatToasts.some((text) => /Already in your library/.test(text)),
    JSON.stringify(repeatToasts)
  );

  // A share without any URL falls back to the pre-filled add dialog.
  await page.goto(BASE + "/save?title=" + encodeURIComponent("No URL share"), {
    waitUntil: "domcontentloaded",
  });
  await page.waitForSelector('[data-testid="dialog-add"]', { timeout: 20000 });
  const fallback = await page.evaluate(() => ({
    url: document.querySelector("#add-url") ? document.querySelector("#add-url").value : null,
    title: document.querySelector("#add-title") ? document.querySelector("#add-title").value : null,
  }));
  check("share without url opens add dialog", fallback.url === "", JSON.stringify(fallback));
  check("share without url keeps title", fallback.title === "No URL share", String(fallback.title));
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
