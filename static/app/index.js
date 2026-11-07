// WASI shim loader for the eza Miso/WebAssembly client.
// External module only (CSP friendly). The wasm binary is produced by
// scripts/build-web.sh (static/app/app.wasm + static/app/ghc_wasm_jsffi.js).
import { WASI, File, OpenFile, ConsoleStdout } from "../vendor/browser_wasi_shim/index.js";
import ghc_wasm_jsffi from "./ghc_wasm_jsffi.js";

const splash = document.getElementById("boot-splash");
const errorBox = document.getElementById("boot-error");
const errorMessage = document.getElementById("boot-error-message");

function removeSplash() {
  if (splash && splash.parentNode) splash.parentNode.removeChild(splash);
}

function fail(error) {
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
  const wasmUrl = new URL("./app.wasm", import.meta.url);
  const response = await fetch(wasmUrl, { cache: "no-cache" });
  if (!response.ok) {
    throw new Error("Could not load app.wasm (HTTP " + response.status + ")");
  }
  const { instance } = await WebAssembly.instantiateStreaming(response, imports);
  Object.assign(exportsObject, instance.exports);
  wasi.initialize(instance);
  if (typeof instance.exports.hs_start !== "function") {
    throw new Error("app.wasm is missing the hs_start export (build may be stale).");
  }
  instance.exports.hs_start();
  removeSplash();
  document.body.classList.add("app-ready");
}

boot().catch(fail);
