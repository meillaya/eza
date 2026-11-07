/* eza PWA glue: service-worker registration, install prompt, clipboard.
 * External file only — index.html has no inline scripts. */
(function () {
  "use strict";

  // ---------------------------------------------------------------- SW ---
  function canUseServiceWorker() {
    if (!("serviceWorker" in navigator)) return false;
    if (location.protocol === "https:") return true;
    return location.hostname === "localhost" || location.hostname === "127.0.0.1";
  }

  function registerServiceWorker() {
    if (!canUseServiceWorker()) return;
    navigator.serviceWorker
      .register("/sw.js", { scope: "/" })
      .catch(function (error) {
        console.warn("[eza] service worker registration failed", error);
      });
  }

  if (document.readyState === "complete") registerServiceWorker();
  else window.addEventListener("load", registerServiceWorker);

  // ------------------------------------------------- install prompt ------
  // The install button only exists after the browser fires
  // beforeinstallprompt — never show a fake/manual install prompt.
  var deferredPrompt = null;
  var installButton = null;

  function removeInstallButton() {
    if (installButton && installButton.parentNode) {
      installButton.parentNode.removeChild(installButton);
    }
    installButton = null;
  }

  function showInstallButton() {
    if (installButton || !deferredPrompt || !document.body) return;
    installButton = document.createElement("button");
    installButton.type = "button";
    installButton.className = "install-fab";
    installButton.textContent = "Install eza";
    installButton.title = "Install eza as an app";
    installButton.addEventListener("click", function () {
      var promptEvent = deferredPrompt;
      deferredPrompt = null;
      removeInstallButton();
      if (promptEvent && typeof promptEvent.prompt === "function") {
        promptEvent.prompt();
      }
    });
    document.body.appendChild(installButton);
  }

  window.addEventListener("beforeinstallprompt", function (event) {
    event.preventDefault();
    deferredPrompt = event;
    showInstallButton();
  });

  window.addEventListener("appinstalled", function () {
    deferredPrompt = null;
    removeInstallButton();
  });

  // ------------------------------------------------------ clipboard ------
  // Used by the Miso account page ("Copy bookmarklet"). Returns a boolean.
  window.ezaCopy = function (text) {
    var value = String(text == null ? "" : text);
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(value);
        return true;
      }
    } catch (error) {
      /* fall through to the legacy path */
    }
    try {
      var area = document.createElement("textarea");
      area.value = value;
      area.setAttribute("readonly", "");
      area.className = "sr-only";
      document.body.appendChild(area);
      area.select();
      var copied = document.execCommand("copy");
      document.body.removeChild(area);
      return copied;
    } catch (error) {
      return false;
    }
  };
})();
