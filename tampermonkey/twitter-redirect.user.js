// ==UserScript==
// @name         X to Nitter redirect
// @namespace    https://github.com/brodieve/utilities
// @version      1.1.0
// @description  Redirect x.com and twitter.com URLs to x.tmts.ca Nitter proxy instance
// @author       Brodie
// @homepageURL  https://github.com/brodieve/utilities
// @supportURL   https://github.com/brodieve/utilities/issues
// @downloadURL  https://raw.githubusercontent.com/brodieve/utilities/main/tampermonkey/twitter-redirect.user.js
// @updateURL    https://raw.githubusercontent.com/brodieve/utilities/main/tampermonkey/twitter-redirect.user.js
// @icon         https://x.tmts.ca/favicon.ico
// @match        https://x.com/*
// @match        https://twitter.com/*
// @run-at       document-start
// @noframes
// @grant        none
// ==/UserScript==

(function () {
    'use strict';
    const url = new URL(window.location.href);
    const newUrl = 'https://x.tmts.ca' + url.pathname + url.search + url.hash;
    window.location.replace(newUrl);
})();
