/* eza PWA glue: service-worker registration, install prompt, clipboard.
 * External file only. index.html has no inline scripts. */
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
    var hadController = !!navigator.serviceWorker.controller;
    navigator.serviceWorker.addEventListener("message", function (event) {
      var data = event.data || {};
      if (data.type !== "EZA_SW_UPDATED" || !hadController || !data.version) return;
      // One reload per new build: the worker has just replaced an older shell.
      var key = "eza-reloaded-" + data.version;
      try {
        if (sessionStorage.getItem(key)) return;
        sessionStorage.setItem(key, "1");
      } catch (error) {
        return;
      }
      window.location.reload();
    });
    navigator.serviceWorker
      .register("/sw.js", { scope: "/", updateViaCache: "none" })
      .catch(function (error) {
        console.warn("[eza] service worker registration failed", error);
      });
  }

  if (document.readyState === "complete") registerServiceWorker();
  else window.addEventListener("load", registerServiceWorker);

  // ------------------------------------------------- install prompt ------
  // The install button only exists after the browser fires
  // beforeinstallprompt. Never show a fake or manual install prompt.
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
    installButton.textContent = "Install the catalogue";
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

  // ------------------------------------------------------------ network -----
  // Miso's fetch drops the response body on non-2xx, and the CSP forbids
  // runtime JavaScript (no unsafe-eval), so the client calls these static
  // helpers instead. Reporting status and body text together keeps the
  // server's JSON error message: duplicate 409, 403, 404 and so on.
  function report(done, status, text, error) {
    try {
      done(JSON.stringify({ status: status, text: text, error: error }));
    } catch (failure) {
      /* the page moved on before the request resolved */
    }
  }

  window.EzaNet = {
    fetch: function (url, method, body, headers, done) {
      var options = { method: method, headers: headers };
      if (body) options.body = body;
      fetch(url, options)
        .then(function (response) {
          return response.text().then(function (text) {
            report(done, response.status, text, null);
          });
        })
        .catch(function (error) {
          report(done, 0, "", String((error && error.message) || error));
        });
    },
    // Netscape HTML import: the FormData body lets the browser set the
    // multipart boundary, which a JSON fetch cannot do.
    upload: function (inputId, token, done) {
      var input = document.getElementById(inputId);
      if (!input || !input.files || !input.files.length) {
        report(done, 0, "", "Choose an HTML bookmarks file first.");
        return;
      }
      var form = new FormData();
      form.append("file", input.files[0]);
      input.value = "";
      var headers = { Accept: "application/json" };
      if (token) headers["X-CSRF-Token"] = token;
      fetch("/api/v1/import", { method: "POST", body: form, headers: headers })
        .then(function (response) {
          return response.text().then(function (text) {
            report(done, response.status, text, null);
          });
        })
        .catch(function (error) {
          report(done, 0, "", String((error && error.message) || error));
        });
    }
  };

  // ------------------------------------------------------ dialog focus ----
  // Dialogs declare role="dialog" aria-modal="true". Keep Tab inside the
  // open dialog instead of letting it walk the page behind.
  var focusableSelector =
    'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), ' +
    'textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

  function openDialogs() {
    return Array.prototype.filter.call(
      document.querySelectorAll('[role="dialog"][aria-modal="true"]'),
      function (node) {
        return node.getClientRects().length > 0 && node.offsetParent !== null;
      }
    );
  }

  function focusableInside(dialog) {
    return Array.prototype.filter.call(dialog.querySelectorAll(focusableSelector), function (node) {
      return node.offsetParent !== null && !node.hasAttribute("aria-hidden");
    });
  }

  document.addEventListener("keydown", function (event) {
    if (event.key !== "Tab") return;
    var dialogs = openDialogs();
    if (!dialogs.length) return;
    var dialog = dialogs[dialogs.length - 1];
    var items = focusableInside(dialog);
    if (!items.length) return;
    var first = items[0];
    var last = items[items.length - 1];
    var active = document.activeElement;
    var inside = dialog.contains(active);
    if (event.shiftKey) {
      if (!inside || active === first || active === dialog) {
        event.preventDefault();
        last.focus();
      }
    } else if (!inside || active === last) {
      event.preventDefault();
      first.focus();
    }
  });

  // ------------------------------------------------------------ keyboard ---
  // Miso sees browser events through its own subscriptions, and keyCode is
  // deprecated and layout dependent. Normalise the key press here instead:
  // event.key is the character the user meant, and the bridge adds the
  // modifier keys and whether focus is in a text field. The client maps keys
  // from the resulting "eza-key" detail and never has to probe the DOM.
  function isEditableTarget(node) {
    if (!node || node.nodeType !== 1) return false;
    var tag = node.tagName;
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return true;
    if (node.isContentEditable) return true;
    if (typeof node.closest === "function") {
      return !!node.closest(
        '[contenteditable=""], [contenteditable="true"], [contenteditable="plaintext-only"]'
      );
    }
    return false;
  }

  function bridgeKeyboard(event) {
    if (event.defaultPrevented || event.isComposing) return;
    var key = event.key;
    if (key === "Tab" || key === "Unidentified" || key === "Dead") return;
    var editable = isEditableTarget(event.target);
    var withModifier = event.ctrlKey || event.metaKey;
    var intercept = false;
    if (withModifier && (key === "k" || key === "K")) intercept = true;
    else if (withModifier && (key === "s" || key === "S")) intercept = true;
    else if (key === "/" && !editable && !withModifier && !event.altKey) intercept = true;
    // Only the shortcuts the browser itself would act on are cancelled: plain
    // typing, j/k movement and Escape keep their native behaviour.
    if (intercept) event.preventDefault();
    window.dispatchEvent(
      new CustomEvent("eza-key", {
        detail: {
          key: key,
          shiftKey: !!event.shiftKey,
          ctrlKey: !!event.ctrlKey,
          metaKey: !!event.metaKey,
          altKey: !!event.altKey,
          editable: editable,
        },
      })
    );
  }

  window.addEventListener("keydown", bridgeKeyboard, false);

  // ------------------------------------------------------ clipboard ------
  // Used by the Miso account page ("Copy bookmarklet"). Returns a boolean.
  window.ezaCopy = function (text) {
    var value = String(text == null ? "" : text);
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        var writing = navigator.clipboard.writeText(value);
        if (writing && typeof writing.catch === "function") writing.catch(function () {});
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
  // The client's screens scroll inside their own containers. Forward the ledger
  // scroll to the window so the Miso subscription can fetch the next page.
  // Coalesce to one event per animation frame: a scroll gesture fires dozens of
  // events and every one of them would run the Miso update function.
  var ledgerScrollFrame = 0;

  function forwardLedgerScroll() {
    ledgerScrollFrame = 0;
    window.dispatchEvent(new Event("scroll"));
  }

  document.addEventListener(
    "scroll",
    function (event) {
      var target = event.target;
      if (!target || !target.classList || !target.classList.contains("ledger")) return;
      if (ledgerScrollFrame) return;
      ledgerScrollFrame = window.requestAnimationFrame(forwardLedgerScroll);
    },
    true
  );

  // The keyboard cursor moves by row index, and the target row may not be in
  // the DOM yet (the ledger is virtualized), so the client asks for an absolute
  // container offset instead of scrollIntoView.
  window.ezaScrollLedger = function (pixels) {
    var ledger = document.querySelector(".ledger");
    if (!ledger) return;
    ledger.scrollTop = Math.max(0, Number(pixels) || 0);
  };

  window.ezaSelectionOffsets = function (containerId) {
    try {
      var container = document.getElementById(containerId);
      var selection = window.getSelection ? window.getSelection() : null;
      if (!container || !selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
      var range = selection.getRangeAt(0);
      if (!container.contains(range.startContainer) || !container.contains(range.endContainer)) return null;
      // Margin pins and other decorative spans carry aria-hidden. Their text is
      // not part of the stored reading copy, so it must not shift offsets.
      function counted(node) {
        if (node.nodeType !== 3) return true;
        var parent = node.parentElement;
        return !(parent && parent.closest && parent.closest('[aria-hidden="true"]'));
      }
      function offsetAt(node, offset) {
        var total = 0;
        var walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
        var current = null;
        while ((current = walker.nextNode())) {
          if (current === node) {
            if (node.nodeType === 3) return counted(node) ? total + offset : total;
            var childTotal = total;
            for (var i = 0; i < offset && i < node.childNodes.length; i++) {
              var child = node.childNodes[i];
              if (child.nodeType === 3 && counted(child)) childTotal += (child.textContent || "").length;
            }
            return childTotal;
          }
          if (current.nodeType === 3 && counted(current)) total += current.textContent.length;
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
