// WebExtension API shim.
//
// Firefox exposes the extension API as `browser`; Chromium exposes the same
// surface as `chrome`. The MV3 APIs used by this extension return promises in
// both browsers. This module is the only place that looks at the global
// namespace: every other module imports getApi() and uses the object it
// returns, which keeps the source tree identical for Chrome and Firefox and
// lets the static checks prove that nothing bypasses the shim.

/**
 * Return the WebExtension API namespace for this browser.
 *
 * Call it lazily (inside a function) from modules that are also loaded by the
 * Node test suite, because Node has no extension namespace. Page scripts and
 * the background worker may call it once at load time.
 * @returns {any}
 */
export function getApi() {
  const scope = globalThis;
  if (scope.browser && scope.browser.runtime) return scope.browser;
  if (scope.chrome) return scope.chrome;
  throw new Error('No WebExtension API namespace is available in this context.');
}
