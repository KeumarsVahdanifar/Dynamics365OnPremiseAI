/*
 * Dynamics 365 On-Premise AI Toolkit - UI test runner - drive a real Dynamics 365 CE (on-prem IFD/ADFS) org in a real browser.
 *
 * Why this exists: d365.ps1 can prove the SERVER is right (component exists, ribbon merged, count
 * query returns 2). It cannot prove the CLIENT renders it. Ribbon buttons, injected DOM, web
 * resource 404s and JavaScript errors are only visible in a browser, and guessing at them wastes
 * far more time than automating them.
 *
 * It uses a browser already installed on the machine (Chrome or Edge) via Playwright's channel
 * support, so nothing is downloaded.
 *
 *   node uitest.js --url https://host/org --user DOMAIN\\user --pass ****            \
 *                  [--app <appid>] [--classic] [--goto <relative-url>]              \
 *                  [--check checks/foo.js] [--out <dir>] [--headed] [--keep-open]
 *
 * Credentials: pass them in, or let d365-uitest.ps1 decrypt the cached DPAPI credential and hand
 * them over as environment variables. They are never written to disk by this script.
 *
 * Output: one JSON document on stdout - console errors, failed requests, check results and the
 * paths of the screenshots taken. Exit code 1 if any check failed.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

/* ------------------------------------------------------------------ arguments */

function parseArgs(argv) {
    const out = { flags: {}, bool: {} };
    for (let i = 2; i < argv.length; i++) {
        const a = argv[i];
        if (!a.startsWith('--')) continue;
        const key = a.slice(2);
        const next = argv[i + 1];
        if (next && !next.startsWith('--')) { out.flags[key] = next; i++; }
        else { out.bool[key] = true; }
    }
    return out;
}

const args = parseArgs(process.argv);
const cfg = {
    url: (args.flags.url || process.env.DVXRM_URL || '').replace(/\/+$/, ''),
    user: args.flags.user || process.env.DVXRM_USER || '',
    pass: args.flags.pass || process.env.DVXRM_PASS || '',
    app: args.flags.app || process.env.DVXRM_APPID || '',
    goto: args.flags.goto || '',
    check: args.flags.check || '',
    out: args.flags.out || path.join(process.cwd(), 'uitest-out'),
    channel: args.flags.channel || 'chrome',
    settleMs: parseInt(args.flags.settle || '9000', 10),
    classic: !!args.bool.classic,
    headed: !!args.bool.headed,
    keepOpen: !!args.bool['keep-open']
};

if (!cfg.url) { fail('missing --url (or DVXRM_URL)'); }
if (!cfg.user || !cfg.pass) { fail('missing --user/--pass (or DVXRM_USER/DVXRM_PASS)'); }

function fail(msg) {
    console.log(JSON.stringify({ ok: false, error: msg }, null, 2));
    process.exit(2);
}

/* ---------------------------------------------------------------------- login */

/**
 * IFD orgs land on an ADFS forms page. Field ids have been stable across ADFS versions
 * (#userNameInput / #passwordInput / #submitButton) but fall back to types so a themed page or a
 * different STS still works. If the org answers with integrated auth instead, httpCredentials on
 * the context has already dealt with it and there is no form to fill.
 */
async function signIn(page, report) {
    const userSelectors = ['#userNameInput', 'input[name="UserName"]', 'input[type="email"]',
                           'input[type="text"]:not([type="hidden"])'];
    const passSelectors = ['#passwordInput', 'input[name="Password"]', 'input[type="password"]'];
    const submitSelectors = ['#submitButton', 'span#submitButton', 'input[type="submit"]',
                             'button[type="submit"]'];

    const pass = await firstVisible(page, passSelectors, 8000);
    if (!pass) { report.login = 'no sign-in form (already authenticated or integrated auth)'; return; }

    const user = await firstVisible(page, userSelectors, 3000);
    if (user) { await user.fill(cfg.user); }
    await pass.fill(cfg.pass);

    const submit = await firstVisible(page, submitSelectors, 3000);
    if (submit) { await submit.click(); } else { await pass.press('Enter'); }
    await page.waitForLoadState('domcontentloaded').catch(() => {});
    report.login = 'submitted credentials to the sign-in form';
}

async function firstVisible(page, selectors, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        for (const sel of selectors) {
            const loc = page.locator(sel).first();
            try { if (await loc.isVisible({ timeout: 250 })) { return loc; } } catch (e) { /* next */ }
        }
        await page.waitForTimeout(250);
    }
    return null;
}

/* ---------------------------------------------------------------------- main */

(async () => {
    fs.mkdirSync(cfg.out, { recursive: true });

    const report = {
        ok: true, url: cfg.url, shell: cfg.classic ? 'classic' : 'uci',
        login: null, pages: [], checks: [], screenshots: [], errors: []
    };

    const browser = await chromium.launch({ channel: cfg.channel, headless: !cfg.headed });
    const context = await browser.newContext({
        httpCredentials: { username: cfg.user, password: cfg.pass },
        viewport: { width: 1500, height: 950 },
        ignoreHTTPSErrors: true
    });

    // Console + network failures are the whole point: a 404 on a web resource or a thrown
    // exception inside a ribbon rule is invisible from the server side.
    const consoleErrors = [];
    const failedRequests = [];
    context.on('console', (msg) => {
        if (msg.type() !== 'error') { return; }
        // A bare "Failed to load resource: 404" is useless without the URL, and the URL only
        // lives on the message location.
        const loc = msg.location && msg.location();
        const where = loc && loc.url ? '  <- ' + trim(loc.url, 200) : '';
        consoleErrors.push(trim(msg.text()) + where);
    });
    context.on('weberror', (e) => consoleErrors.push('uncaught: ' + trim(String(e.error()))));
    context.on('requestfailed', (req) => {
        failedRequests.push(req.method() + ' ' + trim(req.url(), 200) + ' - ' +
                            ((req.failure() && req.failure().errorText) || 'failed'));
    });
    // Every 4xx/5xx with its URL: a console line saying "404 (Not Found)" without the URL is
    // useless, and a missing web resource is the single most common cause of "nothing happens".
    context.on('response', (res) => {
        if (res.status() >= 400) {
            failedRequests.push(res.status() + ' ' + res.request().method() + ' ' + trim(res.url(), 220));
        }
    });

    const page = await context.newPage();

    try {
        const target = cfg.goto
            ? cfg.url + (cfg.goto.startsWith('/') ? '' : '/') + cfg.goto
            : cfg.classic
                ? cfg.url + '/main.aspx?forceClassic=1'
                : cfg.url + '/main.aspx' + (cfg.app ? '?appid=' + cfg.app : '?forceUCI=1');

        report.target = target;
        await page.goto(target, { waitUntil: 'domcontentloaded', timeout: 90000 });
        await signIn(page, report);
        await page.waitForLoadState('domcontentloaded').catch(() => {});
        // The shell keeps building after load: ribbon evaluation, our injected bell, then polling.
        await page.waitForTimeout(cfg.settleMs);

        await dismissOverlays(page, report);
        report.pages.push({ url: page.url(), title: await page.title().catch(() => '') });
        report.screenshots.push(await shot(page, cfg.out, 'shell'));

        if (cfg.check) {
            const mod = require(path.resolve(cfg.check));
            const res = await mod.run({ page, context, cfg, shot: (n) => shot(page, cfg.out, n) });
            report.checks = res.checks || [];
            if (res.screenshots) { report.screenshots.push(...res.screenshots); }
            if (res.extra) { report.extra = res.extra; }
        }
    } catch (e) {
        report.ok = false;
        report.errors.push(String((e && e.stack) || e));
        try { report.screenshots.push(await shot(page, cfg.out, 'error')); } catch (e2) { /* ignore */ }
    }

    report.consoleErrors = dedupe(consoleErrors).slice(0, 40);
    report.failedRequests = dedupe(failedRequests).slice(0, 40);
    if (report.checks.some((c) => c.pass === false)) { report.ok = false; }

    if (!cfg.keepOpen) { await context.close(); await browser.close(); }
    console.log(JSON.stringify(report, null, 2));
    process.exit(report.ok ? 0 : 1);
})();

/**
 * First-run teaching dialogs ("Explore Dynamics 365", "Get Apps for Dynamics 365") sit on top of the
 * shell and swallow clicks, which reads as "the feature is broken" in every check that follows.
 */
async function dismissOverlays(page, report) {
    // Sweep EVERY frame, not just the main document: the first-run tour ("Explore Dynamics 365")
    // is an iframe with a full-page backdrop, and while it is up every click in the shell is
    // intercepted - which reads as "the feature does nothing" in every check that follows.
    const dismissed = [];
    for (const frame of page.frames()) {
        const hits = await frame.evaluate(() => {
            const out = [];
            const sel = '[id*="close" i], [class*="close" i], [title*="close" i], ' +
                        '[aria-label*="close" i], [id*="dontshow" i], [class*="dismiss" i]';
            const nodes = Array.prototype.slice.call(document.querySelectorAll(sel));
            for (const n of nodes) {
                const r = n.getBoundingClientRect();
                if (r.width < 8 || r.height < 8 || r.width > 220) continue;
                const tag = n.tagName.toLowerCase();
                if (!/^(a|button|span|div|img|i|input)$/.test(tag)) continue;
                try {
                    n.click();
                    out.push(tag + (n.id ? '#' + n.id : '') +
                             (n.className ? '.' + String(n.className).split(' ')[0] : ''));
                } catch (e) { /* next */ }
                if (out.length >= 5) break;
            }
            return out;
        }).catch(() => []);
        for (const h of hits) { dismissed.push((frame === page.mainFrame() ? '' : 'frame:') + h); }
    }
    try { await page.keyboard.press('Escape'); } catch (e) { /* ignore */ }
    await page.waitForTimeout(1500);
    if (dismissed.length) { report.dismissedOverlays = dismissed; }
}

/* -------------------------------------------------------------------- helpers */

async function shot(page, dir, name) {
    const file = path.join(dir, name.replace(/[^a-z0-9_-]/gi, '_') + '.png');
    await page.screenshot({ path: file, fullPage: false });
    return file;
}

function trim(s, n) {
    s = String(s == null ? '' : s).replace(/\s+/g, ' ');
    n = n || 300;
    return s.length > n ? s.slice(0, n - 1) + '…' : s;
}

function dedupe(list) {
    const seen = {}, out = [];
    for (const item of list) { if (!seen[item]) { seen[item] = 1; out.push(item); } }
    return out;
}
