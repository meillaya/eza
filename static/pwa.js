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

  // ------------------------------------------------ reader selections -----
  // Character offsets of a DOM selection inside a container, used by the
  // bookmark detail page to create highlights. Returns JSON or null.
  window.ezaSelectionOffsets = function (containerId) {
    try {
      var container = document.getElementById(containerId);
      var selection = window.getSelection ? window.getSelection() : null;
      if (!container || !selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
      var range = selection.getRangeAt(0);
      if (!container.contains(range.startContainer) || !container.contains(range.endContainer)) return null;
      function offsetAt(node, offset) {
        var total = 0;
        var walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
        var current = null;
        while ((current = walker.nextNode())) {
          if (current === node) {
            if (node.nodeType === 3) return total + offset;
            var childTotal = total;
            for (var i = 0; i < offset && i < node.childNodes.length; i++) {
              childTotal += (node.childNodes[i].textContent || "").length;
            }
            return childTotal;
          }
          if (current.nodeType === 3) total += current.textContent.length;
        }
        return null;
      }
      var start = offsetAt(range.startContainer, range.startOffset);
      var end = offsetAt(range.endContainer, range.endOffset);
      if (start === null || end === null) return null;
      if (start > end) {
        var swap = start;
        start = end;
        end = swap;
      }
      var quote = (container.textContent || "").substring(start, end);
      if (!quote.trim()) return null;
      return JSON.stringify({ start: start, end: end, quote: quote });
    } catch (error) {
      return null;
    }
  };

})();
