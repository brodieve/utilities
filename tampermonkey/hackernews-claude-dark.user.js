// ==UserScript==
// @name         Hacker News Claude dark theme
// @namespace    https://github.com/brodieve/utilities
// @version      1.0.0
// @description  Dark theme for news.ycombinator.com using Claude's dark mode palette
// @author       Brodie
// @homepageURL  https://github.com/brodieve/utilities
// @supportURL   https://github.com/brodieve/utilities/issues
// @downloadURL  https://raw.githubusercontent.com/brodieve/utilities/main/tampermonkey/hackernews-claude-dark.user.js
// @updateURL    https://raw.githubusercontent.com/brodieve/utilities/main/tampermonkey/hackernews-claude-dark.user.js
// @icon         https://news.ycombinator.com/y18.svg
// @match        https://news.ycombinator.com/*
// @run-at       document-start
// @noframes
// @grant        none
// ==/UserScript==

(function () {
    'use strict';

    // Vote arrows are an SVG with a hard-coded #999 fill, so swap in recoloured copies.
    const arrow = (fill) =>
        "url(\"data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20height='32'" +
        "%20viewBox='0%200%2032%2016'%20width='32'%3E%3Cpath%20d='m2%2027%2014-29%2014%2029z'" +
        "%20fill='%23" + fill + "'/%3E%3C/svg%3E\")";

    const css = `
/* ---------- palette ---------- */
:root {
    color-scheme: dark;
    --cd-bg:            #1f1e1d;
    --cd-surface:       #262624;
    --cd-raised:        #30302e;
    --cd-border:        #3d3d3a;
    --cd-text:          #f5f4ee;
    --cd-text-2:        #c9c5bb;
    --cd-muted:         #8f8b81;
    --cd-faint:         #6b6862;
    --cd-visited:       #97938a;
    --cd-accent:        #d97757;
    --cd-accent-strong: #c96442;
    --cd-accent-soft:   #e0906f;
}

/* ---------- page shell ---------- */
html, body {
    background-color: var(--cd-bg) !important;
    color: var(--cd-text-2) !important;
}

/* HN paints backgrounds with bgcolor attributes; clear them all, then repaint. */
[bgcolor]:not([bgcolor="#ff6600" i]) { background-color: transparent !important; }

#hnmain {
    background-color: var(--cd-surface) !important;
    border: 1px solid var(--cd-border) !important;
    border-radius: 8px !important;
}

body, td, .default, .title, .comment, .admin, .pagetop, .yclinks {
    color: var(--cd-text-2) !important;
}

a:link   { color: var(--cd-text) !important; }
a:visited { color: var(--cd-visited) !important; }

hr { border: 0 !important; border-top: 1px solid var(--cd-border) !important; }

::selection { background: rgba(217, 119, 87, 0.35) !important; color: var(--cd-text) !important; }

/* ---------- header bar ---------- */
/* Claude keeps its chrome neutral and spends the orange on accents, so the
   #ff6600 bar becomes a raised strip with a clay hairline under it. */
#hnmain > tbody > tr:first-child > td,
#hnmain > tr:first-child > td {
    background-color: var(--cd-raised) !important;
    border-bottom: 1px solid var(--cd-accent-strong) !important;
    border-radius: 7px 7px 0 0 !important;
}

#hnmain img[src$="y18.svg"] { border-color: var(--cd-border) !important; }

.pagetop, .pagetop a:link, .pagetop a:visited { color: var(--cd-text-2) !important; }
.pagetop a:hover { color: var(--cd-text) !important; }
.pagetop b.hnname a:link, .pagetop b.hnname a:visited { color: var(--cd-accent) !important; }
.topsel a:link, .topsel a:visited { color: var(--cd-accent) !important; }

/* ---------- story list ---------- */
.rank { color: var(--cd-faint) !important; }

.titleline a:link { color: var(--cd-text) !important; }
.titleline a:visited { color: var(--cd-visited) !important; }
.titleline a:hover { color: var(--cd-accent) !important; }

.sitebit, .sitestr,
.sitebit a:link, .sitebit a:visited { color: var(--cd-muted) !important; }

.subtext, .subline,
.subtext a:link, .subtext a:visited,
.comhead, .comhead a:link, .comhead a:visited,
.age, .age a:link, .age a:visited,
.navs, .navs a:link, .navs a:visited,
.hnmore, .hnmore a:link, .hnmore a:visited {
    color: var(--cd-muted) !important;
}
.subtext a:hover, .comhead a:hover, .age a:hover, .navs a:hover {
    color: var(--cd-text-2) !important;
}

.score { color: var(--cd-accent-soft) !important; }
.hnuser:link, .hnuser:visited { color: var(--cd-text-2) !important; }
.hnuser:hover { color: var(--cd-accent) !important; }

.morelink:link, .morelink:visited {
    color: var(--cd-accent) !important;
    font-weight: bold !important;
}
.morelink:hover { text-decoration: underline !important; }

/* ---------- vote arrows ---------- */
.votearrow { background-image: ${arrow('8f8b81')} !important; }
.votelinks a:hover .votearrow { background-image: ${arrow('d97757')} !important; }

/* ---------- comments ---------- */
.toptext { color: var(--cd-text-2) !important; }
.togg { color: var(--cd-muted) !important; }
.togg:hover { color: var(--cd-accent) !important; }
.reply a:link, .reply a:visited { color: var(--cd-muted) !important; }
.reply a:hover { color: var(--cd-accent) !important; }

/* HN dims downvoted comments with c00..cdd; re-grade them for a dark ground. */
.c00, .c00 a:link, .c00 a:visited { color: #e8e6df !important; }
.c5a, .c5a a:link, .c5a a:visited { color: #cfccc3 !important; }
.c73, .c73 a:link, .c73 a:visited { color: #bcb8ae !important; }
.c82, .c82 a:link, .c82 a:visited { color: #a9a59b !important; }
.c88, .c88 a:link, .c88 a:visited { color: #9d9990 !important; }
.c9c, .c9c a:link, .c9c a:visited { color: #8b877e !important; }
.cae, .cae a:link, .cae a:visited { color: #7a766e !important; }
.cbe, .cbe a:link, .cbe a:visited { color: #6b675f !important; }
.cce, .cce a:link, .cce a:visited { color: #5c5952 !important; }
.cdd, .cdd a:link, .cdd a:visited { color: #4e4b45 !important; }

/* Links inside full-strength comments and text posts get the accent. */
.commtext.c00 a:link, .commtext.c00 a:visited,
.toptext a:link, .toptext a:visited { color: var(--cd-accent-soft) !important; }

.commtext pre, .toptext pre {
    background-color: var(--cd-raised) !important;
    border: 1px solid var(--cd-border) !important;
    border-radius: 6px !important;
    padding: 8px !important;
}
.commtext code, .toptext code { color: var(--cd-text) !important; }

/* Inline <font color> is used for helper text such as the "help" link. */
font[color] { color: var(--cd-muted) !important; }

/* ---------- forms ---------- */
input, textarea, select {
    background-color: var(--cd-raised) !important;
    color: var(--cd-text) !important;
    border: 1px solid var(--cd-border) !important;
    border-radius: 6px !important;
    padding: 4px 6px !important;
}
input:focus, textarea:focus, select:focus {
    border-color: var(--cd-accent) !important;
    outline: none !important;
    box-shadow: 0 0 0 2px rgba(217, 119, 87, 0.25) !important;
}
::placeholder { color: var(--cd-faint) !important; }

input[type='submit'], button {
    background-color: var(--cd-accent-strong) !important;
    color: #faf9f5 !important;
    border: 1px solid var(--cd-accent-strong) !important;
    border-radius: 8px !important;
    padding: 5px 12px !important;
    cursor: pointer !important;
}
input[type='submit']:hover, button:hover {
    background-color: var(--cd-accent) !important;
    border-color: var(--cd-accent) !important;
}
input[type='checkbox'], input[type='radio'] {
    padding: 0 !important;
    border: 0 !important;
    accent-color: var(--cd-accent-strong) !important;
}

/* ---------- footer ---------- */
td[bgcolor="#ff6600" i] { background-color: rgba(217, 119, 87, 0.45) !important; }

.yclinks, .yclinks a:link, .yclinks a:visited { color: var(--cd-muted) !important; }
.yclinks a:hover { color: var(--cd-accent) !important; }

/* ---------- mobile ---------- */
@media only screen and (min-width: 300px) and (max-width: 750px) {
    #hnmain { border: 0 !important; border-radius: 0 !important; }
    #hnmain > tbody > tr:first-child > td,
    #hnmain > tr:first-child > td { border-radius: 0 !important; }
}
`;

    const style = document.createElement('style');
    style.id = 'hn-claude-dark';
    style.textContent = css;

    // At document-start neither <head> nor even <html> is guaranteed to exist yet,
    // so attach to whichever appears first and watch for it if there is nothing.
    const install = () => {
        const root = document.head || document.documentElement;
        if (!root) return false;
        root.appendChild(style);
        return true;
    };

    if (!install()) {
        const observer = new MutationObserver(() => {
            if (install()) observer.disconnect();
        });
        observer.observe(document, { childList: true, subtree: true });
    }

    // Once the real head exists, move the sheet there so it stays last in the cascade.
    document.addEventListener('DOMContentLoaded', () => {
        if (document.head && style.parentNode !== document.head) {
            document.head.appendChild(style);
        }
    }, { once: true });
})();
