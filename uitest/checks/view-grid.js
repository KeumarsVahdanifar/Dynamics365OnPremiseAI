/*
 * Open an entity list and report what the grid actually renders.
 *
 * Run it after editing a view's FetchXML or layout: a saved query that is valid XML can still fail
 * at render time, show no columns, or come back empty because of the filter you just wrote - and the
 * server will not tell you.
 *
 *   d365-uitest.ps1 -Check checks\view-grid.js -App <appid> `
 *       -Goto "main.aspx?appid=<appid>&pagetype=entitylist&etn=account"
 *
 * Optional environment inputs:
 *   UITEST_EXPECT_ROWS      minimum number of rows expected (default 0)
 *   UITEST_EXPECT_HEADERS   comma-separated column headers that must be present
 */
'use strict';

async function run({ page, shot }) {
    const checks = [];
    const add = (name, pass, detail) => checks.push({ name, pass, detail: detail || '' });

    const minRows = parseInt(process.env.UITEST_EXPECT_ROWS || '0', 10);
    const wantHeaders = (process.env.UITEST_EXPECT_HEADERS || '')
        .split(',').map((s) => s.trim()).filter(Boolean);

    const info = await page.evaluate(() => {
        // Both shells expose the grid through role-based markup, which survives releases better
        // than their internal class names.
        const grid = document.querySelector('[role="grid"], .ms-crm-List, #gridBodyTable');
        const headers = Array.prototype.slice
            .call(document.querySelectorAll('[role="columnheader"], #gridBodyTable th'))
            .map((h) => (h.innerText || h.textContent || '').trim())
            .filter((t) => t.length && t.length < 60);
        const rows = document.querySelectorAll('[role="row"][row-index], #gridBodyTable tr[oid], [role="rowgroup"] [role="row"]');
        const emptyMsg = (function () {
            const body = (document.body.innerText || '');
            const m = body.match(/(No data available|No records|هیچ داده|No .* records are available)/i);
            return m ? m[0] : null;
        })();
        return {
            gridFound: !!grid,
            headers: headers.slice(0, 30),
            rowCount: rows.length,
            emptyMessage: emptyMsg,
            title: document.title
        };
    }).catch((e) => ({ gridFound: false, error: String(e) }));

    add('a grid rendered', !!info.gridFound, info.error || ('headers: ' + (info.headers || []).length));
    add('the grid has column headers', (info.headers || []).length > 0,
        (info.headers || []).slice(0, 8).join(' | '));
    add('row count is at least ' + minRows, (info.rowCount || 0) >= minRows,
        'rows: ' + info.rowCount + (info.emptyMessage ? ' ("' + info.emptyMessage + '")' : ''));
    for (const h of wantHeaders) {
        add('column shown: ' + h, (info.headers || []).some((x) => x.indexOf(h) > -1),
            'headers: ' + (info.headers || []).join(' | '));
    }

    return { checks, screenshots: [await shot('view-grid')], extra: info };
}

module.exports = { run };
