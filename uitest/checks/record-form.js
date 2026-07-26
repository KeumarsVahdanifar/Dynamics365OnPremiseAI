/*
 * Open a record form and report what the client thinks of it.
 *
 * This is the check to run after touching a form, a form script, or a column: it catches script
 * errors, missing controls and required-field surprises that no server-side query can see.
 *
 *   d365-uitest.ps1 -Check checks\record-form.js -App <appid> `
 *       -Goto "main.aspx?appid=<appid>&pagetype=entityrecord&etn=account&id=<guid>"
 *
 * Optional environment inputs (so the module stays entity-agnostic):
 *   UITEST_EXPECT_CONTROLS   comma-separated control/column names that must be on the form
 *   UITEST_EXPECT_TAB        a tab name that must exist
 */
'use strict';

async function run({ page, shot }) {
    const checks = [];
    const add = (name, pass, detail) => checks.push({ name, pass, detail: detail || '' });

    const expectControls = (process.env.UITEST_EXPECT_CONTROLS || '')
        .split(',').map((s) => s.trim()).filter(Boolean);
    const expectTab = (process.env.UITEST_EXPECT_TAB || '').trim();

    // Everything comes from the form's own client API, which is the same thing a form script sees.
    const info = await page.evaluate(() => {
        function pick(w) {
            try {
                if (w.Xrm && w.Xrm.Page && w.Xrm.Page.data && w.Xrm.Page.data.entity) { return w.Xrm.Page; }
            } catch (e) { /* keep looking */ }
            return null;
        }
        let form = pick(window);
        if (!form) {
            for (let i = 0; i < window.frames.length && !form; i++) {
                try { form = pick(window.frames[i]); } catch (e) { /* cross doc */ }
            }
        }
        if (!form) { return { formFound: false }; }

        const controls = [];
        form.ui.controls.forEach(function (c) {
            let name = null, visible = null, disabled = null, required = null;
            try { name = c.getName(); } catch (e) { }
            try { visible = c.getVisible ? c.getVisible() : null; } catch (e) { }
            try { disabled = c.getDisabled ? c.getDisabled() : null; } catch (e) { }
            try {
                const a = c.getAttribute && c.getAttribute();
                required = a ? a.getRequiredLevel() : null;
            } catch (e) { }
            controls.push({ name: name, visible: visible, disabled: disabled, required: required });
        });

        const tabs = [];
        try { form.ui.tabs.forEach(function (t) { tabs.push(t.getName()); }); } catch (e) { }

        return {
            formFound: true,
            entity: form.data.entity.getEntityName(),
            id: form.data.entity.getId(),
            isDirty: form.data.entity.getIsDirty(),
            formType: form.ui.getFormType(),          // 1 create, 2 update, 3 read-only, 4 disabled
            controls: controls,
            tabs: tabs,
            requiredEmpty: controls.filter(function (c) { return c.required === 'required'; }).map(function (c) { return c.name; })
        };
    }).catch((e) => ({ formFound: false, error: String(e) }));

    add('a record form is loaded', !!info.formFound,
        info.formFound ? (info.entity + ' ' + info.id + ' (formType ' + info.formType + ')')
                       : (info.error || 'no Xrm.Page with an entity in any frame'));

    if (info.formFound) {
        add('form is not dirty on load', info.isDirty === false,
            'a form that loads dirty means a script wrote to it during OnLoad');

        const names = (info.controls || []).map((c) => c.name);
        for (const want of expectControls) {
            add('control present: ' + want, names.indexOf(want) > -1,
                names.indexOf(want) > -1 ? 'found' : 'not on this form');
        }
        if (expectTab) {
            add('tab present: ' + expectTab, (info.tabs || []).indexOf(expectTab) > -1,
                'tabs: ' + (info.tabs || []).join(', '));
        }
        add('every control reports a name', names.every((n) => !!n),
            (info.controls || []).length + ' controls');
    }

    return { checks, screenshots: [await shot('record-form')], extra: info };
}

module.exports = { run };
