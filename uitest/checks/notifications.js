/*
 * Check module for the Orchid Notification System bell.
 *
 * A check module exports  run({page, context, cfg, shot})  and returns
 *   { checks: [{name, pass, detail}], screenshots: [paths], extra: {...} }
 *
 * What matters here, in order:
 *   1. exactly ONE application-ribbon Notifications button on the page (three appeared once,
 *      because Unified Interface renders every global tab's groups into one command bar);
 *   2. exactly ONE header bell, with a numeric badge;
 *   3. clicking the bell opens the dropdown with items;
 *   4. "Open notification centre" actually lands on the centre page and lists rows;
 *   5. marking one read decrements the badge.
 */
'use strict';

const RIBBON_SEL = '[id*="op.notifications."], [data-id*="op.notifications."]';
const OWN_BELL_SEL = '#op-notif-bell';
// The bell is whichever of the two exists: the application-ribbon button (Unified Interface draws
// Mscrm.GlobalTab.Tools straight into the top header) or our injected fallback bell.
const BELL_SEL = RIBBON_SEL + ', ' + OWN_BELL_SEL;
const PANEL_SEL = '#op-notif-panel';
const BADGE_SEL = '.op-notif-badge:not(.op-notif-hidden)';

/** Persian-Indic digits to Latin, so assertions work on a localised UI. */
function latinDigits(text) {
    return String(text == null ? '' : text).replace(/[۰-۹]/g,
        (d) => String(d.charCodeAt(0) - 0x06f0)).replace(/[٠-٩]/g,
        (d) => String(d.charCodeAt(0) - 0x0660));
}

async function run({ page, cfg, shot }) {
    const checks = [];
    const screenshots = [];
    const extra = {};

    const add = (name, pass, detail) => checks.push({ name, pass, detail: detail || '' });

    /* 1 - exactly one bell, and it is the ribbon button where the shell draws one --------- */
    const ribbonCount = await countLogical(page, RIBBON_SEL);
    const ownCount = await countLogical(page, OWN_BELL_SEL);
    extra.ribbonBells = ribbonCount;
    extra.fallbackBells = ownCount;
    add('exactly one bell on the page', (ribbonCount + ownCount) === 1,
        'application-ribbon bells: ' + ribbonCount + ', injected fallback bells: ' + ownCount);
    add('no duplicate bell alongside the ribbon button', !(ribbonCount > 0 && ownCount > 0),
        'ribbon: ' + ribbonCount + ', fallback: ' + ownCount);

    /* 2 - the badge -------------------------------------------------------- */
    const bells = ribbonCount + ownCount;
    const badgeRaw = await textOf(page, BADGE_SEL);
    const badgeText = latinDigits(badgeRaw).trim();
    extra.badgeText = badgeRaw;
    extra.badgeDigits = badgeText;
    add('bell shows a numeric unread badge', /^\d+\+?$/.test(badgeText),
        'badge text: ' + JSON.stringify(badgeRaw) + ' -> ' + badgeText);

    /* also confirm the library really loaded, not just that markup exists */
    const libState = await page.evaluate(() => {
        const w = window;
        return {
            api: !!(w.OP && w.OP.Notifications && w.OP.Notifications.fetchUnread),
            bell: !!(w.OP && w.OP.Notifications && w.OP.Notifications.Bell),
            boot: !!(w.OP && w.OP.NotificationsBootstrap),
            css: !!document.getElementById('op-notif-css')
        };
    }).catch((e) => ({ error: String(e) }));
    extra.libState = libState;
    add('client library, bell and stylesheet all loaded in the shell window',
        !!(libState.api && libState.bell && libState.css), JSON.stringify(libState));

    /* 3 - the bell opens the dropdown, in BOTH shells ------------------------
     * Worth stating plainly: the classic web client behaves the same as Unified Interface here. It
     * only looked broken because the first-run tour dialog sits in an iframe with a full-page
     * backdrop and silently intercepts every click - see dismissOverlays in uitest.js.
     */
    if (bells >= 1) {
        // Sentinel: if this value does not survive the click, the shell navigated/reloaded, which
        // is the difference between "our handler never ran" and "our handler ran and was wiped".
        await page.evaluate(() => { (window.top || window).__opNotifSentinel = Date.now(); }).catch(() => {});
        extra.bellClick = await clickLogical(page, BELL_SEL);
        // Wait for the panel rather than sleeping a fixed amount: in the classic client the ribbon
        // command has to download the library before it can open anything, which takes seconds.
        await page.locator(PANEL_SEL).first()
            .waitFor({ state: 'visible', timeout: 20000 }).catch(() => {});
        const panelVisible = await isVisible(page, PANEL_SEL);
        await page.waitForTimeout(1500);
        const items = await countVisible(page, PANEL_SEL + ' .op-notif-item');
        extra.dropdownItems = items;
        screenshots.push(await shot('bell-dropdown'));
        if (!panelVisible) {
            // Where did the panel actually go, and can the API open it at all? Distinguishes a
            // click-plumbing problem from a panel-logic problem, and catches the case where the
            // library installed itself in an iframe instead of the shell window.
            extra.frameProbe = await probeFrames(page);
            extra.sentinelSurvived = await page.evaluate(() => !!(window.top || window).__opNotifSentinel).catch(() => null);
            extra.trace = await page.evaluate(() => {
                const w = window.top || window;
                return (w.__opNotifTrace || []).slice(-25);
            }).catch(() => []);
            extra.apiToggle = await page.evaluate(() => {
                try {
                    const w = window.top || window;
                    if (!(w.OP && w.OP.Notifications && w.OP.Notifications.Bell)) { return 'no bell in top window'; }
                    w.OP.Notifications.Bell.openPanel();
                    const p = w.document.getElementById('op-notif-panel');
                    if (!p) { return 'openPanel ran but no panel element'; }
                    const r = p.getBoundingClientRect();
                    return 'class=' + p.className + ' rect=' + Math.round(r.left) + ',' + Math.round(r.top) +
                           ' ' + Math.round(r.width) + 'x' + Math.round(r.height);
                } catch (e) { return 'threw: ' + String(e && e.message || e); }
            }).catch((e) => 'evaluate failed: ' + String(e));
            await page.waitForTimeout(1500);
            screenshots.push(await shot('bell-after-api-toggle'));
        }
        add('clicking the bell opens the dropdown', panelVisible, 'panel visible: ' + panelVisible);
        add('dropdown lists notifications', items > 0, 'items: ' + items);

        /* 5 - mark one read decrements the badge --------------------------- */
        if (items > 0 && /^\d+$/.test((badgeText || '').trim())) {
            const before = parseInt(badgeText, 10);
            await page.click(PANEL_SEL + ' .op-notif-item .op-notif-dismiss', { timeout: 5000 }).catch(() => {});
            await page.waitForTimeout(6000);
            const after = latinDigits((await textOf(page, BADGE_SEL)) || '0').trim() || '0';
            extra.badgeBefore = before;
            extra.badgeAfter = after;
            add('marking one read decrements the badge',
                parseInt(after || '0', 10) === before - 1,
                before + ' -> ' + after);
        }

        /* 4 - the notification centre ------------------------------------- */
        const opened = await openCentre(page);
        extra.centre = opened;
        screenshots.push(await shot('notification-centre'));
        add('notification centre opens', !!opened.opened, JSON.stringify(opened));
        add('notification centre lists rows', opened.rows > 0, 'rows: ' + opened.rows);
    }

    return { checks, screenshots, extra };
}

/** The centre may open in this tab, a new one, or an iframe; find whichever hosts it. */
async function openCentre(page) {
    const before = page.context().pages().length;
    await page.click(PANEL_SEL + ' .op-notif-all', { timeout: 5000 }).catch(() => {});
    await page.waitForTimeout(7000);
    return findCentre(page, before);
}

async function findCentre(page, before) {
    const context = page.context();
    const pages = context.pages();
    for (const p of pages) {
        const url = p.url();
        if (/op_notificationcenter\.html/i.test(url)) {
            // A standalone tab still has to pull ClientGlobalContext and then query, so give it room.
            await p.waitForTimeout(7000);
            const rows = await p.locator('#opNcList .op-nc-row').count().catch(() => 0);
            const status = await p.locator('#opNcStatus').textContent().catch(() => '');
            return { opened: true, where: pages.length > before ? 'new tab' : 'same tab', url, rows, status: (status || '').trim() };
        }
        // it may also be hosted in an iframe (navigateTo dialog / classic dialog)
        for (const f of p.frames()) {
            if (/op_notificationcenter\.html/i.test(f.url())) {
                const rows = await f.locator('#opNcList .op-nc-row').count().catch(() => 0);
                const status = await f.locator('#opNcStatus').textContent().catch(() => '');
                return { opened: true, where: 'iframe', url: f.url(), rows, status: (status || '').trim() };
            }
        }
    }
    return { opened: false, where: null, url: page.url(), rows: 0 };
}

/** Per-frame view of where our markup and library ended up. */
async function probeFrames(page) {
    const out = [];
    for (const f of page.frames()) {
        const info = await f.evaluate(() => ({
            hasPanel: !!document.getElementById('op-notif-panel'),
            panelClass: (document.getElementById('op-notif-panel') || {}).className || null,
            hasBellLib: !!(window.OP && window.OP.Notifications && window.OP.Notifications.Bell),
            hasApi: !!(window.OP && window.OP.Notifications && window.OP.Notifications.fetchUnread),
            badges: document.querySelectorAll('.op-notif-badge').length,
            isTop: window === window.top
        })).catch((e) => ({ error: String(e && e.message || e) }));
        if (info && (info.hasPanel || info.hasBellLib || info.badges || info.isTop)) {
            out.push({ url: (f.url() || '').slice(0, 110), name: f.name(), info });
        }
    }
    return out;
}

/* -------------------------------------------------------------------- helpers */

/** Counts only outermost matches: a rendered ribbon button and its inner label can both carry the
 *  command id, which made one button look like two. */
async function countLogical(page, selector) {
    return page.evaluate((sel) => {
        const nodes = Array.prototype.slice.call(document.querySelectorAll(sel));
        const visible = nodes.filter((n) => {
            const r = n.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
        });
        return visible.filter((n) => !visible.some((other) => other !== n && other.contains(n))).length;
    }, selector).catch(() => -1);
}

/**
 * Clicks the outermost visible match and REPORTS what went wrong. Swallowing the error here cost
 * real time: a click intercepted by an overlay looked identical to a broken feature.
 * Falls back to a DOM click so a check can distinguish "nothing is listening" from "something is
 * covering the button".
 */
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
