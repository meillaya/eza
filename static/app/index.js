// WASI shim loader for the eza Miso/WebAssembly client.
// External module only (CSP friendly).
//
// This file is a template: scripts/bundle-web.sh rewrites the asset placeholder tokens
// to the content-addressed names from static/asset-manifest.json and emits
// static/app/index.<hash>.js. The compile step (scripts/build-web.sh) produces
// static/app/app.wasm and static/app/ghc_wasm_jsffi.js.
import { WASI, File, OpenFile, ConsoleStdout } from "../vendor/__EZA_VENDOR_DIR__/index.js";
import ghc_wasm_jsffi from "./__EZA_JSFFI_FILE__";

const splash = document.getElementById("boot-splash");
const errorBox = document.getElementById("boot-error");
const errorMessage = document.getElementById("boot-error-message");

function mark(name) {
  try {
    if (typeof performance !== "undefined" && performance.mark) {
      performance.mark("eza:" + name);
    }
  } catch (error) {
    /* performance marks are diagnostic only */
  }
}

function removeSplash() {
  if (splash && splash.parentNode) splash.parentNode.removeChild(splash);
}

function fail(error) {
  mark("boot-failed");
  console.error("[eza] boot failed", error);
  removeSplash();
  if (errorMessage) {
    errorMessage.textContent =
      (error && error.message) || String(error) || "Unknown error";
  }
  if (errorBox) errorBox.hidden = false;
}

async function boot() {
  if (typeof WebAssembly !== "object") {
    throw new Error("WebAssembly is not available in this browser.");
  }
  mark("boot-start");
  const fds = [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered((line) => console.log("[eza:stdout] " + line)),
    ConsoleStdout.lineBuffered((line) => console.warn("[eza:stderr] " + line))
  ];
  const wasi = new WASI([], [], fds, { debug: false });
  // Knot-tying: the JSFFI bindings need the instance exports, which only exist
  // after instantiation, so hand over a mutable object that we fill afterwards.
  const exportsObject = {};
  const imports = {
    wasi_snapshot_preview1: wasi.wasiImport,
    ghc_wasm_jsffi: ghc_wasm_jsffi(exportsObject)
  };
  // Resolve relative to this module (/assets/app/index.js), not the document
  // URL — SPA deep links such as /bookmark/42 would otherwise break the fetch.
  const wasmUrl = new URL("./__EZA_WASM_FILE__", import.meta.url);
  mark("wasm-fetch-start");
  // The wasm name carries its content hash and is served immutable, so the
  // browser HTTP cache can answer a repeat load without revalidation.
  const response = await fetch(wasmUrl, { cache: "default" });
  mark("wasm-fetch-end");
  if (!response.ok) {
    throw new Error("Could not load app.wasm (HTTP " + response.status + ")");
  }
  let instance;
  try {
    if (typeof WebAssembly.instantiateStreaming !== "function") {
      throw new Error("WebAssembly.instantiateStreaming is unavailable");
    }
    mark("wasm-instantiate-start");
    const streaming = await WebAssembly.instantiateStreaming(response.clone(), imports);
    instance = streaming.instance;
  } catch (streamingError) {
    // A reverse proxy that rewrites Content-Type, or a browser without
    // streaming compilation, must not brick the client. The clone above keeps
    // the original response body available for the arrayBuffer fallback.
    console.warn("[eza] streaming instantiation failed; using arrayBuffer", streamingError);
    mark("wasm-streaming-fallback");
    const bytes = await response.arrayBuffer();
    const compiled = await WebAssembly.instantiate(bytes, imports);
    instance = compiled.instance;
  }
  mark("wasm-instantiated");
  Object.assign(exportsObject, instance.exports);
  wasi.initialize(instance);
  if (typeof instance.exports.hs_start !== "function") {
    throw new Error("app.wasm is missing the hs_start export (build may be stale).");
  }
  instance.exports.hs_start();
  mark("hs-start");
  removeSplash();
  document.body.classList.add("app-ready");
  mark("app-ready");
  // Let pwa.js register the service worker only after the WASM fetch and
  // instantiation have finished; installing earlier raced the loader and
  // could download app.wasm twice on a cold visit.
  try {
    window.dispatchEvent(new Event("eza-app-ready"));
  } catch (error) {
    /* older browsers without Event constructors still get the app */
  }
}

boot().catch(fail);
