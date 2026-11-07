/* eza service worker — versioned app-shell cache.
 *
 * The shell (HTML, CSS, JS, WASM, icons) is precached so the app starts
 * instantly and works offline. API and auth endpoints are never cached:
 * /api/*, /save, /login, /setup, /recover always go to the network.
 */
"use strict";

const VERSION = "eza-app-shell-v1";
const SHELL_CACHE = VERSION + "-shell";
const RUNTIME_CACHE = VERSION + "-runtime";

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
];

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
  const cached = await caches.match(request);
  if (cached) {
    // Stale-while-revalidate: serve fast, refresh the cache in the background.
    fetch(request)
      .then(async (response) => {
        if (response && response.ok) {
          const cache = await caches.open(RUNTIME_CACHE);
          await cache.put(request, response.clone());
        }
      })
      .catch(() => {});
    return cached;
  }
  try {
    const response = await fetch(request);
    if (response && response.ok && new URL(request.url).origin === self.location.origin) {
      const cache = await caches.open(RUNTIME_CACHE);
      await cache.put(request, response.clone());
    }
    return response;
  } catch (error) {
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
