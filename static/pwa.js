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
    // Bookmark import: Netscape HTML goes up as multipart (the browser sets
    // the boundary), an eza JSON export goes up as a JSON body. Both answer
    // with the same ImportReport shape from /api/v1/import.
    upload: function (inputId, token, done) {
      var input = document.getElementById(inputId);
      if (!input || !input.files || !input.files.length) {
        report(done, 0, "", "Choose a bookmarks file first.");
        return;
      }
      var file = input.files[0];
      var isJson = /\.json$/i.test(file.name || "");
      input.value = "";
      var headers = { Accept: "application/json" };
      if (token) headers["X-CSRF-Token"] = token;
      var body;
      if (isJson) {
        headers["Content-Type"] = "application/json";
        body = file.text();
      } else {
        body = new FormData();
        body.append("file", file);
      }
      Promise.resolve(body)
        .then(function (payload) {
          return fetch("/api/v1/import", { method: "POST", body: payload, headers: headers });
        })
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

  // The graph route owns the arrow and zoom keys while no text field has
  // focus. Without this, the same press would scroll the panel or zoom the
  // page as well as moving the plate.
  function isGraphKeyTarget(key) {
    if (location.pathname !== "/graph") return false;
    var active = document.activeElement;
    if (isEditableTarget(active)) return false;
    return (
      key === "ArrowUp" ||
      key === "ArrowDown" ||
      key === "ArrowLeft" ||
      key === "ArrowRight" ||
      key === "+" ||
      key === "=" ||
      key === "-" ||
      key === "_" ||
      key === "0" ||
      key === "f" ||
      key === "F"
    );
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
    else if (!editable && !withModifier && !event.altKey) intercept = isGraphKeyTarget(key);
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
  var ledgerScrollTimer = 0;

  function forwardLedgerScroll() {
    if (ledgerScrollFrame) {
      cancelAnimationFrame(ledgerScrollFrame);
      ledgerScrollFrame = 0;
    }
    if (ledgerScrollTimer) {
      clearTimeout(ledgerScrollTimer);
      ledgerScrollTimer = 0;
    }
    window.dispatchEvent(new Event("scroll"));
  }

  document.addEventListener(
    "scroll",
    function (event) {
      var target = event.target;
      if (!target || !target.classList || !target.classList.contains("ledger")) return;
      if (ledgerScrollFrame || ledgerScrollTimer) return;
      ledgerScrollFrame = window.requestAnimationFrame(forwardLedgerScroll);
      // A throttled or hidden tab can postpone requestAnimationFrame past the
      // next interaction, which left the saved ledger offset stale. The timer
      // guarantees one forwarded event within a short window either way.
      ledgerScrollTimer = setTimeout(forwardLedgerScroll, 50);
    },
    true
  );

  // The keyboard cursor moves by row index, and the target row may not be in
  // the DOM yet (the ledger is virtualized), so the client asks for an absolute
  // container offset instead of scrollIntoView.
  // Two frames: the model update that asked for the scroll schedules the DOM
  // patch, and setting scrollTop before the taller content exists would be
  // clamped by the browser. The second frame runs after the patch has landed.
  window.ezaScrollLedger = function (pixels) {
    var target = Math.max(0, Number(pixels) || 0);
    var tries = 0;
    function apply() {
      var ledger = document.querySelector(".ledger");
      if (!ledger) return;
      if (ledger.scrollTop !== target) ledger.scrollTop = target;
      // The restore can run before the taller page has been patched into the
      // DOM, in which case the browser clamps the write. A few frames of
      // retries let the content land and the offset still apply.
      tries += 1;
      if (ledger.scrollTop !== target && tries < 12 && window.requestAnimationFrame) {
        window.requestAnimationFrame(apply);
      }
    }
    if (window.requestAnimationFrame) {
      window.requestAnimationFrame(function () {
        window.requestAnimationFrame(apply);
      });
    } else {
      apply();
    }
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
      // The quote must come from the same text projection as the offsets.
      // container.textContent includes the aria-hidden margin pins, so a
      // selection made after an earlier highlight picked up a digit from the
      // pin and stored the wrong excerpt.
      function countedText() {
        var text = "";
        var walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT);
        var current = null;
        while ((current = walker.nextNode())) {
          if (counted(current)) text += current.textContent;
        }
        return text;
      }
      var quote = countedText().substring(start, end);
      if (!quote.trim()) return null;
      return JSON.stringify({ start: start, end: end, quote: quote });
    } catch (error) {
      return null;
    }
  };

})();
