/* ============================================================================
   Juniper Design — Theme Manager
   ----------------------------------------------------------------------------
   Self-contained light/dark theme switcher.

   Behaviour:
     • On first visit, follows OS preference via prefers-color-scheme.
     • User's explicit choice is stored in localStorage under "juniper.theme"
       and overrides OS preference until they toggle back.
     • Toggle button: any element with id="juniper-theme-toggle" (or pass a
       custom selector via window.JuniperTheme.bind(selector)) gets wired up.
     • Emits a "juniper-theme-change" CustomEvent on the window whenever the
       theme changes, with detail = { theme: "light" | "dark" }.
       Use this to retint canvas-rendered content (e.g. three.js scenes).

   Usage:
     <script src="juniper-theme.js"></script>
     <button id="juniper-theme-toggle" aria-label="Toggle theme">
       <span class="juniper-theme-icon">🌙</span>
     </button>

   No build step; no dependencies. ~2 KB.
   ============================================================================ */

(function () {
  'use strict';

  var STORAGE_KEY = 'juniper.theme';
  var EVENT_NAME = 'juniper-theme-change';
  var DEFAULT_SELECTOR = '#juniper-theme-toggle';
  var ICON_SELECTOR = '.juniper-theme-icon';

  // Pick initial theme: stored > OS preference > light fallback
  function pickInitialTheme() {
    try {
      var stored = localStorage.getItem(STORAGE_KEY);
      if (stored === 'light' || stored === 'dark') return stored;
    } catch (_) { /* localStorage may be blocked */ }
    if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
      return 'dark';
    }
    return 'light';
  }

  // Apply a theme to <html data-theme="…"> and announce the change.
  function applyTheme(theme, announce) {
    document.documentElement.setAttribute('data-theme', theme);
    updateIcons(theme);
    if (announce !== false) {
      window.dispatchEvent(new CustomEvent(EVENT_NAME, { detail: { theme: theme } }));
    }
  }

  function getTheme() {
    return document.documentElement.getAttribute('data-theme') || 'light';
  }

  function setTheme(theme, persist) {
    if (theme !== 'light' && theme !== 'dark') return;
    applyTheme(theme, true);
    if (persist !== false) {
      try { localStorage.setItem(STORAGE_KEY, theme); } catch (_) {}
    }
  }

  function toggle() {
    setTheme(getTheme() === 'dark' ? 'light' : 'dark', true);
  }

  function updateIcons(theme) {
    var icons = document.querySelectorAll(ICON_SELECTOR);
    var glyph = theme === 'dark' ? '☀' : '🌙';
    for (var i = 0; i < icons.length; i++) {
      icons[i].textContent = glyph;
    }
  }

  function bind(selector) {
    var nodes = document.querySelectorAll(selector || DEFAULT_SELECTOR);
    for (var i = 0; i < nodes.length; i++) {
      // Avoid double-binding
      if (nodes[i].dataset.juniperBound === '1') continue;
      nodes[i].dataset.juniperBound = '1';
      nodes[i].addEventListener('click', toggle);
    }
    updateIcons(getTheme());
  }

  // Apply ASAP to avoid a flash of the wrong theme.
  applyTheme(pickInitialTheme(), false);

  // Wire up the toggle button once the DOM is ready.
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { bind(); });
  } else {
    bind();
  }

  // Re-respond to OS-level theme changes if the user has NOT made an explicit choice.
  if (window.matchMedia) {
    var mq = window.matchMedia('(prefers-color-scheme: dark)');
    var listener = function (e) {
      try {
        if (localStorage.getItem(STORAGE_KEY)) return;  // user choice wins
      } catch (_) {}
      applyTheme(e.matches ? 'dark' : 'light', true);
    };
    if (mq.addEventListener) { mq.addEventListener('change', listener); }
    else if (mq.addListener) { mq.addListener(listener); }  // older browsers
  }

  // Public API for projects that want to bind to a custom selector or react in JS.
  window.JuniperTheme = {
    get:     getTheme,
    set:     setTheme,
    toggle:  toggle,
    bind:    bind,
    EVENT:   EVENT_NAME,
    STORAGE: STORAGE_KEY,
  };
})();
