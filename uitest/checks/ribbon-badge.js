/*
 * Example check - a ribbon button that carries a live count badge and opens a dropdown.
 *
 * This is the worked example the other modules point at. It was written against a real in-app
 * notification feature (an application-ribbon button, a count badge pinned to it by script, a
 * dropdown, and a full page behind it), and it is the shape most "did my customization actually
 * render" checks end up having:
 *
 *   1. exactly ONE instance of the control on the page - not zero, not three;
 *   2. the badge shows a number (digits normalised, so a localised UI still passes);
 *   3. clicking it opens the panel, and the panel has content;
 *   4. acting on an item changes the number;
 *   5. the "open the full page" link really lands on that page.
 *
 * Nothing here is specific to one organisation: every selector comes from an environment variable,
 * so point it at your own control. Defaults match the example feature.
 *
 *   $env:UITEST_BUTTON_SEL = '[id*="my.command."], [data-id*="my.command."]'
 *   $env:UITEST_BADGE_SEL  = '.my-badge:not(.my-hidden)'
 *   $env:UITEST_PANEL_SEL  = '#my-panel'
 *   $env:UITEST_ITEM_SEL   = '#my-panel .my-item'
 *   $env:UITEST_DISMISS_SEL= '#my-panel .my-item .my-dismiss'
 *   $env:UITEST_PAGE_URL   = 'mypage\.html'          # regex matched against page/frame URLs
 *   d365-uitest.ps1 -Check checks\ribbon-badge.js -App <appid>
 *
 * What this module taught, and why the odd-looking bits are there, is in docs/UI-TESTING.md.
 */
'use strict';

const BUTTON_SEL  = process.env.UITEST_BUTTON_SEL  || '[id*="op.notifications."], [data-id*="op.notifications."]';
const OWN_SEL     = process.env.UITEST_OWN_SEL     || '#op-notif-bell';
const BADGE_SEL   = process.env.UITEST_BADGE_SEL   || '.op-notif-badge:not(.op-notif-hidden)';
const PANEL_SEL   = process.env.UITEST_PANEL_SEL   || '#op-notif-panel';
const ITEM_SEL    = process.env.UITEST_ITEM_SEL    || '#op-notif-panel .op-notif-item';
const DISMISS_SEL = process.env.UITEST_DISMISS_SEL || '#op-notif-panel .op-notif-item .op-notif-dismiss';
const PAGE_LINK   = process.env.UITEST_PAGE_LINK   || '#op-notif-panel .op-notif-all';
const PAGE_URL    = new RegExp(process.env.UITEST_PAGE_URL || 'notificationcenter\\.html', 'i');
const CONTROL_SEL = BUTTON_SEL + ', ' + OWN_SEL;

/** Persian-Indic and Arabic-Indic digits to Latin, so assertions work on a localised UI. */
function latinDigits(t) {
    return String(t == null ? '' : t)
        .replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 0x06f0))
        .replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x0660));
}

async function run({ page, shot }) {
    const checks = [];
    const screenshots = [];
    const extra = {};
    const add = (name, pass, detail) => checks.push({ name, pass, detail: detail || '' });

    /* 1 - exactly one control ------------------------------------------------ */
    const ribbon = await countLogical(page, BUTTON_SEL);
    const own = await countLogical(page, OWN_SEL);
    extra.ribbonControls = ribbon;
    extra.injectedControls = own;
    add('exactly one instance of the control', (ribbon + own) === 1,
        'ribbon: ' + ribbon + ', injected: ' + own);
    add('no duplicate rendered alongside it', !(ribbon > 0 && own > 0),
        'ribbon: ' + ribbon + ', injected: ' + own);

    /* 2 - the badge ---------------------------------------------------------- */
    const badgeRaw = await textOf(page, BADGE_SEL);
    const badge = latinDigits(badgeRaw).trim();
    extra.badgeRaw = badgeRaw;
    extra.badge = badge;
    add('the badge shows a number', /^\d+\+?$/.test(badge),
        JSON.stringify(badgeRaw) + ' -> ' + badge);

    if (ribbon + own < 1) { return { checks, screenshots, extra }; }

    /* 3 - the panel ---------------------------------------------------------- */
    extra.click = await clickLogical(page, CONTROL_SEL);
    // Wait for the panel instead of sleeping: a shell that downloads a library first will fail a
    // fixed timeout and pass a proper wait.
    await page.locator(PANEL_SEL).first().waitFor({ state: 'visible', timeout: 20000 }).catch(() => {});
    const panelVisible = await isVisible(page, PANEL_SEL);
    await page.waitForTimeout(1500);
    const items = await countVisible(page, ITEM_SEL);
    extra.items = items;
    screenshots.push(await shot('ribbon-badge-panel'));
    add('clicking it opens the panel', panelVisible, 'visible: ' + panelVisible);
    add('the panel has items', items > 0, 'items: ' + items);

    if (!panelVisible) {
        // Distinguish "nothing is listening" from "something is covering it", and show what ran.
        extra.frameProbe = await probeFrames(page, PANEL_SEL);
        extra.trace = await page.evaluate(() => ((window.top || window).__opNotifTrace || []).slice(-20))
                                .catch(() => []);
    }

    /* 4 - acting on an item moves the number --------------------------------- */
    if (items > 0 && /^\d+$/.test(badge)) {
        const before = parseInt(badge, 10);
        await page.click(DISMISS_SEL, { timeout: 5000 }).catch(() => {});
        await page.waitForTimeout(6000);
        const after = latinDigits((await textOf(page, BADGE_SEL)) || '0').trim() || '0';
        extra.badgeBefore = before;
        extra.badgeAfter = after;
        add('acting on an item decrements the number', parseInt(after, 10) === before - 1,
            before + ' -> ' + after);
    }

    /* 5 - the full page ------------------------------------------------------ */
    const landed = await openLinkedPage(page);
    extra.page = landed;
    screenshots.push(await shot('ribbon-badge-page'));
    add('the linked page opens', !!landed.opened, JSON.stringify(landed));
    add('the linked page has rows', landed.rows > 0, 'rows: ' + landed.rows);

    return { checks, screenshots, extra };
}

/** The page may open in this tab, a new tab, or an iframe dialog - find whichever hosts it. */
async function openLinkedPage(page) {
    const context = page.context();
    const before = context.pages().length;
    await page.click(PAGE_LINK, { timeout: 5000 }).catch(() => {});
    await page.waitForTimeout(7000);
    for (const p of context.pages()) {
        if (PAGE_URL.test(p.url())) {
            await p.waitForTimeout(7000);         // a standalone tab still has to fetch its data
            const rows = await p.locator('[data-row], .op-nc-row, [role="row"]').count().catch(() => 0);
            return { opened: true, where: context.pages().length > before ? 'new tab' : 'same tab',
                     url: p.url(), rows };
        }
        for (const f of p.frames()) {
            if (PAGE_URL.test(f.url())) {
                const rows = await f.locator('[data-row], .op-nc-row, [role="row"]').count().catch(() => 0);
                return { opened: true, where: 'iframe', url: f.url(), rows };
            }
        }
    }
    return { opened: false, where: null, url: page.url(), rows: 0 };
}

/* -------------------------------------------------------------------- helpers */

/** Outermost visible matches only: a rendered button and its inner label can both carry the id. */
async function countLogical(page, selector) {
    return page.evaluate((sel) => {
        const nodes = Array.prototype.slice.call(document.querySelectorAll(sel));
        const visible = nodes.filter((n) => {
            const r = n.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
        });
        return visible.filter((n) => !visible.some((o) => o !== n && o.contains(n))).length;
    }, selector).catch(() => -1);
}

/** Reports WHY a click failed instead of swallowing it - an intercepted click looks like a bug. */
async function clickLogical(page, selector) {
    const handle = await page.evaluateHandle((sel) => {
        const nodes = Array.prototype.slice.call(document.querySelectorAll(sel));
        const visible = nodes.filter((n) => {
            const r = n.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
        });
        const outer = visible.filter((n) => !visible.some((o) => o !== n && o.contains(n)));
        return outer[0] || null;
    }, selector);
    const el = handle.asElement();
    if (!el) { return { clicked: false, how: 'no element' }; }
    try {
        await el.click({ timeout: 6000 });
        return { clicked: true, how: 'real click' };
    } catch (e) {
        const err = String((e && e.message) || e).split(String.fromCharCode(10))[0].slice(0, 180);
        await el.evaluate((n) => n.click()).catch(() => {});
        return { clicked: true, how: 'dom click after real click failed', error: err };
    }
}

async function probeFrames(page, panelSel) {
    const out = [];
    for (const f of page.frames()) {
        const info = await f.evaluate((sel) => ({
            hasPanel: !!document.querySelector(sel),
            panelClass: (document.querySelector(sel) || {}).className || null,
            isTop: window === window.top
        }), panelSel).catch((e) => ({ error: String(e && e.message || e) }));
        if (info && (info.hasPanel || info.isTop)) {
            out.push({ url: (f.url() || '').slice(0, 110), info });
        }
    }
    return out;
}

async function countVisible(page, selector) {
    return page.evaluate((sel) => {
        const nodes = document.querySelectorAll(sel);
        let n = 0;
        for (let i = 0; i < nodes.length; i++) {
            const r = nodes[i].getBoundingClientRect();
            if (r.width > 0 && r.height > 0) { n++; }
        }
        return n;
    }, selector).catch(() => -1);
}

async function isVisible(page, selector) {
    return page.locator(selector).first().isVisible({ timeout: 2000 }).catch(() => false);
}

async function textOf(page, selector) {
    return page.locator(selector).first().textContent({ timeout: 2000 }).catch(() => null);
}

module.exports = { run };
