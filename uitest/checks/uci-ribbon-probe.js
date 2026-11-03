/*
 * Does the Unified Interface actually serve a ribbon button? Asks GetClientMetadata for one form's command bar N times
 * from the signed-in page and counts the answers that contain the button.
 *
 * Why this exists: the classic web client and RetrieveEntityRibbon merge the ribbon at run time, but the Unified
 * Interface reads a copy the server prepared earlier (FIELD-NOTES section 17). A button can be on the server, show in
 * classic, and still be missing from every Unified Interface command bar. Load-balanced front ends answer in turn,
 * so one stale server shows up as a share of the answers rather than all or nothing.
 *
 *   d365-uitest.ps1 -Check checks\uci-ribbon-probe.js -App <appid>
 *
 * Environment:
 *   UITEST_ENTITY       logical name of the table, e.g. account                          (required)
 *   UITEST_FORM_ID      id of a main form of that table                                  (required)
 *   UITEST_BUTTON_ID    text only your button's definition contains, e.g. its Button or
 *                       Command id (abc.account.MyButton.Button)                         (required)
 *   UITEST_APP_ID       the app to ask for; defaults to -App
 *   UITEST_PROBE_COUNT  how many times to ask (default 9)
 */
'use strict';

async function run({ page, cfg }) {
    const entity = process.env.UITEST_ENTITY || '';
    const form = (process.env.UITEST_FORM_ID || '').replace(/[{}]/g, '');
    const button = process.env.UITEST_BUTTON_ID || '';
    const app = (process.env.UITEST_APP_ID || cfg.app || '').replace(/[{}]/g, '');
    const n = parseInt(process.env.UITEST_PROBE_COUNT || '9', 10);
    if (!entity || !form || !button) {
        return { checks: [{ name: 'inputs', pass: false, detail: 'set UITEST_ENTITY, UITEST_FORM_ID and UITEST_BUTTON_ID' }] };
    }

    // the same query the Unified Interface sends for a form's command bar (KeepOnly ribbon)
    const query = { MetadataType: 'form', MetadataSubtype: 'Main', EntityLogicalName: entity, MetadataId: form,
                    MetadataNames: [JSON.stringify({ KeepOnly: ['ribbon'] })], GetDefault: false,
                    DependencyDepth: 'OnDemandWithContext' };
    if (app) { query.AppId = app; }

    const answers = await page.evaluate(async ({ base, query, button, n }) => {
        const out = [];
        for (let i = 0; i < n; i++) {
            const url = base + '/api/data/v9.0/GetClientMetadata(ClientMetadataQuery=@ClientMetadataQuery)' +
                        '?@ClientMetadataQuery=' + encodeURIComponent(JSON.stringify(query)) + '&probe=' + Date.now() + '_' + i;
            try {
                const r = await fetch(url, { credentials: 'same-origin', cache: 'no-store',
                                             headers: { Accept: 'application/json', 'OData-MaxVersion': '4.0', 'OData-Version': '4.0' } });
                const t = await r.text();
                out.push({ status: r.status, length: t.length, found: t.indexOf(button) >= 0 });
            } catch (e) { out.push({ error: String(e) }); }
        }
        return out;
    }, { base: cfg.url, query, button, n });

    const found = answers.filter((a) => a.found).length;
    const failed = answers.filter((a) => a.error || a.status !== 200);
    const lengths = Array.from(new Set(answers.filter((a) => a.length).map((a) => a.length)));
    return {
        checks: [
            { name: 'GetClientMetadata answered', pass: failed.length === 0, detail: failed.length ? JSON.stringify(failed[0]) : answers.length + ' answers' },
            { name: 'every answer holds ' + button, pass: found === answers.length, detail: found + ' of ' + answers.length +
              ' (distinct answer sizes: ' + lengths.join(', ') + ')' }
        ],
        extra: { query, answers }
    };
}

module.exports = { run };
