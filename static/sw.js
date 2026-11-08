/* eza service worker: versioned app-shell cache.
 *
 * The shell (HTML, CSS, JS, WASM, icons, fonts) is precached so the app starts
 * instantly and works offline. API and auth endpoints are never cached:
 * /api/*, /save, /login, /setup, /recover always go to the network.
 */
"use strict";

// The server replaces the dev marker with the current web build id, so every
// `bash scripts/build-web.sh` installs a new worker instead of leaving an old
// shell in the browser cache.
const VERSION = "eza-app-shell-v4-dev";
const SHELL_CACHE = VERSION + "-shell";
const RUNTIME_CACHE = VERSION + "-runtime";

// The catalogue typefaces. These are the URLs eza.css requests and the files
// live in static/fonts, which the server serves at /assets/fonts/<file>.
const FONT_ASSETS = [
  "/assets/fonts/fraunces-300-900.woff2",
  "/assets/fonts/newsreader-300-800.woff2",
  "/assets/fonts/ibm-plex-mono-400.woff2",
  "/assets/fonts/ibm-plex-mono-500.woff2",
  "/assets/fonts/ibm-plex-mono-600.woff2",
];

const SHELL_ASSETS = [
  "/",
  "/manifest.webmanifest",
  "/assets/eza.css",
  "/assets/theme.js",
  "/assets/pwa.js",
  "/assets/favicon.svg",
  "/assets/favicon-fallback.svg",
  "/assets/icons/icon-192.png",
  "/assets/icons/icon-512.png",
  "/assets/app/index.js",
  "/assets/app/ghc_wasm_jsffi.js",
  "/assets/app/app.wasm",
  "/assets/vendor/browser_wasi_shim/index.js",
  "/assets/vendor/browser_wasi_shim/wasi.js",
  "/assets/vendor/browser_wasi_shim/wasi_defs.js",
  "/assets/vendor/browser_wasi_shim/fd.js",
  "/assets/vendor/browser_wasi_shim/fs_mem.js",
  "/assets/vendor/browser_wasi_shim/fs_opfs.js",
  "/assets/vendor/browser_wasi_shim/strace.js",
  "/assets/vendor/browser_wasi_shim/debug.js",
].concat(FONT_ASSETS);

// Endpoints that must always talk to the network and never be cached.
const NETWORK_ONLY_PREFIXES = ["/api/", "/save", "/login", "/setup", "/recover"];

function isNetworkOnly(url) {
  const path = url.pathname;
  return NETWORK_ONLY_PREFIXES.some(
    (prefix) => path === prefix || path === prefix.replace(/\/$/, "") || path.startsWith(prefix.endsWith("/") ? prefix : prefix + "/")
  );
}

// Precache one shell asset. redirect: "error" keeps auth redirects (e.g. a
// logged-out "/" that redirects to /login) out of the app-shell cache; a
// missing route only skips that asset instead of failing the installation.
async function precache(cache, url) {
  try {
    const response = await fetch(url, { redirect: "error", cache: "reload" });
    if (response && response.ok) await cache.put(url, response);
  } catch (error) {
    /* tolerate missing routes / offline install */
  }
}

self.addEventListener("install", (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(SHELL_CACHE);
      await Promise.all(SHELL_ASSETS.map((asset) => precache(cache, asset)));
      await self.skipWaiting();
    })()
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(
        keys
          .filter((key) => !key.startsWith(VERSION))
          .map((key) => caches.delete(key))
      );
      await self.clients.claim();
      const windows = await self.clients.matchAll({ type: "window" });
      windows.forEach((client) => client.postMessage({ type: "EZA_SW_UPDATED", version: VERSION }));
    })()
  );
});

async function shellFallback() {
  const cached = await caches.match("/", { cacheName: SHELL_CACHE });
  if (cached) return cached;
  return new Response("eza is offline and the app shell is not cached yet.", {
    status: 503,
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}

async function navigationStrategy(request) {
  try {
    const response = await fetch(request);
    if (response && response.ok) {
      if (new URL(request.url).pathname === "/") {
        const cache = await caches.open(SHELL_CACHE);
        cache.put("/", response.clone());
      }
      return response;
    }
    if (response && response.status === 404) {
      // Deep links must still open the app shell once the server only knows /.
      const cached = await caches.match("/", { cacheName: SHELL_CACHE });
      if (cached) return cached;
    }
    return response;
  } catch (error) {
    return shellFallback();
  }
}

async function assetStrategy(request) {
  // Network first: a rebuilt asset must reach the page on the next load. The
  // server answers conditional requests with 304, so the check is cheap, and
  // the cache still covers the offline case.
  try {
    const response = await fetch(request);
    if (response && response.ok && new URL(request.url).origin === self.location.origin) {
      const cache = await caches.open(RUNTIME_CACHE);
      await cache.put(request, response.clone());
    }
    return response;
  } catch (error) {
    const cached = await caches.match(request);
    if (cached) return cached;
    const cachedShell = await caches.match("/", { cacheName: SHELL_CACHE });
    return cachedShell || new Response("", { status: 504 });
  }
}

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (isNetworkOnly(url)) return;
  if (request.mode === "navigate") {
    event.respondWith(navigationStrategy(request));
    return;
  }
  event.respondWith(assetStrategy(request));
});

self.addEventListener("message", (event) => {
  const data = event.data || {};
  if (data.type === "EZA_SW_SKIP_WAITING") {
    self.skipWaiting();
  }
  if (data.type === "EZA_SW_VERSION" && event.source) {
    event.source.postMessage({ type: "EZA_SW_VERSION", version: VERSION });
  }
});
