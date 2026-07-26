/*
 * Smoke check - "does this org still work in a browser at all".
 *
 * Run it after any deployment, and especially after a solution import: it is the cheapest way to
 * catch a customization that throws on load, a web resource that 404s, or a script error that only
 * shows up in the console. Entity-agnostic, so it works on any organisation.
 *
 *   d365-uitest.ps1 -Check checks\smoke.js -App <appid>        (Unified Interface)
 *   d365-uitest.ps1 -Check checks\smoke.js -Classic            (classic web client)
 */
'use strict';

async function run({ page, cfg, shot }) {
    const checks = [];
    const add = (name, pass, detail) => checks.push({ name, pass, detail: detail || '' });

    const info = await page.evaluate(() => {
        const w = window;
        return {
            title: document.title,
            url: location.href,
            // Is a shell actually rendered, rather than an error page that returns HTTP 200?
            hasShell: !!(document.querySelector('[data-id="topBar"]') || document.getElementById('navBar')),
            hasXrm: !!(w.Xrm && (w.Xrm.Utility || w.Xrm.Page)),
            userId: (function () {
                try { return w.Xrm.Utility.getGlobalContext().userSettings.userId; } catch (e) { return null; }
            })(),
            version: (function () {
                try { return w.Xrm.Utility.getGlobalContext().getVersion(); } catch (e) { return null; }
            })(),
            // A platform error page is HTTP 200 with this text on it - easy to mistake for success.
            errorText: (function () {
                const body = (document.body.innerText || '').slice(0, 4000);
                const m = body.match(/(An error has occurred|Something went wrong|Unexpected error|Record is unavailable|You do not have permission)/i);
                return m ? m[0] : null;
            })()
        };
    }).catch((e) => ({ error: String(e) }));

    add('a shell rendered (header present)', !!info.hasShell, 'title: ' + JSON.stringify(info.title));
    add('the Xrm client API is available', !!info.hasXrm,
        'user: ' + (info.userId || 'unknown') + ', version: ' + (info.version || 'unknown'));
    add('no platform error page', !info.errorText, info.errorText || 'none');

    return {
        checks: checks,
        screenshots: [await shot('smoke-' + (cfg.classic ? 'classic' : 'uci'))],
        extra: info
    };
}

module.exports = { run };
