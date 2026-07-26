/*
 * Header probe - dumps the real DOM of the shell's top bar so a customisation can target it.
 *
 * Use this before writing selectors that inject anything into the application header: the markup
 * differs between Unified Interface and the classic web client and between releases, and guessing
 * at ids costs a deploy cycle per guess.
 *
 *   d365-uitest.ps1 -Check checks/probe-header.js [-Classic] [-App <appid>]
 */
'use strict';

async function run({ page, shot }) {
    const info = await page.evaluate(() => {
        function describe(el) {
            const r = el.getBoundingClientRect();
            return {
                tag: el.tagName.toLowerCase(),
                id: el.id || null,
                cls: (el.className && typeof el.className === 'string') ? el.className.slice(0, 70) : null,
                dataId: el.getAttribute('data-id') || null,
                title: el.getAttribute('title') || el.getAttribute('aria-label') || null,
                rect: [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)]
            };
        }

        // Everything clickable that sits in the top 60px of the page, right of centre: that band is
        // the header icon strip in both shells (search / assistant / add / settings / help / avatar).
        const band = [];
        const all = document.querySelectorAll('a, button, span, img, div');
        for (let i = 0; i < all.length; i++) {
            const el = all[i];
            const r = el.getBoundingClientRect();
            if (r.top > 60 || r.height < 12 || r.height > 60) continue;
            if (r.width < 12 || r.width > 120) continue;
            if (r.left < window.innerWidth * 0.45) continue;
            band.push(describe(el));
        }

        // Likely containers for the icon strip, so we know what to append to.
        const containers = [];
        const seen = {};
        const candidates = document.querySelectorAll(
            '[data-id*="topBar"], [data-id*="globalCommandBar"], #navBar, #crmTopBar, ' +
            '#navBarContainer, [class*="navbar" i], [class*="topBar" i], [id*="TabButton" i], ' +
            '[id*="UserInfo" i], [class*="userinfo" i]');
        for (let i = 0; i < candidates.length; i++) {
            const el = candidates[i];
            const key = (el.id || '') + '|' + (el.className || '');
            if (seen[key]) continue;
            seen[key] = 1;
            const d = describe(el);
            d.childCount = el.children.length;
            containers.push(d);
        }

        return {
            viewport: [window.innerWidth, window.innerHeight],
            band: band.slice(0, 40),
            containers: containers.slice(0, 30)
        };
    }).catch((e) => ({ error: String(e) }));

    return {
        checks: [{ name: 'header probe collected', pass: !info.error, detail: info.error || 'ok' }],
        screenshots: [await shot('header-probe')],
        extra: info
    };
}

module.exports = { run };
