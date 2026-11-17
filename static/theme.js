// Theme bootstrap: set data-theme before first paint so there is no flash.
// External file only (CSP friendly, no inline scripts).
(function () {
  "use strict";
  var KEY = "eza-theme";
  var root = document.documentElement;

  function read() {
    try {
      var v = window.localStorage.getItem(KEY);
      return v === "dark" || v === "light" ? v : null;
    } catch (e) {
      return null;
    }
  }

  function system() {
    try {
      return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches
        ? "dark"
        : "light";
    } catch (e) {
      return "light";
    }
  }

  function apply(theme) {
    root.setAttribute("data-theme", theme);
    // Both theme-color metas must agree with the applied theme: the media-scoped
    // one would otherwise keep describing the OS preference after the reader
    // picked a theme explicitly.
    var color = theme === "dark" ? "#10141F" : "#F2EDE3";
    var metas = document.querySelectorAll('meta[name="theme-color"]');
    for (var i = 0; i < metas.length; i++) metas[i].setAttribute("content", color);
  }

  // Tell the client shell that the OS changed the resolved theme, so the model
  // (graph palette, toggle labels) follows the CSS the page already re-themed.
  function announce(theme) {
    try {
      window.dispatchEvent(new CustomEvent("eza-theme", { detail: { theme: theme } }));
    } catch (e) {
      /* older browsers without CustomEvent still get the CSS theme */
    }
  }

  var stored = read();
  apply(stored || system());

  // Listen for OS changes while the user has not picked an explicit theme.
  try {
    var mq = window.matchMedia("(prefers-color-scheme: dark)");
    var onChange = function () {
      if (!read()) {
        var theme = system();
        apply(theme);
        announce(theme);
      }
    };
    if (mq.addEventListener) mq.addEventListener("change", onChange);
    else if (mq.addListener) mq.addListener(onChange);
  } catch (e) {
    /* ignore */
  }

  window.EzaTheme = {
    get: function () {
      return root.getAttribute("data-theme") === "dark" ? "dark" : "light";
    },
    set: function (theme) {
      var t = theme === "dark" ? "dark" : "light";
      apply(t);
      try {
        window.localStorage.setItem(KEY, t);
      } catch (e) {
        /* storage disabled */
      }
      return t;
    },
    toggle: function () {
      return this.set(this.get() === "dark" ? "light" : "dark");
    }
  };
})();
