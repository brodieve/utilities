// ==UserScript==
// @name         Drudge, Reskinned
// @namespace    https://github.com/brodieve/utilities
// @version      1.2.0
// @description  Modern tech-news styling for drudgereport.com: clean type, card columns, orange accent, light/dark modes.
// @author       Brodie
// @homepageURL  https://github.com/brodieve/utilities
// @supportURL   https://github.com/brodieve/utilities/issues
// @downloadURL  https://raw.githubusercontent.com/brodieve/utilities/main/tampermonkey/drudge-reskin.user.js
// @updateURL    https://raw.githubusercontent.com/brodieve/utilities/main/tampermonkey/drudge-reskin.user.js
// @match        *://drudgereport.com/*
// @match        *://www.drudgereport.com/*
// @run-at       document-start
// @grant        none
// ==/UserScript==

// No GM_* APIs: works in Userscripts (iOS/macOS Safari), Tampermonkey, Violentmonkey, etc.

(function () {
  'use strict';

  // ---------- Settings (persisted in this site's localStorage) ----------
  const store = {
    get(key, fallback) {
      try {
        const v = localStorage.getItem('dr-reskin:' + key);
        return v === null ? fallback : JSON.parse(v);
      } catch (e) { return fallback; }
    },
    set(key, value) {
      try { localStorage.setItem('dr-reskin:' + key, JSON.stringify(value)); } catch (e) { /* ignore */ }
    },
  };

  const THEMES = ['auto', 'light', 'dark'];
  let theme = store.get('theme', 'auto');
  let hideAds = store.get('hideAds', true);
  const root = document.documentElement;

  const applySettings = () => {
    root.dataset.drTheme = theme;
    root.classList.toggle('dr-noads', hideAds);
    const btn = document.querySelector('.dr-theme-btn');
    if (btn) btn.textContent = theme === 'auto' ? 'Auto' : theme === 'dark' ? 'Dark' : 'Light';
    const adBtn = document.querySelector('.dr-ads-btn');
    if (adBtn) adBtn.textContent = hideAds ? 'Ads off' : 'Ads on';
  };
  const cycleTheme = () => {
    theme = THEMES[(THEMES.indexOf(theme) + 1) % THEMES.length];
    store.set('theme', theme);
    applySettings();
  };
  const toggleAds = () => {
    hideAds = !hideAds;
    store.set('hideAds', hideAds);
    applySettings();
  };
  applySettings();

  // Menu commands only where the manager supports them (Tampermonkey/Violentmonkey).
  if (typeof GM_registerMenuCommand === 'function') {
    GM_registerMenuCommand('Cycle theme (auto / light / dark)', cycleTheme);
    GM_registerMenuCommand('Toggle ad hiding', toggleAds);
  }

  const addStyle = (css) => {
    const el = document.createElement('style');
    el.id = 'dr-reskin-style';
    el.textContent = css;
    (document.head || root).appendChild(el);
    // At document-start <head> may not exist yet; move the style into it once it does.
    if (!document.head) {
      document.addEventListener('DOMContentLoaded', () => document.head && document.head.appendChild(el), { once: true });
    }
  };

  // ---------- Fonts ----------
  const fonts = document.createElement('link');
  fonts.rel = 'stylesheet';
  fonts.href =
    'https://fonts.googleapis.com/css2?family=Barlow+Condensed:wght@500;600;700&family=Inter:wght@400;500;600;700&display=swap';
  (document.head || root).appendChild(fonts);

  // ---------- Styles (injected before first paint) ----------
  const DARK_VARS = `
    --dr-bg: #0f0f10; --dr-surface: #19191b; --dr-text: #ececec;
    --dr-muted: #9a9a9e; --dr-rule: #2b2b2f; --dr-shadow: none;`;

  addStyle(`
    :root {
      --dr-accent: #ff4e00;
      --dr-bg: #f3f3f1; --dr-surface: #ffffff; --dr-text: #161616;
      --dr-muted: #62626a; --dr-rule: #e4e4e0;
      --dr-shadow: 0 1px 2px rgba(0,0,0,.06), 0 2px 8px rgba(0,0,0,.04);
      --dr-sans: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      --dr-display: 'Barlow Condensed', 'Arial Narrow', 'Helvetica Neue', sans-serif;
      color-scheme: light;
    }
    :root[data-dr-theme="dark"] { ${DARK_VARS} color-scheme: dark; }
    @media (prefers-color-scheme: dark) {
      :root[data-dr-theme="auto"] { ${DARK_VARS} color-scheme: dark; }
    }

    /* ---- Base reset over Drudge's 1990s markup ---- */
    html, body { background: var(--dr-bg) !important; color: var(--dr-text) !important; }
    body {
      margin: 0 !important; padding: 0 0 56px !important;
      font: 15px/1.5 var(--dr-sans) !important;
      -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
    }
    body * { font-family: var(--dr-sans) !important; }
    body font, body tt, body b, body span { font-size: inherit !important; color: inherit !important; }
    table, tbody, tr, td, center, div { background: transparent !important; border-color: var(--dr-rule) !important; }

    a, a:link { color: var(--dr-text) !important; text-decoration: none !important; transition: color .12s; }
    a:visited { color: var(--dr-muted) !important; }
    a:hover, a:focus-visible { color: var(--dr-accent) !important; }

    hr {
      border: 0 !important; border-top: 1px solid var(--dr-rule) !important;
      height: 0 !important; margin: 14px 0 !important; background: none !important; color: transparent !important;
    }
    img { max-width: 100% !important; height: auto !important; border-radius: 4px; }
    img[src*="logo" i] { display: none !important; }

    /* ---- Page width ---- */
    body.dr-on > :not(.dr-bar):not(script):not(style):not(link) {
      max-width: 1240px; margin-left: auto !important; margin-right: auto !important;
      padding-left: 20px; padding-right: 20px; box-sizing: border-box;
    }

    /* ---- Top bar ---- */
    .dr-bar {
      position: sticky; top: 0; z-index: 2147483000;
      display: flex; align-items: center; gap: 12px;
      height: 52px; padding: 0 20px; margin-bottom: 24px;
      background: #111 !important; color: #fff !important;
      border-bottom: 3px solid var(--dr-accent) !important;
    }
    .dr-bar .dr-dot { width: 14px; height: 14px; border-radius: 50%; background: var(--dr-accent); flex: none; }
    .dr-bar .dr-mark {
      font: 700 26px/1 var(--dr-display) !important; letter-spacing: .06em;
      text-transform: uppercase; color: #fff !important;
    }
    .dr-bar .dr-date {
      margin-left: auto; font-size: 11px !important; font-weight: 600;
      letter-spacing: .12em; text-transform: uppercase; color: #9a9a9e !important;
    }
    .dr-bar .dr-btn {
      font: 600 11px/1 var(--dr-sans) !important; letter-spacing: .08em; text-transform: uppercase;
      color: #fff !important; background: transparent !important;
      border: 1px solid #444 !important; border-radius: 999px; padding: 7px 12px; cursor: pointer;
    }
    .dr-bar .dr-btn:hover { border-color: var(--dr-accent) !important; color: var(--dr-accent) !important; }

    /* ---- Lead story ---- */
    a.dr-hero {
      display: block !important; max-width: 920px; margin: 8px auto 28px !important;
      text-align: center; text-wrap: balance;
      font: 700 clamp(32px, 5.2vw, 58px)/1.02 var(--dr-display) !important;
      letter-spacing: .005em; color: var(--dr-text) !important;
    }
    a.dr-hero::before {
      content: 'Top story'; display: block; margin-bottom: 12px;
      font: 700 12px/1 var(--dr-sans) !important; letter-spacing: .14em;
      text-transform: uppercase; color: var(--dr-accent);
    }
    a.dr-hero:hover { color: var(--dr-accent) !important; }

    /* ---- Three columns as cards ---- */
    table.dr-cols-table { border-collapse: separate !important; border-spacing: 16px 0 !important; width: calc(100% + 32px) !important; margin: 0 -16px !important; }
    td.dr-col {
      vertical-align: top !important; text-align: left !important;
      background: var(--dr-surface) !important; box-shadow: var(--dr-shadow);
      border-radius: 8px; padding: 18px 20px 20px !important;
    }
    td.dr-spacer { display: none !important; }
    td.dr-col br { display: none !important; }
    td.dr-col center { text-align: left !important; }

    td.dr-col a.dr-headline {
      display: block !important; padding: 10px 0 !important;
      border-bottom: 1px solid var(--dr-rule) !important;
      font: 600 18px/1.18 var(--dr-display) !important; letter-spacing: .01em;
    }
    td.dr-col a.dr-imglink { display: block !important; margin: 12px 0 4px !important; }
    td.dr-col a.dr-imglink img { width: 100%; object-fit: cover; }

    td.dr-col a.dr-short {
      display: inline-block !important; margin: 0 4px 6px 0 !important; padding: 5px 9px !important;
      font: 600 11px/1.2 var(--dr-sans) !important; letter-spacing: .05em; text-transform: uppercase;
      color: var(--dr-muted) !important; border: 1px solid var(--dr-rule) !important; border-radius: 999px;
    }
    td.dr-col a.dr-short:hover { border-color: var(--dr-accent) !important; color: var(--dr-accent) !important; }

    /* ---- Drudge's red "hot" links → accent ---- */
    a.dr-hot, a.dr-hot * { color: var(--dr-accent) !important; }
    td.dr-col a.dr-hot.dr-headline { border-left: 3px solid var(--dr-accent) !important; padding-left: 10px !important; }

    /* ---- Ads ---- */
    :root.dr-noads [id^="div-gpt-ad"], :root.dr-noads ins.adsbygoogle,
    :root.dr-noads iframe[id^="google_ads"], :root.dr-noads [id*="taboola" i],
    :root.dr-noads [class*="taboola" i], :root.dr-noads [id*="outbrain" i] { display: none !important; }

    /* ---- Clean-up ---- */
    .dr-gone, br.dr-br-dup { display: none !important; }
    :root.dr-noads .dr-empty { display: none !important; }

    /* ---- Mobile: stack the columns ---- */
    @media (max-width: 820px) {
      table.dr-cols-table, table.dr-cols-table > tbody { display: block !important; width: auto !important; margin: 0 !important; }
      tr.dr-cols-row { display: flex !important; flex-direction: column; gap: 16px; }
      td.dr-col { display: block !important; width: auto !important; }
      .dr-bar .dr-date { display: none; }
    }
  `);

  // ---------- DOM tagging (heuristic, idempotent) ----------
  const RED = /^(red|#f00|#ff0000|#ff0000ff|rgb\(\s*255,\s*0,\s*0\s*\))$/;

  function sizeScore(el) {
    const s = el.getAttribute('size');
    if (s) {
      const n = parseInt(s, 10) || 0;
      return s.trim().startsWith('+') ? 3 + n : n;
    }
    const m = /font-size:\s*(\d+)/i.exec(el.getAttribute('style') || '');
    return m ? parseInt(m[1], 10) / 6 : 0;
  }

  // Lead story = the link Drudge itself renders largest. Measured with our stylesheet
  // switched off for an instant, so it works whatever markup Drudge uses (font tags,
  // classes, inline styles). Also catches red "hot" links by their rendered colour.
  function toRgb(c) {
    c = (c || '').trim().toLowerCase();
    if (c === 'red') return [255, 0, 0];
    const hex = /^#([0-9a-f]{3}|[0-9a-f]{6})/.exec(c);
    if (hex) {
      const h = hex[1].length === 3 ? hex[1].replace(/./g, '$&$&') : hex[1];
      return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
    }
    return (c.match(/[\d.]+/g) || []).map(Number);
  }

  function measureOriginal() {
    if (root.dataset.drMeasured) return;
    root.dataset.drMeasured = '1';
    const style = document.getElementById('dr-reskin-style');
    const parent = style && style.parentNode;
    const next = style && style.nextSibling;
    if (style) style.remove();
    try {
      let best = null;
      let bestSize = 0;
      const sizes = [];
      for (const a of document.querySelectorAll('a')) {
        if (a.closest('.dr-bar')) continue;
        if (a.textContent.replace(/\s+/g, ' ').trim().length < 8) continue;
        let size = 0;
        let red = false;
        for (const el of [a, ...a.querySelectorAll('*')]) {
          const cs = getComputedStyle(el);
          size = Math.max(size, parseFloat(cs.fontSize) || 0);
          const [r, g, b] = toRgb(cs.color);
          if (r > 180 && g < 90 && b < 90) red = true;
        }
        if (red) a.classList.add('dr-hot');
        sizes.push(size);
        if (size > bestSize) { best = a; bestSize = size; }
      }
      sizes.sort((x, y) => x - y);
      const median = sizes[Math.floor(sizes.length / 2)] || 0;
      if (best && bestSize >= median * 1.4) best.classList.add('dr-hero');
    } finally {
      if (style && parent) parent.insertBefore(style, next && next.parentNode === parent ? next : null);
    }
  }

  // Fallback only if measuring found nothing (e.g. the page was hidden while measuring).
  function tagHero() {
    if (document.querySelector('.dr-hero')) return;
    let best = null;
    let bestScore = 4.9;
    for (const el of document.querySelectorAll('font[size], [style*="font-size"]')) {
      const link = el.closest('a') || el.querySelector('a');
      if (!link || link.closest('.dr-col') || !link.textContent.trim()) continue;
      const score = sizeScore(el);
      if (score > bestScore) { best = link; bestScore = score; }
    }
    if (best) best.classList.add('dr-hero');
  }

  // ---------- Clean-up: "WEB VERSION" link and empty space ----------
  const AD_SEL = '[id^="div-gpt-ad"], ins.adsbygoogle, iframe[id^="google_ads"], [id*="taboola" i], [class*="taboola" i], [id*="outbrain" i]';
  const SKIP_TEXT = 'script, style, noscript, template, .dr-gone';

  function visibleText(el) {
    let out = '';
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      if (!n.parentElement.closest(SKIP_TEXT)) out += n.nodeValue;
    }
    return out;
  }

  function hasRealMedia(el) {
    for (const m of el.querySelectorAll('img, video, svg, picture, canvas, iframe, object, embed, hr, input, button')) {
      if (m.closest('.dr-gone') || m.closest(AD_SEL)) continue;
      if (m.tagName === 'IMG' && ((+m.getAttribute('width') || 99) <= 2 || (+m.getAttribute('height') || 99) <= 2)) continue;
      return true;
    }
    return false;
  }

  function gone(el) {
    el.classList.add('dr-gone');
    el.style.setProperty('display', 'none', 'important');
  }

  const WEB_VERSION = /^\s*web\s*version\s*$/i;
  function hideWebVersion() {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const hits = [];
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      if (/web|version/i.test(n.nodeValue)) hits.push(n);
    }
    for (const n of hits) {
      let el = n.parentElement;
      if (!el || el.closest('.dr-gone, .dr-bar, script, style')) continue;
      // Climb to the outermost wrapper that holds nothing but this label.
      while (el.parentElement && el.parentElement !== document.body &&
             WEB_VERSION.test(visibleText(el.parentElement)) && !hasRealMedia(el.parentElement)) {
        el = el.parentElement;
      }
      if (WEB_VERSION.test(visibleText(el))) gone(el);
    }
    for (const el of document.querySelectorAll('input[value], img[alt]')) {
      if (WEB_VERSION.test(el.value || el.alt || '')) gone(el.closest('a') || el);
    }
  }

  // Wrappers with no text and no real media (typically ad slots or spacers) collapse
  // while ads are hidden; they reappear if "Ads on" is chosen.
  function collapseEmpties() {
    for (const el of document.querySelectorAll('div, center, p, section, aside, span, font, figure, header')) {
      if (el.closest('.dr-bar, .dr-col')) continue;
      el.classList.toggle('dr-empty', !visibleText(el).trim() && !hasRealMedia(el));
    }
  }

  // Runs of <br> (and leading ones) outside the columns make big blank gaps.
  function collapseBreaks() {
    for (const br of document.querySelectorAll('br')) {
      if (br.closest('.dr-col')) continue;
      let p = br.previousSibling;
      while (p && ((p.nodeType === 3 && !p.nodeValue.trim()) ||
                   (p.nodeType === 1 && p.matches('.dr-gone, .dr-empty, script, style')))) {
        p = p.previousSibling;
      }
      br.classList.toggle('dr-br-dup', !p || p.nodeName === 'BR');
    }
  }

  function tagColumns() {
    if (document.querySelector('.dr-cols-row')) return;
    const rows = [...document.querySelectorAll('tr')].filter((tr) => {
      const cells = [...tr.children].filter((c) => c.tagName === 'TD');
      return cells.filter((td) => td.querySelectorAll('a').length >= 5).length >= 3;
    });
    // Keep the innermost qualifying rows (outer layout tables also "contain" the links).
    const innermost = rows.filter((tr) => !rows.some((o) => o !== tr && tr.contains(o)));
    for (const tr of innermost) {
      tr.classList.add('dr-cols-row');
      tr.closest('table')?.classList.add('dr-cols-table');
      for (const td of tr.children) {
        if (td.tagName !== 'TD') continue;
        td.classList.add(td.querySelectorAll('a').length >= 5 ? 'dr-col' : 'dr-spacer');
      }
    }
  }

  function tagLinks() {
    for (const a of document.querySelectorAll('td.dr-col a:not([data-dr])')) {
      a.dataset.dr = '1';
      if (a.classList.contains('dr-hero')) continue;
      const text = a.textContent.replace(/\s+/g, ' ').trim();
      if (a.querySelector('img') && text.length < 5) a.classList.add('dr-imglink');
      else if (text.length < 28) a.classList.add('dr-short');
      else a.classList.add('dr-headline');
    }
  }

  function tagHot() {
    for (const el of document.querySelectorAll('font[color]:not([data-drc]), [style*="color"]:not([data-drc])')) {
      el.dataset.drc = '1';
      const style = /(?:^|;)\s*color:\s*([^;]+)/i.exec(el.getAttribute('style') || '');
      const c = (el.getAttribute('color') || (style && style[1]) || '').trim().toLowerCase();
      if (!RED.test(c)) continue;
      (el.closest('a') || el.querySelector('a') || el).classList.add('dr-hot');
    }
  }

  function addBar() {
    if (document.querySelector('.dr-bar') || !document.body) return;
    const bar = document.createElement('header');
    bar.className = 'dr-bar';
    bar.innerHTML =
      '<span class="dr-dot"></span><span class="dr-mark">Drudge</span>' +
      '<span class="dr-date"></span><button class="dr-ads-btn dr-btn" type="button"></button>' +
      '<button class="dr-theme-btn dr-btn" type="button"></button>';
    bar.querySelector('.dr-date').textContent = new Date().toLocaleDateString(undefined, {
      weekday: 'long', month: 'long', day: 'numeric',
    });
    bar.querySelector('.dr-theme-btn').addEventListener('click', cycleTheme);
    bar.querySelector('.dr-ads-btn').addEventListener('click', toggleAds);
    document.body.prepend(bar);
    document.body.classList.add('dr-on');
    applySettings();
  }

  function run() {
    measureOriginal(); // once, before anything else changes the page
    addBar();
    tagHot();          // attribute-based pass for anything added later
    tagHero();
    tagColumns();
    tagLinks();
    hideWebVersion();
    collapseEmpties();
    collapseBreaks();
  }

  function start() {
    run();
    let timer = 0;
    new MutationObserver(() => {
      clearTimeout(timer);
      timer = setTimeout(run, 200);
    }).observe(document.body, { childList: true, subtree: true });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, { once: true });
  } else {
    start();
  }
})();
